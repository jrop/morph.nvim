# morph.nvim Architecture

This document describes the internal architecture of morph.nvim, a React-like component library for Neovim buffers.

## Overview

morph.nvim is implemented as a single file (`lua/morph.lua`) for easy vendoring by plugin authors. It provides a declarative, component-based API for building interactive text UIs in Neovim buffers.

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
│   │   reconcile() <--> reconcile_component()                    │   │
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

The single file is organized into parts. Each part opens with a banner stating
its role:

| Part  | Responsibility                                                        |
| ----- | --------------------------------------------------------------------- |
| I     | Tree model, type definitions, and `h()`                               |
| II    | Core types: environment checks, `Pos00`, `Extmark`, `Ctx`, `RenderError` |
| III   | Reconciliation (the `Reconciler`)                                     |
| IV    | Text generation and diffing: `markup_to_lines`, `diff_to_band`, `patch_lines` |
| V     | The `Morph` instance: render, mount, element queries, key dispatch    |
| VI    | The change guard: buffer watcher and readonly policing                |
| VII   | The undo probe: region-scoped undo/redo                               |
| Annex | `ErrorBoundary`, `Portal`, `FloatingWindow`, and hook helpers         |

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
  ↓ reconcile()
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

### `reconcile(old_tree, new_tree)`

The entry point that dispatches based on node types:

- `reconcile` (primitives, tags, and dispatch)
- `reconcile_array`
- `reconcile_component`

The array walk is where the **side-by-side correlated visitor** pattern is most
visible. It correlates nodes by identity:

**Step 1: Compute identity keys for each node**

```lua
-- the identity-key helper combines:
-- - node type ('tag', 'component', 'string', etc.)
-- - for components: the function reference
-- - explicit `key` attribute (or array index as fallback)

key = 'component-' .. tostring(tag.name) .. '-' .. tostring(tag.attributes.key or index)
```

**Step 2: Pair new nodes with old ones by key**

A single pass builds `old_by_key`, then a second pass looks each new node's key
up in it. This is O(n), which matters for long lists.

**Step 3: Reconcile each pair, then unmount the leftovers**

Matched pairs reconcile recursively against their old node; unmatched new nodes
mount fresh; old nodes whose key was never claimed unmount.

### Why This Pattern Works

The side-by-side visitor pattern provides several benefits:

1. **State Preservation**: By correlating nodes via identity keys, component state is preserved across re-renders when the same component appears in the same logical position.

2. **Minimal Operations**: Key matching prefers updates over destroy/recreate, so only genuinely new or removed nodes pay mount/unmount costs.

3. **Depth-First Processing**: Children are fully reconciled before their parent's reconciliation completes, ensuring proper unmount order (children before parents).

4. **Single Pass**: Both trees are walked once together, rather than walking each separately and then diffing.

## Text Diffing (Levenshtein)

The `levenshtein()` function is used for:

1. **Line-level diffing**: Transform old buffer lines to new lines
2. **Character-level diffing**: Within changed lines, find minimal character edits

The algorithm:

1. Build DP table where `dp[i][j]` = cost to transform `from[1..i]` to `to[1..j]`
2. Backtrack to extract the actual edit sequence
3. Priority when costs tie: delete > add > change (produces more intuitive results for keyed lists)

`Morph.patch_lines()` applies the edits:

- Computes line-level Levenshtein diff
- For each changed line, computes character-level diff
- Applies minimal edits via `nvim_buf_set_lines` and `nvim_buf_set_text`

`patch_lines()` can diff against either the live buffer or a snapshot. A
snapshot is only valid while the buffer still matches it, and `b:changedtick`
is the proof: every write (the render's own patch, a user edit, an undo, the
probe) bumps it. So `render()` records the tick after patching and passes
`text_content.lines` as the old side on the next render only when the tick
still matches; a mismatch falls back to fetching the live lines. This skips a
full-buffer read on the common "render changed nothing" pass without ever
diffing stale text.

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
4. `_on_bytes_burst()`:
   - Diffs the render's line snapshot against the live lines to get the dirty band
   - Reads each tag's live span text in the band and compares it with cached `tag.curr_text`
   - Fires `on_change` handlers from innermost to outermost with bubbling

### Readonly Guard

The 3-state `readonly` attribute is enforced by the same text-change path.
General principle: **the buffer must always match the tree** -- locked text
belongs to the app, editable holes belong to the user. A running example
anchors the pieces: an app renders `Filter: [<hole>]` plus a heading that
re-renders as `## Containers (filter: fl)` whenever the hole's filter
changes.

- **Detection**: each buffer-change batch is diffed against the render's line
  snapshot to yield a dirty band, then the tags intersecting that band have
  their live span text read and compared with the snapshot cached at render
  time (`tag.curr_text`). Example: typing `f` in the hole changes its live text
  to `f` while its snapshot still says '' (empty) -- that mismatch is the edit.
  O(elements in the band) per batch; at TUI scale this is negligible.
- **Violation**: a locked element whose text changed with no changed editable
  tag nested inside it (structural nesting via the `parent` chain, not
  position) triggers a full-tree revert via the normal render pipeline.
  Example: typing into the `Filter: [` chrome changes locked
  text no hole explains -- the guard reverts it. The violated spans flash
  (`Search` highlight) and the cursor is restored to where the rejected edit
  found it -- sampled before nvim's own cursor adjustment, so line deletes
  recover the pre-clamp column. The restore targets the first window showing
  the buffer; with the buffer displayed in multiple windows simultaneously
  the non-originating window's cursor is not tracked.
- **Bounded exception**: an edit that rewrites a hole's whole content with the
  same bytes diffs to nothing and is accepted. Example: `ciw` on the hole's
  whole content, or a visual-select replaced by identical text, leaves the band
  unchanged. Any edit touching bytes outside the hole reverts.
## Buffer Management

### Per-Buffer State

- Each `Morph` instance is bound to one buffer
- Namespace created per buffer: `vim.b[bufnr]._renderer_ns`
- `Morph` owns the buffer-side state:
  - `changing`: Flag to ignore self-inflicted changes
  - `textlock`: Prevents immediate re-renders during callbacks
  - `text_content`: the render's line snapshot, and the tag <-> extmark id maps
  - `changedtick`: the buffer tick recorded when that snapshot was last synced;
    a matching tick proves the snapshot is still the live text
  - `probe`: the hidden undo-probe buffer, created by the first render with editable holes
- Each mount adds a `Reconciler`, which owns component state and lifecycle: the
  tree, the last reconciled tree, the render trace, the after-render callback
  queue, and the debounce timer

### Cleanup

- `BufDelete`/`BufUnload`/`BufWipeout` autocmds trigger:
  - Full tree unmount (depth-first)
  - After-render callbacks drained (registered during the unmount phase)
  - Buffer watcher cleanup
- `renderer:unmount()` runs the same teardown on demand: fires all unmount
  phases, restores pre-morph keymaps, clears morph extmarks, and resets
  instance state. Buffer **content stays** — callers clear it themselves if
  needed. Idempotent (a buffer deletion may already have run teardown), and
  after unmounting, the same buffer/instance can be mounted again.
- The `Portal` component manages the lifecycle of its inner document: it
  unmounts it on Portal unmount and creates a fresh `Morph.new(bufnr)` on each
  mount, so toggling a Portal off/on with a stable `bufnr` works.

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
