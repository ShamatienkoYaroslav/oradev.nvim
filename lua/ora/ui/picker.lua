local config     = require("ora.config")
local connection = require("ora.connection")
local prompt     = require("ora.ui.prompt")

local M = {}

-- ─── helpers ──────────────────────────────────────────────────────────────────

local ns = vim.api.nvim_create_namespace("ora_picker")

local function center(total, size)
  return math.floor((total - size) / 2)
end

local function scratch_buf()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "buftype",   "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile",  false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  return bufnr
end

-- ─── picker state ─────────────────────────────────────────────────────────────

---@class PickerState
---@field bufnr   integer
---@field winid   integer
---@field cursor  integer   1-based; covers items 1..N + 1 action
---@field items   table[]   list of {label, url, kind}

---@type PickerState|nil
local state = nil

local function close()
  if state then
    if vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_win_close(state.winid, true)
    end
    state = nil
  end
end

-- ─── rendering ────────────────────────────────────────────────────────────────

local HEADER = " Oracle Connections"
local FOOTER = " [↑↓/jk] move  [<CR>] connect  [s] string  [a] add  [q/<Esc>] close"

local HL_CURSOR = "OraPickerCursor"
local HL_NAMED  = "OraPickerNamed"
local HL_ACTION = "OraPickerAction"

local function setup_hl()
  local hl = vim.api.nvim_set_hl
  hl(0, "OraPickerTitle",  { link = "Title",       default = true })
  hl(0, "OraPickerBorder", { link = "FloatBorder",  default = true })
  hl(0, HL_CURSOR,         { link = "PmenuSel",     default = true })
  hl(0, HL_NAMED,          { link = "Normal",       default = true })
  hl(0, HL_ACTION,         { link = "Special",      default = true })
  hl(0, "OraPickerFooter", { link = "Comment",      default = true })
end

local function render()
  if not state then return end

  local items = state.items
  local width = config.values.win_width - 4

  local lines = {}
  table.insert(lines, "")  -- top gap

  for i, item in ipairs(items) do
    local prefix = (i == state.cursor) and " ▶ " or "   "
    local label  = item.label
    if #label > width - 5 then
      label = label:sub(1, width - 8) .. "..."
    end
    table.insert(lines, prefix .. label)
  end

  table.insert(lines, "")  -- divider gap
  local n = #items
  local action_prefix = (n + 1 == state.cursor) and " ▶ " or "   "
  table.insert(lines, action_prefix .. " Connect with connection string…")
  table.insert(lines, "")  -- bottom gap

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  for i, item in ipairs(items) do
    local hl = (i == state.cursor) and HL_CURSOR or HL_NAMED
    vim.api.nvim_buf_add_highlight(state.bufnr, ns, hl, i, 0, -1)
    _ = item
  end

  local action_hl = (n + 1 == state.cursor) and HL_CURSOR or HL_ACTION
  vim.api.nvim_buf_add_highlight(state.bufnr, ns, action_hl, n + 2, 0, -1)
end

-- ─── navigation & selection ───────────────────────────────────────────────────

local function move(delta)
  if not state then return end
  local total = #state.items + 1
  state.cursor = ((state.cursor - 1 + delta) % total) + 1
  render()
end

local function select_current()
  if not state then return end
  local items = state.items
  if state.cursor <= #items then
    local item = items[state.cursor]
    close()
    connection.connect(item.url, item.label, { is_named = item.kind == "stored" })
  else
    close()
    prompt.ask_connection_string(function(url)
      connection.connect(url, url)
    end)
  end
end

local function open_add()
  close()
  require("ora.ui.add_connection").ask(function(name, url)
    local ok, err = require("ora.connmgr").add(name, url)
    if ok then
      vim.notify(string.format("[ora] connection '%s' added", name), vim.log.levels.INFO)
    else
      vim.notify("[ora] failed to add connection: " .. (err or ""), vim.log.levels.ERROR)
    end
  end)
end

-- ─── keymaps ──────────────────────────────────────────────────────────────────

local function set_keymaps()
  local buf  = state.bufnr
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  vim.keymap.set("n", "j",      function() move(1)  end,  opts)
  vim.keymap.set("n", "k",      function() move(-1) end,  opts)
  vim.keymap.set("n", "<Down>", function() move(1)  end,  opts)
  vim.keymap.set("n", "<Up>",   function() move(-1) end,  opts)
  vim.keymap.set("n", "<CR>",   select_current,            opts)
  vim.keymap.set("n", "s",      function()
    close()
    prompt.ask_connection_string(function(url)
      connection.connect(url, url)
    end)
  end, opts)
  vim.keymap.set("n", "a",      open_add,  opts)
  vim.keymap.set("n", "q",      close,     opts)
  vim.keymap.set("n", "<Esc>",  close,     opts)
end

-- ─── public API ───────────────────────────────────────────────────────────────

---Open the connection picker.
---Reads available connections from the SQLcl connection manager.
function M.open()
  setup_hl()

  local names = require("ora.connmgr").list()

  local items = {}
  for _, name in ipairs(names) do
    table.insert(items, { label = name, url = name, kind = "stored" })
  end

  local win_w = config.values.win_width
  local win_h = math.min(config.values.win_height, #items + 4)

  local ui       = vim.api.nvim_list_uis()[1]
  local screen_w = ui and ui.width  or vim.o.columns
  local screen_h = ui and ui.height or vim.o.lines
  local col = center(screen_w, win_w)
  local row = center(screen_h, win_h)

  local bufnr = scratch_buf()

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative  = "editor",
    width     = win_w,
    height    = win_h,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = HEADER,
    title_pos = "left",
    footer    = FOOTER,
    footer_pos = "left",
  })

  vim.api.nvim_win_set_option(winid, "cursorline",     false)
  vim.api.nvim_win_set_option(winid, "number",         false)
  vim.api.nvim_win_set_option(winid, "relativenumber", false)
  vim.api.nvim_win_set_option(winid, "signcolumn",     "no")
  vim.api.nvim_win_set_option(winid, "wrap",           false)

  state = { bufnr = bufnr, winid = winid, cursor = 1, items = items }

  render()
  set_keymaps()

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer   = bufnr,
    once     = true,
    callback = function() vim.schedule(close) end,
  })
end

return M
