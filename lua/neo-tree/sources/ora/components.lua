-- Custom rendering components for the ora neo-tree source.

local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")

---@type table<string, neotree.Renderer>
local M = {}

-- Icons for each node type
local icons = {
  connection       = { text = "󰆼 ", hl = "Special" },
  connection_on    = { text = "󰆼 ", hl = "DiagnosticOk" },
  category         = { text = "󰉋 ", hl = "Directory" },
  table            = { text = "󰓫 ", hl = "Type" },
  view             = { text = "󰡠 ", hl = "Type" },
  view_action      = { text = "󰈮 ", hl = "String" },
  column           = { text = "󰠵 ", hl = "Identifier" },
  index            = { text = "󰌹 ", hl = "Number" },
  constraint       = { text = "󰌆 ", hl = "Keyword" },
  comment          = { text = "󰆈 ", hl = "Comment" },
  table_comment    = { text = "󰆈 ", hl = "Comment" },
  ["function"]     = { text = "󰊕 ", hl = "Function" },
  procedure        = { text = "󰡱 ", hl = "Function" },
  package          = { text = "󰏗 ", hl = "Include" },
  package_part     = { text = "󰈮 ", hl = "String" },
  subprogram       = { text = "󰊕 ", hl = "Function" },
  parameter        = { text = "󰆧 ", hl = "Identifier" },
  table_action     = { text = "󰈮 ", hl = "String" },
  source_action    = { text = "󰈮 ", hl = "String" },
  message          = { text = "󰍡 ", hl = "Comment" },
}

M.icon = function(config, node, state)
  if node.extra and node.extra.loading then
    return { text = " ", highlight = "DiagnosticInfo" }
  end

  local t = node.type
  local ic

  if t == "connection" then
    local connected = node.extra and node.extra.connected
    ic = connected and icons.connection_on or icons.connection
  elseif t == "subprogram" then
    local has_return = node.extra and node.extra.return_type
    ic = has_return and icons.subprogram or icons.procedure
  else
    ic = icons[t]
  end

  if not ic then
    return { text = "  ", highlight = "Comment" }
  end

  return { text = ic.text, highlight = ic.hl }
end

M.name = function(config, node, state)
  local highlight = highlights.FILE_NAME
  local name = node.name

  -- Loading indicator
  if node.extra and node.extra.loading then
    return {
      text = name .. " …",
      highlight = "DiagnosticInfo",
    }
  end

  if node.type == "connection" then
    local connected = node.extra and node.extra.connected
    highlight = connected and highlights.FILE_NAME_OPENED or highlights.DIM_TEXT
  elseif node.type == "category" then
    highlight = highlights.DIRECTORY_NAME
    if node.extra and node.extra.loaded then
      local child_ids = node:get_child_ids()
      local count = child_ids and #child_ids or 0
      name = name .. " (" .. count .. ")"
    end
  elseif node.type == "message" then
    highlight = highlights.DIM_TEXT
  elseif node.type == "table" then
    highlight = highlights.FILE_NAME
  elseif node.type == "column" or node.type == "index" or node.type == "constraint" then
    highlight = highlights.FILE_NAME
  elseif node.type == "comment" or node.type == "table_comment" then
    highlight = highlights.FILE_NAME
  elseif node.type == "function" or node.type == "procedure" then
    highlight = highlights.FILE_NAME
  elseif node.type == "view" then
    highlight = highlights.FILE_NAME
  elseif node.type == "view_action" then
    highlight = highlights.FILE_NAME
  elseif node.type == "package" then
    highlight = highlights.DIRECTORY_NAME
  elseif node.type == "package_part" or node.type == "table_action" or node.type == "source_action" then
    highlight = highlights.FILE_NAME
  elseif node.type == "subprogram" then
    highlight = highlights.FILE_NAME
  elseif node.type == "parameter" then
    highlight = highlights.FILE_NAME
  end

  return {
    text = name,
    highlight = highlight,
  }
end

M.comment = function(config, node, state)
  local cmt = node.extra and node.extra.comment
  if not cmt or cmt == "" then return { text = "" } end
  return { text = " " .. cmt, highlight = highlights.DIM_TEXT }
end

M.return_type = function(config, node, state)
  local rt
  if node.type == "function" or node.type == "subprogram" then
    rt = node.extra and node.extra.return_type
  elseif node.type == "column" or node.type == "parameter" then
    rt = node.extra and node.extra.data_type
  end
  if not rt or rt == "" then return { text = "" } end
  vim.api.nvim_set_hl(0, "OraReturnType", { italic = true, link = "Comment", default = true })
  return { text = " " .. rt, highlight = "OraReturnType" }
end

return vim.tbl_deep_extend("force", common, M)
