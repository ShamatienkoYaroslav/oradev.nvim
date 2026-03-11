-- Tree item builder for the ora neo-tree source.
-- Fetches connection names from connmgr and builds the root nodes.

local renderer = require("neo-tree.ui.renderer")

local M = {}

---Build a connection node for the tree.
---@param state table  neo-tree state
---@param name  string connection name
---@return table
local function make_connection_node(state, name)
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

  return {
    id       = "conn:" .. name,
    name     = name,
    type     = "connection",
    path     = name,
    children = children,
    extra    = {
      key      = name,
      is_named = true,
      connected = connected,
    },
  }
end

---Recursively build neo-tree nodes from a connmgr tree structure.
---@param state       table              neo-tree state
---@param tree_items  ConnmgrTreeEntry[] items from connmgr.list_tree()
---@param parent_path string             path prefix for folder nesting
---@return table[]
local function build_nodes(state, tree_items, parent_path)
  local nodes = {}
  for _, entry in ipairs(tree_items) do
    if entry.type == "folder" then
      local folder_path = parent_path ~= "" and (parent_path .. "/" .. entry.name) or entry.name
      local children = build_nodes(state, entry.children or {}, folder_path)
      table.insert(nodes, {
        id       = "folder:" .. folder_path,
        name     = entry.name,
        type     = "folder",
        path     = folder_path,
        children = children,
        extra    = {},
      })
    else
      table.insert(nodes, make_connection_node(state, entry.name))
    end
  end
  return nodes
end

---Build root connection nodes from connmgr and render them.
---@param state table  neo-tree state
function M.get_items(state)
  local connmgr = require("ora.connmgr")
  local ok, tree = pcall(connmgr.list_tree)
  if not ok then
    local err_msg = tostring(tree)
    renderer.show_nodes({
      {
        id       = "error",
        name     = "Error: " .. err_msg,
        type     = "message",
        path     = "error",
        children = {},
        extra    = {},
      },
    }, state)
    return
  end

  local items = build_nodes(state, tree, "")

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
      id       = "cat:" .. conn_name .. ":Materialized Views",
      name     = "Materialized Views",
      type     = "category",
      path     = conn_name .. "/Materialized Views",
      children = {},
      extra    = { category = "mviews", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Materialized View Logs",
      name     = "Materialized View Logs",
      type     = "category",
      path     = conn_name .. "/Materialized View Logs",
      children = {},
      extra    = { category = "mview_logs", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Indexes",
      name     = "Indexes",
      type     = "category",
      path     = conn_name .. "/Indexes",
      children = {},
      extra    = { category = "indexes", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Synonyms",
      name     = "Synonyms",
      type     = "category",
      path     = conn_name .. "/Synonyms",
      children = {},
      extra    = { category = "synonyms", conn_name = conn_name, loaded = false },
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
    {
      id       = "cat:" .. conn_name .. ":Triggers",
      name     = "Triggers",
      type     = "category",
      path     = conn_name .. "/Triggers",
      children = {},
      extra    = { category = "triggers", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Types",
      name     = "Types",
      type     = "category",
      path     = conn_name .. "/Types",
      children = {},
      extra    = { category = "types", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Sequences",
      name     = "Sequences",
      type     = "category",
      path     = conn_name .. "/Sequences",
      children = {},
      extra    = { category = "sequences", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":DBMS Scheduler",
      name     = "DBMS Scheduler",
      type     = "category",
      path     = conn_name .. "/DBMS Scheduler",
      children = {},
      extra    = { category = "dbms_scheduler", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":ORDS",
      name     = "ORDS",
      type     = "category",
      path     = conn_name .. "/ORDS",
      children = {},
      extra    = { category = "ords", conn_name = conn_name, loaded = false },
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

---Build child nodes for a list of materialized views with comments.
---@param conn_name string
---@param mviews    {name: string, comment: string}[]
---@return table[]
function M.make_mview_children(conn_name, mviews)
  local children = {}
  for _, mv in ipairs(mviews) do
    table.insert(children, {
      id       = "mview:" .. conn_name .. ":" .. mv.name,
      name     = mv.name,
      type     = "mview",
      path     = conn_name .. "/Materialized Views/" .. mv.name,
      children = {},
      extra    = { conn_name = conn_name, mview_name = mv.name, comment = mv.comment, loaded = false },
    })
  end
  return children
end

---Build child nodes for materialized view logs.
---@param conn_name string
---@param logs      {name: string, master: string}[]
---@return table[]
function M.make_mview_log_children(conn_name, logs)
  local children = {}
  for _, log in ipairs(logs) do
    table.insert(children, {
      id       = "mvlog:" .. conn_name .. ":" .. log.name,
      name     = log.name,
      type     = "mview_log",
      path     = conn_name .. "/Materialized View Logs/" .. log.name,
      children = {},
      extra    = {
        conn_name = conn_name,
        log_table = log.name,
        master    = log.master,
      },
    })
  end
  return children
end

---Build child nodes for a list of synonyms.
---@param conn_name string
---@param synonyms  {name: string, target_owner: string, target_name: string, db_link: string|nil}[]
---@return table[]
function M.make_synonym_children(conn_name, synonyms)
  local children = {}
  for _, syn in ipairs(synonyms) do
    local target = syn.target_owner .. "." .. syn.target_name
    if syn.db_link then
      target = target .. "@" .. syn.db_link
    end
    table.insert(children, {
      id       = "syn:" .. conn_name .. ":" .. syn.name,
      name     = syn.name,
      type     = "synonym",
      path     = conn_name .. "/Synonyms/" .. syn.name,
      children = {},
      extra    = {
        conn_name    = conn_name,
        synonym_name = syn.name,
        target_owner = syn.target_owner,
        target_name  = syn.target_name,
        db_link      = syn.db_link,
        target       = target,
        loaded       = false,
      },
    })
  end
  return children
end

---Build child nodes for a list of sequences.
---@param conn_name string
---@param sequences {name: string, min_value: string, max_value: string, increment_by: string, last_number: string}[]
---@return table[]
function M.make_sequence_children(conn_name, sequences)
  local children = {}
  for _, seq in ipairs(sequences) do
    local detail = "last: " .. seq.last_number
    if seq.increment_by ~= "1" then
      detail = detail .. ", step: " .. seq.increment_by
    end
    table.insert(children, {
      id       = "seq:" .. conn_name .. ":" .. seq.name,
      name     = seq.name,
      type     = "sequence",
      path     = conn_name .. "/Sequences/" .. seq.name,
      children = {},
      extra    = {
        conn_name    = conn_name,
        sequence_name = seq.name,
        min_value    = seq.min_value,
        max_value    = seq.max_value,
        increment_by = seq.increment_by,
        last_number  = seq.last_number,
        detail       = detail,
      },
    })
  end
  return children
end

---Build child nodes for the top-level Indexes category.
---@param conn_name string
---@param indexes   {name: string, table_name: string, index_type: string, uniqueness: string}[]
---@return table[]
function M.make_schema_index_children(conn_name, indexes)
  local children = {}
  for _, idx in ipairs(indexes) do
    local detail = idx.table_name
    if idx.uniqueness == "UNIQUE" then
      detail = detail .. " (UNIQUE)"
    end
    table.insert(children, {
      id       = "sidx:" .. conn_name .. ":" .. idx.name,
      name     = idx.name,
      type     = "schema_index",
      path     = conn_name .. "/Indexes/" .. idx.name,
      children = {},
      extra    = {
        conn_name  = conn_name,
        index_name = idx.name,
        table_name = idx.table_name,
        index_type = idx.index_type,
        uniqueness = idx.uniqueness,
        detail     = detail,
        loaded     = false,
      },
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

---Build child nodes for a list of packages with body info.
---@param conn_name string
---@param pkgs      {name: string, has_body: boolean}[]
---@return table[]
function M.make_package_children(conn_name, pkgs)
  local children = {}
  for _, pkg in ipairs(pkgs) do
    table.insert(children, {
      id       = "pkg:" .. conn_name .. ":" .. pkg.name,
      name     = pkg.name,
      type     = "package",
      path     = conn_name .. "/Packages/" .. pkg.name,
      children = {},
      extra    = { conn_name = conn_name, pkg_name = pkg.name, has_body = pkg.has_body, loaded = false },
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

---Build child nodes for triggers.
---@param conn_name string
---@param triggers  {name: string, table_name: string, trigger_type: string}[]
---@return table[]
function M.make_trigger_children(conn_name, triggers)
  local children = {}
  for _, t in ipairs(triggers) do
    table.insert(children, {
      id       = "trg:" .. conn_name .. ":" .. t.name,
      name     = t.name,
      type     = "trigger",
      path     = conn_name .. "/Triggers/" .. t.name,
      children = {},
      extra    = {
        conn_name    = conn_name,
        trigger_name = t.name,
        table_name   = t.table_name,
        trigger_type = t.trigger_type,
      },
    })
  end
  return children
end

---Build child nodes for user-defined types.
---@param conn_name string
---@param types     {name: string, typecode: string}[]
---@return table[]
function M.make_type_children(conn_name, types)
  local children = {}
  for _, t in ipairs(types) do
    table.insert(children, {
      id       = "typ:" .. conn_name .. ":" .. t.name,
      name     = t.name,
      type     = "ora_type",
      path     = conn_name .. "/Types/" .. t.name,
      children = {},
      extra    = {
        conn_name = conn_name,
        type_name = t.name,
        typecode  = t.typecode,
      },
    })
  end
  return children
end

---Build sub-category nodes for the DBMS Scheduler parent category.
---@param conn_name string
---@return table[]
function M.make_dbms_scheduler_children(conn_name)
  return {
    {
      id       = "cat:" .. conn_name .. ":Scheduler Jobs",
      name     = "Jobs",
      type     = "category",
      path     = conn_name .. "/DBMS Scheduler/Jobs",
      children = {},
      extra    = { category = "scheduler_jobs", conn_name = conn_name, loaded = false },
    },
    {
      id       = "cat:" .. conn_name .. ":Scheduler Programs",
      name     = "Programs",
      type     = "category",
      path     = conn_name .. "/DBMS Scheduler/Programs",
      children = {},
      extra    = { category = "scheduler_programs", conn_name = conn_name, loaded = false },
    },
  }
end

---Build child nodes for scheduler jobs.
---@param conn_name string
---@param jobs      {name: string, job_type: string, state: string, enabled: string}[]
---@return table[]
function M.make_scheduler_job_children(conn_name, jobs)
  local children = {}
  for _, job in ipairs(jobs) do
    table.insert(children, {
      id       = "sjob:" .. conn_name .. ":" .. job.name,
      name     = job.name,
      type     = "scheduler_job",
      path     = conn_name .. "/DBMS Scheduler/Jobs/" .. job.name,
      children = {},
      extra    = {
        conn_name = conn_name,
        job_name  = job.name,
        job_type  = job.job_type,
        state     = job.state,
        enabled   = job.enabled,
        loaded    = false,
      },
    })
  end
  return children
end

---Build child nodes for scheduler programs.
---@param conn_name string
---@param programs  {name: string, program_type: string, enabled: string, number_of_arguments: string}[]
---@return table[]
function M.make_scheduler_program_children(conn_name, programs)
  local children = {}
  for _, prog in ipairs(programs) do
    local enabled_str = prog.enabled == "TRUE" and "ENABLED" or "DISABLED"
    table.insert(children, {
      id       = "sprog:" .. conn_name .. ":" .. prog.name,
      name     = prog.name,
      type     = "scheduler_program",
      path     = conn_name .. "/DBMS Scheduler/Programs/" .. prog.name,
      children = {},
      extra    = {
        conn_name           = conn_name,
        program_name        = prog.name,
        program_type        = prog.program_type,
        enabled             = enabled_str,
        number_of_arguments = prog.number_of_arguments,
        loaded              = false,
      },
    })
  end
  return children
end

---Build child nodes for ORDS modules.
---@param conn_name string
---@param modules   {name: string, uri_prefix: string, id: string}[]
---@return table[]
function M.make_ords_module_children(conn_name, modules)
  local children = {}
  for _, mod in ipairs(modules) do
    table.insert(children, {
      id       = "ords_mod:" .. conn_name .. ":" .. mod.id,
      name     = mod.name,
      type     = "ords_module",
      path     = conn_name .. "/ORDS/" .. mod.name,
      children = {},
      extra    = { conn_name = conn_name, module_id = mod.id, uri_prefix = mod.uri_prefix, loaded = false },
    })
  end
  return children
end

---Build child nodes for ORDS templates.
---@param conn_name   string
---@param module_id   string
---@param module_name string
---@param templates   {uri_template: string, id: string}[]
---@return table[]
function M.make_ords_template_children(conn_name, module_id, module_name, templates)
  local children = {}
  for _, tpl in ipairs(templates) do
    table.insert(children, {
      id       = "ords_tpl:" .. conn_name .. ":" .. tpl.id,
      name     = tpl.uri_template,
      type     = "ords_template",
      path     = conn_name .. "/ORDS/" .. module_id .. "/" .. tpl.uri_template,
      children = {},
      extra    = { conn_name = conn_name, template_id = tpl.id, module_name = module_name, loaded = false },
    })
  end
  return children
end

---Build child nodes for ORDS handlers.
---@param conn_name    string
---@param template_id  string
---@param module_name  string
---@param uri_template string
---@param handlers     {method: string, source_type: string, id: string}[]
---@return table[]
function M.make_ords_handler_children(conn_name, template_id, module_name, uri_template, handlers)
  local children = {}
  for _, h in ipairs(handlers) do
    table.insert(children, {
      id       = "ords_hdl:" .. conn_name .. ":" .. h.id,
      name     = h.method,
      type     = "ords_handler",
      path     = conn_name .. "/ORDS/" .. template_id .. "/" .. h.method,
      children = {},
      extra    = { conn_name = conn_name, handler_id = h.id, method = h.method, source_type = h.source_type, module_name = module_name, uri_template = uri_template, loaded = false },
    })
  end
  return children
end

---Build child nodes for ORDS parameters.
---@param conn_name    string
---@param handler_id   string
---@param module_name  string
---@param uri_template string
---@param method       string
---@param params       {name: string, param_type: string, source_type: string}[]
---@return table[]
function M.make_ords_parameter_children(conn_name, handler_id, module_name, uri_template, method, params)
  local children = {}
  for _, p in ipairs(params) do
    table.insert(children, {
      id       = "ords_param:" .. conn_name .. ":" .. handler_id .. ":" .. p.name,
      name     = p.name,
      type     = "ords_parameter",
      path     = conn_name .. "/ORDS/" .. handler_id .. "/" .. p.name,
      children = {},
      extra    = { conn_name = conn_name, param_type = p.param_type, source_type = p.source_type, module_name = module_name, uri_template = uri_template, method = method },
    })
  end
  return children
end

return M
