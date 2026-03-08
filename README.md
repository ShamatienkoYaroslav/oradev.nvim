# oradev.nvim

A Neovim plugin providing a UI on top of [SQLcl](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/) for working with Oracle databases.

## Requirements

- Neovim ≥ 0.9
- [SQLcl](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/) installed and accessible
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, for rich notifications; falls back to `vim.notify`)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (optional, for the schema explorer)

## Installation

### lazy.nvim

```lua
{
  "ShamatienkoYaroslav/oradev.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim",
    "folke/snacks.nvim",
    "nvim-neo-tree/neo-tree.nvim",
  },
  config = function()
    require("ora").setup({
      sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
    })

    -- Register the "ora" source with neo-tree (required for :OraExplorer)
    require("neo-tree").setup({
      sources = {
        "filesystem",
        "ora",
      },
    })
  end,
}
```

## Configuration

```lua
require("ora").setup({
  -- Required: path to the sqlcl binary.
  -- On macOS with Homebrew: "/usr/local/bin/sql"
  -- On Linux:               "/opt/oracle/sqlcl/bin/sql"
  sqlcl_path = "sql",   -- default: "sql" (assumes it is on $PATH)

  -- Picker window dimensions (optional).
  win_width  = 60,
  win_height = 20,

  -- Schema explorer key mappings (optional).
  -- These are injected into neo-tree's ora source config automatically.
  -- Override individual keys or set to false to disable a mapping.
  explorer_mappings = {
    ["<cr>"] = "toggle_node",
    ["l"]    = "expand_node",
    ["h"]    = "collapse_node",
    ["r"]    = "refresh",
    ["o"]    = "quick_open",
    ["O"]    = "quick_open_alt",
    ["a"]    = "show_actions",
    ["A"]    = "add_connection",
  },
})
```

Named connections are managed through SQLcl's built-in connection manager (`connmgr`).
Use `:OraAddConnection` to add them — no hardcoded credentials in your config.

### Connection URL formats

nvim-ora passes the URL directly to `sqlcl`, so any format sqlcl accepts works:

| Format                      | Example                                 |
| --------------------------- | --------------------------------------- |
| user/pass@host:port/service | `scott/tiger@localhost:1521/XEPDB1`     |
| EZConnect                   | `scott/tiger@//myhost.example.com/orcl` |
| TNS alias                   | `/@MY_TNS_ALIAS`                        |
| Wallet (mTLS)               | `/@mydb_high?TNS_ADMIN=/path/to/wallet` |
| Prompt password             | `scott@localhost:1521/XEPDB1`           |

## Commands

### Connections

| Command                        | Description                                             |
| ------------------------------ | ------------------------------------------------------- |
| `:OraConnectionsList`          | List saved connections (from SQLcl connmgr) and connect |
| `:OraConnect <url>`            | Connect directly with a connection string               |
| `:OraAddConnection [name url]` | Add a new named connection to SQLcl connmgr             |

### Worksheets

| Command                         | Description                                                       |
| ------------------------------- | ----------------------------------------------------------------- |
| `:OraWorksheetNew`              | Create a new SQL worksheet buffer                                 |
| `:OraWorksheetsList`            | List all open worksheets                                          |
| `:OraWorksheetExecute`          | Execute the current worksheet and show results in a split         |
| `:OraWorksheetFormat`           | Format the current worksheet SQL using SQLcl's built-in formatter |
| `:OraWorksheetChangeConnection` | Change the connection for the current worksheet                   |

### Quick Action

| Command           | Description                                    |
| ----------------- | ---------------------------------------------- |
| `:OraQuickAction` | Find schema objects by pattern and act on them |

### Explorer

| Command        | Description                                          |
| -------------- | ---------------------------------------------------- |
| `:OraExplorer` | Open the schema explorer sidebar (requires neo-tree) |

## Schema Explorer

The schema explorer (`:OraExplorer`) provides a tree sidebar for browsing Oracle schema objects. It requires [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) and must be registered as a neo-tree source (see Installation above).

### Explorer keymaps

These are the default keymaps. Remap them via `explorer_mappings` in `setup()`.

| Key    | Action                                                                     |
| ------ | -------------------------------------------------------------------------- |
| `<CR>` | Toggle node: connect, expand/collapse, or open source                      |
| `l`    | Expand node                                                                |
| `h`    | Collapse node (or jump to parent)                                          |
| `o`    | Quick open (see below)                                                     |
| `O`    | Quick open alt (see below)                                                 |
| `a`    | Show all actions (see below)                                               |
| `r`    | Refresh: re-fetch children on the current node, or refresh connection list |
| `A`    | Add a new named connection                                                 |

### Quick open with `o` / `O`

| Node type             | `o` (primary)      | `O` (secondary)      |
| --------------------- | ------------------ | -------------------- |
| Table                 | Show DDL           | Show data            |
| View                  | Show DDL           | Show data            |
| Materialized View     | Show DDL           | Show data            |
| Materialized View Log | Show DDL           | —                    |
| Index                 | Show DDL           | —                    |
| Synonym               | Show DDL           | —                    |
| Sequence              | Show DDL           | —                    |
| Trigger               | Show source        | —                    |
| Type                  | Show specification | Show body / Add body |
| Function              | Show body          | —                    |
| Procedure             | Show body          | —                    |
| Package               | Show specification | Show body / Add body |
| ORDS Module           | Define module      | Full export          |
| ORDS Template         | Define template    | —                    |
| ORDS Handler          | Define handler     | Show source          |
| ORDS Parameter        | Define parameter   | —                    |

### All actions with `a`

| Node type             | Actions                                                                   |
| --------------------- | ------------------------------------------------------------------------- |
| Connection            | Connect (if disconnected), Disconnect (if connected), Show conn. string   |
| Package               | Show specification, Show body / Add body, Drop package, Drop package body |
| Table                 | Show DDL, Show data, Drop table                                           |
| View                  | Show DDL, Show data, Drop view                                            |
| Materialized View     | Show DDL, Show data, Drop materialized view                               |
| Materialized View Log | Show DDL, Drop materialized view log                                      |
| Index                 | Show DDL, Drop index                                                      |
| Synonym               | Show DDL, Drop synonym                                                    |
| Sequence              | Show DDL, Drop sequence                                                   |
| Trigger               | Show DDL, Drop trigger                                                    |
| Type                  | Show specification, Show body / Add body, Drop type, Drop type body       |
| Function              | Show body, Drop function                                                  |
| Procedure             | Show body, Drop procedure                                                 |

Source code is opened in a new worksheet with the connection pre-set and the filetype set to `plsql`. The winbar shows the schema name, object name, and object type (e.g. `HR.MY_PKG (Package Body)`).

### Supported object types

| Object type                | Features                                                                                               |
| -------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Tables**                 | Columns (with data type), indexes, constraints, table comment, column comments                         |
| **Views**                  | Columns (with data type), column comments, DDL, data                                                   |
| **Materialized Views**     | Columns (with data type), column comments, DDL, data                                                   |
| **Materialized View Logs** | Master table name, DDL                                                                                 |
| **Indexes**                | Table name, uniqueness, DDL                                                                            |
| **Synonyms**               | Target display (owner.name@dblink), DDL                                                                |
| **Sequences**              | Last number, increment step, DDL                                                                       |
| **Triggers**               | Table name, trigger type, source, DDL                                                                  |
| **Types**                  | Typecode (OBJECT/COLLECTION), specification source, body source (if exists), methods with return types |
| **Functions**              | Parameters (with data type), return type, body source                                                  |
| **Procedures**             | Parameters (with data type), body source                                                               |
| **Packages**               | Specification source, body source (shown only if exists), subprograms with parameters and return types |

### Tree structure

```
CONNECTIONS
├──  dev
│   ├── 󰆼 local-free
│   │   ├── 󰉋 Tables (3)
│   │   │   ├── 󰓫 EMPLOYEES  Employee records
│   │   │   │   ├── 󰠵 EMPLOYEE_ID  NUMBER
│   │   │   │   ├── 󰠵 FIRST_NAME   VARCHAR2  First name of the employee
│   │   │   │   ├── 󰌹 EMP_NAME_IDX
│   │   │   │   └── 󰌆 EMP_PK
│   │   │   └── ...
│   │   ├── 󰉋 Materialized Views (1)
│   │   │   └── 󰡠 EMP_SUMMARY
│   │   ├── 󰉋 Materialized View Logs (1)
│   │   │   └── 󰩼 MLOG$_EMPLOYEES  EMPLOYEES
│   │   ├── 󰉋 Triggers (2)
│   │   │   ├── 󱐋 AUDIT_TRG  EMPLOYEES
│   │   │   └── 󱐋 LOG_TRG    ORDERS
│   │   ├── 󰉋 Types (1)
│   │   │   └── 󰕳 ADDRESS_T  OBJECT
│   │   ├── 󰉋 Functions (2)
│   │   │   ├── 󰊕 GET_SALARY  NUMBER
│   │   │   │   └── 󰆧 P_EMP_ID  NUMBER
│   │   │   └── ...
│   │   └── 󰉋 Packages (1)
│   │       └── 󰏗 HR_PKG
│   │           └── 󰊕 GET_EMPLOYEE  VARCHAR2
│   └── 󰆼 local-xe
└──  prod
    └── 󰆼 main-db
```

Connections organized in SQLcl connmgr folders are shown in a hierarchy. Connections without folders appear at the root level as before. The worksheet picker (`:OraWorksheetNew`) remains flat — no folders.

## Connection picker keymaps

| Key           | Action                                   |
| ------------- | ---------------------------------------- |
| `j` / `↓`     | Move cursor down                         |
| `k` / `↑`     | Move cursor up                           |
| `<CR>`        | Connect to selected entry                |
| `s`           | Connect with a one-off connection string |
| `a`           | Add a new named connection to connmgr    |
| `q` / `<Esc>` | Close picker                             |

## Lua API

```lua
-- List saved connections and connect
require("ora").list()

-- Connect directly with a connection string
require("ora").connect("scott/tiger@localhost:1521/XEPDB1")

-- Add a named connection to connmgr
require("ora").add_connection("dev", "system/oracle@localhost:1521/FREEPDB1")

-- Create a new SQL worksheet
require("ora").new_worksheet()

-- List open worksheets
require("ora").list_worksheets()

-- Execute the current worksheet
require("ora").execute_worksheet()

-- Format the current worksheet
require("ora").format_worksheet()

-- Change the worksheet connection
require("ora").change_worksheet_connection()

-- Find schema objects by pattern and act on them
require("ora").quick_action()

-- Open the schema explorer
require("ora").explorer()
```

## Local development

Clone the repo anywhere and point your plugin manager at the local path instead of GitHub.

### lazy.nvim

```lua
{
  dir = "/path/to/nvim-ora-dev",
  dependencies = { "nvim-neo-tree/neo-tree.nvim" },
  config = function()
    require("ora").setup({
      sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
    })
  end,
}
```

### Manual (no plugin manager)

Add the directory to `runtimepath` in your `init.lua`:

```lua
vim.opt.runtimepath:prepend("/path/to/nvim-ora-dev")
require("ora").setup({ ... })
```

### Interactive testing

`dev/init.lua` loads the plugin with a pre-configured setup:

```bash
make dev
# or directly:
nvim -u dev/init.lua
```

Then run `:OraExplorer` to open the schema explorer, `:OraConnectionsList` to open the connection picker, or `:OraWorksheetNew` to open a SQL worksheet.

### Running automated tests

Tests require [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) and
[nui.nvim](https://github.com/MunifTanjim/nui.nvim) to be installed in your Neovim
environment (e.g. via lazy.nvim). Then from the repo root:

```bash
make test                                        # all specs
make test-file FILE=spec/ora/config_spec.lua     # single file
```

## How it works

### Connections

When you select a connection, nvim-ora opens a `:terminal` split running:

```
sqlcl <url>
```

SQLcl handles all authentication, including password prompts and wallet-based mTLS connections. The terminal buffer is named `ora://<connection-name>` for easy identification.

If you select the same connection a second time, nvim-ora jumps to the existing terminal instead of opening a new one.

### Worksheets

`:OraWorksheetNew` opens a new buffer with `plsql` filetype. When you run `:OraWorksheetExecute`, nvim-ora:

1. Prompts you to pick a connection (if the worksheet has none yet).
2. Runs the SQL via SQLcl and captures the output as JSON.
3. Formats the result as an ASCII table in a `belowright` split buffer.

The winbar displays the worksheet name on the left and the connection name on the right.

### Schema Explorer

`:OraExplorer` opens a neo-tree sidebar that lists all connections from the SQLcl connection manager. Expanding a connection fetches schema metadata asynchronously from the Oracle data dictionary (`user_tables`, `user_tab_columns`, `user_objects`, `user_source`, etc.). Loading indicators are shown while queries run.

Opening objects (DDL, source code, data) creates worksheets with the connection pre-set, so you can immediately execute or edit them.
