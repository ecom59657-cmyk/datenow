#!/usr/bin/env bash
# =============================================================================
# DateNow — pre-real-device test runner
#
# One command to run every check that does NOT need two phones:
#   1. static smoke check   (scripts/smoke_check.sh)
#   2. flutter analyze
#   3. flutter test         (full suite, incl. the simulated flow tests)
#
# It does NOT build, deploy or touch Supabase. After it passes, finish the
# manual steps it lists, then run the 2-phone scenario.
#
# Usage:  bash scripts/pre_real_device_test.sh
# Exit:   0 = all automated checks passed, 1 = at least one failed.
# =============================================================================
set -u
cd "$(dirname "$0")/.."

fail=0
step() { echo ""; echo "=== $1 ==="; }

# --- 1. Static smoke check ---------------------------------------------------
step "1/3 · Static smoke check"
if bash scripts/smoke_check.sh; then
  echo "→ smoke check OK"
else
  echo "→ smoke check FAILED"
  fail=1
fi

# --- 2. flutter analyze ------------------------------------------------------
step "2/3 · flutter analyze"
analyze_out="$(flutter analyze 2>&1)"
echo "$analyze_out" | tail -3
if echo "$analyze_out" | grep -qE "^\s*error •"; then
  echo "→ analyze FAILED (errors present)"
  fail=1
else
  echo "→ analyze OK (no errors)"
fi

# --- 3. flutter test ---------------------------------------------------------
step "3/3 · flutter test"
if flutter test 2>&1 | tail -4; then
  echo "→ tests OK"
else
  echo "→ tests FAILED"
  fail=1
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo "AUTOMATED CHECKS: ✅ ALL PASSED"
else
  echo "AUTOMATED CHECKS: ❌ SOMETHING FAILED — see above"
fi
echo "------------------------------------------------------------"
echo "Still MANUAL before the 2-phone run:"
echo "  · flutter build ios --debug --no-codesign"
echo "  · flutter build apk --debug            (needs Android SDK)"
echo "  · run supabase/tests/flow_checks.sql in the Supabase editor"
echo "  · verify generate-agora-token deployed + Agora secrets set"
echo "  · 2-phone scenario — docs/SMOKE_TEST_FINAL.md §3"
echo "============================================================"

exit "$fail"
