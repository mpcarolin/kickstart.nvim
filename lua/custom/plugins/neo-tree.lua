return {
  'nvim-neo-tree/neo-tree.nvim',
  branch = 'v3.x',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons',
    'MunifTanjim/nui.nvim',
  },
  lazy = false,
  ---@module "neo-tree"
  ---@type neotree.Config?
  opts = {},
  config = function(_, opts)
    require('neo-tree').setup(opts)

    -- Sync Neovim's global cwd with Neo-tree's filesystem root on every render.
    -- The built-in `bind_to_cwd` + `cwd_target` config is supposed to handle this,
    -- but it's flaky in practice: a stray window-local cwd (from :lcd, fugitive,
    -- telescope, etc.) shadows the global :cd so :pwd never updates. Subscribing
    -- to AFTER_RENDER and calling :cd ourselves makes the behavior explicit.
    local events = require 'neo-tree.events'
    events.subscribe {
      event = events.AFTER_RENDER,
      handler = function(state)
        if state and state.name == 'filesystem' and state.path then
          if vim.fn.getcwd(-1, -1) ~= state.path then
            vim.cmd.cd(vim.fn.fnameescape(state.path))
          end
        end
      end,
    }
  end,
}
