#!/bin/bash
# Double-click me in Finder. Builds Ferry.app and opens it.
# Output is also saved to logs/build.log.

cd "$(dirname "$0")" || exit 1
mkdir -p logs
exec > >(tee logs/build.log) 2>&1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "== Ferry build — $(date)"
sw_vers 2>/dev/null | tr '\n' ' '; echo
swift --version 2>&1 | head -1

if ! command -v brew >/dev/null 2>&1; then
  echo "NEED_HOMEBREW"
  echo "Homebrew isn't installed. Install it from https://brew.sh, then double-click this again."
  exit 1
fi

for pkg in libmtp pkgconf; do
  if ! brew list --versions "$pkg" >/dev/null 2>&1; then
    echo "== Installing $pkg (one-time)…"
    brew install "$pkg" || { echo "BREW_FAILED $pkg"; exit 1; }
  fi
done
echo "libmtp $(pkg-config --modversion libmtp)"

echo "== Compiling…"
if ! swift build -c release 2>&1; then
  echo "BUILD_FAILED"
  exit 1
fi

echo "== Packaging Ferry.app…"
APP="build/Ferry.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Ferry" "$APP/Contents/MacOS/Ferry"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null
codesign --force --sign - "$APP" >/dev/null 2>&1

pkill -x Ferry 2>/dev/null; sleep 0.5
echo "BUILD_OK"
open "$APP"
