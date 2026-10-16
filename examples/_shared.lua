--- Shared components for the morph examples.
---
--- Examples are launched with `:luafile %`, so each example that needs this
--- module first adds its own directory to package.path, then does
--- `require '_shared'`.

local Morph = require 'morph'

local Shared = {}

---
--- Table component: renders a grid of cells as text trees, padding each
--- column to the width of its widest cell. The per-cell text is computed
--- once and cached, since markup_to_string is the expensive part.
---
--- @param ctx morph.Ctx<{ cells: morph.Tree[][] }, any>
--- @return morph.Tree
function Shared.Table(ctx)
  local cells = ctx.props.cells
  local max_widths = {}

  -- Cache for cell text to avoid calling markup_to_string twice per cell
  local cell_text_cache = {}

  -- Calculate max width for each column
  for col_idx = 1, #cells[1] do
    local max_width = 0
    for row_idx = 1, #cells do
      local cell = cells[row_idx][col_idx]
      if not cell_text_cache[row_idx] then cell_text_cache[row_idx] = {} end
      local cell_text = Morph.markup_to_string { tree = cell }
      cell_text_cache[row_idx][col_idx] = cell_text
      local width = #cell_text + 1
      if width > max_width then max_width = width end
    end
    max_widths[col_idx] = max_width
  end

  local result = {}

  for row_idx, row in ipairs(cells) do
    if row_idx > 1 then table.insert(result, '\n') end

    for col_idx, cell in ipairs(row) do
      table.insert(result, cell)

      if col_idx < #row then
        -- Padding uses the cached cell text instead of recalculating
        local cell_text = cell_text_cache[row_idx][col_idx]
        local cell_width = #cell_text
        --- @type integer
        local needed_padding = max_widths[col_idx] - cell_width

        if needed_padding > 0 then table.insert(result, string.rep(' ', needed_padding)) end
      end
    end
  end

  return result
end

return Shared
