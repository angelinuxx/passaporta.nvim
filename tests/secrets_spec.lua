local secrets = require "passaporta.secrets"

describe("secrets", function()
  local orig_prompt = secrets.prompt
  local calls, answer, last_text

  before_each(function()
    secrets.reset()
    calls, answer, last_text = 0, "hunter2", nil
    secrets.prompt = function(text)
      calls = calls + 1
      last_text = text
      return answer
    end
  end)

  after_each(function()
    secrets.prompt = orig_prompt
    secrets.reset()
  end)

  local function remote(extra)
    return vim.tbl_extend(
      "force",
      { name = "prod", host = "example.com", protocol = "sftp", mappings = {} },
      extra or {}
    )
  end

  it("returns nil, nil when no password is configured", function()
    local pw, err = secrets.get("/p", remote())
    assert.is_nil(pw)
    assert.is_nil(err)
    assert.are.equal(0, calls)
  end)

  it("prompts once for true and caches the answer", function()
    assert.are.equal("hunter2", (secrets.get("/p", remote { password = true })))
    assert.are.equal("hunter2", (secrets.get("/p", remote { password = true })))
    assert.are.equal(1, calls)
  end)

  it("builds the prompt text with and without username", function()
    secrets.get("/p", remote { password = true, username = "bob" })
    assert.are.equal("Password for prod (bob@example.com): ", last_text)
    secrets.reset()
    secrets.get("/p", remote { password = true })
    assert.are.equal("Password for prod (example.com): ", last_text)
  end)

  it("errors on empty or cancelled prompt and does not cache", function()
    answer = ""
    local pw, err = secrets.get("/p", remote { password = true })
    assert.is_nil(pw)
    assert.are.equal("no password entered", err)
    answer = nil
    _, err = secrets.get("/p", remote { password = true })
    assert.are.equal("no password entered", err)
    assert.are.equal(2, calls)
  end)

  it("returns and caches a string password", function()
    assert.are.equal("s3", (secrets.get("/p", remote { password = "s3" })))
    assert.are.equal("s3", (secrets.get("/p", remote { password = "other" })))
  end)

  it("calls a function once and caches its result", function()
    local n = 0
    local r = remote {
      password = function()
        n = n + 1
        return "fromfn"
      end,
    }
    assert.are.equal("fromfn", (secrets.get("/p", r)))
    assert.are.equal("fromfn", (secrets.get("/p", r)))
    assert.are.equal(1, n)
  end)

  it("reports a failing function", function()
    local pw, err = secrets.get(
      "/p",
      remote {
        password = function()
          error("boom", 0)
        end,
      }
    )
    assert.is_nil(pw)
    assert.are.equal("password function on prod failed: boom", err)
  end)

  it("reports a non-string function result", function()
    local pw, err = secrets.get(
      "/p",
      remote {
        password = function()
          return 42
        end,
      }
    )
    assert.is_nil(pw)
    assert.are.equal("password function on prod must return a string", err)
  end)

  it("keys the cache by root and remote name", function()
    secrets.get("/a", remote { password = true })
    secrets.get("/b", remote { password = true })
    secrets.get("/a", remote { password = true, name = "dev" })
    assert.are.equal(3, calls)
  end)

  it("invalidate forces a re-prompt for that remote only", function()
    secrets.get("/p", remote { password = true })
    secrets.get("/p", remote { password = true, name = "dev" })
    secrets.invalidate("/p", "prod")
    secrets.get("/p", remote { password = true })
    secrets.get("/p", remote { password = true, name = "dev" })
    assert.are.equal(3, calls)
  end)

  it("invalidate on an unknown root is a no-op", function()
    secrets.invalidate("/nope", "prod")
  end)

  it("forget drops only one root and returns the count", function()
    secrets.get("/a", remote { password = true })
    secrets.get("/a", remote { password = true, name = "dev" })
    secrets.get("/b", remote { password = true })
    assert.are.equal(2, secrets.forget "/a")
    assert.are.equal(0, secrets.forget "/a")
    secrets.get("/b", remote { password = true })
    assert.are.equal(3, calls)
  end)
end)
