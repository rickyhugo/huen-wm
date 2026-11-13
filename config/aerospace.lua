local bindings = {}
local workspaces = {}

local function bind(mods, key, command)
    bindings[#bindings + 1] = { mods = mods, key = key, command = command }
end

-- Swap approximates AeroSpace's tiling movement without forcing floating.
for key, direction in pairs({ ["h"] = "left", ["j"] = "down", ["k"] = "up", ["l"] = "right" }) do
    bind("alt", key, "focus --wrap " .. direction)
    bind("alt+shift", key, "swap " .. direction)
end

for workspace = 1, 10 do
    workspaces[workspace] = tostring(workspace)
    local key = tostring(workspace % 10)
    bind("alt", key, "workspace " .. workspace)
    bind("alt+shift", key, "send-to-workspace " .. workspace)
end

bind("alt", "return", "launch --new-instance com.mitchellh.ghostty")
bind("alt", "b", "launch --new-instance com.google.Chrome")
bind("alt+shift", "q", "close --quit-if-last-window")
bind("alt", "f", "fullscreen")
bind("alt", "e", "split toggle")
bind("alt+shift", "space", "toggle-floating")
bind("alt+shift", "c", "reload")
bind("alt+shift", "s", 'exec-and-forget "$HOME/Applications/Flameshot.app/Contents/MacOS/flameshot" gui')
bind("alt", "r", "mode resize")

return {
    gap = 10,
    layout = "dwindle",
    workspaces = workspaces,
    workspace_monitors = { "external", "built-in" },
    mouse_follows_monitor = true,
    status_bar = { enabled = true, label = "name" },
    bindings = bindings,
    modes = {
        {
            name = "resize",
            bindings = {
                { mods = "", key = "h", command = "resize width -50" },
                { mods = "", key = "j", command = "resize height 50" },
                { mods = "", key = "k", command = "resize height -50" },
                { mods = "", key = "l", command = "resize width 50" },
                { mods = "", key = "return", command = "mode main" },
                { mods = "", key = "escape", command = "mode main" },
            },
        },
    },
    rules = {
        { bundle = "com.tinyspeck.slackmacgap", workspace = 3 },
    },
}
