-- Read the todo file path from env.lua (gitignored) with a fallback default.
local todo_file = vim.g.todo_file or vim.fn.expand('~/Development/todo.md')

-- Run an action then archive completed todos.
-- vim.schedule lets the toggle's transaction (and on_add metadata callbacks)
-- settle before we sweep the buffer.
local function then_archive(action)
  return function()
    vim.cmd(action)
    vim.schedule(function()
      vim.cmd('Checkmate archive')
    end)
  end
end

return {
  'bngarren/checkmate.nvim',
  ft = 'markdown',
  keys = {
    {
      '<leader>ko',
      function()
        vim.cmd('edit ' .. vim.fn.fnameescape(todo_file))
      end,
      desc = '[K]heckmate [O]pen todo file',
    },
  },
  opts = {
    -- Override every upstream <leader>T* default to <leader>k*.
    -- `rhs` must be a Neovim keymap RHS (string or function), NOT a bare action name.
    keys = {
      ['<leader>Tt'] = false,
      ['<leader>Tc'] = false,
      ['<leader>Tu'] = false,
      ['<leader>T='] = false,
      ['<leader>T-'] = false,
      ['<leader>Tn'] = false,
      ['<leader>Tr'] = false,
      ['<leader>TR'] = false,
      ['<leader>Ta'] = false,
      ['<leader>TF'] = false,
      ['<leader>Tv'] = false,
      ['<leader>T]'] = false,
      ['<leader>T['] = false,

      ['<leader>kt'] = { rhs = then_archive('Checkmate toggle'), desc = 'Toggle todo (auto-archive)', modes = { 'n', 'v' } },
      ['<leader>kc'] = { rhs = then_archive('Checkmate check'), desc = 'Check todo (auto-archive)', modes = { 'n', 'v' } },
      ['<leader>ku'] = { rhs = '<cmd>Checkmate uncheck<CR>', desc = 'Uncheck todo', modes = { 'n', 'v' } },
      ['<leader>k='] = { rhs = '<cmd>Checkmate cycle_next<CR>', desc = 'Cycle next state', modes = { 'n', 'v' } },
      ['<leader>k-'] = { rhs = '<cmd>Checkmate cycle_previous<CR>', desc = 'Cycle previous state', modes = { 'n', 'v' } },
      ['<leader>kn'] = { rhs = '<cmd>Checkmate create<CR>', desc = 'New todo (or convert lines)', modes = { 'n', 'v' } },
      ['<leader>kr'] = { rhs = '<cmd>Checkmate remove<CR>', desc = 'Remove marker', modes = { 'n', 'v' } },
      ['<leader>kR'] = { rhs = '<cmd>Checkmate metadata remove_all<CR>', desc = 'Remove all metadata', modes = { 'n', 'v' } },
      ['<leader>ka'] = { rhs = '<cmd>Checkmate archive<CR>', desc = 'Archive completed', modes = { 'n' } },
      ['<leader>kF'] = { rhs = '<cmd>Checkmate select_todo<CR>', desc = 'Pick todo', modes = { 'n' } },
      ['<leader>kv'] = { rhs = '<cmd>Checkmate metadata select_value<CR>', desc = 'Select metadata value', modes = { 'n' } },
      ['<leader>k]'] = { rhs = '<cmd>Checkmate metadata jump_next<CR>', desc = 'Next metadata', modes = { 'n' } },
      ['<leader>k['] = { rhs = '<cmd>Checkmate metadata jump_previous<CR>', desc = 'Previous metadata', modes = { 'n' } },
    },
    -- Metadata keymaps: shadow upstream <leader>T{p,s,d} defaults onto <leader>k{p,s,d}.
    metadata = {
      priority = { key = '<leader>kp' },
      started = { key = '<leader>ks' },
      done = { key = '<leader>kd' },
    },
    archive = {
      heading = { title = 'done', level = 2 },
    },
  },
}
