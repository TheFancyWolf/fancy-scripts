# Pitch Correct Modes (Natural / Classic / Hard) Implementation Plan

docs/design/pitch-correct-modes.md is Approved (2026-11-23, TheFancyWolf). Implement it exactly. Do not invoke skills.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Mode (Natural, Classic, Hard) to Fancy Pitch Correct while Natural stays identical to v2.18.0, proven by tests written before any feature code.

**Architecture:** Today's `K.correction_build` is renamed `K.natural_build` and not edited. A new, thin `K.correction_build` returns `K.natural_build`'s own result when no note is Classic or Hard; otherwise it runs `K.natural_build` with each Classic or Hard note shown as a bypassed stand-in and adds the points of a new mode writer. A note's mode is `controls.correct_mode`, an item's is `take_data.overrides.correct_mode`, both in the take data inside undo; nothing is stored in ExtState.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui, `_lib/theme.lua` (unchanged). Tests: plain Lua, `lua docs/superpowers/tests/pitch_correct_spec.lua` from the repo root.

**Spec:** `docs/design/pitch-correct-modes.md` (read it in full before Task 1; its "Natural stays untouched: the contract", "Sound rules" and "Copy deck" sections are binding).

## Global Constraints

- Branch `feat/pitch-correct-modes`, cut from `main` at `810bc35`. Never push; commit per task.
- **Do not edit** (text must stay as at `810bc35`): the body of today's `K.correction_build`, `K.tighten_line`, `K.note_body`, `K.points_offsets`, `is_note_modified`, `K.controls_edited`, `K.JOIN`, the Tighten and Tolerance lines of `K.controls_load`, `K.ZONE_CONTROLS` and the zone-drag maths, `param_drag`, the `BAR_VALUES` entries, and all of `_lib/theme.lua`.
- Existing code may be touched only in the places listed in the spec's table "The few places existing code may be touched", and only by adding. Every added branch is behind "this note is Classic or Hard".
- Stored names: `correct_mode` (0 Natural, 1 Classic, 2 Hard). Never read or write `tune_mode` or the ExtState key `pitch_tune_mode`. No ExtState for the mode at all.
- No new chunk-level `local` in `Pitch/Fancy_Pitch Correct.lua` (the chunk is near Lua's 200-local limit): new functions and tables go on `K`; locals inside existing `do` blocks and functions are fine.
- Constants: `K.MODE = { GLIDE_S = 0.100, OUTLIER_ST = 3, STEP_S = 0.0005 }`; names `K.MODES = { "Natural", "Classic", "Hard" }`.
- User-facing strings are copied verbatim from the spec's Copy deck. No "over-tune", "glide" or "frame" in any string.
- House rules (AGENTS.md): call `reaper.X()` directly; every variable `local`; no hardcoded colours, sizes or spacing; check each ReaImGui name with the `reaper-dev` tools before use; never edit `index.xml`, `.github/workflows/` or `_fancy_*.json`; `luacheck .` clean before every commit.
- No fake or mock of REAPER beyond the stub the spec file already has. Real-REAPER steps follow `.agents/skills/reaper-screenshot/references/testing-protocol.md`; a failed permission prompt means stop and tell the user.
- The user's vocal analysis is never committed.

## Review Focus

Inputs the spec implies but its examples do not show, most likely first. Each has a test in the task named.

1. A Classic or Hard note whose frames have no pitch at all, or no frames: written flat at its scale note (or not at all), no error. → Task 3, Task 4.
2. A Classic or Hard note at the very start or end of the item: every point time stays within `0 .. item_len`, in order. → Task 4.
3. Take data from the first attempt or a damaged save: Tighten above 1, a leftover `tune_mode`, `correct_mode` of 3, 1.5 or a string, on the note or on the item: all read as Natural. → Task 2.
4. An unknown or empty scale: the nearest semitone is used. → Task 3.
5. An untouched note in an item whose mode is Classic, and a note with its own Natural in that item: neither is over-tuned. → Task 2, Task 4.

---

### Task 1: Proof of Natural

**Files:**
- Modify: `docs/superpowers/tests/pitch_correct_spec.lua` (above the line `-- Tests appended by later tasks go above this line.`)
- Create: `docs/superpowers/tests/fixtures/natural_v2_18_0.lua`

**Interfaces:**
- Produces: `natural_corpus()` in the spec, returning a fresh list of `{ name = string, notes = { note... }, item_len = number, setup = fn | nil, teardown = fn | nil }` on every call (builds mutate and cache on notes); the fixture file returning `{ commit = "810bc35", cases = { [name] = { points = { { t, v }... }, spans = { { kind, t0, t1, a, b }... }, ranges = { { t0, t1 }... }, shifts = { { number... }... } } } }`.

- [ ] **Step 1: Create the branch and confirm the starting point**

Run: `git checkout -b feat/pitch-correct-modes 810bc35 && git diff --quiet 810bc35 -- "Pitch/Fancy_Pitch Correct.lua" && lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: `ok 60 tests`

- [ ] **Step 2: Write `natural_corpus()`**

At least these cases, each built with the helpers the existing tests of that feature already use (`join_note`, `slid_pair`, `slide_note`, `body_note`, `frames`), with wobbling sung pitch (a sine of ±0.3 st at 5 Hz plus a slow drift) wherever Tighten is set:

`moved`, `tighten_50_tol_8`, `tighten_100`, `tighten_50_tol_30`, `slide_in_0`, `slide_in_50`, `slide_in_100`, `strength_50_note`, `strength_50_item` (item override through `state.session_takes`, set in `setup`, undone in `teardown`), `joined_pair`, `short_gap`, `unjoined_fades`, `edited_then_untouched`, `edited_then_bypassed`, `bypassed_then_edited`, `pitch_points` (as the existing pitch-point tests build them), `bodiless_note`, `note_at_item_start`, `note_at_item_end`, `phrase_of_six` (mixed edits).

- [ ] **Step 3: Add the recorder**

`lua docs/superpowers/tests/pitch_correct_spec.lua --record-natural` runs `S.K.correction_build` on every corpus case and writes the fixture, numbers as `%.17g`, lines short enough for `luacheck`. It refuses with a message and exit code 1 unless `git diff --quiet 810bc35 -- "Pitch/Fancy_Pitch Correct.lua"` succeeds.

- [ ] **Step 4: Record**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua --record-natural`
Expected: the fixture file exists with 20 or more cases.

- [ ] **Step 5: Write the two tests**

```lua
test("natural_same_numbers", function()
  local fx = dofile("docs/superpowers/tests/fixtures/natural_v2_18_0.lua")
  for _, case in ipairs(natural_corpus()) do
    local want = fx.cases[case.name]
    if not want then error("no recorded case " .. case.name) end
    if case.setup then case.setup() end
    local got = S.K.correction_build(case.notes, case.item_len)
    if case.teardown then case.teardown() end
    -- exact: ==, never near()
    eq(#got.points, #want.points, case.name .. " points")
    for i, p in ipairs(got.points) do
      eq(p.time, want.points[i][1], case.name .. " point time " .. i)
      eq(p.val, want.points[i][2], case.name .. " point val " .. i)
    end
    -- the same for spans (kind, t0, t1, a, b), ranges (t0, t1) and every note's frame_shifts
  end
end)

test("natural_same_text", function()
  -- reference: io.popen('git show 810bc35:"Pitch/Fancy_Pitch Correct.lua"'); when it yields nothing, print
  -- "SKIP natural_same_text (810bc35 not readable)" and return
  -- A block runs from the line starting with its prefix to the first later line that is the prefix's own
  -- indentation followed by "end" or "}". Blocks that must be equal, line for line:
  --   "K.tighten_line = function(", "K.note_body = function(", "K.points_offsets = function(",
  --   "local function is_note_modified(", "K.controls_edited = function(", "K.ZONE_CONTROLS = {",
  --   "local function param_drag(", "  local BAR_VALUES = {"
  -- The build: reference prefix "K.correction_build = function(notes, item_len)" against the working file's
  --   "K.natural_build = function(notes, item_len)" when that exists, else the same prefix; compared from the
  --   second line on.
  -- Single lines that must be present unchanged: the "K.JOIN = {" line, and in K.controls_load the lines starting
  --   "  if ctrl.tighten then" and "  if ctrl.tolerance then".
end)
```

- [ ] **Step 6: Run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 62 tests`; luacheck 0 warnings.

- [ ] **Step 7: The real vocal (this machine only)**

Read the path of the user's open project with the `reaper-mcp` project tools, read the project file from disk (do not save the project), and look for a take's `fancy_pitch_data`. If its JSON can be read (`_lib/json.lua`), save it to `$HOME/.fancy-scripts-fixtures/pitch_real_model.json`, extend the recorder to also write `$HOME/.fancy-scripts-fixtures/pitch_real_expected.lua` from it (notes built from the saved `notes` array, each `controls` passed through `K.controls_load`), re-run the recorder, and add `natural_same_numbers_real`, which prints `SKIP natural_same_numbers_real (no local fixture)` and returns when the files are absent. If the data cannot be read, do not add the test; say so in the task report.

- [ ] **Step 8: Commit**

```bash
git add docs/superpowers/tests/pitch_correct_spec.lua docs/superpowers/tests/fixtures/natural_v2_18_0.lua
git commit -m "test(pitch-correct): pin the Natural correction to v2.18.0 (numbers and text)"
```

---

### Task 2: The stored mode

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: `K.NOTE_CONTROLS` (~1443, one row), `K.controls_load` (~1505, one line), a new section `MODES` directly after the end of today's `K.correction_build` (~2662), the test export (last lines)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces:
  - Spec helpers `with_item_mode(mode, fn)` and `untouched_note(t0)`, used by later tasks' tests.
  - `K.NOTE_CONTROLS` row `{ key = "correct_mode", merge = "first", edited = "set" }`
  - `K.MODES`, `K.MODE` (see Global Constraints)
  - `K.mode_value(note | nil) -> 0 | 1 | 2`: the note's own `controls.correct_mode`, else the item's (`get_effective(note, "correct_mode")`, which reads `take_data.overrides` of `state.target_take_guid`); anything but 1 or 2 is 0. `nil` gives the item's.
  - `K.note_mode(note) -> "classic" | "hard" | nil`: `nil` when the note has no controls, is bypassed, is not `is_note_modified`, or `K.mode_value(note) == 0`.
  - `K.mode_unused(key, notes, n) -> "mode" | "hard" | "classic" | nil` for the `n` notes in `notes` (`n == 0` gives `nil`): keys `retune_speed`, `tolerance`, `slide_in` give `"mode"` when every note's `K.mode_value` is 1 or 2; key `tighten` gives `"hard"` when every one is 2, `"classic"` when every one is 1; otherwise `nil`.
  - Test export gains `SCALE_DEFINITIONS = SCALE_DEFINITIONS`.

- [ ] **Step 1: Write the failing tests**

```lua
local function with_item_mode(mode, fn)   -- runs fn with an open item whose mode is `mode` (nil = none)
  local st = S.state
  local saved_guid, saved_take = st.target_take_guid, st.session_takes["{M}"]
  st.target_take_guid = "{M}"
  st.session_takes["{M}"] = { overrides = { correct_mode = mode } }
  local ok, err = pcall(fn)
  st.target_take_guid, st.session_takes["{M}"] = saved_guid, saved_take
  if not ok then error(err, 0) end
end

-- A note nobody edited (join_note stores a Strength of its own, which counts as an edit: take it off)
local function untouched_note(t0)
  local n = join_note(t0, 0.3, 60, 0)
  n.controls.retune_speed = nil
  return n
end

test("mode_load_holds_range", function()
  for _, bad in ipairs({ 3, 1.5, -1, "x" }) do
    local ctrl = {}
    S.K.controls_load(ctrl, { correct_mode = bad })
    eq(ctrl.correct_mode, nil, "bad " .. tostring(bad))
  end
  for _, good in ipairs({ 0, 1, 2 }) do
    local ctrl = {}
    S.K.controls_load(ctrl, { correct_mode = good })
    eq(ctrl.correct_mode, good)
  end
end)

test("mode_first_attempt_data_is_natural", function()
  local ctrl = {}
  S.K.controls_load(ctrl, { tighten = 1.4, tune_mode = 2 })
  eq(ctrl.tighten, 1, "Tighten above 100% reads as 100%")
  eq(ctrl.tune_mode, nil); eq(ctrl.correct_mode, nil)
end)

test("mode_value_and_note_mode", function()
  local moved = join_note(0.1, 0.3, 60, 0.5)
  local untouched = untouched_note(0.5)
  eq(S.K.mode_value(moved), 0); eq(S.K.note_mode(moved), nil)
  with_item_mode(1, function()
    eq(S.K.mode_value(nil), 1, "the item's")
    eq(S.K.note_mode(moved), "classic", "edited note takes the item's mode")
    eq(S.K.note_mode(untouched), nil, "an untouched note is never corrected")
    moved.controls.correct_mode = 0
    eq(S.K.note_mode(moved), nil, "its own Natural wins")
    moved.controls.correct_mode = 2
    eq(S.K.note_mode(moved), "hard")
    moved.controls.bypassed = true
    eq(S.K.note_mode(moved), nil, "bypassed")
  end)
  with_item_mode(7, function() eq(S.K.mode_value(nil), 0, "a bad item mode is Natural") end)
  untouched.controls.correct_mode = 1
  eq(S.K.note_mode(untouched), "classic", "choosing a mode is an edit")
end)

test("mode_carry_merge_clear", function()
  local a, b = join_note(0.1, 0.3, 60, 0), join_note(0.4, 0.3, 62, 0)
  a.controls.correct_mode, b.controls.correct_mode = 2, 1
  eq(S.K.controls_carry(a.controls).correct_mode, 2)
  eq(S.K.controls_merge({ a, b }).correct_mode, 2, "the first note's")
  eq(S.K.controls_clear(a.controls), true); eq(a.controls.correct_mode, nil)
end)

test("mode_unused", function()
  local c, h, n = { controls = { correct_mode = 1 } }, { controls = { correct_mode = 2 } }, { controls = {} }
  eq(S.K.mode_unused("tolerance", { c, h }, 2), "mode")
  eq(S.K.mode_unused("retune_speed", { c, n }, 2), nil)
  eq(S.K.mode_unused("slide_in", {}, 0), nil)
  eq(S.K.mode_unused("tighten", { h, h }, 2), "hard")
  eq(S.K.mode_unused("tighten", { c }, 1), "classic")
  eq(S.K.mode_unused("tighten", { c, h }, 2), nil)
  eq(S.K.mode_unused("separation", { h }, 1), nil)
end)
```

- [ ] **Step 2: Run to see them fail**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: FAIL on the five new tests (`mode_value` is nil); `natural_same_numbers` and `natural_same_text` pass.

- [ ] **Step 3: Implement** the row, the one loader line (after the existing Tolerance line), the `MODES` section with `K.MODES`, `K.MODE`, `K.mode_value`, `K.note_mode`, `K.mode_unused`, and the export.

- [ ] **Step 4: Run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 67 tests` (68 with the real-vocal test); 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "feat(pitch-correct): a note and an item can store a mode (not used yet)"
```

---

### Task 3: The Classic and Hard arithmetic

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: the `MODES` section
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.MODE`, `K.mode_value`.
- Produces:
  - `K.scale_pcs(key_idx, scale_idx) -> { [0..11] = true } | nil`: `nil` when `SCALE_DEFINITIONS[scale_idx]` is missing. Root is `(key_idx - 1) % 12`.
  - `K.item_scale() -> key_idx, scale_idx`: of the take `state.target_take_guid` (its stored `key_idx` / `scale_idx`), else `state.key_idx`, `state.scale_idx`.
  - `K.item_scale_pcs() -> pcs | nil`: `K.scale_pcs(K.item_scale())`.
  - `K.nearest_scale_pitch(pitch, pcs) -> integer`: the whole semitone nearest `pitch` whose pitch class is in `pcs` (`nil` or an empty set: every semitone); searched 6 either side of `floor(pitch + 0.5)`; a tie goes to the lower.
  - `K.mode_line(note, mode, pcs) -> shifts, steps`: `mode` is `"classic"` or `"hard"`. `shifts[i]` is what is added to frame `i` in semitones (without pitch-point offsets); `steps[i]` is `true` where the pitch steps just before frame `i`. A note with no frames gives two empty tables. Cached on `note.mode_cache`, keyed by the frames table, Tighten, mode, placed centre, sung average and `pcs`.

- [ ] **Step 1: Write the failing tests**

```lua
-- A note from t0 lasting dur. sung: a number, or fn(local_time) -> number | nil. avg: its sung average.
local function mode_note(t0, dur, sung, avg, ctrl)
  local fr = {}
  local nf = math.floor(dur / JHOP + 0.5)
  for i = 1, nf do
    local lt = (i - 1) * JHOP
    local v = sung
    if type(sung) == "function" then v = sung(lt) end
    fr[i] = { time = t0 + lt, note = v }
  end
  local c = { center_pitch = avg, bypassed = false }
  for k, v in pairs(ctrl or {}) do c[k] = v end
  return { start_time = t0, end_time = t0 + nf * JHOP, frames = fr, avg_note = avg, controls = c }
end
local C_MAJOR = { [0] = true, [2] = true, [4] = true, [5] = true, [7] = true, [9] = true, [11] = true }

test("mode_nearest_scale_pitch", function()
  local f = S.K.nearest_scale_pitch
  eq(f(60.4, nil), 60); eq(f(60.6, nil), 61)
  eq(f(60.5, nil), 60, "a tie goes to the lower")
  eq(f(61.4, C_MAJOR), 62); eq(f(61.0, C_MAJOR), 60, "tie in the scale"); eq(f(59.2, C_MAJOR), 59)
  eq(f(61.4, {}), 61, "an empty scale is every semitone")
end)

test("mode_scale_pcs", function()
  local major
  for i, d in ipairs(S.SCALE_DEFINITIONS) do if d.name == "Major" then major = i end end
  local pcs = S.K.scale_pcs(1, major)
  for pc = 0, 11 do eq(pcs[pc] == true, C_MAJOR[pc] == true, "pc " .. pc) end
  eq(S.K.scale_pcs(3, major)[2], true, "the root moves with the key")
  eq(S.K.scale_pcs(1, 999), nil, "unknown scale")
end)

test("mode_line_hard", function()
  local n = mode_note(0.5, 0.3, 60.3, 60.3)
  local shifts, steps = S.K.mode_line(n, "hard", nil)
  eq(#shifts, #n.frames)
  for i = 1, #shifts do near(shifts[i], -0.3, 1e-9, "frame " .. i) end
  eq(next(steps), nil)
  n = mode_note(0.5, 0.3, 60.3, 60.3, { center_pitch = 62.4 })
  near(S.K.mode_line(n, "hard", nil)[1], 62 - 60.3, 1e-9, "follows where the note was moved")
  near(S.K.mode_line(n, "hard", C_MAJOR)[1], 62 - 60.3, 1e-9)
end)

test("mode_line_classic_step", function()
  local n = mode_note(0, 0.2, function(lt) return lt < 0.0975 and 60.2 or 61.2 end, 60.7, { tighten = 1 })
  local shifts, steps = S.K.mode_line(n, "classic", nil)
  near(shifts[20], -0.2, 1e-9); near(shifts[21], -0.2, 1e-9)
  eq(steps[21], true, "a step where the scale note changes")
  eq(steps[20], nil); eq(steps[22], nil)
end)

test("mode_line_classic_glide", function()
  local n = mode_note(0, 0.2, function(lt) return lt < 0.0975 and 60 or 61 end, 60.5)   -- Tighten 0: 100 ms
  local shifts, steps = S.K.mode_line(n, "classic", nil)
  local a = 1 - math.exp(-JHOP / 0.100)
  near(shifts[20], 0, 1e-9)
  near(shifts[21], (60 + a) - 61, 1e-9)
  near(shifts[22], (60 + 1 - (1 - a) ^ 2) - 61, 1e-9)
  eq(next(steps), nil, "a glide writes no step")
end)

test("mode_line_untrusted_frames", function()
  local n = mode_note(0.5, 0.1, 60.3, 60.3)
  n.frames[5].note = 72.3   -- a wrong-octave frame
  n.frames[6].note = nil    -- no pitch
  local shifts = S.K.mode_line(n, "hard", nil)
  near(shifts[5], shifts[4], 1e-12); near(shifts[6], shifts[4], 1e-12)
  local silent = mode_note(0.5, 0.1, nil, 60.3)
  shifts = S.K.mode_line(silent, "classic", nil)
  for i = 1, #shifts do near(shifts[i], 60 - 60.3, 1e-9, "no pitch at all: flat at the scale note") end
  local empty = { start_time = 1, end_time = 1.2, frames = {}, avg_note = 60, controls = { center_pitch = 60 } }
  eq(#(S.K.mode_line(empty, "hard", nil)), 0)
end)
```

- [ ] **Step 2: Run to see them fail**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: FAIL on the six new tests.

- [ ] **Step 3: Implement** the five functions. `K.mode_line` follows the spec's "The arithmetic, per note" block exactly (Tighten read as `controls.tighten or 0`, held to 0..1).

- [ ] **Step 4: Run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 73 tests` (74 with the real-vocal test); 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "feat(pitch-correct): Classic and Hard arithmetic (not wired in yet)"
```

---

### Task 4: The build that chooses

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: the definition line of today's `K.correction_build` (~2423) becomes `K.natural_build = function(notes, item_len)`; the new `K.correction_build` in the `MODES` section; `K.correction_view` (~4320, added signature entries only)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.note_mode`, `K.mode_line`, `K.item_scale`, `K.item_scale_pcs`, `K.points_offsets`, `K.JOIN.FADE_S`, `K.MODE.STEP_S`.
- Produces: `K.natural_build(notes, item_len)` (today's function); `K.correction_build(notes, item_len) -> { points, spans, ranges }` with the same shapes as today. It looks up `K.natural_build` and `K.item_scale_pcs` on `K` at call time (the tests replace them).

Behaviour of the new `K.correction_build`:

1. When `K.note_mode` is `nil` for every note: `return K.natural_build(notes, item_len)`, with nothing else done.
2. Otherwise build a stand-in list of the same length and order: a Natural note is itself; a Classic or Hard note is a separate object that reads everything from the real note except `controls`, which is a separate object reading from the real controls except `bypassed = true`. Writes made by `K.natural_build` to a stand-in must not reach the real note.
3. `A = K.natural_build(stand-ins, item_len)`.
4. For each Classic or Hard note with at least one frame: `frame_shifts[i] = mode_line shift + pitch-point offset` on the **real** note, then write its points:
   - `t_first`, `t_last` = its first and last frame time; `STEP = K.MODE.STEP_S`.
   - Unless the previous note is also Classic or Hard and closer than `2 * K.JOIN.FADE_S`: a point at `t_first - STEP` with value 0. When it is: that point holds the previous note's last frame shift.
   - One point per frame; before a frame `i > 1` with `steps[i]`, a point at `time - STEP` holding frame `i - 1`'s shift.
   - Unless the next note is also Classic or Hard and closer than `2 * K.JOIN.FADE_S`: with `t_close = max(end_time, t_last + STEP)`, a point at `t_close - STEP` holding the last shift (only when that is after `t_last`), then a point at `t_close` with value 0. Its range is `t_first - STEP .. t_close`; when the next note continues it, the range ends at that note's first frame time.
   - Every point time is held to `0 .. item_len`.
5. Result: `points` = A's points whose time is outside every mode note's range (ranges closed at both ends) followed by the mode points; `spans` = A's; `ranges` = A's and the mode ranges, sorted by `t0` and merged where they touch.

- [ ] **Step 1: Write the failing tests**

```lua
local function hard_note(t0, sung, ctrl)
  local c = { correct_mode = 2 }
  for k, v in pairs(ctrl or {}) do c[k] = v end
  return mode_note(t0, 0.3, sung, sung, c)
end
local function chromatic(fn)   -- runs fn with every item on the chromatic scale
  local saved = S.K.item_scale_pcs
  S.K.item_scale_pcs = function() return nil end
  local ok, err = pcall(fn)
  S.K.item_scale_pcs = saved
  if not ok then error(err, 0) end
end
local STEP = 0.0005

test("build_natural_only_is_handed_through", function()
  local saved, seen = S.K.natural_build, nil
  local sentinel = { points = {}, spans = {}, ranges = {} }
  S.K.natural_build = function(notes, item_len) seen = { notes, item_len } return sentinel end
  local notes = { join_note(0.1, 0.3, 60, 0.3) }
  local got = S.K.correction_build(notes, 10)
  S.K.natural_build = saved
  eq(got, sentinel, "Natural's own result"); eq(seen[1], notes, "the same list"); eq(seen[2], 10)
end)

test("build_hard_note", function() chromatic(function()
  local h = hard_note(0.5, 60.3)
  local build = S.K.correction_build({ h }, 10)
  eq(#h.frame_shifts, #h.frames)
  for i = 1, #h.frames do near(h.frame_shifts[i], -0.3, 1e-9) end
  local t1 = h.frames[1].time
  near(point_at(build.points, t1 - STEP).val, 0, 1e-12, "steps in from no correction")
  near(point_at(build.points, t1).val, -0.3, 1e-9)
  near(point_at(build.points, h.end_time - STEP).val, -0.3, 1e-9, "held to the end")
  near(point_at(build.points, h.end_time).val, 0, 1e-12, "steps out")
  eq(#build.ranges, 1); near(build.ranges[1].t0, t1 - STEP, 1e-12); near(build.ranges[1].t1, h.end_time, 1e-12)
  eq(#build.spans, 0)
  eq(h.controls.bypassed, false, "the real note is not changed")
end) end)

test("build_classic_step_point", function() chromatic(function()
  local n = mode_note(0.5, 0.2, function(lt) return lt < 0.0975 and 60.2 or 61.2 end, 60.7,
    { correct_mode = 1, tighten = 1 })
  local build = S.K.correction_build({ n }, 10)
  local t = n.frames[21].time
  near(point_at(build.points, t - STEP).val, n.frame_shifts[20], 1e-12, "holds the old value before the step")
  near(point_at(build.points, t).val, n.frame_shifts[21], 1e-12)
end) end)

test("build_natural_neighbour_keeps_its_side", function() chromatic(function()
  local a = join_note(0.1, 0.3, 60, 0.3)
  local h = hard_note(a.end_time, 62.3)
  local build = S.K.correction_build({ a, h }, 10)
  -- What Natural writes next to a note that is not corrected, built by Natural alone
  local a2, b = join_note(0.1, 0.3, 60, 0.3), hard_note(a.end_time, 62.3)
  b.controls.correct_mode, b.controls.bypassed = nil, true
  local ref = S.K.natural_build({ a2, b }, 10)
  local edge = h.frames[1].time - STEP
  local n_ref = 0
  for _, p in ipairs(ref.points) do
    if p.time < edge then
      n_ref = n_ref + 1
      local q = build.points[n_ref]
      eq(q.time, p.time, "same time " .. n_ref); eq(q.val, p.val, "same value " .. n_ref)
    end
  end
  if n_ref < 3 then error("the reference has no blend to compare") end
  local g = spans_of(build, "glide")
  eq(#g, 1); if g[1].t1 > a.end_time + 1e-9 then error("the blend crosses into the Hard note") end
  eq(a.frame_shifts[1], a2.frame_shifts[1], "Natural's own shifts")
end) end)

test("build_adjacent_mode_notes_hold", function() chromatic(function()
  local h1 = hard_note(0.5, 60.3)
  local h2 = hard_note(h1.end_time, 62.4)
  local build = S.K.correction_build({ h1, h2 }, 10)
  local t2 = h2.frames[1].time
  near(point_at(build.points, t2 - STEP).val, -0.3, 1e-9, "held across")
  near(point_at(build.points, t2).val, 62 - 62.4, 1e-9, "one step")
  for _, p in ipairs(build.points) do
    if p.time > h1.frames[1].time and p.time < h2.end_time - STEP and math.abs(p.val) < 1e-9 then
      error("returns to no correction between the notes at " .. p.time)
    end
  end
  eq(#build.ranges, 1, "one merged range")
end) end)

test("build_mode_note_at_item_edges", function() chromatic(function()
  local h = mode_note(0, 0.2, 60.3, 60.3, { correct_mode = 2 })
  local build = S.K.correction_build({ h }, 0.2)
  for _, p in ipairs(build.points) do
    if p.time < 0 or p.time > 0.2 then error("point outside the item at " .. p.time) end
  end
  local empty = { start_time = 1, end_time = 1.2, frames = {}, avg_note = 60,
                  controls = { center_pitch = 60, correct_mode = 2, bypassed = false } }
  build = S.K.correction_build({ empty }, 10)
  eq(#build.points, 0, "a note without frames writes nothing")
end) end)

test("build_item_mode_reaches_edited_notes_only", function() chromatic(function()
  with_item_mode(2, function()
    local moved, untouched = mode_note(0.1, 0.3, 60.3, 60.3, { center_pitch = 61.3 }), mode_note(1, 0.3, 60.3, 60.3)
    local build = S.K.correction_build({ moved, untouched }, 10)
    near(moved.frame_shifts[1], 61 - 60.3, 1e-9, "Hard, around where it was moved")
    for _, p in ipairs(build.points) do
      if p.time >= untouched.start_time - 0.05 and math.abs(p.val) > 1e-9 then error("the untouched note is corrected") end
    end
  end)
end) end)
```

- [ ] **Step 2: Run to see them fail**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: FAIL on the seven new tests.

- [ ] **Step 3: Implement** the rename (that one line only) and the new `K.correction_build`.

- [ ] **Step 4: Add to `K.correction_view`'s signature** (new `set(...)` lines, `k` advanced to match): per note `K.mode_value(n)`; once after the loop, the two values of `K.item_scale()`.

- [ ] **Step 5: Run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 80 tests` (81 with the real-vocal test), `natural_same_numbers` and `natural_same_text` among them; 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "feat(pitch-correct): the build hands Natural through and writes Classic and Hard beside it"
```

---

### Task 5: Key and Scale changes rewrite Classic and Hard notes

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: a new `K.scale_changed` defined after `apply_envelope_to_take` (~2750); the Key list handler (~9627) and the Scale combo handler (~9647)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.note_mode`, `apply_envelope_to_take(undo_desc) -> boolean`, `update_scale_pitch_classes()`, `save_current_scale_settings()`, `set_status(msg)`.
- Produces:
  - `K.mode_note_count(notes) -> integer`: how many notes have a non-nil `K.note_mode`.
  - `K.scale_changed()`: called after `state.key_idx` or `state.scale_idx` was set. Always `update_scale_pitch_classes()`. When `K.mode_note_count(state.notes or {}) == 0` or the open item has no take data: `save_current_scale_settings()` and nothing else (today's behaviour). Otherwise: write the two ExtState values `save_current_scale_settings` writes, set the take data's `key_idx` and `scale_idx`, call `apply_envelope_to_take("Change Key/Scale")`, and on `true` post the status `Key changed: %d Classic / Hard notes follow %s %s` (`1 Classic / Hard note follows` for one), with the key and scale names as the combos show them.

- [ ] **Step 1: Write the failing test**

```lua
test("mode_note_count", function()
  local a, b, c = join_note(0.1, 0.3, 60, 0.3), join_note(0.5, 0.3, 60, 0.3), untouched_note(0.9)
  a.controls.correct_mode = 1
  eq(S.K.mode_note_count({ a, b, c }), 1)
  with_item_mode(2, function() eq(S.K.mode_note_count({ a, b, c }), 2, "the item's mode reaches the edited note") end)
  eq(S.K.mode_note_count({}), 0)
end)
```

- [ ] **Step 2: Run to see it fail**, then **implement** both functions and replace, in each of the two handlers, the pair `update_scale_pitch_classes()` / `save_current_scale_settings()` with `K.scale_changed()`.

- [ ] **Step 3: Run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 81 tests` (82 with the real-vocal test); 0 warnings.

- [ ] **Step 4: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "feat(pitch-correct): a Key or Scale change rewrites Classic and Hard notes in its undo point"
```

---

### Task 6: The Mode dropdown in the top bar

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: `HDR_VALUES` and the narrowest `HDR_PLANS` row (~9403, ~9421); the bar's strings (~9862); `K.bar_measure` (the unit widths); `K.bar_frame` (~10170: `draw_value`, a new `draw_mode`, the returned `draw_unit`)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.MODES`, `K.mode_value`, `K.mode_unused`, `Theme.combo(ctx, id, items, selected_idx, { w, placeholder, disabled, tooltip }) -> new_idx, changed`, the bar's `sel_notes`, `sel_n`, `take_data`, `inspector_reason`, `bar_tooltip`, `apply_envelope_to_take`, `set_status`.
- Produces:
  - Unit id `"mode"`: `HDR_VALUES = { "pill", "tight", "mode", "strength", "tol", "slide", "sep" }`; narrowest plan rows `{ "pill", "tight" }, { "mode", "strength" }, { "tol", "slide" }, { "sep" }`.
  - `K.mode_reach_count(notes) -> integer`: notes that are edited, not bypassed and have no `controls.correct_mode` of their own (what the item's mode reaches).
  - `K.mode_item_status(mode, count) -> string`: `Mode: Classic for this item (12 edited notes)` (`1 edited note` for one); with `count == 0`: `Mode: Classic for this item. Notes you edit will use it`.

`draw_mode()`:

- Shown index: nothing selected → `K.mode_value(nil) + 1`; notes selected → their common `K.mode_value + 1`, or 0 (placeholder `Mixed`) when they differ.
- `Theme.combo(bctx, "##bar_mode", K.MODES, idx, { w = s.unit_w.mode, placeholder = "Mixed", disabled = inspector_reason ~= nil, tooltip = ... })`. `s.unit_w.mode` = the widest of the three names and `Mixed`, plus the frame padding and the arrow (a square of the frame height). Tooltip: the four Mode lines of the Copy deck, a line break, then the scope line (or `inspector_reason` when disabled).
- A choice equal to the shown index does nothing. Notes selected: `controls.correct_mode = choice - 1` on every selected note, then `apply_envelope_to_take("Change Mode")`. Nothing selected: `take_data.overrides = take_data.overrides or {}`, `take_data.overrides.correct_mode` = 1, 2, or `nil` for Natural, then `apply_envelope_to_take("Change Mode")` and, on `true`, `set_status(K.mode_item_status(choice - 1, K.mode_reach_count(state.notes)))`.

`draw_value(spec)`, added only: `local unused = K.mode_unused(spec.key, sel_notes, sel_n)`. When it is `"mode"` or `"hard"`, the control's text colour is pushed to the palette's `text_dim` around `param_drag` and popped after. In the tooltip, one line goes before the scope line, the way `BAR_TOLERANCE_IDLE` does today: `"mode"` → `Not used in Classic or Hard mode.`; `"hard"` → `Not used in Hard mode.`; `"classic"` → `In Classic mode: how fast the pitch jumps between scale notes. 0% glides, 100% steps at once.` The `BAR_VALUES` tips are not edited.

- [ ] **Step 1: Write the failing tests**

```lua
test("mode_reach_and_status", function()
  local own, moved, untouched = join_note(0.1, 0.3, 60, 0.3), join_note(0.5, 0.3, 60, 0.3), untouched_note(0.9)
  own.controls.correct_mode = 0
  eq(S.K.mode_reach_count({ own, moved, untouched }), 1)
  eq(S.K.mode_item_status(1, 12), "Mode: Classic for this item (12 edited notes)")
  eq(S.K.mode_item_status(2, 1), "Mode: Hard for this item (1 edited note)")
  eq(S.K.mode_item_status(0, 0), "Mode: Natural for this item. Notes you edit will use it")
end)
```

- [ ] **Step 2: Run to see it fail, implement, run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 82 tests` (83 with the real-vocal test); 0 warnings.

- [ ] **Step 3: Look at it in real REAPER** (testing protocol; sweep strays before and after): restart the script; a capture shows the dropdown reading `Natural` right after Tighten with nothing selected, and no error window. Select a note, choose Hard: the Preview Curve of that note is a flat line, the dropdown reads `Hard`, Strength, Tolerance, Slide In and Tighten are dim. Undo once (check the undo label is `Change Mode`): the note is as before. Say what was seen and what could not be checked.

- [ ] **Step 4: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "feat(pitch-correct): Mode dropdown next to Tighten (the item's mode, or the selected notes')"
```

---

### Task 7: The note menu, the readouts, the highlight and Help

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: the note menu's value rows (~7015–7103); `K.zone_text` and its constants (~4525–4545); `K.draw_setting_hint` (~4700) and the status beside its call (~6498); `K.INFO_SECTIONS` (~7745)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.MODES`, `K.mode_value`, `K.mode_unused`, `Theme.combo`, the menu's `note`, `ctrl`, `note_idx`, `spread_n`.
- Produces:
  - `K.MODE_IDLE = " (not used in Classic or Hard mode)"`, `K.HARD_IDLE = " (not used in Hard mode)"`.
  - `K.zone_text(zc, note, hover)`: after today's text, for a note whose `K.mode_value` is 1 or 2: keys `tolerance` and `slide_in` add `K.MODE_IDLE` (instead of `K.TOLERANCE_IDLE`); key `tighten` adds `K.HARD_IDLE` when the value is 2. A Natural note gets exactly today's text.
  - `K.draw_setting_hint(...) -> drawn, skipped`: `skipped` counts notes the value reaches that were not marked because `K.mode_value` is 1 or 2 (Strength outline, Tolerance band, and for Slide In the reached notes in view). Such notes get no mark.

Note menu: a Mode row directly above the Tighten row. `Theme.combo(draw_ctx, "##cm_mode", K.MODES, K.mode_value(note) + 1, { w = reaper.ImGui_CalcItemWidth(draw_ctx) })`, then on the same line the text `Mode`, the dim tag `[note]` when `ctrl.correct_mode ~= nil` else `[item]`, and `(N notes)` when `spread_n > 1`, drawn as the value rows draw theirs. A changed choice writes `correct_mode = choice - 1` to the menu's note, and to every selected note when `spread_n > 1`, then `apply_envelope_to_take("Change Mode")`.

`draw_cm_slider`, added only: when `K.mode_unused(key, { note }, 1)` is `"mode"` or `"hard"`, the text colour is pushed to `text_dim` around `param_drag` and popped after.

Status beside the highlight: when `marks == 0` and `skipped > 0`, the status is `Not used in Classic or Hard mode` (for a Tighten highlight on Hard notes: `Not used in Hard mode`); every other case keeps today's three texts.

Help: a row after "Drag Right Zone": `{ "Mode (top bar, note menu)", "Natural, Classic (the pitch jumps between scale notes; Tighten sets how fast) or Hard (one flat scale note)" }`.

- [ ] **Step 1: Write the failing test**

```lua
test("zone_text_mode_suffix", function()
  local zc = S.K.ZONE_CONTROLS
  local tol, tight, slide = zc.tolerance[false], zc.tighten[false], zc.tolerance[true]
  local n = join_note(0.1, 0.3, 60, 0.3)
  n.controls.tighten, n.controls.tolerance = 0.5, 8
  local natural_tol, natural_tight = S.K.zone_text(tol, n, false), S.K.zone_text(tight, n, false)
  n.controls.correct_mode = 1
  eq(S.K.zone_text(tol, n, false), natural_tol .. " (not used in Classic or Hard mode)")
  eq(S.K.zone_text(slide, n, false):sub(-#S.K.MODE_IDLE), " (not used in Classic or Hard mode)")
  eq(S.K.zone_text(tight, n, false), natural_tight, "Tighten acts in Classic")
  n.controls.correct_mode = 2
  eq(S.K.zone_text(tight, n, false), natural_tight .. " (not used in Hard mode)")
  n.controls.correct_mode, n.controls.tighten = 1, nil
  eq(S.K.zone_text(tol, n, false):find("used once Tighten", 1, true), nil, "the Natural advice is not given")
end)
```

- [ ] **Step 2: Run to see it fail, implement, run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 83 tests` (84 with the real-vocal test); 0 warnings.

- [ ] **Step 3: Look at it in real REAPER** (testing protocol): right-click a note, choose Classic in the Mode row: the Preview Curve shows stairs, the row reads `Classic [note]`, Tolerance, Slide In and Strength rows are dim. Open Help: the Mode row is there. Undo. Say what was seen.

- [ ] **Step 4: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "feat(pitch-correct): Mode in the note menu; values a mode does not use say so"
```

---

### Task 8: Release notes, the untouched-code gate and the real-REAPER checks

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (header: `@version 2.19.0`, `@changelog`), `CHANGELOG.md` (under `## [Unreleased]`)

- [ ] **Step 1: Header and changelog.** `@version 2.19.0`. Changelog lines, in the copy deck's words: the Mode with its three choices; where it is set (top bar: this item with nothing selected, the selected notes otherwise; the note menu); Classic and Hard follow where a note was moved and the item's Key and Scale, and a Key or Scale change rewrites them as one undo step; values a mode does not use are dimmed and say so; Natural is unchanged.

- [ ] **Step 2: The untouched-code gate**

Run: `git diff 810bc35 -- "Pitch/Fancy_Pitch Correct.lua" | grep '^-[^-]'` and `git diff --stat 810bc35 -- _lib/theme.lua`
Expected: the second prints nothing. The first lists only: the `@version` and `@changelog` header lines; the definition line `K.correction_build = function(notes, item_len)`; the two `update_scale_pitch_classes()` / `save_current_scale_settings()` pairs in the Key and Scale handlers; `HDR_VALUES` and the narrowest `HDR_PLANS` row; lines of `K.zone_text`, `draw_value`, `draw_cm_slider`, the highlight status and `K.draw_setting_hint` that were rewrapped to take a branch; the test export line. Any other removed line is a defect: restore it.

- [ ] **Step 3: Full test run**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && lua docs/superpowers/tests/theme_spec.lua; luacheck .`
Expected: `ok 83 tests` (84 with the real-vocal test, and it must run and pass on this machine if Task 1 added it); the theme spec shows the same two failures it has on `main` ("canvas: curated values", "literal glyph U+25b8") and no others; luacheck 0 warnings.

- [ ] **Step 4: Natural in real REAPER** (read the memory note on real-REAPER testing limits and the testing protocol first). Restart the script on the user's project, whose envelopes were written by v2.18.0, and before editing anything:
  - no analysed item reads "Outdated". The script's own check compares each item's stored envelope with what this build would write, so this is the real-REAPER proof that Natural writes what v2.18.0 wrote;
  - a capture of the top bar and of the note menu on a Natural note shows no difference from v2.18.0 other than the dropdown and the Mode row;
  - drag Tighten, Tolerance and Slide In on a Natural note: the readouts and ranges are today's; undo each (check each undo label before the next undo).
  If an item does read "Outdated", stop: that is a Natural difference to find, not to edit away.

- [ ] **Step 5: Classic and Hard in real REAPER:** Hard and Classic on a note and on a selection; the item's mode with nothing selected (status message shows the count); a Key change with a Classic note (one undo point named `Change Key/Scale`, status message, undo restores envelope and key); a Classic note touching a Natural edited note; undo and redo of each; Fancy Dark and Match Theme; docked narrow and floating; Analyze the item again and see its mode read `Natural`; with a second analysed item in the project, change a mode in the first and see the second is not marked "Outdated". Sweep stray windows before and after each action. Report what was seen and what could not be checked.

- [ ] **Step 6: Commit, then hand to the user to listen** (Natural first, then Classic and Hard). The glide constants change only on the user's word.

```bash
git add "Pitch/Fancy_Pitch Correct.lua" CHANGELOG.md
git commit -m "feat(pitch-correct): Mode: Natural, Classic and Hard (v2.19.0)"
```
