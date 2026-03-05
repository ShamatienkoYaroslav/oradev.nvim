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
  folder = {
    { "indent" },
    { "icon" },
    { "name" },
  },
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
  view = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  mview = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  mview_log = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  synonym = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  schema_index = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
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
  sequence = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  trigger = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  ora_type = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  ords_module = {
    { "indent" },
    { "icon" },
    { "name" },
    { "comment" },
  },
  ords_template = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  ords_handler = {
    { "indent" },
    { "icon" },
    { "name" },
  },
  ords_parameter = {
    { "indent" },
    { "icon" },
    { "name" },
    { "return_type" },
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
---Overrides window mappings with explorer_mappings from ora.config.
---This runs after neo-tree merges global defaults, so we must force-set
---our mappings to replace generic filesystem commands (e.g. `a` = "add")
---with ora-specific ones (e.g. `a` = "show_actions").
---@param config table
---@param global_config table
M.setup = function(config, global_config)
  local ora_cfg = require("ora.config").values
  if ora_cfg.explorer_mappings then
    if not config.window then config.window = {} end
    if not config.window.mappings then config.window.mappings = {} end
    for key, cmd in pairs(ora_cfg.explorer_mappings) do
      config.window.mappings[key] = cmd
    end
  end
end

return M
