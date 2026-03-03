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
  vim.filetype.add({ pattern = { ["ora://worksheet%-.*"] = "plsql" } })
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

---Create a new SQL worksheet buffer (no connection prompt).
---The connection can be chosen later when executing the worksheet.
function M.new_worksheet()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end

  local ws = require("ora.worksheet").create()
  local ws_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(ws_win, ws.bufnr)
end

---List all open worksheets in a floating picker.
function M.list_worksheets()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end
  require("ora.ui.worksheets_picker").open()
end

---Execute the current worksheet SQL and show the result as a formatted table
---in a split below the worksheet. If the buffer has no connection the
---connection picker is shown first.
function M.execute_worksheet()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end

  local bufnr   = vim.api.nvim_get_current_buf()
  local ws_mod  = require("ora.worksheet")
  local ws      = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  local function do_run()
    local result = require("ora.result")
    local notify = require("ora.notify")
    local nid = "ora_exec"
    local rbuf = result.get_or_create_buf(ws)
    result.set_buf_lines(rbuf, { "-- running…" })
    result.show(rbuf)
    notify.progress(nid, "Executing query…")
    result.run(ws, function(lines, hl_data, err)
      if err then
        result.set_buf_lines(rbuf, { "-- ERROR: " .. err })
        notify.error(nid, "Query failed")
        return
      end
      local sql = table.concat(vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
      result.push_history(ws, sql, lines)
      result.set_buf_content(rbuf, lines, hl_data)
      notify.done(nid, "Query complete")
    end)
  end

  if ws.connection then
    do_run()
  else
    require("ora.ui.picker").select(function(conn)
      if not conn then return end
      ws.connection = conn
      ws_mod.refresh_winbar(ws)
      do_run()
    end)
  end
end

---Run the current worksheet SQL and show the result as a formatted table.
---Alias for execute_worksheet().
function M.worksheet_result()
  M.execute_worksheet()
end

---Format the current worksheet SQL using SQLcl's built-in formatter.
function M.format_worksheet()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  require("ora.format").run(ws.bufnr, function(err)
    if err then
      vim.notify("[ora] format failed: " .. err, vim.log.levels.ERROR)
    end
  end)
end

---Change the connection for the current worksheet.
---Opens the connection picker; the selected connection replaces the current one.
function M.change_worksheet_connection()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  require("ora.ui.picker").select(function(conn)
    if not conn then return end
    ws.connection = conn
    ws_mod.refresh_winbar(ws)
  end)
end

---Open the quick action picker: find objects by pattern and act on them.
function M.quick_action()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end
  require("ora.ui.quick_action").open()
end

---Open the neo-tree Oracle connections/schemas explorer.
function M.explorer()
  if not _setup_done then
    vim.notify("[ora] call require('ora').setup({...}) first", vim.log.levels.ERROR)
    return
  end
  require("neo-tree.command").execute({ source = "ora", position = "left" })
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
