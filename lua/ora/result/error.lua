-- Error output type: parses Oracle/SQLcl error output, extracts error codes
-- and messages, and renders them with highlights.
--
-- Example output:
--    ORA-00942
--    table or view does not exist

local output = require("ora.result.output")

local ns = vim.api.nvim_create_namespace("ora_result_error")

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraErrorIcon",    { fg = "#db4b4b", default = true })
  vim.api.nvim_set_hl(0, "OraErrorCode",    { fg = "#db4b4b", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraErrorMessage", { fg = "#c0caf5", default = true })
  vim.api.nvim_set_hl(0, "OraErrorUrl",     { fg = "#565f89", italic = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, "OraErrorLabel",  { fg = "#7aa2f7", bold = true, default = true })
end

-- ─── noise patterns (lines to discard) ──────────────────────────────────────

local noise_patterns = {
  "^Error starting at line",
  "^In command %-%s*$",
  "^Error at Command Line",
  "^Error report %-%s*$",
  "^%d+%.%s+%d+%s*$",         -- "00942. 000" trailing artifact
  "^File @",
  "^SQL>",
  "^%s*$",
}

---Check whether a line is noise that should be discarded.
---@param line string
---@return boolean
local function is_noise(line)
  for _, pat in ipairs(noise_patterns) do
    if line:match(pat) then return true end
  end
  return false
end

---Check whether a line is the failing SQL command (between "In command -" and
---the next "Error at" line). We detect these heuristically: lines that don't
---look like an error message or URL.
---@param line string
---@return boolean
local function is_sql_command(line)
  -- Lines that ARE valuable (keep them)
  if line:match("^[A-Z]+-[%d]+:")   then return false end  -- ORA-nnn: / PLS-nnn:
  if line:match("^SQL Error:")       then return false end
  if line:match("^https?://")        then return false end
  -- Lines that are part of the SQL command context
  if line:match("^%s*select%s")      then return true end
  if line:match("^%s*insert%s")      then return true end
  if line:match("^%s*update%s")      then return true end
  if line:match("^%s*delete%s")      then return true end
  if line:match("^%s*merge%s")       then return true end
  if line:match("^%s*create%s")      then return true end
  if line:match("^%s*alter%s")       then return true end
  if line:match("^%s*drop%s")        then return true end
  if line:match("^%s*begin%s")       then return true end
  if line:match("^%s*declare%s")     then return true end
  if line:match("^%s*call%s")        then return true end
  if line:match("^%s*grant%s")       then return true end
  if line:match("^%s*revoke%s")      then return true end
  if line:match("^%s*truncate%s")    then return true end
  if line:match("^%s*comment%s")     then return true end
  if line:match("^%s*exec%s")        then return true end
  return false
end

-- ─── parser ─────────────────────────────────────────────────────────────────

---@class OraError
---@field code    string|nil     e.g. "ORA-00942"
---@field lines   string[]       message lines (first is the main message, rest are detail)
---@field url     string|nil     docs URL if present

---Parse raw Oracle error output into structured errors.
---@param raw string
---@return OraError[]
local function parse_errors(raw)
  local errors = {}
  local current = nil

  for line in raw:gmatch("[^\n\r]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")

    if is_noise(line) then
      goto continue
    end

    if is_sql_command(line) then
      goto continue
    end

    -- "SQL Error: ORA-00942: table or view does not exist"
    local code, msg = line:match("^SQL Error:%s*([A-Z]+-[%d]+):%s*(.+)")
    if code then
      if current then table.insert(errors, current) end
      current = { code = code, lines = { msg } }
      goto continue
    end

    -- "ORA-00942: table or view does not exist" (without "SQL Error:" prefix)
    code, msg = line:match("^([A-Z]+-[%d]+):%s*(.+)")
    if code then
      if current then table.insert(errors, current) end
      current = { code = code, lines = { msg } }
      goto continue
    end

    -- Docs URL
    if line:match("^https?://") then
      if current then
        current.url = line
      end
      goto continue
    end

    -- Section starters (*Cause:, *Action:, More Details) → new line
    if current and line:match("^%*%a+:") then
      table.insert(current.lines, line)
      goto continue
    end
    if current and line:match("^More Details") then
      goto continue  -- discard "More Details :" label, URL follows
    end

    -- Continuation line — append to the last line in current error
    if current and line ~= "" then
      local last = current.lines[#current.lines]
      -- If the last line is a section label (*Cause:, *Action:), start
      -- content on the same line after the label.
      if last:match("^%*%a+:%s*$") then
        current.lines[#current.lines] = last .. line
      else
        current.lines[#current.lines] = last .. " " .. line
      end
    elseif line ~= "" then
      -- Standalone error text without a code
      if current then table.insert(errors, current) end
      current = { code = nil, lines = { line } }
    end

    ::continue::
  end

  if current then table.insert(errors, current) end
  return errors
end

-- ─── formatter ──────────────────────────────────────────────────────────────

---@class ErrorHlData
---@field icon_ranges    integer[][]   {line, col_start, col_end}
---@field code_ranges    integer[][]   {line, col_start, col_end}
---@field message_ranges integer[][]   {line, col_start, col_end}
---@field label_ranges   integer[][]   {line, col_start, col_end}
---@field url_ranges     integer[][]   {line, col_start, col_end}

---Format parsed errors into display lines with highlight tracking.
---@param errors OraError[]
---@return string[]     lines
---@return ErrorHlData  hl_data
local function format_errors(errors)
  if #errors == 0 then
    return { " 󰅚 Unknown error" }, {
      icon_ranges = { { 0, 1, 5 } },
      code_ranges = {}, message_ranges = {}, label_ranges = {}, url_ranges = {},
    }
  end

  local lines = {}
  local hl = { icon_ranges = {}, code_ranges = {}, message_ranges = {}, label_ranges = {}, url_ranges = {} }

  for i, err in ipairs(errors) do
    if i > 1 then
      table.insert(lines, "")
    end

    -- Error code line: " 󰅚 ORA-00942"
    local icon = "󰅚 "
    local icon_bytes = #icon
    if err.code then
      local line_str = " " .. icon .. err.code
      local li = #lines
      table.insert(lines, line_str)
      table.insert(hl.icon_ranges, { li, 1, 1 + icon_bytes })
      table.insert(hl.code_ranges, { li, 1 + icon_bytes, #line_str })
    elseif err.lines[1] then
      local line_str = " " .. icon .. err.lines[1]
      local li = #lines
      table.insert(lines, line_str)
      table.insert(hl.icon_ranges, { li, 1, 1 + icon_bytes })
      table.insert(hl.message_ranges, { li, 1 + icon_bytes, #line_str })
      goto continue
    end

    -- Message lines
    for _, msg in ipairs(err.lines) do
      local indent = "   "
      local display = indent .. msg
      local li = #lines
      table.insert(lines, display)

      -- Check for section label (*Cause:, *Action:)
      local label_end = msg:match("^(%*%a+:)")
      if label_end then
        local label_byte_end = #indent + #label_end
        table.insert(hl.label_ranges, { li, #indent, label_byte_end })
        if #display > label_byte_end then
          table.insert(hl.message_ranges, { li, label_byte_end, #display })
        end
      else
        table.insert(hl.message_ranges, { li, #indent, #display })
      end
    end

    -- URL line
    if err.url then
      table.insert(lines, "")
      local url_line = "   " .. err.url
      local li = #lines
      table.insert(lines, url_line)
      table.insert(hl.url_ranges, { li, 3, #url_line })
    end

    ::continue::
  end

  return lines, hl
end

-- ─── detection ──────────────────────────────────────────────────────────────

---Check whether raw spool output looks like an Oracle error rather than
---a query result. Call this before attempting JSON parse.
---@param raw string
---@return boolean
local function is_error(raw)
  if raw:match("SQL Error:") then return true end
  if raw:match("[A-Z]+-[%d]+:") and raw:match("Error") then return true end
  if raw:match("^Error starting at line") then return true end
  if raw:match("\nError starting at line") then return true end
  if raw:match("ORA%-[%d]+:") then return true end
  if raw:match("PLS%-[%d]+:") then return true end
  if raw:match("SP2%-[%d]+:") then return true end
  return false
end

-- ─── output type ────────────────────────────────────────────────────────────

---@param data { raw: string }
---@return OraResultOutput
local function create(data)
  local errors = parse_errors(data.raw)
  local lines, hl_data = format_errors(errors)
  return {
    type    = "error",
    label   = "Errors",
    icon    = "󰅚 ",
    icon_hl = "DiagnosticError",
    lines   = lines,
    render  = function(_, bufnr)
      setup_hl()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      for _, r in ipairs(hl_data.icon_ranges or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraErrorIcon",
          priority = 100,
        })
      end
      for _, r in ipairs(hl_data.code_ranges or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraErrorCode",
          priority = 100,
        })
      end
      for _, r in ipairs(hl_data.message_ranges or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraErrorMessage",
          priority = 100,
        })
      end
      for _, r in ipairs(hl_data.label_ranges or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraErrorLabel",
          priority = 150,
        })
      end
      for _, r in ipairs(hl_data.url_ranges or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraErrorUrl",
          priority = 100,
        })
      end
    end,
  }
end

output.register("error", create)

return {
  create   = create,
  is_error = is_error,
}
