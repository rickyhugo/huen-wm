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
bind("ctrl+alt", "space", "toggle-floating")
bind("ctrl+alt", "=", "resize 0.05")
bind("ctrl+alt", "-", "resize -0.05")
bind("ctrl+alt", "r", "reload")

return {
    status_bar = { enabled = true, label = "name" },
    session = { enabled = false },
    mouse = { enabled = false, mods = "ctrl+alt" },
    gap = 12,
    layout = "dwindle",
    master_ratio = 0.55,
    border_width = 2,
    border_color = "#9BAFFF",
    motion_duration = 0.12,
    workspaces = { "Build", "Browse", "Write", "Talk", "Quiet" },
    bindings = bindings,
    rules = {
        { bundle = "com.apple.systempreferences", floating = true },
        -- {
        --     bundle = "com.apple.TextEdit",
        --     title = { glob = "Notes *" },
        --     geometry = { left = 40, top = 60, width = 800, height = 600 },
        -- },
    },
}
