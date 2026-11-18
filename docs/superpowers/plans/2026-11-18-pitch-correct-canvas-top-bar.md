# Pitch Correct Canvas, Zoom and Top Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make the Fancy Pitch Correct notes the most readable thing on the canvas, give each axis one visible zoom control, and move every control into one top bar.

**Architecture:** All drawing stays in `draw_graph`; it carves its rectangle into note column, note area, overview strip and pitch strip, and every existing conversion keeps using the (shrunk) note area. The dock's units keep their code and move behind `K.bar_frame`, which the header's planner places; the dock block and its row in `loop_body` go. New colours are `P.canvas` tokens in `_lib/theme.lua`, built for both theme modes.

**Tech Stack:** Lua 5.4, ReaScript, ReaImGui, `_lib/theme.lua`.

**Spec:** `docs/design/pitch-correct.md`

## Global Constraints

- `reaper.*` never aliased; every variable `local`; Theme tokens only (no raw colours; sizes from `Theme.layout` except the existing literals this plan does not touch).
- The chunk has a 200-local limit: new cross-section functions go on `K`, not in new chunk-level locals.
- No fake REAPER / ImGui harness. Verification = `luac -p`, `luacheck .` (0 warnings before this plan), and live checks in REAPER.
- A layout is chosen from the content width alone, never from the selection or the analysis state.
- Every canvas text token ≥ 4.5:1, every boundary ≥ 3:1, in Fancy Dark and Match Theme.
- Copy strings are exactly the spec's Copy deck.

## Review Focus

- Item with one note, or notes spanning less than an octave → range is still ≥ 12 semitones, rows not giant (Task 2 check).
- Manual pitch range, then a note dragged outside it → the range does not jump mid-drag or after release (Task 2 check).
- Item analysed before RMS was stored (`frame.rms == nil`) → blobs draw without an envelope, no error (Task 3 check).
- Item shorter than `MIN_VIEW_SPAN_S`, or a 0-width overview thumb → strip gestures do nothing, no division by zero (Task 4 check).
- Window narrower than plan 6, docked → bar still draws (clipped), canvas still gets `total_h > 80` or the "Window too short" line (Task 5 check).

---

### Task 1: Canvas palette tokens

**Files:** Modify `_lib/theme.lua` (section 4A: `build_canvas_fancy`, `build_canvas_match`, header comment); Modify `Utility/Fancy_Design System.lua` (`CANVAS_GROUPS`).

**Interfaces — Produces:** `P.canvas.gutter_bg`, `gutter_text`, `gutter_text_dim`, `gutter_text_tonic`, `gutter_strip`, `note_wave`, `overview_bg`, `overview_note`, `view_fill`, `view_border`, `view_grip`; changed values for `row*`, `grid*`, `note_*`, `trace`, `playhead`.

- [x] Change and add the tokens in `build_canvas_fancy`; derive and fit them in `build_canvas_match`.
- [x] List the new tokens in the Design System window's groups.
- [x] Check: a scratch script loads `theme.lua` with a stub `reaper` and prints the contrast of every label / boundary token on its surfaces in both modes; all meet the constraint.

### Task 2: Pitch range and the pitch strip

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` (`state`, `K`, `clear_interaction_state`, `adopt_take_data`, `draw_graph` range + wheel).

**Interfaces — Produces:** `state.view_p0`, `state.view_p1` (nil = fit); `state.view_drag = { kind, start, a0, a1 }`; `K.notes_pitch_fit(notes) -> has, lo, hi`; in `draw_graph`: `full_h`, shrunk `w` / `h`, `fit_min`, `fit_max`, `ext_min`, `ext_max`, `set_pitch_view(p0, p1)`.

- [x] Fit the range to the notes (≥ 12 semitones); fall back to the frames when there are no notes.
- [x] Apply `view_p0 / view_p1` when set; Alt+wheel zooms, Shift+wheel scrolls.
- [x] Draw the pitch strip and handle its drags and double-click.
- [x] Check: Review Focus lines 1 and 2.

### Task 3: Notes, rows, note column, markers

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` (`draw_graph` grid, blocks, smart spots, playhead; `K.results_range` neighbour `K.results_peak`).

- [x] Note column and rows from the new tokens.
- [x] Blobs: fill, envelope (`K.results_peak` normalises RMS), border, edit mark; label pill only when hovered or selected.
- [x] Smart spots only for hovered / selected notes; playhead head in the ruler.
- [x] Check: Review Focus line 3; acceptance 1.

### Task 4: Overview strip, Z / F, status pill

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` (`draw_graph`; `K.status_line`; `K.INFO_SECTIONS`).

**Interfaces — Produces:** `K.status_line(has_data) -> string` (status message, else hint; "" when nothing to say).

- [x] Overview strip: notes, thumb, grips, gestures, tooltip.
- [x] Z and F shortcuts; help rows.
- [x] Status pill on every return path of `draw_graph`.
- [x] Check: Review Focus line 4; acceptance 3, 4, 7.

### Task 5: Single top bar

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` (HEADER BAR block, BOTTOM DOCK block → TOP BAR CONTROLS, `loop_body`).

**Interfaces — Produces:** `K.bar_measure(ctx) -> s` (`s.unit_w[id]`, `s.edit_w`, `s.frame_h`); `K.bar_frame(ctx, has_target, target_item) -> draw_unit(id)` for ids `retune`, `trans`, `ramp`, `legato`, `timing`, `snap`, `quantize`, `split`, `merge`. **Removes:** `plan_dock`, `layout_dock_texts`, `render_bottom_dock`.

- [x] Move the dock units behind `K.bar_frame`; add the `timing` unit and the scope pill.
- [x] Header: units, groups, the six plans, More popup with Layers / Settings / Help; drop the wordmark and labels.
- [x] `loop_body`: no footer height, no dock call; window size constraints from the new plans.
- [x] Check: Review Focus line 5; acceptance 5, 6.

### Task 6: Release notes and verification

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` (header `@version 2.6.0`, `@changelog`), `CHANGELOG.md`.

- [x] Bump the version, write the changelog entries.
- [x] `luac -p "Pitch/Fancy_Pitch Correct.lua" _lib/theme.lua` → no output; `luacheck .` → 0 warnings / 0 errors.
- [~] Live check in REAPER against the spec's acceptance criteria. NOT DONE: no REAPER bridge in the implementing session. A scratch run against a stubbed `reaper` API (not committed) found no Lua runtime error across widths 240–1500 px, every gesture, open popups, a bypassed item and an empty canvas.
