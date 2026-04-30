-- arbiter: a tool for a HUMAN to leave GitHub-style review notes on code an AI
-- assistant wrote. Visual-select lines in a fugitive diff (or any buffer),
-- press <leader>gr, type a note. Notes are appended to <repo>/.git/arbiter.jsonl.
-- That JSONL file is meant to be read back by the AI assistant (e.g. Claude
-- Code) so it can apply the human reviewer's feedback to the code.
--
-- Git integration is built specifically against vim-fugitive (tpope/vim-fugitive):
-- the diff-position parser keys off `&filetype == 'git'` (the filetype fugitive
-- sets on `:Git show <sha>` buffers), and commit SHA resolution uses
-- `FugitiveParse()` and `FugitiveGitDir()`. Other git plugins (gitsigns,
-- diffview, neogit) are not supported for the diff-mapping path; in those
-- buffers arbiter falls back to the regular-buffer behavior (filename + raw
-- line numbers, no commit SHA).
--
-- Each record carries a `branch` field (resolved at write-time). On detached
-- HEAD the short SHA is stored as the branch. Commands:
--   :Arbiter        leave a note on the current line/selection (<leader>gr)
--   :ArbiterShow    load current branch's notes into the quickfix list
--   :ArbiterClear[!] clear notes for the current branch (<leader>gR, prompts)
--   :ArbiterSigns {enable|disable|toggle}  toggle inline diagnostics
--   :ArbiterStatus {pending|in-progress|needs-rereview}  set status of note under cursor (<leader>gs)
-- Inline diagnostics (severity varies by status) display notes on their
-- target lines for the current branch only. Records without a `branch` field
-- (older entries) match every branch for back-compat.
--
-- Record schema (one JSON object per line in <repo>/.git/arbiter.jsonl):
--   file:        repo-relative path
--   line_start:  1-indexed start line in the post-image
--   line_end:    1-indexed end line
--   commit:      short SHA when set from a fugitive diff buffer (else null)
--   branch:      branch name, or short SHA on detached HEAD (null on error)
--   note:        free-text review comment (markdown ok)
--   created_at:  ISO-8601 timestamp with offset
--   status:      "pending" (default on write) | "in-progress" | "needs-rereview"
-- An AI assistant addressing a note should rewrite the matching record's
-- `status` field (identify by file + line_start + branch + created_at).
-- Records missing `status` are treated as "pending" for back-compat.

return {
  dir = vim.fn.stdpath 'config' .. '/lua/custom/local-plugins/arbiter',
  name = 'arbiter',
  lazy = false,
  config = function()
    local M = {}

    local function find_git_root(start_path)
      local start = start_path
      if not start or start == '' then
        start = vim.fn.getcwd()
      end
      local found = vim.fs.find('.git', { upward = true, type = 'directory', path = start })
      if not found or not found[1] then
        return nil, nil
      end
      local git_dir = found[1]
      local repo_root = vim.fs.dirname(git_dir)
      return repo_root, git_dir
    end

    -- Resolve the current branch for a given git_dir. Returns string|nil.
    -- On detached HEAD (rev-parse --abbrev-ref returns "HEAD") falls back to
    -- the short SHA so records can still be partitioned per-checkout.
    local function current_branch(git_dir)
      if not git_dir or git_dir == '' then
        return nil
      end
      local out = vim.fn.system { 'git', '--git-dir=' .. git_dir, 'rev-parse', '--abbrev-ref', 'HEAD' }
      if vim.v.shell_error ~= 0 then
        return nil
      end
      local name = (out or ''):gsub('%s+$', '')
      if name == '' then
        return nil
      end
      if name == 'HEAD' then
        local sha_out = vim.fn.system { 'git', '--git-dir=' .. git_dir, 'rev-parse', '--short=12', 'HEAD' }
        if vim.v.shell_error ~= 0 then
          return nil
        end
        local sha = (sha_out or ''):gsub('%s+$', '')
        if sha == '' then
          return nil
        end
        return sha
      end
      return name
    end

    -- Resolve (jsonl_path, repo_root, git_dir, err). Tries fugitive first,
    -- falls back to .git discovery from cwd. err is a string when something
    -- failed; jsonl_path is otherwise <git_dir>/arbiter.jsonl.
    local function resolve_paths()
      local repo_root, git_dir
      local ok, repo = pcall(vim.fn.FugitiveGitDir)
      if ok and type(repo) == 'string' and repo ~= '' then
        git_dir = repo
        repo_root = vim.fs.dirname(repo)
      else
        repo_root, git_dir = find_git_root(vim.fn.getcwd())
      end
      if not repo_root or not git_dir then
        return nil, nil, nil, 'not inside a git repo'
      end
      return git_dir .. '/arbiter.jsonl', repo_root, git_dir, nil
    end

    -- Read a JSONL file line-by-line. Malformed lines are silently skipped so
    -- one bad entry doesn't break show/clear. Missing file → {}.
    local function read_jsonl(path)
      local f = io.open(path, 'r')
      if not f then
        return {}
      end
      local records = {}
      for line in f:lines() do
        if line ~= '' then
          local ok, decoded = pcall(vim.json.decode, line)
          if ok and type(decoded) == 'table' then
            table.insert(records, decoded)
          end
        end
      end
      f:close()
      return records
    end

    -- Keep records whose branch matches `branch`, or that have no branch
    -- (back-compat with pre-tagging entries). When `branch` is nil, return
    -- everything.
    local function filter_for_branch(records, branch)
      if not branch then
        return records
      end
      local out = {}
      for _, r in ipairs(records) do
        if r.branch == nil or r.branch == vim.NIL or r.branch == branch then
          table.insert(out, r)
        end
      end
      return out
    end

    local STATUSES = { 'pending', 'in-progress', 'needs-rereview' }

    local function normalize_status(s)
      if s == nil or s == vim.NIL or s == '' then
        return 'pending'
      end
      for _, v in ipairs(STATUSES) do
        if v == s then
          return s
        end
      end
      return 'pending'
    end

    local STATUS_SEVERITY = {
      ['pending'] = vim.diagnostic.severity.HINT,
      ['in-progress'] = vim.diagnostic.severity.INFO,
      ['needs-rereview'] = vim.diagnostic.severity.WARN,
    }

    local STATUS_QF_TYPE = {
      ['pending'] = 'I',
      ['in-progress'] = 'W',
      ['needs-rereview'] = 'E',
    }

    -- Atomic rewrite via tmp + rename inside .git/.
    local function rewrite_jsonl(path, records)
      local tmp = path .. '.tmp'
      local f, err = io.open(tmp, 'w')
      if not f then
        return false, err
      end
      for _, r in ipairs(records) do
        local ok, encoded = pcall(vim.json.encode, r)
        if ok then
          f:write(encoded .. '\n')
        end
      end
      f:close()
      local ok, rename_err = os.rename(tmp, path)
      if not ok then
        return false, rename_err
      end
      return true
    end

    local diag_ns = vim.api.nvim_create_namespace 'arbiter'
    if vim.g.arbiter_signs_enabled == nil then
      vim.g.arbiter_signs_enabled = true
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
      local repo_root, git_dir = find_git_root(bufname)
      if not repo_root or not git_dir then
        return
      end
      local jsonl_path = git_dir .. '/arbiter.jsonl'
      local abs = vim.fn.fnamemodify(bufname, ':p')
      local root_abs = vim.fn.fnamemodify(repo_root, ':p'):gsub('/$', '')
      if abs:sub(1, #root_abs + 1) ~= root_abs .. '/' then
        return
      end
      local rel = abs:sub(#root_abs + 2)
      local branch = current_branch(git_dir)
      local records = filter_for_branch(read_jsonl(jsonl_path), branch)
      local diagnostics = {}
      for _, r in ipairs(records) do
        if r.file == rel and type(r.line_start) == 'number' and type(r.line_end) == 'number' then
          local lnum = math.max(0, r.line_start - 1)
          local end_lnum = math.max(lnum, r.line_end - 1)
          local status = normalize_status(r.status)
          table.insert(diagnostics, {
            lnum = lnum,
            end_lnum = end_lnum,
            col = 0,
            severity = STATUS_SEVERITY[status],
            source = 'arbiter',
            message = '[' .. status .. '] ' .. tostring(r.note or ''),
          })
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
    -- For named refs, ask git to resolve them. We require >=7 hex chars to
    -- avoid matching a 3-char hex word like "abc" in some unexpected rev format.
    local function fugitive_commit_sha(bufnr, git_dir)
      local ok, parsed = pcall(vim.fn.FugitiveParse, vim.api.nvim_buf_get_name(bufnr))
      if not ok or type(parsed) ~= 'table' then
        return nil
      end
      local rev = parsed[1]
      if type(rev) ~= 'string' or rev == '' then
        return nil
      end
      -- Strip trailing ":path" if present.
      local rev_only = rev:match '^([^:]+)' or rev
      -- If it already looks like a SHA, take its short form directly.
      local sha = rev_only:match '^([0-9a-fA-F]+)$'
      if sha and #sha >= 7 then
        return sha:sub(1, 12)
      end
      -- Otherwise resolve via git rev-parse (e.g. "HEAD" -> "abc1234").
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

    -- Walk backwards from `lnum` (1-indexed) to find the most recent line
    -- matching `pattern` (single capture). Returns (lineno, capture) or nil.
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

      -- Walk from the line right after the hunk header down to end_line,
      -- counting non-deletion lines to compute file-line numbers.
      local lines = vim.api.nvim_buf_get_lines(bufnr, hunk_lnum, end_line, false)
      local file_lno = new_start - 1
      local mapped_start, mapped_end = nil, nil
      local cur_diff_line = hunk_lnum -- line number of last consumed line
      for _, line in ipairs(lines) do
        cur_diff_line = cur_diff_line + 1
        local first = line:sub(1, 1)
        if first == '@' then
          -- entered a new hunk; reset based on this header
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
        else
          -- diff header lines (---, +++, etc.) — ignore
        end
      end

      if not mapped_start then
        -- selection contained only deletions / non-mappable lines
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

    local function json_escape(s)
      return (
        s:gsub('\\', '\\\\')
          :gsub('"', '\\"')
          :gsub('\n', '\\n')
          :gsub('\r', '\\r')
          :gsub('\t', '\\t')
          :gsub('[%z\1-\31]', function(c)
            return string.format('\\u%04x', c:byte())
          end)
      )
    end

    local function append_jsonl(path, record)
      local encoded
      local ok, res = pcall(vim.json.encode, record)
      if ok then
        encoded = res
      else
        -- fallback minimal encoder (shouldn't happen with neovim's vim.json)
        local parts = {}
        for k, v in pairs(record) do
          if v == vim.NIL or v == nil then
            table.insert(parts, string.format('"%s":null', k))
          elseif type(v) == 'number' then
            table.insert(parts, string.format('"%s":%d', k, v))
          else
            table.insert(parts, string.format('"%s":"%s"', k, json_escape(tostring(v))))
          end
        end
        encoded = '{' .. table.concat(parts, ',') .. '}'
      end
      local f, err = io.open(path, 'a')
      if not f then
        return false, err
      end
      f:write(encoded .. '\n')
      f:close()
      return true
    end

    local function iso8601_now()
      -- e.g. 2026-04-30T14:22:00-04:00
      local stamp = os.date '%Y-%m-%dT%H:%M:%S'
      local tz = os.date '%z' -- like -0400
      if type(tz) == 'string' and #tz == 5 then
        tz = tz:sub(1, 3) .. ':' .. tz:sub(4, 5)
      end
      return stamp .. (tz or '')
    end

    local function open_note_window(meta, on_save, on_cancel)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'acwrite'
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].filetype = 'markdown'
      vim.bo[buf].swapfile = false
      local title = string.format('review: %s:%d-%d', meta.file, meta.line_start, meta.line_end)
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
          vim.notify(
            'arbiter: could not locate diff header / hunk for selection',
            vim.log.levels.ERROR
          )
          return
        end
        file_path = pos.file
        line_start = pos.line_start
        line_end = pos.line_end
        deletions_only = pos.deletions_only
        -- Repo root: try fugitive, fall back to .git discovery from cwd.
        local ok, repo = pcall(vim.fn.FugitiveGitDir)
        if ok and type(repo) == 'string' and repo ~= '' then
          git_dir = repo
          repo_root = vim.fs.dirname(repo)
        else
          repo_root, git_dir = find_git_root(vim.fn.getcwd())
        end
        commit = fugitive_commit_sha(bufnr, git_dir)
      else
        if bufname == '' then
          vim.notify('arbiter: buffer has no filename', vim.log.levels.ERROR)
          return
        end
        repo_root, git_dir = find_git_root(bufname)
        if not repo_root then
          vim.notify('arbiter: not inside a git repo', vim.log.levels.ERROR)
          return
        end
        file_path = vim.fn.fnamemodify(bufname, ':p')
        -- make repo-relative
        local root_abs = vim.fn.fnamemodify(repo_root, ':p'):gsub('/$', '')
        if file_path:sub(1, #root_abs + 1) == root_abs .. '/' then
          file_path = file_path:sub(#root_abs + 2)
        end
        line_start = start_line
        line_end = end_line
      end

      if not repo_root or not git_dir then
        vim.notify('arbiter: not inside a git repo', vim.log.levels.ERROR)
        return
      end

      if deletions_only then
        vim.notify(
          'arbiter: selection only contains deletions; recorded at hunk start',
          vim.log.levels.WARN
        )
      end

      local meta = {
        file = file_path,
        line_start = line_start,
        line_end = line_end,
        commit = commit,
      }

      local jsonl_path = git_dir .. '/arbiter.jsonl'
      local branch = current_branch(git_dir)

      open_note_window(meta, function(note)
        local record = {
          file = meta.file,
          line_start = meta.line_start,
          line_end = meta.line_end,
          commit = meta.commit, -- nil → omitted by vim.json.encode
          branch = branch,
          note = note,
          created_at = iso8601_now(),
          status = 'pending',
        }
        if record.commit == nil then
          record.commit = vim.NIL
        end
        if record.branch == nil then
          record.branch = vim.NIL
        end
        local ok, err = append_jsonl(jsonl_path, record)
        if not ok then
          vim.notify('arbiter: write failed: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify(
          string.format(
            'arbiter: saved %s:%d-%d → %s',
            meta.file,
            meta.line_start,
            meta.line_end,
            vim.fn.fnamemodify(jsonl_path, ':~')
          ),
          vim.log.levels.INFO
        )
        -- Refresh diagnostics on the source buffer so the new note shows up
        -- immediately (regular-buffer flow). Fugitive diff buffers have no
        -- working-tree file behind them, so the refresh is a no-op there.
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
      local branch = current_branch(git_dir)
      local records = filter_for_branch(read_jsonl(jsonl_path), branch)
      if #records == 0 then
        vim.notify('arbiter: no notes for ' .. (branch or '<unknown>'), vim.log.levels.INFO)
        return
      end
      local items = {}
      for _, r in ipairs(records) do
        if r.file and type(r.line_start) == 'number' then
          local note = tostring(r.note or '')
          local first_nl = note:find '\n'
          local preview
          if first_nl then
            preview = note:sub(1, first_nl - 1) .. ' …'
          else
            preview = note
          end
          local status = normalize_status(r.status)
          table.insert(items, {
            filename = repo_root .. '/' .. r.file,
            lnum = r.line_start,
            end_lnum = type(r.line_end) == 'number' and r.line_end or r.line_start,
            text = '[' .. status .. '] ' .. preview,
            type = STATUS_QF_TYPE[status],
          })
        end
      end
      vim.fn.setqflist({}, ' ', {
        title = 'arbiter notes (' .. (branch or '<unknown>') .. ')',
        items = items,
      })
      vim.cmd 'copen'
    end

    function M.clear(opts)
      opts = opts or {}
      local jsonl_path, _, git_dir, err = resolve_paths()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.ERROR)
        return
      end
      local branch = current_branch(git_dir)
      if not branch then
        vim.notify('arbiter: could not resolve current branch', vim.log.levels.ERROR)
        return
      end
      -- Untagged (back-compat) records match any branch, so a clear on the
      -- current branch sweeps them too.
      local all = read_jsonl(jsonl_path)
      local kept, mine = {}, {}
      for _, r in ipairs(all) do
        if r.branch == nil or r.branch == vim.NIL or r.branch == branch then
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
        local ok, rerr = rewrite_jsonl(jsonl_path, kept)
        if not ok then
          vim.notify('arbiter: clear failed: ' .. tostring(rerr), vim.log.levels.ERROR)
          return
        end
        vim.diagnostic.reset(diag_ns)
        refresh_all_listed_buffers()
        vim.notify(
          string.format('arbiter: cleared %d notes for %s', #mine, branch),
          vim.log.levels.INFO
        )
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

    -- Find the record covering the cursor in the current buffer (current
    -- branch, file matches buffer, line range covers cursor line). Returns
    -- (records, index) into the original on-disk array, or nil.
    local function find_record_at_cursor()
      local bufnr = vim.api.nvim_get_current_buf()
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname == '' then
        return nil, nil, nil, 'buffer has no filename'
      end
      local repo_root, git_dir = find_git_root(bufname)
      if not repo_root or not git_dir then
        return nil, nil, nil, 'not inside a git repo'
      end
      local jsonl_path = git_dir .. '/arbiter.jsonl'
      local abs = vim.fn.fnamemodify(bufname, ':p')
      local root_abs = vim.fn.fnamemodify(repo_root, ':p'):gsub('/$', '')
      if abs:sub(1, #root_abs + 1) ~= root_abs .. '/' then
        return nil, nil, nil, 'file is outside repo'
      end
      local rel = abs:sub(#root_abs + 2)
      local branch = current_branch(git_dir)
      local cursor_lnum = vim.fn.line '.'
      local all = read_jsonl(jsonl_path)
      for i, r in ipairs(all) do
        local matches_branch = r.branch == nil or r.branch == vim.NIL or r.branch == branch
        if
          matches_branch
          and r.file == rel
          and type(r.line_start) == 'number'
          and type(r.line_end) == 'number'
          and cursor_lnum >= r.line_start
          and cursor_lnum <= r.line_end
        then
          return all, i, jsonl_path, nil
        end
      end
      return nil, nil, nil, 'no arbiter note on this line'
    end

    function M.set_status(status)
      status = normalize_status(status)
      local all, idx, jsonl_path, err = find_record_at_cursor()
      if err then
        vim.notify('arbiter: ' .. err, vim.log.levels.WARN)
        return
      end
      all[idx].status = status
      local ok, werr = rewrite_jsonl(jsonl_path, all)
      if not ok then
        vim.notify('arbiter: status write failed: ' .. tostring(werr), vim.log.levels.ERROR)
        return
      end
      refresh_diagnostics_for_buf(vim.api.nvim_get_current_buf())
      vim.notify('arbiter: status → ' .. status, vim.log.levels.INFO)
    end

    function M.pick_status()
      vim.ui.select(STATUSES, { prompt = 'arbiter status:' }, function(choice)
        if choice then
          M.set_status(choice)
        end
      end)
    end

    vim.api.nvim_create_user_command('Arbiter', function(opts)
      local s = opts.line1 or vim.fn.line '.'
      local e = opts.line2 or s
      M.add_comment(s, e)
    end, { range = true, desc = 'arbiter: leave review feedback on AI-written code' })

    vim.keymap.set('n', '<leader>gr', function()
      local l = vim.fn.line '.'
      M.add_comment(l, l)
    end, { desc = 'arbiter: [G]it [R]eview comment (line)' })

    vim.keymap.set('v', '<leader>gr', function()
      -- Leave visual mode so '< and '> are set, then read the marks.
      vim.cmd 'normal! \27' -- <Esc>
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

    vim.keymap.set('n', '<leader>gR', function()
      M.clear {}
    end, { desc = 'arbiter: clear branch [R]eview notes' })

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
  end,
}
