--- @diagnostic disable: need-check-nil, undefined-field
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: redundant-parameter

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

describe('FloatingWindow', function()
  -- These tests drive open/close transitions via app_ctx:update and assert
  -- synchronously, so run with debounce off (NVIM_TEST=true) like the suite
  -- does. Save/restore so other specs are unaffected.
  local saved_nvim_test
  setup(function()
    saved_nvim_test = vim.env.NVIM_TEST
    vim.env.NVIM_TEST = 'true'
  end)
  teardown(function() vim.env.NVIM_TEST = saved_nvim_test end)
  after_each(function()
    -- `:startinsert` leaves nvim's internal insert-pending state set even
    -- though headless scripts never truly enter insert mode. The float-close
    -- path short-circuits (mode() already reports 'n'), so `:stopinsert` is
    -- never called and the state leaks into later specs, flipping how nvim
    -- anchors the cursor on subsequent nvim_buf_set_text calls. Clear it so
    -- suite ordering cannot change later tests' behavior.
    vim.cmd.stopinsert()
  end)
  it('should create floating window when open is true', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(
      h(
        FloatingWindow,
        { open = true, config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 } },
        h('text', {}, { 'Hello' })
      )
    )

    local windows = vim.api.nvim_list_wins()
    local float_win = nil
    for _, w in ipairs(windows) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then
        float_win = w
        break
      end
    end

    assert.is_not_nil(float_win, 'Floating window not created')

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

    local app_ctx
    local function App(ctx)
      if ctx.phase == 'mount' then ctx.state = { open = false } end
      app_ctx = ctx
      return h(FloatingWindow, {
        open = ctx.state.open,
        config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 },
      }, h('text', {}, { 'Hello' }))
    end

    local r = Morph.new(create_test_buffer())
    r:mount(h(App, {}, {}))

    -- open=false: no float, original context untouched.
    assert.are.equal(0, count_float_wins())

    -- false -> true: float opens, focus moves away from original window.
    app_ctx:update { open = true }
    assert.are.equal(1, count_float_wins())
    assert.are_not.equal(original_win, vim.api.nvim_get_current_win())

    -- true -> false: float closes, original context restored.
    app_ctx:update { open = false }
    vim.wait(
      1000,
      function()
        return vim.api.nvim_get_current_win() == original_win and vim.fn.mode():sub(1, 1) == 'n'
      end,
      10
    )
    assert.are.equal(0, count_float_wins())
    assert.are.equal(original_win, vim.api.nvim_get_current_win())
    assert.are.same({ 5, 3 }, vim.api.nvim_win_get_cursor(original_win))
    assert.are.equal('n', vim.fn.mode():sub(1, 1))
  end)

  it('should restore original context when closing after mount with open=true', function()
    local host_buf = create_test_buffer()
    vim.api.nvim_buf_set_lines(host_buf, 0, -1, false, { 'one', 'two', 'three' })
    vim.api.nvim_set_current_buf(host_buf)

    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(original_win, { 2, 2 })

    local app_ctx
    local function App(ctx)
      if ctx.phase == 'mount' then ctx.state = { open = true } end
      app_ctx = ctx
      return h(FloatingWindow, {
        open = ctx.state.open,
        config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 },
      }, h('text', {}, { 'Hello' }))
    end

    local r = Morph.new(create_test_buffer())
    r:mount(h(App, {}, {}))

    assert.are.equal(1, count_float_wins())

    app_ctx:update { open = false }
    vim.wait(1000, function() return vim.api.nvim_get_current_win() == original_win end, 10)

    assert.are.equal(0, count_float_wins())
    assert.are.equal(original_win, vim.api.nvim_get_current_win())
    assert.are.same({ 2, 2 }, vim.api.nvim_win_get_cursor(original_win))
  end)

  it('should not create floating window when open is false', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(h(FloatingWindow, {
      open = false,
      config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 },
    }, h('text', {}, { 'Hello' })))

    local windows = vim.api.nvim_list_wins()
    local float_wins = {}
    for _, w in ipairs(windows) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then table.insert(float_wins, w) end
    end

    assert.are.equal(0, #float_wins, 'Floating window should not be created when open=false')

    cleanup_buffers { buf }
  end)

  it('should render content to floating window buffer', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(
      h(
        FloatingWindow,
        { open = true, config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 } },
        h('text', {}, { 'Test Content' })
      )
    )

    local windows = vim.api.nvim_list_wins()
    local float_win = nil
    for _, w in ipairs(windows) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then
        float_win = w
        break
      end
    end

    assert.is_not_nil(float_win, 'Floating window should be created')

    local win_buf = vim.api.nvim_win_get_buf(float_win)
    local lines = vim.api.nvim_buf_get_lines(win_buf, 0, -1, false)

    assert.are.equal('Test Content', lines[1])

    cleanup_buffers { buf }
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end)

  it('should cleanup window and buffer on unmount', function()
    local buf = create_test_buffer()

    local r = Morph.new(buf)
    r:mount(
      h(
        FloatingWindow,
        { open = true, config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 } },
        h('text', {}, { 'Hello' })
      )
    )

    local windows = vim.api.nvim_list_wins()
    local float_win = nil
    for _, w in ipairs(windows) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then
        float_win = w
        break
      end
    end

    assert.is_not_nil(float_win, 'Floating window should be created')

    cleanup_buffers { buf }

    -- Wait for the window to be closed (unmount happens asynchronously)
    vim.wait(1000, function() return not vim.api.nvim_win_is_valid(float_win) end, 10)

    assert.is_false(
      vim.api.nvim_win_is_valid(float_win),
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

    local app_ctx
    local function App(ctx)
      if ctx.phase == 'mount' then ctx.state = { open = true } end
      app_ctx = ctx
      return h(FloatingWindow, {
        open = ctx.state.open,
        config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 },
        on_closed = function()
          fired = fired + 1
          fire_win = vim.api.nvim_get_current_win()
          fire_mode = vim.fn.mode():sub(1, 1)
          fire_floats = count_float_wins()
        end,
      }, h('text', {}, { 'Hello' }))
    end

    local r = Morph.new(create_test_buffer())
    r:mount(h(App, {}, {}))

    assert.are.equal(1, count_float_wins())
    assert.are.equal(0, fired)

    app_ctx:update { open = false }
    vim.wait(2000, function() return fired > 0 end, 10)

    assert.are.equal(1, fired)
    assert.are.equal(original_win, fire_win)
    assert.are.equal('n', fire_mode)
    assert.are.equal(0, fire_floats)
    assert.are.same({ 2, 2 }, vim.api.nvim_win_get_cursor(original_win))

    -- Unmount must NOT fire on_closed a second time.
    cleanup_buffers { host_buf }
    vim.wait(1000, function() return not vim.api.nvim_buf_is_valid(host_buf) end, 10)
    assert.are.equal(1, fired)
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
    local app_ctx
    local function App(ctx)
      if ctx.phase == 'mount' then ctx.state = { open = true } end
      app_ctx = ctx
      return h(FloatingWindow, {
        open = ctx.state.open,
        config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 },
      }, h('text', {}, { 'Hello' }))
    end

    local r = Morph.new(morph_buf)
    r:mount(h(App, {}))
    assert.are.equal(1, count_float_wins())

    -- Enter insert mode in the float so mode restore is meaningful.
    vim.cmd.startinsert()

    -- Kill the captured previous window while the float is up.
    vim.api.nvim_win_close(w1, true)

    -- Close the float; mode must restore to normal even though W1 is gone.
    app_ctx:update { open = false }
    vim.wait(
      1000,
      function() return vim.fn.mode():sub(1, 1) == 'n' and count_float_wins() == 0 end,
      10
    )

    assert.are.equal('n', vim.fn.mode():sub(1, 1))
    assert.are.equal(0, count_float_wins())
    assert.is_false(vim.api.nvim_win_is_valid(w1))
    assert.are.equal(w2, vim.api.nvim_get_current_win())

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
    local function App(ctx)
      if ctx.phase == 'mount' then ctx.state = { open = true } end
      return h(FloatingWindow, {
        open = ctx.state.open,
        config = { relative = 'editor', row = 1, col = 1, width = 40, height = 10 },
        on_closed = function() fired = fired + 1 end,
      }, h('text', {}, { 'Hello' }))
    end

    local r = Morph.new(morph_buf)
    r:mount(h(App, {}))
    assert.are.equal(1, count_float_wins())
    assert.are.equal(0, fired)

    -- Enter insert mode in the float so mode restore is meaningful.
    vim.cmd.startinsert()

    -- Unmount by wiping the morph's buffer; the float is still open.
    vim.api.nvim_buf_delete(morph_buf, { force = true })
    vim.wait(
      1000,
      function() return fired == 1 and count_float_wins() == 0 and vim.fn.mode():sub(1, 1) == 'n' end,
      10
    )

    assert.are.equal(1, fired)
    assert.are.equal(0, count_float_wins())
    assert.are.equal('n', vim.fn.mode():sub(1, 1))
    assert.are.equal(w1, vim.api.nvim_get_current_win())

    close_all_floats()
    cleanup_buffers { display_buf }
  end)
end)
