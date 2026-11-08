--- `:checkhealth passaporta`
local M = {}

local TIMEOUT_MS = 5000

---@class passaporta.ToolSpec
---@field cmd string
---@field args string[]
---@field min? integer[] minimum recommended version
---@field needed_by string

---@type passaporta.ToolSpec[]
local tools = {
  { cmd = "rsync", args = { "--version" }, min = { 3, 2, 3 }, needed_by = "ssh remotes" },
  { cmd = "ssh", args = { "-V" }, needed_by = "ssh remotes" },
  { cmd = "lftp", args = { "--version" }, min = { 4, 9 }, needed_by = "sftp remotes" },
}

---@type table<string, string[]>
local backend_tools = { ssh = { "rsync", "ssh" }, sftp = { "lftp" } }

--- First `x.y[.z]` number found in a version banner.
---@param text string
---@return integer[]|nil
function M.parse_version(text)
  local v = text:match "%d+%.%d+[%.%d]*"
  if not v then
    return nil
  end
  local parts = {}
  for n in v:gmatch "%d+" do
    parts[#parts + 1] = tonumber(n)
  end
  return parts
end

--- Whether version `a` is older than `b`; missing components count as 0.
---@param a integer[]
---@param b integer[]
---@return boolean
function M.version_lt(a, b)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then
      return x < y
    end
  end
  return false
end

---@param v integer[]
---@return string
local function format_version(v)
  return table.concat(vim.tbl_map(tostring, v), ".")
end

---@param spec passaporta.ToolSpec
---@return integer[]|nil
local function detect_version(spec)
  local ok, res = pcall(function()
    return vim.system({ spec.cmd, unpack(spec.args) }, { text = true }):wait(TIMEOUT_MS)
  end)
  if not ok or not res then
    return nil
  end
  return M.parse_version((res.stdout or "") .. (res.stderr or ""))
end

---@return table<string, boolean> available
local function check_tools()
  vim.health.start "passaporta: tools"
  local available = {}
  for _, spec in ipairs(tools) do
    if vim.fn.executable(spec.cmd) ~= 1 then
      vim.health.warn(("%s not found in PATH (needed by %s)"):format(spec.cmd, spec.needed_by))
    else
      available[spec.cmd] = true
      local version = detect_version(spec)
      if not version then
        vim.health.ok(spec.cmd .. " found (version unknown)")
      elseif spec.min and M.version_lt(version, spec.min) then
        vim.health.warn(
          ("%s %s is older than the recommended %s"):format(spec.cmd, format_version(version), format_version(spec.min))
        )
      else
        vim.health.ok(("%s %s"):format(spec.cmd, format_version(version)))
      end
    end
  end
  return available
end

---@param available table<string, boolean>
local function check_project(available)
  vim.health.start "passaporta: project"
  local root = vim.uv.cwd() or "."
  local path = root .. "/" .. require("passaporta.config").options.config_file
  vim.health.info("project root: " .. root)
  if not vim.uv.fs_stat(path) then
    vim.health.info("no deployment config at " .. path)
    vim.health.info "remote hosts must be in known_hosts: connect once interactively before using a remote"
    return
  end

  local remotes, err, warnings = require("passaporta.deployment").load(root)
  for _, w in ipairs(warnings) do
    vim.health.warn(w)
  end
  if not remotes then
    vim.health.error("deployment config error: " .. tostring(err))
    return
  end

  vim.health.ok("deployment config loaded: " .. path)
  vim.health.info "remote hosts must be in known_hosts: connect once interactively before using a remote"
  for _, remote in ipairs(remotes) do
    local line = ("%s: %s %s"):format(remote.name, remote.protocol, remote.host)
    local missing = vim.tbl_filter(function(t)
      return not available[t]
    end, backend_tools[remote.protocol])
    if #missing > 0 then
      vim.health.error(line .. " (missing: " .. table.concat(missing, ", ") .. ")")
    else
      vim.health.ok(line)
    end
    if type(remote.password) == "string" then
      vim.health.warn(remote.name .. ": password stored in plain text in deployment config")
    end
  end
end

function M.check()
  vim.health.start "passaporta: neovim"
  if vim.fn.has "nvim-0.10" == 1 then
    vim.health.ok "Neovim >= 0.10"
  else
    vim.health.error "Neovim >= 0.10 is required"
  end
  check_project(check_tools())
end

return M
