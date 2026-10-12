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
- New row only when there is something new to play: (1) articulation switch;
  (2) phrase whose figure differs from the previous phrase (phrases split at
  gaps > `phrase_gap`, default 0.75 s). Lyrics sung while resting stay in the
  row before (no REST rows).
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
- Part note per row, LH first (split at `hand_split`, default C4), pitch names
  without octave numbers: the main note or shape ("D", "G octave", "D chord"),
  walk-up/down, a repeating pattern ("G D A D pattern"), octave lines
  ("Octaves: F# G F# A"), otherwise notes in order (max 6, then "…"). Rhythm
  is not described yet (the project grid does not follow the performance).

## Markdown format and merge

Front matter holds per-song values that print at the top (`key`, `run_key`,
`run_direction`, `gliss_direction`, `trill_interval`; blank = a line to write
on) and settings (`hand_split`, `phrase_gap`, `cue_words`).
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
| User row (no anchor comment) | kept at its time |
| `(hide)` in heading | kept in file, not printed |

## Printed page

Title, a settings strip (Key · Run key/dir · Gliss dir · Trill interval),
then rows: articulation name (left, only on rows where it changes) · lyrics
(large) with the part note (bold) placed where the playing starts: lines
sung more than 0.3 s before the row's first note come before it, the rest
after. No time column on the printout (times stay in the .md headings).
Filled-in lyric lines have estimated times, so their side of the part note
can be wrong. Print CSS for letter
portrait.

## Errors

Plain message boxes for: no/ambiguous tracks, no keyswitch names, no audio
file, Python or packages missing (with install command), helper failure (last
lines of the log). The helper always writes a result JSON (`ok`, `error`,
`html`, `warnings`, `rows`, `edited_kept`, `flagged`).

## Testing

Real REAPER on `Hard Knock Life.RPP` (per AGENTS.md). Run, check the sheet,
edit the Markdown, re-run and confirm edits survive, check error paths.
`luacheck .` clean.
