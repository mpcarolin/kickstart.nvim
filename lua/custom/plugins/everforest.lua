return {
  'neanias/everforest-nvim',
  version = false,
  lazy = false,
  priority = 1000, -- load before other start plugins
  config = function()
    local backgrounds = { 'soft', 'medium', 'hard' }

    local function apply(bg)
      require('everforest').setup {
        background = bg, -- 'hard' | 'medium' | 'soft'
        italics = false, -- keep consistent with tokyonight comments = no italic
      }
      vim.g.everforest_bg = bg
      vim.cmd.colorscheme 'everforest'
      vim.notify('everforest: ' .. bg, vim.log.levels.INFO)
    end

    apply 'medium' -- default

    -- cycle soft -> medium -> hard -> soft
    vim.keymap.set('n', '<leader>tb', function()
      local cur = vim.g.everforest_bg or 'medium'
      local idx = 1
      for i, v in ipairs(backgrounds) do
        if v == cur then
          idx = i
        end
      end
      apply(backgrounds[idx % #backgrounds + 1])
    end, { desc = '[T]oggle everforest [b]ackground hardness' })

    -- jump straight to one
    vim.keymap.set('n', '<leader>ts', function()
      apply 'soft'
    end, { desc = 'everforest [s]oft' })
    vim.keymap.set('n', '<leader>tm', function()
      apply 'medium'
    end, { desc = 'everforest [m]edium' })
    vim.keymap.set('n', '<leader>th', function()
      apply 'hard'
    end, { desc = 'everforest [h]ard' })
  end,
}
