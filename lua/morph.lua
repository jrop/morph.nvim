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
--- @param node morph.Node
--- @param index integer fallback key if no explicit key
--- @return string
local function tree_identity_key(node, index)
  local t = tree_type(node)
  if t == 'nil' or t == 'boolean' or t == 'string' or t == 'number' then
    return t
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
  local watcher = {
    last_on_bytes_args = {},
  }

  -- Capture on_bytes args but don't call callback yet
  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(...) watcher.last_on_bytes_args = { ... } end,
  })

  -- Fire callback when TextChanged fires (buffer is now stable)
  watcher.text_changed_autocmd_id = vim.api.nvim_create_autocmd(
    { 'TextChanged', 'TextChangedI', 'TextChangedP' },
    {
      buffer = bufnr,
      callback = function() callback(unpack(watcher.last_on_bytes_args)) end,
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
      local merged_attrs = vim.tbl_deep_extend('force', { hl = highlight_group }, attributes or {})
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
  local extmark_opts = vim.tbl_extend('force', {
    end_row = stop[1],
    end_col = stop[2],
    right_gravity = false,
    end_right_gravity = true,
  }, opts)

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
  local pos1 = { self.bufnr, start[1] + 1, start[2] + 1 }
  local pos2 = { self.bufnr, stop[1] + 1, stop[2] == 0 and 1 or stop[2] }

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
---   extmark_ids_to_tag: table<integer, morph.Tag?>
--- }

--- @class morph.Morph
--- @field private bufnr integer
--- @field private ns integer
--- @field private changedtick integer
--- @field private changing boolean
--- @field private textlock boolean
--- @field private original_keymaps table<string, table<string, any>>
--- @field private text_content { old: morph.MorphTextState, curr: morph.MorphTextState }
--- @field private component_tree { old: morph.Tree  }
--- @field private cleanup_hooks function[]
--- @field private buf_watcher morph.BufWatcher
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
  local curr_line1, curr_col1 = 1, 1 -- 1-based position tracking

  -- Stack of text accumulators - each tag tracks its own text content
  -- so we can cache it for on_change handlers later
  local text_accumulators = {} --- @type { text: string[] }[]

  --- @param s string
  local function emit_text(s)
    lines[curr_line1] = (lines[curr_line1] or '') .. s
    curr_col1 = #lines[curr_line1] + 1
    -- Append to all active accumulators (for nested tags)
    for _, acc in ipairs(text_accumulators) do
      table.insert(acc.text, s)
    end
  end

  local function emit_newline()
    table.insert(lines, '')
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
  return lines
end

--- Convert a tree to a single string (convenience wrapper).
--- @param opts { tree: morph.Tree }
--- @return string
function Morph.markup_to_string(opts) return table.concat(Morph.markup_to_lines(opts), '\n') end

--- Apply minimal edits to transform buffer content from old_lines to new_lines.
--- Uses Levenshtein distance to find the shortest edit sequence.
--- @param bufnr integer
--- @param old_lines string[]?
--- @param new_lines string[]
function Morph.patch_lines(bufnr, old_lines, new_lines)
  old_lines = old_lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local line_changes = levenshtein { from = old_lines, to = new_lines }

  for _, change in ipairs(line_changes) do
    local line0 = change.index - 1

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
  }, Morph)

  -- Snapshot all buffer-local keymaps so we can restore them before each render
  for _, mode in ipairs { 'i', 'n', 'v', 'x', 'o' } do
    self.original_keymaps[mode] = {}
    --- @diagnostic disable-next-line: param-type-mismatch
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      self.original_keymaps[mode][map.lhs] = map
    end
  end

  -- Watch for text changes so we can fire on_change handlers
  --- @diagnostic disable-next-line: param-type-mismatch
  self.buf_watcher = create_buf_watcher(bufnr, function(...) self:_on_bytes_after_autocmd(...) end)
  table.insert(self.cleanup_hooks, self.buf_watcher.cleanup)

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

--------------------------------------------------------------------------------
-- Instance Methods
--------------------------------------------------------------------------------

--- Render static markup to the buffer.
--- This is a "one-shot" render - no lifecycle, no state, just text + extmarks.
--- @param tree morph.Tree
function Morph:render(tree)
  -- Guard: buffer may have been deleted while render was scheduled
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end

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
  for _, mode in ipairs { 'i', 'n', 'v', 'x', 'o' } do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(self.bufnr, mode)) do
      --- @diagnostic disable-next-line: param-type-mismatch
      pcall(vim.keymap.del, mode, map.lhs, { buffer = self.bufnr })
    end
    for _, map in pairs(self.original_keymaps[mode] or {}) do
      vim.fn.mapset(map)
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
      for _, mode in ipairs { 'i', 'n', 'v', 'x', 'o' } do
        local handlers = tag.attributes[mode .. 'map']
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

  -- Update buffer text with minimal edits
  --- @diagnostic disable-next-line: assign-type-mismatch
  self.text_content.old = self.text_content.curr
  self.text_content.curr =
    { lines = lines, extmarks = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} }

  self.changing = true
  Morph.patch_lines(self.bufnr, self.text_content.old.lines, lines)
  self.changing = false
  self.changedtick = vim.b[self.bufnr].changedtick

  -- Now that text is in place, create the extmarks
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)
  for _, pending in ipairs(pending_extmarks) do
    local extmark = Extmark.new(self.bufnr, self.ns, pending.start, pending.stop, pending.opts)
    self.text_content.curr.extmark_ids_to_tag[extmark.id] = pending.tag
    self.text_content.curr.tags_to_extmark_ids[pending.tag] = extmark.id
    table.insert(self.text_content.curr.extmarks, extmark)
  end
end

--- Mount a component tree with full lifecycle management.
--- Components can have state, respond to updates, and run cleanup on unmount.
--- @param tree morph.Tree
function Morph:mount(tree)
  if vim.b[self.bufnr]._morph_mounted then
    error('Morph:mount() can only be called once per buffer', 0)
  end
  vim.b[self.bufnr]._morph_mounted = true

  -- Callbacks scheduled via ctx:do_after_render() - run after each render
  local after_render_callbacks = {} --- @type function[]

  --- @param cb function
  local function schedule_after_render(cb) table.insert(after_render_callbacks, cb) end

  -- Forward declarations for mutual recursion
  --- @diagnostic disable: unused
  local reconcile_tree, reconcile_array, reconcile_component, unmount_tree, rerender
  --- @diagnostic enable: unused

  --- Unmount a tree, calling unmount lifecycle on all components (depth-first).
  --- @param old_tree morph.Tree
  unmount_tree = function(old_tree)
    local node_type = tree_type(old_tree)

    if node_type == 'array' then
      --- @diagnostic disable-next-line: need-check-nil
      reconcile_array(old_tree --[[@as morph.Node[] ]], {})
    elseif node_type == 'tag' then
      -- Tag children can be any tree type, so recurse with reconcile_tree
      --- @diagnostic disable-next-line: need-check-nil
      reconcile_tree((old_tree --[[@as morph.Tag]]).children, nil)
    elseif node_type == 'component' then
      local tag = old_tree --[[@as morph.Tag]]
      local Component = tag.name --[[@as morph.Component]]
      local ctx = assert(tag.ctx, 'component missing context during unmount')

      -- Unmount children first (depth-first) - use reconcile_tree since
      -- prev_rendered_children can be any tree type, not just an array
      --- @diagnostic disable-next-line: need-check-nil
      reconcile_tree(ctx.prev_rendered_children, nil)

      -- Then unmount this component
      ctx.phase = 'unmount'
      Component(ctx)
      ctx.on_change = nil
      ctx._register_after_render_callback = nil
    end
    --- @diagnostic enable: need-check-nil
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
      local old_array = (old_type == 'array') and old_tree --[[@as morph.Node[]?]]
        or nil
      --- @diagnostic disable-next-line: need-check-nil
      rendered = reconcile_array(old_array, new_tree --[[@as morph.Node[] ]])
    elseif new_type == 'tag' then
      local new_tag = new_tree --[[@as morph.Tag]]
      local old_children = (old_type == new_type) and (old_tree --[[@as morph.Tag]]).children
        or nil
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

    -- Pre-compute "identity keys" for each node so we can match them up
    -- A key combines: type + component function (if any) + explicit key attribute
    --- @type table<integer, string>
    local old_keys = {}
    --- @type table<integer, string>
    local new_keys = {}
    --- @type table<morph.Tree, string>
    local node_key_cache = {}

    for i = 1, table.maxn(old_nodes) do
      local node = old_nodes[i]
      if node ~= nil then
        local key = tree_identity_key(node --[[@as morph.Node]], i)
        old_keys[i] = key
        node_key_cache[node] = key
      end
    end
    for i = 1, table.maxn(new_nodes) do
      local node = new_nodes[i]
      if node ~= nil then
        local key = tree_identity_key(node --[[@as morph.Node]], i)
        new_keys[i] = key
        node_key_cache[node] = key
      end
    end

    -- Use Levenshtein to find optimal mapping from old -> new nodes.
    -- We say no nodes are "equal" (all need reconciliation), but nodes with
    -- matching keys have lower change cost (prefer updating over mount/unmount).
    local changes = levenshtein {
      from = old_nodes,
      to = new_nodes,
      are_any_equal = false,
      cost = {
        of_change = function(_, _, old_idx, new_idx)
          return old_keys[old_idx] == new_keys[new_idx] and 1 or 2
        end,
      },
    }

    local result = {} --- @type morph.Node[]

    for _, change in ipairs(changes) do
      local rendered_node

      if change.kind == 'add' then
        -- New node: mount it
        rendered_node = reconcile_tree(nil, change.item)
      elseif change.kind == 'delete' then
        -- Removed node: unmount it
        reconcile_tree(change.item, nil)
      elseif change.kind == 'change' then
        -- Changed node: update (the type should always be the same: see invariant below)
        local from_key = node_key_cache[change.from]
        local to_key = node_key_cache[change.to]
        assert(
          from_key == to_key,
          'array reconciliation invariant: levenshtein should favor delete+add when from_key ~= to_key'
        )
        rendered_node = reconcile_tree(change.from, change.to)
      end

      if rendered_node then table.insert(result, 1, rendered_node) end
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
      ctx = old_tag.ctx
    end

    if ctx then
      ctx.phase = 'update'
    else
      ctx = Ctx.new(self.bufnr, self, new_tag.attributes, nil, new_tag.children)
    end

    -- Update context with new props/children and wire up callbacks
    ctx.props = new_tag.attributes
    ctx.children = new_tag.children
    ctx.on_change = rerender
    ctx._register_after_render_callback = schedule_after_render

    -- Render the component
    new_tag.ctx = ctx
    --- @diagnostic disable-next-line: param-type-mismatch
    local rendered_children = Component(ctx)
    local result = reconcile_tree(ctx.prev_rendered_children, rendered_children)
    ctx.prev_rendered_children = rendered_children

    -- As soon as we've mounted, move past the 'mount' state. This is
    -- because Ctx will not fire `on_update` if it is still in the
    -- 'mount' state (to avoid stack overflows).
    ctx.phase = 'update'

    return result
  end

  --- Perform a full re-render of the component tree.
  rerender = function()
    after_render_callbacks = {}

    local simplified_tree = reconcile_tree(self.component_tree.old, tree)
    self.component_tree.old = tree
    self:render(simplified_tree)

    -- Run any scheduled after-render callbacks
    for _, callback in ipairs(after_render_callbacks) do
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
      reconcile_tree(self.component_tree.old, nil)
      --- @diagnostic disable-next-line: param-type-mismatch
      vim.api.nvim_del_autocmd(unmount_autocmd_id)
    end,
  })

  -- Kick off initial render
  rerender()
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
    if pos[2] == 0 and stop[2] == 0 then
      local line = vim.api.nvim_buf_get_lines(extmark.bufnr, pos[1], pos[1] + 1, true)[1] or ''
      if #line == 0 then return true end
    end

    -- In insert mode the cursor is "thin" (between characters), so we include
    -- the position if it's <= stop (cursor can sit "on" the boundary)
    -- In normal mode the cursor is "wide" (occupies a character), so we only
    -- include if strictly < stop
    if mode == 'i' then
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

  -- Clamp the changed region to buffer bounds
  local end_row0 =
    math.min(start_row0 + new_end_row_off, vim.api.nvim_buf_line_count(self.bufnr) - 1)
  local end_col0 = start_col0 + new_end_col_off
  local last_line = vim.api.nvim_buf_get_lines(self.bufnr, -2, -1, true)[1] or ''
  if end_col0 > #last_line then end_col0 = #last_line end

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
  -- called (at lease, the ones we CAN guarantee).
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

--------------------------------------------------------------------------------
-- Exports
--------------------------------------------------------------------------------

Morph.h = h
Morph.Pos00 = Pos00

-- Export internal functions for testing when NVIM_TEST=true
--- @diagnostic disable-next-line: unnecessary-if
if vim.env.NVIM_TEST then
  Morph._is_textlock = is_textlock
  Morph._levenshtein = levenshtein
  Morph.Extmark = Extmark
end

return Morph
