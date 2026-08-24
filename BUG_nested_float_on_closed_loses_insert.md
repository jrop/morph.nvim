# BUG REPORT: Nested float opened from `on_closed` loses `startinsert`

## Summary

When a second `FloatingWindow` is opened from within the `on_closed`
callback of a first `FloatingWindow`, a `startinsert` issued in the
second float's `on_win_create` does **not** take effect. The editor
stays in normal mode, so the second float's input field is not editable.

The bug is in `morph.nvim`'s `restore_mode_and_wait` (used by
`FloatingWindow`'s close path): the `work` callback — which fires
`on_closed`, which in turn opens the next float — runs **synchronously
inside the `ModeChanged` autocmd** that confirms the `i→n` transition
caused by `stopinsert`. A `startinsert` issued nested within that
autocmd context does not stick.

## Environment

- morph.nvim `artifact-v0.1.27` (submodule @ `4b03cdb`), also present as
  standalone `/home/jonathan/.local/share/nvim/site/pack/core/opt/morph.nvim`.
- Reproduced against Neovim 0.12.4 (interactive TTY). The child-`nvim --embed`
  harness also verifies the fix; see "Update" below.
- Discovered via `tuis.nvim`'s `vim.ui.select` picker: opening a second
  picker from the first picker's `on_choice` callback (e.g. the
  `(clipboard): Switch provider` command launched from `my.cmdp`)
  leaves the second picker in normal mode.

## Root cause

`lua/morph.lua` — `restore_mode_and_wait(target_mode, callback)`:

```lua
mode_changed_id = vim.api.nvim_create_autocmd('ModeChanged', {
  pattern = mode_pattern,
  once = true,
  nested = true,
  callback = function()
    fallback_timer:stop()
    pcall(vim.api.nvim_del_autocmd, mode_changed_id)
    callback()                       -- <-- runs INSIDE the ModeChanged autocmd
  end,
})

if target_mode == 'n' then
  vim.cmd.stopinsert()               -- triggers ModeChanged i:n -> above autocmd
```

`FloatingWindow.close_transition` calls:

```lua
restore_mode_and_wait(prev_mode, function() work(true) end)
```

`work(true)` restores focus/cursor, then fires `props.on_closed()`. If
`on_closed` opens a new float whose `on_win_create` runs
`vim.cmd.startinsert()`, that `startinsert` executes while the
`i:n` ModeChanged autocmd is still on the stack. The nested insert
request is lost and the editor reverts to `n`.

The condition is precise: it only manifests when the *first* float was
in insert mode (so `prev_mode == 'n'` and `current != target`, forcing
the `stopinsert`→ModeChanged path). If the first float is opened from
insert mode (`prev_mode == 'i'`), the close path short-circuits
(`current == target`), no ModeChanged autocmd fires, and the second
float's `startinsert` lands cleanly.

## Steps to reproduce (interactive)

Using `tuis.nvim`'s `vim.ui.select` picker with the real user config
(`~/.config/nvim`), `register_ui_select` active:

1. Start nvim in a TTY (NOT headless):
   `nvim --listen /tmp/repro.sock /tmp/scratch.txt`
2. From **normal** mode, trigger a `vim.ui.select` picker bound to
   `<M-p>` (`my.cmdp`).
3. The first picker opens; mode is `i` (confirmed via RPC
   `mode(1)`).
4. Move to an entry whose `on_choice` opens a *second* picker (e.g.
   `(clipboard): Switch provider`) and press `<CR>`.
5. The second picker opens, but `mode(1)` reports `n`; typing into the
   search field does not register.

Control: repeat step 2 from **insert** mode (`i` then `<M-p>`) — the
second picker opens in `i` and typing filters the list. This is the
same code path with a different `prev_mode`, which is why the bug is
mode-dependent.

## Failing test

`spec/nested_float_probe_spec.lua` — a single self-contained test:
"second float opened from first on_closed is in insert mode". It uses the
child-`nvim --headless --embed` harness (`morph._test.nvim`), mounts float
A (insert on open), closes A whose `on_closed` opens float B with a plain
`startinsert`, and asserts `mode == 'i'`.

Against the current (unfixed) `lua/morph.lua`:

```
$ busted --verbose spec/nested_float_probe_spec.lua
0 successes / 1 failure / 0 errors / 0 pending

Failure -> spec/nested_float_probe_spec.lua @ 44
nested float insert mode second float opened from first on_closed is in insert mode
spec/nested_float_probe_spec.lua:76: Expected objects to be equal.
Passed in:
(string) 'n'
Expected:
(string) 'i'
```

### Update: the fix IS verifiable under the child-nvim harness

An earlier draft of this report claimed the child-`nvim --headless --embed`
harness could demonstrate the bug's *presence* but not validate the *fix*
("headless cannot confirm the fix"). That caveat was **wrong**. The child is
headless but has a real event loop driven by RPC — it is NOT subject to the
**host** (busted runner) nvim's insert-pending-state leak (that leak is a
host-only artifact; see `AGENTS.md`'s "Test Environment Notes" host/child split).

The fix is verified by the regression test absorbed into
`spec/floating_window_spec.lua` (describe block "FloatingWindow nested open
from on_closed"), which runs entirely under the child harness:

- Float A's `on_win_create` calls `startinsert`; a subsequent RPC round-trip
  confirms `mode == 'i'` (programmatic `startinsert` DOES enter insert in the
  child — it is just not visible within the same `exec_func` that issued it; the
  mode change flushes across the round-trip).
- Closing A opens B from `on_closed`; B's `on_win_create` calls `startinsert`.
- Real input (`nv:input 'w'`) into B must land in B's buffer.
  - **Without the fix**: B's `startinsert` runs nested inside the `i:n`
    ModeChanged autocmd and does not stick; B stays in normal mode; `w` is
    consumed as a motion; B's buffer stays `{ '' }`.
  - **With the fix**: `startinsert` is deferred onto a clean tick; B is in
    insert; `w` inserts; B's buffer is `{ 'w' }`.

Buffer content after real input is the user-facing symptom and is directly
observable under the child harness — no interactive TTY run is required. (The
original interactive TTY confirmation remains valid as defense in depth.)


## Proposed fix

Defer `work` (the `callback`) onto a clean event-loop tick so it runs
*outside* the `ModeChanged` autocmd. This lets the `i→n` transition
settle before `on_closed` (and any downstream float open + startinsert)
executes.

```diff
--- a/lua/morph.lua
+++ b/lua/morph.lua
@@ -2062,12 +2062,14 @@ local function restore_mode_and_wait(target_mode, callback)
   local mode_pattern = current_mode .. ':' .. target_mode
   local mode_changed_id
+  local function schedule_callback() vim.schedule(callback) end
   local fallback_timer = vim.defer_fn(function()
     pcall(vim.api.nvim_del_autocmd, mode_changed_id)
-    callback()
+    schedule_callback()
   end, 500)

   mode_changed_id = vim.api.nvim_create_autocmd('ModeChanged', {
     pattern = mode_pattern,
     once = true,
     nested = true,
     callback = function()
       fallback_timer:stop()
       pcall(vim.api.nvim_del_autocmd, mode_changed_id)
-      callback()
+      schedule_callback()
     end,
   })
```

### Verification (interactive TTY)

Applied to the morph submodule (`lua/tuis/_internal/morph/init.lua`),
with tuis `ui.lua` left **untouched** (i.e. the picker's
`on_win_create` still calls `vim.cmd.startinsert { bang = true }`
synchronously):

- Repro step 5 → `mode(1)` reports `i`; typing `wl` filters the second
  picker's list. Bug resolved.
- Morph's own suite (with the probe spec removed) stays green:
  `212 successes / 0 failures / 0 errors`.

### Alternatives considered

- **Fix in `tuis.nvim` (`ui.lua:260`)**: wrap the picker's
  `startinsert` in `vim.schedule`. This is the existing pattern in
  `grep.lua:199` / `ripgrep.lua:224` ("Restore insert mode in picker
  window after popup closes"). It masks the symptom for pickers but
  leaves the underlying morph defect for any other `FloatingWindow`
  consumer that opens a nested float from `on_closed`. Prefer the
  morph-level fix; the tuis `vim.schedule` wrap can stay as defense in
  depth or be removed once morph is fixed.
- **Drop the `ModeChanged` autocmd entirely**, replacing it with
  `stopinsert()` + `vim.schedule(callback)`. Simpler, but loses the
  "wait until the mode change actually takes effect" guarantee the
  autocmd provides (the existing fallback timer is 500 ms; a blind
  schedule is a one-tick bet). The minimal diff above preserves the
  autocmd's timing semantics while only decoupling the *callback
  execution* from the autocmd stack.

## Files

- Bug: `lua/morph.lua` — `restore_mode_and_wait` (~line 2056)
- Failing test: `spec/nested_float_probe_spec.lua` (case 1)
