return {
  'epwalsh/obsidian.nvim',
  version = '*', -- recommended, use latest release instead of latest commit
  lazy = true,
  event = {
    -- If you want to use the home shortcut '~' here you need to call 'vim.fn.expand'.
    -- E.g. "BufReadPre " .. vim.fn.expand "~" .. "/my-vault/*.md"
    -- refer to `:h file-pattern` for more examples
    'BufReadPre "/Users/mpcarolin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal/*.md"',
    'BufNewFile "/Users/mpcarolin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal/*.md"',
  },
  dependencies = {
    -- Required.
    'nvim-lua/plenary.nvim',

    -- see below for full list of optional dependencies 👇
  },
  opts = {
    workspaces = {
      {
        name = 'personal',
        path = '/Users/mpcarolin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal/*.md',
      },
    },

    -- see below for full list of options 👇
  },
}
