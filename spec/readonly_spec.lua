--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: duplicate-require
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

local Nvim = require 'morph._test.nvim'
local util = require 'morph._test.util'

describe('readonly regions', function()
  --- @type morph._test.Nvim
  local nv

  before_each(function() nv = Nvim.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  -- Tracer bullet: one behavior, one test. A programmatic edit inside a
  -- readonly region is reverted; its on_change never fires.
  it('reverts a programmatic edit inside a readonly region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Name: [',
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h('text', { id = 'field', on_change = util.create_event_recorder 'field' }, '36'),
        ']',
      }
    end)

    nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 7, 0, 10, { 'XXX' }) end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Name: [Ada] Age: [36]', result.text)
    assert.are.same({}, result.events)
  end)

  it('accepts an insert claimed by two multi-line editable spans (rank tie)', function()
    -- Regression: the settle phase's winner tie-break compares span sizes,
    -- and size_of read math.maxinteger -- nil under LuaJIT -- for multi-line
    -- spans, so any two same-rank claimants crashed the guard mid-keystroke.
    -- Two nested editable tags share their start, so an insert there makes
    -- both rank-2 claimants.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        h('text', { id = 'outer', on_change = util.create_event_recorder 'outer' }, {
          h(
            'text',
            { id = 'inner', on_change = util.create_event_recorder 'inner' },
            'alpha\nbeta'
          ),
          '\ngamma',
        }),
      }
    end)

    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      vim.api.nvim_buf_set_text(0, 0, 0, 0, 0, { 'X' })
      -- pcall guards the guard: pre-fix, the nil size crashed it here.
      local ok, err = pcall(function() vim.cmd.doautocmd 'TextChanged' end)
      util.drain(100)
      return { ok = ok, err = tostring(err), text = util.text(0), events = util.events() }
    end)
    assert.is_true(result.ok)
    assert.are.equal('nil', result.err)
    assert.are.equal('Xalpha\nbeta\ngamma', result.text)
    assert.is_true(#result.events > 0)
  end)

  it('reverts a typed edit inside a readonly region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Name: [',
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h('text', { id = 'field', on_change = util.create_event_recorder 'field' }, '36'),
        ']',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- cursor strictly inside 'Ada'
    end)

    nv:input 'iX<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Name: [Ada] Age: [36]', result.text)
    assert.are.same({}, result.events)
  end)

  it('restores the readonly text after dd of its line', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Name: [',
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h('text', { id = 'field', on_change = util.create_event_recorder 'field' }, '36'),
        ']',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end)

    nv:input 'dd'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events() }
    end)
    assert.truthy(string.find(result.text, 'Ada', 1, true) ~= nil)
  end)

  it(
    'reverts edits inside a readonly child without firing the editable parent on_change',
    function()
      nv:exec_func(function()
        local util = require 'morph._test.util'
        local Morph = require 'morph'
        local h = Morph.h
        _G.m = Morph.new(util.scratch_buf { focus = true })
        _G.m:render {
          h('text', { id = 'parent', on_change = util.create_event_recorder 'parent' }, {
            'outer ',
            h('text', { id = 'child', readonly = true }, 'inner'),
          }),
        }
      end)

      -- 'outer inner': child span is cols 6..11
      nv:exec_func(function() vim.api.nvim_buf_set_text(0, 0, 6, 0, 11, { 'XXXXX' }) end)
      local result = nv:exec_func(function()
        local util = require 'morph._test.util'
        util.drain(150)
        return { text = util.text(0), events = util.events() }
      end)
      assert.are.same('outer inner', result.text)
      assert.are.same({}, result.events)
    end
  )

  it('reverts replace and paste edits inside a readonly region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Name: [',
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h('text', { id = 'field', on_change = util.create_event_recorder 'field' }, '36'),
        ']',
      }
      vim.fn.setreg('"', 'ZZZ')
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- cursor inside 'Ada'
    end)

    -- Single-char replace inside the readonly region
    nv:input 'rQ'
    local after_replace = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events { clear = true } }
    end)
    assert.are.same('Name: [Ada] Age: [36]', after_replace.text)
    assert.are.same({}, after_replace.events)

    -- Paste inside the readonly region
    nv:input 'p'
    local after_paste = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Name: [Ada] Age: [36]', after_paste.text)
    assert.are.same({}, after_paste.events)
  end)

  -- Repro: typing multiple characters into the single hole of a
  -- readonly-by-default app. 'ifl' in one input batch left 'Filter: [f]' --
  -- the second character was reverted.
  it('accepts multi-character typing into the single hole', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        'Filter: [',
        h('text', {
          id = 'filter',
          readonly = false,
          on_change = util.create_event_recorder 'filter',
        }, ''),
        ']',
      }
      util.cursor_to_extmark_start(_G.m, 'filter')
    end)

    nv:input 'ifl'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: [fl]', result.text)
    assert.are.same({ { id = 'filter', text = 'fl' } }, result.events)
  end)

  -- Regression: fast typing batches SEVERAL keystrokes into one TextChanged
  -- window, and the guard once judged the whole window by the LAST event's
  -- geometry. When an earlier keystroke had already moved the snapshot
  -- forward, the batched chars grew the live text past that snapshot, so the
  -- last char read as escaping the hole, the locked ancestor's mismatch
  -- looked unexplained, and the whole edit was reverted (models.dev filter:
  -- type "glm-" fast, watch it flash back). Two phases reproduce the field
  -- shape: 'f' gets its own window, then 'lm' arrives batched.
  it('accepts batched multi-char typing into a hole under a locked ancestor', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'root' }, {
          'Filter: [',
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = util.create_event_recorder 'filter',
          }, ''),
          ']',
        }),
      }
      util.cursor_to_extmark_start(_G.m, 'filter')
    end)

    nv:input 'if'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events { clear = true } }
    end)

    -- Two edits in ONE exec_func: both on_bytes events fire before the event
    -- loop yields, so ONE TextChanged window covers both -- the real-fast-
    -- typing shape (separate on_bytes events, one guard decision). The child
    -- coalesces typed nvim_input chars into a single edit, so programmatic
    -- edits are the only way to reproduce the multi-event window here.
    nv:exec_func(function()
      vim.api.nvim_buf_set_text(0, 0, 10, 0, 10, { 'l' })
      vim.api.nvim_buf_set_text(0, 0, 11, 0, 11, { 'm' })
    end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: [flm]', result.text)
    -- The window's first event claims the hole and commits the full live
    -- text (including chars from later events in the same window); the
    -- trailing events then find no mismatch and fire nothing.
    assert.are.same({ { id = 'filter', text = 'flm' } }, result.events)
  end)

  -- Tuis-style flat chrome: SIBLING locked tags around the hole (no wrapper
  -- to explain boundary captures). Typing at the hole's tail must land in
  -- the hole, not inside the following locked tag.
  it('accepts typing at a hole tail adjacent to a locked tag', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'Filter: ['),
        h('text', {
          id = 'filter',
          readonly = false,
          on_change = util.create_event_recorder 'filter',
        }, ''),
        h('text', {}, ']'),
      }
      util.cursor_to_extmark_start(_G.m, 'filter')
    end)

    nv:input 'if'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events { clear = true } }
    end)

    -- Still in insert mode: the next keystroke lands at the hole's tail,
    -- exactly where the following locked tag's start mark sits.
    nv:input 'l'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: [fl]', result.text)
    assert.are.same({ { id = 'filter', text = 'fl' } }, result.events)
  end)

  -- Docker.lua shape: a CONTROLLED hole whose on_change re-renders a table
  -- that re-filters per keystroke. The re-render recreates the following
  -- locked tag's extmark at the hole's tail boundary; typing there must land
  -- in the hole, not inside the locked tag.
  it('accepts multi-char typing into a controlled filter with a filtering table', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      local items = { 'flutastic_wp', 'flutastic_db', 'sql-postgres-1', 'sql-mysql-1' }
      local function Table(ctx)
        local rows = { h('text', {}, 'NAME  IMAGE  ID  STATUS') }
        for _, item in ipairs(ctx.props.items or {}) do
          table.insert(rows, h('text', {}, item))
        end
        return rows
      end
      --- @param ctx morph.Ctx<{}, { filter: string }>
      local function DockerView(ctx)
        if ctx.phase == 'mount' then ctx.state = { filter = '' } end
        local state = assert(ctx.state)
        local rows = {}
        for _, item in ipairs(items) do
          if item:find(state.filter, 1, true) then table.insert(rows, item) end
        end
        return {
          h('text', {}, '## Containers'),
          '\n\n',
          h('text', {}, 'Filter: ['),
          h('text', {
            id = 'filter',
            readonly = false,
            on_change = function(e)
              util.create_event_recorder 'filter'(e)
              state.filter = e.text
              ctx:update(state)
            end,
          }, state.filter),
          h('text', {}, ']'),
          '\n\n',
          h(Table, { items = rows }),
        }
      end
      _G.m:mount(h(DockerView), { debounce_ms = 0 })
      local el = assert(_G.m:get_element_by_id 'filter')
      vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] })
    end)

    nv:input 'if'
    nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events { clear = true } }
    end)

    nv:input 'l'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events() }
    end)
    -- the full buffer includes the title and the re-filtered table
    assert.truthy(string.find(result.text, 'Filter: [fl]', 1, true) ~= nil)
    -- the 'f' event was consumed by the first phase's read+clear
    assert.are.same({ { id = 'filter', text = 'fl' } }, result.events)
  end)

  -- Regression: an insert at an editable hole's TAIL is absorbed by the
  -- hole's end mark (the hole grows -- nvim says the hole is the edit
  -- target), but the winner ranking preferred a merely-containing editable
  -- region over the ending span. The container claimed the keystroke, the
  -- hole was snapped back onto its stale span, and the hole's on_change
  -- never fired -- a controlled filter's state lagged the buffer, and its
  -- next debounce render wiped the characters the user had typed.
  it('attributes tail-typed chars to the hole, not the containing region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      -- An editable CONTAINER around the hole: the shape of an App that
      -- wraps its whole UI in one big text tag (examples/big_data_set.lua).
      _G.m:render {
        h('text', { id = 'outer' }, {
          'Name: [',
          h('text', { id = 'hole', on_change = util.create_event_recorder 'hole' }, 'w'),
          ']',
        }),
      }
    end)

    -- Two keystrokes, each in its own TextChanged window, both inserted at
    -- the hole's tail: 'w' -> 'wX' -> 'wXY'. This is typing at the end of a
    -- filter, one keystroke per guard window.
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local line = vim.api.nvim_buf_get_lines(0, 0, 1, true)[1]
      local col = line:find '%]' - 1 -- the hole's tail == the ']' column
      vim.api.nvim_buf_set_text(0, 0, col, 0, col, { 'X' })
      util.drain(100)
    end)
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local line = vim.api.nvim_buf_get_lines(0, 0, 1, true)[1]
      local col = line:find '%]' - 1 -- the hole's tail == the ']' column
      vim.api.nvim_buf_set_text(0, 0, col, 0, col, { 'Y' })
      util.drain(100)
    end)
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Name: [wXY]', result.text)
    assert.are.same({ { id = 'hole', text = 'wX' }, { id = 'hole', text = 'wXY' } }, result.events)
  end)

  -- On revert, the cursor returns to where the rejected keystroke found it:
  -- the guard derives it from the live cursor minus the on_bytes delta.
  it('restores the cursor after a typed edit into a locked region', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h(
          'text',
          { id = 'hole', readonly = false, on_change = util.create_event_recorder 'hole' },
          ''
        ),
        ']',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 1 }) -- inside the locked span
    end)

    nv:input 'iX'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), cursor = vim.api.nvim_win_get_cursor(0) }
    end)
    assert.are.same('Ada] Age: []', result.text)
    assert.are.same({ 1, 1 }, result.cursor)
  end)

  -- A line delete's exact column is unrecoverable (it sat inside the deleted
  -- range); the cursor lands on the restored line's start instead.
  it('lands the cursor on the restored line after a reverted line delete', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'ro', readonly = true }, 'LOCKED\n'),
        h('text', {
          id = 'hole',
          readonly = false,
          on_change = util.create_event_recorder 'hole',
        }, 'editable\n'),
        h('text', { id = 'ro2', readonly = true }, 'more'),
      }
      vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- inside the locked span
    end)

    nv:input 'dd'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), cursor = vim.api.nvim_win_get_cursor(0) }
    end)
    assert.are.same('LOCKED\neditable\nmore', result.text)
    -- nvim preserved the cursor's column through the delete, so the full
    -- pre-edit position is recoverable
    assert.are.same({ 1, 3 }, result.cursor)
  end)

  -- A line delete clamps the cursor column to the next line's length; the
  -- restore must return the PRE-edit column (from the pre-edit snapshot),
  -- not nvim's clamped one.
  it('restores the pre-clamp cursor column after a reverted line delete', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { readonly = true }, 'SHORT\n'),
        h('text', { readonly = true }, 'A_VERY_LONG_READONLY_LINE_GOES_HERE_WITH_MANY_COLUMNS\n'),
        h('text', { readonly = true }, 'tail\n'),
        h(
          'text',
          { id = 'hole', readonly = false, on_change = util.create_event_recorder 'hole' },
          'hole'
        ),
      }
      util.drain(50) -- flush the render's pending TextChanged so the navigation below is sampled
      vim.api.nvim_win_set_cursor(0, { 2, 40 }) -- deep inside the LONG line
    end)

    nv:input 'dd'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), cursor = vim.api.nvim_win_get_cursor(0) }
    end)
    assert.are.same(
      'SHORT\nA_VERY_LONG_READONLY_LINE_GOES_HERE_WITH_MANY_COLUMNS\ntail\nhole',
      result.text
    )
    assert.are.same({ 2, 40 }, result.cursor)
  end)

  -- Insert-mode typing into locked chrome must also restore the pre-typing
  -- cursor: insert advances the cursor past the typed char, and Esc pulls it
  -- back one, so the live position is wrong in both axes by revert time.
  it('restores the pre-typing cursor after a reverted insert-mode edit', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'Name: [',
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h(
          'text',
          { id = 'hole', readonly = false, on_change = util.create_event_recorder 'hole' },
          '36'
        ),
        ']',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- strictly inside 'Ada'
    end)

    nv:input 'iX<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), cursor = vim.api.nvim_win_get_cursor(0) }
    end)
    assert.are.same('Name: [Ada] Age: [36]', result.text)
    assert.are.same({ 1, 9 }, result.cursor)
  end)

  -- With region-aware undo, a rejected locked-chrome edit is reverted by the
  -- guard and never reaches the probe, so it must not consume an undo step:
  -- one `u` after a rejected edit reverts the user's last ACCEPTED hole edit.
  it('does not let a rejected edit consume an undo step', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        'Name: [',
        h(
          'text',
          { id = 'hole', readonly = false, on_change = util.create_event_recorder 'hole' },
          'Ada'
        ),
        ']',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- start of the hole (col 7, 0-based)
    end)

    nv:input 'if<Esc>' -- accepted: 'Name: [fAda]'
    local mid = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(100)
      vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- into the locked 'Name: ['
      return util.text(0)
    end)
    assert.are.same('Name: [fAda]', mid)

    nv:input 'iX<Esc>' -- rejected and reverted by the guard
    nv:input 'u' -- reverts the accepted 'f' edit, not the rejected one
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('Name: [Ada]', result)
  end)

  -- Regression: the original repro report -- pasting INTO the hole with the
  -- cursor sitting on the '[' must be accepted (the paste lands between the
  -- brackets, inside the hole). Only pasting BEFORE the '[' (P, or cursor one
  -- column left) lands in locked chrome and correctly flashes.
  it('accepts pasting into the hole with the cursor on the opening bracket', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', {}, 'Filter: ['),
        h('text', {
          id = 'filter',
          readonly = false,
          on_change = util.create_event_recorder 'filter',
        }, ''),
        h('text', {}, ']'),
      }
      local el = assert(_G.m:get_element_by_id 'filter')
      vim.api.nvim_win_set_cursor(0, { el.extmark.start[1] + 1, el.extmark.start[2] - 1 })
      vim.fn.setreg('"', 'word')
      util.drain(50)
    end)

    nv:input 'p'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: [word]', result.text)
    assert.are.same({ { id = 'filter', text = 'word' } }, result.events)
  end)

  -- ciw on the hole's whole content collapses the hole's span to zero width
  -- (both marks meet at the deletion point) while the surrounding locked
  -- brackets survive. That is a legitimate hole edit, not a destroyed hole:
  -- the locked ancestor must accept the content swap and let insert mode
  -- continue.
  it('lets ciw replace the entire hole content under a locked ancestor', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'row' }, {
          'Filter: [',
          h(
            'text',
            { id = 'filter', readonly = false, on_change = util.create_event_recorder 'filter' },
            'myword'
          ),
          '] ',
          h('text', { id = 'status', readonly = true }, 'Up 3 days'),
        }),
      }
      vim.api.nvim_win_set_cursor(0, { 1, 10 }) -- inside 'myword'
    end)

    nv:input 'ciw'
    nv:input 'new'
    nv:input '<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: [new] Up 3 days', result.text)
    assert.are.same('new', result.events[#result.events].text)
  end)

  -- The collapsed-hole acceptance is bounded by the hole's last-accepted
  -- span: an edit whose PRE-edit range reaches past it (here: the filter
  -- content AND the closing bracket) must still revert.
  it('reverts a collapsed-hole edit that also consumed the closing bracket', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'row' }, {
          'Filter: [',
          h(
            'text',
            { id = 'filter', readonly = false, on_change = util.create_event_recorder 'filter' },
            'myword'
          ),
          '] ',
          h('text', { id = 'status', readonly = true }, 'Up 3 days'),
        }),
      }
      vim.api.nvim_win_set_cursor(0, { 1, 10 })
    end)

    -- v9l selects from the cursor through the ']' and one char past it; the
    -- edit's pre-edit range reaches outside the hole's last-accepted span,
    -- so the guard reverts and the full row is restored
    nv:input 'v9ld'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('Filter: [myword] Up 3 days', result)
  end)

  -- A violation's revert render rebuilds every tag's curr_text/curr_span,
  -- so a batch AFTER a reverted edit must still explain hole edits against
  -- fresh geometry (the next batch's prev span is not corrupted by marks
  -- that the revert moved).
  it('accepts a valid hole edit in the batch after a reverted violation', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'row' }, {
          'Filter: [',
          h(
            'text',
            { id = 'filter', readonly = false, on_change = util.create_event_recorder 'filter' },
            ''
          ),
          ']',
        }),
      }
      vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- inside locked 'Filter: ['
    end)

    nv:input 'iX<Esc>' -- violated and reverted
    local mid = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- the hole between the brackets
      return util.text(0)
    end)
    assert.are.same('Filter: []', mid)

    nv:input 'ifilter'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Filter: [filter]', result.text)
    assert.are.same('filter', result.events[#result.events].text)
  end)

  -- Top-level bare strings get implicit text tags, so a locked renderer
  -- default guards ALL content, not just tagged regions.
  it('guards top-level bare strings under a locked renderer default', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        'bare_head ',
        h('text', { id = 'tagged' }, 'TAGGED'),
        ' bare_tail',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 20 }) -- inside ' bare_tail'
    end)

    nv:input 'iX<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('bare_head TAGGED bare_tail', result)
  end)

  -- Under a classic unlocked default the implicit tag is editable and inert:
  -- bare strings keep accepting edits exactly as before.
  it('leaves top-level bare strings editable under a classic unlocked default', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.m:render {
        'bare_head ',
        h('text', { id = 'tagged', readonly = true }, 'TAGGED'),
        ' bare_tail',
      }
      vim.api.nvim_win_set_cursor(0, { 1, 20 }) -- inside ' bare_tail'
    end)

    nv:input 'iX<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('bare_head TAGGED barXe_tail', result)
  end)

  -- Component tags produce no extmark of their own, so bare strings directly
  -- in a component's output need the implicit-tag treatment too.
  it('guards bare strings directly inside component output', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.Row = function(_ctx)
        return { 'name: ', h('text', { id = 'hole', readonly = false }, 'value') }
      end
      _G.m:render { h(_G.Row, {}, {}) }
      vim.api.nvim_win_set_cursor(0, { 1, 1 }) -- inside the bare 'name: '
    end)

    nv:input 'iX<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(200)
      return util.text(0)
    end)
    assert.are.same('name: value', result)
  end)

  -- Renderer-default app under real keystrokes: locked chrome reverts, the
  -- explicit hole accepts input and fires on_change.
  it('guards a readonly-by-default wrapper with an input hole under real typing', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'wrapper', readonly = true }, {
          'Name: [',
          h('text', {
            id = 'input',
            readonly = false,
            on_change = util.create_event_recorder 'input',
          }, ''),
          ']',
        }),
      }
      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- inside locked chrome
    end)

    nv:input 'iX<Esc>'
    local chrome = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events { clear = true } }
    end)
    assert.are.same('Name: []', chrome.text)
    assert.are.same({}, chrome.events)

    -- Cursor at the empty hole's position (col 7): typing is accepted
    nv:exec_func(function() vim.api.nvim_win_set_cursor(0, { 1, 7 }) end)
    nv:input 'iA<Esc>'
    local typed = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events { clear = true } }
    end)
    assert.are.same('Name: [A]', typed.text)
    assert.are.same({ { id = 'input', text = 'A' } }, typed.events)
  end)

  -- Typing at a non-empty hole's left edge: the keystroke must land INSIDE
  -- the hole (standard insert-before-cursor editing), not in the locked
  -- chrome before it.
  it('accepts typing at the left edge of a non-empty hole', function()
    nv:exec_func(function()
      local util = require 'morph._test.util'
      local Morph = require 'morph'
      local h = Morph.h
      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:render {
        h('text', { id = 'wrapper', readonly = true }, {
          'Name: [',
          h('text', {
            id = 'input',
            readonly = false,
            on_change = util.create_event_recorder 'input',
          }, 'x'),
          ']',
        }),
      }
      vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- hole start col
    end)

    nv:input 'iB<Esc>'
    local result = nv:exec_func(function()
      local util = require 'morph._test.util'
      util.drain(150)
      return { text = util.text(0), events = util.events() }
    end)
    assert.are.same('Name: [Bx]', result.text)
    assert.are.same({ { id = 'input', text = 'Bx' } }, result.events)
  end)
end)

--------------------------------------------------------------------------------
-- In-process (host) tests: the revert guard's handler logic, driven with
-- programmatic edits + a manual `doautocmd TextChanged` (TextChanged never
-- fires in the host runner; see AGENTS.md "Test Environment Notes"). The
-- child-nvim tests above cover real keystroke semantics; this block exercises
-- the same code paths in the host so luacov can observe them.
--------------------------------------------------------------------------------
describe('readonly regions (in-process)', function()
  local Morph = require 'morph'
  local h = Morph.h
  local Pos00 = Morph.Pos00

  local function get_text() return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, true)):join '\n' end

  -- Scratch window per test, cleaned up via bdelete (fires teardown autocmds)
  local function with_buf(f)
    vim.go.swapfile = false
    vim.cmd.new()
    local ok, result = pcall(f)
    vim.cmd.bdelete { bang = true }
    if not ok then error(result) end
  end

  it('reverts a programmatic edit inside a readonly region', function()
    with_buf(function()
      local r = Morph.new(0)
      local events = {}
      r:render {
        'Name: [',
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        '] Age: [',
        h('text', {
          id = 'field',
          on_change = function(e) table.insert(events, { id = 'field', text = e.text }) end,
        }, '36'),
        ']',
      }

      vim.api.nvim_buf_set_text(0, 0, 7, 0, 10, { 'XXX' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('Name: [Ada] Age: [36]', get_text())
      assert.are.same({}, events)
    end)
  end)

  it('reverts a readonly child edit without firing the editable parent on_change', function()
    with_buf(function()
      local r = Morph.new(0)
      local events = {}
      r:render {
        h('text', { id = 'parent', on_change = function(e) table.insert(events, e.text) end }, {
          'outer ',
          h('text', { id = 'child', readonly = true }, 'inner'),
        }),
      }

      vim.api.nvim_buf_set_text(0, 0, 6, 0, 11, { 'XXXXX' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('outer inner', get_text())
      assert.are.same({}, events)
    end)
  end)

  it('reverts nested readonly regions in one pass', function()
    with_buf(function()
      local r = Morph.new(0)
      r:render {
        h('text', { id = 'outer-ro', readonly = true }, {
          'aaa ',
          h('text', { id = 'inner-ro', readonly = true }, 'bbb'),
          ' ccc',
        }),
      }

      -- One write violates both the inner and outer readonly spans
      vim.api.nvim_buf_set_text(0, 0, 4, 0, 7, { 'XXX' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('aaa bbb ccc', get_text())
    end)
  end)

  it('supports a renderer-level readonly default', function()
    with_buf(function()
      local r = Morph.new(0, { readonly = true })
      local events = {}
      -- The hole is controlled (on_change persists via ctx:update) -- the
      -- morph input contract, and what keeps hole content alive across
      -- violation-triggered reverts.
      --- @param ctx morph.Ctx<{}, { v: string }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { v = 'a' } end
        local state = assert(ctx.state)
        return {
          h('text', { id = 'chrome' }, 'static'), -- forgotten: locked by default
          ' ',
          h('text', {
            id = 'input',
            readonly = false,
            on_change = function(e)
              table.insert(events, e.text)
              ctx:update { v = e.text }
            end,
          }, state.v),
        }
      end
      r:mount(h(App), { debounce_ms = 0 })

      -- Edit inside the explicit hole: accepted and persisted via ctx:update
      vim.api.nvim_buf_set_text(0, 0, 7, 0, 8, { 'b' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert
      assert.are.same('static b', get_text())
      assert.are.same({ 'b' }, events)

      -- Edit inside the forgotten tag: reverted; the controlled hole survives
      vim.api.nvim_buf_set_text(0, 0, 0, 0, 6, { 'STATIC' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert
      assert.are.same('static b', get_text())
      assert.are.same({ 'b' }, events)
    end)
  end)

  it('forwards the renderer readonly default through Portal', function()
    with_buf(function()
      local portal_buf = vim.api.nvim_create_buf(false, true)
      local r = Morph.new(0, { readonly = true })
      r:mount {
        h(Morph.Portal, { bufnr = portal_buf }, {
          h('text', { id = 'portal-chrome' }, 'inner'),
        }),
      }
      util.drain() -- flush mount scheduling

      -- The inner document inherited the default: edit reverts
      vim.api.nvim_buf_set_text(portal_buf, 0, 0, 0, 5, { 'INNER' })
      vim.api.nvim_buf_call(portal_buf, function() vim.cmd.doautocmd 'TextChanged' end)
      util.drain() -- flush the scheduled revert
      local lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, true)
      assert.are.same('inner', table.concat(lines, '\n'))
      vim.api.nvim_buf_delete(portal_buf, { force = true })
    end)
  end)

  -- A tree with MULTIPLE top-level tags has no single tag spanning the
  -- buffer, so the old top_level_tag-gated fallback left pastes beyond all
  -- spans unguarded. Under a locked default any unmatched change must revert.
  it('reverts a paste beyond spans in a multi-top-level-tag locked tree', function()
    with_buf(function()
      local r = Morph.new(0, { readonly = true })
      r:render {
        h('text', {}, 'head'),
        h('text', { id = 'hole', readonly = false }, 'x'),
        h('text', {}, 'tail'),
      }

      -- Linewise insert past the rendered content: matches no extmark span
      vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'injected' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('headxtail', get_text())
    end)
  end)

  it('reverts a linewise paste beyond a locked root span', function()
    with_buf(function()
      local r = Morph.new(0, { readonly = true })
      r:render { h('text', { id = 'root' }, 'only line') }

      -- set_lines at the boundary does not expand the root's span, so the
      -- changed region matches no extmark: the top-level-tag fallback must
      -- revert instead of only firing on_change
      vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'injected' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert
      assert.are.same('only line', get_text())
    end)
  end)

  it('gates component output via the component tag readonly attribute', function()
    with_buf(function()
      local r = Morph.new(0)
      local events = {}
      --- @param _ctx morph.Ctx<any, any>
      local function Field(_ctx)
        return h('text', {
          id = 'field-inner',
          on_change = function(e) table.insert(events, e.text) end,
        }, 'value')
      end
      r:render { h(Field, { readonly = true }) }

      vim.api.nvim_buf_set_text(0, 0, 0, 0, 5, { 'XXXXX' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert
      assert.are.same('value', get_text())
      assert.are.same({}, events)
    end)
  end)

  it('lets a component tag carve a hole under the renderer default', function()
    with_buf(function()
      local r = Morph.new(0, { readonly = true })
      local events = {}
      --- @param _ctx morph.Ctx<any, any>
      local function Field(_ctx)
        return h('text', {
          id = 'field-inner',
          on_change = function(e) table.insert(events, e.text) end,
        }, 'v')
      end
      r:render { h('text', { id = 'chrome' }, 'static '), h(Field, { readonly = false }) }

      vim.api.nvim_buf_set_text(0, 0, 7, 0, 8, { 'w' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert
      assert.are.same('static w', get_text())
      assert.are.same({ 'w' }, events)
    end)
  end)

  -- A single write that CROSSES the hole boundary reaches outside the hole's
  -- accepted span in the pre-change frame, so it reverts -- even though nvim
  -- clamps the hole's extmark onto the edit region (which made this look
  -- hole-internal under the old live-mark decision).
  it('reverts writes spanning the hole boundary', function()
    with_buf(function()
      local r = Morph.new(0)
      local events = {}
      r:render {
        h('text', { id = 'wrapper', readonly = true }, {
          'Name: [',
          h('text', {
            id = 'hole',
            readonly = false,
            on_change = function(e) table.insert(events, e.text) end,
          }, 'x'),
          ']',
        }),
      }

      -- One write replaces from inside the chrome through the hole
      vim.api.nvim_buf_set_text(0, 0, 5, 0, 8, { 'Y' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('Name: [x]', get_text())
      assert.are.same({}, events)
    end)
  end)

  it('carves editable holes inside a locked wrapper', function()
    with_buf(function()
      local r = Morph.new(0)
      local events = {}
      r:render {
        h('text', { id = 'wrapper', readonly = true }, {
          'Name: [',
          h('text', {
            id = 'hole',
            readonly = false,
            on_change = function(e) table.insert(events, e.text) end,
          }, 'x'),
          ']',
        }),
      }

      -- 'Name: [x]': hole span is cols 7..8; grow 'x' to 'xy'
      vim.api.nvim_buf_set_text(0, 0, 7, 0, 8, { 'xy' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('Name: [xy]', get_text())
      assert.are.same({ 'xy' }, events)
    end)
  end)

  it('reverts multibyte readonly text without splicing characters', function()
    with_buf(function()
      local r = Morph.new(0)
      r:render { h('text', { id = 'ro', readonly = true }, 'héllo') }

      -- Replace the first byte of the two-byte 'é' with 'e': the byte-level
      -- edit boundary sits inside a character, so the revert must repair on
      -- character boundaries to produce valid UTF-8
      vim.api.nvim_buf_set_text(0, 0, 1, 0, 2, { 'e' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('héllo', get_text())
    end)
  end)

  -- A write that clips BOTH a readonly span and an editable one is fully
  -- reverted: the tree is the source of truth, so no partial repair and
  -- no phantom on_change for content the revert is about to overwrite.
  it('reverts the whole tree for spanning writes', function()
    with_buf(function()
      local r = Morph.new(0)
      local events = {}
      r:render {
        h('text', { id = 'locked', readonly = true }, 'Ada'),
        ' ',
        h('text', { id = 'field', on_change = function(e) table.insert(events, e.text) end }, '36'),
      }

      vim.api.nvim_buf_set_text(0, 0, 2, 0, 5, { 'Z' })
      vim.cmd.doautocmd 'TextChanged'
      util.drain() -- flush the scheduled revert

      assert.are.same('Ada 36', get_text())
      assert.are.same({}, events)
      local locked = r:get_element_by_id 'locked'
      assert.are.same(Pos00.new(0, 0), locked.extmark.start)
      assert.are.same(Pos00.new(0, 3), locked.extmark.stop)
    end)
  end)
end)
