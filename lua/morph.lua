function _G.MorphOpFuncNoop() end

local H = {}

--------------------------------------------------------------------------------
-- Type definitions
--------------------------------------------------------------------------------

--- @alias morph.TagEventHandler fun(e: { tag: morph.Tag, mode: string, lhs: string, bubble_up: boolean }): string

--- @alias morph.TagAttributes {
---   [string]?: unknown,
---   on_change?: (fun(e: { text: string,  bubble_up: boolean }): unknown),
---   key?: string|number,
---   imap?: table<string, morph.TagEventHandler>,
---   nmap?: table<string, morph.TagEventHandler>,
---   vmap?: table<string, morph.TagEventHandler>,
---   xmap?: table<string, morph.TagEventHandler>,
---   omap?: table<string, morph.TagEventHandler>,
---   extmark?: vim.api.keyset.set_extmark
--- }

--- @class morph.Tag
--- @field kind 'tag'
--- @field name string | morph.Component<any, any>
--- @field attributes morph.TagAttributes
--- @field children morph.Tree
--- @field private ctx? morph.Ctx

--- @alias morph.Node nil | boolean | string | morph.Tag
--- @alias morph.Tree morph.Node | morph.Node[]

--- @alias morph.Component<TProps, TState> fun(ctx: morph.Ctx<TProps, TState>): morph.Tree

--- @class morph.MorphExtmark
--- @field id? integer
--- @field start [integer, integer]
--- @field stop [integer, integer]
--- @field opts vim.api.keyset.set_extmark
--- @field tag morph.Tag

--------------------------------------------------------------------------------
-- h, Ctx, Morph implementations
--------------------------------------------------------------------------------

-- luacheck: ignore
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

--- @generic TProps
--- @generic TState
--- @class morph.Ctx<TProps, TState>
--- @field phase 'mount'|'update'|'unmount'
--- @field props TProps
--- @field state? TState
--- @field children morph.Tree
--- @field private on_change? fun(): any
--- @field private prev_rendered_children? morph.Tree
local Ctx = {}
Ctx.__index = Ctx

--- @param props TProps
--- @param state? TState
--- @param children morph.Tree
function Ctx.new(props, state, children)
  return setmetatable({
    phase = 'mount',
    props = props,
    state = state,
    children = children,
  }, Ctx)
end

--- @param new_state TState
function Ctx:update(new_state)
  self.state = new_state
  if self.on_change then
    if
      vim.in_fast_event() --[[@as boolean]]
    then
      vim.schedule(function() self.on_change() end)
    else
      self.on_change()
    end
  end
end

--- @class morph.Morph
--- @field bufnr integer
--- @field ns integer
--- @field changedtick integer
--- @field changing boolean
--- @field text_content { old: { lines: string[], extmarks: morph.MorphExtmark[] }, curr: { lines: string[], extmarks: morph.MorphExtmark[] } }
--- @field component_tree { old: morph.Tree  }
local Morph = {}
Morph.__index = Morph

--------------------------------------------------------------------------------
--- Morph: Static functions
--------------------------------------------------------------------------------

--- @private
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
function Morph.tree_match(tree, visitors)
  local function is_tag(x) return type(x) == 'table' and x.kind == 'tag' end
  local function is_tag_arr(x) return type(x) == 'table' and not is_tag(x) end

  if tree == nil then
    return visitors.nil_ and visitors.nil_() or nil
  elseif type(tree) == 'boolean' then
    return visitors.boolean and visitors.boolean(tree) or nil
  elseif type(tree) == 'string' then
    return visitors.string and visitors.string(tree) or nil
  elseif is_tag_arr(tree) then
    return visitors.array and visitors.array(tree --[[@as any]]) or nil
  elseif is_tag(tree) then
    local tag = tree --[[@as morph.Tag]]
    if type(tag.name) == 'function' then
      return visitors.component and visitors.component(tag.name --[[@as function]], tag) or nil
    else
      return visitors.tag and visitors.tag(tree --[[@as any]]) or nil
    end
  else
    return visitors.unknown and visitors.unknown(tree) or error 'unknown value: not a tag'
  end
end

--- @private
--- @param tree morph.Tree
--- @return 'nil' | 'boolean' | 'string' | 'array' | 'tag' | morph.Component | 'unknown'
function Morph.tree_kind(tree)
  return Morph.tree_match(tree, {
    nil_ = function() return 'nil' end,
    boolean = function() return 'boolean' end,
    string = function() return 'string' end,
    array = function() return 'array' end,
    tag = function() return 'tag' end,
    component = function(c) return c end,
    unknown = function() return 'unknown' end,
  }) --[[@as any]]
end

--- @param opts {
---   tree: morph.Tree,
---   on_tag?: fun(tag: morph.Tag, start0: [number, number], stop0: [number, number]): any
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
    Morph.tree_match(node, {
      string = function(s_node)
        local node_lines = vim.split(s_node, '\n')
        for lnum, s in ipairs(node_lines) do
          if lnum > 1 then put_line() end
          put(s)
        end
      end,
      array = function(ts)
        for _, child in ipairs(ts) do
          visit(child)
        end
      end,
      tag = function(t)
        local start0 = { curr_line1 - 1, curr_col1 - 1 }
        visit(t.children)
        local stop0 = { curr_line1 - 1, curr_col1 - 1 }

        if opts.on_tag then opts.on_tag(t, start0, stop0) end
      end,
      component = function(Component, t)
        local start0 = { curr_line1 - 1, curr_col1 - 1 }
        visit(Component(Ctx.new(t.attributes, nil, t.children)))
        local stop0 = { curr_line1 - 1, curr_col1 - 1 }

        if opts.on_tag then opts.on_tag(t, start0, stop0) end
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
  local line_changes = H.levenshtein {
    from = old_lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    to = new_lines,
  }
  for _, line_change in ipairs(line_changes) do
    local lnum0 = line_change.index - 1

    if line_change.kind == 'add' then
      _set_lines(lnum0, lnum0, true, { line_change.item })
    elseif line_change.kind == 'change' then
      -- Compute inter-line diff, and apply:
      local col_changes =
        H.levenshtein { from = vim.split(line_change.from, ''), to = vim.split(line_change.to, '') }

      for _, col_change in ipairs(col_changes) do
        local cnum0 = col_change.index - 1
        if col_change.kind == 'add' then
          _set_text(lnum0, cnum0, lnum0, cnum0, { col_change.item })
        elseif col_change.kind == 'change' then
          _set_text(lnum0, cnum0, lnum0, cnum0 + 1, { col_change.to })
        elseif col_change.kind == 'delete' then
          _set_text(lnum0, cnum0, lnum0, cnum0 + 1, {})
        else -- luacheck: ignore
          -- No change
        end
      end
    elseif line_change.kind == 'delete' then
      _set_lines(lnum0, lnum0 + 1, true, {})
    else -- luacheck: ignore
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
      old = { lines = {}, extmarks = {} },
      curr = { lines = {}, extmarks = {} },
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
--- Morph: Instance methods
--------------------------------------------------------------------------------

--- Render static markup
--- @param tree morph.Tree
function Morph:render(tree)
  local changedtick = vim.b[self.bufnr].changedtick
  if changedtick ~= self.changedtick then
    self.text_content.curr =
      { extmarks = {}, lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false) }
    self.changedtick = changedtick
  end

  --- @type morph.MorphExtmark[]
  local extmarks = {}

  --- @type string[]
  local lines = Morph.markup_to_lines {
    tree = tree,

    on_tag = function(tag, start0, stop0)
      if tag.name == 'text' then
        local hl = tag.attributes.hl
        if type(hl) == 'string' then
          tag.attributes.extmark = tag.attributes.extmark or {}
          tag.attributes.extmark.hl_group = tag.attributes.extmark.hl_group or hl
        end

        local extmark_opts = tag.attributes.extmark or {}

        -- Set any necessary keymaps:
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

        table.insert(extmarks, {
          start = start0,
          stop = stop0,
          opts = extmark_opts,
          tag = tag,
        })
      end
    end,
  }

  self.text_content.old = self.text_content.curr
  self.text_content.curr = { lines = lines, extmarks = extmarks }
  self:_reconcile_extmarks()
  vim.cmd.doautocmd { args = { 'User', 'Morph:' .. tostring(self.bufnr) .. ':render' } }
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
        Morph.tree_match(tree, {
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
      local old_tree_kind = Morph.tree_kind(old_tree)
      local new_tree_kind = Morph.tree_kind(new_tree)

      local new_tree_rendered = Morph.tree_match(new_tree, {
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
          local old_component_info = Morph.tree_match(
            old_tree,
            { component = function(_, t) return { tag = t, ctx = t.ctx } end }
          )
          local ctx = old_component_info and old_component_info.ctx or nil

          if not ctx then
            --- @type morph.Ctx
            ctx = Ctx.new(new_tag.attributes, nil, new_tag.children)
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
        return Morph.tree_match(tree, {
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
      local changes = H.levenshtein {
        from = old_arr or {},
        to = new_arr or {},
        are_equal = function() return false end,
        cost = {
          of_change = function(tree1, tree2, tree1_idx, tree2_idx)
            local tree1_inf = verbose_tree_kind(tree1, tree1_idx)
            local tree2_inf = verbose_tree_kind(tree2, tree2_idx)
            return tree1_inf == tree2_inf and 1 or 2
          end,
        },
      }

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

    local renderable_tree = H2.visit_tree(self.component_tree.old, tree)
    self.component_tree.old = tree
    self:render(renderable_tree)
  end

  -- Kick off initial render:
  rerender()
end

--- @private
function Morph:_reconcile_extmarks()
  --
  -- Step 1: morph the text to the desired state:
  --
  self.changing = true
  Morph.patch_lines(self.bufnr, self.text_content.old.lines, self.text_content.curr.lines)
  self.changing = false
  self.changedtick = vim.b[self.bufnr].changedtick

  --
  -- Step 2: reconcile extmarks:
  -- You may be tempted to try to keep track of which extmarks are needed, and
  -- only delete those that are not needed. However, each time a tree is
  -- rendered, brand new extmarks are created. For simplicity, it is better to
  -- just delete all extmarks, and recreate them.
  --

  -- Clear current extmarks:
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)

  -- Set current extmarks:
  for _, extmark in ipairs(self.text_content.curr.extmarks) do
    extmark.id = vim.api.nvim_buf_set_extmark(
      self.bufnr,
      self.ns,
      extmark.start[1],
      extmark.start[2],
      vim.tbl_extend('force', {
        id = extmark.id,
        end_row = extmark.stop[1],
        end_col = extmark.stop[2],
        -- If we change the text starting from the beginning (where the extmark
        -- is), we don't want the extmark to move to the right.
        right_gravity = false,
        -- If we change the text starting from the end (where the end extmark
        -- is), we don't want the extmark to stay stationary: we want it to
        -- move to the right.
        end_right_gravity = true,
      }, extmark.opts)
    )
  end

  self.text_content.old = self.text_content.curr
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
  local pos_infos = self:get_tags_at(pos0)

  if #pos_infos == 0 then return lhs end

  -- Find the first tag that is listening for this event:
  local keypress_cancel = false
  local loop_control = { bubble_up = true }
  for _, pos_info in ipairs(pos_infos) do
    if loop_control.bubble_up then
      local tag = pos_info.tag

      -- is the tag listening?
      --- @type morph.TagEventHandler?
      local f = vim.tbl_get(tag.attributes, mode .. 'map', lhs)
      if type(f) == 'function' then
        local e = { tag = tag, mode = mode, lhs = lhs, bubble_up = true }
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

function Morph:_on_text_changed()
  if self.changing or self.changedtick == vim.b[self.bufnr].changedtick then return end

  -- Reset changedtick, so that the reconciler knows to refresh its cached
  -- buffer-content before computing the diff:
  self.changedtick = 0

  local l, c = unpack(vim.api.nvim_win_get_cursor(0))
  l = l - 1 -- make it actually 0-based
  local pos_infos = self:get_tags_at({ l, c }, 'i')
  local loop_control = { bubble_up = true }
  for _, pos_info in ipairs(pos_infos) do
    if loop_control.bubble_up then
      local extmark_inf = pos_info.extmark
      local tag = pos_info.tag

      local on_change = tag.attributes.on_change
      if on_change and type(on_change) == 'function' then
        local extmark = vim.api.nvim_buf_get_extmark_by_id(
          self.bufnr,
          self.ns,
          extmark_inf.id,
          { details = true }
        )

        --- @type integer, integer, vim.api.keyset.extmark_details
        local start_row0, start_col0, details = unpack(extmark)
        local end_row0, end_col0 = details.end_row, details.end_col

        if start_row0 == end_row0 and start_col0 == end_col0 then
          local e = { text = '', bubble_up = true }
          on_change(e)
          loop_control.bubble_up = e.bubble_up
          return -- TODO
        end

        local buf_max_line0 = math.max(1, vim.api.nvim_buf_line_count(self.bufnr) - 1)
        if end_row0 > buf_max_line0 then
          end_row0 = buf_max_line0
          local last_line = vim.api.nvim_buf_get_lines(self.bufnr, end_row0, end_row0 + 1, false)[1]
            or ''
          end_col0 = last_line:len()
        end
        if end_col0 == 0 then
          end_row0 = end_row0 - 1
          local last_line = vim.api.nvim_buf_get_lines(self.bufnr, end_row0, end_row0 + 1, false)[1]
            or ''
          end_col0 = last_line:len()
        end

        if start_row0 == end_row0 and start_col0 == end_col0 then
          local e = { text = '', bubble_up = true }
          on_change(e)
          loop_control.bubble_up = e.bubble_up
          return -- TODO
        end

        local pos1 = { self.bufnr, start_row0 + 1, start_col0 + 1 }
        local pos2 = { self.bufnr, end_row0 + 1, end_col0 }
        local ok, lines = pcall(vim.fn.getregion, pos1, pos2, { type = 'v' })
        if not ok then
          vim.api.nvim_echo({
            { '(u.nvim:getregion:invalid-pos) ', 'ErrorMsg' },
            {
              '{ start, end } = ' .. vim.inspect({ pos1, pos2 }, { newline = ' ', indent = '' }),
            },
          }, true, {})
          error(lines)
        end
        if type(lines) == 'string' then lines = { lines } end

        local e = { text = table.concat(lines, '\n'), bubble_up = true }
        on_change(e)
        loop_control.bubble_up = e.bubble_up
      end
    end
  end
end

--- Returns pairs of extmarks and tags associate with said extmarks. The
--- returned tags/extmarks are sorted smallest (innermost) to largest
--- (outermost).
---
--- @private (private for now)
--- @param pos0 [integer, integer]
--- @param mode string?
--- @return { extmark: morph.MorphExtmark, tag: morph.Tag }[]
function Morph:get_tags_at(pos0, mode)
  local cursor_line0, cursor_col0 = pos0[1], pos0[2]
  if not mode then mode = vim.api.nvim_get_mode().mode end
  mode = mode:sub(1, 1) -- we don't care about sub-modes

  local raw_overlapping_extmarks = vim.api.nvim_buf_get_extmarks(
    self.bufnr,
    self.ns,
    pos0,
    pos0,
    { details = true, overlap = true }
  )

  -- The cursor (block) occupies **two** extmark spaces: one for it's left
  -- edge, and one for it's right. We need to do our own intersection test,
  -- because the NeoVim API is over-inclusive in what it returns:
  --- @type morph.MorphExtmark[]
  local mapped_extmarks = vim
    .iter(raw_overlapping_extmarks)
    :map(
      --- @return morph.MorphExtmark
      function(ext)
        --- @type integer, integer, integer, { end_row?: number, end_col?: number }|nil
        local id, line0, col0, details = unpack(ext)
        local start = { line0, col0 }
        local stop = { line0, col0 }
        if details and details.end_row ~= nil and details.end_col ~= nil then
          stop = {
            details.end_row --[[@as integer]],
            details.end_col --[[@as integer]],
          }
        end
        return { id = id, start = start, stop = stop, opts = details }
      end
    )
    :totable()

  local intersecting_extmarks = vim
    .iter(mapped_extmarks)
    :filter(
      --- @param ext morph.MorphExtmark
      function(ext)
        if ext.stop[1] ~= nil and ext.stop[2] ~= nil then
          -- If we've "ciw" and "collapsed" an extmark onto the cursor,
          -- the cursor pos will equal the exmark's start AND end. In this
          -- case, we want to include the extmark.
          if
            cursor_line0 == ext.start[1]
            and cursor_col0 == ext.start[2]
            and cursor_line0 == ext.stop[1]
            and cursor_col0 == ext.stop[2]
          then
            return true
          end

          return
            -- START: line check
            cursor_line0 >= ext.start[1]
              -- START: column check
              and (cursor_line0 ~= ext.start[1] or cursor_col0 >= ext.start[2])
              -- STOP: line check
              and cursor_line0 <= ext.stop[1]
              -- STOP: column check
              and (
                cursor_line0 ~= ext.stop[1]
                or (
                  mode == 'i'
                    -- In insert mode, the cursor is "thin", so <= to compensate:
                    and cursor_col0 <= ext.stop[2]
                  -- In normal mode, the cursor is "wide", so < to compensate:
                  or cursor_col0 < ext.stop[2]
                )
              )
        else
          return true
        end
      end
    )
    :totable()

  -- Sort the tags into smallest (inner) to largest (outer):
  table.sort(
    intersecting_extmarks,
    --- @param x1 morph.MorphExtmark
    --- @param x2 morph.MorphExtmark
    function(x1, x2)
      if
        x1.start[1] == x2.start[1]
        and x1.start[2] == x2.start[2]
        and x1.stop[1] == x2.stop[1]
        and x1.stop[2] == x2.stop[2]
      then
        return x1.id < x2.id
      end

      return x1.start[1] >= x2.start[1]
        and x1.start[2] >= x2.start[2]
        and x1.stop[1] <= x2.stop[1]
        and x1.stop[2] <= x2.stop[2]
    end
  )

  -- When we set the extmarks in the step above, we captured the IDs of the
  -- created extmarks in self.text_content.curr.extmarks, which also has which tag each
  -- extmark is associated with. Cross-reference with that list to get a list
  -- of tags that we need to fire events for:
  --- @type { extmark: morph.MorphExtmark, tag: morph.Tag }[]
  local matching_tags = vim
    .iter(intersecting_extmarks)
    :map(
      --- @param ext morph.MorphExtmark
      function(ext)
        for _, extmark_cache in ipairs(self.text_content.curr.extmarks) do
          if extmark_cache.id == ext.id then return { extmark = ext, tag = extmark_cache.tag } end
        end
      end
    )
    :totable()

  return matching_tags
end

--- @private (private for now)
--- @param tag_or_id string | morph.Tag
--- @return { start: [number, number], stop: [number, number] } | nil
function Morph:get_tag_bounds(tag_or_id)
  for _, x in ipairs(self.text_content.curr.extmarks) do
    local pos = { start = x.start, stop = x.stop }
    local does_tag_match = type(tag_or_id) == 'string' and x.tag.attributes.id == tag_or_id
      or x.tag == tag_or_id
    if does_tag_match then return pos end
  end
end

--- @alias morph.LevenshteinChange<T> ({ kind: 'add', item: T, index: integer } | { kind: 'delete', item: T, index: integer } | { kind: 'change', from: T, to: T, index: integer })
--- @private
--- @generic T
--- @param opts {
---   from: `T`[],
---   to: T[],
---   are_equal?: (fun(x: T, y: T, xidx: integer, yidx: integer): boolean),
---   cost?: {
---     of_delete?: (fun(x: T, idx: integer): number),
---     of_add?: (fun(x: T, idx: integer): number),
---     of_change?: (fun(x: T, y: T, xidx: integer, yidx: integer): number)
---   }
--- }
--- @return morph.LevenshteinChange<T>[] The changes, from last (greatest index) to first (smallest index).
function H.levenshtein(opts)
  -- At the moment, this whole `cost` plumbing is not used. Deletes have the
  -- same cost as Adds or Changes. I can imagine a future, however, where
  -- fudging with the costs of operations produces a more optimized change-set
  -- that is tailored to working better with how NeoVim manipulates text. I've
  -- done no further investigation in this area, however, so it's impossible to
  -- tell if such tuning would produce real benefit. For now, I'm leaving this
  -- in here even though it's not actively used. Hopefully having this
  -- callback-based plumbing does not cause too much of a performance hit to
  -- the renderer.
  if not opts.are_equal then opts.are_equal = function(x, y) return x == y end end
  if not opts.cost then opts.cost = {} end
  if not opts.cost.of_add then opts.cost.of_add = function() return 1 end end
  if not opts.cost.of_change then opts.cost.of_change = function() return 1 end end
  if not opts.cost.of_delete then opts.cost.of_delete = function() return 1 end end

  local m, n = #opts.from, #opts.to
  -- Initialize the distance matrix
  local dp = {}
  for i = 0, m do
    dp[i] = {}
    for j = 0, n do
      dp[i][j] = 0
    end
  end

  -- Fill the base cases
  for i = 0, m do
    dp[i][0] = i
  end
  for j = 0, n do
    dp[0][j] = j
  end

  -- Compute the Levenshtein distance dynamically
  for i = 1, m do
    for j = 1, n do
      if opts.are_equal(opts.from[i], opts.to[j], i, j) then
        dp[i][j] = dp[i - 1][j - 1] -- no cost if items are the same
      else
        local cost_delete = dp[i - 1][j] + opts.cost.of_delete(opts.from[i], i)
        local cost_add = dp[i][j - 1] + opts.cost.of_add(opts.to[j], j)
        local cost_change = dp[i - 1][j - 1] + opts.cost.of_change(opts.from[i], opts.to[j], i, j)
        dp[i][j] = math.min(cost_delete, cost_add, cost_change)
      end
    end
  end

  -- Backtrack to find the changes
  local i = m
  local j = n
  --- @type morph.LevenshteinChange[]
  local changes = {}

  while i > 0 or j > 0 do
    local default_cost = dp[i][j]
    local cost_of_change = (i > 0 and j > 0) and dp[i - 1][j - 1] or default_cost
    local cost_of_add = j > 0 and dp[i][j - 1] or default_cost
    local cost_of_delete = i > 0 and dp[i - 1][j] or default_cost

    --- @param u number
    --- @param v number
    --- @param w number
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

local M = Morph
Morph.h = H.h
return M
