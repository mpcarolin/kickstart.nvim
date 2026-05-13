-- arbiter.core: pure-Lua primitives shared between the nvim plugin and the
-- standalone CLI. No `vim.*` calls, no nvim-specific deps. Uses cjson for
-- JSON encoding so both surfaces produce/consume byte-compatible JSONL.

local M = {}

-- Extend package.cpath so we can find cjson installed under ~/.luarocks for
-- LuaJIT 5.1 (nvim's interpreter). Harmless for standalone Lua 5.4 since the
-- 5.4 cjson is on the default cpath.
local function extend_cpath()
  local home = os.getenv 'HOME' or ''
  if home == '' then
    return
  end
  local extras = {
    home .. '/.luarocks/lib/lua/5.1/?.so',
    home .. '/.luarocks/lib/lua/5.4/?.so',
  }
  for _, p in ipairs(extras) do
    if not package.cpath:find(p, 1, true) then
      package.cpath = package.cpath .. ';' .. p
    end
  end
end
extend_cpath()

local cjson = require 'cjson'
-- Match nvim's vim.json output (which doesn't escape forward slashes), so the
-- plugin and CLI produce byte-compatible JSONL.
if cjson.encode_escape_forward_slash then
  cjson.encode_escape_forward_slash(false)
end
M.cjson = cjson
M.NULL = cjson.null

-- =====================================================================
-- Path / branch resolution (shells out to git; no vim.fn).
-- =====================================================================

-- Run a command, return trimmed stdout or nil if exit != 0.
local function sh(cmd)
  local p = io.popen(cmd .. ' 2>/dev/null', 'r')
  if not p then
    return nil
  end
  local out = p:read '*a' or ''
  local ok = p:close()
  if not ok then
    return nil
  end
  return (out:gsub('%s+$', ''))
end

-- Resolve absolute git_dir + repo_root from cwd. Returns (git_dir, repo_root)
-- or nil. `--absolute-git-dir` handles worktrees and submodule .git files.
function M.find_git_root(cwd)
  local git_dir, repo_root
  if cwd and cwd ~= '' then
    git_dir = sh(string.format('cd %q && git rev-parse --absolute-git-dir', cwd))
    repo_root = sh(string.format('cd %q && git rev-parse --show-toplevel', cwd))
  else
    git_dir = sh 'git rev-parse --absolute-git-dir'
    repo_root = sh 'git rev-parse --show-toplevel'
  end
  if not git_dir or git_dir == '' or not repo_root or repo_root == '' then
    return nil, nil
  end
  return git_dir, repo_root
end

function M.resolve_jsonl_path(git_dir)
  if not git_dir or git_dir == '' then
    return nil
  end
  return git_dir .. '/arbiter.jsonl'
end

function M.current_branch(git_dir)
  if not git_dir or git_dir == '' then
    return nil
  end
  local g = string.format('git --git-dir=%q ', git_dir)

  local name = sh(g .. 'rev-parse --abbrev-ref HEAD')
  if not name or name == '' then
    return nil
  end
  if name ~= 'HEAD' then
    return name
  end

  local out = sh(g .. "for-each-ref refs/heads/ --contains HEAD --format='%(refname:short)'")
  local candidates = {}
  if out and out ~= '' then
    for line in out:gmatch('[^\n]+') do
      local b = line:gsub('^%s+', ''):gsub('%s+$', '')
      if b ~= '' then
        table.insert(candidates, b)
      end
    end
  end

  if #candidates == 0 then
    local sha = sh(g .. 'rev-parse --short=12 HEAD')
    if not sha or sha == '' then
      return nil
    end
    return sha
  end

  local prev_full = sh(g .. "rev-parse --symbolic-full-name '@{-1}'")
  if prev_full and prev_full:match('^refs/heads/') then
    local prev = prev_full:gsub('^refs/heads/', '')
    for _, c in ipairs(candidates) do
      if c == prev then
        return c
      end
    end
  end

  if #candidates == 1 then
    return candidates[1]
  end

  table.sort(candidates)
  for _, c in ipairs(candidates) do
    if c ~= 'main' and c ~= 'master' then
      return c
    end
  end
  return candidates[1]
end

-- Resolve the short HEAD SHA, mirroring `current_branch`. Returns the trimmed
-- 12-char SHA on success or nil on non-zero exit / empty output (e.g. brand-new
-- repo with no commits, broken HEAD).
function M.head_short_sha(git_dir)
  local cmd
  if git_dir and git_dir ~= '' then
    cmd = string.format('git --git-dir=%q rev-parse --short=12 HEAD', git_dir)
  else
    cmd = 'git rev-parse --short=12 HEAD'
  end
  local sha = sh(cmd)
  if not sha or sha == '' then
    return nil
  end
  return sha
end

-- =====================================================================
-- Model: statuses, normalization, hash-based id, find-by-id.
-- =====================================================================

M.STATUSES = { 'pending', 'in-progress', 'needs-rereview', 'resolved' }

local STATUS_SET = {}
for _, s in ipairs(M.STATUSES) do
  STATUS_SET[s] = true
end

function M.is_status(s)
  return STATUS_SET[s] == true
end

-- A record is file-level if its scope is "file" or its line numbers are
-- absent / non-numeric (legacy records that pre-date scope round-trip with
-- numeric line numbers, so the scope check is the dominant signal).
function M.is_file_level(record)
  if type(record) ~= 'table' then
    return false
  end
  if record.scope == 'file' then
    return true
  end
  return type(record.line_start) ~= 'number'
end

function M.normalize_status(s)
  if s == nil or s == M.NULL or s == '' then
    return 'pending'
  end
  if STATUS_SET[s] then
    return s
  end
  return 'pending'
end

-- Read-side default: a missing/null/non-table `comments` field reads as no
-- replies. Lazy-init on first append (see `append_reply`) keeps the on-disk
-- representation free of empty arrays — cjson encodes `{}` as a JSON object.
function M.normalize_comments(record)
  local c = record and record.comments
  if c == nil or c == M.NULL or type(c) ~= 'table' then
    return {}
  end
  return c
end

-- Read-side default: missing/null/empty author reads as `"human"` (matches
-- the historical contract — old records have no author and were all written
-- by the human-side plugin).
function M.normalize_author(entry)
  local a = entry and entry.author
  if a == nil or a == M.NULL then
    return 'human'
  end
  local s = tostring(a)
  if s == '' then
    return 'human'
  end
  return s
end

-- =====================================================================
-- SHA-1 in pure Lua (used for the 8-char record id). Compact, no deps.
-- Adapted from public-domain references; produces the same hex digest as
-- `sha1sum`. We only use the first 8 hex chars.
-- =====================================================================

local function band(a, b)
  local r, m = 0, 1
  for _ = 0, 31 do
    if (a % 2 == 1) and (b % 2 == 1) then
      r = r + m
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    m = m * 2
  end
  return r
end

local function bor(a, b)
  local r, m = 0, 1
  for _ = 0, 31 do
    if (a % 2 == 1) or (b % 2 == 1) then
      r = r + m
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    m = m * 2
  end
  return r
end

local function bxor(a, b)
  local r, m = 0, 1
  for _ = 0, 31 do
    local ab, bb = a % 2, b % 2
    if ab ~= bb then
      r = r + m
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    m = m * 2
  end
  return r
end

local function bnot32(a)
  return 0xFFFFFFFF - a
end

local function lrot(a, n)
  a = a % 0x100000000
  return ((a * (2 ^ n)) % 0x100000000) + math.floor(a / (2 ^ (32 - n)))
end

local function add32(...)
  local s = 0
  for i = 1, select('#', ...) do
    s = s + select(i, ...)
  end
  return s % 0x100000000
end

local function sha1(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local len = #msg
  msg = msg .. '\128'
  while (#msg % 64) ~= 56 do
    msg = msg .. '\0'
  end
  -- 64-bit big-endian length in bits
  local bitlen = len * 8
  local hi = math.floor(bitlen / 0x100000000)
  local lo = bitlen % 0x100000000
  local function be32(n)
    return string.char(math.floor(n / 0x1000000) % 256, math.floor(n / 0x10000) % 256, math.floor(n / 0x100) % 256, n % 256)
  end
  msg = msg .. be32(hi) .. be32(lo)

  for chunk_start = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local p = chunk_start + i * 4
      w[i] = msg:byte(p) * 0x1000000 + msg:byte(p + 1) * 0x10000 + msg:byte(p + 2) * 0x100 + msg:byte(p + 3)
    end
    for i = 16, 79 do
      w[i] = lrot(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bnot32(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bxor(bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(bxor(b, c), d)
        k = 0xCA62C1D6
      end
      local temp = add32(lrot(a, 5), f, e, k, w[i])
      e = d
      d = c
      c = lrot(b, 30)
      b = a
      a = temp
    end

    h0 = add32(h0, a)
    h1 = add32(h1, b)
    h2 = add32(h2, c)
    h3 = add32(h3, d)
    h4 = add32(h4, e)
  end

  return string.format('%08x%08x%08x%08x%08x', h0, h1, h2, h3, h4)
end

M._sha1 = sha1 -- exposed for tests

-- 8-char hex id from (file, line_start, branch, created_at). Stable across
-- calls. `null`/missing fields collapse to empty strings — the tuple is
-- still well-defined for that record.
function M.record_id(record)
  local function s(v)
    if v == nil or v == M.NULL then
      return ''
    end
    -- Lua 5.4 cjson decodes JSON numbers as floats ("1.0"); Lua 5.1 / LuaJIT
    -- leave them as integers ("1"). Coerce numeric fields to their integer
    -- form so the id is stable across runtimes.
    if type(v) == 'number' then
      if v == math.floor(v) then
        return string.format('%d', v)
      end
      return tostring(v)
    end
    return tostring(v)
  end
  local key = table.concat({
    s(record.file),
    s(record.line_start),
    s(record.branch),
    s(record.created_at),
  }, '|')
  return sha1(key):sub(1, 8)
end

-- Locate a record matching `id`. If `branch` is given, the record's branch
-- must match (or be untagged). Returns the index into `records` or nil.
function M.find_by_id(records, id, branch)
  for i, r in ipairs(records) do
    if M.record_id(r) == id then
      if not branch then
        return i
      end
      if r.branch == nil or r.branch == M.NULL or r.branch == branch then
        return i
      end
    end
  end
  return nil
end

-- =====================================================================
-- IO: read / append / atomic rewrite.
-- =====================================================================

function M.read_jsonl(path)
  local f = io.open(path, 'r')
  if not f then
    return {}
  end
  local records = {}
  for line in f:lines() do
    if line ~= '' then
      local ok, decoded = pcall(cjson.decode, line)
      if ok and type(decoded) == 'table' then
        table.insert(records, decoded)
      end
    end
  end
  f:close()
  return records
end

function M.append_jsonl(path, record)
  local ok_e, encoded = pcall(cjson.encode, record)
  if not ok_e then
    return false, 'encode failed: ' .. tostring(encoded)
  end
  local f, err = io.open(path, 'a')
  if not f then
    return false, err
  end
  f:write(encoded .. '\n')
  f:close()
  return true
end

-- Build a pending record from already-validated inputs and append it to the
-- JSONL. nil/absent commit/branch collapse to JSON null. Returns the record on
-- success so the caller can run record_id() on it.
--
-- Two shapes:
--   range note: opts.line_start and opts.line_end are positive ints,
--               line_start <= line_end. opts.anchor (optional) captures a
--               normalized snapshot of the lines + 3 surrounding lines so
--               drift can be re-resolved on read (see `resolve_anchor`).
--   file note:  both opts.line_start and opts.line_end are nil. Record is
--               written with `scope = "file"` and JSON-null line numbers.
function M.create_note(opts)
  local has_start = opts.line_start ~= nil
  local has_end = opts.line_end ~= nil
  if has_start ~= has_end then
    return nil, 'line_start and line_end must both be set or both be nil'
  end
  local scope
  if not has_start then
    scope = 'file'
  else
    if type(opts.line_start) ~= 'number' or type(opts.line_end) ~= 'number' then
      return nil, 'line_start and line_end must be numbers'
    end
    if opts.line_start < 1 or opts.line_end < 1 then
      return nil, 'line numbers must be positive'
    end
    if opts.line_start > opts.line_end then
      return nil, 'line_start must be <= line_end'
    end
    scope = 'range'
  end
  local record = {
    file = opts.file,
    line_start = has_start and opts.line_start or M.NULL,
    line_end = has_end and opts.line_end or M.NULL,
    commit = opts.commit == nil and M.NULL or opts.commit,
    branch = opts.branch == nil and M.NULL or opts.branch,
    note = opts.note,
    created_at = M.iso8601_now(),
    status = 'pending',
    author = opts.author or 'human',
    scope = scope,
  }
  if scope == 'range' and opts.anchor ~= nil then
    record.anchor = opts.anchor
  end
  local ok, err = M.append_jsonl(opts.jsonl_path, record)
  if not ok then
    return nil, err
  end
  return record, nil
end

-- =====================================================================
-- Anchor capture & drift resolution.
--
-- An anchor is a content snapshot taken at note creation time:
--   { lines = {...}, ctx_before = {...}, ctx_after = {...}, blob = "<sha>"? }
-- It lets us re-locate a note when surrounding edits shift line numbers,
-- without ever rewriting the JSONL on disk in Phase A.
-- =====================================================================

-- Normalize a line for anchor comparison: strip CR, strip leading and
-- trailing whitespace, collapse runs of internal whitespace to a single space.
-- This tolerates trivial reformatting (re-indentation, trailing spaces)
-- without enabling false matches across genuinely different code.
function M.normalize_anchor_line(s)
  if type(s) ~= 'string' then
    return ''
  end
  s = s:gsub('\r', '')
  s = s:gsub('^%s+', '')
  s = s:gsub('%s+$', '')
  s = s:gsub('%s+', ' ')
  return s
end

-- Normalize a list of buffer lines once, suitable for passing to multiple
-- `resolve_anchor` calls against the same buffer.
function M.normalize_buf_lines(buf_lines)
  if type(buf_lines) ~= 'table' then
    return {}
  end
  local out = {}
  for i = 1, #buf_lines do
    out[i] = M.normalize_anchor_line(buf_lines[i])
  end
  return out
end

local function normalize_list(list)
  local out = {}
  if type(list) ~= 'table' then
    return out
  end
  for i, l in ipairs(list) do
    out[i] = M.normalize_anchor_line(l)
  end
  return out
end

-- Build an anchor table from `buf_lines` (1-indexed array of strings) given
-- the range [line_start..line_end]. Up to 3 lines of context above/below.
-- Returns a table suitable for passing as `opts.anchor` to `create_note`.
function M.build_anchor(buf_lines, line_start, line_end, blob)
  local anchor = { lines = {}, ctx_before = {}, ctx_after = {} }
  if type(buf_lines) ~= 'table' then
    return anchor
  end
  for i = line_start, line_end do
    table.insert(anchor.lines, M.normalize_anchor_line(buf_lines[i] or ''))
  end
  for i = math.max(1, line_start - 3), line_start - 1 do
    table.insert(anchor.ctx_before, M.normalize_anchor_line(buf_lines[i] or ''))
  end
  for i = line_end + 1, math.min(#buf_lines, line_end + 3) do
    table.insert(anchor.ctx_after, M.normalize_anchor_line(buf_lines[i] or ''))
  end
  if blob and blob ~= '' then
    anchor.blob = blob
  end
  return anchor
end

-- Resolve an anchor against the current buffer contents. Pure: never mutates
-- `record`. Returns a result table:
--   { line_start = N|nil, line_end = N|nil, drift = "none"|"shifted"|"lost"|"file" }
--
-- - "none":    record has no anchor (legacy) or buffer matches exactly.
-- - "shifted": high-confidence match found at a different position. Use the
--              returned line numbers for this read — caller does NOT rewrite
--              the JSONL in Phase A.
-- - "lost":    no acceptable match. Returned line numbers fall back to the
--              record's stored values; UI should flag the note as drifted.
-- - "file":    file-level note (no line numbers).
--
-- `buf_lines` is a 1-indexed array of strings. `current_blob` is the optional
-- short SHA of the file's blob in the current HEAD; if both it and the
-- anchor's stored blob match, we short-circuit with drift = "none".
--
-- For batched calls against the same buffer (e.g. resolving every record on
-- BufReadPost), pass `buf_norm` — the buffer's already-normalized lines — to
-- avoid re-running the gsub pipeline once per record. When omitted, we
-- normalize in-place.
function M.resolve_anchor(record, buf_lines, current_blob, buf_norm)
  if type(record) ~= 'table' then
    return { line_start = nil, line_end = nil, drift = 'none' }
  end
  if record.scope == 'file' then
    return { line_start = nil, line_end = nil, drift = 'file' }
  end
  local stored_start = record.line_start
  local stored_end = record.line_end
  if type(stored_start) ~= 'number' or type(stored_end) ~= 'number' then
    return { line_start = stored_start, line_end = stored_end, drift = 'none' }
  end
  local anchor = record.anchor
  if type(anchor) ~= 'table' or type(anchor.lines) ~= 'table' or #anchor.lines == 0 then
    return { line_start = stored_start, line_end = stored_end, drift = 'none' }
  end
  if type(buf_lines) ~= 'table' or #buf_lines == 0 then
    return { line_start = stored_start, line_end = stored_end, drift = 'lost' }
  end

  if anchor.blob and current_blob and anchor.blob ~= '' and anchor.blob == current_blob then
    return { line_start = stored_start, line_end = stored_end, drift = 'none' }
  end

  local anchor_lines = normalize_list(anchor.lines)
  local ctx_before = normalize_list(anchor.ctx_before or {})
  local ctx_after = normalize_list(anchor.ctx_after or {})
  local nlen = #anchor_lines
  local nbefore = #ctx_before
  local nafter = #ctx_after

  -- Pre-normalize the entire buffer once. The windowed search below is
  -- O(window * (nlen + ctx)) reads against this array — without this, every
  -- candidate position re-runs the gsubs on overlapping lines.
  local nbuf = #buf_lines
  if buf_norm == nil then
    buf_norm = {}
    for i = 1, nbuf do
      buf_norm[i] = M.normalize_anchor_line(buf_lines[i])
    end
  end

  -- exact_at(c): count of body lines matching buf_norm at start c.
  local function body_matches_at(c)
    local m = 0
    for k = 1, nlen do
      if buf_norm[c + k - 1] == anchor_lines[k] then
        m = m + 1
      end
    end
    return m
  end

  if stored_start >= 1 and stored_end <= nbuf and (stored_end - stored_start + 1) == nlen then
    if body_matches_at(stored_start) == nlen then
      return { line_start = stored_start, line_end = stored_end, drift = 'none' }
    end
  end

  local window = math.max(50, 2 * nlen)
  local lo = math.max(1, stored_start - window)
  local hi = math.min(nbuf - nlen + 1, stored_start + window)
  if hi < 1 then
    return { line_start = stored_start, line_end = stored_end, drift = 'lost' }
  end

  local best_score = -1
  local best_body = -1
  local best_start
  local best_dist = math.huge
  for c = lo, hi do
    local body_score = body_matches_at(c)
    local before_score = 0
    for k = 1, nbefore do
      local idx = c - nbefore + k - 1
      if idx >= 1 and buf_norm[idx] == ctx_before[k] then
        before_score = before_score + 1
      end
    end
    local after_score = 0
    for k = 1, nafter do
      local idx = c + nlen + k - 1
      if idx <= nbuf and buf_norm[idx] == ctx_after[k] then
        after_score = after_score + 1
      end
    end
    local score = body_score + 0.5 * before_score + 0.5 * after_score
    local dist = math.abs(c - stored_start)
    if score > best_score or (score == best_score and dist < best_dist) then
      best_score = score
      best_body = body_score
      best_start = c
      best_dist = dist
    end
  end

  if not best_start then
    return { line_start = stored_start, line_end = stored_end, drift = 'lost' }
  end

  -- Threshold uses body-only score: context contributes to tie-breaking but
  -- shouldn't carry a partial body match over the line.
  local threshold = math.max(1, math.ceil(0.7 * nlen))
  if best_body >= threshold then
    return {
      line_start = best_start,
      line_end = best_start + nlen - 1,
      drift = 'shifted',
    }
  end
  return { line_start = stored_start, line_end = stored_end, drift = 'lost' }
end

-- Append a reply to records[idx]. Pure mutation — caller invokes
-- `rewrite_jsonl` afterward to persist. Lazy-initializes `comments` on first
-- reply so notes without replies never carry an empty array on disk (cjson
-- encodes `{}` as a JSON object, which would break the schema).
function M.append_reply(records, idx, opts)
  local record = records and records[idx]
  if type(record) ~= 'table' then
    return nil, 'no record at index ' .. tostring(idx)
  end
  opts = opts or {}
  local body = opts.body
  if type(body) ~= 'string' then
    return nil, 'reply body must be a string'
  end
  body = body:gsub('\n+$', '')
  if body == '' then
    return nil, 'empty reply body'
  end
  local reply = {
    author = opts.author or 'ai',
    body = body,
    created_at = M.iso8601_now(),
  }
  if record.comments == nil or record.comments == M.NULL or type(record.comments) ~= 'table' then
    record.comments = {}
  end
  table.insert(record.comments, reply)
  return reply, nil
end

function M.rewrite_jsonl(path, records)
  local tmp = path .. '.tmp'
  local f, err = io.open(tmp, 'w')
  if not f then
    return false, err
  end
  for _, r in ipairs(records) do
    local ok_e, encoded = pcall(cjson.encode, r)
    if ok_e then
      f:write(encoded .. '\n')
    end
  end
  f:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rename_err
  end
  return true
end

-- =====================================================================
-- Filtering & sorting.
-- =====================================================================

function M.filter_for_branch(records, branch)
  if not branch then
    return records
  end
  local out = {}
  for _, r in ipairs(records) do
    if r.branch == nil or r.branch == M.NULL or r.branch == branch then
      table.insert(out, r)
    end
  end
  return out
end

function M.sort_resolved_last(list, get_record)
  get_record = get_record or function(x)
    return x
  end
  table.sort(list, function(a, b)
    local ra, rb = get_record(a), get_record(b)
    local a_resolved = M.normalize_status(ra.status) == 'resolved'
    local b_resolved = M.normalize_status(rb.status) == 'resolved'
    if a_resolved ~= b_resolved then
      return not a_resolved
    end
    return tostring(ra.created_at or '') < tostring(rb.created_at or '')
  end)
end

-- =====================================================================
-- Time parsing for --since / --until.
-- =====================================================================

-- Parse "5d", "24h", "30m", "10s", "2w" → seconds. Returns nil on no match.
local function parse_relative(s)
  local n, unit = s:match '^(%d+)([smhdw])$'
  if not n then
    return nil
  end
  n = tonumber(n)
  local mult = ({ s = 1, m = 60, h = 3600, d = 86400, w = 604800 })[unit]
  return n * mult
end

-- Parse ISO-8601 date or timestamp into epoch seconds. Accepts:
--   YYYY-MM-DD
--   YYYY-MM-DDTHH:MM:SS
--   YYYY-MM-DDTHH:MM:SS±HH:MM   or   ±HHMM   or   Z
---@diagnostic disable-next-line: assign-type-mismatch, param-type-mismatch
local function parse_iso(s)
  local y, m, d, h, mi, se, tz_sign, tz_h, tz_m
  -- Date only.
  y, m, d = s:match '^(%d%d%d%d)%-(%d%d)%-(%d%d)$'
  if y then
    return os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 }
  end
  -- Timestamp with optional timezone.
  local rest
  y, m, d, h, mi, se, rest = s:match '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$'
  if not y then
    return nil
  end
  local t = {
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(se),
  }
  -- Treat naive timestamps as local time, matching iso8601_now()'s output
  -- which always carries an offset.
  if rest == nil or rest == '' then
    return os.time(t)
  end
  if rest == 'Z' then
    -- UTC: use os.time on a struct then add the local offset back out.
    local local_epoch = os.time(t)
    local utc_struct = os.date('!*t', local_epoch)
    utc_struct.isdst = false
    local utc_epoch = os.time(utc_struct)
    return local_epoch + (local_epoch - utc_epoch)
  end
  tz_sign, tz_h, tz_m = rest:match '^([+-])(%d%d):?(%d%d)$'
  if not tz_sign then
    return nil
  end
  -- Compute UTC epoch by treating the input as if it were local, then
  -- adjusting by (input_offset - local_offset).
  local local_epoch = os.time(t)
  local utc_struct = os.date('!*t', local_epoch)
  utc_struct.isdst = false
  local utc_epoch = os.time(utc_struct)
  local local_offset = local_epoch - utc_epoch
  local input_offset = (tonumber(tz_h) * 3600 + tonumber(tz_m) * 60) * (tz_sign == '-' and -1 or 1)
  return local_epoch + (local_offset - input_offset)
end

function M.parse_when(s)
  if type(s) ~= 'string' or s == '' then
    return nil
  end
  local rel = parse_relative(s)
  if rel then
    return os.time() - rel
  end
  return parse_iso(s)
end

function M.iso8601_now()
  local stamp = os.date '%Y-%m-%dT%H:%M:%S'
  local tz = os.date '%z'
  if type(tz) == 'string' and #tz == 5 then
    tz = tz:sub(1, 3) .. ':' .. tz:sub(4, 5)
  end
  return stamp .. (tz or '')
end

-- Convert a record's created_at into epoch seconds for comparison.
local function record_epoch(record)
  if type(record.created_at) ~= 'string' then
    return nil
  end
  return parse_iso(record.created_at)
end

-- =====================================================================
-- apply_filters: the CLI's filter set. ANDed together.
-- =====================================================================

local function lower(s)
  return tostring(s or ''):lower()
end

-- opts:
--   status_set          (set of status strings to include; nil = all)
--   branch              (string or nil; nil = no branch filter)
--   all_branches        (bool; overrides branch filter)
--   file_substring      (string)
--   file_regex          (Lua pattern)
--   line                (number; matches if line_start <= n <= line_end)
--   line_range          ({a, b}; matches if record's range overlaps [a,b])
--   commit_prefix       (string; record.commit must start with it)
--   grep                (case-insensitive substring on note body)
--   grep_regex          (Lua pattern on note body)
--   since               (epoch seconds; created_at >= since)
--   until_              (epoch seconds; created_at <= until)
--   limit               (max records after sort/filter)
--   sort                (bool; default true → sort_resolved_last)
function M.apply_filters(records, opts)
  opts = opts or {}
  local out = {}

  -- branch
  if not opts.all_branches and opts.branch then
    records = M.filter_for_branch(records, opts.branch)
  end

  for _, r in ipairs(records) do
    local keep = true

    if keep and opts.status_set then
      local st = M.normalize_status(r.status)
      if not opts.status_set[st] then
        keep = false
      end
    end

    if keep and opts.file_substring then
      if not (type(r.file) == 'string' and r.file:find(opts.file_substring, 1, true)) then
        keep = false
      end
    end

    if keep and opts.file_regex then
      if not (type(r.file) == 'string' and r.file:find(opts.file_regex)) then
        keep = false
      end
    end

    if keep and opts.line then
      if not (type(r.line_start) == 'number' and type(r.line_end) == 'number' and opts.line >= r.line_start and opts.line <= r.line_end) then
        keep = false
      end
    end

    if keep and opts.line_range then
      local a, b = opts.line_range[1], opts.line_range[2]
      if a > b then
        a, b = b, a
      end
      if not (type(r.line_start) == 'number' and type(r.line_end) == 'number' and r.line_end >= a and r.line_start <= b) then
        keep = false
      end
    end

    if keep and opts.commit_prefix then
      local c = r.commit
      if c == M.NULL or c == nil or type(c) ~= 'string' or c:sub(1, #opts.commit_prefix) ~= opts.commit_prefix then
        keep = false
      end
    end

    if keep and opts.grep then
      if not (type(r.note) == 'string' and lower(r.note):find(lower(opts.grep), 1, true)) then
        keep = false
      end
    end

    if keep and opts.grep_regex then
      if not (type(r.note) == 'string' and r.note:find(opts.grep_regex)) then
        keep = false
      end
    end

    if keep and (opts.since or opts['until']) then
      local epoch = record_epoch(r)
      if not epoch then
        keep = false
      else
        if opts.since and epoch < opts.since then
          keep = false
        end
        if keep and opts['until'] and epoch > opts['until'] then
          keep = false
        end
      end
    end

    if keep then
      table.insert(out, r)
    end
  end

  if opts.sort ~= false then
    M.sort_resolved_last(out)
  end

  if opts.limit and #out > opts.limit then
    local trimmed = {}
    for i = 1, opts.limit do
      trimmed[i] = out[i]
    end
    out = trimmed
  end

  return out
end

return M
