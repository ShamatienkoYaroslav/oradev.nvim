-- Tests for ora.result.
-- plenary.job is stubbed so no real sqlcl process is launched.

local function fresh()
  package.loaded["ora.result"] = nil
  package.loaded["ora.config"] = nil
  -- Note: do NOT clear plenary.job here; stub_jobstart() sets it before tests run,
  -- and result.lua requires plenary.job lazily inside run().
  require("ora.config").setup({ sqlcl_path = "/usr/bin/sql" })
  return require("ora.result")
end

---Build a minimal OraWorksheet table for testing.
---@param opts? table
local function make_ws(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false,
    opts.sql_lines or { "SELECT 1 FROM dual;" })
  return {
    bufnr          = bufnr,
    name           = opts.name or "worksheet-test",
    connection     = opts.connection or { key = "dev", label = "dev", is_named = true },
    result_bufnr   = nil,
    result_history = {},
  }
end

---Write a JSON payload to a file so the fake on_exit can read it.
local function write_spool(path, payload)
  local f = assert(io.open(path, "w"))
  f:write(payload)
  f:close()
end

---Stub plenary.job: capture opts, return a controller with fire_exit().
local function stub_jobstart()
  local ctrl = {}
  package.loaded["plenary.job"] = {
    new = function(_, opts)
      ctrl.opts = opts
      return { start = function(_) end }
    end,
  }
  ctrl.fire_exit = function(code)
    ctrl.opts.on_exit(nil, code or 0)
  end
  return ctrl
end

-- ─────────────────────────────────────────────────────────────────────────────

describe("ora.result", function()
  after_each(function()
    package.loaded["plenary.job"] = nil
    while vim.fn.winnr("$") > 1 do vim.cmd("close!") end
  end)

  -- ─── get_or_create_buf ──────────────────────────────────────────────────

  describe("get_or_create_buf()", function()
    it("creates a new buffer for a fresh worksheet", function()
      local ws = make_ws()
      local bufnr = fresh().get_or_create_buf(ws)
      assert.is_number(bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    end)

    it("stores the bufnr on the worksheet", function()
      local ws = make_ws()
      local r = fresh()
      local bufnr = r.get_or_create_buf(ws)
      assert.equals(bufnr, ws.result_bufnr)
    end)

    it("returns the same buffer on subsequent calls", function()
      local ws = make_ws()
      local r = fresh()
      local first  = r.get_or_create_buf(ws)
      local second = r.get_or_create_buf(ws)
      assert.equals(first, second)
    end)

    it("creates a nofile buffer", function()
      local ws = make_ws()
      local bufnr = fresh().get_or_create_buf(ws)
      assert.equals("nofile", vim.api.nvim_buf_get_option(bufnr, "buftype"))
    end)

    it("buffer is not modifiable", function()
      local ws = make_ws()
      local bufnr = fresh().get_or_create_buf(ws)
      assert.is_false(vim.api.nvim_buf_get_option(bufnr, "modifiable"))
    end)

    it("names the buffer ora://result/<ws.name>", function()
      local ws = make_ws({ name = "worksheet-42" })
      local bufnr = fresh().get_or_create_buf(ws)
      assert.matches("ora://result/worksheet%-42", vim.api.nvim_buf_get_name(bufnr))
    end)

    it("recreates the buffer if the previous one was deleted", function()
      local ws  = make_ws()
      local r   = fresh()
      local old = r.get_or_create_buf(ws)
      vim.api.nvim_buf_delete(old, { force = true })
      local new = r.get_or_create_buf(ws)
      assert.is_not_equal(old, new)
      assert.is_true(vim.api.nvim_buf_is_valid(new))
    end)
  end)

  -- ─── set_buf_lines ──────────────────────────────────────────────────────

  describe("set_buf_lines()", function()
    it("writes lines to the buffer", function()
      local ws = make_ws()
      local r  = fresh()
      local bufnr = r.get_or_create_buf(ws)
      r.set_buf_lines(bufnr, { "line1", "line2" })
      assert.same({ "line1", "line2" },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("replaces existing content", function()
      local ws = make_ws()
      local r  = fresh()
      local bufnr = r.get_or_create_buf(ws)
      r.set_buf_lines(bufnr, { "old" })
      r.set_buf_lines(bufnr, { "new1", "new2" })
      assert.same({ "new1", "new2" },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("buffer remains non-modifiable after writing", function()
      local ws = make_ws()
      local r  = fresh()
      local bufnr = r.get_or_create_buf(ws)
      r.set_buf_lines(bufnr, { "x" })
      assert.is_false(vim.api.nvim_buf_get_option(bufnr, "modifiable"))
    end)

    it("does nothing when given an invalid bufnr", function()
      assert.has_no_error(function()
        fresh().set_buf_lines(99999, { "x" })
      end)
    end)
  end)

  -- ─── push_history ───────────────────────────────────────────────────────

  describe("push_history()", function()
    it("appends an entry to result_history", function()
      local ws = make_ws()
      fresh().push_history(ws, "SELECT 1", { "line1" })
      assert.equals(1, #ws.result_history)
    end)

    it("stores sql and lines", function()
      local ws = make_ws()
      fresh().push_history(ws, "SELECT 42", { "row1", "row2" })
      local entry = ws.result_history[1]
      assert.equals("SELECT 42", entry.sql)
      assert.same({ "row1", "row2" }, entry.lines)
    end)

    it("stores a timestamp string", function()
      local ws = make_ws()
      fresh().push_history(ws, "SELECT 1", {})
      assert.is_string(ws.result_history[1].timestamp)
      assert.is_true(#ws.result_history[1].timestamp > 0)
    end)

    it("accumulates multiple entries in order", function()
      local ws = make_ws()
      local r  = fresh()
      r.push_history(ws, "SELECT 1", { "a" })
      r.push_history(ws, "SELECT 2", { "b" })
      assert.equals(2, #ws.result_history)
      assert.equals("SELECT 1", ws.result_history[1].sql)
      assert.equals("SELECT 2", ws.result_history[2].sql)
    end)
  end)

  -- ─── run() — script generation ──────────────────────────────────────────

  describe("run() — script content", function()
    it("calls job with sqlcl_path -name <key> -S @script", function()
      local ctrl = stub_jobstart()
      local ws   = make_ws()
      fresh().run(ws, function() end)
      assert.equals("/usr/bin/sql", ctrl.opts.command)
      assert.equals("-name",        ctrl.opts.args[1])
      assert.equals("dev",          ctrl.opts.args[2])
      assert.equals("-S",           ctrl.opts.args[3])
      assert.matches("^@",          ctrl.opts.args[4])
    end)

    it("uses raw URL for non-named connections", function()
      local ctrl = stub_jobstart()
      local ws   = make_ws({
        connection = { key = "u/p@host:1521/svc", label = "direct", is_named = false }
      })
      fresh().run(ws, function() end)
      assert.equals("/usr/bin/sql",      ctrl.opts.command)
      assert.equals("u/p@host:1521/svc", ctrl.opts.args[1])
      assert.equals("-S",                ctrl.opts.args[2])
    end)

    it("script contains SET SQLFORMAT JSON", function()
      local ctrl = stub_jobstart()
      fresh().run(make_ws(), function() end)
      local script_path = ctrl.opts.args[4]:sub(2)  -- strip leading '@'
      local f = io.open(script_path, "r")
      if f then
        local content = f:read("*a"); f:close()
        assert.matches("SET SQLFORMAT JSON", content)
      end
    end)

    it("script contains SPOOL and SPOOL OFF", function()
      local ctrl = stub_jobstart()
      fresh().run(make_ws(), function() end)
      local script_path = ctrl.opts.args[4]:sub(2)
      local f = io.open(script_path, "r")
      if f then
        local content = f:read("*a"); f:close()
        assert.matches("SPOOL%s+%S+", content)
        assert.matches("SPOOL OFF",   content)
      end
    end)

    it("script contains SET ECHO OFF and SET FEEDBACK OFF", function()
      local ctrl = stub_jobstart()
      fresh().run(make_ws(), function() end)
      local script_path = ctrl.opts.args[4]:sub(2)
      local f = io.open(script_path, "r")
      if f then
        local content = f:read("*a"); f:close()
        assert.matches("SET ECHO OFF",     content)
        assert.matches("SET FEEDBACK OFF", content)
      end
    end)

    it("script contains the worksheet SQL", function()
      local ctrl = stub_jobstart()
      local ws   = make_ws({ sql_lines = { "SELECT * FROM emp;" } })
      fresh().run(ws, function() end)
      local script_path = ctrl.opts.args[4]:sub(2)
      local f = io.open(script_path, "r")
      if f then
        local content = f:read("*a"); f:close()
        assert.matches("SELECT %* FROM emp", content)
      end
    end)

    it("adds a semicolon when the SQL has no terminator", function()
      local ctrl = stub_jobstart()
      local ws   = make_ws({ sql_lines = { "SELECT 1 FROM dual" } })
      fresh().run(ws, function() end)
      local script_path = ctrl.opts.args[4]:sub(2)
      local f = io.open(script_path, "r")
      if f then
        local content = f:read("*a"); f:close()
        assert.matches("SELECT 1 FROM dual;", content)
      end
    end)

    it("returns an error when the worksheet is empty", function()
      local ws = make_ws({ sql_lines = { "", "" } })
      local got_err
      fresh().run(ws, function(_, _, err) got_err = err end)
      assert.is_string(got_err)
      assert.matches("empty", got_err)
    end)
  end)

  -- ─── run() — JSON parsing & table formatting ─────────────────────────────

  describe("run() — result formatting", function()
    local function run_with_spool(spool_content, sql_lines)
      local ctrl     = stub_jobstart()
      local ws       = make_ws({ sql_lines = sql_lines or { "SELECT 1 FROM dual;" } })
      local got_lines, got_err
      fresh().run(ws, function(lines, hl_data, err)
        got_lines = lines
        got_err   = err
      end)

      -- Find the spool path from the script and write our fake content
      local script_path = ctrl.opts.args[4]:sub(2)
      local sf = io.open(script_path, "r")
      if sf then
        local script_content = sf:read("*a"); sf:close()
        local spool_path = script_content:match("SPOOL%s+(%S+)")
        if spool_path and spool_content then
          write_spool(spool_path, spool_content)
        end
      end

      ctrl.fire_exit(0)

      -- on_exit uses vim.schedule; run the event loop tick
      vim.wait(100, function() return got_lines ~= nil or got_err ~= nil end)
      return got_lines, got_err
    end

    it("formats a single-column result as a table", function()
      local json = vim.fn.json_encode({
        results = { {
          columns = { { name = "ID", type = "NUMBER" } },
          items   = { { ID = 1 }, { ID = 2 } },
        } },
      })
      local lines = run_with_spool(json)
      assert.is_table(lines)
      -- header line contains column name; data lines contain values (no border chars)
      local combined = table.concat(lines, "\n")
      assert.matches("ID", combined)
      assert.matches("1",  combined)
      assert.matches("2",  combined)
      -- no box-drawing borders
      assert.is_falsy(combined:match("%+%-%-%-"))
      assert.is_falsy(combined:match("|%s"))
    end)

    it("formats a multi-column result correctly", function()
      local json = vim.fn.json_encode({
        results = { {
          columns = {
            { name = "ID",   type = "NUMBER"   },
            { name = "NAME", type = "VARCHAR2" },
          },
          items = { { ID = 1, NAME = "Alice" } },
        } },
      })
      local lines = run_with_spool(json)
      local combined = table.concat(lines, "\n")
      assert.matches("ID", combined)
      assert.matches("NAME", combined)
      assert.matches("Alice", combined)
    end)

    it("returns '(no rows returned)' when items is empty", function()
      local json = vim.fn.json_encode({
        results = { {
          columns = { { name = "ID", type = "NUMBER" } },
          items   = {},
        } },
      })
      local lines = run_with_spool(json)
      assert.same({ "(no rows returned)" }, lines)
    end)

    it("reports row count at the end", function()
      local json = vim.fn.json_encode({
        results = { {
          columns = { { name = "X", type = "NUMBER" } },
          items   = { { X = 1 }, { X = 2 }, { X = 3 } },
        } },
      })
      local lines = run_with_spool(json)
      assert.equals("(3 rows)", lines[#lines])
    end)

    it("reports singular 'row' for a single result", function()
      local json = vim.fn.json_encode({
        results = { {
          columns = { { name = "X", type = "NUMBER" } },
          items   = { { X = 42 } },
        } },
      })
      local lines = run_with_spool(json)
      assert.equals("(1 row)", lines[#lines])
    end)

    it("returns a parse error message for invalid JSON", function()
      local lines = run_with_spool("not json at all")
      assert.is_table(lines)
      local combined = table.concat(lines, "\n")
      assert.matches("parse error", combined)
    end)

    it("returns an error when spool file is missing", function()
      local _, err = run_with_spool(nil)  -- nil = don't write spool file
      assert.is_string(err)
    end)

    it("returns '(query returned no result set)' for empty results array", function()
      local json = vim.fn.json_encode({ results = {} })
      local lines = run_with_spool(json)
      assert.same({ "(query returned no result set)" }, lines)
    end)

    it("NULL values rendered as 'NULL'", function()
      local json = '{"results":[{"columns":[{"name":"V","type":"VARCHAR2"}],"items":[{"V":null}]}]}'
      local lines = run_with_spool(json)
      local combined = table.concat(lines, "\n")
      assert.matches("NULL", combined)
    end)
  end)

  -- ─── show() ─────────────────────────────────────────────────────────────

  describe("show()", function()
    it("opens a new split showing the buffer", function()
      local ws    = make_ws()
      local r     = fresh()
      local bufnr = r.get_or_create_buf(ws)
      local wins_before = #vim.api.nvim_list_wins()
      r.show(bufnr)
      assert.is_true(#vim.api.nvim_list_wins() > wins_before)
    end)

    it("the new window shows the result buffer", function()
      local ws    = make_ws()
      local r     = fresh()
      local bufnr = r.get_or_create_buf(ws)
      r.show(bufnr)
      assert.equals(bufnr, vim.api.nvim_get_current_buf())
    end)

    it("focuses the existing window when the buffer is already visible", function()
      local ws    = make_ws()
      local r     = fresh()
      local bufnr = r.get_or_create_buf(ws)
      r.show(bufnr)
      local win1  = vim.api.nvim_get_current_win()
      -- open a NEW window with a different buffer, then call show() again
      vim.cmd("new")
      r.show(bufnr)
      assert.equals(win1, vim.api.nvim_get_current_win())
    end)
  end)
end)
