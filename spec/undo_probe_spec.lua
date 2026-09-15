--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

--- Region-aware undo/redo (the undo-probe buffer).
---
--- Runs in a child `nvim --headless --embed` so real input drives real
--- `TextChanged`/`TextChangedI` autocmds and real undo/redo. Every `exec_func`
--- closure is self-contained (`string.dump` drops upvalues); the Morph handle
--- lives in the child global `_G.m`.
local Nvim = require 'morph._test.nvim'

--- Drain scheduled re-renders and return the buffer text: the read-after-
--- action most tests end with. The exec_func closure stays self-contained.
--- @param nv morph._test.Nvim
--- @return string
local function settled_text(nv)
  return nv:exec_func(function()
    local util = require 'morph._test.util'
    util.drain(150)
    return util.text(0)
  end)
end

--- Drain scheduled re-renders when a test only needs the flush, not a value.
--- @param nv morph._test.Nvim
local function drain(nv)
  nv:exec_func(function()
    local util = require 'morph._test.util'
    util.drain(150)
  end)
end

--- Drain the edit's echo re-render, run the app's chrome refresh, drain that.
--- The exec_func closure stays self-contained (no upvalues).
--- @param nv morph._test.Nvim
local function drain_refresh(nv)
  nv:exec_func(function()
    local util = require 'morph._test.util'
    util.drain(150)
    _G.refresh()
    util.drain(150)
  end)
end

--- Move the child's cursor to the region named `r` (element-lookup variant).
--- @param nv morph._test.Nvim
local function cursor_to_r(nv)
  nv:exec_func(function()
    local util = require 'morph._test.util'
    util.drain(150)
    local el = assert(_G.m:get_element_by_id 'r')
    vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] })
  end)
end

describe('region-aware undo', function()
  local nv

  before_each(function() nv = Nvim.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  -- Tracer bullet: the core win. A controlled hole's `on_change` updates app
  -- state, so the app re-renders chrome that embeds the hole text (the lsof
  -- heading shape). One `u` must revert the hole edit and the app's rendered
  -- reflection together, rather than landing on the app's render entry.
  it('undoes a hole edit together with the app render it caused', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { filter = 'aaa' } end
        local state = assert(ctx.state)
        return {
          'Filter: ',
          h('text', { hl = 'Comment' }, state.filter), -- chrome embeds the hole text
          '\n[',
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = function(e)
              util.create_event_recorder 'filter'
              ctx:update { filter = e.text }
            end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
    end)

    local before = nv:exec_func(function()
      local util = require 'morph._test.util'
      return util.text(0)
    end)
    assert.are.same('Filter: aaa\n[aaa]', before)

    -- Type into the hole; the app re-renders the heading reflection.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local el = assert(_G.m:get_element_by_id 'filter')
      vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] })
      util.drain(50)
    end)
    nv:input 'iZZZ<Esc>'
    local typed = settled_text(nv)
    assert.are.same('Filter: ZZZaaa\n[ZZZaaa]', typed)

    -- One `u` must revert the hole edit; the app re-renders the reflection.
    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('Filter: aaa\n[aaa]', undone)
  end)

  -- Region awareness means a traversal steps through edits in the order they
  -- happened, regardless of which region they touched: undo must revert only
  -- the most recent edit, and only the next undo may touch an earlier region.
  it('undoes edits in order across two regions', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'A:['),
        h('text', { id = 'a', readonly = false }, 'aaa'),
        h('text', {}, '] B:['),
        h('text', { id = 'b', readonly = false }, 'bbb'),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'a')
    end)

    nv:input 'iX<Esc>' -- edit region a -> A:[Xaaa]
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      util.cursor_to_extmark_start(_G.m, 'b')
      return nil
    end)
    nv:input 'iY<Esc>' -- edit region b -> B:[Ybbb]
    local both = settled_text(nv)
    assert.are.same('A:[Xaaa] B:[Ybbb]', both)

    nv:input 'u' -- only b's edit reverts
    local first = settled_text(nv)
    assert.are.same('A:[Xaaa] B:[bbb]', first)

    nv:input 'u' -- now a's edit reverts
    local second = settled_text(nv)
    assert.are.same('A:[aaa] B:[bbb]', second)
  end)

  -- Redo must replay the undone edit, and the region-scoped story only holds
  -- if redo also restores the app's rendered reflection of the region text.
  it('redoes an undone edit across regions', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { filter = 'aaa' } end
        local state = assert(ctx.state)
        return {
          'Filter: ',
          h('text', { hl = 'Comment' }, state.filter),
          '\n[',
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = function(e) ctx:update { filter = e.text } end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      util.cursor_to_extmark_start(_G.m, 'filter')
    end)

    nv:input 'iX<Esc>'
    local typed = settled_text(nv)
    assert.are.same('Filter: Xaaa\n[Xaaa]', typed)

    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('Filter: aaa\n[aaa]', undone)

    nv:input '<C-r>'
    local redone = settled_text(nv)
    assert.are.same('Filter: Xaaa\n[Xaaa]', redone)
  end)

  -- The headline win. An app refresh (a timer, async data) renders chrome
  -- between `u` and `<C-r>`. In the main buffer that render writes the tip and
  -- abandons the undone branch, silently killing redo; the probe never sees
  -- that render, so its redo tip survives and `<C-r>` still restores the edit.
  it('redoes after an app chrome render lands between undo and redo', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      -- The app holds a `status`/`tick` the user never edits. `_G.refresh`
      -- drives a chrome-only re-render through the real ctx:update path, the
      -- way a timer or async data would.
      --- @param ctx morph.Ctx<{}, { filter: string, status: string, tick: integer }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = 'aaa', status = 'idle', tick = 0 }
          _G.app_ctx = ctx
        end
        local state = assert(ctx.state)
        return {
          'status: ',
          h('text', {}, state.status),
          ' tick: ',
          h('text', {}, tostring(state.tick)),
          '\n',
          'Filter: ',
          h('text', { hl = 'Comment' }, state.filter),
          '\n[',
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = function(e)
              ctx:update { filter = e.text, status = state.status, tick = state.tick }
            end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      -- Chrome-only refresh: update non-edited state, keep the region text.
      _G.refresh = function()
        local state = assert(_G.app_ctx.state)
        _G.app_ctx:update { filter = state.filter, status = 'working', tick = state.tick + 1 }
      end
      util.cursor_to_extmark_start(_G.m, 'filter')
    end)

    nv:input 'iX<Esc>'
    local typed = settled_text(nv)
    assert.are.same('status: idle tick: 0\nFilter: Xaaa\n[Xaaa]', typed)

    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('status: idle tick: 0\nFilter: aaa\n[aaa]', undone)

    -- The async app refresh lands here, straight onto the main buffer's tree.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      _G.refresh()
      util.drain(150)
      return nil
    end)
    local refreshed = nv:exec_func(function()
      local util = require 'morph._test.util'
      return util.text(0)
    end)
    assert.are.same('status: working tick: 1\nFilter: aaa\n[aaa]', refreshed)

    nv:input '<C-r>'
    local redone = settled_text(nv)
    -- The region edit is restored, and the app's refresh of non-region chrome
    -- survives it (the probe never touched that chrome).
    assert.are.same('status: working tick: 1\nFilter: Xaaa\n[Xaaa]', redone)
  end)

  -- Native granularity. A single insert session is one user-perceived edit, so
  -- it must be one undo step, not one per character. The probe inherits this
  -- from Neovim's own undo coalescing rather than reimplementing it.
  it('treats one insert session as a single undo step', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'X:['),
        h('text', { id = 'r', readonly = false }, 'base'),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    nv:input 'iabc<Esc>'
    local typed = settled_text(nv)
    assert.are.same('X:[abcbase]', typed)

    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('X:[base]', undone)
  end)

  -- The floor is mount state, not empty. Pressing `u` with no user edits yet
  -- (or after all edits are undone) must stop at the mounted region text; it
  -- must never sail out to an empty buffer.
  it('stops undo at the mount state instead of emptying regions', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'X:['),
        h('text', { id = 'r', readonly = false }, 'base'),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    -- Undo with nothing to undo: the region must survive untouched.
    nv:input 'u'
    local at_floor = settled_text(nv)
    assert.are.same('X:[base]', at_floor)

    -- One edit and undo returns to mount state; a further undo is a no-op.
    nv:input 'iZ<Esc>'
    drain(nv)
    nv:input 'u'
    nv:input 'u'
    nv:input 'u'
    local still_floor = settled_text(nv)
    assert.are.same('X:[base]', still_floor)
  end)

  -- A region may contain multiple lines, and an edit can add or remove them.
  -- Undo/redo must carry the line structure across, not just a single line.
  it('undoes a multiline edit inside a region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'X:['),
        h('text', { id = 'r', readonly = false }, 'one'),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    -- Insert a newline inside the region: the region becomes two lines.
    nv:input 'i<CR>line two<Esc>'
    local typed = settled_text(nv)
    assert.are.same('X:[\nline twoone]', typed)

    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('X:[one]', undone)

    nv:input '<C-r>'
    local redone = settled_text(nv)
    assert.are.same('X:[\nline twoone]', redone)
  end)

  -- Enabling the probe must not weaken the locked-chrome guard: editing
  -- outside every editable region is still a violation, still reverted, and
  -- still leaves the app's on_change unfired.
  it('still reverts an edit to locked chrome while the probe is active', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'locked' }, 'Name'),
        ': [',
        h('text', {
          id = 'hole',
          readonly = false,
          on_change = util.create_event_recorder 'hole',
        }, 'editable'),
        ']',
      }
      -- Cursor inside the locked 'Name' span.
      vim.api.nvim_win_set_cursor(0, { 1, 2 })
    end)

    nv:input 'iX<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Name: [editable]', result.text)
    assert.are.same({}, result.events)
  end)

  -- The ex-command forms of traversal must route through the probe too. They
  -- cannot be shadowed as user commands, so they are parsed and redirected at
  -- the command line. A chrome refresh lands after the edit, so native undo
  -- (which would pop the refresh) and probe undo (which pops the region edit)
  -- produce different results; this asserts the probe path wins.
  it('routes the :undo ex-command through the probe', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string, status: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = 'base', status = 'idle' }
          _G.app_ctx = ctx
        end
        local state = assert(ctx.state)
        return {
          'status: ',
          h('text', {}, state.status),
          '\nX:[',
          h('text', {
            id = 'r',
            readonly = false,
            on_change = function(e) ctx:update { filter = e.text, status = state.status } end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      _G.refresh = function()
        local state = assert(_G.app_ctx.state)
        _G.app_ctx:update { filter = state.filter, status = 'working' }
      end
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    nv:input 'iZ<Esc>'
    drain_refresh(nv)
    local refreshed = nv:exec_func(function()
      local util = require 'morph._test.util'
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[Zbase]', refreshed)

    nv:input ':undo<CR>'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[base]', undone)
  end)

  -- Unmount deletes the ex-command interception autocmd, so a remount must
  -- re-arm it: without that, `:undo` after remount falls through to native
  -- traversal and reverts chrome renders instead of region edits.
  it('reinstalls ex-command interception after remount', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string, status: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = 'base', status = 'idle' }
          _G.app_ctx = ctx
        end
        local state = assert(ctx.state)
        return {
          'status: ',
          h('text', {}, state.status),
          '\nX:[',
          h('text', {
            id = 'r',
            readonly = false,
            on_change = function(e) ctx:update { filter = e.text, status = state.status } end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      -- Remount on the same instance: new() is not called again, so whatever
      -- interception it installed must be re-established by the mount path.
      _G.m:unmount()
      _G.m:mount(h(App), { debounce_ms = 0 })
      _G.refresh = function()
        local state = assert(_G.app_ctx.state)
        _G.app_ctx:update { filter = state.filter, status = 'working' }
      end
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    nv:input 'iZ<Esc>'
    drain_refresh(nv)

    -- Probe replay: the region reverts, the chrome keeps its refreshed status.
    -- Native undo would revert the chrome render instead, leaving the region
    -- edited and the status stale.
    nv:input ':undo<CR>'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[base]', undone)

    -- Redo must also route through the probe within the remounted session
    -- (history is reset across remounts, but not across an undo/redo pair).
    nv:input '<C-r>'
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[Zbase]', redone)
  end)

  -- `:earlier N` and `:later N` carry a step count, and must step the probe
  -- that many entries in the requested direction. A chrome refresh lands after
  -- the edits, so native undo's step count includes it and lands on a render,
  -- while the probe's count includes only the two region edits.
  it('routes :earlier and :later counts through the probe', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string, status: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = 'base', status = 'idle' }
          _G.app_ctx = ctx
        end
        local state = assert(ctx.state)
        return {
          'status: ',
          h('text', {}, state.status),
          '\nX:[',
          h('text', {
            id = 'r',
            readonly = false,
            on_change = function(e) ctx:update { filter = e.text, status = state.status } end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      _G.refresh = function()
        local state = assert(_G.app_ctx.state)
        _G.app_ctx:update { filter = state.filter, status = 'working' }
      end
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    -- Two separate edit sessions, so two probe entries.
    nv:input 'iA<Esc>'
    cursor_to_r(nv)
    nv:input 'iB<Esc>'
    drain_refresh(nv)

    nv:input ':earlier 2<CR>'
    local back = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[base]', back)

    nv:input ':later 2<CR>'
    local forward = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[BAbase]', forward)
  end)

  -- `g-` and `g+` traverse the tree by one entry, like `u` and `<C-r>`. They
  -- must route through the probe too, so a chrome refresh between them does not
  -- consume the step.
  it('routes g- and g+ through the probe', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string, status: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = 'base', status = 'idle' }
          _G.app_ctx = ctx
        end
        local state = assert(ctx.state)
        return {
          'status: ',
          h('text', {}, state.status),
          '\nX:[',
          h('text', {
            id = 'r',
            readonly = false,
            on_change = function(e) ctx:update { filter = e.text, status = state.status } end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      _G.refresh = function()
        local state = assert(_G.app_ctx.state)
        _G.app_ctx:update { filter = state.filter, status = 'working' }
      end
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    nv:input 'iZ<Esc>'
    drain_refresh(nv)

    nv:input 'g-'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[base]', undone)

    nv:input 'g+'
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: working\nX:[Zbase]', redone)
  end)

  -- The probe is the default undo mode, not something that requires the
  -- renderer-level `readonly = true`. A single explicit hole (`readonly =
  -- false`) is enough to engage region-scoped undo, so an app that only marks
  -- its editable fields gets region undo without opting into a locked render.
  it('engages region undo for an explicit hole without a locked renderer', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      -- No `{ readonly = true }`: only the hole is declared editable.
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'X:[',
        h('text', { id = 'r', readonly = false }, 'base'),
        ']',
      }
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    local engaged = nv:exec_func(function() return _G.m.probe ~= nil end)
    assert.is_true(engaged)

    nv:input 'iZ<Esc>'
    local typed = settled_text(nv)
    assert.are.same('X:[Zbase]', typed)

    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('X:[base]', undone)
  end)

  -- The probe governs by resolution, not declaration: any resolved-editable
  -- tag is a region, so even a render of plain text with no declared holes
  -- gets region-scoped undo instead of native undo.
  it('engages region undo for a render with no declared holes', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render { 'just chrome, no holes' }
    end)
    local engaged = nv:exec_func(function() return _G.m.probe ~= nil end)
    assert.is_true(engaged)

    nv:input 'iZ<Esc>'
    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('just chrome, no holes', undone)
  end)

  -- Nested editable tags are regions of their own. An undo entry snapshots
  -- the whole region set in one pass, and an outer region's text embeds its
  -- inner regions' text, so replay restores both consistently without any
  -- maximality or nesting bookkeeping.
  it('treats nested editable tags as regions of their own', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'r', readonly = false }, {
          h('text', {
            id = 'inner',
            readonly = false,
            on_change = util.create_event_recorder 'inner',
          }, 'ab'),
          'c',
        }),
      }
      util.cursor_to_extmark_start(_G.m, 'inner')
    end)

    nv:input 'iZ<Esc>'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      -- Drop the typing event so the assertion below sees replay events only.
      util.events { clear = true }
      return nil
    end)

    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events { clear = true } }
    end)
    assert.are.same('abc', undone.text)
    assert.are.same({ { id = 'inner', text = 'ab' } }, undone.events)

    -- A second traversal must be as clean as the first: the redo rewrites the
    -- inner region, and the containing region's snapshot already matches the
    -- restored buffer, so its write must be skipped rather than drag the
    -- inner region's marks.
    nv:input '<C-r>'
    local redone = settled_text(nv)
    assert.are.same('Zabc', redone)
  end)

  -- The probe buffer is per-mount state. Unmounting must delete it, or every
  -- mount/unmount cycle leaks a hidden buffer plus its undo tree.
  it('deletes the probe buffer on unmount', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      --- @param _ctx morph.Ctx
      local function App(_ctx)
        return {
          'X:[',
          h('text', { id = 'r', readonly = false }, 'base'),
          ']',
        }
      end
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      _G.probe_bufnr = _G.m.probe.bufnr
      return nil
    end)

    local valid = nv:exec_func(function()
      if not _G.probe_bufnr then error 'probe buffer was never created' end
      _G.m:unmount()
      return vim.api.nvim_buf_is_valid(_G.probe_bufnr)
    end)
    assert.is_false(valid)
  end)

  -- `:undo N` addresses an absolute undo state, not N steps. With three edits
  -- and one chrome refresh in the main tree, a relative reading would land
  -- wrong; this asserts the probe jumps straight to state 2 (the middle edit).
  it('treats :undo N as an absolute state jump', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      --- @param ctx morph.Ctx<{}, { filter: string, status: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { filter = 'base', status = 'idle' }
          _G.app_ctx = ctx
        end
        local state = assert(ctx.state)
        return {
          'status: ',
          h('text', {}, state.status),
          '\nX:[',
          h('text', {
            id = 'r',
            readonly = false,
            on_change = function(e) ctx:update { filter = e.text, status = state.status } end,
          }, state.filter),
          ']',
        }
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      _G.refresh = function()
        local state = assert(_G.app_ctx.state)
        _G.app_ctx:update { filter = state.filter, status = 'working' }
      end
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    -- Three separate region-edit sessions: probe entries 2, 3 and 4.
    nv:input 'iA<Esc>'
    cursor_to_r(nv)
    nv:input 'iB<Esc>'
    cursor_to_r(nv)
    nv:input 'iC<Esc>'
    drain(nv)

    -- State 2 is baseline + first edit, i.e. 'Abase'.
    nv:input ':undo 2<CR>'
    local at_two = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('status: idle\nX:[Abase]', at_two)
  end)

  -- The probe's mappings are buffer-local, so a buffer with no Morph keeps
  -- Neovim's native undo for `u` and `g-`/`g+` untouched.
  it('leaves native undo alone in a buffer with no morph instance', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local bufnr = util.scratch_buf { focus = true, lines = { 'base' } }
      vim.api.nvim_buf_call(bufnr, function() vim.cmd 'let &undolevels = &undolevels' end)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'one' })
      vim.api.nvim_buf_call(bufnr, function() vim.cmd 'let &undolevels = &undolevels' end)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'two' })
      vim.api.nvim_buf_call(bufnr, function() vim.cmd 'let &undolevels = &undolevels' end)
      return nil
    end)

    nv:input 'u'
    local after_u = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return util.text(0)
    end)
    assert.are.same('one', after_u)

    nv:input 'g-'
    local after_gminus = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return util.text(0)
    end)
    assert.are.same('base', after_gminus)
  end)

  -- A re-render may drop an editable region entirely (a conditional field
  -- disappears). The probe must disengage cleanly rather than leave a stale
  -- slot mapping or crash on the next traversal.
  it('disengages cleanly when a re-render removes the editable region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'A:['),
        h('text', { id = 'a', readonly = false }, 'aaa'),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'a')
    end)

    nv:input 'iZ<Esc>'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      -- Capture the probe buffer id while it exists, so the teardown
      -- assertion below can check the buffer was really deleted.
      _G.probe_buf = _G.m.probe and _G.m.probe.bufnr or nil
      return nil
    end)
    local edited = nv:exec_func(function()
      local util = require 'morph._test.util'
      return util.text(0)
    end)
    assert.are.same('A:[Zaaa]', edited)

    -- Re-render without the hole: the probe is torn down.
    local engaged = nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      _G.m:render { h('text', {}, 'A:[] (no hole)') }
      return _G.m.probe ~= nil
    end)
    assert.is_false(engaged)

    -- Dropping the probe must delete its buffer: the disengage path runs on
    -- every render that loses its holes, and an orphaned hidden buffer (with
    -- its undo tree) would leak one per render.
    local deleted = nv:exec_func(function() return not vim.api.nvim_buf_is_valid(_G.probe_buf) end)
    assert.is_true(deleted)

    -- Traversal after the removal is a harmless no-op, not a crash.
    nv:input 'u'
    local after = settled_text(nv)
    assert.are.same('A:[] (no hole)', after)
  end)

  -- Removing a region is no longer a rebuild trigger: probe entries are keyed
  -- by region id, so the removed region's history simply goes inert -- replay
  -- only ever touches regions present in the current render -- and survivors
  -- keep theirs. The probe buffer must therefore survive the shrink (a
  -- rebuild would wipe survivor history and orphan another hidden buffer),
  -- and an edit recorded before the removal must stay undoable afterwards.
  it('keeps the probe when the region set shrinks, so survivors keep history', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'A:['),
        h('text', { id = 'a', readonly = false }, 'aaa'),
        h('text', { id = 'b', readonly = false }, 'bbb'),
        h('text', {}, ']'),
      }
      _G.old_probe_buf = _G.m.probe and _G.m.probe.bufnr or nil
      util.cursor_to_extmark_start(_G.m, 'a')
    end)

    -- One accepted edit on a gives the probe history above its baseline.
    nv:input 'iX<Esc>'
    drain(nv)

    -- Shrink the set: b is gone, a survives under the same declared id.
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      _G.m:render {
        h('text', {}, 'A:['),
        h('text', { id = 'a', readonly = false }, 'Xaaa'),
        h('text', {}, ']'),
      }
      _G.new_probe_buf = _G.m.probe and _G.m.probe.bufnr or nil
      return nil
    end)

    local kept = nv:exec_func(
      function() return _G.new_probe_buf ~= nil and _G.new_probe_buf == _G.old_probe_buf end
    )
    assert.is_true(kept)

    -- The pre-shrink edit is still undoable: it belongs to a, which survived.
    nv:input 'u'
    local after = settled_text(nv)
    assert.are.same('A:[aaa]', after)
  end)

  -- A render that swaps in a DIFFERENT set of regions with the SAME count
  -- keeps the existing probe (only the count is checked) and re-points its
  -- tags. Probe entries map to regions by index, so the history recorded
  -- under a,b now hangs off c,d: the first traversal would write a's text
  -- into c's span and b's into d's. Traversal must not reach across a
  -- region swap: regions that did not exist in the recorded history keep
  -- their rendered text.
  it('does not replay swapped-out region text into swapped-in regions', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'A:['),
        h('text', { id = 'a', readonly = false }, 'aaa'),
        h('text', {}, '] B:['),
        h('text', { id = 'b', readonly = false }, 'bbb'),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'a')
    end)

    -- One accepted edit gives the probe history above its baseline.
    nv:input 'iX<Esc>'
    settled_text(nv)

    -- Re-render with the same number of editable regions but different
    -- ones (a,b -> c,d); the probe is kept and only its tags are re-pointed.
    local swapped = nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m:render {
        h('text', {}, 'C:['),
        h('text', { id = 'c', readonly = false }, 'ccc'),
        h('text', {}, '] D:['),
        h('text', { id = 'd', readonly = false }, 'ddd'),
        h('text', {}, ']'),
      }
      return util.text(0)
    end)
    assert.are.same('C:[ccc] D:[ddd]', swapped)

    -- Undo must have nothing to say about regions that never existed in its
    -- recorded history: c must not inherit a's text, d must not inherit b's.
    nv:input 'u'
    local after = settled_text(nv)
    assert.are.same('C:[ccc] D:[ddd]', after)
  end)

  -- A prepend grows the region set while shifting every survivor's position
  -- (a "newest first" list). Positional history cannot see the shift: an
  -- entry recorded under the old order replays onto whichever regions now
  -- occupy those indexes, so the first `u` after the prepend writes stale
  -- texts into unrelated spans. With no declared ids the shift is genuinely
  -- ambiguous -- an unkeyed render that prepended is indistinguishable, after
  -- the fact, from one that edited in place -- so the contract is: undo must
  -- only ever write a region it can positively identify, and degrade to a
  -- no-op rather than a cross-write.
  it('makes undo a no-op, not a cross-write, when an unkeyed render prepends', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { items = { 'one', 'two' } }
          _G.add_top = function()
            local items = vim.deepcopy(ctx.state.items)
            table.insert(items, 1, 'new' .. (#items + 1))
            ctx:update { items = items }
          end
        end
        local state = assert(ctx.state)
        local out = {}
        for i, item in ipairs(state.items) do
          out[#out + 1] = h('text', {
            readonly = false,
            on_change = function(e)
              local items = vim.deepcopy(state.items)
              items[i] = e.text
              ctx:update { items = items }
            end,
          }, item)
          out[#out + 1] = '\n'
        end
        return out
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      -- No declared ids to steer by: the first region starts the first line.
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end)

    -- One accepted edit on the FIRST region.
    nv:input 'iX<Esc>'
    drain(nv)

    -- Prepend a new item: the set grows 2 -> 3, every survivor shifts down.
    nv:exec_func(function() _G.add_top() end)
    local grown = settled_text(nv)
    assert.are.same('new3\nXone\ntwo\n', grown)

    -- Undo with NO edits since the add: nothing in the current region set can
    -- be identified with the recorded history, so this must be a no-op --
    -- every region keeps the text it rendered with, typed text included.
    nv:input 'u'
    local after = settled_text(nv)
    assert.are.same('new3\nXone\ntwo\n', after)
  end)

  -- Declared ids are the app's authority channel: when they name items (not
  -- positions), the prepend ambiguity disappears, and history must follow the
  -- items -- the edit recorded before the prepend stays undoable, reverting
  -- the very item it was made on, while the prepended region enters with no
  -- history of its own.
  it('keeps region history across a prepend when regions declare ids', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      local function App(ctx)
        if ctx.phase == 'mount' then
          -- Items carry a uid minted at creation: the id must survive text
          -- edits (it names the item, not its content) and appends.
          ctx.state = { items = { { uid = 'i1', text = 'one' }, { uid = 'i2', text = 'two' } } }
          _G.add_top = function()
            local items = vim.deepcopy(ctx.state.items)
            local n = #items + 1
            table.insert(items, 1, { uid = 'i' .. n, text = 'new' .. n })
            ctx:update { items = items }
          end
        end
        local state = assert(ctx.state)
        local out = {}
        for i, item in ipairs(state.items) do
          out[#out + 1] = h('text', {
            -- The id derives from the item's uid -- never the index (inserts
            -- shift it) and never the text (editing it would change the id
            -- mid-history, the contract violation the memo documents).
            id = 'item-' .. item.uid,
            readonly = false,
            on_change = function(e)
              local items = vim.deepcopy(state.items)
              items[i].text = e.text
              ctx:update { items = items }
            end,
          }, item.text)
          out[#out + 1] = '\n'
        end
        return out
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      util.cursor_to_extmark_start(_G.m, 'item-i1')
    end)

    -- One accepted edit on item "one".
    nv:input 'iX<Esc>'
    drain(nv)

    -- Prepend "new3": one and two keep their ids, new3 has none.
    nv:exec_func(function() _G.add_top() end)
    local grown = settled_text(nv)
    assert.are.same('new3\nXone\ntwo\n', grown)

    -- Undo reverts the pre-prepend edit on the item it was made on.
    nv:input 'u'
    local after = settled_text(nv)
    assert.are.same('new3\none\ntwo\n', after)
  end)

  -- The probe's headline promise: history attaches to ITEMS, not positions.
  -- A keyed list re-ordered by chrome keeps every item's id across the
  -- reorder -- the reconciler matches old and new tags by key, the stamp
  -- (a hex sequence id copied along matches) hands the probe the identity,
  -- and replay writes per id -- so `u`
  -- reverts the most recent text edit on the item it was made on, wherever
  -- the item now sits, and the reordered layout stays put. The reorder
  -- itself consumes no undo step: it is chrome, not a region edit, so
  -- undoing the ORDER is the app's own state-undo job. (This requires the
  -- list to be keyed or id-declared; an unkeyed reorder is the documented
  -- safe-reset case. Key-only identity is used here on purpose: declared
  -- ids are trusted blindly, so only the stamp proves the hook works.)
  it('keeps item history across a keyed reorder', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = {
            items = {
              { uid = 'i1', text = 'one' },
              { uid = 'i2', text = 'two' },
              { uid = 'i3', text = 'three' },
            },
          }
          -- Chrome stand-in: move the item at `pos` up one slot.
          _G.move_up = function(pos)
            local items = vim.deepcopy(ctx.state.items)
            items[pos - 1], items[pos] = items[pos], items[pos - 1]
            ctx:update { items = items }
          end
        end
        local state = assert(ctx.state)
        local out = {}
        for i, item in ipairs(state.items) do
          out[#out + 1] = h('text', {
            key = item.uid,
            readonly = false,
            on_change = function(e)
              local items = vim.deepcopy(state.items)
              items[i].text = e.text
              ctx:update { items = items }
            end,
          }, item.text)
          out[#out + 1] = '\n'
        end
        return out
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
      -- No declared ids to steer by: item #2 starts on the second line.
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
    end)

    -- Edit item #2, then chrome-moves it above #1: #2, #1, #3.
    nv:input 'iX<Esc>'
    drain(nv)
    nv:exec_func(function() _G.move_up(2) end)
    local moved = settled_text(nv)
    assert.are.same('Xtwo\none\nthree\n', moved)

    -- Edit item #1 at its NEW position: an edit made after the reorder, on a
    -- region whose position the reorder changed.
    nv:exec_func(function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      return nil
    end)
    nv:input 'iY<Esc>'
    local edited = settled_text(nv)
    assert.are.same('Xtwo\nYone\nthree\n', edited)

    -- Undo walks back through BOTH edits, each landing on its own item:
    -- first the #1 edit (recorded after the reorder, on line two), then the
    -- #2 edit (recorded before it, now on line one).
    nv:input 'u'
    local first = settled_text(nv)
    assert.are.same('Xtwo\none\nthree\n', first)

    nv:input 'u'
    local second = settled_text(nv)
    assert.are.same('two\none\nthree\n', second)

    -- Redo walks forward again, landing each text back on its item.
    nv:input '<C-r>'
    local redone = settled_text(nv)
    assert.are.same('Xtwo\none\nthree\n', redone)

    nv:input '<C-r>'
    local redone_again = settled_text(nv)
    assert.are.same('Xtwo\nYone\nthree\n', redone_again)
  end)

  -- A render that GROWS the region set (an Add button) must keep the probe's
  -- history: the pre-add edits stay undoable, the new regions undo to their
  -- birth text, and the add itself consumes no undo step. The app is a
  -- controlled-input list: every hole echoes into state, so the re-render
  -- after the add preserves the typed text.
  it('undoes edits from before the region set grew', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h

      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { items = { 'one', 'two' } }
          _G.add_item = function()
            local items = vim.deepcopy(ctx.state.items)
            table.insert(items, 'item' .. (#items + 1))
            ctx:update { items = items }
          end
        end
        local state = assert(ctx.state)
        local out = {}
        for i, item in ipairs(state.items) do
          out[#out + 1] = h('text', {
            id = 'item-' .. i,
            readonly = false,
            on_change = function(e)
              local items = vim.deepcopy(state.items)
              items[i] = e.text
              ctx:update { items = items }
            end,
          }, item)
          out[#out + 1] = '\n'
        end
        return out
      end

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount(h(App), { debounce_ms = 0 })
    end)

    -- Edit item 1, then item 2: two probe entries above the baseline.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.cursor_to_extmark_start(_G.m, 'item-1')
      return nil
    end)
    nv:input 'iX<Esc>'
    drain(nv)

    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.cursor_to_extmark_start(_G.m, 'item-2')
      return nil
    end)
    nv:input 'iY<Esc>'
    drain(nv)

    -- The add grows the set; the re-render preserves the typed edits.
    nv:exec_func(function() _G.add_item() end)
    nv:exec_func(function() _G.add_item() end)
    local grown = settled_text(nv)
    assert.are.same('Xone\nYtwo\nitem3\nitem4\n', grown)

    -- Edit one of the NEW regions.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.cursor_to_extmark_start(_G.m, 'item-3')
      return nil
    end)
    nv:input 'iZ<Esc>'
    drain(nv)

    nv:input 'u' -- reverts item-3's edit
    local first = settled_text(nv)
    assert.are.same('Xone\nYtwo\nitem3\nitem4\n', first)

    nv:input 'u' -- reverts item-2's edit (recorded before the add)
    local second = settled_text(nv)
    assert.are.same('Xone\ntwo\nitem3\nitem4\n', second)

    nv:input 'u' -- reverts item-1's edit
    local third = settled_text(nv)
    assert.are.same('one\ntwo\nitem3\nitem4\n', third)
  end)

  -- A hole declared inside a component must engage the probe even in an
  -- unlocked render. The probe keys off explicit `readonly = false`
  -- declarations, wherever they appear in the tree, not off renderer-level
  -- locking.
  it('engages region undo for a hole nested in a component', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      --- @param _ctx morph.Ctx
      local function Field(_ctx) return h('text', { id = 'r', readonly = false }, 'base') end
      -- No renderer-level readonly: only the nested hole makes a region.
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:mount { 'X:[', h(Field), ']' }
      util.cursor_to_extmark_start(_G.m, 'r')
    end)

    local engaged = nv:exec_func(function() return _G.m.probe ~= nil end)
    assert.is_true(engaged)

    nv:input 'iZ<Esc>'
    nv:input 'u'
    local undone = settled_text(nv)
    assert.are.same('X:[base]', undone)
  end)
end)
