local config = require("ora.config")

local M = {}

-- Track open SQLcl terminal buffers: url -> bufnr
local sessions = {}

---Return true if a terminal buffer for `url` is still alive.
---@param url string
---@return boolean
local function session_alive(url)
  local bufnr = sessions[url]
  if not bufnr then return false end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    sessions[url] = nil
    return false
  end
  local ok, bt = pcall(vim.api.nvim_buf_get_option, bufnr, "buftype")
  return ok and bt == "terminal"
end

---Open a new terminal split running sqlcl.
---If a session for that url already exists, jump to its window instead.
---@param url   string  Connection string OR connmgr connection name
---@param label string  Human-readable label shown in the buffer name
---@param opts? {is_named?: boolean}  When is_named=true, url is a connmgr name
function M.connect(url, label, opts)
  opts = opts or {}

  if session_alive(url) then
    local bufnr = sessions[url]
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
    -- Buffer alive but not visible — show it in a new split
    vim.cmd("botright new")
    vim.api.nvim_win_set_buf(0, bufnr)
    return
  end

  -- Open a horizontal split with a fresh empty buffer (termopen requirement)
  vim.cmd("botright new")
  local bufnr = vim.api.nvim_get_current_buf()

  local cmd
  local startup_file

  if opts.is_named then
    -- For connmgr connections: start SQLcl in /nolog mode, then run a startup
    -- script that connects by name so stored credentials are used automatically.
    -- SQLcl remains interactive after the startup script completes.
    startup_file = vim.fn.tempname() .. ".sql"
    local f = assert(io.open(startup_file, "w"))
    f:write(string.format("connect @%s\n", url))
    f:close()
    cmd = string.format("%s /nolog @%s", config.values.sqlcl_path, startup_file)
  else
    cmd = string.format("%s %s", config.values.sqlcl_path, url)
  end

  vim.fn.termopen(cmd, {
    on_exit = function()
      sessions[url] = nil
      if startup_file then
        os.remove(startup_file)
      end
    end,
  })

  local buf_name = string.format("ora://%s", label)
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
  sessions[url] = bufnr

  vim.cmd("startinsert")
end

---Return all active sessions as a list of {url, bufnr}.
---@return table[]
function M.active_sessions()
  local list = {}
  for url, bufnr in pairs(sessions) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(list, { url = url, bufnr = bufnr })
    else
      sessions[url] = nil
    end
  end
  return list
end

return M
