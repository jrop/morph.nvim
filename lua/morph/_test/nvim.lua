---@diagnostic disable: global-in-non-module
local assert = require 'morph._test.assert'

--- Nvim remote-control helper.
--- Spawns a child `nvim --headless --embed` with RPC on stdio,
--- drives it via msgpack-RPC, and snapshots structured screen-state.

--- @class morph._test.SnapshotWindow
--- @field bufnr integer
--- @field lines string[]
--- @field cursor { [1]: integer, [2]: integer }
--- @field config table
--- @field extmarks { id: integer, row: integer, col: integer, end_row: integer, end_col: integer, hl_group?: string }[]

--- @class morph._test.Screen
--- @field lines string[]      composited screen grid, one string per row (full TUI screenshot)
--- @field rows integer        grid height (vim.o.lines)
--- @field columns integer     grid width (vim.o.columns)
--- @field mode string         editor mode
--- @field curwin integer      current window id
--- @field curbuf integer      current buffer id

--- @class morph._test.Nvim
--- @field jobid integer
--- @field chan integer
local Nvim = {}
Nvim.__index = Nvim

--- @param opts? { columns?: integer, rows?: integer, rtp?: string }
--- @return morph._test.Nvim  handle with :stop(), :request(method, ...), :notify(...), :screen()
function Nvim.start(opts)
  opts = opts or {}
  --- @cast opts { columns?: integer, rows?: integer, rtp?: string }
  --- @type morph._test.Nvim
  local self = setmetatable({}, Nvim)

  --- @type string[]
  local argv = { vim.v.argv[1], '--headless', '--embed', '-n', '-u', 'NORC' }
  if opts.columns then
    vim.list_extend(argv, { '--cmd', ('set columns=%d'):format(opts.columns) })
  end
  if opts.rows then vim.list_extend(argv, { '--cmd', ('set lines=%d'):format(opts.rows) }) end

  local jobid = vim.fn.jobstart(argv, {
    rpc = true,
    env = { NVIM_TEST = 'true' },
  })
  if jobid <= 0 then error('jobstart failed: ' .. jobid, 2) end
  self.jobid = jobid
  -- With rpc=true the job-id IS the channel-id.
  self.chan = jobid

  -- Wait for readiness: retry nvim_get_api_info up to ~1s.
  if
    not vim.wait(
      1000,
      function() return pcall(vim.rpcrequest, self.chan, 'nvim_get_api_info') end,
      10
    )
  then
    vim.fn.jobstop(jobid)
    error('child nvim never became ready', 2)
  end

  -- Add repo to child rtp.
  local rtp = opts.rtp or vim.fn.getcwd()
  self:request('nvim_command', 'set rtp+=' .. vim.fn.escape(rtp, ' '))

  return self
end

--- @param method string
--- @param ... any
function Nvim:request(method, ...) return vim.rpcrequest(self.chan, method, ...) end

--- @param method string
--- @param ... any
function Nvim:notify(method, ...) vim.rpcnotify(self.chan, method, ...) end

--- Type keys into the child nvim, auto-translating key-notation.
--- Simpler than feedkeys: no mode, no escape_ks — just virtual typing.
--- @param keys string  key notation (e.g. "ihello\<Esc>")
function Nvim:input(keys)
  local translated = self:request('nvim_replace_termcodes', keys, true, true, true)
  return self:request('nvim_input', translated)
end

--- @return morph._test.Screen
function Nvim:screen()
  return self:exec_func(function()
    vim.cmd 'redraw!'
    local lines = {}
    for r = 1, vim.o.lines do
      local row = {}
      for c = 1, vim.o.columns do
        table.insert(row, vim.fn.screenstring(r, c) or ' ')
      end
      table.insert(lines, table.concat(row))
    end
    return {
      lines = lines,
      rows = vim.o.lines,
      columns = vim.o.columns,
      mode = vim.fn.mode(),
      curwin = vim.api.nvim_get_current_win(),
      curbuf = vim.api.nvim_get_current_buf(),
    }
  end) --[[@as morph._test.Screen]]
end

--- Execute a Lua function inside the child process.
--- The function is serialized via `string.dump` — upvalues are NOT preserved.
---
--- Dispatches on function arity:
--- - **0 params** — sync: runs via `rpcrequest`, returns the result directly.
--- - **1 param** — async: receives a `done` callback; call `done(results)` to
---   invoke `cb(results)` in the host. Returns nil.
--- - **2+ params** — error.
--- @param f function  arity 0 (sync) or 1 (async)
--- @param cb? fun(results: any)  async callback (required when arity is 1)
--- @param ... any  extra arguments passed to f (sync only)
--- @return any  result when sync, nil when async
function Nvim:exec_func(f, cb, ...)
  local inf = debug.getinfo(f, 'u')
  local nparams = inf and inf.nparams or 0

  if nparams == 0 then
    return self:request(
      'nvim_exec_lua',
      'local f = ...; return assert(loadstring(f))(select(2, ...))',
      { string.dump(f), ... }
    )
  elseif nparams == 1 then
    _G.assert(
      type(cb) == 'function',
      ('exec_func: async function (arity 1) requires a callback, got %s'):format(type(cb))
    )

    _G.___async_cb_registry = _G.___async_cb_registry or {}
    _G.___async_cb_counter = (_G.___async_cb_counter or 0) + 1
    local cb_id = _G.___async_cb_counter
    _G.___async_cb_registry[cb_id] = function(results)
      _G.___async_cb_registry[cb_id] = nil
      if cb then cb(results) end
    end

    self:notify(
      'nvim_exec_lua',
      [[
        local code, cb_id = ...
        local fn = assert(loadstring(code))
        local done = function(results)
          vim.rpcrequest(
            1,
            'nvim_exec_lua',
            '_G.___async_cb_registry[' .. tostring(cb_id) .. '](...)',
            { results }
          )
        end
        fn(done)
      ]],
      { string.dump(f), cb_id }
    )
    return nil
  else
    error('exec_func: function must have arity 0 (sync) or 1 (async), got ' .. nparams)
  end
end
--- Capture screen and assert lines match expected.
--- On mismatch, prints a unified diff via `assert.diff`.
--- @param expected string[]  expected screen lines
--- @param msg? string  assertion label
function Nvim:assert_screenshot(expected, msg)
  msg = msg or 'screenshot mismatch'
  local screen = self:screen()
  local got = screen.lines

  -- Fast path: identical
  local ok = #got == #expected
  if ok then
    for i = 1, #got do
      if got[i] ~= expected[i] then
        ok = false
        break
      end
    end
  end
  if ok then return end

  error(
    msg
      .. '\n'
      .. assert.diff(
        vim.iter(got):map(function(l) return vim.inspect(l) end):totable(),
        vim.iter(expected):map(function(l) return vim.inspect(l) end):totable()
      )
  )
end

function Nvim:stop()
  pcall(vim.fn.jobstop, self.jobid)
  self.jobid = -1
end

return Nvim
