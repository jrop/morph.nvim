# READONLY.md — region-aware undo/redo: design state and session handoff

This file is the pickup point for the undo/redo redesign discussion. It captures
where the code stands, what was tried and reverted, the nvim constraints any
design must respect, and the open decision. Read top to bottom before touching
`lua/morph.lua`.

## Status snapshot (as of this writing)

- Repo: `~/.local/share/nvim/site/pack/core/opt/morph.nvim`, HEAD = `1fb5851`
  ("(readonly) simplification pass 2").
- `lua/morph.lua` is **byte-identical to HEAD**: the guard is fully **strict**.
  No traversal acceptance, no snapshot re-anchoring, no draw deferral. The
  strict behavior: any external change (including `u`/`<C-r>`) that moves
  locked text without an explaining hole edit is a violation — flash + full
  re-render + cursor restore.
- Uncommitted working-tree changes (all intentional, all doc/test only):
  - `ARCHITECTURE.md`: new uncommitted `### Readonly Guard` section
    (Detection / Violation / Bounded-exception bullets) documenting the strict
    guard, written in the communication style. No undo/redo or deferral
    content — those were stripped when the fixes were reverted.
  - `README.md`: the `readonly` bullet was **trimmed** at the user's request
    (the giant paragraph became a compact one pointing at ARCHITECTURE.md).
    HEAD still has the giant paragraph; the trim is uncommitted.
  - `spec/readonly_spec.lua`: one new regression test kept —
    `accepts pasting into the hole with the cursor on the opening bracket`
    (passes under strict; paste into a hole is an ordinary hole edit).
  - `CHANGELOG.md` is untracked; it currently matches HEAD content (the
    Unreleased entries describing the reverted fixes were removed).
- Verification state: 248 tests green on 0.10.4 / 0.11.7 / 0.12.5 / nightly;
  `mise run fmt:check` clean; `mise run lint` at its 28-warning baseline
  (all pre-existing; zero new).
- There is a **stale `stash@{0}`** in morph.nvim from an old session
  ("WIP on main: 68dcbaa" — pre-readonly Portal/FloatingWindow work whose
  contents were later committed as `6bd58a0`). It is safe to drop, but it was
  left alone deliberately.

## The feature as it exists (strict)

- `readonly` is 3-state per tag (`true` locks, `false` carves an editable
  hole, nil inherits); `Morph.new(bufnr, { readonly = true })` locks the whole
  render (top-level bare strings get implicit text tags).
- `undo = 'merge'` folds renders that answer an external change into the
  user's undo block via `:undojoin`, so `u` undoes an edit and its rendered
  reflection together. First render never joins (seeded changedtick); renders
  with no causal change stay their own entries.
- The guard (`_on_bytes_after_autocmd`, driven by a watcher that batches
  `on_bytes` and fires on `TextChanged`): sweeps every rendered tag's live
  span text against `tag.curr_text` / `tag.curr_span` (stored in pre-change
  coordinates); a locked mismatch with no explaining editable hole (hole span
  brackets the change AND sits inside the locked span) → violation → flash
  (`Search` highlight) → full re-render from the tree → cursor restored from
  the pre-edit sample. Bounded exception: an edit whose pre-edit range equals
  the hole's last-accepted span (e.g. `ciw`) is accepted.
- Controlled holes (with `on_change`) are the contract that keeps hole content
  alive across reverts; app state re-renders everything else.

## Problem history (what was reported, learned, and reverted)

1. **"Paste with cursor on `[` rejected"** — could never be reproduced. Paste
   into a hole with the cursor on the `[` works natively; the likely real
   causes of the observed flash are all correct rejections: `P` instead of
   `p`, cursor one column left (on the space), or a linewise register.
   A regression test now pins the acceptance (`...opening bracket` test).
2. **Merge-undo flash (reproduced, fixed, reverted)** — with
   `undo = 'merge'`, `u` after pasting into a controlled filter undoes the
   paste AND the app's re-render reflection (e.g. a heading embedding the
   filter text). The guard saw the reflection as a locked mismatch that no
   hole explains → flash + re-render → the undo was visually canceled.
   Fix was: detect traversals at guard time and accept them wholesale.
3. **Redo silently dead after background renders (reproduced, fixed,
   reverted)** — the lsof app refreshes its table on a 2s timer; a refresh
   render landing between `u` and `<C-r>` created a new undo entry branching
   off the undone state; nvim abandons the undone branch, so `<C-r>` became a
   silent no-op (no flash — the guard never saw a batch). Fix was: defer
   draws while the pointer sat below the tip.
4. Both fixes were **reverted at the user's direction** because suppression
   below the tip leaves the historical view visually broken (extmarks still
   describe the tip layout) and freezes app-state updates. The user wants
   real rendering at all times — see the design goal below. If similar
   machinery is ever rebuilt, its shape is recorded here:
   - Traversal acceptance: sample `undotree()` at every guard batch (gate:
     `#locked > 0 or readonly_default`; lazy baseline because `undotree()`
     reads the *current* buffer). `is_history = seq_cur < seq_last` (any
     write lands at the tip, so only a traversal is non-tip) OR
     (`seq_cur` moved while `seq_last` stayed put — catches redo-to-tip).
     History batches skip the violation sweep, commit hole mismatches +
     re-anchor locked snapshots to live text, and fire `on_change` (the app
     re-syncs; its re-render rebuilds anything it disagrees with).
   - Draw deferral: in `render()`, if the stored sample says non-tip, return
     early (before any buffer mutation). Safe because draws are full
     re-renders of current state (dropping one loses nothing), and the sample
     cannot go stale in the dangerous direction: the only pointer-moving op
     that bypasses a guard batch is morph's own draw (guard returns early on
     `changing`), and deferral confines morph's draws to the tip.

## nvim constraints any design must respect (empirically verified)

- **Undo is per-buffer and tree-shaped; writes below the tip branch, and nvim
  abandons the undone branch.** This is why a single background write between
  `u` and `<C-r>` silently kills redo. There is **no API to write without
  creating an undo entry**: the `undolevels = -1` trick was tested and it
  *destroys the entire undo tree* (`entries` becomes empty); `undolevels = 0`
  for one write *does* suppress that write's entry but collapses the whole
  history to a single entry (verified later in `ul_clean.lua`). Both are
  unusable for "write without recording" at a non-tip position. Entry
  boundaries *can* be controlled within an existing tree, however: `let
  &undolevels = &undolevels` before a write forces a new entry, and
  `:undojoin` merges into the current one.
- `:undojoin` raises E790 immediately after an undo, so the first render after
  an undo cannot fold its writes into the traversal; they branch.
- `undotree()` reads the *current* buffer's tree; `seq_cur`/`seq_last`
  semantics: any write (user's or morph's) moves `seq_cur` onto the tip;
  undo/redo move `seq_cur` below it. `:redo` (ex command) works even when
  `<C-r>` keystroke delivery is broken — useful for disambiguating "dead
  branch" from "key not delivered".
- `TextChanged` is suppressed by typeahead: `vim.cmd 'normal! p'` inside a
  child-nvim `exec_func` does NOT fire it (the guard gets its batches late or
  never). Probes/tests must use real keystrokes via `nv:input`.
- `nv:input` needs the plain notation form `'<C-r>'`; the raw byte `'\29'`
  was dropped by the harness, and `'\\<C-r>'` (backslash-escaped) also fails.
- `vim.fn.undotree()` builds the whole tree — that is why sampling was gated
  on "something to guard" when the acceptance machinery existed.

## The design goal (user's stated intent)

- undo/redo should **govern only the editable regions** (holes, where
  `readonly = false`); in the lsof case, that means the filter text.
- App-state updates (background refreshes, timers, async data) must render
  **continuously and independently** — never suppressed, never entangled with
  undo/redo, in every state including below the tip.
- Highlights/extmarks must always be correct, which the user says requires
  actually rendering — suppressed draws are not acceptable.
- The user's repro app: `~/.local/share/nvim/site/pack/core/opt/tuis.nvim`
  → `lua/tuis/apps/lsof.lua`. Shape: heading (`RenderMarkdownH1`) that embeds
  the filter text (the "Label: asdf" line in the user's repro), a controlled
  filter hole between brackets, a Table filtered per keystroke, and the 2s
  async refresh timer. Runs morph vendored as a submodule.

## The decision on the table (options presented; user has own ideas — ask)

Root cause of the whole tension: **nvim scopes undo per buffer; the user wants
it scoped per region.** Options, in the presented recommendation order:

1. **Option 3 — virtual rendering (recommended).** Render non-editable content
   (heading, table, brackets) as extmark `virt_text`/`virt_lines`; keep real
   buffer text for holes only. Consequence: vim's undo tree contains only hole
   edits, so native `u`/`<C-r>` govern hole text for free; app-state updates
   become extmark updates — drawn continuously in every state, branching
   nothing, with highlights re-derived on every draw. Deletes the guard's
   chrome machinery rather than adding to it. Costs: a renderer virtual mode
   (biggest single piece), display-only chrome (search/yank skip it; the
   cursor cannot enter it — the lsof app already routes yanks through
   `g+`/`g"` keymaps). Suggested middle step: an opt-in per-subtree
   `virtual = true` attribute for incremental migration.
2. **Option 1 — morph-owned per-hole undo.** Strict guard stays; morph keeps
   a Lua-side history of hole contents (coalesced like insert sessions) and
   buffer-local `u`/`<C-r>` mappings that region-write the hole and re-render.
   Most literal region-awareness; costs key stealing and reimplementing
   vim's undo granularity (coalescing, paste-as-one-step, `ciw`).
3. **Option 2 — holes as separate buffers.** Each hole is a borderless float
   over a fully-readonly main buffer; native per-buffer undo *is* region undo.
   Heaviest plumbing (positioning, focus, multi-buffer mounting — Portal
   exists as a starting point); zero emulation; the strict guard is exactly
   right for the main buffer.
4. **Option 4 — the undo-probe buffer (user's proposal; now investigated, see
   below).** A hidden scratch buffer contains *only* the editable-region text
   (one slot per editable span). Every accepted edit in the main buffer is
   mirrored into the probe so the probe's native undo tree grows in lockstep
   with the main buffer's entry boundaries. `u`/`<C-r>` (and `g-`/`g+`, and
   the ex-command forms) are intercepted and replayed against the probe
   instead of the main buffer; after each replay, every editable region's text
   is read out through its probe extmark and written back into the
   corresponding main-buffer span. Wins: (1) undo/redo *ordering* across
   editable regions, (2) Neovim-native undo granularity (insert-session
   coalescing, `ciw`, paste-as-one-step) instead of a hand-rolled history,
   (3) app-state chrome renders become irrelevant to the undo tree. Costs: a
   full region-text sweep per traversal, an interception surface, and a
   structural-change policy for when the region *set* changes between renders.
5. (Rejected) virt overlays only while below the tip — masks symptoms, undo
   stays global, composes badly with tables.

The strict starting point means none of the reverted machinery needs
unsticking: each option is measured from clean.

## tuis.nvim state (flag — needs a decision)

`~/.local/share/nvim/site/pack/core/opt/tuis.nvim` vendors morph as a git
submodule at `lua/tuis/_internal/morph` → `jrop/morph.nvim`, pinned at tag
`artifact-v0.1.28`, **with local modifications that still contain both
reverted fixes** (traversal acceptance + draw deferral; ~441 insertions vs the
tag). All tuis test suites passed with those patches. Consequence: the live
lsof app currently exhibits the lenient behavior while morph.nvim's tree is
strict. When the new design lands in morph.nvim, the submodule must be
re-pointed/re-vendored; until then the two trees disagree by design.

## Harness / test knowledge (for the next session)

- Child-nvim harness: `lua/morph/_test/nvim.lua` + `morph._test.util.lua`.
  Real keystrokes via `nv:input`; `util.drain(ms)` flushes scheduled renders;
  `util.events { clear = true }` reads-and-clears the event sink; snapshots
  must drain before reading text.
- Single-test invocation: `busted --verbose --filter='"<FULL TEST NAME>"'`
  (inner double quotes required; spaces otherwise split into file args).
- Paste-over idiom in tests: position the cursor at the hole START, then
  `vep` (typing also needs the cursor at the hole start, not on the `[`).
- `string.find(s, pattern, 1, true)` is plain-text: write `gamma-3`, not
  `gamma%-3` (a `%-` escape with plain=true cannot match).
- Full verification: `mise run ci` (fmt:check + lint + test:all across
  0.10.4 / 0.11.7 / 0.12.5 / nightly). Lint baseline is 28 pre-existing
  warnings; compare warning-text sets, not raw counts (location lines inflate
  naive greps).
- A run of `mise run test:all` takes ~40s total; single-version
  `eval $(nvimv env 0.12.5) && NVIM_TEST=1 busted` is the fast loop.

## Style note

Explanations in this project follow `~/.agents/skills/communication`
(abstract principle → concrete example → stepwise causal chain with marked
inferences; complete, well-formed sentences; default-vs-exception framing).
Comment rewrites during this conversation followed it and the user confirmed
the pattern.

## Open questions for the next session

- Which option does the user pick (they said they have ideas of their own —
  ask before building).
- If Option 3: per-subtree `virtual = true` opt-in first, or whole-renderer
  flip? What happens to `RenderMarkdownH1`/widget layer in tuis?
- What happens to `undo = 'merge'` under the chosen option (Option 3 makes it
  mostly moot for hole edits; app-driven hole writes still create entries)?
- Should the strict guard keep flashing on traversals until the new design
  lands, or is a smaller stopgap wanted in the meantime?
- The tuis submodule: revert the local lenient patches now, or leave until
  re-vendoring?
- If Option 4: how are editable regions given stable identity (probe slot ->
  region) for the JSON `Record<extmark_id, text>` format? This is deferred
  (see Option 4 investigation, structural-change policy).

## Option 4 investigation: the undo-probe buffer (probed on `nvim 0.12.5`)

This section records the design and what was empirically verified in a
throwaway probe, so a future session can build on it without re-deriving the
nvim behavior. None of the probe scripts were added to the repo; they lived in
`/tmp/probe/`.

### Verdict

The mechanism is sound. A hidden buffer's native undo tree can be driven and
read without ever displaying the buffer, its extmark spans survive undo/redo,
and probe entry boundaries can be made to track the main buffer's entry
boundaries exactly. A prototype reproduced the lsof failure mode (a chrome
re-render between `u` and `<C-r>`) and let redo succeed anyway, because the
chrome render never touched the probe's tree.

### Design overview

The principle is that Neovim's undo is a per-buffer tree of whole-buffer text
snapshots, so a second buffer that contains *only* the editable region text
can own an undo tree whose every entry corresponds to a main-buffer entry; an
example of this is a render with two holes, `[aaa]` and `[bbb]`, mirrored into
a hidden probe as two slot lines, where typing into either hole appends one
probe entry and pressing `u` undoes that entry, reads both slots' text back
out, and writes the changed text into the main buffer.

Two directions keep the probe and main buffer in agreement. The **mirror**
direction runs after every accepted user edit: it copies each changed region's
text from the main buffer into the probe, opening or joining a probe undo
entry so the probe's entry boundaries match the main buffer's. The **replay**
direction runs when a traversal key or command arrives: it moves the probe's
undo pointer instead of the main buffer's, then copies every region's text
from the probe back into the main buffer. Because the replay never traverses
the main buffer, an app chrome render landing between a `u` and a `<C-r>`
changes only the main buffer's tree and leaves the probe's redo tip intact.

### Probe buffer construction

The probe is a scratch buffer created once per renderer, with `buftype = 'nofile'`,
`bufhidden = 'hide'`, and `swapfile = false`; it is never shown in a window,
and all reads and writes go through `nvim_buf_call(probe, function() ... end)`.

Each editable span gets one contiguous run of text in the probe, and one
ranged extmark covers exactly that run:

- Region `i` is written at its slot, then `probe_marks[i]` is placed with
  `right_gravity = false` and `end_right_gravity = true`. The false start
  gravity keeps the slot's start pinned when text is inserted at its leading
  edge, and the true end gravity makes the slot grow when text is appended at
  its trailing edge. The probe prototype verified both edges: inserting at a
  slot's end extended its mark, and inserting a newline extended it across
  lines (`multi.lua`).
- Slots are laid out in region order and separated by a single newline that no
  mark covers, so adjacent slots cannot merge even when a slot grows
  multiline. In the two-region probe of `proto8.lua`, region 1's mark grew
  from `r0.0-r1.2` to `r0.0-r2.2` when a line was added, and region 2's mark
  shifted down with it.

On mount, morph writes every editable region's current text into the probe as
the first undo entry and records `baseline = undotree(probe).seq_cur`. That
entry is the floor: it is the state the render was mounted with, so an undo
that would step below it is a no-op, which is what makes `u` at the bottom
stop at mount content instead of sailing into the probe's empty buffer.

### State model

All fields below live on the Morph instance (or a dedicated probe-record glued
to it); the names are descriptive, not final.

| Field | Meaning | Written by |
| --- | --- | --- |
| `probe` | The hidden scratch buffer number | created once |
| `probe_marks[i]` | Ranged extmark covering region `i`'s text | mount, mirror, replay |
| `probe_ns` | Namespace for all probe extmarks | created once |
| `slot_of[tag]` | Maps a main region (tag) to its probe slot index | mount, render |
| `baseline` | The probe `seq_cur` of the mount-state entry (the floor) | mount |
| `last_main_seq` | Main `seq_cur` as of the last mirror or replay | mirror, replay |
| `probe_entry_open` | Whether the probe's tip corresponds to the main's current entry | mirror, replay |
| `replaying` | Suppresses the mirror while replay writes the main buffer | replay |

The main buffer already carries the pieces the probe maps from: each editable
tag has `tag.curr_text` (its accepted content) and `tag.curr_span` (where that
content lives, in pre-change coordinates), both maintained by the existing
guard. The probe does not replace those; it consumes them.

### Direction 1: the mirror (main edit -> probe)

The mirror rides the guard's existing change path. When
`_on_bytes_after_autocmd` accepts an editable edit, it already computes the
changed editable tags and commits their new `curr_text` and `curr_span`.
Mirroring happens in that same commit step, before the `on_change` handlers
fire, so the probe reflects the same change the app is about to be told about.

For one guard batch the algorithm is:

1. Read `main_seq = undotree(main).seq_cur` and compute
   `fresh = (main_seq ~= last_main_seq)`.
2. For each changed region `i` whose `tag.curr_text` differs from the probe
   slot's current text:
   a. Decide whether to open a new probe entry or join the current one, using
      the rule in the next subsection.
   b. Inside `nvim_buf_call(probe)`, either run `let &undolevels =
      &undolevels` (force a new entry) or `pcall(vim.cmd, 'undojoin')` (merge
      into the current entry), then replace the slot's range with the region's
      new text and re-place `probe_marks[i]` over it.
   c. Mark that this batch wrote at least one slot, and set
      `probe_entry_open = true`.
3. Set `last_main_seq = main_seq`.

The mirror is skipped entirely while `replaying` is set, because replay writes
the main buffer and would otherwise feed back into the probe.

### Direction 2: the replay (key -> probe traversal -> main writeback)

A traversal first moves the probe by one entry using an exact jump, then
writes the resulting region texts back into the main buffer.

For an intercepted undo the algorithm is:

1. Read `tree = undotree(probe)` and stop if `tree.seq_cur <= baseline` (the
   floor).
2. Compute the target sequence: the largest entry `seq` strictly below
   `tree.seq_cur`, read from `tree.entries`. Address it exactly with
   `:undo <target>` inside `nvim_buf_call(probe)`, which the prototype
   verified lands the probe on that exact `seq_cur`. For redo the step is
   `:redo` (or `:later 1`), which the prototype also verified moves exactly
   one entry.
3. Set `replaying = true`, then for each region `i`: read the slot's text
   through `probe_marks[i]`, read the main region's current text through its
   live extmark, and when they differ, replace the main span with the probe
   text and re-place the main extmark over the new span.
4. Clear `replaying`, set `probe_entry_open = false`, and set
   `last_main_seq = undotree(main).seq_cur` (the writeback just created main
   entries, so the next real edit must not be mistaken for a join).

Step 3 is why the prototype carried a per-hole "read both, write if
changed, re-place the mark" block rather than writing unconditionally:
writing every region on every traversal would create a main entry even when a
region did not change, and re-placing the mark is what keeps the main span
snapshot accurate for the next mirror.

### Granularity: mapping main entries to probe entries

The one rule that makes lockstep work is that the probe must open a new entry
if and only if the main buffer did, and join otherwise. The signal is the main
buffer's `seq_cur`: a user edit that `:undojoin`s into the current block leaves
`seq_cur` advanced (the block stays a single entry), while an edit that opens a
new block advances it too, so `seq_cur` alone is not enough. What
distinguishes the two is whether `seq_cur` *changed since the last mirror
batch*: the first batch of a new main entry sees a changed pointer, and every
subsequent batch of the same entry sees it unchanged.

The working predicate is `new_probe_entry = (not probe_entry_open) or (fresh
and not batch_wrote)`. An example shows why each clause exists. An insert
session `iabc<Esc>` produces three `TextChanged` batches under one main entry:
the first batch has `probe_entry_open = false`, so it forces a new probe entry;
the next two have `probe_entry_open = true` and `batch_wrote = true`, so they
`undojoin`. A later separate session produces a fresh `seq_cur`, so its first
batch forces a new entry again. The `not batch_wrote` clause covers the case
two regions change in a single batch: without it, `fresh` would be true for
both regions and the batch would wrongly open two entries.

The prototype verified the coarse version of this rule (entry counts tracked
1:2:3:4 across a session, a second session, and a `ciw`, and undo/redo replayed
in the right order), but the `not batch_wrote` refinement was identified after
the run and is not yet exercised. It is the first thing to test when building.

### Interception surface

The traversal keys are the clean path, and the ex-command forms are the messy
one.

- **Keys.** `u`, `<C-r>`, `g-`, and `g+` are buffer-mappable in `n`, `x`, `v`,
  and `o` modes, and a mapping fully suppresses the native action; a prototype
  installed mappings that only incremented a counter and confirmed the buffer
  text did not change and the native undo tree did not move (`intercept3.lua`).
  The handler runs the replay and consumes the key.
- **Ex commands.** `:undo`, `:redo`, `:earlier`, and `:later` cannot be
  shadowed as buffer-local user commands, because nvim rejects lowercase user
  command names. They can be intercepted from a `CmdlineLeave` autocmd: parse
  the pending command with `nvim_parse_cmd`, and when its `cmd` is one of the
  four, rewrite the command line (or abort it) so the command never executes,
  then run the replay. The prototype confirmed a `CmdlineLeave` handler that
  inspected `getcmdline()` and rewrote it prevented the typed `:undo` from
  running (`cancel2.lua`, run A). The user has accepted this route.
- **Use `nvim_parse_cmd`; do not string-match.** `nvim_parse_cmd(str, {})`
  returns structured fields, so recognition is by `cmd` and arguments rather
  than by text. The probe confirmed `:undo 3` -> `cmd="undo", count=3`,
  `:earlier 5s` -> `cmd="earlier", args={"5s"}`, `:silent undo` ->
  `cmd="undo"`, `.undo` -> `cmd="undo", range={1}`, and `:undo | echo 1` ->
  `cmd="undo", nextcmd="echo 1"`, so a command tail (`nextcmd`), a count, or a
  range can be honored rather than ignored.

Not yet covered by any interception: `U` (undo line), the `.` repeat of an
undo, and programmatic `vim.cmd('undo')` from user Lua. These would bypass the
probe and desynchronize it.

### Edge cases and their handling

- **Multiline regions.** A slot's mark spans multiple lines when its text does;
  the true end gravity grows the mark across the newline, and the separating
  newline keeps the next slot distinct (`multi.lua`).
- **Empty and wiped regions.** A region whose text is deleted collapses its
  probe mark to a zero-width span, and undo restores both the text and the
  span (`child6.lua`). The main side does the same, so the two stay in step.
- **Zero-width region at mount.** A region that starts empty keeps a zero-width
  mark; text inserted into it is covered because the end gravity is true, so
  the slot grows to hold the new text (`struct.lua` T1).
- **Floor.** The mount entry is the floor; `u` at or below `baseline` is a
  no-op. Without the clamp the probe's own `u` reaches the empty buffer and
  wipes every slot (`proto8.lua` with the clamp, `proto5.lua` without it).
- **Replay-created main entries.** Writeback writes the main buffer, so the main
  tree advances; refreshing `last_main_seq` after the replay keeps the next
  user edit from being misclassified as a join.
- **`undojoin` after an undo.** `:undojoin` raises E790 immediately after an
  undo, but `let &undolevels = &undolevels` still opens a new entry and re-tips
  the tree (`intercept3.lua`). A replay that lands the probe below its tip can
  therefore still open fresh entries.

### Structural change: when the region set changes between renders

This is the case where the set of editable spans gains or loses a member, which
happens when an app conditionally shows a different number of holes. A probe
write that adds or removes a slot *line* is itself an undoable entry, so when it
lands below the tip it re-tips the tree; a later `u` then erases the slot and
desynchronizes the slot map. `struct.lua` T2 shows a region added between user
edits, then `u` erasing it.

The user's stance is that an app adding or removing holes between renders is the
app's own doing, so the design should stay correct without over-accommodating.
Two policies were identified and deliberately deferred ("we can talk more about
this in time"):

1. **Fixed slots.** Give each editable region a stable identity, keep one probe
   slot per identity forever, and represent a vanished region as an empty slot
   so the slot union never changes size. This never performs a structural probe
   write. The cost is region identity: the user raised that it may force stable
   extmarks and ids in the main buffer, with a probe format something like
   `JSON<Record<extmark_id, text>>`.
2. **Rebuild and drop the branch.** On a set change, rebuild the probe from the
   new set and reset its tree. This is simple and always consistent, but it
   discards probe history at the moment of the change.

### What the probe does not solve

The probe governs *region-text ordering*; it does not make locked chrome
display correctly when the pointer sits below the tip. Option 3 (virtual
rendering) is what addresses chrome display, so the probe and virtual rendering
are complementary rather than alternatives. Likewise, the probe does not change
the guard's job: the guard still rejects edits to locked chrome, and the probe
just gives the guard a traversal path that does not fight it.

### Verified mechanics catalogue

Each item below is a raw nvim behavior the design depends on, with the probe
that proved it.

- **Hidden-buffer undo works.** A `buftype=nofile`, never-displayed buffer
  accumulates undo entries, and `nvim_buf_call(buf, function() vim.cmd('undo')
  end)` drives them; `vim.fn.undotree()` reads the tree from inside
  `nvim_buf_call`, and `vim.fn.undotree(buf)` also accepts a buffer argument.
  What this buys: the probe needs no window and no focus (`child5.lua`).
- **`:undo N` is an exact jump.** `:undo 3` lands on `seq_cur == 3`, `:undo 0`
  empties, and a target past the tip errors. What this buys: replay can address
  a probe position directly instead of counting blind `u`s, so lockstep cannot
  drift by a step (`child8.lua`, `child9.lua`).
- **Extmarks survive undo/redo.** A region wiped by an edit collapses to a
  clean zero-width span, and its text is restored on undo; two marks over two
  regions stayed correctly positioned through edits to both and through full
  undos. What this buys: the map from region to probe slot is stable across
  traversals (`child6.lua`).
- **Insert-session granularity is native.** Real input `iabc<Esc>` makes one
  entry, and type -> motion -> type makes two. What this buys: the probe does
  not reimplement coalescing, `ciw`, or paste-as-one-step; it only mirrors the
  boundary (`child7.lua`, `proto7.lua`).
- **Probe entry boundaries are controllable.** Placing `let &undolevels =
  &undolevels` *before* a probe write forces a new entry, and `:undojoin`
  before a write merges into the prior one. What this buys: 1:1 entry
  mapping, the premise of lockstep (`gran2.lua`, `gran_final2.lua`).
- **`:undojoin` fails after an undo; force-new does not.** `:undojoin`
  immediately after an undo raises E790, yet the `&undolevels` tweak still
  opens a new entry and re-tips the tree. What this buys: a replay that lands
  the probe below its tip can still open fresh entries (`intercept3.lua`).
- **`undolevels = 0` is not a bypass.** Setting `undolevels` to zero for one
  write *does* make that write non-undoable, but it collapses the entire undo
  history to a single entry (`entries` drops to 1), so it is unusable for
  "write without recording" at a non-tip position (`ul_clean.lua`).
- **The original failure, reproduced and survived.** With a heading that
  embeds a hole's text, a user edit, an undo, and a chrome re-render landing
  between undo and redo: the probe kept its redo tip and `<C-r>` restored the
  hole text while the chrome stayed on the new render. This is the property the
  strict guard cannot provide (`headline.lua`).

### Risks and deferred decisions

- **Granularity is a rule, not a free property.** Every mirrored write must be
  gated on the `seq_cur`-delta rule, including `p`, linewise paste, and
  simultaneous multi-region edits. The coarse rule was proven; the
  `not batch_wrote` refinement and the paste cases are not yet tested.
- **Structural change to the region set.** See the dedicated subsection; the
  fixed-slot versus rebuild choice, and region identity, are deferred.
- **Replay writes create main-buffer entries.** Acceptable because the probe is
  authoritative for region text and replay writes run under `replaying`; the
  requirement is to refresh `last_main_seq` afterward.
- **Untrapped traversal paths.** `U`, `.`-repeat, and programmatic
  `vim.cmd('undo')` bypass the probe. Each needs either interception or an
  explicit desync-recovery story.
- **App-driven region writes.** If the app writes region text directly, the
  mirror records it as a probe entry, so an app refresh that changes region
  text becomes undoable. The stated contract is that the probe is bookkeeping
  and a simulation buffer, never the source of truth for app writes, so this
  interaction is a policy question rather than a settled behavior.
- **Chrome display below the tip is not solved by the probe.** See the section
  above; Option 3 owns it.

### Confirmed decisions

- The probe sits *beside* the strict guard; the guard still rejects
  locked-chrome edits.
- The probe holds *all* editable spans, not only holes.
- Replay uses exact `:undo N` jumps, not blind `u`s.
- The floor is mount state, not empty.
- The probe is bookkeeping plus a simulation buffer, never the source of
  truth for app writes.
- Ex-command interception via `CmdlineLeave` + `setcmdline` is acceptable, and
  recognition uses `nvim_parse_cmd`.
