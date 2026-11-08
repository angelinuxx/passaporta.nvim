# passaporta.nvim v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Neovim plugin that uploads, downloads, syncs and diffs local paths against several named remotes (ssh via rsync, sftp via lftp), picking the remote at command time.

**Architecture:** Pure Lua modules with no plugin dependencies. A `plugin/` loader registers one `:Passaporta` command with lazy requires. `ops.lua` orchestrates: load `.nvim/deployment.lua` → resolve candidates for the path → choose remote (active remote / picker) → obtain password → ask the backend (`backends/ssh.lua` or `backends/sftp.lua`) for a `Job` (argv + stdin) → run it through `runner.lua` (`vim.system`, streaming, idle timeout) → notify / open diff. Every module that decides something is pure and unit-tested; UI is confined to `ops`, `diff`, `commands`.

**Tech Stack:** Lua (LuaJIT, Neovim ≥ 0.10), `vim.system`, `vim.uv`, `vim.ui.select`, `vim.fn.inputsecret`; external `rsync` ≥ 3.2.3, `ssh`, `lftp` ≥ 4.9; plenary busted for tests (run via neotest-plenary or `make test`); stylua.

**Spec:** `docs/superpowers/specs/2026-11-07-passaporta-design.md`

## Global Constraints

- Neovim ≥ 0.10; use `vim.uv`, never `vim.loop`; `vim.system` for processes.
- No plugin dependencies at runtime. Tests depend on plenary only.
- Code, comments, docs, commit messages in English. Conventional Commits.
- Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (project-specific exception requested by the author). Commits happen only after the author's explicit OK.
- stylua: 2 spaces, column width 120, `call_parentheses = "None"`. LuaLS annotations on every class and function, namespace `passaporta.`.
- Remotes are always iterated in sorted-name order. Never `pairs()` over remotes in user-facing logic.
- A password must never appear in argv, logs, notifications, quickfix or files. It travels only inside lftp's stdin script.
- `--delete` is added by the plugin only for `syncup`, `syncdown` and the directory diff. Never by user params.
- Default excludes `.git`, `.nvim`, `.idea`, `.DS_Store`, `*.pyc` apply to every directory operation on both backends.
- Timeouts: `timeout_ms = 120000` total for file operations; `idle_timeout_ms = 60000` idle for directory operations (no total).
- Config file: `.nvim/deployment.lua` relative to the project root = `vim.uv.cwd()`.
- Every user-facing notification has `title = "Passaporta"` and starts with `[<remote name>] ` when a remote is involved.
- Tests: `tests/<module>_spec.lua`, plenary busted. Run all: `make test`. Run one: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/<name>_spec.lua"`.

## Review Focus

Inputs the spec implies but a casual implementation breaks. Each one has a pinned test in the task that owns it.

1. **File and directory names with spaces, quotes or backslashes** must survive the lftp script (quoting) and rsync argv. A wrong quote uploads to the wrong path or fails obscurely. (Task 9, Task 8)
2. **Passwords with `"`, `\`, spaces or `$`** must reach lftp intact and never leak into an error notification. (Task 9, Task 11)
3. **`remote` paths relative to the remote home** (no leading `/`), as transfer.nvim allows, must not gain a leading slash when joined. (Task 3)
4. **A local path outside the project root** (e.g. `:Passaporta upload /etc/hosts`) must be refused with a clear message, not mapped to `""`. (Task 3, Task 5)
5. **rsync itemize lines and lftp dry-run lines whose paths contain spaces** must parse into the right single entry. (Task 8, Task 9)

Manual check only (needs a network): an unknown host key must make ssh/lftp fail fast, not hang (spec: `sftp:auto-confirm no`). Covered by the integration script in Task 15.

---

## File structure

```
plugin/passaporta.lua                 loader: :Passaporta command (lazy requires)
lua/passaporta/init.lua               setup() + public API (thin, delegates to ops/state/secrets)
lua/passaporta/config.lua             defaults, options, setup merging
lua/passaporta/glob.lua               rsync-style glob → matcher
lua/passaporta/paths.lua              local path normalisation, prefix matching, remote path join
lua/passaporta/deployment.lua         load + validate .nvim/deployment.lua → passaporta.Remote[]
lua/passaporta/resolve.lua            candidates for a path, excludes for a directory
lua/passaporta/state.lua              active remote and last command, per project root
lua/passaporta/secrets.lua            password resolution + session cache
lua/passaporta/backends/ssh.lua       rsync Jobs + itemize parsing
lua/passaporta/backends/sftp.lua      lftp script Jobs + quoting + dry-run parsing + auth failure
lua/passaporta/runner.lua             vim.system wrapper: streaming, total/idle timeout
lua/passaporta/notify.lua             vim.notify wrapper with title, remote prefix, redaction
lua/passaporta/diff.lua               temp file + diffsplit, quickfix rendering
lua/passaporta/ops.lua                orchestration of transfer/diff
lua/passaporta/commands.lua           :Passaporta argument parsing, completion, init/repeat/forget
lua/passaporta/health.lua             :checkhealth passaporta
tests/minimal_init.lua, Makefile, tests/*_spec.lua, tests/fixtures/*
README.md, doc/passaporta.txt, scripts/integration-sftp.sh
```

Shared types (declared in the module that owns them, referenced everywhere):

```lua
---@class passaporta.Mapping            (deployment.lua)
---@field ["local"] string   project-relative, no leading "./" or "/", no trailing "/", "" = root
---@field remote string      as configured, trailing "/" stripped unless it is exactly "/"

---@class passaporta.Remote             (deployment.lua)
---@field name string
---@field host string
---@field username? string
---@field port? integer
---@field protocol "ssh"|"sftp"
---@field password? true|string|fun(): string
---@field mappings passaporta.Mapping[]
---@field excludedPaths string[]

---@class passaporta.Candidate          (resolve.lua)
---@field remote passaporta.Remote
---@field mapping passaporta.Mapping
---@field remote_path string   full remote path of the local path (trailing "/" mirrors the input)

---@class passaporta.TransferArgs       (backends)
---@field local_path string    absolute; directories without trailing "/"
---@field remote_path string
---@field direction "up"|"down"
---@field delete boolean       directory ops only
---@field dry_run boolean      directory ops only
---@field excludes string[]    patterns relative to the directory being transferred
---@field password? string     sftp only

---@class passaporta.Job                (backends)
---@field cmd string[]
---@field stdin? string
---@field secrets string[]     strings to redact from any output (password)

---@class passaporta.DiffEntry          (backends)
---@field status "new"|"modified"|"deleted"
---@field path string          relative to the transferred directory; directories end with "/"

---@class passaporta.RunResult          (runner.lua)
---@field code integer
---@field stdout string[]
---@field stderr string[]
---@field timed_out boolean
```

---

### Task 1: Project skeleton, test runner, config module

**Files:**
- Create: `Makefile`, `tests/minimal_init.lua`, `stylua.toml`, `.luarc.json`, `.gitignore`, `LICENSE` (MIT, copy from `../npm-lens.nvim/LICENSE` with year 2026)
- Create: `lua/passaporta/config.lua`
- Test: `tests/config_spec.lua`

**Interfaces:**
- Produces: `config.defaults` (table), `config.options` (table, starts as a deep copy of defaults), `config.setup(opts?: table)` merging with `vim.tbl_deep_extend("force", defaults, opts or {})`.
- Produces `passaporta.Options` class with fields and defaults exactly:
  `config_file = ".nvim/deployment.lua"`, `config_template` (string: the spec's two-remote example trimmed to one `ssh` remote and one commented `sftp` remote), `excludes = { ".git", ".nvim", ".idea", ".DS_Store", "*.pyc" }`, `rsync = { upload_params = { "-rlzi", "--checksum" }, download_params = { "-rlzi", "--checksum" } }`, `lftp = { settings = {}, mirror_params = { "--no-perms" } }`, `timeout_ms = 120000`, `idle_timeout_ms = 60000`, `close_diff_mapping = "<leader>b"`, `notify = nil`.

- [ ] **Step 1: Write `tests/minimal_init.lua` and `Makefile`**

`minimal_init.lua`: prepend the repo root and `PLENARY_DIR` (env, default `~/.local/share/nvim/lazy/plenary.nvim`) to `runtimepath`, `vim.cmd("runtime plugin/plenary.vim")`, `vim.o.swapfile = false`. `Makefile` target `test`: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"`. Copy `stylua.toml` from npm-lens; `.luarc.json` with `diagnostics.globals = ["describe","it","before_each","after_each","assert"]`, `runtime.version = "LuaJIT"`, `workspace.library = ["$VIMRUNTIME", "${3rd}/luv/library"]`.

- [ ] **Step 2: Write the failing test `tests/config_spec.lua`**

```lua
local config = require "passaporta.config"
describe("config", function()
  it("exposes defaults", function()
    assert.are.same({ ".git", ".nvim", ".idea", ".DS_Store", "*.pyc" }, config.defaults.excludes)
    assert.are.equal(120000, config.defaults.timeout_ms)
    assert.are.equal(60000, config.defaults.idle_timeout_ms)
    assert.are.same({ "--no-perms" }, config.defaults.lftp.mirror_params)
  end)
  it("deep-merges user options without touching defaults", function()
    config.setup { rsync = { upload_params = { "-rz" } }, timeout_ms = 5 }
    assert.are.same({ "-rz" }, config.options.rsync.upload_params)
    assert.are.same({ "-rlzi", "--checksum" }, config.options.rsync.download_params)
    assert.are.equal(5, config.options.timeout_ms)
    assert.are.equal(120000, config.defaults.timeout_ms)
  end)
end)
```

- [ ] **Step 3: Run it, expect FAIL** (`module 'passaporta.config' not found`)
- [ ] **Step 4: Implement `lua/passaporta/config.lua`** with the `passaporta.Options` class, `M.defaults`, `M.options = vim.deepcopy(M.defaults)`, `M.setup(opts)`.
- [ ] **Step 5: Run `make test`, expect PASS**
- [ ] **Step 6: Commit** `chore: scaffold project with test runner and config module`

---

### Task 2: Glob matcher

**Files:**
- Create: `lua/passaporta/glob.lua`
- Test: `tests/glob_spec.lua`

**Interfaces:**
- Produces: `glob.is_glob(rule: string): boolean` (true if it contains `*`, `?` or `[`).
- Produces: `glob.matches(path: string, rule: string): boolean` with rsync semantics: `*` matches within one component, `**` crosses `/`, `?` one char; a rule without `/` matches any single path component (basename or any ancestor); a rule with `/` is anchored at the root; a trailing `/` on the rule matches only when `path` ends with `/` (directory).

- [ ] **Step 1: Write failing tests**

```lua
local glob = require "passaporta.glob"
describe("glob.matches", function()
  it("matches basename patterns at any depth", function()
    assert.is_true(glob.matches("a/b/c.pyc", "*.pyc"))
    assert.is_true(glob.matches("c.pyc", "*.pyc"))
    assert.is_false(glob.matches("a/b/c.py", "*.pyc"))
  end)
  it("matches ancestor components", function()
    assert.is_true(glob.matches("node_modules/x/y.js", "node_modules"))
    assert.is_true(glob.matches("src/.git/config", ".git"))
  end)
  it("anchors patterns containing a slash", function()
    assert.is_true(glob.matches("public/storage/x", "public/*"))
    assert.is_false(glob.matches("x/public/storage", "public/*"))
  end)
  it("lets ** cross directories", function()
    assert.is_true(glob.matches("a/b/c/req.http", "**/*.http"))
    assert.is_true(glob.matches("req.http", "**/*.http"))
    assert.is_false(glob.matches("a/b/c/req.http", "*/*.http"))
  end)
  it("treats a trailing slash as directory-only", function()
    assert.is_true(glob.matches("vendor/", "vendor/"))
    assert.is_false(glob.matches("vendor", "vendor/"))
  end)
  it("escapes lua magic characters", function()
    assert.is_true(glob.matches("a+b(1).txt", "a+b(1).txt"))
    assert.is_false(glob.matches("aab.txt", "a+b.txt"))
  end)
end)
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement** `to_pattern(rule): string` (private) converting to an anchored Lua pattern, then `matches` trying the whole path and, for slash-less rules, every component suffix.
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add rsync-style glob matcher`

---

### Task 3: Path helpers

**Files:**
- Create: `lua/passaporta/paths.lua`
- Test: `tests/paths_spec.lua`

**Interfaces:**
- Produces: `paths.normalize_local(abs: string, root: string): string|nil` → project-relative path, `""` for the root itself, trailing `/` preserved from input; `nil` when `abs` is not inside `root`.
- Produces: `paths.path_matches(path: string, prefix: string): boolean` → component-wise prefix (port of transfer.nvim's `path_matches`; `""` prefix matches everything).
- Produces: `paths.normalize_mapping_local(s: string|nil): string` → strips `./`, leading/trailing `/`, maps `nil`/`"."`/`"/"` to `""`.
- Produces: `paths.join_remote(mapping: passaporta.Mapping, rel: string): string` → remote path for `rel` under the mapping (port of transfer.nvim's `remote_scp_path` arithmetic): trailing `/` on `rel` is mirrored; relative remotes keep no leading `/`.

- [ ] **Step 1: Write failing tests** (port the cases of transfer.nvim `tests/plenary/resolve_spec.lua` that concern path arithmetic, plus):

```lua
it("returns nil for paths outside the root", function()
  assert.is_nil(paths.normalize_local("/etc/hosts", "/home/u/proj"))
end)
it("keeps relative remote paths relative", function()
  assert.are.equal("www/wp-config.php",
    paths.join_remote({ ["local"] = "wp-config.php", remote = "www/wp-config.php" }, "wp-config.php"))
  assert.are.equal("www/themes/x/style.css",
    paths.join_remote({ ["local"] = "src/themes/x", remote = "www/themes/x" }, "src/themes/x/style.css"))
end)
it("mirrors trailing slashes", function()
  assert.are.equal("/var/www/app/", paths.join_remote({ ["local"] = "", remote = "/var/www/app" }, ""))
  assert.are.equal("/var/www/app/src/", paths.join_remote({ ["local"] = "", remote = "/var/www/app" }, "src/"))
end)
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `lua/passaporta/paths.lua`**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add local/remote path helpers`

---

### Task 4: Deployment config loading and validation

**Files:**
- Create: `lua/passaporta/deployment.lua`
- Test: `tests/deployment_spec.lua`, fixtures `tests/fixtures/deployment/{valid,password_on_ssh,missing_mappings,transfer_compat}.lua`

**Interfaces:**
- Consumes: `paths.normalize_mapping_local`.
- Produces: `deployment.normalize(raw: table): passaporta.Remote[]|nil, errors: string[], warnings: string[]` → remotes sorted by name; `protocol` defaults to `"ssh"`; `excludedPaths` defaults to `{}`; `remote` trailing `/` stripped.
  Errors (one string each, format `"<name>: <message>"`): missing/non-string `host`; missing/empty `mappings`; `protocol` not in `{"ssh","sftp"}`; `password` present with `protocol ~= "sftp"` → `"password auth is only supported with protocol = 'sftp'"`; `password` not `true`/string/function; `port` not a positive integer. Warnings: `upload_on_save` present → `"upload_on_save is not supported and will be ignored"`.
- Produces: `deployment.load(root: string): passaporta.Remote[]|nil, err: string|nil, warnings: string[]` → reads `root .. "/" .. config.options.config_file` with `pcall(dofile)`; `err` is `"no deployment config at <path>"` when missing, the Lua error when it fails to load, or the errors joined by `"\n"`.

- [ ] **Step 1: Write failing tests** covering: sorted output; defaults applied; each error message; the warning; a transfer.nvim config (`tests/fixtures/deployment/transfer_compat.lua`, the author's Laravel one with host masked) loads with zero errors; missing file error text.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `lua/passaporta/deployment.lua`**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: load and validate deployment config`

---

### Task 5: Candidate resolution and excludes

**Files:**
- Create: `lua/passaporta/resolve.lua`
- Test: `tests/resolve_spec.lua`

**Interfaces:**
- Consumes: `glob.is_glob`, `glob.matches`, `paths.path_matches`, `paths.join_remote`.
- Produces: `resolve.candidates(remotes: passaporta.Remote[], rel: string): passaporta.Candidate[], reason: string|nil`. For each remote in order: skip if any `excludedPaths` rule matches `rel` (glob rules via `glob.matches`, others via `paths.path_matches`), remembering `reason = "excluded on <name> by rule: <rule>"`; else take the mapping with the **longest** matching `local` (`""` matches everything) and build `remote_path`. `reason` when the list is empty: the last exclusion reason, else `"'<rel>' is not mapped in deployment config"`.
- Produces: `resolve.excludes_for_dir(remote: passaporta.Remote, rel_dir: string, is_dir: fun(rel: string): boolean): string[]` → from `excludedPaths`: glob rules pass through unchanged; path rules under `rel_dir` are rebased relative to it; path rules elsewhere are dropped; rebased path rules for which `is_dir(rule)` is true get a trailing `/`.

- [ ] **Step 1: Write failing tests**

```lua
it("returns every remote covering the path, in name order", function()
  local c = resolve.candidates(remotes, "app/Http/Kernel.php")  -- staging + production both map "", shared_hosting maps a theme
  assert.are.same({ "production", "staging" }, vim.tbl_map(function(x) return x.remote.name end, c))
  assert.are.equal("/var/www/production/app/Http/Kernel.php", c[1].remote_path)
end)
it("prefers the longest mapping", ...)        -- "" and "src/wp-content/themes/x" both match → the latter
it("excludes single files by glob rules", function()
  local c, reason = resolve.candidates(remotes_with_http_glob, "tests/api.http")
  assert.are.same({}, c)
  assert.are.equal("excluded on staging by rule: **/*.http", reason)
end)
it("reports unmapped paths", ...)
it("rebases and marks directory excludes", function()
  local ex = resolve.excludes_for_dir(remote, "resources", function(p) return p == "js" end)
  -- excludedPaths = { "resources/js", "resources/mix.lock", "vendor", "**/*.http" }
  assert.are.same({ "js/", "mix.lock", "**/*.http" }, ex)
end)
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `lua/passaporta/resolve.lua`**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: resolve remote candidates for a local path`

---

### Task 6: Session state

**Files:**
- Create: `lua/passaporta/state.lua`
- Test: `tests/state_spec.lua`

**Interfaces:**
- Produces: `state.get_active(root: string): string|nil`, `state.set_active(root: string, name: string|nil)`, `state.get_last(root: string): passaporta.LastCommand|nil`, `state.set_last(root: string, cmd: passaporta.LastCommand|nil)`, `state.reset()` (tests).
- Produces: `---@class passaporta.LastCommand` with `sub: string`, `path: string`, `bang: boolean`.

- [ ] **Step 1: Write failing tests**: independent per root; `nil` clears; `reset` empties.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: keep active remote and last command per project`

---

### Task 7: Password resolution and cache

**Files:**
- Create: `lua/passaporta/secrets.lua`
- Test: `tests/secrets_spec.lua`

**Interfaces:**
- Consumes: `passaporta.Remote`.
- Produces: `secrets.get(root: string, remote: passaporta.Remote): string|nil, err: string|nil`. Synchronous. `remote.password == nil` → `nil, nil`. Cached value for `(root, remote.name)` wins. `true` → `secrets.prompt(prompt_text)` (module field defaulting to `vim.fn.inputsecret`, replaceable in tests) with prompt `"Password for <name> (<username@>host): "`; empty/cancelled → `nil, "no password entered"`. String → cached and returned. Function → `pcall`; non-string result → `nil, "password function on <name> must return a string"`; error → `nil, "password function on <name> failed: <err>"`.
- Produces: `secrets.invalidate(root, name)`, `secrets.forget(root): integer` (count dropped), `secrets.reset()`.

- [ ] **Step 1: Write failing tests**: nil password; prompt called once then cached (count calls on a stub); empty prompt error; function result cached; function error message; invalidate forces re-prompt; forget returns count.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: resolve and cache remote passwords per session`

---

### Task 8: ssh backend (rsync)

**Files:**
- Create: `lua/passaporta/backends/ssh.lua`
- Test: `tests/backend_ssh_spec.lua`, fixture `tests/fixtures/rsync_itemize.txt`

**Interfaces:**
- Consumes: `config.options.rsync`, `passaporta.Remote`, `passaporta.TransferArgs`.
- Produces: `ssh.file(remote, args): passaporta.Job` → `{ "rsync", "-z", "--mkpath", <src>, <dst> }` for `up` (`--mkpath` only for up), `{ "rsync", "-z", <src>, <dst> }` for `down`; remote spec `[username@]host:remote_path`; when `remote.port` is set, insert `"-e", "ssh -p <port>"`.
- Produces: `ssh.dir(remote, args): passaporta.Job` → `rsync` + `upload_params`/`download_params` by direction + `--delete` if `args.delete` + `--dry-run --itemize-changes --out-format=%i %n` if `args.dry_run` + `--exclude <p>` per `args.excludes` + `src/` `dst/` (both with trailing `/`).
- Produces: `ssh.parse_dry_run(lines: string[], args): passaporta.DiffEntry[]` → `*deleting   p` → deleted; code with `+++++++++` → new; other `>f`/`<f` codes → modified; codes starting with `.` → skipped; directory entries end with `/`. Path = everything after the first space following the 11-char code (names with spaces survive).
- Produces: `ssh.is_auth_failure(stderr: string): boolean` → always `false` (ssh backend is key-only).

- [ ] **Step 1: Write failing tests**: argv tables for each operation (assert full tables with `assert.are.same`); port handling; a local path with a space stays one argv element; `parse_dry_run` on the fixture (new file, modified file, deleted file, new dir, unchanged dir, name with spaces) returns the exact expected list.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add rsync backend`

---

### Task 9: sftp backend (lftp)

**Files:**
- Create: `lua/passaporta/backends/sftp.lua`
- Test: `tests/backend_sftp_spec.lua`, fixtures `tests/fixtures/lftp_dryrun_up.txt`, `tests/fixtures/lftp_dryrun_down.txt` (captured from lftp 4.9.2 with `mirror --dry-run` against a local directory tree via the `file:` protocol; include a name with a space)

**Interfaces:**
- Consumes: `config.options.lftp`.
- Produces: `sftp.quote(s: string): string` → `"` + s with `\` and `"` backslash-escaped + `"`.
- Produces: `sftp.open_line(remote, password?: string): string` → `open -u <q(user)>,<q(pass or "")> <q("sftp://host[:port]")>` when `username` is set, else `open <q(url)>`.
- Produces: `sftp.preamble(): string[]` → `set cmd:fail-exit yes`, `set net:max-retries 2`, `set net:timeout 30`, `set net:reconnect-interval-base 5`, `set xfer:clobber yes`, `set sftp:auto-confirm no`, then each `config.options.lftp.settings` entry prefixed with `set `.
- Produces: `sftp.file(remote, args): passaporta.Job` → `cmd = { "lftp" }`, `stdin` = preamble + open line + (`up`: `mkdir -pf <q(dirname(remote_path))>` and `put -O <q(dirname(remote_path))> <q(local_path)>`; `down`: `get -O <q(dirname(local_path))> <q(remote_path)>`) + `bye`, joined by `\n` with trailing `\n`; `secrets = { password }` when set.
- Produces: `sftp.dir(remote, args): passaporta.Job` → `mirror` + (`-R` if up) + (`--delete` if delete) + (`--dry-run` if dry_run) + `-v` + `mirror_params` + `--exclude-glob <q(p)>` per exclude + source and target quoted (local first for `-R`).
- Produces: `sftp.parse_dry_run(lines, args): passaporta.DiffEntry[]` → tokenise each line respecting quotes; `get`/`put` → new, with `-e` → modified, path = last token made relative to `args.local_path` (up) or `args.remote_path` (down); `mkdir` → new directory (`/` suffix); `rm` → deleted, `rm -r`/`rmdir` → deleted directory; other verbs (`chmod`, `set`, `cd`, `lcd`) skipped.
- Produces: `sftp.is_auth_failure(stderr: string): boolean` → matches `Login failed`, `Login incorrect`, `Permission denied`, `Authentication failed` (case-insensitive).

- [ ] **Step 1: Write failing tests**

```lua
it("quotes backslashes, quotes, spaces and dollars", function()
  assert.are.equal([["p\\a\"s $w d"]], sftp.quote([[p\a"s $w d]]))
end)
it("builds the open line with and without username/port/password", ...)
it("puts the password only in stdin, never in cmd", function()
  local job = sftp.file(remote, { direction = "up", local_path = "/p/a b.txt", remote_path = "/www/a b.txt", password = "s3cret" })
  assert.are.same({ "lftp" }, job.cmd)
  assert.truthy(job.stdin:find('put -O "/www" "/p/a b.txt"', 1, true))
  assert.truthy(job.stdin:find('mkdir -pf "/www"', 1, true))
  assert.are.same({ "s3cret" }, job.secrets)
end)
it("builds a reverse mirror with delete, dry-run and excludes", ...)   -- assert the exact mirror line
it("parses dry-run output for both directions", ...)                   -- fixtures → exact DiffEntry lists
it("detects authentication failures", ...)
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Capture fixtures** with lftp against a temp tree (`lftp -c 'open file:/; mirror -R --dry-run /tmp/a /tmp/b'`), check them in, then **implement**.
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add lftp sftp backend`

---

### Task 10: Process runner

**Files:**
- Create: `lua/passaporta/runner.lua`
- Test: `tests/runner_spec.lua` (uses `sh -c` commands; tests wait with `vim.wait`)

**Interfaces:**
- Consumes: `passaporta.Job`.
- Produces: `runner.run(job: passaporta.Job, opts: passaporta.RunOpts, on_done: fun(result: passaporta.RunResult))` with `---@class passaporta.RunOpts` `timeout_ms?: integer` (total, passed to `vim.system`) and `idle_timeout_ms?: integer` (a `vim.uv` timer restarted on every stdout/stderr chunk; on expiry `proc:kill(15)` and `timed_out = true`). `stdin` written via `vim.system`'s `stdin` option. Output split into lines, partial last line kept. `on_done` always invoked once, inside `vim.schedule`.

- [ ] **Step 1: Write failing tests**: `echo hi` → code 0, stdout `{"hi"}`; `cat` with stdin `"a\nb\n"` → stdout `{"a","b"}`; `sh -c 'exit 3'` → code 3; `sleep 5` with `timeout_ms = 200` → `timed_out`; `sh -c 'echo x; sleep 0.3; echo y; sleep 5'` with `idle_timeout_ms = 1000` → `timed_out` with stdout `{"x","y"}`; `sh -c 'for i in 1 2 3; do echo $i; sleep 0.4; done'` with `idle_timeout_ms = 1000` → not timed out (idle timer resets).
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add async process runner with idle timeout`

---

### Task 11: Notifications and diff rendering

**Files:**
- Create: `lua/passaporta/notify.lua`, `lua/passaporta/diff.lua`
- Test: `tests/notify_spec.lua`, `tests/diff_spec.lua`

**Interfaces:**
- Produces (`notify`): `notify.redact(text: string, secrets: string[]): string` (every occurrence → `"***"`); `notify.info|warn|error(msg: string, remote_name?: string, opts?: table)` calling `config.options.notify or vim.notify` with `title = "Passaporta"` and `msg` prefixed `"[" .. remote_name .. "] "` when given; `notify.progress(msg, remote_name): any` returns the notification handle so a later call with `opts.replace` can update it (as transfer.nvim does).
- Produces (`diff`): `diff.quickfix_items(entries: passaporta.DiffEntry[], local_dir: string): table[]` → `{ filename = local_dir .. "/" .. path, text = "[A] path" }` (`[M]`, `[D]`; deleted and directory entries have `valid = 0` and no `filename`); `diff.header_items(local_rel: string, remote: passaporta.Remote, remote_path: string, cmdline: string): table[]` → three `valid = 0` items; `diff.show_dir(header, entries, local_dir)` → `setqflist` with title `"Passaporta diff: <local_rel>"`, `copen`; `diff.temp_path(local_path: string): string` → `stdpath("cache") .. "/passaporta/<pid>-<counter>-<basename>"` (dir created); `diff.open_file(local_path, temp_path, remote_name)` → `diffsplit`, remote buffer `readonly`, `nobuflisted`, `bufhidden=wipe`, autocmd `BufWipeout` deletes the temp file, close mapping from `config.options.close_diff_mapping` as in transfer.nvim.

- [ ] **Step 1: Write failing tests**: redact replaces all occurrences and leaves text without secrets untouched; `info` prefixes `[staging] ` and sets the title (stub `config.options.notify`); `quickfix_items` mapping for the three statuses incl. a path with a space; `temp_path` keeps the extension and the directory exists.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add notifications and diff rendering`

---

### Task 12: Operations orchestration

**Files:**
- Create: `lua/passaporta/ops.lua`
- Test: `tests/ops_spec.lua` (stubs `runner.run`, `vim.ui.select`, `secrets.prompt`, `config.options.notify`; uses a temp project dir with a fixture deployment config and real files)

**Interfaces:**
- Consumes: everything from Tasks 1–11.
- Produces: `ops.transfer(op: "upload"|"download"|"syncup"|"syncdown", path?: string, opts?: passaporta.OpOpts)` and `ops.diff(path?: string, opts?: passaporta.OpOpts)` with `---@class passaporta.OpOpts` `remote?: string`, `force_pick?: boolean`.
- Produces: `ops.choose_remote(root, candidates, opts, cb: fun(remote: passaporta.Remote|nil))` — exact rule: `opts.remote` named → that candidate or error `"<name> does not cover this path"`; `opts.force_pick` → `vim.ui.select` over candidate names, do not store; one candidate → it; active remote among candidates → it; else `vim.ui.select` and `state.set_active`. Picker items formatted `"<name>  (<protocol> <host>:<remote_path>)"`.
- Produces: `ops.in_flight(key: string): boolean` guard — same `(op, abs path)` while running is refused with a warning.
- Behaviour: root = `vim.uv.cwd()`; path default `vim.fn.expand("%:p")`; abs path outside root → error `"<path> is outside the project root"`; directory ↔ file dispatch by `vim.fn.isdirectory`; `syncup`/`syncdown` on a file behave as `upload`/`download`; excludes = `config.options.excludes` + `resolve.excludes_for_dir`; runner opts: file ops `{ timeout_ms }`, dir ops `{ idle_timeout_ms }`; on success: download → `edit!` any loaded buffer under the path; dir ops → info with the output lines (or `"No differences found"`); diff file → `diff.open_file`; diff dir → `backend.parse_dry_run` → `diff.show_dir`; on failure: `is_auth_failure` → `secrets.invalidate` + error `"authentication failed, cached password dropped"`; else error with redacted stderr; `timed_out` → error `"timed out (no output for <n>s)"` / `"timed out after <n>s"`.

- [ ] **Step 1: Write failing tests**: single candidate runs without picker and the Job's cmd targets that remote; two candidates → picker called once, then second call reuses the active remote without picker; bang (`force_pick`) opens the picker and leaves the active remote unchanged; `opts.remote` not covering the path → error notification; sftp candidate with `password = true` prompts once across two operations; auth failure stderr → `secrets.get` prompts again on the next call; path outside root → error; `syncup` on a file produces the file Job; dir diff with stubbed dry-run output fills the quickfix list with the right number of items.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `lua/passaporta/ops.lua`**
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: orchestrate transfers and diffs`

---

### Task 13: Command, loader and public API

**Files:**
- Create: `lua/passaporta/commands.lua`, `plugin/passaporta.lua`, `lua/passaporta/init.lua`
- Test: `tests/commands_spec.lua`

**Interfaces:**
- Produces: `commands.parse(fargs: string[], bang: boolean): passaporta.ParsedCommand|nil, err` with `sub` ∈ `upload download syncup syncdown diff remote repeat init forget`, `arg: string|nil` (path or remote name / `clear`), `bang`. Unknown sub → `"unknown subcommand '<x>'"`.
- Produces: `commands.run(cmd_opts)` (Neovim command callback) dispatching: transfer subs → `ops.transfer(sub, arg, { force_pick = bang })`, `diff` → `ops.diff`, `remote` with no arg → `vim.ui.select` over all remote names → `state.set_active`; `remote clear` → `set_active(nil)`; `remote <name>` → validate exists → set; `repeat` → re-run `state.get_last(root)` or warn `"nothing to repeat"`; `init` → create `.nvim/` and the template if missing, `edit` it; `forget` → `secrets.forget(root)` → info `"dropped <n> cached password(s)"`. `set_last` is updated by transfer subs only.
- Produces: `commands.complete(arglead, cmdline, cursorpos): string[]` → subcommands for the first word; remote names + `clear` after `remote`; `vim.fn.getcompletion(arglead, "file")` after a transfer/diff sub.
- Produces: `plugin/passaporta.lua` → `nvim_create_user_command("Passaporta", ..., { nargs = "*", bang = true, complete = ... })` with lazy requires.
- Produces: `init.lua` → `setup(opts)`, `upload(path?, opts?)`, `download`, `syncup`, `syncdown`, `diff`, `set_remote(name)`, `pick_remote()`, `clear_remote()`, `active_remote(): string|nil`, `repeat_last()`, `forget_passwords()`.

- [ ] **Step 1: Write failing tests**: `parse` for each sub, bang, missing arg, unknown sub; `complete` for the three positions; `init` creates the file from the template in a temp cwd and does not overwrite an existing one; `repeat` with nothing stored warns.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement the three files**
- [ ] **Step 4: Run, expect PASS; then smoke test by hand** in Neovim: `:Passaporta init`, `:Passaporta remote`, `:Passaporta upload` on a two-remote config against a reachable ssh host.
- [ ] **Step 5: Commit** `feat: add :Passaporta command and public API`

---

### Task 14: Health check

**Files:**
- Create: `lua/passaporta/health.lua`
- Test: none automated (vim.health output); verify with `:checkhealth passaporta`.

**Interfaces:**
- Produces: `health.check()` using `vim.health.start/ok/warn/error`: Neovim ≥ 0.10; `rsync` (`vim.fn.executable`, version via `rsync --version`, warn below 3.2.3), `ssh`, `lftp` (warn below 4.9); current project: config present/absent, `deployment.load` errors and warnings, one line per remote `"<name>: <protocol> <host>"` with an error when that backend's tool is missing; warn on plain-string passwords (`"password stored in plain text in deployment config"`).

- [ ] **Step 1: Implement**
- [ ] **Step 2: Verify** `:checkhealth passaporta` in a project with the fixture config shows the expected sections.
- [ ] **Step 3: Commit** `feat: add checkhealth report`

---

### Task 15: Documentation and integration script

**Files:**
- Create: `README.md`, `doc/passaporta.txt`, `scripts/integration-sftp.sh`

- [ ] **Step 1: Write `README.md`** per spec section *Documentation*: name explanation (one line: Italian for Portkey), credit "inspired by transfer.nvim", install (lazy.nvim with `cmd = "Passaporta"`), requirements per backend, config reference (table of remote fields incl. `protocol`, `port`, `password` variants), commands table (merge vs sync explained), active remote and bang, password handling and security notes (`.nvim/` in `.gitignore`), lftp caveats (size/mtime, `--no-perms`, host keys), migration from transfer.nvim (`password` needs `protocol = "sftp"`, `upload_on_save` ignored, glob excludes now apply to single files), snippets for oil.nvim, snacks explorer, which-key, lualine (`require("passaporta").active_remote()`), related projects list from the spec.
- [ ] **Step 2: Write `doc/passaporta.txt`** mirroring the README sections with help tags `*passaporta*`, `*passaporta-config*`, `*passaporta-commands*`, `*:Passaporta*`.
- [ ] **Step 3: Write `scripts/integration-sftp.sh`**: starts `atmoz/sftp` in Docker with user `test:pass:::upload`, creates a temp project with a `deployment.lua` pointing at it (`protocol = "sftp"`, `password = "pass"`), runs headless Neovim calling `require("passaporta").upload(dir)`, `diff`, `syncdown`, asserts file presence via `docker exec`, and ends with an unknown-host-key attempt that must exit within 30 s. Document how to run it in the README's *Contributing* section.
- [ ] **Step 4: Run the script once**, paste the summary in the PR/commit body if anything had to change.
- [ ] **Step 5: Commit** `docs: add README, vimdoc and sftp integration script`
