--[[
Counter Example - Interactive UI with Stateful Components

This example demonstrates:
- Creating reusable components (Button, Counter)
- Managing component state with ctx.state
- Event handling with nmap keybindings
- Component composition and props passing

To run this example:
1. Open this file in Neovim
2. Execute: :luafile %
3. A new buffer will open with interactive counters
4. Press <CR> on the + and - buttons to increment/decrement
--]]

local Morph = require 'morph'
local h = Morph.h

-- Reusable Button component
-- Takes text, highlight group, and click handler as props
--- @param ctx morph.Ctx<any, { text: string, hl?: string, on_click?: function }>
local function Button(ctx)
  return h('text', {
    hl = ctx.props.hl or 'DiffAdd', -- Default to green highlight
    nmap = {
      ['<CR>'] = function() -- Handle Enter key in normal mode
        if ctx.props.on_click then ctx.props.on_click() end
        return '' -- Consume the keypress
      end,
    },
  }, ctx.props.text)
end

-- Counter component with its own state
-- Each instance maintains independent count state
--- @param ctx morph.Ctx<{ count: integer }>
local function Counter(ctx)
  -- Initialize state only on first render (mount phase)
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
      on_click = function()
        -- Update state and trigger re-render
        ctx:update { count = count - 1 }
      end,
    }),
    ' / ',
    h(Button, { -- Increment button
      text = ' + ',
      hl = 'DiffAdd', -- Green highlight
      on_click = function()
        -- Update state and trigger re-render
        ctx:update { count = count + 1 }
      end,
    }),
  }
end

-- Main App component that renders the entire UI
-- Demonstrates component composition and multiple instances
--- @param _ctx morph.Ctx
--- @return morph.Tree
local function App(_ctx)
  return {
    -- Main heading with markdown-style highlighting
    h['@markup.heading']({}, '# Counter Example'),

    '\n\n',
    'Each of the following counters are rendered by a Counter component, each with its own retained state:',

    '\n\n',
    -- First counter instance
    { h['@markup.heading.2.markdown']({}, 'Counter 1:'), '\n' },
    h(Counter), -- Each h(Counter) creates a separate instance with its own state

    '\n\n',
    -- Second counter instance
    h['@markup.heading.2.markdown']({}, 'Counter 2:'),
    '\n',
    h(Counter), -- This counter has completely independent state from Counter 1

    '\n\n',
    'Press <CR> on each "button" above to increment/decrement the counter.',
  } --[[@as morph.Tree]]
end

-- Setup and launch the UI
-- Create a new vertical split buffer for the demo
vim.cmd.vnew()
vim.bo.bufhidden = 'delete' -- Delete buffer when hidden
vim.bo.buflisted = false -- Don't show in buffer list
vim.bo.buftype = 'nowrite' -- Make buffer read-only-ish

-- Create morph renderer and mount the App component
Morph.new():mount(h(App, {}))
