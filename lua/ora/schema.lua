-- Schema module: fetches Oracle data dictionary metadata via one-shot SQLcl jobs.
-- Uses the same async plenary.Job pattern as result.lua.

local M = {}

local run_multi_query -- forward declaration (defined below run_query)

---Run a single-column query against a connection and return the values async.
---@param conn {key: string, is_named: boolean}
---@param sql  string   SQL that returns a single column
---@param callback fun(names: string[]|nil, err: string|nil)
local function run_query(conn, sql, callback)
  local cfg = require("ora.config").values

  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local columns = rs.columns or {}
        local items   = rs.items or {}

        if #columns == 0 then
          callback({}, nil)
          return
        end

        local col_name = columns[1].name
        local names = {}
        for _, item in ipairs(items) do
          local v = item[col_name] or item[col_name:lower()]
          if v and v ~= vim.NIL then
            table.insert(names, tostring(v))
          end
        end
        callback(names, nil)
      end)
    end,
  }):start()
end

---Run a DDL query via DBMS_METADATA.GET_DDL with proper CLOB handling.
---Uses plain text spool (no JSON) with SET LONG to avoid truncation.
---@param conn        {key: string, is_named: boolean}
---@param object_type string  e.g. "TABLE", "VIEW"
---@param object_name string
---@param callback    fun(lines: string[]|nil, err: string|nil)
local function run_ddl_query(conn, object_type, object_name, callback)
  local cfg = require("ora.config").values

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET HEADING OFF\n")
  f:write("SET PAGESIZE 0\n")
  f:write("SET LINESIZE 32767\n")
  f:write("SET LONG 1000000\n")
  f:write("SET LONGCHUNKSIZE 1000000\n")
  f:write("SET TRIMSPOOL ON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(string.format(
    "SELECT DBMS_METADATA.GET_DDL('%s', '%s') FROM dual;\n",
    object_type, object_name
  ))
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local lines = {}
        for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
          line = line:gsub("%s+$", "")
          table.insert(lines, line)
        end
        -- Trim trailing empty lines
        while #lines > 0 and lines[#lines] == "" do
          table.remove(lines)
        end
        callback(lines, nil)
      end)
    end,
  }):start()
end

---Fetch view names with comments from user_views + user_tab_comments.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(views: {name: string, comment: string|nil}[]|nil, err: string|nil)
function M.fetch_views_with_comments(conn, callback)
  local cfg = require("ora.config").values
  local sql = "SELECT v.view_name, c.comments " ..
    "FROM user_views v " ..
    "LEFT JOIN user_tab_comments c ON c.table_name = v.view_name " ..
    "ORDER BY v.view_name;"

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local views = {}
        for _, item in ipairs(items) do
          local name = item.VIEW_NAME or item.view_name
          local cmt  = item.COMMENTS or item.comments
          if name and name ~= vim.NIL then
            local comment = (cmt and cmt ~= vim.NIL) and tostring(cmt) or nil
            table.insert(views, { name = tostring(name), comment = comment })
          end
        end
        callback(views, nil)
      end)
    end,
  }):start()
end

---Fetch DDL for a view via DBMS_METADATA.
---Uses plain text spool with SET LONG to avoid CLOB truncation.
---@param conn      {key: string, is_named: boolean}
---@param view_name string
---@param callback  fun(lines: string[]|nil, err: string|nil)
function M.fetch_view_ddl(conn, view_name, callback)
  run_ddl_query(conn, "VIEW", view_name, callback)
end

---Fetch table names from user_tables.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(names: string[]|nil, err: string|nil)
function M.fetch_tables(conn, callback)
  run_query(conn, "SELECT table_name FROM user_tables ORDER BY table_name", callback)
end

---Fetch table names with their comments from user_tables + user_tab_comments.
---Returns {name, comment} pairs; comment may be nil.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(tables: {name: string, comment: string|nil}[]|nil, err: string|nil)
function M.fetch_tables_with_comments(conn, callback)
  local cfg = require("ora.config").values
  local sql = "SELECT t.table_name, c.comments " ..
    "FROM user_tables t " ..
    "LEFT JOIN user_tab_comments c ON c.table_name = t.table_name " ..
    "ORDER BY t.table_name;"

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local tables = {}
        for _, item in ipairs(items) do
          local name = item.TABLE_NAME or item.table_name
          local cmt  = item.COMMENTS or item.comments
          if name and name ~= vim.NIL then
            local comment = (cmt and cmt ~= vim.NIL) and tostring(cmt) or nil
            table.insert(tables, { name = tostring(name), comment = comment })
          end
        end
        callback(tables, nil)
      end)
    end,
  }):start()
end

---Fetch the table comment from user_tab_comments.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(comment: string|nil, err: string|nil)
function M.fetch_table_comment(conn, table_name, callback)
  run_query(conn, string.format(
    "SELECT comments FROM user_tab_comments WHERE table_name = '%s' AND comments IS NOT NULL",
    table_name
  ), function(names, err)
    if err then
      callback(nil, err)
    elseif names and #names > 0 then
      callback(names[1], nil)
    else
      callback(nil, nil)
    end
  end)
end

---Fetch column names for a specific table.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(names: string[]|nil, err: string|nil)
function M.fetch_columns(conn, table_name, callback)
  run_query(conn, string.format(
    "SELECT column_name FROM user_tab_columns WHERE table_name = '%s' ORDER BY column_id",
    table_name
  ), callback)
end

---Fetch column names with data types for a specific table.
---Returns {name, data_type} pairs.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(cols: {name: string, data_type: string}[]|nil, err: string|nil)
function M.fetch_columns_with_types(conn, table_name, callback)
  local cfg = require("ora.config").values
  local sql = string.format(
    "SELECT column_name, data_type FROM user_tab_columns WHERE table_name = '%s' ORDER BY column_id",
    table_name
  )
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local cols = {}
        for _, item in ipairs(items) do
          local name = item.COLUMN_NAME or item.column_name
          local dtype = item.DATA_TYPE or item.data_type
          if name and name ~= vim.NIL then
            table.insert(cols, {
              name = tostring(name),
              data_type = tostring(dtype or ""),
            })
          end
        end
        callback(cols, nil)
      end)
    end,
  }):start()
end

---Fetch index names for a specific table.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(names: string[]|nil, err: string|nil)
function M.fetch_indexes(conn, table_name, callback)
  run_query(conn, string.format(
    "SELECT index_name FROM user_indexes WHERE table_name = '%s' ORDER BY index_name",
    table_name
  ), callback)
end

---Fetch constraint names for a specific table.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(names: string[]|nil, err: string|nil)
function M.fetch_constraints(conn, table_name, callback)
  run_query(conn, string.format(
    "SELECT constraint_name FROM user_constraints WHERE table_name = '%s' ORDER BY constraint_name",
    table_name
  ), callback)
end

---Fetch column comments for a specific table.
---Returns {column, text} pairs for columns that have a non-null comment.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(comments: {column: string, text: string}[]|nil, err: string|nil)
function M.fetch_comments(conn, table_name, callback)
  local cfg = require("ora.config").values
  local sql = string.format(
    "SELECT column_name, comments FROM user_col_comments WHERE table_name = '%s' AND comments IS NOT NULL ORDER BY column_name",
    table_name
  )
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local comments = {}
        for _, item in ipairs(items) do
          local col  = item.COLUMN_NAME or item.column_name
          local text = item.COMMENTS or item.comments
          if col and col ~= vim.NIL and text and text ~= vim.NIL then
            table.insert(comments, { column = tostring(col), text = tostring(text) })
          end
        end
        callback(comments, nil)
      end)
    end,
  }):start()
end

---Fetch function names from user_objects.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(names: string[]|nil, err: string|nil)
function M.fetch_functions(conn, callback)
  run_query(conn,
    "SELECT object_name FROM user_objects WHERE object_type = 'FUNCTION' ORDER BY object_name",
    callback)
end

---Fetch function names with their return types from user_arguments.
---Returns {name, return_type} pairs.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(funcs: {name: string, return_type: string}[]|nil, err: string|nil)
function M.fetch_functions_with_return_type(conn, callback)
  local cfg = require("ora.config").values
  local sql = "SELECT object_name, data_type FROM user_arguments " ..
    "WHERE package_name IS NULL AND argument_name IS NULL AND position = 0 " ..
    "AND object_name IN (SELECT object_name FROM user_objects WHERE object_type = 'FUNCTION') " ..
    "ORDER BY object_name;"

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local funcs = {}
        for _, item in ipairs(items) do
          local name = item.OBJECT_NAME or item.object_name
          local dtype = item.DATA_TYPE or item.data_type
          if name and name ~= vim.NIL then
            table.insert(funcs, {
              name = tostring(name),
              return_type = tostring(dtype or ""),
            })
          end
        end
        callback(funcs, nil)
      end)
    end,
  }):start()
end

---Fetch procedure names from user_objects.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(names: string[]|nil, err: string|nil)
function M.fetch_procedures(conn, callback)
  run_query(conn,
    "SELECT object_name FROM user_objects WHERE object_type = 'PROCEDURE' ORDER BY object_name",
    callback)
end

---Fetch package names from user_objects.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(names: string[]|nil, err: string|nil)
function M.fetch_packages(conn, callback)
  local sql = "SELECT p.object_name, " ..
    "CASE WHEN b.object_name IS NOT NULL THEN 'Y' ELSE 'N' END AS has_body " ..
    "FROM user_objects p " ..
    "LEFT JOIN user_objects b ON b.object_name = p.object_name AND b.object_type = 'PACKAGE BODY' " ..
    "WHERE p.object_type = 'PACKAGE' " ..
    "ORDER BY p.object_name"
  run_multi_query(conn, sql, function(items, err)
    if err then
      callback(nil, err)
      return
    end
    local pkgs = {}
    for _, item in ipairs(items or {}) do
      local name = item.OBJECT_NAME or item.object_name
      local body = item.HAS_BODY or item.has_body
      if name and name ~= vim.NIL then
        table.insert(pkgs, {
          name = tostring(name),
          has_body = body == "Y",
        })
      end
    end
    callback(pkgs, nil)
  end)
end

---Fetch the source code of a PL/SQL object (package spec, package body, etc.).
---@param conn        {key: string, is_named: boolean}
---@param object_name string
---@param object_type string  e.g. "PACKAGE", "PACKAGE BODY", "FUNCTION", "PROCEDURE"
---@param callback    fun(lines: string[]|nil, err: string|nil)
function M.fetch_source(conn, object_name, object_type, callback)
  run_query(conn, string.format(
    "SELECT text FROM user_source WHERE name = '%s' AND type = '%s' ORDER BY line",
    object_name, object_type
  ), callback)
end

---Fetch DDL for a table via DBMS_METADATA.
---Uses plain text spool with SET LONG to avoid CLOB truncation.
---@param conn       {key: string, is_named: boolean}
---@param table_name string
---@param callback   fun(lines: string[]|nil, err: string|nil)
function M.fetch_ddl(conn, table_name, callback)
  run_ddl_query(conn, "TABLE", table_name, callback)
end

---Fetch DDL for any object type via DBMS_METADATA.GET_DDL.
---The metadata_type must be the DBMS_METADATA name (e.g. "PACKAGE_BODY", not "PACKAGE BODY").
---@param conn          {key: string, is_named: boolean}
---@param metadata_type string  e.g. "TABLE", "FUNCTION", "PROCEDURE", "PACKAGE", "PACKAGE_BODY", "VIEW", "INDEX", "SYNONYM"
---@param object_name   string
---@param callback      fun(lines: string[]|nil, err: string|nil)
function M.fetch_object_ddl(conn, metadata_type, object_name, callback)
  run_ddl_query(conn, metadata_type, object_name, callback)
end

---Generate a DROP DDL statement for an object via DBMS_METADATA.
---@param conn        {key: string, is_named: boolean}
---@param object_type string  e.g. "TABLE", "PACKAGE", "PACKAGE BODY", "FUNCTION", "PROCEDURE", "VIEW"
---@param object_name string
---@param callback    fun(lines: string[]|nil, err: string|nil)
function M.fetch_drop_ddl(conn, object_type, object_name, callback)
  local sql = string.format(
    "SELECT 'DROP %s ' || object_name || ';' FROM user_objects " ..
    "WHERE object_name = '%s' AND object_type = '%s'",
    object_type, object_name, object_type
  )
  run_query(conn, sql, callback)
end

---Check if a package body exists.
---@param conn     {key: string, is_named: boolean}
---@param pkg_name string
---@param callback fun(has_body: boolean, err: string|nil)
function M.fetch_package_has_body(conn, pkg_name, callback)
  run_query(conn, string.format(
    "SELECT object_name FROM user_objects WHERE object_name = '%s' AND object_type = 'PACKAGE BODY'",
    pkg_name
  ), function(names, err)
    if err then
      callback(false, err)
    else
      callback(names ~= nil and #names > 0, nil)
    end
  end)
end

---Fetch subprogram names (procedures/functions) inside a package.
---@param conn     {key: string, is_named: boolean}
---@param pkg_name string
---@param callback fun(names: string[]|nil, err: string|nil)
function M.fetch_package_subprograms(conn, pkg_name, callback)
  run_query(conn, string.format(
    "SELECT procedure_name FROM user_procedures WHERE object_name = '%s' AND procedure_name IS NOT NULL ORDER BY subprogram_id",
    pkg_name
  ), callback)
end

---Fetch subprogram names inside a package with return types for functions.
---Returns {name, return_type} pairs; return_type is nil for procedures.
---@param conn     {key: string, is_named: boolean}
---@param pkg_name string
---@param callback fun(subs: {name: string, return_type: string|nil}[]|nil, err: string|nil)
function M.fetch_package_subprograms_with_types(conn, pkg_name, callback)
  local cfg = require("ora.config").values
  local sql = string.format(
    "SELECT p.procedure_name, a.data_type " ..
    "FROM user_procedures p " ..
    "LEFT JOIN user_arguments a ON a.package_name = p.object_name " ..
      "AND a.object_name = p.procedure_name AND a.argument_name IS NULL AND a.position = 0 " ..
      "AND a.subprogram_id = p.subprogram_id " ..
    "WHERE p.object_name = '%s' AND p.procedure_name IS NOT NULL " ..
    "ORDER BY p.subprogram_id",
    pkg_name
  )
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local subs = {}
        for _, item in ipairs(items) do
          local name = item.PROCEDURE_NAME or item.procedure_name
          local dtype = item.DATA_TYPE or item.data_type
          if name and name ~= vim.NIL then
            local rt = (dtype and dtype ~= vim.NIL) and tostring(dtype) or nil
            table.insert(subs, { name = tostring(name), return_type = rt })
          end
        end
        callback(subs, nil)
      end)
    end,
  }):start()
end

---Fetch parameters for a subprogram inside a package.
---Returns {name, type} pairs.
---@param conn     {key: string, is_named: boolean}
---@param pkg_name string
---@param sub_name string
---@param callback fun(params: {name: string, type: string}[]|nil, err: string|nil)
function M.fetch_subprogram_params(conn, pkg_name, sub_name, callback)
  local cfg = require("ora.config").values
  local sql = string.format(
    "SELECT argument_name, data_type FROM user_arguments WHERE package_name = '%s' AND object_name = '%s' AND argument_name IS NOT NULL ORDER BY position",
    pkg_name, sub_name
  )
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local params = {}
        for _, item in ipairs(items) do
          local name = item.ARGUMENT_NAME or item.argument_name
          local dtype = item.DATA_TYPE or item.data_type
          if name and name ~= vim.NIL then
            table.insert(params, {
              name = tostring(name),
              type = tostring(dtype or ""),
            })
          end
        end
        callback(params, nil)
      end)
    end,
  }):start()
end

---Fetch parameters for a standalone function or procedure (not inside a package).
---Returns {name, type} pairs.
---@param conn        {key: string, is_named: boolean}
---@param object_name string
---@param callback    fun(params: {name: string, type: string}[]|nil, err: string|nil)
function M.fetch_object_params(conn, object_name, callback)
  local cfg = require("ora.config").values
  local sql = string.format(
    "SELECT argument_name, data_type FROM user_arguments WHERE package_name IS NULL AND object_name = '%s' AND argument_name IS NOT NULL ORDER BY position",
    object_name
  )
  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        local items = rs.items or {}
        local params = {}
        for _, item in ipairs(items) do
          local name = item.ARGUMENT_NAME or item.argument_name
          local dtype = item.DATA_TYPE or item.data_type
          if name and name ~= vim.NIL then
            table.insert(params, {
              name = tostring(name),
              type = tostring(dtype or ""),
            })
          end
        end
        callback(params, nil)
      end)
    end,
  }):start()
end

---Run a multi-column JSON query and return parsed items async.
---@param conn     {key: string, is_named: boolean}
---@param sql      string
---@param callback fun(items: table[]|nil, err: string|nil)
run_multi_query = function(conn, sql, callback)
  local cfg = require("ora.config").values

  if not sql:match("[;/]%s*$") then sql = sql .. ";" end

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET SQLFORMAT JSON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local ok, parsed = pcall(vim.fn.json_decode, vim.trim(raw))
        if not ok or not parsed or not parsed.results or #parsed.results == 0 then
          callback(nil, "failed to parse query output")
          return
        end

        local rs = parsed.results[1]
        callback(rs.items or {}, nil)
      end)
    end,
  }):start()
end

---Fetch all indexes with table name and index type from user_indexes.
---Returns {name, table_name, index_type, uniqueness}[].
---@param conn     {key: string, is_named: boolean}
---@param callback fun(indexes: {name: string, table_name: string, index_type: string, uniqueness: string}[]|nil, err: string|nil)
function M.fetch_all_indexes(conn, callback)
  run_multi_query(conn,
    "SELECT i.INDEX_NAME, i.TABLE_NAME, i.INDEX_TYPE, i.UNIQUENESS FROM user_indexes i ORDER BY i.INDEX_NAME",
    function(items, err)
      if err then callback(nil, err); return end
      local indexes = {}
      for _, item in ipairs(items or {}) do
        local name = item.INDEX_NAME or item.index_name
        local tname = item.TABLE_NAME or item.table_name
        local itype = item.INDEX_TYPE or item.index_type
        local uniq = item.UNIQUENESS or item.uniqueness
        if name and name ~= vim.NIL then
          table.insert(indexes, {
            name = tostring(name),
            table_name = (tname and tname ~= vim.NIL) and tostring(tname) or "",
            index_type = (itype and itype ~= vim.NIL) and tostring(itype) or "",
            uniqueness = (uniq and uniq ~= vim.NIL) and tostring(uniq) or "",
          })
        end
      end
      callback(indexes, nil)
    end)
end

---Fetch DDL for an index via DBMS_METADATA.
---@param conn       {key: string, is_named: boolean}
---@param index_name string
---@param callback   fun(lines: string[]|nil, err: string|nil)
function M.fetch_index_ddl(conn, index_name, callback)
  run_ddl_query(conn, "INDEX", index_name, callback)
end

---Fetch synonyms with their targets from user_synonyms.
---Returns {name, target_owner, target_name, db_link}[].
---@param conn     {key: string, is_named: boolean}
---@param callback fun(synonyms: {name: string, target_owner: string, target_name: string, db_link: string|nil}[]|nil, err: string|nil)
function M.fetch_synonyms(conn, callback)
  run_multi_query(conn,
    "SELECT s.SYNONYM_NAME, s.TABLE_OWNER, s.TABLE_NAME, s.DB_LINK FROM user_synonyms s ORDER BY s.SYNONYM_NAME",
    function(items, err)
      if err then callback(nil, err); return end
      local synonyms = {}
      for _, item in ipairs(items or {}) do
        local name = item.SYNONYM_NAME or item.synonym_name
        local owner = item.TABLE_OWNER or item.table_owner
        local tname = item.TABLE_NAME or item.table_name
        local dblink = item.DB_LINK or item.db_link
        if name and name ~= vim.NIL then
          table.insert(synonyms, {
            name = tostring(name),
            target_owner = (owner and owner ~= vim.NIL) and tostring(owner) or "",
            target_name = (tname and tname ~= vim.NIL) and tostring(tname) or "",
            db_link = (dblink and dblink ~= vim.NIL and tostring(dblink) ~= "") and tostring(dblink) or nil,
          })
        end
      end
      callback(synonyms, nil)
    end)
end

---Fetch DDL for a synonym via DBMS_METADATA.
---@param conn         {key: string, is_named: boolean}
---@param synonym_name string
---@param callback     fun(lines: string[]|nil, err: string|nil)
function M.fetch_synonym_ddl(conn, synonym_name, callback)
  run_ddl_query(conn, "SYNONYM", synonym_name, callback)
end

---Fetch sequences from user_sequences.
---Returns {name, min_value, max_value, increment_by, last_number}[].
---@param conn     {key: string, is_named: boolean}
---@param callback fun(sequences: {name: string, min_value: string, max_value: string, increment_by: string, last_number: string}[]|nil, err: string|nil)
function M.fetch_sequences(conn, callback)
  run_multi_query(conn,
    "SELECT sequence_name, min_value, max_value, increment_by, last_number FROM user_sequences ORDER BY sequence_name",
    function(items, err)
      if err then callback(nil, err); return end
      local sequences = {}
      for _, item in ipairs(items or {}) do
        local name = item.SEQUENCE_NAME or item.sequence_name
        local minv = item.MIN_VALUE or item.min_value
        local maxv = item.MAX_VALUE or item.max_value
        local incr = item.INCREMENT_BY or item.increment_by
        local last = item.LAST_NUMBER or item.last_number
        if name and name ~= vim.NIL then
          table.insert(sequences, {
            name         = tostring(name),
            min_value    = (minv and minv ~= vim.NIL) and tostring(minv) or "",
            max_value    = (maxv and maxv ~= vim.NIL) and tostring(maxv) or "",
            increment_by = (incr and incr ~= vim.NIL) and tostring(incr) or "1",
            last_number  = (last and last ~= vim.NIL) and tostring(last) or "",
          })
        end
      end
      callback(sequences, nil)
    end)
end

---Fetch ORDS modules for a connection.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(modules: {name: string, uri_prefix: string, id: string}[]|nil, err: string|nil)
function M.fetch_ords_modules(conn, callback)
  run_multi_query(conn, "SELECT id, name, uri_prefix FROM user_ords_modules ORDER BY name", function(items, err)
    if err then callback(nil, err); return end
    local modules = {}
    for _, item in ipairs(items or {}) do
      local name = item.NAME or item.name
      local prefix = item.URI_PREFIX or item.uri_prefix
      local id = item.ID or item.id
      if name and name ~= vim.NIL then
        table.insert(modules, {
          name = tostring(name),
          uri_prefix = (prefix and prefix ~= vim.NIL) and tostring(prefix) or "",
          id = tostring(id or ""),
        })
      end
    end
    callback(modules, nil)
  end)
end

---Fetch ORDS templates for a module.
---@param conn      {key: string, is_named: boolean}
---@param module_id string
---@param callback  fun(templates: {uri_template: string, id: string}[]|nil, err: string|nil)
function M.fetch_ords_templates(conn, module_id, callback)
  run_multi_query(conn,
    string.format("SELECT id, uri_template FROM user_ords_templates WHERE module_id = %s ORDER BY uri_template", module_id),
    function(items, err)
      if err then callback(nil, err); return end
      local templates = {}
      for _, item in ipairs(items or {}) do
        local tpl = item.URI_TEMPLATE or item.uri_template
        local id = item.ID or item.id
        if tpl and tpl ~= vim.NIL then
          table.insert(templates, {
            uri_template = tostring(tpl),
            id = tostring(id or ""),
          })
        end
      end
      callback(templates, nil)
    end)
end

---Fetch ORDS handlers for a template.
---@param conn        {key: string, is_named: boolean}
---@param template_id string
---@param callback    fun(handlers: {method: string, source_type: string, id: string}[]|nil, err: string|nil)
function M.fetch_ords_handlers(conn, template_id, callback)
  run_multi_query(conn,
    string.format("SELECT id, source_type, method FROM user_ords_handlers WHERE template_id = %s ORDER BY method", template_id),
    function(items, err)
      if err then callback(nil, err); return end
      local handlers = {}
      for _, item in ipairs(items or {}) do
        local method = item.METHOD or item.method
        local stype = item.SOURCE_TYPE or item.source_type
        local id = item.ID or item.id
        if method and method ~= vim.NIL then
          table.insert(handlers, {
            method = tostring(method),
            source_type = (stype and stype ~= vim.NIL) and tostring(stype) or "",
            id = tostring(id or ""),
          })
        end
      end
      callback(handlers, nil)
    end)
end

---Fetch ORDS parameters for a handler.
---@param conn       {key: string, is_named: boolean}
---@param handler_id string
---@param callback   fun(params: {name: string, param_type: string, source_type: string}[]|nil, err: string|nil)
function M.fetch_ords_parameters(conn, handler_id, callback)
  run_multi_query(conn,
    string.format("SELECT name, param_type, source_type FROM user_ords_parameters WHERE handler_id = %s ORDER BY name", handler_id),
    function(items, err)
      if err then callback(nil, err); return end
      local params = {}
      for _, item in ipairs(items or {}) do
        local name = item.NAME or item.name
        local ptype = item.PARAM_TYPE or item.param_type
        local stype = item.SOURCE_TYPE or item.source_type
        if name and name ~= vim.NIL then
          table.insert(params, {
            name = tostring(name),
            param_type = (ptype and ptype ~= vim.NIL) and tostring(ptype) or "",
            source_type = (stype and stype ~= vim.NIL) and tostring(stype) or "",
          })
        end
      end
      callback(params, nil)
    end)
end

---Fetch details of a single ORDS module from user_ords_modules.
---@param conn        {key: string, is_named: boolean}
---@param module_name string
---@param callback    fun(details: {name: string, uri_prefix: string, items_per_page: string, status: string, comments: string|nil}|nil, err: string|nil)
function M.fetch_ords_module_details(conn, module_name, callback)
  run_multi_query(conn,
    string.format(
      "SELECT name, uri_prefix, items_per_page, status, comments " ..
      "FROM user_ords_modules WHERE name = '%s'",
      module_name
    ),
    function(items, err)
      if err then callback(nil, err); return end
      if not items or #items == 0 then callback(nil, nil); return end
      local item = items[1]
      local name = item.NAME or item.name
      local prefix = item.URI_PREFIX or item.uri_prefix
      local ipp = item.ITEMS_PER_PAGE or item.items_per_page
      local status = item.STATUS or item.status
      local cmt = item.COMMENTS or item.comments
      callback({
        name           = (name and name ~= vim.NIL) and tostring(name) or "",
        uri_prefix     = (prefix and prefix ~= vim.NIL) and tostring(prefix) or "",
        items_per_page = (ipp and ipp ~= vim.NIL) and tostring(ipp) or "25",
        status         = (status and status ~= vim.NIL) and tostring(status) or "PUBLISHED",
        comments       = (cmt and cmt ~= vim.NIL) and tostring(cmt) or nil,
      }, nil)
    end)
end

---Fetch details of a single ORDS template from user_ords_templates.
---@param conn        {key: string, is_named: boolean}
---@param template_id string
---@param callback    fun(details: {uri_template: string, module_name: string, priority: string, etag_type: string, etag_query: string|nil, comments: string|nil}|nil, err: string|nil)
function M.fetch_ords_template_details(conn, template_id, callback)
  run_multi_query(conn,
    string.format(
      "SELECT t.uri_template, m.name AS module_name, t.priority, t.etag_type, t.etag_query, t.comments " ..
      "FROM user_ords_templates t " ..
      "JOIN user_ords_modules m ON m.id = t.module_id " ..
      "WHERE t.id = %s",
      template_id
    ),
    function(items, err)
      if err then callback(nil, err); return end
      if not items or #items == 0 then callback(nil, nil); return end
      local item = items[1]
      local tpl   = item.URI_TEMPLATE or item.uri_template
      local mname = item.MODULE_NAME or item.module_name
      local pri   = item.PRIORITY or item.priority
      local etype = item.ETAG_TYPE or item.etag_type
      local eq    = item.ETAG_QUERY or item.etag_query
      local cmt   = item.COMMENTS or item.comments
      callback({
        uri_template = (tpl and tpl ~= vim.NIL) and tostring(tpl) or "",
        module_name  = (mname and mname ~= vim.NIL) and tostring(mname) or "",
        priority     = (pri and pri ~= vim.NIL) and tostring(pri) or "0",
        etag_type    = (etype and etype ~= vim.NIL) and tostring(etype) or "HASH",
        etag_query   = (eq and eq ~= vim.NIL) and tostring(eq) or nil,
        comments     = (cmt and cmt ~= vim.NIL) and tostring(cmt) or nil,
      }, nil)
    end)
end

---Fetch details of a single ORDS handler from user_ords_handlers (without source CLOB).
---@param conn       {key: string, is_named: boolean}
---@param handler_id string
---@param callback   fun(details: {method: string, source_type: string, module_name: string, uri_template: string, mimes_allowed: string|nil, comments: string|nil}|nil, err: string|nil)
function M.fetch_ords_handler_details(conn, handler_id, callback)
  run_multi_query(conn,
    string.format(
      "SELECT h.method, h.source_type, h.mimes_allowed, h.comments, " ..
      "t.uri_template, m.name AS module_name " ..
      "FROM user_ords_handlers h " ..
      "JOIN user_ords_templates t ON t.id = h.template_id " ..
      "JOIN user_ords_modules m ON m.id = t.module_id " ..
      "WHERE h.id = %s",
      handler_id
    ),
    function(items, err)
      if err then callback(nil, err); return end
      if not items or #items == 0 then callback(nil, nil); return end
      local item = items[1]
      local method = item.METHOD or item.method
      local stype  = item.SOURCE_TYPE or item.source_type
      local mimes  = item.MIMES_ALLOWED or item.mimes_allowed
      local cmt    = item.COMMENTS or item.comments
      local tpl    = item.URI_TEMPLATE or item.uri_template
      local mname  = item.MODULE_NAME or item.module_name
      callback({
        method        = (method and method ~= vim.NIL) and tostring(method) or "",
        source_type   = (stype and stype ~= vim.NIL) and tostring(stype) or "",
        mimes_allowed = (mimes and mimes ~= vim.NIL) and tostring(mimes) or nil,
        comments      = (cmt and cmt ~= vim.NIL) and tostring(cmt) or nil,
        uri_template  = (tpl and tpl ~= vim.NIL) and tostring(tpl) or "",
        module_name   = (mname and mname ~= vim.NIL) and tostring(mname) or "",
      }, nil)
    end)
end

---Fetch all templates and handlers for an ORDS module by joining user_ords_* tables.
---Returns handler rows with their template context (no source CLOB).
---@param conn      {key: string, is_named: boolean}
---@param module_id string
---@param callback  fun(rows: {uri_template: string, method: string, source_type: string, handler_id: string}[]|nil, err: string|nil)
function M.fetch_ords_module_handlers(conn, module_id, callback)
  local sql = string.format(
    "SELECT t.uri_template, h.method, h.source_type, h.id AS handler_id " ..
    "FROM user_ords_templates t " ..
    "JOIN user_ords_handlers h ON h.template_id = t.id " ..
    "WHERE t.module_id = %s " ..
    "ORDER BY t.uri_template, h.method",
    module_id
  )
  run_multi_query(conn, sql, function(items, err)
    if err then callback(nil, err); return end
    local rows = {}
    for _, item in ipairs(items or {}) do
      local tpl    = item.URI_TEMPLATE or item.uri_template
      local method = item.METHOD or item.method
      local stype  = item.SOURCE_TYPE or item.source_type
      local hid    = item.HANDLER_ID or item.handler_id
      if tpl and tpl ~= vim.NIL then
        table.insert(rows, {
          uri_template = tostring(tpl),
          method       = (method and method ~= vim.NIL) and tostring(method) or "",
          source_type  = (stype and stype ~= vim.NIL) and tostring(stype) or "",
          handler_id   = tostring(hid or ""),
        })
      end
    end
    callback(rows, nil)
  end)
end

---Run a CLOB-returning SELECT and return the plain-text result as lines.
---@param conn     {key: string, is_named: boolean}
---@param sql      string  SQL that returns a single CLOB column
---@param callback fun(lines: string[]|nil, err: string|nil)
local function run_clob_query(conn, sql, callback)
  local cfg = require("ora.config").values

  local spool  = vim.fn.tempname() .. ".log"
  local script = vim.fn.tempname() .. ".sql"

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("SET HEADING OFF\n")
  f:write("SET PAGESIZE 0\n")
  f:write("SET LINESIZE 32767\n")
  f:write("SET LONG 1000000\n")
  f:write("SET LONGCHUNKSIZE 1000000\n")
  f:write("SET TRIMSPOOL ON\n")
  f:write("SPOOL " .. spool .. "\n")
  f:write(sql .. "\n")
  f:write("SPOOL OFF\n")
  f:write("EXIT\n")
  f:close()

  local args
  if conn.is_named then
    args = { cfg.sqlcl_path, "-name", conn.key, "-S", "@" .. script }
  else
    args = { cfg.sqlcl_path, conn.key, "-S", "@" .. script }
  end

  local Job = require("plenary.job")
  Job:new({
    command = args[1],
    args    = vim.list_slice(args, 2),
    on_exit = function(_, code)
      os.remove(script)

      local fh = io.open(spool, "r")
      if not fh then
        vim.schedule(function()
          callback(nil, "spool file missing (sqlcl exited with code " .. code .. ")")
        end)
        return
      end
      local raw = fh:read("*a")
      fh:close()
      os.remove(spool)

      vim.schedule(function()
        if code ~= 0 and vim.trim(raw) == "" then
          callback(nil, "sqlcl exited with code " .. code)
          return
        end

        local lines = {}
        for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
          line = line:gsub("%s+$", "")
          table.insert(lines, line)
        end
        while #lines > 0 and lines[#lines] == "" do
          table.remove(lines)
        end
        callback(lines, nil)
      end)
    end,
  }):start()
end

---Fetch the source code of an ORDS handler.
---The source column is a CLOB, so we use plain text spool with SET LONG.
---@param conn       {key: string, is_named: boolean}
---@param handler_id string
---@param callback   fun(lines: string[]|nil, err: string|nil)
function M.fetch_ords_handler_source(conn, handler_id, callback)
  local sql = string.format(
    "SELECT source FROM user_ords_handlers WHERE id = %s;",
    handler_id
  )
  run_clob_query(conn, sql, callback)
end

---Fetch objects matching a name pattern from user_objects.
---Pattern is uppercased; if no `%` present, wraps as `%PATTERN%`.
---Returns {name, object_type}[] via callback.
---@param conn     {key: string, is_named: boolean}
---@param pattern  string
---@param callback fun(objects: {name: string, object_type: string}[]|nil, err: string|nil)
function M.fetch_objects_by_pattern(conn, pattern, callback)
  pattern = pattern:upper()
  if not pattern:find("%%") then
    pattern = "%%" .. pattern .. "%%"
  end
  local sql = string.format(
    "SELECT object_name, object_type FROM user_objects " ..
    "WHERE object_name LIKE '%s' " ..
    "AND object_type IN ('TABLE','VIEW','INDEX','SYNONYM','SEQUENCE','TRIGGER','TYPE','TYPE BODY','FUNCTION','PROCEDURE','PACKAGE','PACKAGE BODY') " ..
    "ORDER BY object_type, object_name",
    pattern
  )
  run_multi_query(conn, sql, function(items, err)
    if err then callback(nil, err); return end
    local objects = {}
    for _, item in ipairs(items or {}) do
      local name = item.OBJECT_NAME or item.object_name
      local otype = item.OBJECT_TYPE or item.object_type
      if name and name ~= vim.NIL then
        table.insert(objects, {
          name = tostring(name),
          object_type = (otype and otype ~= vim.NIL) and tostring(otype) or "",
        })
      end
    end
    callback(objects, nil)
  end)
end

---Fetch the full ORDS schema export via ORDS_METADATA.ORDS_EXPORT.EXPORT_SCHEMA.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(lines: string[]|nil, err: string|nil)
function M.fetch_ords_export_schema(conn, callback)
  run_clob_query(conn, "SELECT ORDS_METADATA.ORDS_EXPORT.EXPORT_SCHEMA FROM dual;", callback)
end

---Fetch a single module export via ORDS_METADATA.ORDS_EXPORT.EXPORT_MODULE.
---@param conn        {key: string, is_named: boolean}
---@param module_name string
---@param callback    fun(lines: string[]|nil, err: string|nil)
function M.fetch_ords_export_module(conn, module_name, callback)
  local sql = string.format(
    "SELECT ORDS_METADATA.ORDS_EXPORT.EXPORT_MODULE(p_module_name => '%s') FROM dual;",
    module_name
  )
  run_clob_query(conn, sql, callback)
end

---Fetch triggers from user_triggers.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(triggers: {name: string, table_name: string, trigger_type: string}[]|nil, err: string|nil)
function M.fetch_triggers(conn, callback)
  run_multi_query(conn,
    "SELECT trigger_name, table_name, trigger_type FROM user_triggers ORDER BY trigger_name",
    function(items, err)
      if err then callback(nil, err); return end
      local triggers = {}
      for _, item in ipairs(items or {}) do
        local name  = item.TRIGGER_NAME  or item.trigger_name
        local tname = item.TABLE_NAME    or item.table_name
        local ttype = item.TRIGGER_TYPE  or item.trigger_type
        if name and name ~= vim.NIL then
          table.insert(triggers, {
            name         = tostring(name),
            table_name   = (tname and tname ~= vim.NIL) and tostring(tname) or "",
            trigger_type = (ttype and ttype ~= vim.NIL) and tostring(ttype) or "",
          })
        end
      end
      callback(triggers, nil)
    end)
end

---Check whether a TYPE BODY exists for a given type.
---@param conn      {key: string, is_named: boolean}
---@param type_name string
---@param callback  fun(has_body: boolean, err: string|nil)
function M.fetch_type_has_body(conn, type_name, callback)
  run_query(conn, string.format(
    "SELECT object_name FROM user_objects WHERE object_name = '%s' AND object_type = 'TYPE BODY'",
    type_name
  ), function(names, err)
    if err then
      callback(false, err)
    else
      callback(names ~= nil and #names > 0, nil)
    end
  end)
end

---Fetch user-defined types from user_types.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(types: {name: string, typecode: string}[]|nil, err: string|nil)
function M.fetch_types(conn, callback)
  run_multi_query(conn,
    "SELECT type_name, typecode FROM user_types ORDER BY type_name",
    function(items, err)
      if err then callback(nil, err); return end
      local types = {}
      for _, item in ipairs(items or {}) do
        local name = item.TYPE_NAME or item.type_name
        local code = item.TYPECODE  or item.typecode
        if name and name ~= vim.NIL then
          table.insert(types, {
            name     = tostring(name),
            typecode = (code and code ~= vim.NIL) and tostring(code) or "",
          })
        end
      end
      callback(types, nil)
    end)
end

return M
