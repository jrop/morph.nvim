--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: undefined-field

--- Hole attribution: what each editable hole's on_change receives.
---
--- The guard has two jobs. It reverts any edit that changes readonly text, and
--- it hands each changed hole its new text. These specs pin the second job,
--- because it is the one that breaks: one command that rewrites several holes
--- must give each hole its own text, never the stretch between them.
---
--- Every case runs one real command in a child nvim, and then checks both the
--- buffer and the on_change calls per hole. A single command is a single
--- burst, so these cases also cover edits the guard judges together. Each case
--- runs under both renderers, because they bound a hole differently:
---
--- 1. A locked renderer (readonly by default) makes the text around a hole
---    readonly, so the hole is the only editable text.
--- 2. A classic renderer leaves the text around a hole editable, so the hole's
---    neighbours are editable text that the command happens not to change.
local Test = require 'morph.vendor.test'
local describe, it = Test.describe, Test.it
local before_each, after_each = Test.before_each, Test.after_each
local assert = Test.assert
--- @type spec.util
local util = dofile 'spec/util.lua'

--- A hole in a layout: an editable tag with an on_change recorder.
--- @class spec.Hole
--- @field id string
--- @field text string

local NAME_AGE =
  { 'Name: [', { id = 'a', text = 'ada' }, '] Age: [', { id = 'b', text = '36' }, ']' }

for _, renderer in ipairs {
  { name = 'locked renderer', locked = true },
  { name = 'classic renderer', locked = false },
} do
  describe('hole attribution under a ' .. renderer.name, function()
    --- @type test.Nvim
    local nv

    before_each(function() nv = util.start {} end)
    after_each(function()
      if nv then nv:stop() end
      nv = nil
    end)

    --- Render `layout` into a focused buffer. A string is the text around the
    --- holes and a table is a hole, so the layout reads like the line the user
    --- sees. Trees cannot cross the RPC boundary (their handlers are
    --- closures), so the child builds the tree from this plain description.
    --- @param layout (string|spec.Hole)[]
    local function mount(layout)
      nv:run(function(items, locked)
        --- @cast items (string|spec.Hole)[]
        local util = dofile 'spec/util.lua'
        local Morph = require 'morph'
        local h = Morph.h
        _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = locked })
        local tree = {}
        for _, item in ipairs(items) do
          if type(item) == 'string' then
            tree[#tree + 1] = item
          else
            tree[#tree + 1] = h('text', {
              id = item.id,
              readonly = false,
              on_change = util.create_event_recorder(item.id),
            }, item.text)
          end
        end
        _G.m:render(tree)
      end, layout, renderer.locked)
    end

    --- Run one command, wait for the guard, and return the buffer text plus
    --- the on_change texts grouped by hole id. Grouping keeps the assertion
    --- independent of the order sibling handlers fire in, while still showing
    --- a hole that fired twice.
    --- @param keys string
    --- @return string text
    --- @return table<string, string[]> changes
    local function run(keys)
      nv:input(keys)
      local result = util.settled(nv, { ms = 150 })
      local changes = {}
      for _, e in ipairs(result.events) do
        changes[e.id] = changes[e.id] or {}
        table.insert(changes[e.id], e.text)
      end
      return result.text, changes
    end

    it('gives each hole its own text when one command rewrites two holes on a line', function()
      mount(NAME_AGE)
      local text, changes = run [=[:s/\[\zs[^]]*\ze]/zz/g<CR>]=]
      assert.equal(text, 'Name: [zz] Age: [zz]')
      assert.deep_equal(changes, { a = { 'zz' }, b = { 'zz' } })
    end)

    it('gives each hole its own text when one command rewrites holes on adjacent rows', function()
      mount { 'Name: [', { id = 'a', text = 'ada' }, ']\nAge: [', { id = 'b', text = '36' }, ']' }
      local text, changes = run [=[:%s/\[\zs[^]]*\ze]/zz/<CR>]=]
      assert.equal(text, 'Name: [zz]\nAge: [zz]')
      assert.deep_equal(changes, { a = { 'zz' }, b = { 'zz' } })
    end)

    -- Two :s commands joined by a bar run as one command line, so the guard
    -- judges both replacements together.
    it('gives an emptied hole an empty string when another hole changes too', function()
      mount(NAME_AGE)
      local text, changes = run ':s/ada//|s/36/99/<CR>'
      assert.equal(text, 'Name: [] Age: [99]')
      assert.deep_equal(changes, { a = { '' }, b = { '99' } })
    end)

    -- A replacement that keeps some of the old characters is still one whole
    -- new value: the hole must not be read as only the characters that changed.
    it('gives a hole its whole new text when the replacement keeps some old characters', function()
      mount { 'Code: [', { id = 'a', text = 'abc' }, ']' }
      local text, changes = run ':s/abc/xbz/<CR>'
      assert.equal(text, 'Code: [xbz]')
      assert.deep_equal(changes, { a = { 'xbz' } })
    end)

    -- The new text copies the text that follows the hole, so matching text
    -- alone cannot tell where the hole ends. Positions have to settle it.
    it('keeps a copy of the surrounding text that lands inside a hole', function()
      mount(NAME_AGE)
      local text, changes = run ':s/ada/x] Age: [y/<CR>'
      assert.equal(text, 'Name: [x] Age: [y] Age: [36]')
      assert.deep_equal(changes, { a = { 'x] Age: [y' } })
    end)

    -- Only a locked renderer protects the text around a hole, so only there
    -- must a multi-hole rewrite be caught when it touches that text.
    if renderer.locked then
      it('reverts a two-hole rewrite that also removes readonly text', function()
        mount(NAME_AGE)
        local text, changes = run [=[:s/ada]\(.*\)36/zz\1zz/<CR>]=]
        assert.equal(text, 'Name: [ada] Age: [36]')
        assert.deep_equal(changes, {})
      end)

      -- One replacement that runs from one hole to the next overwrites the
      -- readonly text between them, even though the new text contains an
      -- identical copy of it. Touching readonly text is what gets reverted.
      it('reverts one replacement that spans the readonly text between two holes', function()
        mount(NAME_AGE)
        local text, changes = run [=[:s/ada\(.*\)36/\199/<CR>]=]
        assert.equal(text, 'Name: [ada] Age: [36]')
        assert.deep_equal(changes, {})
      end)
    end
  end)
end
