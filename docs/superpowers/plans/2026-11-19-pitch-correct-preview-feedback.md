# Pitch Correct Preview Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every correction setting of Fancy Pitch Correct shows its effect on the note canvas: the Preview Curve is the shape that is written, and hovering or dragging a setting shades where it acts.

**Architecture:** The trajectory that `apply_envelope_to_take` builds moves into one pure function, `K.correction_build`, which returns the envelope points, the highlight spans and the corrected time ranges. The envelope writer and the canvas both read it (the canvas through a cache that rebuilds only when an input changed). Controls report "this setting is hovered / dragged" through `K.setting_hint`; the canvas draws spans and outlines for that setting.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui 0.10, `_lib/theme.lua` (two new canvas palette keys).

**Spec:** `docs/design/pitch-correct-preview-feedback.md` (Approved 2026-11-19, TheFancyWolf). Implement it exactly. Do not invoke skills.

## Global Constraints

- Target files: `Pitch/Fancy_Pitch Correct.lua` (v2.9.0 → v2.10.0), `_lib/theme.lua` (two canvas keys only), `CHANGELOG.md` under `[Unreleased]`. No change to `index.xml`, `.github/` or `_fancy_*.json`.
- No gesture, default, range, unit, undo label or stored setting changes. The envelope written for any given note model must be point-for-point what it is today.
- Copy is fixed by the spec: Layers tooltip `The pitch after correction. Hover or drag a setting to see where it acts.`; status `No edited note in view uses this value`; Help row `Hover or drag a setting` → `Shows on the notes where it acts`.
- The script chunk is near Lua's 200-locals limit: new constants and functions go into the existing `K` and `state` tables, not new top-level locals.
- Colours only from the canvas palette; `reaper.*` called directly; every variable `local`; nil-guard API returns.
- No test framework, mock or fake REAPER. Tests are `luacheck .` and real REAPER through the bridge, following `.agents/skills/reaper-screenshot/references/testing-protocol.md` (sweep strays before and after every action; put back what you changed).
- Work on branch `feat/pitch-correct-preview-feedback` (cut from `main` after the Shortcuts merge). Commit only when the user says so; never push.
- If a permission prompt fails or the bridge times out: stop and tell the user.

## Review Focus

1. **Envelope unchanged.** The refactor must not move a single envelope point. (Task 1: compare the take's envelope points before and after for an edited item.)
2. **Adjacent notes with no gap** (end time = next start time, and trimmed notes that overlap by a frame). The gap span has zero or negative width: draw one edge line, never a negative rectangle. (Task 3.)
3. **Silence under a ramp or glide.** The curve breaks; a one-point run draws nothing; the span still shows. (Task 2.)
4. **A drag that reaches nothing in view** (all edited notes scrolled out, or every note has its own value). No highlight, and the status pill says so once, not every frame. (Task 3.)
5. **Hundreds of notes during a top bar drag.** The rebuild runs only on frames where a value changed and the screen arrays only when the view or the build changed. (Task 2.)

---

### Task 1: One calculation for the envelope

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `apply_envelope_to_take` (near line 1964).

**Interfaces — Produces:**
- `K.correction_build(notes, item_len) -> build`, pure, no `reaper.*` calls. Sets `n.frame_shifts` on each note as today. `build = { points = { {time, val}... } (generation order, as today), spans = { {kind, t0, t1, a, b}... }, ranges = { {t0, t1}... } }`.
  - `kind`: `"onset"` (t_pre → note start, `a` = note index), `"release"` (note end → end + ramp, `a`), `"glide"` (t_start → t_end of the smoothstep blend, `a` = previous index, `b` = this index; the transition value is note `b`'s), `"gap"` (previous end → this start, same `a`/`b`, emitted with every glide), `"scoop"` (first frame → frame `onset_end`, `a`). Glide and gap spans are emitted only when note `a` or `b` is edited.
  - `ranges`: per edited, non-bypassed note, from the earliest of its start / onset span / glide span to the latest of its end / release span / glide span to the next note; sorted, overlapping ranges merged.

- [ ] **Step 1:** Record the baseline: in real REAPER, with an edited item analysed, read the take pitch envelope's points (count, and time/value of each) through the bridge. Keep them.
- [ ] **Step 2:** Move sections "1. Precalculate" and "2. Build continuous trajectory" into `K.correction_build`, adding the span and range bookkeeping. `apply_envelope_to_take` keeps its early returns, calls it, simplifies and writes as today.
- [ ] **Step 3:** `luacheck .` → no new warnings.
- [ ] **Step 4:** Relaunch the script, make a no-op re-apply (nudge a note up then down), read the envelope again: same count, same times and values as Step 1.

### Task 2: The curve is the written shape

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — draw cache (near line 3007), `K.note_preview` (line 3254, removed), the preview draw (near line 4643).

**Interfaces — Produces:**
- `K.correction_view(notes, item_len) -> build | nil` — returns the cached build with `points` sorted by time; rebuilds only when the signature changed (per note: start, end, frames identity, bypassed, centre pitch, drift scale, vibrato scale, scoop, effective strength / transition / onset ramp; plus effective legato gap and the note count). Carries `build.gen`, incremented on each rebuild. `nil` when no note is edited.
- `K.preview_lines(results, r0, r1, t_to_x, build) -> lines, count` — arrays for `DrawList_AddPolyline`, one per run of consecutive pitched frames inside a range; y from `frame.note + shift(time)`, shift = linear interpolation over the sorted points (held before the first and after the last). Cached on the draw cache generation, `build.gen`, `results`, `r0`, `r1`. Runs of fewer than two points are dropped.

- [ ] **Step 1:** Implement both; replace the per-note preview draw with one draw after the note loop, under the same `state.show_preview` test and not while the take is bypassed. Remove `K.note_preview` and its cache fields.
- [ ] **Step 2:** `luacheck .`.
- [ ] **Step 3:** Real REAPER: screenshot an item with two joined edited notes and one edited note on its own. Expect the curve to fade in before the first, glide between the pair, and fade out after the last. Drag Strength: the curve moves during the drag.

### Task 3: Highlights

**Files:** Modify `_lib/theme.lua` (both canvas palette builders) and `docs/superpowers/tests/theme_spec.lua` (key list 79 → 81, span edge contrast); `Pitch/Fancy_Pitch Correct.lua` — `param_drag`, the top bar (`draw_retune`, `draw_badge`, `edit_timing`), the note menu's `draw_cm_slider`, the Shift+Drag branch, `draw_graph`.

**Interfaces — Produces:**
- Canvas keys `span_fill` (yellow wash, decoration) and `span_edge` (yellow fitted to 3:1 on rows and note fills in Match Theme; a fixed yellow in Fancy Dark that clears 3:1 on its rows and fills).
- `param_drag` records `K.drag_hot = { hovered, active }` for the control it just drew (active includes its typed entry being open).
- `K.setting_hint(hctx, key, dragging, notes)` — stores `state.setting_hint = { key, dragging, notes, frame }`; a dragging hint is not replaced by a hover hint in the same frame. `notes` is `nil` (every note the top bar value reaches) or a set of note indices.
- Canvas: when the hint is from this frame or the previous one, `state.show_preview` is on and the take is not bypassed, draw for notes in view:
  - `retune_speed`: outline (`span_edge`, offset `Theme.layout.xs`) on each reached note.
  - `transition_ms`: `glide` spans whose note `b` is reached. `onset_ramp_ms`: `onset` and `release` spans. `legato_threshold_ms`: `gap` spans. `scoop_shape`: `scoop` spans.
  - Reached, top bar: for outline / onset / release / scoop the note is edited, not bypassed and has no own value for the key; for glide, note `b` has no own transition. Reached, note set: the note is in the set.
  - A span is a filled rectangle with an edge line at each end, as tall as its note's block (glide / gap: top of the higher block to bottom of the lower); under two pixels wide it is one edge line.
  - Dragging and nothing drawn: `set_status("No edited note in view uses this value")` once per drag.

- [ ] **Step 1:** Theme keys in both modes. **Step 2:** hint plumbing at the five sites. **Step 3:** canvas drawing, before the pitch trace. **Step 4:** `luacheck .`.
- [ ] **Step 5:** Real REAPER, pointer placed over each setting in turn (Strength, Transition, Onset Ramp, Legato Gap), one screenshot each; one during a Shift+Drag on a note; one in Match Theme. Restore the theme mode.

### Task 4: Words

**Files:** `Pitch/Fancy_Pitch Correct.lua` (Layers menu Preview Curve tooltip, `K.INFO_SECTIONS` row, `@changelog`), `CHANGELOG.md`.

- [ ] **Step 1:** Add the three strings from Global Constraints and the changelog entries. **Step 2:** `luacheck .`. **Step 3:** Screenshot the Help modal and the Layers tooltip.
