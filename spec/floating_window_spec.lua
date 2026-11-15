--- @diagnostic disable: duplicate-require
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: redundant-parameter
--- @diagnostic disable: undefined-field

local Test = require 'morph.vendor.test'
local describe, it = Test.describe, Test.it
local before_all, after_all, before_each, after_each =
  Test.before_all, Test.after_all, Test.before_each, Test.after_each
local assert = Test.assert
--- @type spec.util
local util = dofile 'spec/util.lua'
local Morph = require 'morph'
local FloatingWindow = Morph.FloatingWindow
local h = Morph.h

local function create_test_buffer()
  vim.go.swapfile = false
  return vim.api.nvim_create_buf(false, true)
end

local function cleanup_buffers(buffers)
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
end

local function count_float_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then n = n + 1 end
  end
  return n
end

local function close_all_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then pcall(vim.api.nvim_win_close, w, true) end
  end
end

--- Return the first floating window found, nil if none.
local function first_float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then return w end
  end
  return nil
end

--- Test float geometry, identical across the host specs.
local CFG = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 }

--- Shared FloatingWindow app: an `{ open }` state captured in `box[1]` so
--- tests drive open/close transitions, with optional on_closed passthrough.
--- @param initial_open boolean
--- @param on_closed? fun()
--- @return fun(ctx: morph.Ctx<any, any>) App
--- @return morph.Ctx<any, any>[] box
local function float_app(initial_open, on_closed)
  local box = {}
  local function App(ctx)
    if ctx.phase == 'mount' then ctx.state = { open = initial_open } end
    box[1] = ctx
    return h(FloatingWindow, {
      open = ctx.state.open,
      config = CFG,
      on_closed = on_closed,
    }, h('text', {}, { 'Hello' }))
  end
  return App, box
end

describe('FloatingWindow', function()
  -- These tests drive open/close transitions via box[1]:update and assert
  -- synchronously, so run with debounce off (NVIM_TEST=true) like the suite
  -- does. Save/restore so other specs are unaffected.
  --- @type string?
  local saved_nvim_test
  before_all(function()
    saved_nvim_test = vim.env.NVIM_TEST
    vim.env.NVIM_TEST = 'true'
  end)
  after_all(function() vim.env.NVIM_TEST = saved_nvim_test end)
  after_each(function()
    -- HOST-only artifact (the test runner nvim, not the test.Nvim
    -- child): `:startinsert` leaves nvim's internal insert-pending state set
    -- even though the host never truly enters insert mode (mode() reports 'n').
    -- The float-close path short-circuits (mode already 'n'), so `:stopinsert`
    -- is never called and the state leaks into later specs, flipping how nvim
    -- anchors the cursor on subsequent nvim_buf_set_text calls. Clear it so
    -- suite ordering cannot change later tests' behavior. The child harness is
    -- unaffected (each child is fresh and torn down per test); see AGENTS.md's
    -- "Test Environment Notes" host/child split.
    vim.cmd.stopinsert()
  end)
  it('should create floating window when open is true', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(h(FloatingWindow, { open = true, config = CFG }, h('text', {}, { 'Hello' })))

    local float_win = first_float_win()

    assert.ok(float_win, 'Floating window not created')

    cleanup_buffers { buf }
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end)

  it('should capture and restore focus, cursor, and mode on open/close', function()
    local host_buf = create_test_buffer()
    vim.api.nvim_buf_set_lines(host_buf, 0, -1, false, {
      'one',
      'two',
      'three',
      'four',
      'five',
    })
    vim.api.nvim_set_current_buf(host_buf)

    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(original_win, { 5, 3 })

    local App, box = float_app(false)

    local r = Morph.new(create_test_buffer())
    r:mount(h(App))

    -- open=false: no float, original context untouched.
    assert.equal(count_float_wins(), 0)

    -- false -> true: float opens, focus moves away from original window.
    box[1]:update { open = true }
    assert.equal(count_float_wins(), 1)
    assert.not_equal(vim.api.nvim_get_current_win(), original_win)

    -- true -> false: float closes, original context restored.
    box[1]:update { open = false }
    vim.wait(
      1000,
      function()
        return vim.api.nvim_get_current_win() == original_win and vim.fn.mode():sub(1, 1) == 'n'
      end,
      10
    )
    assert.equal(count_float_wins(), 0)
    assert.equal(vim.api.nvim_get_current_win(), original_win)
    assert.deep_equal(vim.api.nvim_win_get_cursor(original_win), { 5, 3 })
    assert.equal(vim.fn.mode():sub(1, 1), 'n')
  end)

  it('should restore original context when closing after mount with open=true', function()
    local host_buf = create_test_buffer()
    vim.api.nvim_buf_set_lines(host_buf, 0, -1, false, { 'one', 'two', 'three' })
    vim.api.nvim_set_current_buf(host_buf)

    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(original_win, { 2, 2 })

    local App, box = float_app(true)

    local r = Morph.new(create_test_buffer())
    r:mount(h(App))

    assert.equal(count_float_wins(), 1)

    box[1]:update { open = false }
    vim.wait(1000, function() return vim.api.nvim_get_current_win() == original_win end, 10)

    assert.equal(count_float_wins(), 0)
    assert.equal(vim.api.nvim_get_current_win(), original_win)
    assert.deep_equal(vim.api.nvim_win_get_cursor(original_win), { 2, 2 })
  end)

  it('should not create floating window when open is false', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(h(FloatingWindow, { open = false, config = CFG }, h('text', {}, { 'Hello' })))

    assert.equal(count_float_wins(), 0, 'Floating window should not be created when open=false')

    cleanup_buffers { buf }
  end)

  it('should render content to floating window buffer', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(h(FloatingWindow, { open = true, config = CFG }, h('text', {}, { 'Test Content' })))

    local float_win = first_float_win()

    assert.ok(float_win, 'Floating window should be created')

    local win_buf = vim.api.nvim_win_get_buf(float_win)
    local lines = vim.api.nvim_buf_get_lines(win_buf, 0, -1, false)

    assert.equal(lines[1], 'Test Content')

    cleanup_buffers { buf }
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end)

  it('should cleanup window and buffer on unmount', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(h(FloatingWindow, { open = true, config = CFG }, h('text', {}, { 'Hello' })))

    local float_win = first_float_win()

    assert.ok(float_win, 'Floating window should be created')

    cleanup_buffers { buf }

    -- Wait for the window to be closed (unmount happens asynchronously)
    vim.wait(1000, function() return not vim.api.nvim_win_is_valid(float_win) end, 10)

    assert.equal(
      vim.api.nvim_win_is_valid(float_win),
      false,
      'Floating window should be closed on unmount'
    )
  end)

  it('should fire on_closed after focus, cursor, and mode are restored', function()
    local host_buf = create_test_buffer()
    vim.api.nvim_buf_set_lines(host_buf, 0, -1, false, { 'one', 'two', 'three' })
    vim.api.nvim_set_current_buf(host_buf)

    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(original_win, { 2, 2 })

    local fired = 0
    local fire_win, fire_mode, fire_floats

    local App, box = float_app(true, function()
      fired = fired + 1
      fire_win = vim.api.nvim_get_current_win()
      fire_mode = vim.fn.mode():sub(1, 1)
      fire_floats = count_float_wins()
    end)

    local r = Morph.new(create_test_buffer())
    r:mount(h(App))

    assert.equal(count_float_wins(), 1)
    assert.equal(fired, 0)

    box[1]:update { open = false }
    vim.wait(2000, function() return fired > 0 end, 10)

    assert.equal(fired, 1)
    assert.equal(fire_win, original_win)
    assert.equal(fire_mode, 'n')
    assert.equal(fire_floats, 0)
    assert.deep_equal(vim.api.nvim_win_get_cursor(original_win), { 2, 2 })

    -- Unmount must NOT fire on_closed a second time.
    cleanup_buffers { host_buf }
    vim.wait(1000, function() return not vim.api.nvim_buf_is_valid(host_buf) end, 10)
    assert.equal(fired, 1)
  end)

  it('restores normal mode even when the previous window was closed mid-flight', function()
    -- Regression: when the captured prev_winnr was killed while the float was
    -- open, closing the float used to skip mode restore entirely, stranding
    -- the user in insert mode. Mode must be restored regardless of prev_winnr.
    local display_buf = create_test_buffer()
    vim.api.nvim_buf_set_lines(display_buf, 0, -1, false, { 'one', 'two' })
    vim.api.nvim_set_current_buf(display_buf)
    local w1 = vim.api.nvim_get_current_win()
    vim.cmd.vsplit()
    local w2 = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(w1)

    local morph_buf = create_test_buffer()
    local App, box = float_app(true)

    local r = Morph.new(morph_buf)
    r:mount(h(App))
    assert.equal(count_float_wins(), 1)

    -- Enter insert mode in the float so mode restore is meaningful.
    vim.cmd.startinsert()

    -- Kill the captured previous window while the float is up.
    vim.api.nvim_win_close(w1, true)

    -- Close the float; mode must restore to normal even though W1 is gone.
    box[1]:update { open = false }
    vim.wait(
      1000,
      function() return vim.fn.mode():sub(1, 1) == 'n' and count_float_wins() == 0 end,
      10
    )

    assert.equal(vim.fn.mode():sub(1, 1), 'n')
    assert.equal(count_float_wins(), 0)
    assert.equal(vim.api.nvim_win_is_valid(w1), false)
    assert.equal(vim.api.nvim_get_current_win(), w2)

    close_all_floats()
    cleanup_buffers { morph_buf, display_buf }
  end)

  it('fires on_closed exactly once and restores mode on unmount while open', function()
    -- When the component is unmounted while still open, that unmount IS the
    -- open->closed transition: on_closed fires once and mode is restored.
    local display_buf = create_test_buffer()
    vim.api.nvim_set_current_buf(display_buf)
    local w1 = vim.api.nvim_get_current_win()

    local morph_buf = create_test_buffer()
    local fired = 0
    local App = float_app(true, function() fired = fired + 1 end)

    local r = Morph.new(morph_buf)
    r:mount(h(App))
    assert.equal(count_float_wins(), 1)
    assert.equal(fired, 0)

    -- Enter insert mode in the float so mode restore is meaningful.
    vim.cmd.startinsert()

    -- Unmount by wiping the morph's buffer; the float is still open.
    vim.api.nvim_buf_delete(morph_buf, { force = true })
    vim.wait(
      1000,
      function() return fired == 1 and count_float_wins() == 0 and vim.fn.mode():sub(1, 1) == 'n' end,
      10
    )

    assert.equal(fired, 1)
    assert.equal(count_float_wins(), 0)
    assert.equal(vim.fn.mode():sub(1, 1), 'n')
    assert.equal(vim.api.nvim_get_current_win(), w1)

    close_all_floats()
    cleanup_buffers { display_buf }
  end)
end)

-- Closing a float that was in insert mode restores the prior mode via
-- `restore_mode_and_wait`, which fires the `on_closed` callback from inside
-- the `i:n` ModeChanged autocmd. When `on_closed` opens a *second* float,
-- that float's `on_win_create` -- and any `startinsert` issued there -- runs
-- nested inside that autocmd and does not stick, leaving the second float in
-- normal mode and uneditable.
--
-- The bug only manifests on the `i->n` ModeChanged route, so float A must be
-- in insert at close time. A's own `on_win_create` calls `startinsert`; that
-- suffices -- in the `test.Nvim` child (a real `--embed`ded nvim)
-- programmatic `startinsert` DOES enter insert, it just is not visible within
-- the same `run` call. The mode change is only observable across an RPC
-- round-trip (a later `run`), which acts as the event-loop flush point
-- (see AGENTS.md). So no real `nv:input 'i'` is needed to set up A.
--
-- The assertion is the user-facing symptom itself: after A closes and B
-- opens (whose `on_win_create` calls `startinsert`), real input typed into B
-- must land in B's buffer. With the bug, B's `startinsert` is swallowed by the
-- still-on-stack ModeChanged autocmd, B stays in normal mode, and typed text
-- is consumed as a normal-mode motion instead of inserted -- so B's buffer
-- stays empty. `vim.fn.mode(1)` is NOT a reliable discriminator on its own:
-- typing the input enters insert mode in both cases, so only the buffer
-- content distinguishes bug from fix. Do not "simplify" this to a mode
-- assertion.
describe('FloatingWindow nested open from on_closed', function()
  --- @type test.Nvim?
  local nv
  before_each(function() nv = util.start { columns = 60, rows = 20 } end)
  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('second float opened from first on_closed is editable in insert mode', function()
    nv:run(function()
      local Morph = require 'morph'
      local h = Morph.h
      local FloatingWindow = Morph.FloatingWindow
      local util = dofile 'spec/util.lua'
      _G.m = Morph.new(util.scratch_buf { focus = true })
      _G.b_buf = nil
      --- @type morph.Ctx<any, any>
      _G.app = nil
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { show_a = true, show_b = false }
          _G.app = ctx
        end
        local s = ctx.state
        local cfg = { relative = 'editor', row = 1, col = 1, width = 40, height = 5 }
        if s.show_a then
          return h(FloatingWindow, {
            open = true,
            config = cfg,
            on_win_create = function() vim.cmd.startinsert() end,
            on_closed = function() _G.app:update { show_a = false, show_b = true } end,
          }, h('text', { id = 'qa' }, ''))
        end
        if s.show_b then
          return h(FloatingWindow, {
            open = true,
            config = cfg,
            on_win_create = function(_, bufnr)
              _G.b_buf = bufnr
              vim.cmd.startinsert()
            end,
          }, h('text', { id = 'qb' }, ''))
        end
        return {}
      end
      _G.m:mount(h(App, {}))
    end)

    -- A mode change requested in the child (`startinsert` / `stopinsert`) only
    -- takes effect when the child's main loop regains control between RPC
    -- requests. One long in-child `vim.wait` can therefore starve the very
    -- transition it waits for: the 500ms fallback then closes A while the
    -- child still reports insert, and the pending switch to normal cancels
    -- B's `startinsert`. Poll across requests instead, with a short wait per
    -- attempt so the loop can apply the pending change.
    --- @param predicate fun(): boolean arity-0 function string.dumped into the child
    --- @return boolean
    local function poll_child(predicate, attempts)
      for _ = 1, attempts or 150 do
        if nv:run(predicate) then return true end
      end
      return false
    end

    -- Round-trip so A's on_win_create startinsert flushes: the child is a real
    -- embedded nvim and programmatic startinsert DOES enter insert, but the
    -- mode change is only visible across an RPC round-trip, not within the
    -- same run. This puts A in insert so the close takes the i->n
    -- ModeChanged route (the only path the bug manifests on).
    local a_ready = poll_child(function()
      vim.wait(5)
      return vim.fn.mode():sub(1, 1) == 'i'
    end)
    assert.equal(
      a_ready,
      true,
      'float A never entered insert mode; the i->n route was not exercised'
    )

    -- Close A: its on_closed opens B, whose on_win_create startinsert is
    -- deferred onto a clean tick by the fix. _G.app rides the dump boundary:
    -- run string.dumps its callback into the child nvim, so a host-side
    -- local could not carry the ctx across.
    nv:run(function()
      (_G.app --[[@as morph.Ctx<any, any>]]):update { show_a = false }
    end)

    -- Real input into B: must land in B's buffer iff B entered insert mode.
    -- Wait for B to actually BE in insert mode before typing: nightly applies
    -- B's deferred startinsert one tick after on_win_create, so there is a
    -- window where b_buf exists and is focused but the keystroke would still
    -- be read as a normal-mode motion (older versions apply it within the
    -- same tick, where the buffer's mere existence implied editability).
    local b_ready = poll_child(function()
      vim.wait(5)
      return _G.b_buf ~= nil
        and vim.api.nvim_get_current_buf() == _G.b_buf
        and vim.fn.mode():sub(1, 1) == 'i'
    end)
    assert.equal(b_ready, true, 'second float never became editable in insert mode')
    nv:input 'w'

    local b_buf = nv:run(function() return _G.b_buf end)
    local lines = nv:run(function()
      local b = _G.b_buf
      if not (b and vim.api.nvim_buf_is_valid(b)) then return {} end
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end)

    assert.ok(b_buf, 'second float on_win_create never ran')
    assert.deep_equal(lines, { 'w' }, 'second float was not editable; startinsert was lost')
  end)
end)
