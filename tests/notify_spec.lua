local config = require "passaporta.config"
local notify = require "passaporta.notify"

describe("notify.redact", function()
  it("replaces every occurrence of every secret", function()
    assert.are.equal("a *** b *** c ***", notify.redact("a pw1 b pw1 c tok", { "pw1", "tok" }))
  end)

  it("leaves text without secrets untouched", function()
    assert.are.equal("nothing here", notify.redact("nothing here", { "pw" }))
  end)

  it("treats secrets as plain text, not patterns", function()
    assert.are.equal("x *** y", notify.redact("x a.b%1 y", { "a.b%1" }))
    assert.are.equal("axb", notify.redact("axb", { "a.b" }))
  end)

  it("ignores empty and nil secrets", function()
    assert.are.equal("abc", notify.redact("abc", { "", nil }))
    assert.are.equal("abc", notify.redact("abc", nil))
  end)

  it("redacts a longer secret that contains a shorter one fully", function()
    assert.are.equal("***", notify.redact("secret123", { "secret", "secret123" }))
  end)
end)

describe("notify levels", function()
  local calls
  local original

  before_each(function()
    calls = {}
    original = config.options.notify
    config.options.notify = function(msg, level, opts)
      calls[#calls + 1] = { msg = msg, level = level, opts = opts }
      return "handle"
    end
  end)

  after_each(function()
    config.options.notify = original
  end)

  it("info prefixes the remote name and sets the title", function()
    notify.info("done", "staging")
    assert.are.equal("[staging] done", calls[1].msg)
    assert.are.equal(vim.log.levels.INFO, calls[1].level)
    assert.are.equal("Passaporta", calls[1].opts.title)
  end)

  it("omits the prefix without a remote name", function()
    notify.warn "careful"
    assert.are.equal("careful", calls[1].msg)
    assert.are.equal(vim.log.levels.WARN, calls[1].level)
  end)

  it("error uses the error level and keeps the title over caller opts", function()
    notify.error("bad", "prod", { title = "Other", timeout = 5 })
    assert.are.equal(vim.log.levels.ERROR, calls[1].level)
    assert.are.equal("Passaporta", calls[1].opts.title)
    assert.are.equal(5, calls[1].opts.timeout)
  end)

  it("progress returns the notifier handle", function()
    assert.are.equal("handle", notify.progress("working", "staging"))
    assert.are.equal("[staging] working", calls[1].msg)
  end)
end)
