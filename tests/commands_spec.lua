local commands = require "passaporta.commands"
local config = require "passaporta.config"
local ops = require "passaporta.ops"
local secrets = require "passaporta.secrets"
local state = require "passaporta.state"

local CONFIG = [[
return {
  alpha = { host = "h", mappings = { { ["local"] = ".", remote = "/a" } } },
  beta = { host = "h", mappings = { { ["local"] = ".", remote = "/b" } } },
}
]]

describe("commands.parse", function()
  it("parses every path subcommand", function()
    for _, sub in ipairs { "upload", "download", "syncup", "syncdown", "diff" } do
      assert.are.same({ sub = sub, arg = "src/a.lua", bang = false }, commands.parse({ sub, "src/a.lua" }, false))
      assert.are.same({ sub = sub, arg = nil, bang = false }, commands.parse({ sub }, false))
    end
  end)

  it("carries the bang", function()
    assert.are.same({ sub = "upload", arg = nil, bang = true }, commands.parse({ "upload" }, true))
  end)

  it("parses argument-less subcommands", function()
    for _, sub in ipairs { "repeat", "init", "forget" } do
      assert.are.same({ sub = sub, arg = nil, bang = false }, commands.parse({ sub }, false))
    end
  end)

  it("parses remote with and without an argument", function()
    assert.are.same({ sub = "remote", arg = nil, bang = false }, commands.parse({ "remote" }, false))
    assert.are.same({ sub = "remote", arg = "beta", bang = false }, commands.parse({ "remote", "beta" }, false))
    assert.are.same({ sub = "remote", arg = "clear", bang = false }, commands.parse({ "remote", "clear" }, false))
  end)

  it("rejects a missing subcommand", function()
    local cmd, err = commands.parse({}, false)
    assert.is_nil(cmd)
    assert.is_truthy(err)
  end)

  it("rejects an unknown subcommand", function()
    local cmd, err = commands.parse({ "bogus" }, false)
    assert.is_nil(cmd)
    assert.are.equal("unknown subcommand 'bogus'", err)
  end)
end)

describe("commands", function()
  local old_cwd, tmp, notes, orig_transfer, orig_select, orig_notify, orig_template

  before_each(function()
    old_cwd = vim.uv.cwd()
    tmp = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp .. "/.nvim", "p")
    vim.fn.writefile(vim.split(CONFIG, "\n"), tmp .. "/.nvim/deployment.lua")
    vim.cmd("cd " .. vim.fn.fnameescape(tmp))
    state.reset()
    secrets.reset()
    notes = {}
    orig_notify = config.options.notify
    orig_template = config.options.config_template
    config.options.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    orig_transfer = ops.transfer
    orig_select = vim.ui.select
  end)

  after_each(function()
    ops.transfer = orig_transfer
    vim.ui.select = orig_select
    config.options.notify = orig_notify
    config.options.config_template = orig_template
    vim.cmd("cd " .. vim.fn.fnameescape(old_cwd))
    vim.fn.delete(tmp, "rf")
  end)

  local function last_note()
    return notes[#notes]
  end

  describe("complete", function()
    it("lists subcommands for the first word", function()
      local out = commands.complete("", "Passaporta ", 11)
      assert.are.same(
        { "diff", "download", "forget", "init", "remote", "repeat", "syncdown", "syncup", "upload" },
        vim.fn.sort(out)
      )
      assert.are.same({ "upload" }, commands.complete("up", "Passaporta up", 13))
    end)

    it("lists remote names and clear after remote", function()
      assert.are.same({ "alpha", "beta", "clear" }, commands.complete("", "Passaporta remote ", 18))
      assert.are.same({ "beta" }, commands.complete("b", "Passaporta remote b", 19))
    end)

    it("completes files after a path subcommand", function()
      vim.fn.writefile({}, tmp .. "/zzfile.txt")
      assert.is_truthy(vim.tbl_contains(commands.complete("zz", "Passaporta upload zz", 20), "zzfile.txt"))
      assert.is_truthy(vim.tbl_contains(commands.complete("zz", "Passaporta diff zz", 18), "zzfile.txt"))
    end)
  end)

  describe("transfer subcommands", function()
    it("stores the absolute path and passes it to ops.transfer", function()
      local calls = {}
      ops.transfer = function(op, path, opts)
        calls[#calls + 1] = { op, path, opts }
      end
      commands.run { fargs = { "upload", "sub/a.lua" }, bang = true }
      local abs = tmp .. "/sub/a.lua"
      assert.are.same({ { "upload", abs, { force_pick = true } } }, calls)
      assert.are.same({ sub = "upload", path = abs, bang = true }, state.get_last(tmp))
    end)

    it("uses the current buffer without an argument", function()
      local calls = {}
      ops.transfer = function(op, path)
        calls[#calls + 1] = { op, path }
      end
      vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/buf.txt"))
      commands.run { fargs = { "syncup" }, bang = false }
      assert.are.same({ { "syncup", tmp .. "/buf.txt" } }, calls)
      vim.cmd "bwipeout!"
    end)

    it("repeat re-runs the last transfer", function()
      local calls = {}
      ops.transfer = function(op, path, opts)
        calls[#calls + 1] = { op, path, opts }
      end
      commands.run { fargs = { "download", "x.txt" }, bang = true }
      calls = {}
      commands.run { fargs = { "repeat" }, bang = false }
      assert.are.same({ { "download", tmp .. "/x.txt", { force_pick = true } } }, calls)
    end)

    it("repeat warns when nothing is stored", function()
      commands.run { fargs = { "repeat" }, bang = false }
      assert.are.equal("nothing to repeat", last_note().msg)
      assert.are.equal(vim.log.levels.WARN, last_note().level)
    end)

    it("diff does not record set_last", function()
      local diff_called = false
      local orig = ops.diff
      ops.diff = function()
        diff_called = true
      end
      commands.run { fargs = { "diff", "a.txt" }, bang = false }
      ops.diff = orig
      assert.is_true(diff_called)
      assert.is_nil(state.get_last(tmp))
    end)

    it("reports a parse error", function()
      commands.run { fargs = { "bogus" }, bang = false }
      assert.are.equal("unknown subcommand 'bogus'", last_note().msg)
      assert.are.equal(vim.log.levels.ERROR, last_note().level)
    end)
  end)

  describe("remote", function()
    it("sets a known remote", function()
      commands.run { fargs = { "remote", "beta" }, bang = false }
      assert.are.equal("beta", state.get_active(tmp))
      assert.are.equal("[beta] active remote: beta", last_note().msg)
    end)

    it("errors on an unknown remote", function()
      commands.run { fargs = { "remote", "nope" }, bang = false }
      assert.is_nil(state.get_active(tmp))
      assert.are.equal("unknown remote 'nope'", last_note().msg)
      assert.are.equal(vim.log.levels.ERROR, last_note().level)
    end)

    it("clears the active remote", function()
      state.set_active(tmp, "alpha")
      commands.run { fargs = { "remote", "clear" }, bang = false }
      assert.is_nil(state.get_active(tmp))
      assert.are.equal("active remote cleared", last_note().msg)
    end)

    it("picker lists all remotes and sets the choice", function()
      local seen, prompt
      vim.ui.select = function(items, opts, cb)
        seen, prompt = items, opts.prompt
        cb(items[2])
      end
      commands.run { fargs = { "remote" }, bang = false }
      assert.are.same({ "alpha", "beta" }, seen)
      assert.are.equal("Passaporta: choose active remote", prompt)
      assert.are.equal("beta", state.get_active(tmp))
    end)

    it("picker cancel changes nothing", function()
      state.set_active(tmp, "alpha")
      vim.ui.select = function(items, _, cb)
        cb(nil)
      end
      commands.run { fargs = { "remote" }, bang = false }
      assert.are.equal("alpha", state.get_active(tmp))
    end)

    it("reports a config load error", function()
      vim.fn.delete(tmp .. "/.nvim", "rf")
      commands.run { fargs = { "remote", "alpha" }, bang = false }
      assert.is_truthy(last_note().msg:find("no deployment config", 1, true))
      assert.are.equal(vim.log.levels.ERROR, last_note().level)
    end)
  end)

  describe("init", function()
    it("creates the config from the template", function()
      vim.fn.delete(tmp .. "/.nvim", "rf")
      config.options.config_template = "return {}\n-- x\n"
      commands.run { fargs = { "init" }, bang = false }
      assert.are.same({ "return {}", "-- x" }, vim.fn.readfile(tmp .. "/.nvim/deployment.lua"))
      assert.are.equal(tmp .. "/.nvim/deployment.lua", vim.api.nvim_buf_get_name(0))
      vim.cmd "bwipeout!"
    end)

    it("accepts a table or function template", function()
      vim.fn.delete(tmp .. "/.nvim", "rf")
      config.options.config_template = function()
        return { "return {}", "-- fn" }
      end
      commands.run { fargs = { "init" }, bang = false }
      assert.are.same({ "return {}", "-- fn" }, vim.fn.readfile(tmp .. "/.nvim/deployment.lua"))
      vim.cmd "bwipeout!"
    end)

    it("does not overwrite an existing file", function()
      commands.run { fargs = { "init" }, bang = false }
      assert.are.equal(vim.trim(CONFIG), vim.trim(table.concat(vim.fn.readfile(tmp .. "/.nvim/deployment.lua"), "\n")))
      vim.cmd "bwipeout!"
    end)
  end)

  describe("forget", function()
    it("reports the number of dropped passwords", function()
      secrets.get(tmp, { name = "alpha", host = "h", password = "pw1" })
      secrets.get(tmp, { name = "beta", host = "h", password = "pw2" })
      commands.run { fargs = { "forget" }, bang = false }
      assert.are.equal("dropped 2 cached password(s)", last_note().msg)
      assert.are.equal(0, secrets.forget(tmp))
    end)
  end)

  describe("public api", function()
    local api = require "passaporta"

    it("records set_last so repeat works after a keymap call", function()
      local calls = {}
      ops.transfer = function(op, path, opts)
        calls[#calls + 1] = { op, path, opts }
      end
      api.syncdown "d"
      assert.are.same({ sub = "syncdown", path = tmp .. "/d", bang = false }, state.get_last(tmp))
      calls = {}
      api.repeat_last()
      assert.are.same({ { "syncdown", tmp .. "/d", { force_pick = false } } }, calls)
    end)

    it("manages the active remote", function()
      api.set_remote "alpha"
      assert.are.equal("alpha", api.active_remote())
      api.clear_remote()
      assert.is_nil(api.active_remote())
      api.set_remote "nope"
      assert.is_nil(api.active_remote())
    end)
  end)
end)
