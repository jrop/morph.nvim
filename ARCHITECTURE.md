# morph.nvim Architecture

This document describes the internal architecture of morph.nvim, a React-like component library for Neovim buffers.

## Overview

morph.nvim is implemented as a single file (`lua/morph.lua`, < 1000 SLoC) for easy vendoring by plugin authors. It provides a declarative, component-based API for building interactive text UIs in Neovim buffers.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Code                                   │
│   h(Component, props, children) → Tree                              │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Morph:mount(tree)                              │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │              Reconciliation (Side-by-Side Visitor)          │   │
│   │   reconcile_tree() <--> reconcile_component()               │   │
│   │         │                       │                           │   │
│   │         ▼                       ▼                           │   │
│   │   reconcile_array()      Component(ctx) → Tree              │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                  │                                  │
│                                  ▼                                  │
│                     Simplified Tree (no components)                 │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Morph:render(tree)                             │
│   markup_to_lines() → lines[] + pending extmarks                    │
│   patch_lines()     → minimal buffer edits (Levenshtein)            │
│   create extmarks   → buffer with highlights + interactivity        │
└─────────────────────────────────────────────────────────────────────┘
```

## Module Organization

The single file is organized into logical sections:

| Section               | Responsibility                                                  |
| --------------------- | --------------------------------------------------------------- |
| Type Definitions      | EmmyLua annotations for Tag, Element, Node, Tree, Component     |
| Tree Utilities        | `tree_type()` and `tree_identity_key()` for node classification |
| Levenshtein Algorithm | Generic diff algorithm for minimal edit sequences               |
| Textlock Detection    | Detects when buffer modifications are blocked                   |
| Buffer Watcher        | Batches `on_bytes` events via TextChanged autocmd               |
| `h()` Hyperscript     | Creates virtual DOM tags                                        |
| `Pos00`               | 0-based position class with comparison operators                |
| `Extmark`             | Wrapper around Neovim's extmark API                             |
| `Ctx`                 | Component context (props, state, lifecycle)                     |
| `Morph`               | Main renderer class                                             |

## Core Concepts

### Type Hierarchy

```
Tree (abstract, recursive)
├── nil / boolean (produce no output)
├── string / number (text content)
├── Tag (created by h())
│   ├── name: 'text' | Component function
│   ├── attributes: { hl, key, id, nmap, imap, on_change, extmark, ... }
│   └── children: Tree
└── Array of Trees (flattened during rendering)

Element = Tag + Extmark (instantiated, has buffer position)
```

### Key Abstractions

1. **Tag**: A "recipe" for creating an element. Result of calling `h(name, attrs, children)`. Tags are declarative descriptions that don't yet have physical presence in the buffer.

2. **Element**: An instantiated Tag that has been rendered to the buffer. Elements have an associated `extmark` that tracks their actual position and bounds in buffer text.

3. **Component**: A function `(ctx: Ctx) -> Tree` that can have state and lifecycle. Components are called during reconciliation to produce their rendered output.

4. **Ctx (Context)**: Persistent object passed to components containing:
   - `props`: Immutable data from parent
   - `state`: Mutable component-owned state
   - `phase`: `'mount'` | `'update'` | `'unmount'`
   - `children`: Child elements passed to component
   - `update(newState)`: Trigger re-render
   - `refresh()`: Re-render with current state
   - `do_after_render(fn)`: Schedule post-render callback

5. **Morph**: The main renderer class bound to a single buffer.

## Rendering Pipeline

### Static Rendering (`Morph:render()`)

For trees without components (or after components are expanded):

```
Tree
  ↓ markup_to_lines()
lines[] + pending_extmarks[]
  ↓ Levenshtein diff against old lines
minimal buffer edits (nvim_buf_set_lines/set_text)
  ↓ create extmarks at computed positions
Buffer with styled/interactive regions
```

The `markup_to_lines()` function:

- Visits the tree depth-first
- Tracks current position (line, column)
- For strings: splits on `\n`, emits text
- For numbers: converts to string, emits
- For tags: records start position, visits children, records stop position
- Accumulates text content per tag for `on_change` detection

### Component Rendering (`Morph:mount()`)

For trees with components:

```
Tree (with components)
  ↓ reconcile_tree()
  ↓ reconcile_component() for each component
  ↓ Component(ctx) called → returns Tree
  ↓ reconcile children recursively
Simplified Tree (components expanded to tags/text)
  ↓ Morph:render()
Buffer output
```

## Reconciliation Algorithm: Side-by-Side Correlated Visitor

The reconciliation algorithm is the heart of morph.nvim's efficient updates. It uses a **side-by-side (correlated) visitor pattern** - walking the old and new trees together, correlating nodes by identity to determine the minimal set of mount/update/unmount operations.

### The Pattern

Rather than diffing trees independently and then computing changes, morph.nvim walks both trees simultaneously, making decisions at each node about whether to:

- **Update**: Same identity → reuse existing component context
- **Mount**: New node with no corresponding old node
- **Unmount**: Old node with no corresponding new node

This is implemented through three mutually recursive functions:

### `reconcile_tree(old_tree, new_tree)`

The entry point that dispatches based on node types:

- reconcile_tree
- reconcile_array
- reconcile_component

This is where the **side-by-side correlated visitor** pattern is most visible. It walks old and new arrays together, correlating nodes by identity:

**Step 1: Compute identity keys for each node**

```lua
-- tree_identity_key() combines:
-- - node type ('tag', 'component', 'string', etc.)
-- - for components: the function reference
-- - explicit `key` attribute (or array index as fallback)

key = 'component-' .. tostring(tag.name) .. '-' .. tostring(tag.attributes.key or index)
```

**Step 2: Use Levenshtein with custom cost function**

The key insight: nodes with matching identity keys should be updated (cheaper), while different keys require unmount + mount (more expensive):

```lua
local changes = levenshtein {
  from = old_nodes,
  to = new_nodes,
  are_any_equal = false,  -- all nodes need reconciliation
  cost = {
    of_change = function(_, _, old_idx, new_idx)
      -- Matching keys = cheaper (update existing)
      -- Different keys = more expensive (unmount + mount)
      return old_keys[old_idx] == new_keys[new_idx] and 1 or 2
    end,
  },
}
```

**Step 3: Apply changes**

(Code elided)

### Why This Pattern Works

The side-by-side visitor pattern provides several benefits:

1. **State Preservation**: By correlating nodes via identity keys, component state is preserved across re-renders when the same component appears in the same logical position.

2. **Minimal Operations**: Levenshtein finds the minimum edit distance, naturally preferring updates over destroy/recreate.

3. **Depth-First Processing**: Children are fully reconciled before their parent's reconciliation completes, ensuring proper unmount order (children before parents).

4. **Single Pass**: Both trees are walked once together, rather than walking each separately and then diffing.

## Text Diffing (Levenshtein)

The `levenshtein()` function is used for:

1. **Line-level diffing**: Transform old buffer lines to new lines
2. **Character-level diffing**: Within changed lines, find minimal character edits
3. **Array reconciliation**: Match old/new component arrays

The algorithm:

1. Build DP table where `dp[i][j]` = cost to transform `from[1..i]` to `to[1..j]`
2. Backtrack to extract the actual edit sequence
3. Priority when costs tie: delete > add > change (produces more intuitive results for keyed lists)

`Morph.patch_lines()` applies the edits:

- Computes line-level Levenshtein diff
- For each changed line, computes character-level diff
- Applies minimal edits via `nvim_buf_set_lines` and `nvim_buf_set_text`

## Event Handling

### Keymap Handling

1. During `render()`, keymaps from `nmap`, `imap`, `vmap`, `xmap`, `omap` attributes are registered as buffer-local keymaps.

2. **Original keymaps are snapshotted** in `Morph.new()` and restored before each render.

3. On keypress, `_dispatch_keypress(mode, lhs)`:
   - Gets cursor position
   - Calls `get_elements_at(pos)` to find overlapping elements (innermost first)
   - Iterates through handlers, allowing **event bubbling** via `e.bubble_up`
   - Returns the key to execute (or `''` to swallow the keypress)

4. **Swallowing keypresses in normal mode**: Uses `g@` operator with no-op `operatorfunc` (`MorphOpFuncNoop`)

### Text Change Detection

1. `nvim_buf_attach` with `on_bytes` callback fires during buffer changes
2. **Problem**: Buffer is in inconsistent state during `on_bytes`
3. **Solution**: `create_buf_watcher()` batches `on_bytes` events and fires callback on `TextChanged` autocmd (when buffer is stable)
4. `_on_bytes_after_autocmd()`:
   - Finds extmarks overlapping the changed region
   - Compares cached `tag.curr_text` with current extmark text
   - Fires `on_change` handlers from innermost to outermost with bubbling

## Buffer Management

### Per-Buffer State

- Each `Morph` instance is bound to one buffer
- Namespace created per buffer: `vim.b[bufnr]._renderer_ns`
- Tracks:
  - `changedtick`: Detects external buffer changes
  - `changing`: Flag to ignore self-inflicted changes
  - `textlock`: Prevents immediate re-renders during callbacks
  - `text_content.old/curr`: Lines, extmarks, tag <-> extmark mappings

### Cleanup

- `BufDelete`/`BufUnload`/`BufWipeout` autocmds trigger:
  - Full tree unmount (depth-first)
  - Buffer watcher cleanup

### Textlock Handling

- `is_textlock()` probes by trying to modify a hidden scratch buffer
- When textlocked (e.g., during `on_bytes`), `ctx:update()` schedules the re-render via `vim.schedule()`

## Design Decisions

### Single-File Architecture

The entire framework lives in one file for easy vendoring. Plugin authors can add morph.nvim as a git submodule and require it directly without dependency management concerns.

### No Virtual DOM Diffing

Unlike React, morph.nvim doesn't diff the virtual tree structure. Instead:

- Reconciliation tracks component identity via keys
- Text diffing happens at the buffer level via Levenshtein
- Extmarks track element positions automatically (Neovim handles the bookkeeping)

### Context Object vs Hooks

Uses a persistent `ctx` object instead of React-style hooks:

- Same `ctx` instance across renders
- No hook dependency arrays
- No stale closure issues
- Simpler mental model

### Hyperscript Shorthand

`h.Comment({}, 'text')` automatically sets `hl = 'Comment'` via `__index` metamethod, providing a concise syntax for styled text.

### Event Bubbling

Both keypress and `on_change` events bubble from innermost to outermost elements. Handlers can stop propagation by setting `e.bubble_up = false`.

### Levenshtein Priority

When multiple operations have equal cost, priority is: delete > add > change. This produces more intuitive results when removing items from keyed lists (e.g., removing 'b' from ['a','b'] deletes 'b' rather than substituting 'b' for 'a' and deleting 'a').

### Extmark Gravity

Uses left gravity for start (stays put when text inserted before) and right gravity for end (expands when text inserted at end). This matches the intuitive behavior for text regions.

### TextChanged Batching

`on_bytes` fires during buffer modification when the buffer is in an inconsistent state. Callbacks are deferred to `TextChanged` autocmd when the buffer is stable.
