local Menu = require("nui.menu")

local M = {}

---Open the connection picker.
---Reads available connections from the SQLcl connection manager.
---@param opts? { on_select?: fun(conn: OraWorksheetConn|nil) }
---  When on_select is provided the picker operates in "select" mode:
---  the chosen connection is passed to the callback instead of being
---  connected to directly.  Closing without a selection calls on_select(nil).
function M.open(opts)
  opts = opts or {}
  local names = require("ora.connmgr").list()

  -- Guard: on_select fires at most once
  local on_select = opts.on_select
  local function notify(conn)
    if on_select then on_select(conn); on_select = nil end
  end

  local items = {}
  for _, name in ipairs(names) do
    table.insert(items, Menu.item(name, { kind = "stored", url = name }))
  end
  if #items > 0 then
    table.insert(items, Menu.separator())
  end
  table.insert(items, Menu.item(" Connect with connection string…", { kind = "action_string" }))

  local cfg = require("ora.config").values
  local menu = Menu({
    relative = "editor",
    position = "50%",
    size     = { width = cfg.win_width, height = math.min(cfg.win_height, #items) },
    border   = {
      style = "rounded",
      text  = { top = " Oracle Connections ", top_align = "left" },
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
    on_close  = function() notify(nil) end,
    on_submit = function(item)
      if item.kind == "stored" then
        if opts.on_select then
          notify({ key = item.url, label = item.text, is_named = true })
        else
          require("ora.connection").connect(item.url, item.text, { is_named = true })
        end
      elseif item.kind == "action_string" then
        menu:unmount()
        require("ora.ui.prompt").ask_connection_string(function(url)
          if url and url ~= "" then
            if opts.on_select then
              notify({ key = url, label = url, is_named = false })
            else
              require("ora.connection").connect(url, url)
            end
          else
            notify(nil)
          end
        end)
      end
    end,
  })

  -- q / Esc: close + cancel
  local function do_close() menu:unmount(); notify(nil) end
  menu:map("n", "q",     do_close, { noremap = true })
  menu:map("n", "<Esc>", do_close, { noremap = true })

  -- s: connection-string prompt (not a cancel)
  menu:map("n", "s", function()
    menu:unmount()   -- does NOT call on_close
    require("ora.ui.prompt").ask_connection_string(function(url)
      if url and url ~= "" then
        if opts.on_select then
          notify({ key = url, label = url, is_named = false })
        else
          require("ora.connection").connect(url, url)
        end
      else
        notify(nil)
      end
    end)
  end, { noremap = true })

  -- a: add connection (not a cancel)
  menu:map("n", "a", function()
    menu:unmount()
    require("ora.ui.add_connection").ask(function(name, url)
      local ok, err = require("ora.connmgr").add(name, url)
      if ok then
        vim.notify(("[ora] connection '%s' added"):format(name), vim.log.levels.INFO)
      else
        vim.notify("[ora] failed to add connection: " .. (err or ""), vim.log.levels.ERROR)
      end
    end)
  end, { noremap = true })

  -- BufLeave: auto-close (not a cancel if already acted)
  menu:on("BufLeave", function()
    vim.schedule(function()
      if menu.winid and vim.api.nvim_win_is_valid(menu.winid) then
        menu:unmount(); notify(nil)
      end
    end)
  end)

  menu:mount()
end

---Open the picker in select mode: calls callback(conn) on selection.
---conn is nil when the user cancels without selecting.
---@param callback fun(conn: OraWorksheetConn|nil)
function M.select(callback)
  M.open({ on_select = callback })
end

return M
