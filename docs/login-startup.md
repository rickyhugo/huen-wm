# Start Huen WM at login

Login startup is opt-in. Building or installing the app does not enable it.
The helper does not start the WM when you enable login startup.

## Prepare the app

1. Install the signed development app.

   ```sh
   sh scripts/bundle.sh --install
   ```

2. Create your configuration if it does not exist.

   ```sh
   mkdir -p "$HOME/.config/huen-wm"
   cp -n config/example.lua "$HOME/.config/huen-wm/config.lua"
   ```

3. Grant Accessibility to `~/Applications/Huen WM.app` as described in
   [Run deliberately](../README.md#run-deliberately).
   Confirm that the app works before you enable login startup.
   Do not run another tiling manager against the same windows.

The helper requires Python 3 on `PATH` for safe plist serialization.
On macOS, `/usr/bin/python3` can require Apple's Command Line Tools.
Install those tools with `xcode-select --install`, or use an existing Python 3 installation.
Python is needed only to run the helper, not at login.
Run the helper as your own user, without `sudo`.

## Enable the next login

From the repository, run:

```sh
sh scripts/login.sh enable
sh scripts/login.sh status
```

The helper writes `~/Library/LaunchAgents/dev.huen-wm.login.plist`.
It clears the launchd disabled flag with `launchctl enable`.
It does not call `bootstrap`, `load`, or `kickstart`.
Log out and log in to start the WM through this LaunchAgent.
The plist contains absolute paths for this command:

```sh
/usr/bin/open -g -a "$HOME/Applications/Huen WM.app" --args start --config "$HOME/.config/huen-wm/config.lua"
```

Keep the installed app and configuration at those paths.
The helper does not modify your shell configuration or Lua file.
Re-running `enable` is safe for the helper's own plist.
The helper refuses to overwrite or remove a symlink, malformed plist, or a plist with unexpected contents.
If you already use a different login item for Huen WM, remove that item before enabling this one.

## Disable login startup

```sh
sh scripts/login.sh disable
```

Disable removes the helper's plist and unloads its launcher if registered.
It does not stop an already running WM.
To stop the WM, use the [existing stop command](../README.md#control).
Re-running `disable` is safe.

## Check login startup

`sh scripts/login.sh status` checks only whether the expected plist exists.
It does not check the launchd disabled flag, permissions, or WM health.
Use the existing `huen-wm status` command to check the WM after login.
If macOS blocks background activity, review **System Settings > General > Login Items & Extensions**.
If startup fails, check Accessibility permission and try the launch command above from Terminal.

The LaunchAgent uses the stable label `dev.huen-wm.login` and `RunAtLoad`.
It has no `KeepAlive` because `open` exits after launching the app.
It does not supervise or restart a crashed WM.
A per-user LaunchAgent fits the ad-hoc development app without an embedded helper.
SMAppService would require app integration and is not part of this opt-in script.
See Apple's local `man launchd`, `man launchd.plist`, and `man launchctl` for the login directory,
`RunAtLoad`, and the difference between enabling and bootstrapping a job.
