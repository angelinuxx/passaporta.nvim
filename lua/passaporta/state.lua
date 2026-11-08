--- Per-project session state: active remote and last command, keyed by project root.
--- Lives in memory only; nothing is persisted to disk.

---@class passaporta.LastCommand
---@field sub string subcommand name
---@field path string project-relative path the command ran on
---@field bang boolean whether the command was run with "!"

---@class passaporta.State
---@field active table<string,string> project root -> active remote name
---@field last table<string,passaporta.LastCommand> project root -> last command

---@type passaporta.State
local current = { active = {}, last = {} }

local M = {}

---Active remote name of the project `root`.
---@param root string
---@return string|nil
function M.get_active(root)
  return current.active[root]
end

---Set (or with `nil`, clear) the active remote of the project `root`.
---@param root string
---@param name string|nil
function M.set_active(root, name)
  current.active[root] = name
end

---Last command run in the project `root`.
---@param root string
---@return passaporta.LastCommand|nil
function M.get_last(root)
  return current.last[root]
end

---Set (or with `nil`, clear) the last command of the project `root`.
---@param root string
---@param cmd passaporta.LastCommand|nil
function M.set_last(root, cmd)
  current.last[root] = cmd
end

---Empty all session state. Intended for tests.
function M.reset()
  current = { active = {}, last = {} }
end

return M
