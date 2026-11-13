local message_path = assert(arg[1], "Expected a commit message file")
local message_file = assert(io.open(message_path, "r"))
local title
for line in message_file:lines() do
  if line:sub(1, 1) ~= "#" then
    title = line:gsub("\r$", "")
    break
  end
end
message_file:close()

local allowed_types = {
  build = true,
  chore = true,
  ci = true,
  docs = true,
  feat = true,
  fix = true,
  perf = true,
  refactor = true,
  revert = true,
  style = true,
  test = true,
}

local commit_type, suffix, subject = (title or ""):match("^([a-zA-Z]+)(.-): (.*)$")
local valid_suffix = suffix == "" or suffix == "!"
  or (suffix and suffix:match("^%([^()%s]+%)!?$") ~= nil)

if not (commit_type and allowed_types[commit_type:lower()] and valid_suffix
  and subject:match("^%S") and not subject:find("%c")) then
  io.stderr:write("Invalid commit title. Use type(scope)!: subject with an optional scope and !.\n",
    "Types: build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test.\n",
    "The subject must start with a non-whitespace character.\n")
  os.exit(1)
end
