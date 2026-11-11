local deployment = require "passaporta.deployment"
local config = require "passaporta.config"

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fixtures/deployment"

---@param name string
---@return table
local function raw_remote(name, overrides)
  local r = { host = "h", mappings = { { ["local"] = ".", remote = "/srv" } } }
  return vim.tbl_extend("force", r, overrides or {})
end

describe("deployment.normalize", function()
  it("returns remotes sorted by name with defaults applied", function()
    local remotes, errors, warnings =
      deployment.normalize { zeta = raw_remote(), alpha = raw_remote(), mid = raw_remote() }
    assert.are.same({}, errors)
    assert.are.same({}, warnings)
    assert.are.same(
      { "alpha", "mid", "zeta" },
      vim.tbl_map(function(r)
        return r.name
      end, remotes)
    )
    assert.are.equal("ssh", remotes[1].protocol)
    assert.are.same({}, remotes[1].excludedPaths)
  end)

  it("normalises mappings: local path, trailing slash on remote", function()
    local remotes = deployment.normalize {
      a = raw_remote("a", {
        mappings = {
          { ["local"] = "./src/", remote = "/var/www/" },
          { ["local"] = "/", remote = "/" },
          { remote = "rel/home/" },
        },
      }),
    }
    local m = remotes[1].mappings
    assert.are.same({ ["local"] = "src", remote = "/var/www" }, m[1])
    assert.are.same({ ["local"] = "", remote = "/" }, m[2])
    assert.are.same({ ["local"] = "", remote = "rel/home" }, m[3])
  end)

  it("keeps optional fields", function()
    local fn = function()
      return "x"
    end
    local remotes = deployment.normalize {
      a = raw_remote("a", { username = "u", port = 2222, protocol = "sftp", password = fn, excludedPaths = { "x" } }),
    }
    assert.are.equal("u", remotes[1].username)
    assert.are.equal(2222, remotes[1].port)
    assert.are.equal("sftp", remotes[1].protocol)
    assert.are.equal(fn, remotes[1].password)
    assert.are.same({ "x" }, remotes[1].excludedPaths)
  end)

  local function errors_of(overrides)
    local remotes, errors = deployment.normalize { a = raw_remote("a", overrides) }
    assert.is_nil(remotes)
    return errors
  end

  it("rejects a missing or non-string host", function()
    assert.are.same({ "a: host is required and must be a string" }, errors_of { host = vim.NIL })
    assert.are.same({ "a: host is required and must be a string" }, errors_of { host = 5 })
  end)

  it("rejects missing or empty mappings", function()
    assert.are.same({ "a: mappings must be a non-empty list" }, errors_of { mappings = {} })
    assert.are.same({ "a: mappings must be a non-empty list" }, errors_of { mappings = "x" })
  end)

  it("rejects a mapping without a remote", function()
    assert.are.same(
      { "a: mapping 2 has no remote" },
      errors_of {
        mappings = { { ["local"] = ".", remote = "/a" }, { ["local"] = "x" } },
      }
    )
  end)

  it("rejects an empty remote", function()
    assert.are.same(
      { "a: mapping 1 has an empty remote" },
      errors_of { mappings = { { ["local"] = ".", remote = "" } } }
    )
    assert.are.same(
      { "a: mapping 2 has an empty remote" },
      errors_of { mappings = { { ["local"] = "x", remote = "/a" }, { ["local"] = ".", remote = "" } } }
    )
  end)

  it("collapses a remote made only of slashes to the root", function()
    local remotes = deployment.normalize {
      a = raw_remote("a", { mappings = { { remote = "//" }, { ["local"] = "x", remote = "///" } } }),
    }
    assert.are.same({ ["local"] = "", remote = "/" }, remotes[1].mappings[1])
    assert.are.same({ ["local"] = "x", remote = "/" }, remotes[1].mappings[2])
  end)

  it("rejects an unknown protocol", function()
    assert.are.same({ "a: protocol must be 'ssh' or 'sftp'" }, errors_of { protocol = "ftp" })
  end)

  it("rejects password without sftp", function()
    local msg = "a: password auth is only supported with protocol = 'sftp'"
    assert.are.same({ msg }, errors_of { password = "s" })
    assert.are.same({ msg }, errors_of { password = true, protocol = "ssh" })
  end)

  it("rejects an invalid password type", function()
    assert.are.same(
      { "a: password must be true, a string or a function" },
      errors_of { protocol = "sftp", password = 5 }
    )
    assert.are.same(
      { "a: password must be true, a string or a function" },
      errors_of { protocol = "sftp", password = false }
    )
  end)

  it("rejects password without username", function()
    local msg = "a: password requires username"
    assert.are.same({ msg }, errors_of { protocol = "sftp", password = true })
    assert.are.same({ msg }, errors_of { protocol = "sftp", password = "s", username = "" })
  end)

  it("rejects an invalid port", function()
    local msg = "a: port must be a positive integer"
    assert.are.same({ msg }, errors_of { port = 0 })
    assert.are.same({ msg }, errors_of { port = 22.5 })
    assert.are.same({ msg }, errors_of { port = "22" })
  end)

  it("collects errors in sorted-name order", function()
    local remotes, errors = deployment.normalize {
      zeta = raw_remote("zeta", { protocol = "x" }),
      alpha = raw_remote("alpha", { port = -1 }),
    }
    assert.is_nil(remotes)
    assert.are.same({ "alpha: port must be a positive integer", "zeta: protocol must be 'ssh' or 'sftp'" }, errors)
  end)

  it("warns about upload_on_save", function()
    local remotes, errors, warnings = deployment.normalize { a = raw_remote("a", { upload_on_save = false }) }
    assert.are.same({}, errors)
    assert.is_not_nil(remotes)
    assert.are.same({ "a: upload_on_save is not supported and will be ignored" }, warnings)
  end)

  it("rejects a non-table config", function()
    local remotes, errors = deployment.normalize "oops"
    assert.is_nil(remotes)
    assert.are.same({ "deployment config must return a table of remotes" }, errors)
  end)
end)

describe("deployment.load", function()
  before_each(function()
    config.setup {}
  end)

  it("reports a missing file", function()
    local remotes, err, warnings = deployment.load(fixtures .. "/..")
    assert.is_nil(remotes)
    assert.are.equal("no deployment config at " .. fixtures .. "/../.nvim/deployment.lua", err)
    assert.are.same({}, warnings)
  end)

  local function load_fixture(name)
    config.setup { config_file = "deployment/" .. name .. ".lua" }
    return deployment.load(vim.fn.fnamemodify(fixtures, ":h"))
  end

  it("reads the configured file and normalises it", function()
    local remotes, err = load_fixture "valid"
    assert.is_nil(err)
    assert.are.same({ "production", "staging" }, { remotes[1].name, remotes[2].name })
    assert.are.same({ ["local"] = "src", remote = "/var/www/staging" }, remotes[2].mappings[1])
    assert.are.equal("sftp", remotes[1].protocol)
  end)

  it("reports password on ssh", function()
    local remotes, err = load_fixture "password_on_ssh"
    assert.is_nil(remotes)
    assert.are.equal("staging: password auth is only supported with protocol = 'sftp'", err)
  end)

  it("reports missing mappings", function()
    local remotes, err = load_fixture "missing_mappings"
    assert.is_nil(remotes)
    assert.are.equal("staging: mappings must be a non-empty list", err)
  end)

  it("loads a transfer.nvim config with zero errors", function()
    local remotes, err, warnings = load_fixture "transfer_compat"
    assert.is_nil(err)
    assert.are.same({ "production", "staging" }, { remotes[1].name, remotes[2].name })
    assert.are.equal("example-host", remotes[1].host)
    assert.are.same({ "vendor", "node_modules", ".env", "**/*.http" }, remotes[2].excludedPaths)
    assert.are.same({ "production: upload_on_save is not supported and will be ignored" }, warnings)
  end)

  it("returns the Lua error when the file fails to load", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.nvim", "p")
    vim.fn.writefile({ "return {" }, dir .. "/.nvim/deployment.lua")
    config.setup {}
    local remotes, err = deployment.load(dir)
    assert.is_nil(remotes)
    assert.is_truthy(err:find("deployment.lua", 1, true))
    vim.fn.delete(dir, "rf")
  end)

  it("joins multiple errors with newlines", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.nvim", "p")
    vim.fn.writefile(
      { "return { a = { host = 1, mappings = {{remote='/x'}} }, b = { mappings = {{remote='/x'}} } }" },
      dir .. "/.nvim/deployment.lua"
    )
    config.setup {}
    local _, err = deployment.load(dir)
    assert.are.equal("a: host is required and must be a string\nb: host is required and must be a string", err)
    vim.fn.delete(dir, "rf")
  end)
end)

describe("deployment.remote_names", function()
  local tmp

  before_each(function()
    config.setup {}
    tmp = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp .. "/.nvim", "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  local function write_config(text)
    vim.fn.writefile({ text }, tmp .. "/.nvim/deployment.lua")
  end

  it("lists the names in sorted order", function()
    write_config 'local m = { { remote = "/x" } } return { b = { host = "h", mappings = m }, a = { host = "h", mappings = m } }'
    assert.are.same({ "a", "b" }, deployment.remote_names(tmp))
  end)

  it("is nil for a missing or invalid config", function()
    assert.is_nil(deployment.remote_names(tmp))
    write_config "return { a = { host = 5 } }"
    assert.is_nil(deployment.remote_names(tmp))
  end)

  it("reads the file again only when it changes", function()
    write_config 'return { a = { host = "h", mappings = { { remote = "/x" } } } }'
    assert.are.same({ "a" }, deployment.remote_names(tmp))
    local loads = 0
    local orig = deployment.load
    deployment.load = function(...)
      loads = loads + 1
      return orig(...)
    end
    assert.are.same({ "a" }, deployment.remote_names(tmp))
    assert.are.equal(0, loads)
    write_config 'return { renamed = { host = "h", mappings = { { remote = "/x" } } } }'
    assert.are.same({ "renamed" }, deployment.remote_names(tmp))
    assert.are.equal(1, loads)
    deployment.load = orig
  end)
end)
