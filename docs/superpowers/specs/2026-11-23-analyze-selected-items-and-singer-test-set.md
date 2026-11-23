# Analyze All Selected Items, and the singer test set (brief for a new session)

Date: 2026-11-23. Status: agreed in conversation with the user; the interface layout is **not** designed yet.

This brief carries two things into a new session: the feature to build first (Part A) and the plan it serves (Part B). The interface part of Part A must go through the `reaimgui-ux-design` skill, which writes `docs/design/pitch-correct-analyze-selected.md` and stops for the user's approval before any code (AGENTS.md routing). Everything under "Decided" below is the user's decision and is not reopened there.

## Part A: Analyze All Selected Items

### Why

The user wants to analyse many items in one go, as a feature in its own right and so that a test set of many singers can be analysed without anyone clicking through items one at a time. The user runs it; the assistant then reads the results from the saved project.

### Decided (the user, 2026-11-23)

- **Which items:** the items selected in REAPER's arrange view, audio only. Anything that is not audio is skipped.
- **Existing data:** ask once before starting when any of the selected items already has an analysis that would be replaced, naming how many.
- **Undo:** one undo step for the whole batch.
- **Where it starts:** where the "Analyze Item" button is today (the empty canvas of `draw_graph`, about line 5600 of `Pitch/Fancy_Pitch Correct.lua`). With several items selected the button reads **"Analyze All Selected Items"**.
- **Discoverability:** with one item selected, a note under the button says that several items can be analysed at once.

### Facts about today's code that the design has to work with

- **The button only shows on an empty canvas** (the active item has no analysis). Once the active item has notes, Analyze lives in the "…" menu of the top bar as "Re-Analyze". The batch needs an entry there too, or it cannot be reached from an analysed item.
- **The target is not REAPER's selection.** `get_target_take` prefers the item chosen in the Pitched Items list and falls back to the first selected item only when there is no target. The batch must read the arrange selection itself (`CountSelectedMediaItems`, active take, `TakeIsMIDI`).
- **An analysis runs in slices across frames** (`start_analysis`, `process_analysis_step`, `K.ANALYSIS_SLICE_S`), with one audio accessor and one buffer in `state`. A batch is a queue of takes run one after another.
- **Each analysis ends by writing its own undo step** (`apply_envelope_to_take("Analyze Pitch", true)`), and no undo block can stay open between frames. For one undo step per batch, the finished models have to be held in memory and written together in a single block when the batch ends.
- **Cancel** (`K.cancel_analysis`) puts the previous model back for the one item being analysed.
- **Progress** is shown as a percentage in the "…" button and in the status line.
- **Constraint:** no new chunk-level `local` in the script (it is near Lua's 200-local limit); new functions and tables go on `K`.

### Open questions for the user (ask in the design's one checkpoint message)

1. **Cancel mid-batch.** Recommended: Cancel stops the item being analysed and keeps the items already finished, written as the one undo step. The alternative is all or nothing.
2. **The "…" menu entry** when the active item already has notes: recommended "Analyze Selected Items (N)" under "Re-Analyze", shown only when two or more audio items are selected.
3. **Which item is shown when the batch ends:** recommended the first item of the batch.
4. **An item that fails or has no pitched notes:** recommended to carry on with the rest and name the count in the closing status line.

### Must be fixed with it: Re-Analyze reads the corrected audio

Found 2026-11-23 in real REAPER: the take audio accessor returns audio with the take's Pitch envelope applied, so an item that has corrections is analysed as corrected (a note quantized by −0.59 st read 0.59 st low; a second Analyze, after the first had cleared the envelope, read it right). A batch over items with edits would bake this in for every one of them. Fix it as part of this work or before it: confirm the cause first, then make every analysis read the uncorrected audio, with the envelope left exactly as it was on Cancel or error.

### The developer switch (no interface)

So that a change to the detector can be re-judged in seconds without analysing the audio again:

- **ExtState** `FancyScripts` / `pitch_dev_dump`: a folder path, empty by default. No button, no setting in the window.
- **When set,** every analysis also writes one text file per item into that folder, named from the take's name and GUID.
- **Contents:** a header line with sample rate, block, hop, threshold, minimum and maximum frequency; then one line per frame with the frame time, RMS, short level, and every candidate as `tau:d` (the list `yin_process_block` returns, before `K.pitch_track` removes it).
- **The format matches the recordings of 2026-11-23** in `~/.fancy-scripts-fixtures/detector-diag-2026-11-23/` closely enough that `diag_frames` in `docs/superpowers/tests/pitch_correct_spec.lua` can read both.

### Done looks like

- An approved `docs/design/pitch-correct-analyze-selected.md`, then the feature built from it.
- Tests first for everything that can be tested in plain Lua (which items qualify, the queue, the single write at the end, the dump format); `lua docs/superpowers/tests/pitch_correct_spec.lua` and `luacheck .` clean.
- Checked in real REAPER following `.agents/skills/reaper-screenshot/references/testing-protocol.md`: several items analysed in one batch, one undo step restores all of them, the ask-once dialog names the right count, Cancel behaves as decided.
- Version bump and `CHANGELOG.md` entry in the repo's style. Nothing merged or pushed without asking.

## Part B: the singer test set and the next detector round

### The loop (agreed)

1. **The user builds a separate REAPER project** for testing, outside the repo.
2. **The user selects every item and runs Analyze All Selected Items**, with the developer switch on, then saves the project.
3. **The assistant reads every item's analysis from the saved project file** (each take's `fancy_pitch_data`) and adds regions named `?` over doubtful spots through the REAPER bridge.
4. **The user reviews by eye and by ear and marks what broke** with regions.
5. **Every mark becomes a stored test fact** (file, time span, what is right), kept outside the repo. After each detector change everything is re-run automatically and the user is shown only the spots whose reading changed.

No hand-written notes, MIDI or per-file range are required from the user.

### How the test project is built

- **One track, items end to end** along the timeline with a gap between them, so a region points at exactly one file and time.
- **One item per phrase, 15 to 40 seconds,** dry, one voice, unprocessed, at its original sample rate. A phrase cut from a longer file is glued so the item is its own WAV starting at zero. No stretching, no pitch or rate change, no take effects.
- **Item names carry the facts:** `voice_language_quality_source_nn`, for example `tenor_spanish_belt_raw_01`. `source` is `raw`, `studio` (a released acapella, usually processed) or `separated` (pulled out of a mix by software). Separated stems get a few slots, not most of the set.
- **Coverage:** bass or low baritone, tenor, alto, soprano; breathy, belted, falsetto, fry or rasp, heavy vibrato, straight tone, fast runs; a consonant-heavy, a vowel-heavy, a tonal and a nasal language; a few noisy or bleeding recordings on purpose.
- **Start with a pilot of 6 to 8 files.**

### Marking vocabulary (region names)

`oct low`, `oct high`, `should be B3` (any note name), `not a note`, `missed`. A mark about how notes are split rather than how pitch is read starts with `split:`.

### Approach to the detector round

- **One general detector that adapts to each item,** not modes per language or gender.
- **Range:** the default is the documented singing range, about 65 Hz to 1100 Hz (the upper limit is 1000 Hz today, just under a soprano's high C). An extended range is an option for what falls outside, and the script says so when readings pile up at an edge of the range.
- **Speed:** the low end does not work today (nothing under 93.8 Hz at block 1024 and 48 kHz). Reading it needs a longer window, so a faster difference function comes first. If the full range is too slow, optimise for most voices and switch to the extended range when an item is likely outside it.
- **Per item, automatically:** a first pass finds where the singer's notes sit, a second pass searches around that; the noise level replaces guessing the Detection setting.
- **Judging:** tune on half of the files, judge on the other half untouched. Targets are a measured error rate on the untouched half, no whole-note octave errors, and doubtful notes marked in the window for the user to fix.
- **Order:** run the current detector on everything and sort the failures by kind before changing anything; fix by kind, most frequent first.
- **Where things stand:** `docs/superpowers/specs/2026-11-23-pitch-correct-detector-design.md` (the v2.20.0 detector, its constants `K.TRACK`, its known limits).

### Rules the user has set

- **Nothing runs outside REAPER as a substitute for it.** No copy of the detector in another language, and no clicking through the window for long runs: the user triggers the batch, the assistant reads the results.
- **No backward compatibility** during active development; pitch work in test projects may be redone.
