-- busted spec for the CLI script. Each test sets up an isolated temp git
-- repo, writes a fixture arbiter.jsonl, invokes the CLI as a subprocess via
-- io.popen, and asserts on stdout / exit code.

local CLI = os.getenv 'HOME' .. '/.config/nvim/arbiter/cli.lua'

package.path = package.path
  .. ';/Users/' .. (os.getenv 'USER' or '') .. '/.config/nvim/lua/custom/local-plugins/arbiter/?.lua'
local core = require 'core'

local function run_in(dir, args)
  -- io.popen doesn't expose exit code reliably across platforms — use a tmp
  -- file for stdout and check the script's own status via a wrapping shell.
  local tmp_out = os.tmpname()
  local tmp_err = os.tmpname()
  local cmd = string.format('cd %q && %s %s >%q 2>%q </dev/null; echo $?', dir, CLI, args, tmp_out, tmp_err)
  local p = io.popen(cmd, 'r')
  local exit_str = p:read '*a'
  p:close()
  local exit = tonumber(((exit_str or ''):gsub('%s+$', ''))) or -1
  local fout = io.open(tmp_out, 'r')
  local out = fout:read '*a'
  fout:close()
  os.remove(tmp_out)
  local ferr = io.open(tmp_err, 'r')
  local err = ferr:read '*a'
  ferr:close()
  os.remove(tmp_err)
  return out, err, exit
end

-- Variant that pipes a body to stdin. Returns (stdout, stderr, exit).
local function run_in_with_stdin(dir, args, stdin_body)
  local tmp_in = os.tmpname()
  local fin = io.open(tmp_in, 'w')
  fin:write(stdin_body or '')
  fin:close()
  local tmp_out = os.tmpname()
  local tmp_err = os.tmpname()
  local cmd = string.format('cd %q && %s %s >%q 2>%q <%q; echo $?',
    dir, CLI, args, tmp_out, tmp_err, tmp_in)
  local p = io.popen(cmd, 'r')
  local exit_str = p:read '*a'
  p:close()
  local exit = tonumber(((exit_str or ''):gsub('%s+$', ''))) or -1
  local fout = io.open(tmp_out, 'r')
  local out = fout:read '*a'
  fout:close()
  local ferr = io.open(tmp_err, 'r')
  local err = ferr:read '*a'
  ferr:close()
  os.remove(tmp_out)
  os.remove(tmp_err)
  os.remove(tmp_in)
  return out, err, exit
end

-- Write a file relative to a repo root, creating parent directories.
local function write_repo_file(repo, rel, content)
  local full = repo .. '/' .. rel
  local parent = full:match '^(.*)/[^/]+$'
  if parent then
    os.execute('mkdir -p ' .. string.format('%q', parent))
  end
  local f = io.open(full, 'w')
  f:write(content)
  f:close()
  return full
end

local function repeat_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = 'line ' .. i
  end
  return table.concat(lines, '\n') .. '\n'
end

local function git(dir, ...)
  local parts = { 'cd', string.format('%q', dir), '&&', 'git' }
  for i = 1, select('#', ...) do
    table.insert(parts, string.format('%q', (select(i, ...))))
  end
  table.insert(parts, '>/dev/null 2>&1')
  os.execute(table.concat(parts, ' '))
end

local function setup_repo(branch)
  local dir = os.tmpname()
  os.remove(dir)
  os.execute('mkdir -p ' .. string.format('%q', dir))
  git(dir, 'init', '-q')
  git(dir, 'config', 'user.email', 'a@b.c')
  git(dir, 'config', 'user.name', 'a')
  git(dir, 'commit', '--allow-empty', '-q', '-m', 'init')
  if branch and branch ~= 'master' and branch ~= 'main' then
    git(dir, 'checkout', '-b', branch)
  end
  return dir
end

local function teardown(dir)
  os.execute('rm -rf ' .. string.format('%q', dir))
end

local function write_jsonl(dir, records)
  -- Resolve git_dir for this repo.
  local p = io.popen(string.format('cd %q && git rev-parse --absolute-git-dir', dir))
  local gd = p:read '*a':gsub('%s+$', '')
  p:close()
  local f = io.open(gd .. '/arbiter.jsonl', 'w')
  for _, r in ipairs(records) do
    f:write(core.cjson.encode(r) .. '\n')
  end
  f:close()
  return gd .. '/arbiter.jsonl'
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return '' end
  local s = f:read '*a'
  f:close()
  return s
end

local function sha256(path)
  local p = io.popen('shasum -a 256 ' .. string.format('%q', path) .. ' 2>/dev/null | awk \'{print $1}\'')
  local s = p:read '*a'
  p:close()
  return (s or ''):gsub('%s+$', '')
end

local function fixture(branch)
  branch = branch or 'feature'
  return {
    {
      file = 'src/auth.ts', line_start = 10, line_end = 15, commit = 'abc12345',
      branch = branch, note = 'debounce auth call', created_at = '2026-04-25T10:00:00-04:00',
      status = 'pending',
    },
    {
      file = 'src/foo.ts', line_start = 5, line_end = 5, commit = core.NULL,
      branch = branch, note = 'simplify', created_at = '2026-04-26T10:00:00-04:00',
      status = 'needs-rereview',
    },
    {
      file = 'src/foo.ts', line_start = 30, line_end = 30, commit = core.NULL,
      branch = branch, note = 'done', created_at = '2026-04-27T10:00:00-04:00',
      status = 'resolved',
    },
  }
end

describe('CLI list', function()
  it('default filters to pending,needs-rereview on current branch', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out, _, exit = run_in(dir, 'list')
    teardown(dir)
    assert.equals(0, exit)
    -- Two visible (pending + needs-rereview); resolved hidden.
    local count = select(2, out:gsub('\n', '\n'))
    assert.equals(2, count)
    assert.is_truthy(out:find 'src/auth.ts')
    assert.is_truthy(out:find 'src/foo.ts')
  end)

  it('--all-statuses includes resolved', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out, _, exit = run_in(dir, 'list --all-statuses')
    teardown(dir)
    assert.equals(0, exit)
    assert.equals(3, select(2, out:gsub('\n', '\n')))
  end)

  it('--json emits a JSON array with id field', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out, _, exit = run_in(dir, 'list --json')
    teardown(dir)
    assert.equals(0, exit)
    local arr = core.cjson.decode(out)
    assert.equals(2, #arr)
    for _, r in ipairs(arr) do
      assert.is_string(r.id)
      assert.equals(8, #r.id)
      assert.is_string(r.file)
      assert.is_number(r.line_start)
      assert.is_string(r.note)
    end
  end)

  it('--status filter', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --status pending')
    teardown(dir)
    assert.equals(1, select(2, out:gsub('\n', '\n')))
    assert.is_truthy(out:find 'auth.ts')
  end)

  it('--file substring', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --file foo')
    teardown(dir)
    assert.equals(2, select(2, out:gsub('\n', '\n')))
  end)

  it('--file-regex Lua pattern', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, [[list --all-statuses --file-regex '%.ts$']])
    teardown(dir)
    assert.equals(3, select(2, out:gsub('\n', '\n')))
  end)

  it('--line filter', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --line 12')
    teardown(dir)
    assert.equals(1, select(2, out:gsub('\n', '\n')))
    assert.is_truthy(out:find 'auth')
  end)

  it('--line-range filter', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --line-range 1-10')
    teardown(dir)
    -- 5-5 and 10-15 overlap; 30-30 doesn't.
    assert.equals(2, select(2, out:gsub('\n', '\n')))
  end)

  it('--commit prefix', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --commit abc')
    teardown(dir)
    assert.equals(1, select(2, out:gsub('\n', '\n')))
  end)

  it('--grep case-insensitive', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --grep DEBOUNCE')
    teardown(dir)
    assert.equals(1, select(2, out:gsub('\n', '\n')))
  end)

  it('--limit caps output', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --limit 2')
    teardown(dir)
    assert.equals(2, select(2, out:gsub('\n', '\n')))
  end)

  it('combined filters AND', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local out = run_in(dir, 'list --all-statuses --file foo --status resolved')
    teardown(dir)
    assert.equals(1, select(2, out:gsub('\n', '\n')))
    assert.is_truthy(out:find 'done')
  end)

  it('--all-branches shows other branches', function()
    local dir = setup_repo 'feature'
    local recs = fixture 'feature'
    table.insert(recs, {
      file = 'other.ts', line_start = 1, line_end = 1, commit = core.NULL,
      branch = 'master', note = 'on master', created_at = '2026-04-30T10:00:00-04:00',
      status = 'pending',
    })
    write_jsonl(dir, recs)
    local without = run_in(dir, 'list')
    local with = run_in(dir, 'list --all-branches')
    teardown(dir)
    assert.is_falsy(without:find 'other.ts')
    assert.is_truthy(with:find 'other.ts')
  end)

  it('--branch override', function()
    local dir = setup_repo 'feature'
    local recs = fixture 'feature'
    table.insert(recs, {
      file = 'master-only.ts', line_start = 1, line_end = 1, commit = core.NULL,
      branch = 'master', note = 'master',
      created_at = '2026-04-30T10:00:00-04:00', status = 'pending',
    })
    write_jsonl(dir, recs)
    local out = run_in(dir, 'list --branch master')
    teardown(dir)
    assert.is_truthy(out:find('master-only.ts', 1, true))
  end)
end)

describe('CLI show', function()
  it('prints all fields for valid id', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local list_json = run_in(dir, 'list --json')
    local id = core.cjson.decode(list_json)[1].id
    local out, _, exit = run_in(dir, 'show ' .. id)
    teardown(dir)
    assert.equals(0, exit)
    assert.is_truthy(out:find 'id:')
    assert.is_truthy(out:find 'status:')
    assert.is_truthy(out:find 'note:')
  end)

  it('exits non-zero on bad id', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local _, err, exit = run_in(dir, 'show deadbeef')
    teardown(dir)
    assert.equals(5, exit)
    assert.is_truthy(err:find 'no note with id deadbeef')
  end)
end)

describe('CLI set-status', function()
  it('mutates only the target record', function()
    local dir = setup_repo 'feature'
    local jsonl = write_jsonl(dir, fixture 'feature')
    local list_json = run_in(dir, 'list --json')
    local id = core.cjson.decode(list_json)[1].id
    -- Snapshot byte content of records before / after for the records we don't touch.
    local _, _, exit = run_in(dir, 'set-status ' .. id .. ' in-progress')
    assert.equals(0, exit)
    local after_records = core.read_jsonl(jsonl)
    local target_idx
    for i, r in ipairs(after_records) do
      if core.record_id(r) == id then target_idx = i end
    end
    assert.is_number(target_idx)
    assert.equals('in-progress', after_records[target_idx].status)
    -- Other records keep their statuses.
    local statuses = {}
    for i, r in ipairs(after_records) do
      if i ~= target_idx then table.insert(statuses, r.status) end
    end
    teardown(dir)
    table.sort(statuses)
    assert.same({ 'needs-rereview', 'resolved' }, statuses)
  end)

  it('allows resolved (no skill-level prohibition at CLI layer)', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local list_json = run_in(dir, 'list --json')
    local id = core.cjson.decode(list_json)[1].id
    local _, _, exit = run_in(dir, 'set-status ' .. id .. ' resolved')
    teardown(dir)
    assert.equals(0, exit)
  end)

  it('exits non-zero on bad id', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local _, _, exit = run_in(dir, 'set-status deadbeef in-progress')
    teardown(dir)
    assert.equals(5, exit)
  end)

  it('exits non-zero on invalid status', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local list_json = run_in(dir, 'list --json')
    local id = core.cjson.decode(list_json)[1].id
    local _, err, exit = run_in(dir, 'set-status ' .. id .. ' garbage')
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'pending')
    assert.is_truthy(err:find 'resolved')
  end)
end)

describe('CLI resolve', function()
  it('equivalent to set-status <id> resolved', function()
    local dir = setup_repo 'feature'
    local jsonl = write_jsonl(dir, fixture 'feature')
    local list_json = run_in(dir, 'list --json')
    local id = core.cjson.decode(list_json)[1].id
    local _, _, exit = run_in(dir, 'resolve ' .. id)
    assert.equals(0, exit)
    local recs = core.read_jsonl(jsonl)
    teardown(dir)
    for _, r in ipairs(recs) do
      if core.record_id(r) == id then
        assert.equals('resolved', r.status)
      end
    end
  end)
end)

describe('CLI errors', function()
  it('outside a git repo', function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('mkdir -p ' .. string.format('%q', dir))
    local _, err, exit = run_in(dir, 'list')
    teardown(dir)
    assert.equals(3, exit)
    assert.is_truthy(err:find 'not inside a git repo')
  end)

  it('jsonl missing', function()
    local dir = setup_repo 'feature'
    local _, err, exit = run_in(dir, 'list')
    teardown(dir)
    assert.equals(4, exit)
    assert.is_truthy(err:find 'arbiter not in use here')
  end)

  it('bad --since value', function()
    local dir = setup_repo 'feature'
    write_jsonl(dir, fixture 'feature')
    local _, err, exit = run_in(dir, 'list --since xyz')
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'invalid %-%-since')
  end)
end)

describe('CLI add', function()
  it('happy path: writes pending record, prints id, exit 0', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local out, _, exit = run_in_with_stdin(dir, 'add src/foo.ts 42-47', 'needs debounce')
    assert.equals(0, exit)
    local id = out:gsub('%s+$', '')
    assert.equals(8, #id)
    assert.is_truthy(id:match '^[0-9a-f]+$')
    -- Read back via list --json.
    local list_out = run_in(dir, 'list --json')
    local arr = core.cjson.decode(list_out)
    teardown(dir)
    assert.equals(1, #arr)
    assert.equals('src/foo.ts', arr[1].file)
    assert.equals(42, arr[1].line_start)
    assert.equals(47, arr[1].line_end)
    assert.equals('needs debounce', arr[1].note)
    assert.equals('pending', arr[1].status)
    assert.equals('feature', arr[1].branch)
    assert.is_string(arr[1].commit)
    assert.equals(id, arr[1].id)
  end)

  it('single-line range works', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local out, _, exit = run_in_with_stdin(dir, 'add src/foo.ts 5', 'tiny')
    assert.equals(0, exit)
    local id = out:gsub('%s+$', '')
    assert.equals(8, #id)
    teardown(dir)
  end)

  it('absolute path normalizes to repo-relative', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    -- Resolve dir to a real path (macOS /var → /private/var).
    local p = io.popen('realpath ' .. string.format('%q', dir))
    local real_dir = p:read '*a':gsub('%s+$', '')
    p:close()
    local _, _, exit = run_in_with_stdin(dir, 'add ' .. real_dir .. '/src/foo.ts 1', 'abs')
    assert.equals(0, exit)
    local list_out = run_in(dir, 'list --json')
    local arr = core.cjson.decode(list_out)
    teardown(dir)
    assert.equals('src/foo.ts', arr[1].file)
  end)

  it('--commit override stores literal value', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local _, _, exit = run_in_with_stdin(dir, 'add src/foo.ts 1 --commit deadbeef', 'x')
    assert.equals(0, exit)
    local list_out = run_in(dir, 'list --json')
    local arr = core.cjson.decode(list_out)
    teardown(dir)
    assert.equals('deadbeef', arr[1].commit)
  end)

  it('--commit-null forces null commit', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local _, _, exit = run_in_with_stdin(dir, 'add src/foo.ts 1 --commit-null', 'x')
    assert.equals(0, exit)
    -- Read raw JSONL to confirm null serialization.
    local pp = io.popen(string.format('cd %q && git rev-parse --absolute-git-dir', dir))
    local gd = pp:read '*a':gsub('%s+$', '')
    pp:close()
    local raw = io.open(gd .. '/arbiter.jsonl', 'r'):read '*a'
    teardown(dir)
    assert.is_truthy(raw:find '"commit":null')
  end)

  it('--commit and --commit-null together → exit 1', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local _, err, exit = run_in_with_stdin(dir, 'add src/foo.ts 1 --commit abc --commit-null', 'x')
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'mutually exclusive')
  end)

  it('no stdin body → exit 1', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    -- run_in pipes /dev/null; that produces an empty stdin (TTY-equivalent for our purposes).
    local _, err, exit = run_in(dir, 'add src/foo.ts 1')
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'no note body on stdin')
  end)

  it('file does not exist → exit 1', function()
    local dir = setup_repo 'feature'
    local _, err, exit = run_in_with_stdin(dir, 'add does/not/exist.ts 1', 'x')
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'no such file')
  end)

  it('file outside repo → exit 1', function()
    local dir = setup_repo 'feature'
    -- /tmp exists but is outside the repo.
    local outside = os.tmpname()
    local f = io.open(outside, 'w')
    f:write 'hello\n'
    f:close()
    local _, err, exit = run_in_with_stdin(dir, 'add ' .. outside .. ' 1', 'x')
    os.remove(outside)
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'outside the repo')
  end)

  it('bad range format → exit 1', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    for _, bad in ipairs { 'abc', '42-', '5-3' } do
      local _, err, exit = run_in_with_stdin(dir, 'add src/foo.ts ' .. bad, 'x')
      assert.equals(1, exit, 'expected exit 1 for range ' .. bad)
      assert.is_truthy(err:find 'invalid line range', 'expected error msg for range ' .. bad)
    end
    teardown(dir)
  end)

  it('range past EOF → exit 1', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local _, err, exit = run_in_with_stdin(dir, 'add src/foo.ts 1000', 'x')
    teardown(dir)
    assert.equals(1, exit)
    assert.is_truthy(err:find 'past end of file')
  end)

  it('outside a git repo → exit 3', function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('mkdir -p ' .. string.format('%q', dir))
    write_repo_file(dir, 'foo.ts', repeat_lines(10))
    local _, err, exit = run_in_with_stdin(dir, 'add foo.ts 1', 'x')
    teardown(dir)
    assert.equals(3, exit)
    assert.is_truthy(err:find 'not inside a git repo')
  end)

  it('creates jsonl on first add (no exit 4)', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    -- jsonl absent at this point. add should succeed.
    local _, _, exit = run_in_with_stdin(dir, 'add src/foo.ts 1', 'first')
    assert.equals(0, exit)
    -- Now list works (no exit 4).
    local _, _, list_exit = run_in(dir, 'list')
    teardown(dir)
    assert.equals(0, list_exit)
  end)

  it('relative path from subdirectory normalizes correctly', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local _, _, exit = run_in_with_stdin(dir .. '/src', 'add foo.ts 1', 'sub')
    assert.equals(0, exit)
    local list_out = run_in(dir, 'list --json')
    local arr = core.cjson.decode(list_out)
    teardown(dir)
    assert.equals('src/foo.ts', arr[1].file)
  end)

  it('round-trip: id from add can be passed to set-status', function()
    local dir = setup_repo 'feature'
    write_repo_file(dir, 'src/foo.ts', repeat_lines(50))
    local out = run_in_with_stdin(dir, 'add src/foo.ts 1', 'x')
    local id = out:gsub('%s+$', '')
    local _, _, exit = run_in(dir, 'set-status ' .. id .. ' needs-rereview')
    assert.equals(0, exit)
    local list_out = run_in(dir, 'list --json')
    local arr = core.cjson.decode(list_out)
    teardown(dir)
    assert.equals('needs-rereview', arr[1].status)
  end)
end)

describe('cross-branch isolation', function()
  it("mutating on branch A leaves branch-B records' decoded value identical", function()
    local dir = setup_repo 'feature'
    -- Mix of feature + master records.
    local recs = fixture 'feature'
    for _, r in ipairs(fixture 'master') do
      table.insert(recs, r)
    end
    local jsonl = write_jsonl(dir, recs)
    -- Capture decoded master records before mutation.
    local function master_records()
      local list = {}
      for line in io.lines(jsonl) do
        local decoded = core.cjson.decode(line)
        if decoded.branch == 'master' then
          table.insert(list, decoded)
        end
      end
      table.sort(list, function(a, b)
        return tostring(a.created_at) < tostring(b.created_at)
      end)
      return list
    end
    local before = master_records()

    local list_json = run_in(dir, 'list --json')
    local id = core.cjson.decode(list_json)[1].id
    local _, _, exit = run_in(dir, 'set-status ' .. id .. ' in-progress')
    assert.equals(0, exit)

    local after = master_records()
    teardown(dir)

    assert.equals(#before, #after)
    for i, b in ipairs(before) do
      local a = after[i]
      assert.equals(b.file, a.file)
      assert.equals(b.line_start, a.line_start)
      assert.equals(b.line_end, a.line_end)
      assert.equals(b.note, a.note)
      assert.equals(b.created_at, a.created_at)
      assert.equals(b.status, a.status)
      assert.equals(b.branch, a.branch)
    end
  end)
end)
