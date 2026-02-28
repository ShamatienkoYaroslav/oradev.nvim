local Input = require("nui.input")

local M = {}

---Ask the user for a raw connection string and call callback if one is provided.
---Uses nui.input for a floating input widget.
---@param callback fun(url: string)
function M.ask_connection_string(callback)
  local input = Input({
    relative = "editor",
    position = "50%",
    size     = { width = 60 },
    border   = {
      style = "rounded",
      text  = { top = " SQLcl Connection String ", top_align = "center" },
    },
  }, {
    prompt    = "> ",
    on_submit = function(value)
      if value and value ~= "" then callback(value) end
    end,
    on_close  = function() end,
  })
  input:mount()
end

return M
