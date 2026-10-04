--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

--- diff_to_band tests.
---
--- The guard's dirty band is a content diff: the render's line snapshot vs
--- the live buffer lines, both settled states in final coordinates. These
--- specs pin the band's shape and the change windows per edit class, in
--- terms an on_bytes stream cannot state: what the text WAS and what it
--- BECAME. Pure functions -- no child nvim needed (see AGENTS.md's
--- host/child split).
local Morph = require 'morph'

describe('diff_to_band', function()
  local D = Morph.diff_to_band

  it(
    'returns nothing for identical lines',
    function() assert.is_nil(D({ 'a', 'b' }, { 'a', 'b' })) end
  )

  it(
    'returns nothing for a net-zero burst (typed and deleted in one)',
    function() assert.is_nil(D({ 'x' }, { 'x' })) end
  )

  it('bands a same-line edit with a column-trimmed window', function()
    local top0, bottom0, windows = D({ '[filter]' }, { '[filterX]' })
    assert.are.same({ 0, 1 }, { top0, bottom0 })
    assert.are.same(1, #windows)
    assert.are.same({ row0 = 0, col0 = 7, end_row = 0, end_col = 8 }, windows[1])
  end)

  it('bands a word delete on a single-line buffer to the junction row', function()
    -- The last line's edit keeps the junction row (one past the end) in the
    -- band: content alone cannot tell an in-line edit from one that consumed
    -- the newline whose extmarks nvim parks exactly there.
    local top0, bottom0, windows = D({ '[filter]' }, { '[fil]' })
    assert.are.same({ 0, 1 }, { top0, bottom0 })
    assert.are.same({ row0 = 0, col0 = 4, end_row = 0, end_col = 4 }, windows[1])
  end)

  it('bands an append to the junction row one past the last line', function()
    local top0, bottom0, windows = D({ 'a' }, { 'a', 'b' })
    assert.are.same({ 1, 2 }, { top0, bottom0 })
    assert.are.same({ row0 = 1, col0 = 0, end_row = 1, end_col = 1 }, windows[1])
  end)

  it('bands a prepend from row zero to the junction', function()
    local top0, bottom0, windows = D({ 'b' }, { 'a', 'b' })
    assert.are.same({ 0, 1 }, { top0, bottom0 })
    assert.are.same({ row0 = 0, col0 = 0, end_row = 0, end_col = 1 }, windows[1])
  end)

  it('widens a line delete upward and bands it to the junction', function()
    -- Deleting row 2 parks its tags' extmarks at the junction (row 2); a tag
    -- spanning from the row above owns the deleted tail, and its start mark
    -- sits on an unchanged row -- so the band reaches up one removed line.
    local top0, bottom0, windows = D({ 'a', 'b', 'c', 'd', 'e' }, { 'a', 'b', 'd', 'e' })
    assert.are.same({ 1, 2 }, { top0, bottom0 })
    assert.are.same(0, #windows)
  end)

  it('widens a two-line delete upward past both removed rows', function()
    local top0, bottom0 = D({ 'a', 'b', 'c', 'd' }, { 'a', 'd' })
    assert.are.same({ 0, 1 }, { top0, bottom0 })
  end)

  it('bands a deleted last line to the junction one past the end', function()
    local top0, bottom0, windows = D({ 'only line' }, { '' })
    assert.are.same({ 0, 1 }, { top0, bottom0 })
    assert.are.same({ row0 = 0, col0 = 0, end_row = 0, end_col = 0 }, windows[1])
  end)

  it('bands a multi-row replace to one window spanning the rows', function()
    -- The window trims unchanged bytes from the run's edge pairs: 'b2' and
    -- 'B2' share the suffix '2', so the run's last changed byte is col 1.
    local top0, bottom0, windows = D({ 'a', 'b1', 'b2', 'c' }, { 'a', 'B1', 'B2', 'c' })
    assert.are.same({ 1, 2 }, { top0, bottom0 })
    assert.are.same(1, #windows)
    assert.are.same({ row0 = 1, col0 = 0, end_row = 2, end_col = 1 }, windows[1])
  end)

  it('gives disjoint edits one tight window per run', function()
    local top0, bottom0, windows = D({ 'a', 'x1', 'b', 'y1', 'c' }, { 'a', 'x2', 'b', 'y2', 'c' })
    assert.are.same({ 1, 3 }, { top0, bottom0 })
    assert.are.same(2, #windows)
    assert.are.same({ row0 = 1, col0 = 1, end_row = 1, end_col = 2 }, windows[1])
    assert.are.same({ row0 = 3, col0 = 1, end_row = 3, end_col = 2 }, windows[2])
  end)

  it('bands a multi-row insert to the junction below the inserted lines', function()
    local top0, bottom0, windows = D({ 'a', 'b', 'c' }, { 'a', 'X', 'Y', 'b', 'c' })
    assert.are.same({ 1, 3 }, { top0, bottom0 })
    assert.are.same({ row0 = 1, col0 = 0, end_row = 2, end_col = 1 }, windows[1])
  end)

  it('bands the docker <C-w> burst to the collapsed filter line', function()
    -- The on-change suite's shape: the filter hole collapses on its row, rows
    -- follow, line count is preserved -- the band stays on the changed row.
    local old =
      { '## Docker', '', 'Filter: [filter] (3 items)', '', 'Row one', 'Row two', 'Row three' }
    local new = { '## Docker', '', 'Filter: [] (3 items)', '', 'Row one', 'Row two', 'Row three' }
    local top0, bottom0, windows = D(old, new)
    assert.are.same({ 2, 2 }, { top0, bottom0 })
    -- Cols 9..9 is the empty range at the deletion point: the burst removed
    -- bytes and inserted none, so the window witnesses empty content.
    assert.are.same({ row0 = 2, col0 = 9, end_row = 2, end_col = 9 }, windows[1])
  end)
end)
