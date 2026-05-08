local M = {}

local providers = {
  require 'custom.mr_picker.providers.gitlab',
  require 'custom.mr_picker.providers.github',
}

function M.detect(buf_dir)
  local result = vim.system({ 'git', '-C', buf_dir, 'remote', 'get-url', 'origin' }, { text = true }):wait()
  if result.code ~= 0 then
    return nil, 'not a git repo or no origin remote'
  end
  local url = (result.stdout or ''):gsub('%s+$', '')
  if url == '' then
    return nil, 'not a git repo or no origin remote'
  end
  for _, p in ipairs(providers) do
    if p.matches_remote_url(url) then
      return p
    end
  end
  return nil, 'origin is not a recognized provider: ' .. url
end

return M
