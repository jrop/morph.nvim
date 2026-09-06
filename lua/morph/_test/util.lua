---@diagnostic disable: global-in-non-module
--- Test utilities for child-nvim specs.
---
--- Each `exec_func` closure is a separate child-side chunk, `string.dump`'d with
--- NO upvalues. Nothing survives between calls except child globals. This module
--- provides the shared helpers those closures need; `require` it inside each
--- closure body.
---
--- @class morph._test.util
local M = {}

--- @class morph._test.util.Event
--- @field id string
--- @field text string

--- The child-global event sink shared by every `create_event_recorder` handler.
--- @return morph._test.util.Event[]
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

--- Return an on_change handler that appends { id = id, text = e.text } to
--- the child-global event sink.
--- @param id string
--- @return fun(e: { text: string, bubble_up: boolean })
function M.create_event_recorder(id)
  return function(e) table.insert(sink(), { id = id, text = e.text }) end
end

--- Read (and optionally clear) the event sink as plain data for host asserts.
--- @param opts? { clear?: boolean }
--- @return morph._test.util.Event[]
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
  local elem = assert(morph:get_element_by_id(id), 'element "' .. id .. '" not found')
  local start = elem.extmark.start
  vim.api.nvim_win_set_cursor(0, { start[1] + 1, start[2] })
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

return M
