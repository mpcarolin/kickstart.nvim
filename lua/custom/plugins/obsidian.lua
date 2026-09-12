-- lua/custom/plugins/obsidian.lua
-- obsidian.nvim, gated on vim.g.obsidian_vault (set per-machine in env.lua).
-- Unset on a machine => enabled=false => lazy never installs it. This keeps
-- the shared dotfiles repo machine-agnostic; see env.template.lua and the
-- vim.g.notes_dir gating in neo-tree.lua for the same pattern.
--
-- On a machine where it IS enabled: [[wikilink]] navigation (gf / <CR>),
-- telescope quick-switch / search / tags, backlinks + TOC pickers, and
-- templated new-note creation, all against the vault at vim.g.obsidian_vault.
local vault = vim.g.obsidian_vault

return {
  'obsidian-nvim/obsidian.nvim', -- maintained community fork; epwalsh/obsidian.nvim archived 2024
  enabled = vault ~= nil and vault ~= '',
  version = '*',
  ft = 'markdown', -- lazy-load on markdown buffers
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-telescope/telescope.nvim', -- already in the tree (init.lua)
  },
  opts = {
    workspaces = {
      { name = 'personal', path = vault },
    },
    -- Vault tree conventions (see the `notes` skill): graph/ is flat, new notes
    -- are lowercase-kebab-case, no frontmatter on graph notes.
    notes_subdir = 'graph',
    new_notes_location = 'notes_subdir',
    -- rule 4: no frontmatter on graph notes.
    frontmatter = { enabled = false },
    -- rule 6: lowercase-kebab-case filenames (fall back to a zettel id when a
    -- note is created without a title).
    note_id_func = function(title)
      if title and title ~= '' then
        return title:gsub('[^A-Za-z0-9 -]', ''):gsub('%s+', '-'):lower()
      end
      return tostring(os.time())
    end,
    -- [[wiki]] links, matching the vault. The fork drives link creation off
    -- link.style now (wiki_link_func was removed in 3.18); 'shortest' suits a
    -- flat graph/ where basenames are unique.
    link = { style = 'wiki', format = 'shortest' },
    -- Completion is provided by the fork's built-in obsidian-ls LSP server,
    -- surfaced through blink's existing `lsp` source — nothing to register here.
    completion = { min_chars = 2 },
    picker = { name = 'telescope.nvim' },
    templates = {
      folder = 'templates', -- ~/notes/templates/, outside the tree like attachments/
    },
    ui = { enable = true }, -- full in-editor UI, now that checkmate is gone
    -- gf / <CR> on a wikilink follows it; obsidian.nvim maps this in markdown
    -- buffers. Real URLs go through vim.ui.open (macOS: `open`) by default.
  },
  keys = {
    { '<leader>oo', '<cmd>Obsidian quick_switch<cr>', desc = '[O]bsidian quick switch' },
    { '<leader>os', '<cmd>Obsidian search<cr>', desc = '[O]bsidian [S]earch' },
    { '<leader>ot', '<cmd>Obsidian tags<cr>', desc = '[O]bsidian [T]ags' },
    { '<leader>ob', '<cmd>Obsidian backlinks<cr>', desc = '[O]bsidian [B]acklinks' },
    { '<leader>oc', '<cmd>Obsidian toc<cr>', desc = '[O]bsidian to[C]' },
    { '<leader>on', '<cmd>Obsidian new<cr>', desc = '[O]bsidian [N]ew note' },
    { '<leader>oT', '<cmd>Obsidian template<cr>', desc = '[O]bsidian insert [T]emplate' },
    { '<leader>ol', '<cmd>Obsidian link<cr>', mode = { 'v' }, desc = '[O]bsidian [L]ink selection' },
  },
}
