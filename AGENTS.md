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

This is why tests require manual `r.buf_watcher.fire()` calls - the current implementation uses `TextChanged` autocmd to batch `on_bytes` events, but this autocmd never fires in headless test environments.

**Current workaround in tests**: Call `vim.cmd.doautocmd 'TextChanged'` manually after programmatic buffer changes to simulate the autocmd that would fire with real user input.

### Buffer Event Testing

- **Buffer cleanup**: Tests use `with_buf()` wrapper that explicitly calls `vim.cmd.bdelete { bang = true }`, which fires all deletion events (`BufUnload`, `BufDelete`, `BufWipeout`) regardless of `bufhidden` settings
- **Event testing**: To test buffer deletion events, use explicit `vim.api.nvim_buf_delete(bufnr, { force = true })` rather than Vim commands like `:enew` or `:tabclose`, which have inconsistent behavior depending on `bufhidden`

### Testing Neovim Behaviors Interactively

When you need to quickly test Neovim behaviors outside of the formal test suite:

1. **Create a test script**: Create a standalone `.lua` file (e.g., `test_behavior.lua`) in the project root
2. **Write the test**: Use standard Lua and Neovim API calls. The script should end with `vim.cmd.qall { bang = true }` to exit
3. **Run the test**: Execute with `nvim --headless -u NONE -c "set rtp+=." -c "luafile test_behavior.lua" 2>&1`
   - `--headless`: Run without UI
   - `-u NONE`: Don't load user config
   - `-c "set rtp+=."`: Add current directory to runtime path so `require 'morph'` works
   - `-c "luafile test_behavior.lua"`: Execute your test script
   - `2>&1`: Capture all output
4. **Clean up**: Delete test files when done (they should not be committed)

**Example test script**:
```lua
#!/usr/bin/env nvim -l
local Morph = require 'morph'
-- Your test code here
vim.print('Testing something...')
vim.cmd.qall { bang = true }
```

**Note**: Interactive nvim commands with input (like `nvim --headless -c "..."` where commands expect user input) will hang. Always use non-interactive commands or scripts.

## Code Style Guidelines

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
