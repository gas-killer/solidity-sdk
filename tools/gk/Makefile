# tools/gk — the gkvm guest toolchain.
#
#   make test          unit tests; the gk-run / compiler legs skip unless their inputs exist
#   make golden        regenerate test/fixtures/gkvm/*_vectors.json from direct gk-run
#   make golden-check  the CI fixture diff: fresh direct-gk-run vectors must equal the
#                      committed ones byte for byte, then the forge ffi suites replay them
#                      through GkVmFfiShim (shim output ≡ direct gk-run)
#   make crt-check     bundled guest-crt/ is byte-identical to gas-analyzer's gk-guest-crt
#
# GK_RUN        gk-run sidecar binary       (default: sibling gas-analyzer release build)
# GK_GUEST_CRT  gk-guest-crt + link.ld dir  (default: sibling gas-analyzer crates/gkvm/guest)

SDK_ROOT := $(abspath $(CURDIR)/../..)
GAS_ANALYZER ?= $(abspath $(SDK_ROOT)/../gas-analyzer)
GK_RUN ?= $(wildcard $(GAS_ANALYZER)/target/release/gk-run)
GK_GUEST_CRT ?= $(wildcard $(GAS_ANALYZER)/crates/gkvm/guest)
PYTHON ?= python3
FORGE ?= forge

GOLDEN_DIR := test/fixtures/gkvm
GOLDEN_SCRATCH := cache/gkvm/golden

# $(1) = output dir, relative to the sdk root. Every vector set the golden suite replays
# (test/GkVmGolden.t.sol lists the same three files). bench-c retires 8 instructions per
# iteration + 157, so N = 10^6 under a 1000-cycle budget is the out-of-cycles vector.
define golden_vectors
cd $(SDK_ROOT) && $(PYTHON) -B tools/gk vectors $(GOLDEN_DIR)/hello-c.elf --gk-run "$(GK_RUN)" \
	--out $(1)/hello-c_vectors.json \
	--input 0x --input 0x11223344 \
	--input 0x00000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000670726f6d70740000000000000000000000000000000000000000000000000000
cd $(SDK_ROOT) && $(PYTHON) -B tools/gk vectors $(GOLDEN_DIR)/bench-c.elf --gk-run "$(GK_RUN)" \
	--out $(1)/bench-c_vectors.json \
	--input 0x0000000000000000 --input 0x00000000000f4240 --input 0x01 --input 0x
cd $(SDK_ROOT) && $(PYTHON) -B tools/gk vectors $(GOLDEN_DIR)/bench-c.elf --gk-run "$(GK_RUN)" \
	--name bench-c-limit1000 --out $(1)/bench-c-limit1000_vectors.json --cycle-limit 1000 \
	--input 0x00000000000f4240 --input 0x000000000000000a --input 0x01
endef

test:
	GK_RUN="$(GK_RUN)" GK_GUEST_CRT="$(GK_GUEST_CRT)" $(PYTHON) -B test_gk.py -v

golden: need-gk-run
	$(call golden_vectors,$(GOLDEN_DIR))

golden-check: need-gk-run
	$(call golden_vectors,$(GOLDEN_SCRATCH))
	cd $(SDK_ROOT) && for f in hello-c bench-c bench-c-limit1000; do \
		diff -u $(GOLDEN_DIR)/$${f}_vectors.json $(GOLDEN_SCRATCH)/$${f}_vectors.json || exit 1; \
	done
	@echo "golden-check: direct gk-run == committed fixtures (3 files)"
	cd $(SDK_ROOT) && GK_RUN="$(GK_RUN)" FOUNDRY_PROFILE=gkvm-ffi \
		$(FORGE) test --match-contract 'GkVm(Golden|FfiShim)Test'

# The bundled gk-guest-crt (what `gk init` vendors, what `gk build` falls back to) must be
# byte-identical to gas-analyzer's. Not part of `test`: it compares against whatever the
# sibling checkout has checked out, which CI pins to an older crt.
crt-check:
	@test -n "$(GK_GUEST_CRT)" || { echo "no gas-analyzer guest dir: pass GK_GUEST_CRT=/abs/path"; exit 1; }
	@for f in crt/crt0.S crt/gkvm.c crt/gkvm.h link.ld; do \
		cmp guest-crt/$$f "$(GK_GUEST_CRT)/$$f" || exit 1; \
	done
	@echo "crt-check: tools/gk/guest-crt == $(GK_GUEST_CRT) (4 files)"

need-gk-run:
	@test -n "$(GK_RUN)" && test -x "$(GK_RUN)" || { \
		echo "gk-run not found: build it (cargo build --release -p gas-analyzer-gkvm --bin gk-run) or pass GK_RUN=/abs/path"; exit 1; }

.PHONY: test golden golden-check crt-check need-gk-run
