#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mise exec -- zig build -Doptimize=ReleaseSafe
bundle="zig-out/Huen WM.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp zig-out/bin/huen-wm "$bundle/Contents/MacOS/huen-wm"
cp native/Info.plist "$bundle/Contents/Info.plist"
cp config/example.lua "$bundle/Contents/Resources/config.lua"
codesign --force --sign - --identifier dev.huen-wm --requirements '=designated => identifier "dev.huen-wm"' "$bundle"
codesign --verify --strict "$bundle"
if [ "${1:-}" = "--install" ]; then
	mkdir -p "$HOME/Applications"
	ditto "$bundle" "$HOME/Applications/Huen WM.app"
	# Every build registers its bundle under dev.huen-wm, so point Launch Services at the installed copy.
	lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	"$lsregister" -u "$bundle" 2>/dev/null || true
	"$lsregister" -f "$HOME/Applications/Huen WM.app"
	printf '%s\n' "Installed $HOME/Applications/Huen WM.app. Not launched."
	config="$HOME/.config/huen-wm/config.lua"
	if [ ! -e "$config" ]; then
		mkdir -p "$(dirname "$config")"
		cp config/example.lua "$config"
		printf '%s\n' "Created $config from config/example.lua."
	fi
	# A wrapper, not a symlink, so the binary still runs from inside the bundle.
	cli="$HOME/.local/bin/huen-wm"
	marker="# huen-wm cli wrapper"
	if [ ! -e "$cli" ] || grep -q "$marker" "$cli"; then
		mkdir -p "$(dirname "$cli")"
		printf '#!/bin/sh\n%s\nexec "$HOME/Applications/Huen WM.app/Contents/MacOS/huen-wm" "$@"\n' "$marker" >"$cli"
		chmod +x "$cli"
		case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf '%s\n' "Add $HOME/.local/bin to PATH to run huen-wm from a shell." ;; esac
	else
		printf '%s\n' "Left $cli alone because it is not the huen-wm wrapper."
	fi
	printf '%s\n' "Next: grant Accessibility to Huen WM in System Settings, then open the app."
else
	printf '%s\n' "Built $bundle. Not installed or launched."
fi
