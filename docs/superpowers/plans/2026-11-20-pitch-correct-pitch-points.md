# Pitch Correct Pitch Points Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The dots and diamonds on a note of Fancy Pitch Correct become draggable pitch points that bend the pitch at one moment, and the user can add points of their own.

**Architecture:** Each note stores a short list of moved and added points in its `controls`. A pure function turns the note's knots (start, detected dots, stored points, end) into a per-frame offset array, eased with `smoothstep` between neighbouring knots; `K.correction_build` adds that array to the frame shifts as its last step, so the envelope writer, the Preview Curve and the "outdated" check all see it through the one calculation they already share. The canvas gets a point hit-test that runs before the note's edges and zones, and two popups reuse the script's existing value-drag control and menu pattern.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui 0.10, `_lib/theme.lua` (read only: existing canvas palette keys and layout tokens).

**Spec:** `docs/design/pitch-correct-pitch-points.md` (Approved 2026-11-20, TheFancyWolf). Implement it exactly. Do not invoke skills.

## Global Constraints

- Target files: `Pitch/Fancy_Pitch Correct.lua` (v2.10.0 → v2.11.0) and `CHANGELOG.md` under `[Unreleased]`. No change to `_lib/`, `index.xml`, `.github/` or `_fancy_*.json`.
- **Notes without points write the same envelope as today, point for point.** The glide and ramp code in `K.correction_build` (sections A and C) is not edited.
- Copy is fixed by the spec's Copy deck (labels, tooltips, inline reasons, status messages, undo labels, Help rows). `Cmd` in any string comes from `K.MOD_LABEL`; the undo hint is the existing `" %s+Z to undo"` form.
- Values from the spec: offset limit ±300 ¢ (`K.POINT_MAX_ST = 3.0`); minimum gap between points 3 analysed moments (`K.POINT_MIN_GAP = 3`, in frames); grab distance `Theme.layout.sm * 2` (`K.POINT_GRAB`); an offset under half a cent is 0 (`K.POINT_EPS = 0.005`); fine factor `K.FINE_ADJUST_SCALE`.
- Colours only from the canvas palette keys `spot`, `anchor`, `handle_hover`, `pill_text`; sizes from `K.SPOT_R`, `K.ANCHOR_R` and `Theme.layout.*`. No new palette key.
- The layer's state field and stored key stay `state.show_smart_spots` / `pitch_show_smart_spots`.
- The script chunk is near Lua's 200-locals limit and `draw_graph` is very large: new constants and functions go into the existing `K` and `state` tables, not new top-level locals.
- `reaper.*` called directly; every variable `local`; nil-guard API returns; every ReaImGui name checked against `.agents/skills/reaimgui-ux-review/scripts/reaimgui_api_names.txt` before use.
- No test framework, mock or fake REAPER. Tests are `luacheck .` and real REAPER through the bridge, following `.agents/skills/reaper-screenshot/references/testing-protocol.md` (sweep strays before and after every action). Test on the analysed item the user has open; undo every test edit with the bridge's `undo` and leave the item, the selection, the layer toggles and Theme Mode as they were. If no analysed item is open, stop and ask the user for one.
- Work on a new branch `feat/pitch-correct-pitch-points`, cut from the tip of `feat/pitch-correct-preview-feedback` (v2.10.0 is not on `main` yet). Commit only when the user says so; never push. Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- If a permission prompt fails or the bridge times out: stop and tell the user.

## Review Focus

1. **An item saved before this version, and any note without points.** Same envelope as before, no "outdated" mark after the upgrade. (Task 1, test a.)
2. **Stored points that do not fit the note:** a time outside the note, two on one moment, a non-number, a value beyond ±3 semitones, an empty list. They are dropped or clamped when the item loads; never an error window. (Task 1, `K.points_sanitize`; Step 6.)
3. **A dot on top of a trim handle, a row a few pixels tall, a note crowded with dots.** The note can still be dragged, trimmed and double-click-snapped. (Task 2, tests d and e.)
4. **Undo, redo or a switch to another item while a point is being dragged or its menu is open.** The drag is dropped, the menu closes, nothing indexes a note that is gone. (Task 1, test f; Task 3, test d.)
5. **A split through a bend, a merge across one, a trim into one.** Away from the cut by more than half a Transition the written envelope is the same to within 1 cent. (Task 4, tests a to c.)

---

### Task 1: Point model, the offset curve, and dragging a point

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `K` constants (near line 218 and 323), `state` (near line 375), `extract_note_features` controls (line 1540), `is_note_modified` (line 1579), `load_take_data` (line 1670), `K.correction_build` (line 1978: after the scoop block; section B), `reset_selected_note` (line 2490), `K.correction_view` signature (line 3452), `draw_graph`: hit-test (line 4061), click (line 4131), the spot drawing (line 5021), the drag readout (line 5173), the Esc handling, and wherever a model reload clears `state.drag`.

**Interfaces — Produces:**
- Stored data: `note.controls.points` = array sorted by `t` of `{ t = <item seconds, a frame's time>, st = <semitones>, added = true | nil }`; `nil` when empty. An entry exists only if `added` or `|st| >= K.POINT_EPS`.
- `K.points_sanitize(note)` — called after saved controls are copied in `load_take_data`: drops entries with a non-number `t` or `st` or a `t` outside the note, clamps `st`, snaps `t` to the nearest frame, keeps the first of two entries on one frame, sorts, sets `nil` when empty.
- `K.points_knots(note) -> knots` — ordered by frame; each `{ frame, t, st, kind, entry }`, `kind` = `"start"` (frame 1), `"end"` (last frame), `"spot"` (a detected peak or valley, or a stored entry without `added`), `"added"`. A detected dot closer than `K.POINT_MIN_GAP` frames to a stored entry is not a knot. Cached on the note; rebuilt when `note.points_rev`, `note.frames` or `note.smart_spots` changed.
- `K.points_offsets(note) -> offsets | nil` — per-frame semitone array: between two neighbouring knots `a.st + (b.st - a.st) * smoothstep(u)`, `u` by frame index; `nil` when every knot is at 0. Cached with the knots. No `reaper.*` calls.
- A point is identified across frames by `{ note_idx, frame }`; look its knot up by frame each time, since the knot tables are rebuilt on every `points_rev` change.
- `K.point_set(note, knot, st)` — clamps to ±`K.POINT_MAX_ST`, snaps under `K.POINT_EPS` to 0, creates / updates / removes the entry by the entry rule, bumps `note.points_rev`. No `reaper.*` calls; the caller commits with `apply_envelope_to_take(label)`.
- `K.points_count(note) -> n` (stored entries) and `K.points_reset(note) -> n` (clears them, returns how many).
- `is_note_modified(note)` is also true when `K.points_offsets(note)` is not `nil`.
- `K.correction_build`: for a non-bypassed note with offsets, `frame_shifts[i] += offsets[i]` after the scoop block. Such a note takes the contour branch of section B (as `fine_changed`), with `body_t_start = n.start_time` when it is not joined to the previous note and `body_t_end = n.end_time` when it is not joined to the next (do not write a second point at a time section A or C already wrote). Sections A and C are untouched.
- `K.correction_view` signature gains `n.points_rev`.
- `reset_selected_note` clears points and counts a note with points as changed.
- `state.point_drag = nil | { note_idx, frame, start_st, st, last_y, dirty, view_min, view_max }`; `state.hovered_point = nil | { note_idx, frame }`. Both are cleared wherever a model reload or target switch clears `state.drag`.
- A point's **aim pitch** = `note.frames[frame].note + (note.frame_shifts[frame] or 0)`; when `K.correction_view` returns `nil` every shift counts as 0 (its `frame_shifts` are stale then).
- Drawing (replaces the block at line 5021 and moves after the Preview Curve draw near line 5067, before the pills, so the layer order is Preview Curve, stems, points, pills; same visibility rule): circle `K.SPOT_R` for `"spot"`, diamond `K.ANCHOR_R` for `"start"` / `"end"`, filled square of side `2 * K.SPOT_R` for `"added"`, each at its aim pitch; a 1 px stem from `aim - st` to `aim` when `st ~= 0`, in the point's own colour, under the points. The hovered or dragged point is drawn at `K.ANCHOR_R` with a `handle_hover` outline.
- Drag: a plain press on a point (hit area: `K.POINT_GRAB` each way; refined in Task 2) starts `state.point_drag`, selects the note alone if it was not selected, and does not start a note drag. Per frame `st += (last_y - my) / h * note_range * (Ctrl/Cmd and K.FINE_ADJUST_SCALE or 1)` through `K.point_set`, after the note drag's 2 px dead zone; the pitch view is frozen as for a note drag; cursor `MouseCursor_ResizeNS`. Release: `apply_envelope_to_take("Move Pitch Point")` only if `st ~= start_st`. Esc (through `Shortcut()`, ahead of the selection-clearing Esc): `K.point_set` back to `start_st`, no write. No note tone.
- Readout pill while dragging, through `pill_text`: `"%+d¢ · %s %s%d¢"` = the point's whole cents, then the aim pitch as note name and signed cents (the note readout's format).

- [ ] **Step 1:** Record the baseline: on the open analysed item with at least one edited note, read the take pitch envelope's points through the bridge (count, time and value of each). Keep them.
- [ ] **Step 2:** Implement the model functions, the `K.correction_build` hook, `is_note_modified`, the signature, the reset and the sanitize call.
- [ ] **Step 3:** Implement drawing, the press / drag / release / Esc path and the readout.
- [ ] **Step 4:** `luacheck .` → no new warnings.
- [ ] **Step 5:** Real REAPER, relaunch the script, then:
  - a. No point touched: envelope equals Step 1, and no item in Pitched Items shows "outdated".
  - b. Drag a valley dot of an unedited, free-standing note up: screenshot shows the dot with a stem, the note green, the Preview Curve bending between the two neighbouring dots only, the readout pill. After release the envelope has new points inside that note only.
  - c. Bridge `undo`: dot back, note no longer edited, envelope as before. `redo`: bend back.
  - d. Cmd-drag moves about a tenth as far for the same pointer travel. Drag far up: the readout stops at `+300¢`.
  - e. Drag, press Esc before release: point back, no new undo entry.
  - f. Start a drag and send bridge `undo` mid-drag: no error window, no stuck drag.
  - g. Drag the start diamond of a free-standing note: the curve fades in before the note (onset ramp) to the new value.
  - Undo all test edits.
- [ ] **Step 6:** Damaged stored data cannot be injected without a fake, so check it by reading: walk `K.points_sanitize` through each case of Review Focus 2 (time outside the note, two entries on one moment, a non-number, a value beyond ±3 semitones, an empty list) and write down what the function leaves in `controls.points` for each. Say in the report that this was checked in code, not in REAPER.

### Task 2: Hover, priority, adding and resetting on the canvas

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `draw_graph`: hit-test (line 4061), click (line 4131), double-click (line 4656), spot drawing, hover hint (line 5207), `K.status_line` (line 8053).

**Interfaces — Consumes:** Task 1's `K.points_knots`, `K.point_set`, `state.point_drag`, `state.hovered_point`, aim pitch.

**Interfaces — Produces:**
- `K.points_live(note, row_h, block_w) -> boolean` — `row_h >= K.POINT_GRAB` and `block_w / (#knots - 1) >= K.POINT_GRAB`. Not live: points drawn at half size, never hovered, grabbed or added; the note behaves as today; `K.status_line` returns `Zoom in to move pitch points` while such a note is hovered.
- `state.points_hover_note = nil | n_idx` — the note whose points are shown because the pointer is inside the box around its block and its points' aim pitches, padded by `K.POINT_GRAB`. The draw rule becomes: hovered, `points_hover_note`, or selected.
- Hit area of a live point: half-width `min(K.POINT_GRAB, half the pixel gap to each neighbouring knot)`; half-height `K.POINT_GRAB`, or `min(K.POINT_GRAB, block_h / 4)` where the point's y lies inside its note's block.
- Hit order in the hit-test block: point → edge handle → zone. A press with Shift held skips points. A press with Ctrl/Cmd on a point starts a fine point drag without changing the selection; when it becomes a drag the note is added to the selection; released without a drag it runs today's Ctrl/Cmd-click on the note under the pointer (nothing if none).
- A point press on a bypassed note: `set_status("This note is bypassed, so its pitch points do nothing. Right-click the note to turn bypass off.")`, then the press is handled as a note press.
- `K.point_can_add(note, t) -> frame | nil, reason` — `reason` = `"no_pitch"` (the nearest frame has no pitch) or `"too_close"` (within `K.POINT_MIN_GAP` frames of a knot). `K.point_add(note, t) -> knot | nil, reason` adds `{ t, st = 0, added = true }`.
- `state.point_ghost = nil | { note_idx, frame }` — set when the note is live, no point is hit, the pointer is within the point hit half-height of the aim pitch at the pointer's nearest frame, and `K.point_can_add` allows it. Drawn as a hollow square (outline `spot`, side `2 * K.SPOT_R`).
- Double-click (ahead of the existing snap): on a point → `K.point_set(…, 0)` and, if it was not 0, `apply_envelope_to_take("Reset Pitch Point")`; on the ghost → `K.point_add` and `apply_envelope_to_take("Add Pitch Point")`; a refusal with `"no_pitch"` → `set_status("No pitch detected here: a point needs a pitch to sit on.")`; otherwise the existing snap.
- Tooltips through `Theme.tooltip` under the canvas's existing tooltip gate: point `Drag to bend the pitch here (%s = fine). Double-click: reset. Right-click: menu`; ghost `Double-click to add a pitch point`. `K.status_line` returns `Drag a point to bend the pitch there` while a point is hovered.

- [ ] **Step 1:** Implement liveness, the box rule, hit areas and the hit order with the Shift / Ctrl/Cmd / bypass rules.
- [ ] **Step 2:** Implement the ghost, add and the double-click chain, tooltips and status hints.
- [ ] **Step 3:** `luacheck .`.
- [ ] **Step 4:** Real REAPER:
  - a. Move the pointer from a note's block to a dot above it: the dots stay shown; the dot grows and the cursor changes.
  - b. Double-click the pitch line between two dots: a square appears; drag it. Double-click it: back to 0, still there. Double-click a moved dot: stem gone. Double-click the note's centre away from the line: the note still snaps. Each is one undo step (check with bridge `undo` one at a time).
  - c. Shift+click a second note with the pointer on one of its dots: range select as today. Cmd-click on a dot of an unselected note with two others selected: the note joins the selection; nothing is dropped.
  - d. A start diamond that lies inside its block: pressing just above or below it at the edge still trims; pressing on it drags the point.
  - e. Narrow docker (about 260 px) and a short strip (about 150 px tall): crowded notes and short rows show half-size points, the status pill reads `Zoom in to move pitch points`, and notes drag, trim and snap as before. `Z` on a selected note makes its points live.
  - f. A note of three or four frames: only the two diamonds; a double-click on its line adds nothing and breaks nothing.
  - g. Bypass a note (note menu), press one of its dots: the status message, and the note is selected.
  - Undo all test edits; restore the window size and dock state.

### Task 3: Point menu and note menu

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — right-click handling (line 4259), the note context menu (line 5392), a new popup beside it.

**Interfaces — Consumes:** `K.point_set`, `K.point_add`, `K.point_can_add`, `K.points_count`, `K.points_reset`, `param_drag` (line 3138: returns `changed, value, committed, reset`).

**Interfaces — Produces:**
- `state.context_point = nil | { note_idx, frame }`; popup `"##point_context_menu"`, opened by a right-click on a live point (ahead of the note menu). It closes itself when its knot no longer exists. Esc closes it by the note menu's pattern.
- `K.point_remove(note, knot)` — removes an `added` entry; bumps `note.points_rev`.
- Point menu rows: `param_drag(draw_ctx, "pt_offset", "Offset", st * 100, -300, 300, "%+.0f ¢")` (changed → `K.point_set` live; committed → `"Move Pitch Point"`; reset → 0 and `"Reset Pitch Point"`), a separator, `Reset Point` (disabled at 0, reason `already at 0`), `Remove Point` (disabled unless `kind == "added"`, reason `detected points stay`). A reason is the menu item's right-hand text on the disabled row.
- Reset Point → `set_status("Reset the pitch point." .. undo_hint)`; Remove Point → `apply_envelope_to_take("Remove Pitch Point")` and `set_status("Removed the pitch point." .. undo_hint)`.
- `state.context_menu_time` — the pointer's time when the note menu was opened.
- Note menu, after "Split at Cursor": `Add Pitch Point Here` (disabled with reason `no pitch here` / `a point is already here` from `K.point_can_add`); `Reset Pitch Points (%d)###reset_points` (disabled at 0, reason `none moved or added`) → `K.points_reset`, `apply_envelope_to_take("Reset Pitch Points")`, status `Reset %d pitch point(s) on %s.` plus the undo hint, with the note's name as its label shows it and the script's `plural` helper.

- [ ] **Step 1:** Implement both menus.
- [ ] **Step 2:** `luacheck .`.
- [ ] **Step 3:** Real REAPER (region screenshots: popups are not in a window capture):
  - a. Right-click a moved dot: the menu shows its value; drag Offset: the curve follows; Cmd-click Offset, type `-40`, Enter: the point reads `-40¢`; one undo step each.
  - b. On a detected dot "Remove Point" is disabled with its reason; on a point at 0 "Reset Point" is disabled with its reason; on a square "Remove Point" removes it.
  - c. Note menu on a note with three stored points: `Reset Pitch Points (3)`; click → status names 3 and the note; one bridge `undo` brings all three back. On a note with none the entry is disabled with its reason.
  - d. Open the point menu, send bridge `undo` so the point's note changes: the menu closes, no error window.
  - Undo all test edits.

### Task 4: Split, Merge and Trim keep the bend

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `split_note_at` (line 2586), `merge_selected_notes` (line 2676), `trim_note_edge` (line 2800), and the status text each posts.

**Interfaces — Consumes:** `K.points_knots`, `K.points_offsets`, `K.POINT_MIN_GAP`, `K.POINT_EPS`.

**Interfaces — Produces:**
- `K.points_curve_at(notes, t) -> st` — the offset curve of whichever of `notes` holds time `t` (nearest frame), 0 outside all of them.
- `K.points_transfer(new_note, old_notes, pin_times) -> dropped` — run after `extract_note_features(new_note, …)`:
  1. copy every stored entry of `old_notes` whose `t` lies inside `new_note` (`dropped` = how many do not);
  2. for every knot of `new_note` without an entry (its start, end and re-detected dots), set its offset to `K.points_curve_at(old_notes, knot.t)` (stored only if at least `K.POINT_EPS`);
  3. if `new_note` now has any entry off 0, add an `added` entry holding the old curve's value at each of `pin_times` that lies inside the note and is at least `K.POINT_MIN_GAP` frames from a knot.
- Callers: split → each half with `{ old }, {}`; merge → the merged note with the old notes and `pin_times` = each inner old end and start time; trim → the trimmed note with `{ old }` and `pin_times = { old edge time }` when the note grew, `{}` when it shrank.
- Trim status when `dropped > 0`: `Trimmed the note. %d pitch point(s) outside it were removed.` plus the undo hint.

- [ ] **Step 1:** Implement `K.points_curve_at`, `K.points_transfer` and the three calls.
- [ ] **Step 2:** `luacheck .`.
- [ ] **Step 3:** Real REAPER, on a free-standing note with a bend made of two moved points; read the envelope before each action:
  - a. Split inside the bend (`X` at the edit cursor): the Preview Curve keeps its shape; envelope values more than half a Transition from the cut are within 1 cent of before.
  - b. Merge the two halves (`M`): same check.
  - c. Trim the note's end into the bend: the remaining part keeps its shape; the status names the dropped points. Drag the edge back out: no error, the kept part unchanged.
  - d. One bridge `undo` per action restores points and envelope.
  - Undo all test edits.

### Task 5: Layer entry, Help, version and the full check

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — Settings → Diagnostics (line 6999: remove the entry), the Layers menu (after line 7760), `K.INFO_SECTIONS` (line 5978), the header (`@version`, `@changelog`); `CHANGELOG.md`.

**Interfaces — Produces:**
- Layers menu: `Pitch Points` on `show_smart_spots`, with a swatch (a filled circle in the layer palette's `spot`) after "Preview Curve", tooltip `The points on a note that bend its pitch: peaks and valleys, the note's start and end, and points you add`.
- Help rows, in the section that holds the note gestures: `Drag a pitch point` → `Bend the pitch at that moment (<mod> = fine)` with `panel = { "Edit", 8, "Pitch point", "Drag dot" }`; `Double-click a pitch point` → `Put it back to 0`; `Double-click the pitch line` → `Add a pitch point`; `Right-click a pitch point` → `Point menu: type a value, Reset, Remove`.
- No user-facing string says "Pitch Center Spots", "smart spot" or "anchor".
- `@version 2.11.0`, a one-line `@changelog`, and a `CHANGELOG.md` entry above v2.10.0 that describes: draggable pitch points, adding points, the two menus, what Split / Merge / Trim / Reset do with points, the layer's new name and place, and that items without points are written as before.

- [ ] **Step 1:** Make the changes. **Step 2:** `luacheck .`.
- [ ] **Step 3:** Real REAPER: screenshots of the Layers menu (entry, swatch, tooltip), Settings (no Diagnostics entry for it), the Help modal rows and the Shortcuts panel row. Toggle the layer off: no points, no point gestures, a note with moved points still shows its bend in the Preview Curve; toggle back to what it was.
- [ ] **Step 4:** Whole feature in Match Theme: points, stems, hollow square and readout are readable on rows and on plain, selected and edited note fills. Restore the theme mode.
- [ ] **Step 5:** Walk the spec's Acceptance criteria table row by row against the running script and the code; list any row that could not be checked in real REAPER.
