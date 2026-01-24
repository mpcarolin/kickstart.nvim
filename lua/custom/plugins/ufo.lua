return {
  'kevinhwang91/nvim-ufo',
  dependencies = {
    { 'kevinhwang91/promise-async' },
  },
  config = function()
    -- Set vim options for folding
    vim.o.foldcolumn = '1'
    vim.o.foldlevel = 99
    vim.o.foldlevelstart = 99
    vim.o.foldenable = true

    -- Customize fold column symbols
    vim.o.fillchars = [[eob: ,fold: ,foldopen:▼,foldclose:▶,foldsep:│]]

    local capabilities = vim.lsp.protocol.make_client_capabilities()
    capabilities.textDocument.foldingRange = {
      dynamicRegistration = false,
      lineFoldingOnly = true,
    }
    local language_servers = vim.lsp.get_clients() -- or list servers manually like {'gopls', 'clangd'}
    for _, ls in ipairs(language_servers) do
      require('lspconfig')[ls].setup {
        capabilities = capabilities,
        -- you can add other fields for setting up lsp server in this table
      }
    end
    -- Setup ufo with lsp and indent as fallback
    require('ufo').setup {
      provider_selector = function(bufnr, filetype, buftype)
        return { 'lsp', 'indent' }
      end,
    }
  end,
  keys = {
    {
      'zR',
      function()
        require('ufo').openAllFolds()
      end,
      desc = 'Open all folds',
    },
    {
      'zM',
      function()
        require('ufo').closeAllFolds()
      end,
      desc = 'Close all folds',
    },
    {
      'zk',
      function()
        require('ufo').peekFoldedLinesUnderCursor()
      end,
      desc = 'Peek folded lines under cursor',
    },
    {
      'zr',
      function()
        require('ufo').openFoldsExceptKinds()
      end,
      desc = 'Open folds by one level',
    },
    {
      'zm',
      function()
        require('ufo').closeFoldsWith()
      end,
      desc = 'Close folds by one level',
    },
  },
}
