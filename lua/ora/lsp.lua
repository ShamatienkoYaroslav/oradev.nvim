local M = {}

---Set up the PL/SQL LSP client autocommand.
---@param config OraConfig
function M.setup(config)
  if not config.lsp or config.lsp.enabled == false then
    return
  end

  vim.api.nvim_create_autocmd("FileType", {
    pattern = config.lsp.filetypes or { "plsql", "sql" },
    callback = function(ev)
      M.start(ev.buf)
    end,
  })
end

---Start the plsql-lsp client for the given buffer.
---@param bufnr integer
function M.start(bufnr)
  local config = require("ora.config").values
  if not config.lsp or not config.lsp.server_path then
    return
  end

  vim.lsp.start({
    name = "plsql-lsp",
    cmd = { "node", config.lsp.server_path, "--stdio" },
    root_dir = vim.fs.dirname(
      vim.fs.find({ "oradev.json", ".git" }, { upward = true, path = vim.api.nvim_buf_get_name(bufnr) })[1]
    ),
    on_attach = function(_, buf)
      -- Enable LSP-based folding for all windows showing this buffer
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_set_option_value("foldmethod", "expr", { win = win })
        vim.api.nvim_set_option_value("foldexpr", "v:lua.vim.lsp.foldexpr()", { win = win })
        vim.api.nvim_set_option_value("foldlevel", 99, { win = win })
      end
    end,
  }, { bufnr = bufnr })
end

return M
