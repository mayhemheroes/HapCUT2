#!/usr/bin/env bash
#
# mayhem/test.sh — RUN HapCUT2's upstream functional suite (utilities/test_LinkFragment.py),
# already built by mayhem/build.sh (build/extractHAIRS with the project's normal flags). Never
# compiles. Asserts BEHAVIOR: each test drives extractHAIRS + LinkFragments and diffs the exact
# fragment output, so neutering extractHAIRS to exit(0) makes the suite FAIL (not reward-hackable).
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:=/mayhem}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# build.sh must have produced the normal-flags binary the suite invokes as ../build/extractHAIRS.
if [ ! -x "$SRC/build/extractHAIRS" ]; then
  echo "test.sh: build/extractHAIRS missing — mayhem/build.sh did not produce the test binary" >&2
  emit_ctrf "python-unittest" 0 1 0
  exit 1
fi

# Run the upstream unittest suite via the runner (RESULT <passed> <failed> <skipped>).
line="$(SRC="$SRC" python3 "$SRC/mayhem/run_tests.py" | tee /dev/stderr | grep -E '^RESULT ' | tail -1 || true)"
if [ -z "$line" ]; then
  echo "test.sh: run_tests.py emitted no RESULT line" >&2
  emit_ctrf "python-unittest" 0 1 0
  exit 1
fi
read -r _ passed failed skipped <<<"$line"
emit_ctrf "python-unittest" "$passed" "$failed" "$skipped"
