return {
  'rest-nvim/rest.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    opts = function(_, opts)
      opts.ensure_ed = opts.ensure_installed or {}
      table.insert(opts.ensure_ed, 'http')
    end,
  },
}
