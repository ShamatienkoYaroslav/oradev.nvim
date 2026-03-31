-- Showcase UI: a scratch buffer for displaying information and hosting controls.
-- Not persisted to disk, not tracked as a worksheet.

local M = {}

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraShowcaseWinbar",    { bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraShowcaseWinbarDim", { link = "Comment", default = true })
end

-- ─── types ──────────────────────────────────────────────────────────────────

---@class OraShowcase
---@field bufnr    integer
---@field name     string
---@field title    string
---@field icon     string
---@field icon_hl  string
---@field on_close fun()|nil

---@type OraShowcase[]
local _list = {}
local _counter = 0

-- ─── internal helpers ───────────────────────────────────────────────────────

---Refresh the winbar for every window currently showing this showcase buffer.
---@param sc OraShowcase
local function refresh_winbar(sc)
  setup_hl()
  local icon_hl = sc.icon_hl or "Special"
  local icon    = sc.icon    or ""
  local title   = sc.title   or sc.name
  local safe_title = title:gsub("%%", "%%%%")
  local text = " %#" .. icon_hl .. "#" .. icon .. "%*%#OraShowcaseWinbar# " .. safe_title .. "%*"
  for _, win in ipairs(vim.fn.win_findbuf(sc.bufnr)) do
    vim.api.nvim_win_set_option(win, "winbar", text)
  end
end

---Remove a showcase from the internal list by buffer number.
---@param bufnr integer
local function remove(bufnr)
  for i, sc in ipairs(_list) do
    if sc.bufnr == bufnr then
      if sc.on_close then sc.on_close() end
      table.remove(_list, i)
      return
    end
  end
end

-- ─── public API ─────────────────────────────────────────────────────────────

---Create a new showcase buffer.
---@param opts? { name?: string, title?: string, icon?: string, icon_hl?: string, on_close?: fun() }
---@return OraShowcase
function M.create(opts)
  opts = opts or {}
  _counter = _counter + 1
  local name = opts.name or ("showcase-" .. _counter)

  local bufnr = vim.api.nvim_create_buf(false, false)
  local buf_name = "ora://showcase/" .. name
  local existing = vim.fn.bufnr(buf_name)
  if existing ~= -1 then
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
  vim.api.nvim_buf_set_option(bufnr, "buftype",    "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden",  "hide")
  vim.api.nvim_buf_set_option(bufnr, "swapfile",   false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

  local sc = {
    bufnr    = bufnr,
    name     = name,
    title    = opts.title or name,
    icon     = opts.icon or "󰋼 ",
    icon_hl  = opts.icon_hl or "Special",
    on_close = opts.on_close,
  }
  table.insert(_list, sc)

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer   = bufnr,
    callback = function() refresh_winbar(sc) end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    buffer   = bufnr,
    once     = true,
    callback = function() remove(bufnr) end,
  })

  return sc
end

---Find a showcase by buffer number.
---@param bufnr integer
---@return OraShowcase|nil
function M.find(bufnr)
  for _, sc in ipairs(_list) do
    if sc.bufnr == bufnr then return sc end
  end
end

---Find a showcase by name.
---@param name string
---@return OraShowcase|nil
function M.find_by_name(name)
  for _, sc in ipairs(_list) do
    if sc.name == name then return sc end
  end
end

---Return all registered showcases.
---@return OraShowcase[]
function M.list()
  return _list
end

---Set the buffer content (replaces all lines).
---@param sc    OraShowcase
---@param lines string[]
function M.set_lines(sc, lines)
  if not vim.api.nvim_buf_is_valid(sc.bufnr) then return end
  vim.api.nvim_buf_set_option(sc.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(sc.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(sc.bufnr, "modifiable", false)
end

---Update the title and refresh the winbar.
---@param sc    OraShowcase
---@param title string
function M.set_title(sc, title)
  sc.title = title
  refresh_winbar(sc)
end

---Update the icon and refresh the winbar.
---@param sc      OraShowcase
---@param icon    string
---@param icon_hl? string
function M.set_icon(sc, icon, icon_hl)
  sc.icon = icon
  if icon_hl then sc.icon_hl = icon_hl end
  refresh_winbar(sc)
end

---Apply extmark highlights to the showcase buffer.
---@param sc         OraShowcase
---@param ns_id      integer       namespace id from vim.api.nvim_create_namespace
---@param highlights { line: integer, col_start: integer, col_end: integer, hl_group: string }[]
function M.set_highlights(sc, ns_id, highlights)
  if not vim.api.nvim_buf_is_valid(sc.bufnr) then return end
  vim.api.nvim_buf_clear_namespace(sc.bufnr, ns_id, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(sc.bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end
end

---Show the showcase buffer in the main editor area (like a worksheet/file).
---If already visible, focus the existing window.
---@param sc OraShowcase
function M.show(sc)
  -- Focus existing window if visible
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == sc.bufnr then
      vim.api.nvim_set_current_win(win)
      return
    end
  end

  -- Find the first non-neo-tree, non-floating window in the current tabpage
  local target_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local bname = vim.api.nvim_buf_get_name(buf)
      if not bname:match("neo%-tree") then
        target_win = win
        break
      end
    end
  end

  if target_win then
    vim.api.nvim_win_set_buf(target_win, sc.bufnr)
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("wincmd l")
    vim.api.nvim_win_set_buf(0, sc.bufnr)
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_option(win, "number",         false)
  vim.api.nvim_win_set_option(win, "relativenumber", false)
  vim.api.nvim_win_set_option(win, "signcolumn",     "no")
  vim.api.nvim_win_set_option(win, "wrap",           false)

  refresh_winbar(sc)
end

---Close all windows showing this showcase buffer.
---@param sc OraShowcase
function M.hide(sc)
  for _, win in ipairs(vim.fn.win_findbuf(sc.bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
end

---Delete the showcase buffer and clean up.
---@param sc OraShowcase
function M.destroy(sc)
  if vim.api.nvim_buf_is_valid(sc.bufnr) then
    vim.api.nvim_buf_delete(sc.bufnr, { force = true })
  end
end

return M
