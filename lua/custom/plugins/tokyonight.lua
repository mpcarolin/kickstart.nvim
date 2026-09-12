-- An alternative colorscheme, selectable via the `theme` switcher
-- (NVIM_COLORSCHEME="tokyonight"). It does NOT apply itself: application
-- happens in exactly one place, lua/custom/plugins/colorscheme.lua.
return {
  'folke/tokyonight.nvim',
  lazy = false,
  priority = 1000,
  ---@diagnostic disable-next-line: missing-fields
  opts = {
    styles = {
      comments = { italic = false }, -- keep consistent with everforest italics = false
    },
  },
}
