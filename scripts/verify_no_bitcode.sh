#!/usr/bin/env bash
# =============================================================================
# DateNow — verify the iOS app bundle is bitcode-free
#
# Apple's TestFlight ingestion rejects any framework whose binary still
# carries an `__LLVM,__bitcode` section ("Invalid Executable — contains
# bitcode"). Agora ships its iOS xcframeworks with embedded bitcode;
# `ios/Podfile` already strips them in `post_install`. This script checks
# the FINAL artifact (build/ios/iphoneos/Runner.app/Frameworks/*) so you
# know the next Archive will pass before opening Xcode.
#
# Usage:
#   flutter build ios --release --no-codesign       # produce the bundle
#   bash scripts/verify_no_bitcode.sh               # check it
#
# Exit:  0 = all frameworks clean, 1 = at least one carries bitcode.
# =============================================================================
set -u
cd "$(dirname "$0")/.."

bundle=build/ios/iphoneos/Runner.app/Frameworks
if [ ! -d "$bundle" ]; then
  echo "❌ $bundle not found — run 'flutter build ios --release --no-codesign' first."
  exit 1
fi

offenders=0
checked=0
for fw in "$bundle"/*.framework; do
  name=$(basename "$fw" .framework)
  binary="$fw/$name"
  [ -f "$binary" ] || continue
  checked=$((checked + 1))
  if otool -l "$binary" 2>/dev/null | grep -q "__LLVM"; then
    echo "  ❌ $name CONTAINS bitcode"
    offenders=$((offenders + 1))
  fi
done

echo "------------------------------------------------------------"
if [ "$offenders" -eq 0 ]; then
  echo "✅ $checked framework binaries — none carry bitcode."
  echo "→ Archive should pass TestFlight ingestion."
  exit 0
else
  echo "❌ $offenders / $checked framework binaries still carry bitcode."
  echo "→ Re-run: cd ios && pod deintegrate && pod install"
  echo "  (the Podfile post_install hook strips them in place)"
  exit 1
fi
