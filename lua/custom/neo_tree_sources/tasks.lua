-- lua/custom/neo_tree_sources/tasks.lua
-- External Neo-tree source that re-exports the filesystem source under a
-- new name, so the sidebar gains a "tasks" tab with an independently
-- pinned root. Loaded via Neo-tree's `sources` config. Lives outside
-- lua/custom/plugins/ so lazy.nvim doesn't treat it as a plugin spec.
local fs = require('neo-tree.sources.filesystem')

-- Neo-tree's setup looks up `module.components` / `module.commands` on the
-- source module (or falls back to `<mod_root>.components` / `.commands` as
-- sibling files). Since our mod_root is custom.neo_tree_sources.tasks and
-- there are no sibling files, we expose the filesystem source's submodules
-- directly on the wrapper.
local M = setmetatable({
  name = 'tasks',
  display_name = ' 󰄬 Tasks ',
  components = require('neo-tree.sources.filesystem.components'),
  commands = require('neo-tree.sources.filesystem.commands'),
}, { __index = fs })

-- Pin navigations to vim.g.tasks_dir. Without this, the first navigate
-- (including the one triggered by the source-selector tab click) falls
-- through to vim.fn.getcwd(), so the tasks tree mirrors whatever the
-- filesystem source is rooted at. We override navigate to substitute
-- tasks_dir whenever the caller didn't pass an explicit path inside it.
local utils = require('neo-tree.utils')
M.navigate = function(state, path, path_to_reveal, callback, async)
  local tasks_dir = vim.g.tasks_dir
  if tasks_dir and tasks_dir ~= '' and vim.fn.isdirectory(tasks_dir) == 1 then
    if not path or path == '' or not utils.is_subpath(tasks_dir, path) then
      path = tasks_dir
    end
  end
  return fs.navigate(state, path, path_to_reveal, callback, async)
end

M.setup = function(config, global_config)
  fs.setup(config, global_config)
  -- fs.setup's manager.subscribe calls hardcode "filesystem", so the
  -- tasks state never gets file-watcher refreshes. Mirror them here.
  local manager = require('neo-tree.sources.manager')
  local events = require('neo-tree.events')
  if config.use_libuv_file_watcher then
    manager.subscribe(M.name, {
      event = events.FS_EVENT,
      handler = function(...) manager.refresh(M.name, ...) end,
    })
  elseif global_config.enable_refresh_on_write then
    manager.subscribe(M.name, {
      event = events.VIM_BUFFER_CHANGED,
      handler = function(arg)
        local utils = require('neo-tree.utils')
        if utils.is_real_file(arg.afile or '') then
          manager.refresh(M.name)
        end
      end,
    })
  end
end

return M
