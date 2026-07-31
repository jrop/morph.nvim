--- Minimal assert surface
--- Re-exports Lua's builtin `assert` and adds `assert_deep_equal`.
--- @class morph._test.assert
local M = {}

--- Re-export the builtin so tests write `assert(cond, msg)` directly.
M.assert = assert --[[@as function]]

local Morph = require 'morph'

--- @diagnostic disable-next-line: undefined-field
local levenshtein = Morph._levenshtein --- @type fun(opts: morph.LevenshteinOpts): morph.LevenshteinChange<any>[]

--- Build a readable unified line diff of two line lists using Morph's
--- Levenshtein diff. `+` = add (want line), `-` = delete (got line); a change
--- surfaces as `-` then `+` on consecutive lines.
--- @param got string[] -- got lines
--- @param want string[] -- want lines
--- @return string
function M.diff(got, want)
  local changes = levenshtein { from = got, to = want }

  -- levenshtein emits changes in reverse (backtrack from end); reverse to
  -- source order so we can interleave unchanged context lines.
  local ordered = {} --- @type morph.LevenshteinChange<any>[]
  for k = #changes, 1, -1 do
    ordered[#ordered + 1] = changes[k]
  end

  local out = { '--- got', '+++ want' }
  local gi = 1

  local function emit_context(target)
    while gi < target do
      table.insert(out, '  ' .. got[gi])
      gi = gi + 1
    end
  end

  for _, change in ipairs(ordered) do
    if change.kind == 'add' then
      emit_context(change.index)
      table.insert(out, '+ ' .. change.item)
    elseif change.kind == 'delete' then
      emit_context(change.index)
      table.insert(out, '- ' .. change.item)
      gi = gi + 1
    elseif change.kind == 'change' then
      emit_context(change.index)
      table.insert(out, '- ' .. change.from)
      table.insert(out, '+ ' .. change.to)
      gi = gi + 1
    end
  end

  emit_context(#got + 1)

  return table.concat(out, '\n')
end

--- Deep-equality. On mismatch prints a unified diff of the two values
--- (pretty-printed via vim.inspect) and calls error().
--- @param got any
--- @param want any
--- @param msg? string
function M.assert_deep_equal(got, want, msg)
  if vim.deep_equal(got, want) then return end
  local header = msg and ('assert_deep_equal failed: ' .. msg) or 'assert_deep_equal failed'
  local got_lines = vim.split(vim.inspect(got), '\n')
  local want_lines = vim.split(vim.inspect(want), '\n')
  error(('%s\n%s'):format(header, M.diff(got_lines, want_lines)), 2)
end

return M
