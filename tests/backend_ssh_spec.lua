local config = require "passaporta.config"
local ssh = require "passaporta.backends.ssh"

local function read_fixture(name)
  local lines = {}
  for line in io.lines("tests/fixtures/" .. name) do
    lines[#lines + 1] = line
  end
  return lines
end

---@return passaporta.TransferArgs
local function targs(over)
  return vim.tbl_extend("force", {
    local_path = "/home/u/proj/src",
    remote_path = "/var/www/src",
    direction = "up",
    delete = false,
    dry_run = false,
    excludes = {},
  }, over or {})
end

describe("ssh.file", function()
  local remote = { name = "r", host = "h", protocol = "ssh", mappings = {}, excludedPaths = {} }

  it("builds an upload with --mkpath", function()
    local job = ssh.file(remote, targs { local_path = "/p/a.lua", remote_path = "/w/a.lua" })
    assert.are.same({ "rsync", "-z", "--mkpath", "/p/a.lua", "h:/w/a.lua" }, job.cmd)
    assert.are.same({}, job.secrets)
    assert.is_nil(job.stdin)
  end)
  it("builds a download without --mkpath", function()
    local job = ssh.file(remote, targs { direction = "down", local_path = "/p/a.lua", remote_path = "/w/a.lua" })
    assert.are.same({ "rsync", "-z", "h:/w/a.lua", "/p/a.lua" }, job.cmd)
  end)
  it("includes the username", function()
    local r = vim.tbl_extend("force", remote, { username = "web" })
    local job = ssh.file(r, targs { local_path = "/p/a", remote_path = "/w/a" })
    assert.are.equal("web@h:/w/a", job.cmd[#job.cmd])
  end)
  it("inserts the port after rsync", function()
    local r = vim.tbl_extend("force", remote, { port = 2222 })
    local job = ssh.file(r, targs { local_path = "/p/a", remote_path = "/w/a" })
    assert.are.same({ "rsync", "-e", "ssh -p 2222", "-z", "--mkpath", "/p/a", "h:/w/a" }, job.cmd)
  end)
  it("keeps a local path with spaces as one element", function()
    local job = ssh.file(remote, targs { local_path = "/p/my file.lua", remote_path = "/w/my file.lua" })
    assert.are.equal("/p/my file.lua", job.cmd[4])
    assert.are.equal("h:/w/my file.lua", job.cmd[5])
  end)
end)

describe("ssh.dir", function()
  local remote = { name = "r", host = "h", username = "web", protocol = "ssh", mappings = {}, excludedPaths = {} }
  before_each(function()
    config.setup {}
  end)

  it("builds an upload using upload_params", function()
    local job = ssh.dir(remote, targs())
    assert.are.same({ "rsync", "-rlzi", "--checksum", "/home/u/proj/src/", "web@h:/var/www/src/" }, job.cmd)
    assert.are.same({}, job.secrets)
  end)
  it("builds a download using download_params", function()
    local job = ssh.dir(remote, targs { direction = "down" })
    assert.are.same({ "rsync", "-rlzi", "--checksum", "web@h:/var/www/src/", "/home/u/proj/src/" }, job.cmd)
  end)
  it("honours custom params per direction", function()
    config.setup { rsync = { upload_params = { "-a" }, download_params = { "-rz" } } }
    assert.are.same(
      { "rsync", "-a", "/l/", "web@h:/r/" },
      ssh.dir(remote, targs { local_path = "/l", remote_path = "/r" }).cmd
    )
    assert.are.same(
      { "rsync", "-rz", "web@h:/r/", "/l/" },
      ssh.dir(remote, targs { local_path = "/l", remote_path = "/r", direction = "down" }).cmd
    )
  end)
  it("drops deletion flags from user params", function()
    local flags = {
      "--del",
      "--delete",
      "--delete-before",
      "--delete-during",
      "--delete-delay",
      "--delete-after",
      "--delete-excluded",
      "--delete-missing-args",
      "--remove-source-files",
      "--remove-sent-files",
    }
    config.setup { rsync = { upload_params = vim.list_extend({ "-a" }, flags), download_params = flags } }
    assert.are.same(
      { "rsync", "-a", "/l/", "web@h:/r/" },
      ssh.dir(remote, targs { local_path = "/l", remote_path = "/r" }).cmd
    )
    assert.are.same(
      { "rsync", "--delete", "web@h:/r/", "/l/" },
      ssh.dir(remote, targs { local_path = "/l", remote_path = "/r", direction = "down", delete = true }).cmd
    )
  end)
  it("adds --delete only when requested", function()
    local job = ssh.dir(remote, targs { delete = true })
    assert.are.same({ "rsync", "-rlzi", "--checksum", "--delete", "/home/u/proj/src/", "web@h:/var/www/src/" }, job.cmd)
  end)
  it("adds dry-run flags with a single out-format element", function()
    local job = ssh.dir(remote, targs { dry_run = true })
    assert.are.same({
      "rsync",
      "-rlzi",
      "--checksum",
      "--dry-run",
      "--itemize-changes",
      "--out-format=%i %n",
      "/home/u/proj/src/",
      "web@h:/var/www/src/",
    }, job.cmd)
  end)
  it("emits excludes in order, after delete and dry-run", function()
    local job = ssh.dir(remote, targs { delete = true, dry_run = true, excludes = { ".git/", "*.pyc" } })
    assert.are.same({
      "rsync",
      "-rlzi",
      "--checksum",
      "--delete",
      "--dry-run",
      "--itemize-changes",
      "--out-format=%i %n",
      "--exclude",
      ".git/",
      "--exclude",
      "*.pyc",
      "/home/u/proj/src/",
      "web@h:/var/www/src/",
    }, job.cmd)
  end)
  it("inserts the port after rsync", function()
    local r = vim.tbl_extend("force", remote, { port = 2222 })
    local job = ssh.dir(r, targs())
    assert.are.same(
      { "rsync", "-e", "ssh -p 2222", "-rlzi", "--checksum", "/home/u/proj/src/", "web@h:/var/www/src/" },
      job.cmd
    )
  end)
  it("strips trailing slashes before appending exactly one", function()
    local job = ssh.dir(remote, targs { local_path = "/l//", remote_path = "/r/" })
    assert.are.same({ "rsync", "-rlzi", "--checksum", "/l/", "web@h:/r/" }, job.cmd)
  end)
  it("keeps paths with spaces as single elements", function()
    local job = ssh.dir(remote, targs { local_path = "/my proj/a b", remote_path = "/w/a b" })
    assert.are.equal("/my proj/a b/", job.cmd[4])
    assert.are.equal("web@h:/w/a b/", job.cmd[5])
  end)
end)

describe("ssh.parse_dry_run", function()
  it("parses the real rsync 3.2.7 fixture", function()
    local entries = ssh.parse_dry_run(read_fixture "rsync_itemize.txt", targs())
    assert.are.same({
      { status = "deleted", path = "gone/g.txt" },
      { status = "deleted", path = "gone/" },
      { status = "deleted", path = "deleted.txt" },
      { status = "modified", path = "mod.txt" },
      { status = "new", path = "new.txt" },
      { status = "new", path = "with space.txt" },
      { status = "new", path = "newdir/" },
      { status = "new", path = "newdir/inner.txt" },
    }, entries)
  end)
  it("ignores blank lines", function()
    assert.are.same({}, ssh.parse_dry_run({ "", "" }, targs()))
  end)
end)

describe("ssh.is_auth_failure", function()
  it("is always false", function()
    assert.is_false(ssh.is_auth_failure "Permission denied (publickey)")
    assert.is_false(ssh.is_auth_failure "")
  end)
end)
