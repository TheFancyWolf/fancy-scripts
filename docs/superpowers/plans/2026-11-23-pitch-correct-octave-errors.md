# Pitch Correct Octave Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fancy Pitch Correct's analysis no longer shows drops or spikes where the detector read a frame one octave off, and a note's centre is no longer pulled away from the pitch line by such frames.

**Architecture:** Two small changes in `Pitch/Fancy_Pitch Correct.lua`. A new pure function `K.octave_fix(results)` runs once at the end of an analysis, before the notes are split: it puts short octave-off stretches back in the octave of the frames around them. `extract_note_features` then leaves any frame more than 6 semitones from the note's middle pitch out of the centre; on a note with no such frame its arithmetic is bit-for-bit what it is today.

**Tech Stack:** Lua 5.4, ReaScript API. Tests: plain Lua, `lua docs/superpowers/tests/pitch_correct_spec.lua` from the repo root.

**Spec:** none; the Findings section below is the spec (investigation of 2026-11-23, approved by the user: "Skip, plan the fix").

## Findings (what the fix answers)

Read from the analysis stored on the two takes (REAPER auto-save of 2026-11-23 10:39; hop 512 at 48 kHz, 10.67 ms per frame):

| Item | Sung pitch | Wrong frames | Stored centre | Median of the same frames |
|---|---|---|---|---|
| V Main Verse 1, note 3 (0.853–1.131 s) | 58.8 (B3 −20¢) | 2 of 27 at 47.2 (one octave down), both sides flanked by right frames | 57.59 | 58.80 |
| Chorus Error, held note (0.299–3.211 s) | 66.3 (F#4 +31¢) | 40 of 274 at 78.4 (one octave up), in 14 runs of 1 to 8 frames | 68.05 | 66.31 |

- Every wrong run starts and ends with a frame-to-frame jump of 11.76 to 12.18 semitones, and the longest lasts 85 ms.
- `yin_process_block` judges each frame alone; nothing compares a frame with its neighbours.
- `extract_note_features` step 4 takes an energy-weighted mean of the raw frames, so a few octave-wrong frames move the centre by more than a semitone. Quantize then picks the wrong scale note (A3 instead of B3 in the verse).
- Not investigated (the user chose to skip it): why the detector picks the wrong octave in those frames. This plan does not touch `yin_process_block`.

## Global Constraints

- Branch `fix/pitch-correct-octave-errors`, cut from `main`. Never push; commit per task.
- No backward compatibility (the user, 2026-11-23): stored analyses are not migrated. An item analysed before this fix keeps its octave-wrong frames until it is analysed again, and its notes that hold such frames may load as edited.
- No new chunk-level `local` in `Pitch/Fancy_Pitch Correct.lua` (the chunk is near Lua's 200-local limit): new functions and constants go on `K`.
- Constants, exact: `K.OCTAVE = { JUMP_TOL_ST = 1.0, MAX_RUN_S = 0.15, WINDOW_S = 0.25 }` and `K.CENTRE_OUTLIER_ST = 6`.
- Do not edit `yin_process_block`, `K.segment`, or any function `natural_same_text` pins (`K.tighten_line`, `K.note_body`, `K.points_offsets`, `is_note_modified`, `K.controls_edited`, `K.ZONE_CONTROLS`, `param_drag`, the build).
- The user's vocal analysis is never committed: real frames stay in `~/.fancy-scripts-fixtures/` (tests that read them print `SKIP` where they are absent). Committed tests use made-up frames.
- House rules (AGENTS.md): call `reaper.X()` directly; every variable `local`; never edit `index.xml`, `.github/workflows/` or `_fancy_*.json`; `luacheck .` clean before every commit.
- No fake or mock of REAPER beyond the stub the spec file already has. Real-REAPER steps follow `.agents/skills/reaper-screenshot/references/testing-protocol.md`; a failed permission prompt means stop and tell the user.

## Review Focus

Inputs the findings imply but do not show, most likely first. Each has a test in the task named.

1. A real octave leap that is held (0.17 s or longer, or to the end of the phrase) stays as sung. Task 1, `octave_fix_keeps_real_leaps`.
2. An octave-wrong stretch at the very start or end of a phrase (wrong frames with right frames on one side only) is fixed. Task 1, `octave_fix_at_phrase_start_and_end`.
3. Any frame spacing (hop 256 or 512, 44.1 or 48 kHz) gives the same result: every time constant is converted with the frames' own spacing. Task 1, `octave_fix_any_hop_and_idempotent`.
4. Empty or broken input (no frames, one frame, no pitch at all, frames with equal times) returns 0 and raises nothing. Task 1, `octave_fix_degenerate`.
5. A note whose core is half octave-wrong still gets a centre that is a real, finite pitch of one of its frames' octaves. Task 2, `centre_split_core_stays_finite`.

---

### Task 1: `K.octave_fix` puts short octave-off stretches back

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (new code directly after `K.frame_step`, about line 3720; one line in `run_hybrid_segmentation`, about line 4098)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua` (above the line `-- Tests appended by later tasks go above this line.`)

**Interfaces:**
- Consumes: `K.frame_step(results)` (median frame spacing in seconds).
- Produces: `K.OCTAVE` (constants above) and `K.octave_fix(results) -> integer`: changes `note` and `freq` of octave-off frames in place and returns how many frames it changed. `results` is the analysis frame list `{ time, note | nil, freq | nil, rms, lvl }`, in time order.

- [ ] **Step 1: Create the branch and check the baseline**

Run: `git checkout -b fix/pitch-correct-octave-errors main && lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 93 tests` and `0 warnings / 0 errors`.

- [ ] **Step 2: Write the failing tests**

```lua
-- Octave errors (K.octave_fix) ------------------------------------------------------------------

local OHOP = 512 / 48000
-- list: runs of { frame count, pitch | nil }; returns result frames (freq follows the pitch)
local function oct_frames(list, hop)
  local out = {}
  for _, r in ipairs(list) do
    for _ = 1, r[1] do
      local note = r[2]
      out[#out + 1] = { time = #out * (hop or OHOP), note = note, rms = 0.1, lvl = 0.1,
        freq = note and 440 * 2 ^ ((note - 69) / 12) or nil }
    end
  end
  return out
end
local function all_near(fr, want, tol, msg)
  for i, f in ipairs(fr) do if f.note then near(f.note, want, tol, msg .. " frame " .. i) end end
end

test("octave_fix_drop_in_note", function()   -- the verse: 2 of 27 frames one octave down
  local fr = oct_frames({ { 5, 58.8 }, { 2, 47.0 }, { 20, 58.8 } })
  eq(S.K.octave_fix(fr), 2, "frames changed")
  all_near(fr, 58.8, 0.21, "pitch")
  near(fr[6].note, 59.0, 1e-9, "moved by exactly 12")
  near(fr[6].freq, 440 * 2 ^ ((59.0 - 69) / 12), 1e-6, "freq follows")
end)

test("octave_fix_spikes_in_held_note", function()   -- the chorus: many short runs one octave up
  local fr = oct_frames({ { 7, 66.3 }, { 4, 78.3 }, { 9, 66.3 }, { 8, 78.4 }, { 19, 66.3 }, { 5, 78.4 }, { 26, 66.3 },
    { 4, 78.4 }, { 2, 66.3 }, { 1, 78.4 }, { 5, 66.3 }, { 2, 78.4 }, { 30, 66.3 } })
  eq(S.K.octave_fix(fr), 24, "frames changed")
  all_near(fr, 66.3, 0.11, "pitch")
end)

test("octave_fix_spike_on_a_slide", function()
  local fr = oct_frames({ { 30, 60 } })
  for i, f in ipairs(fr) do f.note = 64.5 + 1.8 * (i - 1) / 29 end
  for i = 12, 15 do fr[i].note = fr[i].note + 12 end
  eq(S.K.octave_fix(fr), 4, "frames changed")
  for i, f in ipairs(fr) do near(f.note, 64.5 + 1.8 * (i - 1) / 29, 1e-9, "on the slide, frame " .. i) end
end)

test("octave_fix_at_phrase_start_and_end", function()
  local fr = oct_frames({ { 3, nil }, { 2, 48 }, { 30, 60 }, { 3, 72 }, { 3, nil } })
  eq(S.K.octave_fix(fr), 5, "frames changed")
  all_near(fr, 60, 1e-9, "pitch")
end)

test("octave_fix_two_octaves", function()
  local fr = oct_frames({ { 20, 60 }, { 3, 84 }, { 20, 60 } })
  eq(S.K.octave_fix(fr), 3, "frames changed")
  all_near(fr, 60, 1e-9, "pitch")
end)

test("octave_fix_keeps_real_leaps", function()
  local held = oct_frames({ { 40, 60 }, { 40, 72 } })
  eq(S.K.octave_fix(held), 0, "a held octave leap")
  local visit = oct_frames({ { 40, 60 }, { 16, 72 }, { 40, 60 } })   -- 16 frames = 171 ms, longer than MAX_RUN_S
  eq(S.K.octave_fix(visit), 0, "an octave held for 171 ms")
  eq(visit[45].note, 72, "untouched")
  local fifth = oct_frames({ { 20, 60 }, { 3, 67 }, { 20, 60 } })
  eq(S.K.octave_fix(fifth), 0, "a jump that is not an octave")
  local gap = oct_frames({ { 20, 60 }, { 2, nil }, { 3, 72 }, { 2, nil }, { 20, 60 } })
  eq(S.K.octave_fix(gap), 0, "a stretch between two unvoiced gaps is judged alone")
  local tie = oct_frames({ { 5, 60 }, { 5, 72 } })
  eq(S.K.octave_fix(tie), 0, "equal halves: no way to tell, nothing changes")
end)

test("octave_fix_any_hop_and_idempotent", function()
  for _, hop in ipairs({ 256 / 48000, 512 / 48000, 256 / 44100 }) do
    local wrong = math.floor(0.06 / hop)   -- 60 ms one octave up inside a 0.5 s note
    local side = math.floor(0.22 / hop)
    local fr = oct_frames({ { side, 60 }, { wrong, 72 }, { side, 60 } }, hop)
    eq(S.K.octave_fix(fr), wrong, "frames changed at hop " .. hop)
    all_near(fr, 60, 1e-9, "pitch at hop " .. hop)
    eq(S.K.octave_fix(fr), 0, "a second run changes nothing at hop " .. hop)
  end
end)

test("octave_fix_degenerate", function()
  eq(S.K.octave_fix({}), 0, "no frames")
  eq(S.K.octave_fix(oct_frames({ { 1, 60 } })), 0, "one frame")
  eq(S.K.octave_fix(oct_frames({ { 20, nil } })), 0, "no pitch at all")
  local same = oct_frames({ { 10, 60 }, { 2, 72 }, { 10, 60 } })
  for _, f in ipairs(same) do f.time = 0 end
  eq(S.K.octave_fix(same), 0, "equal times")
end)

test("octave_fix_real_items", function()   -- this machine only: the two takes of the 2026-11-23 report
  local json = loadfile("_lib/json.lua")()
  local function model(name)
    local f = io.open(FIXTURE_DIR .. name, "rb")
    if not f then return nil end
    local data = json.decode(f:read("a"))
    f:close()
    return data
  end
  local verse, chorus = model("octave_verse_model.json"), model("octave_chorus_model.json")
  if not verse or not chorus then print("SKIP octave_fix_real_items (no local fixture)") return end
  S.K.octave_fix(verse.results)
  for _, f in ipairs(verse.results) do
    if f.time > 0.90 and f.time < 0.92 then near(f.note, 59.0, 0.5, "verse frame at " .. f.time) end
  end
  eq(S.K.octave_fix(chorus.results), 40, "chorus frames changed")
  for _, f in ipairs(chorus.results) do
    if f.time > 0.30 and f.time < 3.19 then near(f.note, 66.3, 1.5, "chorus frame at " .. f.time) end
  end
end)
```

`FIXTURE_DIR` is already defined in the spec file (above `real_model`); put these tests after it.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: nine `FAIL octave_fix_…` lines, each with "attempt to call a nil value (field 'octave_fix')".

- [ ] **Step 4: Implement `K.OCTAVE` and `K.octave_fix(results) -> integer` directly after `K.frame_step`**

The algorithm (the tests do not determine it, so it is given whole):

```lua
--- Octave errors of the pitch detection (K.octave_fix): JUMP_TOL_ST = how far from a whole number of octaves a
--- frame-to-frame jump may be and still count as an octave jump; MAX_RUN_S = the longest stretch that is put back (a
--- longer one may be a sung leap); WINDOW_S = how far each way a stretch looks for the octave most frames are in.
K.OCTAVE = { JUMP_TOL_ST = 1.0, MAX_RUN_S = 0.15, WINDOW_S = 0.25 }

--- Puts short octave-off stretches of analysed frames back (`results`: time-ordered { time, note | nil, freq | nil }).
--- Within each stretch of frames that all have a pitch, a frame-to-frame jump of a whole number of octaves (within
--- JUMP_TOL_ST) starts a new octave class. A run of one class no longer than MAX_RUN_S moves to the class that
--- strictly most frames within WINDOW_S of it are in; with no such class it stays. Changes note and freq in place and
--- returns how many frames changed. A second call changes nothing.
K.octave_fix = function(results)
  local O, n = K.OCTAVE, #results
  if n < 2 then return 0 end
  local hop = K.frame_step(results)
  if not (hop > 0) then return 0 end   -- luacheck: ignore 581 (also catches NaN)
  local changed, i = 0, 1
  while i <= n do
    if not results[i].note then
      i = i + 1
    else
      local j = i   -- the stretch i..j
      while j + 1 <= n and results[j + 1].note do j = j + 1 end
      local class = { [i] = 0 }
      for q = i + 1, j do
        local d = results[q].note - results[q - 1].note
        local k = math.floor(d / 12 + 0.5)
        class[q] = class[q - 1] + ((k ~= 0 and math.abs(d - 12 * k) <= O.JUMP_TOL_ST) and k or 0)
      end
      local moves, q = {}, i   -- decided on the classes as detected, applied afterwards
      while q <= j do
        local e = q
        while e + 1 <= j and class[e + 1] == class[q] do e = e + 1 end
        if results[e].time - results[q].time + hop <= O.MAX_RUN_S then
          local count, best, best_n, tied = {}, nil, 0, false
          for x = i, j do
            if results[x].time >= results[q].time - O.WINDOW_S and results[x].time <= results[e].time + O.WINDOW_S then
              count[class[x]] = (count[class[x]] or 0) + 1
            end
          end
          for c, cn in pairs(count) do
            if cn > best_n then best, best_n, tied = c, cn, false
            elseif cn == best_n then tied = true end
          end
          if not tied and best ~= class[q] then moves[#moves + 1] = { q, e, class[q] - best } end
        end
        q = e + 1
      end
      for _, mv in ipairs(moves) do
        for x = mv[1], mv[2] do
          local f = results[x]
          f.note = f.note - 12 * mv[3]
          if f.freq then f.freq = f.freq / 2 ^ mv[3] end
          changed = changed + 1
        end
      end
      i = j + 1
    end
  end
  return changed
end
```

- [ ] **Step 5: Call it before the notes are split**

In `run_hybrid_segmentation`, as its first line: `K.octave_fix(state.results or {})`. Nothing else calls it: `K.resplit` works on frames an analysis already fixed.

- [ ] **Step 6: Run the tests and the lint**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 102 tests` (93 + 9; `octave_fix_real_items` passes on this machine and prints `SKIP` elsewhere) and `0 warnings / 0 errors`.

- [ ] **Step 7: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua docs/superpowers/plans/2026-11-23-pitch-correct-octave-errors.md
git commit -m "fix(pitch-correct): put short octave-off stretches of the analysis back in their octave"
```

---

### Task 2: A note's centre leaves octave-wrong frames out

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`, `extract_note_features` step 4 (lines 1560–1575)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua` (same place as Task 1's tests; one new recorder flag next to `--record-natural`)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `K.CENTRE_OUTLIER_ST = 6`; `extract_note_features(note)` sets `note.avg_note` and `note.display_note` as before, from the core frames within `K.CENTRE_OUTLIER_ST` of the core's middle pitch. Recorder flag `--record-real`.

- [ ] **Step 1: Write the failing tests**

```lua
-- Note centre (extract_note_features step 4) ------------------------------------------------------

local function centre_note(pitches, rms)
  local fr = {}
  for i, p in ipairs(pitches) do fr[i] = { time = (i - 1) * OHOP, note = p, rms = rms and rms[i] or 0.1 } end
  return { start_time = 0, end_time = #fr * OHOP, frames = fr, count = #fr }
end
-- The centre as v2.19.0 computed it: the energy-weighted mean of the raw frames of the core
local function old_centre(note)
  local nf = #note.frames
  local sum, w_sum = 0, 0
  for i = math.max(1, math.floor(nf * 0.12)), math.min(nf, math.ceil(nf * 0.88)) do
    local f = note.frames[i]
    local w = math.max(0.0001, (f.rms or 0.05))
    sum, w_sum = sum + f.note * w, w_sum + w
  end
  return sum / w_sum
end

test("centre_ignores_octave_frames", function()
  local p = {}
  for i = 1, 27 do p[i] = (i == 6 or i == 7) and 47.0 or 58.8 end
  local note = centre_note(p)
  S.extract_note_features(note)
  near(note.avg_note, 58.8, 1e-9, "centre")
  eq(note.display_note, 59, "display note")
end)

test("centre_clean_note_unchanged", function()
  local p, rms = {}, {}
  for i = 1, 40 do p[i], rms[i] = 60 + 0.3 * math.sin(i), 0.05 + 0.01 * i end
  local note = centre_note(p, rms)
  local want = old_centre(note)
  S.extract_note_features(note)
  eq(note.avg_note, want, "bit for bit the old centre")
end)

test("centre_split_core_stays_finite", function()
  local note = centre_note({ 47, 47, 59.2, 59.2 })
  S.extract_note_features(note)
  near(note.avg_note, 47, 1e-9, "the lower of the two middle pitches decides")
end)

test("centre_real_only_outlier_notes_move", function()   -- this machine only
  local f = io.open(FIXTURE_DIR .. "pitch_real_model.json", "rb")
  if not f then print("SKIP centre_real_only_outlier_notes_move (no local fixture)") return end
  local data = loadfile("_lib/json.lua")().decode(f:read("a"))
  f:close()
  local moved = 0
  for _, note in ipairs(data.notes) do
    note.count = #note.frames
    local want = old_centre(note)
    S.extract_note_features(note)
    if note.avg_note ~= want then moved = moved + 1 end
  end
  eq(moved, 4, "notes whose centre moved (2, 4, 17 and 32 hold octave-wrong frames)")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: `FAIL centre_ignores_octave_frames` (got about 57.73), `FAIL centre_split_core_stays_finite` (got 53.1) and `FAIL centre_real_only_outlier_notes_move` (got 0). `centre_clean_note_unchanged` passes already and must keep passing.

- [ ] **Step 3: Change step 4 of `extract_note_features`**

Add `K.CENTRE_OUTLIER_ST = 6` next to `K.LEVEL_PERIODS` (about line 998), with a one-line comment. In step 4, before the existing loop: collect `note.frames[i].note` for `i = start_f, end_f`, sort, and take the middle value `mid` (index `(#list + 1) // 2`: for an even count the lower of the two middle values, so `mid` is always a real frame's pitch). Inside the existing loop, skip a frame when `math.abs(f.note - mid) > K.CENTRE_OUTLIER_ST`. Leave the loop's order and arithmetic exactly as they are (that is what keeps a clean note bit-identical). Update the step's comment to say what is left out and why.

- [ ] **Step 4: Run the tests**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua`
Expected: the four `centre_…` tests pass; `natural_same_numbers` and `natural_same_text` still pass. On this machine `natural_same_numbers_real` is expected to fail (its recorded numbers hold the old centres of notes 2, 4, 17 and 32); Step 5 records it again either way. Any other failure: stop and report it.

- [ ] **Step 5: Add `--record-real` and record the real fixture again**

Next to `if arg and arg[1] == "--record-natural"`: `--record-real` writes `FIXTURE_DIR .. "pitch_real_expected.lua"` from `S.K.correction_build(data.notes, data.item_len)` on `real_model()`, with the same writer `--record-natural` uses (lift the writer out of `natural_record` so both call it, with the header lines as a parameter), no commit check, and the header line `-- Natural correction of the real vocal, recorded after the note-centre fix (v2.19.1). Do not edit by hand.`; it prints `no local fixture` and exits 1 when `real_model()` is nil. `--record-natural` behaves as it does today.

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua --record-real && lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `recorded 1 cases to …/pitch_real_expected.lua`, then `ok 106 tests`, then `0 warnings / 0 errors`.

- [ ] **Step 6: Commit**

```bash
git add "Pitch/Fancy_Pitch Correct.lua" docs/superpowers/tests/pitch_correct_spec.lua
git commit -m "fix(pitch-correct): a note's centre leaves octave-wrong frames out"
```

---

### Task 3: Version, changelog and the check in real REAPER

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (header lines 3–9), `CHANGELOG.md` (top of `## [Unreleased]`)

**Interfaces:**
- Consumes: Tasks 1 and 2, complete.
- Produces: v2.19.1.

- [ ] **Step 1: Header**

`-- @version 2.19.1`, and the `@changelog` lines replaced by exactly:

```lua
-- @changelog
--   Analysis: a short stretch read one octave too high or too low (a spike or a sudden drop in the pitch line) is put back in the octave of the singing around it
--   A note's centre leaves out any pitch reading still in the wrong octave, so the note block sits on the pitch line and Quantize picks the right note
--   Analyze an item again to get this; notes analysed before may show as edited
```

- [ ] **Step 2: Changelog**

New first bullet under `## [Unreleased]`:

```markdown
- **Fancy Pitch Correct v2.19.1 (`Pitch/Fancy_Pitch Correct.lua`)** — Octave errors in the analysis:
  - **No more spikes and drops**: a short stretch the analysis read one octave too high or too low (up to 150 ms, with the right octave around it) is put back in the octave of the singing around it.
  - **Note blocks sit on the pitch line**: a note's centre leaves out any pitch reading still in the wrong octave, so the block is drawn where the note was sung and Quantize picks the right note.
  - **Analyze again**: items analysed before keep their old readings until you analyze them again, and some of their notes may show as edited.
```

- [ ] **Step 3: Real REAPER, following the testing protocol**

Read `.agents/skills/reaper-screenshot/references/testing-protocol.md` and the memory note `reaper-real-testing-limits` first. Then, in the project "Take It or Leave It" (re-analysing is allowed: the user said this pitch work is test material):

1. Sweep, relaunch `Fancy_Pitch Correct` (`capture.sh --relaunch "Fancy_Pitch Correct"`, wait 10 s), sweep, capture.
2. Open "Chorus Error" in the Pitched Items list, press Analyze (confirm Re-Analyze if asked), capture. Expected: the held note's block sits on its pitch line near F#4, and the pitch line has no vertical spikes.
3. Open "V Main Verse 1", Analyze (confirm Re-Analyze: its edits are replaced, one undo step), capture. Expected: the third note's block sits on its pitch line just under B3, with no drop below it.
4. Select that third note, press Q (Quantize; use the note action bar's button, `key.sh` does not send letters), capture. Expected: the block moves to B3 (before the fix it went to A3).
5. Say in the report what was done to the user's project (two analyses, one quantize, each one undo step) and what could not be checked.

- [ ] **Step 4: Final checks and commit**

Run: `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`
Expected: `ok 106 tests`, `0 warnings / 0 errors`.

```bash
git add "Pitch/Fancy_Pitch Correct.lua" CHANGELOG.md
git commit -m "fix(pitch-correct): octave errors in the analysis (v2.19.1)"
```
