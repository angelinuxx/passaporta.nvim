--- The `:Passaporta` command and the actions shared with the public Lua API.
local config = require "passaporta.config"
local deployment = require "passaporta.deployment"
local notify = require "passaporta.notify"
local ops = require "passaporta.ops"
local secrets = require "passaporta.secrets"
local state = require "passaporta.state"

---@class passaporta.ParsedCommand
---@field sub string
---@field arg? string path, remote name or "clear"
---@field bang boolean

local M = {}

local SUBCOMMANDS = { "upload", "download", "syncup", "syncdown", "diff", "remote", "repeat", "init", "forget" }
local TRANSFER = { upload = true, download = true, syncup = true, syncdown = true }
local PATH_SUBS = { upload = true, download = true, syncup = true, syncdown = true, diff = true }

---@return string
local function root()
  return vim.uv.cwd() or ""
end

---Parse the arguments of `:Passaporta`.
---@param fargs string[]
---@param bang boolean
---@return passaporta.ParsedCommand|nil
---@return string|nil err
function M.parse(fargs, bang)
  local sub = fargs[1]
  if not sub then
    return nil, "missing subcommand (" .. table.concat(SUBCOMMANDS, ", ") .. ")"
  end
  if not vim.list_contains(SUBCOMMANDS, sub) then
    return nil, ("unknown subcommand '%s'"):format(sub)
  end
  return { sub = sub, arg = fargs[2], bang = bang }, nil
end

---Absolute path of `path`, or of the current buffer's file when empty.
---@param path? string
---@return string "" when there is no path and no file buffer
local function absolute(path)
  if path and path ~= "" then
    return vim.fn.fnamemodify(path, ":p")
  end
  return vim.fn.expand "%:p"
end

---Remote names of the current project, sorted. Notifies and returns nil on a load error.
---@return string[]|nil
local function remote_names()
  local remotes, err = deployment.load(root())
  if not remotes then
    notify.error(err or "invalid deployment config")
    return nil
  end
  return vim.tbl_map(function(r)
    return r.name
  end, remotes)
end

---Run a transfer and remember it for `repeat`.
---@param sub passaporta.TransferOp
---@param path? string
---@param opts? passaporta.OpOpts
function M.transfer(sub, path, opts)
  local abs = absolute(path)
  if abs ~= "" then
    state.set_last(root(), { sub = sub, path = abs, bang = (opts and opts.force_pick) == true })
  end
  ops.transfer(sub, abs ~= "" and abs or nil, opts)
end

---@param name string
function M.set_remote(name)
  local names = remote_names()
  if not names then
    return
  end
  if not vim.list_contains(names, name) then
    notify.error(("unknown remote '%s'"):format(name))
    return
  end
  state.set_active(root(), name)
  notify.info("active remote: " .. name, name)
end

function M.pick_remote()
  local names = remote_names()
  if not names then
    return
  end
  vim.ui.select(names, { prompt = "Passaporta: choose active remote" }, function(choice)
    if choice then
      state.set_active(root(), choice)
      notify.info("active remote: " .. choice, choice)
    end
  end)
end

function M.clear_remote()
  state.set_active(root(), nil)
  notify.info "active remote cleared"
end

function M.repeat_last()
  local last = state.get_last(root())
  if not last then
    notify.warn "nothing to repeat"
    return
  end
  ops.transfer(last.sub, last.path, { force_pick = last.bang })
end

function M.forget_passwords()
  local n = secrets.forget(root())
  notify.info(("dropped %d cached password(s)"):format(n))
end

---Open the project config, creating it from the template when missing.
function M.init()
  local path = root() .. "/" .. config.options.config_file
  if not vim.uv.fs_stat(path) then
    local template = config.options.config_template
    if type(template) == "function" then
      template = template()
    end
    local lines = template
    if type(template) == "string" then
      lines = vim.split(template, "\n", { plain = true })
      if lines[#lines] == "" then
        lines[#lines] = nil -- writefile() ends every line with a newline
      end
    end
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

---Neovim command callback.
---@param cmd_opts { fargs: string[], bang: boolean }
function M.run(cmd_opts)
  local cmd, err = M.parse(cmd_opts.fargs, cmd_opts.bang)
  if not cmd then
    notify.error(err or "invalid command")
    return
  end
  local sub, arg = cmd.sub, cmd.arg
  if TRANSFER[sub] then
    M.transfer(sub, arg, { force_pick = cmd.bang })
  elseif sub == "diff" then
    ops.diff(arg, { force_pick = cmd.bang })
  elseif sub == "remote" then
    if arg == "clear" then
      M.clear_remote()
    elseif arg then
      M.set_remote(arg)
    else
      M.pick_remote()
    end
  elseif sub == "repeat" then
    M.repeat_last()
  elseif sub == "init" then
    M.init()
  elseif sub == "forget" then
    M.forget_passwords()
  end
end

---@param items string[]
---@param lead string
---@return string[]
local function matching(items, lead)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, lead)
  end, items)
end

---Command-line completion.
---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  local args = vim.split(vim.trim(cmdline:sub(1, cursorpos)), "%s+", { trimempty = true })
  table.remove(args, 1) -- the command name
  if arglead ~= "" then
    table.remove(args)
  end
  if #args == 0 then
    return matching(SUBCOMMANDS, arglead)
  end
  if #args > 1 then
    return {}
  end
  if args[1] == "remote" then
    local remotes = deployment.load(root())
    local names = vim.tbl_map(function(r)
      return r.name
    end, remotes or {})
    names[#names + 1] = "clear"
    return matching(names, arglead)
  end
  if PATH_SUBS[args[1]] then
    return vim.fn.getcompletion(arglead, "file")
  end
  return {}
end

return M
