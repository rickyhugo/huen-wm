#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mise exec -- zig build -Doptimize=ReleaseSafe
bundle="zig-out/Huen WM.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp zig-out/bin/huen-wm "$bundle/Contents/MacOS/huen-wm"
cp native/Info.plist "$bundle/Contents/Info.plist"
cp config/example.lua "$bundle/Contents/Resources/config.lua"
codesign --force --sign - --identifier dev.huen-wm "$bundle"
codesign --verify --strict "$bundle"
if [ "${1:-}" = "--install" ]; then
	mkdir -p "$HOME/Applications"
	ditto "$bundle" "$HOME/Applications/Huen WM.app"
	printf '%s\n' "Installed $HOME/Applications/Huen WM.app. Not launched."
else
	printf '%s\n' "Built $bundle. Not installed or launched."
fi
