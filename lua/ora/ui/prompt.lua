local M = {}

---Ask the user for a raw connection string and connect if one is provided.
---Uses vim.ui.input so it respects any UI overrides (e.g. dressing.nvim).
---@param on_confirm fun(url: string)
function M.ask_connection_string(on_confirm)
  vim.ui.input({
    prompt = "SQLcl connection string: ",
    default = "",
    completion = "file",
  }, function(input)
    if input == nil or input == "" then
      return
    end
    on_confirm(input)
  end)
end

return M
