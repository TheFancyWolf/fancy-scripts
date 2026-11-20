# Pitch Correct Tighten and Tolerance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Fancy Pitch Correct, Tighten and Tolerance replace Stability and Vibrato as the two side drags of a note, Tolerance gets a Global → Item → Note default of 8 ¢ in the top bar, and everything that only served the old controls is removed.

**Architecture:** A note stores `controls.tighten` (0..1) and, optionally, its own `controls.tolerance` (cents). Tolerance joins the existing cascade (`DEFAULTS` → item `overrides` → note `controls`, read through `get_effective`). `K.tighten_line(note)` turns a note's lightly smoothed pitch into the per-frame amount to take away; `K.correction_build` subtracts it from the frame shifts, so the envelope writer, the Preview Curve and the "outdated" check all see it through the one calculation they already share. The left and right drag zones of a note block, the note menu and one new top bar badge edit the two values.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui, `_lib/theme.lua` (read only).

**Spec:** `docs/design/pitch-correct-tighten-tolerance.md` (Approved 2026-11-20, TheFancyWolf). Implement it exactly. Do not invoke skills.

## Global Constraints

- Target files: `Pitch/Fancy_Pitch Correct.lua` (v2.11.0 → v2.12.0) and `CHANGELOG.md` under `[Unreleased]`. No change to `_lib/`, `index.xml`, `.github/` or `_fancy_*.json`. The palette keys `vibrato` and `trend` stay in `_lib/theme.lua`.
- Starting point: branch `spike/pitch-tighten-dial` (uncommitted try-out: `K.tighten_line`, two note-menu sliders, right-click keeps the selection). Rename the branch to `feat/pitch-correct-tighten-tolerance`. Every "TRY-OUT" comment and "(try-out)" label goes.
- **A note with Tighten at 0 % and no Stability / Vibrato edit writes the same envelope as today, point for point.** Sections A and C of `K.correction_build` (ramps, glides) are not edited.
- Values from the spec: Tighten 0..1 shown as `%.0f%%`, default 0; Tolerance 0..50 ¢, default 8 (`DEFAULTS.tolerance = 8`, ExtState `pitch_tolerance`); window `0.4 s × (1 − tighten)²`; the first tenth of the dial fades in (`smoothstep(tighten / 0.1)`); body = first to last frame within 0.5 semitone of `avg_note`; the frames outside the body take the body-edge value; Tolerance is a soft threshold on the slow line (`|v| > tol and v * (1 - tol / |v|) or 0`).
- Copy is fixed by the spec's Copy deck. `Cmd` in any string comes from `K.MOD_LABEL`.
- Old values are dropped: `drift_scale` and `vibrato_scale` saved on a note are not copied into the model on load and are never written again. No conversion.
- The script chunk is near Lua's 200-locals limit and `draw_graph` is very large: new constants and functions go into the existing `K` and `state` tables, not new top-level locals.
- `reaper.*` called directly; every variable `local`; nil-guard API returns; every ReaImGui name checked against `.agents/skills/reaimgui-ux-review/scripts/reaimgui_api_names.txt` before use.
- No test framework, mock or fake REAPER. Tests are `luacheck .` and real REAPER, following `.agents/skills/reaper-screenshot/references/testing-protocol.md` (sweep strays before and after every action). When the bridge does not answer, restart the script with `capture.sh --relaunch "Fancy_Pitch Correct"` and undo through REAPER's Edit menu, checking the undo label names the test's own edit first. Undo every test edit and leave the item, the selection and Theme Mode as they were.
- Commit only when the user says so; never push. Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. **An item never touched by Stability or Vibrato.** Same envelope as before; not marked "Outdated" after the upgrade. (Task 1, test a.)
2. **Many tightened notes while dragging.** A drag of any value stays smooth with twenty or more tightened notes: the filtered line of a note is computed once per change of that note, not on every rebuild. (Task 1, `note.tighten_cache`; test c.)
3. **A note with no usable body** (never within half a semitone of its own centre, or fewer than three frames). Tighten changes nothing on it and it is not written frame by frame with zeros. (Task 1, test d.)
4. **Tolerance edited while no note is tightened**, from the badge, the menu and the right-side drag. The value is stored, the readout says it is not used yet, the envelope does not change. (Task 2, test c; Task 3, test b.)
5. **Undo, redo or a switch to another item during a side drag or with the badge popup open.** The drag is dropped, nothing indexes a note that is gone. (Task 2, test d.)

---

### Task 1: The two values, the correction, and what dies with the old ones

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `DEFAULTS`, `global_defaults`, `PARAM_LABELS`, `K.LIMITS`, `K.PERSIST` ("cascade" group), `gaussian_filter`, `compute_vibrato_weights` (delete), `extract_note_features`, `K.tighten_line`, `is_note_modified`, `load_take_data`, `K.correction_build` (section 1 and `fine_changed` in section B), `reset_selected_note`, the split / trim / merge carry-over tables, `K.correction_view` signature, `K.note_trend` (delete), the trend / vibrato draw loop in `draw_graph` (delete), `state.show_trend`, `state.show_vibrato_regions` and their `K.PERSIST` flags (delete).

**Interfaces — Produces:**
- `DEFAULTS.tolerance = 8`; `global_defaults.tolerance`; `PARAM_LABELS.tighten = "Tighten"`, `PARAM_LABELS.tolerance = "Tolerance"`; `K.LIMITS.tolerance = { 0, 50 }`; `K.PERSIST` number `"pitch_tolerance"` in the "cascade" group. `get_effective(note, "tolerance")` then returns note → item → global, as for the other cascade keys.
- Stored data: `note.controls.tighten` = number 0..1 or `nil` (0); `note.controls.tolerance` = cents or `nil` (inherit). New notes get neither. `drift_scale`, `vibrato_scale` are gone from the defaults; `load_take_data` skips those two keys when it copies saved controls, and clamps `tighten` to 0..1 and `tolerance` to `K.LIMITS.tolerance` (a non-number becomes `nil`).
- `gaussian_filter(arr, sigma_frames)` computes its weights once per call (`radius + 1` values) and gives the same numbers as today.
- `K.tighten_line(note) -> { [frame] = semitones } | nil` — reads the effective Tolerance with `get_effective(note, "tolerance")`; returns `nil` when Tighten is 0, the note has fewer than three frames, or it has no body. Cached in `note.tighten_cache = { frames, smooth, avg, amount, line, tol, out }`: the filtered `line` is reused while `(frames, smooth, avg, amount)` are unchanged, `out` while the tolerance is unchanged too.
- `note.smooth` stays (set in `extract_note_features`); `note.trend`, `note.modulation`, `note.vibrato_weight` are no longer stored (the dots still use the locals inside `extract_note_features`).
- `is_note_modified(note)`: true for `tighten > 0` and for a note's own `tolerance ~= nil` (with the other overrides); the two old tests are removed.
- `K.correction_build` section 1: `frame_shifts[i] = coarse - (tight and tight[i] or 0)`; `fine_changed` in section B = `scooped or has_points or K.tighten_line(n) ~= nil`.
- `K.correction_view` signature: `n.smooth`, `c.tighten or 0`, `get_effective(n, "tolerance")` replace the trend / modulation / vibrato_weight / drift_scale / vibrato_scale entries.
- Reset clears `tighten` and `tolerance` and counts either as a change. Split and Trim carry both; Merge: `tighten` = length-weighted average, `tolerance` = the first note's.

- [ ] **Step 1:** Implement the above. Delete `compute_vibrato_weights`, `K.note_trend`, the vibrato-region / trend drawing loop, the two state flags and their `K.PERSIST` lines.
- [ ] **Step 2:** `luacheck .` → 0 warnings.
- [ ] **Step 3 (real REAPER):** (a) relaunch on the open item: the window draws, no error window, and an item that had no Stability / Vibrato edit is not newly "Outdated" (compare with a relaunch of the `main` file, as in the testing notes). (b) Note menu → Tighten to about 50 %: the Preview Curve flattens the note's body, the entry slide keeps its shape; undo restores. (c) Select all notes, Tighten to 50 % from the menu, then drag a note's pitch: the drag stays smooth; undo both. (d) Reset to Original on a tightened note clears it (one undo point).

### Task 2: The two side drags, their readouts and the Tolerance band

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `K.note_zone` (zone names), the drag start (`orig_values`), the drag body, the commit labels, the drag readout, the hover tooltip, the zone hover drawing, `K.HINT_KINDS` / `K.draw_setting_hint`, `state.hovered_zone` comment.

**Interfaces — Consumes:** Task 1's values and `get_effective(note, "tolerance")`. **Produces:**
- Zone names `"tighten"` (left quarter) and `"tolerance"` (right quarter) replace `"drift"` and `"vibrato"` everywhere (`K.note_zone`, `state.hovered_zone`, `state.drag.zone`).
- Tighten drag: `tighten = clamp(orig + dy_up / (px_per_st * 2) * fine, 0, 1)`; Tolerance drag: starts from `controls.tolerance or get_effective(note, "tolerance")`, `tolerance = clamp(orig + dy_up / px_per_st * 50 * fine, 0, 50)` and writes the note's own value. `fine` = `K.FINE_ADJUST_SCALE` while Ctrl/Cmd is held, accumulated per frame as the pitch drag does. A Tighten that ends at 0 is stored as `nil`.
- Undo labels `"Adjust Tighten"`, `"Adjust Tolerance"` (with the existing " (N notes)" suffix). Shift+Drag is unchanged.
- Readout and hover tooltip per the Copy deck, including `(used once Tighten is above 0%)` when the note's Tighten is 0.
- `K.setting_hint(ctx, "tolerance", dragging, set)` is called while the right zone is hovered or dragged; `K.draw_setting_hint` draws, for key `"tolerance"`, a band `centre ± tolerance` (`span_fill`, edged with `span_edge`) across each reached note whose Tighten is above 0, and returns how many it drew; the existing "nothing marked" status then reads `No note uses Tolerance yet: raise Tighten on a note first`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `luacheck .` → 0 warnings.
- [ ] **Step 3 (real REAPER):** (a) drag the left side of a note up: readout `Tighten: N%`, Preview Curve follows, one undo point "Adjust Tighten". (b) Drag the right side of that note: readout `Tolerance: N¢`, the band shows, one undo point "Adjust Tolerance". (c) Right-side drag on an untightened note: readout carries the not-used-yet note. (d) Esc during a side drag puts the value back, no undo point. Undo every edit.

### Task 3: Top bar badge and note menu

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `HDR_CORR_FULL`, `HDR_CORR_FOLDED`, `HDR_GROUP`, `BAR_BADGES` and its users (`K.bar_measure`, `draw_badge`, `edit_timing`, `draw_timing`, `K.bar_frame`'s unit dispatch), the note menu (`draw_cm_slider` and its rows), the right-click handler.

**Interfaces — Produces:**
- Badge spec gains `unit` (the edit format: `"%.0f ms"` / `"%.0f ¢"`), `tip` (the value's one-line explanation, `nil` for the timing badges) and `fold` (true for the three timing values). New spec `{ id = "tol", key = "tolerance", fmt = "Tolerance: %.0f¢", unit = "%.0f ¢", min = 0, max = 50, tip = "How far a tightened note may stray from its centre before it is pulled in." }`. `HDR_CORR_FULL = { "retune", "tol", "trans", "ramp", "legato" }`, `HDR_CORR_FOLDED = { "retune", "tol", "timing" }`. The Timing button and its popup list only specs with `fold`.
- The badge behaves as the timing badges do (popup with the value drag, right-click item override / reset, level colours, `*` mark, disabled reasons, `K.setting_hint`).
- Note menu value rows, in order: Tighten (0..100 %, scale 100, no level tag, double-click → `nil`), Tolerance (0..50, `%.0f ¢`, level tag, double-click → `nil`), Onset Ramp, Scoop Shape, Transition, Correction Strength. Tighten and Tolerance write to every selected note when the menu's note is one of several selected, and then end with `(N notes)`; the others act on the menu's note. The row keeps a stable `###` id.
- A right-click on an already selected note keeps the selection.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `luacheck .` → 0 warnings.
- [ ] **Step 3 (real REAPER):** (a) the bar shows `Tolerance: 8¢` between Strength and the timing badges; capture the docked width in use. (b) Click the badge, drag to another value with no note tightened: status says nothing changed on items, envelope unchanged; double-click resets to 8. (c) Tighten a note, change the badge: the note's Preview Curve follows; right-click → Override for this item gives the `*`; undo. (d) Two notes selected, right-click one: rows read `(2 notes)` and both change. Put the global default back to 8 and undo every edit.

### Task 4: Layers, Help, already-dead code, version

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — Layers menu (drop "Vibrato Shading"), Settings → Diagnostics (drop "Trend Line"), Help rows, Shortcuts panel row, the header's `@version` / `@changelog`; `CHANGELOG.md`.

- Help rows and the panel row per the Copy deck. Panel row: group Edit, after the Shift + Drag row.
- Already-dead code to remove, each verified by grep before deleting: `state.pitchmode_name`; `state.drag.original_value`; the `anchor_start` / `anchor_end` entries and the `time` / `mod_val` fields of `smart_spots`; `pcall(reaper.ImGui_GetKeyMods, …)` and `reaper.ImGui_Mod_Shift and … or 0` guards (call both directly, as lines elsewhere in the file do); "Milestone" / "Phase" comment tags; the duplicated banner numbers. Not in this plan (they change stored data or what is written): `results[i].freq`, `display_note`, `scoop_magnitude`, `voiced_start_time`, `voiced_start_idx`.
- `@version 2.12.0`; `@changelog` and `CHANGELOG.md` say, in user terms: Tighten and Tolerance replace Stability and Vibrato; the Tolerance default in the top bar; old Stability / Vibrato values are dropped and such items show as outdated; Vibrato Shading and Trend Line are gone.

- [ ] **Step 1:** Implement. **Step 2:** `luacheck .` → 0 warnings. **Step 3 (real REAPER):** the Layers menu, Settings → Diagnostics and the Help modal show the new rows and none of the old; no error window.

### Task 5: Fold the repeated lists (behaviour unchanged)

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua`.

- `K.NOTE_CONTROLS`: one ordered table of the per-note values (`tighten`, `tolerance`, `scoop_shape`, `retune_speed`, `transition_ms`, `onset_ramp_ms`, `bypassed`), each with `merge` (`"weighted"` / `"first"` / `"reset"`), `modified` (`"positive"` / `"set"` / `"truthy"`) and, where it has one, `limits`. Helpers on `K`: `controls_carry(old_ctrl)`, `controls_merge(notes)`, `controls_reset(ctrl) -> changed`, `controls_modified(ctrl)`, `controls_load(saved)`; they replace the hand-written lists in `is_note_modified`, `load_take_data`, `reset_selected_note`, split, trim, merge. `center_pitch` and `points` stay special.
- `K.ZONE_CONTROLS[zone][shift]` = `{ key, lo, hi, per_row, label, fmt, scale }` replaces the parallel if-chains for the side zones in the drag start, drag body, commit label, readout and hover tooltip. The pitch zone without Shift stays hand-written.
- [ ] **Step 1:** Record what the open item writes before the refactor: tighten one note, set a Shift+Drag value on another, capture the Preview Curve; undo. **Step 2:** Refactor. **Step 3:** `luacheck .` → 0 warnings. **Step 4 (real REAPER):** repeat step 1's edits: same pictures, same undo labels; split, merge and reset a tightened note: values carried as in Task 1. Undo every edit.
