local M = {}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@return snacks.notifier|nil
local function notifier()
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.notifier then return snacks.notifier end
end

---Show/update a spinning progress notification.
---@param id string  unique notification ID (snacks replaces in-place)
---@param msg string
function M.progress(id, msg)
  local n = notifier()
  if not n then return end
  n.notify(msg, vim.log.levels.INFO, {
    id = id,
    title = "OraDev",
    opts = function(notif)
      notif.icon = spinner[math.floor(vim.uv.hrtime() / (1e6 * 80)) % #spinner + 1]
    end,
  })
end

---Replace a notification with a success checkmark.
---@param id string
---@param msg string
function M.done(id, msg)
  local n = notifier()
  if not n then return end
  n.notify(msg, vim.log.levels.INFO, { id = id, title = "OraDev", icon = " " })
end

---Replace a notification with an error icon.
---@param id string
---@param msg string
function M.error(id, msg)
  local n = notifier()
  if not n then
    vim.notify("[ora] " .. msg, vim.log.levels.ERROR)
    return
  end
  n.notify(msg, vim.log.levels.ERROR, { id = id, title = "OraDev", icon = " " })
end

---Show an info notification.
---@param id string
---@param msg string
function M.info(id, msg)
  local n = notifier()
  if not n then
    vim.notify("[ora] " .. msg, vim.log.levels.INFO)
    return
  end
  n.notify(msg, vim.log.levels.INFO, { id = id, title = "OraDev", icon = " " })
end

---Show a warning notification.
---@param id string
---@param msg string
function M.warn(id, msg)
  local n = notifier()
  if not n then
    vim.notify("[ora] " .. msg, vim.log.levels.WARN)
    return
  end
  n.notify(msg, vim.log.levels.WARN, { id = id, title = "OraDev", icon = " " })
end

return M
