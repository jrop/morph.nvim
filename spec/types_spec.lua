-- Type tests: each file in spec/types/ is checked by emmylua_check, and every
-- diagnostic it reports must be announced by an `-- expect: <code>[, <code>]`
-- comment on the flagged line. The match runs both ways, so a fixture fails on
-- 1. a diagnostic nobody expected, and 2. an expectation nothing triggered,
-- i.e., a type that silently widened to `any` fails as loudly as one that
-- broke.

local Test = require 'morph.vendor.test'
local describe, it, before_all = Test.describe, Test.it, Test.before_all
local assert = Test.assert

local ROOT = vim.fn.getcwd()
local FIXTURES = ROOT .. '/spec/types'

--- Reads each fixture's `-- expect:` markers as sorted `line:code` keys, so
--- duplicates on one line count separately.
--- @param path string
--- @return string[]
local function expected_keys(path)
  local keys = {}
  for lnum, line in ipairs(vim.fn.readfile(path)) do
    local codes = line:match '%-%- expect: (.*)$'
    for code in (codes or ''):gmatch '[%w-]+' do
      table.insert(keys, lnum .. ':' .. code)
    end
  end
  table.sort(keys)
  return keys
end

describe('types', function()
  --- @type table<string, string[]>
  local reported = {}

  before_all(function()
    -- The fixtures form their own workspace, because the repo's lint must not
    -- see their deliberate errors. morph therefore enters as a library, and
    -- emmylua resolves `require 'morph'` against a library only through an
    -- absolute path, so the config is written per run.
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local config = tmp .. '/emmyrc.json'
    local output = tmp .. '/diagnostics.json'
    vim.fn.writefile({
      vim.json.encode {
        runtime = { version = 'LuaJIT' },
        workspace = { library = { vim.env.VIMRUNTIME, ROOT .. '/lua' } },
      },
    }, config)

    -- The exit code is ignored, because it is nonzero whenever a fixture has
    -- its expected diagnostics.
    local result = vim
      .system({ 'emmylua_check', '-c', config, '-f', 'json', '--output', output, FIXTURES })
      :wait()
    assert.ok(vim.uv.fs_stat(output), 'emmylua_check wrote no output: ' .. (result.stderr or ''))

    for _, file in ipairs(vim.json.decode(table.concat(vim.fn.readfile(output), '\n'))) do
      local keys = {}
      for _, d in ipairs(file.diagnostics) do
        table.insert(keys, (d.range.start.line + 1) .. ':' .. d.code)
      end
      table.sort(keys)
      reported[vim.fs.normalize(file.file)] = keys
    end
  end)

  for name in vim.fs.dir(FIXTURES) do
    if name:match '%.lua$' then
      local path = vim.fs.normalize(FIXTURES .. '/' .. name)
      it(name, function() assert.deep_equal(reported[path] or {}, expected_keys(path)) end)
    end
  end
end)
