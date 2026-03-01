-- Format module: formats SQL/PL/SQL code using SQLcl's built-in FORMAT command.
-- Runs /nolog (no database connection required).

local M = {}

---Format the SQL content of a worksheet buffer asynchronously.
---Replaces the buffer content with the formatted result on success.
---@param bufnr integer
---@param callback fun(err: string|nil)
function M.run(bufnr, callback)
  local cfg = require("ora.config").values

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sql = vim.trim(table.concat(lines, "\n"))
  if sql == "" then
    callback("worksheet is empty")
    return
  end

  local sql_file = vim.fn.tempname() .. ".sql"
  local script   = vim.fn.tempname() .. ".sql"

  -- Write the raw SQL to a temp file for FORMAT FILE to process in-place
  local sf = assert(io.open(sql_file, "w"))
  sf:write(sql .. "\n")
  sf:close()

  local f = assert(io.open(script, "w"))
  f:write("SET ECHO OFF\n")
  f:write("SET FEEDBACK OFF\n")
  f:write("FORMAT FILE " .. sql_file .. "\n")
  f:write("EXIT\n")
  f:close()

  local Job = require("plenary.job")
  Job:new({
    command = cfg.sqlcl_path,
    args    = { "/nolog", "-S", "@" .. script },
    on_exit = function(_, code)
      os.remove(script)

      vim.schedule(function()
        -- FORMAT FILE overwrites the file in-place; read it back
        local fh = io.open(sql_file, "r")
        if not fh then
          callback("formatted file missing (sqlcl exited with code " .. code .. ")")
          return
        end
        local raw = fh:read("*a")
        fh:close()
        os.remove(sql_file)

        if code ~= 0 and vim.trim(raw) == "" then
          callback("sqlcl exited with code " .. code)
          return
        end

        local formatted = vim.trim(raw)
        if formatted == "" then
          callback("formatter returned empty output")
          return
        end

        local new_lines = vim.split(formatted, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
        callback(nil)
      end)
    end,
  }):start()
end

return M
