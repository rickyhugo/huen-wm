#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
application_path="$repository_root/zig-out/fixtures/HuenFixture.app"
contents_path="$application_path/Contents"
mkdir -p "$contents_path/MacOS"

cat >"$contents_path/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HuenFixture</string>
    <key>CFBundleIdentifier</key><string>dev.huen-wm.fixture</string>
    <key>CFBundleName</key><string>HuenFixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Cocoa \
	"$repository_root/scripts/native-fixture.m" \
	-o "$contents_path/MacOS/HuenFixture"
/usr/bin/codesign --force --sign - "$application_path"
printf '%s\n' "$application_path"
