# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development commands

```bash
# Run all tests
make test

# Run a single spec file
make test-file FILE=spec/ora/config_spec.lua

# Launch nvim with the plugin loaded for interactive testing
make dev   # then :OraConnectionsList to open picker, :OraAddConnection to add a connection

# Syntax-check a single Lua file (quick sanity check, no plenary needed)
nvim --headless -u NONE --cmd "set rtp+=." \
  --cmd "lua require('ora').setup({ sqlcl_path = 'sql' })" +q
```

Tests use **plenary.nvim** (busted runner). Plenary must be installed at
`~/.local/share/nvim/lazy/plenary.nvim`. If placed elsewhere, update `spec/minimal_init.lua`.

## Architecture

`plugin/ora.lua` is the auto-loaded entry point. It registers the user commands
(`OraConnectionsList`, `OraConnect`, `OraAddConnection`) and guards against double-loading with `vim.g.loaded_ora`.
It never does any work itself — it delegates to `lua/ora/init.lua`.

`lua/ora/init.lua` is the public API module. It owns the `_setup_done` flag that gates
all other calls. `setup()` delegates to `config.lua`; `open()` delegates to
`ui/picker.lua`; `connect()` delegates to `connection.lua`.

`lua/ora/config.lua` holds the single `M.values` table (merged defaults + user config).
Every other module reads config exclusively through `require("ora.config").values` —
config is never passed as function arguments between modules.

`lua/ora/connection.lua` owns the `sessions` table (`url -> bufnr`) which tracks live
SQLcl terminal buffers. `connect()` checks session liveness, reuses an existing
window/buffer when possible, and otherwise opens a `botright split` terminal via
`vim.fn.termopen`. Buffer names follow the pattern `ora://<label>`.

`lua/ora/ui/picker.lua` is a self-contained floating window. State is held in
module-level `state` (a `PickerState` or `nil`). The cursor index covers named
connections (1..N) plus one synthetic "action" item at position N+1. `render()` writes
lines and applies highlights from scratch on every cursor move. The picker closes on
`WinLeave` using a one-shot autocmd. Uses `vim.o.columns` / `vim.o.lines` as fallback
when `nvim_list_uis()` is empty (headless).

`lua/ora/ui/prompt.lua` is a thin wrapper around `vim.ui.input`, intentionally kept
separate so the connection-string flow can be triggered both from the picker (`s` key)
and directly from `init.lua`.

## Test layout

```
spec/
  minimal_init.lua          -- sets rtp for plugin + plenary
  ora/
    config_spec.lua         -- config validation (pure Lua, no mocking)
    connection_spec.lua     -- session management (vim.fn.termopen stubbed)
    connmgr_spec.lua        -- connmgr list/show/add (vim.fn.system stubbed)
    ui/
      prompt_spec.lua       -- vim.ui.input stubbed
      picker_spec.lua       -- floating window; ora.connmgr stubbed via package.loaded
```

Tests stub `vim.fn.termopen` to avoid launching a real `sqlcl` process. `session_alive`
internally checks `buftype == "terminal"`, which can only be set by a real `termopen`
call, so session-reuse paths are covered by observable side-effects (termopen call
count, buffer naming) rather than direct session-table inspection.

## Conventions

- LuaCATS annotations (`---@param`, `---@class`, etc.) are used throughout — keep them
  in sync when changing function signatures.
- Highlight groups are defined with `default = true` so colorschemes can override them.
- The `sessions` table in `connection.lua` is keyed by raw URL string. Two different URL
  spellings for the same DB create two sessions — this is intentional.
- `vim.api.nvim_buf_set_option` / `nvim_win_set_option` are used instead of
  `vim.bo`/`vim.wo` for explicitness; keep this consistent.
