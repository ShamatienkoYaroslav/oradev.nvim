-- Tests for ora.connection.
--
-- vim.fn.termopen is stubbed so sqlcl is never actually launched.
-- vim.cmd calls (botright new, startinsert) run against the real headless nvim.

local function setup_config(overrides)
  package.loaded["ora.config"] = nil
  local cfg = require("ora.config")
  cfg.setup(vim.tbl_extend("force", { sqlcl_path = "/usr/bin/sql" }, overrides or {}))
  return cfg
end

local function fresh_connection()
  package.loaded["ora.connection"] = nil
  return require("ora.connection")
end

describe("ora.connection", function()
  local orig_termopen

  before_each(function()
    orig_termopen = vim.fn.termopen
    setup_config()
  end)

  after_each(function()
    vim.fn.termopen = orig_termopen
    while vim.fn.winnr("$") > 1 do vim.cmd("close!") end
  end)

  describe("active_sessions()", function()
    it("returns an empty list when no connections have been made", function()
      assert.same({}, fresh_connection().active_sessions())
    end)
  end)

  describe("connect() — plain connection string", function()
    it("calls termopen with 'sqlcl_path url'", function()
      local captured = {}
      vim.fn.termopen = function(cmd, opts)
        table.insert(captured, { cmd = cmd, opts = opts })
        return 1
      end

      fresh_connection().connect("scott/tiger@localhost:1521/XEPDB1", "dev")

      assert.equals(1, #captured)
      assert.equals(
        "/usr/bin/sql scott/tiger@localhost:1521/XEPDB1",
        captured[1].cmd
      )
    end)

    it("passes an on_exit callback to termopen", function()
      local captured_opts
      vim.fn.termopen = function(_, opts) captured_opts = opts; return 1 end

      fresh_connection().connect("u/p@h:1521/s", "label")

      assert.is_function(captured_opts and captured_opts.on_exit)
    end)

    it("names the buffer 'ora://<label>'", function()
      vim.fn.termopen = function(_, _) return 1 end
      fresh_connection().connect("u/p@h:1521/s", "my-conn")

      local found = false
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(bufnr):match("^ora://my%-conn") then
          found = true; break
        end
      end
      assert.is_true(found)
    end)

    it("uses sqlcl_path from config", function()
      setup_config({ sqlcl_path = "/custom/sql" })
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("u/p@h:1521/s", "x")
      assert.matches("^/custom/sql ", got_cmd)
    end)

    it("calls termopen exactly once per new URL", function()
      local n = 0
      vim.fn.termopen = function(_, _) n = n + 1; return 1 end
      fresh_connection().connect("u/p@h:1521/s", "x")
      assert.equals(1, n)
    end)
  end)

  describe("connect() — named connmgr connection (is_named=true)", function()
    it("passes -name <conn> to sqlcl", function()
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("my-conn", "my-conn", { is_named = true })
      assert.matches("-name", got_cmd)
      assert.matches("my%-conn", got_cmd)
    end)

    it("does NOT use /nolog or a startup script", function()
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("dev", "dev", { is_named = true })
      assert.is_falsy(got_cmd:match("/nolog"))
      assert.is_falsy(got_cmd:match("%.sql"))
    end)

    it("uses sqlcl_path from config with -name flag", function()
      setup_config({ sqlcl_path = "/custom/sql" })
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("dev", "dev", { is_named = true })
      assert.matches("^/custom/sql %-name", got_cmd)
    end)
  end)

  describe("on_exit callback", function()
    it("is callable without error", function()
      local captured_opts
      vim.fn.termopen = function(_, opts) captured_opts = opts; return 1 end
      fresh_connection().connect("u/p@h:1521/s", "x")
      assert.has_no_error(function() captured_opts.on_exit() end)
    end)

    it("leaves active_sessions() in a stable state after exit", function()
      local captured_opts
      vim.fn.termopen = function(_, opts) captured_opts = opts; return 1 end
      local conn = fresh_connection()
      conn.connect("u/p@h:1521/s", "x")
      captured_opts.on_exit()
      assert.has_no_error(function() conn.active_sessions() end)
    end)
  end)
end)
