-- Quick Action: find schema objects by pattern and act on them.

local Menu = require("nui.menu")
local Input = require("nui.input")

local M = {}

local icons = {
  TABLE            = "󰓫 ",
  VIEW             = "󰡠 ",
  INDEX            = "󰌹 ",
  SYNONYM          = "󰔖 ",
  ["FUNCTION"]     = "󰊕 ",
  PROCEDURE        = "󰡱 ",
  PACKAGE          = "󰏗 ",
  ["PACKAGE BODY"] = "󰏗 ",
}

local actions_by_type = {
  TABLE            = { "Show DDL", "Show data", "Drop" },
  VIEW             = { "Show DDL", "Show data", "Drop" },
  INDEX            = { "Show DDL", "Drop" },
  SYNONYM          = { "Show DDL", "Drop" },
  ["FUNCTION"]     = { "Show body", "Drop" },
  PROCEDURE        = { "Show body", "Drop" },
  PACKAGE          = { "Show specification", "Show body", "Drop" },
  ["PACKAGE BODY"] = { "Show body", "Drop" },
}

---DBMS_METADATA type names (uses underscores, not spaces).
local metadata_types = {
  TABLE            = "TABLE",
  VIEW             = "VIEW",
  INDEX            = "INDEX",
  SYNONYM          = "SYNONYM",
  ["FUNCTION"]     = "FUNCTION",
  PROCEDURE        = "PROCEDURE",
  PACKAGE          = "PACKAGE",
  ["PACKAGE BODY"] = "PACKAGE_BODY",
}

---Strip trailing whitespace, split embedded newlines, return flat list.
---@param raw_lines string[]
---@return string[]
local function clean_lines(raw_lines)
  local buf_lines = {}
  for _, line in ipairs(raw_lines or {}) do
    line = line:gsub("%s+$", "")
    for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
      table.insert(buf_lines, seg)
    end
  end
  -- Trim trailing empty lines
  while #buf_lines > 0 and buf_lines[#buf_lines] == "" do
    table.remove(buf_lines)
  end
  return buf_lines
end

---Create a worksheet, set its content, focus it, and format.
---@param opts { conn_name: string, schema_name: string, object_name: string, ws_suffix: string, display_suffix: string, icon: string, lines: string[] }
local function open_worksheet(opts)
  local ws_mod = require("ora.worksheet")
  local ws_conn = { key = opts.conn_name, label = opts.conn_name, is_named = true }
  local display = opts.schema_name .. "." .. opts.object_name .. " (" .. opts.display_suffix .. ")"
  local ws = ws_mod.create({
    connection   = ws_conn,
    name         = opts.object_name .. "-" .. opts.ws_suffix,
    display_name = display,
    icon         = opts.icon,
  })

  vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, opts.lines)
  vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")

  -- Focus in current window
  vim.api.nvim_win_set_buf(0, ws.bufnr)
  ws_mod.refresh_winbar(ws)

  require("ora.format").run(ws.bufnr, function(_) end)
end

---Execute an action on a selected object.
---@param conn_name string
---@param schema string
---@param object {name: string, object_type: string}
---@param action string
local function execute_action(conn_name, schema, object, action)
  local conn = { key = conn_name, is_named = true }
  local s = require("ora.schema")
  local notify = require("ora.notify")
  local nid = "ora_quick"
  local icon = icons[object.object_type] or "  "
  local otype = object.object_type

  if action == "Show DDL" then
    notify.progress(nid, "Loading DDL…")
    local meta_type = metadata_types[otype] or otype
    s.fetch_object_ddl(conn, meta_type, object.name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load DDL")
        vim.notify("[ora] " .. err, vim.log.levels.ERROR)
        return
      end
      open_worksheet({
        conn_name      = conn_name,
        schema_name    = schema,
        object_name    = object.name,
        ws_suffix      = "ddl",
        display_suffix = otype .. " DDL",
        icon           = icon,
        lines          = clean_lines(lines),
              })
      notify.done(nid, "DDL loaded")
    end)

  elseif action == "Show data" then
    open_worksheet({
      conn_name      = conn_name,
      schema_name    = schema,
      object_name    = object.name,
      ws_suffix      = "data",
      display_suffix = otype .. " Data",
      icon           = icon,
      lines          = { "SELECT * FROM " .. object.name .. ";" },
    })

  elseif action == "Show body" then
    notify.progress(nid, "Loading source…")
    -- Map to DBMS_METADATA type: FUNCTION, PROCEDURE, or PACKAGE_BODY
    local meta_type = otype == "PACKAGE" and "PACKAGE_BODY" or metadata_types[otype] or otype
    s.fetch_object_ddl(conn, meta_type, object.name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load source")
        vim.notify("[ora] " .. err, vim.log.levels.ERROR)
        return
      end
      local suffix = otype == "FUNCTION" and "Function Body"
        or otype == "PROCEDURE" and "Procedure Body"
        or "Package Body"
      open_worksheet({
        conn_name      = conn_name,
        schema_name    = schema,
        object_name    = object.name,
        ws_suffix      = "body",
        display_suffix = suffix,
        icon           = icon,
        lines          = clean_lines(lines),
              })
      notify.done(nid, "Source loaded")
    end)

  elseif action == "Show specification" then
    notify.progress(nid, "Loading source…")
    s.fetch_object_ddl(conn, "PACKAGE_SPEC", object.name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load source")
        vim.notify("[ora] " .. err, vim.log.levels.ERROR)
        return
      end
      open_worksheet({
        conn_name      = conn_name,
        schema_name    = schema,
        object_name    = object.name,
        ws_suffix      = "spec",
        display_suffix = "Package Specification",
        icon           = icon,
        lines          = clean_lines(lines),
              })
      notify.done(nid, "Source loaded")
    end)

  elseif action == "Drop" then
    notify.progress(nid, "Loading DROP DDL…")
    s.fetch_drop_ddl(conn, otype, object.name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load DROP DDL")
        vim.notify("[ora] " .. err, vim.log.levels.ERROR)
        return
      end
      if not lines or #lines == 0 then
        notify.error(nid, "Object not found")
        return
      end
      open_worksheet({
        conn_name      = conn_name,
        schema_name    = schema,
        object_name    = object.name,
        ws_suffix      = "drop",
        display_suffix = "Drop " .. otype:lower(),
        icon           = "󰆴 ",
        lines          = clean_lines(lines),
      })
      notify.done(nid, "DROP DDL loaded")
    end)
  end
end

---Show the actions menu for a selected object.
---@param conn_name string
---@param schema string
---@param object {name: string, object_type: string}
local function show_actions_menu(conn_name, schema, object)
  local available = actions_by_type[object.object_type]
  if not available then return end

  local items = {}
  for _, action in ipairs(available) do
    table.insert(items, Menu.item(action, { action = action }))
  end

  local cfg = require("ora.config").values
  local menu = Menu({
    relative = "editor",
    position = "50%",
    size     = { width = cfg.win_width, height = math.min(cfg.win_height, #items) },
    border   = {
      style = "rounded",
      text  = { top = " " .. object.name .. " ", top_align = "left" },
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
      execute_action(conn_name, schema, object, item.action)
    end,
  })

  local function do_close() menu:unmount() end
  menu:map("n", "q",     do_close, { noremap = true })
  menu:map("n", "<Esc>", do_close, { noremap = true })
  menu:mount()
end

---Show the object picker from search results.
---@param conn_name string
---@param schema string
---@param objects {name: string, object_type: string}[]
local function show_objects_menu(conn_name, schema, objects)
  local items = {}
  for _, obj in ipairs(objects) do
    local icon = icons[obj.object_type] or "  "
    local label = icon .. obj.name
    table.insert(items, Menu.item(label, { object = obj }))
  end

  local cfg = require("ora.config").values
  local menu = Menu({
    relative = "editor",
    position = "50%",
    size     = { width = cfg.win_width, height = math.min(cfg.win_height, #items) },
    border   = {
      style = "rounded",
      text  = { top = " Matching Objects ", top_align = "left" },
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
      show_actions_menu(conn_name, schema, item.object)
    end,
  })

  local function do_close() menu:unmount() end
  menu:map("n", "q",     do_close, { noremap = true })
  menu:map("n", "<Esc>", do_close, { noremap = true })
  menu:mount()
end

---Show the pattern input prompt.
---@param conn_name string
---@param schema string
local function ask_pattern(conn_name, schema)
  local cfg = require("ora.config").values
  local input = Input({
    relative = "editor",
    position = "50%",
    size     = { width = cfg.win_width },
    border   = {
      style = "rounded",
      text  = { top = " Object name pattern ", top_align = "left" },
    },
    enter = true,
  }, {
    prompt = " ",
    on_submit = function(value)
      local pattern = vim.trim(value or "")
      if pattern == "" then return end

      local conn = { key = conn_name, is_named = true }
      local notify = require("ora.notify")
      local nid = "ora_quick"
      notify.progress(nid, "Searching objects…")

      require("ora.schema").fetch_objects_by_pattern(conn, pattern, function(objects, err)
        if err then
          notify.error(nid, "Search failed")
          vim.notify("[ora] " .. err, vim.log.levels.ERROR)
          return
        end

        if not objects or #objects == 0 then
          notify.done(nid, "No objects found")
          vim.notify("[ora] No objects matching '" .. pattern .. "'", vim.log.levels.WARN)
          return
        end

        notify.done(nid, #objects .. " object(s) found")
        show_objects_menu(conn_name, schema, objects)
      end)
    end,
  })

  input:map("n", "q",     function() input:unmount() end, { noremap = true })
  input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })
  input:mount()
end

---Open the quick action flow: pick connection → enter pattern → pick object → pick action.
function M.open()
  require("ora.ui.picker").select(function(conn)
    if not conn then return end

    -- Resolve schema name from connmgr
    local info = require("ora.connmgr").show(conn.key)
    local schema = (info and info.user) or conn.key

    ask_pattern(conn.key, schema)
  end)
end

return M
