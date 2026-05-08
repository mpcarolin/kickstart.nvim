-- Lazy.nvim spec that wires <leader>gm to the MR/PR picker.
-- Picker logic lives in lua/custom/mr_picker.lua; provider is auto-detected.
return {
  'nvim-telescope/telescope.nvim',
  optional = true,
  keys = {
    {
      '<leader>gm',
      function()
        require('custom.mr_picker').open()
      end,
      desc = '[G]it [M]erge/Pull requests',
    },
  },
}
