return {
  'rcarriga/nvim-notify',
  config = function()
    local notify = require 'notify'
    notify.setup {
      stages = 'static',
      timeout = 3000,
      top_down = true,
      on_open = function(win)
        local config = vim.api.nvim_win_get_config(win)
        local win_width = config.width or 0
        local editor_width = vim.o.columns
        config.col = math.floor((editor_width - win_width) / 2)
        vim.api.nvim_win_set_config(win, config)
      end,
    }
    vim.notify = notify
  end,
}
