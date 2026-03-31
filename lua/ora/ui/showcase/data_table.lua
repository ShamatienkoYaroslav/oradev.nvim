-- Data table component for the showcase UI.
-- Displays paginated table data with column-aligned bordered tables,
-- reusing the query output formatter from the result module.

local showcase = require("ora.ui.showcase")
local query    = require("ora.result.query")
local notify   = require("ora.notify")

local ns = vim.api.nvim_create_namespace("ora_showcase_data_table")

local PAGE_SIZE = 50

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraShowcaseAction",       { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraShowcaseActionDim",     { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "OraShowcaseActionDisabled", { fg = "#3b4261", default = true })
end

-- ─── state per showcase instance ────────────────────────────────────────────

---@class OraDataTableState
---@field sc         OraShowcase
---@field conn       {key: string, is_named: boolean}
---@field object_name string
---@field page       integer          current page (0-based)
---@field loading    boolean
---@field has_more   boolean
---@field total_rows integer          total rows fetched so far
---@field keymaps_set boolean

---@type table<integer, OraDataTableState>   bufnr → state
local _states = {}

-- ─── SQL builder ────────────────────────────────────────────────────────────

---@param object_name string
---@param offset      integer
---@param limit       integer
---@return string
local function build_sql(object_name, offset, limit)
  return string.format(
    "SELECT * FROM %s OFFSET %d ROWS FETCH NEXT %d ROWS ONLY",
    object_name, offset, limit
  )
end

-- ─── action bar ─────────────────────────────────────────────────────────────

---Build the action bar lines and return highlight data.
---@param st OraDataTableState
---@return string[]  lines
---@return {line: integer, col_start: integer, col_end: integer, hl_group: string}[]  highlights
local function build_action_bar(st)
  setup_hl()
  local page_label = string.format("Page %d", st.page + 1)
  local rows_label = string.format("(%d rows loaded)", st.total_rows)

  local next_text
  if st.loading then
    next_text = "  Loading…"
  elseif st.has_more then
    next_text = "  [n] Next " .. PAGE_SIZE .. " rows"
  else
    next_text = "  (no more rows)"
  end

  local prev_text
  if st.page > 0 then
    prev_text = "  [p] Previous page"
  else
    prev_text = ""
  end

  local first_text = ""
  if st.page > 0 then
    first_text = "  [f] First page"
  end

  local bar = " " .. page_label .. "  " .. rows_label .. next_text .. prev_text .. first_text
  local lines = { "", bar }

  local hls = {}
  -- page label highlight
  local page_start = 1
  local page_end   = page_start + #page_label
  table.insert(hls, { line = 1, col_start = page_start, col_end = page_end, hl_group = "OraShowcaseAction" })

  -- rows label
  local rows_start = page_end + 2
  local rows_end   = rows_start + #rows_label
  table.insert(hls, { line = 1, col_start = rows_start, col_end = rows_end, hl_group = "OraShowcaseActionDim" })

  -- next action
  local next_start = rows_end
  local next_end   = next_start + #next_text
  if st.loading or not st.has_more then
    table.insert(hls, { line = 1, col_start = next_start, col_end = next_end, hl_group = "OraShowcaseActionDisabled" })
  else
    table.insert(hls, { line = 1, col_start = next_start, col_end = next_end, hl_group = "OraShowcaseAction" })
  end

  return lines, hls
end

-- ─── rendering ──────────────────────────────────────────────────────────────

---Render the current page into the showcase buffer.
---@param st        OraDataTableState
---@param raw       string            raw JSON spool content for the current page
---@param append    boolean           true if fetching next page (accumulate)
local function render_page(st, raw, append)
  local q = query.create({ raw = raw })
  local action_lines, action_hls = build_action_bar(st)

  -- Combine action bar + table lines
  local lines = {}
  vim.list_extend(lines, action_lines)
  vim.list_extend(lines, q.lines)

  showcase.set_lines(st.sc, lines)

  -- Apply action bar highlights first (at the top)
  for _, hl in ipairs(action_hls) do
    vim.api.nvim_buf_add_highlight(
      st.sc.bufnr, ns, hl.hl_group,
      hl.line, hl.col_start, hl.col_end
    )
  end

  -- Apply table highlights offset by action bar line count
  q:render(st.sc.bufnr, #action_lines)
end

-- ─── data fetching ──────────────────────────────────────────────────────────

---Fetch a page of data and render it.
---@param st OraDataTableState
local function fetch_page(st)
  if st.loading then return end
  st.loading = true

  -- Show loading state immediately in the action bar (first 2 lines)
  local action_lines, _ = build_action_bar(st)
  local current_lines = vim.api.nvim_buf_get_lines(st.sc.bufnr, 0, -1, false)
  if #current_lines > 2 then
    vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(st.sc.bufnr, 0, 2, false, action_lines)
    vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", false)
  end

  local offset = st.page * PAGE_SIZE
  local sql = build_sql(st.object_name, offset, PAGE_SIZE)
  local schema = require("ora.schema")

  schema.fetch_raw_query(st.conn, sql, function(raw, err)
    st.loading = false

    if err then
      notify.error("ora", "Failed to fetch data: " .. err)
      -- Re-render action bar without loading state (first 2 lines)
      if vim.api.nvim_buf_is_valid(st.sc.bufnr) then
        local al, _ = build_action_bar(st)
        vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(st.sc.bufnr, 0, 2, false, al)
        vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", false)
      end
      return
    end

    -- Parse to count rows and determine if there are more
    local trimmed = vim.trim(raw)
    local ok, parsed = pcall(vim.fn.json_decode, trimmed)
    local row_count = 0
    if ok and parsed and parsed.results and #parsed.results > 0 then
      row_count = #(parsed.results[1].items or {})
    end

    st.has_more = row_count == PAGE_SIZE
    st.total_rows = (st.page * PAGE_SIZE) + row_count

    render_page(st, raw, false)
  end)
end

-- ─── keymaps ────────────────────────────────────────────────────────────────

---Set up buffer-local keymaps for pagination.
---@param st OraDataTableState
local function setup_keymaps(st)
  if st.keymaps_set then return end
  st.keymaps_set = true
  local bufnr = st.sc.bufnr

  vim.keymap.set("n", "n", function()
    local s = _states[bufnr]
    if s and s.has_more and not s.loading then
      s.page = s.page + 1
      fetch_page(s)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Next page" })

  vim.keymap.set("n", "p", function()
    local s = _states[bufnr]
    if s and s.page > 0 and not s.loading then
      s.page = s.page - 1
      fetch_page(s)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Previous page" })

  vim.keymap.set("n", "f", function()
    local s = _states[bufnr]
    if s and s.page > 0 and not s.loading then
      s.page = 0
      fetch_page(s)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "First page" })
end

-- ─── public API ─────────────────────────────────────────────────────────────

local M = {}

---Open a showcase data table for an object.
---@param opts { conn_name: string, object_name: string, schema_name?: string, object_type?: string, icon?: string }
function M.open(opts)
  local conn_name   = opts.conn_name
  local object_name = opts.object_name
  local schema_label = opts.schema_name or conn_name
  local object_type  = opts.object_type or "Table"
  local icon         = opts.icon or "󰓫 "

  local display = schema_label .. "." .. object_name .. " (" .. object_type .. " Data)"
  local sc_name = object_name .. "-data-" .. conn_name

  -- Reuse existing showcase if open
  local existing = showcase.find_by_name(sc_name)
  if existing then
    showcase.show(existing)
    return
  end

  local sc = showcase.create({
    name    = sc_name,
    title   = display,
    icon    = icon,
    icon_hl = "Type",
    on_close = function()
      _states[sc.bufnr] = nil
    end,
  })

  local conn = { key = conn_name, is_named = true }

  ---@type OraDataTableState
  local st = {
    sc          = sc,
    conn        = conn,
    object_name = object_name,
    page        = 0,
    loading     = false,
    has_more    = true,
    total_rows  = 0,
    keymaps_set = false,
  }
  _states[sc.bufnr] = st

  -- Initial placeholder
  showcase.set_lines(sc, { " Loading…" })
  showcase.show(sc)
  setup_keymaps(st)
  fetch_page(st)
end

return M
