local M = {}

---@class OraConfig
---@field sqlcl_path          string                   Path to the sqlcl executable
---@field win_width           integer                  Width of the picker floating window (columns)
---@field win_height          integer                  Height of the picker floating window (rows)
---@field explorer_mappings   table<string, string>    Key → command mappings for the schema explorer

---@type OraConfig
local defaults = {
  sqlcl_path = "sql",
  win_width  = 60,
  win_height = 20,
  explorer_mappings = {
    ["<cr>"] = "toggle_node",
    ["l"]    = "expand_node",
    ["h"]    = "collapse_node",
    ["r"]    = "refresh",
    ["o"]    = "quick_open",
    ["O"]    = "quick_open_alt",
    ["a"]    = "show_actions",
    ["A"]    = "add_connection",
  },
}

---@type OraConfig
M.values = vim.deepcopy(defaults)

---Merge user config with defaults and validate required fields.
---@param user_config table
function M.setup(user_config)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user_config or {})

  if type(M.values.sqlcl_path) ~= "string" or M.values.sqlcl_path == "" then
    error("[ora] config.sqlcl_path must be a non-empty string (path to sqlcl binary)")
  end
end

return M
