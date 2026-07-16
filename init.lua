--                                             _                  _
--                  _ __ ___   ___  _ __ _ __ | |__    _ ____   _(_)_ __ ___
--                 | '_ ` _ \ / _ \| '__| '_ \| '_ \  | '_ \ \ / / | '_ ` _ \
--                 | | | | | | (_) | |  | |_) | | | |_| | | \ V /| | | | | | |
--                 |_| |_| |_|\___/|_|  | .__/|_| |_(_)_| |_|\_/ |_|_| |_| |_|
--                                      |_|
--
--                      .:   :
--                   =.:=:      :
--                 %#      +#    =               :::::::
--               %   #@@=    +   .            ..  :++=.  .:
--              :  %@@@      %    : .====.   : +%       %=  :
--            :    @@@:      %  .=         := %   @@@     #=  =
--           .     @@@@      # =       .   =.%   @@@        %  =               .:..:
--           #              #.=     ....   =.%   @@@@ #      %  :             :      =
--          .              += =    ...  =  =.%    @@@@        #  :           :       =
--          #             %:  =.        ==   %                %  :     =    .:         :
--          =%           #     .==::==##%%#=.:%               %   =   .     .:         =
--          :.%       +#   ..... =###%%%%%%.  =.              %   ===+=.     =.       :
--          =   =%%#.      ...... +##%%%%%%.   :%            %.   =.= = :=  ..:======
--           .             ...... :##%%%%%%:...  +%         %.   .=  = =.  ......   :
--           =:       .=   ...... .##%%%%%%....    .#%+==##.     =      =:........  .
--          =  :=:.:=:     .....   ##%%%%%#....  :.             = .:    .=.::::.... .
--          :             .....    ##%%%%%...      ==         :=  =. ...:::::::.... .
--          =            . .. =   .##%%%%+  =          :====:   :=...:::::::::.==.  .
--                            ######%%%%%  .: ...            .=:...::::=:::::..:=   .
--           ..             =####%%%%%%%   ==.    =:           ..:::=======::..:=   :
--             =    .=:..:=:%#+#+++++%+  =         :+==+=      ..::::=====:::. ::   :
--             .   =.       .#%###%#=  .=     .......          ..:::=======::. ::  :
--                =. ...      :==      =    ...:......        ..::::======::.. =   .
--                .........    .==    .:  ........... . . . ....::::======::. .=  :
--             : ...:::......   :. :::.=:  . ..:=:.... . . ....::::::::=:::.  :..
--              : .....=:....   ::  .....======. ..  . .  . ....::::::::::.. .=
--               .:.. ..==:    :=...:.::.... .= .... .  .  . ....:::::::::.  =
--                 ::       .:...::::::::::...=:   .  .  .    ............  =
--                    .=.     ...::::::::::::...... .. . ...      . ...   .:
--                       :     ..:::::=:==::::............. .       :.   :
--                        =    ...::::=====:::::............       =.  =
--                          =    ..:::=====::::::::::.:.....      ==
--                            =.    ..::::::::::::::::.:...     .
--                               :.    ......:.::::..:....    ..
--                                  =:..   . . ........     :.
--                                       +=====:         =:
--                                           :=::::==.
--
-- A React-like component library for Neovim buffers.
--
-- This module provides:
--   - h()     : hyperscript for creating virtual DOM tags
--   - Pos00   : 0-based position class for buffer coordinates
--   - Extmark : wrapper around Neovim's extmark API
--   - Ctx     : component context (props, state, lifecycle)
--   - Morph   : the main class that renders components to buffers
--
-- The core idea: describe your UI as a tree of tags (like HTML), and Morph
-- will efficiently update the buffer to match using Levenshtein diffing.

-- Used by expr-mappings to swallow key-presses without executing anything
function _G.MorphOpFuncNoop() end

--------------------------------------------------------------------------------
-- Type Definitions
--
-- The type hierarchy flows from abstract to concrete:
--   Tag (recipe) -> Element (instantiated tag with extmark)
--   Node -> Tree (composable structures)
--   Component (function that produces Trees)
--------------------------------------------------------------------------------

--- @alias morph.TagEventHandler fun(e: { tag: morph.Element, mode: string, lhs: string, bubble_up: boolean }): string

--- @alias morph.TagAttributes {
---   [string]?: unknown,
---   on_change?: (fun(e: { text: string,  bubble_up: boolean }): unknown),
---   key?: string|integer,
---   imap?: table<string, morph.TagEventHandler>,
---   nmap?: table<string, morph.TagEventHandler>,
---   vmap?: table<string, morph.TagEventHandler>,
---   xmap?: table<string, morph.TagEventHandler>,
---   omap?: table<string, morph.TagEventHandler>,
---   extmark?: vim.api.keyset.set_extmark
--- }

--- A tag is the result of calling h(...): it is a recipe for creating an
--- element.
--- @class morph.Tag
--- @field kind 'tag'
--- @field name string | morph.Component<any, any>
--- @field attributes morph.TagAttributes
--- @field children morph.Tree
--- @field private ctx? morph.Ctx
--- @field private curr_text? string

--- An element is an instantiated Tag
--- @class morph.Element : morph.Tag
--- @field extmark morph.Extmark

--- @alias morph.Node nil | boolean | string | number | morph.Tag
--- @alias morph.Tree morph.Node | morph.Node[]
--- @alias morph.Component<TProps, TState> fun(ctx: morph.Ctx<TProps, TState>): morph.Tree

--------------------------------------------------------------------------------
-- Tree Utilities
--
-- Helper functions for working with the tree structure. These are used
-- throughout the codebase to identify node types and compute diffs.
--------------------------------------------------------------------------------

--- Determine the type of a tree node.
--- @param node morph.Tree
--- @return 'nil'|'boolean'|'string'|'number'|'array'|'tag'|'component'
local function tree_type(node)
  if node == nil or node == vim.NIL then return 'nil' end
  if type(node) == 'boolean' then return 'boolean' end
  if type(node) == 'string' then return 'string' end
  if type(node) == 'number' then return 'number' end
  if type(node) == 'function' then
    local name = debug.getinfo(node, 'n').name or '<anonymous>'
    error(
      'morph.nvim: raw component function "'
        .. name
        .. '" found in vnode tree. '
        .. 'Wrap it: h('
        .. name
        .. ', ...)'
    )
  end
  if type(node) == 'table' then
    if node.kind == 'tag' then
      return vim.is_callable(node.name) and 'component' or 'tag'
    else
      return 'array'
    end
  end
  error('unknown tree node type: ' .. type(node))
end

--- Compute an identity key for a node, used to match old/new nodes during reconciliation.
--- Includes the node type, component function (if any), and explicit key attribute.
--- For primitive types without explicit keys, uses index to distinguish positions.
--- @param node morph.Node
--- @param index integer fallback key if no explicit key
--- @return string
local function tree_identity_key(node, index)
  local t = tree_type(node)
  if t == 'nil' or t == 'boolean' then
    return t .. '-' .. tostring(index)
  elseif t == 'string' or t == 'number' then
    return t .. '-' .. tostring(index)
  elseif t == 'array' then
    return 'array-' .. tostring(index)
  elseif t == 'tag' then
    local tag = node --[[@as morph.Tag]]
    return 'tag-' .. tag.name .. '-' .. tostring(tag.attributes.key or index)
  elseif t == 'component' then
    local tag = node --[[@as morph.Tag]]
    return 'component-' .. tostring(tag.name) .. '-' .. tostring(tag.attributes.key or index)
  end
  error 'unreachable'
end

-- Pre-computed keymap mode tables and attribute names.
-- Avoids allocating `{ 'i', 'n', 'v', 'x', 'o' }` and concatenating
-- `mode .. 'map'` on every on_tag callback invocation.
local KEYMAP_MODES = { 'i', 'n', 'v', 'x', 'o' }
local KEYMAP_ATTRS = { 'imap', 'nmap', 'vmap', 'xmap', 'omap' }

--------------------------------------------------------------------------------
-- Levenshtein Diff Algorithm
--
-- Used to compute the minimal set of changes needed to transform one list
-- into another. We use this both for text diffing (lines, characters) and
-- for component reconciliation (matching old/new nodes).
--------------------------------------------------------------------------------

--- @alias morph.LevenshteinChange<T> { kind: 'add', item: T, index: integer } | { kind: 'delete', item: T, index: integer } | { kind: 'change', from: T, to: T, index: integer }

--- @class morph.LevenshteinOpts
--- @field from any[]
--- @field to any[]
--- @field are_any_equal? boolean
--- @field cost? morph.LevenshteinCost

--- @class morph.LevenshteinCost
--- @field of_add? integer
--- @field of_delete? integer
--- @field of_change? fun(a: any, b: any, ai: integer, bi: integer): integer

--- Compute the minimal edit sequence to transform `from` into `to`.
--- @param opts morph.LevenshteinOpts
--- @return morph.LevenshteinChange<any>[]
local function levenshtein(opts)
  local are_any_equal = opts.are_any_equal == nil and true or opts.are_any_equal
  local cost_of_add = opts.cost and opts.cost.of_add or 1
  local cost_of_delete = opts.cost and opts.cost.of_delete or 1
  local cost_of_change = opts.cost and opts.cost.of_change or function() return 1 end

  local from, to = opts.from, opts.to
  local m, n = table.maxn(from), table.maxn(to)

  -- Build the DP table. Each cell dp[i][j] represents the minimum cost to
  -- transform from[1..i] into to[1..j].
  --- @diagnostic disable-next-line: assign-type-mismatch
  local dp = {} --- @type integer[][]
  for i = 0, m do
    --- @diagnostic disable-next-line: assign-type-mismatch
    dp[i] = { [0] = i * cost_of_delete }
  end
  for j = 1, n do
    --- @diagnostic disable-next-line: need-check-nil
    dp[0][j] = j * cost_of_add
  end

  --- @diagnostic disable: need-check-nil
  for i = 1, m do
    for j = 1, n do
      if are_any_equal and from[i] == to[j] then
        dp[i][j] = dp[i - 1][j - 1]
      else
        dp[i][j] = math.min(
          dp[i - 1][j] + cost_of_delete,
          dp[i][j - 1] + cost_of_add,
          dp[i - 1][j - 1] + cost_of_change(from[i], to[j], i, j)
        )
      end
    end
  end
  --- @diagnostic enable: need-check-nil

  -- Backtrack to extract the changes.
  --
  -- IMPORTANT: We must check which operation was *actually* used to reach the
  -- current cell, not just compare previous cell values. When costs are
  -- variable (e.g., key-based reconciliation where matching keys cost less),
  -- the previous cell values don't tell us which path was taken - we need to
  -- verify that prev_cell + operation_cost == current_cell.
  --
  -- Priority when multiple operations tie: delete > add > change.
  -- This prefers removing items over substituting them, which produces more
  -- intuitive results for keyed list reconciliation (e.g., removing 'b' from
  -- ['a','b'] should delete 'b', not substitute 'b' for 'a' and delete 'a').
  local changes = {} --- @type morph.LevenshteinChange[]
  local i, j = m, n

  while i > 0 or j > 0 do
    --- @diagnostic disable-next-line: need-check-nil
    local current = dp[i][j]

    -- Check if delete was the operation used (move up: dp[i-1][j] + delete_cost == current)
    --- @diagnostic disable-next-line: need-check-nil
    local can_delete = i > 0 and dp[i - 1][j] + cost_of_delete == current

    -- Check if add was the operation used (move left: dp[i][j-1] + add_cost == current)
    --- @diagnostic disable-next-line: need-check-nil
    local can_add = j > 0 and dp[i][j - 1] + cost_of_add == current

    -- Check if change/keep was the operation used (move diagonal)
    local can_diag = false
    if i > 0 and j > 0 then
      if are_any_equal and from[i] == to[j] then
        --- @diagnostic disable-next-line: need-check-nil
        can_diag = dp[i - 1][j - 1] == current
      else
        --- @diagnostic disable-next-line: need-check-nil
        can_diag = dp[i - 1][j - 1] + cost_of_change(from[i], to[j], i, j) == current
      end
    end

    -- Choose operation with priority: delete > add > diagonal (change/keep)
    if can_delete then
      table.insert(changes, { kind = 'delete', item = from[i], index = i })
      i = i - 1
    elseif can_add then
      table.insert(changes, { kind = 'add', item = to[j], index = i + 1 })
      j = j - 1
    elseif can_diag then
      if not are_any_equal or from[i] ~= to[j] then
        table.insert(changes, { kind = 'change', from = from[i], to = to[j], index = i })
      end
      i, j = i - 1, j - 1
    else
      -- This should never happen with a valid DP table
      error('levenshtein backtrack: no valid operation found at (' .. i .. ',' .. j .. ')')
    end
  end

  return changes
end

--------------------------------------------------------------------------------
-- Textlock Detection
--
-- Neovim has a "textlock" that prevents buffer/window changes during certain
-- operations (like autocmd callbacks). We need to detect this so we can
-- schedule state updates for later instead of applying them immediately.
--------------------------------------------------------------------------------

--- A lazily-created unlisted scratch buffer used to probe for textlock.
--- We reuse a single buffer to avoid creating/destroying buffers on every check.
--- @type integer?
local textlock_probe_buf = nil

--- Check if we're currently in a textlock (can't modify buffers).
--- Uses nvim_buf_set_lines on a hidden probe buffer.
--- @return boolean
local function is_textlock()
  --- @diagnostic disable-next-line: unnecessary-if
  if vim.in_fast_event() then return true end

  -- Lazily create the probe buffer. We can't create it during textlock,
  -- but that's fine - if we're in textlock, this pcall will fail and we'll
  -- know we're in textlock. The buffer persists for future checks.
  if not textlock_probe_buf or not vim.api.nvim_buf_is_valid(textlock_probe_buf) then
    local ok, buf = pcall(vim.api.nvim_create_buf, false, true)
    if not ok then
      -- Buffer creation failed - we're definitely in textlock
      return true
    end
    textlock_probe_buf = buf --[[@as integer]]
  end

  -- Try to set lines - this will fail with E565 if textlock is active.
  -- Setting the same content is a no-op in terms of buffer state.
  --- @diagnostic disable-next-line: param-type-mismatch
  local ok, err = pcall(vim.api.nvim_buf_set_lines, textlock_probe_buf, 0, -1, false, { '' })

  if not ok and type(err) == 'string' and err:find 'E565' then return true end

  return false
end

--------------------------------------------------------------------------------
-- Buffer API Readiness
--
-- During Neovim startup (before VimEnter), file buffers may have their
-- filename set but content not loaded yet. Rendering into such buffers
-- causes content to be prepended instead of replaced (bug).
--------------------------------------------------------------------------------

--- Check if the buffer API is in a consistent state for rendering.
--- @param bufnr integer
--- @return boolean
local function is_buffer_api_ready(bufnr)
  -- Vim hasn't finished startup - buffer state may be inconsistent
  if vim.v.vim_did_enter == 0 then return false end

  -- File buffer has filename but isn't loaded yet
  if vim.api.nvim_buf_get_name(bufnr) ~= '' and vim.fn.bufloaded(bufnr) == 0 then return false end

  return true
end

--------------------------------------------------------------------------------
-- Buffer Watcher
--
-- Neovim's nvim_buf_attach on_bytes callback fires *during* the change,
-- when the buffer is in an inconsistent state. We use TextChanged autocmd
-- to delay our callback until after the change is complete.
--------------------------------------------------------------------------------

--- @class morph.BufWatcher
--- @field last_on_bytes_args unknown[]
--- @field text_changed_autocmd_id integer
--- @field cleanup fun() Remove the watcher

--- Create a buffer watcher that calls `callback` after text changes.
--- @param bufnr integer
--- @param callback function Called with on_bytes args after TextChanged fires
--- @return morph.BufWatcher
local function create_buf_watcher(bufnr, callback)
  -- Guard: buffer API must be ready for nvim_buf_attach to work
  if not is_buffer_api_ready(bufnr) then
    error(
      'morph.nvim: Cannot create buffer watcher - buffer not yet loaded. '
        .. 'Buffer must be loaded before mounting.',
      0
    )
  end

  local watcher = {
    last_on_bytes_args = nil,
  }

  -- Capture on_bytes args but don't call callback yet
  local attach_ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(...) watcher.last_on_bytes_args = { ... } end,
  })

  -- Safety check: attach may fail for other reasons
  if not attach_ok then
    error(
      'morph.nvim: Failed to attach buffer change detection. '
        .. 'on_change handlers will not work.',
      0
    )
  end

  -- Fire callback when TextChanged fires (buffer is now stable)
  watcher.text_changed_autocmd_id = vim.api.nvim_create_autocmd(
    { 'TextChanged', 'TextChangedI', 'TextChangedP' },
    {
      buffer = bufnr,
      callback = function()
        if not watcher.last_on_bytes_args then
          -- on_bytes hasn't fired yet. This can happen when TextChanged
          -- triggers before any actual buffer changes (e.g., on initial mount
          -- into a non-empty buffer).
          return
        end

        local last_args = watcher.last_on_bytes_args
        watcher.last_on_bytes_args = nil
        callback(unpack(last_args))
      end,
    }
  )

  function watcher.cleanup() vim.api.nvim_del_autocmd(watcher.text_changed_autocmd_id) end

  return watcher
end

--------------------------------------------------------------------------------
-- h(): Hyperscript - Creating Virtual DOM Tags
--
-- Usage:
--   h('text', { hl = 'Comment' }, { 'Hello' })  -- explicit text tag
--   h.Comment({}, { 'Hello' })                  -- shorthand: h.<highlight>
--   h(MyComponent, { prop = 1 }, { ... })       -- component tag
--
-- This is the primary way to construct your UI tree.
--------------------------------------------------------------------------------

--- @type table<string, fun(attributes?: morph.TagAttributes, children?: morph.Tree): morph.Tag> & fun(name: string | morph.Component, attributes?: morph.TagAttributes, children?: morph.Tree): morph.Tag>
--- @diagnostic disable-next-line: assign-type-mismatch
local h = setmetatable({}, {
  -- h('text', attrs, children) - create a tag directly
  __call = function(_, name, attributes, children)
    return { kind = 'tag', name = name, attributes = attributes or {}, children = children or {} }
  end,

  -- h.Comment(attrs, children) - shorthand for h('text', { hl = 'Comment', ...attrs }, children)
  __index = function(self, highlight_group)
    return function(attributes, children)
      attributes = attributes or {}
      local merged_attrs = { hl = highlight_group }
      for k, v in pairs(attributes) do
        merged_attrs[k] = v
      end
      return self('text', merged_attrs, children or {})
    end
  end,
})

--------------------------------------------------------------------------------
-- Pos00: Zero-Based Buffer Positions
--
-- Neovim's API is inconsistent about 0-based vs 1-based indexing.
-- This class provides a consistent 0-based position type with comparison ops.
--------------------------------------------------------------------------------

--- @class morph.Pos00
--- @field [1] integer 0-based row
--- @field [2] integer 0-based column
local Pos00 = {}
Pos00.__index = Pos00

--- @param row integer 0-based row
--- @param col integer 0-based column
--- @return morph.Pos00
function Pos00.new(row, col) return setmetatable({ row, col }, Pos00) end

--- @param other unknown
function Pos00:__eq(other)
  return type(other) == 'table' and self[1] == other[1] and self[2] == other[2]
end

--- @param other unknown
function Pos00:__lt(other)
  if type(other) ~= 'table' then return false end
  if self[1] ~= other[1] then return self[1] < other[1] end
  return self[2] < other[2]
end

--- @param other unknown
function Pos00:__gt(other)
  if type(other) ~= 'table' then return false end
  if self[1] ~= other[1] then return self[1] > other[1] end
  return self[2] > other[2]
end

--------------------------------------------------------------------------------
-- Extmark: Wrapper Around Neovim's Extmark API
--
-- Extmarks track regions of text that move as the buffer is edited.
-- This wrapper provides a cleaner interface and handles edge cases like
-- extmarks that extend past the end of the buffer.
--------------------------------------------------------------------------------

--- @class morph.Extmark
--- @field id integer
--- @field start morph.Pos00
--- @field stop morph.Pos00
--- @field raw vim.api.keyset.extmark_details
--- @field private ns integer
--- @field private bufnr integer
local Extmark = {}
Extmark.__index = Extmark

--- Create a new extmark in the buffer.
--- Uses left gravity for start (stays put when text inserted before) and
--- right gravity for end (expands when text inserted at end).
--- @param bufnr integer
--- @param ns integer
--- @param start morph.Pos00
--- @param stop morph.Pos00
--- @param opts vim.api.keyset.set_extmark
--- @return morph.Extmark
function Extmark.new(bufnr, ns, start, stop, opts)
  local extmark_opts = {
    end_row = stop[1],
    end_col = stop[2],
    right_gravity = false,
    end_right_gravity = true,
  }
  for k, v in next, opts do
    extmark_opts[k] = v
  end

  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start[1], start[2], extmark_opts)
  return setmetatable(
    { id = id, start = start, stop = stop, raw = opts, ns = ns, bufnr = bufnr },
    Extmark
  )
end

--- Retrieve an existing extmark by its ID.
--- @param bufnr integer
--- @param ns integer
--- @param id integer
--- @return morph.Extmark?
function Extmark.by_id(bufnr, ns, id)
  local raw = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
  if not raw then return nil end

  local start_row0, start_col0, details = unpack(raw)
  return Extmark._from_raw(bufnr, ns, id, start_row0, start_col0, assert(details))
end

--- @private
--- @param bufnr integer
--- @param ns integer
--- @param id integer
--- @param start_row0 integer
--- @param start_col0 integer
--- @param details vim.api.keyset.extmark_details
--- Construct an Extmark from raw API data, normalizing bounds that extend past buffer end.
function Extmark._from_raw(bufnr, ns, id, start_row0, start_col0, details)
  local start = Pos00.new(start_row0, start_col0)
  local stop = Pos00.new(start_row0, start_col0)

  if details and details.end_row ~= nil and details.end_col ~= nil then
    stop = Pos00.new(details.end_row --[[@as integer]], details.end_col --[[@as integer]])
  end

  local extmark = setmetatable(
    { id = id, start = start, stop = stop, raw = details, ns = ns, bufnr = bufnr },
    Extmark
  )

  -- Clamp extmark bounds to actual buffer size (extmarks can overshoot after deletions)
  local last_line_idx = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, last_line_idx, last_line_idx + 1, true)[1]
    or ''
  if extmark.start[1] > last_line_idx then extmark.start = Pos00.new(last_line_idx, #last_line) end
  if extmark.stop[1] > last_line_idx then extmark.stop = Pos00.new(last_line_idx, #last_line) end

  return extmark
end

--- @private
--- Find all extmarks that overlap with the given region.
--- @param bufnr integer
--- @param ns integer
--- @param start morph.Pos00
--- @param stop morph.Pos00
--- @return morph.Extmark[]
function Extmark._get_in_range(bufnr, ns, start, stop)
  local raw_extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    ns,
    { start[1], start[2] },
    { stop[1], stop[2] },
    { details = true, overlap = true }
  )

  return vim
    .iter(raw_extmarks)
    :map(function(ext)
      local id, line0, col0, details = unpack(ext)
      return Extmark._from_raw(bufnr, ns, id, line0, col0, assert(details))
    end)
    :totable()
end

--- @private
--- Extract the text content covered by this extmark.
--- @return string
function Extmark:_text()
  local start, stop = self.start, self.stop
  if start == stop then return '' end

  -- Handle inverted positions (start > stop), which can occur after buffer
  -- deletions. Return empty string as there's no valid content to extract.
  if start > stop then return '' end

  -- Handle edge case: if stop is at column 0, we need to include the newline
  -- from the previous line, which getregion doesn't handle well
  local needs_trailing_newline = false
  if stop[2] == 0 and stop[1] > 0 then
    needs_trailing_newline = true
    local prev_line = vim.api.nvim_buf_get_lines(self.bufnr, stop[1] - 1, stop[1], true)[1] or ''
    stop = Pos00.new(stop[1] - 1, #prev_line)
  end

  -- Convert to 1-based positions for getregion (Neovim's API inconsistency strikes again)
  local pos1 = { self.bufnr, start[1] + 1, start[2] + 1, 0 }
  local pos2 = { self.bufnr, stop[1] + 1, stop[2] == 0 and 1 or stop[2], 0 }

  local ok, lines = pcall(vim.fn.getregion, pos1, pos2, { type = 'v' })
  if not ok then
    vim.api.nvim_echo({
      { '(morph.nvim:getregion:invalid-pos) ', 'ErrorMsg' },
      { '{ start, end } = ' .. vim.inspect({ pos1, pos2 }, { newline = ' ', indent = '' }) },
    }, true, {})
    error(lines)
  end

  if needs_trailing_newline then
    table.insert(lines --[[@as string[] ]], '')
  end
  return table.concat(lines --[[@as string[] ]], '\n')
end

--------------------------------------------------------------------------------
-- Ctx: Component Context (Props, State, Lifecycle)
--
-- Every component receives a Ctx that provides:
--   - props: immutable data passed from parent
--   - state: mutable data owned by this component
--   - phase: 'mount' | 'update' | 'unmount' lifecycle stage
--   - update(newState): trigger a re-render with new state
--   - refresh(): re-render with current state
--   - do_after_render(fn): schedule work after the render completes
--------------------------------------------------------------------------------

--- @generic TProps
--- @generic TState
--- @class morph.Ctx<TProps, TState>
--- @field bufnr integer
--- @field document? morph.Morph
--- @field name string
--- @field phase 'mount'|'update'|'unmount'
--- @field props TProps
--- @field state? TState
--- @field children morph.Tree
--- @field private on_change? fun(): any
--- @field private prev_rendered_children? morph.Tree
--- @field private _register_after_render_callback? fun(cb: function)
local Ctx = {}
Ctx.__index = Ctx

--- @param bufnr? integer
--- @param document? morph.Morph
--- @param props TProps
--- @param state? TState
--- @param children morph.Tree
function Ctx.new(bufnr, document, props, state, children)
  return setmetatable({
    bufnr = bufnr,
    document = document,
    name = '',
    phase = 'mount',
    props = props,
    state = state,
    children = children,
  }, Ctx)
end

--- Update state and trigger a re-render.
--- During 'mount' phase, this only updates state (no re-render, to avoid infinite loops).
--- If we're in a textlock (e.g., during an on_bytes callback), the re-render is scheduled.
--- @param new_state TState
function Ctx:update(new_state)
  self.state = new_state

  -- Don't trigger re-render during mount (component is still being set up)
  if self.phase == 'mount' then return end
  if not self.on_change then return end

  -- Debounced mode: on_change wrapper defers via vim.defer_fn, so it never
  -- touches the buffer synchronously. But we still need to check both
  -- is_textlock() (expr mappings → E565) and vim.in_fast_event() (fast events
  -- forbid buffer mutation). When either applies, schedule instead.
  if self.document and self.document.debounce_ms then
    if vim.in_fast_event() or is_textlock() then
      vim.schedule(self.on_change)
    else
      self.on_change()
    end
    return
  end

  -- Textlock means we can't modify the buffer right now - schedule for later
  local is_textlocked = (self.document and self.document.textlock) or is_textlock()
  if is_textlocked then
    vim.schedule(self.on_change)
  else
    self.on_change()
  end
end

--- Re-render with current state (convenience wrapper around update).
function Ctx:refresh() self:update(self.state) end

--- Schedule a callback to run after the current render completes.
--- Useful for focus management, scrolling, etc.
--- @param fn function
function Ctx:do_after_render(fn)
  if self._register_after_render_callback then self._register_after_render_callback(fn) end
end

--- @private
--- Build the fallback tree for error display. Checks props.fallback first,
--- then falls back to a default error UI.
--- @return morph.Tree
function Ctx:build_error_fallback()
  local fallback = self.props.fallback
  --- @diagnostic disable-next-line: need-check-nil
  if type(fallback) == 'function' then return fallback(self.state.error) end
  if fallback ~= nil then return fallback end

  --- @diagnostic disable: need-check-nil
  local name_part = self.state.error.component_name ~= ''
      and (' in ' .. self.state.error.component_name .. '@' .. self.state.error.phase)
    or ''
  --- @diagnostic enable: need-check-nil
  return {
    h('text', { hl = 'ErrorMsg' }, 'Error' .. name_part),
    '\n',
    --- @diagnostic disable-next-line: need-check-nil
    h('text', { hl = 'Comment' }, self.state.error.message),
  }
end

-------------------------------------------------------------------------------
-- Error Formatting
-------------------------------------------------------------------------------

--- @class morph.RenderError
--- @field message string original error message
--- @field component_name string component that threw
--- @field phase string lifecycle phase
--- @field render_trace string[] ancestor component names
local RenderError = {}
RenderError.__index = RenderError

--- @param message string
--- @param component_name string
--- @param phase string
--- @param render_trace string[]
--- @return morph.RenderError
function RenderError.new(message, component_name, phase, render_trace)
  return setmetatable({
    message = message,
    component_name = component_name,
    phase = phase,
    render_trace = render_trace,
  }, RenderError)
end

--- @return string
function RenderError:__tostring()
  local lines = {
    'Error in ' .. self.component_name .. '@' .. self.phase .. ': ' .. self.message,
  }
  if #self.render_trace > 0 then
    table.insert(lines, 'Render trace: ' .. table.concat(self.render_trace, ' > '))
  end
  return table.concat(lines, '\n')
end

--------------------------------------------------------------------------------
-- Morph: The Main Renderer Class
--
-- A Morph instance is bound to a single buffer. It provides:
--   - render(tree): render static markup to the buffer
--   - mount(tree): render a component tree with lifecycle management
--   - get_elements_at(pos): find elements at a cursor position
--   - get_element_by_id(id): find an element by its id attribute
--------------------------------------------------------------------------------

--- @alias morph.MorphTextState {
---   lines: string[],
---   extmarks: morph.Extmark[],
---   tags_to_extmark_ids: table<morph.Tag, integer?>,
---   extmark_ids_to_tag: table<integer, morph.Tag?>,
---   top_level_tag?: morph.Tag,
--- }

--- @class morph.Morph
--- @field private bufnr integer
--- @field private ns integer
--- @field private changedtick integer
--- @field private changing boolean
--- @field private textlock boolean
--- @field private debounce_ms? integer
--- @field private original_keymaps table<string, table<string, any>>
--- @field private text_content { old: morph.MorphTextState, curr: morph.MorphTextState }
--- @field private component_tree { old: morph.Tree }
--- @field private cleanup_hooks function[]
--- @field private buf_watcher morph.BufWatcher? -- Created lazily
local Morph = {}
Morph.__index = Morph

--------------------------------------------------------------------------------
-- Static Utilities
--
-- These functions work on trees without needing a Morph instance.
-- Useful for testing or converting markup to strings.
--------------------------------------------------------------------------------

--- Convert a tree to an array of lines, optionally calling on_tag for each tag.
--- This is the core "rendering" logic that flattens the tree into text.
--- @param opts { tree: morph.Tree, on_tag?: fun(tag: morph.Tag, start0: morph.Pos00, stop0: morph.Pos00): any }
--- @return string[]
function Morph.markup_to_lines(opts)
  local lines = {} --- @type string[]
  local line_buffers = {} --- @type string[][]
  local curr_line1, curr_col1 = 1, 1 -- 1-based position tracking

  -- Stack of text accumulators - each tag tracks its own text content
  -- so we can cache it for on_change handlers later
  local text_accumulators = {} --- @type { text: string[] }[]

  --- @param s string
  local function emit_text(s)
    local buf = line_buffers[curr_line1]
    if not buf then
      buf = {}
      line_buffers[curr_line1] = buf
    end
    table.insert(buf, s)
    curr_col1 = curr_col1 + #s
    -- Append to all active accumulators (for nested tags)
    for _, acc in ipairs(text_accumulators) do
      table.insert(acc.text, s)
    end
  end

  local function emit_newline()
    curr_line1 = curr_line1 + 1
    curr_col1 = 1
    for _, acc in ipairs(text_accumulators) do
      table.insert(acc.text, '\n')
    end
  end

  --- @param node morph.Tree
  local function visit(node)
    local node_type = tree_type(node)

    if node_type == 'string' then
      -- Split on newlines and emit each part
      local parts = vim.split(node --[[@as string]], '\n')
      for i, part in ipairs(parts) do
        if i > 1 then emit_newline() end
        emit_text(part)
      end
    elseif node_type == 'number' then
      -- Convert number to string and emit
      emit_text(tostring(node --[[@as number]]))
    elseif node_type == 'array' then
      for i = 1, table.maxn(node) do
        local child = node[i]
        if child ~= nil then visit(child) end
      end
    elseif node_type == 'tag' then
      local tag = node --[[@as morph.Tag]]
      table.insert(text_accumulators, { text = {} })

      local start0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)
      visit(tag.children)
      local stop0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)

      -- Cache the rendered text on the tag
      local acc = table.remove(text_accumulators)
      tag.curr_text = table.concat(acc.text)

      if opts.on_tag then opts.on_tag(tag, start0, stop0) end
    elseif node_type == 'component' then
      local tag = node --[[@as morph.Tag]]
      local Component = tag.name --[[@as morph.Component]]
      local ctx = Ctx.new(nil, nil, tag.attributes, nil, tag.children)

      local start0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)
      visit(Component(ctx))
      local stop0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)

      -- Immediately unmount (this is stateless rendering)
      ctx.phase = 'unmount'
      Component(ctx)

      if opts.on_tag then opts.on_tag(tag, start0, stop0) end
    end
    -- nil/boolean nodes produce no output
  end

  visit(opts.tree)

  -- Finalize: concatenate line buffers into final lines table.
  -- table.concat is O(n) and single-allocation in LuaJIT.
  for i = 1, curr_line1 do
    local buf = line_buffers[i]
    lines[i] = buf and table.concat(buf) or ''
  end

  return lines
end

--- Convert a tree to a single string (convenience wrapper).
--- @param opts { tree: morph.Tree }
--- @return string
function Morph.markup_to_string(opts) return table.concat(Morph.markup_to_lines(opts), '\n') end

--- Apply minimal edits to transform buffer content from old_lines to new_lines.
--- Uses a two-stage strategy:
---   1. (O(1)) If line count delta >30% on a large buffer (>500 lines), skip
---      diffing entirely and do a full buffer replace.
---   2. (O(n)) Trim common prefix/suffix lines, then run Levenshtein on the
---      (much smaller) middle section for character-precise edits.
--- @param bufnr integer
--- @param old_lines string[]?
--- @param new_lines string[]
function Morph.patch_lines(bufnr, old_lines, new_lines)
  old_lines = old_lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local max_lines = math.max(#old_lines, #new_lines)

  -- Stage 1 (O(1)): check if the line count changed enough that
  -- Levenshtein would be wasteful - if so, do a full buffer replace.
  if max_lines > 500 then
    local len_delta = math.abs(#old_lines - #new_lines) / max_lines
    if len_delta > 0.3 then
      local view = vim.fn.winsaveview()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      vim.fn.winrestview(view)
      return
    end
  end

  -- Stage 2 (O(n)): trim common prefix/suffix lines so Levenshtein
  -- only sees the changed middle.  A single-line insertion deep in a
  -- 1000-line list balloons Levenshtein's O(n^2) cost; most tree-view
  -- edits are localised, so the trimmed input is orders of magnitude
  -- smaller than the raw line count suggests.
  local prefix = 0
  while
    prefix < #old_lines
    and prefix < #new_lines
    and old_lines[prefix + 1] == new_lines[prefix + 1]
  do
    prefix = prefix + 1
  end

  local suffix = 0
  while
    suffix < #old_lines - prefix
    and suffix < #new_lines - prefix
    and old_lines[#old_lines - suffix] == new_lines[#new_lines - suffix]
  do
    suffix = suffix + 1
  end

  local trimmed_old = {}
  for i = prefix + 1, #old_lines - suffix do
    trimmed_old[#trimmed_old + 1] = old_lines[i]
  end
  local trimmed_new = {}
  for i = prefix + 1, #new_lines - suffix do
    trimmed_new[#trimmed_new + 1] = new_lines[i]
  end

  local line_changes = levenshtein { from = trimmed_old, to = trimmed_new }

  for _, change in ipairs(line_changes) do
    local line0 = prefix + change.index - 1

    if change.kind == 'add' then
      vim.api.nvim_buf_set_lines(bufnr, line0, line0, true, { change.item })
    elseif change.kind == 'delete' then
      vim.api.nvim_buf_set_lines(bufnr, line0, line0 + 1, true, {})
    elseif change.kind == 'change' then
      -- For changed lines, do character-level diffing for minimal edits
      local char_changes = levenshtein {
        --- @diagnostic disable-next-line: param-type-mismatch
        from = vim.split(change.from, ''),
        --- @diagnostic disable-next-line: param-type-mismatch
        to = vim.split(change.to, ''),
      }

      for _, char_change in ipairs(char_changes) do
        local col0 = char_change.index - 1
        if char_change.kind == 'add' then
          vim.api.nvim_buf_set_text(bufnr, line0, col0, line0, col0, { char_change.item })
        elseif char_change.kind == 'delete' then
          vim.api.nvim_buf_set_text(bufnr, line0, col0, line0, col0 + 1, {})
        elseif char_change.kind == 'change' then
          vim.api.nvim_buf_set_text(bufnr, line0, col0, line0, col0 + 1, { char_change.to })
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

--- Create a new Morph instance bound to a buffer.
--- @param bufnr integer? Buffer number (nil or 0 means current buffer)
--- @return morph.Morph
function Morph.new(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr

  -- Each buffer gets its own namespace for extmarks
  if vim.b[bufnr]._renderer_ns == nil then
    vim.b[bufnr]._renderer_ns = vim.api.nvim_create_namespace('morph:' .. tostring(bufnr))
  end

  local self = setmetatable({
    bufnr = bufnr,
    ns = vim.b[bufnr]._renderer_ns,
    changedtick = 0,
    changing = false,
    textlock = false,
    original_keymaps = {},
    text_content = {
      old = { lines = {}, extmarks = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
      curr = { lines = {}, extmarks = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
    },
    component_tree = { old = nil },
    cleanup_hooks = {},
    buf_watcher = nil, -- Created lazily in _ensure_buf_watcher()
  }, Morph)

  -- Snapshot all buffer-local keymaps so we can restore them before each render
  for _, mode in ipairs(KEYMAP_MODES) do
    self.original_keymaps[mode] = {}
    --- @diagnostic disable-next-line: param-type-mismatch
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      self.original_keymaps[mode][map.lhs] = map
    end
  end

  -- Clean up when buffer is deleted
  local cleanup_autocmd = vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
    buffer = self.bufnr,
    callback = function()
      for _, cleanup in ipairs(self.cleanup_hooks) do
        cleanup()
      end
    end,
  })
  table.insert(self.cleanup_hooks, function() vim.api.nvim_del_autocmd(cleanup_autocmd) end)

  return self
end

--- @private
--- Ensure the buffer watcher is created. Called lazily from render/mount.
function Morph:_ensure_buf_watcher()
  if self.buf_watcher then return end

  -- Guard: buffer API must be ready for nvim_buf_attach to work
  if not is_buffer_api_ready(self.bufnr) then
    error(
      'morph.nvim: Cannot create buffer watcher - buffer not yet loaded. '
        .. 'Buffer must be loaded before mounting.',
      0
    )
  end

  self.buf_watcher = create_buf_watcher(
    self.bufnr,
    function(...) self:_on_bytes_after_autocmd(...) end
  )
  table.insert(self.cleanup_hooks, self.buf_watcher.cleanup)
end

--------------------------------------------------------------------------------
-- Instance Methods
--------------------------------------------------------------------------------

--- Render static markup to the buffer.
--- This is a "one-shot" render - no lifecycle, no state, just text + extmarks.
--- @param tree morph.Tree
function Morph:render(tree)
  -- Guard: buffer may have been deleted while render was scheduled
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end

  -- Guard: buffer API may not be ready during startup (before VimEnter)
  if not is_buffer_api_ready(self.bufnr) then
    vim.notify(
      'morph.nvim: Buffer not yet loaded, deferring render. '
        .. 'Consider wrapping render in vim.schedule() for cleaner startup.',
      vim.log.levels.WARN
    )
    vim.schedule(function() self:render(tree) end)
    return
  end

  -- Ensure buffer watcher is created (for on_change handlers)
  self:_ensure_buf_watcher()

  -- Detect if buffer changed externally since our last render
  local changedtick = vim.b[self.bufnr].changedtick
  if changedtick ~= self.changedtick then
    self.text_content.curr = {
      extmarks = {},
      lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false),
      tags_to_extmark_ids = {},
      extmark_ids_to_tag = {},
    }
    self.changedtick = changedtick
  end

  -- We need to collect extmarks during tree traversal, but can't create them
  -- until after the buffer text is updated (extmarks need valid positions)
  local pending_extmarks = {} --- @type { tag: morph.Tag, start: morph.Pos00, stop: morph.Pos00, opts: any }[]

  -- Clear all buffer-local keymaps, then restore originals
  for _, mode in ipairs(KEYMAP_MODES) do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(self.bufnr, mode)) do
      --- @diagnostic disable-next-line: param-type-mismatch
      pcall(vim.keymap.del, mode, map.lhs, { buffer = self.bufnr })
    end
    for _, map in pairs(self.original_keymaps[mode] or {}) do
      -- Wrap mapset in nvim_buf_call to ensure buffer-local maps are restored
      -- to self.bufnr, regardless of which buffer is currently focused
      vim.api.nvim_buf_call(self.bufnr, function() vim.fn.mapset(map) end)
    end
  end

  -- Traverse the tree, collecting text lines and extmark info
  local lines = Morph.markup_to_lines {
    tree = tree,
    on_tag = function(tag, start, stop)
      if tag.name ~= 'text' then return end

      -- Convert hl attribute to extmark highlight
      if type(tag.attributes.hl) == 'string' then
        tag.attributes.extmark = tag.attributes.extmark or {}
        tag.attributes.extmark.hl_group = tag.attributes.extmark.hl_group or tag.attributes.hl
      end

      table.insert(pending_extmarks, {
        tag = tag,
        start = start,
        stop = stop,
        opts = tag.attributes.extmark or {},
      })

      -- Register keymaps for any mode handlers (nmap, imap, vmap, xmap, omap)
      for i = 1, 5 do
        local handlers = tag.attributes[KEYMAP_ATTRS[i]]
        local mode = KEYMAP_MODES[i]
        for lhs, _ in pairs(handlers or {}) do
          vim.keymap.set(mode, lhs, function()
            local result = self:_dispatch_keypress(mode, lhs)

            -- Empty string means "swallow this keypress". In insert mode that's
            -- easy, but in normal mode we need a trick: use g@ with a no-op
            -- operator function.
            if result == '' and mode ~= 'i' then
              vim.go.operatorfunc = 'v:lua.MorphOpFuncNoop'
              return 'g@ '
            end
            return result
          end, { buffer = self.bufnr, expr = true, replace_keycodes = true })
        end
      end
    end,
  }

  -- Edge case: empty trees produce empty lines array, but buffers always have
  -- at least one line. Set curr.lines to reflect reality, not the empty tree.
  if #lines == 0 then lines = { '' } end

  -- Update buffer text with minimal edits
  --- @diagnostic disable-next-line: assign-type-mismatch
  self.text_content.old = self.text_content.curr
  self.text_content.curr =
    { lines = lines, extmarks = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} }

  -- Clear extmarks BEFORE patching to avoid Neovim's auto-deletion overhead
  -- when lines with extmarks are deleted by patch_lines
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)

  self.changing = true
  Morph.patch_lines(self.bufnr, self.text_content.old.lines, lines)
  self.changing = false
  self.changedtick = vim.b[self.bufnr].changedtick

  -- Create extmarks for the new tree
  for _, pending in ipairs(pending_extmarks) do
    local extmark = Extmark.new(self.bufnr, self.ns, pending.start, pending.stop, pending.opts)
    self.text_content.curr.extmark_ids_to_tag[extmark.id] = pending.tag
    self.text_content.curr.tags_to_extmark_ids[pending.tag] = extmark.id
    table.insert(self.text_content.curr.extmarks, extmark)
  end
  -- First pending_extmark is the outermost <text> node (DFS order).
  -- If it spans the full buffer, it's the top-level tag.
  local first = pending_extmarks[1]
  local rendered_end = Pos00.new(#lines - 1, #(lines[#lines] or ''))
  if first and first.start[1] == 0 and first.start[2] == 0 and first.stop == rendered_end then
    self.text_content.curr.top_level_tag = first.tag
  end
end

--- Mount a component tree with full lifecycle management.
--- Components can have state, respond to updates, and run cleanup on unmount.
--- @param tree morph.Tree
--- @param opts? { debounce_ms?: integer }  debounce_ms: ms to debounce rerenders (0=sync)
function Morph:mount(tree, opts)
  opts = opts or {}
  local debounce_ms = opts.debounce_ms or (vim.env.NVIM_TEST and 0 or 16)
  if debounce_ms > 0 then self.debounce_ms = debounce_ms end
  if vim.b[self.bufnr]._morph_mounted then
    error('Morph:mount() can only be called once per buffer', 0)
  end

  -- Guard: buffer API may not be ready during startup
  if not is_buffer_api_ready(self.bufnr) then
    vim.notify(
      'morph.nvim: Buffer not yet loaded, deferring mount. '
        .. 'Consider wrapping mount in vim.schedule() for cleaner startup.',
      vim.log.levels.WARN
    )
    vim.schedule(function() self:mount(tree) end)
    return
  end

  -- Ensure buffer watcher is created (for on_change handlers)
  self:_ensure_buf_watcher()

  vim.b[self.bufnr]._morph_mounted = true

  -- Callbacks scheduled via ctx:do_after_render() - run after each render
  local after_render_callbacks = {} --- @type function[]
  -- Debounce state: shared between the rerender wrapper (Step 2) and
  -- the BufDelete autocmd cleanup (Step 4).
  local debounce_timer = nil --- @type table?
  local last_invoke_time = nil --- @type integer?

  --- @param cb function
  local function schedule_after_render(cb) table.insert(after_render_callbacks, cb) end

  -- Render trace stack: tracks component ancestry for error messages
  local render_trace = {} --- @type morph.Ctx[]

  -- Forward declarations for mutual recursion
  --- @diagnostic disable: unused
  local reconcile_tree, reconcile_array, reconcile_component, unmount_tree, rerender
  --- @diagnostic enable: unused

  --- Unmount a tree, calling unmount lifecycle on all components (depth-first).
  --- @param old_tree morph.Tree
  unmount_tree = function(old_tree)
    local node_type = tree_type(old_tree)

    if node_type == 'array' then
      -- Fast path: directly unmount each child without key matching overhead
      for _, child in
        ipairs(old_tree --[[@as morph.Node[] ]])
      do
        --- @diagnostic disable-next-line: need-check-nil
        unmount_tree(child)
      end
    elseif node_type == 'tag' then
      -- Tag children can be any tree type, so recurse with unmount_tree
      --- @diagnostic disable-next-line: need-check-nil
      unmount_tree((old_tree --[[@as morph.Tag]]).children)
    elseif node_type == 'component' then
      local tag = old_tree --[[@as morph.Tag]]
      local Component = tag.name --[[@as morph.Component]]

      -- Skip if already unmounted (prevents double-unmount on component_tree.old
      -- not being updated due to a prior unmount error during reconciliation)
      if not tag.ctx then return end
      local ctx = tag.ctx

      -- Unmount children first (depth-first)
      --- @diagnostic disable-next-line: need-check-nil
      unmount_tree(ctx.prev_rendered_children)

      -- Then unmount this component
      ctx.phase = 'unmount'
      local ok, err = pcall(Component, ctx)
      ctx.on_change = nil
      ctx._register_after_render_callback = nil
      tag.ctx = nil
      if not ok then
        local names = {} --- @type string[]
        for _, c in ipairs(render_trace) do
          table.insert(names, c.name)
        end
        error(RenderError.new(tostring(err), ctx.name, 'unmount', names), 0)
      end
    end
  end

  --- Reconcile old and new trees, handling mount/update/unmount.
  --- Returns the rendered (simplified) tree.
  --- @param old_tree morph.Tree
  --- @param new_tree morph.Tree
  --- @return morph.Tree
  reconcile_tree = function(old_tree, new_tree)
    local old_type = tree_type(old_tree)
    local new_type = tree_type(new_tree)

    -- If type changed, unmount old tree first
    if old_type ~= new_type then unmount_tree(old_tree) end

    -- Handle each node type
    local rendered

    if new_type == 'nil' or new_type == 'boolean' then
      rendered = new_tree
    elseif new_type == 'string' or new_type == 'number' then
      rendered = new_tree
    elseif new_type == 'array' then
      local old_array = (old_type == 'array') and old_tree --[[@as morph.Node[]?]] or nil
      --- @diagnostic disable-next-line: need-check-nil
      rendered = reconcile_array(old_array, new_tree --[[@as morph.Node[] ]])
    elseif new_type == 'tag' then
      local new_tag = new_tree --[[@as morph.Tag]]
      local old_children = (old_type == new_type) and (old_tree --[[@as morph.Tag]]).children or nil
      --- @diagnostic disable-next-line: need-check-nil
      rendered = h(new_tag.name, new_tag.attributes, reconcile_tree(old_children, new_tag.children))
    elseif new_type == 'component' then
      --- @diagnostic disable-next-line: need-check-nil
      rendered = reconcile_component(old_tree, new_tree --[[@as morph.Tag]])
    end

    return rendered
  end

  --- Reconcile arrays of nodes using Levenshtein to match up old/new nodes.
  --- This is where the "diffing" magic happens for lists.
  --- @param old_nodes morph.Node[]?
  --- @param new_nodes morph.Node[]?
  --- @return morph.Node[]
  reconcile_array = function(old_nodes, new_nodes)
    --- @type morph.Node[]
    old_nodes = old_nodes or {}
    --- @type morph.Node[]
    new_nodes = new_nodes or {}

    -- Build key -> node map for old nodes (React-style reconciliation)
    -- This is O(n) and much faster than Levenshtein O(n²) for large lists
    local old_by_key = {}
    for i = 1, table.maxn(old_nodes) do
      local node = old_nodes[i]
      if node ~= nil then
        local key = tree_identity_key(node --[[@as morph.Node]], i)
        old_by_key[key] = node
      end
    end

    -- Scan new list, reusing nodes by key or mounting new ones
    local result = {} --- @type morph.Node[]
    for i = 1, table.maxn(new_nodes) do
      local new_node = new_nodes[i]
      if new_node ~= nil then
        local key = tree_identity_key(new_node --[[@as morph.Node]], i)
        local old_node = old_by_key[key]

        --- @diagnostic disable-next-line: unnecessary-if
        if old_node then
          -- Key match: update existing node
          table.insert(result, reconcile_tree(old_node, new_node))
          old_by_key[key] = nil -- Mark as used
        else
          -- No key match: mount new node
          table.insert(result, reconcile_tree(nil, new_node))
        end
      end
    end

    -- Unmount any old nodes that weren't reused
    for _, old_node in pairs(old_by_key) do
      reconcile_tree(old_node, nil)
    end

    return result
  end

  --- Reconcile a component node (mount, update, or reuse existing context).
  --- @param old_tree morph.Tree
  --- @param new_tag morph.Tag
  reconcile_component = function(old_tree, new_tag)
    local Component = new_tag.name --[[@as morph.Component]]

    -- Try to reuse existing context from old tree
    local ctx
    local old_type = tree_type(old_tree)
    if old_type == 'component' then
      local old_tag = old_tree --[[@as morph.Tag]]
      -- Only reuse context when the component function is the same
      if old_tag.name == Component then
        ctx = old_tag.ctx
      else
        -- Component function changed: unmount old, mount fresh
        unmount_tree(old_tree)
      end
    end

    --- @diagnostic disable-next-line: unnecessary-if
    if ctx then
      ctx.phase = 'update'
    else
      ctx = Ctx.new(self.bufnr, self, new_tag.attributes, nil, new_tag.children)
    end

    -- Set name before calling Component so ctx.name is populated if it throws.
    -- Components that self-name (ctx.name = 'X') will override this; on update the
    -- guard skips since the name was already set during mount.
    --- @diagnostic disable-next-line: need-check-nil
    if ctx.name == '' then ctx.name = debug.getinfo(Component, 'n').name or '<anonymous>' end

    -- Update context with new props/children and wire up callbacks
    ctx.props = new_tag.attributes
    ctx.children = new_tag.children
    ctx.on_change = rerender
    ctx._register_after_render_callback = schedule_after_render

    -- Render the component
    new_tag.ctx = ctx
    table.insert(render_trace, ctx)
    --- @diagnostic disable-next-line: param-type-mismatch
    local ok, rendered_children = pcall(Component, ctx)
    if not ok then
      table.remove(render_trace)
      local names = {} --- @type string[]
      for _, c in ipairs(render_trace) do
        table.insert(names, c.name)
      end
      error(RenderError.new(tostring(rendered_children), ctx.name, ctx.phase, names), 0)
    end

    -- ErrorBoundary: catch descendant render errors, show fallback instead of crashing
    local result
    if Component == Morph.ErrorBoundary then
      local ok, res = pcall(reconcile_tree, ctx.prev_rendered_children, rendered_children)
      if not ok then
        --- @diagnostic disable: need-check-nil
        ctx.state.has_error = true
        local is_render_error = getmetatable(res) == RenderError
        ctx.state.error = {
          message = is_render_error and res.message or tostring(res),
          component_name = is_render_error and res.component_name or '',
          phase = is_render_error and res.phase or '',
          render_trace = is_render_error and res.render_trace
            or vim.tbl_map(function(c) return c.name end, render_trace),
        }
        rendered_children = ctx:build_error_fallback()
        result = reconcile_tree(ctx.prev_rendered_children, rendered_children)
        --- @diagnostic enable: need-check-nil
      else
        result = res
      end
    else
      result = reconcile_tree(ctx.prev_rendered_children, rendered_children)
    end

    ctx.prev_rendered_children = rendered_children
    table.remove(render_trace)

    -- As soon as we've mounted, move past the 'mount' state. This is
    -- because Ctx will not fire `on_update` if it is still in the
    -- 'mount' state (to avoid stack overflows).
    ctx.phase = 'update'

    return result
  end

  --- Perform a full re-render of the component tree.
  rerender = function()
    local simplified_tree = reconcile_tree(self.component_tree.old, tree)
    self.component_tree.old = tree
    self:render(simplified_tree)

    -- Run any scheduled after-render callbacks, then clear the list.
    -- We clear after (not before) to handle the case where ctx:update()
    -- is called during the update phase, which would trigger a nested rerender.
    local callbacks = after_render_callbacks
    after_render_callbacks = {}
    for _, callback in ipairs(callbacks) do
      callback()
    end
  end

  -- Don't track this autocmd in cleanup_hooks, because the prior BufDelete/BufUnload/BufWipeout
  -- will take priority, and will delete this autocmd before it even has a
  -- chance to run:
  local unmount_autocmd_id
  unmount_autocmd_id = vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
    buffer = self.bufnr,
    callback = function()
      vim.b[self.bufnr]._morph_mounted = nil
      if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
      end
      reconcile_tree(self.component_tree.old, nil)
      --- @diagnostic disable-next-line: param-type-mismatch
      vim.api.nvim_del_autocmd(unmount_autocmd_id)
    end,
  })

  -- Install the debounced wrapper BEFORE the initial render so that
  -- ctx.on_change = rerender (set in reconcile_component) captures the
  -- debounced version, not the original.
  if debounce_ms > 0 then
    local orig_rerender = rerender

    --- MaxWait debounce: at most one rerender per debounce_ms interval
    --- while updates keep arriving, plus a trailing-edge final render
    --- when they stop.
    ---
    --- On each call:
    ---   - If a timer is already pending, do nothing (state is already
    ---     up to date — Ctx:update sets self.state before calling us).
    ---   - If not, compute the time remaining until the next allowed
    ---     render slot (debounce_ms since last_invoke_time) and schedule
    ---     a timer for that duration.
    ---
    --- This guarantees a ceiling rate of 1 render / debounce_ms, and
    --- the trailing edge ensures the UI always shows the latest state
    --- after a burst settles.
    rerender = function()
      -- Pass-through: initial mount render runs synchronously.
      -- last_invoke_time is nil until set after the initial rerender() call.
      if last_invoke_time == nil then
        orig_rerender()
        return
      end

      if debounce_timer and debounce_timer:is_active() then return end

      local now = vim.uv.now()
      local ms_since_last_invoke = math.max(0, now - last_invoke_time)
      local delay
      if ms_since_last_invoke >= debounce_ms then
        delay = debounce_ms
      else
        delay = debounce_ms - ms_since_last_invoke
      end

      debounce_timer = vim.defer_fn(function()
        debounce_timer = nil
        last_invoke_time = vim.uv.now()
        orig_rerender()
      end, delay)
    end
  end

  -- Kick off initial render
  rerender()
  -- Record when the initial render finished (used by debounce maxWait logic).
  -- Must be set AFTER rerender() to allow the pass-through guard above.
  last_invoke_time = vim.uv.now()
end

--- Find all elements that contain the given position, sorted innermost to outermost.
--- @param pos [integer, integer]|morph.Pos00 0-based position
--- @param mode string? Vim mode ('i', 'n', etc.) - affects cursor width semantics
--- @return morph.Element[]
function Morph:get_elements_at(pos, mode)
  pos = Pos00.new(pos[1], pos[2])
  mode = (mode or vim.api.nvim_get_mode().mode):sub(1, 1)

  -- Get candidate extmarks and convert to elements
  local candidates = Extmark._get_in_range(self.bufnr, self.ns, pos, pos)

  local elements = {} --- @type morph.Element[]
  for _, extmark in ipairs(candidates) do
    local tag = self.text_content.curr.extmark_ids_to_tag[extmark.id]
    if tag and self._position_intersects_extmark(pos, extmark, mode) then
      table.insert(elements, vim.tbl_extend('force', {}, tag, { extmark = extmark }))
    end
  end

  -- Sort innermost (smallest) to outermost (largest)
  table.sort(elements, function(a, b)
    local ea, eb = a.extmark, b.extmark
    if ea.start == eb.start and ea.stop == eb.stop then return ea.id < eb.id end
    return ea.start >= eb.start and ea.stop <= eb.stop
  end)

  return elements
end

--- @private
--- Check if a position truly intersects an extmark (Neovim's API is over-inclusive).
--- @param pos morph.Pos00
--- @param extmark morph.Extmark
--- @param mode? string
function Morph._position_intersects_extmark(pos, extmark, mode)
  local start, stop = extmark.start, extmark.stop

  -- Zero-width extmarks at cursor position are considered intersecting
  if pos == start and pos == stop then return true end

  -- Check row bounds
  if pos[1] < start[1] or pos[1] > stop[1] then return false end

  -- Check column bounds on start row
  if pos[1] == start[1] and pos[2] < start[2] then return false end

  -- Check column bounds on stop row
  if pos[1] == stop[1] then
    -- Special case: on an empty line where extmark ends at column 0,
    -- the cursor at column 0 should be considered inside. This happens when
    -- an element ends with a newline - the cursor on the resulting empty line
    -- has nowhere else to be, so it should still trigger handlers.
    --- @diagnostic disable-next-line: invert-if
    if pos[2] == 0 and stop[2] == 0 then
      local line = vim.api.nvim_buf_get_lines(extmark.bufnr, pos[1], pos[1] + 1, true)[1] or ''
      if #line == 0 then return true end
    end

    -- In insert mode the cursor is "thin" (between characters), so we include
    -- the position if it's <= stop (cursor can sit "on" the boundary)
    -- In normal mode the cursor is "wide" (occupies a character), so we only
    -- include if strictly < stop
    --- @diagnostic disable-next-line: invert-if
    if mode == 'i' then
      --- @diagnostic disable-next-line: invert-if
      if pos[2] > stop[2] then return false end
    else
      if pos[2] >= stop[2] then return false end
    end
  end

  return true
end

--- Find an element by its id attribute.
--- @param id string
--- @return morph.Element?
function Morph:get_element_by_id(id)
  for tag, extmark_id in pairs(self.text_content.curr.tags_to_extmark_ids) do
    if tag.attributes.id == id then
      local extmark = assert(Extmark.by_id(self.bufnr, self.ns, extmark_id))
      return vim.tbl_extend('force', {}, tag, { extmark = extmark }) --[[@as morph.Element]]
    end
  end
end

--------------------------------------------------------------------------------
-- Keymap Management
--
-- We intercept keypresses to dispatch them to element handlers.
-- Original keymaps are snapshotted in Morph.new() and restored before each render.
--------------------------------------------------------------------------------

--- @private
--- Handle a keypress by dispatching to element handlers (innermost first).
--- Returns the key to execute, or '' to swallow the keypress.
--- @param mode string
--- @param lhs string
function Morph:_dispatch_keypress(mode, lhs)
  local cursor = vim.api.nvim_win_get_cursor(0)
  --- @diagnostic disable-next-line: need-check-nil, assign-type-mismatch
  local pos0 = { cursor[1] - 1, cursor[2] } --- @type [integer, integer]

  local elements = self:get_elements_at(pos0)
  if #elements == 0 then return lhs end

  -- Dispatch to handlers, bubbling up until one handles it
  local should_cancel = false
  for _, elem in ipairs(elements) do
    local handler = vim.tbl_get(elem.attributes, mode .. 'map', lhs)
    if vim.is_callable(handler) then
      local event = { tag = elem, mode = mode, lhs = lhs, bubble_up = true }
      local result = handler(event)

      if result == '' then
        -- Handler wants to cancel, but let event bubble in case parent handles it
        should_cancel = true
        --- @diagnostic disable-next-line: unnecessary-if
        if not event.bubble_up then break end
      else
        return result
      end
    end
  end

  return should_cancel and '' or lhs
end

--------------------------------------------------------------------------------
-- Text Change Handling
--
-- When the user edits text inside an element, we detect which elements changed
-- and fire their on_change handlers. This enables controlled input behavior.
--------------------------------------------------------------------------------

--- @private
--- Called after TextChanged autocmd fires, with the on_bytes info.
--- Detects which elements have changed text and fires their on_change handlers.
function Morph:_on_bytes_after_autocmd(
  _,
  _,
  _,
  start_row0,
  start_col0,
  _,
  _,
  _,
  _,
  new_end_row_off,
  new_end_col_off,
  _
)
  -- Ignore changes we're making ourselves during render
  if self.changing then return end

  -- Per :h nvim_buf_attach on_bytes: when new_end_row_off > 0, new_end_col_off
  -- is the ABSOLUTE column in the end row (from column 0), not a relative
  -- offset from start_col0. Only when the change stays on one line
  -- (new_end_row_off == 0) is new_end_col_off relative to start_col0.
  local end_row0 = start_row0 + new_end_row_off
  local end_col0
  if new_end_row_off == 0 then
    end_col0 = start_col0 + new_end_col_off
  else
    end_col0 = new_end_col_off
  end

  -- Clamp the end column to the length of the line it actually lands on.
  -- on_bytes fires after the buffer change so positions are normally valid,
  -- but extmarks can carry stale bounds past buffer end after deletions, and
  -- nvim_buf_get_extmarks rejects out-of-bounds positions.
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  if end_row0 >= line_count then
    end_row0 = line_count - 1
    end_col0 = 0
  else
    local end_line = vim.api.nvim_buf_get_lines(
      self.bufnr,
      end_row0 --[[@as integer]],
      (end_row0 + 1) --[[@as integer]],
      false
    )[1] or ''
    if end_col0 > #end_line then end_col0 = #end_line end
  end

  -- Find extmarks that overlap the changed region
  local affected_extmarks = Extmark._get_in_range(
    self.bufnr,
    self.ns,
    Pos00.new(start_row0, start_col0),
    --- @diagnostic disable-next-line: param-type-mismatch
    Pos00.new(end_row0, end_col0)
  )

  -- Check which ones actually have different text now
  local changed_elements = {} --- @type { extmark: morph.Extmark, text: string }[]
  for _, extmark in ipairs(affected_extmarks) do
    local tag = self.text_content.curr.extmark_ids_to_tag[extmark.id]
    if tag then
      local new_text = extmark:_text()
      if tag.curr_text ~= new_text then
        tag.curr_text = new_text
        table.insert(changed_elements, { extmark = extmark, text = new_text })
      end
    end
  end

  -- Fallback: no extmark matched - paste likely went beyond top-level node bounds.
  if #changed_elements == 0 then
    local tag = self.text_content.curr.top_level_tag
    if tag and vim.is_callable(tag.attributes.on_change) then
      local content = table.concat(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false), '\n')
      if tag.curr_text ~= content then
        tag.curr_text = content
        local prev_textlock = self.textlock
        self.textlock = true
        local event = { text = content, bubble_up = true }
        --- @diagnostic disable-next-line: need-check-nil
        tag.attributes.on_change(event)
        self.textlock = prev_textlock
      end
    end
    return
  end

  -- Sort innermost first (same as get_elements_at)
  table.sort(changed_elements, function(a, b)
    local ea, eb = a.extmark, b.extmark
    if ea.start == eb.start and ea.stop == eb.stop then return ea.id < eb.id end
    return ea.start >= eb.start and ea.stop <= eb.stop
  end)

  -- Fire on_change handlers with bubbling.
  -- NOTE: Sometimes we can lose the correlation of tag <=> extmark. Don't we
  -- track all extmarks/tags in our bookkeeping? Yes: yes we do. However, we
  -- operate on the assumption that the buffer could have changed outside of
  -- our (Morph's) control. In fact, this does frequently happen. It can even
  -- happen in this block because as we iterate through the list, calling
  -- on_change, the on_change handler can update state => cause a re-render.
  -- This is why we set the textlock, which Ctx:update checks to see if it can
  -- apply the update immediately, or if it needs to vim.schedule(...) it. By
  -- setting the text lock, we make sure we can iterate through the list,
  -- maintaining whatever tag <=> extmark correlations exist at the beginning
  -- of this loop, and we can maintain that all the correct handlers are
  -- called (at least, the ones we CAN guarantee).
  local prev_textlock = self.textlock
  self.textlock = true

  for _, changed in ipairs(changed_elements) do
    local tag = self.text_content.curr.extmark_ids_to_tag[changed.extmark.id]
    local on_change = tag and tag.attributes.on_change

    if vim.is_callable(on_change) then
      local event = { text = changed.text, bubble_up = true }
      --- @diagnostic disable-next-line: need-check-nil
      on_change(event)
      --- @diagnostic disable-next-line: unnecessary-if
      if not event.bubble_up then break end
    end
  end

  self.textlock = prev_textlock
end

-------------------------------------------------------------------------------
-- ErrorBoundary Component
-------------------------------------------------------------------------------

--- React-style error boundary that catches render errors in its children
--- and displays a fallback UI instead of crashing the entire render tree.
Morph.ErrorBoundary = function(ctx)
  ctx.name = 'ErrorBoundary'
  if ctx.phase == 'mount' then ctx.state = { has_error = false, error = nil } end

  if ctx.state.has_error and ctx.phase == 'update' then
    ctx.state.has_error = false
    ctx.state.error = nil
  end

  if ctx.state.has_error then return ctx:build_error_fallback() end

  return ctx.children
end

--------------------------------------------------------------------------------
-- Exports
--------------------------------------------------------------------------------

Morph.h = h
Morph.Pos00 = Pos00
Morph.RenderError = RenderError

-- Export internal functions for testing when NVIM_TEST=true
--- @diagnostic disable-next-line: unnecessary-if
if vim.env.NVIM_TEST then
  Morph._is_buffer_api_ready = is_buffer_api_ready
  Morph._is_textlock = is_textlock
  Morph._levenshtein = levenshtein
  Morph.Extmark = Extmark
end

return Morph
