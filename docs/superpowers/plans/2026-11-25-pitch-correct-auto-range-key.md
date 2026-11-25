# Pitch Correct Auto Vocal Range and Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

docs/design/pitch-correct-auto-range-key.md is Approved (2026-11-25, TheFancyWolf). Implement it exactly. Do not invoke skills.

**Goal:** Analyze first listens coarsely through the whole track to find the singer's range and the song's key (once per track, remembered on the track), then analyses with them; on screen this is one "Auto" choice in Vocal Range and one in Key.

**Architecture:** A pure tally (`K.pre_*`: semitone histogram → range and key) fed by a time-sliced coarse reader that reuses `yin_process_block` at a low sample rate. The result is a per-track record in the track's `P_EXT`, cached like Track Defaults and written inside the analysis's own undo block. "Auto" is a flag beside the five analysis values (`auto_range`) and Key index `0` in the bar; both are resolved to real values before anything is stored on an item.

**Tech Stack:** Lua 5.4, ReaScript, ReaImGui, `_lib/theme.lua`. Spec harness `docs/superpowers/tests/pitch_correct_spec.lua` (run: `lua docs/superpowers/tests/pitch_correct_spec.lua` from the repo root; it loads the script with `FANCY_PITCH_TEST` and the existing `reaper_stub.lua`). Lint: `luacheck .`.

**Spec:** `docs/design/pitch-correct-auto-range-key.md` (wireframes, state inventory, copy deck and acceptance criteria are binding; every user-visible string is copied from its Copy deck verbatim).

## Global Constraints

- Only `Pitch/Fancy_Pitch Correct.lua`, the spec file, `CHANGELOG.md` change. Never `index.xml`, `.github/`, `_fancy_*.json`, `_lib/`.
- No new row, button, modal, colour, font size or `Theme` helper (spec: Library proposals "None").
- `reaper.Name()` called directly; every variable `local`; nil-check every API return; no fabricated API (check `GetAudioAccessorSamples`, `GetSetMediaTrackInfo_String`, `GetTrackMediaItem`, `CountTrackMediaItems`, `TakeIsMIDI` with `mcp__reaper-dev__get_function_info` before first use).
- The pre-analysis writes no ExtState. The track record is written only inside an undo block that also holds what it belongs to.
- Track record key: `P_EXT:fancy_pitch_track_scan`. Tracks and takes are named by GUID in it.
- Only Major (`scale_idx` 1) and Natural Minor (`scale_idx` 2) are ever found.
- Long work is sliced with the existing `K.ANALYSIS_SLICE_S`; no enumeration per frame (cache per project state-change count, as `state.cache.trackdef` does).
- Do not build any substitute for REAPER beyond the existing spec harness. Real-REAPER steps follow `.agents/skills/reaper-screenshot/references/testing-protocol.md`; read the memory file `reaper-real-testing-limits.md` in full first; bring REAPER frontmost before a test that reads sources; ask the user to select / prepare items instead of clicking in their arrange. If a permission prompt fails, stop and tell the user.
- No migration code for older stored data (active development, per the user).
- Version: `@version 2.29.0`, with a `@changelog` line and a `CHANGELOG.md` entry (Task 8). Commit only where a step says so; do not push.

## Review Focus

- A track with MIDI items, empty takes or offline media → those items are skipped and counted; the rest is used; the "Couldn't read N of M items…" message appears; nothing crashes.
- Cmd+Z after the first Analyze on a track → the notes **and** the track record are gone, the cache follows the project state count, and the next Analyze runs the pre-analysis again.
- A malformed or hand-edited track record (text, wrong types, NaN, key 13, lo ≥ hi) → treated as no record.
- A batch over items on two tracks → each track is heard and recorded on its own; each item is analysed with its own track's range.
- Cancel during stage 1 (single item and batch) → no undo point, no record, no item data, accessor destroyed.
- Key `0` (Auto) must never reach `SCALE_KEYS[...]`, an item's stored model, or `update_scale_pitch_classes` as an index.

---

### Task 1: The tally: range and key from pitches heard (pure)

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (new block at the end of section 2, DSP LOGIC, after `K.analysis_frame`)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces:
  - `K.PRE = { RATE = 11025, BLOCK = 512, STEP_S = 0.1, MIN_HZ = 65, MAX_HZ = 1000, THRESHOLD = 0.15, MIN_FRAMES = 30, KEY_MIN_FRAMES = 100, TRIM = 0.02, MARGIN_LO_ST = 3, MARGIN_HI_ST = 4, KEY_CLOSE = 0.05, SHARE = 0.25 }` (`STEP_S` and `BLOCK` are provisional until Task 3 step 6).
  - `K.pre_tally_new() -> { st = {}, n = 0 }` (`st[midi_int] = frames heard`).
  - `K.pre_tally_add(tally, freq_hz)` (ignores nil / non-positive; rounds to the nearest MIDI note).
  - `K.pre_tally_merge(into, from)`.
  - `K.pre_range(tally) -> lo_st, hi_st | nil` (nil under `MIN_FRAMES`; the notes at the `TRIM` and `1 - TRIM` quantiles by frame count).
  - `K.pre_range_hz(lo_st, hi_st) -> min_freq, max_freq` (whole Hz; `MARGIN_LO_ST` below and `MARGIN_HI_ST` above; clamped to `K.LIMITS.min_freq[1]` … `K.LIMITS.max_freq[2]`; always `min < max`).
  - `K.pre_key(tally) -> key_idx, scale_idx, alt_key_idx, alt_scale_idx | nil` (nil under `KEY_MIN_FRAMES`; `alt_*` are nil unless the runner-up's score is within `KEY_CLOSE` of the best).
  - `K.pre_range_text(lo_st, hi_st) -> "E2–A4"` (note names from the script's existing namer, `midi_to_name`; en dash).

- [ ] **Step 1: Write the failing tests**

```lua
local function tally_of(notes)   -- { [midi] = frames }
  local t = S.K.pre_tally_new()
  for midi, n in pairs(notes) do
    for _ = 1, n do S.K.pre_tally_add(t, 440 * 2 ^ ((midi - 69) / 12)) end
  end
  return t
end

test("pre_range_trims_outliers", function()
  local t = tally_of({ [40] = 200, [52] = 400, [69] = 200, [88] = 2, [28] = 2 })
  local lo, hi = S.K.pre_range(t)
  eq(lo, 40); eq(hi, 69)
end)

test("pre_range_needs_frames", function()
  eq(S.K.pre_range(tally_of({ [60] = 29 })), nil)
end)

test("pre_range_hz_margin_and_limits", function()
  local lo, hi = S.K.pre_range_hz(40, 69)          -- E2 .. A4
  near(lo, 440 * 2 ^ ((37 - 69) / 12), 1)           -- 3 st below
  near(hi, 440 * 2 ^ ((73 - 69) / 12), 1)           -- 4 st above
  local lo2, hi2 = S.K.pre_range_hz(0, 127)
  eq(lo2, S.K.LIMITS.min_freq[1]); eq(hi2, S.K.LIMITS.max_freq[2])
end)

test("pre_key_major", function()   -- E major scale, tonic and fifth weighted
  local k, s = S.K.pre_key(tally_of({ [52]=300, [54]=100, [56]=180, [57]=120, [59]=250, [61]=100, [63]=60 }))
  eq(k, 5); eq(s, 1)               -- SCALE_KEYS[5] = E, SCALE_DEFINITIONS[1] = Major
end)

test("pre_key_minor", function()   -- A natural minor
  local k, s = S.K.pre_key(tally_of({ [57]=300, [59]=100, [60]=180, [62]=120, [64]=250, [65]=100, [67]=100 }))
  eq(k, 10); eq(s, 2)
end)

test("pre_key_close_call_names_runner_up", function()   -- flat use of the seven notes of C major / A minor
  local k, s, ak, as = S.K.pre_key(tally_of({ [60]=100, [62]=100, [64]=100, [65]=100, [67]=100, [69]=100, [71]=100 }))
  eq(type(ak), "number"); eq(type(as), "number")
  eq((k == 1 and s == 1 and ak == 10 and as == 2) or (k == 10 and s == 2 and ak == 1 and as == 1), true)
end)

test("pre_key_needs_frames", function()
  eq(S.K.pre_key(tally_of({ [60] = 99 })), nil)
end)

test("pre_range_text", function() eq(S.K.pre_range_text(40, 69), "E2\xE2\x80\x93A4") end)
```

- [ ] **Step 2: Run** `lua docs/superpowers/tests/pitch_correct_spec.lua` — the eight new tests FAIL (nil function).

- [ ] **Step 3: Implement the block.** The key finder is the one algorithm the tests do not determine: fold the tally to 12 pitch classes, correlate (Pearson) against the Krumhansl-Kessler profiles rotated to each of the 12 roots, best score wins.

```lua
-- Krumhansl-Kessler key profiles (index 1 = the tonic)
K.PRE.MAJOR = { 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 }
K.PRE.MINOR = { 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 }
```

- [ ] **Step 4: Run the spec** — all PASS. Run `luacheck .` — 0 warnings.

- [ ] **Step 5: Commit** `feat(pitch-correct): tally of pitches heard gives a range and a key`

---

### Task 2: The track record

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (beside `K.track_defaults`, ~line 1111; `K.TRACK_SCAN_KEY` beside `K.TRACK_DEFAULT_KEY`, ~line 217)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.pre_range`, `K.pre_key` (Task 1); `K.take_track(guid)`; `state.cache` (dropped on a project state change).
- Produces:
  - Record shape: `{ st = { ["52"] = 300, … }, takes = { [take_guid] = true }, lo_st, hi_st, key_idx, scale_idx, alt_key_idx, alt_scale_idx, skipped = n }` (`lo_st` / `hi_st` nil = nothing sung found; `key_idx` nil = key not told).
  - `K.track_record_valid(t) -> record | nil` (types checked; `lo_st < hi_st`; `key_idx` 1..12; `scale_idx` 1 or 2; `alt_*` both or neither; anything else → nil).
  - `K.track_record(track) -> record | nil` (parsed from the track's `P_EXT`, cached in `state.cache.trackscan[track]`).
  - `K.track_record_build(tally, takes, prev) -> record` (`prev` given: its `st` is merged in and its key fields are kept; the range is recomputed from the merged tally).
  - `K.track_records_pending = {}` (`[track] = record`) and `K.track_records_flush()` (writes every pending record with `GetSetMediaTrackInfo_String(track, K.TRACK_SCAN_KEY, json, true)`, clears the table and the cache; opens **no** undo block: the caller's block is open).
  - `K.track_record_tally(record) -> tally` (for merging).

- [ ] **Step 1: Write the failing tests** — `track_record_valid_accepts` (a full record round-trips through `JSON.encode` / decode and `K.track_record_valid`); `track_record_valid_rejects` (each of: a string, `key_idx = 13`, `scale_idx = 3`, `lo_st = 60, hi_st = 60`, `st` holding a non-number, `alt_key_idx` without `alt_scale_idx` → nil); `track_record_build_keeps_key` (`prev` with key 5 / scale 1 and a new tally in another key → the built record still has key 5 / scale 1 and a range covering both tallies); `track_records_flush_writes_once` (stub `reaper.GetSetMediaTrackInfo_String` to record calls: one write per pending track, the table empty afterwards, no `Undo_BeginBlock` call).

- [ ] **Step 2: Run the spec** — the four FAIL.
- [ ] **Step 3: Implement** the functions above, following `K.track_defaults` for parse-and-cache.
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): a track remembers its range and key`

---

### Task 3: The pre-analysis runner, then time it in real REAPER

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (section 3, after `K.release_analysis`; `K.analysis_tick` ~line 5769; `K.cancel_analysis` ~line 3009)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: Tasks 1–2; `K.open_accessor(take)`; `yin_process_block(samples, sample_rate, params)` (returns `rms, freq, …`); `get_take_guid`.
- Produces:
  - `K.pre_takes(track, record) -> list, skipped` (`list` = `{ take, item, guid, len }` for every audio item on the track whose active take is not MIDI and is not in `record.takes`; `skipped` = items that are MIDI-free but give no accessor).
  - `K.pre_begin(tracks, opts) -> started` (`tracks` = list of `MediaTrack`; `opts.fresh = true` ignores existing records; `opts.on_done(results)` runs once when every track is finished, `results[track] = record`; returns false and calls `on_done({})` at once when no track has anything to hear). Sets `state.pre = { … }` and `state.is_analyzing = true`.
  - `K.pre_step()` (one slice of at most `K.ANALYSIS_SLICE_S`: reads `K.PRE.BLOCK` samples at `K.PRE.RATE` every `K.PRE.STEP_S` with `GetAudioAccessorSamples`, runs `yin_process_block` with `{ block_size = K.PRE.BLOCK, min_freq = K.PRE.MIN_HZ, max_freq = K.PRE.MAX_HZ, threshold = K.PRE.THRESHOLD }`, adds a voiced frame's `freq` to the track's tally; a finished track's record is built with `K.track_record_build` and put in `K.track_records_pending`).
  - `K.pre_progress() -> 0..1` and `state.pre.track_name` (the track being heard), `state.pre.n_tracks`.
  - `K.pre_cancel()` (destroys the accessor, clears `state.pre` and `K.track_records_pending`; called by `K.cancel_analysis` and `K.release_analysis`).
  - `K.analysis_tick` calls `K.pre_step()` instead of the analysis step while `state.pre` is set.

- [ ] **Step 1: Write the failing tests** with the harness's stub: `GetAudioAccessorSamples` fills the buffer with a 220 Hz sine at the asked rate and returns 1.
  - `pre_runs_to_a_record`: one track, two 20 s takes → after stepping until `state.pre == nil`, `on_done` got one record with `lo_st == hi_st - 0`-style single note 57 heard (`record.st["57"] > 0`), both take GUIDs in `record.takes`, `K.track_records_pending[track]` set, `state.is_analyzing` still true only if the caller keeps it (assert `state.pre == nil`).
  - `pre_skips_heard_takes`: the track's record already lists one of the two takes → `GetAudioAccessorSamples` is only called for the other.
  - `pre_fresh_rehears_all`: `opts.fresh = true` → both takes are read and the built record does not merge the old tally.
  - `pre_slice_budget`: with `reaper.time_precise` stubbed to advance 0.003 per call, one `K.pre_step()` reads at most three blocks.
  - `pre_cancel_leaves_nothing`: begin, step twice, `K.cancel_analysis()` → `state.pre == nil`, `K.track_records_pending` empty, `DestroyAudioAccessor` called once, no `GetSetMediaTrackInfo_String` write, no `Undo_BeginBlock`.
  - `pre_unreadable_take_is_counted`: `K.open_accessor` gives nil for one take → `record.skipped == 1`, the other take is used.

- [ ] **Step 2: Run the spec** — FAIL.
- [ ] **Step 3: Implement.** One accessor open at a time; a take's read positions run from 0 to its item length less one block (take time, like the analysis).
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.

- [ ] **Step 5: Time it in real REAPER (no commit of this step's code).** Ask the user to open a project with a real lead-vocal track (several minutes of items) and select one of its items. Add lines marked `-- TEMP-DIAG` that, on the "…" menu's Analyze, run `K.pre_begin({ track })` alone and append to a file in the scratchpad: seconds of audio heard, wall-clock seconds, frames voiced, `K.pre_range_text(...)`, the key found and the runner-up. Bring REAPER frontmost (`osascript -e 'tell application "REAPER" to activate'`), relaunch the script with `capture.sh --relaunch "Fancy_Pitch Correct"`, wait 10 s, run it once on each track the user offers. Remove the lines with `git checkout -- "Pitch/Fancy_Pitch Correct.lua"` **only if** Step 6 has not been edited yet; otherwise delete them by hand and confirm with `grep -n TEMP-DIAG`.

- [ ] **Step 6: Fix the constants from the measurement.** Rule: target at most 1.5 s of wall clock per minute of audio. If it is met with `STEP_S = 0.1`, keep it. If not, raise `STEP_S` to 0.15, then 0.2, re-timing each; if 0.2 still misses, stop and report the numbers to the user. If reading at `K.PRE.RATE` returns no samples or a wrong pitch (220 Hz expected ± 1 semitone on a known item), set `K.PRE.RATE` to the take's own rate and `K.PRE.BLOCK` to 2048, re-time, and report. Record the measured numbers in the commit message.

- [ ] **Step 7: Commit** `feat(pitch-correct): time-sliced pre-analysis of a track` (measured timings in the body).

---

### Task 4: Vocal Range "Auto"

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`VOCAL_RANGES` line 38; `DEFAULTS` ~176–196; `K.ANALYSIS_KEYS` / `K.PERSIST` ~293, ~866; `K.analysis_defaults` 1818; `K.analysis_values` 1827; `K.form_part_names` 1851; form set / reset 1913–1950; `K.match_preset` uses 11089–11092; `K.SETTINGS_SECTIONS` rows `min_freq` / `max_freq` 11164–11171; `K.ROW_TIPS` 11035)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces:
  - `VOCAL_RANGES[1] = { name = "Auto", auto = true, min = 65, max = 1000 }`; Generic Vocal becomes index 2. `DEFAULTS.preset_range_idx` stays 1; `DEFAULTS.auto_range = true`.
  - Every analysis-values table (`K.analysis_defaults()`, a form's `values`, a stored `analysis`) carries `auto_range` (boolean, default false when absent). `state.auto_range` holds the Settings default; persisted as ExtState `pitch_auto_range` ("1" / "0") in the `engine` group.
  - A stored `analysis` of an Auto analysis also carries `auto_lo_st`, `auto_hi_st` (the notes found; absent when nothing was found).
  - `K.range_name(values) -> string`: "Auto" (auto, nothing stored), "Auto: E2–A4" (auto with `auto_lo_st`), "Auto: Generic Vocal (nothing found)" (auto, analysed, no notes found: `values.auto_none == true`), else the preset name or `K.CUSTOM_PRESET`. `K.form_part_names` uses it.
  - Picking "Auto" in the row sets `auto_range = true` and leaves the Hz at Auto's `min` / `max`; picking any other range, or editing Min / Max Freq by Reset of those rows, sets `auto_range = false`.
  - Min Freq and Max Freq rows: disabled while `auto_range`, with the text "Found from the track" inline after the first of them and as both rows' tooltip (`HoveredFlags_ForTooltip | HoveredFlags_AllowWhenDisabled`).
  - `K.ROW_TIPS` / the per-choice tooltip of "Auto": the spec's Copy deck string.

- [ ] **Step 1: Write the failing tests** — `auto_is_factory_range` (`S.DEFAULTS.auto_range == true`; `K.analysis_defaults()` on a load with empty ExtState has `auto_range == true`); `auto_range_persists` (load with `{ pitch_auto_range = "0" }` → false; unknown text → factory true); `range_name_variants` (the four strings above, exact); `analysis_values_keeps_auto` (`K.analysis_values` of a valid table with `auto_range = true` returns it true; with a non-boolean returns false); `form_pick_range_clears_auto` (form value set with the Tenor entry → `auto_range == false`, Hz 130 / 500; with the Auto entry → true); `existing_presets_shift` (a values table at 250 / 1200 still names "Soprano").

- [ ] **Step 2: Run the spec** — FAIL. Existing tests that index `VOCAL_RANGES` by number may fail too: fix them to look ranges up by name.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): Vocal Range has an Auto choice`

---

### Task 5: Key "Auto"

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`K.new_key` 537; `K.new_item_values` / `K.item_seed` 548–573; `K.PERSIST` key group ~860; `update_scale_pitch_classes` 794; init ~946; top bar combos 13583, 13801–13830)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.track_record(track)`, `K.take_track(guid)`.
- Produces:
  - Key index `0` = Auto. `K.new_key = { key_idx = 0, scale_idx = 1, hand_key_idx = 1, hand_scale_idx = 1 }`; ExtState `pitch_key_idx` accepts 0..12; new ExtState `pitch_key_hand_idx`, `pitch_scale_hand_idx` (the key last chosen by hand: updated whenever a real key or scale is chosen in the bar).
  - `K.key_resolve(key_idx, scale_idx, guid) -> key_idx, scale_idx, from_track` (a real key passes through; `0` gives the track record's key when it has one (`from_track = true`), else `hand_key_idx` / `hand_scale_idx`).
  - `K.item_seed` never leaves `0` on an item: it resolves with `K.key_resolve` and sets `data.key_from_track = true` when the key came from the record.
  - `state.key_idx == 0` is allowed only while the target is not analysed. `update_scale_pitch_classes` treats `0` as "every pitch class in scale".
  - Top bar: the Key combo's list starts with "Auto" (preview "Auto"); `key_w` measured over the labels including "Auto". While `state.key_idx == 0` the Scale combo shows "Auto" inside `BeginDisabled`, tooltip "Found with the key" (allowed when disabled). The Key combo's tooltip for an analysed item with `key_from_track`: "Found from <track>. <Alt> also fits." / "Found from <track>." (the runner-up from the track's record).

- [ ] **Step 1: Write the failing tests** — `key_auto_is_fresh_default` (empty ExtState → `K.new_key.key_idx == 0`); `key_resolve_from_track` (record with key 5 / scale 1 → `5, 1, true`); `key_resolve_falls_to_hand` (no record, `hand_key_idx = 3`, `hand_scale_idx = 2` → `3, 2, false`); `item_seed_never_stores_auto` (seed with `K.new_key.key_idx = 0` → `data.key_idx` in 1..12, `data.key_from_track` matches); `scale_classes_with_auto` (`state.key_idx = 0` → `update` does not error and every pitch class is in scale); `hand_key_tracks_bar_choice` (a real key chosen → `hand_key_idx` follows; choosing Auto leaves it).

- [ ] **Step 2: Run the spec** — FAIL.
- [ ] **Step 3: Implement.** Audit every `SCALE_KEYS[state.key_idx]` and `SCALE_KEYS[...key_idx]` use (`grep -n "SCALE_KEYS\["`) and guard index 0.
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): Key has an Auto choice for new items`

---

### Task 6: Analyze runs the pre-analysis first

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`start_analysis` 2077; `K.analysis_begin` 2005; batch `K.batch_next` 3372 and `K.batch_finish` 3323; `process_analysis_step` 5647–5760; `end_apply` 3664; progress / Cancel label `K.CANCEL_FMT` users; `K.LOCKED_REASON` users 7259, 11200, 11493, 11796)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `K.auto_needed(values, guid) -> boolean` (true when `values.auto_range`, or the item is not analysed and `state.key_idx == 0`).
  - `K.auto_values(values, record) -> values, none` (a copy with `min_freq` / `max_freq` from `K.pre_range_hz(record.lo_st, record.hi_st)` and `auto_lo_st` / `auto_hi_st`; no range in the record → Generic Vocal's Hz, `auto_none = true`, `none = true`).
  - Single item: `start_analysis(values)` → when `K.auto_needed`, `K.pre_begin({ track }, { on_done = … })` and only then `K.analysis_begin(take, item, { values = K.auto_values(...) })`. When the track's record already covers every take, `on_done` runs at once (no stage 1).
  - Batch: before its first item, one `K.pre_begin` over the distinct tracks of the items that need Auto; each item then gets `K.auto_values` from its own track's record.
  - `end_apply` and the batch's undo block call `K.track_records_flush()` before `Undo_EndBlock`.
  - Overall progress while `state.pre`: `K.PRE.SHARE * K.pre_progress()`; during the analysis after a stage 1: `K.PRE.SHARE + (1 - K.PRE.SHARE) * progress`. The "…" Cancel label and the form's locked line use it. Locked line while `state.pre`: "Finding range and key… 42%" (one track) / "Finding range and key: <track>… 42%" (several); the summary layout shows the same.
  - Status after the analysis (single item; a batch keeps its own summary and appends nothing): the Copy deck's "Found …", "Used <track>'s range and key: …", "Couldn't find a range on <track>: used Generic Vocal.", "Not enough singing to tell the key: kept <key>.", "Couldn't read N of M items on <track> (media offline). Used the rest.", built by `K.auto_status(info) -> string` where `info = { fresh, range_text, key_text, alt_text, track, none, no_key, kept_key_text, skipped, total, want_range, want_key }`. Priority when several apply: unreadable-all (existing message) > no range > no key > found / used.

- [ ] **Step 1: Write the failing tests**
  - `auto_needed_cases` (auto range → true; fixed range + unanalysed + key 0 → true; fixed range + key 5 → false; fixed range + analysed item → false).
  - `auto_values_from_record` (record 40..69 → Hz of `K.pre_range_hz(40, 69)`, `auto_lo_st == 40`; record without range → 65 / 1000, `auto_none == true`).
  - `auto_status_strings`: each Copy deck status string produced exactly, including "Found E2–A4, E Major (C# Minor also fits). Cmd+Z to undo." (with `K.MOD_LABEL`), "Found E2–A4." (range only) and "Found E Major." (key only).
  - `analyze_auto_then_stores` (stubbed sine as in Task 3; target on a track with no record; `start_analysis` with Auto values; step `K.analysis_tick` to the end): `state.session_takes[guid].analysis.auto_range == true`, its `min_freq` / `max_freq` equal `K.pre_range_hz` of the record, `GetSetMediaTrackInfo_String` written exactly once and **between** the analysis's `Undo_BeginBlock` and `Undo_EndBlock` (record the call order in the stub).
  - `analyze_auto_reuses_record` (the record covers the take → `GetAudioAccessorSamples` is never called at `K.PRE.RATE`; no track write).
  - `analyze_fixed_range_fixed_key_no_pre` (`state.pre` is never set).
  - `cancel_in_stage_one_writes_nothing` (begin, two ticks, `K.cancel_analysis()` → no `Undo_BeginBlock`, no take or track write, `state.is_analyzing == false`).
  - `batch_two_tracks_each_own_range` (two tracks, sines at 110 Hz and 440 Hz → each item's stored `analysis.min_freq` differs and matches its own track's record; two track writes inside the batch's one undo block).
  - `undo_drops_record_cache` (after the analysis, change what the stub returns for the track's `P_EXT` to "" and bump `GetProjectStateChangeCount` → `K.track_record(track) == nil`).

- [ ] **Step 2: Run the spec** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): Analyze finds the range and key first`

---

### Task 7: Correcting the key, Key Auto on an analysed item, Find Range and Key Again

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`K.scale_changed` 4359; `hdr_draw_more` 13871; Info modal text on analysis ~11943)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: Tasks 2, 3, 5, 6; `save_current_scale_settings(undo_label)`, `apply_envelope_to_take(undo_desc, keep)`.
- Produces:
  - `K.scale_changed(what)` on an analysed item with `data.key_from_track`: does **not** write `K.new_key` / ExtState; puts the track's record (new `key_idx` / `scale_idx`, `alt_*` cleared) in `K.track_records_pending` so it is flushed inside the same undo block as the item's change (also on the plain-save path: `save_current_scale_settings` must flush inside its block); status "Key for <track> is now <Key> <Scale>. New items on this track follow." On any other item: unchanged, plus `hand_key_idx` / `hand_scale_idx` follow.
  - Choosing "Auto" in the Key combo on an analysed item: `K.find_key_request()` → the track is heard first if it has no record (`K.pre_begin`), then the item takes the record's key (`key_from_track = true`), one undo point "Find Key: <item name>"; no key in the record → status "Not enough singing to tell the key: kept <key>." and nothing is written.
  - "…" menu item "Find Range and Key Again" (under the Analyze items): `K.find_again_request()` → `K.pre_begin({ track }, { fresh = true, on_done = … })`, then one undo block "Find Range and Key: <track>" holding only the record; status "Found E2–A4, E Major on <track>. Items already analyzed keep theirs. Cmd+Z to undo." Disabled with the menu's existing reason pattern when there is no target or `state.is_analyzing`. While it runs the menu shows the existing Cancel item.
  - Info modal: one sentence on Auto and one on Find Range and Key Again in its analysis text.

- [ ] **Step 1: Write the failing tests** — `key_fix_follows_track` (item with `key_from_track`, record key 5; bar set to key 2 → pending / written record has key 2 and no `alt_*`; `K.new_key.key_idx` unchanged at 0; the track write falls inside the undo block; the status string exact); `key_fix_other_item_as_before` (item without `key_from_track` → no track write, `K.new_key` follows as today); `find_key_uses_record` (analysed item, record key 10 / scale 2 → item 10 / 2, `key_from_track`, undo label "Find Key: <name>"); `find_key_without_key_changes_nothing` (record without key → no undo block, the status string exact); `find_again_replaces_record` (`fresh` → the record's `takes` equal the takes read now, the item's stored key untouched, undo label "Find Range and Key: <track>").

- [ ] **Step 2: Run the spec** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): a corrected key follows the track; Find Range and Key Again`

---

### Task 8: Release notes and real-REAPER verification

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (header `@version 2.29.0`, `@changelog`), `CHANGELOG.md`

- [ ] **Step 1:** Set `@version 2.29.0`; replace the `@changelog` body with one line describing Auto Vocal Range, Auto Key, the pre-analysis stage and Find Range and Key Again; add the matching Keep a Changelog entry to `CHANGELOG.md`. Leave the rest of the ReaPack header untouched.
- [ ] **Step 2:** Run `lua docs/superpowers/tests/pitch_correct_spec.lua` (all PASS) and `luacheck .` (0 warnings).
- [ ] **Step 3: Real REAPER, following the testing protocol** (sweep strays before and after each action; note edit cursor, view, selection and Theme Mode first and restore them). Ask the user to select an unanalysed vocal item on a track with several items. Relaunch the script, wait 10 s, capture. Check and report what was seen for each:
  1. Empty canvas: Key combo "Auto", Scale "Auto" disabled, Vocal Range "Auto", form the same size as the baseline screenshot.
  2. Analyze: "Finding range and key… NN%" appears, then the pitch line draws in; "…" shows Cancel NN%.
  3. After: the top bar shows a real key; the status line reads "Found …"; Re-Analyze… shows "Auto: <low>–<high>".
  4. One Cmd+Z (through the bridge's `undo`): the notes are gone and a second Analyze shows stage 1 again. Redo it.
  5. A second unanalysed item on the same track: no stage 1 (or a short one), status "Used <track>'s range and key: …".
  6. Change the key on the first item: status "Key for <track> is now …"; an unanalysed item on that track still shows "Auto" before analysis and gets the corrected key after.
  7. "…" → Find Range and Key Again: status as specified; one undo point.
  8. Advanced open: Min / Max Freq disabled with "Found from the track".
  9. Match Theme mode: repeat capture 1.
  Say plainly what could not be checked (narrow-docker and short-strip layouts cannot be produced through the bridge, per the testing-limits notes).
- [ ] **Step 4: Accuracy on the singer test set.** With the user's test items (see `docs/superpowers/specs/2026-11-23-analyze-selected-items-and-singer-test-set.md`), run Analyze with Auto on each singer's track and list per track: range found, key found, runner-up, and the user's verdict on each. Report the table; do not tune constants without the user's say.
- [ ] **Step 5: Commit** `feat(pitch-correct): Auto Vocal Range and Key (v2.29.0)`
