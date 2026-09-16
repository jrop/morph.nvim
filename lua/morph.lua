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
-- Morph, the shapeshifter, doing what he does best.
--

-- A React-like component library for Neovim buffers.
--
-- A morph document turns a tree of tags into buffer text, then keeps that
-- text -- and its extmarks, keymaps, and undo behavior -- in sync as the tree
-- changes and as the user types. One turn of the loop, and the part of this
-- file that plays it:
--
--   describe   the app builds a tree with h()                      (Part I)
--   reconcile  the Reconciler diffs old against new                (Part III)
--   render     the tree becomes lines; patch_lines writes the
--              difference into the buffer                          (Part IV)
--   mount      the Morph instance owns the buffer, extmarks,
--              keymaps, and lifecycle                              (Part V)
--   handle     the watcher batches the user's edits; the guard
--              polices locked text and fires on_change             (Part VI)
--   undo       the probe scopes undo/redo to the editable regions  (Part VII)
--
-- The file is a book: each chapter's code only uses names already
-- introduced -- a rule Lua's `local` scoping enforces mechanically. Type
-- annotations are the exception, not a violation: they are erased comments
-- resolved from a global type registry, so Morph's field card names the
-- reconciler, the watcher, and the probe before their chapters arrive. Two
-- interludes are self-contained and skippable: the environment checks (Part II)
-- and the Levenshtein diff (Part IV). The annex holds components and hook
-- helpers built on the public API -- optional reading that doubles as
-- example code.
--
-- House rules for new code:
--   1. A chapter is contiguous: a class's declaration and its methods stay
--      in one chapter; subsystem-owned Morph methods live with their
--      subsystem's chapter (the guard's and the probe's do not sit in
--      Part V). The one exception is Morph's declaration card, which
--      rides at the top of Part III so the reconciler can name
--      Morph.ErrorBoundary.
--   2. Every banner states the chapter's role and why it sits where it does.
--   3. Interludes reference nothing outside themselves; a new dependency
--      promotes an interlude into a part.
--   4. New features declare which step of the loop they serve; anything that
--      serves none belongs in the annex.
--
-- Public API (see the exports at the end of the file): h, Pos00, Extmark,
-- RenderError, the Morph instance methods, and the Morph.ErrorBoundary /
-- Morph.Portal / Morph.FloatingWindow components.

--------------------------------------------------------------------------------
-- PART I -- THE TREE MODEL
--------------------------------------------------------------------------------
-- The data model: what a UI tree is made of, how nodes are classified and
-- matched, and h(), the one constructor user code calls. Everything later
-- operates on these structures.

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------
-- What trees are made of. Why here: every later chapter annotates its
-- parameters with these names, and nothing here runs at runtime.

-- The type hierarchy flows from abstract to concrete:
--   Tag (recipe) -> Element (instantiated tag with extmark)
--   Node -> Tree (composable structures)
--   Component (function that produces Trees)
--------------------------------------------------------------------------------

--- @alias morph.TagEventHandler fun(e: { tag: morph.Element, mode: string, lhs: string, bubble_up: boolean }): string

--- Tag attributes. The `readonly` field is 3-state: `true` locks the region,
--- `false` carves an editable hole (even under a locked ancestor), and absent
--- (nil) inherits from the enclosing region (ultimately the renderer's
--- default, set via Morph.new's `readonly` option).
--- @alias morph.TagAttributes {
---   [string]?: unknown,
---   on_change?: (fun(e: { text: string,  bubble_up: boolean }): unknown),
---   readonly?: boolean,
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
--- @field parent? morph.Tag Enclosing tag recorded at render time; the guard
---   walks it to ask "is this editable tag inside that readonly one?"
--- @field literal? boolean True on the implicit tag wrapping a bare literal
--- @field private ctx? morph.Ctx<any, any>
--- @field private curr_text? string
--- @field private readonly? boolean
--- @field private stamp? string Hex sequence id minted by the reconciler and
---   copied along matches: the node's identity chain, unique within its
---   document for the session. The reconciler writes it on the app-side node
---   (the graph its next diff sees) and mirrors it on the rendered wrapper
---   for downstream consumers; being a value, it crosses that graph boundary
---   by copying. The undo probe chains a region's history across renders by
---   matching stamps -- then requiring the stored tip to still describe the
---   region's content, so a refilled slot remints instead of inheriting
---   foreign history.

--- An element is an instantiated Tag
--- @class morph.Element : morph.Tag
--- @field extmark morph.Extmark

--- @alias morph.Node nil | boolean | string | number | morph.Tag
--- One level of array nesting: a subtree may be spliced in as a single child
--- (e.g. `{ 'label: ', ctx.children }`), which the reconciler flattens like a
--- directly written nested literal.
--- @alias morph.Tree morph.Node | (morph.Node | morph.Node[])[]
--- @alias morph.Component<TProps, TState> fun(ctx: morph.Ctx<TProps, TState>): morph.Tree

--- One changed tag: its live extmark and the tag's new (live or recovered)
--- content. The collector produces these; the guard's decide and dispatch
--- phases consume them.
--- @alias morph.TagChange { extmark: morph.Extmark, tag: morph.Tag, text: string }

--------------------------------------------------------------------------------
-- Tree Utilities
--------------------------------------------------------------------------------
-- Classify tree nodes: node type, identity keys for matching old to new,
-- and effective readonly resolution. Why here: pure functions over the
-- tree model, consumed by the reconciler (Part III), the text generator
-- (Part IV), and Morph (Part V); nothing here reaches past the tree.

--- Resolve a tag's effective readonly state. 3-state semantics: `true`
--- locks the region, `false` carves an editable hole (even under a locked
--- ancestor), nil inherits from the enclosing region (ultimately the
--- renderer's default).
--- @param tag morph.Tag
--- @param inherited boolean?
--- @return boolean?
local function resolve_readonly(tag, inherited)
  local own = tag.attributes.readonly
  if own ~= nil then return own end
  return inherited
end

--- Determine the type of a tree node.
--- @param node morph.Tree
--- @return 'nil'|'boolean'|'string'|'number'|'array'|'tag'|'component'
local function tree_type(node)
  if node == nil or node == vim.NIL then return 'nil' end
  if type(node) == 'boolean' then return 'boolean' end
  if type(node) == 'string' then return 'string' end
  if type(node) == 'number' then return 'number' end
  if type(node) == 'function' then
    -- getinfo returns nil when the function has no debug info; degrade to a
    -- placeholder name rather than crashing inside the error builder.
    local info = debug.getinfo(node, 'n')
    local name = (info and info.name) or '<anonymous>'
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

--------------------------------------------------------------------------------
-- h(): Hyperscript
--------------------------------------------------------------------------------
-- The one constructor user code calls; everything downstream consumes what
-- it produces. Why here: Part I ends with the constructor everything else
-- is built on.
--
-- Usage:
--   h('text', { hl = 'Comment' }, { 'Hello' })  -- explicit text tag
--   h.Comment({}, { 'Hello' })                  -- shorthand: h.<highlight>
--   h(MyComponent, { prop = 1 }, { ... })       -- component tag

--- @type table<string, fun(attributes?: morph.TagAttributes, children?: morph.Tree): morph.Tag> & fun(name: string | morph.Component<any, any>, attributes?: morph.TagAttributes, children?: morph.Tree): morph.Tag>
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
-- PART II -- CORE TYPES
--------------------------------------------------------------------------------
-- The runtime objects the loop manipulates: a position type, the moving
-- region markers nvim tracks for us, the per-component context, and the
-- error value a failing component becomes. First, an interlude on the two
-- environment checks these objects and the later machinery depend on.

--------------------------------------------------------------------------------
-- Interlude: Environment Checks
--------------------------------------------------------------------------------
-- Two environment checks that answer "may I act right now?". Self-contained
-- and skippable: neither references anything else in this file. Why here,
-- and not later: Ctx:update (below) consults the first, and every
-- buffer-writing chapter consults the second.
--
-- Textlock: Neovim forbids buffer/window changes during certain operations
-- (autocmd callbacks among them); is_textlock() detects that state so
-- updates can be scheduled for later instead of erroring.
--
-- Readiness: during startup (before VimEnter) a file buffer may have its
-- filename set but its content not loaded yet; rendering into such a buffer
-- prepends content instead of replacing it. is_buffer_api_ready() gates
-- render and mount on that.

--- A lazily-created unlisted scratch buffer used to probe for textlock.
--- We reuse a single buffer to avoid creating/destroying buffers on every check.
--- @type integer?
local textlock_probe_buf = nil

--- Check if we're currently in a textlock (can't modify buffers).
--- Uses nvim_buf_set_lines on a hidden probe buffer.
--- @return boolean
local function is_textlock()
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
-- Pos00: Zero-Based Buffer Positions
--------------------------------------------------------------------------------
-- One position type for the whole file: nvim's API mixes 0-based and
-- 1-based indexing, and every comparison would otherwise restate that
-- accident. Why here: Extmark, the printer, the guard, and the probe all
-- compare positions.

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
function Pos00:__le(other)
  if type(other) ~= 'table' then return false end
  if self[1] ~= other[1] then return self[1] < other[1] end
  return self[2] <= other[2]
end

--------------------------------------------------------------------------------
-- Extmark: Wrapper Around Neovim's Extmark API
--------------------------------------------------------------------------------
-- Extmarks are the moving bookmarks nvim keeps for us: regions of text that
-- travel as the buffer is edited. This wrapper normalizes their quirks --
-- inverted or past-EOF bounds, newline-only spans, getregion's 1-based
-- positions. Why here: the printer places them, the guard reads them, and
-- the probe's writebacks re-place them.

--- @class morph.Extmark
--- @field id integer
--- @field start morph.Pos00
--- @field stop morph.Pos00
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
--- @param opts? vim.api.keyset.set_extmark
--- @return morph.Extmark
function Extmark.new(bufnr, ns, start, stop, opts)
  local extmark_opts = {
    end_row = stop[1],
    end_col = stop[2],
    right_gravity = false,
    end_right_gravity = true,
  }
  if opts then
    for k, v in next, opts do
      -- Caller opts may override any keyset field; the dynamic key defeats
      -- per-field checking, so the value is trusted as-is.
      extmark_opts[k] = v --[[@as any]]
    end
  end

  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start[1], start[2], extmark_opts)
  return setmetatable({ id = id, start = start, stop = stop, bufnr = bufnr }, Extmark)
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
  return Extmark._from_raw(bufnr, id, start_row0, start_col0, assert(details))
end

--- @private
--- @param bufnr integer
--- @param id integer
--- @param start_row0 integer
--- @param start_col0 integer
--- @param details vim.api.keyset.extmark_details? Present when the source API
---   call requested details; the body treats absent details as "no known end".
--- Construct an Extmark from raw API data, normalizing bounds that extend past buffer end.
function Extmark._from_raw(bufnr, id, start_row0, start_col0, details)
  local start = Pos00.new(start_row0, start_col0)
  local stop = Pos00.new(start_row0, start_col0)

  if details and details.end_row ~= nil and details.end_col ~= nil then
    stop = Pos00.new(details.end_row --[[@as integer]], details.end_col --[[@as integer]])
  end

  local extmark = setmetatable({ id = id, start = start, stop = stop, bufnr = bufnr }, Extmark)

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
      return Extmark._from_raw(bufnr, id, line0, col0, assert(details))
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
    -- Extmark covers exactly one newline. Return early to avoid the
    -- adjusted stop == start producing inverted same-line positions
    -- that confuse getregion into leaking the preceding character.
    if start == stop then return '\n' end
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
--------------------------------------------------------------------------------
-- Every component receives a Ctx: props (immutable input), state (owned by
-- the component), phase ('mount'|'update'|'unmount'), update(newState) and
-- refresh() to trigger re-renders, and do_after_render(fn) to schedule work.
-- Why here: the reconciler constructs and drives it next.

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
  local render_error = self.state.error --[[@as morph.RenderError]]
  --- @diagnostic enable: need-check-nil
  local name_part = render_error.component_name ~= ''
      and (' in ' .. render_error.component_name .. '@' .. render_error.phase)
    or ''
  return {
    h('text', { hl = 'ErrorMsg' }, 'Error' .. name_part),
    '\n',
    h('text', { hl = 'Comment' }, render_error.message),
  }
end

--------------------------------------------------------------------------------
-- RenderError
--------------------------------------------------------------------------------
-- The value a failing component's error becomes: message, component, phase,
-- and the ancestor trace. Why here: the reconciler throws it and the error
-- boundary renders it.

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
-- PART III -- RECONCILIATION
--------------------------------------------------------------------------------
-- The Reconciler owns everything a single Morph:mount() tracks across
-- renders: the mounted tree, the last reconciled tree, the render trace,
-- the after-render callback queue, and the debounce timer. Morph owns
-- buffers, extmarks, and keymaps; the Reconciler owns components and their
-- lifecycle. The split is visible at their one meeting point:
-- Reconciler:rerender() calls Morph:render() with a simplified tree.

-- Morph's declaration rides at the top of this part because the
-- reconciler must name it: reconcile_component gives Morph.ErrorBoundary
-- descendants their catch-and-fallback treatment -- the one deliberate
-- forward reference in code, since the field itself is assigned in the
-- annex. Morph's behavior is built in Part V.

--- @alias morph.MorphTextState {
---   lines: string[],
---   tags_to_extmark_ids: table<morph.Tag, integer?>,
---   extmark_ids_to_tag: table<integer, morph.Tag?>,
---   top_level_tag?: morph.Tag,
--- }

--- Read a buffer's undo tree. `undotree()` reports on the current buffer, so
--- hidden buffers need the `nvim_buf_call` hop. Shared by the guard (whose
--- mirror signal is the main tree's sequence number) and the probe (whose
--- own tree drives traversal).
--- @param bufnr integer
--- @return vim.fn.undotree.ret
local function undotree(bufnr)
  local tree --- @type vim.fn.undotree.ret
  vim.api.nvim_buf_call(bufnr, function() tree = vim.fn.undotree() end)
  return tree
end

--- @class morph.Morph
--- @field private bufnr integer
--- @field private ns integer
--- @field private changedtick integer
--- @field private changing boolean
--- @field private textlock boolean
--- @field private debounce_ms? integer
--- @field private original_keymaps table<string, table<string, any>>
--- @field private text_content { old: morph.MorphTextState, curr: morph.MorphTextState }
--- @field private cleanup_hooks function[]
--- @field private buf_watcher morph.BufWatcher? -- Created lazily
--- @field private reconciler? morph.Reconciler -- mount-scoped reconciliation, set by mount()
--- @field private readonly_default? boolean -- renderer-level readonly default (nil = unlocked)
--- @field private last_tree? morph.Tree -- last tree passed to :render (static revert source)
--- @field private probe? morph.Probe -- hidden region-text buffer owning region undo/redo
--- @field private _probe_cmdline_autocmd? integer -- CmdlineLeave handler id for ex-command interception
local Morph = {}
Morph.__index = Morph

--------------------------------------------------------------------------------
-- The Reconciler
--------------------------------------------------------------------------------
-- Walks old and new trees together, mounting, updating, and unmounting
-- components. Why here: it sits between the tree model (Part I) and text
-- generation (Part IV); its output is what render draws.

--- @class morph.Reconciler
--- @field document morph.Morph The renderer instance this mount renders into
--- @field tree morph.Tree The root tree passed to mount; rerenders re-reconcile against it
--- @field old_tree morph.Tree? The last tree this mount reconciled (nil until the first render)
--- @field trace morph.Ctx<any, any>[] Component ancestry stack, feeding RenderError traces
--- @field after_render_callbacks function[] Queued ctx:do_after_render callbacks
--- @field debounce_ms integer Resolved debounce for this mount (0 = synchronous)
--- @field debounce_timer table? Pending maxWait debounce timer
--- @field last_invoke_time integer? uv.now() of the last render; nil until the initial render lands
--- @field teardown_done boolean Idempotence guard: buffer deletion and explicit unmount can both tear down
--- @field mounted boolean True while mounted; stale rerenders no-op after unmount
--- @field unmount_autocmd_id integer? BufDelete/BufUnload/BufWipeout autocmd that tears the mount down
--- @field private stamp_seq integer Counter for minted region stamps (hex sequence ids)
local Reconciler = {}
Reconciler.__index = Reconciler

--- Create a reconciler for one mount. Installs the buffer-deletion autocmd but
--- does not render; call start() for that.
--- @param document morph.Morph
--- @param tree morph.Tree
--- @param opts { debounce_ms: integer }
--- @return morph.Reconciler
function Reconciler.new(document, tree, opts)
  local self = setmetatable({
    document = document,
    tree = tree,
    old_tree = nil,
    trace = {},
    after_render_callbacks = {},
    debounce_ms = opts.debounce_ms or 0,
    debounce_timer = nil,
    last_invoke_time = nil,
    teardown_done = false,
    mounted = false,
    stamp_seq = 0,
  }, Reconciler)

  -- Don't track this autocmd in cleanup_hooks, because the prior
  -- BufDelete/BufUnload/BufWipeout will take priority, and will delete this
  -- autocmd before it even has a chance to run:
  self.unmount_autocmd_id = vim.api.nvim_create_autocmd(
    { 'BufDelete', 'BufUnload', 'BufWipeout' },
    { buffer = document.bufnr, callback = function() self:teardown() end }
  )

  return self
end

--- Mount the tree: mark mounted, render synchronously (the debounce wrapper
--- passes through while last_invoke_time is still nil), and record the render
--- time for the debounce maxWait logic.
--- Mint a region stamp: a fixed-width hex sequence id, unique within this
--- document for the session. A counter, not a content hash, because the stamp
--- must be render-invariant for matched nodes -- hashing content or position
--- breaks on exactly the reorders identity exists to support.
--- @return string
function Reconciler:_mint_stamp()
  self.stamp_seq = self.stamp_seq + 1
  return ('%016x'):format(self.stamp_seq)
end

function Reconciler:start()
  self.mounted = true
  self:schedule_rerender()
  -- Must be set AFTER the initial render to allow the pass-through guard.
  self.last_invoke_time = vim.uv.now()
end

--- Collect the ancestor component names currently on the trace, for
--- RenderError. The failing component itself is popped by the caller first.
--- @return string[]
function Reconciler:_trace_names()
  local names = {} --- @type string[]
  for _, c in ipairs(self.trace) do
    table.insert(names, c.name)
  end
  return names
end

--- Queue a callback for the after-render drain.
--- @param cb function
function Reconciler:_schedule_after_render(cb) table.insert(self.after_render_callbacks, cb) end

--- Run all queued after-render callbacks, then clear the queue.
--- Called at the end of each rerender and after a terminal unmount (buffer
--- deletion), so callbacks registered during an unmount phase still execute.
--- The queue is cleared before running so a callback that triggers a nested
--- rerender (via ctx:update during the update phase) sees a fresh queue.
function Reconciler:_run_after_render_callbacks()
  local callbacks = self.after_render_callbacks
  self.after_render_callbacks = {}
  for _, callback in ipairs(callbacks) do
    callback()
  end
end

--- Unmount a tree, calling unmount lifecycle on all components (depth-first).
--- @param old_tree morph.Tree
function Reconciler:_unmount_tree(old_tree)
  local node_type = tree_type(old_tree)

  if node_type == 'array' then
    local arr = old_tree --[[@as morph.Node[] ]]
    for i = 1, table.maxn(arr) do
      local child = arr[i]
      if child ~= nil then self:_unmount_tree(child) end
    end
  elseif node_type == 'tag' then
    -- Tag children can be any tree type, so recurse with _unmount_tree
    --- @diagnostic disable-next-line: need-check-nil
    self:_unmount_tree((old_tree --[[@as morph.Tag]]).children)
  elseif node_type == 'component' then
    local tag = old_tree --[[@as morph.Tag]]
    local Component = tag.name --[[@as morph.Component<any, any>]]

    -- Skip if already unmounted (prevents double-unmount on old_tree not
    -- being updated due to a prior unmount error during reconciliation)
    if not tag.ctx then return end
    local ctx = tag.ctx

    -- Unmount children first (depth-first)
    --- @diagnostic disable-next-line: need-check-nil
    self:_unmount_tree(ctx.prev_rendered_children)

    -- Then unmount this component
    ctx.phase = 'unmount'
    local ok, err = pcall(Component, ctx)
    ctx.on_change = nil
    ctx._register_after_render_callback = nil
    tag.ctx = nil
    if not ok then
      error(RenderError.new(tostring(err), ctx.name, 'unmount', self:_trace_names()), 0)
    end
  end
end

--- Reconcile old and new trees, handling mount/update/unmount.
--- Returns the rendered (simplified) tree.
--- @param old_tree morph.Tree
--- @param new_tree morph.Tree
--- @return morph.Tree
function Reconciler:reconcile(old_tree, new_tree)
  local old_type = tree_type(old_tree)
  local new_type = tree_type(new_tree)

  -- If type changed, unmount old tree first
  if old_type ~= new_type then self:_unmount_tree(old_tree) end

  -- Handle each node type
  local rendered

  if new_type == 'nil' or new_type == 'boolean' then
    rendered = new_tree
  elseif new_type == 'string' or new_type == 'number' then
    rendered = new_tree
  elseif new_type == 'array' then
    local old_array = (old_type == 'array') and old_tree --[[@as morph.Node[]?]] or nil
    --- @diagnostic disable-next-line: need-check-nil
    rendered = self:reconcile_array(old_array, new_tree --[[@as morph.Node[] ]])
  elseif new_type == 'tag' then
    local new_tag = new_tree --[[@as morph.Tag]]
    local old_children = (old_type == new_type) and (old_tree --[[@as morph.Tag]]).children or nil
    --- @diagnostic disable-next-line: need-check-nil
    rendered = h(new_tag.name, new_tag.attributes, self:reconcile(old_children, new_tag.children))
    -- Identity travels as a VALUE: a hex sequence id minted on mount and
    -- copied along matches. It lives on the app-side node because that is
    -- the graph the next diff sees; the wrapper mirrors it for the probe.
    local stamp = (old_type == 'tag') and old_tree.stamp or nil
    if not stamp then stamp = self:_mint_stamp() end
    new_tag.stamp = stamp
    --- @diagnostic disable-next-line: need-check-nil
    rendered.stamp = stamp
  elseif new_type == 'component' then
    --- @diagnostic disable-next-line: need-check-nil
    rendered = self:reconcile_component(old_tree, new_tree --[[@as morph.Tag]])
  end

  return rendered
end

--- Reconcile arrays of nodes using Levenshtein to match up old/new nodes.
--- This is where the "diffing" magic happens for lists.
--- @param old_nodes morph.Node[]?
--- @param new_nodes morph.Node[]?
--- @return morph.Node[]
function Reconciler:reconcile_array(old_nodes, new_nodes)
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

      if old_node then
        -- Key match: update existing node
        table.insert(result, self:reconcile(old_node, new_node))
        old_by_key[key] = nil -- Mark as used
      else
        -- No key match: mount new node
        table.insert(result, self:reconcile(nil, new_node))
      end
    end
  end

  -- Unmount any old nodes that weren't reused
  for _, old_node in pairs(old_by_key) do
    self:reconcile(old_node, nil)
  end

  return result
end

--- Reconcile a component node (mount, update, or reuse existing context).
--- @param old_tree morph.Tree
--- @param new_tag morph.Tag
function Reconciler:reconcile_component(old_tree, new_tag)
  local Component = new_tag.name --[[@as morph.Component<any, any>]]

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
      self:_unmount_tree(old_tree)
    end
  end

  if ctx then
    ctx.phase = 'update'
  else
    ctx = Ctx.new(self.document.bufnr, self.document, new_tag.attributes, nil, new_tag.children)
  end

  -- Set name before calling Component so ctx.name is populated if it throws.
  -- Components that self-name (ctx.name = 'X') will override this; on update the
  -- guard skips since the name was already set during mount.
  --- @diagnostic disable-next-line: need-check-nil
  if ctx.name == '' then ctx.name = debug.getinfo(Component, 'n').name or '<anonymous>' end

  -- Update context with new props/children and wire up callbacks. The closures
  -- are stable for the mount's lifetime, so they can be captured before the
  -- debounced schedule path even exists.
  ctx.props = new_tag.attributes
  ctx.children = new_tag.children
  ctx.on_change = function() self:schedule_rerender() end
  ctx._register_after_render_callback = function(cb) self:_schedule_after_render(cb) end

  -- Render the component
  new_tag.ctx = ctx
  table.insert(self.trace, ctx)
  --- @diagnostic disable-next-line: param-type-mismatch
  local ok, rendered_children = pcall(Component, ctx)
  if not ok then
    table.remove(self.trace)
    error(RenderError.new(tostring(rendered_children), ctx.name, ctx.phase, self:_trace_names()), 0)
  end

  -- ErrorBoundary: catch descendant render errors, show fallback instead of crashing
  local result
  if Component == Morph.ErrorBoundary then
    local ok, res = pcall(self.reconcile, self, ctx.prev_rendered_children, rendered_children)
    if not ok then
      --- @diagnostic disable: need-check-nil
      ctx.state.has_error = true
      local is_render_error = getmetatable(res) == RenderError
      -- The short-circuits below only read RenderError fields after the
      -- metatable check proved the shape; the cast records that for the
      -- analyzer, which cannot narrow through getmetatable.
      local render_error = res --[[@as morph.RenderError]]
      ctx.state.error = {
        message = is_render_error and render_error.message or tostring(res),
        component_name = is_render_error and render_error.component_name or '',
        phase = is_render_error and render_error.phase or '',
        render_trace = is_render_error and render_error.render_trace or self:_trace_names(),
      }
      rendered_children = ctx:build_error_fallback()
      result = self:reconcile(ctx.prev_rendered_children, rendered_children)
      --- @diagnostic enable: need-check-nil
    else
      result = res
    end
  else
    result = self:reconcile(ctx.prev_rendered_children, rendered_children)
  end

  ctx.prev_rendered_children = rendered_children
  table.remove(self.trace)

  -- As soon as we've mounted, move past the 'mount' state. This is
  -- because Ctx will not fire `on_update` if it is still in the
  -- 'mount' state (to avoid stack overflows).
  ctx.phase = 'update'

  return result
end

--- Perform a full re-render of the component tree.
function Reconciler:rerender()
  -- Stale rerenders (e.g. a vim.schedule'd on_change from before an unmount)
  -- are dropped once the document is no longer mounted.
  if not self.mounted then return end
  local simplified_tree = self:reconcile(self.old_tree, self.tree)
  self.old_tree = self.tree
  self.document:render(simplified_tree)

  self:_run_after_render_callbacks()
end

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
function Reconciler:schedule_rerender()
  -- Pass-through: initial mount render runs synchronously.
  -- last_invoke_time is nil until set after the initial rerender() call.
  if self.last_invoke_time == nil then
    self:rerender()
    return
  end

  -- A zero debounce renders synchronously; only positive values rate-limit.
  if self.debounce_ms <= 0 then
    self:rerender()
    return
  end

  if self.debounce_timer and self.debounce_timer:is_active() then return end

  local now = vim.uv.now()
  local ms_since_last_invoke = math.max(0, now - self.last_invoke_time)
  local delay
  if ms_since_last_invoke >= self.debounce_ms then
    delay = self.debounce_ms
  else
    delay = self.debounce_ms - ms_since_last_invoke
  end

  self.debounce_timer = vim.defer_fn(function()
    self.debounce_timer = nil
    self.last_invoke_time = vim.uv.now()
    self:rerender()
  end, delay)
end

--- Terminal teardown: fires all unmount phases and frees every resource
--- attached to this mount. Shared by the unmount autocmd (buffer deletion)
--- and the public Morph:unmount(). Leaves buffer content as-is; callers that
--- want a blank buffer clear it themselves. Idempotent: a buffer deletion may
--- unmount the document via its autocmd, and a later explicit unmount (e.g.
--- a Portal releasing its inner document after the portal buffer is gone)
--- must be a no-op.
function Reconciler:teardown()
  if self.teardown_done then return end
  self.teardown_done = true
  self.mounted = false

  if vim.api.nvim_buf_is_valid(self.document.bufnr) then
    vim.b[self.document.bufnr]._morph_mounted = nil
  end

  if self.debounce_timer then
    self.debounce_timer:stop()
    self.debounce_timer:close()
    self.debounce_timer = nil
  end

  self:reconcile(self.old_tree, nil)
  -- Drain after-render callbacks registered during the unmount phase (no
  -- rerender follows to drain them).
  self:_run_after_render_callbacks()

  -- Remove the unmount autocmd, then hand the buffer-side resources (cleanup
  -- hooks, keymaps, namespace, watcher, probe, diff state) back to Morph.
  --- @diagnostic disable-next-line: param-type-mismatch
  vim.api.nvim_del_autocmd(self.unmount_autocmd_id)
  self.document:_release_mount_resources()
  self.old_tree = nil
end

--------------------------------------------------------------------------------
-- PART IV -- TEXT GENERATION
--------------------------------------------------------------------------------
-- From reconciled tree to buffer bytes: the diff algorithm, the generator
-- that flattens a tree into lines while caching each tag's text and span for
-- the guard, and the patcher that writes the difference with minimal edits.

--------------------------------------------------------------------------------
-- Interlude: The Levenshtein Diff
--------------------------------------------------------------------------------
-- The minimal edit sequence between two lists. Self-contained and
-- skippable. Why here, with the text generator: patch_lines is its only
-- consumer (lines, then characters within a changed line); reconciliation
-- matches components by identity key instead, so the reconciler does not
-- need it.

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
  local changes = {} --- @type morph.LevenshteinChange<any>[]
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
-- From Tree to Lines
--------------------------------------------------------------------------------
-- markup_to_lines flattens a tree into buffer lines, caching every tag's
-- text (curr_text) along the way -- the snapshot the guard later decides
-- with. Why here: the reconciler has decided WHAT to draw; this decides how
-- it reads, and Part V writes it.

--- Convert a tree to an array of lines, optionally calling on_tag for each tag.
--- This is the core "rendering" logic that flattens the tree into text.
--- @param opts { tree: morph.Tree, readonly_default?: boolean, on_tag?: fun(tag: morph.Tag, start0: morph.Pos00, stop0: morph.Pos00): any }
--- @return string[]
function Morph.markup_to_lines(opts)
  local lines = {} --- @type string[]
  local line_buffers = {} --- @type string[][]
  local curr_line1, curr_col1 = 1, 1 -- 1-based position tracking

  -- Stack of text accumulators - each tag tracks its own text content
  -- so we can cache it for on_change handlers later
  local text_accumulators = {} --- @type { text: string[] }[]

  -- Stack of tags currently being rendered. A tag records its enclosing tag
  -- as `parent`, so the guard can later ask whether a changed editable tag
  -- sits inside a changed readonly one (content question, no positions).
  local tag_stack = {} --- @type morph.Tag[]

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
  --- @param parent_readonly? boolean
  local function visit(node, parent_readonly)
    local node_type = tree_type(node)

    if node_type == 'string' then
      -- A string with no enclosing tag (top-level in the render tree, or
      -- directly inside a component's output) would otherwise produce no
      -- extmark and be invisible to the readonly sweep. Wrap it in an
      -- implicit text tag so locked defaults cover ALL content. The wrap also
      -- applies under a READONLY parent, where the guard must see the region's
      -- OWN text change even when an editable hole inside it also changed (a
      -- write spanning the hole's edge). Under an editable parent the literal
      -- belongs to the surrounding region and needs no tag of its own --
      -- wrapping there would mint spurious editable regions.
      local wrap = #text_accumulators == 0 or parent_readonly
      local enclosing = tag_stack[#tag_stack]
      if wrap and not (enclosing and enclosing.literal) then
        local lit = Morph.h('text', {}, node)
        lit.literal = true
        return visit(lit, parent_readonly)
      end
      -- Split on newlines and emit each part. The fast path matters: trees
      -- like big tables emit one single-line string per cell, and vim.split
      -- spins up a gsplit closure plus segment bookkeeping for every one of
      -- them. A plain find skips all of that when there is nothing to split.
      local s = node --[[@as string]]
      if not s:find('\n', 1, true) then
        emit_text(s)
      else
        local parts = vim.split(s, '\n')
        for i, part in ipairs(parts) do
          if i > 1 then emit_newline() end
          emit_text(part)
        end
      end
    elseif node_type == 'number' then
      -- Convert number to string and emit; same implicit-tag treatment as
      -- strings so top-level numbers and readonly-parent literals are guarded
      local text = tostring(node --[[@as number]])
      local wrap = #text_accumulators == 0 or parent_readonly
      local enclosing = tag_stack[#tag_stack]
      if wrap and not (enclosing and enclosing.literal) then
        local lit = Morph.h('text', {}, text)
        lit.literal = true
        return visit(lit, parent_readonly)
      end
      emit_text(text)
    elseif node_type == 'array' then
      for i = 1, table.maxn(node) do
        local child = node[i]
        if child ~= nil then visit(child, parent_readonly) end
      end
    elseif node_type == 'tag' then
      local tag = node --[[@as morph.Tag]]
      table.insert(text_accumulators, { text = {} })

      -- A readonly tag locks its entire subtree: every element inside
      -- inherits the flag, so the guard reverts edits anywhere in the locked
      -- region. 3-state: an explicit `readonly = false` carves an editable
      -- hole even under a locked ancestor.
      tag.readonly = resolve_readonly(tag, parent_readonly)

      tag.parent = tag_stack[#tag_stack]
      tag_stack[#tag_stack + 1] = tag

      local start0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)
      visit(tag.children, tag.readonly)
      local stop0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)

      tag_stack[#tag_stack] = nil

      -- Cache the rendered text on the tag: the guard decides what changed
      -- by comparing live content against this expectation.
      local acc = table.remove(text_accumulators)
      tag.curr_text = table.concat(acc.text)

      if opts.on_tag then opts.on_tag(tag, start0, stop0) end
    elseif node_type == 'component' then
      local tag = node --[[@as morph.Tag]]
      local Component = tag.name --[[@as morph.Component<any, any>]]
      local ctx = Ctx.new(nil, nil, tag.attributes, nil, tag.children)

      local start0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)
      -- A component tag's own readonly attribute gates its output tree; tags
      -- inside the component can still override with their own attribute.
      local component_readonly = resolve_readonly(tag, parent_readonly)
      visit(Component(ctx), component_readonly)
      local stop0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)

      -- Immediately unmount (this is stateless rendering)
      ctx.phase = 'unmount'
      Component(ctx)

      if opts.on_tag then opts.on_tag(tag, start0, stop0) end
    end
    -- nil/boolean nodes produce no output
  end

  visit(opts.tree, opts.readonly_default)

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

--------------------------------------------------------------------------------
-- Writing the Difference
--------------------------------------------------------------------------------
-- patch_lines applies old_lines -> new_lines with minimal buffer edits:
-- a whole-buffer replace when a large buffer changed too much, otherwise a
-- trimmed-context Levenshtein on lines and characters. Why here: render
-- calls it after every flatten, which keeps the write path in one chapter.

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
-- PART V -- THE MORPH INSTANCE
--------------------------------------------------------------------------------
-- The Morph instance: one per buffer, owning its text, extmarks, keymaps,
-- and undo interception. It provides render(tree) for static markup,
-- mount(tree) for component lifecycle, get_elements_at(pos) and
-- get_element_by_id(id) for queries, and keypress dispatch to element
-- handlers. Its declaration rides at the top of Part III (the reconciler
-- names Morph.ErrorBoundary); all of its behavior lives here, in
-- dependency order: constructor, render, mount/unmount, queries, dispatch.

--------------------------------------------------------------------------------
-- Shared Helpers
--------------------------------------------------------------------------------
-- Keymap constants and the two helpers Morph's methods share: the
-- innermost-first element sort (shared with the guard in Part VI), and
-- buffer-keymap restore. Why here: the methods below all use them.

-- Pre-computed keymap mode tables and attribute names.
-- Avoids allocating `{ 'i', 'n', 'v', 'x', 'o' }` and concatenating
-- `mode .. 'map'` on every on_tag callback invocation.
local KEYMAP_MODES = { 'i', 'n', 'v', 'x', 'o' }
local KEYMAP_ATTRS = { 'imap', 'nmap', 'vmap', 'xmap', 'omap' }

--- Sort element records (tables with an `extmark` field) innermost first:
--- smallest span before larger containing spans; ties broken by extmark id.
--- Shared by get_elements_at and the change guard's on_change fire order.
--- @param list { extmark: morph.Extmark }[]
local function sort_innermost_first(list)
  table.sort(list, function(a, b)
    local ea, eb = a.extmark, b.extmark
    if ea.start == eb.start and ea.stop == eb.stop then return ea.id < eb.id end
    return ea.start >= eb.start and ea.stop <= eb.stop
  end)
end

--- @private
--- Clear all buffer-local keymaps, then restore the pre-morph snapshot.
--- Shared by render (before each pass) and terminal teardown (unmount), so a
--- live buffer is never left with stale morph-installed keymap handlers.
--- @param self morph.Morph
local function restore_buffer_keymaps(self)
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
end

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------
-- Morph.new binds the instance to a buffer: namespace, keymap snapshot, the
-- diff-state shell, and the buffer-deletion cleanup. Why here: the object's
-- declaration rode along in Part III; its life starts here.

--- Create a new Morph instance bound to a buffer.
--- @param bufnr integer? Buffer number (nil or 0 means current buffer)
--- @param opts? table  Fields: `readonly` (boolean): every tag without an
---   explicit readonly attribute is locked by default (tags can carve editable
---   holes with readonly = false). Undo/redo is region-aware whenever a render
---   locks anything: traversal keys and commands are routed through a hidden
---   probe buffer so they govern only the editable regions, and app chrome
---   renders stay independent of history.
--- @return morph.Morph
function Morph.new(bufnr, opts)
  local init_opts = opts or {}
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr

  -- Each buffer gets its own namespace for extmarks
  if vim.b[bufnr]._renderer_ns == nil then
    vim.b[bufnr]._renderer_ns = vim.api.nvim_create_namespace('morph:' .. tostring(bufnr))
  end

  local self = setmetatable({
    bufnr = bufnr,
    ns = vim.b[bufnr]._renderer_ns,
    -- Renderer-level readonly default: when true, every tag without an
    -- explicit readonly attribute is locked (readonly = false carves holes).
    readonly_default = init_opts.readonly,
    changedtick = 0,
    changing = false,
    textlock = false,
    probe = nil,
    _probe_cmdline_autocmd = nil,
    original_keymaps = {},
    text_content = {
      old = { lines = { '' }, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
      curr = { lines = { '' }, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
    },
    cleanup_hooks = {},
    buf_watcher = nil, -- Created lazily in _ensure_buf_watcher()
    reconciler = nil, -- Created by mount()
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
      -- Delete the probe buffer too: it is per-instance state, and a
      -- render-only instance has no mount teardown to do it.
      self:_teardown_probe()
      for _, cleanup in ipairs(self.cleanup_hooks) do
        cleanup()
      end
    end,
  })
  table.insert(self.cleanup_hooks, function() vim.api.nvim_del_autocmd(cleanup_autocmd) end)

  return self
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------
-- One pass: flatten the tree, patch the delta, place extmarks under the
-- seam-gravity rules, refresh probe bookkeeping, and reinstall keymaps.
-- Why here: it is the loop's render step; mount and unmount below are its
-- lifecycle wrapper.

--- Render static markup to the buffer.
--- This is a "one-shot" render - no lifecycle, no state, just text + extmarks.
--- @param tree morph.Tree
function Morph:render(tree)
  self.last_tree = tree
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

  -- Detect if the buffer changed externally since our last render, and resync
  -- the diff base from the buffer's real lines when it did.
  local changedtick = vim.b[self.bufnr].changedtick
  if changedtick ~= self.changedtick then
    self.text_content.curr = {
      lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false),
      tags_to_extmark_ids = {},
      extmark_ids_to_tag = {},
    }
    self.changedtick = changedtick
  end

  -- We need to collect extmarks during tree traversal, but can't create them
  -- until after the buffer text is updated (extmarks need valid positions)
  local pending_extmarks = {} --- @type { tag: morph.Tag, start: morph.Pos00, stop: morph.Pos00, opts: any }[]
  -- Every resolved-editable tag, in render order: the probe's regions.
  local probe_regions = {} --- @type morph.Tag[]

  -- Clear all buffer-local keymaps, then restore originals
  restore_buffer_keymaps(self)

  -- Traverse the tree, collecting text lines and extmark info
  local lines = Morph.markup_to_lines {
    tree = tree,
    readonly_default = self.readonly_default,
    on_tag = function(tag, start, stop)
      if tag.name ~= 'text' then return end

      -- Every resolved-editable tag is an undo region, decided purely by the
      -- resolved readonly. Undo entries snapshot the whole region set, so a
      -- nested editable tag neither splits undo steps nor disagrees with the
      -- region that embeds it on replay.
      if not tag.readonly then table.insert(probe_regions, tag) end

      -- Convert hl attribute to extmark highlight
      if type(tag.attributes.hl) == 'string' then
        tag.attributes.extmark = tag.attributes.extmark or {}
        tag.attributes.extmark.hl_group = tag.attributes.extmark.hl_group or tag.attributes.hl
      end

      local extmark_opts = tag.attributes.extmark or {}
      if tag.readonly then
        -- Locked spans reject boundary inserts: a typed character at a locked
        -- span's edge must land OUTSIDE the lock (in an adjacent hole), not
        -- inside the locked text. Inverted gravity does that: the start mark
        -- yields forward, the end mark holds.
        extmark_opts = vim.tbl_extend('force', extmark_opts, {
          right_gravity = true,
          end_right_gravity = false,
        })
      end

      table.insert(pending_extmarks, {
        tag = tag,
        start = start,
        stop = stop,
        opts = extmark_opts,
      })

      -- Register keymaps for any mode handlers (nmap, imap, vmap, xmap, omap)
      for i = 1, 5 do
        -- The loop index hides which of the five keymap attributes is being
        -- read, so field tracking cannot prove the key exists.
        --- @diagnostic disable-next-line: undefined-field
        local handlers = tag.attributes[KEYMAP_ATTRS[i]]
        local mode = KEYMAP_MODES[i] --[[@as string]]
        for lhs, _ in pairs(handlers or {}) do
          vim.keymap.set(mode, lhs, function()
            local result = self:_dispatch_keypress(mode, lhs)

            -- Empty string means "swallow this keypress". In insert mode that's
            -- easy, but in normal mode we need a trick: use g@ with a no-op
            -- operator function.
            if result == '' and mode ~= 'i' then
              function _G.MorphOpFuncNoop() end
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
  self.text_content.curr = { lines = lines, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} }

  -- Clear extmarks BEFORE patching to avoid Neovim's auto-deletion overhead
  -- when lines with extmarks are deleted by patch_lines
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)

  self.changing = true
  Morph.patch_lines(self.bufnr, self.text_content.old.lines, lines)
  self.changing = false
  self.changedtick = vim.b[self.bufnr].changedtick

  -- Boundary gravity: at the seam between two adjacent editable spans, a
  -- keystroke must land in exactly ONE of them. An editable span's start
  -- yields forward when another editable span ends exactly there, so a
  -- keystroke at the seam joins the span to the left instead of being claimed
  -- by both (the guard's attribution below settles leftovers). Zero-width
  -- spans never yield their start: typing at an empty hole's position must
  -- enter the hole.
  --
  -- Ends: Extmark.new's yielding default (end_right_gravity=true) makes a
  -- span's end ride over inserted text -- right for typing at a span's own
  -- tail, but wrong when a ZERO-WIDTH editable span starts at the same
  -- position: the hole's start never yields, so its bytes must go only to
  -- the hole, and a left span whose end also rode over them would grow its
  -- live span across the hole's text (the guard accepts the overlap, but the
  -- undo probe then writes the left region's snapshot over the inflated span
  -- and erases the hole's bytes). So an editable span's end holds when a
  -- zero-width editable span starts exactly there. Non-zero-width starts are
  -- excluded: they yield (rule above), so the left end's ride is what claims
  -- the seam bytes for the span to the left.
  local editable_stop_keys = {}
  local editable_zero_start_keys = {}
  for _, pending in ipairs(pending_extmarks) do
    if not pending.tag.readonly then
      editable_stop_keys[('%d:%d'):format(pending.stop[1], pending.stop[2])] = true
      if pending.start[1] == pending.stop[1] and pending.start[2] == pending.stop[2] then
        editable_zero_start_keys[('%d:%d'):format(pending.start[1], pending.start[2])] = true
      end
    end
  end
  for _, pending in ipairs(pending_extmarks) do
    local zero_width = pending.start[1] == pending.stop[1] and pending.start[2] == pending.stop[2]
    if
      not pending.tag.readonly
      and not zero_width
      and editable_stop_keys[('%d:%d'):format(pending.start[1], pending.start[2])]
    then
      pending.opts = vim.tbl_extend('force', pending.opts, { right_gravity = true })
    end
    if
      not pending.tag.readonly
      and not zero_width -- a zero-width span's stop is its own start, not a neighbor's
      and editable_zero_start_keys[('%d:%d'):format(pending.stop[1], pending.stop[2])]
    then
      pending.opts = vim.tbl_extend('force', pending.opts, { end_right_gravity = false })
    end
  end

  -- Create extmarks for the new tree
  for _, pending in ipairs(pending_extmarks) do
    local extmark = Extmark.new(self.bufnr, self.ns, pending.start, pending.stop, pending.opts)
    self.text_content.curr.extmark_ids_to_tag[extmark.id] = pending.tag
    self.text_content.curr.tags_to_extmark_ids[pending.tag] = extmark.id
  end
  -- First pending_extmark is the outermost <text> node (DFS order).
  -- If it spans the full buffer, it's the top-level tag.
  local first = pending_extmarks[1]
  local rendered_end = Pos00.new(#lines - 1, #(lines[#lines] or ''))
  if first and first.start[1] == 0 and first.start[2] == 0 and first.stop == rendered_end then
    self.text_content.curr.top_level_tag = first.tag
  end

  -- Sync (or create) the undo probe with this render's editable regions. The
  -- probe's content and undo tree persist across renders; only the tag/id
  -- bookkeeping is refreshed, because a render creates brand-new extmarks.
  -- A render with no intentional holes keeps Neovim's native undo.
  self:_sync_probe(probe_regions)

  -- Re-arm traversal interception on every render: unmount's cleanup deletes
  -- the autocmd, so a remount (which never calls new again) must re-install
  -- it here. The installer is idempotent while one is already live.
  self:_install_probe_cmdline()

  -- Install the probe's traversal mappings last, after the probe exists and
  -- after restore_buffer_keymaps wiped the previous render's maps. The wipe is
  -- what removes them again on a later fully-unlocked render.
  if self.probe then self:_install_probe_keymaps() end
end

--------------------------------------------------------------------------------
-- Mount and Unmount
--------------------------------------------------------------------------------
-- mount() hands a tree to a Reconciler (Part III) for full lifecycle,
-- unmount() tears it down, and _release_mount_resources() frees the
-- buffer-side state a mounted document holds. Why here: lifecycle brackets
-- render.

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

  -- Mount-scoped state (trace, after-render queue, debounce timer, the mounted
  -- tree) lives on a Reconciler; Morph keeps buffers, extmarks, and keymaps.
  self.reconciler = Reconciler.new(self, tree, { debounce_ms = debounce_ms })
  self.reconciler:start()
end

--- Unmount the component tree, firing all unmount phases. Leaves buffer
--- content as-is. After unmounting, the same buffer/instance can be re-mounted.
--- Idempotent: calling when already unmounted is a no-op.
function Morph:unmount()
  if self.reconciler then self.reconciler:teardown() end
end

--- @private
--- Free the buffer-side resources a mounted document holds: registered cleanup
--- hooks, buffer keymaps, the extmark namespace, the buffer watcher, the undo
--- probe, and the text/diff state. Lifecycle concerns (unmount phases,
--- after-render callbacks) live in Reconciler:teardown, which calls this as its
--- final step. The buffer's content text is left as-is.
function Morph:_release_mount_resources()
  for _, cleanup in ipairs(self.cleanup_hooks) do
    cleanup()
  end
  self.cleanup_hooks = {}

  -- Restore pre-morph keymaps and clear morph extmarks. Content text stays.
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    restore_buffer_keymaps(self)
    vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)
  end

  -- Reset instance state for re-mountability.
  self.buf_watcher = nil
  self.changedtick = 0
  self.debounce_ms = nil
  -- Free the probe buffer: it is per-mount state, and leaving it loaded
  -- would leak a hidden buffer (and its undo tree) every mount/unmount cycle.
  self:_teardown_probe()
  self.text_content = {
    old = { lines = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
    curr = { lines = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
  }
end

--------------------------------------------------------------------------------
-- Element Queries
--------------------------------------------------------------------------------
-- get_elements_at(pos) and get_element_by_id(id) map buffer positions back
-- to elements, innermost first; _position_intersects_extmark corrects nvim's
-- over-inclusive extmark ranges. Why here: Morph reading its own state
-- back -- and dispatch, below, acts on what a query finds.

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
  sort_innermost_first(elements)

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
-- Keypress Dispatch
--------------------------------------------------------------------------------
-- Element handlers (imap/nmap/vmap/xmap/omap) receive keypresses innermost
-- first; returning '' swallows the key. Render's expr-mappings route the
-- swallow through the no-op operator below, because normal mode needs a `g@`
-- trick rather than an empty rhs. Original keymaps are snapshotted in
-- Morph.new and restored before each render. Why here: the last of
-- Morph's own machinery before Part VI turns to user input.

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
        if not event.bubble_up then break end
      else
        return result
      end
    end
  end

  return should_cancel and '' or lhs
end

--------------------------------------------------------------------------------
-- PART VI -- CHANGE HANDLING
--------------------------------------------------------------------------------
-- User edits arrive through the watcher, and the guard decides, per
-- keystroke, what was aimed at an editable region and what violated the
-- tree. Why after Part V: "is_rendering" and the snapshot fields only mean
-- something once render and the diff state exist.

--------------------------------------------------------------------------------
-- The Buffer Watcher
--------------------------------------------------------------------------------
-- nvim_buf_attach's on_bytes fires DURING a change, while the buffer is
-- inconsistent; the watcher queues those events and drains them when
-- TextChanged says the buffer is stable again, excluding morph's own render
-- writes. _ensure_buf_watcher is its Morph-side adapter. Why here: the
-- reader has now met render, so "morph is mid-render" is a phrase with
-- meaning.

--- @class morph.BufWatcher
--- @field user_bytes_queue unknown[][] User on_bytes events captured while
---   morph was NOT rendering, in arrival order, still unprocessed: genuine
---   user edits. Fast typing batches several events into one TextChanged
---   window; the guard drains them in order when the window closes, because
---   render writes must never be policed as if the user made them.
--- @field cursor_sample? integer[] Last settled cursor position (win_get_cursor
---   format): sampled on genuine navigation and on deliberate placements (an
---   app's post-render cursor positioning), never on movements caused by a
---   change in flight. The pre-edit snapshot for readonly reverts.
--- @field text_changed_autocmd_id integer
--- @field cursor_moved_autocmd_id integer
--- @field cleanup fun() Remove the watcher

--- Create a buffer watcher that calls `callback` after text changes.
--- @param bufnr integer
--- @param callback function Called with on_bytes args after TextChanged fires
--- @param is_rendering fun(): boolean Whether morph is mid-render (its own writes)
--- @return morph.BufWatcher
local function create_buf_watcher(bufnr, callback, is_rendering)
  -- Guard: buffer API must be ready for nvim_buf_attach to work
  if not is_buffer_api_ready(bufnr) then
    error(
      'morph.nvim: Cannot create buffer watcher - buffer not yet loaded. '
        .. 'Buffer must be loaded before mounting.',
      0
    )
  end

  local watcher = { user_bytes_queue = {} }

  -- Capture on_bytes args but don't call callback yet. Only events captured
  -- while morph is NOT rendering are queued as user edits: the guard polices
  -- user edits, and running it on morph's own writes made every app
  -- re-render (which rewrites the buffer after `changing` is already false)
  -- look like an out-of-tree edit -- a spurious revert per keystroke.
  local attach_ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(...)
      if is_rendering() then return end
      table.insert(watcher.user_bytes_queue, { ... })
    end,
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
        local queue = watcher.user_bytes_queue
        if #queue == 0 then
          -- Either no change happened, or the pending window held only
          -- morph's own render writes (the render already refreshed the
          -- snapshots it wrote); policing that would revert the app's
          -- legitimate re-render. Mixed windows (user edit and render writes
          -- in one typeahead batch) still run, on the user event's geometry,
          -- so the sweep sees the user's change.
          return
        end
        watcher.user_bytes_queue = {}
        -- Drain in ARRIVAL order: each event's geometry is exact for the
        -- frame its own change created, and the FIRST event's region is
        -- stated in the pre-window frame -- the frame the stored spans live
        -- in. The first keystroke therefore lands in the hole and updates
        -- its content to the full live text (batched chars included), and
        -- the remaining events find no mismatch and benignly no-op. Judging
        -- the window by only the last event (the old behavior) measured
        -- trailing keystrokes against a snapshot they had already outgrown,
        -- so a locked ancestor
        -- read the whole batch as a violation and reverted legitimate fast
        -- typing.
        for _, user_args in ipairs(queue) do
          callback(unpack(user_args))
        end
      end,
    }
  )

  -- Track the settled cursor position for the pre-edit snapshot used by
  -- readonly reverts: by the time a change's TextChanged fires, nvim has
  -- already adjusted (and often clamped) the cursor, so no post-change
  -- observation can recover the original. Movements are sampled EXCEPT when
  -- caused by a change in flight: morph's own patch (is_rendering) and a
  -- pending user edit's cursor adjustment are skipped, while deliberate
  -- placements after a render's writes settle sample directly.
  watcher.cursor_moved_autocmd_id = vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    buffer = bufnr,
    callback = function()
      if is_rendering() then return end
      -- A user edit is pending (unprocessed): its cursor movements belong to
      -- the change, not to navigation, so keep the pre-edit sample.
      if #watcher.user_bytes_queue > 0 then return end
      watcher.cursor_sample = vim.api.nvim_win_get_cursor(0)
    end,
  })

  function watcher.cleanup()
    vim.api.nvim_del_autocmd(watcher.text_changed_autocmd_id)
    vim.api.nvim_del_autocmd(watcher.cursor_moved_autocmd_id)
  end

  return watcher
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
    function(...) self:_on_bytes_after_autocmd(...) end,
    function() return self.changing end
  )
  table.insert(self.cleanup_hooks, self.buf_watcher.cleanup)
end

--------------------------------------------------------------------------------
-- The Guard
--------------------------------------------------------------------------------
-- Polices text changes: reverts edits that touched locked text or landed
-- outside the tree (flash + full-tree restore), attributes accepted edits to
-- the editable tags that own them, and fires their on_change handlers.
-- State model (each piece justified by a spec):
--   tag.curr_text  the accepted content per tag -- the only frame the guard
--                   decides with; live extmark positions locate the text,
--                   they never decide.
--   watcher.cursor_sample/user_bytes_queue  the pre-edit cursor snapshot
--                   and the pending user edit; render-owned writes never
--                   open a guard window.

--- @private
--- @private
--- Revert an edit that violated the tree: flash the touched regions, then
--- restore the buffer to the tree's content. The tree is the source of
--- truth: instead of surgically repairing the buffer (which fights extmark
--- mark-adjustment), the normal render pipeline rebuilds every span from
--- scratch. Runs on a scheduler tick so it never mutates the buffer
--- mid-handler.
--- @param violated morph.Extmark[] Spans to flash (pre-render geometry); may be
---   empty when the edit landed outside every span and nothing can be flashed
--- @param restore_cursor? integer[] Cursor (win_get_cursor format) to restore
---   after the revert: where the reverted edit found the cursor.
function Morph:_revert_violation(violated, restore_cursor)
  for _, extmark in ipairs(violated) do
    self:_flash_readonly(extmark.start, extmark.stop)
  end
  vim.schedule(function()
    if self.reconciler then
      self.reconciler:schedule_rerender()
    elseif self.last_tree then
      self:render(self.last_tree)
    end
    if restore_cursor then
      local win = vim.fn.bufwinid(self.bufnr)
      if win ~= -1 then pcall(vim.api.nvim_win_set_cursor, win, restore_cursor) end
    end
  end)
end

--- @private
--- Flash a readonly region that just got reverted. Best effort: hl
--- signature variations across nvim versions must never break the guard.
--- @param start morph.Pos00
--- @param stop morph.Pos00
function Morph:_flash_readonly(start, stop)
  pcall(function()
    local hl = vim.hl or vim.highlight
    local ns = vim.api.nvim_create_namespace('morph_flash_' .. self.bufnr)
    hl.range(self.bufnr, ns, 'Search', { start[1], start[2] }, { stop[1], stop[2] }, {
      timeout = 300,
    })
  end)
end

--- @private
--- Called after TextChanged autocmd fires, with the on_bytes info. The
--- guard's phases run in order: collect the tags whose live content differs
--- from the tree's expectation, decide (any readonly tag whose change no
--- editable descendant explains reverts the whole tree), accept (every
--- changed tag's expectation moves to its new content), then dispatch the
--- owned edits to their on_change handlers.
function Morph:_on_bytes_after_autocmd(
  _,
  _,
  _,
  start_row0,
  start_col0,
  _, -- byte offset of the change from buffer start
  _, -- old end row offset (unused: the content model never reasons in the
  -- pre-change frame)
  _, -- old end col offset (unused, same reason)
  _, -- old end byte length
  new_end_row_off,
  new_end_col_off,
  _ -- new end byte length
)
  -- Ignore changes we're making ourselves during render
  if self.changing then return end

  -- The change's start and post-change end. Per :h nvim_buf_attach
  -- on_bytes, a column offset is relative to start_col0 when the change
  -- stays on one line (the matching row offset is 0) and is the ABSOLUTE
  -- column in the end row otherwise. change_start begins the guard's zone
  -- query; new_end ends it and bounds the collapse recovery's read.
  local change_start = Pos00.new(start_row0, start_col0)
  local new_end = Pos00.new(
    start_row0 + new_end_row_off,
    new_end_row_off == 0 and start_col0 + new_end_col_off or new_end_col_off
  )

  -- Phase 1 -- collect: which tags' LIVE content differs from the tree's
  -- expectation? A zone query around [change_start, new_end] returns every
  -- extmark nudged by this change; reading its live text and comparing to
  -- `curr_text` is the entire change test. No spans, no frame arithmetic.
  local changed = self:_collect_changed(change_start, new_end)
  local editable, locked = changed.editable, changed.locked
  local in_editable_span = changed.in_editable_span

  -- Phase 2 -- decide: a readonly tag whose content changed is a violation
  -- unless a changed editable tag sits INSIDE it (that descendant's edit
  -- explains the ancestor's growth). Content and nesting, never position.
  if self:_readonly_violated(editable, locked) then
    -- Flash and restore where the reverted edit found the cursor: by handler
    -- time nvim has already adjusted (and often clamped) it, so the live
    -- position cannot be trusted.
    local violated = {} --- @type morph.Extmark[]
    for _, m in ipairs(locked) do
      table.insert(violated, m.extmark)
    end
    local restore_cursor = self.buf_watcher and self.buf_watcher.cursor_sample or nil
    self:_revert_violation(violated, restore_cursor)
    return
  end

  -- Phase 3 -- accept: every changed tag's expectation moves to its live
  -- content -- editable ones so dispatch announces the new text, locked ones
  -- so the next window does not re-read them as fresh violations.
  for _, list in ipairs { editable, locked } do
    for _, m in ipairs(list) do
      m.tag.curr_text = m.text
    end
  end

  -- Mirror the accepted edit into the undo probe, so probe entries track main
  -- entries. Runs before on_change fires: the probe then reflects the exact
  -- change the app is about to be told about.
  if self.probe then self.probe:mirror(undotree(self.bufnr).seq_cur) end

  -- Phase 4 -- dispatch: editable tags whose content changed OWN the edit --
  -- fire their handlers so the app hears the new content. When none does,
  -- the change is unowned: tolerate it (an app-owned write inside editable
  -- territory) or classify it (outside the tree: locked apps revert, classic
  -- apps route it to the whole-buffer handler).
  if #editable == 0 then
    self:_handle_unowned_change(in_editable_span)
    return
  end
  self:_dispatch_owned_changes(editable)
end

--- @private
--- Read the live text of a (0,0)-indexed span. Rows past the buffer end are
--- clamped first -- nvim_buf_get_text ERRORS there, and extmark ends land on
--- the buffer-end row after truncating edits. The degenerate/inverted check
--- reads empty, mirroring Extmark:_text()'s exclusive-end contract. The
--- trailing-newline behavior (an end on the next line's column 0 includes
--- the previous line's newline) comes from nvim_buf_get_text itself -- no
--- code here implements it. File-local: the collector is the only reader.
--- @param bufnr integer
--- @param row0 integer
--- @param col0 integer
--- @param end_row integer
--- @param end_col integer
--- @return string
local function live_span_text(bufnr, row0, col0, end_row, end_col)
  local last_row = vim.api.nvim_buf_line_count(bufnr) - 1
  if row0 > last_row or end_row > last_row then
    local last_line_len = #(
      vim.api.nvim_buf_get_lines(bufnr, last_row, last_row + 1, true)[1] or ''
    )
    if row0 > last_row then
      row0, col0 = last_row, last_line_len
    end
    if end_row > last_row then
      end_row, end_col = last_row, last_line_len
    end
  end
  if row0 > end_row or (row0 == end_row and col0 >= end_col) then return '' end
  return table.concat(vim.api.nvim_buf_get_text(bufnr, row0, col0, end_row, end_col, {}), '\n')
end

--- @private
--- Collect the tags whose live content differs from the tree's expectation,
--- using the change window only to decide WHERE to look. Mark adjustment
--- converges every affected mark onto the change region, so a zone query
--- over [change_start, new_end] (inclusive on both edges; verified) returns
--- every candidate plus harmless neighbors. Comparing live text against
--- `curr_text` is the whole change test.
--- @param change_start morph.Pos00
--- @param new_end morph.Pos00
--- @return { editable: morph.TagChange[], locked: morph.TagChange[], in_editable_span: boolean }
function Morph:_collect_changed(change_start, new_end)
  local editable = {} --- @type morph.TagChange[]
  local locked = {} --- @type morph.TagChange[]
  local in_editable_span = false
  local change_row, change_col = change_start[1], change_start[2]

  local raw = vim.api.nvim_buf_get_extmarks(
    self.bufnr,
    self.ns,
    { change_row, change_col },
    { new_end[1], new_end[2] },
    { details = true, overlap = true }
  )
  for _, ext in ipairs(raw) do
    local id, row0, col0, details = ext[1], ext[2], ext[3], ext[4]
    local tag = self.text_content.curr.extmark_ids_to_tag[id]
    if tag then
      local end_row = details.end_row or row0
      local end_col = details.end_col or col0

      -- change_start sits inside this editable live span (boundaries
      -- included)? The no-change fallback uses this to tell an edit inside an
      -- editable region from one outside the tree.
      if
        not tag.readonly
        and (row0 < change_row or (row0 == change_row and col0 <= change_col))
        and (change_row < end_row or (change_row == end_row and change_col <= end_col))
      then
        in_editable_span = true
      end

      -- Read the tag's content over its LIVE marks. The live marks are the
      -- truth under morph's gravity scheme for every shape but one: a
      -- replace touching the span's END drags the end mark onto the change
      -- start, so the live span degenerates to a point and reads '' while
      -- the actual replacement text sits at the change window -- the guard's
      -- [change_start, new_end) is the only witness to it. For every other
      -- shape (edited span stays healthy and reads its new bytes; a whole
      -- delete collapses it to '' which IS the new content; a shift leaves
      -- untouched spans reading their own bytes) widening by the stored span
      -- would re-import positional attribution and report bytes gravity
      -- gave to a neighbor as changed content: a typed char at a hole's
      -- tail made the shifted ']' tag report "f]", and a mid-word delete
      -- made a tag read "suf" from the following literal.
      local collapsed = row0 == end_row and col0 == end_col
      local new_text
      if collapsed then
        -- Collapsed live span: the replacement text at the change window is
        -- the tag's new content. A pure delete has new_end == change_start,
        -- so the read yields '' -- the correct content for a fully deleted
        -- span.
        new_text = live_span_text(self.bufnr, change_row, change_col, new_end[1], new_end[2])
      else
        new_text = live_span_text(self.bufnr, row0, col0, end_row, end_col)
      end
      if tag.curr_text ~= new_text then
        local extmark = Extmark._from_raw(self.bufnr, id, row0, col0, details)
        local mismatch = { extmark = extmark, tag = tag, text = new_text }
        if tag.readonly then
          table.insert(locked, mismatch)
        else
          table.insert(editable, mismatch)
        end
      end
    end
  end
  return { editable = editable, locked = locked, in_editable_span = in_editable_span }
end

--- @private
--- True when some readonly tag's content changed and no changed editable tag
--- sits inside it. This is the whole guard: nesting, not position. A hole's
--- own edit explains every readonly ancestor whose growth it caused, but
--- never an editable tag it is not part of -- which is exactly how a write
--- spanning the hole's edge is caught (the chrome literal is a readonly
--- sibling with no changed editable child). Example:
---
---   `Name: [x]`
---   0000000000
---   0123456789
---   A="Name: [" readonly  B="x" editable  C="]" readonly
---
---   write [5,8)->'Y'  ->  A's content changed (it lost " ["); B is not
---   inside A (sibling) -> violation. ciw on B alone leaves A unchanged ->
---   accepted.
--- @param editable morph.TagChange[]
--- @param locked morph.TagChange[]
--- @return boolean
function Morph:_readonly_violated(editable, locked)
  for _, suspect in ipairs(locked) do
    local explained = false
    for _, hole in ipairs(editable) do
      if Morph._is_inside(hole.tag, suspect.tag) then
        explained = true
        break
      end
    end
    if not explained then return true end
  end
  return false
end

--- @private
--- True when `inner` descends from `outer`, walking the parent links recorded
--- at render time.
--- @param inner morph.Tag
--- @param outer morph.Tag
--- @return boolean
function Morph._is_inside(inner, outer)
  local tag = inner.parent
  while tag do
    if tag == outer then return true end
    tag = tag.parent
  end
  return false
end

--- @private
--- Phase 4 of the guard, unowned branch: no editable tag's content changed,
--- so the edit belongs to no hole. It either landed outside every rendered
--- span or was already accounted for (the undo probe's writeback, an app's
--- own re-render); locked apps revert the former and tolerate the latter,
--- and classic apps route the former to the top-level tag's on_change.
--- @param in_editable_span boolean
function Morph:_handle_unowned_change(in_editable_span)
  if in_editable_span then return end
  if self.readonly_default then
    -- See the decision phase above: restore from the pre-edit snapshot
    local restore_cursor = self.buf_watcher and self.buf_watcher.cursor_sample or nil
    self:_revert_violation({}, restore_cursor)
    return
  end

  local tag = self.text_content.curr.top_level_tag
  if tag and vim.is_callable(tag.attributes.on_change) then
    local content = table.concat(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false), '\n')
    if tag.curr_text ~= content then
      tag.curr_text = content
      local prev_textlock = self.textlock
      self.textlock = true
      Morph._fire_tag_on_change(tag, content)
      self.textlock = prev_textlock
    end
  end
end

--- @private
--- Phase 4 of the guard, owned branch: each changed editable tag OWNS the
--- edit, so fire its on_change handler with the new content -- innermost
--- first, holding the textlock so handler-triggered re-renders defer instead
--- of mutating spans mid-loop -- then refresh the watcher's cursor sample.
--- @param editable morph.TagChange[]
function Morph:_dispatch_owned_changes(editable)
  -- Sort innermost first
  sort_innermost_first(editable)

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

  for _, changed in ipairs(editable) do
    local tag = self.text_content.curr.extmark_ids_to_tag[changed.extmark.id]
    local event = tag and Morph._fire_tag_on_change(tag, changed.text)
    if event and not event.bubble_up then break end
  end

  self.textlock = prev_textlock

  -- The accepted edits' own cursor movements were gated out of the snapshot
  -- (they fired while a change was pending), so refresh it with the settled
  -- position: the next violation should restore to here, not before this
  -- batch.
  if self.buf_watcher and vim.fn.bufwinid(self.bufnr) ~= -1 then
    self.buf_watcher.cursor_sample = vim.api.nvim_win_get_cursor(0)
  end
end

--------------------------------------------------------------------------------
-- PART VII -- UNDO AND REDO
--------------------------------------------------------------------------------
-- The undo probe: region-scoped undo/redo. Last of the machinery, because
-- it stands on everything before it -- regions come from the generator's
-- snapshots, writebacks reuse the guard's re-placement, and traversal
-- reuses the guard's on_change dispatch.

--------------------------------------------------------------------------------
-- The Undo Probe
--------------------------------------------------------------------------------

-- Principle: Neovim scopes undo per buffer, but the renderer wants it scoped
-- per editable region. A hidden scratch buffer can therefore own an undo tree
-- whose entries correspond to the user's region edits, while the main buffer
-- keeps a full undo tree of chrome renders that must stay independent of
-- traversals. Example: a render with two holes, `[aaa]` and `[bbb]`, stores
-- the whole region set as one JSON line `{"r1":"aaa","r2":"bbb"}` (ids minted
-- here; a declared `attributes.id` would be used verbatim); typing into either
-- hole rewrites that line, and `u` undoes it, decodes the previous line, and
-- writes the result back into the main buffer's spans.
--
-- Two directions keep the two buffers in agreement. The mirror copies the
-- accepted main-buffer edit into the probe, opening or joining a probe entry
-- so probe entries track main entries. The replay moves the probe's undo
-- pointer (never the main buffer's) and copies every region's text back into
-- the main buffer, so an app chrome render between `u` and `<C-r>` changes
-- only the main tree and leaves the probe's redo tip intact.
--
-- The probe keeps all regions in a single JSON-encoded line -- an object
-- mapping region id to region text -- rather than one buffer line per region.
-- That removes the per-region extmark bookkeeping (marks, spans, id maps) the
-- line-per-region layout needed, at the cost of rewriting the whole line on
-- every edit. Identity is resolved per render in sync: a declared
-- `attributes.id` is authoritative; otherwise the reconciler's stamp (a hex
-- sequence id minted per node chain and copied along matches) carries an id
-- forward while the stored tip still describes the region's content; static
-- renders, which have no reconciler and thus no stamps, match by render order
-- under the same rule; anything unresolved mints. Apps that add, remove,
-- reorder, or swap regions are therefore plain id-set diffs -- new ids enter
-- at birth, orphaned ids go inert, and no structural change needs a rebuild.

--- @class morph.Probe
--- @field bufnr integer The hidden probe buffer
--- @field regions { tag: morph.Tag, id: string, stamp: string? }[] Region
---   records in render order; `id` is the region's identity in stored
---   entries -- either the app-declared `attributes.id` or a probe-minted id
---   -- and `stamp` is the reconciler's hex sequence id for the node chain,
---   the key the next render's identity resolution matches against.
--- @field private birth {[string]: string} Per-id birth text: what a region
---   held when its id entered the probe -- the deepest state undo reaches for
---   a region whose id has no recorded entry (e.g. one added after mount).
--- @field private id_seq integer Counter for minted region ids
--- @field baseline integer Probe `seq_cur` at mount; the undo floor
--- @field last_main_seq integer Main `seq_cur` as of the last mirror/replay
--- @field entry_open boolean Whether the probe tip matches the main's current entry
--- @field private _tip_cache? {[string]: string} Last written tip states; see _texts()
local Probe = {}
Probe.__index = Probe

--- Mint a region id unused by anything the probe knows: ids claimed during
--- the current sync, every birth entry, and the stored tip -- the latter two
--- keep minted ids off app-declared strings that are only temporarily absent
--- from the region set.
--- @param taken {[string]: boolean} ids already claimed during this sync
--- @param tip {[string]: string} stored tip states
--- @return string
function Probe:_mint(taken, tip)
  local id = 'r' .. self.id_seq
  while taken[id] or self.birth[id] or tip[id] do
    self.id_seq = self.id_seq + 1
    id = 'r' .. self.id_seq
  end
  return id
end

--- The region states currently stored in the probe: id -> text.
-- The probe buffer is only ever written by _write (which refreshes the
-- cache below) and by replay's undo traversal (which clears it), so the
-- cache is authoritative in between. Decode-on-read used to round-trip a
-- JSON document the size of the ENTIRE region set on every keystroke and
-- every render; with tens of thousands of editable regions that dominates
-- the typing path.
--- @return {[string]: string}
function Probe:_texts()
  if self._tip_cache then return self._tip_cache end
  -- A fresh buffer holds one empty line (not zero lines); treat both that
  -- and a truly empty read as an empty store.
  local line = vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] or ''
  if line == '' then return {} end
  return vim.json.decode(line)
end

--- Replace the stored region states, opening a new undo entry or joining the
--- current one. `undojoin` folds this write into the previous entry; syncing
--- `&undolevels` forces a fresh entry.
--- @param states {[string]: string} Region states keyed by region id
--- @param join? boolean Whether to merge into the current probe entry
function Probe:_write(states, join)
  vim.api.nvim_buf_call(self.bufnr, function()
    if join then
      pcall(vim.api.nvim_command, 'undojoin')
    else
      vim.cmd 'let &undolevels = &undolevels'
    end
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { vim.json.encode(states) })
  end)
  self.entry_open = true
  -- The written states ARE the new tip; keep them so later reads never
  -- decode what we just encoded.
  self._tip_cache = states
end

--- Create the probe buffer and record the initial region set as one entry.
--- Resolution is `sync`'s job from the very first render: the records built
--- here are what the next render's stamps resolve against.
--- @param tags morph.Tag[] Region tags, in render order
--- @return morph.Probe
function Probe.new(tags)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false

  local self = setmetatable({
    bufnr = bufnr,
    regions = {},
    birth = {},
    id_seq = 0,
    baseline = 0,
    last_main_seq = 0,
    entry_open = false,
  }, Probe)

  -- Resolve identities, then write the mount state: the single entry the
  -- probe starts on. The empty store always differs, so mirror writes it and
  -- opens the entry.
  self:sync(tags)
  self:mirror(0)
  self.baseline = undotree(self.bufnr).seq_cur
  return self
end

--- Resolve each rendered region's identity and re-point the probe's records.
--- Resolution, in order of authority:
--- 1. A declared `attributes.id` is the app's authority channel: it is used
---    as-is, with no content check, so app-side text normalization cannot
---    break history.
--- 2. A node carrying a reconciler stamp (a hex sequence id copied along
---    matches) inherits the id recorded for that stamp -- but only while the
---    stored tip still describes the region. The tip check is what keeps
---    refills safe: a swap or a prepend hands an old stamp to a new item,
---    fails the check, and remints instead of inheriting foreign history.
--- 3. A node with no stamp comes from a static render (no reconciler, no
---    stamps); those fall back to matching by render order under the same
---    tip-equality rule.
--- Anything unresolved mints: its history starts at the region's current
--- text (its birth), and any history left hanging off the slot goes inert. A
--- region that disappears needs no handling at all -- its history simply
--- stops being referenced.
--- @param tags morph.Tag[] Region tags, in render order
function Probe:sync(tags)
  local tip = self:_texts()
  local id_by_stamp = {} --- @type {[string]: string}
  for _, rec in ipairs(self.regions) do
    if rec.stamp then id_by_stamp[rec.stamp] = rec.id end
  end
  local prev_regions = self.regions

  local taken = {} --- @type {[string]: boolean}
  local regions = {} --- @type { tag: morph.Tag, id: string, stamp: string? }[]
  for i, tag in ipairs(tags) do
    local text = tag.curr_text or ''
    local id
    local declared = tag.attributes.id
    if type(declared) == 'string' then
      id = declared
    elseif tag.stamp then
      local prev_id = id_by_stamp[tag.stamp]
      if prev_id and tip[prev_id] == text then id = prev_id end
    else
      local prev = prev_regions[i]
      if prev and tip[prev.id] == text then id = prev.id end
    end
    if not id then id = self:_mint(taken, tip) end
    taken[id] = true
    -- First sighting of an id records its floor: entries that predate it
    -- leave the region at this text.
    self.birth[id] = self.birth[id] or text
    table.insert(regions, { tag = tag, id = id, stamp = tag.stamp })
  end
  self.regions = regions
end

--- Mirror the accepted main-buffer edit into the probe.
--- The probe opens a new entry exactly when the main buffer did, and joins
--- otherwise. The signal is whether the main buffer's `seq_cur` advanced since
--- the previous mirror batch: the first batch of a new main entry sees a
--- changed pointer, later batches of the same entry do not.
--- @param main_seq integer The main buffer's current `seq_cur`
function Probe:mirror(main_seq)
  local fresh = main_seq ~= self.last_main_seq
  local stored = self:_texts()
  local states = {} --- @type {[string]: string}
  local differs = false
  for _, rec in ipairs(self.regions) do
    local text = rec.tag.curr_text or ''
    states[rec.id] = text
    if stored[rec.id] ~= text then differs = true end
  end
  if differs then
    -- First write of a fresh main entry opens a probe entry; later writes of
    -- the same entry join it.
    self:_write(states, self.entry_open and not fresh)
  end
  self.last_main_seq = main_seq
end

--- Move the probe to the previous/next entry (or an absolute entry) and return
--- the resulting region states (id -> text).
--- @param direction 'undo'|'redo'
--- @param abs_target? integer Jump to this exact `seq_cur` instead of one relative step
--- @return {[string]: string}? states The region states after the move, nil when the probe did not move
function Probe:replay(direction, abs_target)
  local tree = undotree(self.bufnr)
  -- Traversal runs in the probe buffer's context; pcall because `undo`/`redo`
  -- error (E663/E664) at the ends of the tree even when the move is guarded.
  local function run(cmd)
    vim.api.nvim_buf_call(self.bufnr, function() pcall(vim.api.nvim_command, cmd) end)
  end
  if abs_target then
    -- `:undo N` addresses an absolute undo state, not a step count, so jump
    -- straight there. Clamp into [baseline, seq_last]: below the floor would
    -- lose the mount state, above the tip is undefined.
    local target = math.max(self.baseline, math.min(abs_target, tree.seq_last))
    if target == tree.seq_cur then return nil end
    run('undo ' .. target)
  elseif direction == 'undo' then
    if tree.seq_cur <= self.baseline then return nil end
    -- Exact-jump to the entry strictly below the current one, so the replay
    -- cannot drift by a step the way repeated blind `u`s could.
    local target = self.baseline
    for _, entry in ipairs(tree.entries) do
      if entry.seq > target and entry.seq < tree.seq_cur then target = entry.seq end
    end
    run('undo ' .. target)
  else
    if tree.seq_cur >= tree.seq_last then return nil end
    run 'redo'
  end

  -- The writeback will write the main buffer, so the main tree advances; mark
  -- the probe disconnected from the current main entry so the next user edit
  -- opens a fresh probe entry rather than joining a stale one.
  self.entry_open = false
  -- Undo moved the probe's content out from under the tip cache; the next
  -- read must decode the entry the traversal landed on.
  self._tip_cache = nil
  return self:_texts()
end

--- Ex-commands that move the undo pointer, and how each is read. `absolute`
--- marks the forms whose numeric argument is an undo-state address rather than
--- a relative step count (`:undo N`, `:redo N`).
local TRAVERSALS = {
  undo = { direction = 'undo', absolute = true },
  redo = { direction = 'redo', absolute = true },
  earlier = { direction = 'undo' },
  later = { direction = 'redo' },
}

--- @private
--- Install buffer-local mappings that reroute traversal keys through the
--- probe. Named `u`/`<C-r>`/`g-`/`g+` mappings replace the native actions, so
--- a traversal moves the probe's undo pointer and then writes region text back
--- rather than traversing the main buffer's (chrome-contaminated) tree.
--- Called after `restore_buffer_keymaps`, which wipes buffer keymaps every
--- render.
function Morph:_install_probe_keymaps()
  local opts = { buffer = self.bufnr, nowait = true, silent = true }
  local traversal_keys = { u = 'undo', ['g-'] = 'undo', ['<C-r>'] = 'redo', ['g+'] = 'redo' }
  for lhs, direction in pairs(traversal_keys) do
    vim.keymap.set('n', lhs, function() self:_probe_traverse(direction) end, opts)
  end
end

--- @private
--- Intercept the ex-command traversal forms (`:undo`, `:redo`, `:earlier`,
--- `:later`). These cannot be shadowed by buffer-local user commands, because
--- Neovim rejects lowercase user command names; a `CmdlineLeave` handler can
--- instead detect the pending command and redirect it before it runs. Parsing
--- goes through `nvim_parse_cmd`, so recognition is by command name and
--- arguments rather than by string matching, and a count or range is honored.
--- Registered once per instance from `Morph.new`; it self-gates on whether the
--- current buffer has a live probe.
function Morph:_install_probe_cmdline()
  if self._probe_cmdline_autocmd then return end
  local group = vim.api.nvim_create_augroup('morph_probe_cmdline:' .. tostring(self.bufnr), {
    clear = true,
  })
  self._probe_cmdline_autocmd = vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = group,
    callback = function()
      -- Only act while this instance's buffer is current and a probe exists.
      if vim.api.nvim_get_current_buf() ~= self.bufnr or not self.probe then return end
      local ok, parsed = pcall(vim.api.nvim_parse_cmd, vim.fn.getcmdline(), {})
      local spec = ok and parsed and TRAVERSALS[parsed.cmd]
      if not spec then return end

      -- `:undo N`/`:redo N` address an absolute undo state; `:earlier N`/
      -- `:later N` count N relative steps. A bare `:undo`/`:redo` has no count
      -- (nil on newer Neovim, 0 on older), so only a positive count is an
      -- absolute target. The step count for the relative forms is the first
      -- argument.
      local absolute = spec.absolute and type(parsed.count) == 'number' and parsed.count > 0
      -- Coerce to an integer: nvim_parse_cmd reports counts as numbers, and the
      -- relative forms carry their step count as a string argument.
      local raw = absolute and parsed.count or tonumber(parsed.args and parsed.args[1] or '')
      local steps = math.max(1, math.floor(raw or 1))

      -- Neutralize the pending command so Neovim's own traversal never runs
      -- (a buffer-local user command cannot shadow a builtin lowercase name,
      -- but rewriting the command line can), then replay the probe once the
      -- command line has closed.
      pcall(vim.fn.setcmdline, 'echo ""')
      vim.schedule(function()
        if absolute then
          self:_probe_traverse(spec.direction, steps)
          return
        end
        for _ = 1, steps do
          self:_probe_traverse(spec.direction)
        end
      end)
    end,
  })
  table.insert(self.cleanup_hooks, function()
    if self._probe_cmdline_autocmd then
      pcall(vim.api.nvim_del_autocmd, self._probe_cmdline_autocmd)
      self._probe_cmdline_autocmd = nil
    end
  end)
end

--- @private
--- Traverse the probe by one entry and apply the result to the main buffer.
--- Writing a region back also fires its `on_change`, so the app re-syncs its
--- state and chrome that embeds the region text re-renders to match.
--- @param direction 'undo'|'redo'
--- @param abs_target? integer For `:undo N`/`:redo N`: the absolute state to reach
function Morph:_probe_traverse(direction, abs_target)
  if not self.probe then return end
  local states = self.probe:replay(direction, abs_target)
  if not states then return end

  -- Determine which regions actually changed, then apply them under `changing`
  -- so the guard treats the write as morph's own render.
  local changed = {} --- @type { tag: morph.Tag, text: string }[]
  for _, rec in ipairs(self.probe.regions) do
    local extmark = self:_region_extmark(rec.tag)
    -- Entries that predate a region's id have nothing to say about it; the
    -- id's birth text is the deepest state undo reaches for the region.
    local target = states[rec.id] or self.probe.birth[rec.id]
    if extmark and target and extmark:_text() ~= target then
      table.insert(changed, { tag = rec.tag, text = target })
    end
  end
  if #changed == 0 then return end

  self.changing = true
  for _, change in ipairs(changed) do
    local extmark = self:_region_extmark(change.tag)
    -- An earlier write in this batch may have restored this region's text
    -- already: a containing region's snapshot embeds its children's text, so
    -- once the child is written the parent matches too. Writing anyway would
    -- drag the contained region's marks to the parent's start, so re-check
    -- the live text immediately before writing.
    if not extmark or extmark:_text() ~= change.text then
      self:_write_region_text(change.tag, change.text)
    end
  end
  self.changing = false

  -- Deliberately do NOT refresh self.changedtick: the next render must see the
  -- buffer as externally changed and resync its diff base (`text_content.curr`)
  -- from the buffer's real lines. `text_content.old` still describes the
  -- pre-writeback text, so diffing against it would corrupt patch_lines.

  -- Fire the changed regions' on_change so app state (and any chrome that
  -- embeds the region text) re-syncs with the reverted content.
  local prev_textlock = self.textlock
  self.textlock = true
  for _, change in ipairs(changed) do
    Morph._fire_tag_on_change(change.tag, change.text)
  end
  self.textlock = prev_textlock
end

--- @private
--- Fire one tag's on_change with the standard event shape and return the
--- (handler-mutable) event, nil when the tag has no handler. Callers hold
--- `self.textlock` across a batch of these so handler-triggered re-renders
--- defer instead of mutating extmark spans mid-loop.
--- @param tag morph.Tag
--- @param text string
--- @return table? event
function Morph._fire_tag_on_change(tag, text)
  local on_change = tag.attributes.on_change
  if not vim.is_callable(on_change) then return nil end
  local event = { text = text, bubble_up = true }
  --- @diagnostic disable-next-line: need-check-nil
  on_change(event)
  return event
end

--- @private
--- The live extmark for a region tag, if the tag is still part of the render.
--- @param tag morph.Tag
--- @return morph.Extmark?
function Morph:_region_extmark(tag)
  local id = self.text_content.curr.tags_to_extmark_ids[tag]
  return id and Extmark.by_id(self.bufnr, self.ns, id)
end

--- @private
--- Replace one region's main-buffer text with `text` and re-place its extmark
--- over the new span. Re-placing is what keeps the span exact: a replacement
--- collapses the mark to zero width, so the guard would otherwise read an
--- empty span on the next batch.
--- @param tag morph.Tag
--- @param text string
function Morph:_write_region_text(tag, text)
  local extmark = self:_region_extmark(tag)
  if not extmark then return end
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_buf_set_text(
    self.bufnr,
    extmark.start[1],
    extmark.start[2],
    extmark.stop[1],
    extmark.stop[2],
    lines
  )
  local end_row = extmark.start[1] + #lines - 1
  local end_col = (#lines == 1) and (extmark.start[2] + #lines[1]) or #lines[#lines]
  -- Re-place through the shared extmark builder so the span's gravity
  -- semantics stay defined in exactly one place.
  Extmark.new(self.bufnr, self.ns, extmark.start, Pos00.new(end_row, end_col), { id = extmark.id })
  tag.curr_text = text
end

--- @private
--- Delete the probe buffer and drop the reference. Every path that stops using
--- a probe -- disengagement, a structural region-set change, unmount, buffer
--- wipe -- funnels through here, so the hidden buffer and its undo tree never
--- outlive their region set.
function Morph:_teardown_probe()
  if self.probe and vim.api.nvim_buf_is_valid(self.probe.bufnr) then
    vim.api.nvim_buf_delete(self.probe.bufnr, { force = true })
  end
  self.probe = nil
end

--- @private
--- Build or refresh the undo probe after a render. The region set is derived
--- from the render (DFS order). Entries are keyed by region id, so every
--- structural change -- add, remove, reorder, swap -- is an id-set diff
--- rather than a rebuild trigger: regions that keep their id keep their
--- history, a region the probe cannot identify mints a fresh id whose
--- history starts at its current text, and a removed region's history goes
--- inert (replay only ever touches regions present in the render).
--- @param regions morph.Tag[] Outermost intentional holes, in render order
function Morph:_sync_probe(regions)
  -- A render with no editable tags (fully locked chrome) has nothing
  -- region-scoped to govern, so the probe must not intercept traversal keys
  -- there; native undo is correct.
  if #regions == 0 then
    self:_teardown_probe()
    return
  end

  if not self.probe then
    self.probe = Probe.new(regions)
    return
  end

  -- Fresh tag objects every pass: resolve each region's identity and re-point
  -- the probe's records (a render rebuilds the tree every pass).
  self.probe:sync(regions)
end

--------------------------------------------------------------------------------
-- THE ANNEX -- CLIENTS OF THE PUBLIC API
--------------------------------------------------------------------------------
-- Components and hook helpers built on the same public surface user code
-- sees: nothing here reaches into private state. Optional reading that
-- doubles as example code; FloatingWindow depends on Portal and on the hook
-- helpers, so read the hooks first.

--------------------------------------------------------------------------------
-- ErrorBoundary
--------------------------------------------------------------------------------
-- Catches descendant render errors and shows a fallback; reconcile_component
-- (Part III) gives it that special treatment.

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
-- Portal
--------------------------------------------------------------------------------
-- Renders children into a different buffer through an inner document.

--- @class morph.PortalProps
--- @field bufnr integer
--- @field on_buf_create? fun(bufnr: integer, document: morph.Morph): any

--- Portal component: Renders children to a different buffer (like React portals)
--- @param ctx morph.Ctx<morph.PortalProps, { document: morph.Morph, update?: fun(children: morph.Tree?) }>
function Morph.Portal(ctx)
  if ctx.phase == 'mount' then
    local bufnr = ctx.props.bufnr
    -- Forward the enclosing renderer's readonly default so locked-by-default
    -- apps stay locked inside portals.
    local outer = ctx.document
    local document = Morph.new(bufnr, { readonly = outer and outer.readonly_default or nil })
    ctx.state = { document = document, update = nil }

    if ctx.props.on_buf_create then ctx.props.on_buf_create(bufnr, document) end

    --- Renders children from state; exposes its ctx:update as ctx.state.update
    --- @param inner morph.Ctx<any, { children: morph.Tree }>
    local function Content(inner)
      if inner.phase == 'mount' then
        inner.state = { children = inner.children }
        ctx.state.update = function(children) inner:update { children = children } end
      end
      return assert(inner.state).children
    end

    document:mount(h(Content, {}, ctx.children), { debounce_ms = 0 })
    return nil
  end

  local portal_state = ctx.state
  if ctx.phase == 'update' and portal_state and portal_state.update then
    portal_state.update(ctx.children)
  elseif ctx.phase == 'unmount' then
    -- Release the inner document. Content stays in the portal buffer; a fresh
    -- Morph.new(bufnr) + mount is legal on re-mount because unmount cleared the
    -- buffer's mounted flag.
    --- @diagnostic disable-next-line: need-check-nil
    portal_state.document:unmount()
  end

  return nil
end

--------------------------------------------------------------------------------
-- Hook Helpers
--------------------------------------------------------------------------------
-- Two small, self-contained utilities FloatingWindow uses: a previous-value
-- cell for per-render comparisons, and mode transition with confirmation.

--- @class morph._internal.hooks.PrevValueCell<T>
--- @field private prev T
--- @field get fun(self: morph._internal.hooks.PrevValueCell<T>, v: T): T  -- returns the previous value, stores v as current

--- Create a previous-value cell. Call once at mount, store on ctx.state.
--- Each render, call cell:get(v) to read the previous value of v and store v.
--- @generic T
--- @param initial T value returned by the first get() call
--- @return morph._internal.hooks.PrevValueCell<T>
local function mk_prev_value_cell(initial)
  local cell = { prev = initial }
  function cell:get(v)
    local p = self.prev
    self.prev = v
    return p
  end
  return cell
end

--- Transition to target_mode (via stopinsert/startinsert) and call callback
--- once the mode change takes effect, confirmed via ModeChanged autocmd
--- (no timing dependency). If already in target_mode, calls callback
--- immediately. Safety fallback: if ModeChanged never fires, proceeds
--- after 500ms.
--- @param target_mode string  Single-char mode to transition to ('n' or 'i')
--- @param callback fun()
local function restore_mode_and_wait(target_mode, callback)
  local current_mode = vim.fn.mode():sub(1, 1)
  if current_mode == target_mode then
    callback()
    return
  end

  local mode_pattern = current_mode .. ':' .. target_mode
  local mode_changed_id
  -- Defer the callback onto a clean event-loop tick so it runs OUTSIDE the
  -- ModeChanged autocmd. Otherwise a nested action taken from the callback --
  -- e.g. FloatingWindow's on_closed opening another float that calls
  -- startinsert -- executes while the i:n transition is still on the autocmd
  -- stack, and the nested startinsert does not stick (leaves the new float in
  -- normal mode). Decoupling callback execution from the autocmd preserves the
  -- autocmd's "wait until the mode change takes effect" timing semantics.
  local function schedule_callback() vim.schedule(callback) end
  local fallback_timer = vim.defer_fn(function()
    -- mode_changed_id reads as nil here because the closure may run before the
    -- autocmd below is created; the pcall swallows that (and any close race).
    pcall(vim.api.nvim_del_autocmd, mode_changed_id --[[@as integer]])
    schedule_callback()
  end, 500)

  mode_changed_id = vim.api.nvim_create_autocmd('ModeChanged', {
    pattern = mode_pattern,
    once = true,
    nested = true,
    callback = function()
      fallback_timer:stop()
      pcall(vim.api.nvim_del_autocmd, mode_changed_id --[[@as integer]])
      schedule_callback()
    end,
  })

  if target_mode == 'n' then
    vim.cmd.stopinsert()
  elseif target_mode == 'i' then
    vim.cmd.startinsert()
  else
    callback()
    return
  end
end

--------------------------------------------------------------------------------
-- FloatingWindow
--------------------------------------------------------------------------------
-- Manages a floating window whose children render through Portal: open and
-- close transitions, focus/cursor/mode restore, and config updates.

--- @class components.FloatingWindowProps
--- @field open boolean
--- @field config vim.api.keyset.win_config | fun(): vim.api.keyset.win_config
--- @field children morph.Tree
--- @field on_win_create? fun(winnr: integer, bufnr: integer, document: morph.Morph)
--- @field on_buf_create? fun(bufnr: integer, document: morph.Morph)
--- @field on_closed? fun()  @ fires exactly once per open→closed transition, after the window
--- is closed and the previous window/cursor/mode have been restored. If the component is
--- unmounted while still open, that unmount IS the transition and on_closed fires there.

--- @class components.FloatingWindowState
--- @field bufnr integer
--- @field winnr integer?
--- @field document morph.Morph?
--- @field autocmd_id integer?
--- @field prev_winnr integer?
--- @field prev_cursor [integer, integer]?
--- @field prev_mode string?
--- @field prev_open_cell morph._internal.hooks.PrevValueCell<boolean>
--- @field prev_config_cell morph._internal.hooks.PrevValueCell<vim.api.keyset.win_config>

--- @param ctx morph.Ctx<components.FloatingWindowProps, components.FloatingWindowState>
function Morph.FloatingWindow(ctx)
  local open = ctx.props.open

  if ctx.phase == 'mount' then
    -- Create autocmd to refresh on window resize
    local autocmd_id = vim.api.nvim_create_autocmd('VimResized', {
      callback = vim.schedule_wrap(function() ctx:refresh() end),
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    ctx.state = {
      bufnr = bufnr,
      winnr = nil,
      document = nil,
      autocmd_id = autocmd_id,
      prev_winnr = nil,
      prev_cursor = nil,
      prev_mode = nil,
      prev_open_cell = mk_prev_value_cell(false),
      prev_config_cell = mk_prev_value_cell(nil) --[[@as morph._internal.hooks.PrevValueCell<vim.api.keyset.win_config>]],
    }
  end

  --- @type components.FloatingWindowState
  local state = assert(ctx.state)
  local prev_open = state.prev_open_cell:get(open)
  local config = ctx.props.config
  if type(config) == 'function' then config = config() end

  --- Shared open→closed teardown for both the prop-driven close transition
  --- and unmount. Closes over ctx/state/prev_open. When the float still holds
  --- focus and a mode was captured, transitions back to that mode first and
  --- restores the previous window/cursor (if alive); never steals focus back.
  --- On unmount also tears down the resize autocmd and the float buffer.
  --- on_closed fires when prev_open is true -- a real transition, not the
  --- unmount of an already-closed or never-opened component.
  local function close_transition()
    local is_unmount = ctx.phase == 'unmount'
    local focused = state.winnr ~= nil
      and vim.api.nvim_win_is_valid(state.winnr)
      and vim.api.nvim_get_current_win() == state.winnr
    local prev_winnr = state.prev_winnr
    local prev_cursor = state.prev_cursor
    local prev_mode = state.prev_mode

    --- @param restore_focus boolean
    local function work(restore_focus)
      if is_unmount and state.autocmd_id then pcall(vim.api.nvim_del_autocmd, state.autocmd_id) end
      if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        vim.api.nvim_win_close(state.winnr, true)
        state.winnr = nil
      end
      if is_unmount and vim.api.nvim_buf_is_valid(state.bufnr) then
        vim.api.nvim_buf_delete(state.bufnr, { force = true })
      end
      if restore_focus and prev_winnr and vim.api.nvim_win_is_valid(prev_winnr) then
        pcall(vim.api.nvim_set_current_win, prev_winnr)
        if prev_cursor then pcall(vim.api.nvim_win_set_cursor, prev_winnr, prev_cursor) end
      end
      if prev_open and ctx.props.on_closed then ctx.props.on_closed() end
    end

    local function run()
      if focused and prev_mode then
        restore_mode_and_wait(prev_mode, function() work(true) end)
      else
        work(false)
      end
    end

    if is_unmount then
      run()
    else
      ctx:do_after_render(run)
    end
  end

  if ctx.phase == 'update' or ctx.phase == 'mount' then
    --
    -- Buffer:
    --
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      state.bufnr = vim.api.nvim_create_buf(false, true)
    end

    --
    -- Window transitions:
    --
    -- Window is opening now.
    if not prev_open and open then
      if config.focusable ~= false then
        state.prev_winnr = vim.api.nvim_get_current_win()
        state.prev_cursor = vim.api.nvim_win_get_cursor(state.prev_winnr)
        state.prev_mode = vim.fn.mode():sub(1, 1)
      end

      local enter = config.focusable ~= false
      state.winnr = vim.api.nvim_open_win(state.bufnr, enter, config)
      state.prev_config_cell:get(config)
      -- Call on_win_create callback if provided
      if ctx.props.on_win_create then
        ctx:do_after_render(function()
          -- document is set by the Portal child's on_buf_create during this
          -- same render, which always precedes do_after_render callbacks.
          ctx.props.on_win_create(state.winnr, state.bufnr, state.document --[[@as morph.Morph]])
        end)
      end
    elseif prev_open and not open then
      close_transition()

      state.prev_winnr = nil
      state.prev_cursor = nil
      state.prev_mode = nil

      -- Window stays open; just update its config (skip unchanged configs to avoid UI flicker).
    elseif open then
      if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        local prev = state.prev_config_cell:get(config)
        if not vim.deep_equal(config, prev) then
          vim.api.nvim_win_set_config(state.winnr, config)
        end
      end
    end
  end

  if ctx.phase == 'unmount' then close_transition() end

  return h(Morph.Portal, {
    bufnr = state.bufnr,
    on_buf_create = function(bufnr, document)
      state.document = document
      if ctx.props.on_buf_create then ctx.props.on_buf_create(bufnr, document) end
    end,
  }, ctx.children)
end

--------------------------------------------------------------------------------
-- Exports
--------------------------------------------------------------------------------

Morph.h = h
Morph.Pos00 = Pos00
Morph.RenderError = RenderError

-- Export internal functions for testing when NVIM_TEST=true
if vim.env.NVIM_TEST then
  Morph._is_buffer_api_ready = is_buffer_api_ready
  Morph._is_textlock = is_textlock
  Morph._levenshtein = levenshtein
  Morph.Extmark = Extmark
end

return Morph
