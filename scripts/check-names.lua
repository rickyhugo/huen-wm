local excluded = {
    vendor = true,
    vendored = true,
    third_party = true,
    ["third-party"] = true,
    [".zig-cache"] = true,
    ["zig-out"] = true,
    ["zig-pkg"] = true,
}

local function long_bracket_end(source, offset)
    local equals = source:sub(offset):match("^%[(=*)%[")
    if not equals then
        return nil
    end
    local _, closing = source:find("]" .. equals .. "]", offset + #equals + 2, true)
    return closing and closing + 1 or #source + 1
end

local function quoted_end(source, offset)
    local quote = source:sub(offset, offset)
    local cursor = offset + 1
    while cursor <= #source do
        local character = source:sub(cursor, cursor)
        if character == "\\" then
            cursor = cursor + 2
        elseif character == quote then
            return cursor + 1
        else
            cursor = cursor + 1
        end
    end
    return #source + 1
end

local function check_file(filename)
    for component in filename:gmatch("[^/]+") do
        if excluded[component] then
            return true
        end
    end
    local language = filename:match("%.([^.]+)$")
    if language ~= "zig" and language ~= "lua" and language ~= "m"
        and language ~= "mm" and language ~= "h" then
        return true
    end
    local file, message = io.open(filename, "rb")
    if not file then
        io.stderr:write(message, "\n")
        return false
    end
    local source = file:read("a")
    file:close()
    local offset, line, column = 1, 1, 1
    local valid = true
    while offset <= #source do
        local remainder = source:sub(offset)
        local pair = remainder:sub(1, 2)
        local character = remainder:sub(1, 1)
        local next_offset
        if language == "lua" and pair == "--" then
            next_offset = long_bracket_end(source, offset + 2)
                or source:find("\n", offset, true) or #source + 1
        elseif language ~= "lua" and pair == "//" then
            next_offset = source:find("\n", offset, true) or #source + 1
        elseif language ~= "lua" and language ~= "zig" and pair == "/*" then
            local _, closing = source:find("*/", offset + 2, true)
            next_offset = closing and closing + 1 or #source + 1
        elseif language == "zig" and pair == "\\\\" then
            next_offset = source:find("\n", offset, true) or #source + 1
        elseif language == "lua" and character == "[" then
            next_offset = long_bracket_end(source, offset)
        end
        if not next_offset then
            if language == "zig" and pair == '@"' then
                next_offset = quoted_end(source, offset + 1)
                local identifier = source:sub(offset + 2, next_offset - 2)
                if identifier:match("^[A-Za-z]$") then
                    io.stderr:write(filename, ":", line, ":", column,
                        ": single-letter identifier '", identifier, "'\n")
                    valid = false
                end
            elseif character == '"' or character == "'" then
                next_offset = quoted_end(source, offset)
            elseif character:match("%d") then
                local number = remainder:match("^[%w_.]+")
                next_offset = offset + #number
            else
                local identifier = remainder:match("^[A-Za-z_][A-Za-z_0-9]*")
                if identifier then
                    next_offset = offset + #identifier
                    if identifier:match("^[A-Za-z]$") then
                        io.stderr:write(filename, ":", line, ":", column,
                            ": single-letter identifier '", identifier, "'\n")
                        valid = false
                    end
                else
                    next_offset = offset + 1
                end
            end
        end
        local consumed = source:sub(offset, next_offset - 1)
        local _, newlines = consumed:gsub("\n", "")
        if newlines > 0 then
            line = line + newlines
            column = #consumed:match("[^\n]*$") + 1
        else
            column = column + #consumed
        end
        offset = next_offset
    end
    return valid
end

if #arg == 0 then
    io.stderr:write("usage: lua scripts/check-names.lua <source files...>\n")
    os.exit(2)
end

local valid = true
for _, filename in ipairs(arg) do
    if not check_file(filename) then
        valid = false
    end
end
os.exit(valid and 0 or 1)
