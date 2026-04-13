return {
  'rcarriga/nvim-notify',
  config = function()
    local notify = require 'notify'
    notify.setup {
      stages = 'fade_in_slide_out',
      timeout = 3000,
    }
    vim.notify = notify
  end,
}
