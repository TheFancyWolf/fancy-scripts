# Fancy Pitch Correct: note tone while dragging

Status: Approved by the user on 2026-11-18 (with the toggle moved to the top bar's More menu)
Date: 2026-11-18
Target file: `Pitch/Fancy_Pitch Correct.lua` (v2.6.1 → v2.7.0)

## Intent

While a note is dragged up or down, a sine tone sounds at the pitch the note is on, so the note can be
placed by ear as well as by eye. Today the script is silent until the drag is released.

## Goals

- A steady sine tone that follows the grabbed note for the whole pitch drag, gliding in cents exactly as
  the note does (including Cmd/Ctrl fine adjust).
- Silent the moment the mouse is released, the window closes, the script ends or a frame fails.
- One on/off setting, remembered between sessions.
- Nothing extra to install: the sound comes from a generator REAPER ships with.

## Non-goals

- Hearing the sung note itself shifted ("Voice" mode). Considered and set aside; may come later as a second
  option of the same setting.
- A tone on arrow-key nudges, Snap, Quantize, or on a plain click that selects a note.
- A tone on Stability / Vibrato drags, on Shift drags (transition, onset ramp, scoop) or on edge trims:
  none of them change the note's pitch.
- A volume control (a fixed level for now; see "Left to the builder").

## Anti-goals

- A tone that keeps sounding after the drag ends, under any exit path.
- Anything that touches the project: no track, no track or take FX, no item, no undo point, no transport
  change, no "project modified" flag.
- A new required extension. The script still needs only REAPER 7.0+ and ReaImGui.

## Constraints

- ReaScript cannot synthesise audio itself; something REAPER already runs has to make the sound.
- REAPER ships a stock sine generator, `JS: Tone Generator` (`Effects/synthesis/tonegenerator`): Wet Mix
  (dB), Dry Mix (dB), Base Frequency (Hz), Note, Octave, Fine Tune, Shape. Its phase is continuous, so
  changing the frequency while it sounds glides without clicks. A JSFX only runs inside an FX chain.
- AGENTS.md: no fabricated API (signatures checked with `reaper-dev`), nil guards, no hardcoded UI values,
  test in real REAPER.

## Approaches

1. **REAPER's Tone Generator on the Monitoring FX chain (picked).** At the start of a pitch drag the script
   adds `JS: Tone Generator` to the Monitoring FX chain (the master track's input-FX slot), sets Dry Mix to
   0 dB so everything else passes untouched, and each frame sets the pitch (through Note, Octave and Fine Tune over a fixed 440 Hz; see Builder's findings) to
   `440 * 2 ^ ((note pitch - 69) / 12)`. On release it removes the effect. The Monitoring chain is global,
   not part of the project: no undo point (the dirty flag is unverified; see Builder's findings). Nothing to install, no file to generate. Costs:
   the effect is visible in the Monitoring FX window during a drag; it is heard after the master, so it is
   not affected by track or master FX, but it passes through the user's own Monitoring FX (see Builder's findings); if REAPER itself dies mid-drag the effect could be left behind (the
   script removes any leftover the next time it starts).
2. **SWS preview player looping a generated sine file.** Clean, never touches any FX chain, has built-in
   fades. Costs: SWS becomes an optional requirement and a generated WAV file has to live on disk. The
   first draft of this design; replaced at the user's request to use REAPER's own generator.
3. **Tone Generator on a track in the project.** Same sound, but adds a track or track FX, makes an undo
   point and marks the project modified. Rejected by the anti-goals.
4. **MIDI to the virtual keyboard (`StuffMIDIMessage`).** Needs an armed instrument track, plays semitones
   only, can be recorded by accident. Rejected.

Picked by the user on 2026-11-18: a sine tone, from REAPER's own generator (approach 1).

## Design

Decided by the user: a sine tone on pitch drags, made by REAPER's built-in generator.

My calls (correct any of them):

- **Which note.** With several notes dragged together, the tone follows the note that was grabbed.
- **When it starts.** Once the pointer leaves the 2 px click dead zone, so a click that only selects stays
  silent. It stops on mouse release.
- **Pitch.** The note's target pitch (`controls.center_pitch`), read every frame, clamped like the note
  and to the floor of A0 (MIDI 21; see Builder's findings).
- **Level and shape.** Sine, about -18 dB. The Wet Mix is ramped up over the first few frames and down
  before removal so the start and stop do not click.
- **Setting.** Decided by the user: the on/off toggle lives in the top bar's "…" (More) menu, not in
  Settings. A checkable "Note Tone" item between Layers and Settings (placement within the menu is my
  call), on by default, stored like the other settings (ExtState `pitch_note_tone`).
- **Cleanup.** One idempotent function finds the script's Tone Generator on the Monitoring chain and
  removes it. Called from: mouse release, `clear_interaction_state`, the frame error handler, window close,
  `atexit`, and once at startup (a leftover from a crash). The script recognises its own instance by a
  name it gives it (e.g. "Fancy Pitch Correct Tone"), so a Tone Generator the user put there is never
  touched.
- **Failure.** If the effect cannot be added (the stock JSFX is missing), the tone is skipped, a status
  message says so once, and dragging is unaffected.

## Left to the builder

- Add-per-drag versus keeping one bypassed instance while the window is open: pick whichever starts
  without an audible delay in real REAPER. (Added per drag; only the add time, about 3 ms, was measured, not whether any delay is audible; see Builder's findings.)
- Verify the Monitoring FX addressing (`TrackFX_AddByName` with `recFX`, index offset `0x1000000` on the
  master track) and `TrackFX_SetNamedConfigParm(..., "renamed_name", ...)` with `reaper-dev` before use. (Resolved: the real-REAPER tests a-h used both; see Builder's findings.)
- Confirm in real REAPER that adding and removing a Monitoring FX makes no undo point and does not mark
  the project modified. If it does, stop and report. (Done for undo; dirty flag not checked, see Builder's findings.)
- `docs/design/pitch-correct.md` gains the More menu item; `CHANGELOG.md` gains the entry.

## Verification

- `luacheck .` clean.
- Real REAPER: drag a note, confirm the Tone Generator is on the Monitoring chain and its frequency
  tracks the note, confirm it is gone after release, after closing the window mid-drag, and with the setting off. Audible quality
  (level, glide smoothness) has to be judged by the user: the test rig cannot hear.

## Builder's findings

- Pitch is set through the generator's Note / Octave / Fine Tune sliders over a fixed 440 Hz, because its Base Frequency slider is quantised to 1 Hz. So the glide moves in 1-cent steps and the floor is A0 (MIDI 21), not 20 Hz.
- The effect is added per drag (about 3 ms) rather than kept bypassed on the chain.
- Adding and removing a Monitoring FX left the project state count and the undo history unchanged in real REAPER. The "project modified" flag could not be checked, because the test project was already modified.
- Real-REAPER tests a-h passed on 2026-11-18. These are the checks listed in Task 4 of `docs/superpowers/plans/2026-11-18-pitch-correct-drag-tone.md`: (a) the tone follows the note, (b) it stops after release, (c) the user's own Tone Generator is left alone, (d) closing mid-drag, a click only, and other zones, (e) a leftover tagged instance is removed at start, (f) the pitch range floor, (g) the Note Tone toggle, (h) a screenshot of the More menu.
- The generator is inserted first in the Monitoring chain, so the tone obeys the user's own Monitoring FX (monitor trim, dim, correction). The cost: the user's other Monitoring FX shift one index during a drag.
- On release the tone fades over about three frames rather than cutting at once, to avoid a click.
- The tone only sounds while the mouse button is physically down; if the window is hidden mid-drag and the button is released, the tone stops.
- Not yet judged by ear: whether the generator's own defaults (Wet -12 dB, Dry -6 dB) are ever heard in the instant between adding it and silencing it, and whether the three-step level ramp is smooth. If either is audible, the fallback is one silent instance kept for the session.
- Not exercised in real REAPER: the missing-JSFX path and the top of the range (MIDI 127).
- How the tone sounds (level, glide, any click at the start) has not been judged by ear.
