--- Pure resolution of project-relative paths to remote candidates and per-directory excludes.
local glob = require "passaporta.glob"
local paths = require "passaporta.paths"

---@class passaporta.Candidate
---@field remote passaporta.Remote
---@field mapping passaporta.Mapping
---@field remote_path string full remote path of the local path (trailing "/" mirrors the input)

local M = {}

---@param rel string
---@param rule string
---@return boolean
local function rule_matches(rel, rule)
  if glob.is_glob(rule) then
    return glob.matches(rel, rule)
  end
  return paths.path_matches(rel, rule)
end

---First exclusion rule of the remote matching `rel`.
---@param remote passaporta.Remote
---@param rel string
---@return string|nil
local function excluding_rule(remote, rel)
  for _, rule in ipairs(remote.excludedPaths) do
    if rule_matches(rel, rule) then
      return rule
    end
  end
  return nil
end

---Mapping with the longest `local` prefix covering `rel`.
---@param remote passaporta.Remote
---@param rel string
---@return passaporta.Mapping|nil
local function best_mapping(remote, rel)
  local best
  for _, mapping in ipairs(remote.mappings) do
    if paths.path_matches(rel, mapping["local"]) and (best == nil or #mapping["local"] > #best["local"]) then
      best = mapping
    end
  end
  return best
end

---Remotes (already in name order) that map and do not exclude the project-relative path `rel`.
---@param remotes passaporta.Remote[]
---@param rel string
---@return passaporta.Candidate[]
---@return string|nil reason set when the list is empty
function M.candidates(remotes, rel)
  ---@type passaporta.Candidate[]
  local result = {}
  local reason
  for _, remote in ipairs(remotes) do
    local rule = excluding_rule(remote, rel)
    if rule then
      reason = ("excluded on %s by rule: %s"):format(remote.name, rule)
    else
      local mapping = best_mapping(remote, rel)
      local remote_path = mapping and paths.join_remote(mapping, rel)
      if mapping and remote_path then
        table.insert(result, { remote = remote, mapping = mapping, remote_path = remote_path })
      end
    end
  end
  if #result == 0 then
    return result, reason or ("'%s' is not mapped in deployment config"):format(rel)
  end
  return result, nil
end

---Exclude patterns of `remote` relative to the directory `rel_dir`. Floating globs (no "/", or a "**/"
---prefix) pass through; path rules and anchored globs are rebased (and dropped when outside or equal to
---the directory); non-glob directories get a trailing "/".
---@param remote passaporta.Remote
---@param rel_dir string project-relative directory, "" for the project root
---@param is_dir fun(rel: string): boolean receives the rebased rule
---@return string[]
function M.excludes_for_dir(remote, rel_dir, is_dir)
  local dir = rel_dir:gsub("/+$", "")
  ---@type string[]
  local result = {}
  for _, rule in ipairs(remote.excludedPaths) do
    local is_glob = glob.is_glob(rule)
    if is_glob and (not rule:find("/", 1, true) or vim.startswith(rule, "**/")) then
      table.insert(result, rule)
    elseif is_glob then
      if dir == "" then
        table.insert(result, rule)
      elseif vim.startswith(rule, dir .. "/") and #rule > #dir + 1 then
        table.insert(result, rule:sub(#dir + 2))
      end
    else
      local bare = rule:gsub("/+$", "")
      local rebased
      if dir == "" then
        rebased = bare
      elseif bare:sub(1, #dir + 1) == dir .. "/" then
        rebased = bare:sub(#dir + 2)
      end
      if rebased and rebased ~= "" then
        table.insert(result, is_dir(rebased) and rebased .. "/" or rebased)
      end
    end
  end
  return result
end

return M
