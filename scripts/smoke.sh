#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mise exec -- zig build
python3 - <<'PYTHON'
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path.cwd()
binary = root / "zig-out/bin/huen-wm"

def invoke(*arguments, success=True):
    completed = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10)
    if (completed.returncode == 0) != success:
        raise RuntimeError(f"{arguments}: {completed.returncode}\n{completed.stdout}{completed.stderr}")
    return completed

assert "send-to-workspace" in invoke("--help").stdout
doctor = json.loads(invoke("doctor").stdout)
assert doctor["zig"] == "0.17.0" and not doctor["permission_prompted"]
assert not doctor["screen_capture_required_for_tiling"]
assert json.loads(invoke("validate", "--config", str(root / "config/example.lua")).stdout)["ok"]
invoke("--config", success=False)
invoke("--unknown-option", success=False)
with tempfile.TemporaryDirectory(prefix="smoke-", dir=root / ".zig-cache") as directory:
    config = pathlib.Path(directory) / "config.lua"
    for content in (
        "return { gap = -1 }",
        "return { gaps = 12 }",
        "return { motion_duration = 'fast' }",
        "return { workspaces = {} }",
        "return { bindings = {{ mods='alt', key='h', command='workspace 99' }} }",
        "return { bindings = {{ mods='alt', key='h', command='quit' }, { mods='alt', key='h', command='quit' }} }",
        "while true do end",
        "return { gap = string.rep('x', 100000000) }",
        "return os.execute('true')",
        "return {",
    ):
        config.write_text(content)
        invoke("validate", "--config", str(config), success=False)
    config.write_text("local settings = { gap = 9, layout = 'master', motion_duration = 0 }; return settings")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    invoke("validate", "--config", str(config) + ".missing", success=False)
if not pathlib.Path(doctor["socket"]).exists():
    assert "not running" in invoke("status", success=False).stderr
print(json.dumps({"headless_smoke": "passed", "accessibility": bool(doctor["accessibility"]), "native_window_smoke": "not run", "wm_started": False}))
PYTHON
