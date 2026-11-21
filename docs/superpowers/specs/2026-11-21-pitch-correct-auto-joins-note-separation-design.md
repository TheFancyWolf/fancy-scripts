# Fancy Pitch Correct: automatic joins and better note separation

Status: Design choices made by the user on 2026-11-21 (approach 1; keep edits on a re-split)
Date: 2026-11-21
Target file: `Pitch/Fancy_Pitch Correct.lua` (v2.15.0 → v2.16.0)

## Intent

Tighten and Tolerance are the values that actually shape the sound. The four timing values (Transition,
Onset Ramp, Scoop Shape, Legato Gap) come from the older "shift the whole note, then smooth the joins" model;
the user does not find them useful. Separately, the analysis joins notes that are clearly separate but close
together, and no setting changes that (Legato Gap is only read when the correction curve is built, never by
the analysis).

The goal is the most natural sound with the least work: the analysis finds the right notes, the joins between
notes follow what was sung, and the user is left with a small set of values that each do something audible.

## Goals

- Notes that are separate but close together are found as separate notes: a sung slide between two pitches,
  and a re-articulation on the same pitch.
- Joins between notes need no settings: the correction blends across the slide the singer actually sang.
- One analysis control, "Separation" (fewer ↔ more notes), that visibly changes the notes found.
- Fewer values on screen: Tighten, Strength, Tolerance, Slide In, Separation.

## Non-goals

- Changing the pitch detection (YIN, quality modes, vocal range).
- Changing what Tighten, Tolerance or Strength do.
- Backwards compatibility. The script is in active development: stored Transition / Onset Ramp / Legato Gap
  values, stored `scoop_shape` values and their ExtState keys are simply dropped, with no migration.

## Anti-goals

- Vibrato splitting a held note into several notes at the default Separation.
- A held note breaking into fragments because one or two frames lost their pitch.
- A step (click or zipper) in the pitch envelope at any join.
- Ending up with as many, or more, values than today.

## Constraints

- Single file, REAPER 7.0+ and ReaImGui only, as today.
- `run_hybrid_segmentation` and `K.correction_build` stay free of REAPER calls so they can be tested with plain
  `lua` on synthetic frames (see `docs/superpowers/tests`).
- Frames are usually 5–12 ms apart, but the advanced hop choices allow about 1.3–23 ms; every time constant
  below is in seconds and must be converted with the actual frame spacing, never assumed in frames.
- Tests reach the script's internals through a test-mode guard in the script itself: when a global set by the
  test is present, the script returns a table of its internals just before it would call `main()`. The script
  stays one file. (My call.)

## Approaches

1. **Automatic joins + new splitting + one Separation control (picked).** Remove the three join values, derive
   the joins from the sung pitch, rebuild the splitting, keep the slide control. Most change, but it is the only
   option that fixes both complaints.
2. **Fix only the splitting, keep the timing values.** Smaller, but leaves four values the user does not use.
3. **Make Legato Gap feed the analysis.** Cheapest, but a gap length cannot separate two notes joined by a
   slide (there is no gap), which is the common failing case.

The user picked 1 on 2026-11-21.

## Design

### 1. Note splitting (`run_hybrid_segmentation`)

Today a split needs one of: a pitch change above 0.75 st between two adjacent frames, a level below a fixed
absolute floor, or a level jump of half within one frame; an 80 ms debounce drops splits that follow too soon.
Replace with:

- **Clean the pitch first.** Median-filter the frame pitches within each voiced run so a one-frame octave
  error cannot cause a split.
- **Bridge dropouts.** An unvoiced stretch shorter than about 25 ms with matching pitch on both sides (within
  the pitch threshold below) does not end the note.
- **Silence is relative.** A frame is silent when its level is far below the item's loud level (about 40 dB
  under the 95th percentile), not under a fixed absolute number. Silent or unvoiced stretches longer than the
  bridge end the note, as today.
- **Pitch change = sustained departure.** Track the current note's centre (median of its frames so far, onset
  excluded). When the pitch moves more than the pitch threshold from that centre and *stays* away for the hold
  time, a new note starts. The split is placed back where the pitch crossed halfway between the old centre and
  the pitch it settled on (the middle of the slide). Vibrato returns within its half-cycle (~90 ms at 5–6 Hz)
  and so does not hold long enough.
- **Re-articulation = level dip.** A local minimum in level (in dB) that is at least the dip depth below the
  peaks on both sides, within about 150 ms each way, splits the note at the minimum. The level each frame
  stores today is measured over the whole pitch-detection block (about 46 ms by default), which smears a 30 ms
  dip down to 3–4 dB. So the analysis also stores a short-window level per frame (about 10 ms or two periods
  of the frame's detected pitch, whichever is longer, centred on the frame; an unvoiced frame uses 10 ms) and
  the dip test uses that. A window shorter than one period (below about 100 Hz) would swing with where it lands
  in the period and cut a steady low note into pieces. Pitch detection itself is untouched. Items analysed before this change
  have no short level and must be analysed again; no fallback. (My call.)
- **No debounce.** A segment shorter than the minimum note length is merged into the neighbour closer in
  pitch (or dropped if it has no touching neighbour) instead of swallowing the next split.

**Separation** (0–100 %, default 50 %) scales three thresholds together. Starting values, the builder's to
tune against the tests:

| | 0 % (fewer notes) | 50 % | 100 % (more notes) |
|---|---|---|---|
| Pitch threshold | 1.5 st | 0.8 st | 0.4 st |
| Hold time | 140 ms | 90 ms | 50 ms |
| Dip depth | 12 dB | 6 dB | 3 dB |
| Minimum note length | 100 ms | 70 ms | 40 ms |

A note separated from its neighbours only by pitch must last about 100 ms to be found at any Separation (the
vibrato-aware centre needs about that long to settle); notes separated by a level dip are found from about
40–50 ms. Very wide vibrato (beyond about ±0.7 st) can still split at 100 %.

Separation is an analysis setting stored beside the other engine settings (global, remembered). Changing it
re-splits the current item from the frames stored with the take (no new pitch detection), once, when the drag
is released, as one undo point; the view does not reset. An item never analysed picks it up on its first
analysis.

**Edited notes on a re-split (the user's decision, 2026-11-21: keep edits).** A new note whose start and end
match an old note's (within one frame) takes over that note's edits (target pitch, Tighten, Tolerance,
Slide In, pitch points, bypass). Edited notes with no match lose their edits; if there are any, the same
confirm that Re-analyse shows today ("…discards your edits to N notes") appears first, counting only those,
and cancelling it puts Separation back to its previous value. Re-analyse itself is unchanged: it still
discards everything behind its confirm.

The debug split markers (`state.split_points`) keep working, with reasons "Onset", "Pitch change", "Level dip".

### 2. The note body

Tighten already finds each note's body: from the first to the last frame within `K.TIGHTEN_BODY_ST` of the
centre. Move that into its own cached helper (for example `K.note_body(note)` → first, last frame index) that
works whether or not Tighten is on. Tighten, the joins and Slide In all use it.

### 3. Automatic joins (`K.correction_build`)

- **Two notes are joined** when the gap between them is too short for a fade out and a fade in (gap shorter
  than twice the fade length). Otherwise each fades on its own.
- **A join blends across the sung slide:** from the end of the first note's body to the start of the second
  note's body. Across that span the correction crossfades (smoothstep) from the first note's correction held
  at its body end to the second note's own frame-by-frame correction, so it meets the second note's body
  exactly, whatever Tighten, Slide In or pitch points do there. Limits: at least about 10 ms, at most about 120 ms, and never further than 40 % into either note. If
  neither note has a slide (both bodies reach the boundary), the blend is the minimum length, centred on the
  boundary.
- **A fade** (into a note from silence, out of a note to silence) is a fixed 30 ms, or a quarter of the note
  if that is shorter, shaped as today.
- The blend is written one point per frame.

`transition_ms`, `onset_ramp_ms` and `legato_threshold_ms` are removed everywhere: defaults, the cascade, the
ExtState keys, per-note controls, the change signature, the hint overlays ("glide", "gap", "onset", "release"
spans may stay in the returned data if the canvas still draws them, but nothing edits them).

### 4. Slide In (was Scoop Shape)

Same idea, 0–100 %, per note, default 0 %: how much of the slide into the note is flattened. Changes:

- The slide is the frames before the body start (from the helper above), not a fixed 9 frames. A note that
  starts on pitch has no slide and the value does nothing.
- The key is renamed `slide_in`, the label is "Slide In".
- It works the same on a joined note: it changes the note's own frame-by-frame correction over its slide
  frames, and the join crossfades into that (section 3). (My call.)
- The pull no longer tapers off across the slide: at 100 % every slide frame sits on the pitch the corrected
  note has at its body start, so the slide meets the body without a step. The per-frame cap
  (`K.SCOOP_MAX_ST`) stays. `voiced_start_idx` and `scoop_magnitude` become unused and are removed.

### 5. Controls and UI

- **Top bar:** selection pill, Tighten, Strength, Tolerance, Slide In, Separation. The "Timing" button and
  the Timing row are removed. Separation is not per-note; it shows the same value whatever is selected.
- **Note drags:** left zone Tighten, right zone Tolerance, as today. Shift + drag anywhere on a note adjusts
  Slide In (the three Shift zones collapse into one). (My call.)
- **Note context menu:** Tighten, Tolerance, Slide In. Onset Ramp and Transition sliders removed.
- **Shortcuts / help panel and tooltips:** updated to match; no mention of the removed values remains.
- Tooltip texts: "Slide In: how much of the slide into the note is corrected. 0% keeps the slide as sung, 100%
  removes it." and "Separation: how readily the analysis splits the singing into notes. Raise it when separate
  notes are joined, lower it when one note is cut up."

### 6. Housekeeping

Version bump to 2.16.0 and a `CHANGELOG.md` entry. The README does not mention the timing values.

## Testing

Plain-`lua` tests on synthetic frames, following the existing files in `docs/superpowers/tests`:

- Splitting: two pitches joined by a 40 ms slide → 2 notes; same pitch with a 9 dB dip for 30 ms → 2 notes;
  a 1 s note with ±0.5 st, 5.5 Hz vibrato → 1 note; a held note with a 15 ms pitch dropout → 1 note; a
  one-frame octave error → 1 note; each at hop 256 and hop 512; Separation 0 % vs 100 % gives fewer vs more
  notes on a borderline case.
- Joins: the trajectory is continuous (no step larger than a small bound between consecutive points) across a
  joined pair, an unjoined pair, and a tightened note joined to an untouched one; a blend lies inside its limits.
- Slide In: 0 % leaves the onset as sung, 100 % puts the onset frames on the settled pitch, a note with no
  slide is unchanged.

The user checks the sound in REAPER on real takes; that cannot be automated.

## Left to the builder

- The exact threshold values and the shape of the Separation scaling, tuned against the tests.
- Where exactly the pre-filtering lives and how the helpers are named.
- Whether the canvas keeps drawing join and fade spans faintly, or drops them.
