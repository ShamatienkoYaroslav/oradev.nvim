-- Development init for manually testing the plugin.
-- Usage: nvim -u dev/init.lua  (or: make dev)
--
-- Starts Neovim with the plugin loaded. Connections are read from the SQLcl
-- connection manager — run :OraAddConnection to add one first if needed.
-- Then run :OraConnectionsList to open the picker.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

require("ora").setup({
  sqlcl_path = "sql",
})
