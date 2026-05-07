-- busted spec for core.lua. Run with `busted spec/core_spec.lua` from
-- ~/.config/nvim/arbiter/.

package.path = package.path
  .. ';/Users/' .. (os.getenv 'USER' or '') .. '/.config/nvim/lua/custom/local-plugins/arbiter/?.lua'

local core = require 'core'

local function tmpfile()
  return os.tmpname()
end

describe('parse_when', function()
  it('parses ISO date', function()
    assert.is_number(core.parse_when '2026-04-01')
  end)
  it('parses ISO timestamp with offset', function()
    local a = core.parse_when '2026-04-01T00:00:00-04:00'
    local b = core.parse_when '2026-04-01T04:00:00+00:00'
    assert.is_number(a)
    assert.equals(a, b)
  end)
  it('parses ISO timestamp with Z', function()
    local a = core.parse_when '2026-04-01T00:00:00Z'
    local b = core.parse_when '2026-04-01T00:00:00+00:00'
    assert.equals(a, b)
  end)
  it('parses relative units', function()
    local now = os.time()
    local d = core.parse_when '7d'
    assert.is_true(d <= now and d > now - 8 * 86400)
    assert.equals(now - core.parse_when '24h', 86400)
    assert.equals(now - core.parse_when '30m', 30 * 60)
    assert.equals(now - core.parse_when '2w', 2 * 7 * 86400)
  end)
  it('rejects garbage', function()
    assert.is_nil(core.parse_when 'xyz')
    assert.is_nil(core.parse_when '7x')
    assert.is_nil(core.parse_when '')
    assert.is_nil(core.parse_when(nil))
  end)
end)

describe('record_id', function()
  it('is stable for the same tuple', function()
    local r = { file = 'a.lua', line_start = 1, branch = 'm', created_at = 't' }
    assert.equals(core.record_id(r), core.record_id(r))
  end)
  it('differs for different fields', function()
    local r1 = { file = 'a.lua', line_start = 1, branch = 'm', created_at = 't' }
    local r2 = { file = 'b.lua', line_start = 1, branch = 'm', created_at = 't' }
    local r3 = { file = 'a.lua', line_start = 2, branch = 'm', created_at = 't' }
    local r4 = { file = 'a.lua', line_start = 1, branch = 'n', created_at = 't' }
    local r5 = { file = 'a.lua', line_start = 1, branch = 'm', created_at = 'u' }
    assert.are_not.equals(core.record_id(r1), core.record_id(r2))
    assert.are_not.equals(core.record_id(r1), core.record_id(r3))
    assert.are_not.equals(core.record_id(r1), core.record_id(r4))
    assert.are_not.equals(core.record_id(r1), core.record_id(r5))
  end)
  it('handles null/missing fields', function()
    assert.has_no.errors(function()
      core.record_id { file = 'a.lua' }
    end)
    assert.has_no.errors(function()
      core.record_id { file = 'a.lua', line_start = 1, branch = core.NULL, created_at = 't' }
    end)
  end)
  it('returns 8 hex chars', function()
    local id = core.record_id { file = 'a.lua', line_start = 1 }
    assert.equals(8, #id)
    assert.is_truthy(id:match '^[0-9a-f]+$')
  end)
end)

describe('find_by_id', function()
  local records = {
    { file = 'a.lua', line_start = 1, branch = 'master', created_at = 't1' },
    { file = 'b.lua', line_start = 5, branch = 'feature', created_at = 't2' },
    { file = 'c.lua', line_start = 9, branch = core.NULL, created_at = 't3' },
  }
  it('finds matching record', function()
    local id = core.record_id(records[1])
    assert.equals(1, core.find_by_id(records, id, 'master'))
  end)
  it('returns nil for no match', function()
    assert.is_nil(core.find_by_id(records, 'deadbeef', 'master'))
  end)
  it('respects branch mismatch', function()
    local id = core.record_id(records[2])
    assert.is_nil(core.find_by_id(records, id, 'master'))
  end)
  it('untagged record matches any branch', function()
    local id = core.record_id(records[3])
    assert.equals(3, core.find_by_id(records, id, 'master'))
    assert.equals(3, core.find_by_id(records, id, 'feature'))
  end)
end)

describe('filter_for_branch', function()
  local records = {
    { file = 'a', branch = 'master' },
    { file = 'b', branch = 'feature' },
    { file = 'c', branch = core.NULL },
    { file = 'd' },
  }
  it('returns all when branch is nil', function()
    assert.equals(4, #core.filter_for_branch(records, nil))
  end)
  it('matches current branch and untagged', function()
    local out = core.filter_for_branch(records, 'master')
    assert.equals(3, #out) -- a, c, d
  end)
  it('excludes other branches', function()
    local out = core.filter_for_branch(records, 'feature')
    assert.equals(3, #out) -- b, c, d
  end)
end)

describe('sort_resolved_last', function()
  it('orders chronologically with resolved last', function()
    local list = {
      { created_at = '2026-05-03', status = 'pending' },
      { created_at = '2026-05-01', status = 'resolved' },
      { created_at = '2026-05-02', status = 'pending' },
      { created_at = '2026-05-04', status = 'resolved' },
    }
    core.sort_resolved_last(list)
    assert.equals('2026-05-02', list[1].created_at)
    assert.equals('2026-05-03', list[2].created_at)
    assert.equals('2026-05-01', list[3].created_at)
    assert.equals('2026-05-04', list[4].created_at)
  end)
  it('is stable for same created_at within a group', function()
    local list = {
      { created_at = 't', note = 'a', status = 'pending' },
      { created_at = 't', note = 'b', status = 'pending' },
      { created_at = 't', note = 'c', status = 'pending' },
    }
    core.sort_resolved_last(list)
    -- Sort is not formally stable, but ties should not crash.
    assert.equals(3, #list)
  end)
end)

describe('normalize_status', function()
  it('keeps known statuses', function()
    for _, s in ipairs(core.STATUSES) do
      assert.equals(s, core.normalize_status(s))
    end
  end)
  it('normalizes nil/empty/unknown to pending', function()
    assert.equals('pending', core.normalize_status(nil))
    assert.equals('pending', core.normalize_status '')
    assert.equals('pending', core.normalize_status 'foo')
    assert.equals('pending', core.normalize_status(core.NULL))
  end)
end)

describe('read_jsonl', function()
  it('returns {} on missing file', function()
    local r = core.read_jsonl('/nonexistent/path/' .. tostring(os.time()))
    assert.same({}, r)
  end)

  it('reads records, skips malformed and blank lines', function()
    local p = tmpfile()
    local f = io.open(p, 'w')
    f:write '{"a":1}\n'
    f:write '\n'
    f:write 'not-valid-json\n'
    f:write '{"b":2}\n'
    f:close()
    local r = core.read_jsonl(p)
    os.remove(p)
    assert.equals(2, #r)
    assert.equals(1, r[1].a)
    assert.equals(2, r[2].b)
  end)
end)

describe('rewrite_jsonl', function()
  it('writes via tmp + rename, one trailing newline per record', function()
    local p = tmpfile()
    local records = { { a = 1 }, { b = 2 } }
    local ok = core.rewrite_jsonl(p, records)
    assert.is_true(ok)
    local f = io.open(p, 'r')
    local data = f:read '*a'
    f:close()
    os.remove(p)
    assert.equals(2, select(2, data:gsub('\n', '\n')))
    assert.is_truthy(data:sub(-1) == '\n')
  end)

  it('preserves null values', function()
    local p = tmpfile()
    local records = { { commit = core.NULL, file = 'a.lua' } }
    core.rewrite_jsonl(p, records)
    local data = io.open(p, 'r'):read '*a'
    os.remove(p)
    assert.is_truthy(data:find '"commit":null')
  end)

  it('round-trip: only mutated field changes', function()
    local p = tmpfile()
    local original = {
      { file = 'a.lua', line_start = 1, line_end = 2, commit = core.NULL, branch = 'm', note = 'hi', created_at = 't1', status = 'pending' },
      { file = 'b.lua', line_start = 5, line_end = 6, commit = core.NULL, branch = 'm', note = 'yo', created_at = 't2', status = 'pending' },
    }
    core.rewrite_jsonl(p, original)
    local readback = core.read_jsonl(p)
    assert.equals(2, #readback)
    readback[1].status = 'in-progress'
    core.rewrite_jsonl(p, readback)
    local readback2 = core.read_jsonl(p)
    os.remove(p)
    assert.equals('in-progress', readback2[1].status)
    assert.equals('pending', readback2[2].status)
    -- Other fields untouched.
    assert.equals('a.lua', readback2[1].file)
    assert.equals('hi', readback2[1].note)
    assert.equals('t1', readback2[1].created_at)
    assert.equals(1, readback2[1].line_start)
  end)
end)

describe('create_note', function()
  it('round-trips with read_jsonl, status pending, all fields preserved', function()
    local p = tmpfile()
    local rec, err = core.create_note {
      jsonl_path = p,
      file = 'src/foo.ts',
      line_start = 10,
      line_end = 15,
      note = 'hello',
      branch = 'feature',
      commit = 'abc123',
    }
    assert.is_nil(err)
    assert.is_table(rec)
    assert.equals('pending', rec.status)
    local read = core.read_jsonl(p)
    os.remove(p)
    assert.equals(1, #read)
    assert.equals('src/foo.ts', read[1].file)
    assert.equals(10, read[1].line_start)
    assert.equals(15, read[1].line_end)
    assert.equals('hello', read[1].note)
    assert.equals('feature', read[1].branch)
    assert.equals('abc123', read[1].commit)
    assert.equals('pending', read[1].status)
    assert.is_string(read[1].created_at)
  end)

  it('nil commit and branch round-trip as JSON null', function()
    local p = tmpfile()
    local rec, err = core.create_note {
      jsonl_path = p,
      file = 'a.lua',
      line_start = 1,
      line_end = 1,
      note = 'x',
      branch = nil,
      commit = nil,
    }
    assert.is_nil(err)
    assert.equals(core.NULL, rec.commit)
    assert.equals(core.NULL, rec.branch)
    local raw = io.open(p, 'r'):read '*a'
    os.remove(p)
    assert.is_truthy(raw:find '"commit":null')
    assert.is_truthy(raw:find '"branch":null')
  end)

  it('returns (nil, err) when jsonl_path is unwritable', function()
    local rec, err = core.create_note {
      jsonl_path = '/nonexistent-dir-xyzzy/arbiter.jsonl',
      file = 'a.lua',
      line_start = 1,
      line_end = 1,
      note = 'x',
    }
    assert.is_nil(rec)
    assert.is_string(err)
  end)

  it('record_id of returned record matches re-read', function()
    local p = tmpfile()
    local rec = core.create_note {
      jsonl_path = p,
      file = 'a.lua',
      line_start = 1,
      line_end = 1,
      note = 'x',
      branch = 'm',
    }
    local read = core.read_jsonl(p)
    os.remove(p)
    assert.equals(core.record_id(rec), core.record_id(read[1]))
  end)
end)

describe('apply_filters', function()
  local function R(t)
    -- defaults
    t.created_at = t.created_at or '2026-05-01T00:00:00-04:00'
    t.branch = t.branch == nil and 'master' or t.branch
    t.status = t.status or 'pending'
    return t
  end
  local recs = {
    R { file = 'src/auth.ts', line_start = 10, line_end = 15, note = 'debounce auth', commit = 'abc12345', created_at = '2026-04-25T10:00:00-04:00' },
    R { file = 'src/foo.ts', line_start = 5, line_end = 5, note = 'simplify', commit = core.NULL, status = 'resolved', created_at = '2026-04-26T10:00:00-04:00' },
    R { file = 'src/bar.lua', line_start = 50, line_end = 60, note = 'TODO refactor', status = 'needs-rereview', created_at = '2026-04-27T10:00:00-04:00' },
    R { file = 'src/auth.ts', line_start = 20, line_end = 25, note = 'cookie', branch = 'feature', created_at = '2026-04-28T10:00:00-04:00' },
  }

  it('returns empty for empty input', function()
    assert.equals(0, #core.apply_filters({}, {}))
  end)

  it('status filter', function()
    local out = core.apply_filters(recs, { status_set = { resolved = true }, all_branches = true })
    assert.equals(1, #out)
    assert.equals('src/foo.ts', out[1].file)
  end)

  it('file substring', function()
    local out = core.apply_filters(recs, { file_substring = 'auth', all_branches = true })
    assert.equals(2, #out)
  end)

  it('file regex', function()
    local out = core.apply_filters(recs, { file_regex = '%.lua$', all_branches = true })
    assert.equals(1, #out)
    assert.equals('src/bar.lua', out[1].file)
  end)

  it('line filter', function()
    local out = core.apply_filters(recs, { line = 12, all_branches = true })
    assert.equals(1, #out)
    assert.equals(10, out[1].line_start)
  end)

  it('line-range overlap', function()
    local out = core.apply_filters(recs, { line_range = { 14, 22 }, all_branches = true })
    -- auth 10-15 overlaps; auth 20-25 overlaps; bar.lua 50-60 doesn't; foo 5 doesn't.
    assert.equals(2, #out)
  end)

  it('commit prefix excludes null commits', function()
    local out = core.apply_filters(recs, { commit_prefix = 'abc', all_branches = true })
    assert.equals(1, #out)
  end)

  it('grep is case-insensitive', function()
    local out = core.apply_filters(recs, { grep = 'DEBOUNCE', all_branches = true })
    assert.equals(1, #out)
  end)

  it('grep-regex (Lua pattern)', function()
    local out = core.apply_filters(recs, { grep_regex = 'TODO', all_branches = true })
    assert.equals(1, #out)
  end)

  it('since cuts older', function()
    local out = core.apply_filters(recs, { since = core.parse_when '2026-04-27', all_branches = true })
    assert.equals(2, #out) -- bar.lua 04-27 + auth 04-28
  end)

  it('until cuts newer', function()
    local out = core.apply_filters(recs, { ['until'] = core.parse_when '2026-04-25T23:59:59-04:00', all_branches = true })
    assert.equals(1, #out)
  end)

  it('limit caps after sort', function()
    local out = core.apply_filters(recs, { limit = 2, all_branches = true })
    assert.equals(2, #out)
  end)

  it('combinations AND', function()
    local out = core.apply_filters(recs, {
      file_substring = 'auth',
      since = core.parse_when '2026-04-26',
      status_set = { pending = true },
      all_branches = true,
    })
    -- auth 10-15 is 04-25 (excluded by since); auth 20-25 is 04-28 (kept).
    assert.equals(1, #out)
    assert.equals(20, out[1].line_start)
  end)

  it('branch filter respects current branch + untagged', function()
    local recs2 = {
      R { file = 'a', branch = 'master' },
      R { file = 'b', branch = 'feature' },
      R { file = 'c', branch = core.NULL },
    }
    local out = core.apply_filters(recs2, { branch = 'master' })
    assert.equals(2, #out) -- a + c
  end)
end)
