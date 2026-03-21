-- Base output type interface for the result container.
-- Each output type must implement this interface.

---@class OraResultOutput
---@field type    string          unique output type name
---@field label   string          display label for the winbar
---@field icon    string          nerd font icon for the winbar
---@field icon_hl string          highlight group for the icon
---@field lines   string[]        buffer content lines
---@field render  fun(self: OraResultOutput, bufnr: integer)  apply highlights/extmarks
---@field actions? { name: string, fn: fun() }[]  optional actions (future use)

---@type table<string, fun(data: table): OraResultOutput>
local registry = {}

local M = {}

---Register a new output type constructor.
---@param type_name string
---@param constructor fun(data: table): OraResultOutput
function M.register(type_name, constructor)
  registry[type_name] = constructor
end

---Create an output instance by type name.
---@param type_name string
---@param data table  type-specific data passed to the constructor
---@return OraResultOutput|nil
function M.create(type_name, data)
  local ctor = registry[type_name]
  if not ctor then return nil end
  return ctor(data)
end

return M
