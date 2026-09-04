local M = {}

function M.run(cmd, callback)
  local stdout = {}
  local stderr = {}
  
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(table.concat(stdout, "\n"), nil)
        else
          callback(nil, table.concat(stderr, "\n"))
        end
      end)
    end,
  })
end

-- Blocking variant of M.run, for call sites that don't take a callback.
-- Accepts the same cmd forms as jobstart (string or argv list). Returns
-- exit code, stdout, stderr instead of the (result, err) callback shape,
-- since callers need stderr even on success-shaped edge cases.
function M.run_sync(cmd)
  local stdout = {}
  local stderr = {}

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr, line)
          end
        end
      end
    end,
  })

  local code = vim.fn.jobwait({ job })[1]
  return code, table.concat(stdout, "\n"), table.concat(stderr, "\n")
end

function M.run_json(cmd, callback)
  M.run(cmd, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    
    local ok, data = pcall(vim.json.decode, result)
    if not ok then
      callback(nil, "Failed to parse JSON")
      return
    end
    
    callback(data, nil)
  end)
end

return M
