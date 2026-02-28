-- Tests for ora.ui.picker.
-- ora.connmgr.list is stubbed so no real sqlcl process is launched.
-- vim.fn.termopen is stubbed so no real sqlcl session is started.

local function setup_config()
  package.loaded["ora.config"] = nil
  require("ora.config").setup({ sqlcl_path = "/usr/bin/sql" })
end

local function fresh_picker()
  package.loaded["ora.ui.picker"]         = nil
  package.loaded["ora.ui.prompt"]         = nil
  package.loaded["ora.ui.add_connection"] = nil
  package.loaded["ora.connection"]        = nil
  package.loaded["ora.connmgr"]           = nil
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
  local orig_termopen

  before_each(function()
    orig_termopen = vim.fn.termopen
    vim.fn.termopen = function(_, _) return 1 end
    setup_config()
  end)

  after_each(function()
    vim.fn.termopen = orig_termopen
    close_floats()
    while vim.fn.winnr("$") > 1 do vim.cmd("close!") end
  end)

  describe("open() — no connections in connmgr", function()
    it("still opens the picker float (shows only the action row)", function()
      local picker = fresh_picker()
      stub_connmgr({})  -- stub AFTER fresh so it isn't wiped

      local before = #float_wins()
      picker.open()

      -- Picker always opens even with zero connections
      assert.is_true(#float_wins() > before)
    end)
  end)

  describe("open() — with connections from connmgr", function()
    local connections = { "dev", "staging" }

    it("opens at least one new floating window", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      local before = #float_wins()
      picker.open()
      -- nui opens 2 windows (border + content); we just verify at least 1 appeared
      assert.is_true(#float_wins() > before)
    end)

    it("floating window width matches config.win_width", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      -- float_wins()[1] is the nui content window; border is a separate float
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

    it("buffer has correct line count (N items + separator + action)", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local bufnr = vim.api.nvim_win_get_buf(float_wins()[1])
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      -- nui.Menu: 2 items + 1 separator + 1 action = 4 lines
      assert.equals(4, #lines)
    end)

    it("buffer lines contain each connection name", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local bufnr = vim.api.nvim_win_get_buf(float_wins()[1])
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local combined = table.concat(lines, "\n")
      assert.matches("dev",     combined)
      assert.matches("staging", combined)
    end)

    it("last line is the connect-with-string action", function()
      local picker = fresh_picker()
      stub_connmgr(connections)
      picker.open()
      local bufnr = vim.api.nvim_win_get_buf(float_wins()[1])
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.matches("string", lines[#lines])
    end)
  end)
end)
