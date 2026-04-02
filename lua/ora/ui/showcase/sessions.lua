-- Active sessions showcase: displays V$SESSION data in a bordered table
-- with refresh support and a detail modal for viewing session SQL text.

local showcase = require("ora.ui.showcase")
local query    = require("ora.result.query")
local explain  = require("ora.result.explain")
local notify   = require("ora.notify")

local ns = vim.api.nvim_create_namespace("ora_showcase_sessions")

-- ─── highlights ─────────────────────────────────────────────────────────────

local function setup_hl()
  vim.api.nvim_set_hl(0, "OraShowcaseAction",         { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraShowcaseActionDim",       { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "OraShowcaseActionDisabled",   { fg = "#3b4261", default = true })
  vim.api.nvim_set_hl(0, "OraSessionDetailHeader",      { fg = "#c0caf5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "OraSessionDetailDim",         { fg = "#565f89", default = true })
end

-- ─── state per showcase instance ────────────────────────────────────────────

---@class OraSessionsState
---@field sc          OraShowcase
---@field conn        {key: string, is_named: boolean}
---@field conn_name   string
---@field loading     boolean
---@field row_count   integer
---@field rows        table[]|nil   parsed session rows for detail lookup
---@field keymaps_set boolean
---@field show_inactive boolean     whether to include INACTIVE sessions
---@field action_bar_lines integer  number of lines the action bar occupies

---@type table<integer, OraSessionsState>   bufnr → state
local _states = {}

-- ─── SQL ────────────────────────────────────────────────────────────────────

---@param show_inactive boolean
---@return string
local function sessions_sql(show_inactive)
  local where = "WHERE s.USERNAME IS NOT NULL\n  AND s.TYPE = 'USER'"
  if not show_inactive then
    where = where .. "\n  AND s.STATUS = 'ACTIVE'"
  end
  return string.format([[
SELECT
  s.SID,
  s.SERIAL# AS SERIAL_NUM,
  s.INST_ID,
  s.USERNAME,
  s.STATUS,
  s.OSUSER,
  s.MACHINE,
  s.PROGRAM,
  s.SQL_ID,
  s.EVENT,
  s.WAIT_CLASS,
  s.SECONDS_IN_WAIT AS WAIT_SECS,
  TO_CHAR(s.LOGON_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LOGON_TIME
FROM GV$SESSION s
%s
ORDER BY s.STATUS, s.USERNAME, s.SID
]], where)
end

---@param sql_id string
---@return string
local function detail_sql(sql_id)
  return string.format(
    "SELECT SQL_TEXT AS SQL_PIECE FROM V$SQLTEXT_WITH_NEWLINES WHERE SQL_ID = '%s' ORDER BY PIECE",
    sql_id:gsub("'", "''")
  )
end

---@param sid string|number
---@return string
local function waits_sql(sid)
  return string.format(
    "SELECT EVENT, P1, P2, P3 FROM V$SESSION_WAIT WHERE SID = %s ORDER BY EVENT",
    tostring(sid)
  )
end

---@param sid string|number
---@return string
local function server_sql(sid)
  return string.format([[
SELECT
  s.SID,
  s.STATUS,
  s.USERNAME,
  s.PROCESS,
  TO_CHAR(s.LOGON_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LOGON_TIME,
  s.LAST_CALL_ET AS SINCE,
  s.SERVER,
  s.TYPE,
  p.SPID,
  p.TRACEID,
  s.SERIAL# AS SERIAL_NUM
FROM V$SESSION s
LEFT JOIN V$PROCESS p ON s.PADDR = p.ADDR
WHERE s.SID = %s
]], tostring(sid))
end

---@param sid string|number
---@return string
local function client_sql(sid)
  return string.format(
    "SELECT OSUSER, MACHINE, TERMINAL, CLIENT_INFO, CLIENT_IDENTIFIER FROM V$SESSION WHERE SID = %s",
    tostring(sid)
  )
end

-- ─── action bar ─────────────────────────────────────────────────────────────

---@param st OraSessionsState
---@return string[]  lines
---@return {line: integer, col_start: integer, col_end: integer, hl_group: string}[]  highlights
local function build_action_bar(st)
  setup_hl()
  local refresh_text
  if st.loading then
    refresh_text = " Loading…"
  else
    refresh_text = " [r] Refresh"
  end

  local inactive_text = st.show_inactive and "  [i] Hide inactive" or "  [i] Show inactive"
  local detail_text   = "  [a] Active SQL"
  local explain_text  = "  [e] Explain Plan"
  local waits_text    = "  [w] Waits"
  local server_text   = "  [s] Server"
  local client_text   = "  [c] Client"
  local kill_text     = "  [K] Kill"
  local close_text    = "  [q] Close"

  local bar = refresh_text .. inactive_text .. detail_text .. explain_text .. waits_text .. server_text .. client_text .. kill_text .. close_text
  local lines = { "", bar }

  local hls = {}
  local pos = 0

  -- refresh
  local hl_group = st.loading and "OraShowcaseActionDisabled" or "OraShowcaseAction"
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #refresh_text, hl_group = hl_group })
  pos = pos + #refresh_text

  -- inactive toggle
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #inactive_text, hl_group = "OraShowcaseAction" })
  pos = pos + #inactive_text

  -- detail
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #detail_text, hl_group = "OraShowcaseAction" })
  pos = pos + #detail_text

  -- explain
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #explain_text, hl_group = "OraShowcaseAction" })
  pos = pos + #explain_text

  -- waits
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #waits_text, hl_group = "OraShowcaseAction" })
  pos = pos + #waits_text

  -- server
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #server_text, hl_group = "OraShowcaseAction" })
  pos = pos + #server_text

  -- client
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #client_text, hl_group = "OraShowcaseAction" })
  pos = pos + #client_text

  -- kill
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #kill_text, hl_group = "OraShowcaseAction" })
  pos = pos + #kill_text

  -- close
  table.insert(hls, { line = 1, col_start = pos, col_end = pos + #close_text, hl_group = "OraShowcaseActionDim" })

  return lines, hls
end

-- ─── rendering ──────────────────────────────────────────────────────────────

---@param st  OraSessionsState
---@param raw string
local function render_sessions(st, raw)
  local q = query.create({ raw = raw })
  local action_lines, action_hls = build_action_bar(st)

  local lines = {}
  vim.list_extend(lines, action_lines)
  vim.list_extend(lines, q.lines)

  showcase.set_lines(st.sc, lines)

  -- action bar highlights
  for _, hl in ipairs(action_hls) do
    vim.api.nvim_buf_add_highlight(
      st.sc.bufnr, ns, hl.hl_group,
      hl.line, hl.col_start, hl.col_end
    )
  end

  -- table highlights offset by action bar
  st.action_bar_lines = #action_lines
  q:render(st.sc.bufnr, #action_lines)
end

-- ─── data fetching ──────────────────────────────────────────────────────────

---@param st OraSessionsState
local function fetch_sessions(st)
  if st.loading then return end
  st.loading = true

  -- Show loading state in action bar
  local action_lines, _ = build_action_bar(st)
  local current_lines = vim.api.nvim_buf_get_lines(st.sc.bufnr, 0, -1, false)
  if #current_lines > 2 then
    vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(st.sc.bufnr, 0, 2, false, action_lines)
    vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", false)
  end

  local schema = require("ora.schema")
  schema.fetch_raw_query(st.conn, sessions_sql(st.show_inactive), function(raw, err)
    st.loading = false

    if err then
      notify.error("ora", "Failed to fetch sessions: " .. err)
      if vim.api.nvim_buf_is_valid(st.sc.bufnr) then
        local al, _ = build_action_bar(st)
        vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(st.sc.bufnr, 0, 2, false, al)
        vim.api.nvim_buf_set_option(st.sc.bufnr, "modifiable", false)
      end
      return
    end

    -- Parse rows for detail lookup
    local trimmed = vim.trim(raw)
    local ok, parsed = pcall(vim.fn.json_decode, trimmed)
    if ok and parsed and parsed.results and #parsed.results > 0 then
      st.rows = parsed.results[1].items or {}
      st.row_count = #st.rows
    else
      st.rows = {}
      st.row_count = 0
    end

    render_sessions(st, raw)
  end)
end

-- ─── detail modal ───────────────────────────────────────────────────────────

---Get the session row at the current cursor position.
---@param st OraSessionsState
---@return table|nil  session row from parsed JSON
local function get_session_at_cursor(st)
  if not st.rows or #st.rows == 0 then return nil end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1 -- 0-based

  -- action_bar_lines (2) + top border (1) + header (1) + separator (1) = 5 lines before first data row
  local data_start = st.action_bar_lines + 3
  local row_idx = line - data_start + 1 -- 1-based

  if row_idx < 1 or row_idx > #st.rows then return nil end
  return st.rows[row_idx]
end

---Show a floating detail modal with the session's SQL text.
---@param st  OraSessionsState
---@param row table  parsed session row
local function show_detail_modal(st, row)
  setup_hl()
  local sql_id = row.SQL_ID or row.sql_id

  local function open_modal(content_lines)
    local lines = content_lines or {}

    -- Calculate float dimensions
    local max_width = 40
    for _, l in ipairs(lines) do
      if #l > max_width then max_width = #l end
    end
    local width  = math.min(max_width + 4, math.floor(vim.o.columns * 0.85))
    local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
    local row_pos = math.floor((vim.o.lines - height) / 2)
    local col_pos = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width    = width,
      height   = height,
      row      = row_pos,
      col      = col_pos,
      style    = "minimal",
      border   = "rounded",
      title    = " Active SQL ",
      title_pos = "center",
    })

    vim.api.nvim_win_set_option(win, "wrap", true)
    vim.api.nvim_win_set_option(win, "cursorline", true)

    vim.api.nvim_buf_set_option(buf, "filetype", "sql")

    -- Close keymaps
    local function close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.keymap.set("n", "q",     close, { buffer = buf, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
  end

  if not sql_id or sql_id == "" or sql_id == vim.NIL then
    open_modal({ " (no active SQL for this session)" })
    return
  end

  -- Fetch the SQL text
  notify.progress("ora_session_detail", "Fetching SQL text…")
  local schema = require("ora.schema")
  schema.fetch_raw_query(st.conn, detail_sql(sql_id), function(raw, err)
    if err then
      notify.error("ora_session_detail", "Failed to fetch SQL: " .. err)
      open_modal({ " (error fetching SQL text)" })
      return
    end

    notify.done("ora_session_detail", "SQL text loaded")

    local trimmed = vim.trim(raw)
    local ok, parsed = pcall(vim.fn.json_decode, trimmed)
    local pieces = {}
    if ok and parsed and parsed.results and #parsed.results > 0 then
      local items = parsed.results[1].items or {}
      for _, item in ipairs(items) do
        local piece = item.SQL_PIECE or item.sql_piece
        if piece and piece ~= vim.NIL then
          table.insert(pieces, tostring(piece))
        end
      end
    end

    if #pieces == 0 then
      open_modal({ " (SQL text not available — may have aged out of V$SQL)" })
      return
    end

    -- Concatenate all pieces into the full SQL text
    local sql_text = table.concat(pieces, "")

    -- Split into lines
    local sql_lines = {}
    for line in sql_text:gmatch("[^\r\n]+") do
      table.insert(sql_lines, " " .. line)
    end
    if #sql_lines == 0 then
      sql_lines = { " " .. sql_text }
    end

    open_modal(sql_lines)
  end)
end

-- ─── table modal (reusable for explain plan, waits, etc.) ──────────────────

---Open a floating modal showing rendered table output.
---@param title string        modal title
---@param lines string[]
---@param render_fn fun(bufnr: integer)
local function open_table_modal(title, lines, render_fn)
  local max_width = 40
  for _, l in ipairs(lines) do
    if #l > max_width then max_width = #l end
  end
  local width   = math.min(max_width + 4, math.floor(vim.o.columns * 0.85))
  local height  = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
  local row_pos = math.floor((vim.o.lines - height) / 2)
  local col_pos = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row_pos,
    col       = col_pos,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
  })

  vim.api.nvim_win_set_option(win, "wrap", false)
  vim.api.nvim_win_set_option(win, "cursorline", true)

  render_fn(buf)

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q",     close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
end

---Fetch session SQL, run EXPLAIN PLAN FOR it, display result in a modal.
---@param st  OraSessionsState
---@param row table
local function show_explain_modal(st, row)
  local sql_id = row.SQL_ID or row.sql_id

  if not sql_id or sql_id == "" or sql_id == vim.NIL then
    open_table_modal("Explain Plan",{ " (no active SQL for this session)" }, function() end)
    return
  end

  notify.progress("ora_session_explain", "Fetching explain plan…")

  -- Step 1: get the SQL text from V$SQLTEXT_WITH_NEWLINES
  local schema = require("ora.schema")
  schema.fetch_raw_query(st.conn, detail_sql(sql_id), function(raw, err)
    if err then
      notify.error("ora_session_explain", "Failed to fetch SQL: " .. err)
      open_table_modal("Explain Plan",{ " (error fetching SQL text)" }, function() end)
      return
    end

    local trimmed = vim.trim(raw)
    local ok, parsed = pcall(vim.fn.json_decode, trimmed)
    local pieces = {}
    if ok and parsed and parsed.results and #parsed.results > 0 then
      local items = parsed.results[1].items or {}
      for _, item in ipairs(items) do
        local piece = item.SQL_PIECE or item.sql_piece
        if piece and piece ~= vim.NIL then
          table.insert(pieces, tostring(piece))
        end
      end
    end

    if #pieces == 0 then
      notify.error("ora_session_explain", "SQL text not available")
      open_table_modal("Explain Plan",{ " (SQL text not available — may have aged out of V$SQL)" }, function() end)
      return
    end

    local sql_text = table.concat(pieces, "")
    -- Strip trailing ; or / so EXPLAIN PLAN FOR doesn't choke
    sql_text = sql_text:gsub("[;/]%s*$", "")

    -- Step 2: run EXPLAIN PLAN FOR via a one-shot SQLcl script
    local cfg = require("ora.config").values
    local spool  = vim.fn.tempname() .. ".log"
    local script = vim.fn.tempname() .. ".sql"

    local f = assert(io.open(script, "w"))
    f:write("SET ECHO OFF\n")
    f:write("SET FEEDBACK OFF\n")
    f:write("SET HEADING OFF\n")
    f:write("SET LINESIZE 200\n")
    f:write("SET PAGESIZE 1000\n")
    f:write("EXPLAIN PLAN FOR\n")
    f:write(sql_text .. ";\n")
    f:write("SPOOL " .. spool .. "\n")
    f:write("SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);\n")
    f:write("SPOOL OFF\n")
    f:write("EXIT\n")
    f:close()

    local args
    if st.conn.is_named then
      args = { cfg.sqlcl_path, "-name", st.conn.key, "-S", "@" .. script }
    else
      args = { cfg.sqlcl_path, st.conn.key, "-S", "@" .. script }
    end

    local Job = require("plenary.job")
    Job:new({
      command = args[1],
      args    = vim.list_slice(args, 2),
      on_exit = function(_, code)
        os.remove(script)

        local fh = io.open(spool, "r")
        if not fh then
          vim.schedule(function()
            notify.error("ora_session_explain", "spool file missing (sqlcl exited with code " .. code .. ")")
            open_table_modal("Explain Plan",{ " (explain plan failed)" }, function() end)
          end)
          return
        end
        local plan_raw = fh:read("*a")
        fh:close()
        os.remove(spool)

        vim.schedule(function()
          if code ~= 0 and vim.trim(plan_raw) == "" then
            notify.error("ora_session_explain", "sqlcl exited with code " .. code)
            open_table_modal("Explain Plan",{ " (explain plan failed)" }, function() end)
            return
          end

          notify.done("ora_session_explain", "Explain plan loaded")
          local output = explain.create({ raw = plan_raw })
          open_table_modal("Explain Plan",output.lines, function(buf)
            output:render(buf)
          end)
        end)
      end,
    }):start()
  end)
end

-- ─── waits modal ────────────────────────────────────────────────────────────

---Fetch session waits and display in a table modal.
---@param st  OraSessionsState
---@param row table
local function show_waits_modal(st, row)
  local sid = row.SID or row.sid
  if not sid then
    open_table_modal("Waits", { " (no SID for this session)" }, function() end)
    return
  end

  notify.progress("ora_session_waits", "Fetching session waits…")
  local schema = require("ora.schema")
  schema.fetch_raw_query(st.conn, waits_sql(sid), function(raw, err)
    if err then
      notify.error("ora_session_waits", "Failed to fetch waits: " .. err)
      open_table_modal("Waits", { " (error fetching waits)" }, function() end)
      return
    end

    notify.done("ora_session_waits", "Waits loaded")
    local output = query.create({ raw = raw })
    open_table_modal("Waits", output.lines, function(buf)
      output:render(buf)
    end)
  end)
end

-- ─── server modal ───────────────────────────────────────────────────────────

---Fetch server/process info and display in a table modal.
---@param st  OraSessionsState
---@param row table
local function show_server_modal(st, row)
  local sid = row.SID or row.sid
  if not sid then
    open_table_modal("Server", { " (no SID for this session)" }, function() end)
    return
  end

  notify.progress("ora_session_server", "Fetching server info…")
  local schema = require("ora.schema")
  schema.fetch_raw_query(st.conn, server_sql(sid), function(raw, err)
    if err then
      notify.error("ora_session_server", "Failed to fetch server info: " .. err)
      open_table_modal("Server", { " (error fetching server info)" }, function() end)
      return
    end

    notify.done("ora_session_server", "Server info loaded")
    local output = query.create({ raw = raw })
    open_table_modal("Server", output.lines, function(buf)
      output:render(buf)
    end)
  end)
end

-- ─── client modal ───────────────────────────────────────────────────────────

---Fetch client info and display in a table modal.
---@param st  OraSessionsState
---@param row table
local function show_client_modal(st, row)
  local sid = row.SID or row.sid
  if not sid then
    open_table_modal("Client", { " (no SID for this session)" }, function() end)
    return
  end

  notify.progress("ora_session_client", "Fetching client info…")
  local schema = require("ora.schema")
  schema.fetch_raw_query(st.conn, client_sql(sid), function(raw, err)
    if err then
      notify.error("ora_session_client", "Failed to fetch client info: " .. err)
      open_table_modal("Client", { " (error fetching client info)" }, function() end)
      return
    end

    notify.done("ora_session_client", "Client info loaded")
    local output = query.create({ raw = raw })
    open_table_modal("Client", output.lines, function(buf)
      output:render(buf)
    end)
  end)
end

-- ─── kill session modal ─────────────────────────────────────────────────────

---Build the ALTER SYSTEM KILL SESSION statement for a session row.
---@param row table
---@return string
local function build_kill_sql(row)
  local sid     = tostring(row.SID or row.sid or "")
  local serial  = tostring(row.SERIAL_NUM or row.serial_num or "")
  local inst_id = row.INST_ID or row.inst_id
  if inst_id and inst_id ~= vim.NIL then
    return string.format("ALTER SYSTEM KILL SESSION '%s, %s, @%s' IMMEDIATE", sid, serial, tostring(inst_id))
  end
  return string.format("ALTER SYSTEM KILL SESSION '%s, %s' IMMEDIATE", sid, serial)
end

---Show a confirmation modal with the kill SQL statement.
---@param st  OraSessionsState
---@param row table
local function show_kill_modal(st, row)
  setup_hl()
  local kill_sql_text = build_kill_sql(row)

  local lines = {
    "",
    " " .. kill_sql_text,
    "",
    "",
  }

  -- Action bar on the last line
  local apply_text  = " [a] Apply"
  local cancel_text = "  [c] Cancel"
  local action_bar  = apply_text .. cancel_text
  lines[4] = action_bar

  local width   = math.max(#kill_sql_text + 4, #action_bar + 4, 50)
  local height  = #lines
  local row_pos = math.floor((vim.o.lines - height) / 2)
  local col_pos = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "sql")

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row_pos,
    col       = col_pos,
    style     = "minimal",
    border    = "rounded",
    title     = " Kill Session? ",
    title_pos = "center",
  })

  vim.api.nvim_win_set_option(win, "wrap", false)
  vim.api.nvim_win_set_option(win, "cursorline", false)

  -- Highlight action bar
  local kill_ns = vim.api.nvim_create_namespace("ora_session_kill")
  local pos = 0
  vim.api.nvim_buf_add_highlight(buf, kill_ns, "OraShowcaseAction", 3, pos, pos + #apply_text)
  pos = pos + #apply_text
  vim.api.nvim_buf_add_highlight(buf, kill_ns, "OraShowcaseActionDim", 3, pos, pos + #cancel_text)

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "c",     close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "q",     close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set("n", "a", function()
    close()
    notify.progress("ora_session_kill", "Killing session…")
    local schema = require("ora.schema")
    schema.fetch_raw_query(st.conn, kill_sql_text .. ";", function(_, err)
      if err then
        notify.error("ora_session_kill", "Failed to kill session: " .. err)
        return
      end
      notify.done("ora_session_kill", "Session killed")
      -- Show inactive sessions so the killed session remains visible
      st.show_inactive = true
      if not st.loading then
        fetch_sessions(st)
      end
    end)
  end, { buffer = buf, silent = true, nowait = true })
end

-- ─── keymaps ────────────────────────────────────────────────────────────────

---@param st OraSessionsState
local function setup_keymaps(st)
  if st.keymaps_set then return end
  st.keymaps_set = true
  local bufnr = st.sc.bufnr

  vim.keymap.set("n", "r", function()
    local s = _states[bufnr]
    if s and not s.loading then
      fetch_sessions(s)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Refresh sessions" })

  vim.keymap.set("n", "i", function()
    local s = _states[bufnr]
    if s and not s.loading then
      s.show_inactive = not s.show_inactive
      fetch_sessions(s)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Toggle inactive sessions" })

  vim.keymap.set("n", "a", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_detail_modal(s, row)
    else
      notify.warn("ora", "Move cursor to a session row first")
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Show active SQL" })

  vim.keymap.set("n", "e", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_explain_modal(s, row)
    else
      notify.warn("ora", "Move cursor to a session row first")
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Show explain plan" })

  vim.keymap.set("n", "w", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_waits_modal(s, row)
    else
      notify.warn("ora", "Move cursor to a session row first")
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Show session waits" })

  vim.keymap.set("n", "s", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_server_modal(s, row)
    else
      notify.warn("ora", "Move cursor to a session row first")
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Show server info" })

  vim.keymap.set("n", "c", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_client_modal(s, row)
    else
      notify.warn("ora", "Move cursor to a session row first")
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Show client info" })

  vim.keymap.set("n", "K", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_kill_modal(s, row)
    else
      notify.warn("ora", "Move cursor to a session row first")
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Kill session" })

  vim.keymap.set("n", "<CR>", function()
    local s = _states[bufnr]
    if not s then return end
    local row = get_session_at_cursor(s)
    if row then
      show_detail_modal(s, row)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Show session details" })

  vim.keymap.set("n", "q", function()
    local s = _states[bufnr]
    if s then
      showcase.destroy(s.sc)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Close sessions" })
end

-- ─── public API ─────────────────────────────────────────────────────────────

local M = {}

---Open a showcase displaying active sessions for a connection.
---@param opts { conn_name: string }
function M.open(opts)
  local conn_name = opts.conn_name
  local sc_name   = "sessions-" .. conn_name
  local display   = conn_name .. " (Active Sessions)"

  -- Reuse existing showcase if open
  local existing = showcase.find_by_name(sc_name)
  if existing then
    showcase.show(existing)
    -- Trigger refresh on reopen
    local st = _states[existing.bufnr]
    if st and not st.loading then
      fetch_sessions(st)
    end
    return
  end

  local sc = showcase.create({
    name     = sc_name,
    title    = display,
    icon     = " ",
    icon_hl  = "DiagnosticInfo",
    on_close = function()
      _states[sc.bufnr] = nil
    end,
  })

  local conn = { key = conn_name, is_named = true }

  ---@type OraSessionsState
  local st = {
    sc               = sc,
    conn             = conn,
    conn_name        = conn_name,
    loading          = false,
    row_count        = 0,
    rows             = nil,
    keymaps_set      = false,
    show_inactive    = true,
    action_bar_lines = 2,
  }
  _states[sc.bufnr] = st

  showcase.set_lines(sc, { " Loading…" })
  showcase.show(sc)
  setup_keymaps(st)
  fetch_sessions(st)
end

return M
