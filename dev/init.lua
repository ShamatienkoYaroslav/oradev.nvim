-- Development init for manually testing the plugin.
-- Usage: nvim -u dev/init.lua  (or: make dev)
--
-- Starts Neovim with the plugin loaded. Connections are read from the SQLcl
-- connection manager — run :OraAddConnection to add one first if needed.
-- Then run :OraConnectionsList to open the picker.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Add lazy-installed plugins to rtp so neo-tree and dependencies load
local lazy_path = vim.fn.stdpath("data") .. "/lazy"
for _, plugin in ipairs({ "neo-tree.nvim", "nui.nvim", "plenary.nvim", "nvim-web-devicons" }) do
  local p = lazy_path .. "/" .. plugin
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

require("ora").setup({
  sqlcl_path = "sql",
})

require("neo-tree").setup({
  sources = {
    "filesystem",
    "ora",
  },
  ora = {
    window = {
      mappings = {
        ["<cr>"] = "toggle_node",
        ["l"]    = "expand_node",
        ["h"]    = "collapse_node",
        ["r"]    = "refresh",
        ["a"]    = "add_connection",
        ["e"]    = "open_object",
      },
    },
  },
})
