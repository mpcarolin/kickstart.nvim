-- The single place a colorscheme is applied.
--
-- Reads the active theme from `custom.theme` (written by dotfiles/bin/theme) and
-- applies it at startup, so a new nvim always matches the rest of the desktop.
-- `theme set` also sends SIGUSR1 to running instances, which re-reads the state
-- and restyles live — no socket, no watcher.
--
-- Nothing else in this config should call `vim.cmd.colorscheme`.

return {
  'neanias/everforest-nvim',
  version = false,
  lazy = false,
  priority = 1000, -- load before other start plugins
  config = function()
    local theme = require 'custom.theme'
    local hardness = { 'soft', 'medium', 'hard' }

    --- Apply a colorscheme. `variant` is everforest-specific and ignored by
    --- other families.
    ---@param spec { colorscheme: string, background: string, variant: string }
    local function apply(spec)
      vim.o.background = spec.background

      if spec.colorscheme == 'everforest' then
        require('everforest').setup {
          background = spec.variant, -- 'soft' | 'medium' | 'hard'
          italics = false,
        }
        vim.g.everforest_bg = spec.variant
      end

      local ok, err = pcall(vim.cmd.colorscheme, spec.colorscheme)
      if not ok then
        vim.notify('theme: could not apply ' .. spec.colorscheme .. ': ' .. tostring(err), vim.log.levels.ERROR)
        return false
      end
      return true
    end

    --- Re-read the state file and apply whatever it now says.
    local function reload(opts)
      local spec = theme.read()
      if apply(spec) and not (opts or {}).quiet then
        vim.notify('theme: ' .. (spec.name or spec.colorscheme) .. ' (' .. spec.background .. '/' .. spec.variant .. ')', vim.log.levels.INFO)
      end
    end

    -- Startup: quiet, so opening nvim doesn't print a theme message every time.
    reload { quiet = true }

    vim.api.nvim_create_user_command('ThemeReload', function()
      reload()
    end, { desc = 'Re-read the active theme and re-apply it' })

    -- `theme set` pushes SIGUSR1 to live instances.
    vim.api.nvim_create_autocmd('Signal', {
      pattern = 'SIGUSR1',
      desc = 'Re-apply the theme when the switcher signals a change',
      callback = function()
        reload()
      end,
    })

    -- Hardness overrides for the current session. These deliberately do not
    -- write the state file — they are a nudge, not a theme switch.
    local function set_hardness(bg)
      local spec = theme.read()
      spec.variant = bg
      apply(spec)
      vim.notify('everforest: ' .. bg, vim.log.levels.INFO)
    end

    -- soft -> medium -> hard -> soft
    local next_hardness = {}
    for i, h in ipairs(hardness) do
      next_hardness[h] = hardness[i % #hardness + 1]
    end

    vim.keymap.set('n', '<leader>tb', function()
      local cur = vim.g.everforest_bg or 'medium'
      set_hardness(next_hardness[cur] or 'medium')
    end, { desc = '[T]oggle everforest [b]ackground hardness' })

    -- <leader>ts / tm / th — one map per hardness, keyed by its first letter.
    for _, h in ipairs(hardness) do
      local initial = h:sub(1, 1)
      vim.keymap.set('n', '<leader>t' .. initial, function()
        set_hardness(h)
      end, { desc = 'everforest [' .. initial .. ']' .. h:sub(2) })
    end
  end,
}
