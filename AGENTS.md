# morph.nvim - Agent Development Guide

## Build/Lint/Test Commands

- `make all` - Run lint, format check, and tests
- `make lint` - Typecheck with emmylua_check
- `make fmt` - Format code with stylua
- `make fmt-check` - Check code formatting
- `make test` - Run all tests with coverage (busted)
- `make watch` - Watch for changes and run make automatically

**Single test**: Use busted directly: `busted --verbose --filter='"<FULL TEST NAME HERE>"'`

## Code Style Guidelines

### Formatting
- Use stylua with 2-space indentation, 100 char column width
- Prefer single quotes, auto-prefer single quotes
- No call parentheses for simple statements
- Collapse simple statements always
- Sort requires automatically

### Type Annotations
- Use EmmyLua type annotations (`---@param`, `---@return`, `---@type`)
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
