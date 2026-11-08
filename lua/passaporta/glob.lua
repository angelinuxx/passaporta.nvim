---@class passaporta.glob
local M = {}

---Return true if the rule contains glob metacharacters.
---@param rule string
---@return boolean
function M.is_glob(rule)
  return rule:find "[*?%[]" ~= nil
end

---Match a bracket class starting at pattern index `pi` (pointing at `[`).
---@param p string
---@param pi integer
---@param ch string
---@return boolean? matched nil when the class is not terminated
---@return integer? next_pi index after the closing bracket
local function match_class(p, pi, ch)
  local i = pi + 1
  local negate = false
  local c = p:sub(i, i)
  if c == "!" or c == "^" then
    negate = true
    i = i + 1
  end
  local found = false
  local first = true
  while i <= #p do
    c = p:sub(i, i)
    if c == "]" and not first then
      return found ~= negate, i + 1
    end
    first = false
    if p:sub(i + 1, i + 1) == "-" and p:sub(i + 2, i + 2) ~= "]" and i + 2 <= #p then
      local hi = p:sub(i + 2, i + 2)
      if ch >= c and ch <= hi then
        found = true
      end
      i = i + 3
    else
      if ch == c then
        found = true
      end
      i = i + 1
    end
  end
  return nil, nil
end

---Backtracking glob matcher over the whole string.
---@param p string pattern
---@param pi integer
---@param s string subject
---@param si integer
---@return boolean
local function match_from(p, pi, s, si)
  while pi <= #p do
    local c = p:sub(pi, pi)
    if c == "*" then
      if p:sub(pi + 1, pi + 1) == "*" then
        local rest = pi + 2
        if p:sub(rest, rest) == "/" then
          -- `**/` matches zero or more whole directories
          rest = rest + 1
          if match_from(p, rest, s, si) then
            return true
          end
          for k = si, #s do
            if s:sub(k, k) == "/" and match_from(p, rest, s, k + 1) then
              return true
            end
          end
          return false
        end
        for k = si, #s + 1 do
          if match_from(p, rest, s, k) then
            return true
          end
        end
        return false
      end
      for k = si, #s + 1 do
        if match_from(p, pi + 1, s, k) then
          return true
        end
        if s:sub(k, k) == "/" then
          break
        end
      end
      return false
    elseif c == "?" then
      local ch = s:sub(si, si)
      if ch == "" or ch == "/" then
        return false
      end
      pi, si = pi + 1, si + 1
    elseif c == "[" then
      local ch = s:sub(si, si)
      local ok, next_pi = match_class(p, pi, ch)
      if ok == nil then
        -- unterminated class: treat `[` literally
        if ch ~= "[" then
          return false
        end
        pi, si = pi + 1, si + 1
      else
        if ch == "" or ch == "/" or not ok then
          return false
        end
        pi, si = next_pi, si + 1
      end
    else
      if s:sub(si, si) ~= c then
        return false
      end
      pi, si = pi + 1, si + 1
    end
  end
  return si > #s
end

---Match a path against an rsync-style rule.
---Slash-less rules match any single component; rules containing `/` are anchored at the root and match
---the whole path or any ancestor prefix. A trailing `/` restricts the rule to directories: ancestors are
---directories, the path itself only when it ends with `/`.
---@param path string
---@param rule string
---@return boolean
function M.matches(path, rule)
  local dir_only = rule:sub(-1) == "/"
  local core = dir_only and rule:sub(1, -2) or rule
  local path_is_dir = path:sub(-1) == "/"
  local trimmed = path_is_dir and path:sub(1, -2) or path
  local anchored = core:find("/", 1, true) ~= nil
  if core:sub(1, 1) == "/" then
    core = core:sub(2)
  end
  if core == "" or trimmed == "" then
    return false
  end

  local parts = vim.split(trimmed, "/", { plain = true })
  for i = 1, #parts do
    local is_dir = i < #parts or path_is_dir
    if is_dir or not dir_only then
      local subject = anchored and table.concat(parts, "/", 1, i) or parts[i]
      if match_from(core, 1, subject, 1) then
        return true
      end
    end
  end
  return false
end

return M
