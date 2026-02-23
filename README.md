# nvim-ora

A Neovim plugin providing a UI on top of [SQLcl](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/) for working with Oracle databases.

## Requirements

- Neovim ≥ 0.9
- [SQLcl](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/) installed and accessible

## Installation

### lazy.nvim

```lua
{
  "yourname/nvim-ora",
  config = function()
    require("ora").setup({
      sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
      connections = {
        { name = "local-xe", url = "scott/tiger@localhost:1521/XEPDB1" },
        { name = "staging",  url = "app/pass@staging:1521/STGDB" },
      },
    })
  end,
}
```

### packer.nvim

```lua
use {
  "yourname/nvim-ora",
  config = function()
    require("ora").setup({ ... })
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

  -- Named connections shown in the picker.
  connections = {
    {
      name = "local-xe",
      url  = "user/password@host:port/service_name",
    },
    -- TNS alias (no password stored – sqlcl will prompt):
    {
      name = "prod-tns",
      url  = "/@prod_tns_alias",
    },
  },

  -- Picker window dimensions (optional).
  win_width  = 60,
  win_height = 20,
})
```

### Connection URL formats

nvim-ora passes the URL directly to `sqlcl`, so any format sqlcl accepts works:

| Format | Example |
|--------|---------|
| user/pass@host:port/service | `scott/tiger@localhost:1521/XEPDB1` |
| EZConnect | `scott/tiger@//myhost.example.com/orcl` |
| TNS alias | `/@MY_TNS_ALIAS` |
| Wallet (mTLS) | `/@mydb_high?TNS_ADMIN=/path/to/wallet` |
| Prompt password | `scott@localhost:1521/XEPDB1` |

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:OraConnectionsList` | List saved connections (from SQLcl connmgr) and connect |
| `:OraConnect <url>` | Connect directly with a connection string |
| `:OraAddConnection [name url]` | Add a new named connection to SQLcl connmgr |

### Picker keymaps

| Key | Action |
|-----|--------|
| `j` / `↓` | Move cursor down |
| `k` / `↑` | Move cursor up |
| `<CR>` | Connect to selected entry |
| `s` | Connect with a connection string (one-off) |
| `a` | Add a new named connection to connmgr |
| `q` / `<Esc>` | Close picker |

### Lua API

```lua
-- List saved connections and connect
require("ora").list()

-- Connect directly with a connection string
require("ora").connect("scott/tiger@localhost:1521/XEPDB1")

-- Add a named connection to connmgr
require("ora").add_connection("dev", "system/oracle@localhost:1521/FREEPDB1")
```

## Local development

Clone the repo anywhere and point your plugin manager at the local path instead of GitHub.

### lazy.nvim

```lua
{
  dir = "/path/to/nvim-ora-dev",
  config = function()
    require("ora").setup({
      sqlcl_path = "/opt/oracle/sqlcl/bin/sql",
          })
  end,
}
```

### packer.nvim

```lua
use {
  "/path/to/nvim-ora-dev",
  config = function()
    require("ora").setup({ ... })
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

`dev/init.lua` loads the plugin with a pre-configured connection to a local
[Oracle Database Free](https://www.oracle.com/database/free/) instance
(`system/oracle@localhost:1521/FREEPDB1`):

```bash
make dev
# or directly:
nvim -u dev/init.lua
```

Then run `:OraConnectionsList` to open the connection picker.

### Running automated tests

Tests require [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) to be installed
in your Neovim environment (e.g. via lazy.nvim). Then from the repo root:

```bash
make test                                        # all specs
make test-file FILE=spec/ora/config_spec.lua     # single file
```

## How it works

When you select a connection, nvim-ora opens a `:terminal` split running:

```
sqlcl <url>
```

SQLcl handles all authentication, including password prompts and wallet-based mTLS connections. The terminal buffer is named `ora://<connection-name>` for easy identification.

If you select the same connection a second time, nvim-ora jumps to the existing terminal instead of opening a new one.
