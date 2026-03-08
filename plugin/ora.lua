if vim.g.loaded_ora then return end
vim.g.loaded_ora = true

-- Icon highlight groups (default = true so colorschemes can override)
vim.api.nvim_set_hl(0, "OraIconPackage", { fg = "#d19a66", default = true })

vim.api.nvim_create_user_command("OraConnectionsList", function()
  require("ora").list()
end, { desc = "List saved Oracle connections (from SQLcl connmgr) and connect" })

vim.api.nvim_create_user_command("OraConnect", function(opts)
  local url = opts.args
  if url == "" then
    require("ora.notify").warn("ora", "Usage: :OraConnect <connection-string>")
    return
  end
  require("ora").connect(url)
end, {
  nargs    = 1,
  desc     = "Connect to Oracle with a connection string",
  complete = "file",
})

vim.api.nvim_create_user_command("OraWorksheetNew", function()
  require("ora").new_worksheet()
end, { desc = "Create a new SQL worksheet and pick a connection" })

vim.api.nvim_create_user_command("OraWorksheetsList", function()
  require("ora").list_worksheets()
end, { desc = "List open worksheets" })

vim.api.nvim_create_user_command("OraWorksheetExecute", function()
  require("ora").execute_worksheet()
end, { desc = "Execute the current worksheet buffer against its connection" })

vim.api.nvim_create_user_command("OraWorksheetResult", function()
  require("ora").worksheet_result()
end, { desc = "Run worksheet SQL and show result as a table in a split buffer" })

vim.api.nvim_create_user_command("OraWorksheetFormat", function()
  require("ora").format_worksheet()
end, { desc = "Format the current worksheet SQL using SQLcl" })

vim.api.nvim_create_user_command("OraWorksheetChangeConnection", function()
  require("ora").change_worksheet_connection()
end, { desc = "Change the connection for the current worksheet" })

vim.api.nvim_create_user_command("OraQuickAction", function()
  require("ora").quick_action()
end, { desc = "Find schema objects by pattern and act on them" })

vim.api.nvim_create_user_command("OraExplorer", function()
  local ok = pcall(require, "neo-tree")
  if not ok then
    require("ora.notify").error("ora", "neo-tree.nvim is required for :OraExplorer")
    return
  end
  local ok2, err = pcall(require("neo-tree.command").execute, { source = "ora", position = "left" })
  if not ok2 then
    require("ora.notify").error("ora",
      'Failed to open explorer: ' .. tostring(err) .. '\n'
        .. 'Make sure "ora" is in your neo-tree sources config:\n'
        .. '  require("neo-tree").setup({ sources = { "filesystem", "ora" }, ora = { ... } })')
  end
end, { desc = "Open Oracle connections/schemas explorer" })

vim.api.nvim_create_user_command("OraAddConnection", function(opts)
  -- Accept optional "name url" as a single arg string, or drop into UI
  local args = vim.trim(opts.args)
  if args ~= "" then
    -- Split on the first space: first token = name, rest = url
    local name, url = args:match("^(%S+)%s+(.+)$")
    if not name then
      require("ora.notify").warn("ora", "Usage: :OraAddConnection [name url]")
      return
    end
    require("ora").add_connection(name, url)
  else
    require("ora").add_connection()
  end
end, {
  nargs = "?",
  desc  = "Add a new named connection to the SQLcl connection manager",
})
