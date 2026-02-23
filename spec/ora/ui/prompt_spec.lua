-- Tests for ora.ui.prompt.
-- vim.ui.input is stubbed to control what the "user" types.

local function fresh()
  package.loaded["ora.ui.prompt"] = nil
  return require("ora.ui.prompt")
end

describe("ora.ui.prompt", function()
  local orig_input

  before_each(function()
    orig_input = vim.ui.input
  end)

  after_each(function()
    vim.ui.input = orig_input
  end)

  describe("ask_connection_string()", function()
    it("passes a prompt string to vim.ui.input", function()
      local received_opts
      vim.ui.input = function(opts, _)
        received_opts = opts
      end

      local p = fresh()
      p.ask_connection_string(function() end)

      assert.is_string(received_opts.prompt)
      assert.is_true(#received_opts.prompt > 0)
    end)

    it("calls on_confirm with the user's input", function()
      vim.ui.input = function(_, callback)
        callback("scott/tiger@localhost:1521/XEPDB1")
      end

      local p = fresh()
      local result
      p.ask_connection_string(function(url) result = url end)

      assert.equals("scott/tiger@localhost:1521/XEPDB1", result)
    end)

    it("does NOT call on_confirm when input is nil (user cancelled)", function()
      vim.ui.input = function(_, callback)
        callback(nil)
      end

      local p = fresh()
      local called = false
      p.ask_connection_string(function() called = true end)

      assert.is_false(called)
    end)

    it("does NOT call on_confirm when input is an empty string", function()
      vim.ui.input = function(_, callback)
        callback("")
      end

      local p = fresh()
      local called = false
      p.ask_connection_string(function() called = true end)

      assert.is_false(called)
    end)

    it("passes the exact non-empty string to on_confirm unchanged", function()
      local raw = "  user / pass@host:1521/svc  "
      vim.ui.input = function(_, callback) callback(raw) end

      local p = fresh()
      local got
      p.ask_connection_string(function(url) got = url end)

      assert.equals(raw, got)
    end)
  end)
end)
