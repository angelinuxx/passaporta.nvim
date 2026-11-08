local runner = require "passaporta.runner"

---@param cmd string[]
---@param opts? passaporta.RunOpts
---@param stdin? string
---@return passaporta.RunResult, integer
local function run(cmd, opts, stdin)
  local result, calls = nil, 0
  runner.run({ cmd = cmd, stdin = stdin, secrets = {} }, opts or {}, function(r)
    calls = calls + 1
    result = r
  end)
  assert(vim.wait(8000, function()
    return result ~= nil
  end, 20))
  vim.wait(100)
  return result, calls
end

describe("runner", function()
  it("captures stdout lines and exit code", function()
    local r, calls = run { "echo", "hi" }
    assert.equals(0, r.code)
    assert.same({ "hi" }, r.stdout)
    assert.same({}, r.stderr)
    assert.is_false(r.timed_out)
    assert.equals(1, calls)
  end)

  it("writes stdin", function()
    local r = run({ "cat" }, nil, "a\nb\n")
    assert.same({ "a", "b" }, r.stdout)
  end)

  it("keeps a final line without trailing newline and captures stderr", function()
    local r = run { "sh", "-c", "printf 'a\\nb'; echo err >&2" }
    assert.same({ "a", "b" }, r.stdout)
    assert.same({ "err" }, r.stderr)
  end)

  it("reassembles lines split across chunks", function()
    local r = run { "sh", "-c", "printf 'hel'; sleep 0.2; printf 'lo\\nwor'; sleep 0.2; printf 'ld\\n'" }
    assert.same({ "hello", "world" }, r.stdout)
  end)

  it("returns the exit code", function()
    local r = run { "sh", "-c", "exit 3" }
    assert.equals(3, r.code)
    assert.is_false(r.timed_out)
  end)

  it("does not flag a legitimate exit 124 as timed out", function()
    local r = run { "sh", "-c", "exit 124" }
    assert.equals(124, r.code)
    assert.is_false(r.timed_out)
  end)

  it("honours the total timeout", function()
    local r = run({ "sleep", "5" }, { timeout_ms = 200 })
    assert.is_true(r.timed_out)
    assert.is_not.equals(0, r.code)
  end)

  it("honours the idle timeout and keeps output", function()
    local r = run({ "sh", "-c", "echo x; sleep 0.3; echo y; sleep 5" }, { idle_timeout_ms = 1000 })
    assert.is_true(r.timed_out)
    assert.same({ "x", "y" }, r.stdout)
  end)

  it("resets the idle timer on output", function()
    local r = run({ "sh", "-c", "for i in 1 2 3; do echo $i; sleep 0.4; done" }, { idle_timeout_ms = 1000 })
    assert.is_false(r.timed_out)
    assert.equals(0, r.code)
    assert.same({ "1", "2", "3" }, r.stdout)
  end)

  it("reports a missing executable without raising", function()
    local r, calls = run { "passaporta-no-such-binary" }
    assert.is_not.equals(0, r.code)
    assert.is_false(r.timed_out)
    assert.is_true(#r.stderr > 0)
    assert.equals(1, calls)
  end)
end)
