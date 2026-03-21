-- Result container: manages the per-worksheet result buffer and split window.
-- Delegates content rendering to output type modules (query, plsql, error, …).

local M = {}

-- Ensure built-in output types are registered on first require.
require("ora.result.query")
require("ora.result.error")
require("ora.result.compile")

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraResultWinbar",     { bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraResultWinbarDim",  { link = "Comment", default = true })
end

-- ─── result buffer ──────────────────────────────────────────────────────────

---Return (creating on demand) the result buffer for a worksheet.
---@param ws OraWorksheet
---@return integer bufnr
function M.get_or_create_buf(ws)
  if ws.result_bufnr and vim.api.nvim_buf_is_valid(ws.result_bufnr) then
    return ws.result_bufnr
  end
  local bufnr = vim.api.nvim_create_buf(false, false)
  pcall(vim.api.nvim_buf_set_name, bufnr, "ora://result/" .. ws.name)
  vim.api.nvim_buf_set_option(bufnr, "buftype",    "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden",  "hide")
  vim.api.nvim_buf_set_option(bufnr, "swapfile",   false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype",   "ora-result")
  ws.result_bufnr = bufnr
  return bufnr
end

---Replace the result buffer content (briefly enables modifiable).
---@param bufnr integer
---@param lines string[]
function M.set_buf_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

-- ─── winbar ─────────────────────────────────────────────────────────────────

---Update the winbar for every window showing the result buffer.
---@param bufnr  integer
---@param output OraResultOutput
local function refresh_winbar(bufnr, output)
  setup_hl()
  local icon_hl = output.icon_hl or "Special"
  local icon    = output.icon    or ""
  local label   = output.label   or ""
  local text = " %#" .. icon_hl .. "#" .. icon .. "%*%#OraResultWinbar#" .. label .. "%*"
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.api.nvim_win_set_option(win, "winbar", text)
  end
end

-- ─── display output ─────────────────────────────────────────────────────────

---Display an output in the result buffer: set lines, render highlights, update winbar.
---@param bufnr  integer
---@param output OraResultOutput
function M.display(bufnr, output)
  M.set_buf_lines(bufnr, output.lines)
  output:render(bufnr)
  refresh_winbar(bufnr, output)
end

-- ─── history ────────────────────────────────────────────────────────────────

---Append an entry to the worksheet result history.
---@param ws    OraWorksheet
---@param sql   string
---@param lines string[]
function M.push_history(ws, sql, lines)
  if not ws.result_history then ws.result_history = {} end
  table.insert(ws.result_history, {
    sql       = sql,
    lines     = lines,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
  })
end

-- ─── sqlcl job ──────────────────────────────────────────────────────────────

---Run `ws.connection`'s SQL via a one-shot sqlcl non-interactive job.
---Calls `callback(raw, err)` with the raw spool content.
---@param ws       OraWorksheet
---@param callback fun(raw: string|nil, err: string|nil)
function M.run(ws, callback)
  local conn = ws.connection
  local cfg  = require("ora.config").values

  local sql = table.concat(
    vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
  sql = vim.trim(sql)
  if sql == "" then
    callback(nil, "worksheet is empty")
    return
  end
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local is_soft = ws.db_object and ws.db_object.kind == "soft"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  if not is_soft then
    f:write("SET SQLFORMAT JSON\n")
  end
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  if is_soft then
    f:write("SHOW ERRORS\n")
  end
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil,
            "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end
        callback(raw, nil)
      end)
    end,
  }):start()
end

-- ─── show window ────────────────────────────────────────────────────────────

---Show the result buffer in a belowright split.
---If the buffer already has a visible window, focus that window instead.
---@param bufnr integer
function M.show(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      return
    end
  end

  vim.cmd("belowright 15split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.api.nvim_win_set_option(win, "number",         false)
  vim.api.nvim_win_set_option(win, "relativenumber", false)
  vim.api.nvim_win_set_option(win, "signcolumn",     "no")
  vim.api.nvim_win_set_option(win, "wrap",           false)
  vim.api.nvim_win_set_option(win, "winfixheight",   true)
  vim.keymap.set("n", "q", "<C-w>c",
    { buffer = bufnr, silent = true, nowait = true })
end

return M
