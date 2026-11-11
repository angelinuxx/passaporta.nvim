local health = require "passaporta.health"
-- preload modules: a single-file `PlenaryBustedFile` run starts the child nvim with a relative
-- runtimepath (`set rtp+=.`), which breaks once the specs chdir (`make test` passes an absolute one)
require "passaporta.deployment"

describe("passaporta.health versions", function()
  it("parses the first version number", function()
    assert.same({ 3, 2, 7 }, health.parse_version "rsync  version 3.2.7  protocol version 31")
    assert.same({ 4, 9, 2 }, health.parse_version "LFTP | Version 4.9.2 | Copyright")
    assert.same({ 9, 6 }, health.parse_version "OpenSSH_9.6p1 Ubuntu-3, OpenSSL 3.0.13")
    assert.is_nil(health.parse_version "nothing here")
  end)

  it("compares numerically per component", function()
    assert.is_true(health.version_lt({ 3, 2, 3 }, { 3, 2, 10 }))
    assert.is_false(health.version_lt({ 3, 2, 10 }, { 3, 2, 3 }))
    assert.is_false(health.version_lt({ 4, 9, 2 }, { 4, 9 }))
    assert.is_false(health.version_lt({ 4, 9 }, { 4, 9, 0 }))
    assert.is_true(health.version_lt({ 3, 1, 9 }, { 3, 2, 3 }))
  end)
end)

describe("passaporta.health check", function()
  local calls, orig_health, orig_cwd, dir

  ---@param config? string
  local function project(config)
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.nvim", "p")
    if config then
      vim.fn.writefile(vim.split(config, "\n"), dir .. "/.nvim/deployment.lua")
    end
    vim.uv.chdir(dir)
  end

  local function has(kind, pattern)
    for _, c in ipairs(calls) do
      if c.kind == kind and c.msg:find(pattern, 1, true) then
        return true
      end
    end
    return false
  end

  before_each(function()
    calls = {}
    orig_cwd = vim.uv.cwd()
    orig_health = vim.health
    local function rec(kind)
      return function(msg)
        calls[#calls + 1] = { kind = kind, msg = msg }
      end
    end
    vim.health = { start = rec "start", ok = rec "ok", warn = rec "warn", error = rec "error", info = rec "info" }
    require("passaporta.config").setup()
  end)

  after_each(function()
    vim.health = orig_health
    vim.uv.chdir(orig_cwd)
  end)

  it("reports a project without config", function()
    project()
    health.check()
    assert.is_true(has("ok", "Neovim"))
    assert.is_true(has("info", "no deployment config"))
    assert.is_true(has("info", "known_hosts"))
  end)

  it("lists remotes, warns on plain passwords and ignored fields", function()
    project [[return {
      alpha = { host = "a.example", mappings = { { ["local"] = ".", remote = "/a" } } },
      beta = {
        host = "b.example", username = "u", protocol = "sftp", password = "hunter2", upload_on_save = true,
        mappings = { { ["local"] = ".", remote = "/b" } },
      },
    }]]
    health.check()
    assert.is_true(has("ok", "alpha: ssh a.example"))
    assert.is_true(has("ok", "beta: sftp b.example"))
    assert.is_true(has("warn", "beta: password stored in plain text in deployment config"))
    assert.is_true(has("warn", "beta: upload_on_save"))
    for _, c in ipairs(calls) do
      assert.is_nil(c.msg:find("hunter2", 1, true))
    end
  end)

  it("errors on remotes whose backend tool is missing", function()
    project [[return { beta = { host = "b.example", protocol = "sftp", mappings = { { remote = "/b" } } } }]]
    local orig = vim.fn.executable
    vim.fn.executable = function(cmd)
      return cmd == "lftp" and 0 or orig(cmd)
    end
    health.check()
    vim.fn.executable = orig
    assert.is_true(has("warn", "lftp"))
    assert.is_true(has("error", "beta: sftp b.example"))
  end)

  it("requires ssh for sftp remotes", function()
    project [[return { beta = { host = "b.example", protocol = "sftp", mappings = { { remote = "/b" } } } }]]
    local orig = vim.fn.executable
    vim.fn.executable = function(cmd)
      return cmd == "ssh" and 0 or orig(cmd)
    end
    health.check()
    vim.fn.executable = orig
    assert.is_true(has("error", "beta: sftp b.example (missing: ssh)"))
  end)

  it("reports load errors", function()
    project [[return { bad = { host = "h", password = "x", mappings = { { remote = "/b" } } } }]]
    health.check()
    assert.is_true(has("error", "password auth is only supported"))
  end)
end)
