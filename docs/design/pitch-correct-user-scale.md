# Design: Fancy Pitch Correct — Custom scale notes

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (the note-name column of the note canvas and the top bar's Scale combo)
Status: Draft
Date: 2026-11-27
Approver:

## Summary

The Scale list offers fixed scales and modes. A song that leaves them (a borrowed note, a blues note, a melody that avoids one degree) has no fitting choice, so Classic and Hard correction pull notes to the wrong place. This design lets the user switch single notes in or out of the scale by clicking their names in the note-name column at the left of the note canvas. The Scale box then reads "Custom" until a scale is picked from the list again. A custom set belongs to the item and becomes its track's scale, so later items on that track start with it. The window's primary display (the note canvas) and primary action (dragging a note) do not change.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Click a note name in the note-name column: that note, in every octave, goes in or out of the scale | the open item's Key, Scale and custom notes | the item's custom notes (stored beside its Key and Scale, relative to the Key); its pitch envelope when it has Classic or Hard notes; the track's record (Key, Scale, custom notes), created if the track has none | take and track data inside one undo block | Y: one undo block on project objects; the model reloads on `GetProjectStateChangeCount`; no ExtState |
| Scale box reads "Custom" while the open item uses its own notes | the item | nothing | none | n/a |
| Pick a scale from the Scale list while "Custom" shows: the custom notes are dropped | the item | the item's Scale, its custom notes removed, the envelope and the track's record as for any scale change | inside the existing "Set Scale" undo block | Y: unchanged scale-change behaviour plus the removed notes |
| Change Key while "Custom" shows: the custom notes move with the key (they are kept as steps from the key note) | the item | as any key change | inside the existing "Set Key" undo block | Y |
| A new item on a track whose scale is custom starts with that custom set | the track's record | at Analyze, the item's Key, Scale and custom notes | inside the analysis's undo block | Y |
| Re-Analyze keeps the item's own custom notes (as it keeps its Key and Scale) | the item | as today | as today | Y |
| Find Range and Key Again replaces the track's key and scale with the found ones, custom notes included; items already analysed keep theirs | the track | the track's record | inside its own undo block (existing) | Y |
| "Apply to other items" for Key and Scale carries the custom notes | the open item | the chosen items | inside the existing Apply undo block | Y |
| Hover a note name: tooltip says what a click will do | the item | nothing | none | n/a |

## References

- Native REAPER analogues: the MIDI editor's **key snap** (a root and a scale; notes outside it are greyed in the piano roll) and its piano-roll keyboard, where the key column at the left is the place to act on a pitch in every bar. Conventions matched (CN6): note names as the script already shows them, left-click only, no Alt / Shift repurposing, right-click left free for a context menu. dB and pan do not appear.
- Redesigns only: baseline capture: the note canvas in real REAPER, 2026-11-27 (note-name column at the left with in-scale names bright, out-of-scale names dim, the key note marked; display only, no mouse behaviour), kept in the session scratchpad. `ds-lint.py` summary: not available (see Open questions).

## Context and job stories

Confirmed in chat on 2026-11-27: "what about manually enabling notes in the note arrange window? … it would just show custom in the drop down until someone chose one of the others"; a custom set becomes the track's scale. Lives in the existing note canvas; used now and then, on songs the fixed scales do not fit; mouse; playback may be running.

1. When a melody borrows one note from outside its scale, I want to switch that note on, so Hard correction stops pulling it away.
2. When a singer never uses one degree, I want to switch it off, so near misses snap to the notes actually sung.
3. When I have built a set for one take, I want the other takes on the track to start with it, so I do not rebuild it.
4. When I change my mind, I want to pick a normal scale again, so the custom set is simply gone.
5. When playback is looping and the window is docked, I want one click per note, so I can hear the result at once.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | The note-name column showing which notes are in the scale (existing); "Custom" in the Scale box while a custom set is in use | Read on every correction |
| 2 one disclosure away | Click a note name to switch it; the hover tooltip that says so; picking a scale to leave Custom | Occasional |
| 3 Settings | Nothing | No setting |

## Information architecture

Regions (both exist):

1. **Note-name column** (left edge of the note canvas): each row is now a click target. In-scale and out-of-scale rows keep their existing look; the hovered row is highlighted.
2. **Scale combo** (top bar): its box reads "Custom" while the open item uses a custom set. The list holds only the real scales; "Custom" is never an entry. Picking any scale leaves Custom.

Primary display: the note canvas. Primary action: dragging a note. Disclosure: none added (IA2 OK).

## Wireframes

### Default floating / wide docked

```
[07_LeadVox.wav] [C ▾] [Custom    ▾] [A3–F4] │ This item │ …
┌──────┬───────────────────────────────────────────────────────────┐
│ D4   │                                                           │
│ C#4  │  ← dim: not in the scale. Hover: "Click to put C# in the  │
│▌C4   │     scale"                              ▌ = the key note   │
│ B3   │                                                           │
│ A#3 ◂│  ← hovered row highlighted, hand cursor                   │
│ A3   │                                                           │
└──────┴───────────────────────────────────────────────────────────┘
 Scale is now Custom: A# is out. 3 Classic / Hard notes follow. Cmd+Z to undo.
```

### Narrow docker (~260 px)

The note-name column keeps its width (it is sized to the longest note name), so the click target does not shrink. The Scale box is as wide as its longest label; "Custom" is shorter than "Minor Pentatonic", so nothing changes. The status message is truncated with its full text in a tooltip, as today.

### Wide short strip (e.g. 1200×150)

Few rows are visible, each still a full click target. When the canvas shows the Analysis Settings form instead of notes (an item not analysed yet), there is no note-name column and so no custom editing: a custom set is made on an analysed item.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Note-name column | empty (no item, or item not analysed) | The column is not drawn (existing); nothing to click | ST6 |
| Note-name column | working (an analysis runs) | The Analysis card covers the canvas; clicks do not reach the column | ST3 |
| Note-name column | hover | The row is highlighted, the cursor is a hand, the tooltip says "Click to take A# out of the scale" / "Click to put C# in the scale" | MT2, RC1 |
| Note-name column | disabled with reason: the last note | Hovering the only note left: "The scale needs at least one note"; a click does nothing | EP2 |
| Note-name column | error: the item is gone or its track is locked | The existing status messages of a scale change ("This item is no longer in the project", the envelope message); nothing is written | ST7 |
| Scale combo | custom set in use | The box reads "Custom"; its tooltip lists the notes: "Custom: C D E G A. Pick a scale to replace it." | ST1, ST4 |
| Scale combo | overflow / long names | n/a: "Custom" is shorter than the longest scale name | LG4 |
| Status line | after a click | "Scale is now Custom: A# is out. Cmd+Z to undo." / "… C# is in. …"; with Classic or Hard notes: "… 3 Classic / Hard notes follow. …" | ST2 |
| Status line | back to a listed scale that matches | When the notes left on equal a listed scale of this key, the box still reads "Custom" (the set is the user's own until a scale is picked) | ST4 |
| All | missing dependency | None new | HI7 |
| All | Fancy Dark / Match Theme | The hover highlight uses the canvas palette's existing hover colour | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Note name (a row of the note-name column) | Click: in / out, for that note in every octave. No drag, no double-click, no modifier. HC2 / HC3 n/a: not a value control. Wheel over the column scrolls the canvas as today | In or out as the item's scale says | Note names without octave in messages ("A#") | At least one note stays in | "Set Scale Notes" | No confirm: one undo block holds the item, its envelope and the track's record; nothing outside the project. Status message posted |
| Scale combo while Custom | Click a scale: leaves Custom. HC2 / HC3 n/a: discrete | "Custom" shown as the box's text only | Scale names as today | Real scales only | The existing "Set Scale" | As today |
| Key combo while Custom | Click a key: the custom notes move with it | As today | As today | As today | The existing "Set Key" | As today |

Keyboard map: no new shortcut; Esc (HC5) and Space (HC6) unchanged. The Info modal's gesture list gains "Click a note name: in or out of the scale" (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | "Custom" (the Scale box's text while a custom set is in use; also the scale's name in the Analysis card and messages: "C Custom") |
| tooltips | note name, in the scale: "Click to take A# out of the scale" · not in the scale: "Click to put C# in the scale" · the last note: "The scale needs at least one note" · Scale box while Custom: "Custom: C D E G A. Pick a scale to replace it." |
| empty / error / confirm | none new |
| status messages | "Scale is now Custom: A# is out. Cmd+Z to undo." · "Scale is now Custom: C# is in. Cmd+Z to undo." · with Classic / Hard notes: "Scale is now Custom: A# is out. 3 Classic / Hard notes follow. Cmd+Z to undo." (1 note: "1 Classic / Hard note follows.") |
| undo labels | "Set Scale Notes" |
| Info modal | "Click a note name: in or out of the scale" |

"Cmd" reads "Ctrl" on Windows and Linux (the script's existing modifier label).

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Note-name row hit area | `reaper.ImGui_InvisibleButton` per visible row (the column's existing geometry), `reaper.ImGui_SetMouseCursor` hand | the column's existing width and row height |
| Hover highlight | the canvas draw list, over the row | the canvas palette's existing hover colour key |
| In / out look, key-note mark | unchanged existing drawing | existing `gutter_*` canvas palette keys |
| Row tooltip | `Theme.tooltip` behind `HoveredFlags_ForTooltip` | n/a |
| "Custom" in the Scale box | `Theme.combo` with its placeholder option carrying the text (no list entry) | n/a |
| Scale box tooltip | the combo's existing tooltip option | n/a |
| Status messages | the window's existing status line | `P.text_dim` |

## Library proposals

None.

## Acceptance criteria

- ST1: the Scale box says "Custom" at rest while a custom set is in use.
- ST2: every click is answered by the column redrawing at once and a status message.
- ST3: n/a: a click is instant.
- ST4: the box shows "Custom" exactly when the item's own notes are in effect; the column shows the notes in effect.
- ST5: n/a: no lifecycle change.
- ST6: n/a: no new region; the column is not drawn without notes, as today.
- ST7: a failed write says why in the status line and changes nothing.
- UC1: one undo point per click, "Set Scale Notes"; none when the click does nothing (the last note).
- UC2: see HC5.
- UC3: item, envelope and the track's record are written in one undo block; the model reloads on project state change; no ExtState.
- UC4: the item and track selection are never changed.
- UC5: n/a: no value control; picking a scale is the way back.
- EP1: n/a: nothing destructive needing a confirm (see HC4).
- EP2: the last note explains why it cannot be switched off.
- EP3: at least one note always stays in the scale.
- EP4: items and tracks are referenced by GUID.
- EP5: no control is added, hidden or moved.
- EP6: n/a: no new shortcut.
- CN1: only existing `Theme.*` helpers.
- CN2: tokens only; no modal.
- CN3: every helper and palette key named in Theme mapping exists.
- CN4: "Custom" is the one word for the user's own set; "in" / "out" for a note.
- CN5: the Info modal and CHANGELOG describe the gesture as built.
- CN6: left-click only; no Alt / Shift use; right-click stays free.
- RC1: the tooltip says what a click does; the Info modal lists the gesture, so it is not tooltip-only.
- RC2: note names, no pitch-class numbers.
- HP1: the Info modal lists "Click a note name: in or out of the scale".
- EF1: n/a: no value control; the wheel over the column scrolls as today.
- EF2: see HC6.
- EF3: zoom, scroll and the ruler are unchanged; the click does not start a canvas drag.
- IA1: tiers as listed.
- IA2: no disclosure added.
- IA3: no new type size, weight or accent.
- IA4: no developer toggle; nothing that does nothing.
- LG1: n/a: no new group.
- LG2: n/a: no new framed row.
- LG3: the Scale box's width still comes from its longest label.
- LG4: the column keeps its width at every window width.
- MT1: each row is a full-width target of the column; when rows are shorter than the minimum target height the tooltip still names the note under the pointer.
- MT2: each row has an `InvisibleButton` hit area, a hover state, a hand cursor and a tooltip.
- CL1: see HC1.
- CL2: in / out is shown by the existing bright / dim names and, in the tooltip, in words.
- CL3: no red is used.
- CL4: the hover highlight comes from the canvas palette; checked in Fancy Dark and Match Theme.
- DV1: n/a: excluded for this archetype.
- HI1: n/a: no new window or child.
- HI2: n/a: no new window.
- HI3: n/a: no toolbar or close change.
- HI4: written once per click, never per frame.
- HI5: hit areas only for visible rows; nothing enumerated per frame beyond the rows already drawn.
- HI6: row buttons use stable IDs from the MIDI note number.
- HI7: n/a: no new dependency.
- AR (Editor / canvas): note objects keep their gestures; a click on the column never selects, moves or deselects a note.
- HC1: the hover highlight keeps the note name at 4.5:1 or better in both theme modes.
- HC2: n/a: no parameter value control.
- HC3: n/a: no parameter value control.
- HC4: no confirm: one undo block restores the item, its envelope and the track's record; no ExtState / JSON / file / cache change; a status message is posted.
- HC5: unchanged.
- HC6: unchanged.

## Open questions / assumptions

- **Decided by the user (2026-11-27):** a custom set becomes the track's scale; "Custom" shows in the Scale box until another scale is chosen.
- **Assumption (my call): a click applies to that note in every octave.** A scale is a set of note names, not of single pitches.
- **Assumption (my call): the custom notes are kept as steps from the key note**, so changing Key moves them, like any scale.
- **Assumption (my call): a custom set always updates the track's record**, creating one if the track has none, so later items on that track start with it. This is wider than a plain key change, which only updates the track when the item still follows it.
- **Assumption (my call): custom notes are made on an analysed item only**, because the note-name column exists only when notes are shown.
- **Assumption (my call): the box keeps reading "Custom" even when the notes left on happen to equal a listed scale**; picking that scale from the list is how to name it.
- **Assumption (my call): Find Range and Key Again replaces a track's custom set** with the found key and scale; items already analysed keep theirs.
- **Assumption (my call): one undo point per click.** Several clicks in a row are several undo points.
- `ds-lint.py` baseline: not available. The linter stops with "theme.lua palette drifted from ds-lint's port of build_palette" (a tooling issue, recorded since 2026-11-24).
- HC6 conflicts: None.
