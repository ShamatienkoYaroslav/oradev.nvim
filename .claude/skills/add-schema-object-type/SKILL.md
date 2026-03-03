---
name: add-schema-object-type
description: Add a new Oracle schema object type to the neo-tree explorer. Use when the user asks to add support for a new database object (e.g., triggers, sequences, types, materialized views).
---

# Add a New Schema Object Type

Guide for adding a new Oracle schema object type to the neo-tree explorer.
Uses "triggers" as the running example — substitute your own type throughout.

## Files to modify (in order)

| #   | File                                      | What to add                                                         |
| --- | ----------------------------------------- | ------------------------------------------------------------------- |
| 1   | `lua/ora/schema.lua`                      | `fetch_triggers` query function                                     |
| 2   | `lua/neo-tree/sources/ora/lib/items.lua`  | Category stub + `make_trigger_children` builder                     |
| 3   | `lua/neo-tree/sources/ora/components.lua` | Icon, name highlight, comment/return_type (if needed)               |
| 4   | `lua/neo-tree/sources/ora/init.lua`       | Renderer entry in `default_renderers`                               |
| 5   | `lua/neo-tree/sources/ora/commands.lua`   | Category dispatch, toggle, keybinding handlers, action picker       |
| 6   | `.claude/CLAUDE.md`                       | Document the new node type, extra fields, schema function, commands |

---

## Step 1 — Schema fetch function (`lua/ora/schema.lua`)

Add a function that queries the data dictionary. Use `run_multi_query` for
multi-column results or `run_query` for single-column.

```lua
---Fetch triggers from user_triggers.
---@param conn     {key: string, is_named: boolean}
---@param callback fun(triggers: {name: string, table_name: string, trigger_type: string}[]|nil, err: string|nil)
function M.fetch_triggers(conn, callback)
  run_multi_query(conn,
    "SELECT trigger_name, table_name, trigger_type FROM user_triggers ORDER BY trigger_name",
    function(items, err)
      if err then callback(nil, err); return end
      local triggers = {}
      for _, item in ipairs(items or {}) do
        local name  = item.TRIGGER_NAME  or item.trigger_name
        local tname = item.TABLE_NAME    or item.table_name
        local ttype = item.TRIGGER_TYPE  or item.trigger_type
        if name and name ~= vim.NIL then
          table.insert(triggers, {
            name         = tostring(name),
            table_name   = (tname and tname ~= vim.NIL) and tostring(tname) or "",
            trigger_type = (ttype and ttype ~= vim.NIL) and tostring(ttype) or "",
          })
        end
      end
      callback(triggers, nil)
    end)
end
```

Pattern notes:

- Always handle both UPPER and lowercase column keys (SQLcl version dependent).
- Guard `vim.NIL` values and `tostring()` everything.
- For DDL fetching, use the existing `run_ddl_query(conn, "TRIGGER", name, cb)` helper.
- For CLOB output (source code), use `run_clob_query(conn, sql, cb)`.

---

## Step 2 — Tree nodes (`lua/neo-tree/sources/ora/lib/items.lua`)

### 2a — Category stub

Add an entry to `make_category_stubs`. Position in the list controls display order.

```lua
{
  id       = "cat:" .. conn_name .. ":Triggers",
  name     = "Triggers",
  type     = "category",
  path     = conn_name .. "/Triggers",
  children = {},
  extra    = { category = "triggers", conn_name = conn_name, loaded = false },
},
```

Key fields:

- `extra.category` — lowercase key used to dispatch in `_toggle_category`.
- `extra.loaded` — starts `false`, set `true` after first fetch.

### 2b — Builder function

```lua
---Build child nodes for triggers.
---@param conn_name string
---@param triggers  {name: string, table_name: string, trigger_type: string}[]
---@return table[]
function M.make_trigger_children(conn_name, triggers)
  local children = {}
  for _, t in ipairs(triggers) do
    table.insert(children, {
      id       = "trg:" .. conn_name .. ":" .. t.name,
      name     = t.name,
      type     = "trigger",
      path     = conn_name .. "/Triggers/" .. t.name,
      children = {},
      extra    = {
        conn_name    = conn_name,
        trigger_name = t.name,
        table_name   = t.table_name,
        trigger_type = t.trigger_type,
        loaded       = false,
      },
    })
  end
  return children
end
```

Pattern notes:

- `id` prefix must be unique across all types (e.g., `"trg:"`).
- `type` is your custom node type string — used everywhere else.
- Put all type-specific data in `extra` for later use by commands/components.

---

## Step 3 — Components (`lua/neo-tree/sources/ora/components.lua`)

### 3a — Icon

Add to the `icons` table:

```lua
trigger = { text = "󱐋 ", hl = "Keyword" },
```

No changes needed to the `icon` function unless you need context-aware icons
(like connected vs disconnected).

### 3b — Name highlight

Add to the `name` function's `elseif` chain:

```lua
elseif node.type == "trigger" then
  highlight = highlights.FILE_NAME
```

Use `highlights.DIRECTORY_NAME` if the node is expandable with children.

### 3c — Comment (optional)

If the node has supplementary info to display, add to the `comment` function:

```lua
elseif node.type == "trigger" then
  cmt = node.extra and node.extra.table_name
```

### 3d — Return type (optional)

If the node has a data type or return type, add to the `return_type` function:

```lua
elseif node.type == "trigger" then
  rt = node.extra and node.extra.trigger_type
```

---

## Step 4 — Renderer (`lua/neo-tree/sources/ora/init.lua`)

Add to the `default_renderers` table. Pick components based on what data you show:

```lua
trigger = {
  { "indent" },
  { "icon" },
  { "name" },
  { "comment" },     -- shows table_name
},
```

Available components: `indent`, `icon`, `name`, `return_type`, `comment`.

---

## Step 5 — Commands (`lua/neo-tree/sources/ora/commands.lua`)

### 5a — Category dispatch in `_toggle_category`

Add to the `if category == ...` chain:

```lua
elseif category == "triggers" then
  fetch_fn = function(cb) schema.fetch_triggers(conn, cb) end
  build_fn = function(triggers) return items.make_trigger_children(conn_name, triggers) end
```

### 5b — Toggle handler (for expanding the node itself)

For leaf nodes (no children), skip this. For expandable nodes:

```lua
M._toggle_trigger = function(state, node)
  if node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
    return
  end
  if node.extra.loaded then
    node:expand()
    renderer.redraw(state)
    return
  end

  local conn_name    = node.extra.conn_name
  local trigger_name = node.extra.trigger_name

  -- Build static children (e.g., DDL action) or fetch dynamic ones
  local children = {
    {
      id       = "trg_ddl:" .. conn_name .. ":" .. trigger_name,
      name     = "DDL",
      type     = "source_action",
      path     = conn_name .. "/Triggers/" .. trigger_name .. "/DDL",
      children = {},
      extra    = { conn_name = conn_name, object_name = trigger_name, object_type = "TRIGGER" },
    },
  }
  M._set_category_children(state, node, conn_name, children)
end
```

### 5c — Wire into `toggle_node` (`<CR>`)

Add to the `toggle_node` function's `elseif` chain:

```lua
elseif node.type == "trigger" then
  M._toggle_trigger(state, node)
```

### 5d — Wire into `expand_node` (`l`) and `collapse_node` (`h`)

In `expand_node`, add the same pattern:

```lua
elseif node.type == "trigger" and node.extra and node.extra.loaded then
    -- already loaded, just expand
elseif node.type == "trigger" then
    M._toggle_trigger(state, node)
```

No changes needed for `collapse_node` — it handles all types generically.

### 5e — Quick open (`o` key) in `quick_open`

For direct action on the node (e.g., DDL):

```lua
elseif node.type == "trigger" then
  local fake = {
    extra = { conn_name = node.extra.conn_name, object_name = node.extra.trigger_name, object_type = "TRIGGER", loading = false },
  }
  M._open_object_source(state, fake)
```

### 5f — Action picker (`a` key) in `show_actions`

```lua
elseif node.type == "trigger" then
  local conn_name    = node.extra.conn_name
  local trigger_name = node.extra.trigger_name
  action_picker(trigger_name, { "Show DDL", "Drop trigger" }, function(choice)
    if choice == "Show DDL" then
      -- fetch DDL via DBMS_METADATA and open worksheet
    elseif choice == "Drop trigger" then
      open_drop_worksheet(state, conn_name, trigger_name, "TRIGGER")
    end
  end)
```

### 5g — Refresh (`r` key)

The `refresh` function already handles categories generically. If your node type
needs its own refresh (re-fetch children), add it to the `refresh` function.

---

## Step 6 — Update CLAUDE.md

Add to the relevant sections:

- `schema.lua` functions list: document the new `fetch_*` function
- Node types and `extra` fields: document the new type
- `commands.lua` handlers: document new `_toggle_*` and `_open_*` functions
- `items.lua` builder functions: add `make_trigger_children`

---

## Step 7 — Update README.md

Update these sections in `README.md`:

### Quick open table (`### Quick open with o / O`)

Add a row for the new type with its `o` and `O` actions:

```markdown
| Trigger | Show DDL | — |
```

### All actions table (`### All actions with a`)

Add a row listing all action picker choices:

```markdown
| Trigger | Show DDL, Drop trigger |
```

### Supported object types table (`### Supported object types`)

Add a row describing what the explorer shows for the type:

```markdown
| **Triggers** | Table name, trigger type, source, DDL |
```

### Tree structure (`### Tree structure`)

If useful, add an example subtree showing the new category and its children:

```
│   ├── 󰉋 Triggers (2)
│   │   ├── 󱐋 AUDIT_TRG  EMPLOYEES
│   │   └── 󱐋 LOG_TRG    ORDERS
```

---

## Step 8 — Testing

### Syntax check

Run a quick syntax check on every modified Lua file:

```bash
luajit -bl lua/ora/schema.lua /dev/null
luajit -bl lua/neo-tree/sources/ora/lib/items.lua /dev/null
luajit -bl lua/neo-tree/sources/ora/components.lua /dev/null
luajit -bl lua/neo-tree/sources/ora/init.lua /dev/null
luajit -bl lua/neo-tree/sources/ora/commands.lua /dev/null
```

### Automated tests

Run the full test suite to catch regressions:

```bash
make test
```

All existing tests must still pass. If the new type introduces testable pure-Lua
logic (e.g., a builder function that transforms data), add a spec file:

```
spec/ora/schema_triggers_spec.lua
```

Follow the existing stub patterns (see CLAUDE.md "Test stub patterns"):

- Stub `plenary.job` via `package.loaded["plenary.job"]` **before** requiring the module.
- Use `package.loaded` to inject fakes for any module loaded at require-time.

### Interactive testing

```bash
make dev
```

Then verify manually:

1. `:OraExplorer` — the new category appears under each connected schema.
2. `<CR>` on the category — children load with a spinner, then appear with correct
   icons, names, and supplementary text (comment/return_type).
3. `<CR>` on a child node — expands (if expandable) or does nothing (if leaf).
4. `o` on a child node — opens the expected worksheet (source/DDL/data).
5. `O` on a child node — opens the secondary artifact (if applicable).
6. `a` on a child node — action picker appears with the correct choices; each
   choice opens the right worksheet.
7. `r` on the category — re-fetches children (count may change).
8. `h` / `l` — collapse/expand works correctly.

---

## Checklist

- [ ] `schema.lua` — fetch function added
- [ ] `items.lua` — category stub added to `make_category_stubs`
- [ ] `items.lua` — builder function `make_*_children` added
- [ ] `components.lua` — icon added to `icons` table
- [ ] `components.lua` — name highlight added
- [ ] `components.lua` — comment/return_type added (if applicable)
- [ ] `init.lua` — renderer added to `default_renderers`
- [ ] `commands.lua` — dispatch added in `_toggle_category`
- [ ] `commands.lua` — toggle handler added (if expandable)
- [ ] `commands.lua` — `toggle_node` wired up
- [ ] `commands.lua` — `expand_node` wired up
- [ ] `commands.lua` — `quick_open` wired up
- [ ] `commands.lua` — `show_actions` wired up
- [ ] `CLAUDE.md` — documented
- [ ] `README.md` — updated (quick open, actions, supported types, tree)
- [ ] Syntax check passes on all modified files
- [ ] `make test` passes (no regressions)
- [ ] `make dev` — category appears, children load, icons/highlights correct
- [ ] `make dev` — `o`, `O`, `a` keybindings work on the new node type
- [ ] `make dev` — `r` refreshes children, `h`/`l` collapse/expand
