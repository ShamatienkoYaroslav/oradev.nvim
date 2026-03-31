-- Explain plan output type: displays Oracle execution plans as bordered tables
-- matching the result UI style.
--
-- Uses EXPLAIN PLAN FOR + DBMS_XPLAN.DISPLAY to produce the plan, then parses
-- the built-in ASCII table output from DBMS_XPLAN.
--
-- Example output:
--   ┌────┬───────────────────────────┬──────────┬──────┬──────┐
--   │ Id │ Operation                 │ Name     │ Rows │ Cost │
--   ├────┼───────────────────────────┼──────────┼──────┼──────┤
--   │  0 │ SELECT STATEMENT          │          │    1 │    2 │
--   │  1 │  TABLE ACCESS FULL        │ EMP      │    1 │    2 │
--   └────┴───────────────────────────┴──────────┴──────┴──────┘

local output = require("ora.result.output")

local ns = vim.api.nvim_create_namespace("ora_result_explain")

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraExplainBorder",  { fg = "#4e5465", default = true })
  vim.api.nvim_set_hl(0, "OraExplainHeader",  { fg = "#c0caf5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraExplainRowAlt",  { bg = "#1a1b26", default = true })
  vim.api.nvim_set_hl(0, "OraExplainNote",    { fg = "#565f89", italic = true, default = true })
end

-- ─── padding helper ─────────────────────────────────────────────────────────

---Left-align a string in a field of `width` characters.
---@param s string
---@param width integer
---@return string
local function lpad(s, width)
  local pad = width - #s
  if pad <= 0 then return s end
  return s .. string.rep(" ", pad)
end

-- ─── box-drawing helpers ────────────────────────────────────────────────────

---@param widths integer[]
---@param left string
---@param mid  string
---@param right string
---@return string
local function hline(widths, left, mid, right)
  local segs = {}
  for i, w in ipairs(widths) do
    segs[i] = string.rep("─", w + 2)
  end
  return left .. table.concat(segs, mid) .. right
end

---@param widths integer[]
---@param values string[]
---@return string line
---@return integer[][] border_byte_ranges
local function build_row(widths, values)
  local parts = {}
  local borders = {}
  local bp = 0

  for i, v in ipairs(values) do
    table.insert(parts, "│")
    table.insert(borders, { bp, bp + 3 })
    bp = bp + 3

    local cell = " " .. lpad(v, widths[i]) .. " "
    table.insert(parts, cell)
    bp = bp + #cell
  end

  table.insert(parts, "│")
  table.insert(borders, { bp, bp + 3 })

  return table.concat(parts), borders
end

-- ─── DBMS_XPLAN parser ─────────────────────────────────────────────────────

---Parse the plain-text output from DBMS_XPLAN.DISPLAY into headers and rows.
---The DBMS_XPLAN output uses dashes and pipes, e.g.:
---  ------------------------------------
---  | Id  | Operation         | Name   |
---  ------------------------------------
---  |   0 | SELECT STATEMENT  |        |
---  ------------------------------------
---@param raw string
---@return string[]|nil headers
---@return string[][]|nil rows
---@return string[] notes  lines after the plan table (predicate info, notes)
local function parse_xplan(raw)
  local all_lines = vim.split(raw, "\n", { plain = true })

  -- Phase 1: find the plan table block.
  -- The DBMS_XPLAN table is the region of consecutive lines that start with
  -- `|` (pipe), bookended by `---` separator lines.  SQLcl's spool may also
  -- contain a PLAN_TABLE_OUTPUT column header followed by its own `---` line,
  -- so we cannot simply start at the first `---`.  Instead, scan for the first
  -- `|`-prefixed line and work outward.
  local first_pipe, last_pipe
  for i, line in ipairs(all_lines) do
    if vim.trim(line):match("^|") then
      if not first_pipe then first_pipe = i end
      last_pipe = i
    elseif first_pipe then
      -- Allow `---` separator lines in between (they separate header from
      -- data), but stop at any other non-pipe, non-dash line.
      if not vim.trim(line):match("^%-%-%-%-") then
        break
      end
    end
  end

  if not first_pipe then return nil, nil, {} end

  -- Extend range to include the surrounding `---` border lines.
  local range_start = first_pipe
  local range_end   = last_pipe
  if range_start > 1 and vim.trim(all_lines[range_start - 1]):match("^%-%-%-%-") then
    range_start = range_start - 1
  end
  if range_end < #all_lines and vim.trim(all_lines[range_end + 1]):match("^%-%-%-%-") then
    range_end = range_end + 1
  end

  -- Phase 2: parse header and data rows from the pipe-delimited block.
  local headers = {}
  local rows = {}
  local header_found = false

  for i = range_start, range_end do
    local trimmed = vim.trim(all_lines[i])
    if trimmed:match("^|") then
      local cells = {}
      for cell in trimmed:gmatch("|([^|]+)") do
        table.insert(cells, vim.trim(cell))
      end
      if not header_found then
        headers = cells
        header_found = true
      else
        table.insert(rows, cells)
      end
    end
  end

  -- Phase 3: collect note lines (predicate information, etc.) after the table.
  local note_lines = {}
  for i = range_end + 1, #all_lines do
    local trimmed = vim.trim(all_lines[i])
    if trimmed ~= "" then
      table.insert(note_lines, trimmed)
    end
  end

  if #headers == 0 then return nil, nil, note_lines end
  return headers, rows, note_lines
end

-- ─── format as bordered table ───────────────────────────────────────────────

---@class ExplainHlData
---@field border_lines integer[]
---@field header_line  integer|nil
---@field alt_rows     integer[]
---@field border_cols  integer[][]
---@field note_lines   integer[]

---Format parsed explain plan as a bordered table matching query output style.
---@param headers string[]
---@param rows string[][]
---@param notes string[]
---@return string[] lines
---@return ExplainHlData hl_data
local function format_explain_table(headers, rows, notes)
  local widths = {}
  for i, h in ipairs(headers) do
    widths[i] = #h
  end
  for _, row in ipairs(rows) do
    for i, v in ipairs(row) do
      if #v > (widths[i] or 0) then widths[i] = #v end
    end
  end

  local lines = {}
  local hl = {
    border_lines = {},
    header_line  = nil,
    alt_rows     = {},
    border_cols  = {},
    note_lines   = {},
  }

  -- Top border
  table.insert(lines, hline(widths, "┌", "┬", "┐"))
  table.insert(hl.border_lines, #lines - 1)

  -- Header row
  local hdr_line, hdr_borders = build_row(widths, headers)
  table.insert(lines, hdr_line)
  hl.header_line = #lines - 1
  for _, br in ipairs(hdr_borders) do
    table.insert(hl.border_cols, { #lines - 1, br[1], br[2] })
  end

  -- Separator
  table.insert(lines, hline(widths, "├", "┼", "┤"))
  table.insert(hl.border_lines, #lines - 1)

  -- Data rows
  for row_idx, row in ipairs(rows) do
    -- Pad row to match header count if needed
    while #row < #headers do table.insert(row, "") end
    local row_line, row_borders = build_row(widths, row)
    local line_idx = #lines
    table.insert(lines, row_line)

    if row_idx % 2 == 0 then
      table.insert(hl.alt_rows, line_idx)
    end
    for _, br in ipairs(row_borders) do
      table.insert(hl.border_cols, { line_idx, br[1], br[2] })
    end
  end

  -- Bottom border
  table.insert(lines, hline(widths, "└", "┴", "┘"))
  table.insert(hl.border_lines, #lines - 1)

  -- Notes (predicate information, etc.)
  if #notes > 0 then
    table.insert(lines, "")
    for _, note in ipairs(notes) do
      local li = #lines
      table.insert(lines, " " .. note)
      table.insert(hl.note_lines, li)
    end
  end

  return lines, hl
end

-- ─── output type ────────────────────────────────────────────────────────────

---@param data { raw: string }
---@return OraResultOutput
local function create(data)
  local raw = data.raw or ""

  -- Check for errors first
  local error_mod = require("ora.result.error")
  if error_mod.is_error(raw) then
    local err_output = error_mod.create({ raw = raw })
    err_output.label = "Explain Plan"
    return err_output
  end

  local headers, rows, notes = parse_xplan(raw)
  if not headers or #headers == 0 then
    return {
      type    = "explain",
      label   = "Explain Plan",
      icon    = "󰙨 ",
      icon_hl = "DiagnosticInfo",
      lines   = { "(no execution plan returned)" },
      render  = function() end,
    }
  end

  local lines, hl_data = format_explain_table(headers, rows, notes)

  return {
    type    = "explain",
    label   = "Explain Plan",
    icon    = "󰙨 ",
    icon_hl = "DiagnosticInfo",
    lines   = lines,
    render  = function(_, bufnr)
      setup_hl()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      for _, li in ipairs(hl_data.border_lines or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraExplainBorder",
          hl_eol        = true,
          priority      = 50,
        })
      end

      if hl_data.header_line then
        vim.api.nvim_buf_set_extmark(bufnr, ns, hl_data.header_line, 0, {
          line_hl_group = "OraExplainHeader",
          priority      = 100,
        })
      end

      for _, li in ipairs(hl_data.alt_rows or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraExplainRowAlt",
          priority      = 50,
        })
      end

      for _, bc in ipairs(hl_data.border_cols or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, bc[1], bc[2], {
          end_col  = bc[3],
          hl_group = "OraExplainBorder",
          priority = 150,
        })
      end

      for _, li in ipairs(hl_data.note_lines or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, li, 0, {
          line_hl_group = "OraExplainNote",
          hl_eol        = true,
          priority      = 50,
        })
      end
    end,
  }
end

output.register("explain", create)

return {
  create     = create,
  parse_xplan = parse_xplan,
}
