-- arbiter ↔ claude-code bridge
--
-- Adds :ArbiterTriggerReview, which types `arbitrate` into the Claude Code
-- terminal that this nvim instance owns — and only that one. Other Claude
-- sessions in other terminals/tmuxes are unaffected because the lookup runs
-- through claude-code.nvim's in-process instance registry.

return {
  'arbiter-claude',
  dir = vim.fn.stdpath('config') .. '/lua/custom/plugins',  -- local, no fetch
  dependencies = {
    'greggh/claude-code.nvim',
    -- arbiter.lua loads its own way (via lazy spec at plugins/arbiter.lua);
    -- we don't strictly require it here since we only talk to claude-code.
  },
  lazy = false,
  config = function()
    local M = {}

    local function resolve_claude_bufnr()
      local ok, cc = pcall(require, 'claude-code')
      if not ok then return nil, 'claude-code.nvim not loaded' end
      local instances = cc.claude_code and cc.claude_code.instances or {}

      -- claude-code keys by git root (terminal.lua:23-31). Use git root if
      -- we're in a repo, else cwd — matches its `get_instance_identifier`.
      local key
      local git_root = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(vim.fn.getcwd()) .. ' rev-parse --show-toplevel')[1]
      if git_root and git_root ~= '' and vim.v.shell_error == 0 then
        key = git_root
      else
        key = vim.fn.getcwd()
      end

      local bufnr = instances[key]
      if not bufnr and cc.claude_code.current_instance then
        bufnr = instances[cc.claude_code.current_instance]
      end
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, 'no Claude Code session in this nvim (open one with <leader>cc)'
      end
      return bufnr
    end

    local function trigger()
      local bufnr, err = resolve_claude_bufnr()
      if not bufnr then
        vim.notify('arbiter: ' .. err, vim.log.levels.WARN)
        return
      end

      local buftype = vim.api.nvim_get_option_value('buftype', { buf = bufnr })
      local job_id = vim.b[bufnr].terminal_job_id
      if buftype ~= 'terminal' or not job_id or vim.fn.jobwait({ job_id }, 0)[1] ~= -1 then
        vim.notify('arbiter: Claude Code terminal is not running', vim.log.levels.WARN)
        return
      end

      -- intentionally NOT revealing a hidden Claude buffer; user wants to drive
      -- the session through arbiter comments only.
      vim.fn.chansend(job_id, 'arbitrate\r')
      vim.notify('arbiter: triggered claude review', vim.log.levels.INFO)
    end

    function M.notify_ready(opts)
      opts = opts or {}
      local count = tonumber(opts.count) or 0
      vim.notify(
        string.format('arbiter: %d note%s ready for re-review', count, count == 1 and '' or 's'),
        vim.log.levels.INFO,
        { title = 'arbiter', icon = '✓', timeout = 5000, hl_group = 'DiagnosticOk' }
      )
    end

    vim.api.nvim_create_user_command('ArbiterTriggerReview', trigger, {
      desc = 'arbiter: ask Claude (in this nvim) to review pending notes',
    })

    vim.keymap.set('n', '<leader>gT', trigger, {
      desc = 'arbiter: [T]rigger Claude review of notes',
    })

    package.loaded['arbiter-claude'] = M
  end,
}
