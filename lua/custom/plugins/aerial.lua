return {
  'stevearc/aerial.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-tree/nvim-web-devicons',
  },
  opts = {
    layout = {
      default_direction = 'right',
    },
    on_attach = function(bufnr)
      vim.keymap.set('n', '{', '<cmd>AerialPrev<CR>', { buffer = bufnr })
      vim.keymap.set('n', '}', '<cmd>AerialNext<CR>', { buffer = bufnr })
    end,
  },
  keys = {
    { '<leader>ty', '<cmd>AerialToggle!<CR>', desc = '[T]oggle Aerial s[Y]mbols' },
  },
}
