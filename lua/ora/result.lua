-- Result module: runs a SQL query via a one-shot sqlcl job, parses the JSON
-- output, formats it as a column-aligned table with highlights, and shows it
-- in a per-worksheet read-only buffer.

local M = {}

-- ─── highlights ───────────────────────────────────────────────────────────────

local ns_result = vim.api.nvim_create_namespace("ora_result")

local function setup_hl()
  -- Full-width header row (teal background).  `default = true` lets colorschemes override.
  vim.api.nvim_set_hl(0, "OraResultHeader", {
    bg = "#005f5f", fg = "#d0d0d0", bold = true, default = true,
  })
  -- NULL values rendered in the same style as comments (dim/italic in most themes).
  vim.api.nvim_set_hl(0, "OraResultNull", { link = "Comment", default = true })
end

-- ─── table formatter ──────────────────────────────────────────────────────────

local COL_GAP = "  "  -- two spaces between columns

---Format one result set as plain column-aligned lines (no box-drawing borders).
---@param columns {name:string, type:string}[]
---@param items   table[]
---@return string[]  lines
---@return table     null_cells   list of {line_0based, byte_start, byte_end}
---@return boolean   has_header   true when lines[1] is a column-name header
local function format_table(columns, items)
  if #columns == 0 then return { "(no columns)" },      {}, false end
  if #items    == 0 then return { "(no rows returned)" }, {}, false end

  local names  = {}
  local widths = {}
  for _, col in ipairs(columns) do
    local n = tostring(col.name or "")
    table.insert(names,  n)
    table.insert(widths, #n)
  end

  -- Build rows; widen each column to fit data
  local rows = {}
  for _, item in ipairs(items) do
    local row = {}
    for i, n in ipairs(names) do
      local v = item[n]
      if v == nil then v = item[n:lower()] end
      local s = (v == nil or v == vim.NIL) and "NULL" or tostring(v)
      table.insert(row, s)
      if #s > widths[i] then widths[i] = #s end
    end
    table.insert(rows, row)
  end

  -- Header line (0-based index 0 within this result set)
  local hdr_parts = {}
  for i, n in ipairs(names) do
    hdr_parts[i] = string.format("%-" .. widths[i] .. "s", n)
  end
  local lines = { table.concat(hdr_parts, COL_GAP) }

  -- Data lines + NULL positions
  local null_cells = {}
  for row_idx, row in ipairs(rows) do
    local line_0based = row_idx  -- header at 0; first data row at 1
    local parts    = {}
    local byte_pos = 0
    for i, v in ipairs(row) do
      local cell = string.format("%-" .. widths[i] .. "s", v)
      if v == "NULL" then
        -- highlight just the four "NULL" bytes, not the trailing padding
        table.insert(null_cells, { line_0based, byte_pos, byte_pos + 4 })
      end
      table.insert(parts, cell)
      byte_pos = byte_pos + widths[i] + #COL_GAP
    end
    table.insert(lines, table.concat(parts, COL_GAP))
  end

  table.insert(lines, string.format("(%d row%s)", #rows, #rows == 1 and "" or "s"))

  return lines, null_cells, true
end

---Parse raw spool content, format all result sets, collect highlight data.
---@param raw string
---@return string[]  lines
---@return table     hl_data   { header_lines: integer[], null_cells: table[] }
local function parse_and_format(raw)
  raw = vim.trim(raw)
  if raw == "" then return { "(empty output)" }, {} end

  local ok, parsed = pcall(vim.fn.json_decode, raw)
  if not ok then
    local preview = raw:gsub("[^\9\10\32-\126]", ""):sub(1, 300)
    return vim.list_extend({ "-- parse error (raw output below):", "" },
                            vim.split(preview, "\n", { plain = true })), {}
  end

  local results = parsed and parsed.results
  if not results or #results == 0 then
    return { "(query returned no result set)" }, {}
  end

  local all_lines = {}
  local all_hl    = { header_lines = {}, null_cells = {} }

  for idx, rs in ipairs(results) do
    if idx > 1 then table.insert(all_lines, "") end
    local offset = #all_lines
    local rs_lines, null_cells, has_header =
      format_table(rs.columns or {}, rs.items or {})

    if has_header then
      table.insert(all_hl.header_lines, offset)  -- 0-based global line index
    end
    for _, nc in ipairs(null_cells) do
      table.insert(all_hl.null_cells, { offset + nc[1], nc[2], nc[3] })
    end
    vim.list_extend(all_lines, rs_lines)
  end

  return all_lines, all_hl
end

-- ─── sqlcl job ────────────────────────────────────────────────────────────────

---Run `ws.connection`'s SQL via a one-shot sqlcl non-interactive job.
---Calls `callback(lines, hl_data, err)` when done.
---@param ws       OraWorksheet
---@param callback fun(lines: string[]|nil, hl_data: table|nil, err: string|nil)
function M.run(ws, callback)
  local conn = ws.connection
  local cfg  = require("ora.config").values

  local sql = table.concat(
    vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
  sql = vim.trim(sql)
  if sql == "" then
    callback(nil, nil, "worksheet is empty")
    return
  end
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
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
          callback(nil, nil,
            "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, nil, "sqlcl exited with code " .. code)
          return
        end
        local lines, hl_data = parse_and_format(raw)
        callback(lines, hl_data, nil)
      end)
    end,
  }):start()
end

-- ─── result buffer ────────────────────────────────────────────────────────────

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

---Apply result highlights to a buffer using extmarks.
---Header lines get a full-width background via `line_hl_group`.
---NULL cells get `OraResultNull` over the exact "NULL" bytes.
---@param bufnr   integer
---@param hl_data table  { header_lines: integer[], null_cells: table[] }
function M.apply_highlights(bufnr, hl_data)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  setup_hl()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_result, 0, -1)

  for _, line_idx in ipairs(hl_data.header_lines or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns_result, line_idx, 0, {
      line_hl_group = "OraResultHeader",
      priority      = 100,
    })
  end

  for _, nc in ipairs(hl_data.null_cells or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns_result, nc[1], nc[2], {
      end_col  = nc[3],
      hl_group = "OraResultNull",
      priority = 200,
    })
  end
end

---Write formatted result lines to the buffer and apply highlights.
---@param bufnr   integer
---@param lines   string[]
---@param hl_data table
function M.set_buf_content(bufnr, lines, hl_data)
  M.set_buf_lines(bufnr, lines)
  M.apply_highlights(bufnr, hl_data or {})
end

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
