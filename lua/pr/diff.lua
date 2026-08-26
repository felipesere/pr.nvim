local M = {}

-- Memoised parses, keyed by the diff text itself. LuaJIT interns strings and
-- caches their hash, so the lookup stays O(1) even for a large diff, and a
-- refreshed diff is a different key rather than something to invalidate.
local parsed = {}

-- Split a full PR diff into per-file line lists, keyed by the b/ path.
-- The `diff --git` header line is kept with its file's block.
local function parse(full_diff)
  local by_file = {}
  local current = nil

  for _, line in ipairs(vim.split(full_diff, "\n")) do
    local path = line:match("^diff %-%-git a/.- b/(.*)$")
    if path then
      current = {}
      by_file[path] = current
    end
    if current then
      table.insert(current, line)
    end
  end

  return by_file
end

-- Returns path -> list of diff lines, parsing each distinct diff at most once.
-- Scanning the whole diff per file is O(diff), which the telescope previewer
-- would otherwise pay on every cursor move through the file list.
function M.by_file(full_diff)
  if not full_diff or full_diff == "" then
    return {}
  end

  local by_file = parsed[full_diff]
  if not by_file then
    by_file = parse(full_diff)
    parsed[full_diff] = by_file
  end

  return by_file
end

return M
