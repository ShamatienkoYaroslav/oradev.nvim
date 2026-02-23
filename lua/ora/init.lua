local M = {}

local _setup_done = false

---Configure the plugin. Must be called before any other ora function.
---
---@param user_config OraConfig
---
---Example:
---  require("ora").setup({
---    sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
---  })
function M.setup(user_config)
  require("ora.config").setup(user_config)
  _setup_done = true
end

---Show saved connections from the SQLcl connection manager and connect to one.
function M.list()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end
  require("ora.ui.picker").open()
end

---Connect directly with a connection string (skips the picker UI).
---@param url string
function M.connect(url)
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end
  require("ora.connection").connect(url, url)
end

---Add a new named connection to the SQLcl connection manager.
---Prompts for a name and connection string if not provided as arguments.
---@param name? string  connection name
---@param url?  string  user[/pass]@host:port/service
function M.add_connection(name, url)
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end

  local function do_add(n, u)
    local ok, err = require("ora.connmgr").add(n, u)
    if ok then
      vim.notify(string.format("[ora] connection '%s' added", n), vim.log.levels.INFO)
    else
      vim.notify("[ora] failed to add connection: " .. (err or ""), vim.log.levels.ERROR)
    end
  end

  if name and url then
    do_add(name, url)
  else
    require("ora.ui.add_connection").ask(do_add)
  end
end

return M
