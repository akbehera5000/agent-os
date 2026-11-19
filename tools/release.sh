#!/bin/zsh
# Builds a release and zips "Agent OS.app" into dist/ for a GitHub release.
set -euo pipefail
here=${0:A:h:h}
cd "$here"
./build.sh
mkdir -p dist
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "/Applications/Agent OS.app/Contents/Info.plist")
out="dist/Agent-OS-$version-macOS-arm64.zip"
rm -f "$out"
ditto -c -k --sequesterRsrc --keepParent "/Applications/Agent OS.app" "$out"
shasum -a 256 "$out"
echo "wrote $out"
