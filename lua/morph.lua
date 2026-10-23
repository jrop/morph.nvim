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
-- text, its extmarks, keymaps, and undo behavior in sync as the tree changes
-- and the user types. Each part of the file owns one step of that loop:
--
--   I    the tree model and h()                   V    the Morph instance
--   II   core types (Pos00, Extmark, Ctx,         VI   the change guard
--        RenderError)                              VII  the undo probe
--   III  reconciliation                           annex components built on
--   IV   text generation and diffing                    the public API
--
-- House rules for new code: a chapter is contiguous; each banner states its
-- role and why it sits where it does; code uses only names already introduced
-- (Lua's `local` scoping enforces this, and type annotations are erased
-- comments that may therefore name a type early).
--
-- Public API (see the exports at the end of the file): h, Pos00, Extmark,
-- RenderError, the Morph instance methods, and the ErrorBoundary / Portal /
-- FloatingWindow components.

--------------------------------------------------------------------------------
-- PART I -- THE TREE MODEL
--------------------------------------------------------------------------------
-- The data model: what a UI tree is made of, how nodes are classified and
-- matched, and h(), the one constructor user code calls.

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------
-- Tag = recipe (an h() result); Element = instantiated tag with an extmark;
-- Node/Tree = composable structures; Component = a function producing a Tree.
-- Nothing here runs at runtime.
--------------------------------------------------------------------------------

--- @alias morph.TagEventHandler fun(e: { tag: morph.Element, mode: string, lhs: string, bubble_up: boolean }): string

--- Tag attributes. `readonly` is 3-state: `true` locks the region, `false`
--- carves an editable hole (even under a locked ancestor), and nil inherits
--- from the enclosing region (ultimately Morph.new's `readonly` option).
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

--- A tag is the result of calling h(...): a recipe for creating an element.
--- @class morph.Tag
--- @field kind 'tag'
--- @field name string | morph.Component<any, any>
--- @field attributes morph.TagAttributes
--- @field children morph.Tree
--- @field parent? morph.Tag Enclosing tag recorded at render time; the guard
---   walks it to ask "is this editable tag inside that readonly one?" The
---   relation must be structural, not positional: a deleted line collapses
---   every tag's marks to one point, so bounds-containment would let a
---   destroyed editable sibling "explain" a destroyed readonly tag.
--- @field literal? boolean True on the implicit tag wrapping a bare literal
--- @field private ctx? morph.Ctx<any, any>
--- @field private curr_text? string
--- @field private readonly? boolean
--- @field private stamp? string Hex sequence id minted by the reconciler and
---   copied along matches: the node's identity chain. The undo probe chains a
---   region's history across renders by matching stamps, then requiring the
---   stored tip to still describe the region's content.

--- An element is an instantiated Tag.
--- @class morph.Element : morph.Tag
--- @field extmark morph.Extmark

--- @alias morph.Node nil | boolean | string | number | morph.Tag
--- One level of array nesting is allowed, so a subtree can be spliced in as a
--- single child (e.g. `{ 'label: ', ctx.children }`).
--- @alias morph.Tree morph.Node | (morph.Node | morph.Node[])[]
--- @alias morph.Component<TProps, TState> fun(ctx: morph.Ctx<TProps, TState>): morph.Tree

--- One changed tag: its live extmark and the tag's new (live or recovered)
--- content.
--- @alias morph.TagChange { extmark: morph.Extmark, tag: morph.Tag, text: string }

--------------------------------------------------------------------------------
-- Tree Utilities
--------------------------------------------------------------------------------
-- Pure functions over the tree model: node classification and readonly
-- resolution. Nothing here reaches past the tree.

--- Resolve a tag's effective readonly state (3-state; see morph.TagAttributes).
--- @param tag morph.Tag
--- @param inherited boolean?
--- @return boolean?
local function resolve_readonly(tag, inherited)
  local own = tag.attributes.readonly
  if own ~= nil then return own end
  return inherited
end

--- Determine the type of a tree node.
--- @param tree morph.Tree
--- @return 'nil'|'boolean'|'string'|'number'|'array'|'tag'|'component'
local function tree_kind(tree)
  if tree == nil or tree == vim.NIL then return 'nil' end
  if type(tree) == 'boolean' then return 'boolean' end
  if type(tree) == 'string' then return 'string' end
  if type(tree) == 'number' then return 'number' end
  if type(tree) == 'function' then
    -- getinfo returns nil when the function has no debug info; degrade to a
    -- placeholder name rather than crashing inside the error builder.
    local info = debug.getinfo(tree, 'n')
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
  if type(tree) == 'table' then
    if tree.kind == 'tag' then
      return vim.is_callable(tree.name) and 'component' or 'tag'
    else
      return 'array'
    end
  end
  error('unknown tree node type: ' .. type(tree))
end

--------------------------------------------------------------------------------
-- h(): Hyperscript
--------------------------------------------------------------------------------
-- The one constructor user code calls; everything downstream consumes what
-- it produces.
--
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
-- The runtime objects the loop manipulates: a position type, the moving region
-- markers nvim tracks for us, the per-component context, and the error value a
-- failing component becomes. The environment checks they depend on come first.

--------------------------------------------------------------------------------
-- Interlude: Environment Checks
--------------------------------------------------------------------------------
-- Two checks that answer "may I act right now?", one per reason. is_textlock
-- detects Neovim's textlock -- buffer/window changes are forbidden during it,
-- e.g. inside an autocmd callback -- so updates can be scheduled instead of
-- erroring. is_buffer_api_ready detects a startup buffer whose content is not
-- loaded yet, where a render would prepend instead of replace.

--- A lazily-created scratch buffer reused to probe for textlock.
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

--- True when the buffer has a filename but its content is not loaded yet. This
--- is the one not-ready cause that never clears on its own.
--- @param bufnr integer
--- @return boolean
local function needs_load(bufnr)
  return vim.api.nvim_buf_get_name(bufnr) ~= '' and vim.fn.bufloaded(bufnr) == 0
end

--- Check if the buffer API is in a consistent state for rendering.
--- @param bufnr integer
--- @return boolean
local function is_buffer_api_ready(bufnr)
  -- Vim hasn't finished startup - buffer state may be inconsistent
  if vim.v.vim_did_enter == 0 then return false end

  return not needs_load(bufnr)
end

--- Run `on_ready` once the buffer can accept a render, or fail loudly.
---
--- The predicate can be false for two reasons. Before VimEnter the buffer is
--- mid-setup and clears itself when VimEnter fires, so the wait rides that
--- event instead of polling. A named-but-unloaded buffer never clears on its
--- own, so load it once (which is what mounting into it means). If the
--- predicate is still false after both, error rather than loop forever.
--- @param bufnr integer
--- @param on_ready fun()
local function when_buffer_ready(bufnr, on_ready)
  -- A buffer can be deleted between the wait being registered and the wait
  -- resolving (e.g. a pre-VimEnter mount whose buffer is wiped first), and
  -- every predicate below would error on it. Fail with a message that names
  -- the real cause instead of a raw "Invalid buffer id".
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error('morph.nvim: buffer ' .. tostring(bufnr) .. ' no longer exists', 0)
  end

  if is_buffer_api_ready(bufnr) then
    on_ready()
    return
  end

  -- Startup: the predicate flips on its own at VimEnter, so wait for the event.
  if vim.v.vim_did_enter == 0 then
    vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function() when_buffer_ready(bufnr, on_ready) end,
    })
    return
  end

  -- Past startup the only remaining blocker is the named-but-unloaded buffer,
  -- which never clears by itself; loading it once is the caller's intent.
  if needs_load(bufnr) then pcall(vim.fn.bufload, bufnr) end

  if is_buffer_api_ready(bufnr) then
    on_ready()
    return
  end

  error(
    'morph.nvim: buffer '
      .. tostring(bufnr)
      .. ' is not ready to render into; '
      .. 'load the buffer or wrap the call in vim.schedule()',
    0
  )
end

--------------------------------------------------------------------------------
-- Pos00: Zero-Based Buffer Positions
--------------------------------------------------------------------------------
-- One zero-based position type for the whole file, so nvim's mix of 0- and
-- 1-based indexing is restated in exactly one place.

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

--- Render as a `row:col` string, so a position can key a set collision-free.
--- @return string
function Pos00:__tostring() return ('%d:%d'):format(self[1], self[2]) end

--------------------------------------------------------------------------------
-- Extmark: Wrapper Around Neovim's Extmark API
--------------------------------------------------------------------------------
-- Extmarks are the moving bookmarks nvim keeps for us: text regions that
-- travel as the buffer is edited. This wrapper normalizes their quirks
-- (inverted or past-EOF bounds, degenerate spans).

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
--- @param details { end_row: integer?, end_col: integer? }? Present when the
---   source API call requested details; the body treats absent details as "no
---   known end". A full extmark-details keyset satisfies this narrower shape.
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
--- The live text covered by this extmark's span. The constructors (new and
--- _from_raw) already clamp the bounds, so no row fixup is needed here; a
--- degenerate or inverted span reads empty. The trailing-newline behavior (an
--- end on the next line's column 0 includes the previous line's newline) comes
--- from nvim_buf_get_text itself.
--- @return string
function Extmark:_text()
  local start, stop = self.start, self.stop
  if not (start < stop) then return '' end
  return table.concat(
    vim.api.nvim_buf_get_text(self.bufnr, start[1], start[2], stop[1], stop[2], {}),
    '\n'
  )
end

--------------------------------------------------------------------------------
-- Ctx: Component Context (Props, State, Lifecycle)
--------------------------------------------------------------------------------
-- Every component receives a Ctx: props, state, phase, and the update /
-- refresh / do_after_render controls.

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

--- Update state and trigger a re-render (mount phase only updates state, to
--- avoid infinite loops). When the buffer cannot be touched right now -- a
--- textlock, or the guard's dispatch batch -- the re-render is scheduled
--- instead of run synchronously.
--- @param new_state TState
function Ctx:update(new_state)
  self.state = new_state

  -- Don't trigger re-render during mount (component is still being set up)
  if self.phase == 'mount' then return end
  if not self.on_change then return end

  -- Scheduling is safe in debounce mode too: on_change only arms a timer, so
  -- this moves when the timer is armed, never when the buffer is written.
  local locked = (self.document and self.document.textlock) or is_textlock()
  if locked then
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
-- and the ancestor trace.

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
-- The Reconciler owns everything a single mount() tracks across renders: the
-- mounted tree, the last reconciled tree, the render trace, the after-render
-- callback queue, and the debounce timer. Morph owns buffers, extmarks, and
-- keymaps; the Reconciler owns components and their lifecycle. They meet at
-- Reconciler:rerender(), which calls Morph:render().
--
-- Morph's declaration rides here because the reconciler names it:
-- reconcile_component gives ErrorBoundary descendants their catch-and-fallback
-- treatment. Morph's behavior is built in Part V.

--- @alias morph.MorphTextState {
---   lines: string[],
---   tags_to_extmark_ids: table<morph.Tag, integer?>,
---   extmark_ids_to_tag: table<integer, morph.Tag?>,
---   top_level_tag?: morph.Tag,
--- }

--- Read a buffer's undo tree. `undotree()` reports on the current buffer, so
--- hidden buffers need the `nvim_buf_call` hop.
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
--- @field private changedtick? integer -- buffer tick recorded after we last synced text_content.lines
--- @field private changing boolean
--- @field private textlock boolean
--- @field private original_keymaps table<string, table<string, any>>
--- @field private text_content morph.MorphTextState
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
--- @field last_invoke_time integer uv.now() of the last render, seeding the debounce window
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
    last_invoke_time = 0,
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

--- Mint a region stamp: a session-unique hex sequence id. A counter, not a
--- content hash: the stamp must be render-invariant for matched nodes, and
--- hashing content or position breaks on the reorders identity exists for.
--- @return string
function Reconciler:_mint_stamp()
  self.stamp_seq = self.stamp_seq + 1
  return ('%016x'):format(self.stamp_seq)
end

--- Mount the tree: mark mounted, render synchronously, and record the render
--- time so the maxWait debounce measures from the mount render.
function Reconciler:start()
  self.mounted = true
  self:rerender()
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

--- Run all queued after-render callbacks, then clear the queue. The queue is
--- swapped out before running, so a callback that triggers a nested rerender
--- (via ctx:update during the update phase) sees a fresh one.
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
  local node_type = tree_kind(old_tree)

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

    -- Skip if already unmounted (a prior unmount error can leave old_tree stale).
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
  local old_type = tree_kind(old_tree)
  local new_type = tree_kind(new_tree)

  -- If type changed, unmount old tree first
  if old_type ~= new_type then self:_unmount_tree(old_tree) end

  -- Primitives pass through untouched: no lifecycle, nothing to match.
  if new_type == 'nil' or new_type == 'boolean' or new_type == 'string' or new_type == 'number' then
    return new_tree
  end

  if new_type == 'array' then
    local old_array = (old_type == 'array') and old_tree --[[@as morph.Node[]?]] or nil
    --- @diagnostic disable-next-line: need-check-nil
    return self:reconcile_array(old_array, new_tree --[[@as morph.Node[] ]])
  end

  if new_type == 'tag' then
    local new_tag = new_tree --[[@as morph.Tag]]
    local old_children = (old_type == new_type) and (old_tree --[[@as morph.Tag]]).children or nil
    --- @diagnostic disable-next-line: need-check-nil
    local rendered =
      h(new_tag.name, new_tag.attributes, self:reconcile(old_children, new_tag.children))
    -- Identity is a value: a hex id minted on mount and copied along matches.
    -- It lives on the app-side node (the graph the next diff sees); the
    -- wrapper mirrors it for the probe.
    local stamp = (old_type == 'tag') and old_tree.stamp or nil
    if not stamp then stamp = self:_mint_stamp() end
    new_tag.stamp = stamp
    --- @diagnostic disable-next-line: need-check-nil
    rendered.stamp = stamp
    return rendered
  end

  -- Components are the only remaining node type.
  --- @diagnostic disable-next-line: need-check-nil
  return self:reconcile_component(old_tree, new_tree --[[@as morph.Tag]])
end

--- Reconcile arrays of nodes by matching old to new on identity keys (node
--- type, component function, explicit key attribute). This is where the
--- "diffing" magic happens for lists.
--- @param old_nodes morph.Node[]?
--- @param new_nodes morph.Node[]?
--- @return morph.Node[]
function Reconciler:reconcile_array(old_nodes, new_nodes)
  --- Compute an identity key for a node, used to match old/new nodes during reconciliation.
  --- Includes the node type, component function (if any), and explicit key attribute.
  --- For primitive types without explicit keys, uses index to distinguish positions.
  --- @param node morph.Node
  --- @param index integer fallback key if no explicit key
  --- @return string
  local function node_kind_key(node, index)
    local t = tree_kind(node)
    if t == 'nil' or t == 'boolean' or t == 'string' or t == 'number' then
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
      local key = node_kind_key(node --[[@as morph.Node]], i)
      old_by_key[key] = node
    end
  end

  -- Scan new list, reusing nodes by key or mounting new ones
  local result = {} --- @type morph.Node[]
  for i = 1, table.maxn(new_nodes) do
    local new_node = new_nodes[i]
    if new_node ~= nil then
      local key = node_kind_key(new_node --[[@as morph.Node]], i)
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
  local old_type = tree_kind(old_tree)
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

  -- Set the name before calling Component so ctx.name is populated if it
  -- throws. A self-naming component (ctx.name = 'X') overrides this.
  --- @diagnostic disable-next-line: need-check-nil
  if ctx.name == '' then ctx.name = debug.getinfo(Component, 'n').name or '<anonymous>' end

  -- Update props/children and wire the callbacks; the closures are stable for
  -- the mount's lifetime.
  ctx.props = new_tag.attributes
  ctx.children = new_tag.children
  ctx.on_change = function() self:schedule_rerender() end
  ctx._register_after_render_callback = function(cb) table.insert(self.after_render_callbacks, cb) end

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

  -- Move past 'mount' right after the first render: Ctx:update no-ops while
  -- the phase is still 'mount' (to avoid stack overflows).
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

--- MaxWait debounce: at most one rerender per debounce_ms while updates
--- arrive, plus a trailing render once they stop. A pending timer makes the
--- call a no-op, because Ctx:update already set state before calling us;
--- otherwise schedule a timer for the time left until the next allowed slot.
function Reconciler:schedule_rerender()
  -- A zero debounce renders synchronously; only positive values rate-limit.
  if self.debounce_ms <= 0 then
    self:rerender()
    return
  end

  if self.debounce_timer and self.debounce_timer:is_active() then return end

  -- Elapsed time past a full window still waits one window: the trailing
  -- render keeps its spacing rather than firing the instant work arrives.
  local ms_since_last_invoke = vim.uv.now() - self.last_invoke_time
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

--- Terminal teardown: fires all unmount phases and frees every resource of
--- this mount (the unmount autocmd and Morph:unmount both call it). Leaves
--- buffer content as-is. Idempotent, because buffer deletion and an explicit
--- unmount can both run it.
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
-- From reconciled tree to buffer bytes: the diff algorithm, the generator that
-- flattens a tree into lines while caching each tag's text for the guard, and
-- the patcher that writes the difference with minimal edits.

--------------------------------------------------------------------------------
-- Interlude: The Levenshtein Diff
--------------------------------------------------------------------------------
-- The minimal edit sequence between two lists. patch_lines is the only
-- consumer (lines, then characters within a changed line).

--- @alias morph.LevenshteinChangeAdd<T> { kind: 'add', item: T, index: integer }
--- @alias morph.LevenshteinChangeDelete<T> { kind: 'delete', item: T, index: integer }
--- @alias morph.LevenshteinChangeChange<T> { kind: 'change', from: T, to: T, index: integer }
--- @alias morph.LevenshteinChange<T> morph.LevenshteinChangeAdd<T> | morph.LevenshteinChangeDelete<T> | morph.LevenshteinChangeChange<T>

--- @class morph.LevenshteinOpts<T>
--- @field from T[]
--- @field to T[]
--- @field are_any_equal? boolean
--- @field cost? morph.LevenshteinCost<T>

--- @class morph.LevenshteinCost<T>
--- @field of_add? integer
--- @field of_delete? integer
--- @field of_change? fun(a: T, b: T, ai: integer, bi: integer): integer

--- Compute the minimal edit sequence to transform `from` into `to`.
--- @generic T
--- @param opts morph.LevenshteinOpts<T>
--- @return morph.LevenshteinChange<T>[]
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

  -- Backtrack to extract the changes. Verify which operation actually reached
  -- each cell (prev_cell + operation_cost == current_cell) rather than
  -- comparing the cell values, since variable costs make a cheaper path
  -- invisible in the values alone. Ties prefer delete > add > change, so
  -- removing 'b' from ['a','b'] deletes it rather than substituting it.
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
-- markup_to_lines flattens a tree into buffer lines, caching every tag's text
-- (curr_text) along the way -- the snapshot the guard later decides with.

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
    local node_type = tree_kind(node)

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
        local lit = h('text', {}, node)
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
      -- Numbers render as their string form and share the string path's
      -- implicit-tag treatment; a stringified number holds no newline, so the
      -- delegation below never reaches the split path.
      return visit(tostring(node --[[@as number]]), parent_readonly)
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
      -- region (resolve_readonly owns the 3-state semantics).
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
-- Reading the Difference / Writing the Difference
--------------------------------------------------------------------------------
-- Two line-array diffs on the same engine (the Interlude's levenshtein).
-- diff_to_band reads where the buffer changed: the guard's dirty band is the
-- content diff of the render's snapshot against the live lines. patch_lines
-- writes a computed difference with minimal buffer edits.

--- Trim the common prefix/suffix lines from two line arrays: the changed
--- region both diff consumers work on. patch_lines writes that region;
--- diff_to_band reads it. The region is old[prefix+1..#old_lines-suffix]
--- rewritten as new[prefix+1..#new_lines-suffix] (1-based, inclusive).
--- @param old_lines string[]
--- @param new_lines string[]
--- @return integer prefix Common leading lines (the region's 0-based top row)
--- @return integer suffix Common trailing lines
local function trim_common_edges(old_lines, new_lines)
  local n, m = #old_lines, #new_lines
  local prefix = 0
  while prefix < n and prefix < m and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  while
    suffix < n - prefix
    and suffix < m - prefix
    and old_lines[n - suffix] == new_lines[m - suffix]
  do
    suffix = suffix + 1
  end
  return prefix, suffix
end

--- The trimmed middle both diff consumers feed their DP: the slice of `lines`
--- between the common prefix and suffix, i.e. what trim_common_edges leaves.
--- @param lines string[]
--- @param prefix integer
--- @param suffix integer
--- @return string[]
local function middle_lines(lines, prefix, suffix)
  local out = {}
  for i = prefix + 1, #lines - suffix do
    out[#out + 1] = lines[i]
  end
  return out
end

--- Diff two line arrays into the guard's dirty band. Both sides are settled
--- content (the render's snapshot vs the live lines), so the rows are final
--- coordinates and no frame compensation applies. The engine is the house
--- levenshtein on the trimmed middle -- the same alignment patch_lines writes.
---
--- The edges are extmark semantics, not diff logic. The top tightens up over
--- the region's net removed lines, so a tag that started above the junction
--- and owns a deleted tail is still reached (nvim_buf_get_extmarks matches by
--- start position). The bottom is the junction where a removed range's marks
--- park; it is deliberately not clamped to the buffer, because appends park
--- marks one row past the last line.
---
--- Windows: one per maximal run of the script's line ops, columns trimmed from
--- the run's first and last line pair. A run with no new rows (a pure delete)
--- gets none; its witness correctly reads empty at the junction.
--- @param old_lines string[] The diff base (the render's line snapshot)
--- @param new_lines string[] The live buffer lines
--- @return integer? top0 nil when the arrays are identical
--- @return integer? bottom0
--- @return morph.ChangeWindow[]? windows
function Morph.diff_to_band(old_lines, new_lines)
  local n, m = #old_lines, #new_lines
  local prefix, suffix = trim_common_edges(old_lines, new_lines)
  local region_old, region_new = n - suffix - prefix, m - suffix - prefix
  if region_old == 0 and region_new == 0 then return nil, nil, nil end

  local removed = math.max(0, region_old - region_new)
  local top0 = math.max(0, prefix - removed)
  local bottom0 = m - suffix
  if region_old == region_new and suffix > 0 then bottom0 = bottom0 - 1 end

  local windows = {} --- @type morph.ChangeWindow[]
  -- Past this size the DP costs milliseconds per burst. The band stays
  -- exact -- its edges are region arithmetic and need no DP -- and only the
  -- windows coarsen to one per region: the witness tolerates a wider read
  -- (apps re-render on change), so correctness never depends on window
  -- tightness.
  if math.max(region_old, region_new) > 300 then
    if region_new > 0 then
      windows[1] = {
        row0 = prefix,
        col0 = 0,
        end_row = m - suffix - 1,
        end_col = #new_lines[m - suffix],
      }
    end
    return top0, bottom0, windows
  end

  local trimmed_old = middle_lines(old_lines, prefix, suffix)
  local trimmed_new = middle_lines(new_lines, prefix, suffix)
  local line_changes = levenshtein { from = trimmed_old, to = trimmed_new }

  -- Walk the script in document order (the backtrack emits it end-first),
  -- grouping ops into runs. Each op records its FROM anchor (its `index`), so
  -- the aligned-equal pairs it skipped appear as a gap between the anchor and
  -- the replay position; that gap breaks runs.
  local from_pos, to_pos = 1, 1
  -- The run's consumed ranges, 1-based into the trimmed arrays: FROM = old rows
  -- rewritten, TO = new rows produced (nil until the run consumes that side).
  --- @type { from_first: integer?, from_last: integer?, to_first: integer?, to_last: integer? }?
  local run = nil
  local function flush_run()
    local r = run
    if not r then return end
    run = nil
    if not r.to_first then return end -- a pure delete run: the witness reads empty
    -- to_first/to_last are set together, so the to_first guard also covers
    -- to_last; the checker cannot see that.
    local to_first, to_last =
      r.to_first, --[[@as integer]]
      r.to_last --[[@as integer]]
    local first_old = r.from_first and trimmed_old[r.from_first] or nil
    local last_old = r.from_last and trimmed_old[r.from_last] or nil
    -- The run's TO rows are within the region, so these lookups cannot miss.
    local first_new = trimmed_new[to_first] --[[@as string]]
    local last_new = trimmed_new[to_last] --[[@as string]]
    local col0 = 0
    if first_old then
      local min_len = math.min(#first_old, #first_new)
      while col0 < min_len and first_old:byte(col0 + 1) == first_new:byte(col0 + 1) do
        col0 = col0 + 1
      end
    end
    local end_col = #last_new
    if last_old then
      local min_len = math.min(#last_old, #last_new)
      local trim = 0
      while
        trim < min_len - col0
        and last_old:byte(#last_old - trim) == last_new:byte(#last_new - trim)
      do
        trim = trim + 1
      end
      end_col = end_col - trim
    end
    if end_col < col0 then end_col = col0 end
    windows[#windows + 1] = {
      row0 = prefix + to_first - 1,
      col0 = col0,
      end_row = prefix + to_last - 1,
      end_col = end_col,
    }
  end

  for i = #line_changes, 1, -1 do
    local change = line_changes[i] --[[@as morph.LevenshteinChange<string>]]
    local keeps = change.index - from_pos
    if keeps > 0 or not run then flush_run() end
    run = run or {}
    if keeps > 0 then
      -- Silent keeps: aligned-equal pairs advancing both sides.
      from_pos, to_pos = from_pos + keeps, to_pos + keeps
    end
    if change.kind == 'delete' then
      run.from_first = run.from_first or from_pos
      run.from_last = from_pos
      from_pos = from_pos + 1
    elseif change.kind == 'add' then
      run.to_first = run.to_first or to_pos
      run.to_last = to_pos
      to_pos = to_pos + 1
    else
      run.from_first = run.from_first or from_pos
      run.from_last = from_pos
      run.to_first = run.to_first or to_pos
      run.to_last = to_pos
      from_pos, to_pos = from_pos + 1, to_pos + 1
    end
  end
  flush_run()
  return top0, bottom0, windows
end

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

  -- Trim common prefix/suffix lines so Levenshtein only sees the changed
  -- middle. A one-line insertion deep in a 1000-line list would otherwise
  -- balloon its O(n^2) cost; most tree-view edits are localised.
  local prefix, suffix = trim_common_edges(old_lines, new_lines)

  local line_changes = levenshtein {
    from = middle_lines(old_lines, prefix, suffix),
    to = middle_lines(new_lines, prefix, suffix),
  }

  for _, change in ipairs(line_changes) do
    local line0 = prefix + change.index - 1

    if change.kind == 'add' then
      --- @cast change morph.LevenshteinChangeAdd<string>
      vim.api.nvim_buf_set_lines(bufnr, line0, line0, true, { change.item })
    elseif change.kind == 'delete' then
      --- @cast change morph.LevenshteinChangeDelete<string>
      vim.api.nvim_buf_set_lines(bufnr, line0, line0 + 1, true, {})
    elseif change.kind == 'change' then
      --- @cast change morph.LevenshteinChangeChange<string>
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
          --- @cast char_change morph.LevenshteinChangeAdd<string>
          vim.api.nvim_buf_set_text(bufnr, line0, col0, line0, col0, { char_change.item })
        elseif char_change.kind == 'delete' then
          --- @cast char_change morph.LevenshteinChangeDelete<string>
          vim.api.nvim_buf_set_text(bufnr, line0, col0, line0, col0 + 1, {})
        elseif char_change.kind == 'change' then
          --- @cast char_change morph.LevenshteinChangeChange<string>
          vim.api.nvim_buf_set_text(bufnr, line0, col0, line0, col0 + 1, { char_change.to })
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- PART V -- THE MORPH INSTANCE
--------------------------------------------------------------------------------
-- One Morph per buffer, owning its text, extmarks, keymaps, and undo
-- interception. Provides render (static markup), mount (component lifecycle),
-- the element queries, and keypress dispatch.

--------------------------------------------------------------------------------
-- Shared Helpers
--------------------------------------------------------------------------------
-- Keymap constants and the two helpers Morph's methods share: the
-- innermost-first element sort and the buffer-keymap restore.

-- Keymap modes paired with the tag attributes that hold their handlers. One
-- table instead of two index-linked arrays, which could desynchronize.
local KEYMAP_MODES = {
  { mode = 'i', attr = 'imap' },
  { mode = 'n', attr = 'nmap' },
  { mode = 'v', attr = 'vmap' },
  { mode = 'x', attr = 'xmap' },
  { mode = 'o', attr = 'omap' },
}

--- Sort element records (tables with an `extmark` field) innermost first:
--- smallest span before larger containing spans; ties broken by extmark id.
--- @param list { extmark: morph.Extmark }[]
local function sort_innermost_first(list)
  table.sort(list, function(a, b)
    local ea, eb = a.extmark, b.extmark
    if ea.start == eb.start and ea.stop == eb.stop then return ea.id < eb.id end
    return ea.start >= eb.start and ea.stop <= eb.stop
  end)
end

--- @private
--- Clear all buffer-local keymaps, then restore the pre-morph snapshot. Shared
--- by render (before each pass) and teardown, so a live buffer never keeps
--- stale morph-installed keymaps.
--- @param self morph.Morph
local function restore_buffer_keymaps(self)
  for _, keymap in ipairs(KEYMAP_MODES) do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(self.bufnr, keymap.mode)) do
      --- @diagnostic disable-next-line: param-type-mismatch
      pcall(vim.keymap.del, keymap.mode, map.lhs, { buffer = self.bufnr })
    end
    for _, map in pairs(self.original_keymaps[keymap.mode] or {}) do
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
-- diff-state shell, and the buffer-deletion cleanup.

--- Create a new Morph instance bound to a buffer.
--- @param bufnr integer? Buffer number (nil or 0 means current buffer)
--- @param opts? table  Fields: `readonly` (boolean): lock every tag that has no
---   explicit readonly attribute, so tags can carve editable holes with
---   readonly = false. Undo/redo is then region-aware: traversal keys route
---   through a hidden probe buffer and govern only the editable regions, while
---   app chrome renders stay independent of history.
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
    -- nil means "no snapshot is proven current": the first render fetches.
    changedtick = nil,
    changing = false,
    textlock = false,
    -- The row range the last judged burst swept (test/debug introspection).
    -- The band itself is the watcher's content diff (see diff_to_band); the
    -- drain receives it ready-made.
    _last_band = nil,
    probe = nil,
    _probe_cmdline_autocmd = nil,
    original_keymaps = {},
    text_content = { lines = { '' }, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
    cleanup_hooks = {},
    buf_watcher = nil, -- Created lazily in _ensure_buf_watcher()
    reconciler = nil, -- Created by mount()
  }, Morph)

  -- Snapshot all buffer-local keymaps so we can restore them before each render
  for _, keymap in ipairs(KEYMAP_MODES) do
    self.original_keymaps[keymap.mode] = {}
    --- @diagnostic disable-next-line: param-type-mismatch
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, keymap.mode)) do
      self.original_keymaps[keymap.mode][map.lhs] = map
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

--- An extmark queued for creation after the buffer text is patched.
--- @alias morph.PendingExtmark { tag: morph.Tag, start: morph.Pos00, stop: morph.Pos00, opts: any }

--- Set the boundary gravity of editable spans that touch. At a seam between
--- two adjacent editable spans a keystroke must land in exactly one: an
--- editable span's start yields forward when another editable span ends there
--- (holding the seam to the left), except a zero-width span, which never
--- yields its start (typing at an empty hole must enter the hole).
---
--- An editable span's end instead holds when a zero-width editable span starts
--- there: the hole's bytes must go only to the hole, and a riding left end
--- would balloon over them (the probe's writeback would then erase the hole).
--- @param pending_extmarks morph.PendingExtmark[]
local function apply_boundary_gravity(pending_extmarks)
  local editable_stop_keys = {}
  local editable_zero_start_keys = {}
  for _, pending in ipairs(pending_extmarks) do
    if not pending.tag.readonly then
      editable_stop_keys[tostring(pending.stop)] = true
      if pending.start == pending.stop then
        editable_zero_start_keys[tostring(pending.start)] = true
      end
    end
  end
  for _, pending in ipairs(pending_extmarks) do
    local zero_width = pending.start == pending.stop
    if
      not pending.tag.readonly
      and not zero_width
      and editable_stop_keys[tostring(pending.start)]
    then
      pending.opts = vim.tbl_extend('force', pending.opts, { right_gravity = true })
    end
    if
      not pending.tag.readonly
      and not zero_width -- a zero-width span's stop is its own start, not a neighbor's
      and editable_zero_start_keys[tostring(pending.stop)]
    then
      pending.opts = vim.tbl_extend('force', pending.opts, { end_right_gravity = false })
    end
  end
end

--- Render static markup to the buffer.
--- This is a "one-shot" render - no lifecycle, no state, just text + extmarks.
--- @param tree morph.Tree
function Morph:render(tree)
  self.last_tree = tree
  -- Guard: buffer may have been deleted while render was scheduled
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end

  -- Buffer may not be ready during startup; see when_buffer_ready.
  if not is_buffer_api_ready(self.bufnr) then
    when_buffer_ready(self.bufnr, function() self:render(tree) end)
    return
  end

  -- Ensure buffer watcher is created (for on_change handlers)
  self:_ensure_buf_watcher()

  -- We need to collect extmarks during tree traversal, but can't create them
  -- until after the buffer text is updated (extmarks need valid positions)
  local pending_extmarks = {} --- @type morph.PendingExtmark[]
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

      -- Every resolved-editable tag is an undo region. Entries snapshot the
      -- whole region set, so a nested editable tag neither splits undo steps
      -- nor disagrees with the region embedding it on replay.
      if not tag.readonly then table.insert(probe_regions, tag) end

      -- Convert hl attribute to extmark highlight
      if type(tag.attributes.hl) == 'string' then
        tag.attributes.extmark = tag.attributes.extmark or {}
        tag.attributes.extmark.hl_group = tag.attributes.extmark.hl_group or tag.attributes.hl
      end

      local extmark_opts = tag.attributes.extmark or {}
      if tag.readonly then
        -- Locked spans reject boundary inserts: inverted gravity (start
        -- yields forward, end holds) lands a typed edge character in the
        -- adjacent hole, not inside the lock.
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

      -- Register keymaps for any mode handlers (imap, nmap, vmap, xmap, omap)
      for _, keymap in ipairs(KEYMAP_MODES) do
        for lhs, _ in pairs(tag.attributes[keymap.attr] or {}) do
          vim.keymap.set(keymap.mode, lhs, function()
            local result = self:_dispatch_keypress(keymap.mode, lhs)

            -- '' swallows the keypress; normal mode needs the g@ no-op trick.
            if result == '' and keymap.mode ~= 'i' then
              vim.go.operatorfunc = 'v:lua.MorphOpFuncNoop'
              return 'g@ '
            end
            return result
          end, { buffer = self.bufnr, expr = true, replace_keycodes = true })
        end
      end
    end,
  }

  -- Buffers always have one line, so an empty tree yields { '' }.
  if #lines == 0 then lines = { '' } end

  -- Reuse the last render's snapshot as the diff base only while the buffer
  -- still matches it. changedtick is the proof: every write (ours, a user's,
  -- undo, the probe) bumps it, so a match means text_content.lines is still
  -- the live text and patch_lines need not fetch it again.
  local diff_base = nil
  if self.changedtick == vim.b[self.bufnr].changedtick then diff_base = self.text_content.lines end

  -- Update buffer text with minimal edits
  self.text_content = { lines = lines, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} }

  -- Clear extmarks BEFORE patching to avoid Neovim's auto-deletion overhead
  -- when lines with extmarks are deleted by patch_lines
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)

  self.changing = true
  -- A nil base makes patch_lines read the live buffer; a recorded base is the
  -- snapshot the tick proved current, so the fetch is skipped.
  Morph.patch_lines(self.bufnr, diff_base, lines)
  self.changing = false
  self.changedtick = vim.b[self.bufnr].changedtick

  apply_boundary_gravity(pending_extmarks)

  -- Create extmarks for the new tree
  for _, pending in ipairs(pending_extmarks) do
    local extmark = Extmark.new(self.bufnr, self.ns, pending.start, pending.stop, pending.opts)
    self.text_content.extmark_ids_to_tag[extmark.id] = pending.tag
    self.text_content.tags_to_extmark_ids[pending.tag] = extmark.id
  end
  -- First pending_extmark is the outermost <text> node (DFS order).
  -- If it spans the full buffer, it's the top-level tag.
  local first = pending_extmarks[1]
  local rendered_end = Pos00.new(#lines - 1, #(lines[#lines] or ''))
  if first and first.start[1] == 0 and first.start[2] == 0 and first.stop == rendered_end then
    self.text_content.top_level_tag = first.tag
  end

  -- Sync the probe with this render's editable regions. Its content and undo
  -- tree persist across renders; only the tag/id bookkeeping is refreshed,
  -- since a render mints brand-new extmarks. No holes means native undo.
  self:_sync_probe(probe_regions)

  -- Re-arm traversal interception: unmount's cleanup deletes the autocmd, so
  -- a remount must re-install it (the installer is idempotent).
  self:_install_probe_cmdline()

  -- Install the probe's traversal mappings after the keymap wipe above, which
  -- is also what removes them on a later fully-unlocked render.
  if self.probe then self:_install_probe_keymaps() end
end

--------------------------------------------------------------------------------
-- Mount and Unmount
--------------------------------------------------------------------------------
-- mount() hands a tree to a Reconciler for full lifecycle; unmount() tears it
-- down and _release_mount_resources() frees the buffer-side state.

--- Mount a component tree with full lifecycle management.
--- Components can have state, respond to updates, and run cleanup on unmount.
--- @param tree morph.Tree
--- @param opts? { debounce_ms?: integer }  debounce_ms: ms to debounce rerenders (0=sync)
function Morph:mount(tree, opts)
  opts = opts or {}
  local debounce_ms = opts.debounce_ms or (vim.env.NVIM_TEST and 0 or 16)
  if vim.b[self.bufnr]._morph_mounted then
    error('Morph:mount() can only be called once per buffer', 0)
  end

  -- May not be ready during startup; re-entering mount preserves opts.
  if not is_buffer_api_ready(self.bufnr) then
    when_buffer_ready(self.bufnr, function() self:mount(tree, opts) end)
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
--- Free the buffer-side resources a mounted document holds: cleanup hooks,
--- keymaps, the extmark namespace, the watcher, the probe, and the diff state.
--- Reconciler:teardown calls this after the lifecycle phases. Content stays.
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
  self.changedtick = nil
  -- The probe buffer is per-mount state; leaving it loaded would leak a hidden
  -- buffer and its undo tree every mount/unmount cycle.
  self:_teardown_probe()
  self.text_content = { lines = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} }
end

--------------------------------------------------------------------------------
-- Element Queries
--------------------------------------------------------------------------------
-- get_elements_at(pos) and get_element_by_id(id) map buffer positions back to
-- elements, innermost first; position_intersects_extmark corrects nvim's
-- over-inclusive extmark ranges.

--- Check if a position truly intersects an extmark (Neovim's API is over-inclusive).
--- @param pos morph.Pos00
--- @param extmark morph.Extmark
--- @param mode? string
--- @return boolean
local function position_intersects_extmark(pos, extmark, mode)
  local start, stop = extmark.start, extmark.stop

  -- Zero-width extmarks at cursor position are considered intersecting
  if pos == start and pos == stop then return true end

  -- Check row bounds
  if pos[1] < start[1] or pos[1] > stop[1] then return false end

  -- Check column bounds on start row
  if pos[1] == start[1] and pos[2] < start[2] then return false end

  -- Check column bounds on stop row
  if pos[1] == stop[1] then
    -- An element ending in a newline strands the cursor on the following
    -- empty line, where it has nowhere else to be; treat it as inside.
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
    local tag = self.text_content.extmark_ids_to_tag[extmark.id]
    if tag and position_intersects_extmark(pos, extmark, mode) then
      table.insert(elements, vim.tbl_extend('force', {}, tag, { extmark = extmark }))
    end
  end

  -- Sort innermost (smallest) to outermost (largest)
  sort_innermost_first(elements)

  return elements
end

--- Find an element by its id attribute.
--- @param id string
--- @return morph.Element?
function Morph:get_element_by_id(id)
  for tag, extmark_id in pairs(self.text_content.tags_to_extmark_ids) do
    if tag.attributes.id == id then
      local extmark = assert(Extmark.by_id(self.bufnr, self.ns, extmark_id))
      return vim.tbl_extend('force', {}, tag, { extmark = extmark }) --[[@as morph.Element]]
    end
  end
end

--------------------------------------------------------------------------------
-- Keypress Dispatch
--------------------------------------------------------------------------------
-- Element handlers (imap/nmap/vmap/xmap/omap) receive keypresses innermost
-- first; returning '' swallows the key, routed through the no-op operator
-- below because normal mode lacks an empty-rhs trick.

-- The no-op operator behind the normal-mode swallow: render's expr mappings
-- return 'g@ ' with this as operatorfunc, and the operator-pending no-op
-- consumes the key. Only the operatorfunc assignment happens per keypress.
function _G.MorphOpFuncNoop() end

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
-- User edits arrive through the watcher, and the guard decides what was aimed
-- at an editable region and what violated the tree.

--------------------------------------------------------------------------------
-- The Buffer Watcher
--------------------------------------------------------------------------------
-- The watcher counts user edits as they stream through nvim_buf_attach's
-- on_bytes (excluding morph's own render writes) and reports the burst once
-- TextChanged says the buffer is stable. Detection only: it reads no event
-- coordinates and carries no geometry; the consumer derives the dirty band by
-- diffing its own line snapshot against the live lines (see diff_to_band).

--- @class morph.ChangeWindow One splice's replacement region: where the
---   change's new text lives.
--- @field row0 integer
--- @field col0 integer
--- @field end_row integer
--- @field end_col integer

--- @class morph.BufWatcher
--- @field pending_edits integer User on_bytes events captured while morph was
---   not rendering, still unprocessed. Fast typing batches several into one
---   TextChanged window, judged together when it closes. Doubles as the
---   change-in-flight flag (cursor movements inside a burst belong to the
---   change, not to navigation).
--- @field cursor_sample? integer[] Last settled cursor position (win_get_cursor
---   format), the pre-edit snapshot for readonly reverts. Sampled on genuine
---   navigation, never on a change in flight.
--- @field text_changed_autocmd_id integer
--- @field cursor_moved_autocmd_id integer
--- @field cleanup fun() Remove the watcher

--- Create a buffer watcher that calls `callback` once per burst of user edits
--- (the on_bytes events between TextChanged windows) after the buffer is
--- stable. A burst need not mean the content changed (type-and-delete diffs to
--- nothing); the consumer decides against its own baseline.
--- @param bufnr integer
--- @param is_rendering fun(): boolean Whether morph is mid-render (its own writes)
--- @param callback fun() Called once per closed user-edit burst, no payload
--- @return morph.BufWatcher
local function create_buf_watcher(bufnr, is_rendering, callback)
  -- Guard: buffer API must be ready for nvim_buf_attach to work
  if not is_buffer_api_ready(bufnr) then
    error(
      'morph.nvim: Cannot create buffer watcher - buffer not yet loaded. '
        .. 'Buffer must be loaded before mounting.',
      0
    )
  end

  local watcher = { pending_edits = 0 }

  -- Count on_bytes events but judge nothing yet; only events from while morph
  -- is not rendering count as user edits, since policing morph's own writes
  -- would revert the app's legitimate re-render.
  -- NOTE: must NOT return true -- a true return from a Lua nvim_buf_listen
  -- callback DETACHES the listener (nil continues), the opposite of the C
  -- API's Boolean.
  local attach_ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(...)
      if is_rendering() then return end
      watcher.pending_edits = watcher.pending_edits + 1
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

  -- Report the closed burst once TextChanged says the buffer is stable.
  watcher.text_changed_autocmd_id = vim.api.nvim_create_autocmd(
    { 'TextChanged', 'TextChangedI', 'TextChangedP' },
    {
      buffer = bufnr,
      callback = function()
        if watcher.pending_edits == 0 then
          -- No change, or the window held only morph's own render writes
          -- (already accounted for); policing that would revert a legitimate
          -- re-render. Mixed windows still run -- the diff reads what came out.
          return
        end
        watcher.pending_edits = 0
        -- One TextChanged window is the unit of user action; the count's only
        -- job was to prove a user edit happened.
        callback()
      end,
    }
  )

  -- Track the settled cursor for readonly reverts' pre-edit snapshot: by the
  -- time TextChanged fires, nvim has already clamped the cursor, so the
  -- original is unrecoverable. Skip movements caused by a change in flight
  -- (morph's own patch, a pending edit's adjustment); sample the rest.
  watcher.cursor_moved_autocmd_id = vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    buffer = bufnr,
    callback = function()
      if is_rendering() then return end
      -- Keep the pre-edit sample while a user edit is pending.
      if watcher.pending_edits > 0 then return end
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
--- Lazily create the buffer watcher and register its cleanup hook.
function Morph:_ensure_buf_watcher()
  if self.buf_watcher then return end

  self.buf_watcher = create_buf_watcher(
    self.bufnr,
    function() return self.changing end,
    -- Called once per closed burst; the guard then reads the live lines and
    -- judges the diff band (see diff_to_band).
    function() self:_on_bytes_burst() end
  )
  table.insert(self.cleanup_hooks, self.buf_watcher.cleanup)
end

--------------------------------------------------------------------------------
-- The Guard
--------------------------------------------------------------------------------
-- Polices text changes: reverts edits that touched locked text or landed
-- outside the tree (flash + full-tree restore), attributes accepted edits to
-- the editable tags that own them, and fires their on_change handlers.
-- The frames it decides with:
--   tag.curr_text  the accepted content per tag -- the only frame the guard
--                   decides with; live extmark positions locate the text but
--                   never decide.
--   diff base        the render's line snapshot (text_content.lines); the
--                   burst's dirty region is the content diff against it
--                   (see diff_to_band).
--   watcher.cursor_sample/pending_edits  the pre-edit cursor snapshot and the
--                   pending user edit; render-owned writes open no window.

--- @private
--- Revert an edit that violated the tree: flash the touched regions, then let
--- the normal render pipeline rebuild every span from scratch (surgical repair
--- would fight extmark mark-adjustment). Runs on a scheduler tick, so it never
--- mutates the buffer mid-handler.
--- @param violated morph.TagChange[] Changed readonly tags whose extmarks get
---   flashed; empty when the edit landed outside every span.
function Morph:_revert_violation(violated)
  for _, m in ipairs(violated) do
    self:_flash_readonly(m.extmark.start, m.extmark.stop)
  end
  -- Restore the pre-edit cursor: nvim has already adjusted (and clamped) the
  -- live position by handler time.
  local restore_cursor = self.buf_watcher and self.buf_watcher.cursor_sample or nil
  local function restore()
    if not restore_cursor then return end
    local win = vim.fn.bufwinid(self.bufnr)
    if win ~= -1 then pcall(vim.api.nvim_win_set_cursor, win, restore_cursor) end
  end
  vim.schedule(function()
    -- Restore must run AFTER the revert render, which may be deferred (the
    -- default debounce is 16ms): a deferred render re-inserts the deleted text
    -- above the cursor, so restoring first leaves it a row low. Queueing it as
    -- an after-render callback lands it on whichever render actually runs.
    if self.reconciler then
      table.insert(self.reconciler.after_render_callbacks, restore)
      self.reconciler:schedule_rerender()
    elseif self.last_tree then
      self:render(self.last_tree)
      restore()
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

--- True when `inner` descends from `outer`, walking the parent links recorded
--- at render time.
--- @param inner morph.Tag
--- @param outer morph.Tag
--- @return boolean
local function is_inside(inner, outer)
  local tag = inner.parent
  while tag do
    if tag == outer then return true end
    tag = tag.parent
  end
  return false
end

--- True when some readonly tag's content changed and no changed editable tag
--- sits inside it. This is the whole guard: nesting, not position. A hole's own
--- edit explains every readonly ancestor whose growth it caused, but never an
--- editable tag it is not part of -- which is how a write over the hole's edge
--- is caught (the chrome literal is a readonly sibling with no changed editable
--- child). Example:
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
local function readonly_violated(editable, locked)
  for _, suspect in ipairs(locked) do
    local explained = false
    for _, hole in ipairs(editable) do
      if is_inside(hole.tag, suspect.tag) then
        explained = true
        break
      end
    end
    if not explained then return true end
  end
  return false
end

--- Fire one tag's on_change with the standard event shape and return the
--- (handler-mutable) event, nil when the tag has no handler. Callers hold
--- `self.textlock` across a batch of these via _with_textlock.
--- @param tag morph.Tag
--- @param text string
--- @return table? event
local function fire_tag_on_change(tag, text)
  local on_change = tag.attributes.on_change
  if not vim.is_callable(on_change) then return nil end
  local event = { text = text, bubble_up = true }
  --- @diagnostic disable-next-line: need-check-nil
  on_change(event)
  return event
end

--- @private
--- Judge one TextChanged burst -- the unit of user action, since fast typing
--- batches several edits into one window and all are already applied when it
--- fires. The dirty band is the content diff of the render's snapshot against
--- the live lines (see diff_to_band), so the guard sweeps final coordinates
--- once: collect changed tags, decide (a readonly change no editable
--- descendant explains reverts the whole tree), accept (advance expectations
--- and the diff base), then dispatch the owned edits to on_change.
function Morph:_on_bytes_burst()
  -- The watcher already drops morph's own writes at capture; this also
  -- deflects a re-entrant call during a render. Deferring is sound: the diff
  -- base stands, so the next drain re-diffs and still contains this burst.
  if self.changing then return end

  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local top0, bottom0, windows = Morph.diff_to_band(self.text_content.lines, lines)
  -- A nil band means content identical to the baseline: type-and-delete
  -- bursts land here and correctly police nothing.
  if not top0 then return end

  -- The band that judged this burst, for tests and debugging.
  self._last_band = { top0, bottom0 }

  -- A non-nil top0 guarantees all three diff returns are real; the checker
  -- cannot narrow multi-returns, so assert it.
  local editable, locked = self:_collect_changed_band(
    top0,
    bottom0 --[[@as integer]],
    windows --[[@as morph.ChangeWindow[] ]]
  )

  -- A changed readonly tag with no changed editable descendant is a
  -- violation (the edit touched locked text that no hole's edit explains).
  -- No baseline commit: the revert restores the standing snapshot, so the
  -- next drain's diff comes back empty.
  if readonly_violated(editable, locked) then
    self:_revert_violation(locked)
    return
  end

  -- No tag changed: the edit landed outside every span. The tree is the whole
  -- document, so locked apps revert that too.
  if #editable == 0 and self.readonly_default then
    self:_revert_violation {}
    return
  end

  -- Accept: advance every changed tag's expectation to its live content
  -- (editable so dispatch announces it, locked so the next burst does not
  -- re-read it as a violation), and move the diff base to the live lines.
  for _, list in ipairs { editable, locked } do
    for _, m in ipairs(list) do
      m.tag.curr_text = m.text
    end
  end
  self.text_content.lines = lines
  -- The guard just read these exact lines, so the rerender it triggers can
  -- reuse them as its diff base instead of fetching the buffer again.
  self.changedtick = vim.b[self.bufnr].changedtick

  -- Keep probe entries in step with main entries, before on_change fires.
  if self.probe then self.probe:mirror(undotree(self.bufnr).seq_cur) end

  -- A changed editable tag owns the edit: fire its on_change innermost first.
  -- The textlock defers handler-triggered re-renders, and the captured tag
  -- stays the right target even if an earlier handler updated app state.
  if #editable > 0 then
    sort_innermost_first(editable)
    self:_with_textlock(function()
      for _, m in ipairs(editable) do
        local event = fire_tag_on_change(m.tag, m.text)
        if event and not event.bubble_up then break end
      end
    end)
    -- The accepted edit's cursor move was gated out of the snapshot; refresh
    -- it so the next revert restores here.
    if self.buf_watcher and vim.fn.bufwinid(self.bufnr) ~= -1 then
      self.buf_watcher.cursor_sample = vim.api.nvim_win_get_cursor(0)
    end
    return
  end

  -- Classic apps have no locked tree: the whole buffer is the top-level tag's
  -- content, so hand the change to its on_change.
  local top = self.text_content.top_level_tag
  if not (top and vim.is_callable(top.attributes.on_change)) then return end
  local content = table.concat(lines, '\n')
  if top.curr_text == content then return end
  top.curr_text = content
  self:_with_textlock(function() fire_tag_on_change(top, content) end)
end

--- @private
--- Collect the tags whose live content differs from the tree's expectation,
--- sweeping the dirty band. Every changed tag's span intersects the band, so
--- an inclusive band query returns every candidate plus harmless neighbors;
--- comparing live text against `curr_text` is the whole change test.
--- @param top0 integer
--- @param bottom0 integer
--- @param windows morph.ChangeWindow[] the burst's change windows
--- @return morph.TagChange[] editable
--- @return morph.TagChange[] locked
function Morph:_collect_changed_band(top0, bottom0, windows)
  local editable = {} --- @type morph.TagChange[]
  local locked = {} --- @type morph.TagChange[]
  local last_row = vim.api.nvim_buf_line_count(self.bufnr) - 1
  if top0 > last_row then return editable, locked end
  -- The band's bottom may sit past the buffer end (a delete parks it there so
  -- the sweep reaches the overshooting marks), but the line read must stay in
  -- bounds.
  local band_bottom_line = vim.api.nvim_buf_get_lines(
    self.bufnr,
    math.min(bottom0, last_row),
    math.min(bottom0 + 1, last_row + 1),
    true
  )[1] or ''

  local raw = vim.api.nvim_buf_get_extmarks(
    self.bufnr,
    self.ns,
    { top0, 0 },
    { bottom0, #band_bottom_line },
    { details = true, overlap = true }
  )
  -- Sorted by position: the degenerate-span witness below matches the
  -- collapsed point against its nearest change window.
  --- @type { id: integer, tag: morph.Tag, row0: integer, col0: integer, details: vim.api.keyset.extmark_details }[]
  local marks = {}
  for _, ext in ipairs(raw) do
    local tag = self.text_content.extmark_ids_to_tag[ext[1]]
    if tag then
      table.insert(
        marks,
        { id = ext[1], tag = tag, row0 = ext[2], col0 = ext[3], details = ext[4] }
      )
    end
  end
  table.sort(marks, function(x, y)
    if x.row0 ~= y.row0 then return x.row0 < y.row0 end
    return x.col0 < y.col0
  end)

  for _i, m in ipairs(marks) do
    local end_row = (m.details and m.details.end_row) or m.row0
    local end_col = (m.details and m.details.end_col) or m.col0

    -- Read the tag's content over its LIVE marks, which are the truth under
    -- morph's gravity scheme for every shape but one: a splice that consumes a
    -- span's whole range (a same-length replace, a paste over the tail, typing
    -- into an empty hole) parks BOTH marks PAST the replacement, so the
    -- between-marks read collapses to '' while the real content sits just
    -- outside. Mount 'Search: [x]' and replace the hole's 'x' with 'y':
    --
    --   Search: [y]
    --   00000000001
    --   01234567890
    --
    -- Both hole marks land at (0,10), after the 'y'; the span reads '' though
    -- its content became 'y' at [9,10). Typing 'filter' into 'Search: []' is
    -- the same shape with more bytes (marks park at (0,15)):
    --
    --   Search: [filter]
    --   0000000000111111
    --   0123456789012345
    --
    -- Only the burst's change windows (see diff_to_band) still bracket the
    -- replacement, so the window at the collapse point is the sole witness of
    -- what the span became. A pure delete collapses the span too and its
    -- window reads '' -- correct for a fully deleted span. Widening the read
    -- for any other shape would re-import positional attribution: a typed char
    -- at a hole's tail made the shifted ']' tag report "f]".
    local collapsed = m.row0 == end_row and m.col0 == end_col
    local extmark = Extmark._from_raw(self.bufnr, m.id, m.row0, m.col0, m.details)
    local new_text
    if collapsed then
      -- Nearest window by rows first, then columns: the change that made
      -- the span degenerate is the one whose window touches its collapse
      -- point (distance zero on both axes).
      --- @type morph.ChangeWindow?, integer?, integer?
      local best, best_row_delta, best_col_delta
      for _, w in ipairs(windows) do
        local row_delta = 0
        if m.row0 < w.row0 then
          row_delta = w.row0 - m.row0
        elseif m.row0 > w.end_row then
          row_delta = m.row0 - w.end_row
        end
        local col_delta = 0
        if row_delta == 0 then
          if m.col0 < w.col0 then
            col_delta = w.col0 - m.col0
          elseif m.col0 > w.end_col then
            col_delta = m.col0 - w.end_col
          end
        end
        if
          not best
          or row_delta < best_row_delta
          or (row_delta == best_row_delta and col_delta < best_col_delta)
        then
          best, best_row_delta, best_col_delta = w, row_delta, col_delta
        end
      end
      if best then
        -- Read the replacement through the window touching the collapse: the
        -- span's own marks parked past the text, so only the window still
        -- brackets what the span became.
        local window_mark = Extmark._from_raw(self.bufnr, m.id, best.row0, best.col0, {
          end_row = best.end_row,
          end_col = best.end_col,
        })
        new_text = window_mark:_text()
      else
        new_text = ''
      end
    else
      new_text = extmark:_text()
    end
    if m.tag.curr_text ~= new_text then
      local mismatch = { extmark = extmark, tag = m.tag, text = new_text }
      if m.tag.readonly then
        table.insert(locked, mismatch)
      else
        table.insert(editable, mismatch)
      end
    end
  end
  return editable, locked
end

--------------------------------------------------------------------------------
-- PART VII -- UNDO AND REDO
--------------------------------------------------------------------------------
-- The undo probe: region-scoped undo/redo. Last of the machinery, because it
-- stands on everything before it -- regions come from the generator, writebacks
-- reuse the guard's re-placement, traversal reuses its on_change dispatch.

--------------------------------------------------------------------------------
-- The Undo Probe
--------------------------------------------------------------------------------

-- Principle: Neovim scopes undo per buffer, but the renderer wants it scoped
-- per editable region. A hidden scratch buffer owns an undo tree whose entries
-- correspond to the user's region edits, while the main buffer keeps a full
-- undo tree of chrome renders independent of traversals. A render with two
-- holes, `[aaa]` and `[bbb]`, stores the whole region set as one JSON line
-- (ids minted here; a declared `attributes.id` is used verbatim); typing into
-- either hole rewrites that line, and `u` undoes it, decodes the previous
-- line, and writes the result back into the main buffer's spans.
--
-- Two directions keep the buffers in agreement. The mirror copies the accepted
-- main edit into the probe, opening or joining a probe entry so probe entries
-- track main entries. The replay moves the probe's undo pointer (never the
-- main buffer's) and copies every region's text back, so an app chrome render
-- between `u` and `<C-r>` changes only the main tree and leaves the probe's
-- redo tip intact.
--
-- The probe keeps all regions in a single JSON line (id -> text) rather than
-- one line per region: that drops per-region extmark bookkeeping at the cost
-- of rewriting the line on every edit. Identity is resolved per render in sync
-- (declared id > stamp while the tip still matches > render order for static
-- renders > mint), so adding, removing, reordering, or swapping regions is a
-- plain id-set diff -- new ids enter at birth, orphaned ids go inert, and no
-- structural change needs a rebuild.

--- @class morph.Probe
--- @field bufnr integer The hidden probe buffer
--- @field regions { tag: morph.Tag, id: string, stamp: string? }[] Region records
---   in render order; `id` is the region's identity in stored entries (the
---   declared `attributes.id` or a minted id), and `stamp` is the reconciler's
---   hex sequence id for the node chain, matched by the next render's resolution.
--- @field private birth {[string]: string} Per-id birth text: the deepest state
---   undo reaches for a region whose id has no recorded entry.
--- @field private id_seq integer Counter for minted region ids
--- @field baseline integer Probe `seq_cur` at mount; the undo floor
--- @field last_main_seq integer Main `seq_cur` as of the last mirror/replay
--- @field entry_open boolean Whether the probe tip matches the main's current entry
--- @field private _tip_cache? {[string]: string} Last written tip states; see _texts()
local Probe = {}
Probe.__index = Probe

--- Mint a region id unused by anything the probe knows: ids claimed this sync,
--- every birth entry, and the stored tip -- the latter two keep minted ids off
--- app-declared strings that are only temporarily absent from the region set.
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

--- The region states currently stored in the probe: id -> text. The cache is
--- authoritative between writes: only _write (which refreshes it) and replay's
--- traversal (which clears it) touch the buffer, so reads never re-decode the
--- whole region set.
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
--- current one (`undojoin` merges into the previous entry; touching
--- `&undolevels` forces a fresh one).
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
--- `sync` resolves identities from the very first render.
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
--- 1. A declared `attributes.id` is used as-is (no content check), so app-side
---    text normalization cannot break history.
--- 2. A node carrying a reconciler stamp inherits the id recorded for that
---    stamp -- but only while the stored tip still describes the region, which
---    is what makes refills safe (a swap or prepend fails the check and remints
---    instead of inheriting foreign history).
--- 3. A node with no stamp comes from a static render, so it matches by render
---    order under the same tip-equality rule.
--- Anything unresolved mints with its current text as birth. A region that
--- disappears needs no handling -- its history simply stops being referenced.
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

--- Mirror the accepted main-buffer edit into the probe: open a new probe entry
--- exactly when the main buffer did (its `seq_cur` advanced since the last
--- mirror batch), join otherwise.
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
    -- `:undo N` addresses an absolute undo state, not a step count. Clamp into
    -- [baseline, seq_last]: below the floor loses the mount state, above the
    -- tip is undefined.
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
  -- Undo moved the probe's content out from under the tip cache.
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
--- Install buffer-local mappings that reroute traversal keys through the probe:
--- `u`/`<C-r>`/`g-`/`g+` move the probe's undo pointer and write region text
--- back rather than traversing the main buffer's chrome-contaminated tree.
--- Called after `restore_buffer_keymaps`, which wipes buffer keymaps each render.
function Morph:_install_probe_keymaps()
  local opts = { buffer = self.bufnr, nowait = true, silent = true }
  local traversal_keys = { u = 'undo', ['g-'] = 'undo', ['<C-r>'] = 'redo', ['g+'] = 'redo' }
  for lhs, direction in pairs(traversal_keys) do
    vim.keymap.set('n', lhs, function() self:_probe_traverse(direction) end, opts)
  end
end

--- @private
--- Intercept the ex-command traversal forms (`:undo`, `:redo`, `:earlier`,
--- `:later`), which cannot be shadowed by buffer-local user commands because
--- Neovim rejects lowercase user command names; a `CmdlineLeave` handler
--- detects the pending command and redirects it before it runs. Parsing goes
--- through `nvim_parse_cmd`, so recognition is by command name and arguments
--- rather than string matching, and a count or range is honored. Installed on
--- the first render and self-gated thereafter; it also gates on whether the
--- current buffer has a live probe.
function Morph:_install_probe_cmdline()
  if self._probe_cmdline_autocmd then return end
  -- The id is the handle: teardown deletes it, so no augroup is needed.
  self._probe_cmdline_autocmd = vim.api.nvim_create_autocmd('CmdlineLeave', {
    callback = function()
      -- Only act while this instance's buffer is current and a probe exists.
      if vim.api.nvim_get_current_buf() ~= self.bufnr or not self.probe then return end
      local ok, parsed = pcall(vim.api.nvim_parse_cmd, vim.fn.getcmdline(), {})
      local spec = ok and parsed and TRAVERSALS[parsed.cmd]
      if not spec then return end

      -- `:undo N`/`:redo N` address an absolute undo state; `:earlier N`/
      -- `:later N` count N relative steps. A bare `:undo`/`:redo` has no count
      -- (nil on newer Neovim, 0 on older), so only a positive count is an
      -- absolute target; the relative forms carry their step count as the
      -- first argument.
      local absolute = spec.absolute and type(parsed.count) == 'number' and parsed.count > 0
      -- nvim_parse_cmd reports counts as numbers, and the relative forms carry
      -- their step count as a string argument.
      local raw = absolute and parsed.count or tonumber(parsed.args and parsed.args[1] or '')
      local steps = math.max(1, math.floor(raw or 1))

      -- Neutralize the pending command so Neovim's own traversal never runs
      -- (rewriting the command line shadows the builtin), then replay the
      -- probe once the command line has closed.
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
--- Writing a region back also fires its `on_change`, so the app re-syncs state
--- and any chrome embedding the region text re-renders to match.
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
    -- Entries that predate a region's id have nothing to say about it; the id's
    -- birth text is the deepest state undo reaches for the region.
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
    -- drag the contained region's marks to the parent's start.
    if not extmark or extmark:_text() ~= change.text then
      self:_write_region_text(change.tag, change.text)
    end
  end
  self.changing = false

  -- Fire the changed regions' on_change so app state (and any chrome that
  -- embeds the region text) re-syncs with the reverted content.
  self:_with_textlock(function()
    for _, change in ipairs(changed) do
      fire_tag_on_change(change.tag, change.text)
    end
  end)
end

--- @private
--- Hold `self.textlock` across `fn` so handler-triggered re-renders defer
--- instead of mutating extmark spans mid-dispatch (see fire_tag_on_change).
--- @param fn fun()
function Morph:_with_textlock(fn)
  local prev_textlock = self.textlock
  self.textlock = true
  fn()
  self.textlock = prev_textlock
end

--- @private
--- The live extmark for a region tag, if the tag is still part of the render.
--- @param tag morph.Tag
--- @return morph.Extmark?
function Morph:_region_extmark(tag)
  local id = self.text_content.tags_to_extmark_ids[tag]
  return id and Extmark.by_id(self.bufnr, self.ns, id)
end

--- @private
--- Replace one region's main-buffer text with `text` and re-place its extmark
--- over the new span. Re-placing keeps the span exact: a replacement collapses
--- the mark to zero width, so the guard would otherwise read an empty span next
--- batch.
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
  -- Re-place through the shared extmark builder so gravity semantics stay
  -- defined in one place.
  Extmark.new(self.bufnr, self.ns, extmark.start, Pos00.new(end_row, end_col), { id = extmark.id })
  tag.curr_text = text
end

--- @private
--- Delete the probe buffer and drop the reference. Every path that stops using a
--- probe -- disengagement, a structural region-set change, unmount, buffer wipe
--- -- funnels through here, so the hidden buffer and its undo tree never
--- outlive their region set.
function Morph:_teardown_probe()
  if self.probe and vim.api.nvim_buf_is_valid(self.probe.bufnr) then
    vim.api.nvim_buf_delete(self.probe.bufnr, { force = true })
  end
  self.probe = nil
end

--- @private
--- Build or refresh the undo probe after a render (region set in DFS order).
--- Entries are keyed by region id, so every structural change -- add, remove,
--- reorder, swap -- is an id-set diff rather than a rebuild trigger: regions
--- that keep their id keep their history, an unidentifiable region mints a
--- fresh id whose history starts at its current text, and a removed region's
--- history goes inert.
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
-- Components and hook helpers built on the public surface user code sees:
-- nothing here reaches into private state. FloatingWindow depends on Portal and
-- on the hook helpers, so read the hooks first.

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
-- One small, self-contained utility FloatingWindow uses: a mode transition
-- confirmed by autocmd rather than a timer.

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
  -- ModeChanged autocmd: a nested action (e.g. on_closed opening another float
  -- that startinserts) would otherwise run while the mode transition is still
  -- on the autocmd stack, and its startinsert would not stick.
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
--- @field prev_open boolean
--- @field prev_config? vim.api.keyset.win_config

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
      prev_open = false,
      prev_config = nil,
    }
  end

  --- @type components.FloatingWindowState
  local state = assert(ctx.state)
  local config = ctx.props.config
  if type(config) == 'function' then config = config() end
  -- Capture the previous render's values, then store this render's, so the
  -- transition branches below compare against what the user last saw.
  local prev_open, prev_config = state.prev_open, state.prev_config
  state.prev_open, state.prev_config = open, config

  --- Shared open→closed teardown for both the prop-driven close transition and
  --- unmount. Restores the previous window/cursor (if alive), transitioning back
  --- to the captured mode first when the float still holds focus; never steals
  --- focus back. On unmount also tears down the resize autocmd and float buffer.
  --- on_closed fires only for a real transition (prev_open true).
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
        if not vim.deep_equal(config, prev_config) then
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
