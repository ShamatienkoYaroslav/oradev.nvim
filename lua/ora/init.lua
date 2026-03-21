local M = {}

local notify = require("ora.notify")
local _setup_done = false


---Configure the plugin. Must be called before any other ora function.
---
---@param user_config OraConfig
---
---Example:
---  require("ora").setup({
---    sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
---  })
function M.setup(user_config)
  require("ora.config").setup(user_config)
  vim.filetype.add({ pattern = { ["ora://.*"] = "plsql" } })
  require("ora.lsp").setup(require("ora.config").values)
  M._setup_icons()
  _setup_done = true
end

-- Map worksheet icon glyphs to mini.icons highlight groups.
local _icon_hl = {
  ["󰆼"] = "MiniIconsOrange",  -- connection / default
  ["󰓫"] = "MiniIconsCyan",    -- table
  ["󰡠"] = "MiniIconsCyan",    -- view
  ["󰊕"] = "MiniIconsPurple",  -- function
  ["󰡱"] = "MiniIconsPurple",  -- procedure
  ["󰏗"] = "MiniIconsOrange",  -- package
  ["󰔖"] = "MiniIconsCyan",    -- synonym
  ["󰌹"] = "MiniIconsYellow",  -- index
  ["󰔚"] = "MiniIconsYellow",  -- sequence
  ["󰒍"] = "MiniIconsGreen",   -- ords
  ["󱐋"] = "MiniIconsRed",     -- trigger
  ["󰕳"] = "MiniIconsCyan",    -- type
  ["󰆴"] = "MiniIconsRed",     -- drop
}

---Hook into mini.icons so ora:// buffers show per-worksheet icons in pickers.
function M._setup_icons()
  local hooked = false

  local function hook()
    if hooked or not _G.MiniIcons then return end
    hooked = true

    local orig_get = MiniIcons.get
    MiniIcons.get = function(category, name)
      if category == "file" and type(name) == "string" and name:match("^ora://") then
        local ws_mod = package.loaded["ora.worksheet"]
        if ws_mod then
          local bufnr = vim.fn.bufnr(name)
          if bufnr ~= -1 then
            local ws = ws_mod.find(bufnr)
            if ws and ws.icon then
              local glyph = ws.icon:gsub("%s+$", "")
              return glyph, _icon_hl[glyph] or "MiniIconsOrange", false
            end
          end
        end
        return "󰆼", "MiniIconsOrange", false
      end
      if category == "filetype" and name == "plsql" then
        return "󰆼", "MiniIconsOrange", false
      end
      return orig_get(category, name)
    end
  end

  hook()
  if not hooked then
    -- Defer past all VeryLazy handlers so mini.icons has time to set _G.MiniIcons
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      once = true,
      callback = function() vim.schedule(hook) end,
    })
    -- Fallback: lazy.nvim fires LazyLoad each time a plugin loads on-demand
    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyLoad",
      callback = function()
        hook()
        if hooked then return true end
      end,
    })
  end
end

---Show saved connections from the SQLcl connection manager and connect to one.
function M.list()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("ora.ui.picker").open()
end

---Connect directly with a connection string (skips the picker UI).
---@param url string
function M.connect(url)
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("ora.connection").connect(url, url)
end

---Create a new SQL worksheet buffer (no connection prompt).
---The connection can be chosen later when executing the worksheet.
function M.new_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local ws = require("ora.worksheet").create()
  local ws_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(ws_win, ws.bufnr)
end

---Execute the current worksheet SQL and show the result as a formatted table
---in a split below the worksheet. If the buffer has no connection the
---connection picker is shown first.
function M.execute_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr   = vim.api.nvim_get_current_buf()
  local ws_mod  = require("ora.worksheet")
  local ws      = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  -- Hard-object worksheets (TABLE DDL, INDEX DDL, etc.) are not executable.
  if ws.db_object and ws.db_object.kind == "hard" then
    notify.warn("ora", ws.db_object.type .. " worksheet is read-only and cannot be executed")
    return
  end

  local is_soft = ws.db_object and ws.db_object.kind == "soft"

  local function do_run()
    local result = require("ora.result")
    local notify = require("ora.notify")
    local nid = "ora_exec"
    local rbuf = result.get_or_create_buf(ws)
    result.set_buf_lines(rbuf, { "-- running…" })
    result.show(rbuf)
    notify.progress(nid, is_soft and "Compiling…" or "Executing query…")
    result.run(ws, function(raw, err)
      if err then
        local error_output = require("ora.result.error")
        local output = error_output.create({ raw = err })
        result.display(rbuf, output)
        notify.error(nid, is_soft and "Compilation failed" or "Query failed")
        return
      end

      local output
      if is_soft then
        local compile_output = require("ora.result.compile")
        output = compile_output.create({
          raw         = raw,
          object_name = ws.db_object.name,
          object_type = ws.db_object.type,
        })
        if require("ora.result.error").is_error(raw) then
          notify.error(nid, "Compilation failed")
        else
          notify.done(nid, "Compiled successfully")
        end
      else
        local error_output = require("ora.result.error")
        if error_output.is_error(raw) then
          output = error_output.create({ raw = raw })
          notify.error(nid, "Query failed")
        else
          output = require("ora.result.query").create({ raw = raw })
          notify.done(nid, "Query complete")
        end
      end

      local sql = table.concat(vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
      result.push_history(ws, sql, output.lines)
      result.display(rbuf, output)
    end)
  end

  if ws.connection then
    do_run()
  else
    require("ora.ui.picker").select(function(conn)
      if not conn then return end
      ws.connection = conn
      ws_mod.refresh_winbar(ws)
      do_run()
    end)
  end
end

---Format the current worksheet SQL using SQLcl's built-in formatter.
function M.format_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  require("ora.format").run(ws.bufnr, function(err)
    if err then
      notify.error("ora", "format failed: " .. err)
    end
  end)
end

---Change the connection for the current worksheet.
---Opens the connection picker; the selected connection replaces the current one.
function M.change_worksheet_connection()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  require("ora.ui.picker").select(function(conn)
    if not conn then return end
    ws.connection = conn
    ws_mod.refresh_winbar(ws)
  end)
end

---Open the quick action picker: find objects by pattern and act on them.
function M.quick_action()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("ora.ui.quick_action").open()
end

---Open the neo-tree Oracle connections/schemas explorer.
function M.explorer()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("neo-tree.command").execute({ source = "ora", position = "left" })
end

return M
