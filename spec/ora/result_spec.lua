-- Tests for ora.result (container), ora.result.query, and ora.result.error.
-- plenary.job is stubbed so no real sqlcl process is launched.

local function fresh()
  package.loaded["ora.result"]         = nil
  package.loaded["ora.result.output"]  = nil
  package.loaded["ora.result.query"]   = nil
  package.loaded["ora.result.error"]   = nil
  package.loaded["ora.result.compile"] = nil
  package.loaded["ora.config"]         = nil
  -- Note: do NOT clear plenary.job here; stub_jobstart() sets it before tests run,
  -- and result runs plenary.job lazily inside run().
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

  -- ─── display ──────────────────────────────────────────────────────────

  describe("display()", function()
    it("sets lines and applies render on the buffer", function()
      local r = fresh()
      local ws = make_ws()
      local bufnr = r.get_or_create_buf(ws)
      local query = require("ora.result.query")
      local json = vim.fn.json_encode({
        results = { {
          columns = { { name = "X", type = "NUMBER" } },
          items   = { { X = 1 } },
        } },
      })
      local output = query.create({ raw = json })
      r.display(bufnr, output)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local combined = table.concat(lines, "\n")
      assert.matches("X", combined)
      assert.matches("1", combined)
    end)

    it("buffer remains non-modifiable after display", function()
      local r = fresh()
      local ws = make_ws()
      local bufnr = r.get_or_create_buf(ws)
      local query = require("ora.result.query")
      local output = query.create({ raw = vim.fn.json_encode({ results = {} }) })
      r.display(bufnr, output)
      assert.is_false(vim.api.nvim_buf_get_option(bufnr, "modifiable"))
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
      fresh().run(ws, function(_, err) got_err = err end)
      assert.is_string(got_err)
      assert.matches("empty", got_err)
    end)
  end)

  -- ─── run() — raw spool delivery ──────────────────────────────────────────

  describe("run() — spool delivery", function()
    local function run_with_spool(spool_content, sql_lines)
      local ctrl     = stub_jobstart()
      local ws       = make_ws({ sql_lines = sql_lines or { "SELECT 1 FROM dual;" } })
      local got_raw, got_err
      fresh().run(ws, function(raw, err)
        got_raw = raw
        got_err = err
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
      vim.wait(100, function() return got_raw ~= nil or got_err ~= nil end)
      return got_raw, got_err
    end

    it("delivers raw spool content to callback", function()
      local json = vim.fn.json_encode({
        results = { {
          columns = { { name = "ID", type = "NUMBER" } },
          items   = { { ID = 1 } },
        } },
      })
      local raw = run_with_spool(json)
      assert.is_string(raw)
      assert.matches("ID", raw)
    end)

    it("returns an error when spool file is missing", function()
      local _, err = run_with_spool(nil)
      assert.is_string(err)
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

-- ─────────────────────────────────────────────────────────────────────────────

describe("ora.result.query", function()
  before_each(function()
    package.loaded["ora.result"]        = nil
    package.loaded["ora.result.output"] = nil
    package.loaded["ora.result.query"]  = nil
  end)

  local function make_output(json)
    local query = require("ora.result.query")
    return query.create({ raw = json })
  end

  it("formats a single-column bordered table", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "ID", type = "NUMBER" } },
        items   = { { ID = 1 }, { ID = 2 } },
      } },
    })
    local output = make_output(json)
    -- Bordered table: top border, header, separator, data rows, bottom border, footer
    assert.is_true(#output.lines >= 6)
    -- Top border uses box-drawing
    assert.matches("┌", output.lines[1])
    assert.matches("┐", output.lines[1])
    -- Header contains column name between │ separators
    assert.matches("│", output.lines[2])
    assert.matches("ID", output.lines[2])
    -- Separator
    assert.matches("├", output.lines[3])
    -- Data rows contain values between │ separators
    local combined = table.concat(output.lines, "\n")
    assert.matches("1", combined)
    assert.matches("2", combined)
    -- Bottom border
    assert.matches("└", output.lines[#output.lines - 1])
  end)

  it("formats a multi-column bordered table", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = {
          { name = "ID",   type = "NUMBER"   },
          { name = "NAME", type = "VARCHAR2" },
        },
        items = { { ID = 1, NAME = "Alice" } },
      } },
    })
    local output = make_output(json)
    local combined = table.concat(output.lines, "\n")
    assert.matches("ID", combined)
    assert.matches("NAME", combined)
    assert.matches("Alice", combined)
    -- Multi-column: borders use ┬ and ┼
    assert.matches("┬", output.lines[1])
    assert.matches("┼", output.lines[3])
  end)

  it("column widths match content", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = {
          { name = "ID",   type = "NUMBER" },
          { name = "LONGNAME", type = "VARCHAR2" },
        },
        items = {
          { ID = 1, LONGNAME = "short" },
          { ID = 2, LONGNAME = "a longer value" },
        },
      } },
    })
    local output = make_output(json)
    -- The top border segment width = content width + 2 (padding).
    -- "ID" col width = 2, so border = ──── (4 dashes). "LONGNAME" col or data max =
    -- "a longer value" = 14, so border = 16 dashes.
    -- Verify header cells are padded to match data:
    -- the header row should have "ID" padded to same width as data "2"
    -- and "LONGNAME" padded to same width as "a longer value"
    local header = output.lines[2]
    -- Both columns should appear in the header
    assert.matches("ID", header)
    assert.matches("LONGNAME", header)
    -- Every data row and header row should have the same byte length
    -- (they all use the same column widths)
    local header_len = #output.lines[2]
    for i = 4, #output.lines - 2 do  -- data rows (skip top, header, sep, bottom, footer)
      assert.equals(header_len, #output.lines[i],
        "data row " .. (i - 3) .. " length mismatch")
    end
    -- Border lines should also have the same visual width
    -- (byte length differs because ─ is 3 bytes, but all border lines are same length)
    assert.equals(#output.lines[1], #output.lines[3])  -- top == separator
    assert.equals(#output.lines[1], #output.lines[#output.lines - 1])  -- top == bottom
  end)

  it("returns '(no rows returned)' when items is empty", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "ID", type = "NUMBER" } },
        items   = {},
      } },
    })
    local output = make_output(json)
    assert.same({ "(no rows returned)" }, output.lines)
  end)

  it("reports row count in footer", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "X", type = "NUMBER" } },
        items   = { { X = 1 }, { X = 2 }, { X = 3 } },
      } },
    })
    local output = make_output(json)
    assert.matches("3 rows", output.lines[#output.lines])
  end)

  it("reports singular 'row' for a single result", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "X", type = "NUMBER" } },
        items   = { { X = 42 } },
      } },
    })
    local output = make_output(json)
    assert.matches("1 row$", output.lines[#output.lines])
  end)

  it("returns a fallback message for invalid JSON", function()
    local output = make_output("not json at all")
    local combined = table.concat(output.lines, "\n")
    assert.matches("not a query result", combined)
  end)

  it("returns '(query returned no result set)' for empty results array", function()
    local json = vim.fn.json_encode({ results = {} })
    local output = make_output(json)
    assert.same({ "(query returned no result set)" }, output.lines)
  end)

  it("NULL values rendered as 'NULL'", function()
    local json = '{"results":[{"columns":[{"name":"V","type":"VARCHAR2"}],"items":[{"V":null}]}]}'
    local output = make_output(json)
    local combined = table.concat(output.lines, "\n")
    assert.matches("NULL", combined)
  end)

  it("has type, label, icon, and render fields", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "X", type = "NUMBER" } },
        items   = { { X = 1 } },
      } },
    })
    local output = make_output(json)
    assert.equals("query", output.type)
    assert.equals("Query Result", output.label)
    assert.is_string(output.icon)
    assert.is_string(output.icon_hl)
    assert.is_function(output.render)
  end)

  it("render applies extmarks without error", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "X", type = "NUMBER" } },
        items   = { { X = 1 } },
      } },
    })
    local output = make_output(json)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, output.lines)
    assert.has_no_error(function()
      output:render(bufnr)
    end)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("produces correct bordered structure for known input", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "X", type = "NUMBER" } },
        items   = { { X = 42 } },
      } },
    })
    local output = make_output(json)
    -- Expected:
    --   ┌────┐
    --   │ X  │
    --   ├────┤
    --   │ 42 │
    --   └────┘
    --    1 row
    assert.equals(6, #output.lines)
    assert.equals("┌────┐", output.lines[1])
    assert.equals("│ X  │", output.lines[2])
    assert.equals("├────┤", output.lines[3])
    assert.equals("│ 42 │", output.lines[4])
    assert.equals("└────┘", output.lines[5])
    assert.equals(" 1 row", output.lines[6])
  end)

  it("truncates CLOB values that exceed max column width", function()
    local long_val = string.rep("A", 200)
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "DOC", type = "CLOB" } },
        items   = { { DOC = long_val } },
      } },
    })
    local output = make_output(json)
    -- Data row should not contain the full 200-char value
    local data_row = output.lines[4]  -- after top border, header, separator
    assert.is_true(#data_row < 200 + 20)  -- much shorter than raw value + borders
    -- Should end with truncation marker … somewhere in the row
    local combined = table.concat(output.lines, "\n")
    assert.matches("…", combined)
  end)

  it("flattens newlines in CLOB values", function()
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "DOC", type = "CLOB" } },
        items   = { { DOC = "line1\nline2\nline3" } },
      } },
    })
    local output = make_output(json)
    -- All output lines should be part of the table structure, not raw newlines
    -- The value should appear flattened into a single data row
    local data_row = output.lines[4]
    assert.matches("line1 line2 line3", data_row)
  end)

  it("truncates any column type exceeding max width", function()
    local long_val = string.rep("X", 200)
    local json = vim.fn.json_encode({
      results = { {
        columns = { { name = "V", type = "VARCHAR2" } },
        items   = { { V = long_val } },
      } },
    })
    local output = make_output(json)
    local combined = table.concat(output.lines, "\n")
    assert.matches("…", combined)
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────

describe("ora.result.error", function()
  before_each(function()
    package.loaded["ora.result"]        = nil
    package.loaded["ora.result.output"] = nil
    package.loaded["ora.result.query"]  = nil
    package.loaded["ora.result.error"]  = nil
  end)

  local function make_error(raw)
    local err = require("ora.result.error")
    return err.create({ raw = raw })
  end

  local function is_error(raw)
    return require("ora.result.error").is_error(raw)
  end

  -- ─── is_error detection ─────────────────────────────────────────────────

  describe("is_error()", function()
    it("detects ORA error codes", function()
      assert.is_true(is_error("ORA-00942: table or view does not exist"))
    end)

    it("detects SQL Error prefix", function()
      assert.is_true(is_error("SQL Error: ORA-00942: table or view does not exist"))
    end)

    it("detects PLS error codes", function()
      assert.is_true(is_error("PLS-00201: identifier must be declared"))
    end)

    it("detects SP2 error codes", function()
      assert.is_true(is_error("SP2-0734: unknown command"))
    end)

    it("detects multi-line error with 'Error starting at line'", function()
      local raw = table.concat({
        "Error starting at line : 5 File @ /tmp/script.sql",
        "In command -",
        "select * from all_objects1",
        "Error at Command Line : 5 Column : 15 File @ /tmp/script.sql",
        "Error report -",
        "SQL Error: ORA-00942: table or view does not exist",
      }, "\n")
      assert.is_true(is_error(raw))
    end)

    it("returns false for valid JSON query output", function()
      local json = '{"results":[{"columns":[{"name":"X"}],"items":[{"X":1}]}]}'
      assert.is_false(is_error(json))
    end)

    it("returns false for empty output", function()
      assert.is_false(is_error(""))
    end)
  end)

  -- ─── error parsing and formatting ───────────────────────────────────────

  describe("create()", function()
    it("extracts ORA error code and message", function()
      local output = make_error("SQL Error: ORA-00942: table or view does not exist")
      local combined = table.concat(output.lines, "\n")
      assert.matches("ORA%-00942", combined)
      assert.matches("table or view does not exist", combined)
    end)

    it("extracts error from full SQLcl error output", function()
      local raw = table.concat({
        "Error starting at line : 5 File @ /tmp/nvim.root/aaVXH1/4.sql",
        "In command -",
        "select * from all_objects1",
        "Error at Command Line : 5 Column : 15 File @ /tmp/nvim.root/aaVXH1/4.sql",
        "Error report -",
        "SQL Error: ORA-00942: table or view does not exist",
        "",
        "https://docs.oracle.com/error-help/db/ora-00942/",
        "00942. 000",
      }, "\n")
      local output = make_error(raw)
      local combined = table.concat(output.lines, "\n")
      -- Shows the error code and message
      assert.matches("ORA%-00942", combined)
      assert.matches("table or view does not exist", combined)
      -- Shows the URL
      assert.matches("https://docs.oracle.com", combined)
      -- Does NOT show noise lines
      assert.is_falsy(combined:match("Error starting at line"))
      assert.is_falsy(combined:match("Error at Command Line"))
      assert.is_falsy(combined:match("In command"))
      assert.is_falsy(combined:match("Error report"))
      assert.is_falsy(combined:match("select %* from all_objects1"))
      assert.is_falsy(combined:match("00942%. 000"))
    end)

    it("handles PLS errors", function()
      local raw = "PLS-00201: identifier 'NONEXISTENT' must be declared"
      local output = make_error(raw)
      local combined = table.concat(output.lines, "\n")
      assert.matches("PLS%-00201", combined)
      assert.matches("identifier", combined)
    end)

    it("handles multiple errors", function()
      local raw = table.concat({
        "ORA-06550: line 2, column 3:",
        "PLS-00201: identifier 'FOO' must be declared",
      }, "\n")
      local output = make_error(raw)
      local combined = table.concat(output.lines, "\n")
      assert.matches("ORA%-06550", combined)
      assert.matches("PLS%-00201", combined)
    end)

    it("has error output type fields", function()
      local output = make_error("ORA-00942: table or view does not exist")
      assert.equals("error", output.type)
      assert.equals("Error", output.label)
      assert.is_string(output.icon)
      assert.is_string(output.icon_hl)
      assert.is_function(output.render)
    end)

    it("render applies extmarks without error", function()
      local output = make_error("ORA-00942: table or view does not exist")
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, output.lines)
      assert.has_no_error(function()
        output:render(bufnr)
      end)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("produces output for unknown error text", function()
      local output = make_error("something went wrong")
      assert.is_true(#output.lines > 0)
      local combined = table.concat(output.lines, "\n")
      assert.matches("something went wrong", combined)
    end)
  end)

  -- ─── compile output ─────────────────────────────────────────────────────

  describe("compile", function()
    local function make_compile(raw, opts)
      fresh()
      local compile = require("ora.result.compile")
      opts = opts or {}
      return compile.create({
        raw         = raw,
        object_name = opts.object_name or "MY_PKG",
        object_type = opts.object_type or "PACKAGE BODY",
      })
    end

    it("shows success for clean output", function()
      local output = make_compile("")
      assert.equals("compile", output.type)
      assert.equals("Compiled", output.label)
      local combined = table.concat(output.lines, "\n")
      assert.matches("Compiled successfully", combined)
      assert.matches("PACKAGE BODY MY_PKG", combined)
    end)

    it("delegates to error output on compilation failure", function()
      local raw = "PLS-00103: Encountered the symbol \"END\""
      local output = make_compile(raw)
      assert.equals("Compilation Failed", output.label)
      local combined = table.concat(output.lines, "\n")
      assert.matches("PLS%-00103", combined)
    end)

    it("has correct output type fields for success", function()
      local output = make_compile("")
      assert.is_string(output.icon)
      assert.is_string(output.icon_hl)
      assert.equals("DiagnosticOk", output.icon_hl)
    end)

    it("render applies extmarks without error", function()
      local output = make_compile("")
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, output.lines)
      assert.has_no_error(function()
        output:render(bufnr)
      end)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("includes object name and type in success output", function()
      local output = make_compile("", { object_name = "CALC_SALARY", object_type = "FUNCTION" })
      local combined = table.concat(output.lines, "\n")
      assert.matches("FUNCTION CALC_SALARY", combined)
    end)
  end)

  -- ─── worksheet object_kind ──────────────────────────────────────────────

  describe("worksheet.object_kind()", function()
    local ws_mod
    before_each(function()
      package.loaded["ora.worksheet"] = nil
      ws_mod = require("ora.worksheet")
    end)

    it("returns 'soft' for PACKAGE BODY", function()
      assert.equals("soft", ws_mod.object_kind("PACKAGE BODY"))
    end)

    it("returns 'soft' for FUNCTION", function()
      assert.equals("soft", ws_mod.object_kind("FUNCTION"))
    end)

    it("returns 'soft' for TYPE", function()
      assert.equals("soft", ws_mod.object_kind("TYPE"))
    end)

    it("returns 'soft' for VIEW", function()
      assert.equals("soft", ws_mod.object_kind("VIEW"))
    end)

    it("returns 'hard' for TABLE", function()
      assert.equals("hard", ws_mod.object_kind("TABLE"))
    end)

    it("returns 'hard' for INDEX", function()
      assert.equals("hard", ws_mod.object_kind("INDEX"))
    end)
  end)
end)
