-- ryanmsnyder/toggleterm-manager.nvim — telescope-based terminal manager
return {
  'ryanmsnyder/toggleterm-manager.nvim',
  dependencies = {
    'akinsho/toggleterm.nvim',
    'nvim-telescope/telescope.nvim',
    'nvim-lua/plenary.nvim',
  },
  config = function()
    local actions = require('toggleterm-manager').actions
    local telescope_actions = require 'telescope.actions'
    require('toggleterm-manager').setup {
      mappings = {
        i = {
          ['<CR>'] = { action = actions.toggle_term, exit_on_action = true },
          ['<C-i>'] = { action = actions.create_term, exit_on_action = false },
          ['<C-d>'] = { action = actions.delete_term, exit_on_action = false },
          ['<C-r>'] = { action = actions.rename_term, exit_on_action = false },
          -- <C-t> toggles the picker off instead of telescope's default open-in-tab
          ['<C-t>'] = { action = telescope_actions.close, exit_on_action = false },
        },
      },
    }
  end,
}
