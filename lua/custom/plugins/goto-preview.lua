return {
  'rmagatti/goto-preview',
  dependencies = { 'rmagatti/logger.nvim' },
  event = 'BufEnter',
  config = true,
  keys = {
    {
      'gpd',
      "<cmd>lua require('goto-preview').goto_preview_definition()<CR>",
      noremap = true,
      desc = 'goto preview definition',
    },
    {
      'gpD',
      "<cmd>lua require('goto-preview').goto_preview_declaration()<CR>",
      noremap = true,
      desc = 'goto preview declaration',
    },
    {
      'gpi',
      "<cmd>lua require('goto-preview').goto_preview_implementation()<CR>",
      noremap = true,
      desc = 'goto preview implementation',
    },
    {
      'gpt',
      "<cmd>lua require('goto-preview').goto_preview_type_definition()<CR>",
      noremap = true,
      desc = 'goto preview type definition',
    },
    {
      'gpr',
      "<cmd>lua require('goto-preview').goto_preview_references()<CR>",
      noremap = true,
      desc = 'goto preview references',
    },
    {
      'gP',
      "<cmd>lua require('goto-preview').close_all_win()<CR>",
      noremap = true,
      desc = 'close all preview windows',
    },
  },
}
