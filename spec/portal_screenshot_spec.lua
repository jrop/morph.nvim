--- @diagnostic disable: need-check-nil, global-in-non-module
--- @diagnostic disable: param-type-mismatch, undefined-field

--- Portal screen-snapshot test.
--- Spawns a child nvim, mounts a Portal component with a parent that renders
--- visible content ("I am parent"), and opens the portal target buffer in a
--- vsplit on the right.  Screenshots show BOTH buffers side by side.
---
--- Every exec_func must be fully self-contained (string.dump does not
--- capture upvalues). All requires and data are defined inside the closure.
local Nvim = require 'morph._test.nvim'

describe('Portal screenshot', function()
  local nv

  before_each(function() nv = Nvim.start { columns = 80, rows = 24 } end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  -- Status-bar line 23 + command-line line 24, hardcoded so drift is detected.

  -----------------------------------------------------------------------
  -- simple text: parent visible in source, portal content in target
  -----------------------------------------------------------------------
  it('simple text renders to portal buffer', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Hello from Portal!' })),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │Hello from Portal!                      ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'simple text: source shows parent, portal shows content')
  end)

  -----------------------------------------------------------------------
  -- parent state update triggers portal re-render
  -----------------------------------------------------------------------
  it('parent state update triggers portal re-render', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false

      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)

      --- @param ctx morph.Ctx<{}, { count: integer }>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = { count = 1 }
          vim.defer_fn(function() ctx:update { count = 2 } end, 200)
        end
        local state = assert(ctx.state)
        return h('text', {}, {
          'Parent: ' .. state.count,
          h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Portal: ' .. state.count })),
        })
      end

      morph:mount(h(App, {}, {}))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'Parent: 1                              │Portal: 1                               ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,9            All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'parent update: count=1')

    nv:exec_func(function()
      vim.wait(500, function() return false end)
    end)

    nv:assert_screenshot({
      'Parent: 2                              │Portal: 2                               ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,9            All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'parent update: count=2')
  end)

  -----------------------------------------------------------------------
  -- portal keymap triggers parent state update
  -----------------------------------------------------------------------
  it('portal keymap triggers parent state update', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false

      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)

      --- @param ctx morph.Ctx<{}, { count: integer }>
      local function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { count = 0 } end
        local state = assert(ctx.state)
        return h('text', {}, {
          'count: ' .. state.count,
          h(
            Portal,
            { bufnr = portal_buf },
            h('text', {
              nmap = {
                ['i'] = function()
                  ctx:update { count = state.count + 1 }
                  return ''
                end,
              },
            }, 'count: ' .. state.count)
          ),
        })
      end

      morph:mount(h(App, {}, {}))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'count: 0                               │count: 0                                ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,8            All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'portal keymap: count=0')

    nv:exec_func(function()
      vim.cmd 'wincmd l'
      vim.api.nvim_feedkeys('i', 'x', false)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'count: 1                               │count: 1                                ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,8            All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'portal keymap: count=1')
  end)

  -----------------------------------------------------------------------
  -- multi-line content
  -----------------------------------------------------------------------
  it('multi-line content renders to portal buffer', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(
          Portal,
          { bufnr = portal_buf },
          h('text', {}, { 'Line 1\n', 'Line 2\n', 'Line 3\n', 'Line 4' })
        ),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │Line 1                                  ',
      '~                                      │Line 2                                  ',
      '~                                      │Line 3                                  ',
      '~                                      │Line 4                                  ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'multi-line: source shows parent, portal shows four lines')
  end)

  -----------------------------------------------------------------------
  -- portal updates propagate to target buffer
  -----------------------------------------------------------------------
  it('updates propagate to portal buffer', function()
    -- Mount v1
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Version 1' })),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │Version 1                               ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'updates v1: source shows parent, portal shows Version 1')

    -- Create fresh v2 (close old split first)
    nv:exec_func(function()
      vim.cmd 'only'
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, { bufnr = portal_buf }, h('text', {}, { 'Version 2' })),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │Version 2                               ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'updates v2: source shows parent, portal shows Version 2')
  end)

  -----------------------------------------------------------------------
  -- nested component children
  -----------------------------------------------------------------------
  it('nested components render through portal', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false

      --- @param ctx morph.Ctx<any, any>
      local function Label(ctx) return h('text', {}, { 'Label: ', ctx.children }) end

      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, { bufnr = portal_buf }, h(Label, {}, { 'nested content' })),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │Label: nested content                   ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'nested: source shows parent, portal shows Label component')
  end)

  -----------------------------------------------------------------------
  -- empty portal renders empty buffer
  -----------------------------------------------------------------------
  it('empty portal renders empty buffer', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, { bufnr = portal_buf }),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │                                        ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             0,0-1          All',
      '                                                                                ',
    }, 'empty portal: source shows parent, portal side is empty')
  end)

  -----------------------------------------------------------------------
  -- multiple portals to different buffers
  -----------------------------------------------------------------------
  it('multiple portals render to separate buffers', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf1 = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf1].buftype = 'nofile'
      vim.bo[portal_buf1].bufhidden = 'wipe'
      vim.bo[portal_buf1].buflisted = false
      local portal_buf2 = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf2].buftype = 'nofile'
      vim.bo[portal_buf2].bufhidden = 'wipe'
      vim.bo[portal_buf2].buflisted = false
      local portal_buf3 = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf3].buftype = 'nofile'
      vim.bo[portal_buf3].bufhidden = 'wipe'
      vim.bo[portal_buf3].buflisted = false

      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, { bufnr = portal_buf1 }, h('text', {}, { 'Portal A' })),
        h(Portal, { bufnr = portal_buf2 }, h('text', {}, { 'Portal B' })),
        h(Portal, { bufnr = portal_buf3 }, h('text', {}, { 'Portal C' })),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf1)
      vim.cmd 'wincmd h'
      _G._test_portal_bufs = { portal_buf1, portal_buf2, portal_buf3 }
    end)

    nv:assert_screenshot({
      'I am parent                            │Portal A                                ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'multiple portals: source shows parent, portal A visible in vsplit')

    local contents = nv:exec_func(function()
      local results = {}
      for _, buf in ipairs(_G._test_portal_bufs) do
        table.insert(results, vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
      end
      return results
    end)
    assert.are.equal('Portal A', contents[1])
    assert.are.equal('Portal B', contents[2])
    assert.are.equal('Portal C', contents[3])
  end)

  -----------------------------------------------------------------------
  -- on_buf_create callback fires
  -----------------------------------------------------------------------
  it('on_buf_create callback receives morph document', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false

      local callback_fired = false
      local received_bufnr = nil
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(Portal, {
          bufnr = portal_buf,
          on_buf_create = function(bufnr, _document)
            callback_fired = true
            received_bufnr = bufnr
          end,
        }, h('text', {}, { 'content' })),
      }))
      _G._test_morph = morph
      _G._test_callback_fired = callback_fired
      _G._test_received_bufnr = received_bufnr
      _G._test_expected_bufnr = portal_buf
    end)

    local result = nv:exec_func(
      function()
        return {
          fired = _G._test_callback_fired,
          received = _G._test_received_bufnr,
          expected = _G._test_expected_bufnr,
        }
      end
    )
    assert.is_true(result.fired)
    assert.are.equal(result.expected, result.received)
  end)

  -----------------------------------------------------------------------
  -- portal with highlighted text
  -----------------------------------------------------------------------
  it('highlighted text renders through portal', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false
      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(
          Portal,
          { bufnr = portal_buf },
          h('text', { hl = 'ErrorMsg' }, { 'Error: something went wrong' })
        ),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │Error: something went wrong             ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'highlighted: source shows parent, portal shows highlighted error')
  end)

  -----------------------------------------------------------------------
  -- complex nested tree through portal
  -----------------------------------------------------------------------
  it('complex nested tree renders through portal', function()
    nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h
      local Portal = Morph.Portal
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].buftype = 'nofile'
      vim.bo[source_buf].bufhidden = 'wipe'
      vim.bo[source_buf].buflisted = false
      local portal_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[portal_buf].buftype = 'nofile'
      vim.bo[portal_buf].bufhidden = 'wipe'
      vim.bo[portal_buf].buflisted = false

      --- @param ctx morph.Ctx<any, any>
      local function Label(ctx) return h('text', {}, { '[', ctx.children, ']' }) end

      --- @param ctx morph.Ctx<any, any>
      local function Greeting(ctx) return h('text', {}, { 'Hello, ', ctx.children, '!' }) end

      vim.api.nvim_set_current_buf(source_buf)
      local morph = Morph.new(source_buf)
      morph:mount(h('text', {}, {
        'I am parent',
        h(
          Portal,
          { bufnr = portal_buf },
          h('text', {}, {
            h(Label, {}, { 'header' }),
            h('text', {}, { '\n' }),
            h(Greeting, {}, { 'world' }),
            h('text', {}, { '\nline3' }),
          })
        ),
      }))
      vim.cmd 'rightbelow vsplit'
      vim.api.nvim_set_current_buf(portal_buf)
      vim.cmd 'wincmd h'
    end)

    nv:assert_screenshot({
      'I am parent                            │[header]                                ',
      '~                                      │Hello, world!                           ',
      '~                                      │line3                                   ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '~                                      │~                                       ',
      '[Scratch]            1,11           All [Scratch]             1,1            All',
      '                                                                                ',
    }, 'complex nested: source shows parent, portal shows multi-line tree')
  end)
end)
