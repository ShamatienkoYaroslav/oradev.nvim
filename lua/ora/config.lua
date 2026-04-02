local M = {}

---@class OraLspConfig
---@field server_path? string   Path to plsql-lsp/dist/server.js (nil = disabled)
---@field filetypes?   string[] File types to attach the LSP client to
---@field enabled?     boolean  Set to false to disable LSP even if server_path is set

---@class OraConfig
---@field sqlcl_path          string                   Path to the sqlcl executable
---@field win_width           integer                  Width of the picker floating window (columns)
---@field win_height          integer                  Height of the picker floating window (rows)
---@field auto_worksheet      boolean                  Auto-register sql/plsql/pks/pkb files as worksheets
---@field explorer_mappings   table<string, string>    Key → command mappings for the schema explorer
---@field lsp?                OraLspConfig             PL/SQL LSP configuration

---@type OraConfig
local defaults = {
  sqlcl_path = "sql",
  win_width  = 60,
  win_height = 20,
  auto_worksheet = true,
  explorer_mappings = {
    ["<cr>"] = "toggle_node",
    ["l"]    = "expand_node",
    ["h"]    = "collapse_node",
    ["r"]    = "refresh",
    ["o"]    = "quick_open",
    ["O"]    = "quick_open_alt",
    ["a"]    = "show_actions",
  },
  lsp = {
    server_path = nil,
    filetypes   = { "plsql", "sql" },
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
