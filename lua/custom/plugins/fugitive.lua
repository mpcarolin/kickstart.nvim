return {
  'tpope/vim-fugitive',
  -- Load on first use instead of at startup. Fugitive is command-driven, so
  -- nothing needs it until one of these is invoked. Arbiter's FugitiveParse /
  -- FugitiveGitDir calls are all pcall-guarded and only run against fugitive
  -- buffers, which cannot exist before one of these commands has loaded it.
  cmd = {
    'G',
    'Git',
    'Gedit',
    'Gread',
    'Gwrite',
    'Gdiffsplit',
    'Gvdiffsplit',
    'Ghdiffsplit',
    'Gsplit',
    'Gvsplit',
    'Gtabedit',
    'Ggrep',
    'Glgrep',
    'Gclog',
    'GcLog',
    'Gllog',
    'GlLog',
    'GMove',
    'GRename',
    'GDelete',
    'GRemove',
    'GUnlink',
    'GBrowse',
  },
}
