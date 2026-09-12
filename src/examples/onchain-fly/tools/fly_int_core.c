// fly_int_core.c — integer twin of the FlyEngine kernel (HANDOFF §3.1–§3.6).
//
// Q24 int64 membrane state, Q64 decay tables, round-half-up (rhu) at every product.
// Iteration order is kernel.cpp's exactly: pre-pass over changed drives, then per step
// sweep(active list, in-place compaction) → deliver(ring FIFO, CSR order) → reset(this
// step's spikes) → clock++.  Nothing here is floating point; every operator running the
// same code on the same bytes produces the same bytes.  fly_int.py holds a pure-Python
// implementation of the same arithmetic used to cross-check this file on small graphs.
//
// Build: clang -O2 -std=c11 -shared -fPIC fly_int_core.c -o libflyint.dylib
#include <stdint.h>
#include <string.h>

typedef unsigned __int128 u128;
typedef __int128 i128;

#define ONE64   ((u128)1 << 64)
#define HALF64  ((u128)1 << 63)
#define HALF56  ((u128)1 << 55)
#define TBL     1024
#define FAR_B_ZERO   2219   /* b := 0 for d >= 2219  (50·64·ln2 = 2218.07) */
#define FAR_ALL_ZERO 8873   /* a := b := c := 0 for d >= 8873 (200·64·ln2 = 8872.28) */

static const uint64_t A1 = 18354740553814661001ULL;   /* floor(e^(-1/200) · 2^64) */
static const uint64_t B1 = 18081474067879353234ULL;   /* floor(e^(-1/50)  · 2^64) */
static const int64_t  R_Q24     = -(52LL << 24);
static const int64_t  THR_Q24   = -(45LL << 24);
static const int32_t  BOUND_Q16 = 7 << 16;
static const int64_t  BOUND_Q24 = 7LL << 24;
static const uint64_t W_NUM     = 23068672ULL;         /* 11 · 2^21 : w_Q24 = count·W_NUM/5 */

static uint64_t tA[TBL + 1], tB[TBL + 1], tC[TBL + 1];  /* index 0 unused (= 2^64, identity) */
static int tables_built = 0;

static inline uint64_t rhu64_u(u128 x) { return (uint64_t)((x + HALF64) >> 64); }
static inline int64_t  rhu64_s(i128 x) { return (int64_t)((x + (i128)HALF64) >> 64); }   /* EVM sar(64, x + 2^63) */
static inline int64_t  rhu56_s(i128 x) { return (int64_t)((x + (i128)HALF56) >> 56); }   /* EVM sar(56, x + 2^55) */

void fly_build_tables(void) {
    u128 a = ONE64, b = ONE64;
    tA[0] = tB[0] = tC[0] = 0;                        /* never read: d == 0 short-circuits */
    for (int d = 1; d <= TBL; d++) {
        a = rhu64_u(a * A1);
        b = rhu64_u(b * B1);
        tA[d] = (uint64_t)a; tB[d] = (uint64_t)b; tC[d] = (uint64_t)((a - b) / 3);
    }
    tables_built = 1;
}
void fly_get_tables(uint64_t *a, uint64_t *b, uint64_t *c) {
    if (!tables_built) fly_build_tables();
    memcpy(a, tA, sizeof tA); memcpy(b, tB, sizeof tB); memcpy(c, tC, sizeof tC);
}

/* x^q in Q64 by right-to-left square-and-multiply, rhu at every product; result starts at 2^64. */
static u128 powq(uint64_t x, uint64_t q) {
    u128 result = ONE64, base = x;
    while (q) {
        if (q & 1) result = rhu64_u(result * base);
        base = rhu64_u(base * base);
        q >>= 1;
    }
    return result;
}
static inline u128 mulq(u128 x, uint64_t y) { return rhu64_u(x * y); }   /* x <= 2^64 */

/* Decay factors for d > 1024: q = d >> 10, r = d & 1023; a = rhu(tA[1024]^q · tA[r]) etc. */
void fly_far_decay(int64_t d, uint64_t *a, uint64_t *b, uint64_t *c) {
    if (d >= FAR_ALL_ZERO) { *a = *b = *c = 0; return; }
    uint64_t q = (uint64_t)d >> 10, r = (uint64_t)d & 1023;
    u128 pa = powq(tA[TBL], q);
    u128 ra = r ? mulq(pa, tA[r]) : pa;
    u128 rb = 0;
    if (d < FAR_B_ZERO) { u128 pb = powq(tB[TBL], q); rb = r ? mulq(pb, tB[r]) : pb; }
    *a = (uint64_t)ra; *b = (uint64_t)rb; *c = (uint64_t)((ra - rb) / 3);
}

typedef struct {
    int32_t   n;
    const uint32_t *ptr;      /* n+1 entries: sign<<31 | offset */
    const uint32_t *edges;    /* post<<14 | count */
    int64_t  *v;              /* Q24 */
    int64_t  *g;              /* Q24 */
    int32_t  *drive;          /* Q16 */
    uint32_t *count;
    uint64_t *last;           /* u48 */
    uint8_t  *refr;
    uint8_t  *flags;          /* bit0 = in active list */
    int32_t  *active;         /* capacity n */
    uint32_t *ring;           /* capacity n, FIFO */
    uint32_t *slotCount;      /* 19 */
    uint64_t  clock;
    int32_t   nActive;
    uint32_t  head, tail, inflight;
    int32_t   delay, rfc, slots;
} FlyState;

static inline void evolve(FlyState *s, int32_t i, uint64_t now, int32_t I) {
    uint64_t lastv = s->last[i];
    if (now == lastv) return;                         /* now >= last validated at entry */
    int64_t d = (int64_t)(now - lastv);
    uint8_t refr = s->refr[i];
    if (refr) {
        int64_t frozen = refr - 1;
        int64_t skip = d < frozen ? d : frozen;
        refr = (d >= refr) ? 0 : (uint8_t)(refr - d);
        d -= skip;
        s->refr[i] = refr;
    }
    if (d > 0) {
        uint64_t a, b, c;
        if (d <= TBL) { a = tA[d]; b = tB[d]; c = tC[d]; } else fly_far_decay(d, &a, &b, &c);
        int64_t v = s->v[i], gq = s->g[i];
        i128 t1 = (i128)(v - R_Q24) * (i128)a;
        i128 t2 = (i128)I * (i128)(int64_t)(ONE64 - a);   /* ONE64 - a fits: a < 2^64 for d >= 1 */
        i128 t3 = (i128)gq * (i128)c;
        s->v[i] = R_Q24 + rhu64_s(t1) + rhu56_s(t2) + rhu64_s(t3);
        s->g[i] = rhu64_s((i128)gq * (i128)b);
    }
    s->last[i] = now;
}

static inline void awaken(FlyState *s, int32_t i) {
    if (!(s->flags[i] & 1)) { s->flags[i] |= 1; s->active[s->nActive++] = i; }
}

/* Pre-pass (kernel.cpp:26-28): settle history under the old drive, install the new one, awaken. */
void fly_set_drives(FlyState *s, const int32_t *newDrive) {
    if (!tables_built) fly_build_tables();
    for (int32_t i = 0; i < s->n; i++) {
        if (newDrive[i] != s->drive[i]) {
            evolve(s, i, s->clock - 1, s->drive[i]);
            s->drive[i] = newDrive[i];
            awaken(s, i);
        }
    }
}

void fly_advance(FlyState *s, int64_t steps) {
    if (!tables_built) fly_build_tables();
    const int32_t n = s->n;
    for (int64_t t = 0; t < steps; t++) {
        const uint64_t now = s->clock;
        const int slot = (int)(now % (uint64_t)s->slots), future = (int)((now + (uint64_t)s->delay) % (uint64_t)s->slots);
        const uint32_t tailBefore = s->tail;
        uint32_t pushed = 0;
        int32_t kept = 0;
        const int32_t original = s->nActive;
        /* (2) threshold sweep over the active-list snapshot, in-place compaction */
        for (int32_t k = 0; k < original; k++) {
            const int32_t i = s->active[k];
            const int32_t I = s->drive[i];
            evolve(s, i, now, I);
            if (s->refr[i] == 0 && s->v[i] > THR_Q24) {
                s->ring[s->tail] = (uint32_t)i; s->tail = (s->tail + 1 == (uint32_t)n) ? 0 : s->tail + 1;
                pushed++; s->count[i]++;
            }
            const int canFire = (s->v[i] > THR_Q24) || (I > BOUND_Q16) || (((int64_t)I << 8) + s->g[i] > BOUND_Q24);
            if (canFire) s->active[kept++] = i; else s->flags[i] &= (uint8_t)~1;
        }
        s->nActive = kept;
        /* (3) deliver spikes emitted at now - delay, ring FIFO order, CSR edge order */
        const uint32_t nDeliver = s->slotCount[slot];
        for (uint32_t q = 0; q < nDeliver; q++) {
            const int32_t i = (int32_t)s->ring[s->head]; s->head = (s->head + 1 == (uint32_t)n) ? 0 : s->head + 1;
            const uint32_t p0 = s->ptr[i], p1 = s->ptr[i + 1];
            const int neg = (int)(p0 >> 31);
            const uint32_t e0 = p0 & 0x7fffffffu, e1 = p1 & 0x7fffffffu;
            for (uint32_t e = e0; e < e1; e++) {
                const uint32_t edge = s->edges[e];
                const int32_t j = (int32_t)(edge >> 14);
                int64_t w = (int64_t)(((uint64_t)(edge & 0x3fffu) * W_NUM) / 5);
                if (neg) w = -w;
                evolve(s, j, now, s->drive[j]);
                if (s->refr[j] == 0) { s->g[j] += w; awaken(s, j); }
            }
        }
        s->slotCount[slot] = 0; s->inflight -= nDeliver;
        /* (5) reset this step's spikes (after delivery: Brian2 parity) */
        for (uint32_t p = tailBefore; p != s->tail; p = (p + 1 == (uint32_t)n) ? 0 : p + 1) {
            const int32_t i = (int32_t)s->ring[p];
            s->v[i] = R_Q24; s->g[i] = 0; s->refr[i] = (uint8_t)s->rfc;
        }
        s->slotCount[future] = pushed; s->inflight += pushed;
        s->clock = now + 1;
    }
}

/* (M) materialize every neuron at the observation boundary clock-1. */
void fly_materialize(FlyState *s) {
    if (!tables_built) fly_build_tables();
    for (int32_t i = 0; i < s->n; i++) evolve(s, i, s->clock - 1, s->drive[i]);
}

/* Exposed for the Python cross-check. */
void fly_evolve_one(FlyState *s, int32_t i, uint64_t now, int32_t I) { if (!tables_built) fly_build_tables(); evolve(s, i, now, I); }
int fly_shift_is_arithmetic(void) { volatile i128 m = -1; return (int)((m >> 1) == -1); }
