# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for HapCUT2 (extractHAIRS fuzz target). Builds ON TOP of the org C/C++
# base (debian + clang/llvm + libFuzzer/afl++ + identities + build-contract ENV), adding only the
# per-commit build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t hapcut2-commit:test .
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (not baked as ENV — an empty value breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Sanitizer override (no default so the base ENV flows through; --build-arg overrides).
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional; build.sh falls back to nproc).
ARG MAYHEM_JOBS=

# Extra apt packages needed by the build, installed as root (re-pinned to SOURCE_DATE_EPOCH for
# reproducibility): htslib dev headers/lib (extractHAIRS links -lhts) + pysam (the upstream test
# suite drives extractHAIRS through it).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libhts-dev python3-pysam \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the upstream functional suite at build time — a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
