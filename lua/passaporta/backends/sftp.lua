local config = require "passaporta.config"

local M = {}

---Characters lftp percent-encodes in the password part of the URLs it prints.
local PASS_UNSAFE = "[%c\128-\255 \"%%'/:<>@%[\\%]%^`{|}]"

---@param p string
---@return string
local function strip_slashes(p)
  if p:match "^/+$" then
    return "/"
  end
  return (p:gsub("/+$", ""))
end

---Quote a string for an lftp script: double quotes, `\` and `"` backslash-escaped.
---@param s string
---@return string
function M.quote(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

local q = M.quote

---The `open` command connecting to the remote; the password only ever lives here.
---@param remote passaporta.Remote
---@param password? string
---@return string
function M.open_line(remote, password)
  local url = "sftp://" .. remote.host .. (remote.port and (":" .. remote.port) or "")
  if remote.username then
    return "open -u " .. q(remote.username) .. "," .. q(password or "") .. " " .. q(url)
  end
  return "open " .. q(url)
end

---Settings applied before connecting, then the user's `lftp.settings` sorted by name.
---@return string[]
function M.preamble()
  local lines = {
    "set cmd:fail-exit yes",
    "set net:max-retries 2",
    "set net:timeout 30",
    "set net:reconnect-interval-base 5",
    "set xfer:clobber yes",
    "set sftp:auto-confirm no",
  }
  local settings = config.options.lftp.settings
  local names = vim.tbl_keys(settings)
  table.sort(names)
  for _, name in ipairs(names) do
    local value = settings[name]
    if type(value) == "boolean" then
      value = value and "yes" or "no"
    end
    lines[#lines + 1] = "set " .. name .. " " .. q(tostring(value))
  end
  return lines
end

---Strings to redact: the password as written and as lftp prints it inside URLs.
---@param password? string
---@return string[]
local function secrets(password)
  if not password or password == "" then
    return {}
  end
  local encoded = password:gsub(PASS_UNSAFE, function(c)
    return string.format("%%%02X", c:byte())
  end)
  if encoded == password then
    return { password }
  end
  return { password, encoded }
end

---@param remote passaporta.Remote
---@param args passaporta.TransferArgs
---@param commands string[]
---@return passaporta.Job
local function job(remote, args, commands)
  local lines = M.preamble()
  lines[#lines + 1] = M.open_line(remote, args.password)
  vim.list_extend(lines, commands)
  lines[#lines + 1] = "bye"
  return { cmd = { "lftp" }, stdin = table.concat(lines, "\n") .. "\n", secrets = secrets(args.password) }
end

---Build the lftp job that transfers a single file.
---@param remote passaporta.Remote
---@param args passaporta.TransferArgs
---@return passaporta.Job
function M.file(remote, args)
  local lp, rp = strip_slashes(args.local_path), strip_slashes(args.remote_path)
  if args.direction == "up" then
    local dir = vim.fs.dirname(rp)
    return job(remote, args, { "mkdir -pf " .. q(dir), "put " .. q(lp) .. " -o " .. q(rp) })
  end
  return job(remote, args, { "get " .. q(rp) .. " -o " .. q(lp) })
end

---Long mirror options that delete or move files (lftp also accepts unambiguous abbreviations).
local DELETION_OPTIONS =
  { "delete", "delete-first", "delete-excluded", "Remove-source-files", "Remove-source-dirs", "Move" }

---Short mirror options whose argument is the rest of the token (or the next token).
local SHORT_WITH_ARG = "[NPixIXfFO]"

---Scan a short-option cluster (`-e`, `-ve`, `-x.env`): whether it holds `-e` before any option that
---takes an argument, and whether that option's argument is the next token (`-x` `RX`; `-P` has an optional one).
---@param token string
---@return boolean deletes
---@return boolean next_is_arg
local function scan_short_cluster(token)
  local letters = token:sub(2)
  for i = 1, #letters do
    local c = letters:sub(i, i)
    if c == "e" then
      return true, false
    elseif c:match(SHORT_WITH_ARG) then
      return false, i == #letters and c ~= "P"
    end
  end
  return false, false
end

---Whether a long option (`--delete-f`, `--Mo`) names a deleting option.
---@param token string
---@return boolean
local function long_option_deletes(token)
  local name = token:sub(3):match "^[^=]*"
  if name == "" then
    return false
  end
  if vim.startswith(name, "delete") or vim.startswith(name:lower(), "remove-source") then
    return true
  end
  for _, option in ipairs(DELETION_OPTIONS) do
    if vim.startswith(option, name) then
      return true
    end
  end
  return false
end

---User mirror params without deletion flags: `--delete` is owned by the plugin (sync and diff only).
---Arguments of options that take one (`-x RX`) are kept untouched.
---@param params string[]
---@return string[]
local function without_deletion(params)
  local kept, next_is_arg = {}, false
  for _, p in ipairs(params) do
    local deletes = false
    if next_is_arg then
      next_is_arg = false
    elseif vim.startswith(p, "--") then
      deletes = long_option_deletes(p)
    elseif p:match "^%-." then
      deletes, next_is_arg = scan_short_cluster(p)
    end
    if not deletes then
      kept[#kept + 1] = p
    end
  end
  return kept
end

---Whether the user mirror params already set the parallelism (`--parallel=N`, an unambiguous
---abbreviation like `--para=N`, or a short cluster like `-P3`).
---@param params string[]
---@return boolean
local function sets_parallel(params)
  for _, p in ipairs(params) do
    local name = vim.startswith(p, "--") and p:sub(3):match "^[^=]*"
    if name and #name >= 2 and vim.startswith("parallel", name) then
      return true
    end
    if not name and p:match "^%-[^%-NPixIXfFO]*P" then
      return true
    end
  end
  return false
end

---Build the lftp job that mirrors (or dry-runs) a directory.
---@param remote passaporta.Remote
---@param args passaporta.TransferArgs
---@return passaporta.Job
function M.dir(remote, args)
  local parts = { "mirror" }
  if args.direction == "up" then
    parts[#parts + 1] = "-R"
  end
  if args.delete then
    parts[#parts + 1] = "--delete"
  end
  if args.dry_run then
    parts[#parts + 1] = "--dry-run"
  end
  parts[#parts + 1] = "-v"
  local params = without_deletion(config.options.lftp.mirror_params)
  local parallel = config.options.lftp.parallel
  -- A dry run transfers nothing: parallel connections would only cost extra logins.
  if not args.dry_run and type(parallel) == "number" and parallel > 1 and not sets_parallel(params) then
    parts[#parts + 1] = ("--parallel=%d"):format(math.floor(parallel))
  end
  vim.list_extend(parts, params)
  for _, pattern in ipairs(args.excludes) do
    -- lftp's "**/" needs at least one directory level: also emit the top-level form.
    local variants = { pattern }
    if vim.startswith(pattern, "**/") and #pattern > 3 then
      variants[2] = pattern:sub(4)
    end
    for _, glob in ipairs(variants) do
      -- lftp only excludes a directory when the glob ends with "/": emit both forms.
      vim.list_extend(parts, { "--exclude-glob", q(glob) })
      if not vim.endswith(glob, "/") then
        vim.list_extend(parts, { "--exclude-glob", q(glob .. "/") })
      end
    end
  end
  local lp, rp = q(strip_slashes(args.local_path)), q(strip_slashes(args.remote_path))
  if args.direction == "up" then
    vim.list_extend(parts, { lp, rp })
  else
    vim.list_extend(parts, { rp, lp })
  end
  return job(remote, args, { table.concat(parts, " ") })
end

---Split an lftp script line into words, honouring double quotes and backslash escapes.
---@param line string
---@return string[]
local function tokenize(line)
  local tokens, current, quoted, escaped, started = {}, {}, false, false, false
  for c in line:gmatch "." do
    if escaped then
      current[#current + 1], escaped, started = c, false, true
    elseif c == "\\" then
      escaped = true
    elseif c == '"' then
      quoted, started = not quoted, true
    elseif c:match "%s" and not quoted then
      if started then
        tokens[#tokens + 1], current, started = table.concat(current), {}, false
      end
    else
      current[#current + 1], started = c, true
    end
  end
  if started then
    tokens[#tokens + 1] = table.concat(current)
  end
  return tokens
end

---Whether `flag` appears among the options (between the verb and the location).
---@param tokens string[]
---@param flag string
---@return boolean
local function has_flag(tokens, flag)
  return vim.tbl_contains({ unpack(tokens, 2, #tokens - 1) }, flag)
end

---Turn a printed location (`file:/a%20b`, `sftp://u:p@h:22/a`, or a plain path) into a decoded path.
---@param location string
---@return string
local function location_path(location)
  local rest = location:match "^%a[%w+.-]*:(.*)$"
  if rest then
    location = rest:match "^//[^/]*(.*)$" or rest
  end
  return (location:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---Path of `path` relative to `root`. A relative remote root is printed by lftp home-resolved
---(`www` -> `/home/u/www`), so it is located as the first "/<root>/" segment run. Limitation: a remote
---root that is the home itself (`.`, `~`, "") cannot be located, and its lines are dropped. The directory
---diff simulates an upload, where transferred paths come from the (absolute) local side.
---@param path string
---@param root string
---@return string?
local function relative_to(path, root)
  root = strip_slashes(root)
  if root == "/" then
    return path:match "^/(.*)$"
  end
  if vim.startswith(root, "/") then
    if path == root then
      return ""
    end
    return vim.startswith(path, root .. "/") and path:sub(#root + 2) or nil
  end
  root = root:gsub("^~/", ""):gsub("^%./", "")
  if vim.endswith(path, "/" .. root) then
    return ""
  end
  local _, stop = path:find("/" .. root .. "/", 1, true)
  return stop and path:sub(stop + 1) or nil
end

---Parse `mirror --dry-run` output into diff entries. lftp prints `get` (even for `-R`) with the source
---last, and `mkdir`/`rm` with the target last; locations are URLs with percent-encoded paths.
---@param lines string[]
---@param args passaporta.TransferArgs
---@return passaporta.DiffEntry[]
function M.parse_dry_run(lines, args)
  local up = args.direction == "up"
  local source = up and args.local_path or args.remote_path
  local target = up and args.remote_path or args.local_path
  local entries = {}
  for _, line in ipairs(lines) do
    local tokens = tokenize(line)
    local verb, last = tokens[1], tokens[#tokens]
    local status, root, is_dir
    if verb == "get" or verb == "put" then
      status, root = has_flag(tokens, "-e") and "modified" or "new", source
    elseif verb == "mkdir" then
      status, root, is_dir = "new", target, true
    elseif verb == "rm" then
      status, root, is_dir = "deleted", target, has_flag(tokens, "-r")
    elseif verb == "rmdir" then
      status, root, is_dir = "deleted", target, true
    end
    local rel = status and #tokens > 1 and relative_to(location_path(last), root)
    if rel and rel ~= "" then
      entries[#entries + 1] = { status = status, path = is_dir and (rel .. "/") or rel }
    end
  end
  return entries
end

---Whether lftp's stderr reports an authentication failure. "Permission denied" counts only in ssh's
---authentication shapes, never on an lftp "Access failed" line (a remote write error).
---@param stderr string
---@return boolean
function M.is_auth_failure(stderr)
  for line in vim.gsplit(stderr:lower(), "\n", { plain = true }) do
    for _, needle in ipairs { "login failed", "login incorrect", "authentication failed" } do
      if line:find(needle, 1, true) then
        return true
      end
    end
    if not line:find("access failed", 1, true) then
      for _, needle in ipairs { "permission denied (", "permission denied, please try again" } do
        if line:find(needle, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

return M
