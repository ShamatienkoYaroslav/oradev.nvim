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
