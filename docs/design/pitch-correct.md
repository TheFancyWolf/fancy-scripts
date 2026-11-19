# Design: Fancy Pitch Correct — readable canvas, zoom and a single top bar

Target file(s): `Pitch/Fancy_Pitch Correct.lua`, `_lib/theme.lua` (canvas palette, section 4A)
Archetype(s): main window → editor / workbench (unchanged); Settings, Info and confirm dialogs unchanged
Status: Draft
Date: 2026-11-18
Approver: layout approved from mockups in chat (TheFancyWolf, 2026-11-18); everything below mockup level is the implementer's and still needs a review before this is marked Approved

## Summary

The v2.5.0 window puts controls in four places (header, bottom dock, sidebar, canvas) and the canvas is hard to read: thin note boxes under a loud layer of markers, a pitch range stretched by stray curve spikes, bright piano keys and strong row stripes. This revision makes the notes the first thing the eye lands on, gives each axis one visible zoom control, and moves every control into one top bar. Behaviour of the note model, the cascade (Global → Item → Note), undo and analysis is unchanged.

## What changes

| # | Area | Before | After |
|---|---|---|---|
| 1 | Notes | translucent boxes with a 1 px border and an always-on label | solid blobs in the accent colour with the item's waveform inside; pitch trace in the text colour on top |
| 2 | Smart spots | drawn for every note | drawn only for the hovered and the selected notes |
| 3 | Pitch range | fitted to every analysis frame (spikes included) | fitted to the notes, at least an octave; zoom and scroll on a strip at the right edge |
| 4 | Time range | whole item on open; Cmd/Ctrl+wheel zoom | unchanged on open; an overview strip under the notes is the one visible zoom / scroll control |
| 5 | Note labels | name + cents on every note | a pill above the hovered and the selected notes only |
| 6 | Note column | white / black piano keys, label on C and in-scale keys | flat panel-coloured column, a name on every row that is a text line tall (C rows always) |
| 7 | Rows | accent-tinted in-scale rows against near-black out-of-scale rows | one surface, out-of-scale rows a small step darker, a faint tint on the root row |
| 8 | Colour roles | trace and playhead both accent | notes = accent, edited = green, trace and playhead = text colour (the playhead has a head in the ruler), spots = yellow |
| 9 | Controls | header + bottom dock | one top bar; no bottom dock |
| 10 | Status / hint | a text line in the dock | a pill in the bottom-left corner of the note area |

Not in this revision (were discussed, not agreed): playhead follow while zoomed, drag-to-pan on the canvas, transition segments between notes.

## Layout

```
┌ top bar ───────────────────────────────────────────────────────────────────────────┐
│ ◆ [item badge] [Key][Scale] │ [scope] Strength [====] [Transition][Onset Ramp]     │
│                             │ [Legato Gap] │ [Snap][Quantize][Split][Merge]  [… ][×]│
├──────┬───────────────────────────────────────────────────────────────────────┬────┤
│ A4   │ ruler                                                                 │ ▲  │
│ G#4  │   ▇▇▇▇▇▇     ▇▇▇▇▇▇▇▇▇                                                │ ▓  │  pitch strip:
│ G4   │           ▇▇▇                                                         │ ▓  │  thumb = visible range
│ …    │ (status pill)                                                         │ ▼  │
├──────┼───────────────────────────────────────────────────────────────────────┴────┤
│      │ overview strip: every note, small; thumb = visible time window             │
└──────┴─────────────────────────────────────────────────────────────────────────────┘
```

The Pitched Items panel (right) is unchanged, apart from a `L.sm` inset on its right. The window has no padding: the canvas and the panel run to its left, right and bottom edges, and the top bar keeps its own margins (`pad_v` above, `pad_x` left and right).

### Top bar

Units, left to right, in four groups (a group break is `L.xl` with a hairline in the middle; units are `L.sm` apart, `L.md` in the Clip group):

- **Clip**: brand icon, item badge (takes the room its row has left, ellipsis), Key, Scale. The FANCY / PITCH CORRECT wordmark and the "Key:" / "Scale:" labels are gone (the window title and the tooltips carry them).
- **Correction**: scope pill, "Strength" + slider, then Transition / Onset Ramp / Legato Gap badges — or one **Timing ▾** button whose popup holds the three as rows (label + drag), when the badges do not fit.
- **Note actions**: Snap, Quantize, Split, Merge.
- **Right** (right-aligned on row 1): **…** (More) and Close.

**More** popup: Analyze / Re-Analyze (Cancel while analysing, and the button itself reads the progress, as before), Reset (same scope-aware label), separator, Layers ▸ (the four layer checkboxes with swatches), Note Tone (checkable: plays a tone at the note's pitch while a note is dragged; on by default), Settings, Keyboard Shortcuts & Help.

**Plans**, first that fits, chosen from the content width alone:

1. one row, Timing as three badges
2. one row, Timing collapsed
3. two rows: Clip + Right / Correction (three badges) + Note actions
4. two rows, Timing collapsed
5. three rows: Clip + Right / Correction (collapsed) / Note actions
6. four rows: brand + badge + Right / Key + Scale / Correction (collapsed) / Note actions

A floating window is never narrower than plan 6 needs.

**Scope pill** reads where the Strength value comes from, as the dock's "· global / · item / · note" tag did: `Global`, `Item`, `Note`. Semantics are unchanged: an edit goes to the item override when there is one, else to the global default; a value the selected note overrides is shown and locked ("Overridden on this note. Right-click the note to change it."). Badges keep their colour and `*` mark.

### Canvas

- **Note column** (left): `gutter_*` tokens. Root row: accent strip on the inner edge, accent label.
- **Note area**: ruler overlay on top (unchanged).
- **Overview strip** (below the note area, `line_h * 2` tall): each note as a small bar placed by pitch; the thumb is the visible time window with a grip at each end. Drag the thumb = scroll; drag an end = zoom; double-click = whole item; click outside the thumb = centre the window there. Tooltip: "Drag to scroll. Drag an end to zoom. Double-click: whole item".
- **Pitch strip** (right of the note area, `L.xl` wide): track = the fitted range widened to include the raw curve; thumb = visible range. Same gestures; double-click = fit to the notes. Tooltip: "Drag to scroll. Drag an end to zoom. Double-click: fit the notes".

### Pitch range

- Fit = lowest / highest of every note's centre and original pitch, ± 0.5, padded 2 semitones each side, never less than 12 semitones (centred). While there are no notes yet (analysing), the analysis frames are used as before.
- A manual range (`state.view_p0 / view_p1`) replaces the fit until it is reset: when the target changes or the item is analysed or cleared, by F, or by a double-click on the pitch strip. It survives undo / redo of the same take, like the time window.
- Limits: never fewer than 3 semitones visible; never outside the strip's track.

### Input

| Input | Result |
|---|---|
| Cmd/Ctrl + wheel | zoom time around the pointer (unchanged) |
| Wheel | scroll pitch (v2.8.1: follows the device's scroll axis) |
| Alt + wheel | zoom pitch around the pointer |
| Shift + wheel, or a horizontal wheel | scroll time when zoomed |
| Z | zoom to the selected notes (time: selection + 10 % each side; pitch: selection ± 3 semitones) |
| F | whole item, fitted pitch |
| Double-click ruler | whole item (unchanged) |

### Status pill

Bottom-left of the note area. Shows, first that applies: the status message (4 s, unchanged), "Analyzing <item>… N %", the selection issue (MIDI / no audio take), "N notes selected" (2 or more), "Select a note to edit it" (analysed, nothing selected). Empty canvases keep their centred message and show only status messages / the selection issue in the pill.

## Copy deck (new or changed strings)

- Strength label: `Strength` (tooltip keeps "Correction Strength: how much of the pitch correction is applied.")
- Scope pill: `Global`, `Item`, `Note`
- Timing button: `Timing ▾` (`Timing* ▾` when one of the three is overridden); tooltip `Transition, Onset Ramp and Legato Gap`
- Key tooltip: `Key: the root note of the scale`; Scale tooltip: `Scale: marks the in-scale rows on the canvas and sets the scale Quantize (Q) snaps to`
- Z with nothing selected: status `Select a note to zoom to it`
- More: `…`; tooltip `More: Analyze, Reset, Layers, Note Tone, Settings, Help`; while analysing `Analyzing. Open to cancel`
- More items: `Layers`, `Note Tone`, `Settings`, `Keyboard Shortcuts & Help`
- Note Tone tooltip: `Play a tone at the note's pitch while you drag it`
- Pill: `%d notes selected`
- Help rows: `Wheel` → `Scroll the pitch axis`; `Alt + Wheel` → `Zoom the pitch axis`; `Shift + Wheel or horizontal scroll` → `Scroll the timeline (when zoomed)`; `Z` → `Zoom to the selected notes`; `F` → `Show the whole item, fit the pitch range`; `Drag the overview strip` → `Scroll; drag an end to zoom`; `Drag the pitch strip` → `Scroll; drag an end to zoom`; "Right-click a dock value" → "Right-click a top bar value"

## Theme mapping (`P.canvas`)

Changed: `row*`, `row_tint`, `row_tonic_tint`, `grid*` (calmer), `note_fill`, `note_border`, `note_edited`, `note_selected`, `note_selected_edited`, `note_selected_border`, `note_label*` (solid blobs, white label ≥ 4.5:1 on each), `trace`, `playhead` (text colour, ≥ 3:1 on rows and blobs), `preview` (a lighter green that reads on the edited blob), `handle_drag` (yellow: the blobs own the accent).
New: `gutter_bg`, `gutter_text`, `gutter_text_dim`, `gutter_text_tonic`, `gutter_strip`, `note_wave`, `overview_bg`, `overview_note`, `view_fill`, `view_border`, `view_grip`.
The piano-key tokens (`key_*`, `key_text_*`) stay in the palette for other canvases; Pitch Correct no longer reads them.
Match Theme: every new text token fitted to ≥ 4.5:1 and every boundary to ≥ 3:1 on the surfaces it is drawn on, as the existing tokens are.

## Acceptance criteria

1. With nothing selected, no smart spot and no note label is drawn; hovering or selecting a note shows both for that note.
2. A clip whose raw curve has a spike two octaves below the melody opens with the melody filling the note area; the spike is reachable with the pitch strip.
3. After analysis the whole item is visible; the overview thumb spans the strip.
4. Dragging an end of the overview thumb changes only that end of the time window; the other end stays put. Same for the pitch strip.
5. No control is drawn below the canvas. Every control the dock had is in the top bar and behaves as it did (drag, double-click reset, right-click item override, disabled reasons).
6. At any window width the top bar picks a plan from the width alone; selecting notes or analysing never moves a control.
7. Status messages remain visible for 4 s in every state (empty, analysing, analysed, bypassed).
8. Every label drawn on the canvas is ≥ 4.5:1 in Fancy and in Match Theme (dark and light REAPER themes).
9. `luacheck .` is clean.

## Open questions / assumptions

- Z and F are assumed free; they need exact modifiers, so Cmd/Ctrl+Z still reaches REAPER's undo.
- The waveform inside a blob is REAPER's peaks for the item (`GetMediaItemTake_Peaks`, first channel, 400 peaks per second, at most 200 000 per item), linear, scaled so the item's loudest sample fills a blob. It is fetched once per item and again when the item's length, start offset, play rate or source changes. While REAPER has no peaks for the item, the blob shows the analysis loudness (RMS per frame) instead; items analysed by a version that stored no RMS then show plain blobs.
- With an average glyph of 7 px the planner picks plan 1 from about 1500 px, plan 2 from about 1100 px and plan 3 from about 900 px of content width; this was estimated with stub text metrics, not measured in REAPER.
- A label is shown for every selected note up to 8 selected; above that only the hovered and the primary note carry one.
