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

function _G.MorphOpFuncNoop() end

local H = {}

--------------------------------------------------------------------------------
-- Type Definitions
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

--- An element is an instantiated Tag
--- @class morph.Element : morph.Tag
--- @field extmark morph.Extmark

--- @alias morph.Node nil | boolean | string | morph.Tag
--- @alias morph.Tree morph.Node | morph.Node[]
--- @alias morph.Component<TProps, TState> fun(ctx: morph.Ctx<TProps, TState>): morph.Tree

--------------------------------------------------------------------------------
-- h: Hyper-script Utility
--------------------------------------------------------------------------------

H.h = setmetatable({}, {
  --- @param name 'text' | morph.Component
  --- @param attributes? morph.TagAttributes
  --- @param children? morph.Tree
  __call = function(_, name, attributes, children)
    return {
      kind = 'tag',
      name = name,
      attributes = attributes or {},
      children = children or {},
    }
  end,

  --- @param hl string
  __index = function(_, hl)
    --- @param attributes? morph.TagAttributes
    --- @param children? morph.Tree
    return function(attributes, children)
      return H.h(
        'text',
        vim.tbl_deep_extend('force', { hl = hl }, attributes or {}),
        children or {}
      )
    end
  end,
}) --[[@as table<string, fun(attributes?: morph.TagAttributes, children?: morph.Tree): morph.Tag> & fun(name: string | morph.Component, attributes?: morph.TagAttributes, children?: morph.Tree): morph.Tag>]]

--------------------------------------------------------------------------------
-- class Pos00
--------------------------------------------------------------------------------

--- @class morph.Pos00
--- @field [1] integer 0-based row
--- @field [2] integer 0-based column
local Pos00 = {}
Pos00.__index = Pos00

--- @param row integer
--- @param col integer
function Pos00.new(row, col) return setmetatable({ row, col }, Pos00) end
--- @param other morph.Pos00
function Pos00:__eq(other) return self[1] == other[1] and self[2] == other[2] end
--- @param other morph.Pos00
function Pos00:__lt(other) return self[1] < other[1] or (self[1] == other[1] and self[2] < other[2]) end
--- @param other morph.Pos00
function Pos00:__gt(other) return self[1] > other[1] or (self[1] == other[1] and self[2] > other[2]) end

--------------------------------------------------------------------------------
-- class Extmark
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

--- @param bufnr integer
--- @param ns integer
--- @param start morph.Pos00
--- @param stop morph.Pos00
--- @param opts vim.api.keyset.set_extmark
--- @return morph.Extmark
function Extmark.new(bufnr, ns, start, stop, opts)
  local id = vim.api.nvim_buf_set_extmark(
    bufnr,
    ns,
    start[1],
    start[2],
    vim.tbl_extend('force', {
      end_row = stop[1],
      end_col = stop[2],
      right_gravity = false,
      end_right_gravity = true,
    }, opts)
  )
  return setmetatable(
    { id = id, start = start, stop = stop, raw = opts, ns = ns, bufnr = bufnr },
    Extmark
  )
end

--- @private
--- @param bufnr integer
--- @param ns integer
--- @param id integer
--- @param start_row0 integer
--- @param start_col0 integer
--- @param details vim.api.keyset.extmark_details
--- @return morph.Extmark
function Extmark._from_raw(bufnr, ns, id, start_row0, start_col0, details)
  local start = Pos00.new(start_row0, start_col0)
  local stop = Pos00.new(start_row0, start_col0)
  if details and details.end_row ~= nil and details.end_col ~= nil then
    stop = Pos00.new(details.end_row --[[@as integer]], details.end_col --[[@as integer]])
  end

  local extmark = setmetatable({
    id = id,
    start = start,
    stop = stop,
    raw = details,
    ns = ns,
    bufnr = bufnr,
  }, Extmark)

  -- Normalize extmark ending-bounds:
  local buf_max_line0 = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
  if extmark.stop[1] > buf_max_line0 then
    local last_line = vim.api.nvim_buf_get_lines(bufnr, buf_max_line0, buf_max_line0 + 1, true)[1]
      or ''
    extmark.stop = Pos00.new(buf_max_line0, last_line:len())
  end

  return extmark
end

--- @param bufnr integer
--- @param ns integer
--- @param id integer
function Extmark.by_id(bufnr, ns, id)
  local raw_extmark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
  if not raw_extmark then return nil end
  local start_row0, start_col0, details = unpack(raw_extmark)
  return Extmark._from_raw(bufnr, ns, id, start_row0, start_col0, assert(details))
end

--- @private
--- @param bufnr integer
--- @param ns integer
--- @param start morph.Pos00
--- @param stop morph.Pos00
--- @return morph.Extmark[]
function Extmark._get_near_overshoot(bufnr, ns, start, stop)
  return vim
    .iter(
      vim.api.nvim_buf_get_extmarks(
        bufnr,
        ns,
        { start[1], start[2] },
        { stop[1], stop[2] },
        { details = true, overlap = true }
      )
    )
    :map(function(ext)
      --- @type integer, integer, integer, any|nil
      local id, line0, col0, details = unpack(ext)
      return Extmark._from_raw(bufnr, ns, id, line0, col0, assert(details))
    end)
    :totable()
end

--------------------------------------------------------------------------------
-- class Ctx
--------------------------------------------------------------------------------

--- @generic TProps
--- @generic TState
--- @class morph.Ctx<TProps, TState>
--- @field document? morph.Morph
--- @field phase 'mount'|'update'|'unmount'
--- @field props TProps
--- @field state? TState
--- @field children morph.Tree
--- @field private on_change? fun(): any
--- @field private prev_rendered_children? morph.Tree
local Ctx = {}
Ctx.__index = Ctx

--- @param document? morph.Morph
--- @param props TProps
--- @param state? TState
--- @param children morph.Tree
function Ctx.new(document, props, state, children)
  return setmetatable({
    document = document,
    phase = 'mount',
    props = props,
    state = state,
    children = children,
  }, Ctx)
end

--- @param new_state TState
function Ctx:update(new_state)
  self.state = new_state
  if self.on_change and self.phase ~= 'mount' then
    if H.is_textlock() then
      vim.schedule(function() self.on_change() end)
    else
      self.on_change()
    end
  end
end

--------------------------------------------------------------------------------
-- class Morph
--------------------------------------------------------------------------------

--- @alias morph.MorphTextState {
---   lines: string[],
---   extmarks: morph.Extmark[],
---   tags_to_extmark_ids: table<morph.Tag, integer?>,
---   extmark_ids_to_tag: table<integer, morph.Tag?>
--- }

--- @class morph.Morph
--- @field bufnr integer
--- @field ns integer
--- @field changedtick integer
--- @field changing boolean
--- @field text_content { old: morph.MorphTextState, curr: morph.MorphTextState }
--- @field component_tree { old: morph.Tree  }
local Morph = {}
Morph.__index = Morph

--------------------------------------------------------------------------------
-- class Morph: Static functions
--------------------------------------------------------------------------------

-- TODO: public API Pos00
--- @param opts {
---   tree: morph.Tree,
---   on_tag?: fun(tag: morph.Tag, start0: morph.Pos00, stop0: morph.Pos00): any
--- }
function Morph.markup_to_lines(opts)
  --- @type string[]
  local lines = {}

  local curr_line1 = 1
  local curr_col1 = 1 -- exclusive: sits one position **beyond** the last inserted text
  --- @param s string
  local function put(s)
    lines[curr_line1] = (lines[curr_line1] or '') .. s
    curr_col1 = #lines[curr_line1] + 1
  end
  local function put_line()
    table.insert(lines, '')
    curr_line1 = curr_line1 + 1
    curr_col1 = 1
  end

  --- @param node morph.Tree
  local function visit(node)
    H.tree_match(node, {
      string = function(s_node)
        local node_lines = vim.split(s_node, '\n')
        for line_num, s in ipairs(node_lines) do
          if line_num > 1 then put_line() end
          put(s)
        end
      end,
      array = function(ts)
        for _, child in ipairs(ts) do
          visit(child)
        end
      end,
      tag = function(t)
        local start0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)
        visit(t.children)
        local stop0 = Pos00.new(curr_line1 - 1, curr_col1 - 1)

        if opts.on_tag then opts.on_tag(t, start0, stop0) end
      end,
      component = function(Component, t)
        local ctx = Ctx.new(nil, t.attributes, nil, t.children)

        local start = Pos00.new(curr_line1 - 1, curr_col1 - 1)
        visit(Component(ctx))
        local stop = Pos00.new(curr_line1 - 1, curr_col1 - 1)

        ctx.phase = 'unmount'
        Component(ctx)

        if opts.on_tag then opts.on_tag(t, start, stop) end
      end,
    })
  end
  visit(opts.tree)

  return lines
end

--- @param opts {
---   tree: morph.Tree,
---   format_tag?: fun(tag: morph.Tag): string
--- }
function Morph.markup_to_string(opts) return table.concat(Morph.markup_to_lines(opts), '\n') end

--- @param bufnr integer
--- @param old_lines string[] | nil
--- @param new_lines string[]
function Morph.patch_lines(bufnr, old_lines, new_lines)
  --
  -- Helpers:
  --

  --- @param start integer
  --- @param end_ integer
  --- @param strict_indexing boolean
  --- @param replacement string[]
  local function _set_lines(start, end_, strict_indexing, replacement)
    vim.api.nvim_buf_set_lines(bufnr, start, end_, strict_indexing, replacement)
  end

  --- @param start_row integer
  --- @param start_col integer
  --- @param end_row integer
  --- @param end_col integer
  --- @param replacement string[]
  local function _set_text(start_row, start_col, end_row, end_col, replacement)
    vim.api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, replacement)
  end

  -- Morph the text to the desired state:
  local line_changes = (
    H.levenshtein {
      from = old_lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      to = new_lines,
    }
  ) --[[@as (morph.LevenshteinChange<string>[])]]

  for _, line_change in ipairs(line_changes) do
    local line_num0 = line_change.index - 1

    if line_change.kind == 'add' then
      _set_lines(line_num0, line_num0, true, { line_change.item })
    elseif line_change.kind == 'change' then
      -- Compute inter-line diff, and apply:
      local col_changes = (
        H.levenshtein {
          from = vim.split(line_change.from, ''),
          to = vim.split(line_change.to, ''),
        }
      ) --[[@as (morph.LevenshteinChange<string>[])]]

      for _, col_change in ipairs(col_changes) do
        local col_num0 = col_change.index - 1
        if col_change.kind == 'add' then
          _set_text(line_num0, col_num0, line_num0, col_num0, { col_change.item })
        elseif col_change.kind == 'change' then
          _set_text(line_num0, col_num0, line_num0, col_num0 + 1, { col_change.to })
        elseif col_change.kind == 'delete' then
          _set_text(line_num0, col_num0, line_num0, col_num0 + 1, {})
        else
          -- No change
        end
      end
    elseif line_change.kind == 'delete' then
      _set_lines(line_num0, line_num0 + 1, true, {})
    else
      -- No change
    end
  end
end

--- @param bufnr integer|nil
function Morph.new(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end

  if vim.b[bufnr]._renderer_ns == nil then
    vim.b[bufnr]._renderer_ns = vim.api.nvim_create_namespace('my.renderer:' .. tostring(bufnr))
  end

  local self = setmetatable({
    bufnr = bufnr,
    ns = vim.b[bufnr]._renderer_ns,
    changedtick = 0,
    changing = false,
    text_content = {
      old = { lines = {}, extmarks = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
      curr = { lines = {}, extmarks = {}, tags_to_extmark_ids = {}, extmark_ids_to_tag = {} },
    },
    component_tree = {
      old = nil,
      curr = nil,
      ctx_by_node = {},
    },
  }, Morph)

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
    buffer = bufnr,
    callback = function() self:_on_text_changed() end,
  })

  return self
end

--------------------------------------------------------------------------------
-- class Morph: Instance methods
--------------------------------------------------------------------------------

--- Render static markup
--- @param tree morph.Tree
function Morph:render(tree)
  local changedtick = vim.b[self.bufnr].changedtick
  if changedtick ~= self.changedtick then
    self.text_content.curr = {
      extmarks = {},
      lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false),
      tags_to_extmark_ids = {},
      extmark_ids_to_tag = {},
    } --[[@as morph.MorphTextState]]
    self.changedtick = changedtick
  end

  -- Extmarks have to correlate to actual text, so we have to accumulate which
  -- ones we want to set, morph the buffer, then set the extmarks:
  --- @type { tag: morph.Tag, start: morph.Pos00, stop: morph.Pos00, opts: any }[]
  local extmarks_to_set = {}

  --- @type string[]
  local lines = Morph.markup_to_lines {
    tree = tree,

    on_tag = function(tag, start, stop)
      if tag.name == 'text' then
        local hl = tag.attributes.hl
        if type(hl) == 'string' then
          tag.attributes.extmark = tag.attributes.extmark or {}
          tag.attributes.extmark.hl_group = tag.attributes.extmark.hl_group or hl
        end

        table.insert(extmarks_to_set, {
          tag = tag,
          start = start,
          stop = stop,
          opts = tag.attributes.extmark or {},
        })

        -- Set any necessary key-maps:
        for _, mode in ipairs { 'i', 'n', 'v', 'x', 'o' } do
          for lhs, _ in pairs(tag.attributes[mode .. 'map'] or {}) do
            -- Force creating an extmark if there are key handlers. To accurately
            -- sense the bounds of the text, we need an extmark:
            vim.keymap.set(mode, lhs, function()
              local result = self:_expr_map_callback(mode, lhs)
              -- If the handler indicates that it wants to swallow the event,
              -- we have to convert that intention into something compatible
              -- with expr-mappings, which don't support '<Nop>' (they try to
              -- execute the literal characters). We'll use the 'g@' operator
              -- to do that, forwarding the event to an operatorfunc that does
              -- nothing:
              if result == '' then
                if mode == 'i' then
                  return ''
                else
                  vim.go.operatorfunc = 'v:lua.MorphOpFuncNoop'
                  return 'g@ '
                end
              end
              return result
            end, { buffer = self.bufnr, expr = true, replace_keycodes = true })
          end
        end
      end
    end,
  }

  self.text_content.old = self.text_content.curr
  self.text_content.curr = {
    lines = lines,
    extmarks = {},
    tags_to_extmark_ids = {},
    extmark_ids_to_tag = {},
  }

  -- Step 1: morph the buffer content:
  self.changing = true
  Morph.patch_lines(self.bufnr, self.text_content.old.lines, self.text_content.curr.lines)
  self.changing = false
  self.changedtick = vim.b[self.bufnr].changedtick

  -- Step 1: apply the new extmarks:
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)
  local bookkeeping = self.text_content.curr
  for _, extmark_to_set in ipairs(extmarks_to_set) do
    local tag = extmark_to_set.tag
    local extmark = Extmark.new(
      self.bufnr,
      self.ns,
      extmark_to_set.start,
      extmark_to_set.stop,
      extmark_to_set.opts
    )
    bookkeeping.extmark_ids_to_tag[extmark.id] = tag
    bookkeeping.tags_to_extmark_ids[tag] = extmark.id
    table.insert(bookkeeping.extmarks, extmark)
  end
end

--- Render a component tree
--- @param tree morph.Tree
function Morph:mount(tree)
  local function rerender()
    local H2 = {}

    --- @param tree morph.Tree
    function H2.unmount(tree)
      --- @param tree morph.Tree
      local function visit(tree)
        H.tree_match(tree, {
          array = function(tags)
            for _, tag in ipairs(tags) do
              visit(tag)
            end
          end,
          tag = function(tag) visit(tag.children) end,
          component = function(Component, tag)
            --- @type morph.Ctx
            local ctx = assert(tag.ctx, 'could not find context for node')

            -- depth-first:
            visit(ctx.children)

            -- now unmount current:
            ctx.phase = 'unmount'
            Component(ctx)
            ctx.on_change = nil
          end,
        })
      end

      visit(tree)
    end

    --- @param old_tree morph.Tree
    --- @param new_tree morph.Tree
    --- @return morph.Tree
    function H2.visit_tree(old_tree, new_tree)
      local old_tree_kind = H.tree_kind(old_tree)
      local new_tree_kind = H.tree_kind(new_tree)

      local new_tree_rendered = H.tree_match(new_tree, {
        string = function(s) return s end,
        boolean = function(b) return b end,
        nil_ = function() return nil end,

        array = function(new_arr)
          return H2.visit_array(old_tree --[[@as any]], new_arr)
        end,
        tag = function(new_tag)
          local old_children = old_tree_kind == new_tree_kind and old_tree.children or nil
          return H.h(
            new_tag.name,
            new_tag.attributes,
            H2.visit_tree(old_children --[[@as any]], new_tag.children --[[@as any]])
          )
        end,

        component = function(NewC, new_tag)
          --- @type { tag: morph.Tag, ctx?: morph.Ctx } | nil
          local old_component_info = H.tree_match(
            old_tree,
            { component = function(_, t) return { tag = t, ctx = t.ctx } end }
          )
          local ctx = old_component_info and old_component_info.ctx or nil

          if not ctx then
            --- @type morph.Ctx
            ctx = Ctx.new(self, new_tag.attributes, nil, new_tag.children)
          else
            ctx.phase = 'update'
          end
          ctx.props = new_tag.attributes
          ctx.children = new_tag.children
          ctx.on_change = rerender

          new_tag.ctx = ctx
          local NewC_rendered_children = NewC(ctx)
          local result = H2.visit_tree(ctx.prev_rendered_children, NewC_rendered_children)
          ctx.prev_rendered_children = NewC_rendered_children
          -- As soon as we've mounted, move past the 'mount' state. This is
          -- because Ctx will not fire `on_update` if it is still in the
          -- 'mount' state (to avoid stack overflows).
          ctx.phase = 'update'

          return result
        end,
      })

      if old_tree_kind ~= new_tree_kind then H2.unmount(old_tree) end

      return new_tree_rendered
    end

    --- @param old_arr morph.Node[]
    --- @param new_arr morph.Node[]
    --- @return morph.Node[]
    function H2.visit_array(old_arr, new_arr)
      --- @return string
      local function verbose_tree_kind(tree, idx)
        return H.tree_match(tree, {
          nil_ = function() return 'nil' end,
          string = function() return 'string' end,
          boolean = function() return 'boolean' end,
          array = function() return 'array' end,
          tag = function(tag)
            return ('tag-%s-%s'):format(tag.name, tostring(tag.attributes.key or idx))
          end,
          component = function(C, tag)
            return ('component-%s-%s'):format(C, tostring(tag.attributes.key or idx))
          end,
        })
      end

      -- We are going to hijack levenshtein in order to compute the
      -- difference between elements/components. In this model, we need to
      -- "update" all the nodes, so no nodes are equal. We will rely on
      -- levenshtein to find the "shortest path" to conforming old => new via
      -- the cost.of_change function. That will provide the meat of modeling
      -- what effort it will take to morph one element into the new form.
      -- What levenshtein gives us for free in this model is also informing
      -- us what needs to be added (i.e., "mounted"), what needs to be
      -- deleted ("unmounted") and what needs to be changed ("updated").
      local changes = (
        H.levenshtein {
          --- @diagnostic disable-next-line: assign-type-mismatch
          from = old_arr or {},
          to = new_arr or {},
          are_equal = function() return false end,
          cost = {
            of_change = function(node1, node2, node1_idx, node2_idx)
              local node1_inf = verbose_tree_kind(node1, node1_idx)
              local node2_inf = verbose_tree_kind(node2, node2_idx)
              return node1_inf == node2_inf and 1 or 2
            end,
          },
        }
      ) --[[@as (morph.LevenshteinChange<morph.Node>[])]]

      --- @type morph.Node[]
      local resulting_nodes = {}

      for _, change in ipairs(changes) do
        local resulting_node
        if change.kind == 'add' then
          -- add => mount
          resulting_node = H2.visit_tree(nil, change.item)
        elseif change.kind == 'delete' then
          -- delete => unmount
          H2.visit_tree(change.item, nil)
        elseif change.kind == 'change' then
          -- change is either:
          -- - unmount, then mount
          -- - update
          local from_kind = verbose_tree_kind(change.from)
          local to_kind = verbose_tree_kind(change.to)
          if from_kind == to_kind then
            resulting_node = H2.visit_tree(change.from, change.to)
          else
            -- from_kind ~= to_kind: unmount/mount
            H2.unmount(change.from)
            resulting_node = H2.visit_tree(nil, change.to)
          end
        end

        if resulting_node then table.insert(resulting_nodes, 1, resulting_node) end
      end

      return resulting_nodes
    end

    local simplified_tree = H2.visit_tree(self.component_tree.old, tree)
    self.component_tree.old = tree
    self:render(simplified_tree)
  end

  -- Kick off initial render:
  rerender()
end

--- @param pos [integer, integer]|morph.Pos00
--- @param mode string?
--- @return morph.Element[]
function Morph:get_elements_at(pos, mode)
  pos = Pos00.new(pos[1], pos[2])
  if not mode then mode = vim.api.nvim_get_mode().mode end
  mode = mode:sub(1, 1) -- we don't care about sub-modes

  --- @type morph.Element[]
  local intersecting_elements = vim
    --
    -- The cursor (block) occupies **two** extmark spaces: one for it's left
    -- edge, and one for it's right. We need to do our own intersection test,
    -- because the Neovim API is over-inclusive in what it returns:
    .iter(Extmark._get_near_overshoot(self.bufnr, self.ns, pos, pos))
    --
    -- First, convert the list of extmarks to Elements:
    :map(
      --- @param ext morph.Extmark
      function(extmark)
        local tag = assert(self.text_content.curr.extmark_ids_to_tag[extmark.id])
        return vim.tbl_extend('force', {}, tag, { extmark = extmark })
      end
    )
    --
    -- Now do our own custom intersection test:
    :filter(
      --- @param elem morph.Element
      function(elem)
        local ext = elem.extmark
        if ext.stop[1] ~= nil and ext.stop[2] ~= nil then
          -- If we've "ciw" and "collapsed" an extmark onto the cursor,
          -- the cursor pos will equal the extmark's start AND end. In this
          -- case, we want to include the extmark.
          if pos == ext.start and pos == ext.stop then return true end

          return
            -- START: line check
            pos[1] >= ext.start[1]
              -- START: column check
              and (pos[1] ~= ext.start[1] or pos[2] >= ext.start[2])
              -- STOP: line check
              and pos[1] <= ext.stop[1]
              -- STOP: column check
              and (
                pos[1] ~= ext.stop[1]
                or (
                  mode == 'i'
                    -- In insert mode, the cursor is "thin", so <= to compensate:
                    and pos[2] <= ext.stop[2]
                  -- In normal mode, the cursor is "wide", so < to compensate:
                  or pos[2] < ext.stop[2]
                )
              )
        else
          return true
        end
      end
    )
    :totable()

  -- Sort the tags into smallest (inner) to largest (outer):
  table.sort(intersecting_elements, function(e1, e2)
    local x1, x2 = e1.extmark, e2.extmark
    if x1.start == x2.start and x1.stop == x2.stop then return x1.id < x2.id end
    return x1.start >= x2.start and x1.stop <= x2.stop
  end)

  return intersecting_elements
end

--- @param id string
--- @return morph.Element?
function Morph:get_element_by_id(id)
  for tag, _ in pairs(self.text_content.curr.tags_to_extmark_ids) do
    local extmark_id = assert(self.text_content.curr.tags_to_extmark_ids[tag])
    local extmark = assert(Extmark.by_id(self.bufnr, self.ns, extmark_id))
    if tag.attributes.id == id then
      return vim.tbl_extend('force', {}, tag, { extmark = extmark }) --[[@as morph.Element]]
    end
  end
end

--- @private
--- @param mode string
--- @param lhs string
function Morph:_expr_map_callback(mode, lhs)
  -- find the tag with the smallest intersection that contains the cursor:
  local pos0 = vim.api.nvim_win_get_cursor(0)
  pos0[1] = (
    pos0[1]--[[@cast -?]]
    - 1
  ) -- make it actually 0-based
  local elements = self:get_elements_at(pos0)

  if #elements == 0 then return lhs end

  -- Find the first tag that is listening for this event:
  local keypress_cancel = false
  --- @type { bubble_up: boolean }
  local loop_control = { bubble_up = true }
  for _, elem in ipairs(elements) do
    if loop_control.bubble_up then
      -- is the tag listening?
      --- @type morph.TagEventHandler?
      local f = vim.tbl_get(elem.attributes, mode .. 'map', lhs)
      if vim.is_callable(f) then
        local e = { tag = elem, mode = mode, lhs = lhs, bubble_up = true }
        --- @diagnostic disable-next-line: need-check-nil
        local result = f(e)
        loop_control.bubble_up = e.bubble_up
        if result == '' then
          -- bubble-up to the next tag, but set cancel to true, in case there are
          -- no more tags to bubble up to:
          keypress_cancel = true
        else
          return result
        end
      end
    end
  end

  -- Resort to default behavior:
  return keypress_cancel and '' or lhs
end

--- @private
function Morph:_on_text_changed()
  if self.changing or self.changedtick == vim.b[self.bufnr].changedtick then return end

  -- Reset changedtick, so that the reconciler knows to refresh its cached
  -- buffer-content before computing the diff:
  self.changedtick = 0

  local l, c = unpack(vim.api.nvim_win_get_cursor(0))
  l = assert(l) - 1 -- make it actually 0-based
  local elements = self:get_elements_at(Pos00.new(l, assert(c)), 'i')
  --- @type { bubble_up: boolean }
  local loop_control = { bubble_up = true }
  for _, elem in ipairs(elements) do
    if loop_control.bubble_up then
      local on_change = elem.attributes.on_change
      if vim.is_callable(on_change) then
        if elem.extmark.start == elem.extmark.stop then
          local e = { text = '', bubble_up = true }
          --- @diagnostic disable-next-line: need-check-nil
          on_change(e)
          loop_control.bubble_up = e.bubble_up
          return -- TODO
        end

        local pos1 = { self.bufnr, elem.extmark.start[1] + 1, elem.extmark.start[2] + 1 }
        local pos2 = { self.bufnr, elem.extmark.stop[1] + 1, elem.extmark.stop[2] }
        local ok, lines = pcall(vim.fn.getregion, pos1, pos2, { type = 'v' })
        if not ok then
          vim.api.nvim_echo({
            { '(morph.nvim:getregion:invalid-pos) ', 'ErrorMsg' },
            {
              '{ start, end } = ' .. vim.inspect({ pos1, pos2 }, { newline = ' ', indent = '' }),
            },
          }, true, {})
          error(lines)
        end
        if type(lines) == 'string' then lines = { lines } end

        local e = { text = table.concat(lines, '\n'), bubble_up = true }
        --- @diagnostic disable-next-line: need-check-nil
        on_change(e)
        loop_control.bubble_up = e.bubble_up
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

--- @param tree morph.Tree
--- @param visitors {
---   nil_?: (fun(): any),
---   boolean?: (fun(b: boolean): any),
---   string?: (fun(s: string): any),
---   array?: (fun(tags: morph.Node[]): any),
---   tag?: (fun(tag: morph.Tag): any),
---   component?: (fun(component: morph.Component, tag: morph.Tag): any),
---   unknown?: fun(tag: any): any
--- }
function H.tree_match(tree, visitors)
  local function is_tag(x) return type(x) == 'table' and x.kind == 'tag' end
  local function is_tag_arr(x) return type(x) == 'table' and not is_tag(x) end

  if tree == nil or tree == vim.NIL then
    return visitors.nil_ and visitors.nil_() or nil
  elseif type(tree) == 'boolean' then
    return visitors.boolean and visitors.boolean(tree) or nil
  elseif type(tree) == 'string' then
    return visitors.string and visitors.string(tree) or nil
  elseif is_tag_arr(tree) then
    return visitors.array and visitors.array(tree --[[@as any]]) or nil
  elseif is_tag(tree) then
    local tag = tree --[[@as morph.Tag]]
    if vim.is_callable(tag.name) then
      return visitors.component and visitors.component(tag.name --[[@as function]], tag) or nil
    else
      return visitors.tag and visitors.tag(tree --[[@as any]]) or nil
    end
  else
    return visitors.unknown and visitors.unknown(tree) or error 'unknown value: not a tag'
  end
end

--- @param tree morph.Tree
--- @return 'nil' | 'boolean' | 'string' | 'array' | 'tag' | morph.Component | 'unknown'
function H.tree_kind(tree)
  return H.tree_match(tree, {
    nil_ = function() return 'nil' end,
    boolean = function() return 'boolean' end,
    string = function() return 'string' end,
    array = function() return 'array' end,
    tag = function() return 'tag' end,
    component = function(c) return c end,
    unknown = function() return 'unknown' end,
  }) --[[@as any]]
end

function H.is_textlock()
  if vim.in_fast_event() then return true end

  local curr_win = vim.api.nvim_get_current_win()

  -- Try to change the window: if textlock is active, an error will be raised:
  local tmp_buf = vim.api.nvim_create_buf(false, true)
  local ok, tmp_win = pcall(vim.api.nvim_open_win, tmp_buf, true, {})
  if
    not ok
    and type(tmp_win) == 'string'
    and tmp_win:find 'E565: Not allowed to change text or change window'
  then
    pcall(vim.api.nvim_buf_delete, tmp_buf, { force = true })
    return true
  end

  pcall(vim.api.nvim_win_close, tmp_win --[[@as integer]], true)
  pcall(vim.api.nvim_buf_delete, tmp_buf, { force = true })
  vim.api.nvim_set_current_win(curr_win)

  return false
end

--- @alias morph.LevenshteinChange<T> ({ kind: 'add', item: T, index: integer } | { kind: 'delete', item: T, index: integer } | { kind: 'change', from: T, to: T, index: integer })

--- @private
--- @generic T
--- @param opts {
---   from: `T`[],
---   to: T[],
---   are_equal?: (fun(x: T, y: T, x_idx: integer, y_idx: integer): boolean),
---   cost?: {
---     of_delete?: (fun(x: T, idx: integer): integer),
---     of_add?: (fun(x: T, idx: integer): integer),
---     of_change?: (fun(x: T, y: T, x_idx: integer, y_idx: integer): integer)
---   }
--- }
--- @return morph.LevenshteinChange<T>[]
function H.levenshtein(opts)
  if not opts.are_equal then opts.are_equal = function(x, y) return x == y end end
  if not opts.cost then opts.cost = {} end
  if not opts.cost.of_add then opts.cost.of_add = function() return 1 end end
  if not opts.cost.of_change then opts.cost.of_change = function() return 1 end end
  if not opts.cost.of_delete then opts.cost.of_delete = function() return 1 end end

  local m, n = #opts.from, #opts.to
  -- Initialize the distance matrix
  --- @type integer[][]
  local dp = {}
  for i = 0, m do
    dp[i] = {}
    for j = 0, n do
      dp[i][j] = 0
    end
  end

  -- Fill the base cases
  for i = 0, m do
    assert(dp[i])[0] = i
  end
  for j = 0, n do
    assert(dp[0])[j] = j
  end

  -- Compute the Levenshtein distance dynamically
  for i = 1, m do
    for j = 1, n do
      if opts.are_equal(opts.from[i], opts.to[j], i, j) then
        assert(dp[i])[j] = assert(dp[i - 1])[j - 1] -- no cost if items are the same
      else
        local cost_delete = assert(assert(dp[i - 1])[j]) + opts.cost.of_delete(opts.from[i], i)
        local cost_add = assert(assert(dp[i])[j - 1]) + opts.cost.of_add(opts.to[j], j)
        local cost_change = assert(assert(dp[i - 1])[j - 1])
          + opts.cost.of_change(opts.from[i], opts.to[j], i, j)
        assert(dp[i])[j] = math.min(cost_delete, cost_add, cost_change)
      end
    end
  end

  -- Backtrack to find the changes
  local i = m
  local j = n
  --- @type morph.LevenshteinChange[]
  local changes = {}

  while i > 0 or j > 0 do
    local default_cost = assert(assert(dp[i])[j])
    local cost_of_change = (i > 0 and j > 0) and assert(dp[i - 1])[j - 1] or default_cost
    local cost_of_add = j > 0 and assert(dp[i])[j - 1] or default_cost
    local cost_of_delete = i > 0 and assert(dp[i - 1])[j] or default_cost

    --- @param u integer
    --- @param v integer
    --- @param w integer
    local function is_first_min(u, v, w) return u <= v and u <= w end

    if is_first_min(cost_of_change, cost_of_add, cost_of_delete) then
      -- potential change
      if not opts.are_equal(opts.from[i], opts.to[j]) then
        --- @type morph.LevenshteinChange
        local change = { kind = 'change', from = opts.from[i], index = i, to = opts.to[j] }
        table.insert(changes, change)
      end
      i = i - 1
      j = j - 1
    elseif is_first_min(cost_of_add, cost_of_change, cost_of_delete) then
      -- addition
      --- @type morph.LevenshteinChange
      local change = { kind = 'add', item = opts.to[j], index = i + 1 }
      table.insert(changes, change)
      j = j - 1
    elseif is_first_min(cost_of_delete, cost_of_change, cost_of_add) then
      -- deletion
      --- @type morph.LevenshteinChange
      local change = { kind = 'delete', item = opts.from[i], index = i }
      table.insert(changes, change)
      i = i - 1
    else
      error 'unreachable'
    end
  end

  return changes
end

--------------------------------------------------------------------------------
-- Exports
--------------------------------------------------------------------------------

local M = Morph
Morph.h = H.h
Morph.Pos00 = Pos00

return M
