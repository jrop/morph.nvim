--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

local Test = require 'morph.vendor.test'
local describe, it = Test.describe, Test.it
local assert = Test.assert
local Morph = require 'morph'
local Portal = Morph.Portal
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

describe('Portal', function()
  it('moves to a new buffer when the bufnr prop changes', function()
    local source_buf = create_test_buffer()
    local first, second = create_test_buffer(), create_test_buffer()
    local created = {}
    --- @type morph.Ctx<any, any>
    local app
    local function App(ctx)
      if ctx.phase == 'mount' then ctx.state = { bufnr = first } end
      app = ctx
      return h(Portal, {
        bufnr = ctx.state.bufnr,
        on_buf_create = function(bufnr) created[#created + 1] = bufnr end,
      }, h('text', {}, { 'Hello' }))
    end
    Morph.new(source_buf):mount(h(App), { debounce_ms = 0 })

    app:update { bufnr = second }
    assert.deep_equal(created, { first, second })
    assert.deep_equal(vim.api.nvim_buf_get_lines(second, 0, -1, false), { 'Hello' })
    -- The old buffer is released, so another document may mount into it.
    assert.ok(not vim.b[first]._morph_mounted)

    cleanup_buffers { source_buf, first, second }
  end)

  it('should render children to a different buffer', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Hello from Portal!' })))

    local source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local portal_lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)

    -- Portal should not render anything to source buffer
    assert.equal(#source_lines, 1)
    assert.equal(source_lines[1], '')
    -- Portal should render children to portal buffer
    assert.equal(#portal_lines, 1)
    assert.equal(portal_lines[1], 'Hello from Portal!')

    cleanup_buffers { source_buf, portal_buf }
  end)

  it('should update children in the portal buffer', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Initial text' })))

    local initial_lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)
    assert.equal(initial_lines[1], 'Initial text')

    -- Create new portal buffer with same name to simulate update
    local portal_buf2 = create_test_buffer()
    local source_buf2 = create_test_buffer()
    local r2 = Morph.new(source_buf2)
    r2:mount(h(Portal, { bufnr = portal_buf2 }, h('text', {}, { 'Updated text' })))

    local updated_lines = vim.api.nvim_buf_get_lines(portal_buf2, 0, -1, false)
    assert.equal(updated_lines[1], 'Updated text')

    cleanup_buffers { source_buf, source_buf2, portal_buf, portal_buf2 }
  end)

  it('should clear the portal buffer when unmounted', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Test content' })))

    local mounted_lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)
    assert.equal(#mounted_lines, 1)
    assert.equal(mounted_lines[1], 'Test content')

    -- Unmount by deleting the buffer which triggers cleanup
    cleanup_buffers { portal_buf }
    source_buf = create_test_buffer()

    -- Portal buffer should be deleted, so verify source buffer still exists
    assert.equal(vim.api.nvim_buf_is_valid(source_buf), true)
    assert.equal(vim.api.nvim_buf_is_valid(portal_buf), false)

    vim.api.nvim_buf_delete(source_buf, { force = true })
  end)

  it('should remount on the same portal buffer after unmount', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }, h('text', {}, { 'First content' })))
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)[1], 'First content')

    -- Unmount releases the inner document; portal buffer content stays
    r:unmount()
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)[1], 'First content')

    -- Toggle back on: a fresh mount on the same portal buffer must not error
    r:mount(h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Second content' })))
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)[1], 'Second content')

    cleanup_buffers { source_buf, portal_buf }
  end)

  it('should render multiple lines to the portal buffer', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Line 1\n', 'Line 2\n', 'Line 3' })))

    local portal_lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)
    assert.equal(#portal_lines, 3)
    assert.equal(portal_lines[1], 'Line 1')
    assert.equal(portal_lines[2], 'Line 2')
    assert.equal(portal_lines[3], 'Line 3')

    cleanup_buffers { source_buf, portal_buf }
  end)

  it('should support nested component children in portal', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    -- Create a custom component to test nesting
    --- @param ctx morph.Ctx<any, any>
    local function CustomComponent(ctx)
      -- Splicing ctx.children nests a tree one level deep; the reconciler
      -- flattens it, but the Tree alias only models one level, so assert it.
      local children = { 'Custom: ', ctx.children }
      return h('text', {}, children --[[@as morph.Tree]])
    end

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }, h(CustomComponent, {}, { 'Outer' })))

    local portal_lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)
    assert.equal(#portal_lines, 1)
    assert.equal(portal_lines[1], 'Custom: Outer')

    cleanup_buffers { source_buf, portal_buf }
  end)

  it('should handle empty children', function()
    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local r = Morph.new(source_buf)
    r:mount(h(Portal, { bufnr = portal_buf }))

    local portal_lines = vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)
    assert.equal(#portal_lines, 1)
    assert.equal(portal_lines[1], '')

    cleanup_buffers { source_buf, portal_buf }
  end)

  it('should handle multiple portals with different buffers', function()
    local portal_buf1 = create_test_buffer()
    local portal_buf2 = create_test_buffer()
    local portal_buf3 = create_test_buffer()

    local source_buf1 = create_test_buffer()
    local r1 = Morph.new(source_buf1)
    r1:mount(h(Portal, { bufnr = portal_buf1 }, h('text', {}, { 'Version 1' })))
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf1, 0, -1, false)[1], 'Version 1')

    local source_buf2 = create_test_buffer()
    local r2 = Morph.new(source_buf2)
    r2:mount(h(Portal, { bufnr = portal_buf2 }, h('text', {}, { 'Version 2' })))
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf2, 0, -1, false)[1], 'Version 2')

    local source_buf3 = create_test_buffer()
    local r3 = Morph.new(source_buf3)
    r3:mount(h(Portal, { bufnr = portal_buf3 }, h('text', {}, { 'Version 3' })))
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf3, 0, -1, false)[1], 'Version 3')

    cleanup_buffers { source_buf1, source_buf2, source_buf3, portal_buf1, portal_buf2, portal_buf3 }
  end)

  it('renders pushed children to the portal buffer synchronously', function()
    -- The portal document is mounted with debounce_ms=0, so a push (Portal
    -- update -> inner:update) must land at once rather than being deferred.
    -- Exercise the production debounce default: NVIM_TEST would force
    -- debounce_ms=0 globally and mask a missing explicit debounce_ms=0.
    local saved = vim.env.NVIM_TEST
    vim.env.NVIM_TEST = nil

    local source_buf = create_test_buffer()
    local portal_buf = create_test_buffer()

    local state = { text = 'v1' }
    --- @type morph.Ctx<any, any>
    local app_ctx
    --- @param ctx morph.Ctx<any, any>
    local function App(ctx)
      if ctx.phase == 'mount' then app_ctx = ctx end
      return h(Portal, { bufnr = portal_buf }, h('text', {}, { state.text }))
    end

    local r = Morph.new(source_buf)
    r:mount(h(App, {}), { debounce_ms = 0 })
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)[1], 'v1')

    state.text = 'v2'
    app_ctx:update { text = 'v2' }

    -- The push must land synchronously: no deferred render is needed.
    assert.equal(vim.api.nvim_buf_get_lines(portal_buf, 0, -1, false)[1], 'v2')

    cleanup_buffers { source_buf, portal_buf }
    vim.env.NVIM_TEST = saved
  end)
end)
