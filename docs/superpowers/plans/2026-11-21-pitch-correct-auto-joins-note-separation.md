# Pitch Correct: Automatic Joins and Note Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Transition / Onset Ramp / Legato Gap values with joins derived from the sung pitch, rebuild the note splitting around a single Separation control, and turn Scoop Shape into Slide In.

**Architecture:** All work is in `Pitch/Fancy_Pitch Correct.lua`. The pure parts (level measurement, splitting, note body, correction trajectory, edit transfer on a re-split) become functions on the existing `K` table that take data in and return data out, and are tested with plain `lua` through a test-mode guard at the bottom of the script. UI changes come last and are checked by hand in REAPER.

**Tech Stack:** Lua 5.4 (REAPER 7 ReaScript), ReaImGui. Tests: `/opt/homebrew/bin/lua`, no framework.

**Spec:** `docs/superpowers/specs/2026-11-21-pitch-correct-auto-joins-note-separation-design.md`

## Global Constraints

- One script file; REAPER 7.0+ and ReaImGui only. No new `_lib` module.
- No backwards compatibility: no migration of stored `transition_ms`, `onset_ramp_ms`, `legato_threshold_ms`, `scoop_shape`, or of frames without a short level.
- Pitch detection (YIN, quality modes, vocal range) and the behaviour of Tighten, Tolerance and Strength do not change.
- Functions under test make no REAPER calls.
- Every time constant is in seconds and converted with the actual frame spacing (hop 64–1024 samples, about 1.3–23 ms). Never a fixed frame count.
- The script has many top-level locals; new functions and constants go on `K`, not in new top-level `local`s (Lua's 200-local limit).
- Work on branch `feat/pitch-correct-auto-joins`, not `main`. Commit messages follow the repo style (`feat(pitch-correct): …`) and end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Run all tests with: `lua docs/superpowers/tests/pitch_correct_spec.lua` from the repo root. Expected final line: `ok N tests`. Also run `luac -p "Pitch/Fancy_Pitch Correct.lua"` after every edit.

## Review Focus

1. **Unusual frame spacing** (hop 64 and hop 1024): the same sung input gives the same notes. → Task 3 test `segment_hop_extremes`.
2. **Items with nothing to split** (all silent; one held note; fewer than 3 frames): no error, 0 or 1 notes. → Task 3 test `segment_degenerate`.
3. **A note with no body** (too short, or never within 0.5 st of its centre) next to a normal note: joins and Slide In treat its whole length as body; trajectory stays continuous. → Task 6 test `join_bodiless_note`.
4. **Frames stored without a short level** (analysed before this change): splitting must not error; it uses `frame.rms` in place of `frame.lvl`. → Task 3 test `segment_missing_lvl`.
5. **Octave error lasting 2–3 frames** inside a held note (longer than a one-frame median removes, shorter than the hold time): still 1 note. → Task 3 test `segment_short_octave_error`.

---

### Task 1: Test entry point

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (last line, `main()`)
- Create: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces: when the global `FANCY_PITCH_TEST` is truthy, the script's chunk returns `{ K = K, state = state, DEFAULTS = DEFAULTS }` instead of calling `main()`.
- Produces in the spec file: `load_script()` → that table; `test(name, fn)`; `eq(a, b, msg)`; `near(a, b, tol, msg)`; and
  `frames(segs, hop_s)` → results array. `segs` is a list of `{ dur = seconds, note = st | nil | function(t) -> st, lvl = linear | function(t) -> linear }`; each frame is `{ time, note, rms, lvl }` with `rms = lvl` and `time` starting at 0. `lvl` defaults to 0.1.

- [ ] **Step 1:** Write the spec file with the helpers above and one test `loads`: `load_script()` returns a table whose `K.correction_build` is a function. The loader installs a global `reaper` whose every field is a function returning nil (`setmetatable({}, { __index = function() return function() end end })`), with `ImGui_CreateContext` present, sets `FANCY_PITCH_TEST = true`, and `dofile`s the script.
- [ ] **Step 2:** Run it. Expected: FAIL (the script calls `main()` or errors at top level).
- [ ] **Step 3:** Replace the final `main()` with `if FANCY_PITCH_TEST then return { K = K, state = state, DEFAULTS = DEFAULTS } end` followed by `main()`. If top-level code needs a real value from a `reaper` call, give the stub that one value; do not guard top-level code in the script beyond this.
- [ ] **Step 4:** Run. Expected: `ok 1 tests`.
- [ ] **Step 5:** Commit: `test(pitch-correct): load the script's internals from plain lua`.

### Task 2: Short-window level per frame

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `yin_process_block` (~980–1075), its callers in `process_analysis_step` (~3385) where a result frame is built.

**Interfaces:**
- Produces: `K.short_level(s, b_size, sample_rate) -> number` — RMS of the samples in a 10 ms window centred on the block (`K.LEVEL_WINDOW_S = 0.010`; the whole block if it is shorter).
- Produces: every result frame carries `lvl` (number) beside `rms`.

- [ ] **Step 1:** Tests `short_level_*`: a block of constant amplitude 0.5 → `near(…, 0.5, 1e-9)`; a 2048-sample block at 44100 Hz that is 0 everywhere except the central 441 samples at 1.0 → `near(…, 1.0, 1e-9)` (whole-block RMS would be about 0.46).
- [ ] **Step 2:** Run. Expected: FAIL, `K.short_level` is nil.
- [ ] **Step 3:** Implement `K.short_level`; return it from `yin_process_block` as a third value and store it as `lvl` on the frame.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(pitch-correct): store a short-window level per analysis frame`.

### Task 3: Note splitting

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `run_hybrid_segmentation` (3277–3383), `DEFAULTS`/`state` (~183–202, ~363), the engine ExtState block (~630–634), `K.LIMITS` (~276).

**Interfaces:**
- Consumes: frames with `time, note, rms, lvl` (Task 2).
- Produces: `K.separation_params(sep) -> { pitch_st, hold_s, dip_db, min_note_s }`, `sep` in 0..1, linear between the spec's three columns (0 → 1.5 / 0.140 / 12 / 0.100; 0.5 → 0.8 / 0.090 / 6 / 0.070; 1 → 0.4 / 0.050 / 3 / 0.040).
- Produces: `K.segment(results, sep) -> notes, split_points`. `notes`: time-ordered `{ start_time, end_time, frames, sum_note, count }`, frames being the original result frames. `split_points`: `{ time, reason }`, reason one of `"Onset"`, `"Pitch change"`, `"Level dip"`.
- Produces: `state.separation` (0..1, default `DEFAULTS.separation = 0.5`, limits `K.LIMITS.separation = { 0, 1 }`), stored as engine ExtState key `pitch_separation`.
- `run_hybrid_segmentation()` becomes: `state.notes, state.split_points = K.segment(state.results, state.separation)`, then the existing anchor-pitch / `extract_note_features` loop.

Fixed constants on `K.SEG`: `BRIDGE_S = 0.025`, `SILENCE_DB = 40` (below the 95th-percentile level of the voiced frames), `DIP_REACH_S = 0.150`, `MEDIAN_S = 0.015` (pitch median window, at least 3 frames). Level used everywhere is `frame.lvl or frame.rms`.

Algorithm (order matters): mark silent/unvoiced frames → bridge short dropouts → median-filter pitch per voiced run → within each run, walk frames keeping the current note's centre (median of its frames after the first `hold_s`); a departure beyond `pitch_st` that lasts `hold_s` starts a new note at the frame where the pitch crossed halfway to the settled pitch (median of the held stretch) → add splits at level minima that are `dip_db` below the highest level within `DIP_REACH_S` on each side → merge any segment shorter than `min_note_s` into the touching neighbour closer in median pitch, or drop it if none touches.

- [ ] **Step 1:** Write the tests (each at hop 256/44100 s unless named):
  - `separation_params_columns`: the three columns above, exactly.
  - `segment_slide`: 0.4 s at 60, 0.04 s linear 60→62, 0.4 s at 62 → 2 notes; boundary time within 0.02 s of 0.42; reason `"Pitch change"`.
  - `segment_rearticulation`: 0.4 s at 60, 0.03 s at 60 with level 9 dB down, 0.4 s at 60 → 2 notes; reason `"Level dip"`.
  - `segment_vibrato`: 1 s of `60 + 0.5*sin(2π·5.5·t)` → 1 note.
  - `segment_dropout`: 0.4 s at 60, 0.015 s `note = nil`, 0.4 s at 60 → 1 note.
  - `segment_octave_frame`: 0.8 s at 60 with one frame at 72 → 1 note.
  - `segment_short_octave_error`: same with 3 consecutive frames at 72 → 1 note.
  - `segment_gap`: 0.3 s at 60, 0.1 s nil, 0.3 s at 60 → 2 notes, each reason `"Onset"`.
  - `segment_separation_range`: 0.4 s at 60, 0.04 s slide, 0.4 s at 60.6 → 1 note at sep 0, 2 notes at sep 1.
  - `segment_hop_extremes`: `segment_slide` and `segment_vibrato` inputs at hop 64/44100 and 1024/44100 → same note counts.
  - `segment_degenerate`: empty results → 0 notes; all frames nil → 0; 2 frames → 0; 1 s at 60 → 1 note covering 0..1 s within one frame.
  - `segment_missing_lvl`: `segment_rearticulation` input with every `lvl` set to nil → no error, 2 notes.
  - `segment_frames_intact`: across `segment_slide`, every voiced input frame belongs to exactly one note, in time order.
- [ ] **Step 2:** Run. Expected: FAIL, `K.separation_params` is nil.
- [ ] **Step 3:** Implement `K.separation_params`, `K.SEG`, `K.segment`; reduce `run_hybrid_segmentation` to the wrapper; add `separation` to `DEFAULTS`, `state`, `K.LIMITS` and the engine ExtState block.
- [ ] **Step 4:** Run. Expected: PASS. If a threshold must move to pass `segment_vibrato` and `segment_slide` together, change the 50 % column in both code and spec, and say so in the commit body.
- [ ] **Step 5:** Commit: `feat(pitch-correct): split notes on sustained pitch change and level dips`.

### Task 4: Note body helper

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `K.tighten_line` (1928–1977).

**Interfaces:**
- Produces: `K.note_body(note) -> a, b` (frame indices, `a <= b`) or `nil` when the note has fewer than 3 frames, no `note.smooth`, or fewer than 3 frames between its first and last frame within `K.TIGHTEN_BODY_ST` of `note.avg_note`. Cached on the note, keyed on `note.frames`, `note.smooth`, `note.avg_note` (not on Tighten).
- `K.tighten_line` calls it instead of finding `a`, `b` itself; its results do not change.

- [ ] **Step 1:** Tests `note_body_*` on hand-built notes (`frames`, `smooth`, `avg_note`, `controls`): flat note → `1, n`; a note whose first 5 frames are 2 st low → `a == 6`; a 2-frame note → nil; a note with `controls.tighten = nil` still returns a body. `tighten_unchanged`: for a wobbling note with `tighten = 0.5`, record `K.tighten_line` output before the refactor in the test as literals (first, middle, last frame) and assert them within 1e-9.
- [ ] **Step 2:** Run. Expected: FAIL, `K.note_body` is nil.
- [ ] **Step 3:** Implement and switch `K.tighten_line` over.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `refactor(pitch-correct): one cached note body for Tighten, joins and Slide In`.

### Task 5: Slide In

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `K.NOTE_CONTROLS` (1410), `extract_note_features` step 7 (1592–1609), `save_take_data` (2023–2025) and its loader, `K.correction_build` part 1 (2407–2430), `PARAM_LABELS` (211), change signature (3951), every other `scoop_shape` / `scoop_magnitude` / `voiced_start_idx` / `voiced_start_time` use.

**Interfaces:**
- Consumes: `K.note_body` (Task 4).
- Produces: per-note control `slide_in` (0..1, nil = 0), label `"Slide In"`. `scoop_shape`, `scoop_magnitude`, `voiced_start_idx`, `voiced_start_time` no longer exist anywhere.
- Behaviour in `K.correction_build`: slide frames are `1 .. a-1`. For each, `frame_shifts[i] = natural + clamp((settle - sung) - natural, ±K.SCOOP_MAX_ST) * slide_in`, where `settle = frames[a].note + frame_shifts[a]`. No taper. Nothing happens when the body is nil or `a == 1`. The span kind stays `"scoop"`.

- [ ] **Step 1:** Tests through `K.correction_build` on a single edited note (centre moved +0.3 st) whose first 6 frames rise linearly from 1 st below: `slide_in_zero` — shifts of frames 1..6 equal the coarse shift; `slide_in_full` — `frames[i].note + frame_shifts[i]` equals `frames[7].note + frame_shifts[7]` within 1e-9 for i = 1..6; `slide_in_half` — halfway between those two; `slide_in_no_slide` — a flat note gives identical shifts for 0 and 1; `slide_in_cap` — an onset frame 12 st low moves by no more than 3 st.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; rename the key everywhere; delete the onset analysis and its saved fields.
- [ ] **Step 4:** Run. Expected: PASS. `grep -n "scoop_shape\|scoop_magnitude\|voiced_start" "Pitch/Fancy_Pitch Correct.lua"` prints nothing.
- [ ] **Step 5:** Commit: `feat(pitch-correct): Slide In flattens the sung slide up to the note body`.

### Task 6: Automatic joins

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `K.correction_build` part 2 (2443–2578), `DEFAULTS` (183–185), item overrides (199–201), `PARAM_LABELS` (208–210), `get_effective` (500–522), cascade ExtState (620–622), `K.NOTE_CONTROLS` (1407–1408), change signature (3953–3960).

**Interfaces:**
- Consumes: `K.note_body`, per-frame `frame_shifts` from part 1 (including Slide In).
- Produces: `K.JOIN = { FADE_S = 0.030, MIN_S = 0.010, MAX_S = 0.120, MAX_PART = 0.4 }`.
- Produces: `K.correction_build(notes, item_len)` with the same return shape `{ points, spans, ranges }` and span kinds `"onset"`, `"release"`, `"glide"`, `"scoop"`; kind `"gap"` is no longer emitted. It reads no timing setting.
- `transition_ms`, `onset_ramp_ms`, `legato_threshold_ms` are removed from the model (the UI is Task 8; leave UI code compiling by removing only what would error at load).

Rules: two neighbours are joined when `gap < 2 * FADE_S`. Blend span = first note's body-end frame time → second note's body-start frame time (a bodiless note counts as all body); grown symmetrically to `MIN_S` if shorter; cut to `MAX_S`, and to `MAX_PART` of each note's length on its own side, keeping the end nearer the boundary. Inside the span, one point per frame time (both notes' frames, plus the span's two ends): `value = hold + (own - hold) * smoothstep(u)`, `hold` = first note's shift at the span start, `own` = the second note's `frame_shifts` at that time (its first frame's shift for times before it starts). Outside spans, an edited note writes one point per frame when its shifts vary and two points when they are constant, as today. Fades: `min(FADE_S, 0.25 * note length)`, shaped as today.

- [ ] **Step 1:** Tests, with a helper `max_step(points)` (sort by time, largest `|Δval|` between neighbours):
  - `join_continuous`: two touching notes shifted +0.3 and −0.2, second with a 40 ms slide → one `"glide"` span, `max_step < 0.12`.
  - `join_span_follows_slide`: same input → glide `t0` within one frame of the first note's body end, `t1` within one frame of the second's body start.
  - `join_limits`: second note with a 300 ms slide → glide length ≤ 0.120 + one frame; a 50 ms second note → the glide ends no later than 40 % into it.
  - `join_min`: two flat touching notes → glide length within one frame of 0.010, centred on the boundary.
  - `join_meets_tightened_body`: second note has `tighten = 0.6` and wobble → the point at glide `t1` equals that frame's `frame_shifts` within 1e-9; `max_step < 0.12`.
  - `join_slide_in`: second note `slide_in = 1` → still continuous, glide end value equals the frame's shift.
  - `unjoined_fades`: two notes 0.2 s apart → no glide; one `"release"` and one `"onset"` span, each 0.030 s within 1e-6; value 0 between them.
  - `joined_by_short_gap`: 0.04 s apart → one glide, no fades between.
  - `join_bodiless_note`: a 3-frame second note 3 st from its centre → no error, `max_step` bounded by the difference of the two shifts.
  - `untouched_pair_writes_nothing`: two unedited notes → `#points == 0`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; delete the three keys from the model.
- [ ] **Step 4:** Run. Expected: PASS. `grep -n "legato_threshold_ms" "Pitch/Fancy_Pitch Correct.lua"` prints nothing outside UI tables Task 8 removes.
- [ ] **Step 5:** Commit: `feat(pitch-correct): joins between notes follow the sung slide`.

### Task 7: Re-split that keeps edits

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — near `request_analyze` (8364–8393) and `run_hybrid_segmentation`.

**Interfaces:**
- Consumes: `K.segment`, `extract_note_features(note, preserve_controls)`, `K.controls_carry`, `K.points_transfer`, `is_note_modified`, `request_confirm`, `apply_envelope_to_take`.
- Produces: `K.resplit_match(old_notes, new_notes, tol_s) -> pairs, lost` — `pairs[new_index] = old_note` where both `start_time` and `end_time` differ by at most `tol_s`; `lost` = the number of old notes for which `is_modified(old)` is true and that are in no pair. Pure: takes the predicate as a 4th argument `is_modified`.
- Produces: `K.resplit(prev_separation)` — re-splits the active item from `state.results` with `state.separation`. Matched notes take the old note's controls (target pitch kept as an offset from the new centre, as `split_note_at` does) and pitch points. If `lost > 0`, it first asks with `request_confirm` (id `"resplit"`, body `"This re-splits the notes and discards your edits to N note(s)."`, confirm label `"Re-Split"`); cancelling sets `state.separation = prev_separation`. Writes one undo point `"Change Note Separation"`, does not call `K.reset_view`, clears the note selection. With no results in memory it only stores the value.

- [ ] **Step 1:** Tests for `K.resplit_match`: identical lists → every index paired, `lost == 0`; one old edited note cut in two → unpaired, `lost == 1`; one old unedited note cut in two → `lost == 0`; an edge moved by half of `tol_s` still pairs, by twice `tol_s` does not.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement both functions. `tol_s` passed by `K.resplit` is the frame spacing of `state.results`.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(pitch-correct): re-split notes without losing edits on unchanged notes`.

### Task 8: Controls and UI

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` — `K.ZONE_CONTROLS` (4122–4137), hint spans (4308–4311, 4332, 4382), note pills (5732–5742), context menu (6408–6412), shortcuts table (7055–7061), top bar (8534–8565, 9084–9128, 9181, 9669 onward), `state.timing_open` and ExtState `pitch_timing_open` (626), comments that name the removed values.

**Interfaces:**
- Consumes: `slide_in`, `state.separation`, `K.resplit(prev)`.

Changes, with the spec's exact copy:
- Top bar order: selection pill, Tighten, Strength, Tolerance, Slide In, Separation. Remove the Timing button, the Timing row and `state.timing_open`.
- Slide In bar entry: key `slide_in`, 0–100 %, tip `"Slide In: how much of the slide into the note is corrected. 0% keeps the slide as sung, 100% removes it."`
- Separation bar entry: 0–100 %, not per-note (shows the same value whatever is selected, no inherit level, no reset-to-inherit), tip `"Separation: how readily the analysis splits the singing into notes. Raise it when separate notes are joined, lower it when one note is cut up."` While dragging it only changes `state.separation`; on release (and on a typed value) it calls `K.resplit(value_before_the_drag)`.
- Shift + drag anywhere on a note adjusts Slide In: all three `[true]` zone entries become the one `slide_in` control (readout `"Slide In: %.0f%%"`, undo `"Adjust Slide In"`); the Shift pill shows one label, `"Slide In"`.
- Context menu sliders: Tighten, Tolerance, Slide In.
- Shortcuts panel: one row `"Shift + Drag Note"` → `"Adjust Slide In"`, panel label `"Slide In"`; the Onset Ramp / Transition rows go.
- Hint overlay: keep the `scoop` span for `slide_in`; remove the entries for the three deleted keys.

- [ ] **Step 1:** Add test `no_removed_names`: read the script as text and assert none of `transition_ms`, `onset_ramp_ms`, `legato_threshold_ms`, `scoop_shape`, `"Legato Gap"`, `"Onset Ramp"`, `"Scoop Shape"`, `timing_open` occurs; and `"Slide In"` and `"Separation"` do.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Make the changes above.
- [ ] **Step 4:** Run all tests and `luac -p`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(pitch-correct): Slide In and Separation replace the Timing row`.

### Task 9: Release notes and REAPER check

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` header (`@version 2.16.0`, `@changelog`), `CHANGELOG.md` (new first entry under `[Unreleased]`, same style as the v2.15.0 entry).

- [ ] **Step 1:** Bump the version and write both changelog texts: joins are automatic; Transition, Onset Ramp and Legato Gap are gone; Scoop Shape is now Slide In; new Separation control; items must be analysed again.
- [ ] **Step 2:** Run all tests and `luac -p`. Expected: PASS.
- [ ] **Step 3:** Commit: `feat(pitch-correct): automatic joins, Slide In and Separation (v2.16.0)`.
- [ ] **Step 4:** Hand the user this checklist to run in REAPER (it cannot be automated): the script opens without error; analysing a take with close notes splits them; moving Separation changes the notes on release, one undo step restores them; an edited note that is not re-cut keeps its edits and a re-cut edited note triggers the confirm; a tightened note next to an untouched one has no audible step; Slide In at 100 % removes a scoop; Shift + drag on a note changes Slide In; no Timing button remains.
