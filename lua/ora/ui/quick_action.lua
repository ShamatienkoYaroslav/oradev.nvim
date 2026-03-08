-- Quick Action: find schema objects by pattern and act on them.
-- Uses Snacks.picker for fuzzy object search, nui.menu for action selection.

local Menu = require("nui.menu")

local M = {}

local icons = {
  TABLE               = "󰓫 ",
  VIEW                = "󰡠 ",
  ["MATERIALIZED VIEW"] = "󰡠 ",
  INDEX               = "󰌹 ",
  SYNONYM             = "󰔖 ",
  SEQUENCE            = "󰔚 ",
  TRIGGER             = "󱐋 ",
  TYPE                = "󰕳 ",
  ["TYPE BODY"]       = "󰕳 ",
  ["FUNCTION"]        = "󰊕 ",
  PROCEDURE           = "󰡱 ",
  PACKAGE             = "󰏗 ",
  ["PACKAGE BODY"]    = "󰏗 ",
  ["ORDS MODULE"]     = "󰒍 ",
  ["ORDS TEMPLATE"]   = "󰒍 ",
  ["ORDS HANDLER"]    = "󰒍 ",
}

local icon_hls = {
  TABLE               = "Type",
  VIEW                = "Type",
  ["MATERIALIZED VIEW"] = "Constant",
  INDEX               = "Number",
  SYNONYM             = "Type",
  SEQUENCE            = "Number",
  TRIGGER             = "Keyword",
  TYPE                = "Type",
  ["TYPE BODY"]       = "Type",
  ["FUNCTION"]        = "Function",
  PROCEDURE           = "Function",
  PACKAGE             = "OraIconPackage",
  ["PACKAGE BODY"]    = "OraIconPackage",
  ["ORDS MODULE"]     = "OraIconOrds",
  ["ORDS TEMPLATE"]   = "OraIconOrds",
  ["ORDS HANDLER"]    = "OraIconOrds",
}

local actions_by_type = {
  TABLE               = { "Show DDL", "Show data", "Drop" },
  VIEW                = { "Show DDL", "Show data", "Drop" },
  ["MATERIALIZED VIEW"] = { "Show DDL", "Show data", "Drop" },
  INDEX               = { "Show DDL", "Drop" },
  SYNONYM             = { "Show DDL", "Drop" },
  SEQUENCE            = { "Show DDL", "Drop" },
  TRIGGER             = { "Show DDL", "Drop" },
  TYPE                = { "Show DDL", "Drop" },
  ["TYPE BODY"]       = { "Show DDL", "Drop" },
  ["FUNCTION"]        = { "Show body", "Drop" },
  PROCEDURE           = { "Show body", "Drop" },
  PACKAGE             = { "Show specification", "Show body", "Drop" },
  ["PACKAGE BODY"]    = { "Show body", "Drop" },
  ["ORDS MODULE"]     = { "Show DDL", "Define Module" },
  ["ORDS TEMPLATE"]   = { "Define Template" },
  ["ORDS HANDLER"]    = { "Define Handler", "Show source" },
}

---DBMS_METADATA type names (uses underscores, not spaces).
local metadata_types = {
  TABLE            = "TABLE",
  VIEW             = "VIEW",
  ["MATERIALIZED VIEW"] = "MATERIALIZED_VIEW",
  INDEX            = "INDEX",
  SYNONYM          = "SYNONYM",
  SEQUENCE         = "SEQUENCE",
  TRIGGER          = "TRIGGER",
  TYPE             = "TYPE",
  ["TYPE BODY"]    = "TYPE_BODY",
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

  require("ora.format").run(ws.bufnr, function(err) if err then require("ora.notify").error("ora", "format failed: " .. err) end end)
end

---Create a worksheet for ORDS content (no SCHEMA.NAME prefix in display).
---@param opts { conn_name: string, display: string, ws_name: string, lines: string[] }
local function open_ords_worksheet(opts)
  local ws_mod  = require("ora.worksheet")
  local ws_conn = { key = opts.conn_name, label = opts.conn_name, is_named = true }
  local ws = ws_mod.create({
    connection   = ws_conn,
    name         = opts.ws_name,
    display_name = opts.display,
    icon         = "󰒍 ",
  })
  vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, opts.lines)
  vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
  vim.api.nvim_win_set_buf(0, ws.bufnr)
  ws_mod.refresh_winbar(ws)
  require("ora.format").run(ws.bufnr, function(err) if err then require("ora.notify").error("ora", "format failed: " .. err) end end)
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
        notify.error("ora", err)
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
        notify.error("ora", err)
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
        notify.error("ora", err)
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

  elseif action == "Show DDL" and otype == "ORDS MODULE" then
    notify.progress(nid, "Loading module DDL…")
    s.fetch_ords_export_module(conn, object.name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load module DDL")
        notify.error("ora", err)
        return
      end
      open_ords_worksheet({
        conn_name = conn_name,
        display   = schema .. " ORDS " .. object.name .. " (DDL)",
        ws_name   = "ords-ddl-" .. object.name,
        lines     = clean_lines(lines or {}),
      })
      notify.done(nid, "Module DDL loaded")
    end)

  elseif action == "Define Module" then
    notify.progress(nid, "Loading module details…")
    s.fetch_ords_module_details(conn, object.name, function(d, err)
      if err or not d then
        notify.error(nid, "Failed to load module details")
        if err then notify.error("ora", err) end
        return
      end
      open_ords_worksheet({
        conn_name = conn_name,
        display   = schema .. " ORDS " .. d.name .. " (Define Module)",
        ws_name   = "ords-define-" .. d.name,
        lines = {
          "BEGIN",
          "  ORDS.DEFINE_MODULE(",
          "    p_module_name    => '" .. d.name .. "',",
          "    p_base_path      => '" .. d.uri_prefix .. "',",
          "    p_items_per_page => " .. d.items_per_page .. ",",
          "    p_status         => '" .. d.status .. "',",
          "    p_comments       => " .. (d.comments and ("'" .. d.comments .. "'") or "NULL"),
          "  );",
          "  COMMIT;",
          "END;",
          "/",
        },
      })
      notify.done(nid, "Module DDL loaded")
    end)

  elseif action == "Define Template" then
    notify.progress(nid, "Loading template details…")
    s.fetch_ords_template_details(conn, object.template_id, function(d, err)
      if err or not d then
        notify.error(nid, "Failed to load template details")
        if err then notify.error("ora", err) end
        return
      end
      open_ords_worksheet({
        conn_name = conn_name,
        display   = schema .. " ORDS " .. d.module_name .. " " .. d.uri_template .. " (Define Template)",
        ws_name   = "ords-define-tpl-" .. d.module_name .. "-" .. d.uri_template,
        lines = {
          "BEGIN",
          "  ORDS.DEFINE_TEMPLATE(",
          "    p_module_name    => '" .. d.module_name .. "',",
          "    p_pattern        => '" .. d.uri_template .. "',",
          "    p_priority       => " .. d.priority .. ",",
          "    p_etag_type      => '" .. d.etag_type .. "',",
          "    p_etag_query     => " .. (d.etag_query and ("'" .. d.etag_query .. "'") or "NULL") .. ",",
          "    p_comments       => " .. (d.comments and ("'" .. d.comments .. "'") or "NULL"),
          "  );",
          "  COMMIT;",
          "END;",
          "/",
        },
      })
      notify.done(nid, "Template DDL loaded")
    end)

  elseif action == "Define Handler" then
    notify.progress(nid, "Loading handler details…")
    local results = {}
    local pending = 2
    local function on_done()
      pending = pending - 1
      if pending > 0 then return end
      local d = results.details
      if not d then
        notify.error(nid, "Handler not found")
        return
      end
      local src_lines = results.source or {}
      local lines = {
        "BEGIN",
        "  ORDS.DEFINE_HANDLER(",
        "    p_module_name    => '" .. d.module_name .. "',",
        "    p_pattern        => '" .. d.uri_template .. "',",
        "    p_method         => '" .. d.method .. "',",
        "    p_source_type    => '" .. d.source_type .. "',",
        "    p_mimes_allowed  => " .. (d.mimes_allowed and ("'" .. d.mimes_allowed .. "'") or "NULL") .. ",",
        "    p_comments       => " .. (d.comments and ("'" .. d.comments .. "'") or "NULL") .. ",",
        "    p_source         =>",
      }
      if #src_lines > 0 then
        table.insert(lines, "      q'[")
        for _, sl in ipairs(src_lines) do table.insert(lines, sl) end
        table.insert(lines, "      ]'")
      else
        table.insert(lines, "      NULL")
      end
      vim.list_extend(lines, { "  );", "  COMMIT;", "END;", "/" })
      open_ords_worksheet({
        conn_name = conn_name,
        display   = schema .. " ORDS " .. d.module_name .. " " .. d.uri_template .. " " .. d.method .. " (Define Handler)",
        ws_name   = "ords-define-hdl-" .. d.module_name .. "-" .. d.method,
        lines     = lines,
      })
      notify.done(nid, "Handler DDL loaded")
    end
    s.fetch_ords_handler_details(conn, object.handler_id, function(d, err)
      if not err then
        results.details = d
      else
        notify.error("ora", err)
      end
      on_done()
    end)
    s.fetch_ords_handler_source(conn, object.handler_id, function(src, err)
      if err then notify.error("ora", err) end
      results.source = src or {}
      on_done()
    end)

  elseif action == "Show source" and otype == "ORDS HANDLER" then
    notify.progress(nid, "Loading handler source…")
    s.fetch_ords_handler_source(conn, object.handler_id, function(lines, err)
      if err then
        notify.error(nid, "Failed to load handler source")
        notify.error("ora", err)
        return
      end
      open_ords_worksheet({
        conn_name = conn_name,
        display   = schema .. " ORDS " .. object.module_name .. " " .. object.uri_template .. " " .. object.method .. " (Source)",
        ws_name   = "ords-src-" .. object.module_name .. "-" .. object.method,
        lines     = clean_lines(lines or {}),
      })
      notify.done(nid, "Handler source loaded")
    end)

  elseif action == "Drop" then
    notify.progress(nid, "Loading DROP DDL…")
    s.fetch_drop_ddl(conn, otype, object.name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load DROP DDL")
        notify.error("ora", err)
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

---Show the Snacks.picker for schema objects with fuzzy search.
---@param conn_name string
---@param schema string
---@param objects {name: string, object_type: string}[]
local function show_picker(conn_name, schema, objects)
  local picker_items = {}
  for _, obj in ipairs(objects) do
    local icon = icons[obj.object_type] or "  "
    table.insert(picker_items, {
      text = obj.name .. " " .. obj.object_type,
      object = obj,
      icon = icon,
      icon_hl = icon_hls[obj.object_type] or "Normal",
    })
  end

  Snacks.picker({
    title = "Quick Action",
    items = picker_items,
    format = function(item)
      return {
        { item.icon, item.icon_hl },
        { item.object.name },
        { "  (" .. item.object.object_type .. ")", "Comment" },
      }
    end,
    layout = {
      hidden = { "preview" },
      layout = {
        backdrop = false,
        width = 0.4,
        min_width = 60,
        height = 0.5,
        border = "rounded",
        box = "vertical",
        { win = "input", height = 1, border = "bottom" },
        { win = "list", border = "none" },
      },
    },
    actions = {
      confirm = function(picker, item)
        picker:close()
        if item and item.object then
          vim.schedule(function()
            show_actions_menu(conn_name, schema, item.object)
          end)
        end
      end,
    },
  })
end

---Open the quick action flow: pick connection → fetch all objects → live filter.
function M.open()
  require("ora.ui.picker").select(function(conn)
    if not conn then return end

    -- Resolve schema name from connmgr
    local info = require("ora.connmgr").show(conn.key)
    local schema = (info and info.user) or conn.key

    local notify = require("ora.notify")
    local nid = "ora_quick"
    notify.progress(nid, "Loading schema objects…")

    local s = require("ora.schema")
    local results = {}
    local pending = 4

    local function on_done()
      pending = pending - 1
      if pending > 0 then return end

      local objects = results.objects or {}

      for _, m in ipairs(results.modules or {}) do
        table.insert(objects, {
          name        = m.name,
          object_type = "ORDS MODULE",
          module_name = m.name,
          module_id   = m.id,
        })
      end

      for _, t in ipairs(results.templates or {}) do
        table.insert(objects, {
          name         = t.module_name .. " › " .. t.uri_template,
          object_type  = "ORDS TEMPLATE",
          template_id  = t.id,
          module_name  = t.module_name,
          uri_template = t.uri_template,
        })
      end

      for _, h in ipairs(results.handlers or {}) do
        table.insert(objects, {
          name         = h.module_name .. " › " .. h.uri_template .. " [" .. h.method .. "]",
          object_type  = "ORDS HANDLER",
          handler_id   = h.id,
          module_name  = h.module_name,
          uri_template = h.uri_template,
          method       = h.method,
          source_type  = h.source_type,
        })
      end

      if #objects == 0 then
        notify.done(nid, "No objects found")
        notify.warn("ora", "No schema objects found")
        return
      end

      notify.done(nid, #objects .. " object(s) loaded")
      show_picker(conn.key, schema, objects)
    end

    s.fetch_objects_by_pattern(conn, "%%", function(objects, err)
      if not err then
        results.objects = objects
      else
        notify.error("ora", err)
      end
      on_done()
    end)

    s.fetch_ords_modules(conn, function(modules, err)
      if err then notify.error("ora", err) end
      results.modules = modules or {}
      on_done()
    end)

    s.fetch_all_ords_templates(conn, function(templates, err)
      if err then notify.error("ora", err) end
      results.templates = templates or {}
      on_done()
    end)

    s.fetch_all_ords_handlers(conn, function(handlers, err)
      if err then notify.error("ora", err) end
      results.handlers = handlers or {}
      on_done()
    end)
  end)
end

return M
