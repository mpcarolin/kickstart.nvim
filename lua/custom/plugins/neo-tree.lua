local notes_dir = vim.g.notes_dir

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
  opts = {
    sources = {
      'filesystem',
      'buffers',
      'git_status',
      'custom.neo_tree_sources.notes',
    },
    source_selector = {
      winbar = false,
      statusline = true,
      separator = '',
      sources = {
        { source = 'filesystem',  display_name = ' 󰉓 ' },
        { source = 'notes',       display_name = ' 󰠮 ' },
        { source = 'git_status',  display_name = ' 󰊢 ' },
        { source = 'buffers',     display_name = ' 󰈚 ' },
      },
    },
  },
  config = function(_, opts)
    -- The notes source is registered by name "notes" but neo-tree's setup
    -- only seeds default config under per-source keys for the built-in
    -- sources. Without this, state.filtered_items / state.path / etc. are
    -- nil for the notes source and create_item throws on every entry.
    -- Inherit the filesystem defaults wholesale, then override the bits
    -- that should differ for a pinned notes tree.
    local fs_defaults = require('neo-tree.defaults').filesystem
    opts.notes = vim.tbl_deep_extend('force', vim.deepcopy(fs_defaults), {
      bind_to_cwd = false,
      follow_current_file = { enabled = false },
    })

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
          if notes_dir and state.path == notes_dir then
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

    -- <leader>n: open the sidebar showing the notes source. If the
    -- sidebar is already open on the notes source, close it (toggle).
    -- If it's open on a different source, switch to notes.
    local function toggle_notes()
      if not notes_dir or notes_dir == '' then
        vim.notify(
          'vim.g.notes_dir is not set. Add it to env.lua (see env.template.lua).',
          vim.log.levels.WARN,
          { title = 'neo-tree notes' }
        )
        return
      end
      if vim.fn.isdirectory(notes_dir) == 0 then
        vim.notify(
          string.format('notes_dir does not exist: %s', notes_dir),
          vim.log.levels.WARN,
          { title = 'neo-tree notes' }
        )
        return
      end
      -- Detect "sidebar currently showing notes" by scanning windows for
      -- a neo-tree filetype whose buffer name encodes source=notes.
      -- neo-tree buffer names look like: neo-tree filesystem [1]
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == 'neo-tree' then
          local name = vim.api.nvim_buf_get_name(buf)
          if name:match('neo%-tree notes') then
            vim.cmd('Neotree close')
            return
          end
        end
      end
      vim.cmd(string.format(
        'Neotree source=notes dir=%s reveal=false',
        vim.fn.fnameescape(notes_dir)
      ))
    end

    vim.keymap.set('n', '<leader>n', toggle_notes, { desc = '[N]otes tree (toggle)' })
  end,
}
