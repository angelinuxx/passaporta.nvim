# passaporta.nvim — design

Date: 2026-11-07
Status: draft, awaiting approval

## Intent

passaporta.nvim is a Neovim plugin to upload, download, sync and diff local
files and directories against remote servers, over SSH (rsync/scp) or SFTP.
It is an evolution of [transfer.nvim](https://github.com/coffebar/transfer.nvim),
whose command-driven workflow and per-project `.nvim/deployment.lua` config
we like and keep. It adds what transfer.nvim lacks for the author's two real
use cases:

1. **A Laravel project with staging and production on the same server, two
   different directories.** transfer.nvim can list both deployments but
   resolves a local path to whichever deployment `pairs()` happens to return
   first, so the author had to edit the remote path by hand before each
   deploy. passaporta lets several remotes map the same local path and asks
   which one to use, with a picker, at the moment of the command.
2. **WordPress sites on shared hosting that only expose SFTP**, usually with
   username and password and no shell. transfer.nvim needs rsync on the
   remote and passes passwords through `sshpass -p` on the command line.
   passaporta adds an SFTP backend built on `lftp` and handles passwords
   without ever putting them in a process argument list.

"Passaporta" is the Italian name of the Portkey from Harry Potter: an
ordinary object that takes you to a predetermined destination. The same file
can be sent to different places depending on which remote you pick.

## Goals

- Keep transfer.nvim's mental model and its config file. An existing
  `.nvim/deployment.lua` written for transfer.nvim must work unchanged, with
  one documented exception (see *Compatibility*).
- Several remotes may cover the same local path. When more than one does,
  the user picks one; the choice becomes the *active remote* for that project
  for the rest of the Neovim session and is reused silently.
- Two backends chosen per remote: `ssh` (rsync, key-based auth via
  `~/.ssh/config`) and `sftp` (lftp, key or password).
- Directory operations come in two flavours: **merge** (`upload`,
  `download`: add new files, overwrite changed ones, never delete) and
  **sync** (`syncup`, `syncdown`: merge plus deletion of files missing on the
  source side, what transfer.nvim does today).
- File diff and directory diff work identically on both backends.
- The user always knows which remote an operation targeted: every
  notification names it.
- Passwords are obtained once per session from a prompt, a string or a Lua
  function, cached in memory, and passed to lftp through stdin only.

## Non-goals

- Plain FTP (unencrypted). Not supported, not planned.
- Windows paths. Linux and macOS only.
- Automatic bidirectional sync, file watching, or deploying to all remotes
  at once.
- Browsing or editing remote files in place (that is what netrw/oil-ssh are
  for). passaporta only moves copies.
- Persisting the active remote or cached passwords to disk.
- Upload on save. The author does not use it, and with several remotes per
  path it is the easiest way to push to the wrong one. Every transfer is an
  explicit command.
- Supporting `ssh` protocol with password auth. A host that only accepts
  passwords is declared `protocol = "sftp"`.

## Anti-goals (what would make this a failure even if it "works")

- Uploading to the wrong remote without the user noticing. Resolution must
  be deterministic, and the remote name must appear in every notification
  and in the picker.
- A password landing in `ps` output, a log, a quickfix list or a file the
  plugin writes.
- Jobs that hang Neovim or run forever. All external processes are async
  with a timeout, and lftp is configured to fail fast instead of retrying
  1000 times (its default `net:max-retries`).
- Silently deleting remote or local files in a *merge* operation.

## Constraints

- Neovim ≥ 0.10 (for `vim.system`). Author runs 0.12.
- Lua only, no plugin dependencies. `vim.ui.select` and `vim.ui.input` are
  used so any picker/UI plugin (snacks, telescope, dressing) is honoured
  automatically.
- External tools: `rsync` ≥ 3.2.3 (for `--mkpath`) and `ssh` for the ssh
  backend; `lftp` ≥ 4.9 for the sftp backend. Each is only required if a
  remote uses that backend; `:checkhealth passaporta` reports what is
  missing.
- Code, comments, docs and commit messages in English.
- Conventional Commits, stylua formatting, LuaLS annotations.

## The project config: `.nvim/deployment.lua`

Same location and shape as transfer.nvim: a table of remotes indexed by
name. New fields are marked.

```lua
return {
  staging = {
    host = "myhost",              -- ssh alias from ~/.ssh/config, or hostname
    username = "web",             -- optional
    port = 22,                    -- optional (new)
    protocol = "ssh",             -- "ssh" (default) | "sftp"   (new)
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/staging" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
  },
  production = {
    host = "myhost",
    protocol = "ssh",
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/production" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
  },
  shared_hosting = {
    host = "ftp.example.com",
    username = "u12345",
    protocol = "sftp",
    password = true,              -- true | "string" | function(): string
    mappings = {
      { ["local"] = "src/wp-content/themes/mytheme",
        ["remote"] = "/public_html/wp-content/themes/mytheme" },
      { ["local"] = "wp-config.php", ["remote"] = "/public_html/wp-config.php" },
    },
  },
}
```

Semantics kept from transfer.nvim: `local` is relative to the project root
(`vim.fn.getcwd()` / `vim.loop.cwd()`), `.`/`""`/`/` all mean the root;
`remote` is absolute or relative to the remote user's home; `excludedPaths`
are local paths relative to the project root, or glob patterns; a mapping
whose `local` is a prefix of the file path applies to it. transfer.nvim's
`resolve_spec.lua` test cases are the reference and should be ported.

One deliberate difference: in transfer.nvim, glob rules in `excludedPaths`
(`*.pyc`, `**/*.http`) only reach rsync as `--exclude` for directory
operations; a single-file `:TransferUpload api.http` goes through. In passaporta an excluded path is excluded everywhere: glob rules
are also matched against single files during candidate resolution, with
rsync's semantics (a pattern without `/` matches any path component, `**`
crosses directories, a trailing `/` matches directories only). The author's
real configs list `**/*.http` precisely so those files never leave the
machine. `resolve.lua` therefore needs a small Lua glob matcher with its own
tests.

`password` (sftp only):

| value | behaviour |
|---|---|
| absent | lftp drives ssh, which uses keys / agent / ssh config as usual |
| `true` | prompt once per session with `vim.fn.inputsecret()` |
| `"string"` | used as is (README warns to keep `.nvim/` out of git) |
| `function` | called once per session, must return a string; errors are reported and the operation aborted |

The resolved value is cached in memory keyed by (project root, remote name),
dropped on `:Passaporta forget`, and dropped automatically when lftp reports
an authentication failure so the next attempt prompts again.

### Compatibility

- A transfer.nvim config with `password` set on a remote without
  `protocol = "sftp"` is rejected with a clear notification: "password auth
  is only supported with protocol = 'sftp'; set it on remote X". This is the
  one breaking difference and the README explains it (we do not use
  `sshpass`).
- Everything else (`host`, `username`, `mappings`, `excludedPaths`) keeps
  its meaning.
- `upload_on_save` is not supported (see *Non-goals*). If present it is
  ignored and `:checkhealth passaporta` mentions it.
- Remotes are iterated in sorted-name order everywhere (candidate list,
  picker, error messages), never with raw `pairs()`.

### Plugin options (`require("passaporta").setup(opts)`)

Defaults the builder should start from; all overridable:

- `config_file = ".nvim/deployment.lua"`
- `config_template` for `:Passaporta init` (string, lines, or function).
- `excludes = { ".git", ".nvim", ".idea", ".DS_Store", "*.pyc" }`:
  backend-neutral default excludes applied to every directory operation on
  both backends (rsync `--exclude`, lftp `--exclude-glob`), before the
  remote's `excludedPaths`. transfer.nvim kept these inside the rsync params,
  which would have let `mirror -R` upload `.git` and `.nvim/deployment.lua`
  (possibly holding a password) to a shared host.
- `rsync.upload_params` and `rsync.download_params`: transfer.nvim's
  defaults **without** `--delete` and **without** the `--exclude` pairs
  (moved to `excludes`). The plugin appends `--delete` itself for
  `syncup`/`syncdown` and for the directory diff. Users cannot turn a merge
  into a sync through these params.
- `lftp.settings`: extra `set` lines prepended to every lftp script, after
  the plugin's own (`cmd:fail-exit yes`, `net:max-retries 2`,
  `net:timeout 30`, `net:reconnect-interval-base 5`, `xfer:clobber yes`,
  `sftp:auto-confirm no`).
- `lftp.mirror_params`: extra `mirror` flags (default `{"--no-perms"}`;
  shared hosts often reject chmod).
- `timeout_ms = 120000`: total timeout for single-file operations and
  file diff.
- `idle_timeout_ms = 60000`: for directory operations (merge, sync, dir
  diff) there is no total timeout, since a first sync of a WordPress theme
  over shared-hosting SFTP can take many minutes. Instead the runner kills
  the process when it has produced no stdout/stderr for this long. rsync
  (`-i`) and lftp (`mirror -v`) both print one line per file, so progress
  resets the timer. This requires the runner to stream output rather than
  capture it at exit.
- `close_diff_mapping = "<leader>b"` as in transfer.nvim (nil disables).
- `notify = vim.notify`-compatible function; title "Passaporta".

## Choosing the remote

Given a local path, **candidates** are the remotes, in sorted-name order,
that have a mapping covering the path and no `excludedPaths` rule matching
it.

- 0 candidates → error notification explaining why (not mapped / excluded by
  rule R on remote X), same as transfer.nvim.
- 1 candidate → used directly, no picker.
- ≥ 2 candidates → if the project's active remote is among them, use it.
  Otherwise open `vim.ui.select` with the candidate names (and
  `protocol host:remote_root` as hint), and the choice becomes the active
  remote for this project.

The **active remote** is in-memory state keyed by project root, so moving
between projects in one session keeps each project's choice. `:Passaporta
remote` opens the picker over *all* remotes in the config and sets it;
`:Passaporta remote <name>` sets it without a picker (for keymaps);
`:Passaporta remote clear` unsets it. The bang form of any transfer command
(`:Passaporta! upload`) ignores the active remote, forces the picker among
the candidates, and does **not** change the active remote: a one-off push
elsewhere.

`require("passaporta").active_remote()` returns the active remote name (or
nil) for the current project, for statuslines. The README shows a lualine
snippet.

## Operations

All commands take an optional path; default is the current buffer
(`expand("%:p")`). A path ending in a directory triggers the directory
variant. Every operation: resolve candidates → pick remote → obtain
password if needed → build the command → run async → notify start and
result with the remote name → post-action (reload buffers, open quickfix).

| command | file | directory (ssh: rsync) | directory (sftp: lftp) |
|---|---|---|---|
| `upload` | ssh: rsync `--mkpath`; sftp: `mkdir -p` + `put -O` | rsync, no `--delete` | `mirror -R` |
| `download` | ssh: rsync; sftp: `get -O`, then reload buffer | rsync, no `--delete` | `mirror` |
| `syncup` | same as upload | rsync `--delete` | `mirror -R --delete` |
| `syncdown` | same as download | rsync `--delete` | `mirror --delete` |
| `diff` | download to a temp file, `diffsplit` | rsync `--dry-run --delete` → quickfix | `mirror -R --delete --dry-run` → quickfix |
| `remote [name\|clear]` | pick / set / clear active remote | | |
| `repeat` | re-run the last transfer command (not `init`, `remote`, `diff`) | | |
| `init` | create config from template if missing, open it | | |
| `forget` | drop cached passwords for this project | | |

Notes:

- **File diff** never uses `scp://` + netrw (disabled in many configs,
  ssh-only). The remote file is downloaded to a temp file under
  `stdpath("cache")/passaporta/` keeping the original extension so filetype
  detection works, opened with `diffsplit` as a readonly, non-listed buffer,
  and deleted when that buffer is wiped. The close mapping behaves like
  transfer.nvim's.
- **Directory diff** simulates `syncup`, so it also lists what a sync would
  delete. Both backends' dry-run output is parsed into a normalised list of
  `{status, path}` with `status ∈ {new, modified, deleted}` and shown in the
  quickfix list as `[A] path`, `[M] path`, `[D] path` with `filename` set to
  the local path so `<CR>` opens it. The header lines show local root,
  remote (name, host, path) and the exact command, as transfer.nvim does.
  rsync: parse `--itemize-changes` codes. lftp: parse the `--dry-run` script
  lines (`get`/`put`/`mkdir`/`rm`/`rmdir`...). The builder must verify the
  exact lftp output format against lftp 4.9 and cover it with unit tests on
  captured samples.
- **Excludes** apply to every directory operation including diffs. rsync:
  `--exclude`; lftp: `--exclude-glob`. transfer.nvim's rule of rebasing
  excludes relative to the directory being transferred is kept. lftp glob
  semantics differ from rsync's (anchoring, `**`); the builder must test
  the common cases (`vendor`, `.env`, `**/*.http`, `public/storage`) and
  document any pattern that cannot be translated.
- **Merge vs sync on a single file** is identical; `syncup`/`syncdown` on a
  file behave as `upload`/`download`.
- **lftp change detection** uses size and mtime, not checksums. Documented
  in the README; `--ignore-time` can be added via `lftp.mirror_params` to
  force transfers when only content changed with the same size and mtime.
- **Host keys**: like transfer.nvim, the user must have connected once
  interactively so the host is in `known_hosts`; otherwise ssh/lftp fail
  (they must not hang; `sftp:auto-confirm no` plus BatchMode-like failure).
  Health check and error messages say so.

## Running external processes

- Everything goes through one runner module wrapping `vim.system` with
  streaming stdout/stderr callbacks (needed for the idle timeout and for
  progress), the total/idle timeout policy above, and `vim.schedule` for UI
  callbacks.
- **ssh backend** commands are argv tables; nothing sensitive is ever in
  argv.
- **sftp backend**: a single `lftp` process is started with no arguments
  that carry secrets (`lftp -f /dev/stdin` or plain `lftp` reading
  commands from stdin). The script is written to its stdin:

  ```
  set cmd:fail-exit yes
  set net:max-retries 2
  ...user settings...
  open -u "user","password" sftp://host:port
  mirror -R --no-perms --exclude-glob vendor ... "local/dir" "/remote/dir"
  bye
  ```

  Password and paths are quoted with lftp's quoting rules (double quotes,
  backslash-escape `"` and `\`). Without a password the `-u` user is passed
  with an empty password and ssh's key auth takes over. When `host` is an
  ssh alias, lftp works because its `sftp:connect-program` is `ssh -a -x`.
- Authentication failure detection: lftp stderr matching
  `Login failed|Permission denied|Authentication failed` → drop the cached
  password, tell the user, and do not retry automatically.
- Concurrent operations are allowed (separate processes). Starting the
  same operation on the same path while one is still in flight is refused
  with a notification.

## Public Lua API

`require("passaporta")` exposes: `setup(opts)`, `upload(path?, opts?)`,
`download(path?, opts?)`, `syncup`, `syncdown`, `diff`, `set_remote(name)`,
`pick_remote()`, `clear_remote()`, `active_remote()`, `repeat_last()`,
`forget_passwords()`. `opts.remote = "name"` bypasses picker and active
remote for that call; `opts.force_pick = true` is the bang. These are what
oil.nvim / snacks explorer / which-key keymaps call; the README shows
snippets for oil.nvim (the author's explorer), snacks explorer and which-key.

## Health check

`:checkhealth passaporta`: Neovim version, presence and versions of rsync,
ssh, lftp; whether the current project has a config, whether it parses,
list of remotes with protocol and whether their backend tool is available;
warn on `password` without `protocol = "sftp"`, on plain-string passwords
and on the ignored `upload_on_save` field.

## Testing

- plenary busted specs under `tests/`, named `*_spec.lua`. The author runs
  them from inside Neovim with neotest (neotest-plenary), as for
  npm-lens.nvim; a `Makefile` with `make test` and `tests/minimal_init.lua`
  also runs them headless (`nvim --headless -u tests/minimal_init.lua -c
  "PlenaryBustedDirectory tests"`) for CI and for the implementer.
- Unit tests, no network: path resolution and candidate selection (port
  transfer.nvim's `resolve_spec.lua` and add multi-remote cases), exclude
  rebasing and translation to rsync/lftp flags, command building for every
  operation × backend (assert argv tables and lftp scripts, including
  quoting of passwords with `"`, `\`, spaces and `$`), parsing of rsync
  itemize output and lftp dry-run output from captured fixtures, active
  remote state and password cache lifecycle.
- A manual integration script (documented, not in CI) that spins up a local
  sftp server in Docker (e.g. `atmoz/sftp`) to exercise the lftp backend
  end to end. Builder decides whether to also wire it to `make
  integration`.

## Documentation

- README in English: what it is, one-line credit "inspired by
  transfer.nvim", install with lazy.nvim, config reference, commands table,
  password handling and its security notes, lftp caveats (size/mtime,
  host keys, `--no-perms`), migration note for transfer.nvim users, oil /
  snacks / which-key / lualine snippets, related projects (transfer.nvim,
  GershM/deploy.nvim, KoinBanks/deploy.nvim, dmbhatti/deployment.nvim,
  rsync.nvim, vim-arsync).
- Vimdoc `doc/passaporta.txt` mirroring the README.

## Conventions (from the author's npm-lens.nvim)

The author's existing plugin, `npm-lens.nvim`, sets the house style; follow
it, with the adjustments noted.

- **`plugin/passaporta.lua` loader**: user command and autocmds are created
  there with lazy `require("passaporta...")` inside the callbacks, so the
  plugin costs nothing until first use and works with lazy.nvim's `cmd =`.
- **LuaLS annotations with a namespace**: `---@class passaporta.Options`,
  `passaporta.Remote`, `passaporta.Mapping`, `passaporta.Candidate`, ...
  declared at the top of the module that owns them; every function has
  `---@param`/`---@return`.
- **`defaults` table + `setup(opts)`** merging with
  `vim.tbl_deep_extend("force", defaults, opts or {})`.
- **Plugin state** in a module-local table with a `passaporta.State` class,
  never in globals.
- **`vim.system`** for processes, `vim.uv` (not the deprecated `vim.loop`).
- **stylua** with the same `stylua.toml` (2 spaces, width 120,
  `call_parentheses = "None"`); `.luarc.json` with busted globals plus
  `runtime.version = "LuaJIT"` and `$VIMRUNTIME` in `workspace.library`.
- **Conventional Commits**, `!` for breaking changes.
- **Adjustments**: several modules instead of one file; tests call the
  public functions of the pure modules (`resolve`, `backends.*`, `secrets`)
  rather than `M._private` re-exports; a `Makefile` and `minimal_init.lua`
  so tests also run headless.

## Suggested module layout (builder may reshape)

```
lua/passaporta/init.lua        setup + public API
lua/passaporta/config.lua      defaults and setup merging
lua/passaporta/deployment.lua  load + validate .nvim/deployment.lua
lua/passaporta/resolve.lua     local path → candidates (remote, remote path, excludes)
lua/passaporta/state.lua       active remote per project, last command
lua/passaporta/secrets.lua     password resolution + cache
lua/passaporta/backends/ssh.lua   build rsync argv, parse itemize output
lua/passaporta/backends/sftp.lua  build lftp scripts, parse dry-run output
lua/passaporta/runner.lua      vim.system wrapper
lua/passaporta/ops.lua         upload/download/sync/diff orchestration
lua/passaporta/diff.lua        file diffsplit + quickfix rendering
lua/passaporta/commands.lua    :Passaporta subcommands, completion, init/repeat/forget
plugin/passaporta.lua          loader: user command + autocmds with lazy requires
lua/passaporta/health.lua
```

## Decisions made during brainstorming (and by whom)

- Author: multiple remotes with picker at command time; sftp support; lftp
  as sftp backend; passwords cached per session; plain FTP excluded; no
  upload on save;
  "merge" for upload/download and separate sync commands with delete;
  `diffsplit` is fine (netrw disabled in the author's setup); name
  passaporta.nvim.
- Claude's calls, open to change: keep transfer.nvim's config file and
  shape; ssh backend is key-only and password hosts go through sftp; single
  `:Passaporta` command with subcommands and bang; active remote is
  per-project, session-only; file diff via temp file on both backends;
  `--delete` owned by the plugin, not by user params; rsync for single files
  too (`--mkpath`) instead of scp; `inputsecret` for prompts; auth failure
  drops the cached password; plenary busted for tests; `--no-perms`
  default for lftp mirror; backend-neutral `excludes` option; idle timeout
  instead of total timeout for directory operations; glob excludes also
  apply to single files.

## Verified against lftp 4.9.2 (by the design reviewer)

- `mirror --dry-run` output distinguishes new (`get`/`put`), modified
  (`get -e`/`put -e`), `mkdir`, `rm`, `rm -r`, so the three quickfix states
  are derivable.
- `--exclude-glob vendor` does **not** exclude the directory; `vendor/` does,
  and it matches at any depth (unanchored, like rsync). `*.http` and
  `**/*.http` behave as expected. The exclude translation layer must append
  `/` for path rules that are directories.

## Left to the builder

- Exact lftp dry-run parsing and glob translation (with tests).
- Quickfix formatting details and header lines.
- Temp-file lifecycle for file diff.
- Whether to queue concurrent operations beyond refusing duplicates.
- Module boundaries beyond the suggested layout.
