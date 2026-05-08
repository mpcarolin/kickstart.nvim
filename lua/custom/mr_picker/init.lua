-- Telescope picker for Merge/Pull Requests, scoped to the current buffer's
-- git repo. Provider (GitLab via `glab`, GitHub via `gh`) is auto-detected
-- from the `origin` remote URL.
--
-- <CR>  checkout the MR/PR locally, refresh buffers
-- <C-o> open the MR/PR in a browser
-- <C-y> yank the MR/PR's url to the system clipboard

local M = {}

-- os.time treats its table arg as local; ISO timestamps from providers are UTC.
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
  local providers = require 'custom.mr_picker.providers'

  local buf_name = vim.api.nvim_buf_get_name(0)
  local buf_dir = buf_name ~= '' and vim.fn.fnamemodify(buf_name, ':p:h') or vim.fn.getcwd()

  local provider, detect_err = providers.detect(buf_dir)
  if not provider then
    vim.notify(detect_err or 'no provider detected', vim.log.levels.WARN, { title = 'mr_picker' })
    return
  end

  local notify_title = provider.display_name

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

  local function entry_maker(pr)
    if pr.__loading then
      return {
        value = pr,
        display = function()
          return displayer {
            { '⏳', 'TelescopeResultsNumber' },
            { '', 'TelescopeResultsComment' },
            { 'Loading ' .. provider.entity_label:lower() .. 's…', 'Comment' },
          }
        end,
        ordinal = 'loading',
      }
    end
    local id = provider.id_prefix .. tostring(pr.id or '?')
    local title = pr.title or ''
    if pr.draft then
      title = 'Draft: ' .. title
    end
    local author = '@' .. (pr.author_login or '?')
    return {
      value = pr,
      display = function()
        return displayer {
          { id, 'TelescopeResultsNumber' },
          { author, 'TelescopeResultsComment' },
          truncate(title, 80),
        }
      end,
      ordinal = table.concat({ id, title, author, table.concat(pr.labels or {}, ' ') }, ' '),
    }
  end

  local function render_preview(bufnr, winid, pr, description)
    local labels = (pr.labels and #pr.labels > 0) and table.concat(pr.labels, ', ') or '—'
    local sep = string.rep('─', 60)
    local lines = {
      'Title:    ' .. (pr.title or ''),
      provider.entity_short .. ':       ' .. provider.id_prefix .. tostring(pr.id or '?') .. (pr.draft and '  [DRAFT]' or ''),
      'Author:   ' .. (pr.author_name or 'unknown'),
      'Branch:   ' .. (pr.source_branch or '?') .. ' → ' .. (pr.target_branch or '?'),
      'State:    ' .. (pr.state or '?'),
      'Labels:   ' .. labels,
      'Created:  ' .. format_relative(pr.created_at),
      'Updated:  ' .. format_relative(pr.updated_at),
      'URL:      ' .. (pr.url or ''),
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
    prompt_title = provider.display_name .. ' ' .. provider.entity_label .. 's (loading…)',
    finder = finders.new_table {
      results = { { __loading = true } },
      entry_maker = entry_maker,
    },
    sorter = conf.generic_sorter {},
    previewer = previewers.new_buffer_previewer {
      title = provider.entity_label,
      get_buffer_by_name = function(_, entry)
        return tostring(entry.value.id)
      end,
      define_preview = function(self, entry)
        local pr = entry.value
        if pr.__loading then
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { '', '  Loading ' .. provider.entity_label:lower() .. 's…' })
          return
        end

        local cached = pr.description
        if (not cached or cached == '') and desc_cache[pr.id] then
          cached = desc_cache[pr.id]
        end
        if cached and cached ~= '' then
          render_preview(self.state.bufnr, self.state.winid, pr, cached)
          return
        end

        render_preview(self.state.bufnr, self.state.winid, pr, '*(loading description…)*')
        local bufnr = self.state.bufnr
        local winid = self.state.winid
        provider.fetch_description(buf_dir, pr, function(description)
          local final = description and description ~= '' and description or '*(no description)*'
          desc_cache[pr.id] = final
          render_preview(bufnr, winid, pr, final)
        end)
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
        local pr = picked()
        if not pr then
          return
        end
        actions.close(prompt_bufnr)
        local ok, err = provider.checkout(buf_dir, pr)
        if not ok then
          vim.notify(err or 'checkout failed', vim.log.levels.ERROR, { title = notify_title })
        else
          vim.notify(
            'Checked out ' .. provider.id_prefix .. tostring(pr.id),
            vim.log.levels.INFO,
            { title = notify_title }
          )
        end
      end)

      map({ 'i', 'n' }, '<C-o>', function()
        local pr = picked()
        if not pr then
          return
        end
        local ok, err = provider.open_web(buf_dir, pr)
        if not ok then
          vim.notify(err or 'open in browser failed', vim.log.levels.ERROR, { title = notify_title })
        end
      end)

      map({ 'i', 'n' }, '<C-y>', function()
        local pr = picked()
        if not pr then
          return
        end
        local url = pr.url or ''
        if url == '' then
          vim.notify('No url on this ' .. provider.entity_short, vim.log.levels.WARN, { title = notify_title })
          return
        end
        vim.fn.setreg('+', url)
        vim.notify('Copied: ' .. url, vim.log.levels.INFO, { title = notify_title })
      end)

      return true
    end,
  })
  picker:find()

  local function show_empty()
    pcall(picker.refresh, picker, finders.new_table { results = {}, entry_maker = entry_maker })
  end

  provider.list(buf_dir, function(ok, prs_or_err)
    if not vim.api.nvim_buf_is_valid(picker.prompt_bufnr or -1) then
      return
    end
    if not ok then
      vim.notify(prs_or_err or 'list failed', vim.log.levels.ERROR, { title = notify_title })
      show_empty()
      return
    end

    pcall(picker.refresh, picker, finders.new_table { results = prs_or_err, entry_maker = entry_maker }, { reset_prompt = false })
    pcall(
      picker.change_prompt_title,
      picker,
      string.format('%s %ss (%d open)', provider.display_name, provider.entity_label, #prs_or_err)
    )
  end)
end

return M
