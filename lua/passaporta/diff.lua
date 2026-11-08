--- Diff rendering: quickfix list for directory diffs, diffsplit for single files.
local config = require "passaporta.config"

local M = {}

local counter = 0

local STATUS_LETTER = { new = "A", modified = "M", deleted = "D" }

---@param entries passaporta.DiffEntry[]
---@param local_dir string
---@return table[]
function M.quickfix_items(entries, local_dir)
  local items = {}
  for _, entry in ipairs(entries) do
    local item = { text = "[" .. (STATUS_LETTER[entry.status] or "?") .. "] " .. entry.path }
    if entry.status == "deleted" or entry.path:sub(-1) == "/" then
      item.valid = 0
    else
      item.filename = local_dir .. "/" .. entry.path
    end
    items[#items + 1] = item
  end
  return items
end

---@param local_rel string
---@param remote passaporta.Remote
---@param remote_path string
---@param cmdline string already redacted
---@return table[]
function M.header_items(local_rel, remote, remote_path, cmdline)
  return {
    { text = "Local:  " .. local_rel, valid = 0 },
    { text = ("Remote: %s (%s:%s)"):format(remote.name, remote.host, remote_path), valid = 0 },
    { text = "Command: " .. cmdline, valid = 0 },
  }
end

---@param header table[]
---@param entries passaporta.DiffEntry[]
---@param local_dir string
---@param local_rel? string used in the list title, defaults to `local_dir`
function M.show_dir(header, entries, local_dir, local_rel)
  local items = vim.list_extend(vim.deepcopy(header), M.quickfix_items(entries, local_dir))
  vim.fn.setqflist({}, "r", { title = "Passaporta diff: " .. (local_rel or local_dir), items = items })
  vim.cmd "copen"
end

---@param local_path string
---@return string
function M.temp_path(local_path)
  local dir = vim.fn.stdpath "cache" .. "/passaporta"
  vim.fn.mkdir(dir, "p")
  counter = counter + 1
  return ("%s/%d-%d-%s"):format(dir, vim.uv.os_getpid(), counter, vim.fn.fnamemodify(local_path, ":t"))
end

---Open `temp_path` (the downloaded remote file) in a vertical diffsplit against `local_path`.
---@param local_path string
---@param temp_path string
---@param remote_name string
function M.open_file(local_path, temp_path, remote_name)
  vim.cmd("silent! edit " .. vim.fn.fnameescape(local_path))
  local local_win = vim.api.nvim_get_current_win()
  local local_buf = vim.api.nvim_get_current_buf()
  vim.cmd("silent vertical diffsplit " .. vim.fn.fnameescape(temp_path))
  local remote_buf = vim.api.nvim_get_current_buf()
  local remote_win = vim.api.nvim_get_current_win()

  vim.bo[remote_buf].readonly = true
  vim.bo[remote_buf].buflisted = false
  vim.bo[remote_buf].bufhidden = "wipe"

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = remote_buf,
    once = true,
    callback = function()
      vim.uv.fs_unlink(temp_path)
    end,
  })

  local mapping = config.options.close_diff_mapping
  if mapping then
    local function close()
      if vim.api.nvim_win_is_valid(local_win) then
        vim.api.nvim_win_call(local_win, function()
          vim.cmd "diffoff"
        end)
      end
      if vim.api.nvim_win_is_valid(remote_win) then
        vim.api.nvim_win_call(remote_win, function()
          vim.cmd "diffoff"
        end)
        vim.api.nvim_win_close(remote_win, true)
      end
      if vim.api.nvim_buf_is_valid(remote_buf) then
        vim.api.nvim_buf_delete(remote_buf, { force = true })
      end
      if vim.api.nvim_win_is_valid(local_win) then
        vim.api.nvim_set_current_win(local_win)
      end
    end
    for _, buf in ipairs { remote_buf, local_buf } do
      vim.keymap.set("n", mapping, close, { buffer = buf, desc = "Close Passaporta diff (" .. remote_name .. ")" })
    end
  end
end

return M
