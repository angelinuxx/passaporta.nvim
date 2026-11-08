local config = require "passaporta.config"

local M = {}

---@class passaporta.TransferArgs
---@field local_path string    absolute; directories without trailing "/"
---@field remote_path string
---@field direction "up"|"down"
---@field delete boolean       directory ops only
---@field dry_run boolean      directory ops only
---@field excludes string[]    patterns relative to the directory being transferred
---@field password? string     sftp only

---@class passaporta.Job
---@field cmd string[]
---@field stdin? string
---@field secrets string[]     strings to redact from any output (password)

---@class passaporta.DiffEntry
---@field status "new"|"modified"|"deleted"
---@field path string          relative to the transferred directory; directories end with "/"

---@param p string
---@return string
local function strip_slashes(p)
  return (p:gsub("/+$", ""))
end

---@param remote passaporta.Remote
---@param path string
---@return string
local function remote_spec(remote, path)
  local user = remote.username and (remote.username .. "@") or ""
  return user .. remote.host .. ":" .. path
end

---User params without deletion flags: `--delete` is owned by the plugin (sync and diff only).
---Covers `--del`, every `--delete*`, `--remove-source-files` and its alias `--remove-sent-files`.
---@param params string[]
---@return string[]
local function without_deletion(params)
  return vim.tbl_filter(function(p)
    return not (vim.startswith(p, "--del") or vim.startswith(p, "--remove-s"))
  end, params)
end

---@param remote passaporta.Remote
---@return string[]
local function base_cmd(remote)
  if remote.port then
    return { "rsync", "-e", "ssh -p " .. remote.port }
  end
  return { "rsync" }
end

---@param remote passaporta.Remote
---@param args passaporta.TransferArgs
---@param suffix string "" for files, "/" for directories
---@return string src
---@return string dst
local function endpoints(remote, args, suffix)
  local lp = strip_slashes(args.local_path) .. suffix
  local rp = remote_spec(remote, strip_slashes(args.remote_path) .. suffix)
  if args.direction == "up" then
    return lp, rp
  end
  return rp, lp
end

---Build the rsync job that transfers a single file.
---@param remote passaporta.Remote
---@param args passaporta.TransferArgs
---@return passaporta.Job
function M.file(remote, args)
  local cmd = base_cmd(remote)
  vim.list_extend(cmd, { "-z" })
  if args.direction == "up" then
    cmd[#cmd + 1] = "--mkpath"
  end
  local src, dst = endpoints(remote, args, "")
  vim.list_extend(cmd, { src, dst })
  return { cmd = cmd, secrets = {} }
end

---Build the rsync job that transfers (or dry-runs) a directory.
---@param remote passaporta.Remote
---@param args passaporta.TransferArgs
---@return passaporta.Job
function M.dir(remote, args)
  local cmd = base_cmd(remote)
  local rsync = config.options.rsync
  vim.list_extend(cmd, without_deletion(args.direction == "up" and rsync.upload_params or rsync.download_params))
  if args.delete then
    cmd[#cmd + 1] = "--delete"
  end
  if args.dry_run then
    vim.list_extend(cmd, { "--dry-run", "--itemize-changes", "--out-format=%i %n" })
  end
  for _, pattern in ipairs(args.excludes) do
    vim.list_extend(cmd, { "--exclude", pattern })
  end
  local src, dst = endpoints(remote, args, "/")
  vim.list_extend(cmd, { src, dst })
  return { cmd = cmd, secrets = {} }
end

---Parse `--itemize-changes --out-format="%i %n"` output into diff entries.
---@param lines string[]
---@param args passaporta.TransferArgs
---@return passaporta.DiffEntry[]
function M.parse_dry_run(lines, args)
  ---@diagnostic disable-next-line: unused-local
  local _ = args
  local entries = {}
  for _, line in ipairs(lines) do
    local code, path = line:sub(1, 11), line:sub(13)
    if path ~= "" then
      if vim.startswith(code, "*deleting") then
        entries[#entries + 1] = { status = "deleted", path = path }
      elseif code:find("+++++++++", 1, true) then
        entries[#entries + 1] = { status = "new", path = path }
      elseif code:match "^[<>]f" then
        entries[#entries + 1] = { status = "modified", path = path }
      end
    end
  end
  return entries
end

---The ssh backend is key-only: there is no password to retry.
---@param _ string
---@return boolean
function M.is_auth_failure(_)
  return false
end

return M
