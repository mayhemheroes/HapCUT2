#!/usr/bin/env bash
#
# mayhem/build.sh — build HapCUT2's extractHAIRS fuzz target + the upstream test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base
# (ghcr.io/mayhemheroes/base) exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...).
# libhts-dev is installed by the Dockerfile (as root) before this runs.
#
#   1) FUZZ  — an in-process libFuzzer harness (mayhem/fuzz_vcf.c) over the extractHAIRS VCF parser
#              (count_variants/read_variantfile/parse_variant in hairs-src), instrumented with
#              -fsanitize=fuzzer + $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF<4). Emitted to
#              /mayhem/extracthairs-fuzz (the Mayhemfile cmd, libfuzzer: true). See fuzz_vcf.c for
#              WHY a harness replaces the old raw `--vcf @@` file CLI: halting ASan makes that CLI
#              abort on trivial input (upstream OOB reads we can't patch), so it is unfuzzable as a
#              file-input target; the harness drives the identical VCF byte path with sancov feedback.
#   2) TEST  — extractHAIRS with the project's NORMAL flags, left at build/extractHAIRS where the
#              upstream suite (utilities/test_LinkFragment.py, via mayhem/run_tests.py) expects
#              ../build/extractHAIRS. mayhem/test.sh only RUNS it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# System htslib (libhts-dev, apt-pinned): headers at /usr/include/htslib, lib on the default link path.
# Point the Makefile's HTSLIB at /usr/include so its -I/-L are harmless no-ops (never the bundled tree).
HTS=/usr/include

# ---------------------------------------------------------------------------------------------------
# 1) FUZZ build — in-process libFuzzer harness, ASan+UBSan (halting), DWARF-3.
#    Compile the two parser TUs (readvariant.c, hashtable.c) + the harness with -fsanitize=fuzzer,
#    then link with -fsanitize=fuzzer. -DNDEBUG turns the parser's assert()s into the standard
#    release no-op; -Wl,--wrap=exit routes the parser's exit()-on-bad-genotype back into the harness
#    (see fuzz_vcf.c). detect_leaks=0 (baked via the linked __asan_default_options): the upstream
#    parser's allocation discipline is loose on error paths — we hunt spatial memory-safety + UB
#    here, not leaks.
# ---------------------------------------------------------------------------------------------------
FUZZFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DNDEBUG -D_GNU_SOURCE -Ihairs-src -I$HTS"
"$CC" $DEBUG_FLAGS -c "$SRC/mayhem/asan_default_options.c" -o /tmp/asan_default_options.o
"$CC" $FUZZFLAGS -fsanitize=fuzzer-no-link -c hairs-src/readvariant.c -o /tmp/readvariant.o
"$CC" $FUZZFLAGS -fsanitize=fuzzer-no-link -c hairs-src/hashtable.c   -o /tmp/hashtable.o
"$CC" $FUZZFLAGS -fsanitize=fuzzer-no-link -c mayhem/fuzz_vcf.c        -o /tmp/fuzz_vcf.o
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer -Wl,--wrap=exit \
  /tmp/fuzz_vcf.o /tmp/readvariant.o /tmp/hashtable.o /tmp/asan_default_options.o \
  -lhts -o /mayhem/extracthairs-fuzz

# ---------------------------------------------------------------------------------------------------
# 2) TEST build — project's NORMAL flags (the Makefile default: -Wall -g -O3 -D_GNU_SOURCE), NOT
#    sanitized, so the functional oracle can't false-fail on benign UB. Left at build/extractHAIRS
#    (utilities/ tests invoke ../build/extractHAIRS). $COVERAGE_FLAGS is appended (empty by default).
# ---------------------------------------------------------------------------------------------------
make clean >/dev/null 2>&1 || true
make -j"$MAYHEM_JOBS" build/extractHAIRS \
  CC="$CC" \
  HTSLIB="$HTS" \
  CFLAGS="-Wall -g -O3 -D_GNU_SOURCE ${COVERAGE_FLAGS}" \
  LDFLAGS="${COVERAGE_FLAGS}"

echo "build.sh: OK — /mayhem/extracthairs-fuzz (libFuzzer+sanitizers) and build/extractHAIRS (normal, for tests)"
