# Pitch Correct: how the detector chooses a pitch (design)

Date: 2026-11-23. Requested by the user after the octave-error fix (v2.19.1): "detection is everything", fix the issues seen now; recordings of more singers will follow for a second round.

## Why

Every note, centre and correction is built on the detector's frames. v2.19.1 repairs octave-wrong frames after the fact (`K.octave_fix`); this change removes their cause.

## What was found (real REAPER, 2026-11-23)

A temporary diagnostic in the script recorded, for every frame of the user's two test items, every dip of the detector's difference function. The recordings are local only (`~/.fancy-scripts-fixtures/detector-diag-2026-11-23/`).

| Finding | Evidence |
|---|---|
| **Octave too high.** The detector took the first dip under the threshold, judged alone. | Chorus Error, all 40 wrong frames: dip at half the period 0.07–0.08 (threshold 0.08), dip at the true period about 0.001. With the default threshold 0.15, 219 of the note's 298 frames would be wrong (computed from the recorded dips). |
| **Octave too low.** With no dip under the threshold it took the lowest dip overall. | V Main Verse 1, 7 frames at note onsets: true-period dip 0.08–0.25, double-period dip lower by 0.01–0.10. |
| **A longer window is not the cure.** | Same items with a 2048-sample block: chorus 36 wrong frames (was 40), verse 10 (was 11), plus new readings three periods off. |
| **A value at the edge of the search range was read as a pitch.** | 93.75 Hz readings (period = 512 samples = the longest searched). |
| **Blocks that run past the item's end read a pitch of their own.** | One or two frames at each item's end, period exactly the hop (512 samples). Cause not proven. |
| **Frames were stamped with the start of their block.** | From the code: the reading belongs 7–11 ms later. A test with a rising pitch reads 206.0 Hz where the middle of the block is 208 Hz. |
| **Lowest readable pitch is 93.8 Hz** at block 1024 and 48 kHz (the range says 65 Hz). | `max_tau` is capped at half the block. Not fixed here, see Deferred. |

## Approaches

1. **Judge each dip against the deepest one, per frame.** Fixes the chorus (about 42 frames off down to 2 on the recording) but not the verse's onsets (about 31 against 32): at an onset the right and the wrong dip are equally deep, and one frame cannot tell them apart.
2. **Keep every dip as a candidate and choose the line through the frames that costs least (chosen).** Each frame pays for how much shallower its chosen dip is than its deepest, and for each octave below its shortest candidate; the line pays for every semitone it moves between frames. Fixes both kinds: by the test's own count, chorus 41 down to 1 and verse 32 down to 21, where the 21 are unchanged readings (quiet falling tails, one real high blip, the item-end junk that the whole-block rule now removes).
3. **A longer analysis window.** Refuted by the test above, and it triples the analysis time.
4. **Many thresholds at once, as in pYIN.** Not chosen: on the chorus note every threshold above 0.07 gives the half period, so it would lean the wrong way on every frame and continuity could not save it.

## What is built

- **`yin_process_block`** returns the block's candidates: the dips of the normalised difference function inside the searched range (`{ tau, d }`, the `K.TRACK.MAX_CANDS` that cost least within the block, each with its interpolated period; trimming by depth alone dropped the true period of steady notes from about A5 up, found in review). A value at the edge of the range is not a dip. Each period is measured on samples centred on the block's middle.
- **The threshold only decides whether a block has a pitch** (deepest dip at most twice the threshold, as before). It no longer decides which pitch. The Detection setting keeps its meaning.
- **`K.pitch_track(results, sample_rate)`** runs once when the last block is read. It chooses each voiced frame's candidate on the cheapest line (`K.cand_cost` per frame, `JUMP_COST` per semitone between frames), carries a line through unvoiced stretches shorter than `K.SEG.BRIDGE_S`, sets `freq` and `note`, and removes the candidates (they are not stored).
- **Frame times** are the middle of the block (`K.analysis_frame`). Only blocks that lie whole inside the item are read (`K.block_fits`), so the pitch line starts and ends half a block inside the item.
- **`K.octave_fix` stays** as a second line after the choice.

## The constants (`K.TRACK`) and how they were set

`FLOOR = 0.02`, `OCTAVE_COST = 0.7`, `JUMP_COST = 0.15`, `JUMP_CAP_ST = 12`, costs given for a frame spacing of 512/48000 s and scaled with the spacing. `OCTAVE_COST` was tried from 0.25 to 1.35 on the four recordings: 0.5 to 0.9 gives the same, best result; 1.35 picks shallow junk dips at note changes. They rest on two items by one singer and are meant to be set again when the other singers' recordings arrive.

## Known limits (found in review, not fixed)

- **A note cut at an item's start** has its first frame half a block in, so its correction ramps in over that stretch instead of holding from 0.
- **A faint fundamental under heavy noise.** With the note's own tone below the noise (a test signal with the overtone 18 dB over the tone and noise 15 dB under the sound) the block is read at the overtone. At 20 dB it is read right, where the old detector was wrong at every noise level up to there.
- **A whole note consistently in the wrong octave** would not show in the "frames off their neighbours" count used on the recordings.
- **Not tested here:** which of `K.pitch_track` and `K.octave_fix` runs first, and the jump cap.

## Not goals

- No change to the UI or the settings.
- No migration: an item analysed before keeps its frames until it is analysed again (the user's rule of 2026-11-23), and its frame times stay half a block early.

## Deferred

- **The 93.8 Hz floor.** Reading lower needs a longer search and a longer window, which costs analysis time the script does not have (30 s of audio already takes about 35 s). It belongs with a faster difference function and with low voices to test on.
- **Re-Analyze reads the audio through the take's pitch envelope** (found 2026-11-23, its own task).
- **Quiet falling tails at phrase ends** are read as low notes at Separation 50%; that is the note splitting, not the detector.

## Tests

`docs/superpowers/tests/pitch_correct_spec.lua`: `track_*` (made-up candidates: half period barely under the threshold, shaky onset, phrase start, real octave leap, glide, a doubtful frame alone and among neighbours, gaps, any hop, degenerate input), `yin_*` (plain tone, strong second harmonic, noise, the edge of the range, the middle of the block), `analysis_chooses_periods_before_splitting`, and `track_real_items` on the local recordings (prints `SKIP` without them).
