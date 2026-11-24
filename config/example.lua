local bindings = {}
local function bind(mods, key, command)
    bindings[#bindings + 1] = { mods = mods, key = key, command = command }
end

for key, direction in pairs({ ["h"] = "left", ["j"] = "down", ["k"] = "up", ["l"] = "right" }) do
    bind("ctrl+alt", key, "focus " .. direction)
    bind("ctrl+alt+shift", key, "swap " .. direction)
end
for index = 1, 5 do
    bind("ctrl+alt", tostring(index), "workspace " .. index)
    bind("ctrl+alt+shift", tostring(index), "send-to-workspace " .. index)
end
bind("ctrl+alt", "[", "workspace occupied-1")
bind("ctrl+alt", "]", "workspace occupied+1")
bind("ctrl+alt+shift", "[", "move-to-workspace -1")
bind("ctrl+alt+shift", "]", "move-to-workspace +1")
bind("ctrl+alt", "tab", "focus last")
bind("ctrl+alt", "u", "focus urgent")
bind("ctrl+alt", "c", "center")
bind("ctrl+alt", "space", "toggle-floating")
bind("ctrl+alt", "=", "resize 0.05")
bind("ctrl+alt", "-", "resize -0.05")
bind("ctrl+alt", "r", "reload")

return {
    status_bar = { enabled = true, label = "name" },
    session = { enabled = false },
    mouse = { enabled = false, mods = "ctrl+alt" },
    -- swipe = { enabled = false, fingers = 3 },
    gap = 12,
    layout = "dwindle",
    master_ratio = 0.55,
    border_width = 2,
    border_color = "#9BAFFF",
    border_single_window = true,
    focus_on_activate = false,
    floating_size = { width = 0.5, height = 0.5 },
    -- single_window_max_width = 1800,
    motion_duration = 0.12,
    workspaces = { "Build", "Browse", "Write", "Talk", "Quiet" },
    bindings = bindings,
    rules = {
        { bundle = "com.apple.systempreferences", floating = true },
    },
}
