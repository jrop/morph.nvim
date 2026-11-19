--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

--- changed_rows tests.
---
--- After an edit, the guard re-reads only the tags on the rows that differ
--- between the render's line snapshot and the live lines. These specs pin
--- those rows per kind of edit, including the widening that reaches every
--- extmark the edit could have moved. A pure function, so no child nvim is
--- needed (see AGENTS.md's host/child split).
local Test = require 'morph.vendor.test'
local describe, it = Test.describe, Test.it
local assert = Test.assert
local Morph = require 'morph'

describe('changed_rows', function()
  local D = Morph.changed_rows

  it(
    'returns nothing for identical lines',
    function() assert.is_nil(D({ 'a', 'b' }, { 'a', 'b' })) end
  )

  it(
    'returns nothing for a net-zero burst (typed and deleted in one)',
    function() assert.is_nil(D({ 'x' }, { 'x' })) end
  )

  it('returns the edited row and the row below the last line', function()
    local top0, bottom0 = D({ '[filter]' }, { '[filterX]' })
    assert.deep_equal({ top0, bottom0 }, { 0, 1 })
  end)

  it('reaches one row past the end for an edit on the last line', function()
    -- Content alone cannot tell an in-line edit from one that consumed the
    -- final newline, whose extmarks nvim moves one row past the end.
    local top0, bottom0 = D({ '[filter]' }, { '[fil]' })
    assert.deep_equal({ top0, bottom0 }, { 0, 1 })
  end)

  it('reaches one row past the end for an append', function()
    local top0, bottom0 = D({ 'a' }, { 'a', 'b' })
    assert.deep_equal({ top0, bottom0 }, { 1, 2 })
  end)

  it('starts at row zero for a prepend', function()
    local top0, bottom0 = D({ 'b' }, { 'a', 'b' })
    assert.deep_equal({ top0, bottom0 }, { 0, 1 })
  end)

  it('widens a line delete upward by the removed line', function()
    -- Deleting row 2 moves its tags' extmarks to row 2. A tag spanning from
    -- the row above owned the deleted tail, and its start mark sits on an
    -- unchanged row, so the rows reach up one removed line.
    local top0, bottom0 = D({ 'a', 'b', 'c', 'd', 'e' }, { 'a', 'b', 'd', 'e' })
    assert.deep_equal({ top0, bottom0 }, { 1, 2 })
  end)

  it('widens a two-line delete upward past both removed rows', function()
    local top0, bottom0 = D({ 'a', 'b', 'c', 'd' }, { 'a', 'd' })
    assert.deep_equal({ top0, bottom0 }, { 0, 1 })
  end)

  it('reaches one row past the end when the last line is emptied', function()
    local top0, bottom0 = D({ 'only line' }, { '' })
    assert.deep_equal({ top0, bottom0 }, { 0, 1 })
  end)

  it('spans every row of a multi-row replace', function()
    local top0, bottom0 = D({ 'a', 'b1', 'b2', 'c' }, { 'a', 'B1', 'B2', 'c' })
    assert.deep_equal({ top0, bottom0 }, { 1, 2 })
  end)

  it('spans from the first to the last of two separate edits', function()
    local top0, bottom0 = D({ 'a', 'x1', 'b', 'y1', 'c' }, { 'a', 'x2', 'b', 'y2', 'c' })
    assert.deep_equal({ top0, bottom0 }, { 1, 3 })
  end)

  it('reaches the row below a multi-row insert', function()
    local top0, bottom0 = D({ 'a', 'b', 'c' }, { 'a', 'X', 'Y', 'b', 'c' })
    assert.deep_equal({ top0, bottom0 }, { 1, 3 })
  end)

  it('stays on the changed row when the line count is unchanged', function()
    -- The on-change suite's shape: a word delete inside the filter line.
    local old =
      { '## Docker', '', 'Filter: [filter] (3 items)', '', 'Row one', 'Row two', 'Row three' }
    local new = { '## Docker', '', 'Filter: [] (3 items)', '', 'Row one', 'Row two', 'Row three' }
    local top0, bottom0 = D(old, new)
    assert.deep_equal({ top0, bottom0 }, { 2, 2 })
  end)

  --- 400 lines whose rows 21..380 (1-based) are rewritten, or removed.
  --- @param keep_middle boolean
  local function big_edit(keep_middle)
    local old, new = {}, {}
    for i = 1, 400 do
      old[i] = 'old ' .. i
      local in_middle = i > 20 and i <= 380
      if not in_middle then
        new[#new + 1] = old[i]
      elseif keep_middle then
        new[#new + 1] = 'new ' .. i
      end
    end
    return old, new
  end

  it('spans a large replace without diffing it', function()
    local top0, bottom0 = D(big_edit(true))
    assert.deep_equal({ top0, bottom0 }, { 20, 379 })
  end)

  it('widens a large delete upward by every removed line', function()
    local top0, bottom0 = D(big_edit(false))
    assert.deep_equal({ top0, bottom0 }, { 0, 20 })
  end)
end)
