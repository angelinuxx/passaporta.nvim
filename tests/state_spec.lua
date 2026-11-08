local state = require "passaporta.state"

describe("state active remote", function()
  before_each(state.reset)

  it("is nil until set", function()
    assert.is_nil(state.get_active "/proj")
  end)

  it("is independent per project root", function()
    state.set_active("/proj/a", "staging")
    state.set_active("/proj/b", "prod")
    assert.are.equal("staging", state.get_active "/proj/a")
    assert.are.equal("prod", state.get_active "/proj/b")
  end)

  it("is cleared by setting nil", function()
    state.set_active("/proj", "staging")
    state.set_active("/proj", nil)
    assert.is_nil(state.get_active "/proj")
  end)
end)

describe("state last command", function()
  before_each(state.reset)

  it("is nil until set", function()
    assert.is_nil(state.get_last "/proj")
  end)

  it("is independent per project root", function()
    state.set_last("/proj/a", { sub = "syncup", path = "src/a.lua", bang = false })
    state.set_last("/proj/b", { sub = "syncdown", path = "docs", bang = true })
    assert.are.same({ sub = "syncup", path = "src/a.lua", bang = false }, state.get_last "/proj/a")
    assert.are.same({ sub = "syncdown", path = "docs", bang = true }, state.get_last "/proj/b")
  end)

  it("is cleared by setting nil", function()
    state.set_last("/proj", { sub = "upload", path = "a", bang = false })
    state.set_last("/proj", nil)
    assert.is_nil(state.get_last "/proj")
  end)
end)

describe("state.reset", function()
  it("empties active remotes and last commands", function()
    state.set_active("/proj", "staging")
    state.set_last("/proj", { sub = "upload", path = "a", bang = false })
    state.reset()
    assert.is_nil(state.get_active "/proj")
    assert.is_nil(state.get_last "/proj")
  end)
end)
