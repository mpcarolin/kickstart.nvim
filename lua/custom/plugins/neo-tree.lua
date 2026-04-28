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

    -- Sync Neovim's cwd with Neo-tree's filesystem root on every render. The
    -- built-in `bind_to_cwd` + `cwd_target` is supposed to handle this but is
    -- flaky in practice. We set both the global cwd (via :cd) and clear any
    -- window-local cwds in non-neo-tree windows (fugitive, telescope, etc.
    -- often leave :lcd state behind, which shadows :cd in `:pwd`).
    --
    -- Re-subscribe on FileType neo-tree because neo-tree's setup() calls
    -- events.clear_all_events(); if anything re-triggers setup after ours
    -- runs, our subscription dies. The autocmd makes recovery automatic.
    local handler_id = 'sync_cwd_to_neotree_root'
    local function ensure_subscribed()
      local events = require 'neo-tree.events'
      events.unsubscribe { event = events.AFTER_RENDER, id = handler_id }
      events.subscribe {
        event = events.AFTER_RENDER,
        id = handler_id,
        handler = function(state)
          if not (state and state.name == 'filesystem' and state.path) then
            return
          end
          if vim.fn.getcwd(-1, -1) ~= state.path then
            vim.cmd.cd(vim.fn.fnameescape(state.path))
          end
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.fn.haslocaldir(win) == 1 then
              local buf = vim.api.nvim_win_get_buf(win)
              if vim.bo[buf].filetype ~= 'neo-tree' then
                vim.api.nvim_win_call(win, function()
                  vim.cmd('lcd ' .. vim.fn.fnameescape(state.path))
                end)
              end
            end
          end
        end,
      }
    end

    ensure_subscribed()
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'neo-tree',
      callback = ensure_subscribed,
    })
  end,
}
