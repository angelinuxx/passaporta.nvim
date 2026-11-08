local config = require "passaporta.config"
local diff = require "passaporta.diff"

describe("diff.quickfix_items", function()
  it("maps the three statuses", function()
    local items = diff.quickfix_items({
      { status = "new", path = "a.txt" },
      { status = "modified", path = "dir/b.txt" },
      { status = "deleted", path = "c.txt" },
    }, "/proj")
    assert.are.same({ filename = "/proj/a.txt", text = "[A] a.txt" }, items[1])
    assert.are.same({ filename = "/proj/dir/b.txt", text = "[M] dir/b.txt" }, items[2])
    assert.are.same({ text = "[D] c.txt", valid = 0 }, items[3])
  end)

  it("handles a path with a space", function()
    local items = diff.quickfix_items({ { status = "new", path = "my file.txt" } }, "/proj")
    assert.are.equal("/proj/my file.txt", items[1].filename)
    assert.are.equal("[A] my file.txt", items[1].text)
  end)

  it("marks directory entries as not valid", function()
    local items = diff.quickfix_items({ { status = "new", path = "sub/" } }, "/proj")
    assert.is_nil(items[1].filename)
    assert.are.equal(0, items[1].valid)
    assert.are.equal("[A] sub/", items[1].text)
  end)
end)

describe("diff.header_items", function()
  it("returns three invalid items", function()
    local remote = { name = "staging", host = "h.example", protocol = "ssh", mappings = {}, excludedPaths = {} }
    local items = diff.header_items("src", remote, "/var/www", "rsync -n a b")
    assert.are.equal(3, #items)
    for _, item in ipairs(items) do
      assert.are.equal(0, item.valid)
    end
    assert.truthy(items[1].text:find("src", 1, true))
    assert.truthy(items[2].text:find("staging (h.example:/var/www)", 1, true))
    assert.truthy(items[3].text:find("rsync -n a b", 1, true))
  end)
end)

describe("diff.show_dir", function()
  it("fills the quickfix list with the title", function()
    diff.show_dir({ { text = "hdr", valid = 0 } }, { { status = "new", path = "a.txt" } }, "/proj", "src")
    local qf = vim.fn.getqflist { title = true, items = true }
    assert.are.equal("Passaporta diff: src", qf.title)
    assert.are.equal(2, #qf.items)
    vim.cmd "cclose"
  end)
end)

describe("diff.temp_path", function()
  it("keeps the extension and creates the directory", function()
    local p = diff.temp_path "/proj/lib/file.php"
    assert.truthy(p:match "%-file%.php$")
    assert.are.equal(1, vim.fn.isdirectory(vim.fn.fnamemodify(p, ":h")))
    assert.are.equal(vim.fn.stdpath "cache" .. "/passaporta", vim.fn.fnamemodify(p, ":h"))
  end)

  it("returns a different path each call", function()
    assert.are_not.equal(diff.temp_path "/x/a.txt", diff.temp_path "/x/a.txt")
  end)
end)

describe("diff.open_file", function()
  local local_path, tmp

  before_each(function()
    local_path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "local" }, local_path)
    tmp = diff.temp_path(local_path)
    vim.fn.writefile({ "remote" }, tmp)
  end)

  after_each(function()
    vim.cmd "silent! only!"
    vim.cmd "silent! %bwipeout!"
    os.remove(local_path)
    os.remove(tmp)
  end)

  it("opens the remote file readonly, unlisted and wipes it with the temp file", function()
    diff.open_file(local_path, tmp, "staging")
    local buf = vim.api.nvim_get_current_buf()
    assert.are.equal(tmp, vim.api.nvim_buf_get_name(buf))
    assert.is_true(vim.bo[buf].readonly)
    assert.is_false(vim.bo[buf].buflisted)
    assert.are.equal("wipe", vim.bo[buf].bufhidden)
    assert.are.equal("", vim.bo[buf].buftype)
    assert.is_true(vim.wo.diff)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(vim.uv.fs_stat(tmp))
  end)

  it("sets the close mapping on both buffers and closes the diff", function()
    config.options.close_diff_mapping = "<leader>b"
    diff.open_file(local_path, tmp, "staging")
    local remote_buf = vim.api.nvim_get_current_buf()
    assert.truthy(vim.fn.maparg("<leader>b", "n", false, true).buffer == 1)
    vim.cmd "wincmd p"
    local local_buf = vim.api.nvim_get_current_buf()
    assert.are.equal(1, vim.fn.maparg("<leader>b", "n", false, true).buffer)
    vim.fn.maparg("<leader>b", "n", false, true).callback()
    assert.is_false(vim.api.nvim_buf_is_valid(remote_buf))
    assert.is_false(vim.wo.diff)
    assert.are.equal(local_buf, vim.api.nvim_get_current_buf())
  end)
end)
