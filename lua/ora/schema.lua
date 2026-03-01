-- Schema module: fetches Oracle data dictionary metadata via one-shot SQLcl jobs.
-- Uses the same async plenary.Job pattern as result.lua.

local M = {}

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
  run_query(conn,
    "SELECT object_name FROM user_objects WHERE object_type = 'PACKAGE' ORDER BY object_name",
    callback)
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

return M
