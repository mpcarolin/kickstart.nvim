-- akinsho/toggleterm.nvim — managed, toggleable terminals
return {
  'akinsho/toggleterm.nvim',
  version = '*',
  dependencies = { 'nvim-telescope/telescope.nvim' },
  keys = {
    -- <C-\> lives here (not in config()) so pressing it loads the plugin and
    -- the callback runs after load — fixes cold-start "no terminal created"
    {
      [[<C-\>]],
      function()
        local count = vim.v.count
        if count > 0 then
          -- a count targets terminal N, creating it if it doesn't exist yet
          vim.cmd(count .. 'ToggleTerm')
          return
        end
        local term = require 'toggleterm.terminal'
        if vim.tbl_isempty(term.get_all(true)) then
          vim.cmd '1ToggleTerm'
        else
          vim.cmd 'ToggleTerm'
        end
      end,
      mode = { 'n', 'i', 't' },
      desc = 'Toggle terminal (create if none)',
    },
    { '<leader>tt', '<cmd>ToggleTerm<CR>', desc = '[T]oggle [T]erminal (float)' },
    { '<leader>tf', function() _G.toggleterm_set_direction 'float' end, desc = '[T]erminal [F]loat (move or open)' },
    { '<leader>tv', function() _G.toggleterm_set_direction 'vertical' end, desc = '[T]erminal [V]ertical (move or open)' },
    { '<leader>ts', function() _G.toggleterm_set_direction 'horizontal' end, desc = '[T]erminal horizontal [S]plit (move or open)' },
    { '<leader>td', function() _G.toggleterm_cycle_direction() end, desc = '[T]erminal cycle [D]irection' },
    { '<leader>ta', '<cmd>ToggleTermToggleAll<CR>', desc = '[T]erminal toggle [A]ll' },
    -- fixed numbered terminals + a picker to jump between live ones
    { '<leader>t1', '<cmd>1ToggleTerm<CR>', desc = '[T]erminal [1]' },
    { '<leader>t2', '<cmd>2ToggleTerm<CR>', desc = '[T]erminal [2]' },
    { '<leader>t3', '<cmd>3ToggleTerm<CR>', desc = '[T]erminal [3]' },
    { '<leader>t4', '<cmd>4ToggleTerm<CR>', desc = '[T]erminal [4]' },
    -- send current line / visual selection to the terminal
    { '<leader>tl', '<cmd>ToggleTermSendCurrentLine<CR>', desc = '[T]erminal send [L]ine' },
    { '<leader>to', '<cmd>ToggleTermSendVisualSelection<CR>', mode = 'v', desc = '[T]erminal send selecti[O]n' },
  },
  opts = {
    -- <C-\> is bound in the keys table above so it creates a terminal on first
    -- press (toggleterm's open_mapping no-ops when zero terminals exist yet)
    direction = 'float',
    size = function(term)
      if term.direction == 'horizontal' then
        return 15
      elseif term.direction == 'vertical' then
        return math.floor(vim.o.columns * 0.4)
      end
    end,
    float_opts = {
      border = 'curved',
    },
    -- match nvim background, shade non-float terminals slightly darker
    shade_terminals = true,
    start_in_insert = true,
    persist_size = true,
    persist_mode = true,
  },
  config = function(_, opts)
    require('toggleterm').setup(opts)

    -- resolve the currently focused terminal (falls back to last focused)
    local function focused_term()
      local term = require 'toggleterm.terminal'
      local id = (term.get_focused_id and term.get_focused_id())
        or (term.get_last_focused and term.get_last_focused() and term.get_last_focused().id)
      return id and term.get(id, true)
    end

    -- move focused terminal to `direction`; if none focused, open a new one there
    _G.toggleterm_set_direction = function(direction)
      local focused = focused_term()
      if focused and focused:is_open() then
        focused:close()
        focused:change_direction(direction)
        focused:open()
      else
        vim.cmd('ToggleTerm direction=' .. direction)
      end
    end

    -- rotate the focused terminal float → horizontal → vertical → float
    local order = { 'float', 'horizontal', 'vertical' }
    _G.toggleterm_cycle_direction = function()
      local focused = focused_term()
      if not (focused and focused:is_open()) then
        return
      end
      local i = 1
      for k, d in ipairs(order) do
        if d == focused.direction then
          i = k
        end
      end
      _G.toggleterm_set_direction(order[(i % #order) + 1])
    end

    -- swap the focused terminal for the next/prev one, same open window
    local function cycle(step)
      local term = require 'toggleterm.terminal'
      local all = term.get_all(true)
      if #all < 2 then
        return
      end
      table.sort(all, function(a, b)
        return a.id < b.id
      end)

      local cur_id = term.get_focused_id and term.get_focused_id()
      if not cur_id and term.get_last_focused then
        local last = term.get_last_focused()
        cur_id = last and last.id
      end

      if not cur_id then
        all[1]:open()
        return
      end

      local idx
      for i, t in ipairs(all) do
        if t.id == cur_id then
          idx = i
          break
        end
      end
      if not idx then
        all[1]:open()
        return
      end

      local target = all[((idx - 1 + step) % #all) + 1]
      local cur = all[idx]
      local direction = cur.direction
      cur:close()
      target:open(nil, direction)
    end

    -- picker + cycle bound across normal/insert/terminal modes
    local map = function(lhs, fn, desc)
      vim.keymap.set({ 'n', 'i', 't' }, lhs, function()
        if vim.fn.mode() == 't' then
          vim.cmd 'stopinsert'
        end
        fn()
      end, { desc = desc, silent = true })
    end

    -- <C-\> is bound in the keys table so it can trigger plugin load.
    -- <C-t> (manager picker) is bound at top level in init.lua so it works
    -- before toggleterm loads.

    map('<C-]>', function()
      cycle(1)
    end, 'Terminal: next')
    map('<C-}>', function()
      cycle(-1)
    end, 'Terminal: prev')

    -- emulator-independent path to the same manager
    vim.keymap.set('n', '<leader>tp', function()
      require('toggleterm-manager').open {}
    end, { desc = '[T]erminal [P]ick / manage', silent = true })

    -- terminal-mode navigation: escape to normal, window moves with <C-hjkl>
    local function set_terminal_keymaps()
      local o = { buffer = 0 }
      vim.keymap.set('t', '<esc>', [[<C-\><C-n>]], o)
      vim.keymap.set('t', '<C-h>', [[<Cmd>wincmd h<CR>]], o)
      vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]], o)
      vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]], o)
      vim.keymap.set('t', '<C-l>', [[<Cmd>wincmd l<CR>]], o)
    end
    vim.api.nvim_create_autocmd('TermOpen', {
      pattern = 'term://*toggleterm#*',
      callback = set_terminal_keymaps,
    })
  end,
}
