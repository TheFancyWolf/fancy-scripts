# Fancy Cheat Sheet — Design

Date: 2026-10-12 · Status: approved in chat (user asked to build directly)

## Goal

A printable cheat sheet to read while playing a keyswitched string part live.
For each song (one REAPER project): when to switch articulation, what is being
sung at that moment, and what the hands play. Up to ~3 letter pages per song.
Re-runnable whenever the MIDI changes, and quick to edit by hand without losing
edits on the next run.

## User flow

1. Open the song's project, select the MIDI track (keyswitches + played notes)
   and the audio track (recording with vocals). Selection is remembered per
   project, so later runs need no selection.
2. Run **Fancy_Cheat Sheet** (REAPER action).
3. The sheet opens in the browser; print with Cmd+P.
4. To change wording, edit `Cheat Sheets/<Song>.md` and run the action again.

## Pieces

| Piece | Job |
|---|---|
| `Performance/Fancy_Cheat Sheet.lua` | Resolves the two tracks, reads keyswitch names (`GetTrackMIDINoteNameEx`), every played note (project time), the audio clip's file, position, offset and rate. Writes an input JSON, launches the Python helper without blocking REAPER, shows progress in REAPER's help line (`Help_Set`), then opens the HTML or shows a plain error. |
| `_lib/cheatsheet/fancy_cheatsheet.py` | transcribe (cached) → build rows → merge with the existing Markdown → render HTML. |
| Python 3 + `mlx-whisper` + `markdown` | Installed once by the user. The script never installs anything; if missing it shows the exact command. Python path resolution: saved setting → `<REAPER resource>/Data/Fancy Cheat Sheet/venv/bin/python3` → common system paths. |

Output (in the project folder, never in the repo):

```
<project dir>/Cheat Sheets/<Song>.md      editable source
<project dir>/Cheat Sheets/<Song>.html    regenerated each run
<project dir>/Cheat Sheets/.cache/        input JSON, Whisper cache, result JSON, log
```

Platform: Apple Silicon only for now (mlx-whisper). Stated in `@about`.

## Rows

- Clock: 0:00 = earliest start of the MIDI or audio item. Times print m:ss.
- Keyswitch = any pitch with a note name on the MIDI track. Label = that name.
- One row per articulation switch (plus a leading row for notes before the
  first switch). Inside a row, each change of figure is a new part (gray
  band): phrases split at gaps > `phrase_gap` (default 0.75 s), and
  consecutive phrases with the same figure merge. Parts and lyric lines are
  interleaved in time order (a line sung more than 0.3 s before a part's first
  note comes before it). Lyrics sung while resting stay in the row.
- With `split_by_line: yes` (default), a part that runs across several lyric
  lines is cut at each line start; each piece is placed just above the line it
  is played under, and a piece whose wording equals the previous piece is left
  out (a repeated figure stays one band). Up to 10 notes are listed per band.
- Lyrics: each Whisper segment goes in the row where it starts (0.4 s lead
  allowed). A row without lyrics shows only its part note.
- Reference lyrics (optional): `Cheat Sheets/<Song>.lyrics.txt`, supplied by
  the user (never fetched). Heard segments are matched in song order to 1–3
  reference lines or part of one line (difflib); matched text replaces the
  heard text; heard lines that match nothing are left out (counted in a
  warning). Reference lines nobody matched are placed between their
  neighbours' times, so the sheet carries the whole lyric. Section tags like
  `[ORPHANS]` and Genius "You might also like" suggestions are skipped.
  Encodings: UTF-8, UTF-16 with BOM, Mac Roman.
- Lyrics print in full, one line per line (`cue_words` > 0 shortens each line
  to its first N words; default 0).
- Part wording follows how the player marks parts (learned from the edited
  Hard Knock Life sheet):
  - register words instead of octave numbers: High (C6+), Mid (C5–B5), none
    (C4–B4), Low (below C4); left-hand parts get no register word;
  - "F# octave", "Quad octave D" (one pitch class stacked; both hands doubling
    the same notes read as one shape), "D chord" / "D chord: D F# A D" for
    arpeggios;
  - short single notes as lines with speed: "Slow line G D A D", "Fast line …",
    "Run up C# D E" (fast, stepwise), "Walk-up slow F G A";
  - held notes and octave changes with arrows: "High D → Mid D → High G",
    "Octaves B → C"; repeats as "2x" (or "(repeat)" when the last pass is cut
    off); a long last note as ", then hold D";
  - LH/RH labels only when the hands do different things.
  Rhythm and judgment ("odd rhythm", "slam", "double time") stay the
  player's.

## Markdown format and merge

Front matter holds per-song values that print at the top (`key`, `run_key`,
`run_direction`, `gliss_direction`, `trill_interval`; blank = a line to write
on) and settings (`hand_split`, `phrase_gap`, `cue_words`, `split_by_line`, `auto_keys` —
first-pass keyboards, default `no`). `short` prints as a "Short ____" field
(detaché / spiccato) and `scale` pre-fills the title-bar keyboard.
Free text between the title and the first row is preserved verbatim.
Row = `## m:ss · ART <!-- at=SECONDS auto=HASH -->`, then a `>` lyric line, then
the part note (any Markdown).

On re-run, each new auto row matches an existing row with the same articulation
within 0.5 s:

| Case | Result |
|---|---|
| Match, body unedited (hash equal) | refreshed |
| Match, body edited | kept |
| Old edited row, no match | kept, marked `⚠ no longer in MIDI — check` |
| Old unedited row, no match | dropped |
| New auto row | inserted in time order |
| Row whose anchor comment was lost (some editors strip comments) | matched by heading time (±1.1 s) and articulation, kept as edited, anchor restored |
| User row (no anchor comment, no match) | kept at its time |
| `(hide)` in heading | kept in file, not printed |

## Printed page

Title with a one-octave keyboard (C–B, full title-bar height) on the right
for writing in a scale (`scale:` in the front matter pre-fills dots), a
settings strip (Key · Run key/dir · Gliss dir · Trill interval),
then rows: articulation name (left, only on rows where it changes) · lyrics
(large) with each part note (bold, in a gray band with a black left bar,
forced to print) placed where the playing starts: lines
sung more than 0.3 s before the row's first note come before it, the rest
after. No time column on the printout (times stay in the .md headings).
Filled-in lyric lines have estimated times, so their side of the part note
can be wrong. Print CSS for letter
portrait.

## Keyboard diagrams

A line `keys [LH|RH] <low>-<high>: <notes>` (dots) or `line …` (dots numbered
in the order given) under an instruction draws a small keyboard inline in that
gray band; several sit side by side. Notes take an optional octave (`G2`);
the range reads upward and is widened to white keys at both ends; without an
octave a mark is the first matching key in the range. Spans over 4 octaves or
unknown notes leave the line as plain text. Full runs add a first-pass `keys`
line per hand under each generated part note (range = notes played ±1 key;
a `line` for walk-ups/downs of 3–8 notes). Drawn at render time, so the
double-click render picks up edits.

## Show toggles (screen only)

The HTML has a control bar (Lyrics · Part notes · Keyboards checkboxes) that
hides those parts via body classes; print shows what is on screen and the bar
itself never prints. Rows left with nothing visible and no switch name are
hidden. The choice is stored per song in the browser's localStorage. The .md
and the REAPER action are unaffected; articulation switches always show.

## Render from the Markdown only

Typical use: run the action once, edit the .md, then print. Re-rendering
needs only the .md: `fancy_cheatsheet.py --render <file.md | folder> [--open]`
parses the .md and writes the HTML in file order, without reading project
data or rewriting the .md. Each full run writes `Cheat Sheets/Render Cheat
Sheets.command` (absolute Python and helper paths, chmod 755), which runs
`--render . --pick --open` when double-clicked: a plain `osascript` "choose
from list" dialog (no `tell application`, so no automation permission)
lists the folder's songs with those edited since their last render (.md newer
than .html) preselected; Cancel renders nothing. Without osascript, the
edited songs are rendered. The header carries no counts or song length, so both paths produce
identical HTML.

## Errors

Plain message boxes for: no/ambiguous tracks, no keyswitch names, no audio
file, Python or packages missing (with install command), helper failure (last
lines of the log). The helper always writes a result JSON (`ok`, `error`,
`html`, `warnings`, `rows`, `edited_kept`, `flagged`).

## Testing

Real REAPER on `Hard Knock Life.RPP` (per AGENTS.md). Run, check the sheet,
edit the Markdown, re-run and confirm edits survive, check error paths.
`luacheck .` clean.
