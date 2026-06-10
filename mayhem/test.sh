#!/usr/bin/env bash
#
# draco/mayhem/test.sh — RUN draco's own GoogleTest suite (draco_tests + draco_factory_tests, built
# by mayhem/build.sh with normal flags) and emit a CTRF summary. exit 0 iff no test failed.
# PATCH-grade oracle: these are draco's real known-answer / golden tests (decode/encode round-trips,
# corner-table invariants, quantization math, IO golden compares) — they assert BEHAVIOR, so a no-op
# "exit(0)" patch cannot pass. This script only RUNS the pre-built binaries; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

# Sum GoogleTest "[==========] N tests ... ran." / "[ PASSED ] P" / "[ SKIPPED ] S" across both
# test binaries. failed = total - passed - skipped (robust against repeated FAILED lines).
TOTAL=0 PASSED=0 SKIPPED=0
ran_any=0
for BIN in ./build-tests/draco_tests ./build-tests/draco_factory_tests; do
  if [ ! -x "$BIN" ]; then
    echo "missing $BIN — run mayhem/build.sh first" >&2
    emit_ctrf "googletest" "$PASSED" 1 "$SKIPPED"; exit 2
  fi
  ran_any=1
  echo "=== running $BIN ==="
  out="$("$BIN" 2>&1)"; echo "$out"
  t=$( printf '%s\n' "$out" | sed -n 's/.*\[=*\] \([0-9][0-9]*\) tests* from .*ran\..*/\1/p' | tail -1)
  p=$( printf '%s\n' "$out" | sed -n 's/.*\[ *PASSED *\] \([0-9][0-9]*\) tests*\..*/\1/p'     | tail -1)
  s=$( printf '%s\n' "$out" | sed -n 's/.*\[ *SKIPPED *\] \([0-9][0-9]*\) tests*,*.*/\1/p'    | tail -1)
  : "${t:=0}" "${p:=0}" "${s:=0}"
  TOTAL=$(( TOTAL + t )); PASSED=$(( PASSED + p )); SKIPPED=$(( SKIPPED + s ))
done

[ "$ran_any" = 1 ] || { echo "no test binaries found" >&2; emit_ctrf "googletest" 0 1 0; exit 2; }

FAILED=$(( TOTAL - PASSED - SKIPPED )); [ "$FAILED" -lt 0 ] && FAILED=0
emit_ctrf "googletest" "$PASSED" "$FAILED" "$SKIPPED"
