# tools/gk — the gkvm guest toolchain.
#
#   make test     unit tests; the gk-run / compiler legs skip unless their inputs exist
#
# GK_RUN        gk-run sidecar binary       (default: sibling gas-analyzer release build)
# GK_GUEST_CRT  gk-guest-crt + link.ld dir  (default: sibling gas-analyzer crates/gkvm/guest)

SDK_ROOT := $(abspath $(CURDIR)/../..)
GAS_ANALYZER ?= $(abspath $(SDK_ROOT)/../gas-analyzer)
GK_RUN ?= $(wildcard $(GAS_ANALYZER)/target/release/gk-run)
GK_GUEST_CRT ?= $(wildcard $(GAS_ANALYZER)/crates/gkvm/guest)
PYTHON ?= python3

test:
	GK_RUN="$(GK_RUN)" GK_GUEST_CRT="$(GK_GUEST_CRT)" $(PYTHON) -B test_gk.py -v

.PHONY: test
