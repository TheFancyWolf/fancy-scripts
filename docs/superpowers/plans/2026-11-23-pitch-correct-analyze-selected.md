# Analyze All Selected Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

docs/design/pitch-correct-analyze-selected.md is Approved (2026-11-23, TheFancyWolf). Implement it exactly. Do not invoke skills.

**Goal:** Fancy Pitch Correct analyses every selected audio item in one batch behind one undo step, every analysis reads the uncorrected audio, and a developer switch dumps what the detector saw.

**Architecture:** The analysis core stays one-item-at-a-time and sliced across frames. `start_analysis` becomes a thin caller of `K.analysis_begin`, which the batch calls too. A batch is a table `K.batch` holding a frozen queue of takes; finished models are held in memory and written by `K.batch_write` in a single undo block when the batch ends, however it ends. Everything new lives on `K` (the script is near Lua's 200-local limit).

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui 0.10, `_lib/theme.lua`; tests in plain Lua (`docs/superpowers/tests/pitch_correct_spec.lua`, which stubs single `reaper.*` functions per test, as it does today).

**Spec:** `docs/design/pitch-correct-analyze-selected.md` (interface, copy, states) and `docs/superpowers/specs/2026-11-23-analyze-selected-items-and-singer-test-set.md`, Part A (the Re-Analyze fix, the developer switch, done criteria).

## Global Constraints

- No new chunk-level `local` in `Pitch/Fancy_Pitch Correct.lua`: new functions, tables and constants go on `K`.
- `reaper.Function()` called directly, never aliased; every API return checked for nil before use.
- Every user-visible string is taken verbatim from the design's Copy deck. The modifier in "Cmd+Z" comes from `K.MOD_LABEL`.
- No colours, sizes or spacing as literals: `Theme.layout.*`, palette keys, `Theme.*` helpers only.
- REAPER's item selection is read, never changed by the batch (`ensure_take_pitch_envelope` already saves and restores it while it creates an envelope; that stays).
- One undo point per batch, named `Analyze Pitch (N items)`; none when nothing was written. No undo block stays open between frames.
- Nothing is written to ExtState or JSON by the batch. The developer switch only reads ExtState `FancyScripts` / `pitch_dev_dump`.
- Every ReaImGui / REAPER function name is checked (`reaper-dev` or `.agents/skills/reaimgui-ux-review/scripts/reaimgui_api_names.txt`) before use.
- After every task: `lua docs/superpowers/tests/pitch_correct_spec.lua` prints `ok N tests` and `luacheck .` reports 0 warnings / 0 errors.
- Nothing is merged or pushed.

## Facts established in real REAPER (2026-11-23, REAPER 7.86)

- **Cause confirmed.** A take audio accessor returns the audio with the take's active Pitch envelope applied: five edited notes read 0.10 to 0.22 st higher through the accessor than with the envelope bypassed, matching the envelope's value at each spot (0.13 to 0.25 st).
- **An accessor keeps the take state it was made with.** It does not see a later envelope change until `AudioAccessorValidateState` or `AudioAccessorUpdate` is called (the script calls neither). An accessor created while the envelope is bypassed (`ACT 0`), with the chunk put back in the same call, still read uncorrected audio 30 and 120 frames later, on blocks it had not read before. Both chunk writes took 0.14 ms; the restored chunk was byte-identical; no undo point was added.
- **So the fix needs no audible switch-off:** bypass, create the accessor, restore, all inside one call.
- **Media reads as offline while REAPER is in the background** on this machine ("Set media items offline when application is not active"): `GetMediaSourceSampleRate` returns 0 then, though accessors keep reading. Today that stores an analysis with no notes. A batch must record each item's sample rate at the click (REAPER is frontmost then) and never ask again.

## Review Focus

1. **REAPER goes to the background during a batch** (media reads offline, sample rate 0): later items are still analysed, at the rate recorded at the click. Test `batch_uses_rates_from_the_click` (Task 4).
2. **An item is deleted, or the project tab is switched, during a batch:** its turn is skipped and counted as "could not be analyzed"; finished items that are gone at the end are not written and not counted as analysed. Tests `batch_skips_missing_and_offline`, `batch_write_skips_gone_takes` (Task 4).
3. **The selection changes during a batch:** the queue is the list frozen at the click. Test `batch_queue_is_frozen` (Task 4).
4. **A selected item's media is offline at the click** (sample rate 0 even in the foreground): counted as "could not be analyzed", never stored as an empty analysis; the same guard for a single analysis. Test `analysis_begin_refuses_offline_media` (Task 1).
5. **A selection of hundreds of items:** the button's count is refreshed at most every 0.25 s or on a selection / project change, never per frame. Test `batch_peek_is_cached` (Task 3).

---

### Task 1: Every analysis reads the uncorrected audio

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`start_analysis`, about line 1334; new `K.open_accessor`, `K.analysis_begin` just above it)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua` (append above the "Tests appended by later tasks" line)

**Interfaces:**
- Produces: `K.open_accessor(take) -> accessor | nil`. When the take has a Pitch envelope whose chunk holds `ACT 1` and at least one `PT ` line: write the chunk with the first `ACT 1` changed to `ACT 0`, create the accessor inside `pcall`, write the original chunk back, call `note_own_write()`. Otherwise just create the accessor. Returns nil when creation failed.
- Produces: `K.analysis_begin(take, item, opts) -> true | false, reason`. The body of today's `start_analysis` after the target is resolved. `opts.sample_rate` (number, optional): use it instead of asking the source. `opts.defer_envelope` (boolean): skip the "Show Pitch Envelope" block. Returns `false, "offline"` when the sample rate is not above 0 and `false, "accessor"` when no accessor could be made; in both cases nothing is allocated and `state.is_analyzing` stays false.
- `start_analysis()` keeps its signature: resolve the target, call `K.analysis_begin(take, item)`, and on `false` post `Couldn't read this item's audio. Check that its media is online, then try again.`

- [ ] **Step 1: Write the failing tests**

```lua
local ENV_CHUNK = "<PITCHENV\nEGUID {E}\nACT 1 -1\nVIS 1 1 1\nPT 0 0 0\nPT 0.5 0.244 5 0\n>"
local function with_envelope(chunk, create, fn)   -- runs fn(log) with the envelope and accessor calls recorded
  local log = {}
  reaper.GetTakeEnvelopeByName = function() return chunk and "ENV" or nil end
  reaper.GetEnvelopeStateChunk = function() return true, chunk end
  reaper.SetEnvelopeStateChunk = function(_, c) log[#log + 1] = "set:" .. c; return true end
  reaper.CreateTakeAudioAccessor = function() log[#log + 1] = "create"; return create() end
  local ok, err = pcall(fn, log)
  reaper.GetTakeEnvelopeByName, reaper.GetEnvelopeStateChunk, reaper.SetEnvelopeStateChunk,
    reaper.CreateTakeAudioAccessor = nil, nil, nil, nil
  if not ok then error(err, 0) end
end

test("open_accessor_reads_around_the_envelope", function()
  with_envelope(ENV_CHUNK, function() return "ACC" end, function(log)
    eq(S.K.open_accessor("TAKE"), "ACC")
    eq(#log, 3, "calls")
    eq(log[1], "set:" .. (ENV_CHUNK:gsub("ACT 1", "ACT 0", 1)), "bypassed first")
    eq(log[2], "create")
    eq(log[3], "set:" .. ENV_CHUNK, "put back byte for byte")
  end)
end)

test("open_accessor_restores_when_creation_fails", function()
  with_envelope(ENV_CHUNK, function() error("boom") end, function(log)
    eq(S.K.open_accessor("TAKE"), nil)
    eq(log[#log], "set:" .. ENV_CHUNK, "envelope put back")
  end)
end)

test("open_accessor_leaves_other_envelopes_alone", function()
  for _, chunk in ipairs({ false, (ENV_CHUNK:gsub("ACT 1", "ACT 0", 1)), "<PITCHENV\nACT 1 -1\nVIS 1 1 1\n>" }) do
    with_envelope(chunk, function() return "ACC" end, function(log)
      eq(S.K.open_accessor("TAKE"), "ACC")
      eq(#log, 1, "only the accessor is created"); eq(log[1], "create")
    end)
  end
end)

test("analysis_begin_refuses_offline_media", function()
  local st = S.state
  reaper.GetMediaSourceSampleRate = function() return 0 end
  local created = false
  reaper.CreateTakeAudioAccessor = function() created = true; return "ACC" end
  local ok, reason = S.K.analysis_begin("TAKE", "ITEM")
  reaper.GetMediaSourceSampleRate, reaper.CreateTakeAudioAccessor = nil, nil
  eq(ok, false); eq(reason, "offline"); eq(st.is_analyzing, false); eq(created, false, "nothing was opened")
end)
```

- [ ] **Step 2: Run** `lua docs/superpowers/tests/pitch_correct_spec.lua` — expected: four FAIL lines ("attempt to call a nil value (field 'open_accessor')" / `analysis_begin`).
- [ ] **Step 3: Implement** `K.open_accessor` and `K.analysis_begin`, and reduce `start_analysis` to the caller described above. `K.analysis_begin` sets `state.target_take_guid` / `state.target_take_name` as today, uses `K.open_accessor` in place of `reaper.CreateTakeAudioAccessor`, and runs the "Show Pitch Envelope" block only when `opts.defer_envelope` is not set.
- [ ] **Step 4: Run the tests** — expected `ok N tests`; `luacheck .` clean.
- [ ] **Step 5: Commit** `fix(pitch-correct): analysis reads the uncorrected audio`

### Task 2: The developer dump

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (new `K.dump_name`, `K.dump_text`, `K.dev_dump` in section 3; one call in the completion branch of `process_analysis_step`, before `run_hybrid_segmentation()`)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua` (`diag_frames`, about line 2031, and new tests)

**Interfaces:**
- Produces: `K.dump_name(take_name, guid) -> string`: `"diag_" .. name .. "_" .. guid .. ".tsv"`, where every character of the name outside `[%w%-]` becomes `_` (an empty name becomes `item`) and the GUID loses its braces.
- Produces: `K.dump_text(params, sample_rate, results) -> string`. Line 1: `# sr=48000 block=1024 hop=512 th=0.08 min=65 max=1000` (`%g` for each number). Line 2: `time\tfreq\trms\thow\tlvl\tdips`. One line per frame: `%.6f\t%.3f\t%.5f\t%s\t%.5f\t%s` = time, freq (`-1.000` without one), rms, `voiced` / `unvoiced` (unvoiced = the frame has no `cands`), lvl, and the candidates as `tau:d` (`%.3f:%.4f`) joined by spaces. Ends with a newline.
- Produces: `K.dev_dump(take_name, guid, params, sample_rate, results) -> path | nil`: reads `reaper.GetExtState("FancyScripts", "pitch_dev_dump")`; empty or nil → returns nil and touches no file; else writes `K.dump_text` to `<folder>/<K.dump_name>` and returns the path. A folder that cannot be written posts `Dev dump: couldn't write to <folder>` and returns nil.
- Test side: `diag_frames(name)` keeps its signature and is split into `diag_parse(text) -> frames`, which finds columns by the header line's names (`time`, `rms`, `how`, `dips`, and `lvl` when present, else rms), and reads candidates with `([%d%.]+):([%d%.]+)` so integer and fractional periods both parse.

- [ ] **Step 1: Write the failing tests**

```lua
local DUMP_PARAMS = { block_size = 1024, hop_size = 512, threshold = 0.08, min_freq = 65, max_freq = 1000 }
local function dump_results()
  return {
    { time = 0.010667, rms = 0.0007, lvl = 0.0006 },
    { time = 0.064, freq = 337.22, rms = 0.02487, lvl = 0.0231,
      cands = { { tau = 142.337, d = 0.0182 }, { tau = 284.5, d = 0.0507 } } },
  }
end

test("dump_name", function()
  eq(S.K.dump_name("V Main: Verse/1", "{AB12-CD}"), "diag_V_Main__Verse_1_AB12-CD.tsv")
  eq(S.K.dump_name("", "{X}"), "diag_item_X.tsv")
end)

test("dump_text_format", function()
  local lines = {}
  for line in S.K.dump_text(DUMP_PARAMS, 48000, dump_results()):gmatch("[^\n]+") do lines[#lines + 1] = line end
  eq(lines[1], "# sr=48000 block=1024 hop=512 th=0.08 min=65 max=1000")
  eq(lines[2], "time\tfreq\trms\thow\tlvl\tdips")
  eq(lines[3], "0.010667\t-1.000\t0.00070\tunvoiced\t0.00060\t")
  eq(lines[4], "0.064000\t337.220\t0.02487\tvoiced\t0.02310\t142.337:0.0182 284.500:0.0507")
  eq(#lines, 4)
end)

test("dump_round_trip", function()
  local fr = diag_parse(S.K.dump_text(DUMP_PARAMS, 48000, dump_results()))
  eq(#fr, 2)
  eq(fr[1].cands, nil, "an unvoiced frame has no candidates")
  near(fr[2].time, 0.064, 1e-6); near(fr[2].rms, 0.02487, 1e-5); near(fr[2].lvl, 0.0231, 1e-5)
  eq(#fr[2].cands, 2); near(fr[2].cands[1].tau, 142.337, 1e-3); near(fr[2].cands[2].d, 0.0507, 1e-4)
end)

test("dump_reader_still_reads_the_recordings_of_2026_11_23", function()
  local fr = diag_parse("# sr=48000 block=1024 hop=512 th=0.08 min=65 max=1000\n"
    .. "time\tfreq\trms\thow\ttau\tW\tmin_tau\tmax_tau\tedge\tdips\n"
    .. "0.000000\t-1.000\t0.00027\tunvoiced\t487\t512\t48\t512\t1.0127\t487:0.7824\n"
    .. "0.053333\t333.208\t0.01981\tglobal\t144\t512\t48\t512\t1.1187\t116:0.5025 144:0.0912\n")
  eq(#fr, 2); eq(fr[1].cands, nil); near(fr[2].rms, 0.01981, 1e-9); near(fr[2].lvl, 0.01981, 1e-9, "no lvl column: rms")
  eq(#fr[2].cands, 2); eq(fr[2].cands[2].tau, 144); near(fr[2].cands[2].d, 0.0912, 1e-9)
end)

test("dev_dump_off_by_default_and_on", function()
  eq(S.K.dev_dump("Take", "{G}", DUMP_PARAMS, 48000, dump_results()), nil, "off: the switch is empty")
  local dir = os.tmpname(); os.remove(dir); os.execute('mkdir "' .. dir .. '"')
  reaper.GetExtState = function(_, key) return key == "pitch_dev_dump" and dir or "" end
  local path = S.K.dev_dump("Take", "{G}", DUMP_PARAMS, 48000, dump_results())
  reaper.GetExtState = function() return "" end   -- the harness's own stub
  eq(path, dir .. "/diag_Take_G.tsv")
  local f = io.open(path, "rb"); local body = f:read("a"); f:close(); os.remove(path); os.remove(dir)
  eq(body, S.K.dump_text(DUMP_PARAMS, 48000, dump_results()))
end)
```

- [ ] **Step 2: Run** — expected: FAIL for each new test (`diag_parse` and the `K` functions do not exist).
- [ ] **Step 3: Implement** the three `K` functions, the call in `process_analysis_step` (it uses the local `params` and `state.results` before the segmentation removes the candidates, and the target's name and GUID), and `diag_parse` in the spec.
- [ ] **Step 4: Run** — `ok N tests` (`track_real_items` still passes on this machine: it reads the old recordings through the new reader); `luacheck .` clean.
- [ ] **Step 5: Commit** `feat(pitch-correct): developer dump of what the detector saw`

### Task 3: What a batch is made of (selection, counts, copy)

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (a new banner section "3b. BATCH ANALYSIS" after `K.cancel_analysis`, so `adopt_take_data` and `plural` users are in reach; `plural` is defined later in the file, so copy functions that need it use their own singular / plural strings)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces (all produced here, consumed by Tasks 4 and 5):**
- `K.batch_selection() -> { takes = { entry... }, skipped = n }`. `entry = { guid, take, item, name, len, sample_rate, has_notes, track, pos }` for each selected item whose active take exists and is not MIDI, in REAPER's selection order. `skipped` counts the other selected items. `has_notes` = `state.session_takes[guid]` holds at least one note. `len` = `D_LENGTH`, `pos` = `D_POSITION`, `track` = the track's name, `sample_rate` = the source's rate (may be 0).
- `K.BATCH_PEEK_S = 0.25` and `K.batch_peek(now) -> { n, skipped, with_notes, target_in }`: a summary of `K.batch_selection()` kept in `K.batch_peek_cache` and rebuilt only when `reaper.CountSelectedMediaItems(0)` or `reaper.GetProjectStateChangeCount(0)` differs from the cached one, or `now - at >= K.BATCH_PEEK_S`. `target_in` = `state.target_take_guid` is one of the takes.
- `K.batch_label(n, narrow) -> string`: `Analyze Item` for `n < 2`; else `Analyze All Selected Items`, or `Analyze All` when `narrow`.
- `K.batch_lines(peek) -> line1, line2 | nil` and `K.batch_tip(n) -> string`: the Copy deck's "lines under the canvas button" and the batch tooltip.
- `K.batch_confirm(entries) -> { title, body_lines, list, after_lines, confirm_label } | nil`: nil when no entry has notes; `list` = `{ { name, track, pos } ... }` for the entries that have notes, in order.
- `K.batch_new(entries, prev_guid) -> batch`: `{ queue = entries, index = 0, done = {}, failed = 0, total_len, done_len = 0, prev_guid }`.
- `K.batch_progress(batch, item_progress) -> number` in 0..1: `(done_len + len of queue[index] * item_progress) / total_len`; 0 when `total_len` is 0.
- `K.batch_undo_label(n) -> string`, `K.batch_summary(r) -> string` with `r = { total, written, empty, failed, cancelled }`.

- [ ] **Step 1: Write the failing tests**

```lua
local MOD = S.K.MOD_LABEL

local function with_selection(items, fn)   -- items: { { take = id | nil, midi = bool, name, len, sr, track, pos } }
  reaper.CountSelectedMediaItems = function() return #items end
  reaper.GetSelectedMediaItem = function(_, i) return items[i + 1] end
  reaper.GetActiveTake = function(it) return it.take end
  reaper.TakeIsMIDI = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.midi == true end end end
  reaper.GetSetMediaItemTakeInfo_String = function(tk, key) if key == "GUID" then return true, "{" .. tk .. "}" end return false, "" end
  reaper.GetTakeName = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.name end end end
  reaper.GetMediaItemInfo_Value = function(it, key) return key == "D_LENGTH" and (it.len or 1) or (it.pos or 0) end
  reaper.GetMediaItemTake_Source = function(tk) return tk end
  reaper.GetMediaSourceSampleRate = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.sr or 48000 end end end
  reaper.GetMediaItemTrack = function(it) return it end
  reaper.GetTrackName = function(it) return true, it.track or "Vox" end
  local ok, err = pcall(fn)
  for _, name in ipairs({ "CountSelectedMediaItems", "GetSelectedMediaItem", "GetActiveTake", "TakeIsMIDI",
    "GetSetMediaItemTakeInfo_String", "GetTakeName", "GetMediaItemInfo_Value", "GetMediaItemTake_Source",
    "GetMediaSourceSampleRate", "GetMediaItemTrack", "GetTrackName" }) do reaper[name] = nil end
  S.K.batch_peek_cache = nil
  if not ok then error(err, 0) end
end

test("batch_selection_audio_only", function()
  local st = S.state
  st.session_takes["{b}"] = { notes = { {} }, results = { {} } }
  st.session_takes["{d}"] = { notes = {}, results = { {} } }
  with_selection({ { take = "a", name = "A", len = 10, pos = 4 }, { take = "m", midi = true }, { name = "empty" },
      { take = "b", name = "B", len = 20, sr = 44100, track = "Dbl" }, { take = "d", name = "D" } }, function()
    local sel = S.K.batch_selection()
    eq(#sel.takes, 3); eq(sel.skipped, 2)
    eq(sel.takes[1].guid, "{a}"); eq(sel.takes[1].name, "A"); eq(sel.takes[1].len, 10); eq(sel.takes[1].pos, 4)
    eq(sel.takes[1].has_notes, false)
    eq(sel.takes[2].guid, "{b}"); eq(sel.takes[2].sample_rate, 44100); eq(sel.takes[2].track, "Dbl"); eq(sel.takes[2].has_notes, true)
    eq(sel.takes[3].has_notes, false, "analysed without notes: nothing to lose")
  end)
  st.session_takes["{b}"], st.session_takes["{d}"] = nil, nil
end)

test("batch_peek_is_cached", function()
  local calls = 0
  with_selection({ { take = "a" }, { take = "b" } }, function()
    local get = reaper.GetSelectedMediaItem
    reaper.GetSelectedMediaItem = function(...) calls = calls + 1; return get(...) end
    reaper.GetProjectStateChangeCount = function() return 7 end
    eq(S.K.batch_peek(10).n, 2); local first = calls
    S.K.batch_peek(10.1); eq(calls, first, "same selection, same project state, under 0.25 s: no walk")
    S.K.batch_peek(10.3); eq(calls > first, true, "walked again after 0.25 s")
    reaper.GetProjectStateChangeCount = nil
  end)
end)

test("batch_copy", function()
  local K = S.K
  eq(K.batch_label(1), "Analyze Item"); eq(K.batch_label(0), "Analyze Item")
  eq(K.batch_label(2), "Analyze All Selected Items"); eq(K.batch_label(12, true), "Analyze All")
  local a, b = K.batch_lines({ n = 1, skipped = 0, with_notes = 0, target_in = true })
  eq(a, "No data. Select an item and click Analyze."); eq(b, "Select several items in REAPER to analyze them all at once.")
  a, b = K.batch_lines({ n = 12, skipped = 0, with_notes = 0, target_in = true })
  eq(a, "12 audio items selected."); eq(b, nil)
  a, b = K.batch_lines({ n = 12, skipped = 2, with_notes = 3, target_in = false })
  eq(a, "12 audio items selected (2 other items are skipped). This item is not one of them.")
  eq(b, "3 already have notes. You will be asked before they are replaced.")
  a, b = K.batch_lines({ n = 2, skipped = 1, with_notes = 1, target_in = true })
  eq(a, "2 audio items selected (1 other item is skipped)."); eq(b, "1 already has notes. You will be asked before it is replaced.")
  eq(K.batch_tip(12), "Detect the pitch of the 12 selected audio items, one after another. One undo step for all of them.")
  eq(K.batch_undo_label(12), "Analyze Pitch (12 items)"); eq(K.batch_undo_label(1), "Analyze Pitch (1 item)")
end)

test("batch_confirm_copy", function()
  local K = S.K
  local function entries(n, with)
    local out = {}
    for i = 1, n do out[i] = { guid = "{" .. i .. "}", name = "N" .. i, track = "T", pos = i, has_notes = i <= with } end
    return out
  end
  eq(K.batch_confirm(entries(3, 0)), nil, "nothing to replace: no confirm")
  local c = K.batch_confirm(entries(12, 3))
  eq(c.title, "Analyze 12 items?"); eq(c.confirm_label, "Analyze 12 Items")
  eq(c.body_lines[1], "3 of them already have notes. Analyzing replaces their notes and any edits:")
  eq(#c.list, 3); eq(c.list[2].name, "N2"); eq(c.list[2].track, "T"); eq(c.list[2].pos, 2)
  eq(c.after_lines[1], MOD .. "+Z restores all 12 items in one step once the batch has finished.")
  eq(K.batch_confirm(entries(12, 1)).body_lines[1], "1 of them already has notes. Analyzing replaces its notes and any edits:")
  eq(K.batch_confirm(entries(12, 12)).body_lines[1], "All 12 already have notes. Analyzing replaces their notes and any edits:")
end)

test("batch_progress_by_audio_length", function()
  local K = S.K
  local b = K.batch_new({ { len = 10 }, { len = 30 }, { len = 0 } }, "{p}")
  eq(b.total_len, 40); eq(b.prev_guid, "{p}"); eq(K.batch_progress(b, 0), 0)
  b.index = 1; near(K.batch_progress(b, 0.5), 0.125, 1e-12)
  b.index, b.done_len = 2, 10; near(K.batch_progress(b, 0.5), 0.625, 1e-12)
  eq(K.batch_progress(K.batch_new({ { len = 0 } }), 0.5), 0, "no audio at all")
end)

test("batch_summary_copy", function()
  local sum = S.K.batch_summary
  eq(sum({ total = 12, written = 12, empty = 0, failed = 0 }), "Analyzed 12 items. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 1, written = 1, empty = 0, failed = 0 }), "Analyzed 1 item. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 11, empty = 1, failed = 1 }),
    "Analyzed 11 of 12 items (1 has no pitched notes). 1 could not be analyzed. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 12, empty = 2, failed = 0 }), "Analyzed 12 items (2 have no pitched notes). " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 2, empty = 0, failed = 0, cancelled = true }),
    "Batch cancelled. 2 of 12 items were analyzed and kept. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 1, empty = 0, failed = 0, cancelled = true }),
    "Batch cancelled. 1 of 12 items was analyzed and kept. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 0, empty = 0, failed = 0, cancelled = true }), "Batch cancelled. Nothing was changed.")
  eq(sum({ total = 12, written = 0, empty = 0, failed = 12 }), "None of the 12 items could be analyzed. Nothing was changed.")
end)
```

- [ ] **Step 2: Run** — expected: FAIL for each new test (the `K.batch_*` functions do not exist).
- [ ] **Step 3: Implement** the functions listed under Interfaces.
- [ ] **Step 4: Run** — `ok N tests`; `luacheck .` clean.
- [ ] **Step 5: Commit** `feat(pitch-correct): batch selection, counts and copy`

### Task 4: The queue and the single write

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: `save_take_data` (about line 2079), `K.cancel_analysis` (2277), `sync_with_project` (2348), `process_analysis_step` (4324), `loop_body` (the `process_analysis_step()` call and the selection tracker's `if not state.is_analyzing`), `loop` and `main`'s `atexit`; new functions in section 3b
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.analysis_begin` (Task 1), `K.batch_new`, `K.batch_progress`, `K.batch_undo_label`, `K.batch_summary` (Task 3).
- Produces: `K.take_json(data) -> string` (exactly what `save_take_data` stores) and `save_take_data(take, data, json)` (the third argument, when given, is stored instead of encoding again).
- Produces: `K.batch` (nil when idle) and
  - `K.batch_start(entries)`: commits a pending nudge, remembers the open item as `prev_guid`, sets `K.batch`, calls `K.batch_next()`.
  - `K.batch_next()`: moves to the next entry until one starts. An entry whose take no longer resolves (`resolve_take_by_guid(guid, true)`), whose `sample_rate` is not above 0, or whose `K.analysis_begin(take, item, { sample_rate = entry.sample_rate, defer_envelope = true })` returns false, adds 1 to `failed`. Before a start it makes the entry the open item with an empty model (`reset_analysis_model`, target GUID and name). When the queue is exhausted it calls `K.batch_finish(false)`.
  - `K.batch_item_done(take_data)`: appends `{ guid, data = take_data, json = K.take_json(take_data), empty = (#take_data.notes == 0) }` to `done`, adds the entry's `len` to `done_len`, calls `K.batch_next()`.
  - `K.batch_item_failed(err)`: releases the analysis, logs `err` to the console when given, adds 1 to `failed`, calls `K.batch_next()`.
  - `K.batch_write(done) -> written` (list of the `done` entries written): resolves every take first; with none left it opens no undo block and returns `{}`. Otherwise, inside ONE `Undo_BeginBlock` / `Undo_EndBlock(K.batch_undo_label(#written), -1)`: for each take `ensure_take_pitch_envelope(take, item, true)`, delete the envelope's points across the item and sort, `save_take_data(take, data, json)`; then put each model into `state.session_takes` / `state.session_order` and clear its stale flags. `state.undo_open` is true only inside the block; `note_own_write()` after it.
  - `K.batch_finish(cancelled)`: clears `K.batch`, releases the analysis, writes, opens the first written item (`adopt_take_data`), or else puts the previous item back as it was; posts `K.batch_summary` through `K.status_hold` (Task 5; until then `set_status`); sets `state.last_seen_sel_guid` to the first selected audio take's GUID so the tracker does not switch items; forces a resync when the project changed meanwhile.
  - `K.analysis_tick()`: what `loop_body` calls instead of `process_analysis_step()`. Without a batch it is `process_analysis_step()`. With one it runs it inside `xpcall` and turns an error into `K.batch_item_failed(err)`.
  - `K.analysis_progress() -> number`: `K.batch_progress(K.batch, state.progress)` during a batch, else `state.progress`.
- Changed: the completion branch of `process_analysis_step` builds `take_data` as today and then calls `K.batch_item_done(take_data)` when `K.batch` is set, in place of storing it and calling `apply_envelope_to_take`.
- Changed: `K.cancel_analysis()` with a batch running calls `K.batch_finish(true)` and returns true. `sync_with_project` and the selection tracker also stand still while `K.batch` is set. `atexit` finishes a running batch (`pcall(K.batch_finish, true)`) before releasing.

- [ ] **Step 1: Write the failing tests**

```lua
-- A batch with the analysis itself and the write replaced by recorders. fn(rec) runs with takes "a".."c" selected.
local function with_batch(fn)
  local K, st = S.K, S.state
  local saved = { K.analysis_begin, K.batch_write, st.target_take_guid, st.target_take_name }
  local rec = { begun = {}, writes = {} }
  K.analysis_begin = function(take, _, opts)
    rec.begun[#rec.begun + 1] = { take = take, sr = opts and opts.sample_rate, defer = opts and opts.defer_envelope }
    if rec.refuse and rec.refuse[take] then return false, "accessor" end
    st.is_analyzing = true
    return true
  end
  K.batch_write = function(done) rec.writes[#rec.writes + 1] = done; return done end
  reaper.GetMediaItemTakeByGUID = function(_, guid) if rec.gone and rec.gone[guid] then return nil end return (guid:gsub("[{}]", "")) end
  reaper.GetMediaItemTake_Item = function(take) return "item_" .. take end
  local ok, err = pcall(fn, rec)
  K.analysis_begin, K.batch_write, st.target_take_guid, st.target_take_name = table.unpack(saved, 1, 4)
  K.batch, st.is_analyzing = nil, false
  st.status.text, st.status.hold = "", nil
  reaper.GetMediaItemTakeByGUID, reaper.GetMediaItemTake_Item = nil, nil
  K.drop_project_cache()
  if not ok then error(err, 0) end
end
local function entries3()
  local out = {}
  for i, id in ipairs({ "a", "b", "c" }) do
    out[i] = { guid = "{" .. id .. "}", take = id, item = "item_" .. id, name = id:upper(), len = 10, sample_rate = 48000, has_notes = false }
  end
  return out
end
local function model(guid, notes) return { guid = guid, name = guid, results = { {} }, notes = notes or { { frames = {} } } } end

test("batch_runs_queue_in_order", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3())
  eq(#rec.begun, 1); eq(rec.begun[1].take, "a"); eq(rec.begun[1].sr, 48000); eq(rec.begun[1].defer, true)
  eq(S.state.target_take_guid, "{a}", "the canvas follows the item in progress")
  K.batch_item_done(model("{a}")); K.batch_item_done(model("{b}")); eq(#rec.writes, 0, "nothing is written while it runs")
  near(K.analysis_progress(), 20 / 30, 1e-12)
  K.batch_item_done(model("{c}"))
  eq(#rec.writes, 1, "one write"); eq(#rec.writes[1], 3)
  eq(rec.writes[1][1].guid, "{a}"); eq(rec.writes[1][3].guid, "{c}"); eq(type(rec.writes[1][1].json), "string")
  eq(K.batch, nil); eq(S.state.is_analyzing, false)
  eq(S.state.status.text, "Analyzed 3 items. " .. MOD .. "+Z to undo.")
end) end)

test("batch_skips_missing_and_offline", function() with_batch(function(rec)
  local K = S.K
  rec.gone = { ["{a}"] = true }
  local e = entries3(); e[2].sample_rate = 0
  K.batch_start(e)
  eq(#rec.begun, 1); eq(rec.begun[1].take, "c", "the deleted and the offline item never start")
  K.batch_item_done(model("{c}"))
  eq(S.state.status.text, "Analyzed 1 of 3 items. 2 could not be analyzed. " .. MOD .. "+Z to undo.")
end) end)

test("batch_uses_rates_from_the_click", function() with_batch(function(rec)
  reaper.GetMediaSourceSampleRate = function() return 0 end   -- REAPER went to the background
  S.K.batch_start(entries3()); S.K.batch_item_done(model("{a}"))
  reaper.GetMediaSourceSampleRate = nil
  eq(rec.begun[2].take, "b"); eq(rec.begun[2].sr, 48000)
end) end)

test("batch_item_failure_carries_on", function() with_batch(function(rec)
  local K = S.K
  rec.refuse = { b = true }
  K.batch_start(entries3()); K.batch_item_done(model("{a}"))
  eq(rec.begun[#rec.begun].take, "c", "b was refused, c is running")
  K.batch_item_failed(nil)
  eq(#rec.writes, 1); eq(#rec.writes[1], 1)
  eq(S.state.status.text, "Analyzed 1 of 3 items. 2 could not be analyzed. " .. MOD .. "+Z to undo.")
end) end)

test("batch_counts_items_without_notes", function() with_batch(function()
  local K = S.K
  K.batch_start(entries3())
  K.batch_item_done(model("{a}", {})); K.batch_item_done(model("{b}")); K.batch_item_done(model("{c}"))
  eq(S.state.status.text, "Analyzed 3 items (1 has no pitched notes). " .. MOD .. "+Z to undo.")
end) end)

test("batch_cancel_keeps_finished", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3()); K.batch_item_done(model("{a}"))
  eq(K.cancel_analysis(), true)
  eq(#rec.writes, 1); eq(#rec.writes[1], 1); eq(K.batch, nil); eq(S.state.is_analyzing, false)
  eq(S.state.status.text, "Batch cancelled. 1 of 3 items was analyzed and kept. " .. MOD .. "+Z to undo.")
end) end)

test("batch_cancel_before_any_item", function() with_batch(function(rec)
  local K, st = S.K, S.state
  st.target_take_guid, st.target_take_name = "{prev}", "Prev"
  K.batch_start(entries3())
  K.cancel_analysis()
  eq(#rec.writes == 0 or #rec.writes[1] == 0, true, "nothing to write")
  eq(st.target_take_guid, "{prev}", "the item that was open comes back")
  eq(st.status.text, "Batch cancelled. Nothing was changed.")
end) end)

test("batch_queue_is_frozen", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3())
  reaper.CountSelectedMediaItems = function() return 0 end   -- the user deselects everything
  K.batch_item_done(model("{a}")); K.batch_item_done(model("{b}"))
  reaper.CountSelectedMediaItems = nil
  eq(rec.begun[3].take, "c")
end) end)

test("batch_tick_turns_an_error_into_a_failed_item", function() with_batch(function(rec)
  local K, st = S.K, S.state
  local saved_msg = reaper.ShowConsoleMsg
  reaper.ShowConsoleMsg = function() end
  K.batch_start(entries3())
  st.is_analyzing, st.analysis_params = true, setmetatable({}, { __index = function() error("bad frame") end })
  K.analysis_tick()
  reaper.ShowConsoleMsg = saved_msg
  eq(rec.begun[#rec.begun].take, "b", "the batch moved on"); eq(K.batch.failed, 1)
end) end)

local function with_write_stubs(gone, fn)
  local st = S.state
  local rec = { begin = 0, labels = {}, stored = {} }
  reaper.Undo_BeginBlock = function() rec.begin = rec.begin + 1 end
  reaper.Undo_EndBlock = function(label) rec.labels[#rec.labels + 1] = label end
  reaper.GetMediaItemTakeByGUID = function(_, guid) if gone[guid] then return nil end return (guid:gsub("[{}]", "")) end
  reaper.GetMediaItemTake_Item = function(take) return "item_" .. take end
  reaper.GetTakeEnvelopeByName = function() return nil end
  reaper.NamedCommandLookup = function() return 0 end
  reaper.CountSelectedMediaItems = function() return 0 end
  reaper.GetSetMediaItemTakeInfo_String = function(take, key, value, set)
    if key == "GUID" then return true, "{" .. take .. "}" end
    if set then rec.stored[take] = value end
    return true, rec.stored[take] or ""
  end
  local order = #st.session_order
  local ok, err = pcall(fn, rec)
  for _, name in ipairs({ "Undo_BeginBlock", "Undo_EndBlock", "GetMediaItemTakeByGUID", "GetMediaItemTake_Item",
    "GetTakeEnvelopeByName", "NamedCommandLookup", "CountSelectedMediaItems", "GetSetMediaItemTakeInfo_String" }) do reaper[name] = nil end
  for _, g in ipairs({ "{a}", "{b}" }) do st.session_takes[g], st.raw_cache[g] = nil, nil end
  while #st.session_order > order do table.remove(st.session_order) end
  S.K.drop_project_cache()
  if not ok then error(err, 0) end
end
local function done2()
  local out = {}
  for i, g in ipairs({ "{a}", "{b}" }) do
    local data = { guid = g, name = g, results = {}, notes = {}, item_len = 1, sample_rate = 48000 }
    out[i] = { guid = g, data = data, json = S.K.take_json(data), empty = true }
  end
  return out
end

test("batch_write_is_one_undo_block", function() with_write_stubs({}, function(rec)
  local done = done2()
  local written = S.K.batch_write(done)
  eq(#written, 2); eq(rec.begin, 1, "one undo block"); eq(#rec.labels, 1); eq(rec.labels[1], "Analyze Pitch (2 items)")
  eq(rec.stored.a, done[1].json); eq(rec.stored.b, done[2].json)
  eq(S.state.session_takes["{a}"], done[1].data); eq(S.state.undo_open, false)
end) end)

test("batch_write_skips_gone_takes", function()
  with_write_stubs({ ["{a}"] = true }, function(rec)
    local written = S.K.batch_write(done2())
    eq(#written, 1); eq(written[1].guid, "{b}"); eq(rec.labels[1], "Analyze Pitch (1 item)")
  end)
  with_write_stubs({ ["{a}"] = true, ["{b}"] = true }, function(rec)
    eq(#S.K.batch_write(done2()), 0); eq(rec.begin, 0, "nothing to write: no undo point")
  end)
end)

test("take_json_is_what_save_writes", function() with_write_stubs({}, function(rec)
  local data = { guid = "{a}", name = "A", results = { { time = 0, note = 60 } }, item_len = 2, sample_rate = 48000,
    notes = { { start_time = 0, end_time = 1, avg_note = 60, display_note = 60, controls = { center_pitch = 60 }, frames = { 1 } } } }
  S.K.batch_write({ { guid = "{a}", data = data, json = S.K.take_json(data) } })
  local direct = rec.stored.a
  rec.stored.a = nil
  S.K.batch_write({ { guid = "{a}", data = data } })   -- no json given: encoded at the write
  eq(rec.stored.a, direct)
end) end)
```

- [ ] **Step 2: Run** — expected: FAIL for each new test.
- [ ] **Step 3: Implement** the Interfaces above. `K.batch_write` treats a missing `json` as "encode now". The batch's `xpcall` handler is `debug.traceback`, and the console line starts `Fancy Pitch Correct: an item could not be analyzed: `.
- [ ] **Step 4: Run** — `ok N tests`; `luacheck .` clean.
- [ ] **Step 5: Commit** `feat(pitch-correct): batch queue with one write at the end`

### Task 5: The interface

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`: `set_status` / `request_confirm` (about 536–557), `draw_graph`'s empty canvas (5725–5771), `K.INFO` "Icons" row (8491), `K.draw_items_body` rows (8600–8730), `draw_confirm_modal` (9602), top bar constants and `hdr_draw_more` (10095–10437), `K.status_line` (10819), `loop_body`
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: everything from Tasks 3 and 4.
- Produces: `K.status_hold(msg)`: shows `msg` on the status pill until `K.status_release()` (it sets `state.status.hold = true` and an `until_time` of `math.huge`). `set_status` clears the hold. `K.status_release()` clears a held message and does nothing otherwise. `loop_body` calls `K.status_release()` on the first mouse click or wheel move over the window, typed character, or press of Esc, Enter, Space, Delete, Backspace, Tab or an arrow key; `K.batch_finish` posts through `K.status_hold`.
- Produces: `request_confirm(req)` also carries `req.list` (rows `{ name, track, pos }`) and `req.after_lines` into `state.confirm`; `draw_confirm_modal` draws the list between `body_lines` and `after_lines`.
- Produces: `K.batch_request()`: what the canvas button (with 2 or more) and the menu entry call. `K.batch_selection()` afresh; no takes → `set_status("Select an audio item first")`; `K.batch_confirm(takes)` non-nil → `request_confirm` with id `batch`, `on_confirm = K.batch_start(takes)`; else `K.batch_start(takes)`.

**What is drawn (see the design's wireframes, State inventory and Copy deck for every string):**
- **Empty canvas.** `peek = K.batch_peek(reaper.time_precise())`. Label `K.batch_label(peek.n, narrow)` under the stable ID `cv_analyze`; `narrow` when the full label's button is wider than the canvas minus `L.sm` on each side. Enabled when a batch can run (`peek.n >= 2`) or the open item can be analysed, and no analysis runs. Click: `K.batch_request()` for `peek.n >= 2`, else `start_analysis()`. Tooltip: `K.batch_tip(peek.n)` for a batch, the existing strings otherwise. Under the button, `K.batch_lines(peek)`: each line word-wrapped to the canvas width minus `L.sm` on each side and centred, `L.lg` below the button, `L.xs` between lines; lines are dropped from the last one up while the block is taller than the canvas. Colour: `P.text_dim` when it reaches 4.5:1 on the canvas surface in both theme modes, else `P.text` (measure with `ds-lint.py --contrast` or by hand and record the numbers in the commit message).
- **"…" menu.** After Analyze / Re-Analyze: `Analyze Selected Items (N)###more_batch` when `peek.n >= 2` and nothing runs; otherwise `Analyze Selected Items###more_batch` disabled, with `Select 2 or more audio items` or (while analysing) `Wait for the analysis to finish` in the shortcut column. While a batch runs the first entry reads `Cancel Batch NN%###more_analyze` with the tooltip `Stops the batch. Items already finished are kept.` (for-tooltip hover check). `NN` everywhere = `math.floor(K.analysis_progress() * 100)`.
- **"…" button.** Label from `K.analysis_progress()`; tooltip during a batch `Analyzing 3 of 12. Open to cancel`. `HDR_MORE_TIP` and the Help "Icons" row gain `Analyze Selected Items` after `Analyze`.
- **Status pill.** `K.status_line` during a batch: `Analyzing 3 of 12: <name>… 42%`.
- **Confirm list.** A child region with borders on the `P.well` surface, between the body and the after lines, as tall as the room left above the after lines and the button row (at least three text lines). Rows through a list clipper (the pattern of `K.draw_items_body`, with its own clipper attached to `ctx`): the name in `P.text`, shortened with the script's `fit_text` and its full text in a for-tooltip hover; then `track · position` in `P.text_dim`, where position is `reaper.format_timestr_pos(pos, "", -1)`; the track and position are dropped first when the row is too narrow for both.
- **Pitched Items.** While `state.is_analyzing` or `K.batch`: each row's checkbox, name and Remove button are inside `BeginDisabled`; the row's tooltip (for-tooltip hover with allow-when-disabled) reads `Wait for the analysis to finish`.

- [ ] **Step 1: Write the failing tests**

```lua
test("status_hold_stays_until_released", function()
  local K, st = S.K, S.state
  local now = 100
  reaper.time_precise = function() return now end
  st.frame.take, st.target_take_name = nil, nil
  K.status_hold("Analyzed 12 items.")
  now = 10000
  eq(K.status_line(false), "Analyzed 12 items.", "still there long after the usual four seconds")
  K.status_release()
  eq(K.status_line(false) ~= "Analyzed 12 items.", true, "gone after the next input")
  st.status.text, st.status.until_time, st.status.hold = "plain", now + 4, nil
  K.status_release()
  eq(st.status.text, "plain", "releasing does not touch an ordinary message")
  reaper.time_precise = nil
  st.status.text = ""
end)

test("batch_status_line", function()
  local K, st = S.K, S.state
  reaper.time_precise = function() return 0 end
  st.status.text, st.status.hold = "", nil
  K.batch = K.batch_new({ { len = 10, name = "A" }, { len = 30, name = "V Main Verse 3" } })
  K.batch.index, K.batch.done_len, st.is_analyzing, st.progress = 2, 10, true, 0.5
  eq(K.status_line(false), "Analyzing 2 of 2: V Main Verse 3… 62%")
  K.batch, st.is_analyzing, st.progress = nil, false, 0
  reaper.time_precise = nil
end)

test("confirm_carries_the_list", function()
  local st = S.state
  local req = S.K.batch_confirm({ { guid = "{a}", name = "A", track = "Vox", pos = 1, has_notes = true }, { guid = "{b}", name = "B", has_notes = false } })
  req.id, req.on_confirm = "batch", function() end
  S.request_confirm(req)
  eq(st.confirm.id, "batch"); eq(#st.confirm.list, 1); eq(st.confirm.list[1].name, "A")
  eq(st.confirm.after_lines[1], MOD .. "+Z restores all 2 items in one step once the batch has finished.")
  st.confirm = nil
end)
```

(`request_confirm` is added to the table the script returns under `FANCY_PITCH_TEST`.)

- [ ] **Step 2: Run** — expected: FAIL for the three tests.
- [ ] **Step 3: Implement** the Interfaces and "What is drawn". Check every ReaImGui name used (`ImGui_GetInputQueueCharacter`, `ImGui_BeginChild` and its flags, `ImGui_ListClipper_*`, `ImGui_GetMouseWheel`) against the names file first.
- [ ] **Step 4: Run** — `ok N tests`; `luacheck .` clean.
- [ ] **Step 5: Commit** `feat(pitch-correct): Analyze All Selected Items in the window`

### Task 6: Version, changelog, real REAPER

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (header: `@version 2.21.0`, `@changelog`), `CHANGELOG.md` (a new entry at the top of "Unreleased", in the style of the v2.20.0 entry: what the user sees, in plain words, including "Re-Analyze reads the true pitch of an item that has corrections")
- No test file change.

- [ ] **Step 1:** Bump the version and write both changelog texts. The developer switch gets one line in `CHANGELOG.md` and none in the window.
- [ ] **Step 2:** `lua docs/superpowers/tests/pitch_correct_spec.lua` and `luacheck .` — both clean.
- [ ] **Step 3: Real REAPER**, following `.agents/skills/reaper-screenshot/references/testing-protocol.md` and the memory note on testing limits (REAPER frontmost before anything that reads media; note edit cursor, selection and undo label first; undo a counted number of own steps). Check and capture:
  1. Empty canvas with one item selected: "Analyze Item" and both lines. With several selected: "Analyze All Selected Items", the count line, the "already have notes" line.
  2. "…" menu: the entry enabled with a count for 2 or more, disabled with its reason for fewer.
  3. A batch over several items of which some are analysed: the confirm lists exactly those, with track and position; Cancel starts nothing.
  4. The batch runs: percent on "…", "N of M" on the pill, Pitched Items read-only; it ends on the first item with the closing message, which stays until a click.
  5. One Cmd+Z restores every item (notes back in the window, REAPER's undo label "Analyze Pitch (N items)" gone from the top of the history); redo brings the batch back.
  6. Cancel mid-batch keeps the finished items as one undo step and says so.
  7. Re-Analyze of an item with corrections reads the same notes as the analysis before the edits (compare a note's sung pitch before and after, to under 0.05 st).
  8. The developer switch: with `pitch_dev_dump` set to a scratch folder a batch writes one file per item whose header and rows parse with `diag_parse`; with it empty nothing is written. Put the ExtState back to empty.
  9. Both theme modes for the empty canvas and the confirm.
  Put back everything changed (undo own steps, selection, edit cursor, theme mode, ExtState) and say plainly what could not be checked (narrow docker and short strip cannot be resized through the bridge).
- [ ] **Step 4: Commit** `chore(pitch-correct): v2.21.0, Analyze All Selected Items`
- [ ] **Step 5:** A fresh reviewer reads the branch diff against the design and this plan; fix what it finds. Then stop and ask before merging or pushing.
