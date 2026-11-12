#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mise exec -- zig build
python3 - <<'PYTHON'
import json
import pathlib
import os
import socket
import subprocess
import tempfile
import threading

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
        "return {bindings={{mods='+alt++',key='h',command='quit'}}}",
        "return { bindings = {{ mods='alt', key='h', command='quit' }, { mods='alt', key='h', command='quit' }} }",
        "while true do end",
        "while true do pcall(function() while true do end end) end",
        "local input=string.rep('a',50000); string.match(input,'^a*a*a*a*a*a*b'); return {}",
        "return setmetatable({}, {__index=function() error('bad field') end})",
        "return setmetatable({}, {__index=function() while true do end end})",
        "return {bindings={oops={key='h',mods='alt',command='quit'}}}",
        "return {bindings={[128]={key='h',mods='alt',command='quit'}}}",
        "return {bindings={[1]={key='h',mods='alt',command='quit'},[999]={}}}",
        "return {rules={oops={bundle='com.apple.Terminal'}}}",
        "return {workspaces={'one',typo='two'}}",
        "return {workspaces={[1]='one',[999]='two'}}",
        r"return {['gap\0typo']=23}",
        "return {bindings={setmetatable({}, {__index=function() error('bad binding') end})}}",
        "return {rules={setmetatable({}, {__index=function() error('bad rule') end})}}",
        "return { gap = string.rep('x', 100000000) }",
        "return os.execute('true')",
        "return {",
    ):
        config.write_text(content)
        invoke("validate", "--config", str(config), success=False)
    config.write_text("local settings = { gap = 9, layout = 'master', motion_duration = 0 }; return settings")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    invoke("validate", "--config", str(config) + ".missing", success=False)
    config.write_text("print('user output is not the response'); return {}")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    config.write_bytes(b"\xef\xbb\xbf#!/usr/bin/env lua\nreturn {}\n")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    config.write_bytes(b" " * (256 * 1024 + 1))
    invoke("validate", "--config", str(config), success=False)
    config.write_text("return {bindings={{mods='alt',key='b',command='workspace 1'}},workspaces={'one'}}")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    config.write_text("warn('@on'); for index=1,1000 do warn(string.rep('x',512)) end; return {}")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    config.write_text("error(string.rep('x',100000))")
    assert len(invoke("validate", "--config", str(config), success=False).stderr.encode()) < 4200
    maximum_config = """
local keys={'a','s','d','f','h','g','z','x','c','v','b','q','w'}
local modifiers={'alt','ctrl','shift','cmd','alt+ctrl','alt+shift','alt+cmd','ctrl+shift','ctrl+cmd','shift+cmd'}
local bindings, rules = {}, {}
for index=1,128 do
    bindings[index]={key=keys[(index-1)%13+1],mods=modifiers[math.floor((index-1)/13)+1],command='quit'}
end
for index=1,64 do rules[index]={bundle='com.example.app'} end
return {bindings=bindings,rules=rules}
"""
    config.write_text(maximum_config)
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    config.write_text(maximum_config.replace("command='quit'", "command=string.rep(string.char(9),123)..'quit'").replace("'com.example.app'", "string.rep(string.char(1),255)"))
    assert "ConfigResponseTooLarge" in invoke("validate", "--config", str(config), success=False).stderr

socket_path = pathlib.Path(doctor["socket"])
fake_socket_checked = False
if not os.path.lexists(socket_path):
    assert "not running" in invoke("status", success=False).stderr
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(socket_path))
        owned_inode = socket_path.lstat().st_ino
        try:
            listener.listen()
            listener.settimeout(5)
            for reply, success in ((b"garbage", False), (b'{"ok":', False), (b'{"ok":true} trailing', False), (b"null", False), (b'{"error":true}', False), (b'{"ok":true}\n', True), (b"[]\n", True)):
                errors = []
                def respond():
                    try:
                        connection, _ = listener.accept()
                        with connection:
                            connection.recv(512)
                            connection.sendall(reply)
                    except BaseException as error:
                        errors.append(error)
                server = threading.Thread(target=respond)
                server.start()
                try:
                    invoke("status", success=success)
                finally:
                    server.join(timeout=6)
                assert not server.is_alive() and not errors, errors
            fake_socket_checked = True
        finally:
            if socket_path.lstat().st_ino == owned_inode:
                socket_path.unlink()
print(json.dumps({"headless_smoke": "passed", "fake_socket_checked": fake_socket_checked, "accessibility": bool(doctor["accessibility"]), "native_window_smoke": "not run", "wm_started": False}))
PYTHON
