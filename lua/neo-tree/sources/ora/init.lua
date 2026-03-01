-- Neo-tree source for Oracle connections and schema browsing.

local renderer = require("neo-tree.ui.renderer")
local manager = require("neo-tree.sources.manager")
local items = require("neo-tree.sources.ora.lib.items")

---@class neotree.sources.Ora : neotree.Source
local M = {
  name = "ora",
  display_name = " 󰆼 Oracle ",
}

-- Default renderers for all ora node types.
-- Without these, neo-tree falls back to "type: name" display.
local default_renderers = {
  connection = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  category = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  table = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  table_comment = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  table_action = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  source_action = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  view = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  view_action = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  column = {
    { "indent" },
    { "icon" },
    { "name" },
    { "return_type" },
    { "comment" },
  },
  index = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  constraint = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  comment = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  ["function"] = {
    { "indent" },
    { "icon" },
    { "name" },
    { "return_type" },
  },
  procedure = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  package = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  package_part = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  subprogram = {
    { "indent" },
    { "icon" },
    { "name" },
    { "return_type" },
  },
  parameter = {
    { "indent" },
    { "icon" },
    { "name" },
    { "return_type" },
  },
  message = {
    { "indent" },
    { "icon" },
    { "name" },
  },
}

---Navigate to the given path and populate the tree.
---@param state neotree.State
---@param path string?
---@param path_to_reveal string?
---@param callback function?
---@param async boolean?
M.navigate = function(state, path, path_to_reveal, callback, async)
  state.dirty = false
  if not state.ora_connected then
    state.ora_connected = {}
  end
  if not state.ora_children then
    state.ora_children = {}
  end

  -- Merge default renderers with any user-configured ones
  if not state.renderers then state.renderers = {} end
  for ntype, rend in pairs(default_renderers) do
    if not state.renderers[ntype] then
      state.renderers[ntype] = rend
    end
  end

  items.get_items(state)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

---Configures the source. Called once during neo-tree setup.
---@param config table
---@param global_config table
M.setup = function(config, global_config)
  -- No automatic events needed — connections don't change on their own.
  -- Users press `r` to refresh.
end

return M
