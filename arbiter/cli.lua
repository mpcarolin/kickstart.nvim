#!/usr/bin/env lua
-- arbiter CLI: thin wrapper around lua/custom/local-plugins/arbiter/core.lua.
-- Resolves the script's location so it works whether installed via symlink
-- (~/.local/bin/arbiter) or invoked directly.

local function script_dir()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then
    src = src:sub(2)
  end
  -- Resolve symlinks so we find core.lua relative to the real script path.
  local p = io.popen('readlink -f ' .. string.format('%q', src) .. ' 2>/dev/null')
  if p then
    local resolved = p:read '*a'
    p:close()
    if resolved and resolved ~= '' then
      src = resolved:gsub('%s+$', '')
    end
  end
  return src:match '^(.*)/[^/]+$'
end

local self_dir = script_dir() or '.'
-- Default install: ~/.config/nvim/arbiter/cli.lua sits next to its core via
-- ../lua/custom/local-plugins/arbiter/core.lua.
package.path = table.concat({
  self_dir .. '/../lua/custom/local-plugins/arbiter/?.lua',
  package.path,
}, ';')

local ok, core = pcall(require, 'core')
if not ok then
  io.stderr:write 'arbiter: failed to load core module:\n'
  io.stderr:write(tostring(core) .. '\n')
  os.exit(2)
end

-- =====================================================================
-- argv parsing.
-- =====================================================================

local function die(msg, code)
  io.stderr:write('arbiter: ' .. msg .. '\n')
  os.exit(code or 1)
end

local function parse_status_list(s)
  local set = {}
  for tok in (s .. ','):gmatch '([^,]+),' do
    tok = tok:gsub('%s+', '')
    if tok ~= '' then
      if not core.is_status(tok) then
        die("invalid status '" .. tok .. "' (one of: " .. table.concat(core.STATUSES, ', ') .. ')')
      end
      set[tok] = true
    end
  end
  return set
end

local function parse_args(argv)
  local opts = {}
  local i = 1
  local function need(flag)
    i = i + 1
    if argv[i] == nil then
      die('flag ' .. flag .. ' needs a value')
    end
    return argv[i]
  end
  while i <= #argv do
    local a = argv[i]
    if a == '--json' then
      opts.json = true
    elseif a == '--status' then
      opts.status_set = parse_status_list(need '--status')
    elseif a == '--all-statuses' then
      local set = {}
      for _, s in ipairs(core.STATUSES) do
        set[s] = true
      end
      opts.status_set = set
    elseif a == '--branch' then
      opts.branch_override = need '--branch'
    elseif a == '--all-branches' then
      opts.all_branches = true
    elseif a == '--file' then
      opts.file_substring = need '--file'
    elseif a == '--file-regex' then
      opts.file_regex = need '--file-regex'
    elseif a == '--line' then
      local n = tonumber(need '--line')
      if not n then
        die '--line needs a number'
      end
      opts.line = n
    elseif a == '--line-range' then
      local v = need '--line-range'
      local lo, hi = v:match '^(%d+)%-(%d+)$'
      if not lo then
        die "--line-range needs A-B (e.g. '40-60')"
      end
      opts.line_range = { tonumber(lo), tonumber(hi) }
    elseif a == '--commit' then
      -- Dual-purpose: list filter (`commit_prefix`) and add override (`commit`).
      -- Both shapes are populated; subcommand handlers pick the one they need.
      local v = need '--commit'
      opts.commit_prefix = v
      opts.commit = v
    elseif a == '--commit-null' then
      opts.commit_null = true
    elseif a == '--grep' then
      opts.grep = need '--grep'
    elseif a == '--grep-regex' then
      opts.grep_regex = need '--grep-regex'
    elseif a == '--since' then
      local v = need '--since'
      local epoch = core.parse_when(v)
      if not epoch then
        die("invalid --since value '" .. v .. "' (try '7d', '24h', '2026-04-01', or '2026-04-01T00:00:00-04:00')")
      end
      opts.since = epoch
    elseif a == '--until' then
      local v = need '--until'
      local epoch = core.parse_when(v)
      if not epoch then
        die("invalid --until value '" .. v .. "' (try '7d', '24h', '2026-04-01', or '2026-04-01T00:00:00-04:00')")
      end
      opts['until'] = epoch
    elseif a == '--limit' then
      local n = tonumber(need '--limit')
      if not n or n < 0 then
        die '--limit needs a non-negative integer'
      end
      opts.limit = math.floor(n)
    elseif a == '-h' or a == '--help' then
      opts.help = true
    elseif a:sub(1, 2) == '--' then
      die("unknown flag '" .. a .. "'")
    else
      table.insert(opts, a)
    end
    i = i + 1
  end
  return opts
end

-- =====================================================================
-- Repo / JSONL setup helpers.
-- =====================================================================

local function setup(opts)
  local cwd = os.getenv 'PWD'
  local git_dir, repo_root = core.find_git_root(cwd)
  if not git_dir then
    die('not inside a git repo', 3)
  end
  local jsonl = core.resolve_jsonl_path(git_dir)
  if not jsonl then
    die('cannot resolve jsonl path', 3)
  end
  -- The CLI requires the file to exist; absence means arbiter isn't in use.
  local f = io.open(jsonl, 'r')
  if not f then
    die('arbiter not in use here (no ' .. jsonl .. ')', 4)
  end
  f:close()
  local branch
  if opts and opts.all_branches then
    branch = nil
  elseif opts and opts.branch_override then
    branch = opts.branch_override
  else
    branch = core.current_branch(git_dir)
  end
  return {
    git_dir = git_dir,
    repo_root = repo_root,
    jsonl = jsonl,
    branch = branch,
  }
end

-- Add the synthetic `id` field to a record (returned for output, not written
-- back to disk).
local function with_id(record)
  local out = {}
  out.id = core.record_id(record)
  for k, v in pairs(record) do
    out[k] = v
  end
  return out
end

local function preview(s, n)
  s = tostring(s or '')
  s = s:gsub('\n.*$', ''):gsub('%s+$', '')
  n = n or 80
  if #s > n then
    return s:sub(1, n - 1) .. '…'
  end
  return s
end

-- =====================================================================
-- Subcommands.
-- =====================================================================

local function cmd_list(opts)
  local ctx = setup(opts)
  local records = core.read_jsonl(ctx.jsonl)

  -- Build apply_filters opts. Default status set = pending + needs-rereview.
  local filt = {
    status_set = opts.status_set or { ['pending'] = true, ['needs-rereview'] = true },
    branch = ctx.branch,
    all_branches = opts.all_branches,
    file_substring = opts.file_substring,
    file_regex = opts.file_regex,
    line = opts.line,
    line_range = opts.line_range,
    commit_prefix = opts.commit_prefix,
    grep = opts.grep,
    grep_regex = opts.grep_regex,
    since = opts.since,
    ['until'] = opts['until'],
    limit = opts.limit,
  }
  local results = core.apply_filters(records, filt)

  if opts.json then
    local arr = {}
    for i, r in ipairs(results) do
      arr[i] = with_id(r)
    end
    io.write(core.cjson.encode(arr))
    io.write '\n'
    return 0
  end

  for _, r in ipairs(results) do
    local id = core.record_id(r)
    local status = core.normalize_status(r.status)
    local file = tostring(r.file or '?')
    local ls = tonumber(r.line_start) or 0
    local le = tonumber(r.line_end) or ls
    io.write(string.format('%s  [%s]  %s:%d-%d  %s\n', id, status, file, ls, le, preview(r.note, 80)))
  end
  return 0
end

local function format_show(record, want_json)
  if want_json then
    return core.cjson.encode(with_id(record))
  end
  local id = core.record_id(record)
  local status = core.normalize_status(record.status)
  local lines = {
    string.format('id:         %s', id),
    string.format('status:     %s', status),
    string.format('file:       %s', tostring(record.file or '?')),
    string.format('lines:      %d-%d', tonumber(record.line_start) or 0, tonumber(record.line_end) or 0),
    string.format(
      'commit:     %s',
      (record.commit == nil or record.commit == core.NULL) and '(none)' or tostring(record.commit)
    ),
    string.format(
      'branch:     %s',
      (record.branch == nil or record.branch == core.NULL) and '(none)' or tostring(record.branch)
    ),
    string.format('created_at: %s', tostring(record.created_at or '')),
    '',
    'note:',
    tostring(record.note or ''),
  }
  return table.concat(lines, '\n')
end

local function cmd_show(opts)
  local id = opts[2]
  if not id or id == '' then
    die 'usage: arbiter show <id> [--json]'
  end
  local ctx = setup(opts)
  local records = core.read_jsonl(ctx.jsonl)
  local idx = core.find_by_id(records, id, ctx.branch)
  if not idx then
    die("no note with id " .. id .. " on branch " .. (ctx.branch or '<unknown>'), 5)
  end
  io.write(format_show(records[idx], opts.json))
  io.write '\n'
  return 0
end

local function cmd_set_status(opts)
  local id = opts[2]
  local status = opts[3]
  if not id or not status then
    die 'usage: arbiter set-status <id> <status>'
  end
  if not core.is_status(status) then
    die("invalid status '" .. status .. "' (one of: " .. table.concat(core.STATUSES, ', ') .. ')')
  end
  local ctx = setup(opts)
  local records = core.read_jsonl(ctx.jsonl)
  local idx = core.find_by_id(records, id, ctx.branch)
  if not idx then
    die("no note with id " .. id .. " on branch " .. (ctx.branch or '<unknown>'), 5)
  end
  records[idx].status = status
  local ok_w, err = core.rewrite_jsonl(ctx.jsonl, records)
  if not ok_w then
    die('write failed: ' .. tostring(err), 6)
  end
  io.write(string.format('arbiter: %s → %s\n', id, status))
  return 0
end

local function cmd_resolve(opts)
  local id = opts[2]
  if not id then
    die 'usage: arbiter resolve <id>'
  end
  -- Re-dispatch through set-status so all the same checks run.
  opts[3] = 'resolved'
  return cmd_set_status(opts)
end

-- Count lines in a file. Each '\n' is one line; if the file ends without a
-- trailing newline, the final partial line still counts. Empty file → 0.
local function count_lines(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local n = 0
  local trailing_newline = false
  while true do
    local chunk = f:read(8192)
    if not chunk then
      break
    end
    if #chunk > 0 then
      local _, c = chunk:gsub('\n', '\n')
      n = n + c
      trailing_newline = chunk:sub(-1) == '\n'
    end
  end
  f:close()
  if n > 0 and not trailing_newline then
    n = n + 1
  end
  return n
end

local function cmd_add(opts)
  if opts.commit and opts.commit_null then
    die '--commit and --commit-null are mutually exclusive'
  end

  local file_arg = opts[2]
  local range_arg = opts[3]
  if not file_arg or file_arg == '' or not range_arg or range_arg == '' then
    die 'usage: arbiter add <file> <line-or-range> < note-body'
  end

  -- Parse line range.
  local line_start, line_end
  local single = range_arg:match '^(%d+)$'
  if single then
    line_start = tonumber(single)
    line_end = line_start
  else
    local lo, hi = range_arg:match '^(%d+)%-(%d+)$'
    if not lo then
      die("invalid line range: " .. range_arg)
    end
    line_start = tonumber(lo)
    line_end = tonumber(hi)
    if line_start > line_end then
      die("invalid line range: " .. range_arg)
    end
  end

  -- Read body from stdin. If nothing was piped, io.read returns ''.
  local body = io.read '*a' or ''
  body = body:gsub('\n+$', '')
  if body == '' then
    die 'no note body on stdin — pipe a note or redirect from a file'
  end

  -- Resolve repo (must be inside one).
  local cwd = os.getenv 'PWD'
  local git_dir, repo_root = core.find_git_root(cwd)
  if not git_dir or not repo_root then
    die('not inside a git repo', 3)
  end

  -- Resolve <file> to repo-relative.
  local function is_absolute(p)
    return p:sub(1, 1) == '/'
  end
  local cwd_for_join = cwd and cwd ~= '' and cwd or '.'
  local abs_file
  if is_absolute(file_arg) then
    abs_file = file_arg
  else
    abs_file = cwd_for_join .. '/' .. file_arg
  end
  -- Normalize via realpath so `..`, `.`, and symlinks collapse.
  local rp = io.popen('realpath ' .. string.format('%q', abs_file) .. ' 2>/dev/null')
  local resolved
  if rp then
    resolved = (rp:read '*a' or ''):gsub('%s+$', '')
    rp:close()
  end
  if not resolved or resolved == '' then
    die('no such file: ' .. file_arg)
  end
  -- Existence check (realpath may resolve a non-existent path on some systems).
  local exists = io.open(resolved, 'r')
  if not exists then
    die('no such file: ' .. file_arg)
  end
  exists:close()

  local root_abs
  do
    local rrp = io.popen('realpath ' .. string.format('%q', repo_root) .. ' 2>/dev/null')
    if rrp then
      root_abs = (rrp:read '*a' or ''):gsub('%s+$', '')
      rrp:close()
    end
  end
  if not root_abs or root_abs == '' then
    root_abs = repo_root
  end
  if resolved:sub(1, #root_abs + 1) ~= root_abs .. '/' and resolved ~= root_abs then
    die 'file is outside the repo'
  end
  local rel
  if resolved == root_abs then
    rel = ''
  else
    rel = resolved:sub(#root_abs + 2)
  end
  if rel == '' then
    die 'file is outside the repo'
  end

  -- Line bounds.
  local total = count_lines(resolved)
  if total == nil then
    die('no such file: ' .. file_arg)
  end
  if line_end > total then
    die(string.format('line %d is past end of file (%d lines)', line_end, total))
  end

  -- Resolve commit.
  local commit
  if opts.commit_null then
    commit = nil
  elseif opts.commit then
    commit = opts.commit
  else
    commit = core.head_short_sha(git_dir)
  end

  -- Resolve branch (best-effort; nil/null on failure or detached HEAD edge cases).
  local branch = core.current_branch(git_dir)

  local jsonl = core.resolve_jsonl_path(git_dir)
  if not jsonl then
    die('cannot resolve jsonl path', 3)
  end

  local record, err = core.create_note {
    jsonl_path = jsonl,
    file = rel,
    line_start = line_start,
    line_end = line_end,
    note = body,
    branch = branch,
    commit = commit,
  }
  if not record then
    die('write failed: ' .. tostring(err), 6)
  end

  io.write(core.record_id(record))
  io.write '\n'
  return 0
end

-- =====================================================================
-- Help / dispatch.
-- =====================================================================

local USAGE = [[
arbiter — read and update arbiter review notes from the command line.

USAGE
  arbiter list [filter flags...] [--json]
  arbiter show <id> [--json]
  arbiter set-status <id> <pending|in-progress|needs-rereview|resolved>
  arbiter resolve <id>
  arbiter add <file> <line-or-range> [--commit <sha> | --commit-null]
              < note-body

LIST FILTERS  (combine; AND together)
  --status <list>        comma-separated statuses. default: pending,needs-rereview
  --all-statuses         shorthand for all four
  --branch <name>        override current-branch filter (untagged still match)
  --all-branches         disable branch filter entirely
  --file <substring>     path substring (case-sensitive)
  --file-regex <pat>     path Lua-pattern match
  --line <N>             notes whose [line_start, line_end] include line N
  --line-range <A-B>     notes overlapping [A, B]
  --commit <prefix>      record.commit prefix match (excludes null commits)
  --grep <substring>     case-insensitive substring on note body
  --grep-regex <pat>     Lua-pattern match on note body
  --since <when>         created_at >= when. ISO date/timestamp, or 7d/24h/30m/2w
  --until <when>         created_at <= when. same formats
  --limit <N>            cap output at N records (after sort)
  --json                 emit JSON array (full records + synthetic `id`)

ADD
  arbiter add <file> <line-or-range>
    Read the note body from stdin and append a new pending record.
    <line-or-range>     1-indexed: '42' or '42-47' (inclusive).
    --commit <sha>      override commit. default: short HEAD sha, or null.
    --commit-null       force commit=null even if HEAD resolves.
    Prints the new record's id on success.

NOTES
  Patterns are Lua patterns (%a, %d, %s, %.) — not PCRE. No alternation;
  pipe through `grep` if you need it.

EXIT CODES
  0 ok · 1 usage · 3 not in a git repo · 4 no arbiter.jsonl here
  5 id not found · 6 write failed
]]

local function main(argv)
  if #argv == 0 then
    io.stderr:write(USAGE)
    return 1
  end
  local cmd = argv[1]
  if cmd == '-h' or cmd == '--help' or cmd == 'help' then
    io.write(USAGE)
    return 0
  end

  -- Strip the subcommand from argv before parsing.
  local rest = {}
  for i = 2, #argv do
    rest[i - 1] = argv[i]
  end
  local opts = parse_args(rest)
  -- For show / set-status / resolve, opts[1..n] are positional after the
  -- subcommand. Re-shift so opts[2] is the id (mirroring the `arbiter <cmd> …` shape).
  table.insert(opts, 1, cmd)

  if opts.help then
    io.write(USAGE)
    return 0
  end

  if cmd == 'list' then
    return cmd_list(opts)
  elseif cmd == 'show' then
    return cmd_show(opts)
  elseif cmd == 'set-status' then
    return cmd_set_status(opts)
  elseif cmd == 'resolve' then
    return cmd_resolve(opts)
  elseif cmd == 'add' then
    return cmd_add(opts)
  else
    io.stderr:write("arbiter: unknown subcommand '" .. cmd .. "'\n")
    io.stderr:write(USAGE)
    return 1
  end
end

os.exit(main(arg))
