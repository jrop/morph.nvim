local Morph = require 'morph'
local h = Morph.h

--------------------------------------------------------------------------------
-- Utility Components:
--------------------------------------------------------------------------------

--- Allows setting children externally:
--- 1. Children are controlled via state
--- 2. It "leaks" a callback for updating it's state.
--- @param ctx morph.Ctx<{ capture_update: fun(update: fun(children: morph.Tree)) }, { children: morph.Tree }>
local function SetChildren(ctx)
  if ctx.phase == 'mount' then
    ctx.state = { children = ctx.children }
    ctx.props.capture_update(
      --- @param children morph.Tree
      function(children) ctx:update { children = children } end
    )
  end
  local state = assert(ctx.state)
  return state.children
end

--- Renders a component tree to another buffer (like React portals). It
--- "teleports" the children that it renders to the buffer given by
--- `props.bufnr`.
--- @param ctx morph.Ctx<{ bufnr: integer }, { document: morph.Morph, children: morph.Tree, portal_update?: fun(children: morph.Tree) }>
local function BufferPortal(ctx)
  if ctx.phase == 'mount' then
    local document = Morph.new(ctx.props.bufnr)

    ctx.state = {
      document = document,
      children = ctx.children,
      portal_update = nil,
    }

    document:mount(h(SetChildren, {
      capture_update = function(update_children)
        ctx.state.portal_update = update_children
        ctx:update(ctx.state)
      end,
    }, ctx.children))
  end

  local state = assert(ctx.state)
  if ctx.phase == 'update' then assert(state.portal_update)(ctx.children) end
  if ctx.phase == 'unmount' then assert(state.portal_update)(nil) end
  return nil
end

--------------------------------------------------------------------------------
-- App
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<any, { text: string, hl?: string, on_click?: function }>
local function Button(ctx)
  return h('text', {
    hl = ctx.props.hl or 'DiffAdd',
    nmap = {
      ['<CR>'] = function()
        if ctx.props.on_click then ctx.props.on_click() end
        return ''
      end,
    },
  }, ctx.props.text)
end

--- @param ctx morph.Ctx<{ count: integer }>
local function Counter(ctx)
  if ctx.phase == 'mount' then ctx.state = { count = 1 } end
  local state = assert(ctx.state)

  return {
    'Value: ',
    h.Number({}, tostring(state.count)),
    ' ',
    h(Button, {
      text = ' - ',
      hl = 'DiffDelete',
      on_click = function() ctx:update { count = state.count - 1 } end,
    }),
    ' / ',
    h(Button, {
      text = ' + ',
      hl = 'DiffAdd',
      on_click = function() ctx:update { count = state.count + 1 } end,
    }),
  }
end

--- @param ctx morph.Ctx<{ buf2: integer }, { toggle: boolean }>
local function App(ctx)
  if ctx.phase == 'mount' then ctx.state = { toggle = false } end
  local state = assert(ctx.state)

  return {
    'This demonstrates a rendered "portal".\n',
    'Part of the component tree is rendered\n',
    'in the buffer below.\n',
    '\n\n',
    'Toggle the below check-mark by placing\n',
    'your cursor over the following line,\n',
    'and pressing ',
    h.Keyword({}, '<C-Space>.'),
    '\n\n',

    h('text', {
      nmap = {
        ['<C-Space>'] = function()
          ctx:update { toggle = not state.toggle }
          return ''
        end,
      },
    }, { '- [', state.toggle and 'X' or ' ', '] Toggle' }),

    h(BufferPortal, { bufnr = ctx.props.buf2 }, {
      'These children are rendered as\n',
      'part of the tree in the document\n',
      'above, but they are teleported\n',
      'to this buffer during render.',
      '\n\n',
      'Counter 1:\n',
      h(Counter),
      '\n\n',
      'Counter 2:\n',
      h(Counter),
      state.toggle and '\n\nTOGGLE: EXTRA!' or '',
    }),
  }
end

local function setup()
  vim.cmd.vnew()
  local buf1 = vim.api.nvim_get_current_buf()
  vim.bo.bufhidden = 'delete'
  vim.bo.buflisted = false
  vim.bo.buftype = 'nowrite'

  vim.cmd.new()
  local buf2 = vim.api.nvim_get_current_buf()
  vim.bo.bufhidden = 'delete'
  vim.bo.buflisted = false
  vim.bo.buftype = 'nowrite'

  Morph.new(buf1):mount(h(App, { buf2 = buf2 }))
end

setup()
