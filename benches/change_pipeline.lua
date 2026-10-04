--- Headless benchmarks for morph's change-detection pipeline.
---
--- Run with `mise run bench`, or filter groups with
--- `mise run bench -- diff` (substring match on the group name). Each case
--- prints ms/op; read the numbers as trends, not absolutes -- compare only
--- runs from the same machine and nvim version.
---
--- Why these exist: the band design was born from a measured cliff. A
--- full-document extmark sweep cost ~170ms per burst at big_data scale,
--- while deriving the dirty region from a content diff keeps per-burst work
--- proportional to the burst itself. These benches keep that cliff -- and
--- the neighbors that could grow their own cliffs -- visible over time.
---
--- Groups: diff_to_band (the guard's sensor), drain (what one user burst
--- pays end to end), patch_lines (the render-path write twin), sweep (the
--- full-vs-band extmark query contrast).

--- Make `require 'morph'` resolve no matter the cwd: this file lives in
--- <root>/benches, so the runtime root is one level up. The first chunk's
--- getinfo is never nil under -l, but the checker cannot prove it.
---@diagnostic disable-next-line: need-check-nil
local script_path = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(script_path, ':p:h:h')
package.path = ('%s/lua/?.lua;%s'):format(root, package.path)

local Morph = require 'morph'

--- Build n synthetic document lines, wide enough that string compares in
--- the trim are realistic rather than pointer-interned no-ops.
--- @param n integer
--- @return string[]
local function build_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = ('row %d %s'):format(i, ('x'):rep(40))
  end
  return lines
end

--- @param lines string[]
--- @return string[]
local function copy_lines(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line
  end
  return out
end

--- Time `fn` per operation: one untimed warmup (JIT the body, touch lazy
--- loads), then the loop, reported as milliseconds per op.
--- @param name string
--- @param iterations integer
--- @param fn fun()
local function bench(name, iterations, fn)
  fn()
  local t0 = vim.uv.hrtime()
  for _ = 1, iterations do
    fn()
  end
  local ms = (vim.uv.hrtime() - t0) / 1e6 / iterations
  print(('  %-52s %9.3f ms/op'):format(name, ms))
end

--- @type table<string, fun()>
local groups = {}

-- The guard's sensor: content diff of the render snapshot vs the live
-- lines. The trim must stay O(n) in the document, the DP bounded by the
-- burst, and the degenerate guard must keep huge rewrites off the DP.
groups.diff_to_band = function()
  for _, n in ipairs { 1000, 50000 } do
    local base = build_lines(n)
    bench(('identical (%d lines)'):format(n), 50, function() Morph.diff_to_band(base, base) end)

    -- Edit depth must not matter: the trim walks both ends, the DP sees one
    -- line either way.
    for _, pos in ipairs { 1, math.floor(n / 2), n } do
      local edited = copy_lines(base)
      edited[pos] = edited[pos] .. '!'
      bench(
        ('1-line edit at row %d (%d lines)'):format(pos, n),
        50,
        function() Morph.diff_to_band(base, edited) end
      )
    end

    -- Just under the degenerate threshold: the DP works, and its cost is
    -- the worst case a legitimate rewrite burst may pay.
    local rewrite = copy_lines(base)
    for i = 1001, 1300 do
      rewrite[i] = ('rewritten %d'):format(i)
    end
    bench(
      ('300-line rewrite, DP path (%d lines)'):format(n),
      20,
      function() Morph.diff_to_band(base, rewrite) end
    )

    -- Past the threshold: the DP must be skipped entirely.
    for i = 1001, 1400 do
      rewrite[i] = ('rewritten %d'):format(i)
    end
    bench(
      ('400-line rewrite, degenerate (%d lines)'):format(n),
      20,
      function() Morph.diff_to_band(base, rewrite) end
    )
  end
end

-- What one user burst pays end to end: fetch the live lines, then diff.
-- The get_lines cost is the price of observing settled state -- the design
-- accepted it deliberately (render pays the same read).
groups.drain = function()
  local n = 50000
  local base = build_lines(n)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, base)
  local edited = copy_lines(base)
  edited[math.floor(n / 2)] = edited[math.floor(n / 2)] .. '!'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, edited)

  bench(('get_lines + diff (%d lines)'):format(n), 20, function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    Morph.diff_to_band(base, lines)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- The render-path write twin: same engine, applied to the buffer. A small
-- edit into a large document must stay proportional to the edit, not the
-- document (the trim + bounded DP guarantee that).
groups.patch_lines = function()
  local n = 50000
  local base = build_lines(n)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, base)

  local changed = copy_lines(base)
  changed[math.floor(n / 2)] = changed[math.floor(n / 2)] .. '!'
  bench(
    ('patch 1-line change (%d lines)'):format(n),
    20,
    function() Morph.patch_lines(buf, base, changed) end
  )

  local grown = copy_lines(changed)
  for i = 1, 10 do
    table.insert(grown, math.floor(n / 2) + i, ('inserted %d'):format(i))
  end
  bench(
    ('patch 10-line insert (%d lines)'):format(n),
    20,
    function() Morph.patch_lines(buf, changed, grown) end
  )
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- The cliff the band was born from: policing a burst by sweeping the whole
-- document's extmarks versus querying only the band. At big_data scale the
-- first was ~170ms per burst once per-mark processing was added; the second
-- is what the guard actually pays.
groups.sweep = function()
  local n = 50000
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local ns = vim.api.nvim_create_namespace 'morph_bench_sweep'
  local lines = build_lines(n)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- One extmark per line, like big_data's readonly-literal wrapping.
  for i = 0, n - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, { end_row = i, end_col = 10 })
  end

  bench(
    ('full-document extmark query (%d marks)'):format(n),
    10,
    function() vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { -1, -1 }, {}) end
  )
  bench(
    'band-scoped extmark query (3 rows)',
    200,
    function() vim.api.nvim_buf_get_extmarks(buf, ns, { 24999, 0 }, { 25001, 50 }, {}) end
  )
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- CLI: nvim --headless -l benches/change_pipeline.lua [filter ...]. Args
-- arrive through `arg` (the standalone-interpreter convention), not `...`.
-- An omitted or empty filter runs every group.
--- @type string[]
local filters = _G.arg or {}
---@diagnostic disable-next-line: call-non-callable -- the stub disagrees; vim.version is callable at runtime
print(('morph benches -- nvim %s'):format(tostring(vim.version())))
for name, fn in pairs(groups) do
  local wanted = #filters == 0
  for _, filter in ipairs(filters) do
    if filter ~= '' and name:find(filter, 1, true) then wanted = true end
  end
  if wanted then
    print(name .. ':')
    fn()
  end
end
