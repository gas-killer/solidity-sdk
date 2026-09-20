# tools/gk — the gkvm guest toolchain.
#
#   make test          unit tests; the gk-run / compiler legs skip unless their inputs exist
#   make golden        regenerate test/fixtures/gkvm/*_vectors.json from direct gk-run
#   make golden-check  the CI fixture diff: fresh direct-gk-run vectors must equal the
#                      committed ones byte for byte, then the forge ffi suites replay them
#                      through GkVmFfiShim (shim output ≡ direct gk-run)
#   make crt-check     bundled guest-crt/ is byte-identical to gas-analyzer's gk-guest-crt
#   make port-check    bundled guest-crt/micropython/ (the MicroPython gkvm port) likewise, and
#                      gk_python.py pins the same upstream commits as gas-analyzer's Makefile
#   make quickstart-proof  the README quickstart replayed in a scratch dir outside the repo
#   make native-example        rebuild src/examples/onchain-llm-native's guest + binding
#   make native-example-check  … the committed binding must not move, then its forge suites
#                              with the real guest behind GkVmFfiShim
#   make native-stories-check  the stories260K Python demo: artifacts from the donor's hex
#                              fixtures, guest + binding rebuilt (binding must not move), then
#                              the real guest must tell the donor's story bit for bit
#   make zero-glue             regenerate test/fixtures/gkvm/native_tasks.json (the forge leg)
#   make zero-glue-check       answer.py → gk build → forge test → gas-analyzer's local executor:
#                              same StateUpdate bytes on both legs, no hand-written marshalling
#
# GK_RUN        gk-run sidecar binary       (default: sibling gas-analyzer release build)
# GK_GUEST_CRT  gk-guest-crt + link.ld dir  (default: sibling gas-analyzer crates/gkvm/guest)
# GK_MPY_SRC    MicroPython at the pinned commit, for the Python-guest build tests (default:
#               sibling gas-analyzer target/gkvm-micropython/src — its `make fetch`; the
#               tests skip without it rather than clone)

SDK_ROOT := $(abspath $(CURDIR)/../..)
GAS_ANALYZER ?= $(abspath $(SDK_ROOT)/../gas-analyzer)
GK_RUN ?= $(wildcard $(GAS_ANALYZER)/target/release/gk-run)
GK_GUEST_CRT ?= $(wildcard $(GAS_ANALYZER)/crates/gkvm/guest)
GK_MPY_SRC ?= $(wildcard $(GAS_ANALYZER)/target/gkvm-micropython/src)
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

# TESTS= narrows the run (unittest names, e.g. TESTS="PythonUnits PythonBuild");
# GK_TEST_FETCH=1 lets PythonFetch clone MicroPython from github (off by default: network)
test:
	GK_RUN="$(GK_RUN)" GK_GUEST_CRT="$(GK_GUEST_CRT)" GK_MPY_SRC="$(GK_MPY_SRC)" \
		GK_TEST_FETCH="$(GK_TEST_FETCH)" $(PYTHON) -B test_gk.py -v $(TESTS)

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

# Same lockstep for the MicroPython gkvm port (linked into every Python guest) and for the
# upstream pin: a port or interpreter that differs from gas-analyzer's is a different
# programHash for the same script.
PORT_FILES := port.mk manifest.py mpconfigport.h mphalport.h gkport.h qstrdefsport.h main.c modgkvm.c gk_libc.c
port-check:
	@test -n "$(GK_GUEST_CRT)" || { echo "no gas-analyzer guest dir: pass GK_GUEST_CRT=/abs/path"; exit 1; }
	@for f in $(PORT_FILES); do \
		cmp guest-crt/micropython/$$f "$(GK_GUEST_CRT)/micropython/$$f" || exit 1; \
	done
	@for pin in MPY_TAG MPY_COMMIT MPY_LIB_COMMIT; do \
		want=$$(sed -n "s/^$$pin := //p" "$(GK_GUEST_CRT)/micropython/Makefile"); \
		grep -q "^$$pin = '$$want'$$" gk_python.py || { echo "port-check: $$pin != gas-analyzer's ($$want)"; exit 1; }; \
	done
	@echo "port-check: tools/gk/guest-crt/micropython == $(GK_GUEST_CRT)/micropython (9 files + 3 pins)"

# The clean-directory proof: fresh forge project outside every checkout, only the commands
# written in README.md + the scaffolded guest/README.md. Installs THIS checkout's HEAD commit
# (SDK_SRC= takes the published `forge install` route instead); network + a recursive
# submodule fetch, so not part of `test`. KEEP=1 keeps the scratch project.
quickstart-proof:
	GAS_ANALYZER="$(GAS_ANALYZER)" bash quickstart-proof.sh

# src/examples/onchain-llm-native: guest/answer.py → guest.elf + gen/GkAnswer.sol. The binding
# is committed, the 1 MB ELF is not — `native-example` rebuilds it (docker + the pinned
# MicroPython) and regenerates the binding IN PLACE; `native-example-check` then requires that
# the committed binding did not move (the build reproduces its PROGRAM_HASH) and runs the
# consumer's suites with the real guest behind GkVmFfiShim.
NATIVE_DIR := src/examples/onchain-llm-native
NATIVE_OUT := cache/gkvm/build/native-answer

native-example:
	cd $(SDK_ROOT) && GK_GUEST_CRT= GK_MPY_SRC="$(GK_MPY_SRC)" $(PYTHON) -B tools/gk build \
		$(NATIVE_DIR)/guest/answer.py --out $(NATIVE_OUT) --sol-out $(NATIVE_DIR)/gen

native-example-check: need-gk-run native-example
	cd $(SDK_ROOT) && git diff --exit-code -- $(NATIVE_DIR)/gen
	@echo "native-example-check: rebuilt answer.py == committed gen/GkAnswer.sol"
	cd $(SDK_ROOT) && GK_RUN="$(GK_RUN)" FOUNDRY_PROFILE=gkvm-ffi \
		$(FORGE) test --match-contract 'GasKillerChatNative'

# src/examples/onchain-llm-native's second guest: guest/stories260k.py, the engine-v1 donor
# (../onchain-llm, stories260K) as a Python guest over artifact-mounted weights. The blobs are
# the donor's committed hex fixtures, byte for byte; `native-stories-artifacts` writes them as
# the two binary files gk-run mounts and prints their manifest-v3 root.
STORIES_OUT := cache/gkvm/build/native-stories
STORIES_ART := cache/gkvm/artifacts/stories260k
STORIES_HEX := test/fixtures/onchain-llm
UNHEX := import sys; open(sys.argv[2], "wb").write(bytes.fromhex(open(sys.argv[1]).read().strip()))

native-stories-artifacts: need-gk-run
	cd $(SDK_ROOT) && mkdir -p $(STORIES_ART) && \
		$(PYTHON) -c '$(UNHEX)' $(STORIES_HEX)/weights.hex $(STORIES_ART)/weights.bin && \
		$(PYTHON) -c '$(UNHEX)' $(STORIES_HEX)/tokenizer.hex $(STORIES_ART)/tokenizer.bin
	cd $(SDK_ROOT) && "$(GK_RUN)" --print-artifact-root \
		--artifact $(STORIES_ART)/weights.bin,$(STORIES_ART)/tokenizer.bin

native-stories:
	cd $(SDK_ROOT) && GK_GUEST_CRT= GK_MPY_SRC="$(GK_MPY_SRC)" $(PYTHON) -B tools/gk build \
		$(NATIVE_DIR)/guest/stories260k.py --out $(STORIES_OUT) --sol-out $(NATIVE_DIR)/gen

# The demo's gate: the committed binding reproduces, then the consumer's suites — the real
# guest over the mounted blobs must tell the donor's 32-token story bit for bit (≈ 9.5G guest
# cycles). STORIES_LONG=1 adds the 200-token vector (≈ 100G cycles: minutes, tier-dependent).
native-stories-check: need-gk-run native-stories-artifacts native-stories
	cd $(SDK_ROOT) && git diff --exit-code -- $(NATIVE_DIR)/gen/GkStories260k.sol
	@echo "native-stories-check: rebuilt stories260k.py == committed gen/GkStories260k.sol"
	cd $(SDK_ROOT) && GK_RUN="$(GK_RUN)" GK_STORIES_LONG="$(if $(STORIES_LONG),true,false)" \
		FOUNDRY_PROFILE=gkvm-ffi $(FORGE) test --match-contract 'GasKillerLLMNative' -vv

# The zero-glue check: answer.py → gk build → forge test → local executor, nothing marshalled
# by hand in between. `zero-glue-tasks` records every `ask` task of the real guest behind
# GkVmFfiShim as the encoded StateUpdate payload (test/examples/OnchainChatNativeZeroGlue.t.sol);
# `zero-glue-check` rebuilds the guest (the committed binding must not move), lints the three
# hand-written files for marshalling, requires the recorded tasks to equal the committed
# fixture AND gas-analyzer's copy, then runs gas-analyzer's local executor over the same
# bytecode + calldata against the real precompile with the rebuilt image installed.
# ZERO_GLUE_CARGO_FLAGS="--features gkvm-portable-exec" takes the consensus interpreter.
ZERO_GLUE_SCRATCH := cache/gkvm/zero-glue
ZERO_GLUE_CONSUMER_COPY := $(GAS_ANALYZER)/crates/evmsketch/tests/fixtures/gkvm/native_tasks.json

zero-glue-tasks: need-gk-run
	cd $(SDK_ROOT) && GK_RUN="$(GK_RUN)" FOUNDRY_PROFILE=gkvm-ffi \
		$(FORGE) test --match-contract GasKillerChatNativeZeroGlueTest

zero-glue: native-example zero-glue-tasks
	cp $(SDK_ROOT)/$(ZERO_GLUE_SCRATCH)/native_tasks.json $(SDK_ROOT)/$(GOLDEN_DIR)/native_tasks.json

zero-glue-check: native-example-check zero-glue-tasks
	$(PYTHON) -B test_gk.py -v ZeroGlue
	cd $(SDK_ROOT) && diff -u $(GOLDEN_DIR)/native_tasks.json $(ZERO_GLUE_SCRATCH)/native_tasks.json
	@echo "zero-glue-check: forge-leg tasks == committed fixture"
	diff -u $(SDK_ROOT)/$(GOLDEN_DIR)/native_tasks.json "$(ZERO_GLUE_CONSUMER_COPY)"
	@echo "zero-glue-check: gas-analyzer's copy == committed fixture"
	cd $(GAS_ANALYZER) && GK_NATIVE_ANSWER_ELF="$(SDK_ROOT)/$(NATIVE_OUT)/guest.elf" \
		cargo test -p gas-analyzer-evmsketch --lib $(ZERO_GLUE_CARGO_FLAGS) gkvm_native -- --include-ignored
	@echo "zero-glue-check: PASS — answer.py → gk build → forge test → local executor, same bytes"

need-gk-run:
	@test -n "$(GK_RUN)" && test -x "$(GK_RUN)" || { \
		echo "gk-run not found: build it (cargo build --release -p gas-analyzer-gkvm --bin gk-run) or pass GK_RUN=/abs/path"; exit 1; }

.PHONY: test golden golden-check crt-check port-check quickstart-proof native-example native-example-check \
	native-stories-artifacts native-stories native-stories-check zero-glue-tasks zero-glue zero-glue-check \
	need-gk-run
