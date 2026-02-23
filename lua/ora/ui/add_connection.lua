local M = {}

---Prompt for a connection name then a connection string, then call on_confirm.
---@param on_confirm fun(name: string, url: string)
function M.ask(on_confirm)
  vim.ui.input({ prompt = "Connection name: " }, function(name)
    if not name or name == "" then return end
    vim.ui.input({
      prompt = "Connection string (user[/pass]@host:port/service): ",
    }, function(url)
      if not url or url == "" then return end
      on_confirm(name, url)
    end)
  end)
end

return M
