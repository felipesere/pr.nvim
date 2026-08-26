local M = {}
local async = require("pr.async")
local cache = require("pr.cache")

-- Memory caches, keyed by origin remote. Both `gh pr list` and repo detection
-- target whatever repo is current, so a session that changes directory must not
-- be served another repo's data.
M.pr_cache = {}
M.current_user = nil
M.prefetch_in_progress = false
M.auth_checked = false
M.is_authenticated = nil
M.auth_token = nil

-- Origin remote of the cwd's repo, or nil outside a repo. A local git call with
-- no network, so it is cheap enough to re-check instead of caching globally.
local function origin_remote()
  local remote = vim.fn.system("git remote get-url origin 2>/dev/null"):gsub("%s+", "")
  if vim.v.shell_error ~= 0 or remote == "" then
    return nil
  end
  return remote
end

-- Cached PR list for the current repo, if any.
function M.get_cached_prs()
  local remote = origin_remote()
  return remote and M.pr_cache[remote] or nil
end

local function set_cached_prs(prs)
  local remote = origin_remote()
  if remote then
    M.pr_cache[remote] = prs
  end
end

-- Resolve the gh token once and memoise it for the session.
function M.get_auth_token(callback)
  if M.auth_token then
    callback(M.auth_token)
    return
  end

  async.run("gh auth token 2>/dev/null", function(result, _)
    local token = (result or ""):gsub("%s+", "")
    if token ~= "" then
      M.auth_token = token
    end
    callback(M.auth_token)
  end)
end

-- Check if user is authenticated with gh CLI.
-- Holding a token is the same signal as `gh auth status`, but `gh auth status`
-- validates it against the API over the network (~0.4s) while `gh auth token`
-- reads local config (~0.06s), and the token is needed for raw fetches anyway.
function M.check_auth(callback)
  if M.auth_checked then
    if callback then callback(M.is_authenticated) end
    return M.is_authenticated
  end

  M.get_auth_token(function(token)
    M.auth_checked = true
    M.is_authenticated = token ~= nil
    if callback then callback(M.is_authenticated) end
  end)
end

-- Show auth error in a floating window
function M.show_auth_error()
  local lines = {
    "",
    "  GitHub CLI not authenticated  ",
    "",
    "  Run this command in your terminal:",
    "",
    "    gh auth login",
    "",
    "  Then restart Neovim.",
    "",
  }
  
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  
  local width = 40
  local height = #lines
  
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ⚠ Authentication Required ",
    title_pos = "center",
  })
  
  vim.wo[win].winhl = "Normal:ErrorFloat,FloatBorder:ErrorFloat"
  
  -- Close on any key
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<CR>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
end

-- Wrapper to check auth before running commands
function M.require_auth(callback)
  if M.is_authenticated == false then
    M.show_auth_error()
    return false
  end
  
  if M.is_authenticated == nil then
    M.check_auth(function(authed)
      if authed then
        callback()
      else
        M.show_auth_error()
      end
    end)
    return false
  end
  
  return true
end

-- Prefetch PRs in background (call on nvim start)
function M.prefetch()
  if M.prefetch_in_progress then return end
  M.prefetch_in_progress = true

  -- Warm the auth gate and token so the first command does not wait on them
  M.check_auth()

  -- Fetch user first, then PRs (need username for review status)
  local function fetch_prs()
    local cmd = "gh pr list --limit 100 --json number,title,author,reviewDecision,reviews,reviewRequests,createdAt,url"
    async.run_json(cmd, function(prs, err)
      M.prefetch_in_progress = false
      if err or not prs then return end
      
      for _, pr in ipairs(prs) do
        pr.review_status = M.get_review_status(pr, M.current_user or "")
      end
      
      set_cached_prs(prs)
    end)
  end
  
  if not M.current_user then
    async.run("gh api user --jq .login", function(username, _)
      M.current_user = (username or ""):gsub("%s+", "")
      fetch_prs()
    end)
  else
    fetch_prs()
  end
end

-- Extract owner/repo from a PR web URL. The URL names the base repo with its
-- canonical casing, so it is correct for PRs from forks and, unlike
-- get_repo_info, does not depend on the current working directory.
function M.repo_from_url(url)
  if not url then return nil, nil end
  return url:match("github%.com/([^/]+)/([^/]+)/pull")
end

-- Cache for correct owner/repo casing, keyed by remote so that changing
-- directory resolves the new repo instead of returning the first one seen.
M.repo_info_cache = {}

function M.get_repo_info(callback)
  local remote = origin_remote()
  if not remote then
    if callback then callback(nil, nil) end
    return nil, nil
  end

  local cached = M.repo_info_cache[remote]
  if cached then
    if callback then
      callback(cached.owner, cached.repo)
      return
    end
    return cached.owner, cached.repo
  end

  local owner, repo = remote:match("github%.com[:/]([^/]+)/([^/]+)")
  if repo then
    repo = repo:gsub("%.git$", "")
  end
  
  if not owner or not repo then
    if callback then callback(nil, nil) end
    return nil, nil
  end
  
  -- For async mode, fetch correct casing from GitHub
  if callback then
    local cmd = string.format("gh repo view %s/%s --json owner,name --jq '.owner.login + \"/\" + .name' 2>/dev/null", owner, repo)
    async.run(cmd, function(result, err)
      if not err and result and result:match("/") then
        local correct_owner, correct_repo = result:gsub("%s+", ""):match("([^/]+)/(.+)")
        if correct_owner and correct_repo then
          M.repo_info_cache[remote] = { owner = correct_owner, repo = correct_repo }
          callback(correct_owner, correct_repo)
          return
        end
      end
      -- Fallback to parsed values
      M.repo_info_cache[remote] = { owner = owner, repo = repo }
      callback(owner, repo)
    end)
    return
  end
  
  -- Sync mode - just return parsed values (used for quick checks)
  return owner, repo
end

function M.list_prs(filter, callback, on_update)
  filter = filter or ""
  
  -- If we have cached data for this repo, show it immediately
  local cached_prs = M.get_cached_prs()
  if cached_prs and #cached_prs > 0 and filter == "" then
    callback(cached_prs, nil)

    -- Refresh full data in background (skip fast load, we already have data)
    if on_update then
      M.fetch_full_prs(filter, on_update)
    end
    return
  end
  
  -- No cache - fetch fresh (fast first, then full update)
  M.fetch_fresh_prs(filter, function(prs)
    callback(prs, nil)
  end, on_update)
end

-- Full fetch only (used when cache already shown)
function M.fetch_full_prs(filter, on_update)
  if not M.current_user then
    async.run("gh api user --jq .login", function(username, _)
      M.current_user = (username or ""):gsub("%s+", "")
      M.fetch_full_prs(filter, on_update)
    end)
    return
  end
  
  local cmd = string.format("gh pr list --limit 100 --json number,title,author,reviewDecision,reviews,reviewRequests,createdAt,url %s", filter)
  
  async.run_json(cmd, function(prs, err)
    if err or not prs then return end
    
    for _, pr in ipairs(prs) do
      pr.review_status = M.get_review_status(pr, M.current_user or "")
    end
    
    if filter == "" then
      set_cached_prs(prs)
    end
    
    if on_update then
      on_update(prs)
    end
  end)
end

function M.fetch_fresh_prs(filter, callback, on_update)
  -- Ensure we have user info (parallel fetch)
  if not M.current_user then
    async.run("gh api user --jq .login", function(username, _)
      M.current_user = (username or ""):gsub("%s+", "")
    end)
  end
  
  -- Fast first load - basic info only
  local cmd_fast = string.format("gh pr list --limit 50 --json number,title,author,createdAt,url %s", filter)
  
  async.run_json(cmd_fast, function(prs, err)
    if err or not prs then
      if callback then callback({}, nil) end
      return
    end
    
    -- Show immediately with empty status
    for _, pr in ipairs(prs) do
      pr.review_status = ""
    end
    
    if callback then
      callback(prs)
    end
    
    -- Now fetch full details in background
    local cmd_full = string.format("gh pr list --limit 100 --json number,title,author,reviewDecision,reviews,reviewRequests,url %s", filter)
    
    async.run_json(cmd_full, function(full_prs, full_err)
      if full_err or not full_prs then return end
      
      for _, pr in ipairs(full_prs) do
        pr.review_status = M.get_review_status(pr, M.current_user or "")
      end
      
      -- Update cache if no filter
      if filter == "" then
        set_cached_prs(full_prs)
      end
      
      if on_update then
        on_update(full_prs)
      end
    end)
  end)
end

function M.get_review_status(pr, current_user)
  local decision = pr.reviewDecision or ""
  local reviews = pr.reviews or {}
  local review_requests = pr.reviewRequests or {}
  
  -- Check if current user has reviewed
  local your_review = nil
  local has_any_review = #reviews > 0
  for _, review in ipairs(reviews) do
    if review.author and review.author.login == current_user then
      your_review = review.state
    end
  end
  
  -- Check if current user is requested to review
  local you_requested = false
  for _, request in ipairs(review_requests) do
    if request.login == current_user then
      you_requested = true
      break
    end
  end
  
  local icon = ""
  local status_text = ""
  
  -- Overall status
  if decision == "APPROVED" then
    icon = "✓"
    status_text = "approved"
  elseif decision == "CHANGES_REQUESTED" then
    icon = "✗"
    status_text = "changes req"
  elseif has_any_review then
    icon = "●"
  else
    icon = "○"
  end
  
  -- Build main status (not highlighted)
  local main_parts = {}
  if status_text ~= "" then
    table.insert(main_parts, status_text)
  end
  
  -- Build "for you" parts (will be highlighted)
  local you_parts = {}
  if you_requested then
    table.insert(you_parts, "review req")
  end
  if your_review then
    if your_review == "APPROVED" then
      table.insert(you_parts, "you approved")
    elseif your_review == "CHANGES_REQUESTED" then
      table.insert(you_parts, "you req changes")
    elseif your_review == "COMMENTED" or your_review == "PENDING" then
      table.insert(you_parts, "you reviewed")
    end
  end
  
  return {
    icon = icon,
    main = table.concat(main_parts, ", "),
    you = table.concat(you_parts, ", "),
  }
end

function M.get_pr(owner, repo, pr_number, callback)
  local cmd = string.format(
    "gh pr view %s --repo %s/%s --json number,title,body,author,files,comments,reviews,headRefName,baseRefName,baseRefOid,headRefOid,createdAt",
    pr_number, owner, repo
  )
  
  async.run_json(cmd, function(pr, err)
    if err then
      callback(nil, "Failed to fetch PR: " .. err)
      return
    end
    
    -- The --json above already carries the file list, so flatten those objects
    -- to paths here rather than spending a second gh pr view on --jq
    local paths = {}
    for _, file in ipairs(pr.files or {}) do
      if file.path then
        table.insert(paths, file.path)
      end
    end
    pr.files = paths

    callback(pr, nil)
  end)
end

function M.get_diff(owner, repo, pr_number, callback)
  -- Check cache first
  local cached = cache.get_diff(owner, repo, pr_number)
  if cached then
    if callback then
      callback(cached)
    end
    return cached
  end
  
  if callback then
    -- Async mode
    local cmd = string.format("gh pr diff %s --repo %s/%s", pr_number, owner, repo)
    async.run(cmd, function(result, err)
      if not err and result then
        cache.set_diff(owner, repo, pr_number, result)
      end
      callback(result)
    end)
  else
    -- Sync mode (fallback)
    local cmd = string.format("gh pr diff %s --repo %s/%s 2>&1", pr_number, owner, repo)
    local result = vim.fn.system(cmd)
    if vim.v.shell_error == 0 then
      cache.set_diff(owner, repo, pr_number, result)
      return result
    end
    return nil
  end
end

function M.get_comments(owner, repo, pr_number, callback)
  local cmd = string.format("gh api repos/%s/%s/pulls/%s/comments", owner, repo, pr_number)
  
  if callback then
    async.run_json(cmd, function(comments, err)
      callback(comments, err)
    end)
  else
    local result = vim.fn.system(cmd .. " 2>&1")
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to fetch comments"
    end
    local ok, comments = pcall(vim.json.decode, result)
    if not ok then
      return nil, "Failed to parse comments"
    end
    return comments, nil
  end
end

function M.add_comment(owner, repo, pr_number, path, line, body, start_line, callback)
  -- Validate line number
  if not line or line < 1 then
    local err = string.format("Invalid line number: %s", tostring(line))
    if callback then callback(nil, err) else return nil, err end
    return
  end
  
  if callback then
    -- Async mode
    local sha_cmd = string.format("gh pr view %s --repo %s/%s --json headRefOid --jq .headRefOid", pr_number, owner, repo)
    async.run(sha_cmd, function(commit_id, sha_err)
      if sha_err or not commit_id or commit_id == "" then
        callback(nil, "Failed to get commit SHA")
        return
      end
      commit_id = commit_id:gsub("%s+", "")
      
      local cmd = M._build_comment_cmd(owner, repo, pr_number, path, line, body, start_line, commit_id)
      async.run(cmd, function(result, err)
        if err then
          local err_msg = (result or err):match('"message":"([^"]+)"') or err
          callback(nil, "Failed to add comment: " .. err_msg)
        else
          callback(true, nil)
        end
      end)
    end)
  else
    -- Sync mode (legacy fallback)
    local sha_cmd = string.format("gh pr view %s --repo %s/%s --json headRefOid --jq .headRefOid", pr_number, owner, repo)
    local commit_id = vim.fn.system(sha_cmd):gsub("%s+", "")
    
    if vim.v.shell_error ~= 0 or commit_id == "" then
      return nil, "Failed to get commit SHA"
    end
    
    local cmd = M._build_comment_cmd(owner, repo, pr_number, path, line, body, start_line, commit_id)
    local result = vim.fn.system(cmd .. " 2>&1")
    
    if vim.v.shell_error ~= 0 then
      local err_msg = result:match('"message":"([^"]+)"') or result
      return nil, "Failed to add comment: " .. err_msg
    end
    
    return true, nil
  end
end

function M._build_comment_cmd(owner, repo, pr_number, path, line, body, start_line, commit_id)
  if start_line and start_line < line then
    return string.format(
      "gh api repos/%s/%s/pulls/%s/comments --method POST " ..
      "--field body=%q " ..
      "--field path=%q " ..
      "--field commit_id=%s " ..
      "--field line=%d " ..
      "--field start_line=%d " ..
      "--field side=RIGHT " ..
      "--field start_side=RIGHT",
      owner, repo, pr_number, body, path, commit_id, line, start_line
    )
  else
    return string.format(
      "gh api repos/%s/%s/pulls/%s/comments --method POST " ..
      "--field body=%q " ..
      "--field path=%q " ..
      "--field commit_id=%s " ..
      "--field line=%d " ..
      "--field side=RIGHT",
      owner, repo, pr_number, body, path, commit_id, line
    )
  end
end

-- Helper to decode base64, using Neovim's built-in if available
local function decode_base64(encoded)
  local clean = encoded:gsub("%s+", "")
  -- Try Neovim's built-in base64 decode (available in 0.10+)
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, clean)
    if ok then
      return decoded
    end
  end
  -- Fallback to shell command
  return vim.fn.system("echo " .. vim.fn.shellescape(clean) .. " | base64 -d")
end

function M.get_file_content(owner, repo, ref, path, callback)
  -- Blob contents at a given SHA never change, so a hit is always safe to reuse.
  -- Missing entries are nil; `false` records a file known to be absent at this SHA.
  local cached = cache.get_blob(owner, repo, ref, path)
  if cached == false then
    if callback then
      callback(nil, "File not found")
      return
    end
    return nil, "File not found"
  elseif cached then
    if callback then
      callback(cached, nil)
      return
    end
    return cached, nil
  end

  local function is_missing(result)
    return not result or result == "" or result:match("^404:") or result:match("^Not Found")
  end

  -- Use raw.githubusercontent.com directly - most reliable for any file size
  -- URL-encode path components that might have special chars
  local encoded_path = path:gsub(" ", "%%20"):gsub("#", "%%23")
  local raw_url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo, ref, encoded_path)
  -- Prefer the memoised token; the subshell is the fallback before it resolves.
  -- Double quotes either way, so the substitution is interpolated.
  local auth_header = M.auth_token
    and string.format('"Authorization: token %s"', M.auth_token)
    or '"Authorization: token $(gh auth token)"'
  local raw_cmd = string.format('curl -sL -H %s %q 2>&1', auth_header, raw_url)

  if callback then
    async.run(raw_cmd, function(result, err)
      -- Transport failures are transient, so they are never cached
      if err then
        callback(nil, err)
        return
      end
      if is_missing(result) then
        cache.set_blob(owner, repo, ref, path, false)
        callback(nil, "File not found")
        return
      end
      cache.set_blob(owner, repo, ref, path, result)
      callback(result, nil)
    end)
  else
    local result = vim.fn.system(raw_cmd)
    if vim.v.shell_error ~= 0 then
      return nil, result
    end
    if is_missing(result) then
      cache.set_blob(owner, repo, ref, path, false)
      return nil, "File not found"
    end
    cache.set_blob(owner, repo, ref, path, result)
    return result, nil
  end
end

function M.add_suggestion(owner, repo, pr_number, path, start_line, end_line, suggestion)
  local body = string.format("```suggestion\n%s\n```", suggestion)
  return M.add_comment(owner, repo, pr_number, path, end_line, body)
end

function M.delete_comment(owner, repo, comment_id)
  local cmd = string.format(
    "gh api repos/%s/%s/pulls/comments/%s --method DELETE 2>&1",
    owner, repo, comment_id
  )
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    return nil, "Failed to delete comment: " .. result
  end

  return true, nil
end

function M.reply_to_comment(owner, repo, pr_number, comment_id, body)
  local cmd = string.format(
    "gh api repos/%s/%s/pulls/%s/comments/%s/replies -f body=%q 2>&1",
    owner, repo, pr_number, comment_id, body
  )
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    return nil, "Failed to reply: " .. result
  end

  return true, nil
end

function M.submit_review(owner, repo, pr_number, event, body)
  -- gh pr review expects: --approve, --comment, --request-changes
  local event_flags = {
    approve = "--approve",
    comment = "--comment",
    request_changes = "--request-changes",
  }
  
  local flag = event_flags[event]
  if not flag then
    return nil, "Invalid review event: " .. event
  end
  
  -- gh CLI requires a body for --request-changes
  if event == "request_changes" and (not body or body == "") then
    return nil, "Request changes review requires a body"
  end
  
  -- gh CLI requires --body for --comment, but inline comments alone are valid review content
  -- Use a zero-width space as minimal body when no body is provided
  if event == "comment" and (not body or body == "") then
    body = "\xe2\x80\x8b"
  end
  
  local cmd = string.format("gh pr review %s --repo %s/%s %s", pr_number, owner, repo, flag)
  
  if body and body ~= "" then
    cmd = cmd .. string.format(" --body %q", body)
  end

  local result = vim.fn.system(cmd .. " 2>&1")

  if vim.v.shell_error ~= 0 then
    -- Handle common errors with friendlier messages
    if result:match("Can not approve your own pull request") then
      return nil, "Cannot approve your own PR"
    elseif result:match("Can not request changes on your own pull request") then
      return nil, "Cannot request changes on your own PR"
    end
    return nil, "Failed to submit review: " .. result
  end

  return true, nil
end

return M
