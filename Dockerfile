# syntax=docker/dockerfile:1
# Deploy image for gas-killer/solidity-sdk demo targets (e.g. ArraySummation).
# Carries forge + jq + the SDK contracts so a Kubernetes job can deploy a
# correctly-wired target (real BLSSignatureChecker) against a freshly-deployed AVS.
# See script/DeployArraySummation.s.sol and the service chart's deploy-target-job.yaml.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl git ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*

# Install Foundry (forge, cast, anvil).
ENV PATH="/root/.foundry/bin:${PATH}"
RUN curl -L https://foundry.paradigm.xyz | bash \
    && foundryup

WORKDIR /sdk

# Submodules under lib/ must be present in the build context
# (CI: actions/checkout with submodules: recursive).
COPY . .

# Pre-compile so the deploy job only needs to broadcast.
RUN forge build

CMD ["forge", "--version"]
