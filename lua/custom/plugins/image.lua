return {
  '3rd/image.nvim',
  build = false,
  opts = {
    backend = 'kitty',
    processor = 'magick_cli',
    max_height_window_percentage = 100,
    integrations = {
      markdown = { enabled = false },
      neorg = { enabled = false },
      typst = { enabled = false },
    },
  },
}
