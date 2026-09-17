--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: global-in-non-module
--- @diagnostic disable: inject-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: undefined-field

--- Mount readiness probe.
---
--- `is_buffer_api_ready` returns false forever for a buffer that has a name but
--- is not loaded (`bufloaded == 0`). `Morph:mount` reacts by notifying and
--- calling `vim.schedule(function() self:mount(tree) end)`, with no bound and no
--- failure path -- so mount never completes and never gives up.
---
--- This probe proves that unboundedness without draining the real event loop
--- (which the runaway starves). It intercepts `vim.schedule`, calls the
--- *first* deferred mount attempt manually, and reports whether mount ever
--- completes or whether it only ever re-defers. It runs in a child
--- `nvim --headless --embed` so module state is pristine; each `exec_func`
--- closure is self-contained (`string.dump` drops upvalues).
local Nvim = require 'morph._test.nvim'

describe('Morph:mount readiness retry', function()
  --- @type morph._test.Nvim
  local nv

  before_each(function() nv = Nvim.start {} end)

  after_each(function()
    if nv then nv:stop() end
    nv = nil
  end)

  it('does not retry forever when the buffer is named but not loaded', function()
    local result = nv:exec_func(function()
      local Morph = require 'morph'

      -- A named, scratch, unloaded buffer: the `bufloaded == 0` clause of
      -- is_buffer_api_ready() is false no matter the startup state.
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, '/tmp/morph-notready-' .. tostring(vim.uv.hrtime()))
      vim.cmd('bunload ' .. buf)

      local deferrals = 0
      local real_notify = vim.notify
      vim.notify = function(msg, ...)
        if type(msg) == 'string' and msg:find('deferring mount', 1, true) then
          deferrals = deferrals + 1
          return
        end
        return real_notify(msg, ...)
      end

      -- Capture (do not forward) every scheduled callback mount queues, so we
      -- can invoke the retry chain by hand and observe its behaviour.
      local real_schedule = vim.schedule
      local queued = {}
      vim.schedule = function(fn) queued[#queued + 1] = fn end

      Morph.new(buf):mount(Morph.h('text', {}, 'RENDERED'))

      -- Drive the retry chain: each manually-invoked attempt re-defers, so
      -- this follows the loop deterministically. Cap it: if the cap is what
      -- stops it, mount is not self-terminating.
      local CAP = 200
      local steps = 0
      local errored = false
      while #queued > 0 and steps < CAP do
        local fn = table.remove(queued, 1)
        steps = steps + 1
        local ok = pcall(fn)
        if not ok then
          errored = true
          break
        end
      end
      local stopped_on_its_own = #queued == 0

      vim.schedule = real_schedule
      vim.notify = real_notify

      return {
        deferrals = deferrals,
        steps = steps,
        mounted = vim.b[buf]._morph_mounted == true,
        stopped_on_its_own = stopped_on_its_own,
        errored = errored,
      }
    end)

    -- Bar for a correct implementation: for a permanently-unready buffer, mount
    -- must terminate on its own -- either by completing (e.g. force-loading the
    -- buffer) or by giving up with a bounded error -- rather than re-deferring
    -- without limit. Either acceptable outcome clears `stopped_on_its_own`
    -- before the cap; the defect exhausts the cap while still queueing a retry.
    assert(
      result.stopped_on_its_own,
      string.format(
        'Morph:mount neither completed nor failed for a named-but-unloaded buffer; '
          .. 'it re-deferred %d times and was still queueing another retry. '
          .. 'Retrying without a bound means a permanently-unready buffer loops forever.',
        result.deferrals
      )
    )
  end)

  -- The chosen bounded outcome for a named-but-unloaded buffer is to load it and
  -- render, not to give up: mounting into the buffer is the caller's intent, and
  -- the load is exactly what makes the buffer ready. This pins that outcome, so
  -- a future change that merely errors (satisfying the probe above) still fails
  -- here, and one that force-mounts without loading fails too (the render would
  -- share the buffer with whatever bunload left behind).
  it('loads a named-but-unloaded buffer and renders into it', function()
    local result = nv:exec_func(function()
      local Morph = require 'morph'
      local h = Morph.h

      -- A named file buffer with real content, so the render has to replace
      -- loaded text rather than start from an empty unloaded buffer.
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, '/tmp/morph-notready-load-' .. tostring(vim.uv.hrtime()))
      vim.cmd('bunload ' .. buf)
      local loaded_before = vim.fn.bufloaded(buf)

      local m = Morph.new(buf)
      local ok, err = pcall(function() m:mount(h('text', {}, 'RENDERED')) end)

      return {
        loaded_before = loaded_before,
        mounted_ok = ok,
        err = tostring(err),
        loaded_after = vim.fn.bufloaded(buf),
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      }
    end)

    assert.are.same(0, result.loaded_before)
    assert.is_true(result.mounted_ok, 'mount should succeed, got: ' .. result.err)
    assert.are.same(1, result.loaded_after)
    assert.are.same({ 'RENDERED' }, result.lines)
  end)
end)
