#!/bin/bash
# Builds build/Rocky.app from the SwiftPM product and signs it.
# The bundle id (dev.jhzl.rocky) is what the macOS power log attributes energy to.
# Signing uses the "Rocky Local" certificate when it exists (README, "One-time: signing certificate"), so the
# Keychain treats every rebuild as the same app and does not ask again for repo secrets. Otherwise: ad hoc.
# Usage: scripts/make-app.sh [release|debug]
set -euo pipefail
config="${1:-release}"
identity="${ROCKY_SIGN_IDENTITY:-Rocky Local}"
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c "$config" --product Rocky --package-path "$root"
bin_dir="$(swift build -c "$config" --product Rocky --package-path "$root" --show-bin-path)"
app="$root/build/Rocky.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Rocky" "$app/Contents/MacOS/Rocky"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
if [[ "$(security find-identity -p codesigning 2>/dev/null)" == *"\"$identity\""* ]]; then
  codesign --force --sign "$identity" "$app"
else
  echo "warning: no \"$identity\" signing identity, signing ad hoc; the Keychain will ask again for repo secrets after each build" >&2
  codesign --force --sign - "$app"
fi
echo "$app"
