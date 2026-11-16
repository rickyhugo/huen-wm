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

help_text = invoke("--help").stdout
assert all(command in help_text for command in ("send-to-workspace", "move-to-workspace", "focus last", "cycle", "resize-by", "focus-monitor"))
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
        "return { bindings = {{ mods='alt', key='h', command='workspace +0' }} }",
        "return { bindings = {{ mods='alt', key='h', command='workspace -11' }} }",
        "return { bindings = {{ mods='alt', key='h', command='workspace occupied' }} }",
        "return { bindings = {{ mods='alt', key='h', command='workspace 1+' }} }",
        "return { bindings = {{ mods='alt', key='h', command='workspace previous 2' }} }",
        "return { bindings = {{ mods='alt', key='h', command='workspace name:' }} }",
        "return { workspaces = {'one'}, bindings = {{ mods='alt', key='h', command='send-to-workspace name:two' }} }",
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
        "return { workspace_back_and_forth = 'yes' }",
        "return { bindings = {{ mods='alt', key='h', command='move-to-workspace' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus last 1' }} }",
        "return { bindings = {{ mods='alt', key='h', command='cycle' }} }",
        "return { bindings = {{ mods='alt', key='h', command='cycle sideways' }} }",
        "return { bindings = {{ mods='alt', key='h', command='cycle next both' }} }",
        "return { bindings = {{ mods='alt', key='h', command='cycle next tiled 1' }} }",
        "return { bindings = {{ mods='alt', key='h', command='swap next 1' }} }",
        "return { bindings = {{ mods='alt', key='h', command='center now' }} }",
        "return { bindings = {{ mods='alt', key='h', command='move-by 40' }} }",
        "return { bindings = {{ mods='alt', key='h', command='move-by nan 0' }} }",
        "return { bindings = {{ mods='alt', key='h', command='resize-by 10001 0' }} }",
        "return { bindings = {{ mods='alt', key='h', command='resize-by 0 20 20' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus --wrap last' }} }",
        "return { workspaces = {'one'}, bindings = {{ mods='alt', key='h', command='move-to-workspace name:two' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus-monitor' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus-monitor sideways' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus-monitor builtin' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus-monitor name:' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus-monitor left 1' }} }",
        "return { bindings = {{ mods='alt', key='h', command='focus-monitor 2' }} }",
        "return {",
    ):
        config.write_text(content)
        invoke("validate", "--config", str(config), success=False)
    config.write_text("return {bindings={{mods='alt',key='tab',command='focus last'},{mods='alt',key='n',command='cycle next'},{mods='alt+shift',key='n',command='cycle previous floating'},{mods='ctrl',key='n',command='cycle next tiled'},{mods='alt',key='j',command='swap next'},{mods='alt',key='k',command='swap previous'},{mods='alt',key='c',command='center'},{mods='alt',key='left',command='move-by -40 0'},{mods='alt',key='right',command='resize-by 40 -20.5'}}}")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    config.write_text("local settings = { gap = 9, layout = 'master', motion_duration = 0, workspace_back_and_forth = true }; return settings")
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
    selectors = ("previous", "+1", "-10", "occupied+1", "occupied-2", "empty", "next-empty", "name:web dev")
    config.write_text("return {workspaces={'web dev','mail'},bindings={" + ",".join(f"{{mods='alt',key='{key}',command='workspace {selector}'}},{{mods='alt+shift',key='{key}',command='send-to-workspace {selector}'}},{{mods='ctrl',key='{key}',command='move-to-workspace {selector}'}}" for key, selector in zip("asdfghjk", selectors)) + "}}")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    monitor_selectors = ("left", "right", "up", "down", "next", "previous", "built-in", "external", "name:DELL U2725QE")
    config.write_text("return {bindings={" + ",".join(f"{{mods='alt',key='{key}',command='focus-monitor {selector}'}}" for key, selector in zip("asdfghjkl", monitor_selectors)) + "}}")
    assert json.loads(invoke("validate", "--config", str(config)).stdout)["ok"]
    for content, expected in (
        ("return { workspaces = {{ name='1', monitor='built-in' }} }", "MonitorRequiresGlobalWorkspaces"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={} }} }", "EmptyWorkspaceMonitors"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'built-in','external','name:A','name:B','name:C'} }} }", "TooManyWorkspaceMonitors"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external','external'} }} }", "DuplicateMonitor"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'name:DELL','name:DELL'} }} }", "DuplicateMonitor"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor='builtin' }} }", "UnknownMonitor"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor='left' }} }", "RelativeMonitorSelector"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external','next'} }} }", "RelativeMonitorSelector"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor='name:' }} }", "InvalidMonitorName"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external',7} }} }", "ExpectedString"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external',typo='built-in'} }} }", "ExpectedDenseArray"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitors='external' }} }", "UnknownConfigurationField"),
        ("return { workspace_monitors={'external'}, workspaces = {{ monitor='external' }} }", "ExpectedWorkspaceName"),
        ("return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor=true }} }", "ExpectedTable"),
    ):
        config.write_text(content)
        assert expected in invoke("validate", "--config", str(config), success=False).stderr, (content, expected)
    config.write_text("return { workspace_monitors={'external','built-in'}, workspaces = {{ name='1', monitor={'name:DELL U2725QE','external'} }, '2', { name='6', monitor='built-in' }, { name='7' }} }")
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
