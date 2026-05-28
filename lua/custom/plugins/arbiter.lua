-- arbiter: a tool for a HUMAN to leave GitHub-style review notes on code an AI
-- assistant wrote. Visual-select lines in a fugitive diff (or any buffer),
-- press <leader>gr, type a note. Notes are appended to <repo>/.git/arbiter.jsonl.
-- That JSONL file is meant to be read back by the AI assistant (e.g. Claude
-- Code) so it can apply the human reviewer's feedback to the code.
--
-- The data model and JSONL primitives live in `arbiter.core` (a pure-Lua
-- module under lua/custom/local-plugins/arbiter/core.lua) so the same
-- read/write/filter logic is shared with the standalone `arbiter` CLI at
-- ~/.config/nvim/arbiter/cli.lua. UI (popups, keymaps, diagnostics, fugitive
-- diff parsing) stays in this file.
--
-- Git integration is built specifically against vim-fugitive (tpope/vim-fugitive):
-- the diff-position parser keys off `&filetype == 'git'`, and commit SHA
-- resolution uses `FugitiveParse()` and `FugitiveGitDir()`. Other git plugins
-- (gitsigns, diffview, neogit) are not supported for the diff-mapping path;
-- in those buffers arbiter falls back to the regular-buffer behavior
-- (filename + raw line numbers, no commit SHA).
--
-- Each record carries a `branch` field (resolved at write-time). On detached
-- HEAD the short SHA is stored as the branch. Commands:
--   :Arbiter        leave a note on the current line/selection (<leader>gr)
--   :ArbiterShow    show current branch's notes in a popup; <CR> jumps (<leader>gl)
--   :ArbiterClear[!] clear notes for the current branch (<leader>gc, prompts)
--   :ArbiterSigns {enable|disable|toggle}  toggle inline diagnostics (<leader>gt)
--   :ArbiterStatus {pending|in-progress|needs-rereview|resolved}  set status of note under cursor (<leader>gs)
--   <leader>gd  resolve note(s) on the current line. With one note, resolves
--               immediately. With multiple, opens a checklist popup.
--   <leader>gp  preview full text of all notes on the current line
--   ]g / [g     jump to next/previous arbiter note across all files in the
--               current branch (resolved notes are skipped; wraps around)
--
-- Record schema (see core.lua / SKILL.md for the canonical contract):
--   file, line_start, line_end, commit, branch, note, created_at, status

return {
  dir = vim.fn.stdpath 'config' .. '/lua/custom/local-plugins/arbiter',
  name = 'arbiter',
  lazy = false,
  config = function()
    -- Make `arbiter.core` resolvable from the plugin runtime. The local-plugin
    -- directory isn't on package.path by default.
    local core_dir = vim.fn.stdpath 'config' .. '/lua/custom/local-plugins/arbiter'
    if not package.path:find(core_dir, 1, true) then
      package.path = core_dir .. '/?.lua;' .. package.path
    end
    -- cjson installed under ~/.luarocks for LuaJIT 5.1 isn't on the default
    -- cpath. Extending here so the require below succeeds in nvim.
    local home = os.getenv 'HOME' or ''
    if home ~= '' then
      local extra = home .. '/.luarocks/lib/lua/5.1/?.so'
      if not package.cpath:find(extra, 1, true) then
        package.cpath = package.cpath .. ';' .. extra
      end
    end

    local ok, core = pcall(require, 'core')
    if not ok then
      vim.notify('arbiter: failed to load core module: ' .. tostring(core), vim.log.levels.ERROR)
      return
    end

    local M = {}

    -- Resolve (jsonl_path, repo_root, git_dir, err). err is a string when
    -- something failed; jsonl_path is otherwise <git_dir>/arbiter.jsonl.
    local function resolve_paths()
      local git_dir, repo_root = core.find_git_root(vim.fn.getcwd())
      if not repo_root or not git_dir then
        return nil, nil, nil, 'not inside a git repo'
      end
      return core.resolve_jsonl_path(git_dir), repo_root, git_dir, nil
    end

    -- Resolve git root from a buffer file path. Uses the parent directory
    -- of the file as the cwd hint for `git rev-parse`.
    local function find_git_root_for(path)
      if not path or path == '' then
        return nil, nil
      end
      local dir = vim.fn.fnamemodify(path, ':h')
      local git_dir, repo_root = core.find_git_root(dir)
      return repo_root, git_dir
    end

    -- Convert an absolute file path to a path relative to repo_root, or nil
    -- if the file lies outside the repo. Returns the trailing-slash-stripped
    -- root_abs as a second value so callers that need it can skip recomputing.
    local function repo_relpath(repo_root, abs_path)
      if not repo_root or not abs_path then
        return nil, nil
      end
      local root_abs = vim.fn.fnamemodify(repo_root, ':p'):gsub('/$', '')
      if abs_path:sub(1, #root_abs + 1) ~= root_abs .. '/' then
        return nil, root_abs
      end
      return abs_path:sub(#root_abs + 2), root_abs
    end

    local STATUSES = core.STATUSES

    -- Resolved notes are intentionally omitted — they're done, no need to
    -- clutter the buffer. They still appear in :ArbiterShow for audit.
    local STATUS_SEVERITY = {
      ['pending'] = vim.diagnostic.severity.HINT,
      ['in-progress'] = vim.diagnostic.severity.INFO,
      ['needs-rereview'] = vim.diagnostic.severity.WARN,
    }

    -- Highlight groups for status-styled lines in popups. Linked to existing
    -- semantic groups so the colorscheme drives the actual colors. Override
    -- ArbiterStatus* in your config if you want different palettes.
    local STATUS_HL = {
      ['pending'] = 'ArbiterStatusPending',
      ['in-progress'] = 'ArbiterStatusInProgress',
      ['needs-rereview'] = 'ArbiterStatusNeedsRereview',
      ['resolved'] = 'ArbiterStatusResolved',
    }
    vim.api.nvim_set_hl(0, 'ArbiterStatusPending', { link = 'DiagnosticHint', default = true })
    vim.api.nvim_set_hl(0, 'ArbiterStatusInProgress', { link = 'DiagnosticInfo', default = true })
    vim.api.nvim_set_hl(0, 'ArbiterStatusNeedsRereview', { link = 'DiagnosticWarn', default = true })
    vim.api.nvim_set_hl(0, 'ArbiterStatusResolved', { link = 'Comment', default = true })
    vim.api.nvim_set_hl(0, 'ArbiterStatusDrifted', { link = 'DiagnosticSignWarn', default = true })
    vim.api.nvim_set_hl(0, 'ArbiterStatusFile', { link = 'DiagnosticSignInfo', default = true })

    -- Author highlight groups for reply headers in the preview window. Human
    -- replies use Comment (diminished) since the human is the local actor;
    -- AI replies use Function so they stand out in the thread.
    vim.api.nvim_set_hl(0, 'ArbiterAuthorHuman', { link = 'Comment', default = true })
    vim.api.nvim_set_hl(0, 'ArbiterAuthorAI', { link = 'Function', default = true })

    vim.api.nvim_set_hl(0, 'ArbiterReplyCount', { link = 'Special', default = true })

    local hl_ns = vim.api.nvim_create_namespace 'arbiter_hl'

    -- Apply a status highlight to one buffer line (0-indexed).
    local function highlight_status_line(buf, line, status)
      local group = STATUS_HL[status]
      if not group then
        return
      end
      vim.api.nvim_buf_set_extmark(buf, hl_ns, line, 0, {
        end_row = line + 1,
        end_col = 0,
        hl_eol = true,
        hl_group = group,
      })
    end

    -- Apply an author highlight to the reply header + rule rows (0-indexed).
    -- Human replies render diminished; AI replies stand out.
    local function highlight_reply_lines(buf, rows, author)
      local norm = (author or 'human'):lower()
      local group
      if norm == 'human' then
        group = 'ArbiterAuthorHuman'
      else
        group = 'ArbiterAuthorAI'
      end
      for _, line in ipairs(rows) do
        vim.api.nvim_buf_set_extmark(buf, hl_ns, line, 0, {
          end_row = line + 1,
          end_col = 0,
          hl_eol = false,
          hl_group = group,
        })
      end
    end

    local function lang_for(file)
      return file and vim.filetype.match { filename = file } or nil
    end

    -- Row indices in heading_rows / reply_rows are 0-based and local to the
    -- returned `lines` array; callers concatenating multiple records must
    -- offset them before applying highlights.
    --
    -- `resolved` (optional) is the result of `core.resolve_anchor`. When
    -- provided, the heading reflects drift state (lost notes get a warning
    -- prefix; file-level notes show `[file-level]`).
    local function render_record_lines(record, resolved)
      local lines = {}
      local heading_rows = {}
      local reply_rows = {}
      local status = core.normalize_status(record.status)
      local drift = resolved and resolved.drift or 'none'
      local range
      if drift == 'file' or core.is_file_level(record) then
        range = '[file-level]'
      elseif drift == 'lost' then
        range = string.format('⚠ drifted — original L%d-%d', record.line_start, record.line_end)
      else
        range = string.format('L%d-%d', record.line_start, record.line_end)
      end
      table.insert(lines, string.format('# [%s] %s · %s', status, range, record.created_at or ''))
      table.insert(heading_rows, { row = #lines - 1, status = status })
      table.insert(lines, '')
      for note_line in (tostring(record.note or '')):gmatch '[^\n]+' do
        table.insert(lines, note_line)
      end
      local lang = lang_for(record.file)
      for _, reply in ipairs(core.normalize_comments(record)) do
        table.insert(lines, '')
        table.insert(lines, '')
        local author = core.normalize_author(reply)
        local header = string.format('  ↳ %s · %s', author, tostring(reply.created_at or ''))
        table.insert(lines, header)
        local header_row = #lines - 1
        local rule_width = vim.fn.strdisplaywidth(header) - 2
        if rule_width < 1 then
          rule_width = 1
        end
        table.insert(lines, '  ' .. string.rep('─', rule_width))
        local rule_row = #lines - 1
        table.insert(lines, '')
        table.insert(reply_rows, { author = author, rows = { header_row, rule_row } })
        local in_fence = false
        for body_line in (tostring(reply.body or '')):gmatch '[^\n]+' do
          local fence_open = body_line:match '^```(.*)$'
          if fence_open and not in_fence then
            in_fence = true
            local tag = fence_open:gsub('^%s+', ''):gsub('%s+$', '')
            if tag == '' and lang then
              table.insert(lines, '  ```' .. lang)
            else
              table.insert(lines, '  ' .. body_line)
            end
          elseif body_line:match '^```%s*$' and in_fence then
            in_fence = false
            table.insert(lines, '  ' .. body_line)
          else
            table.insert(lines, '  ' .. body_line)
          end
        end
      end
      return { lines = lines, heading_rows = heading_rows, reply_rows = reply_rows }
    end

    local diag_ns = vim.api.nvim_create_namespace 'arbiter'
    if vim.g.arbiter_signs_enabled == nil then
      vim.g.arbiter_signs_enabled = true
    end

    local function read_buf_lines(bufnr)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
      end
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    local function resolve_records_for_buf(bufnr, all_records, rel)
      local buf_lines = read_buf_lines(bufnr)
      local buf_norm = core.normalize_buf_lines(buf_lines)
      local out = {}
      for i, r in ipairs(all_records) do
        if r.file == rel then
          local resolved = core.resolve_anchor(r, buf_lines, nil, buf_norm)
          table.insert(out, { idx = i, record = r, resolved = resolved })
        end
      end
      return out
    end

    local function format_title_for_meta(prefix, meta)
      if core.is_file_level(meta) then
        return string.format('%s: %s [file-level]', prefix, meta.file)
      end
      return string.format('%s: %s:%d-%d', prefix, meta.file, meta.line_start, meta.line_end)
    end

    -- Refresh diagnostics for one buffer based on the JSONL + current branch.
    local function refresh_diagnostics_for_buf(bufnr)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if not vim.g.arbiter_signs_enabled then
        return
      end
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname == '' then
        return
      end
      if vim.bo[bufnr].buftype ~= '' then
        return
      end
      local repo_root, git_dir = find_git_root_for(bufname)
      if not repo_root or not git_dir then
        return
      end
      local jsonl_path = core.resolve_jsonl_path(git_dir)
      local abs = vim.fn.fnamemodify(bufname, ':p')
      local rel = repo_relpath(repo_root, abs)
      if not rel then
        return
      end
      local branch = core.current_branch(git_dir)
      local all = core.filter_for_branch(core.read_jsonl(jsonl_path), branch)
      local resolved = resolve_records_for_buf(bufnr, all, rel)
      local diagnostics = {}
      for _, item in ipairs(resolved) do
        local r = item.record
        local res = item.resolved
        local status = core.normalize_status(r.status)
        local sev = STATUS_SEVERITY[status]
        if sev then
          local n_replies = #core.normalize_comments(r)
          local suffix = n_replies > 0 and string.format(' (%d replies)', n_replies) or ''
          local lnum, end_lnum, sev_use, tag
          if res.drift == 'file' then
            lnum, end_lnum, sev_use, tag = 0, 0, sev, '[file] '
          elseif type(res.line_start) == 'number' and type(res.line_end) == 'number' then
            lnum = math.max(0, res.line_start - 1)
            end_lnum = math.max(lnum, res.line_end - 1)
            if res.drift == 'lost' then
              sev_use, tag = vim.diagnostic.severity.WARN, '[drifted] '
            else
              sev_use, tag = sev, ''
            end
          end
          if sev_use then
            table.insert(diagnostics, {
              lnum = lnum,
              end_lnum = end_lnum,
              col = 0,
              severity = sev_use,
              source = 'arbiter',
              message = tag .. '[' .. status .. '] ' .. tostring(r.note or '') .. suffix,
            })
          end
        end
      end
      vim.diagnostic.set(diag_ns, bufnr, diagnostics)
    end

    local function refresh_all_listed_buffers()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
          refresh_diagnostics_for_buf(bufnr)
        end
      end
    end

    -- Resolve a fugitive buffer's rev to a short SHA.
    -- FugitiveParse returns {rev, repo}. The rev can be:
    --   "abc1234def..." (full SHA, from :Git show <sha>)
    --   "abc1234:path/to/file" (object reference)
    --   "HEAD", "HEAD~1", "master", "refs/heads/foo" (named ref)
    --   "" or absent for non-fugitive buffers
    local function fugitive_commit_sha(bufnr, git_dir)
      local ok_p, parsed = pcall(vim.fn.FugitiveParse, vim.api.nvim_buf_get_name(bufnr))
      if not ok_p or type(parsed) ~= 'table' then
        return nil
      end
      local rev = parsed[1]
      if type(rev) ~= 'string' or rev == '' then
        return nil
      end
      local rev_only = rev:match '^([^:]+)' or rev
      local sha = rev_only:match '^([0-9a-fA-F]+)$'
      if sha and #sha >= 7 then
        return sha:sub(1, 12)
      end
      if not git_dir then
        return nil
      end
      local out = vim.fn.system { 'git', '--git-dir=' .. git_dir, 'rev-parse', '--short=12', rev_only }
      if vim.v.shell_error ~= 0 then
        return nil
      end
      local resolved = (out or ''):gsub('%s+$', '')
      if resolved:match '^[0-9a-fA-F]+$' and #resolved >= 7 then
        return resolved
      end
      return nil
    end

    local function find_back(bufnr, lnum, pattern)
      for i = lnum, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
        if line then
          local cap = line:match(pattern)
          if cap then
            return i, cap
          end
        end
      end
      return nil
    end

    -- For a fugitive diff buffer, map a visual selection (start_line, end_line)
    -- to (file_path, line_start, line_end) in the post-image of the diff.
    local function parse_diff_position(bufnr, start_line, end_line)
      local file_path
      for i = start_line, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
        if line then
          local b = line:match '^diff %-%-git a/.- b/(.+)$'
          if b then
            file_path = b
            break
          end
        end
      end

      local hunk_lnum, new_start_str = find_back(bufnr, start_line, '^@@ %-%d+,?%d* %+(%d+),?%d* @@')
      if not file_path or not hunk_lnum then
        return nil
      end
      local new_start = tonumber(new_start_str)

      local lines = vim.api.nvim_buf_get_lines(bufnr, hunk_lnum, end_line, false)
      local file_lno = new_start - 1
      local mapped_start, mapped_end = nil, nil
      local cur_diff_line = hunk_lnum
      for _, line in ipairs(lines) do
        cur_diff_line = cur_diff_line + 1
        local first = line:sub(1, 1)
        if first == '@' then
          local ns = line:match '^@@ %-%d+,?%d* %+(%d+),?%d* @@'
          if ns then
            file_lno = tonumber(ns) - 1
          end
        elseif first == '+' or first == ' ' then
          file_lno = file_lno + 1
          if cur_diff_line >= start_line and not mapped_start then
            mapped_start = file_lno
          end
          if cur_diff_line >= start_line and cur_diff_line <= end_line then
            mapped_end = file_lno
          end
        elseif first == '-' then
          -- deletion: doesn't exist in post-image; skip
        end
      end

      if not mapped_start then
        return {
          file = file_path,
          line_start = new_start,
          line_end = new_start,
          deletions_only = true,
        }
      end
      return {
        file = file_path,
        line_start = mapped_start,
        line_end = mapped_end or mapped_start,
        deletions_only = false,
      }
    end

    local function open_reply_window_with_context(record, meta, on_save, on_cancel)
      local total_width = math.min(160, math.floor(vim.o.columns * 0.9))
      local pane_width = math.floor((total_width - 2) / 2)
      local height = math.min(24, math.floor(vim.o.lines * 0.7))
      local row = math.floor((vim.o.lines - height) / 2)
      local col_left = math.floor((vim.o.columns - total_width) / 2)
      local col_right = col_left + pane_width + 2

      local left_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[left_buf].buftype = 'nofile'
      vim.bo[left_buf].bufhidden = 'wipe'
      vim.bo[left_buf].swapfile = false
      vim.bo[left_buf].filetype = 'markdown'

      local rendered = render_record_lines(record)
      vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, rendered.lines)
      for _, h in ipairs(rendered.heading_rows) do
        highlight_status_line(left_buf, h.row, h.status)
      end
      for _, rep in ipairs(rendered.reply_rows) do
        highlight_reply_lines(left_buf, rep.rows, rep.author)
      end
      vim.bo[left_buf].modifiable = false

      local left_win = vim.api.nvim_open_win(left_buf, false, {
        relative = 'editor',
        row = row,
        col = col_left,
        width = pane_width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' arbiter notes (read-only · <C-w>w to focus) ',
        title_pos = 'center',
      })
      vim.wo[left_win].wrap = true
      vim.wo[left_win].linebreak = true
      vim.wo[left_win].cursorline = true

      local right_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[right_buf].buftype = 'acwrite'
      vim.bo[right_buf].bufhidden = 'wipe'
      vim.bo[right_buf].filetype = 'markdown'
      vim.bo[right_buf].swapfile = false
      local title = format_title_for_meta(meta.title_prefix or 'reply', meta)
      vim.api.nvim_buf_set_name(right_buf, title)

      local right_win = vim.api.nvim_open_win(right_buf, true, {
        relative = 'editor',
        row = row,
        col = col_right,
        width = pane_width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' ' .. title .. ' (:w save · <Esc><Esc> cancel) ',
        title_pos = 'center',
      })
      vim.wo[right_win].wrap = true
      vim.wo[right_win].linebreak = true

      local closed = false
      local function close_both()
        if closed then
          return
        end
        closed = true
        if left_win and vim.api.nvim_win_is_valid(left_win) then
          vim.api.nvim_win_close(left_win, true)
        end
        if right_win and vim.api.nvim_win_is_valid(right_win) then
          vim.api.nvim_win_close(right_win, true)
        end
      end

      vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = right_buf,
        callback = function()
          local body_lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
          local note = table.concat(body_lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
          vim.bo[right_buf].modified = false
          if note == '' then
            vim.notify('arbiter: empty note, not saved', vim.log.levels.WARN)
            close_both()
            return
          end
          on_save(note)
          close_both()
        end,
      })

      local function cancel()
        if on_cancel then
          on_cancel()
        end
        close_both()
      end

      vim.keymap.set('n', '<Esc><Esc>', cancel, { buffer = right_buf, silent = true, desc = 'cancel reply' })
      vim.keymap.set('n', 'q', cancel, { buffer = left_buf, silent = true, nowait = true, desc = 'cancel reply' })
      vim.keymap.set('n', '<Esc>', cancel, { buffer = left_buf, silent = true, nowait = true, desc = 'cancel reply' })

      vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(left_win),
        once = true,
        callback = close_both,
      })
      vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(right_win),
        once = true,
        callback = close_both,
      })

      vim.cmd 'startinsert'
    end

    local function open_note_window(meta, on_save, on_cancel)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'acwrite'
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].filetype = 'markdown'
      vim.bo[buf].swapfile = false
      local title = format_title_for_meta(meta.title_prefix or 'review', meta)
      vim.api.nvim_buf_set_name(buf, title)

      local width = math.min(80, math.floor(vim.o.columns * 0.7))
      local height = math.min(12, math.floor(vim.o.lines * 0.4))
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)

      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' ' .. title .. ' ',
        title_pos = 'center',
      })
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true

      local closed = false
      local function close()
        if closed then
          return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = buf,
        callback = function()
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local note = table.concat(lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
          vim.bo[buf].modified = false
          if note == '' then
            vim.notify('arbiter: empty note, not saved', vim.log.levels.WARN)
            close()
            return
          end
          on_save(note)
          close()
        end,
      })

      vim.keymap.set('n', '<Esc><Esc>', function()
        if on_cancel then
          on_cancel()
        end
        close()
      end, { buffer = buf, silent = true, desc = 'cancel review note' })

      vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
        buffer = buf,
        once = true,
        callback = function()
          if not closed then
            close()
          end
        end,
      })

      vim.cmd 'startinsert'
    end

    function M.add_comment(start_line, end_line)
      local bufnr = vim.api.nvim_get_current_buf()
      local source_bufnr = bufnr
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      local is_fugitive_diff = vim.bo[bufnr].filetype == 'git'

      local repo_root, git_dir
      local file_path
      local line_start, line_end
      local commit = nil
      local deletions_only = false

      if is_fugitive_diff then
        local pos = parse_diff_position(bufnr, start_line, end_line)
        if not pos then
          vim.notify('arbiter: could not locate diff header / hunk for selection', vim.log.levels.ERROR)
          return
        end
        file_path = pos.file
        line_start = pos.line_start
        line_end = pos.line_end
        deletions_only = pos.deletions_only
        git_dir, repo_root = core.find_git_root(vim.fn.getcwd())
        commit = fugitive_commit_sha(bufnr, git_dir)
      else
        if bufname == '' then
          vim.notify('arbiter: buffer has no filename', vim.log.levels.ERROR)
          return
        end
        repo_root, git_dir = find_git_root_for(bufname)
        if not repo_root then
          vim.notify('arbiter: not inside a git repo', vim.log.levels.ERROR)
          return
        end
        local abs = vim.fn.fnamemodify(bufname, ':p')
        file_path = repo_relpath(repo_root, abs) or abs
        line_start = start_line
        line_end = end_line
      end

      if not repo_root or not git_dir then
        vim.notify('arbiter: not inside a git repo', vim.log.levels.ERROR)
        return
      end

      if deletions_only then
        vim.notify('arbiter: selection only contains deletions; recorded at hunk start', vim.log.levels.WARN)
      end

      local meta = {
        file = file_path,
        line_start = line_start,
        line_end = line_end,
        commit = commit,
      }

      local jsonl_path = core.resolve_jsonl_path(git_dir)
      local branch = core.current_branch(git_dir)

      -- Capture an anchor against the source buffer's current contents. For a
      -- fugitive diff, source_bufnr is still the diff buffer — we can't read
      -- the post-image of the file from it directly, so skip anchor capture in
      -- that case (the note still works; it just behaves like a legacy note).
      local anchor
      if not is_fugitive_diff and vim.api.nvim_buf_is_valid(source_bufnr) then
        local buf_lines = vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
        anchor = core.build_anchor(buf_lines, line_start, line_end)
      end

      open_note_window(meta, function(note)
        local record, err = core.create_note {
          jsonl_path = jsonl_path,
          file = meta.file,
          line_start = meta.line_start,
          line_end = meta.line_end,
          note = note,
          branch = branch,
          commit = meta.commit,
          author = 'human',
          anchor = anchor,
        }
        if not record then
          vim.notify('arbiter: write failed: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify(
          string.format('arbiter: saved %s:%d-%d → %s', meta.file, meta.line_start, meta.line_end, vim.fn.fnamemodify(jsonl_path, ':~')),
          vim.log.levels.INFO
        )
        if vim.api.nvim_buf_is_valid(source_bufnr) then
          refresh_diagnostics_for_buf(source_bufnr)
        end
      end)
    end

    -- File-level note entry point. Anchored to the file as a whole (no line
    -- range). Renders at line 1 with a sign + virtual_text marker.
    function M.add_file_comment()
      local bufnr = vim.api.nvim_get_current_buf()
      local source_bufnr = bufnr
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname == '' then
        vim.notify('arbiter: buffer has no filename', vim.log.levels.ERROR)
        return
      end
      if vim.bo[bufnr].filetype == 'git' then
        vim.notify('arbiter: file-level notes are not supported on fugitive diff buffers', vim.log.levels.ERROR)
        return
      end
      local repo_root, git_dir = find_git_root_for(bufname)
      if not repo_root or not git_dir then
        vim.notify('arbiter: not inside a git repo', vim.log.levels.ERROR)
        return
      end
      local abs = vim.fn.fnamemodify(bufname, ':p')
      local file_path = repo_relpath(repo_root, abs) or abs
      local jsonl_path = core.resolve_jsonl_path(git_dir)
      local branch = core.current_branch(git_dir)

      local meta = { file = file_path, scope = 'file' }
      open_note_window(meta, function(note)
        local record, err = core.create_note {
          jsonl_path = jsonl_path,
          file = file_path,
          line_start = nil,
          line_end = nil,
          note = note,
          branch = branch,
          author = 'human',
        }
        if not record then
          vim.notify('arbiter: write failed: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify(
          string.format('arbiter: saved %s [file-level] → %s', file_path, vim.fn.fnamemodify(jsonl_path, ':~')),
          vim.log.levels.INFO
        )
        if vim.api.nvim_buf_is_valid(source_bufnr) then
          refresh_diagnostics_for_buf(source_bufnr)
        end
      end)
    end

    function M.show()
      local jsonl_path, repo_root, git_dir, err = resolve_paths()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.ERROR)
        return
      end
      local branch = core.current_branch(git_dir)
      local repo_root_clean = repo_root:gsub('/$', '')

      local header_rows = 3
      local entries = {}

      local function build_entries()
        local records = core.filter_for_branch(core.read_jsonl(jsonl_path), branch)
        core.sort_resolved_last(records)
        local out = {}
        for _, r in ipairs(records) do
          if r.file then
            local is_file_level = core.is_file_level(r)
            local note = tostring(r.note or '')
            local first_nl = note:find '\n'
            local preview = first_nl and (note:sub(1, first_nl - 1) .. ' …') or note
            table.insert(out, {
              fname = repo_root_clean .. '/' .. r.file,
              file_rel = r.file,
              lnum = is_file_level and 1 or r.line_start,
              file_level = is_file_level,
              status = core.normalize_status(r.status),
              preview = preview,
              created_at = r.created_at,
              n_replies = #core.normalize_comments(r),
            })
          end
        end
        return out
      end

      entries = build_entries()
      if #entries == 0 then
        vim.notify('arbiter: no notes for ' .. (branch or '<unknown>'), vim.log.levels.INFO)
        return
      end

      -- Format an entry's display line and the byte range of its chip (or
      -- nil if no chip). Single source of truth for both the line text and
      -- highlight column math, so they can't drift.
      local function format_entry(e)
        local n = e.n_replies or 0
        local prefix = string.format('[%s] ', e.status)
        local chip = n > 0 and string.format('[%d↩] ', n) or ''
        local locator = e.file_level and string.format('%s [file]', e.file_rel) or string.format('%s:%d', e.file_rel, e.lnum)
        local line = string.format('%s%s%s  %s', prefix, chip, locator, e.preview)
        if n == 0 then
          return line, nil
        end
        return line, { start_col = #prefix, end_col = #prefix + #chip }
      end

      local function format_lines(es)
        local lines = {
          string.format('# arbiter notes (%s) — %d entries', branch or '<unknown>', #es),
          '# <CR> jump · d resolve · s status · r refresh · q/<Esc> close',
          '',
        }
        if #es == 0 then
          table.insert(lines, '(no notes)')
        else
          for _, e in ipairs(es) do
            local line = format_entry(e)
            table.insert(lines, line)
          end
        end
        return lines
      end

      -- Higher priority than highlight_status_line so the chip color
      -- punches through the hl_eol-filled status background.
      local function apply_entry_highlights(target_buf, es)
        for i, e in ipairs(es) do
          local row = header_rows + i - 1
          highlight_status_line(target_buf, row, e.status)
          local _, chip = format_entry(e)
          if chip then
            vim.api.nvim_buf_set_extmark(target_buf, hl_ns, row, chip.start_col, {
              end_row = row,
              end_col = chip.end_col,
              hl_group = 'ArbiterReplyCount',
              priority = 200,
            })
          end
        end
      end

      local lines = format_lines(entries)

      local width = 40
      for _, l in ipairs(lines) do
        if #l > width then
          width = #l
        end
      end
      width = math.min(width + 2, math.floor(vim.o.columns * 0.85))
      local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.6))

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].filetype = 'arbiter-list'
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      apply_entry_highlights(buf, entries)
      vim.bo[buf].modifiable = false

      local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2)
      local col = math.max(0, math.floor((vim.o.columns - width) / 2))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' arbiter notes ',
        title_pos = 'center',
      })
      vim.wo[win].cursorline = true
      vim.wo[win].wrap = false
      vim.api.nvim_win_set_cursor(win, { math.min(header_rows + 1, vim.api.nvim_buf_line_count(buf)), 0 })

      local function rebuild()
        if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local prev_row = vim.api.nvim_win_get_cursor(win)[1]
        entries = build_entries()
        local new_lines = format_lines(entries)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
        apply_entry_highlights(buf, entries)
        local last_entry_row = header_rows + math.max(#entries, 1)
        local total = vim.api.nvim_buf_line_count(buf)
        local clamped = math.min(prev_row, last_entry_row, total)
        clamped = math.max(clamped, math.min(header_rows + 1, total))
        pcall(vim.api.nvim_win_set_cursor, win, { clamped, 0 })
      end

      local function current_entry()
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
        local i = cursor_row - header_rows
        if i < 1 or i > #entries then
          return nil
        end
        return entries[i]
      end

      local function find_record_index(all, e)
        for i, r in ipairs(all) do
          if r.file == e.file_rel and tostring(r.created_at or '') == tostring(e.created_at or '') then
            local r_is_file = core.is_file_level(r)
            if e.file_level and r_is_file then
              return i
            elseif not e.file_level and not r_is_file and r.line_start == e.lnum then
              return i
            end
          end
        end
        return nil
      end

      local function close()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      local function jump()
        local e = current_entry()
        if not e then
          return
        end
        close()
        vim.cmd('edit ' .. vim.fn.fnameescape(e.fname))
        pcall(vim.api.nvim_win_set_cursor, 0, { e.lnum, 0 })
        vim.cmd 'normal! zz'
      end

      local function resolve_under_cursor()
        local e = current_entry()
        if not e then
          return
        end
        if e.status == 'resolved' then
          vim.notify('arbiter: already resolved', vim.log.levels.INFO)
          return
        end
        local all = core.read_jsonl(jsonl_path)
        local idx = find_record_index(all, e)
        if not idx then
          vim.notify('arbiter: record not found (file changed?)', vim.log.levels.WARN)
          return
        end
        all[idx].status = 'resolved'
        local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
        if not ok_w then
          vim.notify('arbiter: resolve write failed: ' .. tostring(werr), vim.log.levels.ERROR)
          return
        end
        refresh_all_listed_buffers()
        vim.notify('arbiter: resolved', vim.log.levels.INFO)
        rebuild()
      end

      local function status_under_cursor()
        local e = current_entry()
        if not e then
          return
        end
        vim.ui.select(STATUSES, { prompt = 'arbiter status:' }, function(choice)
          if not choice then
            return
          end
          local all = core.read_jsonl(jsonl_path)
          local idx = find_record_index(all, e)
          if not idx then
            vim.notify('arbiter: record not found (file changed?)', vim.log.levels.WARN)
            return
          end
          local new_status = core.normalize_status(choice)
          if core.normalize_status(all[idx].status) == new_status then
            vim.notify('arbiter: no changes', vim.log.levels.INFO)
            return
          end
          all[idx].status = new_status
          local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
          if not ok_w then
            vim.notify('arbiter: status write failed: ' .. tostring(werr), vim.log.levels.ERROR)
            return
          end
          refresh_all_listed_buffers()
          vim.notify('arbiter: status → ' .. choice, vim.log.levels.INFO)
          rebuild()
        end)
      end

      local opts = { buffer = buf, nowait = true, silent = true }
      vim.keymap.set('n', '<CR>', jump, opts)
      vim.keymap.set('n', 'd', resolve_under_cursor, opts)
      vim.keymap.set('n', 's', status_under_cursor, opts)
      vim.keymap.set('n', 'r', rebuild, opts)
      vim.keymap.set('n', 'q', close, opts)
      vim.keymap.set('n', '<Esc>', close, opts)
    end

    function M.clear(opts)
      opts = opts or {}
      local jsonl_path, _, git_dir, err = resolve_paths()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.ERROR)
        return
      end
      local branch = core.current_branch(git_dir)
      if not branch then
        vim.notify('arbiter: could not resolve current branch', vim.log.levels.ERROR)
        return
      end
      local all = core.read_jsonl(jsonl_path)
      local kept, mine = {}, {}
      for _, r in ipairs(all) do
        if r.branch == nil or r.branch == core.NULL or r.branch == branch then
          table.insert(mine, r)
        else
          table.insert(kept, r)
        end
      end
      if #mine == 0 then
        vim.notify('arbiter: nothing to clear for ' .. branch, vim.log.levels.INFO)
        return
      end

      local function do_clear()
        local ok_w, rerr = core.rewrite_jsonl(jsonl_path, kept)
        if not ok_w then
          vim.notify('arbiter: clear failed: ' .. tostring(rerr), vim.log.levels.ERROR)
          return
        end
        vim.diagnostic.reset(diag_ns)
        refresh_all_listed_buffers()
        vim.notify(string.format('arbiter: cleared %d notes for %s', #mine, branch), vim.log.levels.INFO)
      end

      if opts.bang then
        do_clear()
        return
      end

      vim.ui.select({ 'no', 'yes' }, {
        prompt = string.format('Clear %d notes for branch %s?', #mine, branch),
      }, function(choice)
        if choice == 'yes' then
          do_clear()
        end
      end)
    end

    -- Find every record matching the current cursor position. Range notes
    -- match when the cursor is within their resolved range; file-level notes
    -- match for every cursor position in the file. Returns
    --   (all, matches, jsonl_path, err)
    -- where each match is { idx, record, resolved }.
    local function find_records_at_cursor()
      local bufnr = vim.api.nvim_get_current_buf()
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname == '' then
        return nil, nil, nil, 'buffer has no filename'
      end
      local repo_root, git_dir = find_git_root_for(bufname)
      if not repo_root or not git_dir then
        return nil, nil, nil, 'not inside a git repo'
      end
      local jsonl_path = core.resolve_jsonl_path(git_dir)
      local abs = vim.fn.fnamemodify(bufname, ':p')
      local rel = repo_relpath(repo_root, abs)
      if not rel then
        return nil, nil, nil, 'file is outside repo'
      end
      local branch = core.current_branch(git_dir)
      local cursor_lnum = vim.fn.line '.'
      local all = core.read_jsonl(jsonl_path)

      local buf_lines = read_buf_lines(bufnr)
      local buf_norm = core.normalize_buf_lines(buf_lines)
      local matches = {}
      for i, r in ipairs(all) do
        local matches_branch = r.branch == nil or r.branch == core.NULL or r.branch == branch
        if matches_branch and r.file == rel then
          local resolved = core.resolve_anchor(r, buf_lines, nil, buf_norm)
          local hit = false
          if resolved.drift == 'file' then
            hit = true
          elseif type(resolved.line_start) == 'number' and type(resolved.line_end) == 'number'
            and cursor_lnum >= resolved.line_start and cursor_lnum <= resolved.line_end then
            hit = true
          end
          if hit then
            table.insert(matches, { idx = i, record = r, resolved = resolved })
          end
        end
      end
      core.sort_resolved_last(matches, function(m)
        return m.record
      end)
      return all, matches, jsonl_path, nil
    end

    local function note_label(record)
      local note = tostring(record.note or '')
      local first_nl = note:find '\n'
      local preview = first_nl and note:sub(1, first_nl - 1) or note
      if #preview > 60 then
        preview = preview:sub(1, 57) .. '…'
      end
      local n_replies = #core.normalize_comments(record)
      local suffix = n_replies > 0 and string.format(' (%d replies)', n_replies) or ''
      return string.format('[%s] %s%s', core.normalize_status(record.status), preview, suffix)
    end

    local function pick_record_at_cursor(prompt, cb)
      local all, matches, jsonl_path, err = find_records_at_cursor()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.WARN)
        return
      end
      if not matches or #matches == 0 then
        vim.notify('arbiter: no notes on this line', vim.log.levels.WARN)
        return
      end
      if #matches == 1 then
        cb(all, matches[1].idx, jsonl_path)
        return
      end
      vim.ui.select(matches, {
        prompt = prompt or 'arbiter: which note?',
        format_item = function(m)
          return note_label(m.record)
        end,
      }, function(choice)
        if choice then
          cb(all, choice.idx, jsonl_path)
        end
      end)
    end

    function M.set_status(status)
      status = core.normalize_status(status)
      pick_record_at_cursor('arbiter: set status on which note?', function(all, idx, jsonl_path)
        all[idx].status = status
        local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
        if not ok_w then
          vim.notify('arbiter: status write failed: ' .. tostring(werr), vim.log.levels.ERROR)
          return
        end
        refresh_diagnostics_for_buf(vim.api.nvim_get_current_buf())
        vim.notify('arbiter: status → ' .. status, vim.log.levels.INFO)
      end)
    end

    function M.pick_status()
      pick_record_at_cursor('arbiter: which note?', function(all, idx, jsonl_path)
        vim.ui.select(STATUSES, { prompt = 'arbiter status:' }, function(choice)
          if not choice then
            return
          end
          all[idx].status = core.normalize_status(choice)
          local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
          if not ok_w then
            vim.notify('arbiter: status write failed: ' .. tostring(werr), vim.log.levels.ERROR)
            return
          end
          refresh_diagnostics_for_buf(vim.api.nvim_get_current_buf())
          vim.notify('arbiter: status → ' .. choice, vim.log.levels.INFO)
        end)
      end)
    end

    -- Multi-select buffer for resolving 1+ notes on the current line.
    local function open_resolve_picker(all, matches, jsonl_path, source_buf)
      local selected = {}
      for i, m in ipairs(matches) do
        selected[i] = core.normalize_status(m.record.status) == 'resolved'
      end

      local function render_lines()
        local lines = { '# resolve notes  (<Tab> toggle · a all · <CR> apply · q cancel)', '' }
        for i, m in ipairs(matches) do
          local mark = selected[i] and '[x]' or '[ ]'
          table.insert(lines, string.format('%s %s', mark, note_label(m.record)))
        end
        return lines
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].filetype = 'arbiter-picker'
      local function redraw()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines())
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
        for i, m in ipairs(matches) do
          highlight_status_line(buf, i + 1, core.normalize_status(m.record.status))
        end
      end
      redraw()

      local max_w = math.min(80, math.floor(vim.o.columns * 0.7))
      local width = 30
      for _, l in ipairs(render_lines()) do
        if #l > width then
          width = #l
        end
      end
      width = math.min(width + 2, max_w)
      local height = math.min(#matches + 3, math.floor(vim.o.lines * 0.5))

      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'cursor',
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' arbiter: resolve ',
        title_pos = 'center',
      })
      vim.wo[win].cursorline = true
      vim.wo[win].wrap = false
      vim.api.nvim_win_set_cursor(win, { math.min(3, vim.api.nvim_buf_line_count(buf)), 0 })

      local function close()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      local function row_to_match_idx(row)
        local i = row - 2
        if i >= 1 and i <= #matches then
          return i
        end
      end

      local function toggle()
        local row = vim.api.nvim_win_get_cursor(win)[1]
        local i = row_to_match_idx(row)
        if i then
          selected[i] = not selected[i]
          redraw()
          vim.api.nvim_win_set_cursor(win, { row, 0 })
        end
      end

      local function select_all()
        local any_unset = false
        for i = 1, #matches do
          if not selected[i] then
            any_unset = true
            break
          end
        end
        for i = 1, #matches do
          selected[i] = any_unset
        end
        local row = vim.api.nvim_win_get_cursor(win)[1]
        redraw()
        vim.api.nvim_win_set_cursor(win, { row, 0 })
      end

      local function apply()
        local changed = 0
        local any_checked = false
        for i, m in ipairs(matches) do
          if selected[i] then
            any_checked = true
            if core.normalize_status(m.record.status) ~= 'resolved' then
              all[m.idx].status = 'resolved'
              changed = changed + 1
            end
          end
        end
        if not any_checked then
          local row = vim.api.nvim_win_get_cursor(win)[1]
          local i = row_to_match_idx(row)
          if i and core.normalize_status(matches[i].record.status) ~= 'resolved' then
            all[matches[i].idx].status = 'resolved'
            changed = 1
          end
        end
        close()
        if changed == 0 then
          vim.notify('arbiter: no changes', vim.log.levels.INFO)
          return
        end
        local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
        if not ok_w then
          vim.notify('arbiter: resolve write failed: ' .. tostring(werr), vim.log.levels.ERROR)
          return
        end
        if vim.api.nvim_buf_is_valid(source_buf) then
          refresh_diagnostics_for_buf(source_buf)
        end
        vim.notify(string.format('arbiter: resolved %d note%s', changed, changed == 1 and '' or 's'), vim.log.levels.INFO)
      end

      local opts = { buffer = buf, nowait = true, silent = true }
      vim.keymap.set('n', '<Tab>', toggle, opts)
      vim.keymap.set('n', '<Space>', toggle, opts)
      vim.keymap.set('n', 'a', select_all, opts)
      vim.keymap.set('n', '<CR>', apply, opts)
      vim.keymap.set('n', 'q', close, opts)
      vim.keymap.set('n', '<Esc>', close, opts)
    end

    function M.resolve()
      local all, matches, jsonl_path, err = find_records_at_cursor()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.WARN)
        return
      end
      if not matches or #matches == 0 then
        vim.notify('arbiter: no notes on this line', vim.log.levels.WARN)
        return
      end
      local source_buf = vim.api.nvim_get_current_buf()
      if #matches == 1 then
        all[matches[1].idx].status = 'resolved'
        local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
        if not ok_w then
          vim.notify('arbiter: resolve write failed: ' .. tostring(werr), vim.log.levels.ERROR)
          return
        end
        refresh_diagnostics_for_buf(source_buf)
        vim.notify('arbiter: resolved', vim.log.levels.INFO)
        return
      end
      open_resolve_picker(all, matches, jsonl_path, source_buf)
    end

    function M.preview()
      local all, matches, jsonl_path, err = find_records_at_cursor()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.WARN)
        return
      end
      if not matches or #matches == 0 then
        vim.notify('arbiter: no notes on this line', vim.log.levels.WARN)
        return
      end
      local lines = {}
      local heading_rows = {}
      local reply_rows = {}
      for i, m in ipairs(matches) do
        if i > 1 then
          table.insert(lines, '')
          table.insert(lines, '---')
          table.insert(lines, '')
        end
        local offset = #lines
        local rendered = render_record_lines(m.record, m.resolved)
        for _, l in ipairs(rendered.lines) do
          table.insert(lines, l)
        end
        for _, h in ipairs(rendered.heading_rows) do
          table.insert(heading_rows, { row = h.row + offset, status = h.status, match_idx = i })
        end
        for _, rep in ipairs(rendered.reply_rows) do
          local rows = {}
          for _, rr in ipairs(rep.rows) do
            table.insert(rows, rr + offset)
          end
          table.insert(reply_rows, { author = rep.author, rows = rows })
        end
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = 'markdown'
      vim.bo[buf].modifiable = false
      vim.bo[buf].bufhidden = 'wipe'
      for _, h in ipairs(heading_rows) do
        highlight_status_line(buf, h.row, h.status)
      end
      for _, rep in ipairs(reply_rows) do
        highlight_reply_lines(buf, rep.rows, rep.author)
      end

      local source_win_w = vim.api.nvim_win_get_width(0)
      local max_w = math.max(source_win_w, math.floor(vim.o.columns * 0.7))
      local width = math.max(source_win_w, 20)
      for _, l in ipairs(lines) do
        if #l > width then
          width = #l
        end
      end
      width = math.min(width + 2, max_w)
      local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.5))

      local source_buf = vim.api.nvim_get_current_buf()
      local cursor_screen = vim.fn.screenpos(0, vim.fn.line '.', vim.fn.col '.')
      local anchor_row = (cursor_screen and cursor_screen.row and cursor_screen.row > 0) and cursor_screen.row or math.floor(vim.o.lines / 2)
      local anchor_col = (cursor_screen and cursor_screen.col and cursor_screen.col > 0) and cursor_screen.col or 0
      local normal_row = math.min(vim.o.lines - height - 2, anchor_row)
      local normal_col = math.max(0, math.min(vim.o.columns - width - 2, anchor_col - 1))

      -- Map a 1-indexed cursor row in the preview buffer to a `matches` index
      -- by walking heading_rows (0-indexed buffer rows) and picking the largest
      -- heading row <= cursor row - 1. Falls back to match 1 if the cursor is
      -- above the first heading.
      local function match_at(cursor_row)
        local target = cursor_row - 1
        local picked = 1
        for _, h in ipairs(heading_rows) do
          if h.row <= target then
            picked = h.match_idx
          else
            break
          end
        end
        return picked
      end

      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = normal_row,
        col = normal_col,
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' arbiter notes (q close · m maximize · r reply) ',
        title_pos = 'center',
        focusable = true,
      })
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true
      vim.wo[win].cursorline = true

      local function close()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      local maximized = false
      local function toggle_maximize()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        if maximized then
          vim.api.nvim_win_set_config(win, {
            relative = 'editor',
            row = normal_row,
            col = normal_col,
            width = width,
            height = height,
            border = 'rounded',
            title = ' arbiter notes (q close · m maximize · r reply) ',
            title_pos = 'center',
          })
        else
          local big_w = math.max(20, math.floor(vim.o.columns * 0.95))
          local big_h = math.max(5, math.floor(vim.o.lines * 0.9))
          local big_row = math.max(0, math.floor((vim.o.lines - big_h) / 2) - 1)
          local big_col = math.max(0, math.floor((vim.o.columns - big_w) / 2))
          vim.api.nvim_win_set_config(win, {
            relative = 'editor',
            row = big_row,
            col = big_col,
            width = big_w,
            height = big_h,
            border = 'rounded',
            title = ' arbiter notes (q close · m restore · r reply) ',
            title_pos = 'center',
          })
        end
        maximized = not maximized
      end

      local function reply()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
        local mi = match_at(cursor_row)
        local m = matches[mi]
        if not m then
          return
        end
        local idx = m.idx
        local r = m.record
        local meta = {
          file = r.file,
          line_start = r.line_start,
          line_end = r.line_end,
          scope = r.scope,
          title_prefix = 'reply',
        }
        local source_win = vim.fn.bufwinid(source_buf)
        close()
        open_reply_window_with_context(r, meta, function(body)
          local _, err2 = core.append_reply(all, idx, { body = body, author = 'human' })
          if err2 then
            vim.notify('arbiter: reply failed: ' .. tostring(err2), vim.log.levels.ERROR)
            return
          end
          -- A human reply on a needs-rereview note flips it back to pending so
          -- the AI knows to look again on the next pass.
          if all[idx].status == 'needs-rereview' then
            all[idx].status = 'pending'
          end
          local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
          if not ok_w then
            vim.notify('arbiter: reply write failed: ' .. tostring(werr), vim.log.levels.ERROR)
            return
          end
          if vim.api.nvim_buf_is_valid(source_buf) then
            refresh_diagnostics_for_buf(source_buf)
          end
          vim.notify('arbiter: reply saved', vim.log.levels.INFO)
          -- Reopen the preview from the source window so it re-renders with the
          -- new reply included. open_note_window's BufWriteCmd closes the
          -- compose window before our callback returns, so focus is on
          -- whatever window vim returned to — defensively jump back to the
          -- source window before re-invoking M.preview().
          vim.schedule(function()
            if source_win and source_win ~= -1 and vim.api.nvim_win_is_valid(source_win) then
              vim.api.nvim_set_current_win(source_win)
              M.preview()
            end
          end)
        end)
      end

      vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
      vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
      vim.keymap.set('n', 'm', toggle_maximize, { buffer = buf, nowait = true, silent = true })
      vim.keymap.set('n', 'r', reply, { buffer = buf, nowait = true, silent = true })

      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertEnter' }, {
        buffer = source_buf,
        once = true,
        callback = close,
      })
    end

    function M.add_reply()
      local source_bufnr = vim.api.nvim_get_current_buf()
      pick_record_at_cursor('arbiter: reply to which note?', function(all, idx, jsonl_path)
        local r = all[idx]
        local meta = {
          file = r.file,
          line_start = r.line_start,
          line_end = r.line_end,
          scope = r.scope,
          title_prefix = 'reply',
        }
        open_reply_window_with_context(r, meta, function(body)
          local reply, err = core.append_reply(all, idx, { body = body, author = 'human' })
          if not reply then
            vim.notify('arbiter: reply failed: ' .. tostring(err), vim.log.levels.ERROR)
            return
          end
          if all[idx].status == 'needs-rereview' then
            all[idx].status = 'pending'
          end
          local ok_w, werr = core.rewrite_jsonl(jsonl_path, all)
          if not ok_w then
            vim.notify('arbiter: reply write failed: ' .. tostring(werr), vim.log.levels.ERROR)
            return
          end
          if vim.api.nvim_buf_is_valid(source_bufnr) then
            refresh_diagnostics_for_buf(source_bufnr)
          end
          vim.notify('arbiter: reply saved', vim.log.levels.INFO)
        end)
      end)
    end

    vim.api.nvim_create_user_command('Arbiter', function(opts)
      local s = opts.line1 or vim.fn.line '.'
      local e = opts.line2 or s
      M.add_comment(s, e)
    end, { range = true, desc = 'arbiter: leave review feedback on AI-written code' })

    vim.api.nvim_create_user_command('ArbiterReply', function()
      M.add_reply()
    end, { desc = 'arbiter: reply to a note on the current line' })

    vim.api.nvim_create_user_command('ArbiterFileComment', function()
      M.add_file_comment()
    end, { desc = 'arbiter: leave a file-level review note (no line range)' })

    vim.keymap.set('n', '<leader>gF', function()
      M.add_file_comment()
    end, { desc = 'arbiter: [F]ile-level review comment' })

    vim.keymap.set('n', '<leader>gr', function()
      local l = vim.fn.line '.'
      M.add_comment(l, l)
    end, { desc = 'arbiter: [G]it [R]eview comment (line)' })

    vim.keymap.set('v', '<leader>gr', function()
      vim.cmd 'normal! \27'
      local s = vim.fn.line "'<"
      local e = vim.fn.line "'>"
      if s > e then
        s, e = e, s
      end
      M.add_comment(s, e)
    end, { desc = 'arbiter: [G]it [R]eview comment (selection)' })

    vim.api.nvim_create_user_command('ArbiterShow', function()
      M.show()
    end, { desc = 'arbiter: show current branch notes in quickfix' })

    vim.api.nvim_create_user_command('ArbiterClear', function(opts)
      M.clear { bang = opts.bang }
    end, { bang = true, desc = 'arbiter: clear current branch notes' })

    vim.api.nvim_create_user_command('ArbiterSigns', function(opts)
      local arg = opts.args
      if arg == 'disable' then
        vim.g.arbiter_signs_enabled = false
        vim.diagnostic.reset(diag_ns)
      elseif arg == 'enable' then
        vim.g.arbiter_signs_enabled = true
        refresh_all_listed_buffers()
      elseif arg == 'toggle' then
        vim.g.arbiter_signs_enabled = not vim.g.arbiter_signs_enabled
        if vim.g.arbiter_signs_enabled then
          refresh_all_listed_buffers()
        else
          vim.diagnostic.reset(diag_ns)
        end
      else
        vim.notify('arbiter: usage :ArbiterSigns {enable|disable|toggle}', vim.log.levels.ERROR)
      end
    end, {
      nargs = 1,
      complete = function()
        return { 'enable', 'disable', 'toggle' }
      end,
      desc = 'arbiter: enable/disable/toggle inline diagnostics',
    })

    vim.keymap.set('n', '<leader>gc', function()
      M.clear {}
    end, { desc = 'arbiter: [C]lear branch review notes' })

    vim.keymap.set('n', '<leader>gl', function()
      M.show()
    end, { desc = 'arbiter: [L]ist branch review notes (quickfix)' })

    vim.keymap.set('n', '<leader>gt', function()
      vim.g.arbiter_signs_enabled = not vim.g.arbiter_signs_enabled
      if vim.g.arbiter_signs_enabled then
        refresh_all_listed_buffers()
        vim.notify('arbiter: signs enabled', vim.log.levels.INFO)
      else
        vim.diagnostic.reset(diag_ns)
        vim.notify('arbiter: signs disabled', vim.log.levels.INFO)
      end
    end, { desc = 'arbiter: [T]oggle inline diagnostics' })

    vim.api.nvim_create_user_command('ArbiterStatus', function(opts)
      if opts.args == '' then
        M.pick_status()
      else
        M.set_status(opts.args)
      end
    end, {
      nargs = '?',
      complete = function()
        return STATUSES
      end,
      desc = 'arbiter: set status of note under cursor',
    })

    vim.keymap.set('n', '<leader>gs', function()
      M.pick_status()
    end, { desc = 'arbiter: set [S]tatus of note under cursor' })

    vim.keymap.set('n', '<leader>gd', function()
      M.resolve()
    end, { desc = 'arbiter: mark note under cursor [D]one (resolved)' })

    vim.keymap.set('n', '<leader>gp', function()
      M.preview()
    end, { desc = 'arbiter: [P]review notes on current line in floating window' })

    vim.keymap.set('n', '<leader>gR', function()
      M.add_reply()
    end, { desc = 'arbiter: [R]eply to note on current line' })

    function M.goto_note(direction)
      local jsonl_path, repo_root, git_dir, err = resolve_paths()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.WARN)
        return
      end
      local branch = core.current_branch(git_dir)
      local records = core.filter_for_branch(core.read_jsonl(jsonl_path), branch)
      -- STATUS_SEVERITY only maps unresolved statuses, so this filter
      -- skips resolved notes implicitly (same trick as the diagnostics).
      local entries = {}
      for _, r in ipairs(records) do
        local status = core.normalize_status(r.status)
        if STATUS_SEVERITY[status] and r.file then
          if core.is_file_level(r) then
            table.insert(entries, { file = r.file, lnum = 1 })
          else
            table.insert(entries, { file = r.file, lnum = r.line_start })
          end
        end
      end
      if #entries == 0 then
        vim.notify('arbiter: no notes for ' .. (branch or '<unknown>'), vim.log.levels.INFO)
        return
      end
      table.sort(entries, function(a, b)
        if a.file == b.file then
          return a.lnum < b.lnum
        end
        return a.file < b.file
      end)

      local cur_bufname = vim.api.nvim_buf_get_name(0)
      local cur_rel, root_abs
      if cur_bufname ~= '' then
        local abs = vim.fn.fnamemodify(cur_bufname, ':p')
        cur_rel, root_abs = repo_relpath(repo_root, abs)
      end
      if not root_abs then
        root_abs = vim.fn.fnamemodify(repo_root, ':p'):gsub('/$', '')
      end
      local cur_lnum = vim.fn.line '.'

      local function cmp(a_file, a_lnum, b_file, b_lnum)
        if a_file == b_file then
          if a_lnum == b_lnum then
            return 0
          end
          return a_lnum < b_lnum and -1 or 1
        end
        return a_file < b_file and -1 or 1
      end

      local target
      if direction == 'next' then
        for _, e in ipairs(entries) do
          if not cur_rel or cmp(e.file, e.lnum, cur_rel, cur_lnum) > 0 then
            target = e
            break
          end
        end
        if not target then
          target = entries[1]
        end
      else
        for i = #entries, 1, -1 do
          local e = entries[i]
          if not cur_rel or cmp(e.file, e.lnum, cur_rel, cur_lnum) < 0 then
            target = e
            break
          end
        end
        if not target then
          target = entries[#entries]
        end
      end

      local target_abs = root_abs .. '/' .. target.file
      if target.file ~= cur_rel then
        vim.cmd('edit ' .. vim.fn.fnameescape(target_abs))
      end
      pcall(vim.api.nvim_win_set_cursor, 0, { target.lnum, 0 })
      vim.cmd 'normal! zz'
    end

    vim.keymap.set('n', ']g', function()
      M.goto_note 'next'
    end, { desc = 'arbiter: jump to next note (across files)' })

    vim.keymap.set('n', '[g', function()
      M.goto_note 'prev'
    end, { desc = 'arbiter: jump to previous note (across files)' })

    local diag_group = vim.api.nvim_create_augroup('ArbiterDiagnostics', { clear = true })
    vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
      group = diag_group,
      callback = function(ev)
        refresh_diagnostics_for_buf(ev.buf)
      end,
    })
    vim.api.nvim_create_autocmd('User', {
      group = diag_group,
      pattern = 'FugitiveChanged',
      callback = function()
        refresh_all_listed_buffers()
      end,
    })

    vim.schedule(refresh_all_listed_buffers)

    vim.api.nvim_create_user_command('ArbiterRefresh', function()
      refresh_all_listed_buffers()
    end, { desc = 'arbiter: re-read JSONL and refresh inline diagnostics' })
  end,
}
