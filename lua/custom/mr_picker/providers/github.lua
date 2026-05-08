local M = {}

M.name = 'github'
M.display_name = 'GitHub'
M.entity_label = 'Pull Request'
M.entity_short = 'PR'
M.id_prefix = '#'

function M.matches_remote_url(url)
  if not url or url == '' then
    return false
  end
  if url:find 'github%.com' then
    return true
  end
  if url:find 'github%.' then
    return true
  end
  return false
end

local function not_implemented()
  vim.notify(
    'GitHub adapter not yet implemented — install `gh` and add gh support to providers/github.lua',
    vim.log.levels.WARN,
    { title = 'mr_picker' }
  )
end

function M.list(_, cb)
  not_implemented()
  cb(false, 'not implemented')
end

function M.fetch_description(_, _, cb)
  cb(nil)
end

function M.checkout()
  not_implemented()
  return false, 'not implemented'
end

function M.open_web()
  not_implemented()
  return false, 'not implemented'
end

return M
