# morph.nvim

Build interactive text user interfaces in Neovim with a React-like component model.

![Blob](./morph.jpg)

## What is morph.nvim?

morph.nvim lets you create dynamic, interactive buffers using familiar React patterns like components, state, and event handlers. Perfect for building custom UIs, forms, dashboards, or any interactive text-based interface within Neovim.

## Quick Start

```lua
local Morph = require('morph')
local h = Morph.h

-- Create a simple counter component
--- @param ctx morph.Ctx<{}, { count: integer }>
local function Counter(ctx)
  if ctx.phase == 'mount' then 
    ctx.state = { count = 0 }
  end
  
  return {
    h.Title({}, 'Count: '),
    h.Number({}, tostring(ctx.state.count)),
    '\n',
    h.Keyword({
      nmap = {
        ['<CR>'] = function()
          ctx:update({ count = ctx.state.count + 1 })
          return '' -- consume the keypress
        end
      }
    }, '[Press Enter to increment]')
  }
end

-- Render to current buffer
local renderer = Morph.new()
renderer:mount(h(Counter, {}, {}))
```

## Key Features

### 🎯 **Component-Based Architecture**
Write reusable components with props, state, and lifecycle methods. Components can render other components, creating a composable hierarchy:

```lua
--- @param ctx morph.Ctx<{ todo: any, on_toggle: function }, {}>
local function TodoItem(ctx)
  local todo = ctx.props.todo
  
  return {
    h('text', { 
      hl = todo.done and 'Comment' or 'Normal',
      nmap = {
        ['<Space>'] = function()
          ctx.props.on_toggle(todo.id)
          return ''
        end
      }
    }, todo.done and '✓ ' or '○ '),
    todo.text
  }
end

--- @param ctx morph.Ctx<{}, { todos: table[] }>
local function TodoList(ctx)
  if ctx.phase == 'mount' then
    ctx.state = { 
      todos = {
        { id = 1, text = 'Learn morph.nvim', done = false },
        { id = 2, text = 'Build awesome UI', done = false }
      }
    }
  end
  
  return {
    h.Title({}, 'My Todos'),
    '\n\n',
    vim.tbl_map(function(todo)
      return {
        h(TodoItem, { 
          todo = todo,
          on_toggle = function(id)
            -- Update todo state...
          end
        }),
        '\n'
      }
    end, ctx.state.todos)
  }
end
```

### ⚡ **Efficient Reconciliation**
Only updates what changed, using a diffing algorithm similar to React's virtual DOM.

### 🎨 **Rich Text Styling**
Apply highlight groups and extmarks with simple attributes:

```lua
h.ErrorMsg({ 
  extmark = { 
    virt_text = { { ' ← Error here', 'Comment' } }
  }
}, 'Invalid input')
```

### 🔥 **Interactive Event Handling**
Respond to keypresses with mode-specific handlers:

```lua
h('text', {
  nmap = { ['<CR>'] = handle_enter },
  imap = { ['<Tab>'] = handle_tab },
  on_change = function(e) 
    print('Text changed to:', e.text)
  end
}, 'Interactive text')
```

### 📝 **Text Change Detection**
Automatically detect when users edit text within tags:

```lua
h('text', {
  on_change = function(e)
    -- e.text contains the new content
    validate_input(e.text)
  end
}, 'Editable content')
```

## Real-World Example

```lua
--- @param ctx morph.Ctx<{}, { query: string, results: table[] }>
local function SearchForm(ctx)
  if ctx.phase == 'mount' then
    ctx.state = { query = '', results = {} }
  end
  
  return {
    h.Title({}, 'Search: '),
    h('text', {
      on_change = function(e)
        ctx:update({ 
          query = e.text,
          results = performSearch(e.text)
        })
      end
    }, ctx.state.query),
    '\n\n',
    
    -- Results
    vim.tbl_map(function(result)
      return {
        h.Directory({
          nmap = {
            ['<CR>'] = function()
              vim.cmd('edit ' .. result.path)
              return ''
            end
          }
        }, result.name),
        '\n'
      }
    end, ctx.state.results)
  }
end
```

## Installation

Since this is not a traditional Neovim "plugin" (it is a library), plugin authors are the intended consumers. Neovim does not have a good answer for automatic management of plugin dependencies. As such, it is recommended that library authors:

1. Vendor morph.nvim in their plugin. Morph is implemented in a single file, so this should be relatively painless. However, there is no great way to check for updates.

OR:

2. Suggest to their users to add morph.nvim as a dependency in their package manager. The major con here is that breaking changes could be inadvertantly pulled in by users when they update their plugins.

## Hyperscript Syntax

morph.nvim uses a hyperscript-like syntax for creating elements, similar to React's JSX but in Lua:

```lua
-- Basic text element
h('text', { hl = 'Comment' }, 'Hello world')

-- Shorthand for highlight groups
h.Comment({}, 'Hello world')  -- equivalent to above

-- Nested elements
h('text', {}, {
  'Outer text ',
  h.Keyword({}, 'highlighted'),
  ' more text'
})

-- With event handlers
h.Directory({
  nmap = {
    ['<CR>'] = function() 
      vim.cmd('edit ' .. filename)
      return ''  -- consume keypress
    end
  }
}, filename)

-- With extmark options for advanced styling
h.ErrorMsg({
  extmark = {
    virt_text = { { ' ← Error here', 'Comment' } },
    virt_text_pos = 'eol',
    priority = 100
  }
}, 'Invalid input')

-- Arrays of elements
{
  h.Title({}, 'Header'),
  '\n',
  h.Normal({}, 'Body text'),
  '\n\n',
  h.Comment({}, 'Footer')
}
```

The `h` function creates virtual elements that get rendered to buffer text with associated extmarks for styling and interactivity. Use `h.HighlightGroup({...}, children)` as shorthand when you don't need conditional highlighting. The `extmark` attribute accepts any options supported by `nvim_buf_set_extmark()` for advanced text decoration.

## API Reference

### Core Functions

- `Morph.new(bufnr?)` - Create a new renderer for a buffer
- `renderer:mount(tree)` - Mount a component tree
- `renderer:render(tree)` - Render static markup
- `h(name, attributes?, children?)` - Create elements

### Component Context

- `ctx.props` - Component properties
- `ctx.state` - Component state
- `ctx.children` - Child elements
- `ctx:update(new_state)` - Update state and trigger re-render
- `ctx.phase` - Current lifecycle phase ('mount', 'update', 'unmount')

### Event Handlers

- `nmap`, `imap`, `vmap`, `xmap`, `omap` - Mode-specific key handlers
- `on_change` - Text change callback

## Why morph.nvim?

Building interactive UIs in Neovim traditionally requires managing buffer content, extmarks, keymaps, and autocmds manually. morph.nvim abstracts this complexity behind a declarative, component-based API that feels familiar to web developers while being optimized for Neovim's unique capabilities.

## License (MIT)

Copyright (c) 2025 jrapodaca@gmail.com

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
