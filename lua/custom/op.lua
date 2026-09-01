-- 1Password resolution helper.
--
-- Credentials are exported into the shell as unresolved `op://` references.
-- `op.inject(str)` substitutes any `op://` refs embedded in a template string
-- with their resolved secret values. Each ref is resolved via `op read <ref>`
-- (the 1Password CLI), which takes the ref as an argument — NOT stdin. `op`
-- does not reliably receive stdin when spawned by Neovim's `system()` (it exits
-- with "expected data on stdin but none found" before it can even prompt for
-- unlock), so `op inject` is unusable here; `op read` sidesteps that entirely.
-- Resolution happens at call time — wire it behind a function (e.g. a dadbod
-- connection `url` closure) so secrets are fetched on demand, not on startup.

local M = {}

-- An `op://` reference spans `op://vault/item[/section]/field`. Slashes are
-- internal to the ref, so it cannot stop at the first `/`. Embedded in a DB URL
-- the ref sits in the password slot (`scheme://user:<ref>@host/db`) and thus
-- terminates at the `@`. Stop at `@`, whitespace, or a quote — anything that
-- structurally ends the ref inside a surrounding URL.
local REF_PATTERN = 'op://[^%s@\'"]+'

--- Resolve one `op://` ref via `op read`. Returns the secret, or nil on failure.
local function read_ref(ref)
  local out = vim.fn.system { 'op', 'read', '--no-newline', ref }
  if vim.v.shell_error ~= 0 then
    vim.notify('op read failed for ' .. ref .. ': ' .. vim.trim(out), vim.log.levels.ERROR)
    return nil
  end
  return out
end

--- Resolve any `op://` references embedded in `str`.
--- Returns `str` unchanged when it is nil/empty or contains no `op://` ref
--- (so we never spawn `op` needlessly). On any CLI failure, notifies and
--- returns nil — never hands back a URL with an unresolved ref still in it.
---@param str string|nil
---@return string|nil
function M.inject(str)
  if not str or str == '' or not str:find('op://', 1, true) then
    return str
  end
  local failed = false
  local resolved = str:gsub(REF_PATTERN, function(ref)
    if failed then
      return ref
    end
    local secret = read_ref(ref)
    if secret == nil then
      failed = true
      return ref
    end
    return secret
  end)
  if failed then
    return nil
  end
  return resolved
end

return M
