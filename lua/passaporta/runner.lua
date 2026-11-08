local M = {}

---@class passaporta.RunOpts
---@field timeout_ms? integer       total timeout, passed to vim.system
---@field idle_timeout_ms? integer  kill the process when no output arrives for this long

---@class passaporta.RunResult
---@field code integer
---@field stdout string[]
---@field stderr string[]
---@field timed_out boolean

---Incremental line collector: buffers a partial tail across chunks.
---@return { feed: fun(chunk: string?), finish: fun(): string[] }
local function line_collector()
  local lines, tail = {}, ""
  return {
    feed = function(chunk)
      if not chunk or chunk == "" then
        return
      end
      local data = tail .. chunk
      local start = 1
      while true do
        local nl = data:find("\n", start, true)
        if not nl then
          break
        end
        lines[#lines + 1] = data:sub(start, nl - 1)
        start = nl + 1
      end
      tail = data:sub(start)
    end,
    finish = function()
      if tail ~= "" then
        lines[#lines + 1] = tail
        tail = ""
      end
      return lines
    end,
  }
end

---Run a job asynchronously. `on_done` is called exactly once, scheduled.
---@param job passaporta.Job
---@param opts passaporta.RunOpts
---@param on_done fun(result: passaporta.RunResult)
function M.run(job, opts, on_done)
  local out, err = line_collector(), line_collector()
  local timed_out = false
  local timer ---@type uv.uv_timer_t?
  local proc ---@type vim.SystemObj?

  local function stop_timer()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
  end

  local function touch()
    if timer then
      timer:again()
    end
  end

  if opts.idle_timeout_ms then
    timer = vim.uv.new_timer()
    timer:start(opts.idle_timeout_ms, opts.idle_timeout_ms, function()
      timed_out = true
      stop_timer()
      if proc then
        pcall(proc.kill, proc, 15)
      end
    end)
  end

  local ok, res = pcall(vim.system, job.cmd, {
    text = true,
    stdin = job.stdin,
    timeout = opts.timeout_ms,
    stdout = function(_, data)
      out.feed(data)
      touch()
    end,
    stderr = function(_, data)
      err.feed(data)
      touch()
    end,
  }, function(obj)
    stop_timer()
    -- vim.system's own timeout ends the process with signal 15 and code 124
    if opts.timeout_ms and obj.code == 124 and obj.signal == 15 then
      timed_out = true
    end
    local result = { code = obj.code, stdout = out.finish(), stderr = err.finish(), timed_out = timed_out }
    vim.schedule(function()
      on_done(result)
    end)
  end)

  if not ok then
    stop_timer()
    vim.schedule(function()
      on_done { code = 127, stdout = {}, stderr = { tostring(res) }, timed_out = false }
    end)
    return
  end
  proc = res
end

return M
