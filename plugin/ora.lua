if vim.g.loaded_ora then return end
vim.g.loaded_ora = true

-- Icon highlight groups (default = true so colorschemes can override)
vim.api.nvim_set_hl(0, "OraIconPackage", { fg = "#d19a66", default = true })

vim.api.nvim_create_user_command("OraOpenSqlcl", function()
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

vim.api.nvim_create_user_command("OraWorksheetExecute", function()
  require("ora").execute_worksheet()
end, { desc = "Execute the current worksheet buffer against its connection" })

vim.api.nvim_create_user_command("OraWorksheetExecuteSelected", function()
  require("ora").execute_worksheet_selected()
end, { desc = "Execute selected SQL or statement at cursor", range = true })

vim.api.nvim_create_user_command("OraWorksheetExplainPlan", function()
  require("ora").explain_worksheet()
end, { desc = "Show explain plan for the worksheet or visual selection", range = true })

vim.api.nvim_create_user_command("OraWorksheetExecutionPlan", function()
  require("ora").execution_plan()
end, { desc = "Show actual execution plan for the worksheet or visual selection", range = true })

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
  -- Find the ora neo-tree window by scanning buffers directly,
  -- since state.winid/bufnr may not be reliably set for custom sources.
  local ora_win = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok_s, src = pcall(vim.api.nvim_buf_get_var, buf, "neo_tree_source")
    if ok_s and src == "ora" then
      ora_win = win
      break
    end
  end
  local args = ora_win
    and { source = "ora", action = "close" }
    or  { source = "ora", action = "focus", position = "left" }
  local ok2, err = pcall(require("neo-tree.command").execute, args)
  if not ok2 then
    require("ora.notify").error("ora",
      'Failed to open explorer: ' .. tostring(err) .. '\n'
        .. 'Make sure "ora" is in your neo-tree sources config:\n'
        .. '  require("neo-tree").setup({ sources = { "filesystem", "ora" }, ora = { ... } })')
  end
end, { desc = "Toggle Oracle connections/schemas explorer" })

