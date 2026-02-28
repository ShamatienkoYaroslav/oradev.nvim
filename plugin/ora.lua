if vim.g.loaded_ora then return end
vim.g.loaded_ora = true

vim.api.nvim_create_user_command("OraConnectionsList", function()
  require("ora").list()
end, { desc = "List saved Oracle connections (from SQLcl connmgr) and connect" })

vim.api.nvim_create_user_command("OraConnect", function(opts)
  local url = opts.args
  if url == "" then
    vim.notify("[ora] Usage: :OraConnect <connection-string>", vim.log.levels.WARN)
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

vim.api.nvim_create_user_command("OraAddConnection", function(opts)
  -- Accept optional "name url" as a single arg string, or drop into UI
  local args = vim.trim(opts.args)
  if args ~= "" then
    -- Split on the first space: first token = name, rest = url
    local name, url = args:match("^(%S+)%s+(.+)$")
    if not name then
      vim.notify("[ora] Usage: :OraAddConnection [name url]", vim.log.levels.WARN)
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
