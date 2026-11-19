# Design: Fancy Pitch Correct — visual feedback for every correction setting

Target file(s): `Pitch/Fancy_Pitch Correct.lua`, `_lib/theme.lua`
Archetype(s): main window → Editor / canvas (unchanged); this design changes one layer of the canvas
Status: Approved
Date: 2026-11-19
Approver: TheFancyWolf (in chat, 2026-11-19; includes the two canvas palette keys in `_lib/theme.lua`)

## Summary

Every setting that changes the correction shows its effect on the note canvas, not only as a number. The green Preview Curve becomes the exact shape that is written to the item (it gains the scoop, the onset and release ramps, and the glides between joined notes), and while a setting is hovered or dragged, shaded spans mark where on the notes it acts. It is for someone setting Strength, Transition, Onset Ramp, Legato Gap or Scoop by eye. The window's primary display (the note canvas) and primary action (dragging a note) do not change. No new control, menu entry or stored setting is added.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Preview Curve follows the full correction shape (scoop, ramps, glides) | none new (the analysed notes already in memory) | none | none | n/a: display only |
| Preview Curve updates live while a top bar value is dragged | none | none (the write on release is unchanged) | none | n/a: display only |
| Highlight spans while a setting is hovered or dragged | none | none | none | n/a: display only |
| Existing, unchanged: every control, gesture, value range, undo point, the write on release, the saved global defaults, the Layers menu entries | as today | as today | as today | as today |

What each setting shows (confirmed in chat, 2026-11-19: hover and drag; every note the value reaches; joined gaps shaded; the existing Preview Curve toggle covers it all):

| Setting | Where it is changed | Curve | Highlight while hovered or dragged |
|---|---|---|---|
| Strength | Top bar; note menu | Moves live on every edited note it reaches | Outline on each note it reaches |
| Transition | Top bar; Timing popup; note menu; Shift+Drag a note's centre | Glide between two joined notes gets longer or shorter | Span over each glide |
| Onset Ramp | Top bar; Timing popup; note menu; Shift+Drag a note's left zone | Fade in before the note and fade out after it get longer or shorter | Span before the start and after the end of each note that is not joined on that side |
| Legato Gap | Top bar; Timing popup | Glide appears or disappears between two notes | Span over every gap that is joined; unjoined gaps stay empty |
| Scoop | Note menu; Shift+Drag a note's right zone | The start of the note bends toward the corrected pitch | Span over the note's onset |
| Stability, Vibrato, pitch | Drag on the note (as today) | As today | None (the whole note changes; the curve already shows it) |

A note is **reached** by a setting when it is edited, not bypassed, and takes that setting from the level being changed (a note with its own value for it is not reached by the top bar). Untouched notes get no correction at all, so nothing is drawn on them: that is the truth of what the script writes.

## References

- Native REAPER analogues: the take pitch envelope drawn on the item in the arrange view (the curve is the same data, drawn on the pitch scale), and the time selection / loop shading (a translucent band over a time range). Conventions matched (CN6): no gesture changes; Shift and Alt keep their current meanings; values keep their units (ms, %).
- Baseline capture: the user's screenshot of 2026-11-19 (docked, 7 pitched items, top bar showing Global · Strength 100% · Transition 35ms · Onset Ramp 35ms · Legato Gap 91ms). `ds-lint.py` summary: did not run ("theme.lua palette drifted from ds-lint's port of build_palette"), so there is no mechanical baseline; that is a tool fault, separate from this design.

## Context and job stories

Confirmed at the checkpoint (2026-11-19): lives on the existing canvas, used all session, during playback, mostly by mouse.

1. When I drag Transition, Onset Ramp or Legato Gap in the top bar, I want to see where on the notes it acts and how the pitch line changes, so I can set it by eye.
2. When I Shift+Drag a note for its own Onset Ramp, Transition or Scoop, I want the same feedback on that note.
3. When I change Strength, I want every edited note's curve to move live, so I see how far each is pulled.
4. When I hover a setting without dragging, I want to see which notes it reaches, so I know what I am about to change.
5. When I am not touching a setting, I want the canvas as calm as today, so highlights do not clutter editing.
6. When the script is docked narrow and the timing values sit behind the Timing button, I want the same feedback from that popup.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | The accurate Preview Curve on edited notes, their ramps and glides | It is the result of every edit; read constantly |
| 2 one disclosure away | The highlight spans and outlines (shown by hovering or dragging a setting) | Needed only while a setting is being judged; clutter otherwise |
| 3 Settings | None | The Layers menu's existing Preview Curve entry switches curve and highlights together |

## Information architecture

Regions touched:

1. **Note canvas, curve layer** (existing): the Preview Curve, now continuous through ramps and glides, so it may leave the note block by up to the ramp length on each side.
2. **Note canvas, highlight layer** (new, drawn under the curve and over the note blocks): spans and outlines, only while a setting is hovered or dragged.
3. **Top bar, Timing popup, note menu** (existing, unchanged look): they only report "this setting is hovered / being dragged" to the canvas.

One disclosure level (hover or drag shows the highlights). Primary display and primary action are unchanged (IA3). Layer order, bottom to top: rows, note blocks, vibrato shading, highlight spans, pitch trace, trend, Preview Curve, spots, pills.

## Wireframes

Legend: `▓` note block, `~` pitch trace, `=` Preview Curve, `░` highlight span, `┆` span edge.

Default floating size. At rest, two joined notes and one note on its own (all edited). The curve now fades in before the first note, glides between the joined pair and fades out after the last:

```
        ▓▓▓▓▓▓▓▓▓▓▓▓
     ===============\
    /   ▓▓▓▓▓▓▓▓▓▓▓▓ \ ▓▓▓▓▓▓▓▓▓▓▓            ▓▓▓▓▓▓▓▓
 ~~~                  ===============\      /==========\
                       ▓▓▓▓▓▓▓▓▓▓▓    ~~~~~~  ▓▓▓▓▓▓▓▓  ~~~
```

Pointer over **Onset Ramp** in the top bar (or dragging it): a span before the start and after the end of each reached note, on the sides that are not joined:

```
     ┆░░┆▓▓▓▓▓▓▓▓▓▓▓
     ┆==============\
     ┆/░┆▓▓▓▓▓▓▓▓▓▓▓ \ ▓▓▓▓▓▓▓▓▓▓▓┆░░┆     ┆░░┆▓▓▓▓▓▓▓▓┆░░┆
 ~~~                  ============\░░┆     ┆░/=========\░┆
                       ▓▓▓▓▓▓▓▓▓▓▓┆░░┆~~~~~┆░░┆▓▓▓▓▓▓▓▓┆░░┆~~
```

Pointer over **Transition**: a span over each glide, centred on the boundary, as wide as the transition:

```
        ▓▓▓▓▓▓▓▓▓┆░░░┆
     ============┆==\┆
    /   ▓▓▓▓▓▓▓▓▓┆░░░\▓▓▓▓▓▓▓▓▓▓▓
                 ┆░░░┆===========
                 ┆░░░┆▓▓▓▓▓▓▓▓▓▓▓
```

Pointer over **Legato Gap**: a span across every joined gap, from the end of one note to the start of the next; a gap that is too long has none, and the curve returns to the trace there:

```
        ▓▓▓▓▓▓▓▓▓▓▓▓┆░┆
     ===============┆\┆                         (gap too long: no span)
        ▓▓▓▓▓▓▓▓▓▓▓▓┆░\▓▓▓▓▓▓▓▓▓▓▓            ▓▓▓▓▓▓▓▓
                    ┆░┆===========\      /==========
                    ┆░┆▓▓▓▓▓▓▓▓▓▓▓ ~~~~~~   ▓▓▓▓▓▓▓▓
```

Pointer over **Strength**: no time span; each reached note gets an outline, and its curve moves as the value is dragged:

```
       ┌────────────┐
       │▓▓▓▓▓▓▓▓▓▓▓▓│  ┌───────────┐
     ==│============│\ │▓▓▓▓▓▓▓▓▓▓▓│          ▓▓▓▓▓▓▓▓   (own Strength: not reached, no outline)
       └────────────┘ =│===========│
                       └───────────┘
```

Shift+Drag on one note (Onset Ramp, Transition or Scoop of that note, or of the selected notes): the same spans, only on the dragged notes. Scoop's span covers the note's onset, inside the block:

```
        ┆░░░┆▓▓▓▓▓▓▓▓
        ┆ ==┆========
        ┆/░░┆▓▓▓▓▓▓▓▓
```

A span is as tall as the note blocks it belongs to (for a glide: from the top of the higher block to the bottom of the lower one), so it stays next to its note and several notes in view do not merge into stripes.

Narrow docker (about 260 px wide): the three timing values sit behind the existing **Timing** button. Hovering or dragging a row in its popup shows the same highlights on the canvas behind it. Nothing else changes; the canvas keeps its minimum width.

```
┌ … [Strength 100%] [Timing ▾] ┐
│  ┌──────────────────────┐    │
│  │ Transition   [ 35 ms]│◂── pointer here: glide spans on the canvas
│  │ Onset Ramp   [ 35 ms]│    │
│  │ Legato Gap   [ 91 ms]│    │
│  └──────────────────────┘    │
│ ▓▓▓▓▓┆░░┆▓▓▓▓▓               │
└──────────────────────────────┘
```

Wide short strip (about 1200 × 150): same as the default size. Blocks are short, so spans are short; the span edges keep them visible. When zoomed far out, a span narrower than two pixels is drawn as a single edge line, so a reached note is still marked.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Curve and highlights | empty (no edited note in view reaches the setting) | No highlight. While the value is being dragged the status pill says "No edited note in view uses this value" | ST6, ST2 |
| Curve and highlights | empty (nothing analysed) | Unchanged: the settings are disabled with their existing reason; nothing is drawn | ST6, EP2 |
| Curve | working (analysing) | Unchanged; no highlights while analysing | ST3 |
| Curve | error | None new: display only, no failure path | ST7 |
| Top bar setting | disabled with reason (note has its own value; not analysed) | Unchanged reason tooltip; a disabled setting shows no highlights | EP2 |
| Highlights | overflow (many notes in view; zoomed far out) | Only notes in view are highlighted; a span under two pixels wide is one edge line | LG4, HI5 |
| Curve | no detected pitch under a ramp or glide | The curve has no point where there is no detected pitch and bridges such frames with a straight line, exactly as the pitch trace does (amended after the first live test, 2026-11-19: breaking there cut the curve into pieces inside notes); the span still marks the range | ST4 |
| Canvas | item bypassed | Unchanged dimmed canvas; no highlights | ST1 |
| Canvas | Preview Curve layer off | No curve and no highlights (one toggle for both) | IA4 |
| Both | missing dependency | None new | HI7 |
| Both | Fancy Dark / Match Theme | Span fill is a faint wash; the span edge and the note outline are fitted to at least 3:1 on every row and note fill in both modes | CL4, HC1 |

## Interaction spec

No gesture, default, range, unit or undo label changes. The table lists what newly reports to the canvas.

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Strength (top bar) | Unchanged. New: hover or drag shows outlines; the curve follows the value every frame of the drag | as today | as today (%) | as today | as today (one point on release) | n/a |
| Transition, Onset Ramp, Legato Gap badges (top bar) | Unchanged. New: hovering the badge, or hovering or dragging the value in its popup, shows that setting's spans | as today | as today (ms) | as today | as today | n/a |
| Timing popup rows (narrow widths) | Unchanged. New: same as the badges, per row | as today | as today | as today | as today | n/a |
| Note menu sliders (Strength, Onset Ramp, Scoop, Transition) | Unchanged. New: hover or drag shows the spans on the notes the menu acts on | as today | as today | as today | as today | n/a |
| Shift+Drag on a note (left: Onset Ramp, centre: Transition, right: Scoop) | Unchanged. New: spans on the dragged notes for the length of the drag | as today | as today | as today | as today | n/a |
| Preview Curve (Layers menu) | Unchanged checkbox; now also switches the highlights | On | n/a | n/a | None (view preference) | n/a |

Rules for the highlight layer:

- **Shown while:** the pointer is over an enabled setting, or that setting is being dragged, or its typed entry is open. Hidden the frame the pointer leaves and nothing is being dragged. It does not depend on the Show Tooltips preference.
- **One setting at a time:** a drag wins over a hover.
- **Not interactive:** spans and outlines take no clicks, change no cursor and never block a note, a handle or the marquee (MT2 n/a).
- **During playback:** unchanged; highlights draw under the playhead.

Keyboard map: no new key. Esc (HC5), Space (HC6) and every existing shortcut are unchanged. The Help modal gains one row describing the highlights (HP1).

Implementation notes for the builder (not user-visible):

- **One calculation.** The point list that `apply_envelope_to_take` builds (frame shifts, scoop, onset and release ramps, glides, legato test) moves into one function that returns the points without touching REAPER. The envelope writer and the curve both call it, so they cannot disagree. It also returns the spans (kind, start, end, notes) so the highlight layer does not re-derive them.
- **Curve = pitch trace + shift.** At each pitch frame in a corrected range, the drawn pitch is the detected pitch plus the shift interpolated from the point list. The written envelope is simplified to within one cent and uses REAPER's curve between points; the drawn curve uses straight segments between unsimplified points. The difference is under one cent and is not labelled.
- **Cost (HI5).** The point list is rebuilt only when an input changed (a note's controls, an effective value, the note list), never per frame at rest; during a drag it is rebuilt on the frames where the value changed. Screen coordinates stay in the existing draw cache, keyed as today plus the values the curve now reads.
- **Curve coverage.** Today the curve is drawn per edited note. It is now drawn per corrected range: each edited, non-bypassed note with its ramps, and each glide including the half that lies in an untouched neighbour.
- **Hover reporting.** The top bar, popups and menu set "active setting" (key, level, notes) in `state` each frame; the canvas reads it. Hover uses `reaper.ImGui_IsItemHovered` with the popup-safe flags already used by the bar's tooltips, without the tooltip delay.

## Copy deck

| Where | String |
|---|---|
| labels | None new |
| tooltips | Layers menu, Preview Curve (new tooltip): `The pitch after correction. Hover or drag a setting to see where it acts.` |
| empty / error / confirm | None new. No confirm |
| status messages | `No edited note in view uses this value` |
| Help modal addition | `Hover or drag a setting` → `Shows on the notes where it acts` (the group that lists the top bar values) |
| undo labels | None new |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Preview Curve | `Theme.get_palette` → canvas palette, drawn with `reaper.ImGui_DrawList_AddPolyline` (as today) | canvas `preview` |
| Span fill | canvas palette, `reaper.ImGui_DrawList_AddRectFilled` | canvas `span_fill` (proposed) |
| Span edge, note outline | canvas palette, `reaper.ImGui_DrawList_AddLine` / `reaper.ImGui_DrawList_AddRect` | canvas `span_edge` (proposed) |
| Status message | the script's existing status pill | canvas `pill_bg`, `pill_text` |
| Layers tooltip | `Theme.tooltip` | none new |
| Line weights and padding | none | `Theme.layout.xs` (outline offset from the block); the curve keeps its current weight |

## Library proposals

Two keys in the canvas palette of `_lib/theme.lua`, built in both theme modes next to `zone_drift` and `preview`:

- `canvas.span_fill`: a faint wash of the yellow already used for the Shift zone (`zone_shift`), so "Shift+Drag timing" and "timing span" read as the same family. Decoration; exempt from contrast like the vibrato wash.
- `canvas.span_edge`: the same hue, fitted to at least 3:1 on every row and every note fill (the way `preview` and `spot` are fitted), and kept apart from `spot` and `handle_drag` by shape (a vertical line or a box, never a dot or a handle).

Why no existing key fits: `zone_shift` is tuned for a fill inside a note block and is not fitted for the rows outside it; `marquee_*` and `view_*` mean selection and viewport. Beneficiary: Pitch Correct only, today. This touches the shared library, so it needs its own yes.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | Which notes a setting reaches is visible on the canvas while it is hovered or dragged; bypass and scope badges unchanged |
| ST2 | Curve and spans respond in the same frame as the value; a drag that reaches nothing in view says so on the status pill |
| ST3 | n/a: no new long work; the rebuild happens only on change |
| ST4 | The curve is the shape that is written (same calculation); it breaks where there is no pitch rather than inventing one |
| ST5 | n/a: lifecycle unchanged |
| ST6 | Nothing reached: status message while dragging; nothing analysed: existing disabled reason |
| ST7 | n/a: no new failure path |
| UC1 | No new undo point; the value still commits once on release |
| UC2, HC5 | Esc order unchanged |
| UC3, UC4, UC5 | n/a: no state written, selection untouched, resets unchanged |
| EP1, HC4 | n/a: nothing destructive |
| EP2 | A disabled setting keeps its reason and shows no highlights |
| EP3, EP4 | n/a: no input or identity change |
| EP5 | No control moves or hides; highlights are an overlay that appears on hover |
| EP6 | n/a: no new shortcut |
| CN1 | Tooltip through `Theme.tooltip`; no new widget |
| CN2, CN3 | Colours only from the canvas palette; the two new keys exist in both theme modes before the script uses them |
| CN4 | "Strength", "Transition", "Onset Ramp", "Legato Gap", "Scoop", "Preview Curve" as used today |
| CN5, HP1 | The Help modal describes the highlights; no claim without code |
| CN6, HC2, HC3 | Gestures unchanged; Shift and Alt keep their meanings |
| RC1 | Highlights are explained in the Layers tooltip and the Help modal, not by hover alone |
| RC2 | No new units or jargon |
| EF1, EF2, HC6 | Unchanged |
| EF3 | Scale stays frozen during a drag; highlights follow zoom and scroll |
| IA1 | Curve Tier 1, highlights Tier 2, nothing in Settings |
| IA2 | One disclosure level |
| IA3 | Primary display and action unchanged; no new text sizes |
| IA4 | The Preview Curve toggle switches everything it names; no dead option |
| LG1, LG2, LG3 | n/a: no new framed rows or buttons |
| LG4 | Works through the Timing popup at about 260 px and in a 1200 × 150 strip; sub-two-pixel spans draw as one line |
| MT1, MT2 | n/a: nothing new to click |
| CL1, HC1 | Span edge and note outline at least 3:1 on rows and note fills in both modes; the fill is decoration |
| CL2 | A span is told from other marks by shape and position (a box beside or between notes) and by the setting under the pointer, not by colour alone |
| CL3 | No red |
| CL4 | Checked in Fancy Dark and Match Theme |
| HI1, HI2, HI3, HI4 | n/a: no window, toolbar or persistence change |
| HI5 | Point list rebuilt on change only; highlights only for notes in view; no REAPER calls per frame for either |
| HI6 | No new IDs |
| HI7 | n/a |
| RB15, RB19 | Tooltip respects the Show Tooltips preference; every ImGui name checked before use |

## Open questions / assumptions

- **Onset Ramp also sets the fade-out after a note.** The code uses the one value for both ends, and the span will show both. The name is not changed here.
- **Transition has no visible effect on a note that is not joined to a neighbour**, so it shows spans only at joined boundaries. If no boundary in view is joined, the "No edited note in view uses this value" message applies.
- **Assumption: the curve follows the pitch trace.** It has points only where pitch was detected and bridges unpitched frames the way the trace does; under a ramp in silence with no pitch on either side, only the span shows.
- **Assumption: under-one-cent difference** between the drawn curve and the written envelope is acceptable unlabelled.
- **Assumption: hover on a top bar badge counts**, not only hover on the value inside its popup.
- **Not in scope, noticed:** nothing is drawn for untouched notes, so on an item with no edits every setting still appears to do nothing. A hint for that case (for example in the settings' tooltips) is not added here.
- **Not in scope:** dragging a span's edge to set the value on the canvas; a separate Layers entry for highlights; any change to how the correction is calculated.
- **Doc placement:** a third design doc for this script, kept apart from `pitch-correct.md` and `pitch-correct-shortcuts.md` because each describes a different change.
- HC6 conflicts: None.
