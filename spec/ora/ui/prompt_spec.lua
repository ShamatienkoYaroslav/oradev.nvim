-- Tests for ora.ui.prompt.
-- nui.input is stubbed to control what the "user" types.
-- Stub must be set BEFORE fresh() because prompt.lua requires nui.input at load time.

---Stub nui.input so that mount() immediately calls on_submit with the given value.
local function stub_nui_input(value)
  package.loaded["nui.input"] = function(_, opts)
    return {
      mount = function()
        if value ~= nil then
          opts.on_submit(value)
        end
      end,
    }
  end
end

local function fresh()
  package.loaded["ora.ui.prompt"] = nil
  -- Note: do NOT clear nui.input here; tests set the stub before calling fresh()
  -- so prompt.lua picks up the stub when it does `local Input = require("nui.input")`.
  return require("ora.ui.prompt")
end

describe("ora.ui.prompt", function()
  after_each(function()
    package.loaded["nui.input"]     = nil
    package.loaded["ora.ui.prompt"] = nil
  end)

  describe("ask_connection_string()", function()
    it("creates a nui.input with a non-empty border title", function()
      local received_cfg
      package.loaded["nui.input"] = function(cfg, _)
        received_cfg = cfg
        return { mount = function() end }
      end

      local p = fresh()
      p.ask_connection_string(function() end)

      assert.is_not_nil(received_cfg)
      assert.is_not_nil(received_cfg.border)
      local top = received_cfg.border.text and received_cfg.border.text.top or ""
      assert.is_true(#top > 0)
    end)

    it("calls callback with the user's input", function()
      stub_nui_input("scott/tiger@localhost:1521/XEPDB1")
      local p = fresh()
      local result
      p.ask_connection_string(function(url) result = url end)
      assert.equals("scott/tiger@localhost:1521/XEPDB1", result)
    end)

    it("does NOT call callback when on_submit receives nil (user cancelled)", function()
      stub_nui_input(nil)  -- mount() won't call on_submit
      local p = fresh()
      local called = false
      p.ask_connection_string(function() called = true end)
      assert.is_false(called)
    end)

    it("does NOT call callback when on_submit receives empty string", function()
      stub_nui_input("")
      local p = fresh()
      local called = false
      p.ask_connection_string(function() called = true end)
      assert.is_false(called)
    end)

    it("passes the exact non-empty string to callback unchanged", function()
      local raw = "  user / pass@host:1521/svc  "
      stub_nui_input(raw)
      local p = fresh()
      local got
      p.ask_connection_string(function(url) got = url end)
      assert.equals(raw, got)
    end)
  end)
end)
