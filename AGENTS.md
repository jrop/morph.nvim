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

### TextChanged Autocmds in Headless Mode

**Key Understanding**: `TextChanged` autocmds don't fire in headless neovim due to typeahead/operator pending behavior:

- **`TextChanged`/`TextChangedI`/`TextChangedP` autocmds**: Do NOT fire in headless mode, regardless of whether changes are programmatic (`nvim_buf_set_lines`) or simulated user input (`feedkeys`, `vim.cmd.normal`). According to `:help TextChanged`: *"Not triggered when there is typeahead or when an operator is pending."*
- **`nvim_buf_attach` with `on_bytes` callback**: DOES fire reliably in all scenarios (headless, interactive, programmatic, user input).
- **`changedtick`**: Does increment for all buffer changes, providing a way to detect that changes occurred.

This is why tests require manual `vim.cmd.doautocmd 'TextChanged'` calls - the current implementation uses `TextChanged` autocmd to batch `on_bytes` events, but this autocmd never fires in headless test environments.

**Current workaround in tests**: Call `vim.cmd.doautocmd 'TextChanged'` manually after programmatic buffer changes to simulate the autocmd that would fire with real user input.

### Buffer Event Testing

- **Buffer cleanup**: Tests use `with_buf()` wrapper that explicitly calls `vim.cmd.bdelete { bang = true }`, which fires all deletion events (`BufUnload`, `BufDelete`, `BufWipeout`) regardless of `bufhidden` settings
- **Event testing**: To test buffer deletion events, use explicit `vim.api.nvim_buf_delete(bufnr, { force = true })` rather than Vim commands like `:enew` or `:tabclose`, which have inconsistent behavior depending on `bufhidden`

**Note**: Interactive nvim commands with input (like `nvim --headless -c "..."` where commands expect user input) will hang. Always use non-interactive commands or scripts.

### Two Testing Modes for Text-Change (on_change) Behavior

Text-change behavior (`on_change`, `TextChanged`-driven reconciliation) is
tested in two different ways depending on what is under test:

1. **In-process + fake autocmd** (`spec/morph_spec.lua`): The morph instance,
   buffer, and event loop all live in the busted runner's own nvim. Because
   `TextChanged` never fires in headless mode, the test itself triggers it
   manually with `vim.cmd.doautocmd 'TextChanged'` after a programmatic buffer
   change (`nvim_buf_set_text`/`nvim_buf_set_lines`). This is the right choice
   when the *handler logic* is the subject under test (e.g., which elements
   fire, bubbling, batching) and no real user-input timing matters.

2. **Child-nvim + real input** (`spec/on_change_spec.lua`): A fresh child
   nvim (via `lua/morph/_test/nvim.lua`) receives real typed input through
   `nv:input`; real `TextChanged`/`TextChangedI` autocmds and `on_bytes` events
   fire naturally, as do real undo/redo (`u`, `<C-r>`) and RPC round-trips that
   act as the event-loop flush point. Choose this when the behavior depends on
   real input timing or genuine autocmd firing (undo/redo granularity, typed
   insert-mode changes). Programmatic child-side edits
   (`nvim_buf_set_text`, `nvim_buf_set_lines`) still fire events on the next
   round-trip; `M.drain(ms)` flushes scheduled re-renders.

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
