local config = require "passaporta.config"
local sftp = require "passaporta.backends.sftp"

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

---@param job passaporta.Job
---@return string[]
local function script(job)
  local lines = vim.split(job.stdin, "\n", { plain = true })
  assert.are.equal("", table.remove(lines), "stdin ends with a newline")
  return lines
end

local preamble = {
  "set cmd:fail-exit yes",
  "set net:max-retries 2",
  "set net:timeout 30",
  "set net:reconnect-interval-base 5",
  "set xfer:clobber yes",
  "set sftp:auto-confirm no",
}

local remote = { name = "r", host = "h.example", protocol = "sftp", mappings = {}, excludedPaths = {} }
local remote_user = vim.tbl_extend("force", remote, { username = "web", port = 2222 })

describe("sftp.quote", function()
  it("quotes backslashes, quotes, spaces and dollars", function()
    assert.are.equal([["p\\a\"s $w d"]], sftp.quote [[p\a"s $w d]])
  end)
  it("quotes the empty string", function()
    assert.are.equal([[""]], sftp.quote "")
  end)
end)

describe("sftp.open_line", function()
  it("builds the open line with username, port and password", function()
    assert.are.equal(
      [[open -u "web","p\\a\"s $w d" "sftp://h.example:2222"]],
      sftp.open_line(remote_user, [[p\a"s $w d]])
    )
  end)
  it("passes an empty password when none is given", function()
    assert.are.equal([[open -u "web","" "sftp://h.example:2222"]], sftp.open_line(remote_user))
  end)
  it("omits -u without a username and the port when unset", function()
    assert.are.equal([[open "sftp://h.example"]], sftp.open_line(remote))
  end)
end)

describe("sftp.preamble", function()
  after_each(function()
    config.setup()
  end)

  it("returns the fixed settings", function()
    assert.are.same(preamble, sftp.preamble())
  end)
  it("appends user settings sorted by name, quoting values", function()
    config.setup {
      lftp = {
        settings = { ["sftp:connect-program"] = "ssh -a -x -i k", ["net:timeout"] = 60, ["ftp:ssl-allow"] = false },
      },
    }
    local expected = vim.list_extend(vim.deepcopy(preamble), {
      'set ftp:ssl-allow "no"',
      'set net:timeout "60"',
      'set sftp:connect-program "ssh -a -x -i k"',
    })
    assert.are.same(expected, sftp.preamble())
  end)
end)

describe("sftp.file", function()
  it("puts the password only in stdin, never in cmd", function()
    local job = sftp.file(
      remote,
      targs { direction = "up", local_path = "/p/a b.txt", remote_path = "/www/a b.txt", password = "s3cret" }
    )
    assert.are.same({ "lftp" }, job.cmd)
    assert.truthy(job.stdin:find('put -O "/www" "/p/a b.txt"', 1, true))
    assert.truthy(job.stdin:find('mkdir -pf "/www"', 1, true))
    assert.are.same({ "s3cret" }, job.secrets)
  end)
  it("builds the full upload script", function()
    local job = sftp.file(remote_user, targs { local_path = "/p/a.txt", remote_path = "/www/a.txt", password = "pw" })
    local expected = vim.list_extend(vim.deepcopy(preamble), {
      [[open -u "web","pw" "sftp://h.example:2222"]],
      [[mkdir -pf "/www"]],
      [[put -O "/www" "/p/a.txt"]],
      "bye",
    })
    assert.are.same(expected, script(job))
  end)
  it("downloads to the exact local path with -o", function()
    local job = sftp.file(
      remote,
      targs { direction = "down", local_path = "/tmp/nvim/12-3-a b.txt", remote_path = "/www/a b.txt" }
    )
    local lines = script(job)
    assert.are.equal([[get "/www/a b.txt" -o "/tmp/nvim/12-3-a b.txt"]], lines[#lines - 1])
    assert.are.equal("bye", lines[#lines])
    assert.are.same({}, job.secrets)
  end)
  it("also redacts the password as lftp URL-encodes it in its output", function()
    local job =
      sftp.file(remote_user, targs { local_path = "/p/a", remote_path = "/w/a", password = [[p\a"s $w d@:/%]] })
    assert.are.same({ [[p\a"s $w d@:/%]], "p%5Ca%22s%20$w%20d%40%3A%2F%25" }, job.secrets)
    assert.is_nil(job.cmd[2])
  end)
end)

describe("sftp.dir", function()
  after_each(function()
    config.setup()
  end)

  it("builds a reverse mirror with delete, dry-run and excludes", function()
    local job = sftp.dir(
      remote_user,
      targs {
        local_path = "/home/u/my proj/",
        remote_path = "/var/www/site/",
        delete = true,
        dry_run = true,
        excludes = { ".nvim", "vendor/", "*.pyc" },
        password = "pw",
      }
    )
    local lines = script(job)
    assert.are.equal(
      'mirror -R --delete --dry-run -v --no-perms --exclude-glob ".nvim" --exclude-glob ".nvim/"'
        .. ' --exclude-glob "vendor/" --exclude-glob "*.pyc" --exclude-glob "*.pyc/"'
        .. ' "/home/u/my proj" "/var/www/site"',
      lines[#lines - 1]
    )
    assert.are.equal([[open -u "web","pw" "sftp://h.example:2222"]], lines[#lines - 2])
    assert.are.same({ "pw" }, job.secrets)
  end)
  it("also excludes top-level matches of **/ globs", function()
    local job = sftp.dir(remote, targs { excludes = { "**/*.http", "**/cache/" } })
    local lines = script(job)
    assert.are.equal(
      'mirror -R -v --no-perms --exclude-glob "**/*.http" --exclude-glob "**/*.http/"'
        .. ' --exclude-glob "*.http" --exclude-glob "*.http/"'
        .. ' --exclude-glob "**/cache/" --exclude-glob "cache/"'
        .. ' "/home/u/proj/src" "/var/www/src"',
      lines[#lines - 1]
    )
  end)
  it("drops deletion flags from mirror_params", function()
    config.setup {
      lftp = {
        mirror_params = {
          "--no-perms",
          "-e",
          "--delete",
          "--delete-first",
          "--delete-excluded",
          "--delete-f",
          "--del",
          "--Remove-source-files",
          "--Remove-source-dirs",
          "--remove-source-files",
          "--Move",
          "--Mo",
          "-ve",
          "-pe",
          "-x",
          "-e",
          "-x.env",
          "-P2e",
          "--parallel=2",
        },
      },
    }
    local mirror = 'mirror -R%s -v --no-perms -x -e -x.env -P2e --parallel=2 "/l" "/r"'
    local lines = script(sftp.dir(remote, targs { local_path = "/l", remote_path = "/r" }))
    assert.are.equal(mirror:format "", lines[#lines - 1])
    lines = script(sftp.dir(remote, targs { local_path = "/l", remote_path = "/r", delete = true }))
    assert.are.equal(mirror:format " --delete", lines[#lines - 1])
  end)
  it("builds a plain download mirror, remote first", function()
    local job = sftp.dir(remote, targs { direction = "down" })
    local lines = script(job)
    assert.are.equal('mirror -v --no-perms "/var/www/src" "/home/u/proj/src"', lines[#lines - 1])
  end)
  it("keeps the root path as /", function()
    local job = sftp.dir(remote, targs { remote_path = "/" })
    local lines = script(job)
    assert.are.equal('mirror -R -v --no-perms "/home/u/proj/src" "/"', lines[#lines - 1])
  end)
end)

describe("sftp.parse_dry_run", function()
  local roots = { local_path = "/tmp/pp-lftp/local", remote_path = "/tmp/pp-lftp/remote", dry_run = true }

  it("parses file: output for an upload", function()
    local entries = sftp.parse_dry_run(read_fixture "lftp_dryrun_up.txt", targs(roots))
    assert.are.same({
      { status = "modified", path = "changed.txt" },
      { status = "new", path = "new file.txt" },
      { status = "new", path = "new dir/" },
      { status = "new", path = "new dir/inner.txt" },
      { status = "new", path = "sub/nested new.txt" },
      { status = "deleted", path = "gone dir/" },
      { status = "deleted", path = "gone.txt" },
    }, entries)
  end)
  it("parses file: output for a download", function()
    local entries = sftp.parse_dry_run(
      read_fixture "lftp_dryrun_down.txt",
      targs(vim.tbl_extend("force", roots, { direction = "down" }))
    )
    assert.are.same({
      { status = "modified", path = "changed.txt" },
      { status = "new", path = "gone.txt" },
      { status = "new", path = "gone dir/" },
      { status = "new", path = "gone dir/x.txt" },
      { status = "deleted", path = "sub/nested new.txt" },
      { status = "deleted", path = "new dir/" },
      { status = "deleted", path = "new file.txt" },
    }, entries)
  end)
  it("parses real sftp output with a remote path relative to the home", function()
    local args = targs { local_path = "/tmp/pp-lftp/local", remote_path = "remote", dry_run = true }
    assert.are.same({
      { status = "modified", path = "changed.txt" },
      { status = "new", path = "new file.txt" },
      { status = "new", path = "new dir/" },
      { status = "new", path = "new dir/inner.txt" },
      { status = "new", path = "sub/nested new.txt" },
      { status = "deleted", path = "gone dir/" },
      { status = "deleted", path = "gone.txt" },
    }, sftp.parse_dry_run(read_fixture "lftp_dryrun_up_sftp.txt", args))
    args.direction = "down"
    assert.are.same({
      { status = "modified", path = "changed.txt" },
      { status = "new", path = "gone.txt" },
      { status = "new", path = "gone dir/" },
      { status = "new", path = "gone dir/x.txt" },
      { status = "deleted", path = "sub/nested new.txt" },
      { status = "deleted", path = "new dir/" },
      { status = "deleted", path = "new file.txt" },
    }, sftp.parse_dry_run(read_fixture "lftp_dryrun_down_sftp.txt", args))
  end)
  it("handles quoted URLs, percent-encoding, put, rmdir and skipped verbs", function()
    local args = targs { local_path = "/l", remote_path = "/www", direction = "down" }
    local lines = {
      [[get -O "/l/a b" "sftp://u:a#b@h:22/www/a%20b/q%22%5C%25%23.txt"]],
      [[put -e /www/x.txt]],
      [[rmdir file:/l/old]],
      [[chmod 644 file:/l/x.txt]],
      [[set foo bar]],
      [[cd /www]],
      [[lcd /l]],
      "",
    }
    assert.are.same({
      { status = "new", path = [[a b/q"\%#.txt]] },
      { status = "modified", path = "x.txt" },
      { status = "deleted", path = "old/" },
    }, sftp.parse_dry_run(lines, args))
  end)
end)

describe("sftp.is_auth_failure", function()
  it("detects authentication failures", function()
    assert.is_true(sftp.is_auth_failure "ls: Login failed: 530 Login incorrect.")
    assert.is_true(sftp.is_auth_failure "mirror: Fatal error: max-retries exceeded\nLOGIN INCORRECT")
    assert.is_true(sftp.is_auth_failure "Permission denied (publickey,password).")
    assert.is_true(sftp.is_auth_failure "authentication failed")
    assert.is_false(sftp.is_auth_failure "mirror: Access failed: No such file (/www/x)")
    assert.is_false(sftp.is_auth_failure "")
  end)
end)
