# morph.nvim - Agent Development Guide

## General Methodology

When asked to add a feature, start with adding a failing test, then the feature.

## Build/Lint/Test Commands

- `mise run ci` - Run lint, format check, and tests
- `mise run lint` - Typecheck with emmylua_check
- `mise run fmt` - Format code with stylua
- `mise run fmt:check` - Check code formatting
- `mise run test` - Run tests with busted

**Single test**: Use busted directly: `busted --verbose --filter='"<FULL TEST NAME HERE>"'`

## Test Environment Notes

Tests run across two distinct neovim instances. **Both are headless**, but they
behave differently — the word "headless" alone is NOT the distinguishing axis;
the host/child boundary is.

- **Host (busted runner) nvim**: the process running the busted test suite. Its
  event loop is driven by the test runner, not real input.
- **Child (embedded) nvim**: a fresh `nvim --headless --embed` spawned per test
  via `lua/morph/_test/nvim.lua`, driven over msgpack-RPC. It has a real event
  loop, real autocmds, and real input — the host's limitations do NOT transfer
  to the child.

**Decision rule**: if a test needs real autocmd/input timing or genuine mode
changes, use the child-nvim harness; otherwise in-process host tests are fine.
When in doubt, prefer the child-nvim mode since it exercises the real event
loop end to end.

### Host: TextChanged autocmds never fire

`TextChanged` autocmds don't fire in the **host** (busted runner) nvim due to
typeahead/operator pending behavior:

- **`TextChanged`/`TextChangedI`/`TextChangedP` autocmds**: Do NOT fire in the
  host, regardless of whether changes are programmatic (`nvim_buf_set_lines`)
  or simulated user input (`feedkeys`, `vim.cmd.normal`). According to
  `:help TextChanged`: *"Not triggered when there is typeahead or when an
  operator is pending."*
- **`nvim_buf_attach` with `on_bytes` callback**: DOES fire reliably in all
  scenarios (host, child, interactive, programmatic, user input).
- **`changedtick`**: Does increment for all buffer changes, providing a way to
  detect that changes occurred.

This is why host-side tests require manual `vim.cmd.doautocmd 'TextChanged'`
calls — the current implementation uses `TextChanged` to batch `on_bytes`
events, but that autocmd never fires in the host test environment.

**Current workaround in tests**: Call `vim.cmd.doautocmd 'TextChanged'` manually
after programmatic buffer changes to simulate the autocmd that would fire with
real user input.

### Host: insert-pending state leaks across specs

In the **host** nvim, `:startinsert` sets nvim's internal insert-pending state
even though headless scripts never truly enter insert mode (`mode()` reports
`n`). The float-close path short-circuits (mode already `n`), so `:stopinsert`
is never called and the state leaks into later specs, flipping how nvim anchors
the cursor on subsequent `nvim_buf_set_text` calls. This is why host-side specs
(see `spec/floating_window_spec.lua`'s in-process block) clear it with
`after_each(function() vim.cmd.stopinsert() end)`.

**This is a host-only artifact. The child does not have it** (see below).

### Child: real autocmds, real input, RPC round-trips flush

The **child** (`morph._test.nvim`) is also `--headless`, but it has a real
event loop driven by RPC. Key consequences — all proven by green tests:

- **Programmatic `:startinsert` DOES enter insert** in the child. It is just
  not visible within the *same* `exec_func` call that issued it; the mode
  change is only observable across an **RPC round-trip** (a later `exec_func`),
  which acts as the event-loop flush point. So: read mode/insert observability
  *after* a round-trip, never in the same `exec_func`.
- **Real input** (`nv:input 'i'`, `nv:input 'w'`) drives genuine mode changes
  and inserts into buffers — observable via buffer content or `mode()` after a
  round-trip.
- **`TextChanged`/`TextChangedI` fire naturally** from real keystrokes, as do
  real undo/redo (`u`, `<C-r>`). Programmatic child-side edits
  (`nvim_buf_set_text`, `nvim_buf_set_lines`) still fire events on the next
  round-trip; `util.drain(ms)` flushes scheduled re-renders.
- **No insert-pending leak**: the host's `after_each stopinsert` guard is
  unnecessary for child-only specs; each child is fresh and torn down per test.

### Buffer Event Testing

- **Buffer cleanup**: Tests use `with_buf()` wrapper that explicitly calls
  `vim.cmd.bdelete { bang = true }`, which fires all deletion events
  (`BufUnload`, `BufDelete`, `BufWipeout`) regardless of `bufhidden` settings
- **Event testing**: To test buffer deletion events, use explicit
  `vim.api.nvim_buf_delete(bufnr, { force = true })` rather than Vim commands
  like `:enew` or `:tabclose`, which have inconsistent behavior depending on
  `bufhidden`

**Note**: Interactive nvim commands with input (like `nvim --headless -c "..."`
where commands expect user input) will hang. Always use non-interactive commands
or scripts.

### Two Testing Modes for Text-Change (on_change) Behavior

Text-change behavior (`on_change`, `TextChanged`-driven reconciliation) is
tested in two different ways depending on what is under test:

1. **In-process + fake autocmd** (`spec/morph_spec.lua`): The morph instance,
   buffer, and event loop all live in the **host** (busted runner) nvim.
   Because `TextChanged` never fires in the host, the test itself triggers it
   manually with `vim.cmd.doautocmd 'TextChanged'` after a programmatic buffer
   change (`nvim_buf_set_text`/`nvim_buf_set_lines`). This is the right choice
   when the *handler logic* is the subject under test (e.g., which elements
   fire, bubbling, batching) and no real user-input timing matters.

2. **Child-nvim + real input** (`spec/on_change_spec.lua`): A fresh **child**
   nvim (via `lua/morph/_test/nvim.lua`) receives real typed input through
   `nv:input`; real `TextChanged`/`TextChangedI` autocmds and `on_bytes` events
   fire naturally (see "Child" above). Choose this when the behavior depends
   on real input timing or genuine autocmd firing (undo/redo granularity, typed
   insert-mode changes).

Choose per-test on a "what am I actually testing?" basis; when in doubt, prefer
the child-nvim mode since it exercises the real autocmd path end to end.

## Code Style Guidelines

### Runtime
- LuaJIT, do **NOT** use goto

### Formatting
- Use stylua with 2-space indentation, 100 char column width
- Prefer single quotes, auto-prefer single quotes
- No call parentheses for simple statements
- Collapse simple statements always
- Sort requires automatically

### Type Annotations
- Use EmmyLua type annotations (`--- @param`, `--- @return`, `--- @type`)
- Follow patterns in existing code: `morph.Ctx<Props, State>`
- Component functions should annotate props and state types

### Naming Conventions
- Components: PascalCase (e.g., `Counter`, `TodoList`)
- Functions/variables: snake_case
- Constants: UPPER_SNAKE_CASE
- Local variables: concise but descriptive

### Imports
- Use `require 'module'` (single quotes, no parentheses)
- Group imports at top of file
- Use local aliases: `local Morph = require 'morph'`

### Error Handling
- Use pcall for error boundaries in tests
- Return empty string from event handlers to consume keypress
- Validate inputs in component functions

### Component Patterns
- Use context object (`ctx`) for state management
- Initialize state in `ctx.phase == 'mount'` condition
- Use `ctx:update(new_state)` to trigger re-renders (`ctx:refresh()` is short-hand for `ctx:update(ctx.state)`)
- Return arrays/tables of elements, not strings with concatenation
