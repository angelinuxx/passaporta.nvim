--- Load and validate the project's deployment config (`.nvim/deployment.lua`).
local paths = require "passaporta.paths"

local M = {}

---@class passaporta.Mapping
---@field ["local"] string project-relative, no leading "./" or "/", no trailing "/", "" = root
---@field remote string as configured, trailing "/" stripped unless it is exactly "/"

---@class passaporta.Remote
---@field name string
---@field host string
---@field username? string
---@field port? integer
---@field protocol "ssh"|"sftp"
---@field password? true|string|fun(): string
---@field mappings passaporta.Mapping[]
---@field excludedPaths string[]

---@param v any
---@return boolean
local function is_positive_integer(v)
  return type(v) == "number" and v > 0 and v == math.floor(v)
end

---@param name string
---@param raw table
---@param errors string[]
---@param warnings string[]
---@return passaporta.Remote|nil
local function normalize_remote(name, raw, errors, warnings)
  local before = #errors
  ---@param msg string
  local function fail(msg)
    errors[#errors + 1] = name .. ": " .. msg
  end

  if type(raw) ~= "table" then
    fail "remote must be a table"
    return nil
  end

  if type(raw.host) ~= "string" or raw.host == "" then
    fail "host is required and must be a string"
  end

  local mappings = {}
  if type(raw.mappings) ~= "table" or #raw.mappings == 0 then
    fail "mappings must be a non-empty list"
  else
    for i, m in ipairs(raw.mappings) do
      if type(m) ~= "table" or type(m.remote) ~= "string" then
        fail(("mapping %d has no remote"):format(i))
      elseif m["local"] ~= nil and type(m["local"]) ~= "string" then
        fail(("mapping %d has a non-string local"):format(i))
      else
        local remote = m.remote:match "^/+$" and "/" or m.remote:gsub("/+$", "")
        if remote == "" then
          fail(("mapping %d has an empty remote"):format(i))
        else
          mappings[#mappings + 1] = { ["local"] = paths.normalize_mapping_local(m["local"]), remote = remote }
        end
      end
    end
  end

  local protocol = raw.protocol == nil and "ssh" or raw.protocol
  if protocol ~= "ssh" and protocol ~= "sftp" then
    fail "protocol must be 'ssh' or 'sftp'"
  end

  if raw.password ~= nil then
    if protocol ~= "sftp" then
      fail "password auth is only supported with protocol = 'sftp'"
    elseif raw.password ~= true and type(raw.password) ~= "string" and type(raw.password) ~= "function" then
      fail "password must be true, a string or a function"
    elseif type(raw.username) ~= "string" or raw.username == "" then
      -- lftp only receives the password together with a user (`open -u user,password`).
      fail "password requires username"
    end
  end

  if raw.port ~= nil and not is_positive_integer(raw.port) then
    fail "port must be a positive integer"
  end

  if raw.upload_on_save ~= nil then
    warnings[#warnings + 1] = name .. ": upload_on_save is not supported and will be ignored"
  end

  if #errors > before then
    return nil
  end

  return {
    name = name,
    host = raw.host,
    username = raw.username,
    port = raw.port,
    protocol = protocol,
    password = raw.password,
    mappings = mappings,
    excludedPaths = raw.excludedPaths or {},
  }
end

--- Validate a raw config table. Remotes come back sorted by name; errors and warnings follow that order.
---@param raw table
---@return passaporta.Remote[]|nil remotes nil when there are errors
---@return string[] errors
---@return string[] warnings
function M.normalize(raw)
  local errors, warnings = {}, {}
  if type(raw) ~= "table" then
    return nil, { "deployment config must return a table of remotes" }, warnings
  end

  local names = {}
  for name in pairs(raw) do
    names[#names + 1] = tostring(name)
  end
  table.sort(names)

  local remotes = {}
  for _, name in ipairs(names) do
    local remote = normalize_remote(name, raw[name], errors, warnings)
    remotes[#remotes + 1] = remote
  end

  if #errors > 0 then
    return nil, errors, warnings
  end
  return remotes, errors, warnings
end

--- Read and validate `<root>/<config_file>`.
---@param root string
---@return passaporta.Remote[]|nil remotes
---@return string|nil err
---@return string[] warnings
function M.load(root)
  local path = root .. "/" .. require("passaporta.config").options.config_file
  if not vim.uv.fs_stat(path) then
    return nil, "no deployment config at " .. path, {}
  end
  local ok, raw = pcall(dofile, path)
  if not ok then
    return nil, tostring(raw), {}
  end
  local remotes, errors, warnings = M.normalize(raw)
  if not remotes then
    return nil, table.concat(errors, "\n"), warnings
  end
  return remotes, nil, warnings
end

return M
