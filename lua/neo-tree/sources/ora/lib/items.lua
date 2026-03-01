-- Tree item builder for the ora neo-tree source.
-- Fetches connection names from connmgr and builds the root nodes.

local renderer = require("neo-tree.ui.renderer")

local M = {}

---Build root connection nodes from connmgr and render them.
---@param state table  neo-tree state
function M.get_items(state)
  local connmgr = require("ora.connmgr")
  local names = connmgr.list()

  local items = {}
  for i, name in ipairs(names) do
    local id = "conn:" .. name
    local connected = state.ora_connected and state.ora_connected[name] or false
    local children = {}

    -- If connected and children were loaded, rebuild them from cache
    if connected and state.ora_children and state.ora_children[name] then
      children = state.ora_children[name]
    elseif connected then
      -- Connected but no children loaded yet — show category stubs
      children = M.make_category_stubs(name)
      -- Cache the stubs so commands.lua can update them in-place
      if not state.ora_children then state.ora_children = {} end
      state.ora_children[name] = children
    end

    table.insert(items, {
      id       = id,
      name     = name,
      type     = "connection",
      path     = name,
      children = children,
      extra    = {
        key      = name,
        is_named = true,
        connected = connected,
      },
    })
  end

  if #items == 0 then
    table.insert(items, {
      id       = "no_connections",
      name     = "No connections found",
      type     = "message",
      path     = "no_connections",
      children = {},
      extra    = {},
    })
  end

  renderer.show_nodes(items, state)
end

---Create all category stub nodes for a connection.
---@param conn_name string
---@return table[]
function M.make_category_stubs(conn_name)
  return {
    {
      id       = "cat:" .. conn_name .. ":Tables",
      name     = "Tables",
      type     = "category",
      path     = conn_name .. "/Tables",
      children = {},
      extra    = { category = "tables", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Views",
      name     = "Views",
      type     = "category",
      path     = conn_name .. "/Views",
      children = {},
      extra    = { category = "views", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Functions",
      name     = "Functions",
      type     = "category",
      path     = conn_name .. "/Functions",
      children = {},
      extra    = { category = "functions", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Procedures",
      name     = "Procedures",
      type     = "category",
      path     = conn_name .. "/Procedures",
      children = {},
      extra    = { category = "procedures", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Packages",
      name     = "Packages",
      type     = "category",
      path     = conn_name .. "/Packages",
      children = {},
      extra    = { category = "packages", conn_name = conn_name, loaded = false },
    },
  }
end

---Build child nodes for a list of tables with comments.
---@param conn_name string
---@param tables    {name: string, comment: string|nil}[]
---@return table[]
function M.make_table_children(conn_name, tables)
  local children = {}
  for _, tbl in ipairs(tables) do
    table.insert(children, {
      id       = "tbl:" .. conn_name .. ":" .. tbl.name,
      name     = tbl.name,
      type     = "table",
      path     = conn_name .. "/Tables/" .. tbl.name,
      children = {},
      extra    = { conn_name = conn_name, table_name = tbl.name, comment = tbl.comment, loaded = false },
    })
  end
  return children
end

---Build child nodes for a list of columns with data types.
---@param conn_name  string
---@param table_name string
---@param cols       {name: string, data_type: string}[]
---@return table[]
---Build child nodes for a list of views with comments.
---@param conn_name string
---@param views     {name: string, comment: string|nil}[]
---@return table[]
function M.make_view_children(conn_name, views)
  local children = {}
  for _, v in ipairs(views) do
    table.insert(children, {
      id       = "view:" .. conn_name .. ":" .. v.name,
      name     = v.name,
      type     = "view",
      path     = conn_name .. "/Views/" .. v.name,
      children = {},
      extra    = { conn_name = conn_name, view_name = v.name, comment = v.comment, loaded = false },
    })
  end
  return children
end

function M.make_column_children(conn_name, table_name, cols)
  local children = {}
  for _, col in ipairs(cols) do
    table.insert(children, {
      id       = "col:" .. conn_name .. ":" .. table_name .. ":" .. col.name,
      name     = col.name,
      type     = "column",
      path     = conn_name .. "/Tables/" .. table_name .. "/Columns/" .. col.name,
      children = {},
      extra    = { conn_name = conn_name, table_name = table_name, data_type = col.data_type },
    })
  end
  return children
end

---Build child nodes for a list of index names.
---@param conn_name  string
---@param table_name string
---@param names      string[]
---@return table[]
function M.make_index_children(conn_name, table_name, names)
  local children = {}
  for _, idx_name in ipairs(names) do
    table.insert(children, {
      id       = "idx:" .. conn_name .. ":" .. table_name .. ":" .. idx_name,
      name     = idx_name,
      type     = "index",
      path     = conn_name .. "/Tables/" .. table_name .. "/Indexes/" .. idx_name,
      children = {},
      extra    = { conn_name = conn_name, table_name = table_name },
    })
  end
  return children
end

---Build child nodes for a list of constraint names.
---@param conn_name  string
---@param table_name string
---@param names      string[]
---@return table[]
function M.make_constraint_children(conn_name, table_name, names)
  local children = {}
  for _, cst_name in ipairs(names) do
    table.insert(children, {
      id       = "cst:" .. conn_name .. ":" .. table_name .. ":" .. cst_name,
      name     = cst_name,
      type     = "constraint",
      path     = conn_name .. "/Tables/" .. table_name .. "/Constraints/" .. cst_name,
      children = {},
      extra    = { conn_name = conn_name, table_name = table_name },
    })
  end
  return children
end

---Build child nodes for column comments.
---@param conn_name  string
---@param table_name string
---@param comments   {column: string, text: string}[]
---@return table[]
function M.make_comment_children(conn_name, table_name, comments)
  local children = {}
  for _, c in ipairs(comments) do
    table.insert(children, {
      id       = "cmt:" .. conn_name .. ":" .. table_name .. ":" .. c.column,
      name     = c.column .. ": " .. c.text,
      type     = "comment",
      path     = conn_name .. "/Tables/" .. table_name .. "/Comments/" .. c.column,
      children = {},
      extra    = { conn_name = conn_name, table_name = table_name },
    })
  end
  return children
end

---Build child nodes for a list of functions with return types.
---@param conn_name string
---@param funcs     {name: string, return_type: string}[]
---@return table[]
function M.make_function_children(conn_name, funcs)
  local children = {}
  for _, func in ipairs(funcs) do
    table.insert(children, {
      id       = "func:" .. conn_name .. ":" .. func.name,
      name     = func.name,
      type     = "function",
      path     = conn_name .. "/Functions/" .. func.name,
      children = {},
      extra    = { conn_name = conn_name, object_name = func.name, return_type = func.return_type, loaded = false },
    })
  end
  return children
end

---Build child nodes for a list of procedure names.
---@param conn_name string
---@param names     string[]
---@return table[]
function M.make_procedure_children(conn_name, names)
  local children = {}
  for _, proc_name in ipairs(names) do
    table.insert(children, {
      id       = "proc:" .. conn_name .. ":" .. proc_name,
      name     = proc_name,
      type     = "procedure",
      path     = conn_name .. "/Procedures/" .. proc_name,
      children = {},
      extra    = { conn_name = conn_name, object_name = proc_name, loaded = false },
    })
  end
  return children
end

---Build child nodes for parameters of a standalone function or procedure.
---@param conn_name   string
---@param object_name string
---@param params      {name: string, type: string}[]
---@return table[]
function M.make_object_parameter_children(conn_name, object_name, params)
  local children = {}
  for _, p in ipairs(params) do
    table.insert(children, {
      id       = "param:" .. conn_name .. ":" .. object_name .. ":" .. p.name,
      name     = p.name,
      type     = "parameter",
      path     = conn_name .. "/" .. object_name .. "/" .. p.name,
      children = {},
      extra    = { conn_name = conn_name, object_name = object_name, data_type = p.type },
    })
  end
  return children
end

---Build child nodes for a list of package names.
---@param conn_name string
---@param names     string[]
---@return table[]
function M.make_package_children(conn_name, names)
  local children = {}
  for _, pkg_name in ipairs(names) do
    table.insert(children, {
      id       = "pkg:" .. conn_name .. ":" .. pkg_name,
      name     = pkg_name,
      type     = "package",
      path     = conn_name .. "/Packages/" .. pkg_name,
      children = {},
      extra    = { conn_name = conn_name, pkg_name = pkg_name, loaded = false },
    })
  end
  return children
end

---Build child nodes for subprograms inside a package.
---@param conn_name string
---@param pkg_name  string
---@param subprograms string[]
---@return table[]
function M.make_subprogram_children(conn_name, pkg_name, subprograms)
  local children = {}
  for _, sub_name in ipairs(subprograms) do
    table.insert(children, {
      id       = "sub:" .. conn_name .. ":" .. pkg_name .. ":" .. sub_name,
      name     = sub_name,
      type     = "subprogram",
      path     = conn_name .. "/Packages/" .. pkg_name .. "/" .. sub_name,
      children = {},
      extra    = { conn_name = conn_name, pkg_name = pkg_name, subprogram = sub_name, loaded = false },
    })
  end
  return children
end

---Build child nodes for parameters of a subprogram.
---@param conn_name string
---@param pkg_name  string
---@param sub_name  string
---@param params    {name: string, type: string}[]
---@return table[]
function M.make_parameter_children(conn_name, pkg_name, sub_name, params)
  local children = {}
  for _, p in ipairs(params) do
    table.insert(children, {
      id       = "param:" .. conn_name .. ":" .. pkg_name .. ":" .. sub_name .. ":" .. p.name,
      name     = p.name,
      type     = "parameter",
      path     = conn_name .. "/Packages/" .. pkg_name .. "/" .. sub_name .. "/" .. p.name,
      children = {},
      extra    = { conn_name = conn_name, pkg_name = pkg_name, subprogram = sub_name, data_type = p.type },
    })
  end
  return children
end

return M
