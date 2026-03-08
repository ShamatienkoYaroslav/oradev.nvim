-- Floating picker that lists all open worksheets.

local Menu = require("nui.menu")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

-- Icon text → highlight group, matching the neo-tree explorer icons.
local icon_highlights = {
  ["󰆼 "]  = "Special",
  ["󰓫 "]  = "Type",
  ["󰡠 "]  = "Type",
  ["󰊕 "]  = "Function",
  ["󰡱 "]  = "Function",
  ["󰏗 "]  = "OraIconPackage",
  ["󰔖 "]  = "Type",
  ["󰌹 "]  = "Number",
  ["󰔚 "]  = "Number",
  ["󰒍 "]  = "Type",
  ["󱐋 "]  = "Keyword",
  ["󰕳 "]  = "Type",
  ["󰆴 "]  = "DiagnosticError",
}

local M = {}

---Open the worksheets picker.
function M.open()
  local worksheets = require("ora.worksheet").list()
  if #worksheets == 0 then
    require("ora.notify").info("ora", "No worksheets open. Use :OraWorksheetNew to create one.")
    return
  end

  local items = {}
  for _, ws in ipairs(worksheets) do
    local icon = ws.icon or "󰆼 "
    local icon_hl = icon_highlights[icon] or "Special"
    local conn = ws.connection and ("  [" .. ws.connection.label .. "]") or "  [no connection]"
    local line = NuiLine({ NuiText(icon, icon_hl), NuiText(ws.name .. conn) })
    table.insert(items, Menu.item(line, { bufnr = ws.bufnr }))
  end

  local menu = Menu({
    relative = "editor",
    position = "50%",
    size     = { width = 64, height = math.min(#items, 20) },
    border   = {
      style = "rounded",
      text  = { top = " Worksheets ", top_align = "left" },
    },
    enter = true,
  }, {
    lines  = items,
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close      = {},
      submit     = { "<CR>" },
    },
    on_close  = function() end,
    on_submit = function(item)
      if vim.api.nvim_buf_is_valid(item.bufnr) then
        vim.api.nvim_set_current_buf(item.bufnr)
      end
    end,
  })

  local function do_close() menu:unmount() end
  menu:map("n", "q",     do_close, { noremap = true })
  menu:map("n", "<Esc>", do_close, { noremap = true })

  menu:on("BufLeave", function()
    vim.schedule(function()
      if menu.winid and vim.api.nvim_win_is_valid(menu.winid) then
        menu:unmount()
      end
    end)
  end)

  menu:mount()
end

return M
