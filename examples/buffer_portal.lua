--[[
Buffer Portal Example - Rendering Components Across Multiple Buffers

This example demonstrates:
- Creating "portal" components that render to different buffers
- Advanced component composition and state management
- Cross-buffer UI coordination (like React portals)
- Utility components for flexible rendering

To run this example:
1. Open this file in Neovim
2. Execute: :luafile %
3. Two buffers will open - content flows between them
4. Use <C-Space> on the toggle line to see dynamic updates
5. Interact with the counters in the second buffer
--]]

local Morph = require 'morph'
local h = Morph.h

--------------------------------------------------------------------------------
-- Utility Components:
--------------------------------------------------------------------------------

-- Utility component that allows external control of its children
-- This is used internally by BufferPortal to enable dynamic updates
--- Allows setting children externally:
--- 1. Children are controlled via state
--- 2. It "leaks" a callback for updating it's state.
--- @param ctx morph.Ctx<{ capture_update: fun(update: fun(children: morph.Tree)) }, { children: morph.Tree }>
local function SetChildren(ctx)
  if ctx.phase == 'mount' then
    ctx.state = { children = ctx.children }
    -- Provide a callback to the parent for updating our children
    ctx.props.capture_update(
      --- @param children morph.Tree
      function(children) ctx:update { children = children } end
    )
  end
  local state = assert(ctx.state)
  return state.children -- Render whatever children we currently have
end

-- BufferPortal: Renders children to a different buffer (like React portals)
-- This "teleports" the component tree to another buffer while maintaining
-- the logical parent-child relationship in the component hierarchy
--- Renders a component tree to another buffer (like React portals). It
--- "teleports" the children that it renders to the buffer given by
--- `props.bufnr`.
--- @param ctx morph.Ctx<{ bufnr: integer }, { document: morph.Morph, children: morph.Tree, portal_update?: fun(children: morph.Tree) }>
local function BufferPortal(ctx)
  if ctx.phase == 'mount' then
    -- Create a new Morph renderer for the target buffer
    local document = Morph.new(ctx.props.bufnr)

    ctx.state = {
      document = document,
      children = ctx.children,
      portal_update = nil, -- Will be set by SetChildren callback
    }

    -- Mount a SetChildren component in the target buffer
    -- This gives us a way to update the portal content later
    document:mount(h(SetChildren, {
      capture_update = function(update_children)
        ctx.state.portal_update = update_children
        ctx:update(ctx.state)
      end,
    }, ctx.children))
  end

  local state = assert(ctx.state)
  local portal_update = state.portal_update
  -- When this component updates, update the portal content
  --- @diagnostic disable: unnecessary-assert, need-check-nil
  if ctx.phase == 'update' then assert(portal_update)(ctx.children) end
  -- When unmounting, clear the portal content
  if ctx.phase == 'unmount' then assert(portal_update)(nil) end
  --- @diagnostic enable: unnecessary-assert, need-check-nil
  return nil -- This component renders nothing in its own buffer
end

--------------------------------------------------------------------------------
-- App
--------------------------------------------------------------------------------

-- Reusable Button component (same as counter example)
--- @param ctx morph.Ctx<any, { text: string, hl?: string, on_click?: function }>
local function Button(ctx)
  return h('text', {
    hl = ctx.props.hl or 'DiffAdd', -- Default green highlight
    nmap = {
      ['<CR>'] = function() -- Handle Enter key press
        if ctx.props.on_click then ctx.props.on_click() end
        return '' -- Consume the keypress
      end,
    },
  }, ctx.props.text)
end

-- Counter component (same as counter example)
-- Each instance maintains independent state even across buffer portals
--- @param ctx morph.Ctx<{ count: integer }>
local function Counter(ctx)
  if ctx.phase == 'mount' then ctx.state = { count = 1 } end
  local state = assert(ctx.state)
  local count = state.count or 0

  return {
    'Value: ',
    h.Number({}, tostring(count)), -- Display current count
    ' ',
    h(Button, { -- Decrement button
      text = ' - ',
      hl = 'DiffDelete', -- Red highlight
      on_click = function() ctx:update { count = count - 1 } end,
    }),
    ' / ',
    h(Button, { -- Increment button
      text = ' + ',
      hl = 'DiffAdd', -- Green highlight
      on_click = function() ctx:update { count = count + 1 } end,
    }),
  }
end

-- Main App component demonstrating buffer portals
-- Shows how components can render across multiple buffers while maintaining state
--- @param ctx morph.Ctx<{ buf2: integer }, { toggle: boolean }>
local function App(ctx)
  if ctx.phase == 'mount' then ctx.state = { toggle = false } end
  local state = assert(ctx.state)

  return {
    -- Instructions rendered in the first buffer
    'This demonstrates a rendered "portal".\n',
    'Part of the component tree is rendered\n',
    'in the buffer below.\n',
    '\n\n',
    'Toggle the below check-mark by placing\n',
    'your cursor over the following line,\n',
    'and pressing ',
    h.Keyword({}, '<C-Space>.'),
    '\n\n',

    -- Interactive toggle control (rendered in first buffer)
    h('text', {
      nmap = {
        ['<C-Space>'] = function() -- Ctrl+Space to toggle
          ctx:update { toggle = not state.toggle }
          return ''
        end,
      },
    }, { '- [', state.toggle and 'X' or ' ', '] Toggle' }),

    -- Portal: These children will be rendered in buf2, not here!
    h(BufferPortal, { bufnr = ctx.props.buf2 }, {
      'These children are rendered as\n',
      'part of the tree in the document\n',
      'above, but they are teleported\n',
      'to this buffer during render.',
      '\n\n',
      'Counter 1:\n',
      h(Counter), -- This counter renders in buf2 but maintains state
      '\n\n',
      'Counter 2:\n',
      h(Counter), -- Independent counter, also in buf2
      -- Conditional content based on toggle state from buf1
      state.toggle and '\n\nTOGGLE: EXTRA!' or '',
    }),
  }
end

-- Setup function: Creates two buffers and demonstrates portal rendering
local function setup()
  -- Create first buffer (vertical split)
  vim.cmd.vnew()
  local buf1 = vim.api.nvim_get_current_buf()
  vim.bo.bufhidden = 'delete' -- Delete when hidden
  vim.bo.buflisted = false -- Don't show in buffer list
  vim.bo.buftype = 'nowrite' -- Make read-only-ish

  -- Create second buffer (horizontal split)
  vim.cmd.new()
  local buf2 = vim.api.nvim_get_current_buf()
  vim.bo.bufhidden = 'delete' -- Delete when hidden
  vim.bo.buflisted = false -- Don't show in buffer list
  vim.bo.buftype = 'nowrite' -- Make read-only-ish

  -- Mount the App in buf1, but it will render portal content to buf2
  Morph.new(buf1):mount(h(App, { buf2 = buf2 }))
end

-- Launch the demo
setup()
