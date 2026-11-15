---@diagnostic disable: global-in-non-module
--- Helpers the specs share, on both sides of the child-nvim RPC boundary.
---
--- Each `nv:run` closure is a separate child-side chunk, `string.dump`'d with
--- NO upvalues. Nothing survives between calls except child globals, so a
--- closure that needs these helpers loads them itself:
--- `local util = dofile 'spec/util.lua'`. A `dofile` (not `require`) is what
--- reaches this file, because neither nvim puts `spec/` on its module path; the
--- relative path resolves because the runner and its children share the
--- repository root as their cwd. The runner only collects `*_spec.lua` files,
--- so this file is never run as a spec.
---
--- @class spec.util
local M = {}

--- @class spec.util.Event
--- @field id string
--- @field text string

--- The child-global event sink shared by every `create_event_recorder` handler.
--- @return spec.util.Event[]
local function sink()
  _G.__morph_test_events = _G.__morph_test_events or {}
  return _G.__morph_test_events
end

--- Create a scratch buffer (nofile/wipe/unlisted), optionally with lines,
--- optionally focused.
--- @param opts? { focus?: boolean, lines?: string[] }
--- @return integer bufnr
function M.scratch_buf(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buflisted = false
  ---@diagnostic disable-next-line: need-check-nil
  if opts.lines then vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines) end
  ---@diagnostic disable-next-line: need-check-nil
  if opts.focus then vim.api.nvim_set_current_buf(bufnr) end
  return bufnr
end

--- Run `f` inside a temporary scratch window, cleaned up afterward (bdelete
--- fires the teardown autocmds). Host-side specs; the child harness uses
--- scratch_buf instead.
--- @param lines string[]?  initial lines (nil leaves the buffer empty)
--- @param f fun()
function M.with_buf(lines, f)
  vim.go.swapfile = false
  vim.cmd.new()
  if lines then vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
  local ok, result = pcall(f)
  vim.cmd.bdelete { bang = true }
  if not ok then error(result) end
end

--- Return an on_change handler that appends { id = id, text = e.text } to
--- the child-global event sink.
--- @param id string
--- @return fun(e: { text: string, bubble_up: boolean })
function M.create_event_recorder(id)
  return function(e) table.insert(sink(), { id = id, text = e.text }) end
end

--- Read (and optionally clear) the event sink as plain data for host asserts.
--- @param opts? { clear?: boolean }
--- @return spec.util.Event[]
function M.events(opts)
  opts = opts or {}
  local events = sink()
  ---@diagnostic disable-next-line: need-check-nil
  if opts.clear then _G.__morph_test_events = {} end
  return events
end

--- Buffer content as a single string (host-side get_text() equivalent).
--- @param bufnr? integer  defaults to 0 (current)
--- @return string
function M.text(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), '\n')
end

--- Place the cursor at the start of a named element's extmark.
--- @param morph morph.Morph
--- @param id string
function M.cursor_to_extmark_start(morph, id)
  --- @type morph.Element
  local elem = assert(morph:get_element_by_id(id), 'element "' .. id .. '" not found')
  local start = elem.extmark.start
  vim.api.nvim_win_set_cursor(0, { start[1] + 1, start[2] })
end

--- Snapshot every rendered tag's live text and span (plain data for host
--- asserts), for band-superset assertions in child specs.
--- @param morph morph.Morph
--- @return table<string, { text: string, start: integer[], stop: integer[] }>
function M.tag_snapshot(morph)
  local out = {}
  for id in pairs(morph.text_content.extmark_ids_to_tag) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(morph.bufnr, morph.ns, id, { details = true })
    if pos and pos[1] then
      local srow, scol = pos[1], pos[2]
      local det = pos[3] or {}
      local erow, ecol = det.end_row or srow, det.end_col or scol
      local text
      if srow == erow and scol >= ecol then
        text = ''
      else
        text =
          table.concat(vim.api.nvim_buf_get_text(morph.bufnr, srow, scol, erow, ecol, {}), '\n')
      end
      out[id] = { text = text, start = { srow, scol }, stop = { erow, ecol } }
    end
  end
  return out
end

--- Ids whose live text differs between two snapshots (or is new).
--- @param before table<string, { text: string }>
--- @param after table<string, { text: string }>
--- @return string[]
function M.changed_tag_ids(before, after)
  local changed = {}
  for id, snap in pairs(after) do
    local was = before[id]
    if not was or was.text ~= snap.text then changed[#changed + 1] = id end
  end
  return changed
end

--- Flush scheduled re-renders.
---
--- A plain `vim.wait(ms, function() return false end)` always burns its full
--- timeout, but the work being flushed here is `vim.schedule`'d, and schedule
--- callbacks run in FIFO order. Queueing a sentinel AFTER the drain call means
--- the sentinel cannot run until all previously scheduled work has run, so
--- waiting on the sentinel releases as soon as the queue is drained (usually
--- sub-millisecond) instead of after a fixed sleep. `ms` is only a safety cap.
--- @param ms? integer  timeout cap (default 1000)
function M.drain(ms)
  local done = false
  vim.schedule(function() done = true end)
  vim.wait(ms or 1000, function() return done end, 1)
end

--------------------------------------------------------------------------------
-- Host-side readbacks over a child
--------------------------------------------------------------------------------

--- Start a child nvim with `NVIM_TEST` set. Morph exports its internals and
--- drops its render debounce under that variable, and the specs rely on both,
--- so every child must see the variable the host specs set for themselves.
--- @param opts? test.NvimStartOpts
--- @return test.Nvim
function M.start(opts)
  local Test = require 'morph.vendor.test'
  return Test.Nvim.start(vim.tbl_extend('force', { env = { NVIM_TEST = 'true' } }, opts or {}))
end

--- Poll across RPC round trips until the guard has judged every captured
--- edit -- the buffer watcher's pending_edits drains to 0, i.e. the
--- TextChanged window that opened for the burst has closed. A programmatic
--- edit (nvim_buf_set_text from a spec) gets its TextChanged dispatched by
--- nvim's main loop, and on some versions that dispatch is only guaranteed
--- when the loop regains control BETWEEN RPC requests -- a single in-child
--- vim.wait can pump the loop without ever reaching that checkpoint, so the
--- guard never runs and the readback observes a half-processed burst.
--- Each attempt is its own request (the arrival flushes pending events) plus
--- an in-child wait. Best effort: returns false on timeout so callers can
--- decide whether a half-processed burst is a failure (see observe-style
--- readbacks) or irrelevant. Requires the spec's instance in `_G.m` (the
--- convention every child spec follows); without one it passes immediately.
--- @param nv test.Nvim
--- @param ms? integer  per-attempt in-child wait cap (default 50)
--- @return boolean  true once no burst window is open
function M.await_guard(nv, ms)
  for _ = 1, 40 do
    local done = nv:run(function(...)
      local cap = ... --- @type integer?
      local window_open = function()
        local w = _G.m and _G.m.buf_watcher
        return (w and w.pending_edits or 0) > 0
      end
      vim.wait(cap or 50, function() return not window_open() end, 5)
      return not window_open()
    end, ms)
    if done then return true end
  end
  return false
end

--- Drain scheduled child work (when `opts.ms` is given) and read back the
--- child's buffer text and event sink: the read-after-action most child specs
--- end with. Without `ms`, no drain happens -- the read observes whatever has
--- settled by the time this RPC round-trip executes, exactly like a bare
--- `run` readback. `opts.clear` empties the event sink after reading;
--- `opts.cursor` adds the child's cursor to the result. Before reading, the
--- guard's burst window is awaited (see await_guard) -- a pending window
--- means the action has not fully settled, and its judgment would land after
--- the read on some nvim versions.
--- @param nv test.Nvim
--- @param opts? { ms?: integer, cursor?: boolean, clear?: boolean }
--- @return { text: string, events: spec.util.Event[], cursor: integer[]? }
function M.settled(nv, opts)
  M.await_guard(nv)
  return nv:run(function(...)
    local util = dofile 'spec/util.lua'
    local o = ... --- @type { ms?: integer, cursor?: boolean, clear?: boolean }
    if o.ms then util.drain(o.ms) end
    local out = { text = util.text(0), events = util.events { clear = o.clear } }
    if o.cursor then out.cursor = vim.api.nvim_win_get_cursor(0) end
    return out
  end, opts or {}) --[[@as { text: string, events: spec.util.Event[], cursor: integer[]? }]]
end

return M
