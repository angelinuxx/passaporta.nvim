local config = require "passaporta.config"
local ops = require "passaporta.ops"
local runner = require "passaporta.runner"
local secrets = require "passaporta.secrets"
local state = require "passaporta.state"

local TWO_SSH = [[
return {
  alpha = { host = "a.example", mappings = { { ["local"] = ".", remote = "/srv/a" } } },
  beta = { host = "b.example", mappings = { { ["local"] = ".", remote = "/srv/b" } } },
}
]]

local ONE_SSH = [[
return {
  alpha = { host = "a.example", mappings = { { ["local"] = ".", remote = "/srv/a" } }, excludedPaths = { "src/vendor" } },
}
]]

local KEY_SFTP = [[
return {
  shared = { host = "s.example", protocol = "sftp", mappings = { { ["local"] = ".", remote = "/public_html" } } },
}
]]

local ONE_SFTP = [[
return {
  shared = {
    host = "s.example",
    username = "u1",
    protocol = "sftp",
    password = true,
    mappings = { { ["local"] = ".", remote = "/public_html" } },
  },
}
]]

describe("ops", function()
  local orig_run, orig_select, orig_prompt, orig_notify, orig_cwd
  local dir, jobs, run_opts, result, notes, selects, select_choice, prompts, password, defer

  ---@param content string
  local function write_config(content)
    vim.fn.writefile(vim.split(content, "\n"), dir .. "/.nvim/deployment.lua")
  end

  ---@param level? integer
  ---@return string[]
  local function messages(level)
    local out = {}
    for _, n in ipairs(notes) do
      if level == nil or n.level == level then
        out[#out + 1] = n.msg
      end
    end
    return out
  end

  ---@param needle string
  ---@param level? integer
  ---@return boolean
  local function notified(needle, level)
    for _, msg in ipairs(messages(level)) do
      if msg:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  before_each(function()
    orig_run, orig_select, orig_prompt, orig_notify = runner.run, vim.ui.select, secrets.prompt, config.options.notify
    orig_cwd = vim.uv.cwd()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.nvim", "p")
    vim.fn.mkdir(dir .. "/src/vendor", "p")
    dir = vim.uv.fs_realpath(dir)
    vim.fn.writefile({ "hello" }, dir .. "/a.txt")
    vim.fn.writefile({ "x" }, dir .. "/src/b.txt")
    vim.fn.chdir(dir)

    secrets.reset()
    state.reset()
    ops.reset()
    jobs, run_opts, notes, selects, prompts = {}, {}, {}, {}, 0
    result = { code = 0, stdout = {}, stderr = {}, timed_out = false }
    select_choice = 2
    password = "hunter2"
    defer = false

    runner.run = function(job, opts, on_done)
      jobs[#jobs + 1] = job
      run_opts[#run_opts + 1] = opts
      if defer then
        defer = on_done
      else
        on_done(vim.deepcopy(result))
      end
    end
    vim.ui.select = function(items, opts, cb)
      selects[#selects + 1] = { items = items, opts = opts }
      cb(select_choice and items[select_choice] or nil)
    end
    secrets.prompt = function()
      prompts = prompts + 1
      return password
    end
    config.options.notify = function(msg, level, opts)
      notes[#notes + 1] = { msg = msg, level = level, opts = opts }
    end
  end)

  after_each(function()
    runner.run, vim.ui.select, secrets.prompt, config.options.notify = orig_run, orig_select, orig_prompt, orig_notify
    vim.fn.chdir(orig_cwd)
    vim.fn.delete(dir, "rf")
    secrets.reset()
    state.reset()
    ops.reset()
    pcall(vim.cmd, "cclose")
  end)

  it("uses the single candidate without a picker", function()
    write_config(ONE_SSH)
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(0, #selects)
    assert.are.equal(1, #jobs)
    assert.are.equal("a.example:/srv/a/a.txt", jobs[1].cmd[#jobs[1].cmd])
    assert.are.same({ timeout_ms = 120000 }, run_opts[1])
    assert.is_true(notified "[alpha] uploading a.txt")
    assert.is_true(notified("[alpha] uploaded a.txt", vim.log.levels.INFO))
  end)

  it("picks once among two candidates, then reuses the active remote", function()
    write_config(TWO_SSH)
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(1, #selects)
    assert.are.equal("Passaporta: choose remote", selects[1].opts.prompt)
    assert.are.equal("alpha  (ssh a.example:/srv/a/a.txt)", selects[1].opts.format_item(selects[1].items[1]))
    assert.are.equal("beta", state.get_active(dir))
    assert.are.equal("b.example:/srv/b/a.txt", jobs[1].cmd[#jobs[1].cmd])

    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(1, #selects)
    assert.are.equal("b.example:/srv/b/a.txt", jobs[2].cmd[#jobs[2].cmd])
  end)

  it("force_pick opens the picker and keeps the active remote", function()
    write_config(TWO_SSH)
    state.set_active(dir, "alpha")
    ops.transfer("upload", dir .. "/a.txt", { force_pick = true })
    assert.are.equal(1, #selects)
    assert.are.equal("alpha", state.get_active(dir))
    assert.are.equal("b.example:/srv/b/a.txt", jobs[1].cmd[#jobs[1].cmd])
  end)

  it("cancelling the picker aborts without state change", function()
    write_config(TWO_SSH)
    select_choice = nil
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(0, #jobs)
    assert.is_nil(state.get_active(dir))
  end)

  it("uses opts.remote directly", function()
    write_config(TWO_SSH)
    ops.transfer("upload", dir .. "/a.txt", { remote = "alpha" })
    assert.are.equal(0, #selects)
    assert.are.equal("a.example:/srv/a/a.txt", jobs[1].cmd[#jobs[1].cmd])
  end)

  it("errors when opts.remote does not cover the path", function()
    write_config(ONE_SSH)
    ops.transfer("upload", dir .. "/a.txt", { remote = "nope" })
    assert.are.equal(0, #jobs)
    assert.is_true(notified("[nope] does not cover this path", vim.log.levels.ERROR))
  end)

  it("prompts for an sftp password once across two operations", function()
    write_config(ONE_SFTP)
    ops.transfer("upload", dir .. "/a.txt")
    ops.transfer("download", dir .. "/a.txt")
    assert.are.equal(1, prompts)
    assert.are.equal(2, #jobs)
    assert.are.same({ "lftp" }, jobs[1].cmd)
    assert.truthy(jobs[2].stdin:find('get "/public_html/a.txt" -o "' .. dir .. '/a.txt"', 1, true))
    for _, cmd in ipairs { jobs[1].cmd, jobs[2].cmd } do
      assert.is_nil(table.concat(cmd, " "):find("hunter2", 1, true))
    end
  end)

  it("drops the cached password on auth failure", function()
    write_config(ONE_SFTP)
    result = { code = 1, stdout = {}, stderr = { "mirror: Login failed: Login incorrect" }, timed_out = false }
    ops.transfer("upload", dir .. "/a.txt")
    assert.is_true(notified("[shared] authentication failed, cached password dropped", vim.log.levels.ERROR))
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(2, prompts)
  end)

  it("reports a plain authentication failure when no password is configured", function()
    write_config(KEY_SFTP)
    result = { code = 1, stdout = {}, stderr = { "u@s: Permission denied (publickey)." }, timed_out = false }
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.same({ "[shared] authentication failed" }, messages(vim.log.levels.ERROR))
    assert.are.equal(0, prompts)
  end)

  it("emits deployment warnings with the remote prefix", function()
    write_config [[
return {
  alpha = { host = "a.example", upload_on_save = true, mappings = { { ["local"] = ".", remote = "/srv/a" } } },
}
]]
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.same({ "[alpha] upload_on_save is not supported and will be ignored" }, messages(vim.log.levels.WARN))
  end)

  it("aborts when no password is entered", function()
    write_config(ONE_SFTP)
    password = ""
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(0, #jobs)
    assert.is_true(notified("[shared] no password entered", vim.log.levels.ERROR))
  end)

  it("redacts the password from error output", function()
    write_config(ONE_SFTP)
    password = "s3cr et/x"
    result = {
      code = 1,
      stdout = {},
      stderr = { "open sftp://u1:s3cr%20et%2Fx@s.example failed", "echo s3cr et/x" },
      timed_out = false,
    }
    ops.transfer("upload", dir .. "/a.txt")
    assert.is_true(notified("[shared]", vim.log.levels.ERROR))
    for _, msg in ipairs(messages()) do
      assert.is_nil(msg:find("s3cr et/x", 1, true))
      assert.is_nil(msg:find("s3cr%20et%2Fx", 1, true))
    end
  end)

  it("refuses a path outside the project root", function()
    write_config(ONE_SSH)
    ops.transfer("upload", "/etc/hosts")
    assert.are.equal(0, #jobs)
    assert.is_true(notified("/etc/hosts is outside the project root", vim.log.levels.ERROR))
  end)

  it("reports an empty config", function()
    write_config "return {}"
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(0, #jobs)
    assert.is_true(notified("no remotes configured in .nvim/deployment.lua", vim.log.levels.ERROR))
  end)

  it("reports an unmapped path", function()
    write_config [[return { alpha = { host = "a", mappings = { { ["local"] = "src", remote = "/x" } } } }]]
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(0, #jobs)
    assert.is_true(notified("'a.txt' is not mapped in deployment config", vim.log.levels.ERROR))
  end)

  it("runs syncup on a file as an upload", function()
    write_config(ONE_SSH)
    ops.transfer("syncup", dir .. "/a.txt")
    assert.are.same({ "rsync", "-z", "--mkpath", dir .. "/a.txt", "a.example:/srv/a/a.txt" }, jobs[1].cmd)
  end)

  it("syncs a directory with delete, excludes and the idle timeout", function()
    write_config(ONE_SSH)
    ops.transfer("syncup", dir .. "/src")
    local cmd = jobs[1].cmd
    assert.are.same({ idle_timeout_ms = 60000 }, run_opts[1])
    assert.is_true(vim.tbl_contains(cmd, "--delete"))
    local joined = table.concat(cmd, " ")
    assert.truthy(joined:find("--exclude .git --exclude .nvim", 1, true))
    assert.truthy(joined:find("--exclude vendor/", 1, true))
    assert.are.equal(dir .. "/src/", cmd[#cmd - 1])
    assert.are.equal("a.example:/srv/a/src/", cmd[#cmd])
    assert.is_true(notified("[alpha] No differences found", vim.log.levels.INFO) or notified "No differences found")
  end)

  it("uploads a directory without delete and reports output lines", function()
    write_config(ONE_SSH)
    result.stdout = { "<f+++++++++ b.txt" }
    ops.transfer("upload", dir .. "/src")
    assert.is_false(vim.tbl_contains(jobs[1].cmd, "--delete"))
    assert.is_true(notified("<f+++++++++ b.txt", vim.log.levels.INFO))
  end)

  it("reports a timeout before looking at the exit code", function()
    write_config(ONE_SSH)
    result = { code = 0, stdout = {}, stderr = {}, timed_out = true }
    ops.transfer("upload", dir .. "/src")
    assert.is_true(notified("[alpha] timed out (no output for 60s)", vim.log.levels.ERROR))
    ops.transfer("upload", dir .. "/a.txt")
    assert.is_true(notified("[alpha] timed out after 120s", vim.log.levels.ERROR))
  end)

  it("refuses the same operation on the same path while in flight", function()
    write_config(ONE_SSH)
    defer = true
    ops.transfer("upload", dir .. "/a.txt")
    local pending = defer
    assert.is_true(ops.in_flight("upload:" .. dir .. "/a.txt"))
    ops.transfer("upload", dir .. "/a.txt")
    assert.are.equal(1, #jobs)
    assert.is_true(notified("upload already running for a.txt", vim.log.levels.WARN))
    pending { code = 1, stdout = {}, stderr = { "boom" }, timed_out = false }
    assert.is_false(ops.in_flight("upload:" .. dir .. "/a.txt"))
    assert.is_true(notified("boom", vim.log.levels.ERROR))
  end)

  it("reloads unmodified buffers after a download", function()
    write_config(ONE_SSH)
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    local buf = vim.api.nvim_get_current_buf()
    runner.run = function(job, _, on_done)
      jobs[#jobs + 1] = job
      vim.fn.writefile({ "from remote" }, dir .. "/a.txt")
      on_done { code = 0, stdout = {}, stderr = {}, timed_out = false }
    end
    ops.transfer("download", dir .. "/a.txt")
    assert.are.same({ "from remote" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd("bwipeout! " .. buf)
  end)

  it("does not reload a buffer whose file was removed by a syncdown", function()
    write_config(ONE_SSH)
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/src/b.txt"))
    local buf = vim.api.nvim_get_current_buf()
    runner.run = function(job, _, on_done)
      jobs[#jobs + 1] = job
      os.remove(dir .. "/src/b.txt")
      on_done { code = 0, stdout = { "*deleting   b.txt" }, stderr = {}, timed_out = false }
    end
    ops.transfer("syncdown", dir .. "/src")
    assert.are.same({ "x" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.cmd("bwipeout! " .. buf)
  end)

  it("diffs a single file through a temp download", function()
    write_config(ONE_SSH)
    local opened
    local diff = require "passaporta.diff"
    local orig_open = diff.open_file
    diff.open_file = function(...)
      opened = { ... }
    end
    ops.diff(dir .. "/a.txt")
    diff.open_file = orig_open
    local cmd = jobs[1].cmd
    assert.are.equal("a.example:/srv/a/a.txt", cmd[#cmd - 1])
    assert.are.equal(cmd[#cmd], opened[2])
    assert.are.equal(dir .. "/a.txt", opened[1])
    assert.are.equal("alpha", opened[3])
  end)

  it("fills the quickfix list from a directory dry run", function()
    write_config(ONE_SSH)
    result.stdout = { ">f+++++++++ new.txt", ">fcsT...... b.txt", "*deleting   gone.txt", ".d          ./" }
    ops.diff(dir .. "/src")
    local cmd = jobs[1].cmd
    assert.is_true(vim.tbl_contains(cmd, "--delete"))
    assert.is_true(vim.tbl_contains(cmd, "--dry-run"))
    assert.are.equal(dir .. "/src/", cmd[#cmd - 1])
    local qf = vim.fn.getqflist { items = true, title = true }
    assert.are.equal(3 + 3, #qf.items)
    assert.are.equal("Passaporta diff: src", qf.title)
    assert.truthy(qf.items[3].text:find("Command: rsync", 1, true))
  end)

  it("shows the lftp mirror line as the sftp diff command", function()
    write_config(ONE_SFTP)
    result.stdout = { "get -O sftp://u1@s.example/public_html/src file:" .. dir .. "/src/b.txt" }
    ops.diff(dir .. "/src")
    local qf = vim.fn.getqflist { items = true }
    assert.are.equal(4, #qf.items)
    assert.truthy(qf.items[3].text:find("Command: lftp mirror -R --delete --dry-run", 1, true))
    assert.is_nil(qf.items[3].text:find("hunter2", 1, true))
  end)
end)
