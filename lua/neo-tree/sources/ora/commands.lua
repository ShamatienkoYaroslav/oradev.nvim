-- Commands (keybindings) for the ora neo-tree source.

local cc = require("neo-tree.sources.common.commands")
local utils = require("neo-tree.utils")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")

local notify = require("ora.notify")

---@class neotree.sources.Ora.Commands : neotree.sources.Common.Commands
local M = {}

local refresh = utils.wrap(manager.refresh, "ora")

---Resolve the schema (Oracle user) name for a connection, falling back to connection name.
---@param state table
---@param conn_name string
---@return string
local function schema_name(state, conn_name)
  return state.ora_schema and state.ora_schema[conn_name] or conn_name
end

---Open a worksheet buffer in the first non-neo-tree window.
---@param ws table  worksheet object (must have .bufnr)
local function open_ws_in_main(ws)
  local ws_mod = require("ora.worksheet")
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local target_win
  for _, win in ipairs(wins) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local bname = vim.api.nvim_buf_get_name(buf)
      if not bname:match("neo%-tree") then
        target_win = win
        break
      end
    end
  end
  if target_win then
    vim.api.nvim_win_set_buf(target_win, ws.bufnr)
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("wincmd l")
    vim.api.nvim_win_set_buf(0, ws.bufnr)
  end
  ws_mod.refresh_winbar(ws)
end

---Format the content of a worksheet buffer using SQLcl's formatter.
---@param bufnr integer
local function format_buffer(bufnr)
  local format = require("ora.format")
  format.run(bufnr, function(err) if err then notify.error("ora", "format failed: " .. err) end end)
end

---Fetch a DROP DDL statement from the database and open it in a worksheet.
---@param state table
---@param conn_name string
---@param object_name string
---@param object_type string  e.g. "TABLE", "PACKAGE", "PACKAGE BODY", "FUNCTION", "PROCEDURE", "VIEW"
local function open_drop_worksheet(state, conn_name, object_name, object_type)
  local schema = require("ora.schema")
  local conn   = { key = conn_name, is_named = true }

  local nid    = "ora_open"
  notify.progress(nid, "Loading DROP DDL…")

  schema.fetch_drop_ddl(conn, object_type, object_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to load DROP DDL")
      notify.error("ora", err)
      return
    end

    if not lines or #lines == 0 then
      notify.error(nid, "Object not found")
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. object_name .. " (Drop " .. object_type:lower() .. ")"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = object_name .. "-drop",
      display_name = display,
      icon         = "󰆴 ",
      db_object    = { name = object_name, type = object_type, schema = schema_name(state, conn_name), kind = require("ora.worksheet").object_kind(object_type) },
    })

    local buf_lines = {}
    for _, line in ipairs(lines) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "DROP DDL loaded")
  end)
end

---Show a small nui.menu popup for picking an action (no search input).
---@param title string  popup title
---@param actions string[]  list of action labels
---@param on_choice fun(choice: string)  called with the selected label
local function action_picker(title, actions, on_choice)
  local Menu = require("nui.menu")
  local items = {}
  for _, a in ipairs(actions) do
    table.insert(items, Menu.item(a))
  end
  local menu = Menu({
    relative = "cursor",
    position = { row = 1, col = 0 },
    size     = { width = 30 },
    border   = {
      style = "rounded",
      text  = { top = " " .. title .. " ", top_align = "left" },
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
    on_submit = function(item)
      on_choice(item.text)
    end,
  })
  local function do_close() menu:unmount() end
  menu:map("n", "q",     do_close, { noremap = true })
  menu:map("n", "<Esc>", do_close, { noremap = true })
  menu:mount()
end

---Toggle a connection (connect + expand), or expand/collapse a category
---with lazy loading of schema children.
M.toggle_node = function(state)
  local tree = state.tree
  local node = tree:get_node()
  if not node then return end

  if node.type == "connection" then
    M._toggle_connection(state, node)
  elseif node.type == "category" then
    M._toggle_category(state, node)
  elseif node.type == "table" then
    M._toggle_table(state, node)
  elseif node.type == "view" then
    M._toggle_view(state, node)
  elseif node.type == "mview" then
    M._toggle_mview(state, node)
  elseif node.type == "function" or node.type == "procedure" then
    M._toggle_func_or_proc(state, node)
  elseif node.type == "package" then
    M._toggle_package(state, node)
  elseif node.type == "ora_type" then
    M._toggle_type(state, node)
  elseif node.type == "subprogram" then
    M._toggle_subprogram(state, node)
  elseif node.type == "scheduler_job" then
    M._toggle_scheduler_job(state, node)
  elseif node.type == "scheduler_program" then
    M._toggle_scheduler_program(state, node)
  elseif node.type == "ords_module" then
    M._toggle_ords_module(state, node)
  elseif node.type == "ords_template" then
    M._toggle_ords_template(state, node)
  elseif node.type == "ords_handler" then
    M._toggle_ords_handler(state, node)
  elseif node:has_children() then
    -- package nodes etc — simple expand/collapse
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    renderer.redraw(state)
  end
end

---Connect/disconnect a connection node.
M._toggle_connection = function(state, node)
  local name = node.extra.key
  if not state.ora_connected then state.ora_connected = {} end
  if not state.ora_children then state.ora_children = {} end

  if state.ora_connected[name] then
    -- Already connected — just toggle expand/collapse
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    renderer.redraw(state)
    return
  end

  -- Mark as connected — schema queries use the connmgr name directly
  state.ora_connected[name] = true

  -- Show loading state (spinner icon + "…" suffix in the tree)
  node.extra.loading = true
  renderer.redraw(state)


  local nid = "ora_conn"
  notify.progress(nid, "Connecting to " .. name .. "…")

  -- Defer the blocking connmgr.show() call so the spinner notification
  -- and loading indicator get a chance to render before the main loop is blocked.
  vim.schedule(function()
    -- Cache the schema (Oracle user) name for display
    if not state.ora_schema then state.ora_schema = {} end
    local info = require("ora.connmgr").show(name)
    if info and info.user then
      state.ora_schema[name] = info.user
    end

    node.extra.loading = false

    -- Rebuild and re-navigate to show category stubs
    local ora_source = require("neo-tree.sources.ora")
    ora_source.navigate(state)

    -- Expand the connection node to reveal categories
    if state.tree then
      local conn_node = state.tree:get_node("conn:" .. name)
      if conn_node then
        conn_node:expand()
        renderer.redraw(state)
      end
    end

    notify.done(nid, "Connected to " .. name)
  end)
end

---Expand/collapse a category node, lazy-loading children on first expand.
M._toggle_category = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  -- If children are already loaded, just expand
  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  -- Lazy-load children from schema
  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local category = node.extra.category
  local conn = { key = conn_name, is_named = true }

  local fetch_fn, build_fn

  if category == "tables" then
    fetch_fn = function(cb) schema.fetch_tables_with_comments(conn, cb) end
    build_fn = function(tables) return items.make_table_children(conn_name, tables) end
  elseif category == "views" then
    fetch_fn = function(cb) schema.fetch_views_with_comments(conn, cb) end
    build_fn = function(views) return items.make_view_children(conn_name, views) end
  elseif category == "mviews" then
    fetch_fn = function(cb) schema.fetch_mviews(conn, cb) end
    build_fn = function(mviews) return items.make_mview_children(conn_name, mviews) end
  elseif category == "mview_logs" then
    fetch_fn = function(cb) schema.fetch_mview_logs(conn, cb) end
    build_fn = function(logs) return items.make_mview_log_children(conn_name, logs) end
  elseif category == "functions" then
    fetch_fn = function(cb) schema.fetch_functions_with_return_type(conn, cb) end
    build_fn = function(funcs) return items.make_function_children(conn_name, funcs) end
  elseif category == "procedures" then
    fetch_fn = function(cb) schema.fetch_procedures(conn, cb) end
    build_fn = function(names) return items.make_procedure_children(conn_name, names) end
  elseif category == "packages" then
    fetch_fn = function(cb) schema.fetch_packages(conn, cb) end
    build_fn = function(pkgs) return items.make_package_children(conn_name, pkgs) end
  elseif category == "indexes" then
    fetch_fn = function(cb) schema.fetch_all_indexes(conn, cb) end
    build_fn = function(indexes) return items.make_schema_index_children(conn_name, indexes) end
  elseif category == "synonyms" then
    fetch_fn = function(cb) schema.fetch_synonyms(conn, cb) end
    build_fn = function(synonyms) return items.make_synonym_children(conn_name, synonyms) end
  elseif category == "triggers" then
    fetch_fn = function(cb) schema.fetch_triggers(conn, cb) end
    build_fn = function(triggers) return items.make_trigger_children(conn_name, triggers) end
  elseif category == "types" then
    fetch_fn = function(cb) schema.fetch_types(conn, cb) end
    build_fn = function(types) return items.make_type_children(conn_name, types) end
  elseif category == "sequences" then
    fetch_fn = function(cb) schema.fetch_sequences(conn, cb) end
    build_fn = function(sequences) return items.make_sequence_children(conn_name, sequences) end
  elseif category == "dbms_scheduler" then
    -- Static sub-categories, no fetch needed
    local children = items.make_dbms_scheduler_children(conn_name)
    M._set_category_children(state, node, conn_name, children)
    return
  elseif category == "scheduler_jobs" then
    fetch_fn = function(cb) schema.fetch_scheduler_jobs(conn, cb) end
    build_fn = function(jobs) return items.make_scheduler_job_children(conn_name, jobs) end
  elseif category == "scheduler_programs" then
    fetch_fn = function(cb) schema.fetch_scheduler_programs(conn, cb) end
    build_fn = function(programs) return items.make_scheduler_program_children(conn_name, programs) end
  elseif category == "ords" then
    fetch_fn = function(cb) schema.fetch_ords_modules(conn, cb) end
    build_fn = function(modules) return items.make_ords_module_children(conn_name, modules) end
  end

  if not fetch_fn then return end

  -- Show loading state
  node.extra.loading = true
  renderer.redraw(state)

  fetch_fn(function(names, err)
    node.extra.loading = false
    if err then
      notify.error("ora", err)
      renderer.redraw(state)
      return
    end
    local children = build_fn(names or {})
    M._set_category_children(state, node, conn_name, children)
  end)
end

---Expand/collapse a table node, lazy-loading columns/indexes/constraints/comments.
M._toggle_table = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  -- Show loading state
  node.extra.loading = true
  renderer.redraw(state)

  -- Fetch all five types in parallel, merge when all complete
  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local table_name = node.extra.table_name
  local conn = { key = conn_name, is_named = true }

  local results = {}
  local pending = 5

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end

    node.extra.loading = false

    -- Merge column comments into column nodes
    if results.col_comments and #results.col_comments > 0 then
      local cmt_map = {}
      for _, c in ipairs(results.col_comments) do
        cmt_map[c.column] = c.text
      end
      for _, col_node in ipairs(results.columns or {}) do
        local cmt = cmt_map[col_node.name]
        if cmt then
          col_node.extra.comment = cmt
        end
      end
    end

    local children = {}
    for _, c in ipairs(results.columns or {}) do table.insert(children, c) end
    for _, c in ipairs(results.indexes or {}) do table.insert(children, c) end
    for _, c in ipairs(results.constraints or {}) do table.insert(children, c) end
    for _, c in ipairs(results.triggers or {}) do table.insert(children, c) end

    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_columns_with_types(conn, table_name, function(cols, err)
    if not err then
      results.columns = items.make_column_children(conn_name, table_name, cols or {})
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_indexes(conn, table_name, function(names, err)
    if not err then
      results.indexes = items.make_index_children(conn_name, table_name, names or {})
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_constraints(conn, table_name, function(names, err)
    if not err then
      results.constraints = items.make_constraint_children(conn_name, table_name, names or {})
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_comments(conn, table_name, function(comments, err)
    if not err then
      results.col_comments = comments or {}
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_triggers_for_table(conn, table_name, function(triggers, err)
    if not err then
      results.triggers = items.make_trigger_children(conn_name, triggers or {})
    else
      notify.error("ora", err)
    end
    on_done()
  end)
end

---Expand/collapse a view node, lazy-loading columns and DDL action.
M._toggle_view = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local view_name = node.extra.view_name
  local conn = { key = conn_name, is_named = true }

  local results = {}
  local pending = 2

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end

    node.extra.loading = false

    -- Merge column comments into column nodes
    if results.col_comments and #results.col_comments > 0 then
      local cmt_map = {}
      for _, c in ipairs(results.col_comments) do
        cmt_map[c.column] = c.text
      end
      for _, col_node in ipairs(results.columns or {}) do
        local cmt = cmt_map[col_node.name]
        if cmt then
          col_node.extra.comment = cmt
        end
      end
    end

    local children = {}
    for _, c in ipairs(results.columns or {}) do table.insert(children, c) end

    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_columns_with_types(conn, view_name, function(cols, err)
    if not err then
      results.columns = items.make_column_children(conn_name, view_name, cols or {})
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_comments(conn, view_name, function(comments, err)
    if not err then
      results.col_comments = comments or {}
    else
      notify.error("ora", err)
    end
    on_done()
  end)
end

---Expand/collapse a materialized view node, lazy-loading columns.
M._toggle_mview = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name  = node.extra.conn_name
  local mview_name = node.extra.mview_name
  local conn = { key = conn_name, is_named = true }

  local results = {}
  local pending = 2

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end

    node.extra.loading = false

    -- Merge column comments into column nodes
    if results.col_comments and #results.col_comments > 0 then
      local cmt_map = {}
      for _, c in ipairs(results.col_comments) do
        cmt_map[c.column] = c.text
      end
      for _, col_node in ipairs(results.columns or {}) do
        local cmt = cmt_map[col_node.name]
        if cmt then
          col_node.extra.comment = cmt
        end
      end
    end

    local children = {}
    for _, c in ipairs(results.columns or {}) do table.insert(children, c) end

    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_columns_with_types(conn, mview_name, function(cols, err)
    if not err then
      results.columns = items.make_column_children(conn_name, mview_name, cols or {})
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_comments(conn, mview_name, function(comments, err)
    if not err then
      results.col_comments = comments or {}
    else
      notify.error("ora", err)
    end
    on_done()
  end)
end

---Open the DDL or data of a materialized view in a new worksheet.
M._open_mview_action = function(state, node)
  local conn_name  = node.extra.conn_name
  local mview_name = node.extra.mview_name
  local action     = node.extra.action

  local ws_mod  = require("ora.worksheet")
  local ws_conn = { key = conn_name, label = conn_name, is_named = true }

  if action == "data" then
    local display = schema_name(state, conn_name) .. "." .. mview_name .. " (Materialized View Data)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = mview_name .. "-data",
      display_name = display,
      icon         = "󰡠 ",
      db_object    = { name = mview_name, type = "MATERIALIZED VIEW", schema = schema_name(state, conn_name), kind = "hard" },
    })
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, { "SELECT * FROM " .. mview_name .. ";" })
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
  else
    -- DDL
  
    local nid = "ora_open"
    notify.progress(nid, "Loading materialized view DDL…")
    local conn = { key = conn_name, is_named = true }
    require("ora.schema").fetch_object_ddl(conn, "MATERIALIZED_VIEW", mview_name, function(lines, err)
      if err then
        notify.error(nid, "Failed to load DDL")
        notify.error("ora", err)
        return
      end
      local display = schema_name(state, conn_name) .. "." .. mview_name .. " (Materialized View DDL)"
      local ws = ws_mod.create({
        connection   = ws_conn,
        name         = mview_name .. "-ddl",
        display_name = display,
        icon         = "󰡠 ",
        db_object    = { name = mview_name, type = "MATERIALIZED VIEW", schema = schema_name(state, conn_name), kind = "hard" },
      })
      local buf_lines = {}
      for _, line in ipairs(lines or {}) do
        line = line:gsub("%s+$", "")
        for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
          table.insert(buf_lines, seg)
        end
      end
      vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
      vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
      open_ws_in_main(ws)
      format_buffer(ws.bufnr)
      notify.done(nid, "Materialized view DDL loaded")
    end)
  end
end

---Open the DDL of a materialized view log in a new worksheet.
M._open_mview_log_ddl = function(state, node)
  local conn_name = node.extra.conn_name
  local log_table = node.extra.log_table
  local master    = node.extra.master
  local conn      = { key = conn_name, is_named = true }
  local notify    = require("ora.notify")
  local nid       = "ora_open"
  notify.progress(nid, "Loading materialized view log DDL…")

  require("ora.schema").fetch_object_ddl(conn, "MATERIALIZED_VIEW_LOG", master, function(lines, err)
    if err then
      notify.error(nid, "Failed to load DDL")
      notify.error("ora", err)
      return
    end
    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. log_table .. " (Materialized View Log DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = log_table .. "-ddl",
      display_name = display,
      icon         = "󰩼 ",
      db_object    = { name = log_table, type = "MATERIALIZED VIEW LOG", schema = schema_name(state, conn_name), kind = "hard" },
    })
    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Materialized view log DDL loaded")
  end)
end

---Open the DDL of a view in a new worksheet.
M._open_view_action = function(state, node)
  local conn_name = node.extra.conn_name
  local view_name = node.extra.view_name
  local action    = node.extra.action

  local ws_mod  = require("ora.worksheet")
  local ws_conn = { key = conn_name, label = conn_name, is_named = true }

  if action == "ddl" then
    node.extra.loading = true
    renderer.redraw(state)

    local schema = require("ora.schema")
    local conn = { key = conn_name, is_named = true }

  
    local nid = "ora_open"
    notify.progress(nid, "Loading view DDL…")

    schema.fetch_view_ddl(conn, view_name, function(lines, err)
      node.extra.loading = false
      renderer.redraw(state)

      if err then
        notify.error(nid, "Failed to load view DDL")
        notify.error("ora", err)
        return
      end

      local display = schema_name(state, conn_name) .. "." .. view_name .. " (View DDL)"
      local ws = ws_mod.create({
        connection   = ws_conn,
        name         = view_name .. "-ddl",
        display_name = display,
        icon         = "󰡠 ",
        db_object    = { name = view_name, type = "VIEW", schema = schema_name(state, conn_name), kind = "soft" },
      })

      local buf_lines = {}
      for _, line in ipairs(lines or {}) do
        line = line:gsub("%s+$", "")
        for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
          table.insert(buf_lines, seg)
        end
      end
      vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
      vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
      open_ws_in_main(ws)
      format_buffer(ws.bufnr)
      notify.done(nid, "View DDL loaded")
    end)
  elseif action == "data" then
    local display = schema_name(state, conn_name) .. "." .. view_name .. " (View Data)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = view_name .. "-data",
      display_name = display,
      icon         = "󰡠 ",
      db_object    = { name = view_name, type = "VIEW", schema = schema_name(state, conn_name), kind = "soft" },
    })
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, { "SELECT * FROM " .. view_name .. ";" })
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
  end
end

---Open a table DDL or Data worksheet.
M._open_table_action = function(state, node)
  local conn_name  = node.extra.conn_name
  local table_name = node.extra.table_name
  local action     = node.extra.action

  local ws_mod  = require("ora.worksheet")
  local ws_conn = { key = conn_name, label = conn_name, is_named = true }

  local function open_in_main(ws)
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local target_win
    for _, win in ipairs(wins) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "" then
        local buf = vim.api.nvim_win_get_buf(win)
        local bname = vim.api.nvim_buf_get_name(buf)
        if not bname:match("neo%-tree") then
          target_win = win
          break
        end
      end
    end
    if target_win then
      vim.api.nvim_win_set_buf(target_win, ws.bufnr)
      vim.api.nvim_set_current_win(target_win)
    else
      vim.cmd("wincmd l")
      vim.api.nvim_win_set_buf(0, ws.bufnr)
    end
    ws_mod.refresh_winbar(ws)
  end

  if action == "ddl" then
    node.extra.loading = true
    renderer.redraw(state)

    local schema = require("ora.schema")
    local conn = { key = conn_name, is_named = true }
  
    local nid = "ora_open"
    notify.progress(nid, "Loading DDL…")

    schema.fetch_ddl(conn, table_name, function(lines, err)
      node.extra.loading = false
      renderer.redraw(state)

      if err then
        notify.error(nid, "Failed to load DDL")
        notify.error("ora", err)
        return
      end

      local display = schema_name(state, conn_name) .. "." .. table_name .. " (Table DDL)"
      local ws = ws_mod.create({
        connection   = ws_conn,
        name         = table_name .. "-ddl",
        display_name = display,
        icon         = "󰓫 ",
        db_object    = { name = table_name, type = "TABLE", schema = schema_name(state, conn_name), kind = "hard" },
      })

      local buf_lines = {}
      for _, line in ipairs(lines or {}) do
        line = line:gsub("%s+$", "")
        for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
          table.insert(buf_lines, seg)
        end
      end
      vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
      vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
      open_in_main(ws)
      format_buffer(ws.bufnr)
      notify.done(nid, "DDL loaded")
    end)
  elseif action == "data" then
    local display = schema_name(state, conn_name) .. "." .. table_name .. " (Table Data)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = table_name .. "-data",
      display_name = display,
      icon         = "󰓫 ",
      db_object    = { name = table_name, type = "TABLE", schema = schema_name(state, conn_name), kind = "hard" },
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, { "SELECT * FROM " .. table_name .. ";" })
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_in_main(ws)
    format_buffer(ws.bufnr)
  end
end

---Open the DDL of a synonym in a new worksheet.
M._open_synonym_ddl = function(state, node)
  local conn_name    = node.extra.conn_name
  local synonym_name = node.extra.synonym_name
  local conn = { key = conn_name, is_named = true }


  local nid    = "ora_open"
  notify.progress(nid, "Loading synonym DDL…")

  local schema = require("ora.schema")
  schema.fetch_synonym_ddl(conn, synonym_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to load synonym DDL")
      notify.error("ora", err)
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. synonym_name .. " (Synonym DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = synonym_name .. "-ddl",
      display_name = display,
      icon         = "󰔖 ",
      db_object    = { name = synonym_name, type = "SYNONYM", schema = schema_name(state, conn_name), kind = "soft" },
    })

    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Synonym DDL loaded")
  end)
end

---Fetch sequence DDL via DBMS_METADATA and open in a worksheet.
M._open_sequence_ddl = function(state, node)
  local conn_name     = node.extra.conn_name
  local sequence_name = node.extra.sequence_name
  local conn = { key = conn_name, is_named = true }


  local nid    = "ora_open"
  notify.progress(nid, "Loading sequence DDL…")

  local schema = require("ora.schema")
  schema.fetch_object_ddl(conn, "SEQUENCE", sequence_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to load sequence DDL")
      notify.error("ora", err)
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. sequence_name .. " (Sequence DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = sequence_name .. "-ddl",
      display_name = display,
      icon         = "󰔚 ",
      db_object    = { name = sequence_name, type = "SEQUENCE", schema = schema_name(state, conn_name), kind = "hard" },
    })

    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Sequence DDL loaded")
  end)
end

---Open the DDL of an index in a new worksheet.
M._open_index_ddl = function(state, node)
  local conn_name  = node.extra.conn_name
  local index_name = node.extra.index_name
  local conn = { key = conn_name, is_named = true }


  local nid    = "ora_open"
  notify.progress(nid, "Loading index DDL…")

  local schema = require("ora.schema")
  schema.fetch_index_ddl(conn, index_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to load index DDL")
      notify.error("ora", err)
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. index_name .. " (Index DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = index_name .. "-ddl",
      display_name = display,
      icon         = "󰌹 ",
      db_object    = { name = index_name, type = "INDEX", schema = schema_name(state, conn_name), kind = "hard" },
    })

    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Index DDL loaded")
  end)
end

---Open the source code of a package spec or body in a new worksheet.
M._open_package_source = function(state, node)
  local conn_name = node.extra.conn_name
  local pkg_name = node.extra.pkg_name
  local part = node.extra.part
  local metadata_type = part == "spec" and "PACKAGE_SPEC" or "PACKAGE_BODY"

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local conn = { key = conn_name, is_named = true }

  local nid = "ora_open"
  notify.progress(nid, "Loading package source…")

  schema.fetch_object_ddl(conn, metadata_type, pkg_name, function(lines, err)
    node.extra.loading = false
    renderer.redraw(state)

    if err then
      notify.error(nid, "Failed to load package source")
      notify.error("ora", err)
      return
    end

    -- Create a worksheet with the connection pre-set
    local ws_mod = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local part_label = part == "spec" and "Package Specification" or "Package Body"
    local display = schema_name(state, conn_name) .. "." .. pkg_name .. " (" .. part_label .. ")"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = pkg_name .. "-" .. part,
      display_name = display,
      icon         = "󰏗 ",
      db_object    = { name = pkg_name, type = part == "spec" and "PACKAGE" or "PACKAGE BODY", schema = schema_name(state, conn_name), kind = "soft" },
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines or {})
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")

    -- Focus the worksheet in the main editing area (not the neo-tree window)
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local target_win
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype ~= "neo-tree" then
        target_win = win
        break
      end
    end

    if target_win then
      vim.api.nvim_set_current_win(target_win)
      vim.api.nvim_win_set_buf(target_win, ws.bufnr)
    else
      vim.cmd("wincmd l")
      vim.api.nvim_win_set_buf(0, ws.bufnr)
    end

    ws_mod.refresh_winbar(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Package source loaded")
  end)
end

---Expand/collapse a package node, lazy-loading subprograms.
M._toggle_package = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local pkg_name = node.extra.pkg_name
  local conn = { key = conn_name, is_named = true }

  local results = {}
  local pending = 2

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end

    node.extra.loading = false
    node.extra.has_body = results.has_body
    local children = {}
    for _, sub in ipairs(results.subprograms or {}) do
      table.insert(children, {
        id       = "sub:" .. conn_name .. ":" .. pkg_name .. ":" .. sub.name,
        name     = sub.name,
        type     = "subprogram",
        path     = conn_name .. "/Packages/" .. pkg_name .. "/" .. sub.name,
        children = {},
        extra    = { conn_name = conn_name, pkg_name = pkg_name, subprogram = sub.name, return_type = sub.return_type, loaded = false },
      })
    end
    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_package_has_body(conn, pkg_name, function(has_body, err)
    results.has_body = has_body and not err
    on_done()
  end)

  schema.fetch_package_subprograms_with_types(conn, pkg_name, function(subs, err)
    if not err then
      results.subprograms = subs or {}
    else
      notify.error("ora", err)
    end
    on_done()
  end)
end

---Open the source code of a type spec or body in a new worksheet.
M._open_type_source = function(state, node)
  local conn_name = node.extra.conn_name
  local type_name = node.extra.type_name
  local part = node.extra.part
  local metadata_type = part == "spec" and "TYPE_SPEC" or "TYPE_BODY"

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local conn = { key = conn_name, is_named = true }

  local nid = "ora_open"
  notify.progress(nid, "Loading type source…")

  schema.fetch_object_ddl(conn, metadata_type, type_name, function(lines, err)
    node.extra.loading = false
    renderer.redraw(state)

    if err then
      notify.error(nid, "Failed to load type source")
      notify.error("ora", err)
      return
    end

    local ws_mod = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local part_label = part == "spec" and "Type Specification" or "Type Body"
    local display = schema_name(state, conn_name) .. "." .. type_name .. " (" .. part_label .. ")"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = type_name .. "-" .. part,
      display_name = display,
      icon         = "󰕳 ",
      db_object    = { name = type_name, type = part == "spec" and "TYPE" or "TYPE BODY", schema = schema_name(state, conn_name), kind = "soft" },
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines or {})
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Type source loaded")
  end)
end

---Expand/collapse a type node, lazy-loading methods.
M._toggle_type = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local type_name = node.extra.type_name
  local conn = { key = conn_name, is_named = true }

  local results = {}
  local pending = 2

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end

    node.extra.loading = false
    node.extra.has_body = results.has_body
    local children = {}
    for _, sub in ipairs(results.subprograms or {}) do
      table.insert(children, {
        id       = "sub:" .. conn_name .. ":" .. type_name .. ":" .. sub.name,
        name     = sub.name,
        type     = "subprogram",
        path     = conn_name .. "/Types/" .. type_name .. "/" .. sub.name,
        children = {},
        extra    = { conn_name = conn_name, pkg_name = type_name, subprogram = sub.name, return_type = sub.return_type, loaded = false },
      })
    end
    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_type_has_body(conn, type_name, function(has_body, err)
    results.has_body = has_body and not err
    on_done()
  end)

  schema.fetch_package_subprograms_with_types(conn, type_name, function(subs, err)
    if not err then
      results.subprograms = subs or {}
    else
      notify.error("ora", err)
    end
    on_done()
  end)
end

---Expand/collapse a standalone function or procedure node, lazy-loading parameters.
M._toggle_func_or_proc = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name   = node.extra.conn_name
  local object_name = node.extra.object_name
  local conn = { key = conn_name, is_named = true }

  schema.fetch_object_params(conn, object_name, function(params, err)
    node.extra.loading = false
    if err then
      notify.error("ora", err)
      renderer.redraw(state)
      return
    end
    local children = {}
    for _, p in ipairs(items.make_object_parameter_children(conn_name, object_name, params or {})) do
      table.insert(children, p)
    end
    M._set_category_children(state, node, conn_name, children)
  end)
end

---Open the source code of a standalone function or procedure in a new worksheet.
M._open_object_source = function(state, node)
  local conn_name   = node.extra.conn_name
  local object_name = node.extra.object_name
  local object_type = node.extra.object_type

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local conn = { key = conn_name, is_named = true }

  local nid = "ora_open"
  notify.progress(nid, "Loading source…")

  schema.fetch_object_ddl(conn, object_type, object_name, function(lines, err)
    node.extra.loading = false
    renderer.redraw(state)

    if err then
      notify.error(nid, "Failed to load source")
      notify.error("ora", err)
      return
    end

    local ws_mod = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local icon_map  = { FUNCTION = "󰊕 ", PROCEDURE = "󰡱 ", TRIGGER = "󱐋 ", TYPE = "󰕳 " }
    local label_map = { FUNCTION = "Function Body", PROCEDURE = "Procedure Body", TRIGGER = "Trigger Source", TYPE = "Type Source" }
    local icon = icon_map[object_type] or "󰡱 "
    local type_label = label_map[object_type] or (object_type:sub(1,1) .. object_type:sub(2):lower() .. " Body")
    local display = schema_name(state, conn_name) .. "." .. object_name .. " (" .. type_label .. ")"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = object_name .. "-body",
      display_name = display,
      icon         = icon,
      db_object    = { name = object_name, type = object_type, schema = schema_name(state, conn_name), kind = require("ora.worksheet").object_kind(object_type) },
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines or {})
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")

    local wins = vim.api.nvim_tabpage_list_wins(0)
    local target_win
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype ~= "neo-tree" then
        target_win = win
        break
      end
    end
    if target_win then
      vim.api.nvim_set_current_win(target_win)
      vim.api.nvim_win_set_buf(target_win, ws.bufnr)
    else
      vim.cmd("wincmd l")
      vim.api.nvim_win_set_buf(0, ws.bufnr)
    end
    ws_mod.refresh_winbar(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Source loaded")
  end)
end

---Expand/collapse a subprogram node, lazy-loading parameters.
M._toggle_subprogram = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local pkg_name = node.extra.pkg_name
  local sub_name = node.extra.subprogram
  local conn = { key = conn_name, is_named = true }

  schema.fetch_subprogram_params(conn, pkg_name, sub_name, function(params, err)
    node.extra.loading = false
    if err then
      notify.error("ora", err)
      renderer.redraw(state)
      return
    end
    local children = items.make_parameter_children(conn_name, pkg_name, sub_name, params or {})
    M._set_category_children(state, node, conn_name, children)
  end)
end

---Expand/collapse a scheduler job node, creating DDL action child on first expand.
M._toggle_scheduler_job = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  local conn_name = node.extra.conn_name
  local job_name  = node.extra.job_name

  local children = {
    {
      id       = "sjob_action:" .. conn_name .. ":" .. job_name .. ":ddl",
      name     = "DDL",
      type     = "source_action",
      path     = conn_name .. "/DBMS Scheduler/Jobs/" .. job_name .. "/DDL",
      children = {},
      extra    = { conn_name = conn_name, object_name = job_name, object_type = "PROCOBJ" },
    },
  }

  M._set_category_children(state, node, conn_name, children)
end

---Open the DDL of a scheduler job in a new worksheet.
M._open_scheduler_job_ddl = function(state, node)
  local conn_name = node.extra.conn_name
  local job_name  = node.extra.job_name
  local conn = { key = conn_name, is_named = true }

  local nid = "ora_open"
  notify.progress(nid, "Loading scheduler job DDL…")

  local schema = require("ora.schema")
  schema.fetch_object_ddl(conn, "PROCOBJ", job_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to load scheduler job DDL")
      notify.error("ora", err)
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. job_name .. " (Scheduler Job DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = job_name .. "-ddl",
      display_name = display,
      icon         = "󰃰 ",
      db_object    = { name = job_name, type = "SCHEDULER JOB", schema = schema_name(state, conn_name), kind = "hard" },
    })

    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Scheduler job DDL loaded")
  end)
end

---Expand/collapse a scheduler program node, adding DDL action child on first expand.
M._toggle_scheduler_program = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  local conn_name    = node.extra.conn_name
  local program_name = node.extra.program_name

  local children = {
    {
      id       = "sprog_action:" .. conn_name .. ":" .. program_name .. ":ddl",
      name     = "DDL",
      type     = "source_action",
      path     = conn_name .. "/DBMS Scheduler/Programs/" .. program_name .. "/DDL",
      children = {},
      extra    = { conn_name = conn_name, object_name = program_name, object_type = "PROCOBJ" },
    },
  }

  M._set_category_children(state, node, conn_name, children)
end

---Fetch scheduler program DDL via DBMS_METADATA and open in a worksheet.
M._open_scheduler_program_ddl = function(state, node)
  local conn_name    = node.extra.conn_name
  local program_name = node.extra.program_name
  local conn = { key = conn_name, is_named = true }

  local nid = "ora_open"
  notify.progress(nid, "Loading scheduler program DDL…")

  local schema = require("ora.schema")
  schema.fetch_object_ddl(conn, "PROCOBJ", program_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to load scheduler program DDL")
      notify.error("ora", err)
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. program_name .. " (Scheduler Program DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = program_name .. "-ddl",
      display_name = display,
      icon         = "󰐱 ",
      db_object    = { name = program_name, type = "SCHEDULER PROGRAM", schema = schema_name(state, conn_name), kind = "hard" },
    })

    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
        table.insert(buf_lines, seg)
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Scheduler program DDL loaded")
  end)
end

---Expand/collapse an ORDS module node, lazy-loading templates.
M._toggle_ords_module = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local module_id = node.extra.module_id
  local conn = { key = conn_name, is_named = true }

  local module_name = node.name

  schema.fetch_ords_templates(conn, module_id, function(templates, err)
    node.extra.loading = false
    if err then
      notify.error("ora", err)
      renderer.redraw(state)
      return
    end
    local children = items.make_ords_template_children(conn_name, module_id, module_name, templates or {})
    M._set_category_children(state, node, conn_name, children)
  end)
end

---Expand/collapse an ORDS template node, lazy-loading handlers.
M._toggle_ords_template = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name = node.extra.conn_name
  local template_id = node.extra.template_id
  local conn = { key = conn_name, is_named = true }

  local module_name  = node.extra.module_name or ""
  local uri_template = node.name

  schema.fetch_ords_handlers(conn, template_id, function(handlers, err)
    node.extra.loading = false
    if err then
      notify.error("ora", err)
      renderer.redraw(state)
      return
    end
    local children = items.make_ords_handler_children(conn_name, template_id, module_name, uri_template, handlers or {})
    M._set_category_children(state, node, conn_name, children)
  end)
end

---Expand/collapse an ORDS handler node, lazy-loading parameters.
M._toggle_ords_handler = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end

  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local items = require("neo-tree.sources.ora.lib.items")
  local conn_name    = node.extra.conn_name
  local handler_id   = node.extra.handler_id
  local module_name  = node.extra.module_name or ""
  local uri_template = node.extra.uri_template or ""
  local method       = node.extra.method or ""
  local conn = { key = conn_name, is_named = true }

  schema.fetch_ords_parameters(conn, handler_id, function(params, err)
    node.extra.loading = false
    if err then
      notify.error("ora", err)
      renderer.redraw(state)
      return
    end
    local children = items.make_ords_parameter_children(conn_name, handler_id, module_name, uri_template, method, params or {})
    M._set_category_children(state, node, conn_name, children)
  end)
end

---Format a SQL string or NULL literal for embedding in PL/SQL.
---@param val string|nil
---@return string
local function sql_str_or_null(val)
  if val then return "'" .. val .. "'" end
  return "NULL"
end

---Open a worksheet with an ORDS.DEFINE_MODULE call, fetching details from user_ords_modules.
M._open_ords_define_module = function(state, node)
  local conn_name   = node.extra.conn_name
  local module_name = node.name
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Loading module details…")

  local schema = require("ora.schema")
  schema.fetch_ords_module_details(conn, module_name, function(d, err)
    if err then
      notify.error(nid, "Failed to load module details")
      notify.error("ora", err)
      return
    end
    if not d then
      notify.error(nid, "Module not found")
      return
    end

    local lines = {
      "BEGIN",
      "  ORDS.DEFINE_MODULE(",
      "    p_module_name    => '" .. d.name .. "',",
      "    p_base_path      => '" .. d.uri_prefix .. "',",
      "    p_items_per_page => " .. d.items_per_page .. ",",
      "    p_status         => '" .. d.status .. "',",
      "    p_comments       => " .. sql_str_or_null(d.comments),
      "  );",
      "  COMMIT;",
      "END;",
      "/",
    }

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. " ORDS " .. d.name .. " (Define Module)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = "ords-define-" .. d.name,
      display_name = display,
      icon         = "󰒍 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Module DDL loaded")
  end)
end

---Open a worksheet with an ORDS.DEFINE_TEMPLATE call, fetching details from user_ords_templates.
M._open_ords_define_template = function(state, node)
  local conn_name   = node.extra.conn_name
  local template_id = node.extra.template_id
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Loading template details…")

  local schema = require("ora.schema")
  schema.fetch_ords_template_details(conn, template_id, function(d, err)
    if err then
      notify.error(nid, "Failed to load template details")
      notify.error("ora", err)
      return
    end
    if not d then
      notify.error(nid, "Template not found")
      return
    end

    local lines = {
      "BEGIN",
      "  ORDS.DEFINE_TEMPLATE(",
      "    p_module_name    => '" .. d.module_name .. "',",
      "    p_pattern        => '" .. d.uri_template .. "',",
      "    p_priority       => " .. d.priority .. ",",
      "    p_etag_type      => '" .. d.etag_type .. "',",
      "    p_etag_query     => " .. sql_str_or_null(d.etag_query) .. ",",
      "    p_comments       => " .. sql_str_or_null(d.comments),
      "  );",
      "  COMMIT;",
      "END;",
      "/",
    }

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. " ORDS " .. d.module_name .. " " .. d.uri_template .. " (Define Template)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = "ords-define-tpl-" .. d.module_name .. "-" .. d.uri_template,
      display_name = display,
      icon         = "󰒍 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Template DDL loaded")
  end)
end

---Open a worksheet with an ORDS.DEFINE_HANDLER call, fetching details + source from user_ords_handlers.
M._open_ords_define_handler = function(state, node)
  local conn_name  = node.extra.conn_name
  local handler_id = node.extra.handler_id
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Loading handler details…")

  local schema = require("ora.schema")
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
      "    p_mimes_allowed  => " .. sql_str_or_null(d.mimes_allowed) .. ",",
      "    p_comments       => " .. sql_str_or_null(d.comments) .. ",",
      "    p_source         =>",
    }

    if #src_lines > 0 then
      table.insert(lines, "      q'[")
      for _, sl in ipairs(src_lines) do
        table.insert(lines, sl)
      end
      table.insert(lines, "      ]'")
    else
      table.insert(lines, "      NULL")
    end

    vim.list_extend(lines, {
      "  );",
      "  COMMIT;",
      "END;",
      "/",
    })

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. " ORDS " .. d.module_name .. " " .. d.uri_template .. " " .. d.method .. " (Define Handler)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = "ords-define-hdl-" .. d.module_name .. "-" .. d.method,
      display_name = display,
      icon         = "󰒍 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Handler DDL loaded")
  end

  schema.fetch_ords_handler_details(conn, handler_id, function(d, err)
    if not err then
      results.details = d
    else
      notify.error("ora", err)
    end
    on_done()
  end)

  schema.fetch_ords_handler_source(conn, handler_id, function(src, err)
    if err then notify.error("ora", err) end
    results.source = src or {}
    on_done()
  end)
end

---Open a worksheet with an ORDS.DEFINE_PARAMETER PL/SQL call for a parameter node.
---@param state table
---@param node table
M._open_ords_define_parameter = function(state, node)
  local conn_name    = node.extra.conn_name
  local module_name  = node.extra.module_name
  local uri_template = node.extra.uri_template
  local method       = node.extra.method
  local param_name   = node.name
  local param_type   = node.extra.param_type
  local source_type  = node.extra.source_type

  local lines = {
    "BEGIN",
    "  ORDS.DEFINE_PARAMETER(",
    "    p_module_name        => '" .. (module_name or "") .. "',",
    "    p_pattern            => '" .. (uri_template or "") .. "',",
    "    p_method             => '" .. (method or "") .. "',",
    "    p_name               => '" .. param_name .. "',",
    "    p_bind_variable_name => '" .. param_name .. "',",
    "    p_source_type        => '" .. (source_type or "HEADER") .. "',",
    "    p_param_type         => '" .. (param_type or "STRING") .. "',",
    "    p_access_method      => 'IN'",
    "  );",
    "  COMMIT;",
    "END;",
    "/",
  }

  local ws_mod  = require("ora.worksheet")
  local ws_conn = { key = conn_name, label = conn_name, is_named = true }
  local display = schema_name(state, conn_name) .. " ORDS " .. (module_name or "") .. " " .. param_name .. " (Define Parameter)"
  local ws = ws_mod.create({
    connection   = ws_conn,
    name         = "ords-define-param-" .. (module_name or "") .. "-" .. param_name,
    display_name = display,
    icon         = "󰒍 ",
  })

  vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
  open_ws_in_main(ws)
  format_buffer(ws.bufnr)
end

---Open the full DDL of an ORDS module in a new worksheet.
---Fetches templates, handlers, and handler sources from user_ords_* tables,
---then assembles ORDS.DEFINE_MODULE / DEFINE_TEMPLATE / DEFINE_HANDLER calls.
M._open_ords_module_ddl = function(state, node)
  local conn_name   = node.extra.conn_name
  local module_name = node.name
  local uri_prefix  = node.extra.uri_prefix or module_name
  local module_id   = node.extra.module_id
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Loading module DDL…")

  local schema = require("ora.schema")

  -- Step 1: fetch all templates + handlers (without source CLOBs)
  schema.fetch_ords_module_handlers(conn, module_id, function(rows, err)
    if err then
      notify.error(nid, "Failed to load module DDL")
      notify.error("ora", err)
      return
    end

    rows = rows or {}

    -- If no handlers, build DDL with just the module definition
    if #rows == 0 then
      local lines = {
        "BEGIN",
        "  ORDS.DEFINE_MODULE(",
        "    p_module_name    => '" .. module_name .. "',",
        "    p_base_path      => '" .. uri_prefix .. "',",
        "    p_items_per_page => 25,",
        "    p_status         => 'PUBLISHED',",
        "    p_comments       => NULL",
        "  );",
        "",
        "  COMMIT;",
        "END;",
        "/",
      }
      M._open_ords_ddl_worksheet(state, conn_name, module_name, lines)
      notify.done(nid, "Module DDL loaded")
      return
    end

    -- Step 2: fetch source for each handler in parallel
    local sources = {}
    local pending = #rows

    local function on_done()
      pending = pending - 1
      if pending > 0 then return end

      -- Step 3: assemble the full DDL
      local lines = {
        "BEGIN",
        "  ORDS.DEFINE_MODULE(",
        "    p_module_name    => '" .. module_name .. "',",
        "    p_base_path      => '" .. uri_prefix .. "',",
        "    p_items_per_page => 25,",
        "    p_status         => 'PUBLISHED',",
        "    p_comments       => NULL",
        "  );",
        "",
      }

      -- Group handlers by template
      local seen_templates = {}
      for _, row in ipairs(rows) do
        if not seen_templates[row.uri_template] then
          seen_templates[row.uri_template] = true
          vim.list_extend(lines, {
            "  ORDS.DEFINE_TEMPLATE(",
            "    p_module_name    => '" .. module_name .. "',",
            "    p_pattern        => '" .. row.uri_template .. "'",
            "  );",
            "",
          })
        end

        local src_lines = sources[row.handler_id] or {}
        local src_text = table.concat(src_lines, "\n")

        vim.list_extend(lines, {
          "  ORDS.DEFINE_HANDLER(",
          "    p_module_name    => '" .. module_name .. "',",
          "    p_pattern        => '" .. row.uri_template .. "',",
          "    p_method         => '" .. row.method .. "',",
          "    p_source_type    => '" .. row.source_type .. "',",
          "    p_source         =>",
        })

        if #src_lines > 0 then
          table.insert(lines, "      q'[")
          for _, sl in ipairs(src_lines) do
            table.insert(lines, sl)
          end
          table.insert(lines, "      ]'")
        else
          table.insert(lines, "      NULL")
        end

        vim.list_extend(lines, {
          "  );",
          "",
        })
      end

      vim.list_extend(lines, {
        "  COMMIT;",
        "END;",
        "/",
      })

      M._open_ords_ddl_worksheet(state, conn_name, module_name, lines)
      notify.done(nid, "Module DDL loaded")
    end

    for i, row in ipairs(rows) do
      schema.fetch_ords_handler_source(conn, row.handler_id, function(src_lines, err)
        if err then notify.error("ora", err) end
        sources[row.handler_id] = src_lines or {}
        on_done()
      end)
    end
  end)
end

---Helper: open a worksheet with ORDS DDL lines.
M._open_ords_ddl_worksheet = function(state, conn_name, module_name, lines)
  local ws_mod  = require("ora.worksheet")
  local ws_conn = { key = conn_name, label = conn_name, is_named = true }
  local display = schema_name(state, conn_name) .. " ORDS " .. module_name .. " (Module DDL)"
  local ws = ws_mod.create({
    connection   = ws_conn,
    name         = "ords-module-" .. module_name,
    display_name = display,
    icon         = "󰒍 ",
  })

  vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
  open_ws_in_main(ws)
  format_buffer(ws.bufnr)
end

---Export the full ORDS schema via ords_export_admin.export_schema.
M._open_ords_export_schema = function(state, node)
  local conn_name = node.extra.conn_name
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Exporting ORDS schema…")

  local schema = require("ora.schema")
  schema.fetch_ords_export_schema(conn, function(lines, err)
    if err then
      notify.error(nid, "Failed to export ORDS schema")
      notify.error("ora", err)
      return
    end

    if not lines or #lines == 0 then
      notify.error(nid, "ORDS schema export returned no data")
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. " ORDS (Schema Export)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = "ords-export-schema",
      display_name = display,
      icon         = "󰒍 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "ORDS schema exported")
  end)
end

---Export a single ORDS module via ORDS_METADATA.ORDS_EXPORT.EXPORT_MODULE.
M._open_ords_export_module = function(state, node)
  local conn_name   = node.extra.conn_name
  local module_name = node.name
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Exporting ORDS module…")

  local schema = require("ora.schema")
  schema.fetch_ords_export_module(conn, module_name, function(lines, err)
    if err then
      notify.error(nid, "Failed to export ORDS module")
      notify.error("ora", err)
      return
    end

    if not lines or #lines == 0 then
      notify.error(nid, "ORDS module export returned no data")
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. " ORDS " .. module_name .. " (Module Export)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = "ords-export-" .. module_name,
      display_name = display,
      icon         = "󰒍 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "ORDS module exported")
  end)
end

---Open the source code of an ORDS handler in a new worksheet.
M._open_ords_handler_source = function(state, node)
  local conn_name  = node.extra.conn_name
  local handler_id = node.extra.handler_id
  local method     = node.extra.method or "handler"
  local conn = { key = conn_name, is_named = true }


  local nid = "ora_open"
  notify.progress(nid, "Loading handler source…")

  local schema = require("ora.schema")
  schema.fetch_ords_handler_source(conn, handler_id, function(lines, err)
    if err then
      notify.error(nid, "Failed to load handler source")
      notify.error("ora", err)
      return
    end

    local ws_mod  = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. " ORDS " .. method .. " Handler"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = "ords-handler-" .. handler_id,
      display_name = display,
      icon         = "󰒍 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, lines or {})
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_ws_in_main(ws)
    format_buffer(ws.bufnr)
    notify.done(nid, "Handler source loaded")
  end)
end

---Apply fetched children to a category node and re-render.
M._set_category_children = function(state, node, conn_name, children)
  node.extra.loaded = true

  -- Cache in state for rebuild persistence
  if not state.ora_children then state.ora_children = {} end
  if not state.ora_children[conn_name] then
    state.ora_children[conn_name] = {}
  end

  -- Walk the cached tree to find this category node and update it
  local function update_node(nodes)
    for _, n in ipairs(nodes) do
      if n.id == node:get_id() then
        n.children = children
        n.extra.loaded = true
        return true
      end
      if n.children and #n.children > 0 then
        if update_node(n.children) then return true end
      end
    end
    return false
  end
  update_node(state.ora_children[conn_name])

  -- Remember which nodes were expanded before re-navigating
  local expanded_ids = {}
  if state.tree then
    for _, nid in ipairs(state.tree:get_nodes()) do
      -- Recursively collect expanded node IDs
      M._collect_expanded(state.tree, nid, expanded_ids)
    end
  end

  -- Also expand the node we just loaded children for
  expanded_ids[node:get_id()] = true

  -- Re-navigate to rebuild the full tree with new children
  local ora_source = require("neo-tree.sources.ora")
  ora_source.navigate(state)

  -- Restore expanded state
  if state.tree then
    M._restore_expanded(state.tree, expanded_ids)
    renderer.redraw(state)
  end
end

---Recursively collect IDs of expanded nodes.
M._collect_expanded = function(tree, node_or_id, result)
  local node = type(node_or_id) == "table" and node_or_id or tree:get_node(node_or_id)
  if not node then return end
  if node:is_expanded() then
    result[node:get_id()] = true
  end
  for _, child_id in ipairs(node:get_child_ids()) do
    M._collect_expanded(tree, child_id, result)
  end
end

---Restore expanded state on a rebuilt tree.
M._restore_expanded = function(tree, expanded_ids)
  for id, _ in pairs(expanded_ids) do
    local node = tree:get_node(id)
    if node and node:has_children() then
      node:expand()
    end
  end
end

---Expand the current node (same as toggle_node but only expands, never collapses).
M.expand_node = function(state)
  local node = state.tree:get_node()
  if not node then return end

  if node.type == "connection" then
    local name = node.extra.key
    if not state.ora_connected or not state.ora_connected[name] then
      -- Not connected yet — connect and expand
      M._toggle_connection(state, node)
      return
    end
    if not node:is_expanded() then
      node:expand()
      renderer.redraw(state)
    end
  elseif node.type == "category" then
    if not node:is_expanded() then
      M._toggle_category(state, node)
    end
  elseif node.type == "table" then
    if not node:is_expanded() then
      M._toggle_table(state, node)
    end
  elseif node.type == "view" then
    if not node:is_expanded() then
      M._toggle_view(state, node)
    end
  elseif node.type == "mview" then
    if not node:is_expanded() then
      M._toggle_mview(state, node)
    end
  elseif node.type == "function" or node.type == "procedure" then
    if not node:is_expanded() then
      M._toggle_func_or_proc(state, node)
    end
  elseif node.type == "package" then
    if not node:is_expanded() then
      M._toggle_package(state, node)
    end
  elseif node.type == "ora_type" then
    if not node:is_expanded() then
      M._toggle_type(state, node)
    end
  elseif node.type == "subprogram" then
    if not node:is_expanded() then
      M._toggle_subprogram(state, node)
    end
  elseif node.type == "scheduler_job" then
    if not node:is_expanded() then
      M._toggle_scheduler_job(state, node)
    end
  elseif node.type == "scheduler_program" then
    if not node:is_expanded() then
      M._toggle_scheduler_program(state, node)
    end
  elseif node.type == "ords_module" then
    if not node:is_expanded() then
      M._toggle_ords_module(state, node)
    end
  elseif node.type == "ords_template" then
    if not node:is_expanded() then
      M._toggle_ords_template(state, node)
    end
  elseif node.type == "ords_handler" then
    if not node:is_expanded() then
      M._toggle_ords_handler(state, node)
    end
  elseif node:has_children() and not node:is_expanded() then
    node:expand()
    renderer.redraw(state)
  end
end

---Collapse the current node. If already collapsed, jump to parent.
M.collapse_node = function(state)
  local node = state.tree:get_node()
  if not node then return end

  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
  else
    local parent_id = node:get_parent_id()
    if parent_id then
      renderer.focus_node(state, parent_id)
    end
  end
end

---Context-aware refresh. Re-fetches the children of the current node.
---Falls back to refreshing the full connection list from connmgr.
M.refresh = function(state)
  local node = state.tree and state.tree:get_node()
  if not node then
    refresh()
    return
  end

  local type_to_toggle = {
    category          = M._toggle_category,
    table             = M._toggle_table,
    view              = M._toggle_view,
    mview             = M._toggle_mview,
    package           = M._toggle_package,
    ora_type          = M._toggle_type,
    subprogram        = M._toggle_subprogram,
    scheduler_job     = M._toggle_scheduler_job,
    scheduler_program = M._toggle_scheduler_program,
    ords_module       = M._toggle_ords_module,
    ords_template     = M._toggle_ords_template,
    ords_handler      = M._toggle_ords_handler,
  }

  -- function/procedure share a toggle
  type_to_toggle["function"]  = M._toggle_func_or_proc
  type_to_toggle["procedure"] = M._toggle_func_or_proc

  local toggle_fn = type_to_toggle[node.type]
  if toggle_fn and node.extra and node.extra.loaded then
    node:collapse()
    node.extra.loaded = false
    M._clear_cached_node(state, node)
    toggle_fn(state, node)
  elseif node.type == "connection" and node.extra and state.ora_connected and state.ora_connected[node.extra.key] then
    -- Refresh a connected connection: clear cached categories and re-navigate
    local name = node.extra.key
    if state.ora_children then state.ora_children[name] = nil end
    node:collapse()
    local ora_source = require("neo-tree.sources.ora")
    ora_source.navigate(state)
    if state.tree then
      local conn_node = state.tree:get_node("conn:" .. name)
      if conn_node then
        conn_node:expand()
        renderer.redraw(state)
      end
    end
  else
    refresh()
  end
end

---Clear the loaded flag and children for a node in the state cache.
M._clear_cached_node = function(state, node)
  if not state.ora_children then return end
  local function clear_in(nodes)
    for _, n in ipairs(nodes) do
      if n.id == node:get_id() then
        n.children = {}
        n.extra.loaded = false
        return true
      end
      if n.children and #n.children > 0 then
        if clear_in(n.children) then return true end
      end
    end
    return false
  end
  for _, children in pairs(state.ora_children) do
    if clear_in(children) then return end
  end
end

---Show a picker with context-appropriate actions for the current node.
---Quick action: open the primary artifact for the current node.
---Tables → DDL, Views → DDL, Functions/Procedures → Body, Packages → Specification.
M.quick_open = function(state)
  local node = state.tree:get_node()
  if not node then return end

  if node.type == "table" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, table_name = node.extra.table_name, action = "ddl", loading = false },
    }
    M._open_table_action(state, fake)
  elseif node.type == "view" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, view_name = node.extra.view_name, action = "ddl", loading = false },
    }
    M._open_view_action(state, fake)
  elseif node.type == "mview" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, mview_name = node.extra.mview_name, action = "ddl", loading = false },
    }
    M._open_mview_action(state, fake)
  elseif node.type == "function" or node.type == "procedure" then
    local object_type = node.type == "function" and "FUNCTION" or "PROCEDURE"
    local fake = {
      extra = { conn_name = node.extra.conn_name, object_name = node.extra.object_name, object_type = object_type, loading = false },
    }
    M._open_object_source(state, fake)
  elseif node.type == "package" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, pkg_name = node.extra.pkg_name, part = "spec", loading = false },
    }
    M._open_package_source(state, fake)
  elseif node.type == "mview_log" then
    M._open_mview_log_ddl(state, node)
  elseif node.type == "synonym" then
    M._open_synonym_ddl(state, node)
  elseif node.type == "schema_index" then
    M._open_index_ddl(state, node)
  elseif node.type == "trigger" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, object_name = node.extra.trigger_name, object_type = "TRIGGER", loading = false },
    }
    M._open_object_source(state, fake)
  elseif node.type == "ora_type" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, type_name = node.extra.type_name, part = "spec", loading = false },
    }
    M._open_type_source(state, fake)
  elseif node.type == "sequence" then
    M._open_sequence_ddl(state, node)
  elseif node.type == "scheduler_job" then
    M._open_scheduler_job_ddl(state, node)
  elseif node.type == "scheduler_program" then
    M._open_scheduler_program_ddl(state, node)
  elseif node.type == "ords_module" then
    M._open_ords_define_module(state, node)
  elseif node.type == "ords_template" then
    M._open_ords_define_template(state, node)
  elseif node.type == "ords_handler" then
    M._open_ords_define_handler(state, node)
  elseif node.type == "ords_parameter" then
    M._open_ords_define_parameter(state, node)
  end
end

---Secondary quick action: open the secondary artifact for the current node.
---Tables → Data, Views → Data, Packages → Body, ORDS modules → Full export,
---ORDS handlers → Handler source.
M.quick_open_alt = function(state)
  local node = state.tree:get_node()
  if not node then return end

  if node.type == "table" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, table_name = node.extra.table_name, action = "data", loading = false },
    }
    M._open_table_action(state, fake)
  elseif node.type == "view" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, view_name = node.extra.view_name, action = "data", loading = false },
    }
    M._open_view_action(state, fake)
  elseif node.type == "mview" then
    local fake = {
      extra = { conn_name = node.extra.conn_name, mview_name = node.extra.mview_name, action = "data", loading = false },
    }
    M._open_mview_action(state, fake)
  elseif node.type == "package" then
    local conn_name = node.extra.conn_name
    local pkg_name  = node.extra.pkg_name
    if node.extra.has_body then
      local fake = {
        extra = { conn_name = conn_name, pkg_name = pkg_name, part = "body", loading = false },
      }
      M._open_package_source(state, fake)
    else
      local ws_mod = require("ora.worksheet")
      local ws_conn = { key = conn_name, label = conn_name, is_named = true }
      local display = schema_name(state, conn_name) .. "." .. pkg_name .. " (Package Body)"
      local ws = ws_mod.create({
        connection   = ws_conn,
        name         = pkg_name .. "-body",
        display_name = display,
        icon         = "󰏗 ",
        db_object    = { name = pkg_name, type = "PACKAGE BODY", schema = schema_name(state, conn_name), kind = "soft" },
      })
      vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
      open_ws_in_main(ws)
    end
  elseif node.type == "ora_type" then
    local conn_name = node.extra.conn_name
    local type_name = node.extra.type_name
    if node.extra.has_body then
      local fake = {
        extra = { conn_name = conn_name, type_name = type_name, part = "body", loading = false },
      }
      M._open_type_source(state, fake)
    else
      local ws_mod = require("ora.worksheet")
      local ws_conn = { key = conn_name, label = conn_name, is_named = true }
      local display = schema_name(state, conn_name) .. "." .. type_name .. " (Type Body)"
      local ws = ws_mod.create({
        connection   = ws_conn,
        name         = type_name .. "-body",
        display_name = display,
        icon         = "󰕳 ",
        db_object    = { name = type_name, type = "TYPE BODY", schema = schema_name(state, conn_name), kind = "soft" },
      })
      vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
      open_ws_in_main(ws)
    end
  elseif node.type == "ords_module" then
    M._open_ords_export_module(state, node)
  elseif node.type == "ords_handler" then
    M._open_ords_handler_source(state, node)
  end
end

---Show a picker with context-appropriate actions for the current node.
M.show_actions = function(state)
  local node = state.tree:get_node()
  if not node then return end

  if node.type == "connection" then
    local name = node.extra.key
    local connected = state.ora_connected and state.ora_connected[name] or false
    local actions = {}
    if not connected then
      table.insert(actions, "Connect")
    else
      table.insert(actions, "Disconnect")
    end
    table.insert(actions, "Show connection string")
    action_picker(name, actions, function(choice)
      if choice == "Connect" then
        vim.schedule(function()
          local fresh_node = state.tree and state.tree:get_node("conn:" .. name)
          if fresh_node then
            M._toggle_connection(state, fresh_node)
          end
        end)
      elseif choice == "Disconnect" then
        state.ora_connected[name] = false
        if state.ora_children then state.ora_children[name] = nil end
        if state.ora_schema then state.ora_schema[name] = nil end
        node:collapse()
        local ora_source = require("neo-tree.sources.ora")
        ora_source.navigate(state)
      
        notify.done("ora_conn", "Disconnected from " .. name)
      elseif choice == "Show connection string" then
      
        local nid = "ora_connstr"
        notify.progress(nid, "Fetching connection info…")
        vim.schedule(function()
          local info = require("ora.connmgr").show(name)
          if not info then
            notify.error(nid, "Could not fetch connection info")
            return
          end
          notify.done(nid, "Connection info loaded")
          local buf = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "-- Connection: " .. name,
            "-- User: " .. (info.user or "?"),
            info.connect_string or "",
          })
          vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
          vim.api.nvim_buf_set_option(buf, "filetype", "sql")
          local wins = vim.api.nvim_tabpage_list_wins(0)
          local target_win
          for _, win in ipairs(wins) do
            local cfg = vim.api.nvim_win_get_config(win)
            if cfg.relative == "" then
              local wbuf = vim.api.nvim_win_get_buf(win)
              local bname = vim.api.nvim_buf_get_name(wbuf)
              if not bname:match("neo%-tree") then
                target_win = win
                break
              end
            end
          end
          if target_win then
            vim.api.nvim_win_set_buf(target_win, buf)
            vim.api.nvim_set_current_win(target_win)
          else
            vim.cmd("wincmd l")
            vim.api.nvim_win_set_buf(0, buf)
          end
        end)
      end
    end)
  elseif node.type == "package" then
    local conn_name = node.extra.conn_name
    local pkg_name  = node.extra.pkg_name
    local has_body  = node.extra.has_body
    local actions = { "Show specification" }
    if has_body then
      table.insert(actions, "Show body")
    else
      table.insert(actions, "Add body")
    end
    table.insert(actions, "Drop package")
    if has_body then
      table.insert(actions, "Drop package body")
    end
    action_picker(pkg_name, actions, function(choice)
      if choice == "Show specification" or choice == "Show body" then
        local part = choice == "Show specification" and "spec" or "body"
        local fake = {
          extra = { conn_name = conn_name, pkg_name = pkg_name, part = part, loading = false },
        }
        M._open_package_source(state, fake)
      elseif choice == "Add body" then
        local ws_mod = require("ora.worksheet")
        local ws_conn = { key = conn_name, label = conn_name, is_named = true }
        local display = schema_name(state, conn_name) .. "." .. pkg_name .. " (Package Body)"
        local ws = ws_mod.create({
          connection   = ws_conn,
          name         = pkg_name .. "-body",
          display_name = display,
          icon         = "󰏗 ",
          db_object    = { name = pkg_name, type = "PACKAGE BODY", schema = schema_name(state, conn_name), kind = "soft" },
        })
        vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
        open_ws_in_main(ws)
      elseif choice == "Drop package" then
        open_drop_worksheet(state, conn_name, pkg_name, "PACKAGE")
      elseif choice == "Drop package body" then
        open_drop_worksheet(state, conn_name, pkg_name, "PACKAGE BODY")
      end
    end)
  elseif node.type == "table" then
    local conn_name  = node.extra.conn_name
    local table_name = node.extra.table_name
    action_picker(table_name, { "Show DDL", "Show data", "Drop table" }, function(choice)
      if choice == "Show DDL" or choice == "Show data" then
        local action = choice == "Show DDL" and "ddl" or "data"
        local fake = {
          extra = { conn_name = conn_name, table_name = table_name, action = action, loading = false },
        }
        M._open_table_action(state, fake)
      elseif choice == "Drop table" then
        open_drop_worksheet(state, conn_name, table_name, "TABLE")
      end
    end)
  elseif node.type == "view" then
    local conn_name = node.extra.conn_name
    local view_name = node.extra.view_name
    action_picker(view_name, { "Show DDL", "Show data", "Drop view" }, function(choice)
      if choice == "Show DDL" or choice == "Show data" then
        local action = choice == "Show DDL" and "ddl" or "data"
        local fake = {
          extra = { conn_name = conn_name, view_name = view_name, action = action, loading = false },
        }
        M._open_view_action(state, fake)
      elseif choice == "Drop view" then
        open_drop_worksheet(state, conn_name, view_name, "VIEW")
      end
    end)
  elseif node.type == "mview" then
    local conn_name  = node.extra.conn_name
    local mview_name = node.extra.mview_name
    action_picker(mview_name, { "Show DDL", "Show data", "Drop materialized view" }, function(choice)
      if choice == "Show DDL" or choice == "Show data" then
        local action = choice == "Show DDL" and "ddl" or "data"
        local fake = {
          extra = { conn_name = conn_name, mview_name = mview_name, action = action, loading = false },
        }
        M._open_mview_action(state, fake)
      elseif choice == "Drop materialized view" then
        open_drop_worksheet(state, conn_name, mview_name, "MATERIALIZED VIEW")
      end
    end)
  elseif node.type == "mview_log" then
    local conn_name = node.extra.conn_name
    local log_table = node.extra.log_table
    local master    = node.extra.master
    action_picker(log_table, { "Show DDL", "Drop materialized view log" }, function(choice)
      if choice == "Show DDL" then
        M._open_mview_log_ddl(state, node)
      elseif choice == "Drop materialized view log" then
        open_drop_worksheet(state, conn_name, master, "MATERIALIZED_VIEW_LOG")
      end
    end)
  elseif node.type == "synonym" then
    local conn_name    = node.extra.conn_name
    local synonym_name = node.extra.synonym_name
    action_picker(synonym_name, { "Show DDL", "Drop synonym" }, function(choice)
      if choice == "Show DDL" then
        M._open_synonym_ddl(state, node)
      elseif choice == "Drop synonym" then
        open_drop_worksheet(state, conn_name, synonym_name, "SYNONYM")
      end
    end)
  elseif node.type == "schema_index" then
    local conn_name  = node.extra.conn_name
    local index_name = node.extra.index_name
    action_picker(index_name, { "Show DDL", "Drop index" }, function(choice)
      if choice == "Show DDL" then
        M._open_index_ddl(state, node)
      elseif choice == "Drop index" then
        open_drop_worksheet(state, conn_name, index_name, "INDEX")
      end
    end)
  elseif node.type == "sequence" then
    local conn_name     = node.extra.conn_name
    local sequence_name = node.extra.sequence_name
    action_picker(sequence_name, { "Show DDL", "Drop sequence" }, function(choice)
      if choice == "Show DDL" then
        M._open_sequence_ddl(state, node)
      elseif choice == "Drop sequence" then
        open_drop_worksheet(state, conn_name, sequence_name, "SEQUENCE")
      end
    end)
  elseif node.type == "function" or node.type == "procedure" then
    local conn_name   = node.extra.conn_name
    local object_name = node.extra.object_name
    local object_type = node.type == "function" and "FUNCTION" or "PROCEDURE"
    local label = object_type:sub(1, 1) .. object_type:sub(2):lower()
    action_picker(object_name, { "Show body", "Drop " .. label:lower() }, function(choice)
      if choice == "Show body" then
        local fake = {
          extra = { conn_name = conn_name, object_name = object_name, object_type = object_type, loading = false },
        }
        M._open_object_source(state, fake)
      else
        open_drop_worksheet(state, conn_name, object_name, object_type)
      end
    end)
  elseif node.type == "ora_type" then
    local conn_name = node.extra.conn_name
    local type_name = node.extra.type_name
    local has_body  = node.extra.has_body
    local actions = { "Show specification" }
    if has_body then
      table.insert(actions, "Show body")
    else
      table.insert(actions, "Add body")
    end
    table.insert(actions, "Drop type")
    if has_body then
      table.insert(actions, "Drop type body")
    end
    action_picker(type_name, actions, function(choice)
      if choice == "Show specification" or choice == "Show body" then
        local part = choice == "Show specification" and "spec" or "body"
        local fake = {
          extra = { conn_name = conn_name, type_name = type_name, part = part, loading = false },
        }
        M._open_type_source(state, fake)
      elseif choice == "Add body" then
        local ws_mod = require("ora.worksheet")
        local ws_conn = { key = conn_name, label = conn_name, is_named = true }
        local display = schema_name(state, conn_name) .. "." .. type_name .. " (Type Body)"
        local ws = ws_mod.create({
          connection   = ws_conn,
          name         = type_name .. "-body",
          display_name = display,
          icon         = "󰕳 ",
          db_object    = { name = type_name, type = "TYPE BODY", schema = schema_name(state, conn_name), kind = "soft" },
        })
        vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
        open_ws_in_main(ws)
      elseif choice == "Drop type" then
        open_drop_worksheet(state, conn_name, type_name, "TYPE")
      elseif choice == "Drop type body" then
        open_drop_worksheet(state, conn_name, type_name, "TYPE BODY")
      end
    end)
  elseif node.type == "trigger" then
    local conn_name    = node.extra.conn_name
    local trigger_name = node.extra.trigger_name
    action_picker(trigger_name, { "Show DDL", "Drop trigger" }, function(choice)
      if choice == "Show DDL" then
        local schema = require("ora.schema")
        local conn = { key = conn_name, is_named = true }
      
        local nid = "ora_open"
        notify.progress(nid, "Loading trigger DDL…")
        schema.fetch_object_ddl(conn, "TRIGGER", trigger_name, function(lines, err)
          if err then
            notify.error(nid, "Failed to load trigger DDL")
            notify.error("ora", err)
            return
          end
          local ws_mod  = require("ora.worksheet")
          local ws_conn = { key = conn_name, label = conn_name, is_named = true }
          local display = schema_name(state, conn_name) .. "." .. trigger_name .. " (Trigger DDL)"
          local ws = ws_mod.create({
            connection   = ws_conn,
            name         = trigger_name .. "-ddl",
            display_name = display,
            icon         = "󱐋 ",
            db_object    = { name = trigger_name, type = "TRIGGER", schema = schema_name(state, conn_name), kind = "hard" },
          })
          local buf_lines = {}
          for _, line in ipairs(lines or {}) do
            line = line:gsub("%s+$", "")
            for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
              table.insert(buf_lines, seg)
            end
          end
          vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
          vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
          open_ws_in_main(ws)
          format_buffer(ws.bufnr)
          notify.done(nid, "Trigger DDL loaded")
        end)
      elseif choice == "Drop trigger" then
        open_drop_worksheet(state, conn_name, trigger_name, "TRIGGER")
      end
    end)
  elseif node.type == "scheduler_job" then
    local conn_name = node.extra.conn_name
    local job_name  = node.extra.job_name
    action_picker(job_name, { "Show DDL", "Drop job" }, function(choice)
      if choice == "Show DDL" then
        M._open_scheduler_job_ddl(state, node)
      elseif choice == "Drop job" then
        open_drop_worksheet(state, conn_name, job_name, "PROCOBJ")
      end
    end)
  elseif node.type == "scheduler_program" then
    local conn_name    = node.extra.conn_name
    local program_name = node.extra.program_name
    action_picker(program_name, { "Show DDL", "Drop program" }, function(choice)
      if choice == "Show DDL" then
        M._open_scheduler_program_ddl(state, node)
      elseif choice == "Drop program" then
        open_drop_worksheet(state, conn_name, program_name, "PROCOBJ")
      end
    end)
  elseif node.type == "category" and node.extra.category == "ords" then
    action_picker("ORDS", { "Export schema" }, function(choice)
      if choice == "Export schema" then
        local fake = { extra = { conn_name = node.extra.conn_name } }
        M._open_ords_export_schema(state, fake)
      end
    end)
  elseif node.type == "ords_module" then
    local module_name = node.name
    action_picker(module_name, { "Define module", "Export module" }, function(choice)
      if choice == "Define module" then
        M._open_ords_define_module(state, node)
      elseif choice == "Export module" then
        M._open_ords_export_module(state, node)
      end
    end)
  elseif node.type == "ords_template" then
    local uri_template = node.name
    action_picker(uri_template, { "Define template" }, function(choice)
      if choice == "Define template" then
        M._open_ords_define_template(state, node)
      end
    end)
  elseif node.type == "ords_handler" then
    local method = node.extra.method or "handler"
    action_picker(method, { "Define handler" }, function(choice)
      if choice == "Define handler" then
        M._open_ords_define_handler(state, node)
      end
    end)
  elseif node.type == "ords_parameter" then
    action_picker(node.name, { "Define parameter" }, function(choice)
      if choice == "Define parameter" then
        M._open_ords_define_parameter(state, node)
      end
    end)
  end
end

cc._add_common_commands(M)

return M
