local M = {}

local notify = require("ora.notify")
local _setup_done = false


---Configure the plugin. Must be called before any other ora function.
---
---@param user_config OraConfig
---
---Example:
---  require("ora").setup({
---    sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
---  })
function M.setup(user_config)
  require("ora.config").setup(user_config)
  vim.filetype.add({
    extension = { pks = "plsql", pkb = "plsql" },
    pattern   = { ["ora://.*"] = "plsql" },
  })
  require("ora.lsp").setup(require("ora.config").values)
  M._setup_icons()

  if require("ora.config").values.auto_worksheet then
    M._setup_auto_worksheet()
  end

  _setup_done = true
end

---Set up autocmd to auto-register sql/plsql/pks/pkb files as worksheets.
function M._setup_auto_worksheet()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "sql", "plsql" },
    group = vim.api.nvim_create_augroup("OraAutoWorksheet", { clear = true }),
    callback = function(ev)
      local bufnr = ev.buf
      -- Skip ora:// buffers — they are already managed as worksheets.
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name:match("^ora://") then return end
      -- Skip special buffers (terminals, nofile, etc.).
      local bt = vim.api.nvim_buf_get_option(bufnr, "buftype")
      if bt ~= "" then return end

      local ws_mod = require("ora.worksheet")
      if not ws_mod.find(bufnr) then
        local ws = ws_mod.register(bufnr)
        ws_mod.refresh_winbar(ws)
      end
    end,
  })
end

-- Map worksheet icon glyphs to mini.icons highlight groups.
local _icon_hl = {
  ["󰆼"] = "MiniIconsOrange",  -- connection / default
  ["󰓫"] = "MiniIconsCyan",    -- table
  ["󰡠"] = "MiniIconsCyan",    -- view
  ["󰊕"] = "MiniIconsPurple",  -- function
  ["󰡱"] = "MiniIconsPurple",  -- procedure
  ["󰏗"] = "MiniIconsOrange",  -- package
  ["󰔖"] = "MiniIconsCyan",    -- synonym
  ["󰌹"] = "MiniIconsYellow",  -- index
  ["󰔚"] = "MiniIconsYellow",  -- sequence
  ["󰒍"] = "MiniIconsGreen",   -- ords
  ["󱐋"] = "MiniIconsRed",     -- trigger
  ["󰕳"] = "MiniIconsCyan",    -- type
  ["󰆴"] = "MiniIconsRed",     -- drop
}

---Hook into mini.icons so ora:// buffers show per-worksheet icons in pickers.
function M._setup_icons()
  local hooked = false

  local function hook()
    if hooked or not _G.MiniIcons then return end
    hooked = true

    local orig_get = MiniIcons.get
    MiniIcons.get = function(category, name)
      if category == "file" and type(name) == "string" and name:match("^ora://") then
        local ws_mod = package.loaded["ora.worksheet"]
        if ws_mod then
          local bufnr = vim.fn.bufnr(name)
          if bufnr ~= -1 then
            local ws = ws_mod.find(bufnr)
            if ws and ws.icon then
              local glyph = ws.icon:gsub("%s+$", "")
              return glyph, _icon_hl[glyph] or "MiniIconsOrange", false
            end
          end
        end
        return "󰆼", "MiniIconsOrange", false
      end
      if category == "filetype" and name == "plsql" then
        return "󰆼", "MiniIconsOrange", false
      end
      return orig_get(category, name)
    end
  end

  hook()
  if not hooked then
    -- Defer past all VeryLazy handlers so mini.icons has time to set _G.MiniIcons
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      once = true,
      callback = function() vim.schedule(hook) end,
    })
    -- Fallback: lazy.nvim fires LazyLoad each time a plugin loads on-demand
    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyLoad",
      callback = function()
        hook()
        if hooked then return true end
      end,
    })
  end
end

---Show saved connections from the SQLcl connection manager and connect to one.
function M.list()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("ora.ui.picker").open()
end

---Connect directly with a connection string (skips the picker UI).
---@param url string
function M.connect(url)
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("ora.connection").connect(url, url)
end

---Convert the current buffer into a worksheet and pick a connection.
function M.register_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr)
  if ws then
    notify.warn("ora", "Buffer is already a worksheet")
    return
  end

  ws = ws_mod.register(bufnr)
  ws_mod.refresh_winbar(ws)

  require("ora.ui.picker").select(function(conn)
    if not conn then return end
    ws.connection = conn
    ws_mod.refresh_winbar(ws)
  end)
end

---Create a new SQL worksheet buffer (no connection prompt).
---The connection can be chosen later when executing the worksheet.
function M.new_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local ws = require("ora.worksheet").create()
  local ws_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(ws_win, ws.bufnr)
end

-- ─── SQL block splitting ──────────────────────────────────────────────────

---Check if a line is a statement terminator.
---@param line string
---@return boolean
local function is_terminator(line)
  local trimmed = vim.trim(line)
  return trimmed:match(";%s*$") ~= nil or trimmed == "/"
end

---Check if a line starts a PL/SQL block (where `;` is internal, not a terminator).
---@param line string
---@return boolean
local function starts_plsql_block(line)
  local upper = vim.trim(line):upper()
  if upper:match("^BEGIN%s") or upper == "BEGIN" then return true end
  if upper:match("^DECLARE%s") or upper == "DECLARE" then return true end
  if upper:match("^CREATE%s") and (
    upper:match("FUNCTION") or upper:match("PROCEDURE") or
    upper:match("PACKAGE") or upper:match("TRIGGER") or
    upper:match("TYPE")
  ) then return true end
  return false
end

---Check if a line is a SQLcl SET directive (not a SQL statement).
---@param line string
---@return boolean
local function is_set_directive(line)
  return vim.trim(line):upper():match("^SET%s") ~= nil
end

---Split SQL text into individual blocks.
---Simple statements are delimited by `;`. PL/SQL blocks (BEGIN/DECLARE/CREATE
---FUNCTION etc.) are delimited by `/` on its own line.
---@param text string
---@return string[]
local function split_sql_blocks(text)
  local lines = vim.split(text, "\n", { plain = true })
  local blocks = {}
  local current = {}
  local in_plsql = false

  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)

    -- Detect PL/SQL block start
    if not in_plsql and (starts_plsql_block(line) or is_set_directive(line)) then
      in_plsql = true
    end

    table.insert(current, line)

    if in_plsql then
      -- PL/SQL block: only `/` on its own line terminates
      if trimmed == "/" then
        local block = vim.trim(table.concat(current, "\n"))
        if block ~= "" then
          table.insert(blocks, block)
        end
        current = {}
        in_plsql = false
      end
    else
      -- Simple SQL: `;` at end of line terminates
      if trimmed:match(";%s*$") then
        local block = vim.trim(table.concat(current, "\n"))
        if block ~= "" then
          table.insert(blocks, block)
        end
        current = {}
      end
    end
  end

  -- Remaining lines without terminator
  local tail = vim.trim(table.concat(current, "\n"))
  if tail ~= "" then
    table.insert(blocks, tail)
  end

  return blocks
end

---Extract the SQL statement at the cursor position.
---@param bufnr integer
---@return string
local function sql_at_cursor(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]  -- 1-based

  local start_row = 1
  for r = cursor_row - 1, 1, -1 do
    if is_terminator(lines[r]) then
      start_row = r + 1
      break
    end
  end
  while start_row < cursor_row and vim.trim(lines[start_row]) == "" do
    start_row = start_row + 1
  end

  local end_row = #lines
  for r = cursor_row, #lines do
    if is_terminator(lines[r]) then
      end_row = r
      break
    end
  end

  local stmt_lines = {}
  for r = start_row, end_row do
    table.insert(stmt_lines, lines[r])
  end
  return table.concat(stmt_lines, "\n")
end

-- ─── block runner ─────────────────────────────────────────────────────────

---Check if a SQL block is PL/SQL (BEGIN/DECLARE/SET or ends with `/`).
---@param sql string
---@return boolean
local function is_plsql_block(sql)
  local first = vim.trim(sql):upper()
  if first:match("^BEGIN%s") or first:match("^BEGIN$") then return true end
  if first:match("^DECLARE%s") or first:match("^DECLARE$") then return true end
  if first:match("^SET%s") then return true end
  if vim.trim(sql):match("/%s*$") then return true end
  return false
end

---Build an output for a single raw query result (JSON).
---@param raw string
---@return OraResultOutput
local function make_query_output(raw)
  local error_output = require("ora.result.error")
  if error_output.is_error(raw) then
    return error_output.create({ raw = raw })
  end
  return require("ora.result.query").create({ raw = raw })
end

---Build an output for a PL/SQL block result (plain text).
---@param raw string
---@return OraResultOutput
local function make_plsql_output(raw)
  local error_output = require("ora.result.error")
  if error_output.is_error(raw) then
    return error_output.create({ raw = raw })
  end
  -- Success: show the output or a success message
  return require("ora.result.compile").create({
    raw         = raw,
    object_name = "anonymous block",
    object_type = "PL/SQL",
  })
end

---Run a list of SQL blocks sequentially, collecting outputs.
---Calls done(sections) when all blocks have been executed.
---@param ws       OraWorksheet
---@param blocks   string[]
---@param result   table       the ora.result module
---@param rbuf     integer     result buffer
---@param done     fun(sections: OraMultiSection[])
local function run_blocks(ws, blocks, result, rbuf, done)
  local sections = {}
  local idx = 0

  local function next_block()
    idx = idx + 1
    if idx > #blocks then
      done(sections)
      return
    end

    local block_sql = blocks[idx]
    local plsql = is_plsql_block(block_sql)
    result.set_buf_lines(rbuf, { "-- running block " .. idx .. "/" .. #blocks .. "…" })

    result.run(ws, function(raw, err)
      local output
      if err then
        output = require("ora.result.error").create({ raw = err })
      elseif plsql then
        output = make_plsql_output(raw)
      else
        output = make_query_output(raw)
      end
      table.insert(sections, { sql = block_sql, output = output })
      -- Stop on first error
      if output.type == "error" then
        done(sections)
      else
        next_block()
      end
    end, block_sql, plsql and { plsql = true } or nil)
  end

  next_block()
end

-- ─── execute worksheet ────────────────────────────────────────────────────

---Execute the current worksheet SQL and show the result as a formatted table
---in a split below the worksheet. If the buffer has no connection the
---connection picker is shown first.
function M.execute_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr   = vim.api.nvim_get_current_buf()
  local ws_mod  = require("ora.worksheet")
  local ws      = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  -- Hard-object worksheets (TABLE DDL, INDEX DDL, etc.) are not executable.
  if ws.db_object and ws.db_object.kind == "hard" then
    notify.warn("ora", ws.db_object.type .. " worksheet is read-only and cannot be executed")
    return
  end

  local is_soft = ws.db_object and ws.db_object.kind == "soft"

  local function do_run()
    local result = require("ora.result")
    local nid = "ora_exec"
    local rbuf = result.get_or_create_buf(ws)
    result.set_buf_lines(rbuf, { "-- running…" })
    result.show(rbuf)

    if is_soft then
      -- Soft objects: compile the whole buffer as one unit
      notify.progress(nid, "Compiling…")
      result.run(ws, function(raw, err)
        if err then
          local output = require("ora.result.error").create({ raw = err })
          result.display(rbuf, output)
          notify.error(nid, "Compilation failed")
          return
        end
        local compile_output = require("ora.result.compile")
        local output = compile_output.create({
          raw         = raw,
          object_name = ws.db_object.name,
          object_type = ws.db_object.type,
          is_soft     = true,
        })
        if require("ora.result.error").is_error(raw) then
          notify.error(nid, "Compilation failed")
        else
          notify.done(nid, "Compiled successfully")
        end
        local sql = table.concat(vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
        result.push_history(ws, sql, output.lines)
        result.display(rbuf, output)
      end)
      return
    end

    -- Anonymous worksheet: split into blocks and run sequentially
    local full_sql = table.concat(vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
    local blocks = split_sql_blocks(full_sql)
    if #blocks == 0 then
      notify.warn(nid, "Worksheet is empty")
      return
    end

    notify.progress(nid, "Executing " .. #blocks .. " block" .. (#blocks == 1 and "" or "s") .. "…")

    run_blocks(ws, blocks, result, rbuf, function(sections)
      local multi = require("ora.result.multi")
      local output = multi.create({ sections = sections })

      local has_error = false
      for _, sec in ipairs(sections) do
        if sec.output.type == "error" then has_error = true end
      end
      if has_error then
        notify.error(nid, "Execution completed with errors")
      else
        notify.done(nid, "All blocks executed")
      end

      result.push_history(ws, full_sql, output.lines)
      result.display(rbuf, output)
    end)
  end

  if ws.connection then
    do_run()
  else
    require("ora.ui.picker").select(function(conn)
      if not conn then return end
      ws.connection = conn
      ws_mod.refresh_winbar(ws)
      do_run()
    end)
  end
end

-- ─── execute selected ─────────────────────────────────────────────────────

---Execute the selected SQL (visual selection) or the statement at cursor.
---Only works for regular worksheets (not db_object worksheets).
function M.execute_worksheet_selected()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr   = vim.api.nvim_get_current_buf()
  local ws_mod  = require("ora.worksheet")
  local ws      = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  if ws.db_object then
    notify.warn("ora", "Use OraWorksheetExecute to compile db object worksheets")
    return
  end

  -- Extract SQL: visual selection or statement at cursor.
  local mode = vim.fn.mode()
  local sql
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \27")  -- exit visual to update '< and '> marks
    local start_row = vim.fn.line("'<")
    local end_row   = vim.fn.line("'>")
    local sel_lines = vim.api.nvim_buf_get_lines(bufnr, start_row - 1, end_row, false)
    if mode == "v" then
      local start_col = vim.fn.col("'<")
      local end_col   = vim.fn.col("'>")
      if #sel_lines == 1 then
        sel_lines[1] = sel_lines[1]:sub(start_col, end_col)
      else
        sel_lines[1] = sel_lines[1]:sub(start_col)
        sel_lines[#sel_lines] = sel_lines[#sel_lines]:sub(1, end_col)
      end
    end
    sql = table.concat(sel_lines, "\n")
  else
    sql = sql_at_cursor(bufnr)
  end

  sql = vim.trim(sql)
  if sql == "" then
    notify.warn("ora", "No SQL statement at cursor")
    return
  end

  local function do_run()
    local result = require("ora.result")
    local nid = "ora_exec"
    local rbuf = result.get_or_create_buf(ws)
    result.set_buf_lines(rbuf, { "-- running…" })
    result.show(rbuf)

    local blocks = split_sql_blocks(sql)
    if #blocks == 0 then
      notify.warn(nid, "No SQL to execute")
      return
    end

    notify.progress(nid, "Executing " .. #blocks .. " block" .. (#blocks == 1 and "" or "s") .. "…")

    run_blocks(ws, blocks, result, rbuf, function(sections)
      local multi = require("ora.result.multi")
      local output = multi.create({ sections = sections })

      local has_error = false
      for _, sec in ipairs(sections) do
        if sec.output.type == "error" then has_error = true end
      end
      if has_error then
        notify.error(nid, "Execution completed with errors")
      else
        notify.done(nid, "All blocks executed")
      end

      result.push_history(ws, sql, output.lines)
      result.display(rbuf, output)
    end)
  end

  if ws.connection then
    do_run()
  else
    require("ora.ui.picker").select(function(conn)
      if not conn then return end
      ws.connection = conn
      ws_mod.refresh_winbar(ws)
      do_run()
    end)
  end
end

---Extract SQL from the current buffer: visual selection or full buffer.
---@param bufnr integer
---@return string|nil sql
local function get_worksheet_sql(bufnr)
  local mode = vim.fn.mode()
  local sql
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \27")
    local start_row = vim.fn.line("'<")
    local end_row   = vim.fn.line("'>")
    local sel_lines = vim.api.nvim_buf_get_lines(bufnr, start_row - 1, end_row, false)
    if mode == "v" then
      local start_col = vim.fn.col("'<")
      local end_col   = vim.fn.col("'>")
      if #sel_lines == 1 then
        sel_lines[1] = sel_lines[1]:sub(start_col, end_col)
      else
        sel_lines[1] = sel_lines[1]:sub(start_col)
        sel_lines[#sel_lines] = sel_lines[#sel_lines]:sub(1, end_col)
      end
    end
    sql = table.concat(sel_lines, "\n")
  else
    sql = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end
  sql = vim.trim(sql)
  if sql == "" then return nil end
  return sql
end

---Show the explain plan for the current worksheet or visual selection.
function M.explain_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr   = vim.api.nvim_get_current_buf()
  local ws_mod  = require("ora.worksheet")
  local ws      = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  if ws.db_object and ws.db_object.kind ~= "soft" then
    notify.warn("ora", ws.db_object.type .. " worksheet cannot be explained")
    return
  end

  local sql = get_worksheet_sql(bufnr)
  if not sql then
    notify.warn("ora", "Worksheet is empty")
    return
  end

  local function do_explain()
    local result = require("ora.result")
    local nid = "ora_explain"
    local rbuf = result.get_or_create_buf(ws)
    result.set_buf_lines(rbuf, { "-- loading explain plan…" })
    result.show(rbuf)

    notify.progress(nid, "Loading explain plan…")

    result.run_explain(ws, sql, function(raw, err)
      if err then
        local out = require("ora.result.error").create({ raw = err })
        result.display(rbuf, out)
        notify.error(nid, "Explain plan failed")
        return
      end

      local out = require("ora.result.explain").create({ raw = raw })
      result.display(rbuf, out)
      notify.done(nid, "Explain plan loaded")
    end)
  end

  if ws.connection then
    do_explain()
  else
    require("ora.ui.picker").select(function(conn)
      if not conn then return end
      ws.connection = conn
      ws_mod.refresh_winbar(ws)
      do_explain()
    end)
  end
end

---Show the actual execution plan for the current worksheet or visual selection.
function M.execution_plan()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr   = vim.api.nvim_get_current_buf()
  local ws_mod  = require("ora.worksheet")
  local ws      = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  if ws.db_object and ws.db_object.kind ~= "soft" then
    notify.warn("ora", ws.db_object.type .. " worksheet cannot show execution plan")
    return
  end

  local sql = get_worksheet_sql(bufnr)
  if not sql then
    notify.warn("ora", "Worksheet is empty")
    return
  end

  local function do_execution()
    local result = require("ora.result")
    local nid = "ora_execution"
    local rbuf = result.get_or_create_buf(ws)
    result.set_buf_lines(rbuf, { "-- running query and loading execution plan…" })
    result.show(rbuf)

    notify.progress(nid, "Loading execution plan…")

    result.run_execution(ws, sql, function(raw, err)
      if err then
        local out = require("ora.result.error").create({ raw = err })
        result.display(rbuf, out)
        notify.error(nid, "Execution plan failed")
        return
      end

      local out = require("ora.result.execution").create({ raw = raw })
      result.display(rbuf, out)
      notify.done(nid, "Execution plan loaded")
    end)
  end

  if ws.connection then
    do_execution()
  else
    require("ora.ui.picker").select(function(conn)
      if not conn then return end
      ws.connection = conn
      ws_mod.refresh_winbar(ws)
      do_execution()
    end)
  end
end

---Format the current worksheet SQL using SQLcl's built-in formatter.
function M.format_worksheet()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  require("ora.format").run(ws.bufnr, function(err)
    if err then
      notify.error("ora", "format failed: " .. err)
    end
  end)
end

---Change the connection for the current worksheet.
---Opens the connection picker; the selected connection replaces the current one.
function M.change_worksheet_connection()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local ws_mod = require("ora.worksheet")
  local ws     = ws_mod.find(bufnr) or ws_mod.register(bufnr)

  require("ora.ui.picker").select(function(conn)
    if not conn then return end
    ws.connection = conn
    ws_mod.refresh_winbar(ws)
  end)
end

---Open the quick action picker: find objects by pattern and act on them.
function M.quick_action()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("ora.ui.quick_action").open()
end

---Open the neo-tree Oracle connections/schemas explorer.
function M.explorer()
  if not _setup_done then
    notify.error("ora", "call require('ora').setup({...}) first")
    return
  end
  require("neo-tree.command").execute({ source = "ora", position = "left", toggle = true })
end

-- Exposed for testing
M._split_sql_blocks = split_sql_blocks

return M
