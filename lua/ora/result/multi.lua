-- Multi output type: combines multiple child outputs into a single result buffer.
-- Each section has a header showing the SQL block that produced it.
--
-- Example output:
--   ── select * from employees ──────────────────────────
--   ┌────┬─────────┐
--   │ ID │ NAME    │
--   ...
--
--   ── begin ... end; ───────────────────────────────────
--    󰄬 Executed successfully

local output = require("ora.result.output")

local ns = vim.api.nvim_create_namespace("ora_result_multi")

local SECTION_WIDTH = 72

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraMultiHeader",   { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraMultiIndex",    { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "OraMultiSuccess",  { fg = "#9ece6a", default = true })
end

-- ─── section header ─────────────────────────────────────────────────────────

---Build a section header line: "── [1] select * from emp ──────────"
---@param index integer
---@param sql string
---@return string
local function section_header(index, sql)
  -- Take first meaningful line, truncate
  local label = sql:match("^%s*(.-)%s*$") or sql
  label = label:gsub("\n.*", "")  -- first line only
  if #label > SECTION_WIDTH - 14 then
    label = label:sub(1, SECTION_WIDTH - 17) .. "…"
  end
  local prefix = "── [" .. index .. "] " .. label .. " "
  local pad = SECTION_WIDTH - #prefix
  if pad < 2 then pad = 2 end
  return prefix .. string.rep("─", pad)
end

-- ─── output type ────────────────────────────────────────────────────────────

---@class OraMultiSection
---@field sql     string           the SQL block text
---@field output  OraResultOutput  child output (query, error, etc.)

---@param data { sections: OraMultiSection[] }
---@return OraResultOutput
local function create(data)
  local sections = data.sections or {}
  if #sections == 0 then
    return {
      type = "multi", label = "Results", icon = "󰓫 ", icon_hl = "Type",
      lines = { "(no blocks executed)" },
      render = function() end,
    }
  end

  -- Single section → unwrap, no header needed
  if #sections == 1 then
    return sections[1].output
  end

  -- Build combined lines and track per-section offsets for rendering
  local all_lines = {}
  local section_meta = {}  -- { offset, header_line, output }

  for i, sec in ipairs(sections) do
    if i > 1 then
      table.insert(all_lines, "")
    end

    local header = section_header(i, sec.sql)
    local header_line = #all_lines  -- 0-based
    table.insert(all_lines, header)
    table.insert(all_lines, "")

    local offset = #all_lines
    table.insert(section_meta, {
      offset      = offset,
      header_line = header_line,
      output      = sec.output,
    })

    for _, line in ipairs(sec.output.lines) do
      table.insert(all_lines, line)
    end
  end

  -- Determine overall status
  local has_error = false
  for _, sec in ipairs(sections) do
    if sec.output.type == "error" then has_error = true end
  end

  return {
    type    = "multi",
    label   = #sections .. " Blocks",
    icon    = "󰓫 ",
    icon_hl = has_error and "DiagnosticError" or "Type",
    lines   = all_lines,
    render  = function(_, bufnr)
      setup_hl()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      -- Render section headers
      for _, meta in ipairs(section_meta) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, meta.header_line, 0, {
          line_hl_group = "OraMultiHeader",
          priority      = 100,
        })

        -- Delegate child output rendering with line offset
        -- We call the child render on a "virtual" bufnr context by offsetting
        -- the extmarks. Instead, we re-implement by calling render and letting
        -- each output type place extmarks at 0-based positions, then we shift.
      end

      -- Render each child output with shifted line positions.
      -- Each child output type sets extmarks at 0-based line indices.
      -- We render them into the real buffer by temporarily patching the lines,
      -- then restoring. But that's complex.
      --
      -- Simpler: call each child's render on a scratch buffer, read extmarks,
      -- then re-create them with offset. But that's also heavy.
      --
      -- Simplest: each child render writes extmarks into bufnr at its own
      -- 0-based positions. We call them in order; extmarks at wrong positions
      -- get ignored by nvim. So we need to offset.
      --
      -- Best approach: each output's render places extmarks at positions
      -- matching its own lines array. We need to shift those positions.
      -- Since render functions use hardcoded line indices from their hl_data
      -- closures, we can't easily shift them. Instead, we render each child
      -- into a temp buffer and copy extmarks.
      --
      -- Actually the simplest correct approach: render each child into a
      -- temporary buffer, extract extmarks, then recreate them with offset.
      for _, meta in ipairs(section_meta) do
        local child = meta.output
        local tmp = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(tmp, 0, -1, false, child.lines)
        child:render(tmp)

        -- Copy all extmarks from the child's namespaces to the real buffer
        -- with line offset.
        local child_marks = vim.api.nvim_buf_get_extmarks(tmp, -1, 0, -1, { details = true })
        for _, mark in ipairs(child_marks) do
          local row = mark[2] + meta.offset
          local col = mark[3]
          local details = mark[4]
          local ext_opts = { priority = details.priority or 100 }
          if details.hl_group then
            ext_opts.hl_group = details.hl_group
          end
          if details.end_col then
            ext_opts.end_col = details.end_col
          end
          if details.end_row then
            ext_opts.end_row = details.end_row + meta.offset
          end
          if details.line_hl_group then
            ext_opts.line_hl_group = details.line_hl_group
          end
          if details.hl_eol then
            ext_opts.hl_eol = details.hl_eol
          end
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, ext_opts)
        end

        vim.api.nvim_buf_delete(tmp, { force = true })
      end
    end,
  }
end

output.register("multi", create)

return {
  create = create,
}
