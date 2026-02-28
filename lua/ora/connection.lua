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

  if opts.is_named then
    cmd = string.format("%s -name %s", config.values.sqlcl_path, vim.fn.shellescape(url))
  else
    cmd = string.format("%s %s", config.values.sqlcl_path, url)
  end

  vim.fn.termopen(cmd, {
    on_exit = function()
      sessions[url] = nil
    end,
  })

  local buf_name = string.format("ora://%s", label)
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
  sessions[url] = bufnr

  vim.cmd("startinsert")
end

---Return the terminal buffer number for an active session, or nil.
---@param key string  connection URL or connmgr name
---@return integer|nil
function M.get_bufnr(key)
  return session_alive(key) and sessions[key] or nil
end

---Return true if the given terminal buffer has a live SQLcl job.
---@param bufnr integer|nil
---@return boolean
function M.term_alive(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local ok, bt = pcall(vim.api.nvim_buf_get_option, bufnr, "buftype")
  if not ok or bt ~= "terminal" then return false end
  local ok2, chan = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
  if not ok2 or not chan then return false end
  return vim.fn.jobwait({ chan }, 0)[1] == -1  -- -1 = still running
end

---Open a fresh dedicated SQLcl terminal in the background (no visible window).
---Unlike connect(), this never reuses an existing session and does not update
---the shared sessions table — the caller owns the returned buffer.
---@param url   string  connection string or connmgr name
---@param label string  display label used in the buffer name
---@param opts? { is_named?: boolean, buf_name?: string }
---@return integer bufnr  the new terminal buffer
function M.open_dedicated(url, label, opts)
  opts = opts or {}

  local cmd

  if opts.is_named then
    cmd = string.format("%s -name %s", config.values.sqlcl_path, vim.fn.shellescape(url))
  else
    cmd = string.format("%s %s", config.values.sqlcl_path, url)
  end

  -- Create the buffer first, then open a temporary hidden float so that
  -- termopen() can run (it requires the buffer to be current in a window).
  -- The float is closed immediately after — the job keeps running in the buffer.
  local bufnr    = vim.api.nvim_create_buf(true, false)
  local prev_win = vim.api.nvim_get_current_win()

  local float_win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width    = 200,
    height   = 50,
    row      = 0,
    col      = 0,
    style    = "minimal",
  })

  vim.fn.termopen(cmd, {
    on_exit = function() end,
  })

  pcall(vim.api.nvim_buf_set_name, bufnr, opts.buf_name or ("ora://ws/" .. label))

  -- Close the float; focus returns to the caller's window
  vim.api.nvim_win_close(float_win, false)
  vim.api.nvim_set_current_win(prev_win)

  return bufnr
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
