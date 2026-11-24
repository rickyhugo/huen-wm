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
   [Get it running](../README.md#get-it-running).
   Confirm that the app works before you enable login startup.
   Do not run another tiling manager against the same windows.

The helper is a Zig program that `mise run login` builds and runs. It needs only the repository's Zig.
Run the helper as your own user, without `sudo`.

## Enable the next login

From the repository, run:

```sh
mise run login enable
mise run login status
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
It compares the plist by content through `plutil`, so a plist that the earlier Python helper wrote still matches.
If you already use a different login item for Huen WM, remove that item before enabling this one.

## Disable login startup

```sh
mise run login disable
```

Disable removes the helper's plist and unloads its launcher if registered.
It does not stop an already running WM.
To stop the WM, use the [existing stop command](../README.md#drive-it).
Re-running `disable` is safe.

## Check login startup

`mise run login status` checks only whether the expected plist exists.
It does not check the launchd disabled flag, permissions, or WM health.
Use the existing `huen-wm status` command to check the WM after login.
If macOS blocks background activity, review **System Settings > General > Login Items & Extensions**.
If startup fails, check Accessibility permission and try the launch command above from Terminal.

The LaunchAgent uses the stable label `dev.huen-wm.login` and `RunAtLoad`.
It has no `KeepAlive` because `open` exits after launching the app.
It does not supervise or restart a crashed WM.
A per-user LaunchAgent fits the ad-hoc development app without an embedded helper.
SMAppService would require app integration and is not part of this opt-in helper.
See Apple's local `man launchd`, `man launchd.plist`, and `man launchctl` for the login directory,
`RunAtLoad`, and the difference between enabling and bootstrapping a job.
