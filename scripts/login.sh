#!/bin/sh
set -eu
exec python3 - "$@" <<'PY'
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2 or sys.argv[1] not in ("enable", "disable", "status"):
    sys.exit("Usage: sh scripts/login.sh enable|disable|status")

command = sys.argv[1]
home = Path(os.environ["HOME"])
if not home.is_absolute():
    sys.exit("HOME must be an absolute path.")

label = "dev.huen-wm.login"
app = home / "Applications/Huen WM.app"
config = home / ".config/huen-wm/config.lua"
destination = home / "Library/LaunchAgents" / (label + ".plist")
service = "gui/{}/{}".format(os.getuid(), label)
definition = {
    "Label": label,
    "ProgramArguments": [
        "/usr/bin/open", "-g", "-a", str(app),
        "--args", "start", "--config", str(config),
    ],
    "RunAtLoad": True,
}

try:
    installed = destination.exists()
    if destination.is_symlink():
        sys.exit("Refusing a symlink at " + str(destination))
    if installed:
        with destination.open("rb") as source:
            existing = plistlib.load(source)
        if existing != definition:
            sys.exit("Refusing an unexpected plist at " + str(destination))

    if command == "status":
        if installed:
            print("Login plist installed at " + str(destination))
            print("This does not report whether the WM is running.")
        else:
            print("Login startup is not installed.")
    elif command == "enable":
        if not (app / "Contents/MacOS/huen-wm").is_file():
            sys.exit("Install the app first: " + str(app))
        if not config.is_file():
            sys.exit("Create the configuration first: " + str(config))
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
                temporary = Path(output.name)
                plistlib.dump(definition, output)
                os.fchmod(output.fileno(), 0o644)
            temporary.replace(destination)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
        subprocess.run(["launchctl", "enable", service], check=True)
        print("Enabled for the next GUI login. The WM was not started.")
    elif installed:
        registered = subprocess.run(
            ["launchctl", "print", service],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
        if registered:
            subprocess.run(["launchctl", "bootout", service], check=True)
        destination.unlink()
        print("Disabled login startup. An already running WM is not stopped.")
    else:
        print("Login startup is already disabled.")
except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
    sys.exit("Login startup failed: " + str(error))
PY
