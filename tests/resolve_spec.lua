local deployment = require "passaporta.deployment"
local resolve = require "passaporta.resolve"

---@param raw table
---@return passaporta.Remote[]
local function build(raw)
  local remotes, errors = deployment.normalize(raw)
  assert.are.same({}, errors)
  return remotes
end

---@param c passaporta.Candidate[]
---@return string[]
local function names(c)
  return vim.tbl_map(function(x)
    return x.remote.name
  end, c)
end

local remotes = build {
  staging = { host = "s", mappings = { { ["local"] = "", remote = "/var/www/staging" } } },
  production = { host = "p", mappings = { { ["local"] = "", remote = "/var/www/production" } } },
  shared_hosting = {
    host = "h",
    mappings = { { ["local"] = "src/wp-content/themes/x", remote = "/home/u/themes/x" } },
  },
}

describe("resolve.candidates", function()
  it("returns every remote covering the path, in name order", function()
    local c = resolve.candidates(remotes, "app/Http/Kernel.php")
    assert.are.same({ "production", "staging" }, names(c))
    assert.are.equal("/var/www/production/app/Http/Kernel.php", c[1].remote_path)
    assert.are.equal("/var/www/staging/app/Http/Kernel.php", c[2].remote_path)
    assert.are.equal(remotes[1].mappings[1], c[1].mapping)
  end)

  it("includes a remote whose mapping is a prefix of the path", function()
    local c = resolve.candidates(remotes, "src/wp-content/themes/x/style.css")
    assert.are.same({ "production", "shared_hosting", "staging" }, names(c))
    assert.are.equal("/home/u/themes/x/style.css", c[2].remote_path)
  end)

  it("prefers the longest mapping", function()
    local r = build {
      a = {
        host = "a",
        mappings = {
          { ["local"] = "", remote = "/root" },
          { ["local"] = "src/wp-content/themes/x", remote = "/themes/x" },
        },
      },
    }
    local c = resolve.candidates(r, "src/wp-content/themes/x/a.php")
    assert.are.equal(1, #c)
    assert.are.equal("/themes/x/a.php", c[1].remote_path)
    c = resolve.candidates(r, "src/other.php")
    assert.are.equal("/root/src/other.php", c[1].remote_path)
  end)

  it("does not match a sibling sharing a name prefix", function()
    local c, reason = resolve.candidates(remotes, "src/wp-content/themes/xy/a.css")
    assert.are.same({ "production", "staging" }, names(c))
    assert.is_nil(reason)
  end)

  it("mirrors a trailing slash for directories", function()
    local c = resolve.candidates(remotes, "app/")
    assert.are.equal("/var/www/production/app/", c[1].remote_path)
  end)

  it("excludes single files by glob rules", function()
    local r = build {
      staging = {
        host = "s",
        mappings = { { ["local"] = "", remote = "/srv" } },
        excludedPaths = { "**/*.http" },
      },
    }
    local c, reason = resolve.candidates(r, "tests/api.http")
    assert.are.same({}, c)
    assert.are.equal("excluded on staging by rule: **/*.http", reason)
  end)

  it("excludes by path rules, component-wise", function()
    local r = build {
      staging = {
        host = "s",
        mappings = { { ["local"] = "", remote = "/srv" } },
        excludedPaths = { "vendor" },
      },
    }
    local c, reason = resolve.candidates(r, "vendor/autoload.php")
    assert.are.same({}, c)
    assert.are.equal("excluded on staging by rule: vendor", reason)
    assert.are.equal(1, #resolve.candidates(r, "vendors/a.php"))
  end)

  it("keeps non-excluding remotes and still skips excluding ones", function()
    local r = build {
      a = { host = "a", mappings = { { ["local"] = "", remote = "/a" } }, excludedPaths = { "vendor" } },
      b = { host = "b", mappings = { { ["local"] = "", remote = "/b" } } },
    }
    local c, reason = resolve.candidates(r, "vendor/x.php")
    assert.are.same({ "b" }, names(c))
    assert.is_nil(reason)
  end)

  it("reports unmapped paths", function()
    local r = build { a = { host = "a", mappings = { { ["local"] = "src", remote = "/a" } } } }
    local c, reason = resolve.candidates(r, "docs/readme.md")
    assert.are.same({}, c)
    assert.are.equal("'docs/readme.md' is not mapped in deployment config", reason)
  end)
end)

describe("resolve.excludes_for_dir", function()
  local remote = build({
    a = {
      host = "a",
      mappings = { { ["local"] = "", remote = "/a" } },
      excludedPaths = { "resources/js", "resources/mix.lock", "vendor", "**/*.http" },
    },
  })[1]

  it("rebases and marks directory excludes", function()
    local seen = {}
    local ex = resolve.excludes_for_dir(remote, "resources", function(p)
      table.insert(seen, p)
      return p == "js"
    end)
    assert.are.same({ "js/", "mix.lock", "**/*.http" }, ex)
    assert.are.same({ "js", "mix.lock" }, seen)
  end)

  it("passes path rules through at the project root", function()
    local ex = resolve.excludes_for_dir(remote, "", function(p)
      return p == "vendor"
    end)
    assert.are.same({ "resources/js", "resources/mix.lock", "vendor/", "**/*.http" }, ex)
  end)

  it("drops a path rule equal to the directory itself and tolerates a trailing slash", function()
    local ex = resolve.excludes_for_dir(remote, "vendor/", function()
      return false
    end)
    assert.are.same({ "**/*.http" }, ex)
  end)

  it("does not rebase siblings sharing a name prefix", function()
    local ex = resolve.excludes_for_dir(remote, "resource", function()
      return false
    end)
    assert.are.same({ "**/*.http" }, ex)
  end)
end)
