# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development commands

```bash
# Run all tests
make test

# Run a single spec file
make test-file FILE=spec/ora/config_spec.lua

# Launch nvim with the plugin loaded for interactive testing
make dev   # then :OraExplorer, :OraConnectionsList, :OraWorksheetNew

# Syntax-check a single Lua file (quick sanity check, no plenary needed)
nvim --headless -u NONE --cmd "set rtp+=." \
  --cmd "lua require('ora').setup({ sqlcl_path = 'sql' })" +q
```

Tests use **plenary.nvim** (busted runner). Plenary must be installed at
`~/.local/share/nvim/lazy/plenary.nvim`. If placed elsewhere, update `spec/minimal_init.lua`.

## Architecture

`plugin/ora.lua` is the auto-loaded entry point. It registers the user commands
(`OraConnectionsList`, `OraConnect`, `OraAddConnection`, `OraWorksheetNew`,
`OraWorksheetsList`, `OraWorksheetExecute`, `OraWorksheetFormat`,
`OraWorksheetChangeConnection`, `OraExplorer`) and guards against double-loading
with `vim.g.loaded_ora`. It never does any work itself — it delegates to
`lua/ora/init.lua`.

`lua/ora/init.lua` is the public API module. It owns the `_setup_done` flag that gates
all other calls. `setup()` delegates to `config.lua`; `list()` delegates to
`ui/picker.lua`; `connect()` delegates to `connection.lua`.

`lua/ora/config.lua` holds the single `M.values` table (merged defaults + user config).
Every other module reads config exclusively through `require("ora.config").values` —
config is never passed as function arguments between modules.

`lua/ora/connection.lua` owns the `sessions` table (`url -> bufnr`) which tracks live
SQLcl terminal buffers. `connect()` checks session liveness, reuses an existing
window/buffer when possible, and otherwise opens a `botright split` terminal via
`vim.fn.termopen`. Buffer names follow the pattern `ora://<label>`.

`lua/ora/connmgr.lua` interfaces with SQLcl's connection manager (`connmgr`).
`list()` returns stored connection names, `show(name)` returns connection details
(connect_string, user), `add(name, url)` creates a new named connection. All calls
run SQLcl `/nolog` via `plenary.Job:sync()`.

`lua/ora/worksheet.lua` tracks open SQL/PL/SQL worksheet buffers and their connections.
`create()` makes a new buffer, `find(bufnr)` looks up by buffer number,
`register(bufnr)` adopts an existing buffer. Each worksheet has a winbar showing
the worksheet/object name (left) and connection name (right).

`lua/ora/result.lua` runs worksheet SQL via one-shot SQLcl jobs (JSON output),
parses result sets, and formats them as column-aligned ASCII tables with highlights
in a per-worksheet read-only split buffer.

`lua/ora/format.lua` formats worksheet SQL using SQLcl's `FORMAT FILE` command.
Runs `/nolog` (no DB connection required).

`lua/ora/schema.lua` fetches Oracle data dictionary metadata via one-shot SQLcl jobs.
Uses `plenary.Job:start()` for async queries. Functions include:
- `fetch_tables_with_comments` — `user_tables` + `user_tab_comments`
- `fetch_columns_with_types` — `user_tab_columns` (name + data_type)
- `fetch_indexes`, `fetch_constraints` — `user_indexes`, `user_constraints`
- `fetch_comments` — `user_col_comments` (multi-column)
- `fetch_functions_with_return_type` — `user_arguments` (position 0)
- `fetch_procedures` — `user_objects`
- `fetch_packages` — `user_objects`
- `fetch_package_subprograms_with_types` — `user_procedures` + `user_arguments`
- `fetch_source` — `user_source` (package spec/body, function/procedure body)
- `fetch_ddl` — `DBMS_METADATA.GET_DDL`
- `fetch_object_params`, `fetch_subprogram_params` — `user_arguments` (multi-column)
- `fetch_package_has_body` — checks for `PACKAGE BODY` in `user_objects`

### Neo-tree explorer

The schema explorer lives in `lua/neo-tree/sources/ora/` and follows neo-tree's
source plugin pattern:

`lua/neo-tree/sources/ora/init.lua` — source entry point with `navigate()` and
`setup()`. Defines `default_renderers` for all custom node types (connection,
category, table, column, index, constraint, function, procedure, package,
package_part, subprogram, parameter, table_action, source_action, message).
Renderers are injected into `state.renderers` during navigate.

`lua/neo-tree/sources/ora/commands.lua` — all keybinding commands:
- `toggle_node` (`<CR>`) — context-aware: connect, expand/collapse, open source
- `expand_node` (`l`) — expand only, never collapse
- `collapse_node` (`h`) — collapse or jump to parent
- `open_object` (`e`) — open object: picker for packages/tables, direct for functions/procedures
- `refresh` (`r`) — context-aware: re-fetch children or refresh connection list
- `add_connection` (`a`) — open add-connection prompt

Internal handlers:
- `_toggle_connection` — marks connected, caches schema name from `connmgr.show()`,
  navigates and expands. Schema name stored in `state.ora_schema[conn_name]`.
- `_toggle_category` — lazy-loads Tables/Functions/Procedures/Packages children
- `_toggle_table` — fetches 4 types in parallel (columns, indexes, constraints,
  column comments), merges comments into column nodes, adds DDL + Data action nodes
- `_toggle_func_or_proc` — fetches params, adds Body source_action node
- `_toggle_package` — fetches has_body + subprograms (with return types) in parallel,
  adds Specification/Body package_part nodes
- `_toggle_subprogram` — fetches params
- `_open_package_source` — fetches source, creates worksheet with connection pre-set
- `_open_object_source` — fetches function/procedure source, creates worksheet
- `_open_table_action` — DDL: fetches via DBMS_METADATA; Data: pre-fills SELECT *
- `_set_category_children` — caches children, preserves expansion state across rebuilds
- `_collect_expanded` / `_restore_expanded` — save/restore NuiTree node expansion

`lua/neo-tree/sources/ora/components.lua` — custom rendering components:
- `icon` — per-type nerd font icons with type-specific highlights; loading spinner
- `name` — type-specific highlights; category count when loaded; loading "…" suffix
- `return_type` — italic dimmed text for function return types, column data types,
  parameter data types (uses `OraReturnType` highlight)
- `comment` — dimmed text for table comments and column comments

`lua/neo-tree/sources/ora/lib/items.lua` — builds tree nodes from schema data.
`get_items(state)` reads connmgr, builds connection nodes, caches category stubs
in `state.ora_children`. Builder functions: `make_table_children`,
`make_column_children`, `make_index_children`, `make_constraint_children`,
`make_function_children`, `make_procedure_children`, `make_package_children`,
`make_subprogram_children`, `make_parameter_children`, `make_object_parameter_children`.

### Neo-tree state

The explorer stores state on the neo-tree state object:
- `state.ora_connected` — `{[conn_name]: boolean}` — which connections are active
- `state.ora_children` — `{[conn_name]: table[]}` — cached category children
- `state.ora_schema` — `{[conn_name]: string}` — Oracle user/schema name per connection

### Node types and their `extra` fields

- `connection` — `{key, is_named, connected}`
- `category` — `{category, conn_name, loaded}`
- `table` — `{conn_name, table_name, comment?, loaded}`
- `column` — `{conn_name, table_name, data_type, comment?}`
- `index` — `{conn_name, table_name}`
- `constraint` — `{conn_name, table_name}`
- `function` — `{conn_name, object_name, return_type, loaded}`
- `procedure` — `{conn_name, object_name, loaded}`
- `package` — `{conn_name, pkg_name, loaded}`
- `package_part` — `{conn_name, pkg_name, part}` (part = "spec" | "body")
- `subprogram` — `{conn_name, pkg_name, subprogram, return_type?, loaded}`
- `parameter` — `{conn_name, data_type, ...}`
- `table_action` — `{conn_name, table_name, action}` (action = "ddl" | "data")
- `source_action` — `{conn_name, object_name, object_type}`

## UI libraries

- **nui.nvim** — all floating UI (picker, worksheets picker, prompts)
- **plenary.Job** — all non-interactive external processes (connmgr, schema queries,
  result execution, formatting). `vim.fn.termopen` stays in `connection.lua` for
  interactive PTY sessions.

`lua/ora/ui/picker.lua` — nui.menu-based connection picker. Supports both direct
connect mode and select mode (callback with chosen connection).

`lua/ora/ui/prompt.lua` — nui.input wrapper for connection string input.

`lua/ora/ui/add_connection.lua` — nui.input prompts for name + URL.

`lua/ora/ui/worksheets_picker.lua` — nui.menu picker for open worksheets.

## Test layout

```
spec/
  minimal_init.lua          -- sets rtp for plugin + plenary
  ora/
    config_spec.lua         -- config validation (pure Lua, no mocking)
    connection_spec.lua     -- session management (vim.fn.termopen stubbed)
    connmgr_spec.lua        -- connmgr list/show/add (plenary.job stubbed)
    result_spec.lua         -- result execution and formatting
    ui/
      prompt_spec.lua       -- vim.ui.input stubbed
      picker_spec.lua       -- floating window; ora.connmgr stubbed via package.loaded
```

Tests stub `vim.fn.termopen` to avoid launching a real `sqlcl` process. `session_alive`
internally checks `buftype == "terminal"`, which can only be set by a real `termopen`
call, so session-reuse paths are covered by observable side-effects (termopen call
count, buffer naming) rather than direct session-table inspection.

### Test stub patterns

- **plenary.job stub**: set `package.loaded["plenary.job"]` BEFORE `fresh()` (loaded
  lazily in run()). Do NOT clear plenary.job inside `fresh()`.
- **nui.input stub**: set `package.loaded["nui.input"]` BEFORE `fresh()` (loaded at
  module load time). Do NOT clear nui.input inside `fresh()`.

## Conventions

- LuaCATS annotations (`---@param`, `---@class`, etc.) are used throughout — keep them
  in sync when changing function signatures.
- Highlight groups are defined with `default = true` so colorschemes can override them.
- The `sessions` table in `connection.lua` is keyed by raw URL string. Two different URL
  spellings for the same DB create two sessions — this is intentional.
- `vim.api.nvim_buf_set_option` / `nvim_win_set_option` are used instead of
  `vim.bo`/`vim.wo` for explicitness; keep this consistent.
- Multi-column query results (comments, parameters, return types) use custom JSON
  parsing in `schema.lua` instead of the single-column `run_query` helper.
- Async parallel fetches use a pending counter pattern with an `on_done()` callback.
- Source lines from `user_source` contain trailing newlines — strip with
  `line:gsub("%s+$", "")` before splitting.
- Worksheet display names for objects opened from the explorer show
  `SCHEMA.OBJECT_NAME (Type Detail)`, where schema is the Oracle user from
  `connmgr.show()`, not the connection name.
