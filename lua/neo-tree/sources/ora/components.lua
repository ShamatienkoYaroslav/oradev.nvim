-- Custom rendering components for the ora neo-tree source.

local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")

---@type table<string, neotree.Renderer>
local M = {}

-- Icons for each node type
local icons = {
  folder           = { text = " ", hl = "Directory" },
  connection       = { text = "󰆼 ", hl = "Special" },
  connection_on    = { text = "󰆼 ", hl = "DiagnosticOk" },
  category         = { text = "󰉋 ", hl = "Directory" },
  table            = { text = "󰓫 ", hl = "Type" },
  schema_index     = { text = "󰌹 ", hl = "Number" },
  synonym          = { text = "󰔖 ", hl = "Type" },
  view             = { text = "󰡠 ", hl = "Type" },
  column           = { text = "󰠵 ", hl = "Identifier" },
  index            = { text = "󰌹 ", hl = "Number" },
  constraint       = { text = "󰌆 ", hl = "Keyword" },
  comment          = { text = "󰆈 ", hl = "Comment" },
  table_comment    = { text = "󰆈 ", hl = "Comment" },
  ["function"]     = { text = "󰊕 ", hl = "Function" },
  procedure        = { text = "󰡱 ", hl = "Function" },
  package          = { text = "󰏗 ", hl = "OraIconPackage" },
  subprogram       = { text = "󰊕 ", hl = "Function" },
  parameter        = { text = "󰆧 ", hl = "Identifier" },
  trigger          = { text = "󱐋 ", hl = "Keyword" },
  message          = { text = "󰍡 ", hl = "Comment" },
  sequence         = { text = "󰔚 ", hl = "Number" },
  ords_module      = { text = "󰒍 ", hl = "Type" },
  ords_template    = { text = "󰅩 ", hl = "String" },
  ords_handler     = { text = "󰌑 ", hl = "Function" },
  ords_parameter   = { text = "󰆧 ", hl = "Identifier" },
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

  if node.type == "folder" then
    highlight = highlights.DIRECTORY_NAME
  elseif node.type == "connection" then
    highlight = highlights.FILE_NAME
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
  elseif node.type == "synonym" then
    highlight = highlights.FILE_NAME
  elseif node.type == "schema_index" then
    highlight = highlights.FILE_NAME
  elseif node.type == "package" then
    highlight = highlights.DIRECTORY_NAME
  elseif node.type == "subprogram" then
    highlight = highlights.FILE_NAME
  elseif node.type == "parameter" then
    highlight = highlights.FILE_NAME
  elseif node.type == "sequence" then
    highlight = highlights.FILE_NAME
  elseif node.type == "trigger" then
    highlight = highlights.FILE_NAME
  elseif node.type == "ords_module" then
    highlight = highlights.FILE_NAME
  elseif node.type == "ords_template" then
    highlight = highlights.FILE_NAME
  elseif node.type == "ords_handler" then
    highlight = highlights.FILE_NAME
  elseif node.type == "ords_parameter" then
    highlight = highlights.FILE_NAME
  end

  return {
    text = name,
    highlight = highlight,
  }
end

M.comment = function(config, node, state)
  local cmt = node.extra and node.extra.comment
  if node.type == "ords_module" then
    cmt = node.extra and node.extra.uri_prefix
  elseif node.type == "synonym" then
    cmt = node.extra and node.extra.target
  elseif node.type == "schema_index" then
    cmt = node.extra and node.extra.detail
  elseif node.type == "sequence" then
    cmt = node.extra and node.extra.detail
  elseif node.type == "trigger" then
    cmt = node.extra and node.extra.table_name
  end
  if not cmt or cmt == "" then return { text = "" } end
  return { text = " " .. cmt, highlight = highlights.DIM_TEXT }
end

M.return_type = function(config, node, state)
  local rt
  if node.type == "function" or node.type == "subprogram" then
    rt = node.extra and node.extra.return_type
  elseif node.type == "column" or node.type == "parameter" then
    rt = node.extra and node.extra.data_type
  elseif node.type == "ords_parameter" then
    rt = node.extra and node.extra.param_type
  end
  if not rt or rt == "" then return { text = "" } end
  vim.api.nvim_set_hl(0, "OraReturnType", { italic = true, link = "Comment", default = true })
  return { text = " " .. rt, highlight = "OraReturnType" }
end

return vim.tbl_deep_extend("force", common, M)
