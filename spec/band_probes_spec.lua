--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch
--- @diagnostic disable: undefined-field

--- Changed-rows tests under real input.
---
--- After a burst, the guard re-reads only the tags on the rows that changed
--- (see changed_rows). These specs pin those rows per kind of burst (typing,
--- word delete, newline, line delete, append past the tree), and check that
--- every tag whose content changed lies on them. Runs in a child nvim so real keystrokes
--- and real autocmds drive the bursts (see AGENTS.md's host/child split).
local Test = require 'morph.vendor.test'
local describe, it = Test.describe, Test.it
local before_each, after_each = Test.before_each, Test.after_each
local assert = Test.assert
--- @type spec.util
local util = dofile 'spec/util.lua'

describe('changed rows', function()
  --- @type test.Nvim
  local nv

  before_each(function() nv = util.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  --- Mount a docker-shaped locked document with room below the filter for
  --- line-level edits. The hole records on_change events; reverts are
  --- counted through an instance-level wrap.
  local function mount_docker_shape()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      local Morph = require 'morph'
      local h = Morph.h

      _G.m = Morph.new(util.scratch_buf { focus = true }, { readonly = true })
      _G.m:mount {
        '## Docker\n\n',
        'Filter: [',
        h('text', {
          id = 'filter',
          readonly = false,
          on_change = util.create_event_recorder 'filter',
        }, ''),
        '] (3 items)\n\n',
        'Row one\n',
        'Row two\n',
        'Row three',
      }
      util.drain(100)
      local orig = _G.m._revert_violation
      _G.m._revert_violation = function(...)
        _G.reverts = (_G.reverts or 0) + 1
        return orig(...)
      end
      _G.before = util.tag_snapshot(_G.m)
      return nil
    end)
  end

  --- Wait for the guard to judge the current burst, drain the revert/accept
  --- fall-out, and collect band, changed tags, text and reverts.
  local function observe()
    -- Wait for the guard to judge the burst (the event under test) before
    -- reading any state. The burst-closing TextChanged autocmd is dispatched
    -- by nvim's main loop, and for programmatic edits some versions dispatch
    -- it only when the loop regains control BETWEEN RPC requests, which a
    -- single in-child drain misses. await_guard polls across round trips
    -- (each request flushes pending key-events); unlike a plain drain, its
    -- failure mode is a loud error with diagnostics, not a nil band.
    if not util.await_guard(nv) then
      error 'guard never judged the burst (TextChanged window never closed)'
    end
    return nv:run(function()
      local util = dofile 'spec/util.lua'
      util.drain(200)
      local after = util.tag_snapshot(_G.m)
      return {
        band = _G.m._last_changed_rows,
        changed = util.changed_tag_ids(_G.before, after),
        after = after,
        text = util.text(0),
        events = util.events(),
        reverts = _G.reverts or 0,
      }
    end)
  end

  --- Every genuinely changed tag must intersect the band's rows.
  local function assert_band_covers_changes(result)
    assert.ok(result.band, 'guard recorded no band for the burst')
    local top, bottom = result.band[1], result.band[2]
    for _, id in ipairs(result.changed) do
      local snap = result.after[id]
      assert.ok(snap, 'changed tag ' .. id .. ' vanished from the snapshot')
      assert.equal(
        snap.start[1] <= bottom and snap.stop[1] >= top,
        true,
        ('changed tag "%s" (rows %d..%d) outside band %d..%d'):format(
          id,
          snap.start[1],
          snap.stop[1],
          top,
          bottom
        )
      )
    end
  end

  it('bands a typing burst to the filter line', function()
    mount_docker_shape()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      util.cursor_to_extmark_start(_G.m, 'filter')
      return nil
    end)

    nv:input 'ifilter'
    local result = observe()

    -- The filter sits on 0-based row 2 ('## Docker', '', 'Filter: ...').
    assert.deep_equal(result.band, { 2, 2 })
    assert_band_covers_changes(result)
    assert.deep_equal(result.events, { { id = 'filter', text = 'filter' } })
    assert.equal(result.reverts, 0)
  end)

  it('bands a <C-w> word delete to the collapsed filter line', function()
    mount_docker_shape()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      util.cursor_to_extmark_start(_G.m, 'filter')
      return nil
    end)

    nv:input 'ifilter'
    nv:run(function()
      local util = dofile 'spec/util.lua'
      util.drain(150)
      -- Snapshot before the second burst so its changed set is exact; the
      -- sink is cleared so burst 2's events are the only ones observed.
      _G.before = util.tag_snapshot(_G.m)
      util.events { clear = true }
      return nil
    end)

    nv:input '<C-w>'
    local result = observe()

    -- All six sub-deletes converge on the filter's line: the probes nvim
    -- adjusted through the batch land on the collapsed hole's row.
    assert.deep_equal(result.band, { 2, 2 })
    assert_band_covers_changes(result)
    assert.deep_equal(result.events, { { id = 'filter', text = '' } })
    assert.equal(result.reverts, 0)
    assert.deep_equal(
      result.text,
      '## Docker\n\nFilter: [] (3 items)\n\nRow one\nRow two\nRow three'
    )
  end)

  it('bands a newline insert to both touched lines', function()
    mount_docker_shape()
    nv:run(function()
      local util = dofile 'spec/util.lua'
      util.cursor_to_extmark_start(_G.m, 'filter')
      return nil
    end)

    nv:input 'iab'
    nv:run(function()
      local util = dofile 'spec/util.lua'
      util.drain(150)
      -- Snapshot before the second burst so its changed set is exact.
      _G.before = util.tag_snapshot(_G.m)
      return nil
    end)

    -- Real keystroke burst: newline inside the hole, then more typing on
    -- the new line, all in one typeahead batch.
    nv:input '<CR>cd'
    local result = observe()

    -- The burst added one line, so the sound band overshoots by that churn.
    assert.deep_equal(result.band, { 2, 4 })
    assert_band_covers_changes(result)
    assert.deep_equal(
      result.text,
      '## Docker\n\nFilter: [ab\ncd] (3 items)\n\nRow one\nRow two\nRow three'
    )
    assert.deep_equal(result.events[#result.events].text, 'ab\ncd')
    assert.equal(result.reverts, 0)
  end)

  it('bands a deleted locked line to its collapse point and reverts', function()
    mount_docker_shape()
    nv:run(function()
      -- Cursor onto 'Row one' (line 5, 1-based row 6? rows: 1 '## Docker',
      -- 2 '', 3 'Filter: ...', 4 '', 5 'Row one').
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      return nil
    end)

    nv:input 'dd'
    local result = observe()

    -- The deleted line's tags collapse onto the deletion point's row; the
    -- burst removed one line, so the band overshoots upward by that churn.
    assert.deep_equal(result.band, { 3, 4 })
    assert_band_covers_changes(result)
    -- The dd touched locked text: the guard reverts, which restores the
    -- deleted line -- the buffer ends up exactly as mounted.
    assert.equal(result.reverts, 1)
    assert.deep_equal(
      result.text,
      '## Docker\n\nFilter: [] (3 items)\n\nRow one\nRow two\nRow three'
    )
  end)

  it('bands an append past the tree and reverts it in a locked app', function()
    mount_docker_shape()
    nv:run(function()
      -- Append two lines after 'Row three' (last line, 0-based row 6).
      local last = vim.api.nvim_buf_line_count(0) - 1
      local len = #vim.api.nvim_buf_get_lines(0, last, last + 1, true)[1]
      vim.api.nvim_buf_set_text(0, last, len, last, len, { '', 'extra one', 'extra two' })
      return nil
    end)

    local result = observe()

    -- The band covers every appended row plus the junction one past the
    -- end (the content diff of the render snapshot vs the live lines --
    -- see changed_rows). Nothing there is a tag, so the locked app reverts
    -- the outside-tree edit.
    assert.deep_equal(result.band, { 7, 9 })
    assert_band_covers_changes(result)
    assert.equal(result.reverts, 1)
    assert.deep_equal(
      result.text,
      '## Docker\n\nFilter: [] (3 items)\n\nRow one\nRow two\nRow three'
    )
  end)
end)
