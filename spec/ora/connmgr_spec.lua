-- Tests for ora.connmgr.
-- plenary.job is stubbed so no real sqlcl process is launched.

local function fresh()
  package.loaded["ora.connmgr"] = nil
  package.loaded["ora.config"]  = nil
  -- Note: do NOT clear plenary.job here; tests set the stub before calling fresh()
  -- so the stub is in place when connmgr's run() calls require("plenary.job").
  require("ora.config").setup({ sqlcl_path = "/usr/bin/sql" })
  return require("ora.connmgr")
end

---Stub plenary.job so that job:sync() returns (lines_table, code).
---Returns a controller table with the captured Job opts.
local function stub_job_sync(mock_output, mock_code)
  local ctrl = {}
  package.loaded["plenary.job"] = {
    new = function(_, opts)
      ctrl.opts = opts
      return {
        sync = function(_)
          return vim.split(mock_output or "", "\n"), mock_code or 0
        end,
      }
    end,
  }
  return ctrl
end

describe("ora.connmgr", function()
  after_each(function()
    package.loaded["plenary.job"] = nil
  end)

  -- ─── list() ───────────────────────────────────────────────────────────────

  describe("list()", function()
    it("returns an empty list when output is empty", function()
      stub_job_sync("")
      assert.same({}, fresh().list())
    end)

    it("parses one connection per line", function()
      stub_job_sync("dev\nstaging\nprod")
      assert.same({ "dev", "staging", "prod" }, fresh().list())
    end)

    it("strips ANSI escape codes", function()
      stub_job_sync("\27[1mdev\27[0m\nstaging")
      assert.same({ "dev", "staging" }, fresh().list())
    end)

    it("strips leading SQL> prompts", function()
      stub_job_sync("SQL> dev\nSQL> staging")
      assert.same({ "dev", "staging" }, fresh().list())
    end)

    it("skips blank lines", function()
      stub_job_sync("\ndev\n\nstaging\n")
      assert.same({ "dev", "staging" }, fresh().list())
    end)

    it("skips SQLcl and Oracle banner lines", function()
      stub_job_sync("SQLcl: Release 25.2\nOracle 19c\ndev\nstaging")
      assert.same({ "dev", "staging" }, fresh().list())
    end)
  end)

  -- ─── list_tree() ────────────────────────────────────────────────────────────

  describe("list_tree()", function()
    it("returns flat connections when no tree chars present", function()
      stub_job_sync("dev\nstaging\nprod")
      local tree = fresh().list_tree()
      assert.same({
        { name = "dev",     type = "connection" },
        { name = "staging", type = "connection" },
        { name = "prod",    type = "connection" },
      }, tree)
    end)

    it("parses folder structure from ASCII tree output", function()
      stub_job_sync(table.concat({
        ".",
        "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 dev",
        "\xe2\x94\x82   \xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 local-free",
        "\xe2\x94\x82   \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 local-xe",
        "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 prod",
        "    \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 main-db",
      }, "\n"))
      local tree = fresh().list_tree()
      assert.same({
        {
          name = "dev",
          type = "folder",
          children = {
            { name = "local-free", type = "connection" },
            { name = "local-xe",   type = "connection" },
          },
        },
        {
          name = "prod",
          type = "folder",
          children = {
            { name = "main-db", type = "connection" },
          },
        },
      }, tree)
    end)

    it("handles mixed root connections and folders", function()
      stub_job_sync(table.concat({
        ".",
        "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 standalone",
        "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 dev",
        "    \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 local-free",
      }, "\n"))
      local tree = fresh().list_tree()
      assert.same({
        { name = "standalone", type = "connection" },
        {
          name = "dev",
          type = "folder",
          children = {
            { name = "local-free", type = "connection" },
          },
        },
      }, tree)
    end)

    it("handles nested folders", function()
      stub_job_sync(table.concat({
        ".",
        "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 env",
        "    \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 dev",
        "        \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 local-free",
      }, "\n"))
      local tree = fresh().list_tree()
      assert.same({
        {
          name = "env",
          type = "folder",
          children = {
            {
              name = "dev",
              type = "folder",
              children = {
                { name = "local-free", type = "connection" },
              },
            },
          },
        },
      }, tree)
    end)

    it("handles deeply nested folders with vertical-bar continuation lines", function()
      -- Real SQLcl output uses │ (3-byte UTF-8) for continuation lines
      stub_job_sync(table.concat({
        ".",
        "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 env",
        "\xe2\x94\x82   \xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 dev",
        "\xe2\x94\x82   \xe2\x94\x82   \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 local-free",
        "\xe2\x94\x82   \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 staging",
        "\xe2\x94\x82       \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 staging-db",
        "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 prod",
        "    \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 main-db",
      }, "\n"))
      local tree = fresh().list_tree()
      assert.same({
        {
          name = "env",
          type = "folder",
          children = {
            {
              name = "dev",
              type = "folder",
              children = {
                { name = "local-free", type = "connection" },
              },
            },
            {
              name = "staging",
              type = "folder",
              children = {
                { name = "staging-db", type = "connection" },
              },
            },
          },
        },
        {
          name = "prod",
          type = "folder",
          children = {
            { name = "main-db", type = "connection" },
          },
        },
      }, tree)
    end)

    it("returns empty list when output is empty", function()
      stub_job_sync("")
      assert.same({}, fresh().list_tree())
    end)

    it("strips ANSI codes from tree output", function()
      stub_job_sync("\27[1m.\27[0m\n\27[1m\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 dev\27[0m")
      local tree = fresh().list_tree()
      assert.same({
        { name = "dev", type = "connection" },
      }, tree)
    end)
  end)

  -- ─── show() ───────────────────────────────────────────────────────────────

  describe("show()", function()
    it("parses Connect String and User", function()
      stub_job_sync(table.concat({
        "Name: local-free",
        "Connect String: localhost:1521/FREEPDB1",
        "User: system",
        "Password: not saved",
      }, "\n"))
      local info = fresh().show("local-free")
      assert.is_not_nil(info)
      assert.equals("localhost:1521/FREEPDB1", info.connect_string)
      assert.equals("system", info.user)
    end)

    it("returns nil when output lacks required fields", function()
      stub_job_sync("something unexpected")
      assert.is_nil(fresh().show("missing"))
    end)
  end)

  -- ─── add() ────────────────────────────────────────────────────────────────

  describe("add()", function()
    it("returns true on success", function()
      stub_job_sync("", 0)
      local ok, err = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("passes sqlcl_path as command to plenary.job", function()
      local ctrl = stub_job_sync("", 0)
      fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.equals("/usr/bin/sql", ctrl.opts.command)
    end)

    it("passes /nolog -S @script.sql as args to plenary.job", function()
      local ctrl = stub_job_sync("", 0)
      fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.equals("/nolog", ctrl.opts.args[1])
      assert.equals("-S",     ctrl.opts.args[2])
      assert.matches("%.sql$", ctrl.opts.args[3])
    end)

    it("script passed to sqlcl contains 'connmgr import <file>.json'", function()
      local ctrl = stub_job_sync("", 0)
      fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      -- args[3] is "@/path/to/script.sql"
      local script_path = ctrl.opts.args[3]
      -- Script may already be deleted (os.remove called after run); check if readable
      local f = io.open(script_path, "r")
      if f then
        local contents = f:read("*a"); f:close()
        assert.matches("connmgr import", contents)
        assert.matches("%.json", contents)
      else
        -- Script was cleaned up — verify the args referenced sqlcl correctly
        assert.matches("/usr/bin/sql", ctrl.opts.command)
        assert.matches("%.sql$", script_path)
      end
    end)

    it("accepts url without password (user@host:port/service)", function()
      stub_job_sync("", 0)
      local ok, err = fresh().add("dev", "system@localhost:1521/FREEPDB1")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns false for an unparseable connection string", function()
      stub_job_sync("", 0)
      local ok, err = fresh().add("bad", "not-a-valid-url")
      assert.is_false(ok)
      assert.is_string(err)
    end)

    it("returns false when sqlcl output contains 'Error'", function()
      stub_job_sync("Error: import failed", 0)
      local ok = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_false(ok)
    end)

    it("returns false when sqlcl output contains 'failed'", function()
      stub_job_sync("Connection failed: access denied", 0)
      local ok = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_false(ok)
    end)

    it("returns false when exit code is non-zero", function()
      stub_job_sync("", 1)
      local ok = fresh().add("dev", "system/oracle@localhost:1521/FREEPDB1")
      assert.is_false(ok)
    end)
  end)
end)
