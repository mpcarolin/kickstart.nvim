-- Telescope picker for GitLab Merge Requests, scoped to the current buffer's
-- git repo. Backed by the `glab` CLI.
--
-- <CR>  checkout the MR locally (`glab mr checkout <iid>`), refresh buffers
-- <C-o> open the MR in a browser (`glab mr view --web <iid>`), keep picking
-- <C-y> yank the MR's web_url to the system clipboard

local M = {}

-- os.time treats its table arg as local; ISO timestamps from `glab` are UTC.
-- Cache the offset once so format_relative stays cheap on every render.
local UTC_OFFSET = os.difftime(os.time(), os.time(os.date '!*t'))

local function format_relative(iso)
  if not iso or iso == '' then
    return ''
  end
  local y, mo, d, h, mi, s = iso:match '(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)'
  if not y then
    return iso
  end
  local then_ = os.time {
    year = tonumber(y) or 1970,
    month = tonumber(mo) or 1,
    day = tonumber(d) or 1,
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
    sec = tonumber(s) or 0,
  } + UTC_OFFSET
  local diff = os.time() - then_
  if diff < 60 then
    return diff .. 's ago'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. 'm ago'
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. 'h ago'
  elseif diff < 86400 * 30 then
    return math.floor(diff / 86400) .. 'd ago'
  elseif diff < 86400 * 365 then
    return math.floor(diff / (86400 * 30)) .. 'mo ago'
  else
    return math.floor(diff / (86400 * 365)) .. 'y ago'
  end
end

local function truncate(s, n)
  s = s or ''
  if #s <= n then
    return s
  end
  return s:sub(1, n - 1) .. '…'
end

function M.open()
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local previewers = require 'telescope.previewers'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'

  local buf_name = vim.api.nvim_buf_get_name(0)
  local buf_dir = buf_name ~= '' and vim.fn.fnamemodify(buf_name, ':p:h') or vim.fn.getcwd()

  -- Cache descriptions fetched on-demand so cursor movement doesn't reshell.
  local desc_cache = {}

  local displayer = entry_display.create {
    separator = ' ',
    items = {
      { width = 6 },
      { width = 18 },
      { remaining = true },
    },
  }

  local function entry_maker(mr)
    if mr.__loading then
      return {
        value = mr,
        display = function()
          return displayer {
            { '⏳', 'TelescopeResultsNumber' },
            { '', 'TelescopeResultsComment' },
            { 'Loading merge requests…', 'Comment' },
          }
        end,
        ordinal = 'loading',
      }
    end
    local iid = '!' .. tostring(mr.iid or '?')
    local title = mr.title or ''
    if mr.draft then
      title = 'Draft: ' .. title
    end
    local author = '@' .. ((mr.author and mr.author.username) or '?')
    return {
      value = mr,
      display = function()
        return displayer {
          { iid, 'TelescopeResultsNumber' },
          { author, 'TelescopeResultsComment' },
          truncate(title, 80),
        }
      end,
      ordinal = table.concat({ iid, title, author, table.concat(mr.labels or {}, ' ') }, ' '),
    }
  end

  local function render_preview(bufnr, winid, mr, description)
    local labels = (mr.labels and #mr.labels > 0) and table.concat(mr.labels, ', ') or '—'
    local author_label = (mr.author and (mr.author.name or mr.author.username)) or 'unknown'
    local sep = string.rep('─', 60)
    local lines = {
      'Title:    ' .. (mr.title or ''),
      'MR:       !' .. tostring(mr.iid or '?') .. (mr.draft and '  [DRAFT]' or ''),
      'Author:   ' .. author_label,
      'Branch:   ' .. (mr.source_branch or '?') .. ' → ' .. (mr.target_branch or '?'),
      'State:    ' .. (mr.state or '?'),
      'Labels:   ' .. labels,
      'Created:  ' .. format_relative(mr.created_at),
      'Updated:  ' .. format_relative(mr.updated_at),
      'URL:      ' .. (mr.web_url or ''),
      sep,
      '',
    }
    for body_line in (description or ''):gmatch '[^\n]+' do
      table.insert(lines, body_line)
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = 'markdown'
    if winid and vim.api.nvim_win_is_valid(winid) then
      vim.wo[winid].wrap = true
      vim.wo[winid].linebreak = true
    end

    local hl = vim.api.nvim_buf_add_highlight
    local label_len = 10
    for row = 0, 8 do
      hl(bufnr, 0, 'Comment', row, 0, label_len)
    end
    hl(bufnr, 0, 'Function', 0, label_len, -1)
    hl(bufnr, 0, 'Number', 1, label_len, -1)
    hl(bufnr, 0, 'String', 2, label_len, -1)
    hl(bufnr, 0, 'Identifier', 3, label_len, -1)
    hl(bufnr, 0, 'Comment', 9, 0, -1)
  end

  local picker
  picker = pickers.new({}, {
    prompt_title = 'GitLab Merge Requests (loading…)',
    finder = finders.new_table {
      results = { { __loading = true } },
      entry_maker = entry_maker,
    },
    sorter = conf.generic_sorter {},
    previewer = previewers.new_buffer_previewer {
      title = 'Merge Request',
      get_buffer_by_name = function(_, entry)
        return tostring(entry.value.iid)
      end,
      define_preview = function(self, entry)
        local mr = entry.value
        if mr.__loading then
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { '', '  Loading merge requests…' })
          return
        end

        local cached = mr.description
        if (not cached or cached == '') and desc_cache[mr.iid] then
          cached = desc_cache[mr.iid]
        end
        if cached and cached ~= '' then
          render_preview(self.state.bufnr, self.state.winid, mr, cached)
          return
        end

        render_preview(self.state.bufnr, self.state.winid, mr, '*(loading description…)*')
        local bufnr = self.state.bufnr
        local winid = self.state.winid
        vim.system(
          { 'glab', 'mr', 'view', tostring(mr.iid), '-F', 'json' },
          { cwd = buf_dir, text = true },
          vim.schedule_wrap(function(result)
            local description = '*(no description)*'
            if result.code == 0 then
              local ok, full = pcall(vim.json.decode, result.stdout or '')
              if ok and type(full) == 'table' and full.description and full.description ~= '' then
                description = full.description
              end
            end
            desc_cache[mr.iid] = description
            render_preview(bufnr, winid, mr, description)
          end)
        )
      end,
    },
    attach_mappings = function(prompt_bufnr, map)
      local function picked()
        local s = action_state.get_selected_entry()
        if not s or s.value.__loading then
          return nil
        end
        return s.value
      end

      actions.select_default:replace(function()
        local mr = picked()
        if not mr then
          return
        end
        actions.close(prompt_bufnr)
        local iid = tostring(mr.iid)
        local out = vim.fn.system { 'glab', 'mr', 'checkout', iid }
        if vim.v.shell_error ~= 0 then
          vim.notify(out, vim.log.levels.ERROR, { title = 'glab mr checkout' })
        else
          vim.cmd 'checktime'
          vim.notify('Checked out !' .. iid, vim.log.levels.INFO, { title = 'glab' })
        end
      end)

      map({ 'i', 'n' }, '<C-o>', function()
        local mr = picked()
        if not mr then
          return
        end
        vim.fn.system { 'glab', 'mr', 'view', '--web', tostring(mr.iid) }
        if vim.v.shell_error ~= 0 then
          vim.notify('glab mr view --web failed', vim.log.levels.ERROR, { title = 'glab' })
        end
      end)

      map({ 'i', 'n' }, '<C-y>', function()
        local mr = picked()
        if not mr then
          return
        end
        local url = mr.web_url or ''
        if url == '' then
          vim.notify('No web_url on this MR', vim.log.levels.WARN, { title = 'glab' })
          return
        end
        vim.fn.setreg('+', url)
        vim.notify('Copied: ' .. url, vim.log.levels.INFO, { title = 'glab' })
      end)

      return true
    end,
  })
  picker:find()

  local function show_empty()
    pcall(picker.refresh, picker, finders.new_table { results = {}, entry_maker = entry_maker })
  end

  vim.system(
    { 'glab', 'mr', 'list', '-F', 'json', '-P', '100' },
    { cwd = buf_dir, text = true },
    vim.schedule_wrap(function(result)
      if not vim.api.nvim_buf_is_valid(picker.prompt_bufnr or -1) then
        return
      end
      if result.code ~= 0 then
        local msg = result.stderr ~= '' and result.stderr or result.stdout
        vim.notify('glab mr list failed:\n' .. (msg or ''), vim.log.levels.ERROR, { title = 'glab' })
        show_empty()
        return
      end

      local ok, decoded = pcall(vim.json.decode, result.stdout or '[]')
      if not ok or type(decoded) ~= 'table' then
        vim.notify('glab: could not parse JSON output', vim.log.levels.ERROR, { title = 'glab' })
        show_empty()
        return
      end

      pcall(picker.refresh, picker, finders.new_table { results = decoded, entry_maker = entry_maker }, { reset_prompt = false })
      pcall(picker.change_prompt_title, picker, string.format('GitLab Merge Requests (%d open)', #decoded))
    end)
  )
end

return M
