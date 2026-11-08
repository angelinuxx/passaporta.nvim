# passaporta.nvim

Upload, download, sync and diff local files and directories against remote
servers, over SSH (rsync) or SFTP (lftp), straight from Neovim.

*Passaporta* is the Italian name of the Portkey from Harry Potter: an ordinary
object that takes you to a predetermined destination. The same file can be sent
to different places depending on which remote you pick.

Inspired by [transfer.nvim](https://github.com/coffebar/transfer.nvim): same
command-driven workflow and same per-project `.nvim/deployment.lua`, plus
several remotes mapping the same path (with a picker) and an SFTP backend with
password support.

---

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "angelinuxx/passaporta.nvim",
  cmd = "Passaporta",
  -- Optional: these are the default options, define only the ones you want to change
  opts = {
    config_file = ".nvim/deployment.lua",
    excludes = { ".git", ".nvim", ".idea", ".DS_Store", "*.pyc" },
    rsync = {
      upload_params = { "-rlzi", "--checksum" },
      download_params = { "-rlzi", "--checksum" },
    },
    lftp = {
      settings = {}, -- extra lftp `set` options, e.g. { ["net:timeout"] = 60 }
      mirror_params = { "--no-perms" },
      parallel = 4, -- files transferred in parallel by directory operations (1 disables)
    },
    timeout_ms = 120000, -- total timeout for file operations
    idle_timeout_ms = 60000, -- directory operations: killed after this long without output
    close_diff_mapping = "<leader>b", -- closes a file diff
    notify = nil, -- vim.notify-compatible function
  },
}
```

If you load the plugin only through `cmd`, the Lua API and the keymaps below
need a `keys` entry (or no lazy loading) to be available at startup.

### Requirements

- Neovim >= 0.10
- ssh remotes: `rsync` (>= 3.2.3, for `--mkpath`) and `ssh` locally, and `rsync` >= 3.2.3 on the server too.
- sftp remotes: [`lftp`](https://lftp.yar.ru/) (>= 4.9 recommended) and `ssh` locally (lftp connects through it). Nothing is needed on the server but an SFTP subsystem.

Run `:checkhealth passaporta` to verify tools, config and passwords.

---

## Configuration of the project

Each project has a `.nvim/deployment.lua` (relative to the directory Neovim was
started in). Create it from a template with `:Passaporta init`. It returns a
table of remotes indexed by name:

```lua
return {
  staging = {
    host = "myhost", -- ssh alias from ~/.ssh/config, or hostname
    username = "web", -- optional
    port = 22, -- optional
    protocol = "ssh", -- "ssh" (default) | "sftp"
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/staging" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
  },
  production = {
    host = "myhost",
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/production" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
  },
  shared_hosting = {
    host = "ftp.example.com",
    username = "u12345",
    protocol = "sftp",
    password = true, -- true | "string" | function(): string
    mappings = {
      { ["local"] = "src/wp-content/themes/mytheme", ["remote"] = "/public_html/wp-content/themes/mytheme" },
      { ["local"] = "wp-config.php", ["remote"] = "/public_html/wp-config.php" },
    },
  },
}
```

| field | meaning |
|---|---|
| `host` | ssh alias or hostname (required) |
| `username` | optional |
| `port` | optional positive integer |
| `protocol` | `"ssh"` (default, rsync) or `"sftp"` (lftp) |
| `password` | sftp only, see [Passwords](#passwords) |
| `mappings` | list of `{ ["local"] = ..., ["remote"] = ... }`. `local` is relative to the project root (`.`, `""` and `/` mean the root); `remote` is absolute or relative to the remote home. A mapping applies to every path below its `local`. |
| `excludedPaths` | local paths relative to the project root, or glob patterns |

Remotes are always listed in sorted-name order.

Glob rules in `excludedPaths` (`*.pyc`, `**/*.http`) also exclude **single
files**, not only directory operations (rsync semantics: a pattern without `/`
matches any path component, `**` crosses directories, a trailing `/` matches
directories only).

### Default excludes

`excludes` (default `.git`, `.nvim`, `.idea`, `.DS_Store`, `*.pyc`) applies to
**every directory operation on both backends**, before the remote's
`excludedPaths`. This keeps `.git` and `.nvim/deployment.lua` (which may hold a
password) from being mirrored to a server.

### Deletion flags

`--delete` is added by the plugin only for `syncup`, `syncdown` and the
directory `diff`. Deletion flags in `rsync.upload_params`, `rsync.download_params`
and `lftp.mirror_params` are dropped, so you cannot turn a merge into a sync
through them.

---

## Commands

All commands take an optional path; the default is the current buffer's file. A
directory triggers the directory variant.

| command | file | directory |
|---|---|---|
| `:Passaporta upload [path]` | upload | merge up: copies new and changed files, deletes nothing |
| `:Passaporta download [path]` | download (reloads the buffer) | merge down, deletes nothing |
| `:Passaporta syncup [path]` | same as upload | mirror up, **deletes remote extras** |
| `:Passaporta syncdown [path]` | same as download | mirror down, **deletes local extras** |
| `:Passaporta diff [path]` | `diffsplit` against the remote file | quickfix list of what a `syncup` would do: `[A]` new, `[M]` modified, `[D]` deleted |
| `:Passaporta remote [name\|clear]` | pick / set / clear the active remote | |
| `:Passaporta repeat` | re-run the last upload/download/syncup/syncdown with the same absolute path and bang | |
| `:Passaporta init` | create `.nvim/deployment.lua` from a template and open it | |
| `:Passaporta forget` | drop the cached passwords of this project | |

*Merge* (`upload`, `download`) only adds and updates. *Sync* (`syncup`,
`syncdown`) makes the destination identical to the source, deleting extras.

### Choosing the remote

Candidates are the remotes with a mapping covering the path and no
`excludedPaths` rule matching it.

- no candidate: an error says why
- one candidate: used directly
- several: the **active remote** is used if it is among them, otherwise a
  picker (`vim.ui.select`) opens and your choice becomes the active remote

The active remote is kept in memory per project root. `:Passaporta remote` picks
among all remotes, `:Passaporta remote <name>` sets it directly and
`:Passaporta remote clear` unsets it.

With a bang (`:Passaporta! upload`) the active remote is ignored, the picker is
always shown among the candidates and the active remote is **not** changed: a
one-off push elsewhere.

### Passwords

`password` works with `protocol = "sftp"` only.

| value | behaviour |
|---|---|
| absent | lftp drives ssh, which uses keys, agent and ssh config as usual |
| `true` | prompt once per session (`inputsecret`) |
| `"string"` | used as is |
| `function` | called once per session, must return a string |

The password is cached in memory per (project, remote). It is dropped by
`:Passaporta forget` and on an authentication failure, so the next attempt asks
again. It is only ever sent on lftp's stdin (never in the argument list) and is
redacted from every output.

> A plain-text `"string"` password lives in `.nvim/deployment.lua`: keep
> `.nvim/` out of git (add it to `.gitignore`). `:checkhealth passaporta` warns
> about it.

### lftp caveats

- **Change detection** uses size and mtime, not checksums. If only content
  changed with the same size and mtime, add `--ignore-time` to
  `lftp.mirror_params`.
- **`--no-perms`** is the default mirror param, since shared hosts often reject
  chmod.
- **Parallel transfers**: directory uploads, downloads and syncs move
  `lftp.parallel` files at once (default 4), each over its own SSH connection.
  Lower it (or set 1) if your host limits concurrent sessions. A `--parallel`
  or `-P` in `lftp.mirror_params` takes precedence. Diff dry runs stay sequential.
- **Host keys** must already be in `known_hosts`: connect once interactively.
  lftp is configured to fail fast instead of asking (`net:max-retries 2`,
  `net:timeout 30`, `sftp:auto-confirm no`).
- **Exclude translation**: every pattern is passed to lftp both as `p` and
  `p/` (so directories are excluded), and `**/x` is also passed as `x` (lftp's
  `**/` misses top-level files). Path rules containing `/`, for example
  `public/storage`, are **not anchored** in lftp, unlike rsync: they also
  exclude `app/public/storage` (over-exclusion).
- A directory diff on sftp whose remote path is the remote home itself (`.`,
  `~` or empty) cannot be parsed reliably (known limitation).

---

## Lua API

```lua
local p = require("passaporta")
p.setup(opts)
p.upload(path?, opts?)   -- also download, syncup, syncdown, diff
p.set_remote(name)
p.pick_remote()
p.clear_remote()
p.active_remote()        -- name or nil, for the current project
p.repeat_last()
p.forget_passwords()
```

`opts.remote = "name"` bypasses the picker and the active remote for that call
(the remote must cover the path); `opts.force_pick = true` is the bang.

---

## Integrations

### oil.nvim

```lua
{
  "stevearc/oil.nvim",
  opts = {
    keymaps = {
      ["<leader>pu"] = { desc = "Passaporta upload", callback = function()
        require("passaporta").upload(require("oil").get_current_dir() .. require("oil").get_cursor_entry().name)
      end },
      ["<leader>pd"] = { desc = "Passaporta diff", callback = function()
        require("passaporta").diff(require("oil").get_current_dir() .. require("oil").get_cursor_entry().name)
      end },
    },
  },
}
```

### snacks.nvim explorer

```lua
{
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        explorer = {
          actions = {
            passaporta_upload = function(_, item)
              if item then require("passaporta").upload(item.file) end
            end,
          },
          win = { list = { keys = { ["<leader>pu"] = "passaporta_upload" } } },
        },
      },
    },
  },
}
```

### which-key

```lua
require("which-key").add {
  { "<leader>p", group = "Passaporta" },
  { "<leader>pu", function() require("passaporta").upload() end, desc = "Upload" },
  { "<leader>pU", function() require("passaporta").upload(nil, { force_pick = true }) end, desc = "Upload to..." },
  { "<leader>pd", function() require("passaporta").download() end, desc = "Download" },
  { "<leader>pf", function() require("passaporta").diff() end, desc = "Diff" },
  { "<leader>pr", function() require("passaporta").pick_remote() end, desc = "Pick remote" },
  { "<leader>p.", function() require("passaporta").repeat_last() end, desc = "Repeat" },
}
```

### lualine

```lua
require("lualine").setup {
  sections = {
    lualine_x = {
      { function() return " " .. require("passaporta").active_remote() end,
        cond = function() return require("passaporta").active_remote() ~= nil end },
    },
  },
}
```

---

## Migrating from transfer.nvim

The config format is the same (`host`, `username`, `mappings`, `excludedPaths`).
Differences:

- `password` needs `protocol = "sftp"`; there is no `sshpass`. A remote with
  `password` and no sftp protocol is rejected.
- `upload_on_save` is not supported and is ignored (`:checkhealth passaporta` mentions it).
- Glob rules in `excludedPaths` now also exclude single files.
- `--delete` and the default excludes are no longer in the rsync params: see
  [Default excludes](#default-excludes) and [Deletion flags](#deletion-flags).
- Several remotes can map the same path: a picker asks which one to use.

---

## Contributing

```sh
make test          # plenary specs
make integration   # end-to-end sftp test, see below
```

`make integration` runs `scripts/integration-sftp.sh`. It needs docker, lftp,
ssh and nvim. It starts an `atmoz/sftp` container (unique name, random
localhost port), uploads, diffs and syncs a temporary project with headless
Neovim, asserts the result with `docker exec`, and checks that an unknown host
key fails within 30 s. It uses a temporary `known_hosts` and removes the
container and temp files on exit.

---

## Related projects

- [transfer.nvim](https://github.com/coffebar/transfer.nvim)
- [GershM/deploy.nvim](https://github.com/GershM/deploy.nvim)
- [KoinBanks/deploy.nvim](https://github.com/KoinBanks/deploy.nvim)
- [dmbhatti/deployment.nvim](https://github.com/dmbhatti/deployment.nvim)
- [rsync.nvim](https://github.com/OscarCreator/rsync.nvim)
- [vim-arsync](https://github.com/KenN7/vim-arsync)
