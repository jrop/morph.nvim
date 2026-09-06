--- @diagnostic disable: assign-type-mismatch, global-in-non-module
--- @diagnostic disable: inject-field, missing-fields, need-check-nil, param-type-mismatch, undefined-field

--- Region-aware undo/redo (the undo-probe buffer).
---
--- Runs in a child `nvim --headless --embed` so real input drives real
--- `TextChanged`/`TextChangedI` autocmds and real undo/redo. Every `exec_func`
--- closure is self-contained (`string.dump` drops upvalues); the Morph handle
--- lives in the child global `_G.m`.
local Nvim = require 'morph._test.nvim'

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
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('Filter: ZZZaaa\n[ZZZaaa]', typed)

    -- One `u` must revert the hole edit; the app re-renders the reflection.
    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local both = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('A:[Xaaa] B:[Ybbb]', both)

    nv:input 'u' -- only b's edit reverts
    local first = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('A:[Xaaa] B:[bbb]', first)

    nv:input 'u' -- now a's edit reverts
    local second = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('Filter: Xaaa\n[Xaaa]', typed)

    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('Filter: aaa\n[aaa]', undone)

    nv:input '<C-r>'
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('status: idle tick: 0\nFilter: Xaaa\n[Xaaa]', typed)

    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('X:[abcbase]', typed)

    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local at_floor = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('X:[base]', at_floor)

    -- One edit and undo returns to mount state; a further undo is a no-op.
    nv:input 'iZ<Esc>'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return nil
    end)
    nv:input 'u'
    nv:input 'u'
    nv:input 'u'
    local still_floor = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('X:[\nline twoone]', typed)

    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('X:[one]', undone)

    nv:input '<C-r>'
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      _G.refresh()
      util.drain(150)
      return nil
    end)
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
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      _G.refresh()
      util.drain(150)
      return nil
    end)

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
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      local el = assert(_G.m:get_element_by_id 'r')
      vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] })
      return nil
    end)
    nv:input 'iB<Esc>'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      _G.refresh()
      util.drain(150)
      return nil
    end)

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
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      _G.refresh()
      util.drain(150)
      return nil
    end)

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
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('X:[Zbase]', typed)

    nv:input 'u'
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    local redone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
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
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      local el = assert(_G.m:get_element_by_id 'r')
      vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] })
      return nil
    end)
    nv:input 'iB<Esc>'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      local el = assert(_G.m:get_element_by_id 'r')
      vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] })
      return nil
    end)
    nv:input 'iC<Esc>'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return nil
    end)

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
    local after = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('A:[] (no hole)', after)
  end)

  -- A structural region-set change (hole count differs) rebuilds the probe
  -- from scratch; the replaced probe's buffer must be deleted, or each
  -- structural change orphans another hidden buffer.
  it('deletes the replaced probe buffer when the region set changes', function()
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
    end)

    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      _G.m:render {
        h('text', {}, 'A:['),
        h('text', { id = 'a', readonly = false }, 'aaa'),
        h('text', {}, ']'),
      }
      _G.new_probe_buf = _G.m.probe and _G.m.probe.bufnr or nil
    end)

    local result = nv:exec_func(
      function()
        return {
          old_had_probe = _G.old_probe_buf ~= nil,
          old_deleted = not vim.api.nvim_buf_is_valid(_G.old_probe_buf),
          new_probe = _G.new_probe_buf,
        }
      end
    )
    assert.is_true(result.old_had_probe)
    assert.is_true(result.old_deleted)
    assert.is_not.equals(_G.old_probe_buf, result.new_probe)
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
    local undone = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return util.text(0)
    end)
    assert.are.same('X:[base]', undone)
  end)
end)
