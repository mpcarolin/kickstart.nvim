-- c.lua — per-machine C build/run/debug bundle.
--
-- This file is always imported by `{ import = 'custom.plugins' }`, but every
-- spec below self-disables via `enabled = enabled_c`. When the function returns
-- false, lazy.nvim treats each plugin as nonexistent: not downloaded, not
-- loaded, no keymaps registered, and not pinned in lazy-lock.json. So on a
-- machine that hasn't opted in (env.lua does not set `vim.g.enable_c = true`),
-- this whole bundle has zero footprint.
--
-- Opt in by adding `vim.g.enable_c = true` to env.lua (see env.template.lua),
-- then run `:Lazy sync`. clangd (the LSP) is gated separately in init.lua by the
-- same flag.

-- Shared predicate. lazy evaluates `enabled` while resolving specs at startup,
-- after env.lua has run (env.lua is loaded before lazy.setup in init.lua).
local function enabled_c()
  return vim.g.enable_c == true
end

return {
  -----------------------------------------------------------------------------
  -- Task runner: build via `make`, stream output to a panel, push compiler
  -- errors into quickfix (navigate with :cnext / :cprev).
  -----------------------------------------------------------------------------
  {
    'stevearc/overseer.nvim',
    enabled = enabled_c,
    -- Load at startup (not lazily) when C is enabled, so the build-on-save
    -- autocmd and C/C++ keymaps below are always registered for C buffers.
    lazy = false,
    dependencies = {
      'williamboman/mason.nvim',
      { 'akinsho/toggleterm.nvim', optional = true },
    },
    opts = {
      -- Surface task output and let the builtin `make` template populate
      -- quickfix from compiler diagnostics.
      templates = { 'builtin' },
      task_list = {
        direction = 'bottom',
        min_height = 12,
      },
    },
    config = function(_, opts)
      require('overseer').setup(opts)

      -- Ensure the codelldb debug adapter is installed (clangd is handled by the
      -- LSP `servers` table in init.lua). mason-tool-installer can install
      -- arbitrary Mason packages, not just LSP servers.
      pcall(function()
        require('mason-tool-installer').setup { ensure_installed = { 'codelldb' } }
      end)

      -- Run the overseer `make` task, falling back to plain `:make` if no `make`
      -- template resolves (e.g. no Makefile). Output streams to the overseer
      -- panel and compiler errors land in quickfix (navigate with :cnext).
      local function run_make()
        local overseer = require 'overseer'
        -- run_task is the current API; older overseer only has run_template
        -- (which warns + prints a traceback). Prefer run_task when present.
        local run = overseer.run_task or overseer.run_template
        run({ name = 'make' }, function(task)
          if task then
            overseer.open { enter = false, direction = 'bottom' }
          else
            vim.cmd 'make'
          end
        end)
      end

      -- Build, then run the produced binary in a toggleterm float. Prefers a
      -- `make run` target if one exists, else falls back to ./a.out.
      local function build_and_run()
        run_make()
        vim.defer_fn(function()
          local ok, term = pcall(require, 'toggleterm.terminal')
          if not ok then
            vim.cmd '!if make -n run >/dev/null 2>&1; then make run; else ./a.out; fi'
            return
          end
          local runner = term.Terminal:new {
            cmd = 'if make -n run >/dev/null 2>&1; then make run; else ./a.out; fi',
            direction = 'float',
            close_on_exit = false,
          }
          runner:toggle()
        end, 500)
      end

      -- Watch loop: run `make watch` in a dedicated, persistent toggleterm. The
      -- Makefile's `watch` target drives watchexec, which re-runs `make run` on
      -- every source change. Reusing one named terminal means re-triggering the
      -- keymap toggles the same window instead of spawning duplicate watchers.
      local watch_term
      local function make_watch()
        local ok, term = pcall(require, 'toggleterm.terminal')
        if not ok then
          vim.notify('toggleterm not available for make watch', vim.log.levels.WARN)
          return
        end
        if not watch_term then
          watch_term = term.Terminal:new {
            cmd = 'make watch',
            direction = 'horizontal',
            close_on_exit = false,
            on_exit = function()
              -- drop the handle so the next press starts a fresh watcher
              watch_term = nil
            end,
          }
        end
        watch_term:toggle()
      end

      -- Silent build for the save path: run `make` asynchronously with no panel,
      -- no terminal, and no "Press ENTER" prompt. Parse compiler output through
      -- the quickfix errorformat; only open the quickfix window when the build
      -- FAILS. A clean build leaves your editing completely uninterrupted.
      local function build_silent()
        local function finish(out)
          -- Feed combined stdout+stderr to quickfix via vim's C errorformat.
          local lines = vim.split(out or '', '\n', { trimempty = false })
          vim.fn.setqflist({}, ' ', {
            title = 'make (build-on-save)',
            lines = lines,
            efm = vim.o.errorformat,
          })
          -- Keep only real entries (valid == 1: lines errorformat actually matched).
          local items = vim.fn.getqflist()
          local errors = vim.tbl_filter(function(it)
            return it.valid == 1
          end, items)
          if #errors > 0 then
            vim.fn.setqflist({}, 'r', { title = 'make (build-on-save)', items = errors })
            vim.cmd 'copen'
          else
            -- Clean build: clear any stale errors and close the quickfix window.
            vim.fn.setqflist({}, 'r', { title = 'make (build-on-save)', items = {} })
            vim.cmd 'cclose'
          end
        end

        vim.system(
          { 'make' },
          { text = true, cwd = vim.fn.getcwd() },
          vim.schedule_wrap(function(res)
            finish((res.stdout or '') .. (res.stderr or ''))
          end)
        )
      end

      -- Build-on-save: real compiler feedback (incl. linker errors) into quickfix
      -- on every write of a C source/header. clangd already gives editor-time
      -- semantic squiggles; this adds actual-build truth. Silent on success;
      -- pops the quickfix only on failure. Toggleable below for large projects.
      vim.g.c_build_on_save = true
      local augroup = vim.api.nvim_create_augroup('c-build-on-save', { clear = true })
      vim.api.nvim_create_autocmd('BufWritePost', {
        group = augroup,
        pattern = { '*.c', '*.h' },
        callback = function()
          if vim.g.c_build_on_save then
            build_silent()
          end
        end,
      })

      -- Buffer-local build/run keymaps, only in C/C++ buffers, under <leader>c.
      -- Kept buffer-local so they don't collide with the global <leader>cc/cR/cV
      -- (claude-code) bindings outside C files.
      vim.api.nvim_create_autocmd('FileType', {
        group = augroup,
        pattern = { 'c', 'cpp' },
        callback = function(ev)
          local map = function(lhs, fn, desc)
            vim.keymap.set('n', lhs, fn, { buffer = ev.buf, desc = desc, silent = true })
          end
          map('<leader>cb', run_make, '[C] [B]uild (make)')
          map('<leader>cr', build_and_run, '[C] build & [R]un')
          map('<leader>cw', make_watch, '[C] [W]atch (make watch)')
          map('<leader>cB', function()
            vim.g.c_build_on_save = not vim.g.c_build_on_save
            vim.notify('C build-on-save: ' .. (vim.g.c_build_on_save and 'ON' or 'OFF'))
          end, '[C] toggle [B]uild-on-save')
        end,
      })
    end,
  },

  -----------------------------------------------------------------------------
  -- Debugging: nvim-dap + dap-ui, using codelldb as the adapter (installed via
  -- Mason below). nvim-nio is a dap-ui dependency.
  -----------------------------------------------------------------------------
  {
    'mfussenegger/nvim-dap',
    enabled = enabled_c,
    dependencies = {
      { 'rcarriga/nvim-dap-ui', enabled = enabled_c },
      { 'nvim-neotest/nvim-nio', enabled = enabled_c },
    },
    config = function()
      local dap = require 'dap'
      local dapui = require 'dapui'

      dapui.setup()

      -- Auto-open / close the dap-ui when a debug session starts / ends.
      dap.listeners.after.event_initialized['dapui_config'] = function()
        dapui.open()
      end
      dap.listeners.before.event_terminated['dapui_config'] = function()
        dapui.close()
      end
      dap.listeners.before.event_exited['dapui_config'] = function()
        dapui.close()
      end

      -- codelldb adapter. Mason installs the binary into its `bin/` dir; resolve
      -- the path so this works without a globally installed codelldb.
      local mason_bin = vim.fn.stdpath 'data' .. '/mason/bin/codelldb'
      dap.adapters.codelldb = {
        type = 'server',
        port = '${port}',
        executable = {
          command = mason_bin,
          args = { '--port', '${port}' },
        },
      }

      -- A single, prompt-driven launch config covers both C and C++. It asks for
      -- the binary to debug (defaulting to the cwd) so it works for any project.
      local launch = {
        {
          name = 'Launch (codelldb)',
          type = 'codelldb',
          request = 'launch',
          program = function()
            return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
          end,
          cwd = '${workspaceFolder}',
          stopOnEntry = false,
        },
      }
      dap.configurations.c = launch
      dap.configurations.cpp = launch

      -- Debug keymaps. <leader>d is otherwise unused; it's the conventional dap
      -- prefix. These are global (dap is only loaded on C machines anyway).
      local map = function(lhs, fn, desc)
        vim.keymap.set('n', lhs, fn, { desc = desc, silent = true })
      end
      map('<leader>db', dap.toggle_breakpoint, '[D]ebug: toggle [B]reakpoint')
      map('<leader>dc', dap.continue, '[D]ebug: [C]ontinue / start')
      map('<leader>do', dap.step_over, '[D]ebug: step [O]ver')
      map('<leader>di', dap.step_into, '[D]ebug: step [I]nto')
      map('<leader>dO', dap.step_out, '[D]ebug: step [O]ut')
      map('<leader>dr', dap.repl.toggle, '[D]ebug: toggle [R]EPL')
      map('<leader>dt', dap.terminate, '[D]ebug: [T]erminate')
      map('<leader>du', dapui.toggle, '[D]ebug: toggle [U]I')
    end,
  },
}
