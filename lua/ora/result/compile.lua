-- Compile output type: shows compilation success or failure for code objects
-- (packages, functions, procedures, types).
--
-- Example success output:
--    Compiled successfully
--    PACKAGE BODY MY_PKG
--
-- Example failure output:
--   󰅚 PLS-00103
--      Encountered the symbol "END" when expecting...

local output = require("ora.result.output")
local error_mod = require("ora.result.error")

local ns = vim.api.nvim_create_namespace("ora_result_compile")

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraCompileSuccess",     { fg = "#9ece6a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraCompileSuccessIcon", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "OraCompileObject",      { fg = "#c0caf5", default = true })
end

-- ─── output type ────────────────────────────────────────────────────────────

---@param data { raw: string, object_name: string, object_type: string }
---@return OraResultOutput
local function create(data)
  local raw = data.raw or ""
  local has_error = error_mod.is_error(raw)

  if has_error then
    -- Delegate to the error output type for compilation errors
    local err_output = error_mod.create({ raw = raw })
    err_output.label = "Compilation Failed"
    return err_output
  end

  -- ── success ──────────────────────────────────────────────────────────────
  local icon = "󰄬 "
  local icon_bytes = #icon
  local object_label = (data.object_type or "") .. " " .. (data.object_name or "")

  local lines = {
    " " .. icon .. "Compiled successfully",
    "   " .. object_label,
  }

  ---@type integer[][] {line, col_start, col_end}
  local icon_ranges    = { { 0, 1, 1 + icon_bytes } }
  local success_ranges = { { 0, 1 + icon_bytes, #lines[1] } }
  local object_ranges  = { { 1, 3, #lines[2] } }

  return {
    type    = "compile",
    label   = "Compiled",
    icon    = "󰄬 ",
    icon_hl = "DiagnosticOk",
    lines   = lines,
    render  = function(_, bufnr)
      setup_hl()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      for _, r in ipairs(icon_ranges) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraCompileSuccessIcon",
          priority = 100,
        })
      end
      for _, r in ipairs(success_ranges) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraCompileSuccess",
          priority = 100,
        })
      end
      for _, r in ipairs(object_ranges) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_col  = r[3],
          hl_group = "OraCompileObject",
          priority = 100,
        })
      end
    end,
  }
end

output.register("compile", create)

return {
  create = create,
}
