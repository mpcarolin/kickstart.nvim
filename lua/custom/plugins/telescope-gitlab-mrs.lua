-- Lazy.nvim spec that wires <leader>gm to the GitLab MR picker.
-- Picker logic lives in lua/custom/gitlab_mr_picker.lua.
return {
  'nvim-telescope/telescope.nvim',
  optional = true,
  keys = {
    {
      '<leader>gm',
      function()
        require('custom.gitlab_mr_picker').open()
      end,
      desc = '[G]itLab [M]erge requests',
    },
  },
}
