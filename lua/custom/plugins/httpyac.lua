return {
  'abidibo/nvim-httpyac',
  config = function()
    local httpyac = require 'nvim-httpyac'
    httpyac.setup()

    -- Override exec_httpyac with an async version so running a request does not
    -- freeze Neovim. Upstream uses a synchronous `vim.fn.system()` on the UI
    -- thread (lua/nvim-httpyac/init.lua:34), which blocks the editor for the
    -- whole token-mint + HTTP round-trip. We patch our own copy here so the fix
    -- survives plugin updates (the lazy dir is never edited).
    local B = require 'nvim-httpyac.buffer'

    httpyac.exec_httpyac = function(opts)
      opts = opts or {}
      local args = opts.args or { '-a' }
      local userArgs = opts.userArgs or {}

      -- Build the argument list. Upstream passes args as a single shell string,
      -- so e.g. "-l 19" is one element; as a real argv element httpyac would see
      -- the literal "-l 19" and fail to parse it. Split each arg on whitespace
      -- and flatten so { "-l 19" } becomes { "-l", "19" } and { "-a" } is unchanged.
      local arg_list = {}
      for _, list in ipairs { args, userArgs } do
        for _, arg in ipairs(list) do
          for _, piece in ipairs(vim.split(arg, '%s+', { trimempty = true })) do
            table.insert(arg_list, piece)
          end
        end
      end

      -- Capture the file path before going async so the result isn't tied to
      -- whatever buffer happens to be focused when the request completes.
      local file_path = vim.fn.expand '%:p'
      if file_path == '' then
        vim.notify('No file for the current buffer', vim.log.levels.ERROR, { title = 'httpyac' })
        return
      end

      -- Run httpyac from the file's own directory. httpyac (via globby) rejects
      -- an absolute target path that isn't under the process cwd with
      -- "Path ... is not in cwd", so without this the request errors out
      -- whenever Neovim's cwd differs from the .http file's location.
      local cwd = vim.fn.fnamemodify(file_path, ':h')

      local notify_id = vim.notify('Running request…', vim.log.levels.INFO, {
        title = 'httpyac',
      })

      local cmd = { 'httpyac', file_path }
      for _, piece in ipairs(arg_list) do
        table.insert(cmd, piece)
      end

      -- vim.system runs httpyac off the main loop, keeping Neovim responsive.
      -- The callback fires in a fast/luv context where buffer + notify APIs are
      -- disallowed, so wrap it in vim.schedule_wrap.
      vim.system(cmd, { text = true, cwd = cwd }, vim.schedule_wrap(function(res)
        local out = (res.stdout or '') .. (res.stderr or '')
        -- Open the output split only now that the response is ready, so an empty
        -- pane doesn't appear while the request is still in flight.
        B.open_buffer()
        B.log(out)

        if res.code == 0 then
          vim.notify('Request finished', vim.log.levels.INFO, {
            title = 'httpyac',
            replace = notify_id,
          })
        else
          vim.notify('Request failed (exit ' .. res.code .. ')', vim.log.levels.ERROR, {
            title = 'httpyac',
            replace = notify_id,
          })
        end
      end))
    end

    -- if you want to set up the keymaps
    vim.keymap.set('n', '<Leader>rr', '<cmd>:NvimHttpYac<CR>', { desc = 'Run request' })
    vim.keymap.set('n', '<Leader>ra', '<cmd>:NvimHttpYacAll<CR>', { desc = 'Run all requests' })
  end,
}
