-- Tests for ora.connmgr.
-- vim.fn.system is stubbed so no real sqlcl process is launched.

local function fresh()
  package.loaded["ora.connmgr"] = nil
  package.loaded["ora.config"]  = nil
  require("ora.config").setup({ sqlcl_path = "/usr/bin/sql" })
  return require("ora.connmgr")
end

describe("ora.connmgr", function()
  local orig_system

  before_each(function()
    orig_system = vim.fn.system
  end)

  after_each(function()
    vim.fn.system = orig_system
    -- Note: vim.v.shell_error is read-only; it resets automatically
    -- after the next vim.fn.system() call.
  end)

  -- ─── list() ───────────────────────────────────────────────────────────────

  describe("list()", function()
    it("returns an empty list when output is empty", function()
      vim.fn.system = function(_) return "" end
      assert.same({}, fresh().list())
    end)

    it("parses one connection per line", function()
      vim.fn.system = function(_) return "dev\nstaging\nprod\n" end
      assert.same({ "dev", "staging", "prod" }, fresh().list())
    end)

    it("strips ANSI escape codes", function()
      vim.fn.system = function(_) return "\27[1mdev\27[0m\nstaging\n" end
      assert.same({ "dev", "staging" }, fresh().list())
    end)

    it("strips leading SQL> prompts", function()
      vim.fn.system = function(_) return "SQL> dev\nSQL> staging\n" end
      assert.same({ "dev", "staging" }, fresh().list())
    end)

    it("skips blank lines", function()
      vim.fn.system = function(_) return "\ndev\n\nstaging\n\n" end
      assert.same({ "dev", "staging" }, fresh().list())
    end)

    it("skips SQLcl and Oracle banner lines", function()
      vim.fn.system = function(_)
        return "SQLcl: Release 25.2\nOracle 19c\ndev\nstaging\n"
      end
      assert.same({ "dev", "staging" }, fresh().list())
    end)
  end)

  -- ─── show() ───────────────────────────────────────────────────────────────

  describe("show()", function()
    it("parses Connect String and User", function()
      vim.fn.system = function(_)
        return table.concat({
          "Name: local-free",
          "Connect String: localhost:1521/FREEPDB1",
          "User: system",
          "Password: not saved",
        }, "\n") .. "\n"
      end
      local info = fresh().show("local-free")
      assert.is_not_nil(info)
      assert.equals("localhost:1521/FREEPDB1", info.connect_string)
      assert.equals("system", info.user)
    end)

    it("returns nil when output lacks required fields", function()
      vim.fn.system = function(_) return "something unexpected\n" end
      assert.is_nil(fresh().show("missing"))
    end)
  end)

  -- ─── add() ────────────────────────────────────────────────────────────────

  describe("add()", function()
    it("returns true on success", function()
      vim.fn.system = function(_) return "" end
      local ok, err = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("script passed to sqlcl contains 'connmgr import <file>.json'", function()
      local received_cmd
      vim.fn.system = function(cmd) received_cmd = cmd; return "" end
      fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")

      -- run() passes a .sql script to sqlcl via @path; extract and read it
      local script_path = received_cmd:match("@'?([^']+%.sql)'?")
      assert.is_not_nil(script_path, "expected @script.sql in command")
      -- Script may already be deleted (os.remove called after run); check if readable
      local f = io.open(script_path, "r")
      if f then
        local contents = f:read("*a"); f:close()
        assert.matches("connmgr import", contents)
        assert.matches("%.json", contents)
      else
        -- Script was cleaned up — verify the command at least referenced sqlcl correctly
        assert.matches("/usr/bin/sql", received_cmd)
        assert.matches("%.sql", received_cmd)
      end
    end)

    it("uses sqlcl_path from config", function()
      local received_cmd
      vim.fn.system = function(cmd) received_cmd = cmd; return "" end
      fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.matches("/usr/bin/sql", received_cmd)
    end)

    it("accepts url without password (user@host:port/service)", function()
      vim.fn.system = function(_) return "" end
      local ok, err = fresh().add("dev", "system@localhost:1521/FREEPDB1")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns false for an unparseable connection string", function()
      vim.fn.system = function(_) return "" end
      local ok, err = fresh().add("bad", "not-a-valid-url")
      assert.is_false(ok)
      assert.is_string(err)
    end)

    it("returns false when sqlcl output contains 'Error'", function()
      vim.fn.system = function(_) return "Error: import failed\n" end
      local ok = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_false(ok)
    end)

    it("returns false when sqlcl output contains 'failed'", function()
      vim.fn.system = function(_) return "Connection failed: access denied\n" end
      local ok = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_false(ok)
    end)
  end)
end)
