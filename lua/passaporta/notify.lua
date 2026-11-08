--- User-facing notifications. Every message carries the "Passaporta" title and,
--- when a remote is involved, a "[<remote>] " prefix.
local config = require "passaporta.config"

local M = {}

local TITLE = "Passaporta"

---Replace every occurrence of every secret with "***" (plain text, longest secret first).
---@param text string
---@param secrets? string[]
---@return string
function M.redact(text, secrets)
  local list = {}
  for i = 1, #(secrets or {}) do
    local s = secrets[i]
    if type(s) == "string" and s ~= "" then
      list[#list + 1] = s
    end
  end
  table.sort(list, function(a, b)
    return #a > #b
  end)
  for _, secret in ipairs(list) do
    local out, pos = {}, 1
    while true do
      local s, e = text:find(secret, pos, true)
      if not s then
        break
      end
      out[#out + 1] = text:sub(pos, s - 1)
      out[#out + 1] = "***"
      pos = e + 1
    end
    out[#out + 1] = text:sub(pos)
    text = table.concat(out)
  end
  return text
end

---@param level integer
---@param msg string
---@param remote_name? string
---@param opts? table
---@return any
local function send(level, msg, remote_name, opts)
  if remote_name then
    msg = "[" .. remote_name .. "] " .. msg
  end
  local notifier = config.options.notify or vim.notify
  return notifier(msg, level, vim.tbl_extend("force", opts or {}, { title = TITLE }))
end

---@param msg string
---@param remote_name? string
---@param opts? table
---@return any
function M.info(msg, remote_name, opts)
  return send(vim.log.levels.INFO, msg, remote_name, opts)
end

---@param msg string
---@param remote_name? string
---@param opts? table
---@return any
function M.warn(msg, remote_name, opts)
  return send(vim.log.levels.WARN, msg, remote_name, opts)
end

---@param msg string
---@param remote_name? string
---@param opts? table
---@return any
function M.error(msg, remote_name, opts)
  return send(vim.log.levels.ERROR, msg, remote_name, opts)
end

---Sticky progress notification. Pass `{ replace = handle }` to update a previous one.
---@param msg string
---@param remote_name? string
---@param opts? table
---@return any handle
function M.progress(msg, remote_name, opts)
  return send(vim.log.levels.INFO, msg, remote_name, vim.tbl_extend("force", { timeout = 0 }, opts or {}))
end

return M
