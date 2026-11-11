--- Public Lua API of passaporta.nvim.
local M = {}

---@param opts? table
function M.setup(opts)
  require("passaporta.config").setup(opts)
end

---@param sub passaporta.TransferOp
---@return fun(path?: string, opts?: passaporta.OpOpts)
local function transfer(sub)
  return function(path, opts)
    require("passaporta.commands").transfer(sub, path, opts)
  end
end

---Upload a file or directory (default: the current buffer's file).
M.upload = transfer "upload"
---Download a file or directory.
M.download = transfer "download"
---Sync a directory up (deletes remote extras).
M.syncup = transfer "syncup"
---Sync a directory down (deletes local extras).
M.syncdown = transfer "syncdown"

---@param path? string
---@param opts? passaporta.OpOpts
function M.diff(path, opts)
  require("passaporta.ops").diff(path, opts)
end

---@param name string
function M.set_remote(name)
  require("passaporta.commands").set_remote(name)
end

function M.pick_remote()
  require("passaporta.commands").pick_remote()
end

function M.clear_remote()
  require("passaporta.commands").clear_remote()
end

---Remote the next operation of the current project goes to: the one chosen explicitly, or the only
---configured remote. Nil when several remotes are configured and none is chosen.
---@return string|nil
function M.active_remote()
  local root = vim.uv.cwd() or ""
  local active = require("passaporta.state").get_active(root)
  if active then
    return active
  end
  local names = require("passaporta.deployment").remote_names(root)
  if names and #names == 1 then
    return names[1]
  end
  return nil
end

function M.repeat_last()
  require("passaporta.commands").repeat_last()
end

function M.forget_passwords()
  require("passaporta.commands").forget_passwords()
end

return M
