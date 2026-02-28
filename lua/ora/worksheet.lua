-- Worksheet manager: tracks open SQL/PL/SQL buffers and their connections.

local M = {}

---@class OraWorksheetConn
---@field key      string   session key used in connection.sessions (name or raw URL)
---@field label    string   human-readable display name
---@field is_named boolean  true = connmgr stored connection; false = raw URL

---@class OraResultEntry
---@field sql       string
---@field lines     string[]
---@field timestamp string

---@class OraWorksheet
---@field bufnr          integer
---@field name           string
---@field connection     OraWorksheetConn|nil
---@field term_bufnr     integer|nil  dedicated terminal buffer for this worksheet
---@field result_bufnr   integer|nil  read-only result display buffer (created on demand)
---@field result_history OraResultEntry[]

---@type OraWorksheet[]
local _list = {}
local _counter = 0

---Refresh the winbar for every window currently showing this worksheet.
---Shows the connection name, or "[no connection]" when none is set.
---@param ws OraWorksheet
function M.refresh_winbar(ws)
  local label = ws.connection and ws.connection.label or "[no connection]"
  -- Escape % so the string is treated as literal text by the statusline renderer.
  local text = "  " .. label:gsub("%%", "%%%%")
  for _, win in ipairs(vim.fn.win_findbuf(ws.bufnr)) do
    vim.api.nvim_win_set_option(win, "winbar", text)
  end
end

---Create and register a new worksheet buffer.
---@param opts? { connection?: OraWorksheetConn }
---@return OraWorksheet
function M.create(opts)
  opts = opts or {}
  _counter = _counter + 1
  local name  = "worksheet-" .. _counter
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "ora://" .. name)
  vim.api.nvim_buf_set_option(bufnr, "buftype",   "")
  vim.api.nvim_buf_set_option(bufnr, "swapfile",  false)

  local ws = {
    bufnr          = bufnr,
    name           = name,
    connection     = opts.connection,
    result_bufnr   = nil,
    result_history = {},
  }
  table.insert(_list, ws)

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer   = bufnr,
    callback = function() M.refresh_winbar(ws) end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    buffer   = bufnr,
    once     = true,
    callback = function() M._remove(bufnr) end,
  })

  return ws
end

---Return all registered worksheets.
---@return OraWorksheet[]
function M.list()
  return _list
end

---Find a worksheet by buffer number. Returns nil if not tracked.
---@param bufnr integer
---@return OraWorksheet|nil
function M.find(bufnr)
  for _, ws in ipairs(_list) do
    if ws.bufnr == bufnr then return ws end
  end
end

---Register an existing buffer as a worksheet (e.g. a file opened outside OraWorksheetNew).
---Does nothing and returns the existing entry if the buffer is already tracked.
---@param bufnr integer
---@return OraWorksheet
function M.register(bufnr)
  local existing = M.find(bufnr)
  if existing then return existing end

  _counter = _counter + 1
  local raw_name = vim.api.nvim_buf_get_name(bufnr)
  local name = (raw_name ~= "" and vim.fn.fnamemodify(raw_name, ":t")) or ("worksheet-" .. _counter)

  local ws = {
    bufnr          = bufnr,
    name           = name,
    connection     = nil,
    result_bufnr   = nil,
    result_history = {},
  }
  table.insert(_list, ws)

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer   = bufnr,
    callback = function() M.refresh_winbar(ws) end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    buffer   = bufnr,
    once     = true,
    callback = function() M._remove(bufnr) end,
  })

  return ws
end

---@package
function M._remove(bufnr)
  for i, ws in ipairs(_list) do
    if ws.bufnr == bufnr then
      if ws.result_bufnr and vim.api.nvim_buf_is_valid(ws.result_bufnr) then
        pcall(vim.api.nvim_buf_delete, ws.result_bufnr, { force = true })
      end
      table.remove(_list, i)
      return
    end
  end
end

return M
