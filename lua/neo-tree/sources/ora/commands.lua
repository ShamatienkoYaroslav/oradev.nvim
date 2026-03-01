-- Commands (keybindings) for the ora neo-tree source.

local cc = require("neo-tree.sources.common.commands")
local utils = require("neo-tree.utils")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")

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
  elseif node.type == "view_action" then
    M._open_view_ddl(state, node)
  elseif node.type == "table_action" then
    M._open_table_action(state, node)
  elseif node.type == "source_action" then
    M._open_object_source(state, node)
  elseif node.type == "function" or node.type == "procedure" then
    M._toggle_func_or_proc(state, node)
  elseif node.type == "package_part" then
    M._open_package_source(state, node)
  elseif node.type == "package" then
    M._toggle_package(state, node)
  elseif node.type == "subprogram" then
    M._toggle_subprogram(state, node)
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

  -- Cache the schema (Oracle user) name for display
  if not state.ora_schema then state.ora_schema = {} end
  local info = require("ora.connmgr").show(name)
  if info and info.user then
    state.ora_schema[name] = info.user
  end

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
  elseif category == "functions" then
    fetch_fn = function(cb) schema.fetch_functions_with_return_type(conn, cb) end
    build_fn = function(funcs) return items.make_function_children(conn_name, funcs) end
  elseif category == "procedures" then
    fetch_fn = function(cb) schema.fetch_procedures(conn, cb) end
    build_fn = function(names) return items.make_procedure_children(conn_name, names) end
  elseif category == "packages" then
    fetch_fn = function(cb) schema.fetch_packages(conn, cb) end
    build_fn = function(names) return items.make_package_children(conn_name, names) end
  end

  if not fetch_fn then return end

  -- Show loading state
  node.extra.loading = true
  renderer.redraw(state)

  fetch_fn(function(names, err)
    node.extra.loading = false
    if err then
      vim.notify("[ora] " .. err, vim.log.levels.ERROR)
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
  local pending = 4

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
    -- DDL and Data action nodes
    table.insert(children, {
      id       = "ddl:" .. conn_name .. ":" .. table_name,
      name     = "DDL",
      type     = "table_action",
      path     = conn_name .. "/Tables/" .. table_name .. "/DDL",
      children = {},
      extra    = { conn_name = conn_name, table_name = table_name, action = "ddl" },
    })
    table.insert(children, {
      id       = "data:" .. conn_name .. ":" .. table_name,
      name     = "Data",
      type     = "table_action",
      path     = conn_name .. "/Tables/" .. table_name .. "/Data",
      children = {},
      extra    = { conn_name = conn_name, table_name = table_name, action = "data" },
    })
    for _, c in ipairs(results.columns or {}) do table.insert(children, c) end
    for _, c in ipairs(results.indexes or {}) do table.insert(children, c) end
    for _, c in ipairs(results.constraints or {}) do table.insert(children, c) end

    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_columns_with_types(conn, table_name, function(cols, err)
    if not err then
      results.columns = items.make_column_children(conn_name, table_name, cols or {})
    end
    on_done()
  end)

  schema.fetch_indexes(conn, table_name, function(names, err)
    if not err then
      results.indexes = items.make_index_children(conn_name, table_name, names or {})
    end
    on_done()
  end)

  schema.fetch_constraints(conn, table_name, function(names, err)
    if not err then
      results.constraints = items.make_constraint_children(conn_name, table_name, names or {})
    end
    on_done()
  end)

  schema.fetch_comments(conn, table_name, function(comments, err)
    if not err then
      results.col_comments = comments or {}
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
    -- DDL action node
    table.insert(children, {
      id       = "vddl:" .. conn_name .. ":" .. view_name,
      name     = "DDL",
      type     = "view_action",
      path     = conn_name .. "/Views/" .. view_name .. "/DDL",
      children = {},
      extra    = { conn_name = conn_name, view_name = view_name },
    })
    for _, c in ipairs(results.columns or {}) do table.insert(children, c) end

    M._set_category_children(state, node, conn_name, children)
  end

  schema.fetch_columns_with_types(conn, view_name, function(cols, err)
    if not err then
      results.columns = items.make_column_children(conn_name, view_name, cols or {})
    end
    on_done()
  end)

  schema.fetch_comments(conn, view_name, function(comments, err)
    if not err then
      results.col_comments = comments or {}
    end
    on_done()
  end)
end

---Open the DDL of a view in a new worksheet.
M._open_view_ddl = function(state, node)
  local conn_name = node.extra.conn_name
  local view_name = node.extra.view_name

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local conn = { key = conn_name, is_named = true }

  schema.fetch_view_ddl(conn, view_name, function(lines, err)
    node.extra.loading = false
    renderer.redraw(state)

    if err then
      vim.notify("[ora] " .. err, vim.log.levels.ERROR)
      return
    end

    local ws_mod = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local display = schema_name(state, conn_name) .. "." .. view_name .. " (View DDL)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = view_name .. "-ddl",
      display_name = display,
      icon         = "󰡠 ",
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
  end)
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

    schema.fetch_ddl(conn, table_name, function(lines, err)
      node.extra.loading = false
      renderer.redraw(state)

      if err then
        vim.notify("[ora] " .. err, vim.log.levels.ERROR)
        return
      end

      local display = schema_name(state, conn_name) .. "." .. table_name .. " (Table DDL)"
      local ws = ws_mod.create({
        connection   = ws_conn,
        name         = table_name .. "-ddl",
        display_name = display,
        icon         = "󰓫 ",
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
    end)
  elseif action == "data" then
    local display = schema_name(state, conn_name) .. "." .. table_name .. " (Table Data)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = table_name .. "-data",
      display_name = display,
      icon         = "󰓫 ",
    })

    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, { "SELECT * FROM " .. table_name .. ";" })
    vim.api.nvim_buf_set_option(ws.bufnr, "filetype", "plsql")
    open_in_main(ws)
  end
end

---Open the source code of a package spec or body in a new worksheet.
M._open_package_source = function(state, node)
  local conn_name = node.extra.conn_name
  local pkg_name = node.extra.pkg_name
  local part = node.extra.part
  local object_type = part == "spec" and "PACKAGE" or "PACKAGE BODY"

  node.extra.loading = true
  renderer.redraw(state)

  local schema = require("ora.schema")
  local conn = { key = conn_name, is_named = true }

  schema.fetch_source(conn, pkg_name, object_type, function(lines, err)
    node.extra.loading = false
    renderer.redraw(state)

    if err then
      vim.notify("[ora] " .. err, vim.log.levels.ERROR)
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
    })

    -- Each user_source row typically ends with a trailing newline;
    -- strip it and split any remaining embedded newlines.
    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      if line ~= "" then
        for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
          table.insert(buf_lines, seg)
        end
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
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
    local children = {}
    -- Specification
    table.insert(children, {
      id       = "part:" .. conn_name .. ":" .. pkg_name .. ":spec",
      name     = "Specification",
      type     = "package_part",
      path     = conn_name .. "/Packages/" .. pkg_name .. "/spec",
      children = {},
      extra    = { conn_name = conn_name, pkg_name = pkg_name, part = "spec" },
    })
    -- Body node only if body exists
    if results.has_body then
      table.insert(children, {
        id       = "part:" .. conn_name .. ":" .. pkg_name .. ":body",
        name     = "Body",
        type     = "package_part",
        path     = conn_name .. "/Packages/" .. pkg_name .. "/body",
        children = {},
        extra    = { conn_name = conn_name, pkg_name = pkg_name, part = "body" },
      })
    end
    -- Subprograms
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
      vim.notify("[ora] " .. err, vim.log.levels.ERROR)
      renderer.redraw(state)
      return
    end
    local object_type = node.type == "function" and "FUNCTION" or "PROCEDURE"
    local children = {}
    -- Body node first
    table.insert(children, {
      id       = "body:" .. conn_name .. ":" .. object_name,
      name     = "Body",
      type     = "source_action",
      path     = conn_name .. "/" .. object_name .. "/body",
      children = {},
      extra    = { conn_name = conn_name, object_name = object_name, object_type = object_type },
    })
    -- Then parameters
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

  schema.fetch_source(conn, object_name, object_type, function(lines, err)
    node.extra.loading = false
    renderer.redraw(state)

    if err then
      vim.notify("[ora] " .. err, vim.log.levels.ERROR)
      return
    end

    local ws_mod = require("ora.worksheet")
    local ws_conn = { key = conn_name, label = conn_name, is_named = true }
    local icon = object_type == "FUNCTION" and "󰊕 " or "󰡱 "
    local type_label = object_type == "FUNCTION" and "Function" or "Procedure"
    local display = schema_name(state, conn_name) .. "." .. object_name .. " (" .. type_label .. " Body)"
    local ws = ws_mod.create({
      connection   = ws_conn,
      name         = object_name .. "-body",
      display_name = display,
      icon         = icon,
    })

    local buf_lines = {}
    for _, line in ipairs(lines or {}) do
      line = line:gsub("%s+$", "")
      if line ~= "" then
        for _, seg in ipairs(vim.split(line, "\n", { plain = true })) do
          table.insert(buf_lines, seg)
        end
      end
    end
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, buf_lines)
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
      vim.notify("[ora] " .. err, vim.log.levels.ERROR)
      renderer.redraw(state)
      return
    end
    local children = items.make_parameter_children(conn_name, pkg_name, sub_name, params or {})
    M._set_category_children(state, node, conn_name, children)
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
  elseif node.type == "view_action" then
    M._open_view_ddl(state, node)
  elseif node.type == "table_action" then
    M._open_table_action(state, node)
  elseif node.type == "source_action" then
    M._open_object_source(state, node)
  elseif node.type == "function" or node.type == "procedure" then
    if not node:is_expanded() then
      M._toggle_func_or_proc(state, node)
    end
  elseif node.type == "package_part" then
    M._open_package_source(state, node)
  elseif node.type == "package" then
    if not node:is_expanded() then
      M._toggle_package(state, node)
    end
  elseif node.type == "subprogram" then
    if not node:is_expanded() then
      M._toggle_subprogram(state, node)
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

---Context-aware refresh. On a category or table node, re-fetches its children.
---Otherwise refreshes the full connection list from connmgr.
M.refresh = function(state)
  local node = state.tree and state.tree:get_node()
  if not node then
    refresh()
    return
  end

  if node.type == "category" and node.extra and node.extra.loaded then
    -- Collapse, clear cache, then re-fetch (which will expand)
    node:collapse()
    node.extra.loaded = false
    -- Also clear in the state cache
    M._clear_cached_node(state, node)
    M._toggle_category(state, node)
  elseif node.type == "table" and node.extra and node.extra.loaded then
    node:collapse()
    node.extra.loaded = false
    M._clear_cached_node(state, node)
    M._toggle_table(state, node)
  elseif node.type == "view" and node.extra and node.extra.loaded then
    node:collapse()
    node.extra.loaded = false
    M._clear_cached_node(state, node)
    M._toggle_view(state, node)
  elseif node.type == "package" and node.extra and node.extra.loaded then
    node:collapse()
    node.extra.loaded = false
    M._clear_cached_node(state, node)
    M._toggle_package(state, node)
  elseif node.type == "subprogram" and node.extra and node.extra.loaded then
    node:collapse()
    node.extra.loaded = false
    M._clear_cached_node(state, node)
    M._toggle_subprogram(state, node)
  elseif (node.type == "function" or node.type == "procedure") and node.extra and node.extra.loaded then
    node:collapse()
    node.extra.loaded = false
    M._clear_cached_node(state, node)
    M._toggle_func_or_proc(state, node)
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

---Add a new connection via the add-connection prompt.
M.add_connection = function(state)
  require("ora").add_connection()
end

---Open object: for packages show Spec/Body picker, for tables show DDL/Data picker,
---for functions/procedures open the Body directly.
M.open_object = function(state)
  local node = state.tree:get_node()
  if not node then return end

  if node.type == "package" then
    local conn_name = node.extra.conn_name
    local pkg_name  = node.extra.pkg_name
    vim.ui.select({ "Specification", "Body" }, { prompt = pkg_name .. ":" }, function(choice)
      if not choice then return end
      local part = choice == "Specification" and "spec" or "body"
      local fake = {
        extra = { conn_name = conn_name, pkg_name = pkg_name, part = part, loading = false },
      }
      M._open_package_source(state, fake)
    end)
  elseif node.type == "table" then
    local conn_name  = node.extra.conn_name
    local table_name = node.extra.table_name
    vim.ui.select({ "DDL", "Data" }, { prompt = table_name .. ":" }, function(choice)
      if not choice then return end
      local action = choice == "DDL" and "ddl" or "data"
      local fake = {
        extra = { conn_name = conn_name, table_name = table_name, action = action, loading = false },
      }
      M._open_table_action(state, fake)
    end)
  elseif node.type == "view" then
    local conn_name = node.extra.conn_name
    local view_name = node.extra.view_name
    local fake = {
      extra = { conn_name = conn_name, view_name = view_name, loading = false },
    }
    M._open_view_ddl(state, fake)
  elseif node.type == "function" or node.type == "procedure" then
    local conn_name   = node.extra.conn_name
    local object_name = node.extra.object_name
    local object_type = node.type == "function" and "FUNCTION" or "PROCEDURE"
    local fake = {
      extra = { conn_name = conn_name, object_name = object_name, object_type = object_type, loading = false },
    }
    M._open_object_source(state, fake)
  end
end

cc._add_common_commands(M)

return M
