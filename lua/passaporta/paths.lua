--- Pure path helpers: local normalisation, prefix matching and remote path joining.
local M = {}

---@param s string
---@return string
local function strip_trailing_slash(s)
  return (s:gsub("/+$", ""))
end

--- Project-relative path of `abs` inside `root`.
--- Returns "" for the root itself, keeps a trailing "/" from the input, nil when outside the root.
---@param abs string
---@param root string
---@return string|nil
function M.normalize_local(abs, root)
  local trailing = abs:sub(-1) == "/"
  local bare = strip_trailing_slash(vim.fs.normalize(abs, { expand_env = false }))
  root = strip_trailing_slash(vim.fs.normalize(root, { expand_env = false }))
  if bare == root then
    return ""
  end
  if bare:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  local rel = bare:sub(#root + 2)
  if trailing then
    rel = rel .. "/"
  end
  return rel
end

--- Component-wise prefix match; an empty prefix matches everything.
---@param path string
---@param prefix string
---@return boolean
function M.path_matches(path, prefix)
  prefix = strip_trailing_slash(prefix)
  path = strip_trailing_slash(path)
  if prefix == "" then
    return true
  end
  if path:sub(1, #prefix) ~= prefix then
    return false
  end
  return #path == #prefix or path:sub(#prefix + 1, #prefix + 1) == "/"
end

--- Normalise a mapping's `local` value: no "./", no leading/trailing "/", nil/"."/"/" become "".
---@param s string|nil
---@return string
function M.normalize_mapping_local(s)
  if s == nil then
    return ""
  end
  s = s:gsub("^%./", ""):gsub("^/+", ""):gsub("/+$", "")
  if s == "." then
    return ""
  end
  return s
end

--- Remote path for the project-relative `rel` under `mapping`. A trailing "/" on `rel` (or the
--- empty root) is mirrored. Relative remotes stay relative. Nil when `rel` is outside the mapping.
---@param mapping passaporta.Mapping
---@param rel string
---@return string|nil
function M.join_remote(mapping, rel)
  local mapped = mapping["local"]
  local remote = mapping.remote
  local trailing = rel == "" or rel:sub(-1) == "/"
  local bare = strip_trailing_slash(rel)
  if not M.path_matches(bare, mapped) then
    return nil
  end
  local suffix = mapped == "" and bare or bare:sub(#mapped + 2)

  local result
  if suffix == "" then
    result = remote
  elseif remote == "" then
    result = suffix
  elseif remote:sub(-1) == "/" then
    result = remote .. suffix
  else
    result = remote .. "/" .. suffix
  end

  if result == "/" or result == "" then
    return result
  end
  result = strip_trailing_slash(result)
  return trailing and result .. "/" or result
end

return M
