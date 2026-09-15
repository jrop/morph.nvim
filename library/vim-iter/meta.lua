---@meta

-- The analyzer does not apply `@operator call` when checking a call through
-- nvim's runtime annotation for vim.iter (an IterMod table), so every
-- `vim.iter(x)` reports "expected 0 parameters but found 1". Re-annotate it
-- as a plain function; the `Iter` class and its chain methods still come
-- from $VIMRUNTIME, so chained calls keep their existing checking.

---@param src any
---@return Iter
function vim.iter(src) end
