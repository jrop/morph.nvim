--- @diagnostic disable: need-check-nil, undefined-field, missing-fields

local Morph = require 'morph'
local h = Morph.h
local Pos00 = Morph.Pos00

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
  -- get_elements_at
  --

  it('should return no extmarks for an empty buffer', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local pos_infos = r:get_elements_at { 0, 0 }
      assert.are.same(pos_infos, {})
    end)
  end)

  it('should return correct tags for a given position', function()
    with_buf({}, function()
      local r = Morph.new(0)
      -- Text:
      -- 00000000001
      -- 01234567890
      -- Hello World
      r:render {
        h('text', { hl = 'HighlightGroup1' }, 'Hello'),
        h('text', { hl = 'HighlightGroup2' }, ' World'),
      }

      local tags = r:get_elements_at { 0, 2 }
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].attributes.hl, 'HighlightGroup1')
      assert.are.same(tags[1].extmark.start, Pos00.new(0, 0))
      assert.are.same(tags[1].extmark.stop, Pos00.new(0, 5))
      tags = r:get_elements_at { 0, 4 }
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].attributes.hl, 'HighlightGroup1')
      assert.are.same(tags[1].extmark.start, Pos00.new(0, 0))
      assert.are.same(tags[1].extmark.stop, Pos00.new(0, 5))

      tags = r:get_elements_at { 0, 5 }
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].attributes.hl, 'HighlightGroup2')
      assert.are.same(tags[1].extmark.start, Pos00.new(0, 5))
      assert.are.same(tags[1].extmark.stop, Pos00.new(0, 11))

      -- In insert mode, bounds are eagerly included:
      tags = r:get_elements_at({ 0, 5 }, 'i')
      assert.are.same(#tags, 2)
      assert.are.same(tags[1].attributes.hl, 'HighlightGroup1')
      assert.are.same(tags[2].attributes.hl, 'HighlightGroup2')
    end)
  end)

  it('should return correct tags for elements enclosing empty lines', function()
    with_buf({}, function()
      local r = Morph.new(0)
      -- Text:
      --   012345
      -- 0 Header
      -- 1
      -- 2

      local tag, start0, stop0
      local lines = Morph.markup_to_lines {
        on_tag = function(_tag, _start0, _stop0)
          tag = _tag
          start0 = _start0
          stop0 = _stop0
        end,
        tree = h('text', {}, { 'Header\n\n' }),
      }
      assert.are.same(lines, { 'Header', '', '' })

      r:render(h('text', {}, { 'Header\n\n' }))

      local tags = r:get_elements_at { 0, 2 }
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].extmark.start, Pos00.new(0, 0))
      assert.are.same(tags[1].extmark.stop, Pos00.new(2, 0))
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

      local tags = r:get_elements_at { 0, 5 }

      assert.are.same(#tags, 2)
      assert.are.same(tags[1].attributes.hl, 'HighlightGroup2')
      assert.are.same(tags[2].attributes.hl, 'HighlightGroup1')
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
      [[    ns_name = "morph:91",]],
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

      -- Text:
      --   01234
      -- 0 one
      -- 1 two
      -- 2 three
      -- 3
      r:render {
        h('text', {
          on_change = function(e) captured_changed_text = e.text end,
        }, {
          'one\n',
          'two\n',
          'three\n',
        }),
      }

      local elems = r:get_elements_at { 0, 1 }
      assert.are.same(#elems, 1)
      assert.are.same(elems[1].extmark.start, Pos00.new(0, 0))
      assert.are.same(elems[1].extmark.stop, Pos00.new(3, 0))

      -- New text:
      --   1234
      -- 0 bleh
      vim.fn.setreg('"', 'bleh')
      vim.cmd [[normal! ggVGp]]

      assert.are.same(vim.api.nvim_buf_line_count(0), 1)
      elems = r:get_elements_at { 0, 1 }
      assert.are.same(#elems, 1)

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

      local tags = r:get_elements_at { 0, 11 }
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].attributes.id, 'outer')

      tags = r:get_elements_at { 0, 12 }
      assert.are.same(#tags, 2)
      assert.are.same(tags[1].attributes.id, 'inner')
      assert.are.same(tags[2].attributes.id, 'outer')
    end)
  end)

  it('should return tags sorted from innermost to outermost', function()
    with_buf({}, function()
      local r = Morph.new(0)
      -- Text:
      -- startmiddleinnermostafterend
      r:render {
        h('text', { id = 'level1', hl = 'Level1' }, {
          'start',
          h('text', { id = 'level2', hl = 'Level2' }, {
            'middle',
            h('text', { id = 'level3', hl = 'Level3' }, {
              'innermost',
            }),
            'after',
          }),
          'end',
        }),
      }

      -- Test position in the innermost tag
      local tags = r:get_elements_at { 0, 11 } -- position in 'innermost'
      assert.are.same(#tags, 3)
      assert.are.same(tags[1].attributes.id, 'level3') -- innermost first
      assert.are.same(tags[2].attributes.id, 'level2')
      assert.are.same(tags[3].attributes.id, 'level1') -- outermost last

      -- Test position in middle level
      local tags = r:get_elements_at { 0, 7 } -- position in 'middle'
      assert.are.same(#tags, 2)
      assert.are.same(tags[1].attributes.id, 'level2') -- innermost first
      assert.are.same(tags[2].attributes.id, 'level1') -- outermost last

      -- Test position in outermost level only
      local tags = r:get_elements_at { 0, 2 } -- position in 'start'
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].attributes.id, 'level1')
    end)
  end)

  it('should return correct extmark positions for complex nested structures', function()
    with_buf({}, function()
      local r = Morph.new(0)
      -- Text:
      --    00000000001111111111
      --    0123456789_123456789
      -- 0: Section 1: important
      -- 1: Section 2: critical
      r:render {
        h('text', { id = 'container', hl = 'Container' }, {
          h('text', { id = 'section1', hl = 'Section' }, {
            'Section 1: ',
            h('text', { id = 'highlight1', hl = 'Highlight' }, 'important'),
          }),
          '\n',
          h('text', { id = 'section2', hl = 'Section' }, {
            'Section 2: ',
            h('text', { id = 'highlight2', hl = 'Highlight' }, 'critical'),
          }),
        }),
      }

      -- Test extmark positions:
      local extmarks = r:get_elements_at { 0, 15 } -- position in 'important'
      assert.are.same(#extmarks, 3)
      assert.are.same(extmarks[1].attributes.id, 'highlight1') -- innermost first
      assert.are.same(extmarks[2].attributes.id, 'section1')
      assert.are.same(extmarks[3].attributes.id, 'container') -- outermost last

      -- Verify extmark bounds
      assert.are.same(extmarks[1].extmark.start, Pos00.new(0, 11)) -- highlight1 start
      assert.are.same(extmarks[1].extmark.stop, Pos00.new(0, 20)) -- highlight1 stop
      assert.are.same(extmarks[2].extmark.start, Pos00.new(0, 0)) -- section1 start
      assert.are.same(extmarks[2].extmark.stop, Pos00.new(0, 20)) -- section1 stop
      assert.are.same(extmarks[3].extmark.start, Pos00.new(0, 0)) -- container start
      assert.are.same(extmarks[3].extmark.stop, Pos00.new(1, 19)) -- container stop

      -- Test position in second highlight (after newline)
      extmarks = r:get_elements_at { 1, 15 } -- position in 'critical'
      assert.are.same(#extmarks, 3)
      assert.are.same(extmarks[1].attributes.id, 'highlight2')
      assert.are.same(extmarks[2].attributes.id, 'section2')
      assert.are.same(extmarks[3].attributes.id, 'container')

      -- Test position in section text but not in highlight
      extmarks = r:get_elements_at { 0, 5 } -- position in 'Section 1: '
      assert.are.same(#extmarks, 2)
      assert.are.same(extmarks[1].attributes.id, 'section1')
      assert.are.same(extmarks[2].attributes.id, 'container')
    end)
  end)

  it('should handle complex nested structures with multiple siblings', function()
    with_buf({}, function()
      local r = Morph.new(0)
      -- Text:
      --    00000000001111111111
      --    0123456789_123456789
      -- 0: Section 1: important
      -- 1: Section 2: critical
      r:render {
        h('text', { id = 'container', hl = 'Container' }, {
          h('text', { id = 'section1', hl = 'Section' }, {
            'Section 1: ',
            h('text', { id = 'highlight1', hl = 'Highlight' }, 'important'),
          }),
          '\n',
          h('text', { id = 'section2', hl = 'Section' }, {
            'Section 2: ',
            h('text', { id = 'highlight2', hl = 'Highlight' }, 'critical'),
          }),
        }),
      }

      --- @param id string
      local function get_tag_bounds(id)
        local tag = r:get_element_by_id(id)
        return tag and { start = tag.extmark.start, stop = tag.extmark.stop }
      end

      -- Test positions:
      assert.are.same(get_tag_bounds 'container', {
        start = Pos00.new(0, 0),
        stop = Pos00.new(1, 19),
      })
      assert.are.same(get_tag_bounds 'section1', {
        start = Pos00.new(0, 0),
        stop = Pos00.new(0, 20),
      })
      assert.are.same(get_tag_bounds 'highlight1', {
        start = Pos00.new(0, 11),
        stop = Pos00.new(0, 20),
      })
      assert.are.same(get_tag_bounds 'section2', {
        start = Pos00.new(1, 0),
        stop = Pos00.new(1, 19),
      })
      assert.are.same(get_tag_bounds 'highlight2', {
        start = Pos00.new(1, 11),
        stop = Pos00.new(1, 19),
      })

      local tags = r:get_elements_at { 0, 15 } -- position in 'important'
      assert.are.same(#tags, 3)
      assert.are.same(tags[1].attributes.id, 'highlight1')
      assert.are.same(tags[2].attributes.id, 'section1')
      assert.are.same(tags[3].attributes.id, 'container')

      -- Test position in second highlight (after newline)
      local tags = r:get_elements_at { 1, 15 } -- position in 'critical'
      assert.are.same(#tags, 3)
      assert.are.same(tags[1].attributes.id, 'highlight2')
      assert.are.same(tags[2].attributes.id, 'section2')
      assert.are.same(tags[3].attributes.id, 'container')

      -- Test position in section text but not in highlight
      local tags = r:get_elements_at { 0, 5 } -- position in 'Section 1: '
      assert.are.same(#tags, 2)
      assert.are.same(tags[1].attributes.id, 'section1')
      assert.are.same(tags[2].attributes.id, 'container')
    end)
  end)

  it('should handle tags with same boundaries correctly', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        h('text', { id = 'outer', hl = 'Outer' }, {
          h('text', { id = 'inner', hl = 'Inner' }, {
            'same-bounds',
          }),
        }),
      }

      -- Both tags have the same text bounds, should return both sorted by nesting
      local tags = r:get_elements_at { 0, 5 } -- position in 'same-bounds'
      assert.are.same(#tags, 2)
      assert.are.same(tags[1].attributes.id, 'inner') -- innermost first
      assert.are.same(tags[2].attributes.id, 'outer') -- outermost last
    end)
  end)

  it('should handle empty tags and edge cases', function()
    with_buf({}, function()
      local r = Morph.new(0)
      r:render {
        'prefix',
        h('text', { id = 'empty', hl = 'Empty' }, {}),
        h('text', { id = 'normal', hl = 'Normal' }, 'content'),
        'suffix',
      }

      -- Test position in normal tag
      local tags = r:get_elements_at { 0, 8 } -- position in 'content'
      assert.are.same(#tags, 1)
      assert.are.same(tags[1].attributes.id, 'normal')

      -- Test position at boundary between prefix and empty tag
      local tags = r:get_elements_at { 0, 6 } -- position at start of empty tag
      -- Empty tags might not create extmarks, so this tests the boundary behavior
      assert.is_true(#tags >= 0) -- Should not error, may return 0 or more tags
    end)
  end)

  it('get_elements_at should not get siblings', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text structure:
      --           1111111111222222
      -- 01234567890123456789012345
      -- sibling outer middle inner
      r:render {
        h('text', {
          id = 'sibling',
          on_change = function(e) table.insert(captured_events, { id = 'sibling', text = e.text }) end,
        }, 'sibling'),
        ' ',
        h('text', {
          id = 'outer',
          on_change = function(e) table.insert(captured_events, { id = 'outer', text = e.text }) end,
        }, {
          'outer ',
          h('text', {
            id = 'middle',
          }, {
            'middle ',
            h('text', {
              id = 'inner',
              on_change = function(e)
                table.insert(captured_events, { id = 'inner', text = e.text })
              end,
            }, 'inner'),
          }),
        }),
      }

      local elems = r:get_elements_at { 0, 23 }
      assert.are.same(#elems, 3)
      -- Should return inner, middle, and outer (innermost to outermost)
      assert.are.same(elems[1].attributes.id, 'inner')
      assert.are.same(elems[2].attributes.id, 'middle')
      assert.are.same(elems[3].attributes.id, 'outer')

      -- Test position in sibling - should only return sibling
      local sibling_elems = r:get_elements_at { 0, 3 }
      assert.are.same(#sibling_elems, 1)
      assert.are.same(sibling_elems[1].attributes.id, 'sibling')

      -- Test position in outer but not in nested elements
      local outer_elems = r:get_elements_at { 0, 9 }
      assert.are.same(#outer_elems, 1)
      assert.are.same(outer_elems[1].attributes.id, 'outer')
    end)
  end)

  it('should fire on_change handlers from inner to outer and not affect siblings', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text structure:
      --           1111111111222222
      -- 01234567890123456789012345
      -- sibling outer middle inner
      local function reset_render()
        r:render {
          h('text', {
            id = 'sibling',
            on_change = function(e)
              table.insert(captured_events, { id = 'sibling', text = e.text })
            end,
          }, 'sibling'),
          ' ',
          h('text', {
            id = 'outer',
            on_change = function(e) table.insert(captured_events, { id = 'outer', text = e.text }) end,
          }, {
            'outer ',
            h('text', {
              id = 'middle',
            }, {
              'middle ',
              h('text', {
                id = 'inner',
                on_change = function(e)
                  table.insert(captured_events, { id = 'inner', text = e.text })
                end,
              }, 'inner'),
            }),
          }),
        }
      end
      reset_render()

      -- Test 1: Change text in the innermost element
      -- This should fire inner handler first, then outer handler
      captured_events = {}

      -- Replace "inner" with "changed"
      vim.api.nvim_buf_set_text(0, 0, 21, 0, 26, { 'changed' })
      assert.are.same(
        vim.api.nvim_buf_get_lines(0, 0, -1, false),
        { 'sibling outer middle changed' }
      )
      -- Text structure:
      --           111111111122222222
      -- 0123456789012345678901234567
      -- sibling outer middle changed
      r:_on_text_changed()

      assert.are.same(#captured_events, 2)
      assert.are.same(captured_events[1].id, 'inner')
      assert.are.same(captured_events[1].text, 'changed')
      assert.are.same(captured_events[2].id, 'outer')
      assert.are.same(captured_events[2].text, 'outer middle changed')

      -- Test 2: Change text in the sibling element
      -- This should only fire the sibling handler, not any of the nested ones
      reset_render()
      captured_events = {}

      -- Replace "sibling" with "modified"
      vim.api.nvim_buf_set_text(0, 0, 0, 0, 7, { 'modified' })
      assert.are.same(
        vim.api.nvim_buf_get_lines(0, 0, -1, false),
        { 'modified outer middle inner' }
      )
      -- Text structure:
      --           1111111111222222222
      -- 01234567890123456789012345678
      -- modified outer middle inner
      r:_on_text_changed()

      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].id, 'sibling')
      assert.are.same(captured_events[1].text, 'modified')

      -- Test 3: Change text in the middle element (which has no handler)
      -- This should only fire the outer handler
      reset_render()
      captured_events = {}

      -- Replace "middle" with "center"
      vim.api.nvim_buf_set_text(0, 0, 14, 0, 20, { 'center' })
      assert.are.same(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'sibling outer center inner' })
      r:_on_text_changed()

      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].id, 'outer')
      assert.are.same(captured_events[1].text, 'outer center inner')
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

      --- @param id string
      local function get_tag_bounds(id)
        local tag = r:get_element_by_id(id)
        return tag and { start = tag.extmark.start, stop = tag.extmark.stop }
      end

      local bounds = get_tag_bounds 'outer'
      assert.are.same(bounds, { start = Pos00.new(0, 0), stop = Pos00.new(0, 29) })

      bounds = get_tag_bounds 'inner'
      assert.are.same(bounds, { start = Pos00.new(0, 9), stop = Pos00.new(0, 19) })
    end)
  end)

  it('should handle components in markup_to_lines', function()
    local mount_calls = {}
    local unmount_calls = {}

    --- @param ctx morph.Ctx<{ name: string }, { value: string }>
    local function TestComponent(ctx)
      if ctx.phase == 'mount' then
        ctx.state = { value = 'Hello ' .. ctx.props.name }
        table.insert(mount_calls, ctx.props.name)
      elseif ctx.phase == 'unmount' then
        table.insert(unmount_calls, ctx.props.name)
      end

      return {
        h('text', { hl = 'TestHL' }, ctx.state.value),
        '!',
      }
    end

    local tree = {
      'Prefix: ',
      h(TestComponent, { name = 'World' }, {}),
      ' Suffix',
    }

    local lines = Morph.markup_to_lines { tree = tree }

    -- Check that the text is correct
    assert.are.same(lines, { 'Prefix: Hello World! Suffix' })

    -- Check that component was mounted and then unmounted
    assert.are.same(mount_calls, { 'World' })
    assert.are.same(unmount_calls, { 'World' })
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

  --
  -- _expr_map_callback tests
  --

  it('should handle key-presses only in defined regions', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text
      -- 00000000011111111112222
      -- 01345678901234567890123
      -- prefix clickable suffix
      r:render {
        'prefix ',
        h('text', {
          id = 'clickable',
          nmap = {
            ['<CR>'] = function(e)
              table.insert(captured_events, { tag_id = e.tag.attributes.id, key = e.lhs })
              return ''
            end,
          },
        }, 'clickable'),
        ' suffix',
      }

      -- Test keypress inside the clickable region
      vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- position in 'clickable'
      local result = r:_expr_map_callback('n', '<CR>')
      assert.are.same(result, '')
      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].tag_id, 'clickable')
      assert.are.same(captured_events[1].key, '<CR>')

      -- Test keypress outside the clickable region (in prefix)
      captured_events = {}
      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- position in 'prefix'
      local result = r:_expr_map_callback('n', '<CR>')
      assert.are.same(result, '<CR>') -- should return the original key
      assert.are.same(#captured_events, 0) -- no events captured

      -- Test keypress outside the clickable region (in suffix)
      captured_events = {}
      vim.api.nvim_win_set_cursor(0, { 1, 17 }) -- position in 'suffix'
      local result = r:_expr_map_callback('n', '<CR>')
      assert.are.same(result, '<CR>') -- should return the original key
      assert.are.same(#captured_events, 0) -- no events captured
    end)
  end)

  it('should handle multiple overlapping regions with different key-maps', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text
      -- 00000000001111111111
      -- 01234567890123456789
      -- outer inner text end
      r:render {
        h('text', {
          id = 'outer',
          nmap = {
            ['x'] = function(e)
              table.insert(
                captured_events,
                { tag_id = e.tag.attributes.id, key = e.lhs, bubble = e.bubble_up }
              )
              return 'outer-x'
            end,
          },
        }, {
          'outer ',
          h('text', {
            id = 'inner',
            nmap = {
              ['x'] = function(e)
                table.insert(
                  captured_events,
                  { tag_id = e.tag.attributes.id, key = e.lhs, bubble = e.bubble_up }
                )
                return 'inner-x'
              end,
            },
          }, 'inner'),
          ' text',
        }),
        ' end',
      }

      -- Test keypress in inner region - should trigger inner handler first
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- position in 'inner'
      local result = r:_expr_map_callback('n', 'x')
      assert.are.same(result, 'inner-x')
      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].tag_id, 'inner')

      -- Test keypress in outer region but not inner
      captured_events = {}
      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- position in 'outer '
      local result = r:_expr_map_callback('n', 'x')
      assert.are.same(result, 'outer-x')
      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].tag_id, 'outer')

      -- Test keypress outside both regions
      captured_events = {}
      vim.api.nvim_win_set_cursor(0, { 1, 18 }) -- position in ' end'
      local result = r:_expr_map_callback('n', 'x')
      assert.are.same(result, 'x') -- should return original key
      assert.are.same(#captured_events, 0)
    end)
  end)

  it('should handle bubble_up behavior correctly', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text:
      -- 000000000011111
      -- 012345678901234
      -- start inner end
      -- --------------- outer
      --       -----     inner
      r:render {
        h('text', {
          id = 'outer',
          nmap = {
            ['b'] = function(e)
              table.insert(captured_events, { tag_id = e.tag.attributes.id, key = e.lhs })
              return 'b'
            end,
          },
        }, {
          'start ',
          h('text', {
            id = 'inner',
            nmap = {
              ['b'] = function(e)
                table.insert(captured_events, { tag_id = e.tag.attributes.id, key = e.lhs })
                e.bubble_up = true -- allow bubbling to outer
                return ''
              end,
            },
          }, 'inner'),
          ' end',
        }),
      }

      -- Test bubble up behavior
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- position in 'inner'
      local result = r:_expr_map_callback('n', 'b')
      assert.are.same(result, 'b')
      assert.are.same(#captured_events, 2)
      assert.are.same(captured_events[1].tag_id, 'inner')
      assert.are.same(captured_events[2].tag_id, 'outer')
    end)
  end)

  it('should handle no bubble_up behavior correctly', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text:
      -- 000000000011111
      -- 012345678901234
      -- start inner end
      -- --------------- outer
      --       -----     inner
      r:render {
        h('text', {
          id = 'outer',
          nmap = {
            ['c'] = function(e)
              table.insert(captured_events, { tag_id = e.tag.attributes.id, key = e.lhs })
              return 'outer-handled'
            end,
          },
        }, {
          'start ',
          h('text', {
            id = 'inner',
            nmap = {
              ['c'] = function(e)
                table.insert(captured_events, { tag_id = e.tag.attributes.id, key = e.lhs })
                e.bubble_up = false -- prevent bubbling
                return 'inner-handled'
              end,
            },
          }, 'inner'),
          ' end',
        }),
      }

      -- Test no bubble up behavior
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- position in 'inner'
      local result = r:_expr_map_callback('n', 'c')
      assert.are.same(result, 'inner-handled')
      assert.are.same(#captured_events, 1) -- only inner should be called
      assert.are.same(captured_events[1].tag_id, 'inner')
    end)
  end)

  it('should handle different modes correctly', function()
    with_buf({}, function()
      local r = Morph.new(0)
      local captured_events = {}

      -- Text:
      -- 0123
      -- text
      r:render {
        h('text', {
          id = 'multi-mode',
          nmap = {
            ['m'] = function(e)
              table.insert(captured_events, { tag_id = e.tag.attributes.id, mode = e.mode })
              return 'normal-mode'
            end,
          },
          imap = {
            ['m'] = function(e)
              table.insert(captured_events, { tag_id = e.tag.attributes.id, mode = e.mode })
              return 'insert-mode'
            end,
          },
        }, 'text'),
      }

      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- position in 'text'

      -- Test normal mode
      local result = r:_expr_map_callback('n', 'm')
      assert.are.same(result, 'normal-mode')
      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].mode, 'n')

      -- Test insert mode
      captured_events = {}
      local result = r:_expr_map_callback('i', 'm')
      assert.are.same(result, 'insert-mode')
      assert.are.same(#captured_events, 1)
      assert.are.same(captured_events[1].mode, 'i')

      -- Test mode that has no handler
      captured_events = {}
      local result = r:_expr_map_callback('v', 'm')
      assert.are.same(result, 'm') -- should return original key
      assert.are.same(#captured_events, 0)
    end)
  end)

  it('should handle empty keypress cancellation', function()
    with_buf({}, function()
      local r = Morph.new(0)

      -- Text:
      -- 00000000001111111
      -- 01234567890123456
      -- cancelable normal
      -- ----------        #cancel-key
      r:render {
        h('text', {
          id = 'cancel-key',
          nmap = {
            ['z'] = function()
              return '' -- cancel the keypress
            end,
          },
        }, 'cancelable'),
        ' normal',
      }

      -- Test keypress cancellation in the region
      vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- position in 'cancelable'
      local result = r:_expr_map_callback('n', 'z')
      assert.are.same(result, '')

      -- Test normal keypress outside the region
      vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- position in ' normal'
      local result = r:_expr_map_callback('n', 'z')
      assert.are.same(result, 'z') -- should return original key
    end)
  end)
end)
