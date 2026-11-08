--- Password resolution and per-session cache. Memory only; never persisted.

local M = {}

---@type table<string,table<string,string>> project root -> remote name -> password
local cache = {}

---Ask the user for a secret without echoing it. Replaceable in tests.
---@param text string
---@return string|nil
M.prompt = function(text)
  return vim.fn.inputsecret(text)
end

---@param root string
---@param name string
---@param password string
---@return string
local function store(root, name, password)
  cache[root] = cache[root] or {}
  cache[root][name] = password
  return password
end

---Resolve the password of `remote` for the project `root`, caching it for the session.
---@param root string
---@param remote passaporta.Remote
---@return string|nil password nil when the remote has no password or resolution failed
---@return string|nil err
function M.get(root, remote)
  local spec = remote.password
  if spec == nil then
    return nil, nil
  end
  local name = remote.name
  local cached = cache[root] and cache[root][name]
  if cached then
    return cached, nil
  end

  if spec == true then
    local who = remote.username and (remote.username .. "@") or ""
    local answer = M.prompt(("Password for %s (%s%s): "):format(name, who, remote.host))
    if answer == nil or answer == "" then
      return nil, "no password entered"
    end
    return store(root, name, answer), nil
  end

  if type(spec) == "string" then
    return store(root, name, spec), nil
  end

  local ok, result = pcall(spec)
  if not ok then
    return nil, ("password function on %s failed: %s"):format(name, tostring(result))
  end
  if type(result) ~= "string" then
    return nil, ("password function on %s must return a string"):format(name)
  end
  return store(root, name, result), nil
end

---Drop the cached password of one remote.
---@param root string
---@param name string
function M.invalidate(root, name)
  if cache[root] then
    cache[root][name] = nil
  end
end

---Drop every cached password of the project `root`.
---@param root string
---@return integer count entries dropped
function M.forget(root)
  local count = vim.tbl_count(cache[root] or {})
  cache[root] = nil
  return count
end

---Drop all cached passwords.
function M.reset()
  cache = {}
end

return M
