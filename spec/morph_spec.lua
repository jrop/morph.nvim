--- @diagnostic disable: need-check-nil, undefined-field, missing-fields, redundant-parameter, param-type-mismatch

vim.print(tostring(vim.version()))

-- Set NVIM_TEST to enable testing of internal functions
vim.env.NVIM_TEST = 'true'

local Morph = require 'morph'
local h = Morph.h
local Pos00 = Morph.Pos00
local Extmark = Morph.Extmark

--------------------------------------------------------------------------------
-- TEST HELPERS
--------------------------------------------------------------------------------

local function get_lines() return vim.api.nvim_buf_get_lines(0, 0, -1, true) end
local function get_text() return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, true)):join '\n' end
local function line_count() return vim.api.nvim_buf_line_count(0) end

--- @param start_row integer
--- @param start_col integer
--- @param end_row integer
--- @param end_col integer
--- @param repl string[]
local function set_text(start_row, start_col, end_row, end_col, repl)
  vim.api.nvim_buf_set_text(0, start_row, start_col, end_row, end_col, repl)
end

--- @param pos [integer, integer]
local function set_cursor(pos) vim.api.nvim_win_set_cursor(0, pos) end

--- Execute a test within a temporary buffer that is cleaned up afterward.
local function with_buf(lines, f)
  vim.go.swapfile = false
  vim.cmd.new()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local ok, result = pcall(f)
  vim.cmd.bdelete { bang = true }
  if not ok then error(result) end
end

--------------------------------------------------------------------------------
-- ASSERTION HELPERS
--------------------------------------------------------------------------------

--- Assert that get_elements_at returns elements with the expected IDs (in order).
--- @param renderer morph.Morph
--- @param pos [integer, integer]
--- @param expected_ids string[]
local function assert_elements_at(renderer, pos, expected_ids)
  local elements = renderer:get_elements_at(pos)
  local actual_ids = vim.tbl_map(function(e) return e.attributes.id end, elements)
  assert.are.same(expected_ids, actual_ids)
end

--- Assert that an element has the expected start and stop positions.
--- @param renderer morph.Morph
--- @param id string
--- @param expected_start table
--- @param expected_stop table
local function assert_element_bounds(renderer, id, expected_start, expected_stop)
  local elem = renderer:get_element_by_id(id)
  assert.is_not_nil(elem, 'Element with id "' .. id .. '" not found')
  assert.are.same(expected_start, elem.extmark.start)
  assert.are.same(expected_stop, elem.extmark.stop)
end

--------------------------------------------------------------------------------
-- REUSABLE COMPONENT FIXTURES
--------------------------------------------------------------------------------

--- Creates a component that captures its context for later inspection.
--- @param captured_contexts table<string, morph.Ctx> Table to store contexts by id
--- @return fun(ctx: morph.Ctx<{id: string}, {count: integer}>): morph.Tree
local function make_counter(captured_contexts)
  return function(ctx)
    if ctx.phase == 'mount' then ctx.state = { phase = ctx.phase, count = 1 } end
    local state = assert(ctx.state)
    state.phase = ctx.phase
    captured_contexts[ctx.props.id] = ctx
    return { { 'Value: ', h.Number({}, tostring(state.count)) } }
  end
end

--------------------------------------------------------------------------------
-- TESTS
--------------------------------------------------------------------------------

describe('Morph', function()
  ------------------------------------------------------------------------------
  -- BASIC RENDERING
  ------------------------------------------------------------------------------

  describe('basic rendering', function()
    it('renders text in an empty buffer', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'hello', ' ', 'world' }
        assert.are.same({ 'hello world' }, get_lines())
      end)
    end)

    it('reconciles correctly across multiple renders', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'hello', ' ', 'world' }
        assert.are.same({ 'hello world' }, get_lines())

        r:render { 'goodbye', ' ', 'world' }
        assert.are.same({ 'goodbye world' }, get_lines())

        r:render { 'hello', ' ', 'universe' }
        assert.are.same({ 'hello universe' }, get_lines())
      end)
    end)

    it('renders h() tags with highlight groups', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', { hl = 'HighlightGroup' }, 'hello '),
          h('text', { hl = 'HighlightGroup' }, 'world'),
        }
        assert.are.same({ 'hello world' }, get_lines())
      end)
    end)

    it('renders numbers as strings', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'count: ', 42 }
        assert.are.same({ 'count: 42' }, get_lines())
      end)
    end)

    it('renders negative and decimal numbers', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'negative: ', -5, ', decimal: ', 3.14 }
        assert.are.same({ 'negative: -5, decimal: 3.14' }, get_lines())
      end)
    end)

    it('renders numbers within tags', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', { hl = 'Number' }, { 'Value: ', 123 }),
        }
        assert.are.same({ 'Value: 123' }, get_lines())
      end)
    end)

    it('treats vim.NIL as nil (produces no output)', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'before', vim.NIL, 'after' }
        assert.are.same({ 'beforeafter' }, get_lines())
      end)
    end)

    it('treats boolean false and true as nil (produces no output)', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'before', false, 'after' }
        assert.are.same({ 'beforeafter' }, get_lines())

        r:render { 'start', true, 'end' }
        assert.are.same({ 'startend' }, get_lines())
      end)
    end)

    it('flattens deeply nested arrays', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          { { { 'deep' } } },
          { { 'medium' } },
          { 'shallow' },
        }
        assert.are.same({ 'deepmediumshallow' }, get_lines())
      end)
    end)

    it('handles empty content gracefully', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {}
        assert.are.same({ '' }, get_lines())
      end)
    end)

    it('handles tree with only newlines', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { '\n\n\n' }
        assert.are.same({ '', '', '', '' }, get_lines())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- LINE MANAGEMENT
  ------------------------------------------------------------------------------

  describe('line management', function()
    it('adds lines when content grows', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'line 1', '\n', 'line 2' }
        assert.are.same({ 'line 1', 'line 2' }, get_lines())

        r:render { 'line 1', '\n', 'line 2\n', 'line 3' }
        assert.are.same({ 'line 1', 'line 2', 'line 3' }, get_lines())
      end)
    end)

    it('removes lines when content shrinks', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'line 1', '\nline 2', '\nline 3' }
        assert.are.same({ 'line 1', 'line 2', 'line 3' }, get_lines())

        r:render { 'line 1', '\nline 3' }
        assert.are.same({ 'line 1', 'line 3' }, get_lines())
      end)
    end)

    it('handles multiple consecutive newlines', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'line1\n\n\nline4' }
        assert.are.same({ 'line1', '', '', 'line4' }, get_lines())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- NESTED ELEMENTS
  ------------------------------------------------------------------------------

  describe('nested elements', function()
    it('renders and updates nested h() tags', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', {}, { 'first line' }),
          '\n',
          h('text', {}, 'second line'),
        }
        assert.are.same({ 'first line', 'second line' }, get_lines())

        r:render {
          h('text', {}, 'updated first line'),
          '\n',
          h('text', {}, 'third line'),
        }
        assert.are.same({ 'updated first line', 'third line' }, get_lines())
      end)
    end)

    it('renders h.HighlightGroup shorthand with nested children', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h.Comment({}, {
            'comment start ',
            h.String({}, 'string'),
            ' comment end',
          }),
        }
        assert.are.same('comment start string comment end', get_text())

        local comment_elem = r:get_elements_at { 0, 0 }
        assert.are.same(1, #comment_elem)
        assert.are.same('Comment', comment_elem[1].attributes.hl)

        local string_elem = r:get_elements_at { 0, 14 }
        assert.are.same(2, #string_elem)
        assert.are.same('String', string_elem[1].attributes.hl)
        assert.are.same('Comment', string_elem[2].attributes.hl)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- PATCH_LINES
  ------------------------------------------------------------------------------

  describe('patch_lines', function()
    it('is idempotent when content unchanged', function()
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
        assert.are.same(lines, get_lines())

        Morph.patch_lines(0, lines, lines)
        assert.are.same(lines, get_lines())

        Morph.patch_lines(0, lines, lines)
        assert.are.same(lines, get_lines())
      end)
    end)

    it('handles complete content replacement', function()
      with_buf({ 'old line 1', 'old line 2', 'old line 3' }, function()
        Morph.patch_lines(0, { 'old line 1', 'old line 2', 'old line 3' }, { 'new content' })
        assert.are.same({ 'new content' }, get_lines())
      end)
    end)

    it('handles expanding content', function()
      with_buf({ 'single' }, function()
        Morph.patch_lines(0, { 'single' }, { 'line 1', 'line 2', 'line 3', 'line 4' })
        assert.are.same({ 'line 1', 'line 2', 'line 3', 'line 4' }, get_lines())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- GET_ELEMENTS_AT
  --
  -- Tests for querying elements at cursor positions. Elements are returned
  -- sorted from innermost to outermost.
  ------------------------------------------------------------------------------

  describe('get_elements_at', function()
    it('returns empty array for empty buffer', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local pos_infos = r:get_elements_at { 0, 0 }
        assert.are.same({}, pos_infos)
      end)
    end)

    it('returns empty array for position beyond buffer end', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { h('text', { id = 'tag' }, 'short') }

        local elems = r:get_elements_at { 0, 100 }
        assert.are.same(0, #elems)

        elems = r:get_elements_at { 10, 0 }
        assert.are.same(0, #elems)
      end)
    end)

    it('returns correct element for position within bounds', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Text:
        --   00000000001
        --   01234567890
        --   Hello World
        r:render {
          h('text', { hl = 'HighlightGroup1' }, 'Hello'),
          h('text', { hl = 'HighlightGroup2' }, ' World'),
        }

        local tags = r:get_elements_at { 0, 2 }
        assert.are.same(1, #tags)
        assert.are.same('HighlightGroup1', tags[1].attributes.hl)
        assert.are.same(Pos00.new(0, 0), tags[1].extmark.start)
        assert.are.same(Pos00.new(0, 5), tags[1].extmark.stop)

        tags = r:get_elements_at { 0, 4 }
        assert.are.same(1, #tags)
        assert.are.same('HighlightGroup1', tags[1].attributes.hl)
        assert.are.same(Pos00.new(0, 0), tags[1].extmark.start)
        assert.are.same(Pos00.new(0, 5), tags[1].extmark.stop)

        tags = r:get_elements_at { 0, 5 }
        assert.are.same(1, #tags)
        assert.are.same('HighlightGroup2', tags[1].attributes.hl)
        assert.are.same(Pos00.new(0, 5), tags[1].extmark.start)
        assert.are.same(Pos00.new(0, 11), tags[1].extmark.stop)
      end)
    end)

    it('includes both adjacent elements in insert mode', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Text:
        --   00000000001
        --   01234567890
        --   Hello World
        r:render {
          h('text', { hl = 'HighlightGroup1' }, 'Hello'),
          h('text', { hl = 'HighlightGroup2' }, ' World'),
        }

        local tags = r:get_elements_at({ 0, 5 }, 'i')
        assert.are.same(2, #tags)
        assert.are.same('HighlightGroup1', tags[1].attributes.hl)
        assert.are.same('HighlightGroup2', tags[2].attributes.hl)
      end)
    end)

    it('returns elements enclosing empty lines', function()
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
        assert.are.same({ 'Header', '', '' }, lines)

        r:render(h('text', {}, { 'Header\n\n' }))

        local tags = r:get_elements_at { 0, 2 }
        assert.are.same(1, #tags)
        assert.are.same(Pos00.new(0, 0), tags[1].extmark.start)
        assert.are.same(Pos00.new(2, 0), tags[1].extmark.stop)
      end)
    end)

    it('returns multiple elements for overlapping text (innermost first)', function()
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
        assert.are.same(2, #tags)
        assert.are.same('HighlightGroup2', tags[1].attributes.hl)
        assert.are.same('HighlightGroup1', tags[2].attributes.hl)
      end)
    end)

    it('returns elements sorted innermost to outermost for nested tags', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Text:
        --   00000000001111111111222222222
        --   0123456789012345678901234567890
        --   startmiddleinnermostafterend
        r:render {
          h('text', { id = 'level1', hl = 'Level1' }, {
            'start',
            h('text', { id = 'level2', hl = 'Level2' }, {
              'middle',
              h('text', { id = 'level3', hl = 'Level3' }, { 'innermost' }),
              'after',
            }),
            'end',
          }),
        }

        -- Position in 'innermost' -> all three levels
        assert_elements_at(r, { 0, 11 }, { 'level3', 'level2', 'level1' })

        -- Position in 'middle' -> two levels
        assert_elements_at(r, { 0, 7 }, { 'level2', 'level1' })

        -- Position in 'start' -> outermost only
        assert_elements_at(r, { 0, 2 }, { 'level1' })
      end)
    end)

    it('excludes sibling elements (only returns ancestors)', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Text:
        --   0123456789012345678901234567890
        --   preinner-preinner-textinner-postpost
        r:render {
          'pre',
          h('text', { id = 'outer' }, {
            'inner-pre',
            h('text', { id = 'inner' }, { 'inner-text' }),
            'inner-post',
          }),
          'post',
        }

        local tags = r:get_elements_at { 0, 11 }
        assert.are.same(1, #tags)
        assert.are.same('outer', tags[1].attributes.id)

        tags = r:get_elements_at { 0, 12 }
        assert.are.same(2, #tags)
        assert.are.same('inner', tags[1].attributes.id)
        assert.are.same('outer', tags[2].attributes.id)
      end)
    end)

    it('does not return sibling elements in complex nested structures', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_events = {}

        -- Text:
        --   0         1         2
        --   0123456789012345678901234567890
        --   sibling outer middle inner
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
            h('text', { id = 'middle' }, {
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

        -- Position in 'inner' -> inner, middle, outer (not sibling)
        assert_elements_at(r, { 0, 23 }, { 'inner', 'middle', 'outer' })

        -- Position in 'sibling' -> sibling only
        assert_elements_at(r, { 0, 3 }, { 'sibling' })

        -- Position in 'outer ' text -> outer only
        assert_elements_at(r, { 0, 9 }, { 'outer' })
      end)
    end)

    it('handles tags with same boundaries (both returned, inner first)', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', { id = 'outer', hl = 'Outer' }, {
            h('text', { id = 'inner', hl = 'Inner' }, { 'same-bounds' }),
          }),
        }

        local tags = r:get_elements_at { 0, 5 }
        assert.are.same(2, #tags)
        assert.are.same('inner', tags[1].attributes.id)
        assert.are.same('outer', tags[2].attributes.id)
      end)
    end)

    it('handles empty tags at boundaries', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          'prefix',
          h('text', { id = 'empty', hl = 'Empty' }, {}),
          h('text', { id = 'normal', hl = 'Normal' }, 'content'),
          'suffix',
        }

        local tags = r:get_elements_at { 0, 8 }
        assert.are.same(1, #tags)
        assert.are.same('normal', tags[1].attributes.id)

        tags = r:get_elements_at { 0, 6 }
        assert.is_true(#tags >= 0) -- Should not error
      end)
    end)

    it('returns correct extmark positions for complex nested structures', function()
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
        assert.are.same(3, #extmarks)
        assert.are.same('highlight1', extmarks[1].attributes.id) -- innermost first
        assert.are.same('section1', extmarks[2].attributes.id)
        assert.are.same('container', extmarks[3].attributes.id) -- outermost last

        -- Verify extmark bounds
        assert.are.same(Pos00.new(0, 11), extmarks[1].extmark.start) -- highlight1 start
        assert.are.same(Pos00.new(0, 20), extmarks[1].extmark.stop) -- highlight1 stop
        assert.are.same(Pos00.new(0, 0), extmarks[2].extmark.start) -- section1 start
        assert.are.same(Pos00.new(0, 20), extmarks[2].extmark.stop) -- section1 stop
        assert.are.same(Pos00.new(0, 0), extmarks[3].extmark.start) -- container start
        assert.are.same(Pos00.new(1, 19), extmarks[3].extmark.stop) -- container stop

        -- Test position in second highlight (after newline)
        extmarks = r:get_elements_at { 1, 15 } -- position in 'critical'
        assert.are.same(3, #extmarks)
        assert.are.same('highlight2', extmarks[1].attributes.id)
        assert.are.same('section2', extmarks[2].attributes.id)
        assert.are.same('container', extmarks[3].attributes.id)

        -- Test position in section text but not in highlight
        extmarks = r:get_elements_at { 0, 5 } -- position in 'Section 1: '
        assert.are.same(2, #extmarks)
        assert.are.same('section1', extmarks[1].attributes.id)
        assert.are.same('container', extmarks[2].attributes.id)
      end)
    end)

    it('handles complex nested structures with multiple siblings', function()
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

        -- Test positions via get_element_by_id:
        assert.are.same(
          { start = Pos00.new(0, 0), stop = Pos00.new(1, 19) },
          get_tag_bounds 'container'
        )
        assert.are.same(
          { start = Pos00.new(0, 0), stop = Pos00.new(0, 20) },
          get_tag_bounds 'section1'
        )
        assert.are.same(
          { start = Pos00.new(0, 11), stop = Pos00.new(0, 20) },
          get_tag_bounds 'highlight1'
        )
        assert.are.same(
          { start = Pos00.new(1, 0), stop = Pos00.new(1, 19) },
          get_tag_bounds 'section2'
        )
        assert.are.same(
          { start = Pos00.new(1, 11), stop = Pos00.new(1, 19) },
          get_tag_bounds 'highlight2'
        )

        local tags = r:get_elements_at { 0, 15 } -- position in 'important'
        assert.are.same(3, #tags)
        assert.are.same('highlight1', tags[1].attributes.id)
        assert.are.same('section1', tags[2].attributes.id)
        assert.are.same('container', tags[3].attributes.id)

        -- Test position in second highlight (after newline)
        tags = r:get_elements_at { 1, 15 } -- position in 'critical'
        assert.are.same(3, #tags)
        assert.are.same('highlight2', tags[1].attributes.id)
        assert.are.same('section2', tags[2].attributes.id)
        assert.are.same('container', tags[3].attributes.id)

        -- Test position in section text but not in highlight
        tags = r:get_elements_at { 0, 5 } -- position in 'Section 1: '
        assert.are.same(2, #tags)
        assert.are.same('section1', tags[1].attributes.id)
        assert.are.same('container', tags[2].attributes.id)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- GET_ELEMENT_BY_ID
  ------------------------------------------------------------------------------

  describe('get_element_by_id', function()
    it('finds element by id', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', { id = 'outer' }, {
            'inner-pre',
            h('text', { id = 'inner' }, { 'inner-text' }),
            'inner-post',
          }),
          'post',
        }

        assert_element_bounds(r, 'outer', Pos00.new(0, 0), Pos00.new(0, 29))
        assert_element_bounds(r, 'inner', Pos00.new(0, 9), Pos00.new(0, 19))
      end)
    end)

    it('returns nil for non-existent id', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { h('text', { id = 'exists' }, 'content') }

        assert.is_not_nil(r:get_element_by_id 'exists')
        assert.is_nil(r:get_element_by_id 'does-not-exist')
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- EXTMARK EDGE CASES
  ------------------------------------------------------------------------------

  describe('extmark edge cases', function()
    it('handles extmarks at buffer boundaries', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', { id = 'start-boundary' }, 'start'),
          ' middle ',
          h('text', { id = 'end-boundary' }, 'end'),
        }

        assert.are.same({ 'start middle end' }, get_lines())
        assert_element_bounds(r, 'start-boundary', Pos00.new(0, 0), Pos00.new(0, 5))
        assert_element_bounds(r, 'end-boundary', Pos00.new(0, 13), Pos00.new(0, 16))

        r:render {
          'prefix ',
          h('text', { id = 'buffer-end' }, 'at-end'),
        }

        assert_element_bounds(r, 'buffer-end', Pos00.new(0, 7), Pos00.new(0, 13))
      end)
    end)

    it('handles zero-width extmarks', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_events = {}

        r:render {
          'before',
          h('text', {
            id = 'zero-width',
            on_change = function(e)
              table.insert(captured_events, { id = 'zero-width', text = e.text })
            end,
          }, ''),
          'after',
        }

        assert.are.same({ 'beforeafter' }, get_lines())

        local zero_elem = r:get_element_by_id 'zero-width'
        assert.is_not_nil(zero_elem)
        assert.are.same(Pos00.new(0, 6), zero_elem.extmark.start)
        assert.are.same(Pos00.new(0, 6), zero_elem.extmark.stop)

        -- Can detect zero-width extmark at its position
        local elements = r:get_elements_at { 0, 6 }
        assert.are.same(1, #elements)
        assert.are.same('zero-width', elements[1].attributes.id)

        -- Inserting text triggers on_change
        set_text(0, 6, 0, 6, { 'inserted' })
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('beforeinsertedafter', get_text())
        assert.are.same(1, #captured_events)
        assert.are.same('inserted', captured_events[1].text)
      end)
    end)

    it('handles extmark spanning multiple lines', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render {
          h('text', { id = 'multiline' }, {
            'line 1\n',
            'line 2\n',
            'line 3',
          }),
        }

        assert.are.same({ 'line 1', 'line 2', 'line 3' }, get_lines())

        local elem = r:get_element_by_id 'multiline'
        assert.is_not_nil(elem)
        assert.are.same(Pos00.new(0, 0), elem.extmark.start)
        assert.are.same(Pos00.new(2, 6), elem.extmark.stop)
        assert.are.same('line 1\nline 2\nline 3', elem.extmark:_text())
      end)
    end)

    it('handles blank lines at end of buffer text', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_changed_text = ''

        r:render {
          h('text', {
            on_change = function(e) captured_changed_text = e.text end,
          }, {
            'line 1\n',
            'line 2\n',
            '\n',
          }),
        }

        assert.are.same({ 'line 1', 'line 2', '', '' }, get_lines())

        local elems = r:get_elements_at { 0, 1 }
        assert.are.same(1, #elems)
        assert.are.same(Pos00.new(0, 0), elems[1].extmark.start)
        assert.are.same(Pos00.new(3, 0), elems[1].extmark.stop)

        -- extmark:_text() handles blank lines at end correctly
        assert.are.same('line 1\nline 2\n\n', elems[1].extmark:_text())

        set_text(0, 0, 3, 0, { 'modified content' })
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('modified content', get_text())
        assert.are.same('modified content', captured_changed_text)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- MULTI-BYTE CHARACTER HANDLING
  ------------------------------------------------------------------------------

  describe('multi-byte characters', function()
    it('calculates correct extmark boundaries for emojis, CJK, and combining chars', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local emoji_text = '🚀🌟'
        local cjk_text = '你好世界'
        local combining_text = 'é' -- e + combining acute accent

        r:render {
          h('text', { id = 'emoji-tag' }, emoji_text),
          ' ',
          h('text', { id = 'cjk-tag' }, cjk_text),
          ' ',
          h('text', { id = 'combining-tag' }, combining_text),
        }

        local expected_text = emoji_text .. ' ' .. cjk_text .. ' ' .. combining_text
        assert.are.same(expected_text, get_text())

        local emoji_elem = r:get_element_by_id 'emoji-tag'
        local cjk_elem = r:get_element_by_id 'cjk-tag'
        local combining_elem = r:get_element_by_id 'combining-tag'

        assert.is_not_nil(emoji_elem)
        assert.is_not_nil(cjk_elem)
        assert.is_not_nil(combining_elem)

        assert.are.same(emoji_text, emoji_elem.extmark:_text())
        assert.are.same(cjk_text, cjk_elem.extmark:_text())
        assert.are.same(combining_text, combining_elem.extmark:_text())
      end)
    end)

    it('handles cursor positioning in multi-byte sequences', function()
      with_buf({}, function()
        local r = Morph.new(0)

        r:render {
          'ASCII',
          h('text', { id = 'mixed', hl = 'Test' }, '🎯中文'),
          'more',
        }

        assert.are.same('ASCII🎯中文more', get_text())

        local mixed_elem = r:get_element_by_id 'mixed'
        assert.is_not_nil(mixed_elem)

        local elements_at_start = r:get_elements_at { 0, 5 }
        assert.are.same(1, #elements_at_start)
        assert.are.same('mixed', elements_at_start[1].attributes.id)

        local elements_in_middle = r:get_elements_at { 0, 7 }
        if #elements_in_middle > 0 then
          assert.are.same('mixed', elements_in_middle[1].attributes.id)
        end
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- ON_CHANGE EVENTS
  --
  -- Tests for text change detection and event bubbling.
  ------------------------------------------------------------------------------

  describe('on_change events', function()
    it('fires when text is replaced', function()
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
        assert.are.same(1, #elems)
        assert.are.same(Pos00.new(0, 0), elems[1].extmark.start)
        assert.are.same(Pos00.new(3, 0), elems[1].extmark.stop)

        vim.fn.setreg('"', 'bleh')
        vim.cmd [[normal! ggVGp]]

        assert.are.same(1, line_count())
        elems = r:get_elements_at { 0, 1 }
        assert.are.same(1, #elems)

        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('bleh', get_text())
        assert.are.same('bleh', captured_changed_text)

        vim.fn.setreg('"', '')
        vim.cmd [[normal! ggdG]]
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('', get_text())
        assert.are.same('', captured_changed_text)
      end)
    end)

    it('fires when text is deleted', function()
      with_buf({}, function()
        local r = Morph.new(0)
        --- @type string?
        local captured_changed_text = nil
        r:render {
          'prefix:',
          h('text', {
            on_change = function(e) captured_changed_text = e.text end,
          }, { 'one' }),
          'suffix',
        }

        vim.fn.setreg('"', 'bleh')
        set_cursor { 1, 9 }
        vim.cmd [[normal! vhhd]]
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('prefix:suffix', get_text())
        assert.are.same('', captured_changed_text)
      end)
    end)

    it('fires when newline is inserted', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_changed_text = nil

        r:render {
          'Search [',
          h('text', {
            on_change = function(e) captured_changed_text = e.text end,
          }, 'filter'),
          ']',
        }

        assert.are.same({ 'Search [filter]' }, get_lines())

        set_text(0, 14, 0, 14, { '', '' })
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same({ 'Search [filter', ']' }, get_lines())
        assert.are.same('filter\n', captured_changed_text)
      end)
    end)

    it('fires with empty string when tag text is deleted entirely', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_changed_text = nil

        -- Text structure: "Search: input_text"
        -- The input tag is at the end of the line
        r:render {
          'Search: ',
          h('text', {
            on_change = function(e) captured_changed_text = e.text end,
          }, 'input_text'),
        }

        assert.are.same({ 'Search: input_text' }, get_lines())

        -- Delete the input text at the end of the line
        -- This should trigger on_change with an empty string
        set_text(0, 8, 0, 18, {})
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('Search: ', get_text())
        assert.are.same('', captured_changed_text)

        -- Test with different end position
        r:render {
          'Filter: ',
          h('text', {
            on_change = function(e) captured_changed_text = e.text end,
          }, 'query'),
        }

        captured_changed_text = nil
        assert.are.same({ 'Filter: query' }, get_lines())

        -- Delete just the query part
        set_text(0, 8, 0, 13, {})
        vim.cmd.doautocmd 'TextChanged'

        assert.are.same('Filter: ', get_text())
        assert.are.same('', captured_changed_text)
      end)
    end)

    it('detects change when new text has same length as original', function()
      with_buf({}, function()
        local captured_changed_text = ''

        --- @param _ctx morph.Ctx
        local function App(_ctx)
          return {
            h('text', {
              id = 'the-id',
              on_change = function(e)
                e.bubble_up = false
                captured_changed_text = e.text
              end,
            }, { 'hello' }),
          }
        end
        local r = Morph.new()
        r:mount(h(App))

        assert.are.same('hello', get_text())

        set_text(0, 4, 0, 5, { 'p' })
        vim.cmd.doautocmd 'TextChanged'
        assert.are.same('hellp', get_text())
        assert.are.same('hellp', captured_changed_text)
      end)
    end)

    it('detects change when text changes back to original content', function()
      with_buf({}, function()
        local captured_changed_text = ''

        --- @param _ctx morph.Ctx
        local function App2(_ctx)
          return {
            h('text', {
              id = 'the-id',
              on_change = function(e)
                e.bubble_up = false
                captured_changed_text = e.text
              end,
            }, { 'hello' }),
          }
        end
        local r = Morph.new()
        r:mount(h(App2))

        assert.are.same('hello', get_text())

        set_text(0, 4, 0, 5, {})
        assert.are.same('hell', get_text())
        vim.cmd.doautocmd 'TextChanged'
        assert.are.same('hell', captured_changed_text)

        set_text(0, 4, 0, 4, { 'o' })
        assert.are.same('hello', get_text())
        vim.cmd.doautocmd 'TextChanged'
        assert.are.same('hello', captured_changed_text)
      end)
    end)

    describe('event bubbling', function()
      it('fires handlers from inner to outer, not affecting siblings', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local captured_events = {}

          -- Text:
          --   0         1         2
          --   0123456789012345678901234567890
          --   sibling outer middle inner
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
                on_change = function(e)
                  table.insert(captured_events, { id = 'outer', text = e.text })
                end,
              }, {
                'outer ',
                h('text', { id = 'middle' }, {
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

          -- Change innermost element -> fires inner then outer
          captured_events = {}
          set_text(0, 21, 0, 26, { 'changed' })
          assert.are.same({ 'sibling outer middle changed' }, get_lines())
          vim.cmd.doautocmd 'TextChanged'

          assert.are.same(2, #captured_events)
          assert.are.same('inner', captured_events[1].id)
          assert.are.same('changed', captured_events[1].text)
          assert.are.same('outer', captured_events[2].id)
          assert.are.same('outer middle changed', captured_events[2].text)

          -- Change sibling -> only sibling handler fires
          reset_render()
          captured_events = {}
          set_text(0, 0, 0, 7, { 'modified' })
          assert.are.same({ 'modified outer middle inner' }, get_lines())
          vim.cmd.doautocmd 'TextChanged'

          assert.are.same(1, #captured_events)
          assert.are.same('sibling', captured_events[1].id)
          assert.are.same('modified', captured_events[1].text)

          -- Change middle (no handler) -> only outer handler fires
          reset_render()
          captured_events = {}
          set_text(0, 14, 0, 20, { 'center' })
          assert.are.same({ 'sibling outer center inner' }, get_lines())
          vim.cmd.doautocmd 'TextChanged'

          assert.are.same(1, #captured_events)
          assert.are.same('outer', captured_events[1].id)
          assert.are.same('outer center inner', captured_events[1].text)
        end)
      end)

      it('bubbles through multiple nested levels', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local events = {}

          r:render {
            h('text', {
              id = 'level1',
              on_change = function(e) table.insert(events, { level = 1, text = e.text }) end,
            }, {
              h('text', {
                id = 'level2',
                on_change = function(e) table.insert(events, { level = 2, text = e.text }) end,
              }, {
                h('text', {
                  id = 'level3',
                  on_change = function(e) table.insert(events, { level = 3, text = e.text }) end,
                }, 'inner'),
              }),
            }),
          }

          set_text(0, 0, 0, 5, { 'changed' })
          vim.cmd.doautocmd 'TextChanged'

          assert.are.same(3, #events)
          assert.are.same(3, events[1].level)
          assert.are.same(2, events[2].level)
          assert.are.same(1, events[3].level)
        end)
      end)

      it('stops bubbling when bubble_up is set to false', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local events = {}

          r:render {
            h('text', {
              id = 'outer',
              on_change = function(e) table.insert(events, { id = 'outer', text = e.text }) end,
            }, {
              h('text', {
                id = 'inner',
                on_change = function(e)
                  table.insert(events, { id = 'inner', text = e.text })
                  e.bubble_up = false
                end,
              }, 'text'),
            }),
          }

          set_text(0, 0, 0, 4, { 'new' })
          vim.cmd.doautocmd 'TextChanged'

          assert.are.same(1, #events)
          assert.are.same('inner', events[1].id)
        end)
      end)
    end)

    it('handles inverted extmark positions gracefully', function()
      -- This test verifies that extmark positions becoming inverted
      -- (start > stop) is handled gracefully by returning empty string.
      -- The error message was:
      --   (morph.nvim:getregion:invalid-pos) { start, end } = { { 9, 4, 1 }, { 9, 3, 9 } }
      -- Note how line 4 > line 3, which is inverted.
      with_buf({ 'line1', 'line2', 'line3' }, function()
        -- Create an Extmark directly with inverted positions (start > stop)
        -- This simulates what happens when extmarks get corrupted
        local extmark = {
          bufnr = 0,
          ns = vim.api.nvim_create_namespace 'test',
          -- Inverted: start at row 2, stop at row 1 (0-based)
          -- This is the bug condition
          start = Pos00.new(2, 0),
          stop = Pos00.new(1, 5),
        }
        setmetatable(extmark, { __index = Extmark })

        -- Calling _text() with inverted positions should return empty string
        local result = extmark:_text()

        assert.are.equal(
          '',
          result,
          'Extmark:_text() should handle inverted positions gracefully (return empty string), but got: '
            .. vim.inspect(result)
        )
      end)
    end)
  end)

  -- Bug: Deleting trailing blank line causes getregion invalid-pos error
  -- Error: (morph.nvim:getregion:invalid-pos) { start, end } = { { 9, 4, 1 }, { 9, 3, 9 } }
  --
  -- Root cause: Extmark._from_raw clamps stop but NOT start.
  -- When an extmark's start is past buffer end after deletion, we get start > stop.

  it('clamps extmark start position to buffer bounds', function()
    with_buf({}, function()
      local ns = vim.api.nvim_create_namespace 'test_extmark_clamp'

      -- Buffer: 4 lines (0-3)
      vim.api.nvim_buf_set_lines(0, 0, -1, true, { 'line 0', 'line 1', 'line 2', '' })
      assert.are.same(4, line_count())

      -- Extmark at line 3 (the last line)
      local ext_id = vim.api.nvim_buf_set_extmark(0, ns, 3, 0, { end_row = 3, end_col = 0 })

      -- Delete the last line → buffer now has 3 lines (0-2)
      vim.api.nvim_buf_set_lines(0, 3, 4, true, {})
      assert.are.same(3, line_count())

      -- Neovim returns extmark with stale position (line 3 doesn't exist)
      local raw = vim.api.nvim_buf_get_extmark_by_id(0, ns, ext_id, { details = true })
      local start_row, start_col, details = raw[1], raw[2], raw[3]

      -- BUG: _from_raw clamps stop to buffer bounds but NOT start
      local extmark = Extmark._from_raw(0, ns, ext_id, start_row, start_col, details)

      -- start should be clamped to valid buffer line
      local last_line_idx = line_count() - 1
      assert.is_true(
        extmark.start[1] <= last_line_idx,
        ('extmark.start[1] (%d) should be <= last_line_idx (%d)'):format(
          extmark.start[1],
          last_line_idx
        )
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- KEYPRESS DISPATCH
  --
  -- Tests for _dispatch_keypress routing keypresses to element handlers.
  ------------------------------------------------------------------------------

  describe('keypress dispatch', function()
    it('returns original key when no elements at cursor', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'plain text without handlers' }

        set_cursor { 1, 5 }
        local result = r:_dispatch_keypress('n', '<CR>')
        assert.are.same('<CR>', result)
      end)
    end)

    it('only triggers handlers in defined regions', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_events = {}

        -- Text:
        --   0         1         2
        --   01345678901234567890123
        --   prefix clickable suffix
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

        -- Inside clickable region
        set_cursor { 1, 12 }
        local result = r:_dispatch_keypress('n', '<CR>')
        assert.are.same('', result)
        assert.are.same(1, #captured_events)
        assert.are.same('clickable', captured_events[1].tag_id)
        assert.are.same('<CR>', captured_events[1].key)

        -- In prefix (outside)
        captured_events = {}
        set_cursor { 1, 2 }
        result = r:_dispatch_keypress('n', '<CR>')
        assert.are.same('<CR>', result)
        assert.are.same(0, #captured_events)

        -- In suffix (outside)
        captured_events = {}
        set_cursor { 1, 17 }
        result = r:_dispatch_keypress('n', '<CR>')
        assert.are.same('<CR>', result)
        assert.are.same(0, #captured_events)
      end)
    end)

    it('triggers innermost handler first for overlapping regions', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_events = {}

        -- Text:
        --   0         1
        --   01234567890123456789
        --   outer inner text end
        r:render {
          h('text', {
            id = 'outer',
            nmap = {
              ['x'] = function(e)
                table.insert(captured_events, { tag_id = e.tag.attributes.id })
                return 'outer-x'
              end,
            },
          }, {
            'outer ',
            h('text', {
              id = 'inner',
              nmap = {
                ['x'] = function(e)
                  table.insert(captured_events, { tag_id = e.tag.attributes.id })
                  return 'inner-x'
                end,
              },
            }, 'inner'),
            ' text',
          }),
          ' end',
        }

        -- In inner region
        set_cursor { 1, 8 }
        local result = r:_dispatch_keypress('n', 'x')
        assert.are.same('inner-x', result)
        assert.are.same(1, #captured_events)
        assert.are.same('inner', captured_events[1].tag_id)

        -- In outer region but not inner
        captured_events = {}
        set_cursor { 1, 2 }
        result = r:_dispatch_keypress('n', 'x')
        assert.are.same('outer-x', result)
        assert.are.same(1, #captured_events)
        assert.are.same('outer', captured_events[1].tag_id)

        -- Outside both regions
        captured_events = {}
        set_cursor { 1, 18 }
        result = r:_dispatch_keypress('n', 'x')
        assert.are.same('x', result)
        assert.are.same(0, #captured_events)
      end)
    end)

    describe('event bubbling', function()
      it('bubbles to outer when bubble_up is true', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local captured_events = {}

          -- Text:
          --   0         1
          --   012345678901234
          --   start inner end
          r:render {
            h('text', {
              id = 'outer',
              nmap = {
                ['b'] = function(e)
                  table.insert(captured_events, { tag_id = e.tag.attributes.id })
                  return 'b'
                end,
              },
            }, {
              'start ',
              h('text', {
                id = 'inner',
                nmap = {
                  ['b'] = function(e)
                    table.insert(captured_events, { tag_id = e.tag.attributes.id })
                    e.bubble_up = true
                    return ''
                  end,
                },
              }, 'inner'),
              ' end',
            }),
          }

          set_cursor { 1, 8 }
          local result = r:_dispatch_keypress('n', 'b')
          assert.are.same('b', result)
          assert.are.same(2, #captured_events)
          assert.are.same('inner', captured_events[1].tag_id)
          assert.are.same('outer', captured_events[2].tag_id)
        end)
      end)

      it('stops at inner when bubble_up is false', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local captured_events = {}

          r:render {
            h('text', {
              id = 'outer',
              nmap = {
                ['c'] = function(e)
                  table.insert(captured_events, { tag_id = e.tag.attributes.id })
                  return 'outer-handled'
                end,
              },
            }, {
              'start ',
              h('text', {
                id = 'inner',
                nmap = {
                  ['c'] = function(e)
                    table.insert(captured_events, { tag_id = e.tag.attributes.id })
                    e.bubble_up = false
                    return 'inner-handled'
                  end,
                },
              }, 'inner'),
              ' end',
            }),
          }

          set_cursor { 1, 8 }
          local result = r:_dispatch_keypress('n', 'c')
          assert.are.same('inner-handled', result)
          assert.are.same(1, #captured_events)
          assert.are.same('inner', captured_events[1].tag_id)
        end)
      end)
    end)

    describe('mode-specific handlers', function()
      it('uses nmap for normal mode and imap for insert mode', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local captured_events = {}

          r:render {
            h('text', {
              id = 'multi-mode',
              nmap = {
                ['m'] = function(e)
                  table.insert(captured_events, { mode = e.mode })
                  return 'normal-mode'
                end,
              },
              imap = {
                ['m'] = function(e)
                  table.insert(captured_events, { mode = e.mode })
                  return 'insert-mode'
                end,
              },
            }, 'text'),
          }

          set_cursor { 1, 2 }

          local result = r:_dispatch_keypress('n', 'm')
          assert.are.same('normal-mode', result)
          assert.are.same(1, #captured_events)
          assert.are.same('n', captured_events[1].mode)

          captured_events = {}
          result = r:_dispatch_keypress('i', 'm')
          assert.are.same('insert-mode', result)
          assert.are.same(1, #captured_events)
          assert.are.same('i', captured_events[1].mode)

          -- Mode with no handler returns original key
          captured_events = {}
          result = r:_dispatch_keypress('v', 'm')
          assert.are.same('m', result)
          assert.are.same(0, #captured_events)
        end)
      end)
    end)

    it('cancels keypress when handler returns empty string', function()
      with_buf({}, function()
        local r = Morph.new(0)

        -- Text:
        --   0         1
        --   01234567890123456
        --   cancelable normal
        r:render {
          h('text', {
            id = 'cancel-key',
            nmap = { ['z'] = function() return '' end },
          }, 'cancelable'),
          ' normal',
        }

        set_cursor { 1, 3 }
        local result = r:_dispatch_keypress('n', 'z')
        assert.are.same('', result)

        set_cursor { 1, 12 }
        result = r:_dispatch_keypress('n', 'z')
        assert.are.same('z', result)
      end)
    end)

    it('triggers handler on trailing empty line when element ends with newline', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local handler_called = false

        -- Buffer has single element ending with newline:
        --   Line 0: "hello"
        --   Line 1: "" (empty, from trailing \n)
        -- Extmark covers (0,0) to (1,0)
        r:render {
          h('text', {
            id = 'with-newline',
            nmap = {
              ['<CR>'] = function()
                handler_called = true
                return ''
              end,
            },
          }, 'hello\n'),
        }

        assert.are.same({ 'hello', '' }, get_lines())

        -- Cursor on the trailing empty line should still trigger the handler
        set_cursor { 2, 0 } -- 1-based: row 2, col 0 (the empty line)
        local result = r:_dispatch_keypress('n', '<CR>')

        assert.are.same('', result)
        assert.is_true(handler_called, 'Handler should be called on trailing empty line')
      end)
    end)

    it('triggers second element handler when first ends with newline and second follows', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local first_called = false
        local second_called = false

        -- Buffer:
        --   Line 0: "hello"
        --   Line 1: "world"
        -- Element 'first': (0,0) to (1,0) - ends at start of line 1
        -- Element 'second': (1,0) to (1,5) - covers "world"
        r:render {
          h('text', {
            id = 'first',
            nmap = {
              ['<CR>'] = function()
                first_called = true
                return 'first'
              end,
            },
          }, 'hello\n'),
          h('text', {
            id = 'second',
            nmap = {
              ['<CR>'] = function()
                second_called = true
                return 'second'
              end,
            },
          }, 'world'),
        }

        assert.are.same({ 'hello', 'world' }, get_lines())

        -- Cursor at start of "world" line - should be in second element only
        set_cursor { 2, 0 } -- 1-based: row 2, col 0
        local result = r:_dispatch_keypress('n', '<CR>')

        assert.are.same('second', result)
        assert.is_false(first_called, 'First handler should NOT be called')
        assert.is_true(second_called, 'Second handler should be called')

        -- Verify get_elements_at returns only second element in normal mode
        local elems = r:get_elements_at { 1, 0 } -- 0-based
        assert.are.same(1, #elems)
        assert.are.same('second', elems[1].attributes.id)
      end)
    end)

    it('returns both elements at boundary in insert mode', function()
      with_buf({}, function()
        local r = Morph.new(0)

        -- Same setup: first element ends with newline, second follows
        r:render {
          h('text', { id = 'first' }, 'hello\n'),
          h('text', { id = 'second' }, 'world'),
        }

        assert.are.same({ 'hello', 'world' }, get_lines())

        -- In insert mode, cursor at boundary should see both elements
        local elems = r:get_elements_at({ 1, 0 }, 'i') -- 0-based, insert mode
        assert.are.same(2, #elems)
        -- Second element is "innermost" (starts at cursor), first is "outer" (ends at cursor)
        local ids = vim.tbl_map(function(e) return e.attributes.id end, elems)
        assert.is_true(vim.tbl_contains(ids, 'first'))
        assert.is_true(vim.tbl_contains(ids, 'second'))
      end)
    end)

    it('does not trigger first element on non-empty line even if extmark ends there', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local first_called = false

        -- Element 'first' ends at (1,0) but line 1 has content
        r:render {
          h('text', {
            id = 'first',
            nmap = {
              ['x'] = function()
                first_called = true
                return ''
              end,
            },
          }, 'hello\n'),
          'world', -- plain text, no handler
        }

        assert.are.same({ 'hello', 'world' }, get_lines())

        -- Cursor on "world" line - first element's handler should NOT fire
        set_cursor { 2, 0 }
        local result = r:_dispatch_keypress('n', 'x')

        -- Should return original key (no handler matched)
        assert.are.same('x', result)
        assert.is_false(first_called)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- KEYMAP MANAGEMENT
  ------------------------------------------------------------------------------

  describe('keymap management', function()
    it('cleans up keymaps without error when no original mapping existed', function()
      with_buf({}, function()
        local leaked_context
        local function TestComponent(ctx)
          leaked_context = ctx
          if ctx.phase == 'mount' then ctx.state = 1 end

          if ctx.state == 1 then
            return h('text', {
              nmap = { ['<Leader>nonexistent'] = function() return '' end },
            }, { 'with keymap' })
          else
            return h('text', {}, { 'without keymap' })
          end
        end

        local r = Morph.new(0)
        r:mount(h(TestComponent))
        assert.are.same('with keymap', get_text())

        local mapping = vim.fn.maparg('<Leader>nonexistent', 'n', false, true)
        assert.is_false(vim.tbl_isempty(mapping))

        assert.has_no.errors(function() leaked_context:update(2) end)
        assert.are.same('without keymap', get_text())

        mapping = vim.fn.maparg('<Leader>nonexistent', 'n', false, true)
        assert.is_true(vim.tbl_isempty(mapping))
      end)
    end)

    it('restores original keymaps when component unmounts', function()
      with_buf({}, function()
        local my_orig_callback = function() end
        local my_component_callback_count = 0
        local my_component_callback = function()
          my_component_callback_count = my_component_callback_count + 1
        end
        vim.keymap.set('n', '<Leader>abc', my_orig_callback, { buffer = true })

        local leaked_context
        local function TestComponent(ctx)
          leaked_context = ctx
          if ctx.phase == 'mount' then ctx.state = 1 end

          if ctx.state == 1 then
            return h('text', {
              nmap = { ['<Leader>abc'] = my_component_callback },
            }, { 'Hello World!' })
          else
            return h('text', {}, { 'Hello World (II)!' })
          end
        end

        local r = Morph.new(0)
        local result = r:_dispatch_keypress('n', '<Leader>abc')
        assert.are.same('<Leader>abc', result)
        assert.are.same(0, my_component_callback_count)

        r:mount(h(TestComponent))
        assert.are.same('Hello World!', get_text())
        assert.are_not.same(
          my_orig_callback,
          vim.fn.maparg('<Leader>abc', 'n', false, true).callback
        )

        result = r:_dispatch_keypress('n', '<Leader>abc')
        assert.are.same(nil, result)
        assert.are.same(1, my_component_callback_count)

        leaked_context:update(2)
        assert.are.same('Hello World (II)!', get_text())

        result = r:_dispatch_keypress('n', '<Leader>abc')
        assert.are.same('<Leader>abc', result)
        assert.are.same(my_orig_callback, vim.fn.maparg('<Leader>abc', 'n', false, true).callback)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- KEYED LIST RECONCILIATION
  ------------------------------------------------------------------------------

  describe('keyed list reconciliation', function()
    it('correctly identifies same component across renders', function()
      with_buf({}, function()
        local mount_count = {}
        local app_ctx

        --- @param ctx morph.Ctx<{ key: string }, { count: integer }>
        local function Counter(ctx)
          if ctx.phase == 'mount' then
            mount_count[ctx.props.key] = (mount_count[ctx.props.key] or 0) + 1
            ctx.state = { count = 1 }
          end
          return h('text', { key = ctx.props.key }, { 'Count: ' .. ctx.state.count })
        end

        --- @param ctx morph.Ctx<{}, { items: {key: string, comp: morph.Component}[] }>
        local function App(ctx)
          app_ctx = ctx
          if ctx.phase == 'mount' then
            ctx.state = {
              items = {
                { key = 'a', comp = Counter },
                { key = 'b', comp = Counter },
              },
            }
          end
          return vim.tbl_map(
            function(item) return h(item.comp, { key = item.key }, {}) end,
            ctx.state.items
          )
        end

        local r = Morph.new()
        r:mount(h(App))

        -- Re-render with same components - should reuse contexts
        local old_items = app_ctx.state.items
        app_ctx:update { items = old_items }

        -- Each component should have been mounted only once
        assert.are.same(1, mount_count.a, 'Component a should be mounted once')
        assert.are.same(1, mount_count.b, 'Component b should be mounted once')
      end)
    end)

    it('correctly handles reordering of keyed components', function()
      with_buf({}, function()
        local key_to_init_value = {
          a = 1,
          b = 2,
          c = 3,
        }
        local app_ctx

        --- @param ctx morph.Ctx<{ key: string }, { value: integer }>
        local function Counter(ctx)
          if ctx.phase == 'mount' then ctx.state = { value = key_to_init_value[ctx.props.key] } end
          return h('text', { key = ctx.props.key }, { ctx.props.key .. ': ' .. ctx.state.value })
        end

        --- @param ctx morph.Ctx<{}, { order: string[] }>
        local function App(ctx)
          app_ctx = ctx
          if ctx.phase == 'mount' then ctx.state = { order = { 'a', 'b', 'c' } } end
          return vim.tbl_map(function(id) return h(Counter, { key = id }, {}) end, ctx.state.order)
        end

        local r = Morph.new()
        r:mount(h(App))
        assert.are.same({ 'a: 1b: 2c: 3' }, get_lines())

        -- Reverse order - components should be reused
        app_ctx:update { order = { 'c', 'b', 'a' } }
        assert.are.same({ 'c: 3b: 2a: 1' }, get_lines())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- UNDO/REDO
  ------------------------------------------------------------------------------

  describe('undo/redo', function()
    it('tracks extmarks correctly through undo/redo', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local captured_changed_text = ''

        --- @param _ctx morph.Ctx
        local function App(_ctx)
          return {
            'Search: [',
            h('text', {
              id = 'filter',
              on_change = function(e) captured_changed_text = e.text end,
            }, ''),
            ']',
          }
        end

        r:mount(h(App))
        local filter_elem = assert(r:get_element_by_id 'filter')
        assert.are.same('Search: []', get_text())
        assert.are.same('', filter_elem.extmark:_text())
        set_cursor { filter_elem.extmark.start[1] + 1, filter_elem.extmark.start[2] }

        vim.api.nvim_feedkeys('ifilter', 'ntx', false)
        vim.cmd.doautocmd 'TextChanged'
        assert.are.same('filter', captured_changed_text)

        filter_elem = assert(r:get_element_by_id 'filter')
        assert.are.same('filter', filter_elem.extmark:_text())
        assert.are.same('Search: [filter]', get_text())

        vim.cmd.undo()
        assert.are.same('Search: []', get_text())
        vim.cmd.doautocmd 'TextChanged'
        assert.are.same('', captured_changed_text)

        filter_elem = assert(r:get_element_by_id 'filter')
        assert.are.same('', filter_elem.extmark:_text())

        vim.cmd.redo()
        vim.cmd.doautocmd 'TextChanged'
        assert.are.same('filter', captured_changed_text)

        filter_elem = assert(r:get_element_by_id 'filter')
        assert.are.same('filter', filter_elem.extmark:_text())
        assert.are.same('Search: [filter]', get_text())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- MOUNT MULTIPLE TIMES
  ------------------------------------------------------------------------------

  describe('mount multiple times', function()
    it('throws error on second mount call', function()
      with_buf({}, function()
        --- @param ctx morph.Ctx<{}, { text: string }>
        local function App(ctx)
          if ctx.phase == 'mount' then ctx.state = { text = 'initial' } end
          return h('text', {}, { ctx.state.text })
        end

        local r = Morph.new()
        r:mount(h(App))

        local ok, err = pcall(function() r:mount(h(App)) end)

        assert.is_false(ok, 'Second mount should fail')
        assert.is_not_nil(err, 'Error should be thrown')
        assert.is_not_nil(err:match 'once per buffer', 'Should show helpful error message')
      end)
    end)

    it('throws error when second Morph instance mounts on same buffer', function()
      with_buf({}, function()
        --- @param ctx morph.Ctx<{}, { text: string }>
        local function App(ctx)
          if ctx.phase == 'mount' then ctx.state = { text = 'initial' } end
          return h('text', {}, { ctx.state.text })
        end

        local r1 = Morph.new()
        r1:mount(h(App))

        local r2 = Morph.new()
        local ok, err = pcall(function() r2:mount(h(App)) end)

        assert.is_false(ok, 'Second Morph instance should fail')
        assert.is_not_nil(err, 'Error should be thrown')
        assert.is_not_nil(err:match 'once per buffer', 'Should show helpful error message')
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- COMPONENT LIFECYCLE
  ------------------------------------------------------------------------------

  describe('component lifecycle', function()
    describe('mount phase', function()
      it('calls component with phase=mount on first render', function()
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
        assert.are.same({ 'Prefix: Hello World! Suffix' }, lines)
        assert.are.same({ 'World' }, mount_calls)
        assert.are.same({ 'World' }, unmount_calls)
      end)

      it('executes do_after_render callbacks immediately after mount', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local callback_executed = false
          local callback_execution_order = {}

          --- @param ctx morph.Ctx
          local function TestComponent(ctx)
            if ctx.phase == 'mount' then
              ctx:do_after_render(function()
                callback_executed = true
                table.insert(callback_execution_order, 'callback')
              end)
              table.insert(callback_execution_order, 'component-render')
            end
            return { h('text', { id = 'test-text' }, 'Hello World') }
          end

          r:mount(h(TestComponent))
          table.insert(callback_execution_order, 'after-mount')

          assert.is_true(callback_executed)
          assert.are.same({
            'component-render',
            'callback',
            'after-mount',
          }, callback_execution_order)
          assert.are.same('Hello World', get_text())
        end)
      end)

      it('executes multiple do_after_render callbacks in registration order', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local execution_order = {}

          --- @param ctx morph.Ctx
          local function TestComponent(ctx)
            if ctx.phase == 'mount' then
              ctx:do_after_render(function() table.insert(execution_order, 'first') end)
              ctx:do_after_render(function() table.insert(execution_order, 'second') end)
              ctx:do_after_render(function() table.insert(execution_order, 'third') end)
            end
            return { h('text', { id = 'test' }, 'Multiple callbacks') }
          end

          r:mount(h(TestComponent))

          assert.are.same({ 'first', 'second', 'third' }, execution_order)
        end)
      end)

      it(
        'executes do_after_render callbacks even when update is called during update phase',
        function()
          with_buf({}, function()
            local callback_executed = false
            local capture_ctx

            --- @param ctx morph.Ctx<{}, { open: boolean, updated: boolean }>
            local function ComponentWithCallback(ctx)
              if ctx.phase == 'mount' then
                ctx.state = { open = false, updated = false }
                capture_ctx = ctx
              end
              -- Only schedule callback and call update on the first update when open becomes true
              if ctx.state.open and ctx.phase == 'update' and not ctx.state.updated then
                ctx:do_after_render(function() callback_executed = true end)
                -- Mark as updated to prevent infinite loop
                ctx.state.updated = true
                ctx:update(ctx.state)
              end
              return { ctx.state.open and 'open' or 'closed' }
            end

            local r = Morph.new(0)
            r:mount(h(ComponentWithCallback))
            assert.are.same('closed', get_text())
            assert.is_false(callback_executed)

            -- Now trigger the update that causes the issue
            capture_ctx.state.open = true
            capture_ctx:refresh()

            -- The callback should have been executed
            assert.is_true(
              callback_executed,
              'do_after_render callback should be executed even when ctx:update is called during update phase'
            )
          end)
        end
      )

      it('does not re-render when update called during mount phase', function()
        with_buf({}, function()
          local render_count = 0

          --- @param ctx morph.Ctx<{}, { value: number }>
          local function TestComponent(ctx)
            render_count = render_count + 1
            if ctx.phase == 'mount' then
              ctx.state = { value = 1 }
              ctx:update { value = 2 }
            end
            return { 'Value: ' .. ctx.state.value }
          end

          local r = Morph.new(0)
          r:mount(h(TestComponent))

          assert.are.same(1, render_count)
          assert.are.same('Value: 2', get_text())
        end)
      end)
    end)

    describe('update phase', function()
      it('re-renders components when state changes', function()
        with_buf({}, function()
          --- @diagnostic disable-next-line: assign-type-mismatch
          local leaked_ctx = { app = {}, c1 = {}, c2 = {} } --- @type table<string, morph.Ctx>
          local Counter = make_counter(leaked_ctx)

          --- @param ctx morph.Ctx<{}, { toggle1: boolean, show2: boolean }>
          local function App(ctx)
            if ctx.phase == 'mount' then ctx.state = { toggle1 = false, show2 = true } end
            leaked_ctx.app = ctx
            return {
              ctx.state.toggle1 and 'Toggle1' or h(Counter, { id = 'c1' }, {}),
              '\n',
              ctx.state.show2 and { '\n', h(Counter, { id = 'c2' }, {}) },
            }
          end

          local renderer = Morph.new()
          renderer:mount(h(App, {}, {}))

          assert.are.same({ 'Value: 1', '', 'Value: 1' }, get_lines())
          assert.are.same('mount', leaked_ctx.c1.state.phase)
          assert.are.same('mount', leaked_ctx.c2.state.phase)

          leaked_ctx.app:update { toggle1 = true, show2 = true }
          assert.are.same({ 'Toggle1', '', 'Value: 1' }, get_lines())
          assert.are.same('unmount', leaked_ctx.c1.state.phase)
          assert.are.same('update', leaked_ctx.c2.state.phase)

          leaked_ctx.app:update { toggle1 = true, show2 = false }
          assert.are.same({ 'Toggle1', '' }, get_lines())
          assert.are.same('unmount', leaked_ctx.c1.state.phase)
          assert.are.same('unmount', leaked_ctx.c2.state.phase)

          leaked_ctx.app:update { toggle1 = false, show2 = true }
          assert.are.same({ 'Value: 1', '', 'Value: 1' }, get_lines())
          assert.are.same('mount', leaked_ctx.c1.state.phase)
          assert.are.same('mount', leaked_ctx.c2.state.phase)

          leaked_ctx.c1:update { count = 2 }
          assert.are.same({ 'Value: 2', '', 'Value: 1' }, get_lines())
          assert.are.same('update', leaked_ctx.c1.state.phase)
          assert.are.same('update', leaked_ctx.c2.state.phase)

          leaked_ctx.c2:update { count = 3 }
          assert.are.same({ 'Value: 2', '', 'Value: 3' }, get_lines())
          assert.are.same('update', leaked_ctx.c1.state.phase)
          assert.are.same('update', leaked_ctx.c2.state.phase)
        end)
      end)

      it('persists child state across parent re-renders', function()
        with_buf({}, function()
          local child_ctx_ref

          --- @param ctx morph.Ctx<{}, { count: number }>
          local function Child(ctx)
            if ctx.phase == 'mount' then ctx.state = { count = 0 } end
            child_ctx_ref = ctx
            return { 'Count: ' .. ctx.state.count }
          end

          local parent_ctx_ref
          --- @param ctx morph.Ctx<{}, { label: string }>
          local function Parent(ctx)
            if ctx.phase == 'mount' then ctx.state = { label = 'A' } end
            parent_ctx_ref = ctx
            return {
              'Label: ' .. ctx.state.label .. '\n',
              h(Child),
            }
          end

          local r = Morph.new(0)
          r:mount(h(Parent))

          assert.are.same('Label: A\nCount: 0', get_text())

          child_ctx_ref:update { count = 5 }
          assert.are.same('Label: A\nCount: 5', get_text())

          parent_ctx_ref:update { label = 'B' }
          assert.are.same('Label: B\nCount: 5', get_text())
        end)
      end)

      it('preserves sibling component state when conditional array sibling changes', function()
        -- This tests a bug where sibling components wrapped in arrays get incorrectly
        -- matched during reconciliation when a conditional sibling changes from
        -- false/nil to an array. All plain arrays have identity key 'array', so
        -- the Levenshtein algorithm can match the wrong arrays together, causing
        -- components inside to be unmounted/remounted and lose state.
        with_buf({}, function()
          local services_ctx_ref
          local services_mount_count = 0

          --- @param ctx morph.Ctx<{}, { filter: string }>
          local function Services(ctx)
            if ctx.phase == 'mount' then
              ctx.state = { filter = '' }
              services_mount_count = services_mount_count + 1
            end
            services_ctx_ref = ctx
            return { 'Filter: [' .. ctx.state.filter .. ']' }
          end

          --- @param _ctx morph.Ctx
          local function Help(_ctx) return { 'Help content' } end

          local parent_ctx_ref
          --- @param ctx morph.Ctx<{}, { show_help: boolean }>
          local function App(ctx)
            if ctx.phase == 'mount' then ctx.state = { show_help = false } end
            parent_ctx_ref = ctx
            return {
              'Header\n',
              -- Conditional sibling: false when hidden, array when shown
              ctx.state.show_help and { h(Help), '\n' },
              -- Services wrapped in array - this is the component whose state should persist
              { h(Services) },
            }
          end

          local r = Morph.new(0)
          r:mount(h(App))

          assert.are.same('Header\nFilter: []', get_text())
          assert.are.same(1, services_mount_count, 'Services should mount once initially')

          -- Update Services state
          services_ctx_ref:update { filter = 'docker' }
          assert.are.same('Header\nFilter: [docker]', get_text())

          -- Toggle help ON - this should NOT cause Services to remount
          parent_ctx_ref:update { show_help = true }
          assert.are.same('Header\nHelp content\nFilter: [docker]', get_text())
          assert.are.same(
            1,
            services_mount_count,
            'Services should NOT remount when sibling conditional changes'
          )
          assert.are.same(
            'docker',
            services_ctx_ref.state.filter,
            'Services state should be preserved'
          )

          -- Toggle help OFF - state should still be preserved
          parent_ctx_ref:update { show_help = false }
          assert.are.same('Header\nFilter: [docker]', get_text())
          assert.are.same(1, services_mount_count, 'Services should still not have remounted')
          assert.are.same('docker', services_ctx_ref.state.filter, 'Services state still preserved')
        end)
      end)

      it('handles Ctx:update when on_change is nil without errors', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local leaked_context = nil
          local called = 0

          --- @param ctx morph.Ctx<{}, { count: integer }>
          local function TestComponent(ctx)
            called = called + 1
            if ctx.phase == 'mount' then
              ctx.state = { count = 1 }
              leaked_context = ctx
              ctx.on_change = nil
            end
            return { h('text', { id = 'test-component' }, 'Count: ' .. ctx.state.count) }
          end

          r:mount(h(TestComponent))
          assert.are.same('Count: 1', get_text())
          assert.are.same(1, called)

          local orig_schedule = vim.schedule
          vim.schedule = function(f) return f() end
          assert.has_no.errors(function() leaked_context:update { count = 2 } end)
          vim.schedule = orig_schedule
        end)
      end)

      it('handles state update via do_after_render', function()
        with_buf({}, function()
          local render_count = 0

          --- @param ctx morph.Ctx<{}, { initialized: boolean }>
          local function TestComponent(ctx)
            render_count = render_count + 1
            if ctx.phase == 'mount' then
              ctx.state = { initialized = false }
              ctx:do_after_render(function()
                --- @diagnostic disable-next-line: unnecessary-if
                if not ctx.state.initialized then ctx:update { initialized = true } end
              end)
            end
            return { ctx.state.initialized and 'ready' or 'loading' }
          end

          local r = Morph.new(0)
          local orig_schedule = vim.schedule
          vim.schedule = function(f) f() end

          r:mount(h(TestComponent))

          vim.schedule = orig_schedule

          assert.are.same(2, render_count)
          assert.are.same('ready', get_text())
        end)
      end)
    end)

    describe('unmount phase', function()
      it('unmounts components when buffer is deleted', function()
        local unmount_calls = {}
        local mount_calls = {}

        --- @param ctx morph.Ctx<any, { value: string }>
        local function TestComponent(ctx)
          if ctx.phase == 'mount' then
            table.insert(mount_calls, ctx.props.name)
          elseif ctx.phase == 'unmount' then
            table.insert(unmount_calls, ctx.props.name)
          end
          return { h('text', { id = ctx.props.name }, 'Component ' .. ctx.props.name) }
        end

        --- @param ctx morph.Ctx<{}, { show_second: boolean }>
        local function App(ctx)
          if ctx.phase == 'mount' then
            ctx.state = { show_second = true }
          elseif ctx.phase == 'unmount' then
            table.insert(unmount_calls, 'app')
          end
          return {
            h(TestComponent, { name = 'first' }),
            '\n',
            ctx.state.show_second and h(TestComponent, { name = 'second' }) or nil,
          }
        end

        vim.cmd.new()
        local bufnr = vim.api.nvim_get_current_buf()
        local r = Morph.new(bufnr)
        r:mount(h(App))

        assert.are.same({ 'Component first', 'Component second' }, get_lines())
        assert.is_true(vim.tbl_contains(mount_calls, 'first'))
        assert.is_true(vim.tbl_contains(mount_calls, 'second'))
        assert.are.same({}, unmount_calls)

        vim.api.nvim_buf_delete(bufnr, { force = true })

        assert.is_true(vim.tbl_contains(unmount_calls, 'first'))
        assert.is_true(vim.tbl_contains(unmount_calls, 'second'))
        assert.is_true(vim.tbl_contains(unmount_calls, 'app'))
      end)

      it('unmounts deeply nested components on state change', function()
        with_buf({}, function()
          local r = Morph.new(0)
          local unmount_calls = {}
          local leaked_contexts = {}

          --- @param ctx morph.Ctx<{ name: string }, {}>
          local function Level3Component(ctx)
            if ctx.phase == 'unmount' then
              table.insert(unmount_calls, 'level3-' .. ctx.props.name)
            end
            return { h('text', { id = 'level3-' .. ctx.props.name }, 'Level3: ' .. ctx.props.name) }
          end

          --- @param ctx morph.Ctx<{ name: string }, {}>
          local function Level2Component(ctx)
            if ctx.phase == 'unmount' then
              table.insert(unmount_calls, 'level2-' .. ctx.props.name)
            end
            return {
              h('text', {}, {
                'Level2: ' .. ctx.props.name,
                '\n',
                {
                  h('text', {}, 'Container: '),
                  {
                    h(Level3Component, { name = ctx.props.name .. '-child1' }),
                    '\n',
                    h(Level3Component, { name = ctx.props.name .. '-child2' }),
                  },
                },
              }),
            }
          end

          --- @param ctx morph.Ctx<{ name: string }, {}>
          local function Level1Component(ctx)
            if ctx.phase == 'unmount' then
              table.insert(unmount_calls, 'level1-' .. ctx.props.name)
            end
            return {
              h('text', {}, 'Level1: ' .. ctx.props.name),
              '\n',
              { h(Level2Component, { name = ctx.props.name .. '-sub' }) },
            }
          end

          --- @param ctx morph.Ctx<{}, { show_nested: boolean }>
          local function App(ctx)
            if ctx.phase == 'mount' then
              ctx.state = { show_nested = true }
              leaked_contexts.app = ctx
            elseif ctx.phase == 'unmount' then
              table.insert(unmount_calls, 'app')
            end
            return {
              'App Root',
              '\n',
              ctx.state.show_nested and {
                h(Level1Component, { name = 'main' }),
                '\n',
                h(Level1Component, { name = 'secondary' }),
              } or 'No nested components',
            }
          end

          r:mount(h(App))

          assert.are.same({
            'App Root',
            'Level1: main',
            'Level2: main-sub',
            'Container: Level3: main-sub-child1',
            'Level3: main-sub-child2',
            'Level1: secondary',
            'Level2: secondary-sub',
            'Container: Level3: secondary-sub-child1',
            'Level3: secondary-sub-child2',
          }, get_lines())

          leaked_contexts.app:update { show_nested = false }

          assert.is_true(vim.tbl_contains(unmount_calls, 'level3-main-sub-child1'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level3-main-sub-child2'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level2-main-sub'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level1-main'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level3-secondary-sub-child1'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level3-secondary-sub-child2'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level2-secondary-sub'))
          assert.is_true(vim.tbl_contains(unmount_calls, 'level1-secondary'))

          assert.are.same('App Root\nNo nested components', get_text())

          unmount_calls = {}
          leaked_contexts.app:update { show_nested = true }
          assert.are.same({}, unmount_calls)
        end)
      end)
    end)

    describe('lifecycle transitions', function()
      it('never has illegal transitions (mount->update->unmount only)', function()
        with_buf({}, function()
          local lifecycle_history = {}
          local illegal_transitions = {}

          local legal_transitions = {
            mount = { update = true, unmount = true },
            update = { update = true, unmount = true },
          }

          local TrackedComponent = function(ctx)
            local id = ctx.props.id
            lifecycle_history[id] = lifecycle_history[id] or {}
            local history = lifecycle_history[id]

            if #history > 0 then
              local prev = history[#history]
              local curr = ctx.phase
              if not (legal_transitions[prev] and legal_transitions[prev][curr]) then
                table.insert(illegal_transitions, string.format('%s: %s -> %s', id, prev, curr))
              end
            end

            table.insert(history, ctx.phase)
            return { id }
          end

          local leaked_ctx
          --- @param ctx morph.Ctx<{}, { items: string[] }>
          local function App(ctx)
            if ctx.phase == 'mount' then
              ctx.state = { items = { 'a', 'b' } }
              leaked_ctx = ctx
            end
            return vim.tbl_map(
              function(item) return h(TrackedComponent, { id = item, key = item }) end,
              ctx.state.items
            )
          end

          local r = Morph.new(0)
          r:mount(h(App))

          assert.are.same('ab', get_text())
          assert.are.same({}, illegal_transitions)

          leaked_ctx:update { items = { 'a' } }

          assert.are.same('a', get_text())
          assert.are.same({}, illegal_transitions)

          local a_has_unmount = vim.tbl_contains(lifecycle_history['a'] or {}, 'unmount')
          assert.is_false(a_has_unmount)

          local b_unmounts = vim.tbl_filter(
            function(phase) return phase == 'unmount' end,
            lifecycle_history['b'] or {}
          )
          assert.are.same(1, #b_unmounts)
        end)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- COMPONENT CHILDREN
  ------------------------------------------------------------------------------

  describe('component children', function()
    it('passes children via ctx.children', function()
      with_buf({}, function()
        --- @param ctx morph.Ctx
        local function Wrapper(ctx) return { '[', ctx.children, ']' } end

        local r = Morph.new(0)
        r:mount(h(Wrapper, {}, { 'child content' }))
        assert.are.same('[child content]', get_text())
      end)
    end)

    it('handles component returning empty table', function()
      with_buf({}, function()
        --- @param _ctx morph.Ctx
        local function EmptyComponent(_ctx) return {} end

        local r = Morph.new(0)
        r:mount { 'before', h(EmptyComponent), 'after' }
        assert.are.same('beforeafter', get_text())
      end)
    end)

    it('handles component returning nil', function()
      with_buf({}, function()
        --- @param _ctx morph.Ctx
        local function NilComponent(_ctx) return nil end

        local r = Morph.new(0)
        r:mount { 'before', h(NilComponent), 'after' }
        assert.are.same('beforeafter', get_text())
      end)
    end)

    it('renders numbers in component children', function()
      --- @param ctx morph.Ctx<{ value: number }, {}>
      local function NumberDisplay(ctx)
        return { h('text', { hl = 'Number' }, { 'The value is: ', ctx.props.value }) }
      end

      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(NumberDisplay, { value = 99 }))
        assert.are.same({ 'The value is: 99' }, get_lines())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- KEYED RECONCILIATION
  ------------------------------------------------------------------------------

  describe('keyed reconciliation', function()
    it('uses key attribute for component identity', function()
      with_buf({}, function()
        local mount_count = 0
        local unmount_count = 0

        --- @param ctx morph.Ctx<{ id: string }, {}>
        local function KeyedComponent(ctx)
          if ctx.phase == 'mount' then
            mount_count = mount_count + 1
          elseif ctx.phase == 'unmount' then
            unmount_count = unmount_count + 1
          end
          return { ctx.props.id }
        end

        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { items: string[] }>
        local function App(ctx)
          if ctx.phase == 'mount' then
            ctx.state = { items = { 'a', 'b', 'c' } }
            leaked_ctx = ctx
          end
          return vim.tbl_map(
            function(item) return h(KeyedComponent, { id = item, key = item }) end,
            ctx.state.items
          )
        end

        local r = Morph.new(0)
        r:mount(h(App))

        assert.are.same('abc', get_text())
        assert.are.same(3, mount_count)
        assert.are.same(0, unmount_count)

        -- Same items - no mounts/unmounts
        mount_count = 0
        unmount_count = 0
        leaked_ctx:update { items = { 'a', 'b', 'c' } }

        assert.are.same('abc', get_text())
        assert.are.same(0, mount_count)
        assert.are.same(0, unmount_count)

        -- Different items - remounting occurs
        mount_count = 0
        unmount_count = 0
        leaked_ctx:update { items = { 'x', 'y' } }

        assert.are.same('xy', get_text())
        assert.is_true(mount_count > 0)
        assert.is_true(unmount_count > 0)
      end)
    end)

    it('optimally reconciles when removing items from end', function()
      with_buf({}, function()
        local events = {} --- @type { id: string, phase: string }[]

        --- @param ctx morph.Ctx<{ id: string }, {}>
        local function TrackedComponent(ctx)
          table.insert(events, { id = ctx.props.id, phase = ctx.phase })
          return { ctx.props.id }
        end

        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { items: string[] }>
        local function App(ctx)
          if ctx.phase == 'mount' then
            ctx.state = { items = { 'a', 'b', 'c' } }
            leaked_ctx = ctx
          end
          return vim.tbl_map(
            function(item) return h(TrackedComponent, { id = item, key = item }) end,
            ctx.state.items
          )
        end

        local r = Morph.new(0)
        r:mount(h(App))
        assert.are.same('abc', get_text())

        -- Clear events from initial mount
        events = {}
        leaked_ctx:update { items = { 'a', 'b' } }

        assert.are.same('ab', get_text())

        local mounts = vim.tbl_filter(function(e) return e.phase == 'mount' end, events)
        local unmounts = vim.tbl_filter(function(e) return e.phase == 'unmount' end, events)

        assert.are.same(0, #mounts)
        assert.are.same(1, #unmounts)
        assert.are.same('c', unmounts[1].id)
      end)
    end)

    it('optimally reconciles when removing items from middle', function()
      with_buf({}, function()
        local events = {} --- @type { id: string, phase: string }[]

        --- @param ctx morph.Ctx<{ id: string }, {}>
        local function TrackedComponent(ctx)
          table.insert(events, { id = ctx.props.id, phase = ctx.phase })
          return { ctx.props.id }
        end

        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { items: string[] }>
        local function App(ctx)
          if ctx.phase == 'mount' then
            ctx.state = { items = { 'a', 'b', 'c' } }
            leaked_ctx = ctx
          end
          return vim.tbl_map(
            function(item) return h(TrackedComponent, { id = item, key = item }) end,
            ctx.state.items
          )
        end

        local r = Morph.new(0)
        r:mount(h(App))
        assert.are.same('abc', get_text())

        -- Clear events from initial mount
        events = {}
        leaked_ctx:update { items = { 'a', 'c' } }

        assert.are.same('ac', get_text())

        local mounts = vim.tbl_filter(function(e) return e.phase == 'mount' end, events)
        local unmounts = vim.tbl_filter(function(e) return e.phase == 'unmount' end, events)

        assert.are.same(0, #mounts)
        assert.are.same(1, #unmounts)
        assert.are.same('b', unmounts[1].id)
      end)
    end)

    it('treats same component with different keys as different components', function()
      with_buf({}, function()
        local mount_ids = {}
        local unmount_ids = {}

        --- @param ctx morph.Ctx<{ id: string }, {}>
        local function Item(ctx)
          if ctx.phase == 'mount' then
            table.insert(mount_ids, ctx.props.id)
          elseif ctx.phase == 'unmount' then
            table.insert(unmount_ids, ctx.props.id)
          end
          return { ctx.props.id }
        end

        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { show_first: boolean }>
        local function App(ctx)
          if ctx.phase == 'mount' then ctx.state = { show_first = true } end
          leaked_ctx = ctx
          return {
            ctx.state.show_first and h(Item, { id = 'first', key = 'first' })
              or h(Item, { id = 'second', key = 'second' }),
          }
        end

        local r = Morph.new(0)
        r:mount(h(App))

        assert.are.same('first', get_text())
        assert.are.same({ 'first' }, mount_ids)

        leaked_ctx:update { show_first = false }

        assert.are.same('second', get_text())
        assert.are.same({ 'first' }, unmount_ids)
        assert.are.same({ 'first', 'second' }, mount_ids)
      end)
    end)

    it('preserves component context when re-rendering with same key', function()
      with_buf({}, function()
        local lifecycle_events = {} --- @type { id: string, phase: string }[]
        local component_ctxs = {} --- @type table<string, morph.Ctx>

        --- @param ctx morph.Ctx<{ id: string }, { value: integer }>
        local function TrackedComponent(ctx)
          table.insert(lifecycle_events, { id = ctx.props.id, phase = ctx.phase })
          if ctx.phase == 'mount' then
            ctx.state = { value = 0 }
            component_ctxs[ctx.props.id] = ctx
          end
          return { ctx.props.id .. ': ' .. ctx.state.value }
        end

        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { counter: integer }>
        local function App(ctx)
          if ctx.phase == 'mount' then ctx.state = { counter = 1 } end
          leaked_ctx = ctx
          return {
            h(TrackedComponent, { id = 'comp', key = 'stable-key' }),
          }
        end

        local r = Morph.new(0)
        r:mount(h(App))

        assert.are.same('comp: 0', get_text())
        assert.are.same(1, #lifecycle_events)
        local original_ctx = component_ctxs['comp']

        lifecycle_events = {}
        leaked_ctx:update { counter = 2 }

        local mounts = vim.tbl_filter(function(e) return e.phase == 'mount' end, lifecycle_events)
        local unmounts = vim.tbl_filter(
          function(e) return e.phase == 'unmount' end,
          lifecycle_events
        )

        assert.are.same(0, #mounts, 'Should not mount when key is same')
        assert.are.same(0, #unmounts, 'Should not unmount when key is same')
        assert.are.same(original_ctx, component_ctxs['comp'], 'Context should be preserved')

        lifecycle_events = {}
        original_ctx:update { value = 42 }

        assert.are.same('comp: 42', get_text())

        mounts = vim.tbl_filter(function(e) return e.phase == 'mount' end, lifecycle_events)
        unmounts = vim.tbl_filter(function(e) return e.phase == 'unmount' end, lifecycle_events)

        assert.are.same(0, #mounts, 'Should not mount when key is same')
        assert.are.same(0, #unmounts, 'Should not unmount when key is same')
        assert.are.same(original_ctx, component_ctxs['comp'], 'Context should be preserved')
      end)
    end)

    it('produces delete+add (unmount+mount) when component keys differ', function()
      with_buf({}, function()
        local lifecycle_events = {} --- @type { id: string, phase: string }[]

        --- @param ctx morph.Ctx<{ id: string }, {}>
        local function TrackedComponent(ctx)
          table.insert(lifecycle_events, { id = ctx.props.id, phase = ctx.phase })
          return { ctx.props.id }
        end

        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { show_variant: string }>
        local function App(ctx)
          if ctx.phase == 'mount' then ctx.state = { show_variant = 'a' } end
          leaked_ctx = ctx
          return {
            h(TrackedComponent, { id = ctx.state.show_variant, key = ctx.state.show_variant }),
          }
        end

        local r = Morph.new(0)
        r:mount(h(App))

        assert.are.same('a', get_text())
        assert.are.same(1, #lifecycle_events)
        assert.are.same('a', lifecycle_events[1].id)
        assert.are.same('mount', lifecycle_events[1].phase)

        lifecycle_events = {}
        leaked_ctx:update { show_variant = 'b' }

        assert.are.same('b', get_text())

        local mounts = vim.tbl_filter(function(e) return e.phase == 'mount' end, lifecycle_events)
        local unmounts = vim.tbl_filter(
          function(e) return e.phase == 'unmount' end,
          lifecycle_events
        )

        assert.are.same(
          1,
          #mounts,
          'Should mount new component when key differs (delete+add in levenshtein)'
        )
        assert.are.same(
          1,
          #unmounts,
          'Should unmount old component when key differs (delete+add in levenshtein)'
        )
        assert.are.same('b', mounts[1].id)
        assert.are.same('a', unmounts[1].id)
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- TYPE TRANSITIONS IN RECONCILIATION
  ------------------------------------------------------------------------------

  describe('type transitions in reconciliation', function()
    it('handles transitioning from string to array', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local leaked_ctx

        --- @param ctx morph.Ctx<{show_array: boolean}>
        local function Root(ctx)
          if ctx.phase == 'mount' then
            leaked_ctx = ctx
            ctx.state = { show_array = false }
          end
          --- @diagnostic disable-next-line: unnecessary-if
          if ctx.state.show_array then
            return { 'item1', ' ', 'item2' }
          else
            return 'single string'
          end
        end

        r:mount { h(Root) }
        assert.are.same('single string', get_text())

        leaked_ctx:update { show_array = true }
        assert.are.same('item1 item2', get_text())
      end)
    end)

    it('handles transitioning from array to string', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local leaked_ctx

        --- @param ctx morph.Ctx<{show_array: boolean}>
        local function Root(ctx)
          if ctx.phase == 'mount' then
            leaked_ctx = ctx
            ctx.state = { show_array = true }
          end
          --- @diagnostic disable-next-line: unnecessary-if
          if ctx.state.show_array then
            return { 'item1', ' ', 'item2' }
          else
            return 'single string'
          end
        end

        r:mount { h(Root) }
        assert.are.same('item1 item2', get_text())

        leaked_ctx:update { show_array = false }
        assert.are.same('single string', get_text())
      end)
    end)

    it('unmounts component when transitioning from component to array', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local leaked_ctx
        local child_unmounted = false

        --- @param ctx morph.Ctx
        local function Child(ctx)
          if ctx.phase == 'unmount' then child_unmounted = true end
          return 'child component'
        end

        --- @param ctx morph.Ctx<{}, {show_array: boolean}>
        local function Root(ctx)
          if ctx.phase == 'mount' then
            leaked_ctx = ctx
            ctx.state = { show_array = false }
          end
          --- @diagnostic disable-next-line: unnecessary-if
          if ctx.state.show_array then
            return { 'item1', ' ', 'item2' }
          else
            return h(Child)
          end
        end

        r:mount { h(Root) }
        assert.are.same('child component', get_text())
        assert.is_false(child_unmounted)

        leaked_ctx:update { show_array = true }
        assert.are.same('item1 item2', get_text())
        assert.is_true(child_unmounted)
      end)
    end)

    it('unmounts old tree BEFORE reconciling new array', function()
      with_buf({}, function()
        local r = Morph.new(0)
        local leaked_ctx
        local events = {}

        --- @param ctx morph.Ctx
        local function Child(ctx)
          if ctx.phase == 'mount' then
            table.insert(events, 'child:mount')
          elseif ctx.phase == 'unmount' then
            table.insert(events, 'child:unmount')
          end
          return 'child'
        end

        --- @param ctx morph.Ctx
        local function ArrayItem(ctx)
          if ctx.phase == 'mount' then table.insert(events, 'array-item:mount') end
          return 'array item'
        end

        --- @param ctx morph.Ctx<{}, {show_array: boolean}>
        local function Root(ctx)
          if ctx.phase == 'mount' then
            leaked_ctx = ctx
            ctx.state = { show_array = false }
          end
          --- @diagnostic disable-next-line: unnecessary-if
          if ctx.state.show_array then
            return { h(ArrayItem) }
          else
            return h(Child)
          end
        end

        r:mount { h(Root) }
        assert.are.same({ 'child:mount' }, events)

        leaked_ctx:update { show_array = true }
        assert.are.same({ 'child:mount', 'child:unmount', 'array-item:mount' }, events)
      end)
    end)

    it('handles render when buffer is deleted before scheduled update', function()
      local render_error = nil
      local leaked_ctx

      --- @param ctx morph.Ctx<{}, {}>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = {}
          leaked_ctx = ctx
        end
        return 'test'
      end

      vim.cmd.new()
      local bufnr = vim.api.nvim_get_current_buf()
      local r = Morph.new(bufnr)
      r:mount(h(App))

      vim.api.nvim_buf_delete(bufnr, { force = true })

      local schedule_called = false
      vim.schedule(function()
        local ok, err = pcall(function() r:render { 'hello' } end)
        if not ok then render_error = err end
        schedule_called = true
      end)

      vim.wait(100, function() return schedule_called end)

      assert.is_true(schedule_called, 'the scheduled callback never fired')
      assert.is_nil(render_error, 'render should not error when buffer is deleted')
    end)

    it('handles mount when buffer is deleted before scheduled update', function()
      local schedule_called = false
      local update_error = nil
      local leaked_ctx

      --- @param ctx morph.Ctx<{}, {}>
      local function App(ctx)
        if ctx.phase == 'mount' then
          ctx.state = {}
          leaked_ctx = ctx
        end
        if ctx.phase == 'update' then
          vim.schedule(function()
            local ok, err = pcall(ctx.update, ctx, ctx.state)
            if not ok then update_error = err end
            schedule_called = true
          end)
        end
        return 'test'
      end

      vim.cmd.new()
      local bufnr = vim.api.nvim_get_current_buf()
      local r = Morph.new(bufnr)
      r:mount(h(App))

      leaked_ctx:update {}

      vim.api.nvim_buf_delete(bufnr, { force = true })

      vim.wait(100, function() return schedule_called end)

      assert.is_true(schedule_called, 'the scheduled callback never fired')
      assert.is_nil(update_error, 'mount should not error when buffer is deleted')
    end)
  end)

  ------------------------------------------------------------------------------
  -- MARKUP UTILITIES
  ------------------------------------------------------------------------------

  describe('markup utilities', function()
    it('converts tree to string via markup_to_string', function()
      local result = Morph.markup_to_string {
        tree = {
          'line 1\n',
          h('text', { hl = 'Comment' }, 'styled'),
          '\nline 3',
        },
      }
      assert.are.same('line 1\nstyled\nline 3', result)
    end)

    it('handles arrays with nil holes in markup_to_lines', function()
      local lines = Morph.markup_to_lines {
        tree = {
          'before',
          nil,
          'after',
        },
      }
      assert.are.same({ 'beforeafter' }, lines)
    end)

    it('handles multiple nil holes in markup_to_lines', function()
      local lines = Morph.markup_to_lines {
        tree = {
          nil,
          'a',
          nil,
          'b',
          nil,
        },
      }
      assert.are.same({ 'ab' }, lines)
    end)

    it('handles conditional rendering with nil holes', function()
      with_buf({}, function()
        local leaked_ctx
        --- @param ctx morph.Ctx<{}, { show_optional: boolean }>
        local function App(ctx)
          if ctx.phase == 'mount' then ctx.state = { show_optional = false } end
          leaked_ctx = ctx
          return {
            h('text', {}, 'first'),
            '\n',
            ctx.state.show_optional and h('text', {}, 'optional') or nil,
            '\n',
            h('text', {}, 'last'),
          }
        end

        local r = Morph.new(0)
        r:mount(h(App))
        assert.are.same({ 'first', '', 'last' }, get_lines())

        leaked_ctx:update { show_optional = true }
        assert.are.same({ 'first', 'optional', 'last' }, get_lines())

        leaked_ctx:update { show_optional = false }
        assert.are.same({ 'first', '', 'last' }, get_lines())
      end)
    end)

    it('detects external buffer changes and resyncs', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:render { 'initial content' }
        assert.are.same('initial content', get_text())

        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'external change' })

        r:render { 'new morph content' }
        assert.are.same('new morph content', get_text())
      end)
    end)
  end)

  ------------------------------------------------------------------------------
  -- MODE PRESERVATION
  --
  -- Tests that rendering doesn't disrupt the current Vim mode.
  ------------------------------------------------------------------------------

  describe('mode preservation during rendering', function()
    local function test_mode_preservation(mode_char, enter_mode_fn, exit_mode_fn)
      with_buf({ 'test content' }, function()
        local r = Morph.new(0)
        r:render { h('text', {}, 'initial content') }

        set_cursor { 1, 0 }
        enter_mode_fn()

        local initial_mode = vim.api.nvim_get_mode().mode:sub(1, 1)
        assert.are.same(mode_char, initial_mode)

        r:render { h('text', {}, 'updated content') }

        local final_mode = vim.api.nvim_get_mode().mode:sub(1, 1)
        assert.are.same(mode_char, final_mode)

        exit_mode_fn()
      end)
    end

    it('preserves normal mode', function()
      test_mode_preservation('n', vim.cmd.stopinsert, function() end)
    end)

    it('preserves visual mode', function()
      test_mode_preservation(
        'v',
        function() vim.cmd.normal { args = { 'v' }, bang = true } end,
        function() vim.cmd.normal { args = { '<Esc>' }, bang = true } end
      )
    end)

    it('preserves visual line mode', function()
      with_buf({ 'line 1', 'line 2' }, function()
        local r = Morph.new(0)
        r:render { h('text', {}, 'line 1\nline 2') }

        set_cursor { 1, 0 }
        vim.cmd.normal { args = { 'V' }, bang = true }
        local initial_mode = vim.api.nvim_get_mode().mode:sub(1, 1)
        assert.are.same('V', initial_mode)

        r:render { h('text', {}, 'updated line 1\nupdated line 2') }

        local final_mode = vim.api.nvim_get_mode().mode:sub(1, 1)
        assert.are.same('V', final_mode)

        vim.cmd.normal { args = { '<Esc>' }, bang = true }
      end)
    end)

    it('preserves visual mode in focused split during render in unfocused buffer', function()
      vim.cmd.new()
      local morph_buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(morph_buf, 0, -1, false, { '' })
      local r = Morph.new(morph_buf)
      r:render { h('text', {}, 'morph buffer content') }

      vim.cmd.vsplit()
      local focus_buf = vim.api.nvim_get_current_buf()
      local focus_win = vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(focus_buf, 0, -1, false, { 'line 1', 'line 2', 'line 3' })

      set_cursor { 1, 0 }
      vim.cmd.normal { args = { 'v' }, bang = true }
      local initial_mode = vim.api.nvim_get_mode().mode:sub(1, 1)
      assert.are.same('v', initial_mode)

      assert.are.same(focus_win, vim.api.nvim_get_current_win())
      assert.are.same(focus_buf, vim.api.nvim_get_current_buf())

      r:render { h('text', {}, 'updated morph content') }

      local final_mode = vim.api.nvim_get_mode().mode:sub(1, 1)
      assert.are.same('v', final_mode)

      assert.are.same(focus_win, vim.api.nvim_get_current_win())
      assert.are.same(focus_buf, vim.api.nvim_get_current_buf())

      local morph_lines = vim.api.nvim_buf_get_lines(morph_buf, 0, -1, false)
      assert.are.same({ 'updated morph content' }, morph_lines)

      vim.cmd.normal { args = { '<Esc>' }, bang = true }
      pcall(vim.api.nvim_win_close, focus_win, true)
      pcall(vim.api.nvim_buf_delete, morph_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, focus_buf, { force = true })
    end)
  end)

  ------------------------------------------------------------------------------
  -- POS00 COMPARISONS
  ------------------------------------------------------------------------------

  describe('Pos00 comparisons', function()
    it('compares with __lt correctly', function()
      assert.is_true(Pos00.new(0, 0) < Pos00.new(0, 1))
      assert.is_true(Pos00.new(0, 0) < Pos00.new(1, 0))
      assert.is_true(Pos00.new(0, 5) < Pos00.new(1, 0))
      assert.is_false(Pos00.new(1, 0) < Pos00.new(0, 5))
      assert.is_false(Pos00.new(0, 0) < Pos00.new(0, 0))
    end)

    it('compares with __gt correctly', function()
      assert.is_true(Pos00.new(0, 1) > Pos00.new(0, 0))
      assert.is_true(Pos00.new(1, 0) > Pos00.new(0, 0))
      assert.is_true(Pos00.new(1, 0) > Pos00.new(0, 5))
      assert.is_false(Pos00.new(0, 5) > Pos00.new(1, 0))
      assert.is_false(Pos00.new(0, 0) > Pos00.new(0, 0))
    end)

    it('compares with __eq correctly', function()
      assert.is_true(Pos00.new(0, 0) == Pos00.new(0, 0))
      assert.is_true(Pos00.new(5, 10) == Pos00.new(5, 10))
      assert.is_false(Pos00.new(0, 0) == Pos00.new(0, 1))
      assert.is_false(Pos00.new(0, 0) == Pos00.new(1, 0))
    end)
  end)

  ------------------------------------------------------------------------------
  -- LEVENSHTEIN
  ------------------------------------------------------------------------------

  describe('levenshtein', function()
    local levenshtein = Morph._levenshtein

    it('handles sparse arrays with gaps correctly', function()
      -- Create sparse arrays with gaps (non-contiguous indices)
      -- The # operator has undefined behavior for sparse arrays,
      -- but table.maxn correctly returns the highest numeric index
      local sparse_from = { [1] = 'a', [3] = 'c' } -- gap at index 2
      local sparse_to = { [1] = 'x', [3] = 'z' } -- same structure, different values

      -- #sparse_from might return 1 (Lua sees no contiguous sequence beyond index 1)
      -- table.maxn(sparse_from) correctly returns 3
      assert.are.same(3, table.maxn(sparse_from), 'test setup: maxn should be 3')

      --- @diagnostic disable-next-line: assign-type-mismatch
      local changes = levenshtein { from = sparse_from, to = sparse_to }

      -- If levenshtein correctly uses table.maxn, it should see elements at indices 1 and 3
      -- and produce changes for both. With the # bug, it may only see index 1.
      local change_changes = vim.tbl_filter(function(c) return c.kind == 'change' end, changes)

      -- We expect 2 changes: 'a' -> 'x' at index 1, and 'c' -> 'z' at index 3
      assert.are.same(
        2,
        #change_changes,
        'should produce changes for both indices 1 and 3, not just index 1'
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- IS_TEXTLOCK
  ------------------------------------------------------------------------------

  describe('is_textlock', function()
    local is_textlock = Morph._is_textlock

    it('returns false when not in textlock', function()
      with_buf({}, function() assert.is_false(is_textlock()) end)
    end)

    it('returns true during expression mapping', function()
      local result = nil
      vim.keymap.set('n', '<F12>', function()
        result = is_textlock()
        return ''
      end, { expr = true })

      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<F12>', true, false, true), 'x', false)

      vim.keymap.del('n', '<F12>')
      assert.is_true(result)
    end)

    it('returns true during foldexpr evaluation', function()
      vim.cmd.new()
      local result = nil
      --- @diagnostic disable-next-line: global-in-non-module
      _G._test_foldexpr_textlock = function()
        result = is_textlock()
        return '0'
      end

      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'line1', 'line2' })
      vim.wo.foldmethod = 'expr'
      vim.wo.foldexpr = 'v:lua._test_foldexpr_textlock()'
      vim.cmd.normal { args = { 'zx' }, bang = true }

      _G._test_foldexpr_textlock = nil
      vim.cmd.bdelete { bang = true }

      assert.is_true(result)
    end)

    it('returns true during vim.in_fast_event (luv callback)', function()
      local result = nil
      local timer = vim.uv.new_timer()
      timer:start(0, 0, function()
        result = is_textlock()
        timer:close()
      end)

      vim.wait(100, function() return result ~= nil end)

      assert.is_true(result)
    end)

    it('preserves window after check', function()
      with_buf({}, function()
        local win_before = vim.api.nvim_get_current_win()
        is_textlock()
        local win_after = vim.api.nvim_get_current_win()
        assert.are.same(win_before, win_after)
      end)
    end)
  end)

  ----------------------------------------------------------------------------
  -- REGRESSION TEST: Rendering empty tree should not cause blank lines
  --
  -- Bug: When rendering an empty tree ({}) between non-empty renders,
  -- the next render would have old.lines = {} (empty array) instead of
  -- {""}, causing patch_lines to add an extra blank line.
  ----------------------------------------------------------------------------

  it('should not add blank lines when rendering empty tree between content', function()
    with_buf({}, function()
      local r = Morph.new(0)

      -- First render: non-empty content
      r:render { 'First' }
      assert.are.same({ 'First' }, get_lines())

      -- Second render: empty tree (may or may not clear buffer)
      r:render {}

      -- Third render: new non-empty content
      -- The key assertion: no blank line should appear after the content
      r:render { 'Second' }
      local lines = get_lines()
      assert.are.same(1, #lines, 'Buffer should have exactly 1 line, no blank lines')
      assert.are.same('Second', lines[1])
    end)
  end)
end)
