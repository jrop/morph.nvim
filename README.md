# morph.nvim

Build interactive text user interfaces in Neovim with a React-like component model.

![Blob](./morph.jpg)

## Demo

Show, don't tell: If you want to see the kinds of things you can make with **morph.nvim**, see the following screencast, that demos [one of the examples](./examples/docker-containers.lua) from this repo.

[![asciicast](https://asciinema.org/a/sErPWJAgYge1DSskj5zrgNJZM.svg)](https://asciinema.org/a/sErPWJAgYge1DSskj5zrgNJZM)

## Table of Contents

- [What is morph.nvim?](#what-is-morphnvim)
- [Quick Start](#quick-start)
- [Key Features](#key-features)
  - [Component-Based Architecture](#-component-based-architecture)
  - [Efficient Reconciliation](#-efficient-reconciliation)
  - [Rich Text Styling](#-rich-text-styling)
  - [Interactive Event Handling](#-interactive-event-handling)
  - [Text Change Detection](#-text-change-detection)
- [Real-World Example](#real-world-example)
- [Installation](#installation)
- [Hyperscript Syntax](#hyperscript-syntax)
  - [Element Types](#element-types)
  - [Special Attributes](#special-attributes)
- [API Reference](#api-reference)
  - [Core Functions](#core-functions)
  - [Component Context](#component-context)
  - [Event Handlers](#event-handlers)
- [Why morph.nvim?](#why-morphnvim)
- [Similar Projects](#similar-projects)
- [License (MIT)](#license-mit)

## What is morph.nvim?

morph.nvim transforms Neovim into a powerful **TUI (Terminal User Interface) framework**, letting you create dynamic, interactive buffers using familiar React patterns like components, state, and event handlers. Perfect for building custom UIs, forms, dashboards, file explorers, or any interactive text-based interface within Neovim's editing environment.

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

### **Component-Based Architecture**
Write reusable components with props, state, and lifecycle methods. Components can render other components, creating a composable hierarchy:

<details>
<summary>View TodoList component example</summary>

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

</details>

### **Efficient Reconciliation**
Only updates what changed, using a diffing algorithm similar to React's virtual DOM. The renderer intelligently patches only the specific text regions that have actually changed, preserving cursor position and avoiding disruptive window jumps. This means smooth, flicker-free updates even for complex UIs with frequent state changes.

### **Rich Text Styling**
Apply highlight groups and extmarks with simple attributes:

<details>
<summary>View styling examples</summary>

```lua
h.ErrorMsg({ 
  extmark = { 
    virt_text = { { ' ← Error here', 'Comment' } }
  }
}, 'Invalid input')
```

</details>

### **Interactive Event Handling**
Respond to keypresses with mode-specific handlers:

<details>
<summary>View event handling examples</summary>

```lua
h('text', {
  nmap = { ['<CR>'] = handle_enter },
  imap = { ['<Tab>'] = handle_tab },
  on_change = function(e) 
    print('Text changed to:', e.text)
  end
}, 'Interactive text')
```

</details>

### **Text Change Detection**
Automatically detect when users edit text within tags:

<details>
<summary>View text change detection example</summary>

```lua
h('text', {
  on_change = function(e)
    -- e.text contains the new content
    validate_input(e.text)
  end
}, 'Editable content')
```

</details>

## Real-World Example

<details>
<summary>View SearchForm component example</summary>

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

</details>

## Installation

### If you are a _Plugin Author_

Neovim does not have a good answer for automatic management of plugin dependencies. As such, it is recommended that library authors vendor morph.nvim within their plugin. **morph.nvim** is implemented in a single file, so this should be relatively painless. Furthermore, `lua/morph.lua` versions are published into artifact tags `artifact-vX.Y.Z` as `init.lua` so that plugin authors can add morph as a submodule to their plugin.

<details>
<summary>Example git submodule setup</summary>

```bash
# In your plugin repository
git submodule add -- https://github.com/jrop/morph.nvim lua/my_plugin/morph
cd lua/my_plugin/morph/
git checkout artifact-v0.1.0 # put whatever version of morph.nvim you want to pin here
# ... commit the submodule within your repo

# This would place morph@v0.1.0 at:
# lua/my_plugin/morph/init.lua
```

Then in your plugin code:
```lua
local Morph = require('my_plugin.morph')
```

This approach allows plugin authors to:
- Pin to specific versions of morph.nvim
- Get updates by pulling/committing new **morph.nvim** versions (i.e., the usual git submodule way)
- Keep the dependency explicit and version-controlled
- Avoid namespace conflicts with user-installed plugins

</details>

### If you are a _User_ wanting to use morph.nvim in your config

<details>
<summary>vim.pack</summary>

```lua
vim.pack.add { 'https://github.com/jrop/morph.nvim' }
```

</details>

<details>
<summary>lazy.nvim</summary>

```lua
{ 'jrop/morph.nvim' }
```

</details>

<details>
<summary>packer.nvim</summary>

```lua
use({ 'jrop/morph.nvim' })
```

</details>

## Hyperscript Syntax

morph.nvim uses a hyperscript-like syntax for creating elements, similar to React's JSX but in Lua:

### Element Types

Currently, morph.nvim understands only one type of string-based element: `'text'`.

### Special Attributes

Several attributes have special meaning in morph.nvim:

- `id` - Unique identifier for the element (used with `renderer:get_element_by_id()`)
- `hl` - Highlight group name for styling the text
- `extmark` - Raw extmark options passed to `nvim_buf_set_extmark()`
- `key` - Helps the reconciler identify matchup old elements in arrays with new ones during updates (similar to React keys)

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

### Key Concepts

Understanding morph.nvim's core data structures:

- **Tree** - A declarative description of what you want to render. A Tree can be `nil`, `boolean`, `string`, a `Tag` (created by calling `h()`), or an array (even nested) of any combination of these types. Trees are returned from components and describe the structure and attributes but don't have physical presence in the buffer yet.

- **Element** - An instantiated Tree that has been rendered to the buffer. Elements have an associated `extmark` that tracks their actual position and bounds in the buffer text. When you call `renderer:get_elements_at()`, you get Elements, not Trees.

- **Tag** - The result of calling `h(name, attributes, children)`. Tags are a type of Tree node that represents a single element with its properties.

- **Component** - A function that takes a context and returns a Tree. Components can have state and lifecycle methods, making them the building blocks for interactive UIs.

- **Context (ctx)** - The persistent object passed to components that holds props, state, and lifecycle information. Unlike React hooks, the same context instance is reused across renders.

The flow: `Tree → render() → Element → buffer text + extmarks`

### Core Functions

- `h(name, attributes?, children?)` - Create elements
- `Morph.new(bufnr?)` - Create a new renderer for a buffer
- `renderer:mount(tree)` - Mount a component tree
- `renderer:render(tree)` - Render static markup
- `renderer:get_element_by_id(id)` - Find an element by its `id` attribute
- `renderer:get_elements_at(pos, mode?)` - Get all elements at a cursor position, sorted from innermost to outermost

### Component Context

Instead of React-style hooks like `useState` and `useEffect`, morph.nvim uses a **context object** (`ctx`) that persists across renders. This approach is simpler and more predictable - your component receives the same context instance on every render, maintaining state automatically.

The context acts as your component's "memory" between renders:

<details>
<summary>View StatefulCounter component example</summary>

```lua
--- @param ctx morph.Ctx<{ initial: number }, { count: number, history: number[] }>
local function StatefulCounter(ctx)
  -- Initialize state only on first render
  if ctx.phase == 'mount' then
    ctx.state = { 
      count = ctx.props.initial or 0,
      history = {}
    }
  end
  
  local state = ctx.state
  
  return {
    'Count: ', tostring(state.count), '\n',
    'History: ', table.concat(state.history, ', '), '\n',
    h.Keyword({
      nmap = {
        ['<CR>'] = function()
          -- Update state and trigger re-render
          ctx:update({
            count = state.count + 1,
            history = vim.list_extend({}, state.history, { state.count })
          })
          return ''
        end
      }
    }, '[Press Enter to increment]')
  }
end
```

</details>

**Key Properties:**

- `ctx.props` - Component properties (read-only, updated by parent)
- `ctx.state` - Component state (your persistent data between renders)
- `ctx.children` - Child elements passed to this component
- `ctx:update(new_state)` - Update state and trigger re-render
- `ctx.phase` - Current lifecycle phase ('mount', 'update', 'unmount')

**Why this approach?** No hook dependency arrays, no stale closures, no complex effect cleanup. Just straightforward state management that's easy to reason about and debug. If this simple approach doesn't meet your needs, you can easily integrate more sophisticated state management solutions (like Redux-style reducers, state machines, or reactive stores) by calling `ctx:update()` whenever your external state changes.

### Event Handlers

- `nmap`, `imap`, `vmap`, `xmap`, `omap` - Mode-specific key handlers
- `on_change` - Text change callback

## Why morph.nvim?

Neovim is already an exceptional text editor, but morph.nvim unlocks its potential as a **full-featured TUI application host**. Instead of being limited to traditional plugin UIs, you can build rich, interactive applications that feel native to the terminal while leveraging Neovim's powerful text manipulation capabilities.

Building interactive UIs in Neovim traditionally requires managing buffer content, extmarks, keymaps, and autocmds manually. morph.nvim abstracts this complexity behind a declarative, component-based API that feels familiar to web developers while being optimized for Neovim's unique capabilities.

## Similar Projects

- [reactive.nvim](https://github.com/rasulomaroff/reactive.nvim)
- [nvim-react](https://github.com/s1n7ax/nvim-react)
- [magenta.nvim](https://github.com/dlants/magenta.nvim) - [custom rendering engine](https://github.com/dlants/magenta.nvim/blob/main/node/tea/render.ts)

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
