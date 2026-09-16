--- Reads the active theme chosen by the `theme` switcher (dotfiles/bin/theme).
---
--- The switcher writes `~/.local/state/dotfiles-theme/current` as flat
--- `KEY="value"` lines. That file is runtime state and lives outside the
--- dotfiles repo, so switching themes never dirties git.
---
--- Everything is optional: with no state file (fresh machine, or nvim used
--- without the switcher) the defaults below apply and nothing breaks.

local M = {}

M.defaults = {
  colorscheme = 'everforest',
  background = 'dark',
  variant = 'medium',
}

local function state_path()
  local xdg = vim.env.XDG_STATE_HOME
  if xdg and xdg ~= '' then
    return xdg .. '/dotfiles-theme/current'
  end
  return vim.fn.expand '~/.local/state/dotfiles-theme/current'
end

--- Parse `KEY="value"` / `KEY=value` lines, ignoring blanks and `#` comments.
---@param path string
---@return table<string, string>
local function parse(path)
  local out = {}
  local fd = io.open(path, 'r')
  if not fd then
    return out
  end
  for line in fd:lines() do
    if not line:match '^%s*#' then
      local k, v = line:match '^%s*([%w_]+)%s*=%s*"(.*)"%s*$'
      if not k then
        k, v = line:match '^%s*([%w_]+)%s*=%s*(%S*)%s*$'
      end
      -- Empty values are dropped here so callers only ever see real values
      -- and can fall back with a plain `or`.
      if k and v ~= '' then
        out[k] = v
      end
    end
  end
  fd:close()
  return out
end

--- The active theme, with defaults filled in for anything missing.
---@return { colorscheme: string, background: string, variant: string, name: string|nil, wallpaper: string|nil }
function M.read()
  local s = parse(state_path())
  local bg = s.NVIM_BACKGROUND
  if bg ~= 'dark' and bg ~= 'light' then
    bg = M.defaults.background
  end

  return {
    name = s.THEME_NAME,
    colorscheme = s.NVIM_COLORSCHEME or M.defaults.colorscheme,
    background = bg,
    variant = s.NVIM_VARIANT or M.defaults.variant,
    wallpaper = s.WALLPAPER,
  }
end

return M
