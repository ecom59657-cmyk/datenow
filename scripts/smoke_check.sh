#!/usr/bin/env bash
# =============================================================================
# DateNow — smoke check (non-intrusive, read-only)
#
# Runs the automatable half of docs/SMOKE_TEST_FINAL.md: static checks that
# need no devices and no network. It NEVER writes to the repo and NEVER
# touches Supabase. The build / device / Supabase steps stay manual — see
# the markdown checklist.
#
# Usage:  bash scripts/smoke_check.sh
# Exit:   0 = all static checks passed, 1 = at least one failed.
# =============================================================================
set -u
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()   { echo "  ✅ $1"; pass=$((pass + 1)); }
ko()   { echo "  ❌ $1"; fail=$((fail + 1)); }
info() { echo "  ·  $1"; }

echo "DateNow — smoke check"
echo "====================="

# --- 1. flutter analyze ------------------------------------------------------
echo "[1] flutter analyze"
analyze_out="$(flutter analyze 2>&1)"
if echo "$analyze_out" | grep -qE "^\s*error •"; then
  ko "analyze reports errors"
  echo "$analyze_out" | grep -E "error •" | sed 's/^/      /'
else
  ok "no analyzer errors (infos/warnings tolerated)"
fi

# --- 2. Debug routes gated on kDebugMode ------------------------------------
echo "[2] debug routes absent from release"
router="lib/app/router/app_router.dart"
if grep -q "if (kDebugMode)" "$router" \
   && grep -B1 "AppRoute.debugDateNow.path" "$router" | grep -q "GoRoute"; then
  ok "debug routes wrapped in 'if (kDebugMode)'"
else
  ko "debug routes not gated in $router"
fi

# --- 3. App identifiers ------------------------------------------------------
echo "[3] app identifiers"
if grep -rq "com\.example" --include="*.kts" --include="*.xml" \
     --include="*.pbxproj" --include="*.xcconfig" --include="*.plist" .; then
  ko "placeholder 'com.example' still present"
else
  ok "no 'com.example' placeholder"
fi
if grep -q 'applicationId = "com.datenow.app"' android/app/build.gradle.kts; then
  ok "Android applicationId = com.datenow.app"
else
  ko "Android applicationId not com.datenow.app"
fi

# --- 4. No full Agora token / certificate client-side -----------------------
echo "[4] no Agora secret client-side"
if grep -rq "AGORA_APP_CERTIFICATE" lib/ 2>/dev/null; then
  ko "AGORA_APP_CERTIFICATE referenced in lib/ (must stay server-side)"
else
  ok "AGORA_APP_CERTIFICATE absent from lib/"
fi

# --- 5. Supabase migrations + Edge Function present -------------------------
echo "[5] Supabase assets present locally"
mig_count="$(ls supabase/migrations/*.sql 2>/dev/null | wc -l | tr -d ' ')"
if [ "$mig_count" -gt 0 ]; then
  ok "$mig_count migration file(s) present"
else
  ko "no migration files found"
fi
if [ -f supabase/functions/generate-agora-token/index.ts ]; then
  ok "generate-agora-token Edge Function present"
else
  ko "generate-agora-token Edge Function missing"
fi

# --- Summary -----------------------------------------------------------------
echo "---------------------"
echo "Static checks: $pass passed, $fail failed."
echo ""
echo "Still MANUAL (see docs/SMOKE_TEST_FINAL.md):"
info "iOS / Android debug builds"
info "Supabase migrations applied on remote (supabase db push)"
info "Edge Function deployed + AGORA_APP_ID/CERTIFICATE secrets set"
info "real 2-phone test scenario"

[ "$fail" -eq 0 ] && exit 0 || exit 1
