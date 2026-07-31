--- @diagnostic disable: assign-type-mismatch, global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

--- on_change integration tests.
---
--- Runs in a child `nvim --headless --embed` (real event loop) so
--- `TextChanged`/`TextChangedI` fire naturally from real keystrokes and
--- programmatic edits — no `vim.cmd.doautocmd` fakes.  Every `exec_func`
--- closure is self-contained (`string.dump` drops upvalues); requires go inside
--- the closure body and the Morph handle lives in the child global `_G.m`.
local Nvim = require 'morph._test.nvim'

describe('on_change events', function()
  local nv

  before_each(function() nv = Nvim.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('fires when text is replaced', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, {
          'one\n',
          'two\n',
          'three\n',
        }),
      }
      vim.fn.setreg('"', 'bleh')
    end)

    nv:input 'ggVGp'
    local replaced = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('bleh', replaced.text)
    assert.are.same({ { id = 'tag', text = 'bleh' } }, replaced.events)

    nv:input 'ggdG'
    local cleared = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('', cleared.text)
    assert.are.same({ { id = 'tag', text = 'bleh' }, { id = 'tag', text = '' } }, cleared.events)
  end)

  it('fires when text is deleted', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'prefix:',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, { 'one' }),
        'suffix',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 9 })
    end)

    nv:input 'vhhd'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('prefix:suffix', result.text)
    assert.are.same({ { id = 'tag', text = '' } }, result.events)
  end)

  it('fires when newline is inserted', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Search [',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'filter'),
        ']',
      }
    end)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 14, 0, 14, { '', '' }) end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Search [filter\n]', result.text)
    assert.are.same({ { id = 'tag', text = 'filter\n' } }, result.events)
  end)

  it('does not corrupt buffer on atomic multi-line insert at end of line', function()
    -- When a multi-line insert happens at the end of an extmark, the buggy
    -- end_col0 calculation and the wrong clamp can cause _get_in_range to query
    -- the wrong region. The on_change handler re-renders via ctx:update; a
    -- stale or missed event would overwrite the buffer with stale single-line
    -- text, destroying the user's multi-line insert.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param ctx morph.Ctx<{}, { text: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { text = 'jsonPayload.message' } end
        local state = assert(ctx.state)
        return {
          h('text', {
            id = 'the-id',
            on_change = function(e)
              e.bubble_up = false
              rec(e)
              ctx:update { text = e.text }
            end,
          }, state.text),
        }
      end
      _G.m:mount(h(App))
    end)

    -- Simulate real Cmd+V: atomic multi-line insert at end of line 0.
    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 19, 0, 19, { '', 'severity' }) end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return { text = util.text(0), events = util.events() }
    end)
    -- Buffer must NOT be corrupted by the re-render
    assert.are.same('jsonPayload.message\nseverity', result.text)
    -- on_change must receive the full updated text
    assert.are.same({ { id = 'the-id', text = 'jsonPayload.message\nseverity' } }, result.events)
  end)

  it('fires with empty string when tag text is deleted entirely', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Search: ',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'input_text'),
      }
    end)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 8, 0, 18, {}) end)
    local deleted = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Search: ', deleted.text)
    assert.are.same({ { id = 'tag', text = '' } }, deleted.events)

    nv:exec_func(function()
      local util = require 'morph._test.util'
      local h = require('morph').h
      _G.m:render {
        'Filter: ',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'query'),
      }
    end)
    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 8, 0, 13, {}) end)
    local second = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: ', second.text)
    assert.are.same({
      { id = 'tag', text = '' },
      { id = 'tag', text = '' },
    }, second.events)
  end)

  it('detects change when new text has same length as original', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param _ctx morph.Ctx
      local function App(_ctx)
        return {
          h('text', {
            id = 'the-id',
            on_change = function(e)
              e.bubble_up = false
              rec(e)
            end,
          }, { 'hello' }),
        }
      end
      _G.m:mount(h(App))
    end)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 4, 0, 5, { 'p' }) end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('hellp', result.text)
    assert.are.same({ { id = 'the-id', text = 'hellp' } }, result.events)
  end)

  it('detects change when text changes back to original content', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param _ctx morph.Ctx
      local function App(_ctx)
        return {
          h('text', {
            id = 'the-id',
            on_change = function(e)
              e.bubble_up = false
              rec(e)
            end,
          }, { 'hello' }),
        }
      end
      _G.m:mount(h(App))
    end)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 4, 0, 5, {}) end)
    local deleted = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('hell', deleted.text)
    assert.are.same({ { id = 'the-id', text = 'hell' } }, deleted.events)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 4, 0, 4, { 'o' }) end)
    local restored = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('hello', restored.text)
    assert.are.same({
      { id = 'the-id', text = 'hell' },
      { id = 'the-id', text = 'hello' },
    }, restored.events)
  end)

  describe('event bubbling', function()
    it('fires handlers from inner to outer, not affecting siblings', function()
      nv:exec_func(function()
        local util = require 'morph._test.util'
        local Morph = require 'morph'
        local h = Morph.h
        _G.m = Morph.new(util.scratch_buf { focus = true })
        _G.__render = function()
          _G.m:render {
            h(
              'text',
              { id = 'sibling', on_change = util.create_event_recorder 'sibling' },
              'sibling'
            ),
            ' ',
            h('text', { id = 'outer', on_change = util.create_event_recorder 'outer' }, {
              'outer ',
              h('text', { id = 'middle' }, {
                'middle ',
                h(
                  'text',
                  { id = 'inner', on_change = util.create_event_recorder 'inner' },
                  'inner'
                ),
              }),
            }),
          }
        end
        _G.__render()
      end)

      -- Change innermost element -> fires inner then outer
      nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 21, 0, 26, { 'changed' }) end)
      local inner = nv:exec_func(function()
        local util = require 'morph._test.util'
        return { text = util.text(0), events = util.events() }
      end)
      assert.are.same('sibling outer middle changed', inner.text)
      assert.are.same(2, #inner.events)
      assert.are.same('inner', inner.events[1].id)
      assert.are.same('changed', inner.events[1].text)
      assert.are.same('outer', inner.events[2].id)
      assert.are.same('outer middle changed', inner.events[2].text)

      -- Change sibling -> only sibling handler fires
      nv:exec_func(function()
        local util = require 'morph._test.util'
        util.events { clear = true }
        _G.__render()
        vim.api.nvim_buf_set_text(0, 0, 0, 0, 7, { 'modified' })
      end)
      local sibling = nv:exec_func(function()
        local util = require 'morph._test.util'
        return { text = util.text(0), events = util.events() }
      end)
      assert.are.same('modified outer middle inner', sibling.text)
      assert.are.same(1, #sibling.events)
      assert.are.same('sibling', sibling.events[1].id)
      assert.are.same('modified', sibling.events[1].text)

      -- Change middle (no handler) -> only outer handler fires
      nv:exec_func(function()
        local util = require 'morph._test.util'
        util.events { clear = true }
        _G.__render()
        vim.api.nvim_buf_set_text(0, 0, 14, 0, 20, { 'center' })
      end)
      local middle = nv:exec_func(function()
        local util = require 'morph._test.util'
        return { text = util.text(0), events = util.events() }
      end)
      assert.are.same('sibling outer center inner', middle.text)
      assert.are.same(1, #middle.events)
      assert.are.same('outer', middle.events[1].id)
      assert.are.same('outer center inner', middle.events[1].text)
    end)

    it('bubbles through multiple nested levels', function()
      nv:exec_func(function()
        local util = require 'morph._test.util'
        local Morph = require 'morph'
        local h = Morph.h
        _G.m = Morph.new(util.scratch_buf { focus = true })
        _G.m:render {
          h('text', { id = 'level1', on_change = util.create_event_recorder 'level1' }, {
            h('text', { id = 'level2', on_change = util.create_event_recorder 'level2' }, {
              h(
                'text',
                { id = 'level3', on_change = util.create_event_recorder 'level3' },
                'inner'
              ),
            }),
          }),
        }
      end)

      nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 0, 0, 5, { 'changed' }) end)
      local result = nv:exec_func(function()
        local util = require 'morph._test.util'
        return { text = util.text(0), events = util.events() }
      end)
      assert.are.same(3, #result.events)
      assert.are.same('level3', result.events[1].id)
      assert.are.same('level2', result.events[2].id)
      assert.are.same('level1', result.events[3].id)
    end)

    it('stops bubbling when bubble_up is set to false', function()
      nv:exec_func(function()
        local util = require 'morph._test.util'
        local Morph = require 'morph'
        local h = Morph.h
        _G.m = Morph.new(util.scratch_buf { focus = true })
        local rec = util.create_event_recorder
        _G.m:render {
          h('text', { id = 'outer', on_change = rec 'outer' }, {
            h('text', {
              id = 'inner',
              on_change = function(e)
                e.bubble_up = false
                rec 'inner'(e)
              end,
            }, 'text'),
          }),
        }
      end)

      nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 0, 0, 4, { 'new' }) end)
      local result = nv:exec_func(function()
        local util = require 'morph._test.util'
        return { text = util.text(0), events = util.events() }
      end)
      assert.are.same(1, #result.events)
      assert.are.same('inner', result.events[1].id)
    end)
  end)

  it('fires on_change when set_lines inserts content after extmark range', function()
    -- nvim_buf_set_lines at a boundary does NOT expand the extmark's end_row.
    -- This simulates linewise paste ("p" in Normal mode), where the extmark
    -- covers only the original content and the newly inserted lines fall
    -- outside the extmark's range. The fallback in _on_bytes_after_autocmd
    -- must scan all on_change elements when no extmarks overlap the changed
    -- region and read the full buffer content directly.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param ctx morph.Ctx<{}, { text: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { text = 'asldkfjasdlfjkasdfkj' } end
        local state = assert(ctx.state)
        return {
          h('text', {
            id = 'the-id',
            on_change = function(e)
              e.bubble_up = false
              rec(e)
              ctx:update { text = e.text }
            end,
          }, state.text),
        }
      end
      _G.m:mount(h(App))
    end)

    -- Simulate linewise paste: insert a line after the extmark's range.
    nv:exec_func(
      function()
        vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'logName="projects/-----------/logs/---"' })
      end
    )
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return { text = util.text(0), events = util.events() }
    end)
    -- on_change must receive the full multi-line text
    assert.are.same('asldkfjasdlfjkasdfkj\nlogName="projects/-----------/logs/---"', result.text)
    assert.are.same(
      { { id = 'the-id', text = 'asldkfjasdlfjkasdfkj\nlogName="projects/-----------/logs/---"' } },
      result.events
    )
  end)

  it('fires on_change when set_lines inserts content before extmark range', function()
    -- nvim_buf_set_lines at row 0 (before the extmark) shifts the extmark
    -- rather than expanding it. The fallback must detect that the extmark
    -- moved and fire on_change with the full buffer text including the
    -- prepended content.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param ctx morph.Ctx<{}, { text: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { text = 'asldkfjasdlfjkasdfkj' } end
        local state = assert(ctx.state)
        return {
          h('text', {
            id = 'the-id',
            on_change = function(e)
              e.bubble_up = false
              rec(e)
              ctx:update { text = e.text }
            end,
          }, state.text),
        }
      end
      _G.m:mount(h(App))
    end)

    -- Prepend a line before the extmark range.
    nv:exec_func(function() vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'prepended' }) end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return { text = util.text(0), events = util.events() }
    end)
    -- on_change must fire with the full buffer including prepended content
    assert.are.same('prepended\nasldkfjasdlfjkasdfkj', result.text)
    assert.are.same({ { id = 'the-id', text = 'prepended\nasldkfjasdlfjkasdfkj' } }, result.events)
  end)
end)

describe('undo/redo', function()
  local nv

  before_each(function() nv = Nvim.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('tracks extmarks correctly through undo/redo', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:mount {
        'Search: [',
        h('text', { id = 'filter', on_change = util.create_event_recorder 'filter' }, ''),
        ']',
      }
      util.cursor_to_extmark_start(_G.m, 'filter')
    end)

    -- Real keystrokes; TextChangedI fires by itself (no doautocmd).
    nv:input 'ifilter'
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Search: [filter]', typed.text)
    assert.are.same({ { id = 'filter', text = 'filter' } }, typed.events)

    nv:input '<Esc>u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Search: []', undone.text)
    assert.are.same({
      { id = 'filter', text = 'filter' },
      { id = 'filter', text = '' },
    }, undone.events)

    nv:input '<C-r>'
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Search: [filter]', redone.text)
    assert.are.same({
      { id = 'filter', text = 'filter' },
      { id = 'filter', text = '' },
      { id = 'filter', text = 'filter' },
    }, redone.events)
  end)
end)

describe('morph._test.util', function()
  local nv

  before_each(function() nv = Nvim.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('covers the full helper API through a child', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      local bufnr = util.scratch_buf { focus = true, lines = { 'Search: [x]' } }
      _G.m = Morph.new(bufnr)
      _G.m:mount {
        'Search: [',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'x'),
        ']',
      }
      util.cursor_to_extmark_start(_G.m, 'tag')
    end)

    local cursor = nv:exec_func(function() return vim.api.nvim_win_get_cursor(0) end)
    assert.are.same({ 1, 9 }, cursor)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 9, 0, 10, { 'y' }) end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(30)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Search: [y]', result.text)
    assert.are.same({ { id = 'tag', text = 'y' } }, result.events)

    local cleared = nv:exec_func(function()
      local util = require 'morph._test.util'
      return util.events { clear = true }
    end)
    assert.are.same({ { id = 'tag', text = 'y' } }, cleared)

    local after_clear = nv:exec_func(function()
      local util = require 'morph._test.util'
      return util.events()
    end)
    assert.are.same({}, after_clear)
  end)
end)
