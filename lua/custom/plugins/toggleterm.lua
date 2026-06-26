-- akinsho/toggleterm.nvim — managed, toggleable terminals
return {
  'akinsho/toggleterm.nvim',
  version = '*',
  dependencies = { 'nvim-telescope/telescope.nvim' },
  keys = {
    { '<leader>tt', '<cmd>ToggleTerm<CR>', desc = '[T]oggle [T]erminal (float)' },
    { '<leader>tf', '<cmd>ToggleTerm direction=float<CR>', desc = '[T]erminal [F]loat' },
    { '<leader>tv', '<cmd>ToggleTerm direction=vertical<CR>', desc = '[T]erminal [V]ertical split' },
    { '<leader>ts', '<cmd>ToggleTerm direction=horizontal<CR>', desc = '[T]erminal horizontal [S]plit' },
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
    -- <C-\> is bound manually in config() so it creates a terminal on first
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

    -- telescope picker over all open terminals, with live buffer preview
    local function pick_terminal()
      local term = require 'toggleterm.terminal'
      local all = term.get_all(true)
      if vim.tbl_isempty(all) then
        vim.notify 'No terminals open'
        return
      end

      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local previewers = require 'telescope.previewers'
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'

      pickers
        .new({}, {
          prompt_title = 'Terminals',
          finder = finders.new_table {
            results = all,
            entry_maker = function(t)
              local name = t._display_name and t:_display_name() or t.name
              local display = string.format('%d: %s', t.id, name or '')
              return {
                value = t,
                display = display,
                ordinal = display,
                bufnr = t.bufnr,
              }
            end,
          },
          sorter = conf.generic_sorter {},
          previewer = previewers.new_buffer_previewer {
            title = 'Terminal preview',
            define_preview = function(self, entry)
              local src = entry.value.bufnr
              if not (src and vim.api.nvim_buf_is_valid(src)) then
                return
              end
              local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
              vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
            end,
          },
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry and entry.value then
                entry.value:open()
              end
            end)
            return true
          end,
        })
        :find()
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

    -- <C-\>: ensure a terminal exists on first press, else toggle.
    -- toggleterm's open_mapping can no-op when zero terminals exist yet.
    map([[<C-\>]], function()
      local term = require 'toggleterm.terminal'
      if vim.tbl_isempty(term.get_all(true)) then
        vim.cmd '1ToggleTerm'
      else
        vim.cmd 'ToggleTerm'
      end
    end, 'Toggle terminal (create if none)')

    map('<C-t>', pick_terminal, 'Terminal picker (telescope)')
    map('<C-]>', function()
      cycle(1)
    end, 'Terminal: next')
    map('<C-}>', function()
      cycle(-1)
    end, 'Terminal: prev')

    -- emulator-independent path to the same picker
    vim.keymap.set('n', '<leader>tp', pick_terminal, { desc = '[T]erminal [P]ick / select', silent = true })

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
