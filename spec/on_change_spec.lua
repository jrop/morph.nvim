--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

--- on_change integration tests.
---
--- Runs in a **child** `nvim --headless --embed` (real event loop, real
--- autocmds, real input) so `TextChanged`/`TextChangedI` fire naturally from
--- real keystrokes and programmatic edits — no `vim.cmd.doautocmd` fakes. The
--- child is headless but is NOT subject to the host (test runner) nvim's
--- TextChanged-doesn't-fire / insert-pending-leak limitations; see AGENTS.md's
--- "Test Environment Notes" host/child split. Every `run` closure is
--- self-contained (`string.dump` drops upvalues); requires go inside the
--- closure body and the Morph handle lives in the child global `_G.m`.
--- Programmatic mode changes / scheduled work are only observable across an
--- RPC round-trip (a later `run`), not within the same call.
local Test = require 'morph.vendor.test'
local describe, it = Test.describe, Test.it
local before_each, after_each = Test.before_each, Test.after_each
local assert = Test.assert
--- @type spec.util
local util = dofile 'spec/util.lua'

describe('on_change events', function()
  --- @type test.Nvim
  local nv

  before_each(function() nv = util.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  --- Mount the controlled-hole app the corruption tests share: one editable
  --- tag whose on_change echoes the new text into app state (so every edit
  --- re-renders) and records into the event sink as 'the-id'.
  --- @param initial string  the tag's text at mount
  local function mount_echo_hole(initial)
    nv:run(function(...)
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      local initial_text = ... --- @type string
      --- @param ctx morph.Ctx<{}, { text: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { text = initial_text } end
        local state = _G.assert(ctx.state)
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
    end, initial)
  end

  it('fires when text is replaced', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
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
    local replaced = util.settled(nv, {})
    assert.deep_equal(replaced.text, 'bleh')
    assert.deep_equal(replaced.events, { { id = 'tag', text = 'bleh' } })

    nv:input 'ggdG'
    local cleared = util.settled(nv, {})
    assert.deep_equal(cleared.text, '')
    assert.deep_equal(cleared.events, { { id = 'tag', text = 'bleh' }, { id = 'tag', text = '' } })
  end)

  it('fires when text is deleted', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
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
    local result = util.settled(nv, {})
    assert.deep_equal(result.text, 'prefix:suffix')
    assert.deep_equal(result.events, { { id = 'tag', text = '' } })
  end)

  it('fires when newline is inserted', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Search [',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'filter'),
        ']',
      }
    end)

    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 14, 0, 14, { '', '' }) end)
    local result = util.settled(nv, {})
    assert.deep_equal(result.text, 'Search [filter\n]')
    assert.deep_equal(result.events, { { id = 'tag', text = 'filter\n' } })
  end)

  it('does not corrupt buffer on atomic multi-line insert at end of line', function()
    -- When a multi-line insert happens at the end of an extmark, the buggy
    -- end_col0 calculation and the wrong clamp can cause _get_in_range to query
    -- the wrong region. The on_change handler re-renders via ctx:update; a
    -- stale or missed event would overwrite the buffer with stale single-line
    -- text, destroying the user's multi-line insert.
    mount_echo_hole 'jsonPayload.message'

    -- Simulate real Cmd+V: atomic multi-line insert at end of line 0.
    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 19, 0, 19, { '', 'severity' }) end)
    local result = util.settled(nv, { ms = 100 })
    -- Buffer must NOT be corrupted by the re-render
    assert.deep_equal(result.text, 'jsonPayload.message\nseverity')
    -- on_change must receive the full updated text
    assert.deep_equal(result.events, { { id = 'the-id', text = 'jsonPayload.message\nseverity' } })
  end)

  it('fires with empty string when tag text is deleted entirely', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Search: ',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'input_text'),
      }
    end)

    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 8, 0, 18, {}) end)
    local deleted = util.settled(nv, {})
    assert.deep_equal(deleted.text, 'Search: ')
    assert.deep_equal(deleted.events, { { id = 'tag', text = '' } })

    nv:run(function()
      local util = dofile 'spec/util.lua'
      local h = require('morph').h
      _G.m:render {
        'Filter: ',
        h('text', { id = 'tag', on_change = util.create_event_recorder 'tag' }, 'query'),
      }
    end)
    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 8, 0, 13, {}) end)
    local second = util.settled(nv, {})
    assert.deep_equal(second.text, 'Filter: ')
    assert.deep_equal(second.events, {
      { id = 'tag', text = '' },
      { id = 'tag', text = '' },
    })
  end)

  it('detects change when new text has same length as original', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param _ctx morph.Ctx<any, any>
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

    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 4, 0, 5, { 'p' }) end)
    local result = util.settled(nv, {})
    assert.deep_equal(result.text, 'hellp')
    assert.deep_equal(result.events, { { id = 'the-id', text = 'hellp' } })
  end)

  it('detects change when text changes back to original content', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      local rec = util.create_event_recorder 'the-id'
      --- @param _ctx morph.Ctx<any, any>
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

    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 4, 0, 5, {}) end)
    local deleted = util.settled(nv, {})
    assert.deep_equal(deleted.text, 'hell')
    assert.deep_equal(deleted.events, { { id = 'the-id', text = 'hell' } })

    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 4, 0, 4, { 'o' }) end)
    local restored = util.settled(nv, {})
    assert.deep_equal(restored.text, 'hello')
    assert.deep_equal(restored.events, {
      { id = 'the-id', text = 'hell' },
      { id = 'the-id', text = 'hello' },
    })
  end)

  describe('event bubbling', function()
    it('fires handlers from inner to outer, not affecting siblings', function()
      nv:run(function()
        local util = dofile 'spec/util.lua'
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
      nv:run(function() vim.api.nvim_buf_set_text(0, 0, 21, 0, 26, { 'changed' }) end)
      local inner = util.settled(nv, {})
      assert.deep_equal(inner.text, 'sibling outer middle changed')
      assert.deep_equal(#inner.events, 2)
      assert.deep_equal(inner.events[1].id, 'inner')
      assert.deep_equal(inner.events[1].text, 'changed')
      assert.deep_equal(inner.events[2].id, 'outer')
      assert.deep_equal(inner.events[2].text, 'outer middle changed')

      -- Change sibling -> only sibling handler fires
      nv:run(function()
        local util = dofile 'spec/util.lua'
        util.events { clear = true }
        _G.__render()
        vim.api.nvim_buf_set_text(0, 0, 0, 0, 7, { 'modified' })
      end)
      local sibling = util.settled(nv, {})
      assert.deep_equal(sibling.text, 'modified outer middle inner')
      assert.deep_equal(#sibling.events, 1)
      assert.deep_equal(sibling.events[1].id, 'sibling')
      assert.deep_equal(sibling.events[1].text, 'modified')

      -- Change middle (no handler) -> only outer handler fires
      nv:run(function()
        local util = dofile 'spec/util.lua'
        util.events { clear = true }
        _G.__render()
        vim.api.nvim_buf_set_text(0, 0, 14, 0, 20, { 'center' })
      end)
      local middle = util.settled(nv, {})
      assert.deep_equal(middle.text, 'sibling outer center inner')
      assert.deep_equal(#middle.events, 1)
      assert.deep_equal(middle.events[1].id, 'outer')
      assert.deep_equal(middle.events[1].text, 'outer center inner')
    end)

    it('bubbles through multiple nested levels', function()
      nv:run(function()
        local util = dofile 'spec/util.lua'
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

      nv:run(function() vim.api.nvim_buf_set_text(0, 0, 0, 0, 5, { 'changed' }) end)
      local result = util.settled(nv, {})
      assert.deep_equal(#result.events, 3)
      assert.deep_equal(result.events[1].id, 'level3')
      assert.deep_equal(result.events[2].id, 'level2')
      assert.deep_equal(result.events[3].id, 'level1')
    end)

    it('stops bubbling when bubble_up is set to false', function()
      nv:run(function()
        local util = dofile 'spec/util.lua'
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

      nv:run(function() vim.api.nvim_buf_set_text(0, 0, 0, 0, 4, { 'new' }) end)
      local result = util.settled(nv, {})
      assert.deep_equal(#result.events, 1)
      assert.deep_equal(result.events[1].id, 'inner')
    end)
  end)

  it('fires on_change when set_lines inserts content after extmark range', function()
    -- nvim_buf_set_lines at a boundary does NOT expand the extmark's end_row.
    -- This simulates linewise paste ("p" in Normal mode), where the extmark
    -- covers only the original content and the newly inserted lines fall
    -- outside the extmark's range. The guard must still notice the change from
    -- the render-vs-live content diff and fire on_change.
    mount_echo_hole 'asldkfjasdlfjkasdfkj'

    -- Simulate linewise paste: insert a line after the extmark's range.
    nv:run(
      function()
        vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'logName="projects/-----------/logs/---"' })
      end
    )
    local result = util.settled(nv, { ms = 100 })
    -- on_change must receive the full multi-line text
    assert.deep_equal(result.text, 'asldkfjasdlfjkasdfkj\nlogName="projects/-----------/logs/---"')
    assert.deep_equal(
      result.events,
      { { id = 'the-id', text = 'asldkfjasdlfjkasdfkj\nlogName="projects/-----------/logs/---"' } }
    )
  end)

  it('fires on_change when set_lines inserts content before extmark range', function()
    -- nvim_buf_set_lines at row 0 (before the extmark) shifts the extmark
    -- rather than expanding it. The content diff must still detect the change
    -- and fire on_change with the full buffer text including the prepended
    -- content.
    mount_echo_hole 'asldkfjasdlfjkasdfkj'

    -- Prepend a line before the extmark range.
    nv:run(function() vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'prepended' }) end)
    local result = util.settled(nv, { ms = 100 })
    -- on_change must fire with the full buffer including prepended content
    assert.deep_equal(result.text, 'prepended\nasldkfjasdlfjkasdfkj')
    assert.deep_equal(
      result.events,
      { { id = 'the-id', text = 'prepended\nasldkfjasdlfjkasdfkj' } }
    )
  end)

  -- The guard must police USER edits only. A re-render that the app's own
  -- on_change triggered (e.g. a filter count updating) rewrites the buffer
  -- after `changing` is already false, so its TextChanged lands in the guard
  -- with a change position outside every editable span. Treating that as a
  -- violation schedules a full-tree revert render on EVERY keystroke; in a
  -- real app (state landing between renders) that revert races the user's
  -- in-flight typing: chrome flashes readonly, characters are clobbered, and
  -- the region's text diverges from app state.
  it('does not revert when the app re-renders from on_change', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string, count: number }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = '', count = 0 }
          _G.app_state = ctx.state
        end
        local state = _G.assert(ctx.state)
        return {
          'Header\n\n',
          'Filter: [',
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = function(e)
              state.filter = e.text
              state.count = #e.text
              ctx:update(state)
            end,
          }, state.filter),
          '] (',
          h('text', {}, tostring(state.count)),
          ' models)\n\nFooter chrome',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      util.drain(100)
      -- Count guard reverts: each one is a whole-tree re-render racing the
      -- user's typing. Instance-level wrap so the prototype method is
      -- untouched.
      local orig = _G.m._revert_violation
      _G.m._revert_violation = function(...)
        _G.reverts = (_G.reverts or 0) + 1
        return orig(...)
      end
      util.cursor_to_extmark_start(_G.m, 'filter')
      return nil
    end)

    -- Slow typing: one keystroke per drain, each with its own TextChangedI.
    nv:input 'i'
    for _, c in ipairs { 'g', 'l', 'm' } do
      nv:input(c)
      nv:drain(60)
    end

    -- Fast typing: one input call batches the keystrokes in typeahead, so
    -- TextChangedI fires only once for the whole burst.
    nv:input '-5.3'
    nv:drain(150)

    local result = nv:run(function()
      local util = dofile 'spec/util.lua'
      return { text = util.text(0), state = _G.app_state.filter, reverts = _G.reverts or 0 }
    end)

    -- No keystroke -- slow or fast -- may schedule a revert render.
    assert.equal(result.reverts, 0)
    -- And the region must stay in sync with the app state it feeds.
    assert.deep_equal(result.text, 'Header\n\nFilter: [glm-5.3] (7 models)\n\nFooter chrome')
    assert.deep_equal(result.state, 'glm-5.3')
  end)

  -- Deleting the last word of the filter with <C-w> is an edit owned by the
  -- hole, exactly like typing: the deletion starts and ends inside the
  -- editable span, so the guard must accept it, dispatch on_change with the
  -- emptied text, and keep the cursor between the brackets. Treating it as a
  -- violation flashes the locked chrome and restores a pre-edit cursor that
  -- no longer exists in the emptied line, which lands the cursor to the
  -- right of the closing bracket.
  it('accepts <C-w> deleting the last word of the filter at its end', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h

      local rec = util.create_event_recorder 'filter'

      --- @param ctx morph.Ctx<{}, { filter: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { filter = '' } end
        local state = _G.assert(ctx.state)
        return {
          'Search: [',
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = function(e)
              rec(e)
              state.filter = e.text
              ctx:update(state)
            end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      util.drain(100)
      local orig = _G.m._revert_violation
      _G.m._revert_violation = function(...)
        _G.reverts = (_G.reverts or 0) + 1
        return orig(...)
      end
      util.cursor_to_extmark_start(_G.m, 'filter')
      return nil
    end)

    -- Type the filter, then delete its last word with <C-w> while still in
    -- insert mode: the cursor sits at the hole's end, before the locked ']'.
    nv:input 'ifilter'
    local typed = util.settled(nv, { ms = 150, cursor = true })
    assert.deep_equal(typed.text, 'Search: [filter]')
    assert.deep_equal(typed.events, { { id = 'filter', text = 'filter' } })
    assert.deep_equal(typed.cursor, { 1, 15 })

    nv:input '<C-w>'
    local result = nv:run(function()
      local util = dofile 'spec/util.lua'
      util.drain(150)
      return {
        text = util.text(0),
        events = util.events(),
        cursor = vim.api.nvim_win_get_cursor(0),
        reverts = _G.reverts or 0,
      }
    end)

    -- The deletion emptied the hole: no revert, one on_change with '', and
    -- the cursor back between the brackets ([|], not []|).
    assert.equal(result.reverts, 0)
    assert.deep_equal(result.text, 'Search: []')
    assert.deep_equal(result.events, {
      { id = 'filter', text = 'filter' },
      { id = 'filter', text = '' },
    })
    assert.deep_equal(result.cursor, { 1, 9 })
  end)
end)

describe('undo/redo', function()
  --- @type test.Nvim
  local nv

  before_each(function() nv = util.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('tracks extmarks correctly through undo/redo', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
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
    local typed = util.settled(nv, {})
    assert.deep_equal(typed.text, 'Search: [filter]')
    assert.deep_equal(typed.events, { { id = 'filter', text = 'filter' } })

    nv:input '<Esc>u'
    local undone = util.settled(nv, {})
    assert.deep_equal(undone.text, 'Search: []')
    assert.deep_equal(undone.events, {
      { id = 'filter', text = 'filter' },
      { id = 'filter', text = '' },
    })

    nv:input '<C-r>'
    local redone = util.settled(nv, {})
    assert.deep_equal(redone.text, 'Search: [filter]')
    assert.deep_equal(redone.events, {
      { id = 'filter', text = 'filter' },
      { id = 'filter', text = '' },
      { id = 'filter', text = 'filter' },
    })
  end)
end)

describe('spec/util.lua', function()
  --- @type test.Nvim
  local nv

  before_each(function() nv = util.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('covers the full helper API through a child', function()
    nv:run(function()
      local util = dofile 'spec/util.lua'
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

    local cursor = nv:run(function() return vim.api.nvim_win_get_cursor(0) end)
    assert.deep_equal(cursor, { 1, 9 })

    nv:run(function() vim.api.nvim_buf_set_text(0, 0, 9, 0, 10, { 'y' }) end)
    local result = util.settled(nv, { ms = 30 })
    assert.deep_equal(result.text, 'Search: [y]')
    assert.deep_equal(result.events, { { id = 'tag', text = 'y' } })

    local cleared = util.settled(nv, { clear = true }).events
    assert.deep_equal(cleared, { { id = 'tag', text = 'y' } })

    local after_clear = util.settled(nv, {}).events
    assert.deep_equal(after_clear, {})
  end)
end)
