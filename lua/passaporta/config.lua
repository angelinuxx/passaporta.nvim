local M = {}

---@class passaporta.RsyncOptions
---@field upload_params string[] Extra rsync params for uploads.
---@field download_params string[] Extra rsync params for downloads.

---@class passaporta.LftpOptions
---@field settings table<string, string|number|boolean> Extra `set` settings applied to every lftp session.
---@field mirror_params string[] Extra params for `mirror` commands.
---@field parallel integer Files transferred in parallel by directory operations (1 disables).

---@class passaporta.Options
---@field config_file string Project config path, relative to the project root.
---@field config_template string Content written when creating a new project config.
---@field excludes string[] Patterns excluded from every directory operation.
---@field rsync passaporta.RsyncOptions
---@field lftp passaporta.LftpOptions
---@field timeout_ms integer Total timeout for file operations.
---@field idle_timeout_ms integer Idle timeout for directory operations.
---@field close_diff_mapping string Mapping that closes a diff view.
---@field notify? fun(msg: string, level: integer, opts: table) Custom notifier, defaults to `vim.notify`.

local config_template = [[
return {
  staging = {
    host = "myhost", -- ssh alias from ~/.ssh/config, or hostname
    username = "web", -- optional
    port = 22, -- optional
    protocol = "ssh", -- "ssh" (default) | "sftp"
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/staging" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
  },
  -- shared_hosting = {
  --   host = "ftp.example.com",
  --   username = "u12345",
  --   protocol = "sftp",
  --   password = true, -- true | "string" | function(): string
  --   mappings = {
  --     { ["local"] = ".", ["remote"] = "/public_html" },
  --   },
  -- },
}
]]

---@type passaporta.Options
M.defaults = {
  config_file = ".nvim/deployment.lua",
  config_template = config_template,
  excludes = { ".git", ".nvim", ".idea", ".DS_Store", "*.pyc" },
  rsync = {
    upload_params = { "-rlzi", "--checksum" },
    download_params = { "-rlzi", "--checksum" },
  },
  lftp = {
    settings = {},
    mirror_params = { "--no-perms" },
    parallel = 4,
  },
  timeout_ms = 120000,
  idle_timeout_ms = 60000,
  close_diff_mapping = "<leader>b",
  notify = nil,
}

---@type passaporta.Options
M.options = vim.deepcopy(M.defaults)

---Merge user options over the defaults.
---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
