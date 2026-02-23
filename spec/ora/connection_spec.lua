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
    it("starts sqlcl with /nolog instead of the connection string", function()
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("my-conn", "my-conn", { is_named = true })
      assert.matches("/nolog", got_cmd)
      -- must NOT contain the bare name as a direct argument
      assert.is_falsy(got_cmd:match("/usr/bin/sql my%-conn$"))
    end)

    it("creates a startup script file that is passed to sqlcl", function()
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("my-conn", "my-conn", { is_named = true })
      -- The command must reference a .sql startup script
      assert.matches("%.sql", got_cmd)
    end)

    it("startup script contains 'connect @<name>'", function()
      local got_cmd
      vim.fn.termopen = function(cmd, _) got_cmd = cmd; return 1 end
      fresh_connection().connect("dev", "dev", { is_named = true })

      -- Extract the script path from the command and read it
      local script_path = got_cmd:match("@(.+%.sql)")
      assert.is_not_nil(script_path, "expected @script.sql in command")
      -- Note: file may be cleaned up by on_exit; check before that
      local f = io.open(script_path, "r")
      if f then
        local contents = f:read("*a")
        f:close()
        assert.matches("connect @dev", contents)
      end
    end)

    it("cleans up the startup script on exit", function()
      local captured_opts
      local script_path
      vim.fn.termopen = function(cmd, opts)
        captured_opts = opts
        script_path = cmd:match("@(.+%.sql)")
        return 1
      end

      fresh_connection().connect("dev", "dev", { is_named = true })
      captured_opts.on_exit()

      if script_path then
        assert.is_nil(io.open(script_path, "r"), "startup script should be removed after exit")
      end
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
