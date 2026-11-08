--- Orchestration of transfers and diffs: resolve candidates, pick the remote, obtain the password,
--- build the backend Job, run it and report the outcome.
local config = require "passaporta.config"
local deployment = require "passaporta.deployment"
local diff = require "passaporta.diff"
local notify = require "passaporta.notify"
local paths = require "passaporta.paths"
local resolve = require "passaporta.resolve"
local runner = require "passaporta.runner"
local secrets = require "passaporta.secrets"
local state = require "passaporta.state"

---@class passaporta.OpOpts
---@field remote? string use this remote (it must cover the path), no picker
---@field force_pick? boolean always open the picker and do not change the active remote

---@alias passaporta.TransferOp "upload"|"download"|"syncup"|"syncdown"

---@class passaporta.Target
---@field root string project root
---@field abs string absolute path, no trailing "/"
---@field rel string project-relative path, "" for the root
---@field label string `rel` for display ("." for the root)
---@field is_dir boolean

local M = {}

local backends = {
  ssh = require "passaporta.backends.ssh",
  sftp = require "passaporta.backends.sftp",
}

---@type table<string, boolean>
local running = {}

local PROGRESS = { upload = "uploading", download = "downloading", syncup = "syncing up", syncdown = "syncing down" }
local DONE = { upload = "uploaded", download = "downloaded", syncup = "synced up", syncdown = "synced down" }

---Whether the operation keyed `op .. ":" .. abs path` is still running.
---@param key string
---@return boolean
function M.in_flight(key)
  return running[key] == true
end

---Forget every in-flight operation. Intended for tests.
function M.reset()
  running = {}
end

---@param candidate passaporta.Candidate
---@return string
local function format_candidate(candidate)
  local r = candidate.remote
  return ("%s  (%s %s:%s)"):format(r.name, r.protocol, r.host, candidate.remote_path)
end

---Pick the remote among `candidates` (see the "Choosing the remote" rules).
---`cb` receives nil when the choice failed or was cancelled.
---@param root string
---@param candidates passaporta.Candidate[]
---@param opts? passaporta.OpOpts
---@param cb fun(remote: passaporta.Remote|nil, candidate: passaporta.Candidate|nil)
function M.choose_remote(root, candidates, opts, cb)
  opts = opts or {}

  ---@param name string
  ---@return passaporta.Candidate|nil
  local function find(name)
    for _, c in ipairs(candidates) do
      if c.remote.name == name then
        return c
      end
    end
    return nil
  end

  ---@param remember boolean
  local function pick(remember)
    vim.ui.select(candidates, { prompt = "Passaporta: choose remote", format_item = format_candidate }, function(choice)
      if not choice then
        cb(nil, nil)
        return
      end
      if remember then
        state.set_active(root, choice.remote.name)
      end
      cb(choice.remote, choice)
    end)
  end

  if opts.remote then
    local c = find(opts.remote)
    if not c then
      notify.error("does not cover this path", opts.remote)
      cb(nil, nil)
      return
    end
    cb(c.remote, c)
    return
  end
  if opts.force_pick then
    pick(false)
    return
  end
  if #candidates == 1 then
    cb(candidates[1].remote, candidates[1])
    return
  end
  local active = state.get_active(root)
  local c = active and find(active)
  if c then
    cb(c.remote, c)
    return
  end
  pick(true)
end

---Resolve `path` (default: current buffer) against the project root.
---@param path? string
---@return passaporta.Target|nil
local function target(path)
  local root = vim.uv.cwd() or ""
  path = (path and path ~= "") and path or vim.fn.expand "%:p"
  if path == "" then
    notify.error "no path given and the current buffer has no file"
    return nil
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  if abs ~= "/" then
    abs = abs:gsub("/+$", "")
  end
  local rel = paths.normalize_local(abs, root)
  if not rel then
    notify.error(("%s is outside the project root"):format(path))
    return nil
  end
  return {
    root = root,
    abs = abs,
    rel = rel,
    label = rel == "" and "." or rel,
    is_dir = vim.fn.isdirectory(abs) == 1,
  }
end

---Load the config and resolve the candidates of `t`; notifies and returns nil on failure.
---@param t passaporta.Target
---@return passaporta.Candidate[]|nil
local function candidates_for(t)
  local remotes, err, warnings = deployment.load(t.root)
  local unnamed = {}
  for _, w in ipairs(warnings or {}) do
    local owner
    for _, remote in ipairs(remotes or {}) do
      if vim.startswith(w, remote.name .. ": ") then
        owner = remote.name
        break
      end
    end
    if owner then
      notify.warn(w:sub(#owner + 3), owner)
    else
      unnamed[#unnamed + 1] = w
    end
  end
  if #unnamed > 0 then
    notify.warn(table.concat(unnamed, "\n"))
  end
  if not remotes then
    notify.error(err or "invalid deployment config")
    return nil
  end
  if #remotes == 0 then
    notify.error("no remotes configured in " .. config.options.config_file)
    return nil
  end
  local rel = (t.is_dir and t.rel ~= "") and (t.rel .. "/") or t.rel
  local candidates, reason = resolve.candidates(remotes, rel)
  if #candidates == 0 then
    notify.error(reason or ("'%s' is not mapped in deployment config"):format(t.rel))
    return nil
  end
  return candidates
end

---Excludes of a directory operation: the global ones, then the remote's rebased rules.
---@param remote passaporta.Remote
---@param t passaporta.Target
---@return string[]
local function dir_excludes(remote, t)
  local excludes = vim.deepcopy(config.options.excludes)
  return vim.list_extend(
    excludes,
    resolve.excludes_for_dir(remote, t.rel, function(rule)
      return vim.fn.isdirectory(t.abs .. "/" .. rule) == 1
    end)
  )
end

---@param remote_path string
---@return string
local function strip_remote(remote_path)
  if remote_path == "/" then
    return remote_path
  end
  return (remote_path:gsub("/+$", ""))
end

---The command shown to the user: argv for ssh, "lftp" plus the mirror line for sftp. Redacted.
---@param job passaporta.Job
---@return string
local function display_cmdline(job)
  local line = table.concat(job.cmd, " ")
  if job.stdin then
    for l in vim.gsplit(job.stdin, "\n", { plain = true }) do
      if vim.startswith(l, "mirror") then
        line = "lftp " .. l
        break
      end
    end
  end
  return notify.redact(line, job.secrets)
end

---@param lines string[]
---@param job passaporta.Job
---@return string[]
local function redacted_lines(lines, job)
  local out = {}
  for _, l in ipairs(lines) do
    if l ~= "" then
      out[#out + 1] = notify.redact(l, job.secrets)
    end
  end
  return out
end

---Message for a failed run, or nil on success. On authentication failures drops the cached password
---when the remote uses one.
---@param result passaporta.RunResult
---@param job passaporta.Job
---@param backend table
---@param remote passaporta.Remote
---@param t passaporta.Target
---@param run_opts passaporta.RunOpts
---@param what string
---@return string|nil
local function failure(result, job, backend, remote, t, run_opts, what)
  if result.timed_out then
    if run_opts.idle_timeout_ms then
      return ("timed out (no output for %ds)"):format(run_opts.idle_timeout_ms / 1000)
    end
    return ("timed out after %ds"):format(run_opts.timeout_ms / 1000)
  end
  if result.code == 0 then
    return nil
  end
  if backend.is_auth_failure(table.concat(result.stderr, "\n")) then
    if remote.password == nil then
      return "authentication failed"
    end
    secrets.invalidate(t.root, remote.name)
    return "authentication failed, cached password dropped"
  end
  local output = redacted_lines(#result.stderr > 0 and result.stderr or result.stdout, job)
  local msg = ("%s %s failed (exit %d)"):format(what, t.label, result.code)
  if #output > 0 then
    msg = msg .. "\n" .. table.concat(output, "\n")
  end
  return msg
end

---Reload the unmodified loaded buffers at or under `t.abs` whose file still exists; warn about modified ones.
---@param t passaporta.Target
---@param remote passaporta.Remote
local function reload_buffers(t, remote)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if
      name ~= ""
      and vim.api.nvim_buf_is_loaded(buf)
      and (name == t.abs or (t.is_dir and vim.startswith(name, t.abs .. "/")))
      and vim.uv.fs_stat(name) -- a file removed by syncdown keeps its buffer instead of becoming empty
    then
      if vim.bo[buf].modified then
        local rel = paths.normalize_local(name, t.root) or name
        notify.warn(("%s has unsaved changes, not reloaded"):format(rel), remote.name)
      else
        vim.api.nvim_buf_call(buf, function()
          vim.cmd "silent edit!"
        end)
      end
    end
  end
end

---Common pipeline: target → candidates → remote → password, then `start` builds and runs the Job.
---@param op string in-flight key prefix and name in messages
---@param path? string
---@param opts? passaporta.OpOpts
---@param start fun(t: passaporta.Target, remote: passaporta.Remote, candidate: passaporta.Candidate, password: string|nil)
local function prepare(op, path, opts, start)
  local t = target(path)
  if not t then
    return
  end
  local key = op .. ":" .. t.abs
  if M.in_flight(key) then
    notify.warn(("%s already running for %s"):format(op, t.label))
    return
  end
  local candidates = candidates_for(t)
  if not candidates then
    return
  end
  M.choose_remote(t.root, candidates, opts, function(remote, candidate)
    if not remote or not candidate then
      return
    end
    local password, err = secrets.get(t.root, remote)
    if err then
      notify.error(err, remote.name)
      return
    end
    if M.in_flight(key) then
      notify.warn(("%s already running for %s"):format(op, t.label), remote.name)
      return
    end
    start(t, remote, candidate, password)
  end)
end

---Run `job` under the in-flight guard and call `on_success` or report the failure.
---@param key string
---@param job passaporta.Job
---@param run_opts passaporta.RunOpts
---@param ctx { backend: table, remote: passaporta.Remote, target: passaporta.Target, what: string, progress: any }
---@param on_success fun(result: passaporta.RunResult)
---@param on_failure? fun()
local function run(key, job, run_opts, ctx, on_success, on_failure)
  running[key] = true
  runner.run(job, run_opts, function(result)
    running[key] = nil
    local msg = failure(result, job, ctx.backend, ctx.remote, ctx.target, run_opts, ctx.what)
    if msg then
      if on_failure then
        on_failure()
      end
      notify.error(msg, ctx.remote.name, { replace = ctx.progress })
      return
    end
    on_success(result)
  end)
end

---Upload, download or sync a file or directory.
---@param op passaporta.TransferOp
---@param path? string default: the current buffer's file
---@param opts? passaporta.OpOpts
function M.transfer(op, path, opts)
  prepare(op, path, opts, function(t, remote, candidate, password)
    local backend = backends[remote.protocol]
    local up = op == "upload" or op == "syncup"
    local effective = t.is_dir and op or (up and "upload" or "download")
    ---@type passaporta.TransferArgs
    local args = {
      local_path = t.abs,
      remote_path = strip_remote(candidate.remote_path),
      direction = up and "up" or "down",
      delete = t.is_dir and (op == "syncup" or op == "syncdown"),
      dry_run = false,
      excludes = t.is_dir and dir_excludes(remote, t) or {},
      password = password,
    }
    local job, run_opts
    if t.is_dir then
      job, run_opts = backend.dir(remote, args), { idle_timeout_ms = config.options.idle_timeout_ms }
    else
      job, run_opts = backend.file(remote, args), { timeout_ms = config.options.timeout_ms }
    end
    local progress = notify.progress(("%s %s …"):format(PROGRESS[effective], t.label), remote.name)
    local ctx = { backend = backend, remote = remote, target = t, what = effective, progress = progress }
    run(op .. ":" .. t.abs, job, run_opts, ctx, function(result)
      local done = ("%s %s"):format(DONE[effective], t.label)
      if t.is_dir then
        local lines = redacted_lines(result.stdout, job)
        if #lines == 0 then
          done = done .. ": No differences found"
        else
          done = done .. "\n" .. table.concat(lines, "\n")
        end
      end
      notify.info(done, remote.name, { replace = progress })
      if not up then
        reload_buffers(t, remote)
      end
    end)
  end)
end

---Diff a file (temp download + diffsplit) or a directory (simulated syncup → quickfix).
---@param path? string default: the current buffer's file
---@param opts? passaporta.OpOpts
function M.diff(path, opts)
  prepare("diff", path, opts, function(t, remote, candidate, password)
    local backend = backends[remote.protocol]
    local remote_path = strip_remote(candidate.remote_path)
    local key = "diff:" .. t.abs
    local progress = notify.progress(("diffing %s …"):format(t.label), remote.name)
    local ctx = { backend = backend, remote = remote, target = t, what = "diff", progress = progress }

    if not t.is_dir then
      local temp = diff.temp_path(t.abs)
      ---@type passaporta.TransferArgs
      local args = {
        local_path = temp,
        remote_path = remote_path,
        direction = "down",
        delete = false,
        dry_run = false,
        excludes = {},
        password = password,
      }
      run(key, backend.file(remote, args), { timeout_ms = config.options.timeout_ms }, ctx, function()
        notify.info(("diff of %s ready"):format(t.label), remote.name, { replace = progress })
        diff.open_file(t.abs, temp, remote.name)
      end, function()
        os.remove(temp)
      end)
      return
    end

    ---@type passaporta.TransferArgs
    local args = {
      local_path = t.abs,
      remote_path = remote_path,
      direction = "up",
      delete = true,
      dry_run = true,
      excludes = dir_excludes(remote, t),
      password = password,
    }
    local job = backend.dir(remote, args)
    run(key, job, { idle_timeout_ms = config.options.idle_timeout_ms }, ctx, function(result)
      local entries = backend.parse_dry_run(result.stdout, args)
      for _, entry in ipairs(entries) do
        entry.path = notify.redact(entry.path, job.secrets)
      end
      if #entries == 0 then
        notify.info(("diff %s: No differences found"):format(t.label), remote.name, { replace = progress })
        return
      end
      notify.info(("diff %s: %d differences"):format(t.label, #entries), remote.name, { replace = progress })
      local header = diff.header_items(t.label, remote, remote_path, display_cmdline(job))
      diff.show_dir(header, entries, t.abs, t.label)
    end)
  end)
end

return M
