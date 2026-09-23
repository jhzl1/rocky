#!/bin/bash
# Builds build/Rocky.app from the SwiftPM product and signs it ad hoc.
# The bundle id (dev.jhzl.rocky) is what the macOS power log attributes energy to.
# Usage: scripts/make-app.sh [release|debug]
set -euo pipefail
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c "$config" --product Rocky --package-path "$root"
bin_dir="$(swift build -c "$config" --product Rocky --package-path "$root" --show-bin-path)"
app="$root/build/Rocky.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Rocky" "$app/Contents/MacOS/Rocky"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
