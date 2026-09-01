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
    { '<leader>tb', function() _G.toggleterm_toggle_winbar() end, desc = '[T]erminal toggle [B]ar (roster)' },
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
      -- the winbar eats one row inside the float, so ask for one extra to keep
      -- the usable height toggleterm would otherwise pick (ui.lua:278)
      height = function()
        return math.ceil(math.min(vim.o.lines, math.max(20, vim.o.lines - 10))) + 1
      end,
    },
    -- persistent roster of every terminal, drawn in each terminal's own window
    winbar = {
      enabled = true,
      -- ui.winbar wraps each entry in WinBarActive/WinBarInactive by id only, so
      -- dim closed-but-alive terminals here with an explicit group of our own
      name_formatter = function(term)
        local label = string.format('%d:%s', term.id, term:_display_name())
        if term:is_open() then
          return label
        end
        return '%#ToggleTermWinBarClosed#' .. label .. '%*'
      end,
    },
    -- match nvim background, shade non-float terminals slightly darker
    shade_terminals = true,
    start_in_insert = true,
    persist_size = true,
    persist_mode = true,
    -- every terminal's bar lists all terminals, so any open/close has to
    -- refresh the others. winbar re-evaluates on redraw, so one redrawstatus
    -- covers all windows -- no per-window loop needed.
    on_open = function(term)
      _G.toggleterm_apply_winbar(term)
      vim.cmd.redrawstatus { bang = true }
    end,
    -- on_close runs *before* ui.close, so is_open() is still true here;
    -- defer past the actual close for the dimming to be correct
    on_close = function()
      vim.schedule(function()
        vim.cmd.redrawstatus { bang = true }
      end)
    end,
    on_exit = function()
      vim.schedule(function()
        vim.cmd.redrawstatus { bang = true }
      end)
    end,
  },
  config = function(_, opts)
    require('toggleterm').setup(opts)

    -- dim group for terminals that exist but are closed (see name_formatter)
    local function set_roster_hl()
      vim.api.nvim_set_hl(0, 'ToggleTermWinBarClosed', { link = 'Comment', default = true })
    end
    set_roster_hl()
    vim.api.nvim_create_autocmd('ColorScheme', { callback = set_roster_hl })

    -- Force the roster bar onto a terminal window, bypassing ui.set_winbar's
    -- `term:is_float()` early-return (ui.lua:99). That guard exists for
    -- neovim#19464 (winbar broke float borders), fixed in nvim 0.11.
    --
    -- Called from on_open rather than relying on toggleterm's TermOpen autocmd:
    -- TermOpen only fires on terminal *buffer* creation, and reopening a float
    -- reuses the buffer while building a fresh window -- which loses the
    -- window-local winbar.
    _G.toggleterm_apply_winbar = function(term)
      if not (term and term.window and vim.api.nvim_win_is_valid(term.window)) then
        return
      end
      local conf = require('toggleterm.config').get()
      if not (conf.winbar and conf.winbar.enabled) then
        return
      end
      -- the %{%...%} form (not %{...}) re-parses the result as statusline
      -- format, which is what makes the %#hl# groups and %N@fn@ click regions
      -- live rather than literal text
      local value = ('%%{%%v:lua.require("toggleterm.ui").winbar(%d)%%}'):format(term.id)
      vim.api.nvim_set_option_value('winbar', value, { scope = 'local', win = term.window })

      -- ui.hl_term filters float winhighlight down to FloatBorder/NormalFloat
      -- and overwrites the whole option (ui.lua:127), dropping the WinBar
      -- mapping on every float open. Re-append it so the bar stays shaded.
      local ok, wh = pcall(vim.api.nvim_get_option_value, 'winhighlight', { scope = 'local', win = term.window })
      if ok and not wh:match 'WinBar' then
        local prefix = wh ~= '' and (wh .. ',') or ''
        pcall(vim.api.nvim_set_option_value, 'winhighlight', prefix .. 'WinBar:WinBar,WinBarNC:WinBarNC', {
          scope = 'local',
          win = term.window,
        })
      end
    end

    -- re-apply across every open terminal (resize, toggle-on)
    local function refresh_all_winbars()
      for _, t in ipairs(require('toggleterm.terminal').get_all(true)) do
        if t:is_open() then
          _G.toggleterm_apply_winbar(t)
        end
      end
      vim.cmd.redrawstatus { bang = true }
    end

    -- flip the roster off/on for when the row is unwanted
    _G.toggleterm_toggle_winbar = function()
      local conf = require('toggleterm.config').get()
      conf.winbar.enabled = not conf.winbar.enabled
      if conf.winbar.enabled then
        refresh_all_winbars()
      else
        for _, t in ipairs(require('toggleterm.terminal').get_all(true)) do
          if t:is_open() and t.window and vim.api.nvim_win_is_valid(t.window) then
            vim.api.nvim_set_option_value('winbar', '', { scope = 'local', win = t.window })
          end
        end
        vim.cmd.redrawstatus { bang = true }
      end
      vim.notify('Terminal roster bar ' .. (conf.winbar.enabled and 'on' or 'off'))
    end

    -- update_float (resize) calls nvim_win_set_config without re-setting winbar
    vim.api.nvim_create_autocmd('VimResized', { callback = refresh_all_winbars })

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
      -- <esc> above is swallowed by nvim, so TUIs that want it (claude code)
      -- never see one. <C-q> forwards a literal escape byte to the job instead.
      vim.keymap.set('t', '<C-q>', '<esc>', vim.tbl_extend('error', o, { remap = false, desc = 'Send raw <esc> to terminal' }))
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
