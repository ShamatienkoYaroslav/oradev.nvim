-- Execution plan output type: displays actual Oracle execution plans with
-- runtime statistics (A-Rows, A-Time, Buffers, etc.) matching the result UI
-- style.
--
-- Uses GATHER_PLAN_STATISTICS + DBMS_XPLAN.DISPLAY_CURSOR to produce the plan.
-- Reuses the explain module's parser since the DBMS_XPLAN format is identical.

local output  = require("ora.result.output")
local explain = require("ora.result.explain")

---@param data { raw: string }
---@return OraResultOutput
local function create(data)
  local raw = data.raw or ""

  local error_mod = require("ora.result.error")
  if error_mod.is_error(raw) then
    local err_output = error_mod.create({ raw = raw })
    err_output.label = "Execution Plan"
    return err_output
  end

  local out = explain.create(data)
  out.type    = "execution"
  out.label   = "Execution Plan"
  out.icon    = "󰑮 "
  out.icon_hl = "DiagnosticOk"
  return out
end

output.register("execution", create)

return {
  create = create,
}
