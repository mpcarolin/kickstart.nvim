return {
  'greggh/claude-code.nvim',
  dependencies = {
    'nvim-lua/plenary.nvim', -- Required for git operations
  },
  config = function()
    require('claude-code').setup {
      command = 'claude',
      window = {
        position = 'vertical',
        split_ratio = 0.3,
        enter_insert = true,
        start_in_normal_mode = true,
        hide_numbers = true,
        hide_signcolumn = true,
      },
      -- Keymaps
      keymaps = {
        toggle = {
          normal = '<leader>cc', -- Normal mode keymap for toggling Claude Code, false to disable
          terminal = '<C-.>', -- Terminal mode keymap for toggling Claude Code, false to disable
          variants = {
            continue = '<leader>cR', -- Normal mode keymap for Claude Code with continue flag
            verbose = '<leader>cV', -- Normal mode keymap for Claude Code with verbose flag
          },
        },
        window_navigation = true, -- Enable window navigation keymaps (<C-h/j/k/l>)
        scrolling = true, -- Enable scrolling keymaps (<C-f/b>) for page up/down
      },
    }
  end,
}
