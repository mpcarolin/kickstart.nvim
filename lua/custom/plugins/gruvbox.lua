-- An alternative colorscheme, selectable via the `theme` switcher
-- (NVIM_COLORSCHEME="gruvbox"). It does NOT apply itself: application
-- happens in exactly one place, lua/custom/plugins/colorscheme.lua.
return {
  'ellisonleao/gruvbox.nvim',
  lazy = false,
  priority = 1000,
  opts = {
    italic = { -- keep consistent with everforest italics = false
      strings = false,
      comments = false,
      operators = false,
      folds = false,
    },
  },
}
