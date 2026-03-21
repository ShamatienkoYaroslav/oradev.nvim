-- Query output type: formats SQL result sets as bordered, column-aligned
-- tables with header highlighting, alternating rows, and NULL markers.
--
-- Example output:
--   ┌────┬─────────┬──────┐
--   │ ID │ NAME    │ AGE  │
--   ├────┼─────────┼──────┤
--   │ 1  │ Alice   │ 30   │
--   │ 2  │ Bob     │ NULL │
--   │ 3  │ Charlie │ 25   │
--   └────┴─────────┴──────┘
--    3 rows

local output = require("ora.result.output")

local ns = vim.api.nvim_create_namespace("ora_result_query")

local MAX_COL_WIDTH = 64   -- hard cap for any single column (LOB-friendly)
local LOB_TYPES = {         -- column types that get truncated aggressively
  BLOB = true, CLOB = true, NCLOB = true, BFILE = true,
  ["LONG"]     = true,
  ["LONG RAW"] = true,
  ["RAW"]      = true,
}

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraResultBorder",  { fg = "#4e5465", default = true })
  vim.api.nvim_set_hl(0, "OraResultHeader",  { fg = "#c0caf5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraResultRowAlt",  { bg = "#1a1b26", default = true })
  vim.api.nvim_set_hl(0, "OraResultNull",    { fg = "#565f89", italic = true, default = true })
  vim.api.nvim_set_hl(0, "OraResultFooter",  { fg = "#565f89", italic = true, default = true })
  vim.api.nvim_set_hl(0, "OraResultTrunc",  { fg = "#565f89", default = true })
end

-- ─── padding helper ─────────────────────────────────────────────────────────

---Left-align a string in a field of `width` characters, padding with spaces.
---Unlike string.format("%-Ns"), this has no width limit.
---@param s string
---@param width integer
---@return string
local function lpad(s, width)
  local pad = width - #s
  if pad <= 0 then return s end
  return s .. string.rep(" ", pad)
end

-- ─── box-drawing helpers ────────────────────────────────────────────────────

---Build a horizontal border line: ┌──┬──┐, ├──┼──┤, or └──┴──┘.
---@param widths integer[]
---@param left string  e.g. "┌"
---@param mid  string  e.g. "┬"
---@param right string e.g. "┐"
---@return string
local function hline(widths, left, mid, right)
  local segs = {}
  for i, w in ipairs(widths) do
    segs[i] = string.rep("─", w + 2)  -- 1 space padding each side
  end
  return left .. table.concat(segs, mid) .. right
end

---Build a data/header row with │ separators, tracking byte positions.
---@param widths integer[]
---@param values string[]
---@return string              line
---@return integer[][]         border_byte_ranges  list of {start, end} for each │
---@return integer[][]         cell_byte_ranges    list of {start, end, value} per cell
local function build_row(widths, values)
  local parts = {}
  local borders = {}
  local cells = {}
  local bp = 0  -- byte position

  for i, v in ipairs(values) do
    -- │ before cell
    table.insert(parts, "│")
    table.insert(borders, { bp, bp + 3 })
    bp = bp + 3

    -- space + content + space
    local cell = " " .. lpad(v, widths[i]) .. " "
    local content_start = bp + 1            -- after the leading space
    local content_end   = bp + 1 + widths[i] -- just the content, not trailing space
    table.insert(cells, { content_start, content_end, v })
    table.insert(parts, cell)
    bp = bp + #cell
  end

  -- trailing │
  table.insert(parts, "│")
  table.insert(borders, { bp, bp + 3 })

  return table.concat(parts), borders, cells
end

-- ─── table formatter ────────────────────────────────────────────────────────

---@class QueryHlData
---@field border_lines integer[]        line indices that are entirely border
---@field header_line  integer|nil      line index of the header row
---@field alt_rows     integer[]        line indices for alternating row bg
---@field null_cells   integer[][]      {line, byte_start, byte_end}
---@field trunc_cells  integer[][]      {line, byte_start, byte_end} for … markers
---@field border_cols  integer[][]      {line, byte_start, byte_end} for │ in rows
---@field footer_line  integer|nil      line index for footer text

---Format one result set as a bordered table.
---@param columns {name:string, type:string}[]
---@param items   table[]
---@return string[]     lines
---@return QueryHlData  hl_data
local function format_table(columns, items)
  if #columns == 0 then
    return { "(no columns)" }, { border_lines = {}, alt_rows = {}, null_cells = {}, border_cols = {} }
  end
  if #items == 0 then
    return { "(no rows returned)" }, { border_lines = {}, alt_rows = {}, null_cells = {}, border_cols = {} }
  end

  -- Compute column names, types, and widths
  local names    = {}
  local is_lob   = {}
  local widths   = {}
  for _, col in ipairs(columns) do
    local n = tostring(col.name or "")
    local t = tostring(col.type or ""):upper()
    table.insert(names, n)
    table.insert(is_lob, LOB_TYPES[t] or false)
    table.insert(widths, #n)
  end

  -- Build rows: sanitise values (flatten newlines, truncate LOBs)
  local rows = {}
  local truncated = {}  -- [row_idx][col_idx] = true when value was truncated
  for _, item in ipairs(items) do
    local row = {}
    local trunc_row = {}
    for i, n in ipairs(names) do
      local v = item[n]
      if v == nil then v = item[n:lower()] end
      local s
      if v == nil or v == vim.NIL then
        s = "NULL"
      else
        s = tostring(v)
        -- Flatten newlines / tabs to single space for display
        s = s:gsub("[\n\r\t]+", " ")
        -- Truncate if LOB or exceeds max width
        local cap = is_lob[i] and math.min(MAX_COL_WIDTH, MAX_COL_WIDTH) or MAX_COL_WIDTH
        if #s > cap then
          s = s:sub(1, cap - 1) .. "…"
          trunc_row[i] = true
        end
      end
      table.insert(row, s)
      if #s > widths[i] then widths[i] = #s end
    end
    table.insert(rows, row)
    table.insert(truncated, trunc_row)
  end

  -- Cap column widths (safety net)
  for i = 1, #widths do
    if widths[i] > MAX_COL_WIDTH then widths[i] = MAX_COL_WIDTH end
  end

  local lines = {}
  ---@type QueryHlData
  local hl = {
    border_lines = {},
    header_line  = nil,
    alt_rows     = {},
    null_cells   = {},
    trunc_cells  = {},
    border_cols  = {},
    footer_line  = nil,
  }

  -- Top border ┌──┬──┐
  table.insert(lines, hline(widths, "┌", "┬", "┐"))
  table.insert(hl.border_lines, #lines - 1)  -- 0-based

  -- Header row │ NAME │
  local hdr_line, hdr_borders = build_row(widths, names)
  table.insert(lines, hdr_line)
  hl.header_line = #lines - 1
  for _, br in ipairs(hdr_borders) do
    table.insert(hl.border_cols, { #lines - 1, br[1], br[2] })
  end

  -- Separator ├──┼──┤
  table.insert(lines, hline(widths, "├", "┼", "┤"))
  table.insert(hl.border_lines, #lines - 1)

  -- Data rows │ val │
  for row_idx, row in ipairs(rows) do
    local row_line, row_borders, row_cells = build_row(widths, row)
    local line_idx = #lines  -- 0-based index after insert
    table.insert(lines, row_line)

    -- Alternating background (even data rows, 1-indexed → odd line indices)
    if row_idx % 2 == 0 then
      table.insert(hl.alt_rows, line_idx)
    end

    -- Border │ positions
    for _, br in ipairs(row_borders) do
      table.insert(hl.border_cols, { line_idx, br[1], br[2] })
    end

    -- NULL cells and truncation markers
    local trunc_row = truncated[row_idx] or {}
    for col_idx, cell in ipairs(row_cells) do
      if cell[3] == "NULL" then
        table.insert(hl.null_cells, { line_idx, cell[1], cell[1] + 4 })
      elseif trunc_row[col_idx] then
        -- Highlight the trailing "…" (3 bytes UTF-8)
        table.insert(hl.trunc_cells, { line_idx, cell[2] - 3, cell[2] })
      end
    end
  end

  -- Bottom border └──┴──┘
  table.insert(lines, hline(widths, "└", "┴", "┘"))
  table.insert(hl.border_lines, #lines - 1)

  -- Footer
  table.insert(lines, string.format(" %d row%s", #rows, #rows == 1 and "" or "s"))
  hl.footer_line = #lines - 1

  return lines, hl
end

-- ─── raw JSON → output ──────────────────────────────────────────────────────

---Parse raw spool content and build lines + highlight data.
---@param raw string
---@return string[]     lines
---@return QueryHlData  hl_data
local function parse_and_format(raw)
  local empty_hl = { border_lines = {}, alt_rows = {}, null_cells = {}, trunc_cells = {}, border_cols = {} }

  raw = vim.trim(raw)
  if raw == "" then return { "(empty output)" }, empty_hl end

  local ok, parsed = pcall(vim.fn.json_decode, raw)
  if not ok or type(parsed) ~= "table" then
    return { "(unexpected output — not a query result)" }, empty_hl
  end

  local results = parsed.results
  if not results or #results == 0 then
    return { "(query returned no result set)" }, empty_hl
  end

  local all_lines = {}
  local all_hl    = {
    border_lines = {},
    alt_rows     = {},
    null_cells   = {},
    trunc_cells  = {},
    border_cols  = {},
    header_line  = nil,
    footer_line  = nil,
  }

  for idx, rs in ipairs(results) do
    if idx > 1 then table.insert(all_lines, "") end
    local offset = #all_lines
    local rs_lines, rs_hl = format_table(rs.columns or {}, rs.items or {})

    -- Offset all highlight line indices
    for _, li in ipairs(rs_hl.border_lines) do
      table.insert(all_hl.border_lines, offset + li)
    end
    if rs_hl.header_line then
      -- Keep only the first result set's header for the single-header case
      if not all_hl.header_line then
        all_hl.header_line = offset + rs_hl.header_line
      end
      -- Store all header lines for multi-result
      if not all_hl.header_lines then all_hl.header_lines = {} end
      table.insert(all_hl.header_lines, offset + rs_hl.header_line)
    end
    for _, ar in ipairs(rs_hl.alt_rows) do
      table.insert(all_hl.alt_rows, offset + ar)
    end
    for _, nc in ipairs(rs_hl.null_cells) do
      table.insert(all_hl.null_cells, { offset + nc[1], nc[2], nc[3] })
    end
    for _, tc in ipairs(rs_hl.trunc_cells or {}) do
      table.insert(all_hl.trunc_cells, { offset + tc[1], tc[2], tc[3] })
    end
    for _, bc in ipairs(rs_hl.border_cols) do
      table.insert(all_hl.border_cols, { offset + bc[1], bc[2], bc[3] })
    end
    if rs_hl.footer_line then
      all_hl.footer_line = offset + rs_hl.footer_line
      if not all_hl.footer_lines then all_hl.footer_lines = {} end
      table.insert(all_hl.footer_lines, offset + rs_hl.footer_line)
    end

    vim.list_extend(all_lines, rs_lines)
  end

  return all_lines, all_hl
end

-- ─── output type ────────────────────────────────────────────────────────────

---@param data { raw: string }
---@return OraResultOutput
local function create(data)
  local lines, hl_data = parse_and_format(data.raw)
  return {
    type    = "query",
    label   = "Query Result",
    icon    = "󰓫 ",
    icon_hl = "Type",
    lines   = lines,
    render  = function(_, bufnr)
      setup_hl()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      -- Border lines (top, separator, bottom) — full line
      for _, li in ipairs(hl_data.border_lines or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraResultBorder",
          hl_eol        = true,
          priority      = 50,
        })
      end

      -- Header row — full line
      for _, li in ipairs(hl_data.header_lines or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraResultHeader",
          priority      = 100,
        })
      end

      -- Alternating data rows
      for _, li in ipairs(hl_data.alt_rows or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraResultRowAlt",
          priority      = 50,
        })
      end

      -- Border │ characters in header + data rows
      for _, bc in ipairs(hl_data.border_cols or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, bc[1], bc[2], {
          end_col  = bc[3],
          hl_group = "OraResultBorder",
          priority = 150,
        })
      end

      -- NULL cells
      for _, nc in ipairs(hl_data.null_cells or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, nc[1], nc[2], {
          end_col  = nc[3],
          hl_group = "OraResultNull",
          priority = 200,
        })
      end

      -- Truncation markers (…)
      for _, tc in ipairs(hl_data.trunc_cells or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, tc[1], tc[2], {
          end_col  = tc[3],
          hl_group = "OraResultTrunc",
          priority = 200,
        })
      end

      -- Footer lines
      for _, li in ipairs(hl_data.footer_lines or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraResultFooter",
          priority      = 50,
        })
      end
    end,
  }
end

output.register("query", create)

return {
  create           = create,
  parse_and_format = parse_and_format,
}
