-- Interface to the SQLcl connection manager (connmgr).
-- Connections are stored by SQLcl; this module reads and writes them.

local M = {}

-- ─── internal helpers ─────────────────────────────────────────────────────────

---Run a list of SQLcl commands non-interactively via a temp script file.
---Uses /nolog (no DB required) and -S (silent, no banner).
---@param commands string[]
---@return string output  raw stdout
---@return integer code   exit code
local function run(commands)
  local cfg = require("ora.config").values
  local script = vim.fn.tempname() .. ".sql"
  local f = assert(io.open(script, "w"))
  for _, cmd in ipairs(commands) do
    f:write(cmd .. "\n")
  end
  f:write("exit\n")
  f:close()

  local Job = require("plenary.job")
  local job = Job:new({
    command          = cfg.sqlcl_path,
    args             = { "/nolog", "-S", "@" .. script },
    enable_recording = true,
  })
  local lines, code = job:sync(30000)
  os.remove(script)
  return table.concat(lines or {}, "\n"), code or 0
end

---Strip ANSI escape codes, UTF-8 box-drawing tree chars, "SQL> " prompts, and whitespace.
---@param line string
---@return string
local function clean(line)
  return (line
    :gsub("\27%[[%d;]*[mABCDHJKSTfilhsu]", "")   -- ANSI escape codes
    :gsub("[^\1-\127]", "")                        -- non-ASCII bytes (UTF-8 box-drawing: └──)
    :gsub("^SQL>%s*", "")                          -- SQL> prompt prefix
    :match("^%s*(.-)%s*$"))                        -- trim
end

-- ─── public API ───────────────────────────────────────────────────────────────

---@class ConnmgrTreeEntry
---@field name string
---@field type "folder"|"connection"
---@field children ConnmgrTreeEntry[]|nil

---Parse the ASCII tree output from `connmgr list` into a hierarchical structure.
---Folders are detected by having a deeper item following them.
---@return ConnmgrTreeEntry[]
function M.list_tree()
  local out = (run({ "connmgr list" }))
  local entries = {} ---@type {name: string, depth: integer}[]

  for line in out:gmatch("[^\n\r]+") do
    -- Strip ANSI codes
    line = line:gsub("\27%[[%d;]*[mABCDHJKSTfilhsu]", "")
    -- Strip SQL> prompt
    line = line:gsub("^SQL>%s*", "")

    -- Skip empty, banner, and noise lines (same filters as list())
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    if  trimmed == ""
    or  trimmed:match("^%-%-")
    or  trimmed:match("^=+")
    or  trimmed:match(":$")
    or  trimmed:match("^Connecting")
    or  trimmed:match("^SQLcl")
    or  trimmed:match("^Oracle")
    or  trimmed:match("^Copyright")
    or  trimmed:match("^All%s")
    or  trimmed == "."
    then
      goto continue
    end

    -- Determine depth from visual column of the tree branch chars (├ └).
    -- Each depth level is 4 visual columns of indent in the tree output.
    -- UTF-8 box-drawing chars (│ ├ └ ─) are 3 bytes but 1 visual column,
    -- so adjust byte position to visual column before computing depth.
    local branch_pos = line:find("\xe2\x94\x9c") or line:find("\xe2\x94\x94")
    local depth
    if branch_pos then
      local prefix = line:sub(1, branch_pos - 1)
      local _, box_count = prefix:gsub("\xe2\x94[\x80-\xbf]", "")
      local visual_col = branch_pos - (box_count * 2)
      depth = math.floor((visual_col - 1) / 4)
    else
      -- No tree chars — top-level flat name
      depth = 0
    end

    -- Extract the name: strip tree drawing chars and whitespace
    local name = line:gsub("[^\1-\127]", ""):match("^%s*(.-)%s*$") or ""
    if name ~= "" then
      table.insert(entries, { name = name, depth = depth })
    end

    ::continue::
  end

  -- Build tree: an item is a folder if the next item has greater depth
  local function build(list, start, parent_depth)
    local result = {}
    local i = start
    while i <= #list do
      local entry = list[i]
      if entry.depth <= parent_depth then
        break -- back to parent level
      end
      if entry.depth == parent_depth + 1 then
        -- Check if next entry is a child (folder)
        local is_folder = (i + 1 <= #list) and (list[i + 1].depth > entry.depth)
        if is_folder then
          local children, next_i = build(list, i + 1, entry.depth)
          table.insert(result, {
            name     = entry.name,
            type     = "folder",
            children = children,
          })
          i = next_i
        else
          table.insert(result, {
            name = entry.name,
            type = "connection",
          })
          i = i + 1
        end
      else
        i = i + 1
      end
    end
    return result, i
  end

  local tree = build(entries, 1, -1)
  return tree
end

---Return all connection names stored in the SQLcl connection manager.
---@return string[]
function M.list()
  local out = (run({ "connmgr list" }))
  local names = {}
  for line in out:gmatch("[^\n\r]+") do
    line = clean(line)
    -- Skip empty lines and known non-name output lines
    if  line ~= ""
    and not line:match("^%-%-")           -- SQL-style separators
    and not line:match("^=+")            -- banner separators
    and not line:match(":$")             -- category headers like "Oracle:"
    and not line:match("^Connecting")
    and not line:match("^SQLcl")
    and not line:match("^Oracle")
    and not line:match("^Copyright")
    and not line:match("^All%s")         -- "All Connections:" etc.
    and line ~= "."                        -- connmgr artifact
    then
      table.insert(names, line)
    end
  end
  return names
end

---Return details for a single stored connection.
---@param name string
---@return {connect_string: string, user: string}|nil
function M.show(name)
  local out = (run({ "connmgr show " .. vim.fn.shellescape(name) }))
  local info = {}
  for line in out:gmatch("[^\n\r]+") do
    line = clean(line)
    -- Match "Key: Value" lines (with optional spaces around the colon)
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key and value then
      info[vim.trim(key):lower():gsub("%s+", "_")] = vim.trim(value)
    end
  end
  -- normalise: "connect_string" may appear as different keys
  local cs = info.connect_string or info.connectstring or info.url
  local user = info.user or info.username
  if not (cs and user) then return nil end
  return { connect_string = cs, user = user }
end

---Add a new named connection to the SQLcl connection manager.
---Accepts the EZConnect format: user[/pass]@host:port/service
---@param name string  display name
---@param url  string  connection string
---@return boolean ok
---@return string|nil err
function M.add(name, url)
  -- Parse user/pass@host:port/service
  local user, pass, host, port, service =
    url:match("^([^/@]+)/([^@]*)@([^:/]+):(%d+)/(.+)$")
  if not user then
    -- Try without password: user@host:port/service
    user, host, port, service =
      url:match("^([^/@]+)@([^:/]+):(%d+)/(.+)$")
    pass = nil
  end
  if not user then
    return false,
      "cannot parse connection string — expected user[/pass]@host:port/service"
  end

  local info = {
    customUrl             = string.format("jdbc:oracle:thin:@//%s:%s/%s", host, port, service),
    user                  = user,
    SavePassword          = (pass and pass ~= "") and "true" or "false",
    OS_AUTHENTICATION     = "false",
    KERBEROS_AUTHENTICATION = "false",
    RoleType              = "normal",
    driverType            = "thin",
  }
  if pass and pass ~= "" then
    info.password = pass
  end

  local json = vim.fn.json_encode({
    connections = { { name = name, type = "Oracle", info = info } },
  })

  local tmpjson = vim.fn.tempname() .. ".json"
  local f = assert(io.open(tmpjson, "w"))
  f:write(json)
  f:close()

  local out, code = run({ "connmgr import " .. vim.fn.shellescape(tmpjson) })
  os.remove(tmpjson)

  if code ~= 0 or out:match("[Ee]rror") or out:match("[Ff]ailed") then
    return false, vim.trim(out ~= "" and out or ("exit code " .. tostring(code)))
  end
  return true
end

return M
