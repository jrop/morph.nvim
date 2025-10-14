local Morph = require 'morph'
local h = Morph.h

local function get_lines() return vim.api.nvim_buf_get_lines(0, 0, -1, true) end
local function get_text() return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, true)):join '\n' end
local function with_buf(lines, f)
  vim.go.swapfile = false

  vim.cmd.new()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local ok, result = pcall(f)
  vim.cmd.bdelete { bang = true }
  if not ok then error(result) end
end

describe('Morph', function()
  it('should render text in an empty buffer', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render { 'hello', ' ', 'world' }
      assert.are.same(get_lines(), { 'hello world' })
    end)
  end)

  it('should result in the correct text after repeated renders', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render { 'hello', ' ', 'world' }
      assert.are.same(get_lines(), { 'hello world' })

      r:render { 'goodbye', ' ', 'world' }
      assert.are.same(get_lines(), { 'goodbye world' })

      r:render { 'hello', ' ', 'universe' }
      assert.are.same(get_lines(), { 'hello universe' })
    end)
  end)

  it('should handle tags correctly', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        h('text', { hl = 'HighlightGroup' }, 'hello '),
        h('text', { hl = 'HighlightGroup' }, 'world'),
      }
      assert.are.same(get_lines(), { 'hello world' })
    end)
  end)

  it('should reconcile added lines', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render { 'line 1', '\n', 'line 2' }
      assert.are.same(get_lines(), { 'line 1', 'line 2' })

      -- Add a new line:
      r:render { 'line 1', '\n', 'line 2\n', 'line 3' }
      assert.are.same(get_lines(), { 'line 1', 'line 2', 'line 3' })
    end)
  end)

  it('should reconcile deleted lines', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render { 'line 1', '\nline 2', '\nline 3' }
      assert.are.same(get_lines(), { 'line 1', 'line 2', 'line 3' })

      -- Remove a line:
      r:render { 'line 1', '\nline 3' }
      assert.are.same(get_lines(), { 'line 1', 'line 3' })
    end)
  end)

  it('should handle multiple nested elements', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        h('text', {}, {
          'first line',
        }),
        '\n',
        h('text', {}, 'second line'),
      }
      assert.are.same(get_lines(), { 'first line', 'second line' })

      r:render {
        h('text', {}, 'updated first line'),
        '\n',
        h('text', {}, 'third line'),
      }
      assert.are.same(get_lines(), { 'updated first line', 'third line' })
    end)
  end)

  --
  -- get_tags_at
  --

  it('should return no extmarks for an empty buffer', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local pos_infos = r:get_tags_at { 0, 0 }
      assert.are.same(pos_infos, {})
    end)
  end)

  it('should return correct extmark for a given position', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        h('text', { hl = 'HighlightGroup1' }, 'Hello'),
        h('text', { hl = 'HighlightGroup2' }, ' World'),
      }

      local pos_infos = r:get_tags_at { 0, 2 }
      assert.are.same(#pos_infos, 1)
      assert.are.same(pos_infos[1].tag.attributes.hl, 'HighlightGroup1')
      assert.are.same(pos_infos[1].extmark.start, { 0, 0 })
      assert.are.same(pos_infos[1].extmark.stop, { 0, 5 })
      pos_infos = r:get_tags_at { 0, 4 }
      assert.are.same(#pos_infos, 1)
      assert.are.same(pos_infos[1].tag.attributes.hl, 'HighlightGroup1')
      assert.are.same(pos_infos[1].extmark.start, { 0, 0 })
      assert.are.same(pos_infos[1].extmark.stop, { 0, 5 })

      pos_infos = r:get_tags_at { 0, 5 }
      assert.are.same(#pos_infos, 1)
      assert.are.same(pos_infos[1].tag.attributes.hl, 'HighlightGroup2')
      assert.are.same(pos_infos[1].extmark.start, { 0, 5 })
      assert.are.same(pos_infos[1].extmark.stop, { 0, 11 })

      -- In insert mode, bounds are eagerly included:
      pos_infos = r:get_tags_at({ 0, 5 }, 'i')
      assert.are.same(#pos_infos, 2)
      assert.are.same(pos_infos[1].tag.attributes.hl, 'HighlightGroup1')
      assert.are.same(pos_infos[2].tag.attributes.hl, 'HighlightGroup2')
    end)
  end)

  it('should return multiple extmarks for overlapping text', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        h('text', { hl = 'HighlightGroup1' }, {
          'Hello',
          h(
            'text',
            { hl = 'HighlightGroup2', extmark = { hl_group = 'HighlightGroup2' } },
            ' World'
          ),
        }),
      }

      local pos_infos = r:get_tags_at { 0, 5 }

      assert.are.same(#pos_infos, 2)
      assert.are.same(pos_infos[1].tag.attributes.hl, 'HighlightGroup2')
      assert.are.same(pos_infos[2].tag.attributes.hl, 'HighlightGroup1')
    end)
  end)

  it('repeated patch_lines calls should not change the buffer content', function()
    local lines = {
      [[{ {]],
      [[    bounds = {]],
      [[      start1 = { 1, 1 },]],
      [[      stop1 = { 4, 1 }]],
      [[    },]],
      [[    end_right_gravity = true,]],
      [[    id = 1,]],
      [[    ns_id = 623,]],
      [[    ns_name = "my.renderer:91",]],
      [[    right_gravity = false]],
      [[  } }]],
      [[]],
    }
    with_buf(lines, function()
      Morph.patch_lines(0, nil, lines)
      assert.are.same(get_lines(), lines)

      Morph.patch_lines(0, lines, lines)
      assert.are.same(get_lines(), lines)

      Morph.patch_lines(0, lines, lines)
      assert.are.same(get_lines(), lines)
    end)
  end)

  it('should fire text-changed events', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_changed_text = ''
      r:render {
        h('text', {
          on_change = function(e) captured_changed_text = e.text end,
        }, {
          'one\n',
          'two\n',
          'three\n',
        }),
      }

      vim.fn.setreg('"', 'bleh')
      vim.cmd [[normal! ggVGp]]
      -- For some reason, the autocmd does not fire in the busted environment.
      -- We'll call the handler ourselves:
      r:_on_text_changed()

      assert.are.same(get_text(), 'bleh')
      assert.are.same(captured_changed_text, 'bleh')

      vim.fn.setreg('"', '')
      vim.cmd [[normal! ggdG]]
      -- We'll call the handler ourselves:
      r:_on_text_changed()

      assert.are.same(get_text(), '')
      assert.are.same(captured_changed_text, '')
    end)

    with_buf({}, function()
      local r = Morph.new(0)
      --- @type string?
      local captured_changed_text = nil
      r:render {
        'prefix:',
        h('text', {
          on_change = function(e) captured_changed_text = e.text end,
        }, {
          'one',
        }),
        'suffix',
      }

      vim.fn.setreg('"', 'bleh')
      vim.api.nvim_win_set_cursor(0, { 1, 9 })
      vim.cmd [[normal! vhhd]]
      -- For some reason, the autocmd does not fire in the busted environment.
      -- We'll call the handler ourselves:
      r:_on_text_changed()

      assert.are.same(get_text(), 'prefix:suffix')
      assert.are.same(captured_changed_text, '')
    end)
  end)

  it('should find tags by position', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        'pre',
        h('text', {
          id = 'outer',
        }, {
          'inner-pre',
          h('text', {
            id = 'inner',
          }, {
            'inner-text',
          }),
          'inner-post',
        }),
        'post',
      }

      local tags = r:get_tags_at { 0, 11 }
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].tag.attributes.id, 'outer')

      tags = r:get_tags_at { 0, 12 }
      assert.are.same(#tags, 2)
      assert.are.same(tags[1].tag.attributes.id, 'inner')
      assert.are.same(tags[2].tag.attributes.id, 'outer')
    end)
  end)

  it('should find tags by id', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        h('text', {
          id = 'outer',
        }, {
          'inner-pre',
          h('text', {
            id = 'inner',
          }, {
            'inner-text',
          }),
          'inner-post',
        }),
        'post',
      }

      local bounds = r:get_tag_bounds 'outer'
      assert.are.same(bounds, { start = { 0, 0 }, stop = { 0, 29 } })

      bounds = r:get_tag_bounds 'inner'
      assert.are.same(bounds, { start = { 0, 9 }, stop = { 0, 19 } })
    end)
  end)

  it('should mount and rerender components', function()
    with_buf({}, function()
      --- @type any
      local leaked_ctx = { app = {}, c1 = {}, c2 = {} }

      --- @param ctx morph.Ctx<{ id: string }, { phase: string, count: integer }>
      local function Counter(ctx)
        if ctx.phase == 'mount' then ctx.state = { phase = ctx.phase, count = 1 } end
        local state = assert(ctx.state)
        state.phase = ctx.phase
        leaked_ctx[ctx.props.id] = ctx

        return {
          { 'Value: ', h.Number({}, tostring(state.count)) },
        }
      end

      --- @param ctx morph.Ctx<{}, { toggle1: boolean, show2: boolean }>
      function App(ctx)
        if ctx.phase == 'mount' then ctx.state = { toggle1 = false, show2 = true } end
        local state = assert(ctx.state)
        leaked_ctx.app = ctx

        return {
          state.toggle1 and 'Toggle1' or h(Counter, { id = 'c1' }, {}),
          '\n',

          state.show2 and {
            '\n',
            h(Counter, { id = 'c2' }, {}),
          },
        }
      end

      local renderer = Morph.new()
      renderer:mount(h(App, {}, {}))

      assert.are.same(get_lines(), {
        'Value: 1',
        '',
        'Value: 1',
      })
      assert.are.same(leaked_ctx.c1.state.phase, 'mount')
      assert.are.same(leaked_ctx.c2.state.phase, 'mount')
      leaked_ctx.app:update { toggle1 = true, show2 = true }
      assert.are.same(get_lines(), {
        'Toggle1',
        '',
        'Value: 1',
      })
      assert.are.same(leaked_ctx.c1.state.phase, 'unmount')
      assert.are.same(leaked_ctx.c2.state.phase, 'update')

      leaked_ctx.app:update { toggle1 = true, show2 = false }
      assert.are.same(get_lines(), {
        'Toggle1',
        '',
      })
      assert.are.same(leaked_ctx.c1.state.phase, 'unmount')
      assert.are.same(leaked_ctx.c2.state.phase, 'unmount')

      leaked_ctx.app:update { toggle1 = false, show2 = true }
      assert.are.same(get_lines(), {
        'Value: 1',
        '',
        'Value: 1',
      })
      assert.are.same(leaked_ctx.c1.state.phase, 'mount')
      assert.are.same(leaked_ctx.c2.state.phase, 'mount')

      leaked_ctx.c1:update { count = 2 }
      assert.are.same(get_lines(), {
        'Value: 2',
        '',
        'Value: 1',
      })
      assert.are.same(leaked_ctx.c1.state.phase, 'update')
      assert.are.same(leaked_ctx.c2.state.phase, 'update')

      leaked_ctx.c2:update { count = 3 }
      assert.are.same(get_lines(), {
        'Value: 2',
        '',
        'Value: 3',
      })
      assert.are.same(leaked_ctx.c1.state.phase, 'update')
      assert.are.same(leaked_ctx.c2.state.phase, 'update')
    end)
  end)
end)
