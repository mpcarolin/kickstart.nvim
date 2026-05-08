local M = {}

M.name = 'gitlab'
M.display_name = 'GitLab'
M.entity_label = 'Merge Request'
M.entity_short = 'MR'
M.id_prefix = '!'

function M.matches_remote_url(url)
  if not url or url == '' then
    return false
  end
  return url:find 'gitlab%.' ~= nil
end

local function normalize(mr)
  return {
    id = mr.iid,
    title = mr.title or '',
    description = mr.description or '',
    state = mr.state,
    draft = mr.draft and true or false,
    url = mr.web_url or '',
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    author_login = mr.author and mr.author.username or nil,
    author_name = (mr.author and (mr.author.name or mr.author.username)) or 'unknown',
    labels = mr.labels or {},
    created_at = mr.created_at,
    updated_at = mr.updated_at,
  }
end

function M.list(buf_dir, cb)
  vim.system(
    { 'glab', 'mr', 'list', '-F', 'json', '-P', '100' },
    { cwd = buf_dir, text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local msg = (result.stderr and result.stderr ~= '') and result.stderr or result.stdout
        cb(false, 'glab mr list failed:\n' .. (msg or ''))
        return
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout or '[]')
      if not ok or type(decoded) ~= 'table' then
        cb(false, 'glab: could not parse JSON output')
        return
      end
      local out = {}
      for i, mr in ipairs(decoded) do
        out[i] = normalize(mr)
      end
      cb(true, out)
    end)
  )
end

function M.fetch_description(buf_dir, pr, cb)
  vim.system(
    { 'glab', 'mr', 'view', tostring(pr.id), '-F', 'json' },
    { cwd = buf_dir, text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        cb(nil)
        return
      end
      local ok, full = pcall(vim.json.decode, result.stdout or '')
      if ok and type(full) == 'table' and full.description and full.description ~= '' then
        cb(full.description)
        return
      end
      cb(nil)
    end)
  )
end

function M.checkout(_, pr)
  local out = vim.fn.system { 'glab', 'mr', 'checkout', tostring(pr.id) }
  if vim.v.shell_error ~= 0 then
    return false, out
  end
  vim.cmd 'checktime'
  return true, nil
end

function M.open_web(_, pr)
  vim.fn.system { 'glab', 'mr', 'view', '--web', tostring(pr.id) }
  if vim.v.shell_error ~= 0 then
    return false, 'glab mr view --web failed'
  end
  return true, nil
end

return M
