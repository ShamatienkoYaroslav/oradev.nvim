local Input = require("nui.input")

local M = {}

---Prompt for a connection name then a connection string, then call on_confirm.
---Uses sequential nui.input widgets.
---@param on_confirm fun(name: string, url: string)
function M.ask(on_confirm)
  local name_input = Input({
    relative = "editor",
    position = "50%",
    size     = { width = 50 },
    border   = {
      style = "rounded",
      text  = { top = " Connection Name ", top_align = "center" },
    },
  }, {
    prompt    = "> ",
    on_submit = function(name)
      if not name or name == "" then return end
      local url_input = Input({
        relative = "editor",
        position = "50%",
        size     = { width = 60 },
        border   = {
          style = "rounded",
          text  = { top = " Connection URL ", top_align = "center" },
        },
      }, {
        prompt    = "> ",
        on_submit = function(url)
          if url and url ~= "" then on_confirm(name, url) end
        end,
        on_close  = function() end,
      })
      url_input:mount()
    end,
    on_close = function() end,
  })
  name_input:mount()
end

return M
