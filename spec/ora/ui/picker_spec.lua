-- Tests for ora.ui.picker.
-- ora.connmgr.list is stubbed so no real sqlcl process is launched.
-- vim.fn.termopen is stubbed so no real sqlcl session is started.

local function setup_config()
  package.loaded["ora.config"] = nil
  require("ora.config").setup({ sqlcl_path = "/usr/bin/sql" })
end

local function fresh_picker()
  package.loaded["ora.ui.picker"]      = nil
  package.loaded["ora.ui.prompt"]      = nil
  package.loaded["ora.ui.add_connection"] = nil
  package.loaded["ora.connection"]     = nil
  package.loaded["ora.connmgr"]        = nil
  return require("ora.ui.picker")
end

local function stub_connmgr(names)
  package.loaded["ora.connmgr"] = { list = function() return names end }
end

local function float_wins()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      table.insert(out, win)
    end
  end
  return out
end

local function close_floats()
  for _, win in ipairs(float_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
end

describe("ora.ui.picker", function()
  local orig_input
  local orig_termopen

  before_each(function()
    orig_input    = vim.ui.input
    orig_termopen = vim.fn.termopen
    vim.fn.termopen = function(_, _) return 1 end
    setup_config()
  end)

  after_each(function()
    vim.ui.input    = orig_input
    vim.fn.termopen = orig_termopen
    close_floats()
    while vim.fn.winnr("$") > 1 do vim.cmd("close!") end
  end)

  describe("open() — no connections in connmgr", function()
    it("falls through to vim.ui.input directly", function()
      local picker = fresh_picker()
      stub_connmgr({})  -- stub AFTER fresh so it isn't wiped

      local input_called = false
      vim.ui.input = function(_, _) input_called = true end

      local before = #float_wins()
      picker.open()

      assert.is_true(input_called)
      assert.equals(before, #float_wins())
    end)
  end)

  describe("open() — with connections from connmgr", function()
    local connections = { "dev", "staging" }

    it("opens exactly one floating window", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      local before = #float_wins()
      picker.open()
      assert.equals(before + 1, #float_wins())
    end)

    it("floating window uses rounded border", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local wins = float_wins()
      local cfg  = vim.api.nvim_win_get_config(wins[#wins])
      local border = cfg.border
      if type(border) == "string" then
        assert.equals("rounded", border)
      else
        assert.equals("table", type(border))
      end
    end)

    it("floating window width matches config.win_width", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local cfg = vim.api.nvim_win_get_config(float_wins()[1])
      assert.equals(60, cfg.width)
    end)

    it("does NOT call vim.ui.input immediately", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      local called = false
      vim.ui.input = function(_, _) called = true end
      picker.open()
      assert.is_false(called)
    end)

    it("buffer has correct line count (1 gap + N items + 1 gap + 1 action + 1 gap)", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local bufnr = vim.api.nvim_win_get_buf(float_wins()[1])
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equals(6, #lines)  -- 1+2+1+1+1
    end)

    it("buffer lines contain each connection name", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local bufnr = vim.api.nvim_win_get_buf(float_wins()[1])
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.matches("dev",     lines[2])
      assert.matches("staging", lines[3])
    end)

    it("last non-empty line is the connect-with-string action", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local bufnr = vim.api.nvim_win_get_buf(float_wins()[1])
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.matches("string", lines[#lines - 1])
    end)
  end)
end)
