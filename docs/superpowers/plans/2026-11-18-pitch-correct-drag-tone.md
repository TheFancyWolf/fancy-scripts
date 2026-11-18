# Pitch Correct Drag Note Tone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a note is pitch-dragged in Fancy Pitch Correct, a sine tone sounds at the note's pitch, switchable from the "…" (More) menu.

**Architecture:** The script adds REAPER's stock `JS: Tone Generator` to the Monitoring FX chain (master track, `recFX = true`) when a pitch drag starts, sets its Note / Octave / Fine Tune every frame, and removes it when the drag ends. One per-frame function (`K.tone_tick`) owns start, follow, fade and removal; one immediate function (`K.tone_kill`) serves every exit path.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui, `_lib/theme.lua`. No new extension.

**Spec:** `docs/superpowers/specs/2026-11-18-pitch-correct-drag-tone-design.md`

## Global Constraints

- Target file: `Pitch/Fancy_Pitch Correct.lua`, v2.6.1 → v2.7.0. Requirements stay "REAPER 7.0+, ReaImGui".
- The project is never touched: no track, track FX, take FX, item, undo point, transport change or dirty flag.
- No test framework, mock or fake REAPER (AGENTS.md Working Rules). Tests are `luacheck .` and real REAPER through the bridge, following `.agents/skills/reaper-screenshot/references/testing-protocol.md` (sweep strays before and after every action).
- Call `reaper.*` directly, every variable `local`, nil-guard every API return, no hardcoded UI colours / sizes / spacing.
- Verify every ReaScript signature with `reaper-dev` before first use. Never edit `index.xml` or `_fancy_*.json`.
- Work on branch `feat/pitch-correct-drag-tone`. Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Do not push or open a PR unless the user asks.
- If a permission prompt fails or the bridge times out: stop and tell the user.

## Review Focus

1. **The user has their own Tone Generator on the Monitoring chain.** It must never be changed or removed: the script acts only on the instance whose `renamed_name` is `Fancy Pitch Correct Tone`. (Task 1 probe, Task 4 test c.)
2. **The window is closed, or the target item changes, in the middle of a drag.** The tone stops and the effect is gone. (Task 4 test d.)
3. **REAPER was killed mid-drag in an earlier session.** The leftover instance is removed when the script starts. (Task 4 test e.)
4. **A note dragged below A0 (MIDI 21) or to MIDI 127.** The pitch is clamped to what the generator's Octave slider reaches (MIDI 21..127); no error. (Task 2 `K.tone_params`; Task 4 test f.)
5. **The stock JSFX is missing or cannot be added.** One status message, no tone, the drag works, no retry on every frame. (Task 2; not exercised in real REAPER; by code reading only.)

---

### Task 1: Prove the Monitoring FX mechanics in real REAPER

No product code. A throwaway probe script in the session scratchpad, run in real REAPER, answers the questions the spec left to the builder. Record the answers at the bottom of this plan under "Probe results"; later tasks use them.

**Files:**
- Create (scratchpad only, never committed): `probe_tone.lua`

- [ ] **Step 1: Check signatures with `reaper-dev`**: `TrackFX_AddByName`, `TrackFX_Delete`, `TrackFX_SetParam`, `TrackFX_GetParam`, `TrackFX_GetRecCount`, `TrackFX_GetFXGUID`, `TrackFX_GetNamedConfigParm`, `TrackFX_SetNamedConfigParm`, `GetMasterTrack`, `GetProjectStateChangeCount`, `IsProjectDirty`, `Undo_CanUndo2`.

- [ ] **Step 2: Write the probe.** On `reaper.GetMasterTrack(0)`, with monitoring FX addressed as `0x1000000 + index`, it prints to the console:
  - which name `TrackFX_AddByName(master, name, true, -1)` accepts: try `"JS: Tone Generator"`, then `"JS:synthesis/tonegenerator"`; print the returned index for each (remove what was added);
  - `GetProjectStateChangeCount(0)`, `IsProjectDirty(0)` and `Undo_CanUndo2(0)` before the add, after the add, and after `TrackFX_Delete`;
  - whether `TrackFX_SetNamedConfigParm(master, fx, "renamed_name", "Fancy Pitch Correct Tone")` returns true and reads back;
  - parameter indices 0..6 by `TrackFX_GetParamName` (expected: Wet Mix, Dry Mix, Base Frequency, Note, Octave, Fine Tune, Shape) and whether `TrackFX_SetParam(master, fx, 2, 261.63)` reads back 261.63;
  - `reaper.time_precise()` around the add (the add-per-drag cost in ms);
  - the Monitoring chain count before and after: the probe must leave it as it found it.

- [ ] **Step 3: Run it in real REAPER** (reaper-screenshot skill, testing protocol). Expected: an accepted name, change count / dirty / undo identical across add and delete, rename and parameter read-backs succeed, chain count restored.

- [ ] **Step 4: Decide and record.** If the add costs more than ~15 ms, use "one instance, bypassed (`TrackFX_SetEnabled`) while the window is open, removed at exit" in Task 2 in place of add-per-drag. **If adding or deleting changes the project state count, dirty flag or undo history: stop and report to the user; do not continue.**

---

### Task 2: Tone engine

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` — constants next to `K.LIMITS` (~line 261); `state` table (~line 340); a new block after `K.release_analysis` (~line 1064).

**Interfaces:**
- Produces:
  - `K.TONE = { FX_NAME = "JS: Tone Generator", TAG = "Fancy Pitch Correct Tone", LEVEL_DB = -18, SILENT_DB = -120, RAMP_FRAMES = 3, BASE_HZ = 440, MIN_PITCH = 21, MAX_PITCH = 127, P_WET = 0, P_DRY = 1, P_FREQ = 2, P_NOTE = 3, P_OCTAVE = 4, P_FINE = 5, P_SHAPE = 6, MON = 0x1000000 }`
  - `state.note_tone` (boolean, default `true`), `state.tone` (nil, or `{ guid = string, gain = number 0..1 }`), `state.tone_failed` (boolean)
  - `K.tone_params(pitch: number) -> note: integer, octave: integer, fine: integer` — the generator's sliders are quantised to whole steps (Base Frequency to 1 Hz), so the pitch is set as Note (0..11, 0 = A), Octave (-4..4) and Fine Tune (whole cents, -50..50) over a fixed Base Frequency of `BASE_HZ`; the generator plays `BASE_HZ * 2 ^ (octave + note / 12 + fine / 1200)`. Clamp `pitch` to `MIN_PITCH..MAX_PITCH`, then `cents = round((pitch - 69) * 100)`, `semis = round(cents / 100)`, `fine = cents - semis * 100`, `octave = semis // 12`, `note = semis % 12`. Examples: 69 → 0, 0, 0; 60 → 3, -1, 0; 60.25 → 3, -1, 25; 21 → 0, -4, 0; 10 → 0, -4, 0
  - `K.tone_find(guid: string|nil) -> integer|nil` — index (with `MON` added) of the Monitoring FX whose GUID is `guid`, or, when `guid` is nil, of the first one whose `renamed_name` is `K.TONE.TAG`
  - `K.tone_tick(pitch: number|nil)` — call once per frame. With a pitch: add the effect if `state.tone` is nil (first Wet at `SILENT_DB` and Dry Mix 0 dB, straight after the add, then rename it to `TAG`, Base Frequency `BASE_HZ`, Shape 0; keep its GUID from `TrackFX_GetFXGUID`), set Note / Octave / Fine Tune from `K.tone_params(pitch)` (only the ones whose value changed since the last frame), raise `gain` by `1 / RAMP_FRAMES` up to 1. With nil: lower `gain` by `1 / RAMP_FRAMES`; at 0 delete the effect and set `state.tone = nil`. Wet Mix (dB) each frame = `LEVEL_DB + 20 * log10(gain)`, floored at `SILENT_DB`. Does nothing when `state.tone` is nil and `pitch` is nil.
  - `K.tone_kill()` — immediate, idempotent: delete the instance in `state.tone` if any, then every Monitoring FX tagged `TAG`; `state.tone = nil`. Never raises (wrap the API calls in `pcall`).

- [ ] **Step 1: Implement the constants, state fields and the four functions.** If the effect cannot be added, or `K.tone_find(state.tone.guid)` no longer finds it (the user deleted it mid-drag): set `state.tone = nil`; on an add failure also set `state.tone_failed = true` and call `set_status("Note tone unavailable: REAPER's Tone Generator effect was not found")` once. While `state.tone_failed` is true, `K.tone_tick` does not try to add again; the More menu toggle (Task 3) clears the flag.

- [ ] **Step 2: Lint.** Run: `luacheck .` — Expected: `0 warnings / 0 errors`.

- [ ] **Step 3: Commit.** `feat: Fancy Pitch Correct tone engine on the Monitoring FX chain`

---

### Task 3: Drive the tone from the drag, every exit path, and the More menu toggle

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` — `K.PERSIST` (~line 585); pitch drag in `draw_graph` (~lines 3751–3850); `clear_interaction_state` (~line 1612); `loop` error branch and the not-`open` branch (~lines 7830–7848); `main` (`atexit`, startup; ~line 7858); `hdr_draw_more` (~line 6987).

**Interfaces:**
- Consumes: `K.tone_tick`, `K.tone_kill`, `state.note_tone`, `state.tone_failed` (Task 2).

- [ ] **Step 1: Persist the setting.** In `K.PERSIST`: `flag("tone", "pitch_note_tone", state, "note_tone")`.

- [ ] **Step 2: Per-frame drive.** In `loop_body`, after the canvas is drawn, call `K.tone_tick(pitch)` exactly once per frame, where `pitch` is `state.notes[state.drag.note_idx].controls.center_pitch` when all of these hold, else `nil`: `state.note_tone`, `state.drag` exists, `state.drag.zone == "pitch"`, `state.drag.dirty`, not `state.drag.shift_mode`, and the note and its controls exist. (Release sets `state.drag = nil`, so the next frames fade the tone out and remove it.)

- [ ] **Step 3: Exit paths.** Call `K.tone_kill()` in: `clear_interaction_state`; the `loop` error branch (beside `pcall(K.cancel_analysis)`); the branch where the window closed; the `atexit` function; and once in `main` before `loop()` (removes a leftover from a crashed session).

- [ ] **Step 4: Menu item.** In `hdr_draw_more`, between the Layers submenu and Settings:

```lua
if reaper.ImGui_MenuItem(ctx, "Note Tone", nil, state.note_tone) then
  state.note_tone = not state.note_tone
  state.tone_failed = false
  K.save_settings("tone")
end
if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
  Theme.tooltip(ctx, "Play a tone at the note's pitch while you drag it")
end
```

  Update `HDR_MORE_TIP` and the Help row to `More: Analyze, Reset, Layers, Note Tone, Settings, Help`.

- [ ] **Step 5: Lint.** Run: `luacheck .` — Expected: `0 warnings / 0 errors`.

- [ ] **Step 6: Commit.** `feat: Fancy Pitch Correct note tone while dragging, with a More menu toggle`

---

### Task 4: Real REAPER verification

Follow the testing protocol. Use an analysed audio item. Read the Monitoring chain with a small console script or the bridge (count, `renamed_name`, Note / Octave / Fine Tune, Wet Mix), not by ear.

- [ ] **a. Follows the note.** Hold a pitch drag on a note: one FX tagged `Fancy Pitch Correct Tone` is on the Monitoring chain; `440 * 2 ^ (Octave + Note / 12 + Fine Tune / 1200)` read from the FX is within 1 cent of the note's `center_pitch` at two different drag positions; Wet Mix reaches -18 dB.
- [ ] **b. Stops.** After release (wait 0.5 s): no tagged FX on the chain. Undo history shows the pitch edit only; one Cmd+Z restores the note.
- [ ] **c. Leaves the user's own instance alone.** Add an untagged `JS: Tone Generator` to the Monitoring chain by hand, drag and release: the untagged one is still there with unchanged parameters. Remove it afterwards.
- [ ] **d. Closed mid-drag / click only / other zones.** Close the window while a drag is held: no tagged FX. A click without movement, a Stability drag, a Vibrato drag, a Shift drag and an edge trim never add the FX.
- [ ] **e. Leftover.** With the script closed, add a `JS: Tone Generator` renamed `Fancy Pitch Correct Tone` by hand; start the script: it is gone.
- [ ] **f. Range.** Drag a note to the bottom of the pitch range: Octave never reads below -4 and Base Frequency stays 440; no console error.
- [ ] **g. Toggle.** Untick "Note Tone" in More: a drag adds nothing. Restart the script: still unticked. Tick it: the tone is back.
- [ ] **h. Screenshot** the open More menu and attach it to the report. Sweep strays; the Monitoring chain is as it was before testing.
- [ ] **Report what could not be checked:** how the tone sounds (level, glide, start/stop clicks) needs the user's ears.

---

### Task 5: Version, changelog, design docs

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` header — `@version 2.7.0`, `@changelog` entry (keep the existing header lines intact).
- Modify: `CHANGELOG.md` — under `[Unreleased]`, first entry: Fancy Pitch Correct v2.7.0, note tone while dragging (REAPER's own Tone Generator on the Monitoring FX chain during the drag, never part of the project; pitch drags only; "Note Tone" in the "…" menu, on by default).
- Modify: `docs/design/pitch-correct.md` — More popup line and copy deck: add `Note Tone` (checkable, between Layers and Settings) and the new tooltip text.
- Modify: `docs/superpowers/specs/2026-11-18-pitch-correct-drag-tone-design.md` — builder's findings from Task 1.

- [ ] **Step 1: Make the edits.**
- [ ] **Step 2: Lint.** Run: `luacheck .` — Expected: `0 warnings / 0 errors`.
- [ ] **Step 3: Commit.** `docs: Fancy Pitch Correct v2.7.0 changelog and design notes for the note tone`

---

## Probe results

Run in real REAPER on 2026-11-18 (full output: the Task 1 report in the plan workspace).

- `TrackFX_AddByName(master, "JS: Tone Generator", true, -1)` works (so does `"JS:synthesis/tonegenerator"`); monitoring FX are addressed as `0x1000000 + index`.
- Adding, renaming, setting parameters and deleting leave `GetProjectStateChangeCount` and the undo history unchanged. The dirty flag did not flip either, but the project was already modified, so that one was not rechecked on a clean project in Task 4 (the project was still modified).
- Add takes about 2.8 ms (max 3.4), delete 0.05 ms: **add per drag**.
- `renamed_name` sets and reads back; a never-renamed FX reads back an empty string. `TrackFX_GetFXGUID` works on monitoring indices and is stable.
- Parameters take native units (dB, Hz) and are **quantised to the slider step**: Base Frequency 261.63 reads back 262. Hence Note / Octave / Fine Tune over a fixed 440 Hz (Task 2).
- The effect is born with Wet -12 dB and Dry -6 dB; the script sets Wet -120 / Dry 0 immediately after the add. Whether that instant is ever audible needs the user's ears.
