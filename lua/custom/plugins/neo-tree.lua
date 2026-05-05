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
    local fs_defaults = require('neo-tree.defaults').filesystem
    opts.notes = vim.tbl_deep_extend('force', vim.deepcopy(fs_defaults), {
      bind_to_cwd = false,
      follow_current_file = { enabled = false },
    })

    vim.api.nvim_set_hl(0, 'NeoTreeGitBranch', { link = 'Comment', default = true })

    require('neo-tree').setup(opts)

    -- Sync Neovim's cwd with Neo-tree's filesystem root on every render. The
    -- built-in `bind_to_cwd` + `cwd_target` is supposed to handle this but is
    -- flaky in practice.
    local cwd_handler_id = 'sync_cwd_to_neotree_root'
    local branch_handler_id = 'render_git_branch_virt_line'
    local ns = vim.api.nvim_create_namespace('neotree_git_branch')

    local function compute_branch(path)
      if not path or vim.fn.isdirectory(path) == 0 then
        return nil
      end
      local result = vim.system(
        { 'git', '-C', path, 'branch', '--show-current' },
        { text = true }
      ):wait()
      if result.code ~= 0 then
        return nil
      end
      local branch = vim.trim(result.stdout or '')
      if branch == '' then
        return nil
      end
      return branch
    end

    -- Track per-buffer branch so we can repaint after neo-tree rewrites the
    -- buffer (nvim_buf_set_lines clears extmarks on overwritten ranges).
    local branch_by_buf = {}
    local attached_bufs = {}

    local function paint_branch(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      local branch = branch_by_buf[bufnr]
      if not branch then return end
      if vim.api.nvim_buf_line_count(bufnr) < 1 then return end
      -- Attach to line 0 (the root directory line) with virt_lines below it.
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
        virt_lines = { { { ' 󰊢 ' .. branch, 'NeoTreeGitBranch' } } },
      })
    end

    local function ensure_attached(bufnr)
      if attached_bufs[bufnr] then return end
      attached_bufs[bufnr] = true
      vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function()
          vim.schedule(function() paint_branch(bufnr) end)
        end,
        on_detach = function()
          attached_bufs[bufnr] = nil
          branch_by_buf[bufnr] = nil
        end,
      })
    end

    local function ensure_subscribed()
      local events = require 'neo-tree.events'

      events.unsubscribe { event = events.AFTER_RENDER, id = cwd_handler_id }
      events.subscribe {
        event = events.AFTER_RENDER,
        id = cwd_handler_id,
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

      -- Render the current git branch as a virt_line attached to the last
      -- buffer line. virt_lines render in the buffer's window beneath that
      -- line, so it sits at the bottom of the tree, just above the
      -- source-selector statusline.
      events.unsubscribe { event = events.AFTER_RENDER, id = branch_handler_id }
      events.subscribe {
        event = events.AFTER_RENDER,
        id = branch_handler_id,
        handler = function(state)
          if not (state and state.name == 'filesystem' and state.path and state.bufnr) then
            return
          end
          if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
          branch_by_buf[state.bufnr] = compute_branch(state.path)
          ensure_attached(state.bufnr)
          paint_branch(state.bufnr)
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
