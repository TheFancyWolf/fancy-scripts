# Design: Fancy Pitch Correct — draggable pitch points

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); point menu → popup of the same window (same archetype)
Status: Approved
Date: 2026-11-20
Approver: TheFancyWolf (in chat, 2026-11-20)

## Summary

The yellow dots and cyan diamonds on a note stop being markers and become **pitch points**: handles that bend the pitch at one moment of a note. Dragging one up or down moves the pitch fully at that point and eases to nothing at the points on either side; double-clicking the note's pitch line adds a point of your own. It is for fixing one swing that sticks out, a sag or creep inside a held note, and the start or end of a note, without changing the rest of the note. The window's primary display (the note canvas) and primary action (dragging a note) do not change. A point edit is one more per-note correction: it shows in the green Preview Curve and is written to the item on release as one undo step.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Drag a pitch point (vertical) | none new (the analysed note in memory) | take pitch envelope points; the note model on the take | take data (`P_EXT`), inside the edit's undo block | Y: one undo block holds envelope and model; the script reloads the model when the project state changes; nothing else is stored |
| Add a pitch point (double-click the pitch line, or note menu) | none new | the note model on the take (the envelope is rewritten, unchanged in value) | take data, inside the undo block | Y: as above |
| Reset a pitch point (double-click it, or point menu) | none new | envelope points; note model | take data, inside the undo block | Y |
| Remove an added pitch point (point menu) | none new | envelope points; note model | take data, inside the undo block | Y |
| Type a point's value (point menu, Offset) | none new | envelope points; note model | take data, inside the undo block | Y |
| Reset Pitch Points of a note (note menu) | none new | envelope points; note model | take data, inside the undo block | Y |
| Existing "Reset to Original" (`R`) also clears the note's pitch points | as today | as today | as today | Y (as today) |
| Existing Split, Merge and Trim keep the bend: each point stays at its time, a point is kept or set where an edge moves or disappears so the pitch inside what remains does not change, and Trim drops points left outside the note | as today | as today | as today | Y (the points are part of the note model those actions already write) |
| "Pitch Points" layer toggle (today "Pitch Center Spots" under Settings → Diagnostics) moves to the Layers menu | none | none | ExtState, the existing key (unchanged) | n/a: a view preference, never part of undo (as every layer toggle today) |
| Existing, unchanged: note drags and their zones, Shift+Drag, edge trims, marquee, the note menu's other entries, every key, the top bar, the write on release | as today | as today | as today | as today |

**What a pitch point is.** A note carries a pitch-offset curve of its own. Its points are: the note's start and end (the cyan diamonds), every detected peak and valley (the yellow dots), and every point the user added. Each point has an offset in cents, 0 until moved. Between two neighbouring points the offset eases smoothly from one value to the other (flat at both points, never overshooting), so a moved point changes the pitch only as far as the point on either side of it.

**How it combines with the rest of the correction.**
- It is added on top of the note's pitch shift, Stability, Vibrato and Scoop, as the last step, so a hand-set point is the final word at its moment.
- It is literal: Strength does not scale it. A point that reads +20¢ aims the note +20¢ at that moment, and that is what is written everywhere outside a glide (next bullets).
- A note with any point off zero counts as edited (green, edit mark, correction written), like any other edit. A bypassed note ignores its points.
- **Ramps and glides keep their shape.** The onset and release ramps and the glides between joined notes start from and arrive at the note's edge values exactly as today. So on a side where the note is joined to its neighbour, a move of the start or end point, or of a point within half a Transition of that edge, is reached half a Transition inside the note and blended into the neighbour's edge by the glide, like every other edit of a joined note. A shorter Transition tightens it.
- **On a side that is not joined**, a note with a point off 0 is written moment by moment right up to its edge, so points near the start or end of a free-standing note land exactly.
- **Notes without points are written exactly as today.** No existing item changes or is reported as outdated by this feature.
- The Preview Curve stays what is written to the item.

## References

- Native REAPER analogue: envelope points on a take or track envelope (drag a point vertically; double-click a point resets it to the default value; double-click the envelope adds a point). Conventions matched (CN6): Ctrl/Cmd-drag is fine adjust; right-click opens a menu; Shift and Alt keep their current meanings (a press with Shift held never grabs a point); values are shown in cents with a sign, as the note readout already does. Deviation recorded: REAPER deletes a point with Alt+click; here Alt is not used (HC2), removal is in the point menu.
- Baseline capture: the user's screenshot of 2026-11-19 (one selected note "B3 -5¢", seven yellow dots on the white pitch trace, a cyan diamond at each end of the note). `ds-lint.py` summary: did not run ("theme.lua palette drifted from ds-lint's port of build_palette"), so there is no mechanical baseline; that is a tool fault, separate from this design.

## Context and job stories

Confirmed at the checkpoint (2026-11-19): the goals are one swing that sticks out, a sag or creep inside a note, and note starts and endings (free redrawing of the pitch was not chosen); draggable points are the detected dots plus points the user adds; a press on a dot always grabs the dot. Carried over from the earlier Pitch Correct designs and not contradicted: lives on the existing canvas, used all session, during playback, by mouse.

1. When one swing in a held note pokes out sharp or flat, I want to drag just that peak or valley, so I can fix it and keep the rest of the note's vibrato.
2. When a note sags or creeps between two dots, I want to add a point there and pull it, so I can leave the note's Stability as it is.
3. When a note slides in or falls off badly, I want to drag its start or end point, so I can shape the entry or exit by hand.
4. When playback loops over the phrase, I want to hear the change as soon as I release the drag, so I can tune by ear.
5. When I dislike a move, I want double-click to put that point back, one menu entry to clear the note's points, and Cmd+Z to step back, so trying things is safe.
6. When I am moving whole notes, I want the points to stay out of the way, so note editing is as quick as today.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Pitch points on the hovered and the selected notes; drag; the cents readout while dragging; double-click to reset or add | The whole feature is these gestures; used many times per phrase |
| 2 one disclosure away | Point menu (Offset, Reset Point, Remove Point); note menu entries "Add Pitch Point Here" and "Reset Pitch Points (N)" | Exact values and clean-up: a few times per session |
| 3 Settings | None. The "Pitch Points" toggle sits in the Layers menu with the other canvas layers | It is a layer the user edits, not a diagnostic |

## Information architecture

Regions touched (the window's regions are unchanged):

1. **Note canvas, points layer.** Shown, as today, only on the hovered note and the selected notes. Layer order, bottom to top: rows, note blocks, vibrato shading, highlight spans, pitch trace, trend, Preview Curve, point stems, points, pills.
2. **Point menu** (right-click a point): one value row and two commands.
3. **Note menu** (right-click a note): two entries added after "Split at Cursor", before "Reset to Original".
4. **Layers menu:** one entry, "Pitch Points", with a swatch (a yellow dot), after "Preview Curve". The entry "Pitch Center Spots" leaves Settings → Diagnostics.
5. **Help modal and Shortcuts panel:** rows for the new gestures.

Primary display: the note canvas (unchanged). Primary action: dragging a note (unchanged). Disclosure levels: hover or select a note to see its points (level 1), right-click a point for its menu (level 2) (IA2).

**Where a point is drawn.** At its time, at the pitch the note aims for at that moment (the sung pitch plus the note's own correction there). On a note with no correction that is the white pitch trace, exactly as today; on a corrected note it is the Preview Curve, except inside a glide at a joined edge, where the Preview Curve shows the blend toward the neighbour and the point shows what this note aims for (as the note block itself does). A moved point carries a **stem**: a thin vertical line as long as the point's own offset, from where the point would sit at 0 to where it sits now. The stem, not a colour, says "this point was moved".

**Shapes** (CL2, shape and not colour alone):

| Shape | Meaning |
|---|---|
| ● circle | a detected peak or valley |
| ◆ diamond | the note's start or end |
| ■ square | a point the user added |
| □ hollow square | where a double-click would add a point (shown only while the pointer rests on the pitch line) |
| stem | the point is moved off 0 |

**What wins under the pointer** (confirmed: the dot always wins). In this order: a pitch point of a note whose points are shown → the note's edge handles → the note's three drag zones → empty canvas. A note's points stay shown while the pointer is inside the box around the note block and its points (padded by the grab distance), so a dot above or below the block does not vanish as the pointer leaves the block toward it.

**Room for the note.** Where a point lies over its note's block, its grab area never takes more than half the block's height, so the trim handle under a start or end point and the note's drag zones under a dot keep at least half of the height. Sideways it never reaches past the midpoint to the neighbouring point.

**Too small to grab.** When a semitone row is shorter than one grab distance, or a note's points are on average closer together than one grab distance, that note's points are drawn at half size and cannot be grabbed (nor added); the note behaves exactly as today and the status hint says to zoom in. This keeps notes draggable and trimmable in compact layouts without turning the layer off.

## Wireframes

Default floating size, one selected note with one moved valley and one added point (`┊` = stem):

```
┌ FANCY PITCH CORRECT ─────────────────────────────── Info  Settings  × ┐
│ Global · Strength 100% · Transition 35ms · Onset Ramp 35ms · …        │
├────┬─────────────────────────────────────────────────────┬────────────┤
│    │ 0:01        0:02        0:03        0:04            │ SHORTCUTS  │
│ C4 │                                                     │ …          │
│    │  B3 -5¢    ●                    ●        ●          │ Pitch point│
│ B3 │ ◆▓▓▓▓▓▓▓▓▓/▓\▓▓▓▓▓▓■▓▓▓▓▓▓▓▓▓▓▓/▓\▓▓▓▓▓▓/▓\▓▓▓▓▓◆    │  Drag dot  │
│    │ ▓▓▓▓▓▓▓▓▓/▓▓▓\▓▓▓▓/┊\▓▓▓●▓▓▓▓▓/▓▓▓\▓▓▓▓/▓▓▓\▓▓▓▓     │ …          │
│ A#3│           ●  \  / ┊ \_/ ┊\___/     ●──/               │ PITCHED    │
│    │               \/  ┊     ┊            [ +23¢ · B3 -2¢ ]│ ITEMS      │
│    │ [ Drag a point to bend the pitch there ]             │ …          │
└────┴─────────────────────────────────────────────────────┴────────────┘
```

Point menu (opens at the pointer, sized by its content):

```
┌──────────────────────────────┐
│ Offset  [   +23 ¢   ]        │
│ ──────────────────────────── │
│ Reset Point                  │
│ Remove Point                 │
└──────────────────────────────┘
on a detected point or a start / end point:
│ Remove Point   detected points stay │   (disabled, reason beside it)
on a point at 0:
│ Reset Point    already at 0         │   (disabled, reason beside it)
```

Note menu (existing entries unchanged; two added):

```
│ Snap to Semitone            S │
│ Quantize to Scale           Q │
│ Split at Cursor             X │
│ Add Pitch Point Here          │
│ Reset Pitch Points (3)        │   at 0 points: disabled, "none moved or added" beside it
│ Reset to Original           R │
```

Narrow docker (~260 px): the right panel is hidden by the existing rule and the canvas takes the width. A note is a few dozen pixels wide, so its points crowd:

```
┌ FANCY PITCH CORRECT ──── … × ┐
│ Global · Strength 100%  [Timing]│
├───┬───────────────────────────┤
│ B3│ ·······    ◆ ● ● ● ◆      │
│   │ [ Zoom in to move pitch… ] │
└───┴───────────────────────────┘
```

Every point is still drawn. On a note whose points are on average at least one grab distance apart they stay grabbable (the grab area never reaches past the midpoint to the neighbour). On a note where they are closer, as the left one here, they are drawn at half size and are not grabbable; the status hint reads "Zoom in to move pitch points" and `Z` zooms to the selection. The hollow add-square is not offered within the minimum gap of an existing point. The readout pill and the status pill keep their existing clamping to the note area; the point menu's content is narrower than the docker (RB9 does not apply: it is a popup, not a modal).

Wide short strip (1200 × 150): the pitch axis is short, so one pixel is many cents.

```
┌ FANCY PITCH CORRECT · Global · Strength 100% · Transition 35ms · …                     × ┐
│ B3 │ ·──·──·──·──·──·──·──·        ·──·──·──·        [ Zoom in to move pitch points ]   │
└────┴──────────────────────────────────────────────────────────────────────────────────┘
```

Nothing hides. With the pitch axis this short a semitone row is shorter than one grab distance, so the points are drawn at half size and are not grabbable: notes drag and trim exactly as today, and the status hint names the way out (Alt+Wheel zooms the pitch axis). Once a row is at least one grab distance tall the points are live; the drag stays 1:1 with the pitch scale as for a note, and Cmd-drag (fine) and the point menu's Offset field give exact values on short rows.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Canvas points | empty | A note too short to have a peak or valley shows its two diamonds only; they are draggable. An item with no notes keeps today's canvas message. With the layer off no point is drawn or grabbable; the Preview Curve still shows what moved points do | ST6 |
| Canvas points | working | n/a: the write on release takes well under 1 s, as every note edit today | ST3 |
| Canvas points | error | Double-click on a stretch with no detected pitch: status pill "No pitch detected here: a point needs a pitch to sit on." | ST7 |
| Canvas points | disabled with reason | On a bypassed note the points are drawn but a press on one posts "This note is bypassed, so its pitch points do nothing. Right-click the note to turn bypass off." on the status pill (visible with tooltips off) and falls through to the note. Under the script's Bypassed overlay the canvas is inert as today | EP2 |
| Canvas points | overflow / long names | Many points at low zoom, a narrow docker or a short strip: all drawn. Where a note's points are too close together or its row too short (see "Too small to grab") they are drawn at half size, are not grabbable, and the status hint reads "Zoom in to move pitch points". Otherwise the grab area is capped at half the gap to the neighbour and half the block's height. The readout pill is clamped to the note area as today | LG4 |
| Canvas points | missing dependency | n/a: nothing new is required | HI7 |
| Canvas points | Fancy Dark / Match Theme | Points, stems and the add-square use the existing canvas palette keys, which are fitted for contrast in Match Theme | CL4 |
| Point menu | empty | n/a: it opens only on a point | ST6 |
| Point menu | disabled with reason | "Remove Point" on a detected or start / end point: disabled, "detected points stay" beside it. "Reset Point" at 0: disabled, "already at 0" beside it | EP2 |
| Point menu | overflow / long names | n/a: fixed short strings | LG4 |
| Point menu | Fancy Dark / Match Theme | Standard popup colours from the theme push | CL4 |
| Note menu | disabled with reason | "Reset Pitch Points (0)": disabled, "none moved or added" beside it. "Add Pitch Point Here" where there is no pitch or a point already sits: disabled, "no pitch here" or "a point is already here" beside it | EP2 |
| Layers menu | Fancy Dark / Match Theme | "Pitch Points" swatch drawn with the same palette key as the dots | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Pitch point (circle, diamond, square) on the canvas | Press and drag vertically: the point follows the pointer on the pitch scale; the Preview Curve follows live; written on release. Ctrl/Cmd held: fine, with the note drag's fine factor (HC2). Double-click: back to 0 (HC3 reset). Right-click: point menu. A press with Shift held is not a point press (it goes to the note beneath, as today). A Ctrl/Cmd press on a point never drops notes from the selection: if it becomes a drag, the point's note is added to the selection and the point is fine-dragged; released without dragging it is today's Ctrl/Cmd-click on the note beneath (toggle), or nothing where no note is beneath. Typed entry is in the point menu. Wheel: n/a, the canvas scrolls. Horizontal movement is ignored: a point does not move in time. A dead zone of the note drag's size separates a click from a drag. A plain press on a point of a note that is not selected selects that note alone; on a selected note the selection is kept. Only the pressed point moves, whatever is selected | 0 ¢ | Readout pill beside the pointer while dragging: signed whole cents of the point, then the resulting pitch there, `+23¢ · B3 -2¢` | ±300 ¢, linear, held at the limit | "Move Pitch Point"; none if the value did not change | n/a: not destructive |
| Pitch line of a note (the corrected pitch between its points) | Pointer within the grab distance of the line, no point under it: a hollow square shows on the line at the pointer's time, snapped to the nearest analysed moment. Double-click: adds a point there at 0 ¢. This takes the double-click from "Snap to Semitone" only on the line itself; a double-click elsewhere in the note's centre still snaps. A single press there drags the note as today | no added points | n/a | A point cannot be added closer than three analysed moments (roughly 20 to 35 ms) to another point, or where no pitch was detected | "Add Pitch Point" | n/a |
| Point menu → Offset | Drag (Ctrl/Cmd-drag fine), Ctrl/Cmd-click types a number, double-click resets to 0: the script's existing value-drag control (HC2, HC3). Live preview on the canvas, written on release or Enter | 0 ¢ | `%+.0f ¢` | ±300 ¢, always clamped, linear | "Move Pitch Point"; "Reset Pitch Point" on double-click | n/a |
| Point menu → Reset Point | Click | n/a: command | n/a | Disabled at 0, reason inline | "Reset Pitch Point" | No confirm: one Ctrl/Cmd+Z restores it and nothing else is stored (HC4). Status message posted |
| Point menu → Remove Point | Click. Added points only | n/a: command | n/a | Disabled on detected and start / end points, reason inline | "Remove Pitch Point" | No confirm (HC4, as above). Status message posted |
| Note menu → Add Pitch Point Here | Click: adds a point at the time the note was right-clicked (same rule as the double-click) | n/a: command | n/a | Disabled with reason where the double-click would refuse | "Add Pitch Point" | n/a |
| Note menu → Reset Pitch Points (N) | Click: every point of the menu's note back to 0 and every added point removed. N = points off 0 plus added points | n/a: command | N as a whole number | Disabled at N = 0, reason inline | "Reset Pitch Points" | No confirm (HC4, as above). Status message names the count |
| Existing: Reset to Original (`R`, Backspace, Delete, note menu) | As today; it now also clears the note's pitch points, and a note whose only change is its points counts as changed | as today | as today | as today | "Reset Pitch Correction" (unchanged) | As today |
| Layers menu → Pitch Points | Checkbox, as the other layers | on (the stored value of today's toggle is kept) | n/a: discrete | n/a | none (view only) | n/a |

Keyboard map: no new keys. Esc (HC5): an open point menu closes first; then, new, Esc during a point drag puts the point back where it was and writes nothing (active edit reverts); then selection, then the window when floating, as today. Space is forwarded as today (HC6), also during a point drag. A press with Shift held never grabs a point; Ctrl/Cmd on a point means fine adjust and nothing else. No key repeats are added (EP6). Every gesture above gets a row in the Help modal, and one row in the Shortcuts panel (HP1).

Hover feedback: a point under the pointer grows from the dot size to the diamond size and gains an outline, the cursor becomes the vertical resize arrows (the note pitch drag's cursor), and after the usual delay a tooltip names the gestures. While dragged the point keeps the hover look.

## Copy deck

| Where | String |
|---|---|
| labels | Layers menu: `Pitch Points` · Point menu: `Offset`, `Reset Point`, `Remove Point` · Note menu: `Add Pitch Point Here`, `Reset Pitch Points (3)` |
| tooltips | Point: `Drag to bend the pitch here (Cmd = fine). Double-click: reset. Right-click: menu` (the modifier is named per platform) · Pitch line with the hollow square: `Double-click to add a pitch point` · Layers entry: `The points on a note that bend its pitch: peaks and valleys, the note's start and end, and points you add` |
| empty / error / confirm | Inline reasons: `already at 0` · `detected points stay` · `none moved or added` · `no pitch here` · `a point is already here` · Status: `No pitch detected here: a point needs a pitch to sit on.` · `This note is bypassed, so its pitch points do nothing. Right-click the note to turn bypass off.` · No confirm dialogs |
| status messages | `Reset the pitch point. Cmd+Z to undo` · `Removed the pitch point. Cmd+Z to undo` · `Reset 3 pitch points on B3. Cmd+Z to undo` · after a trim that left points outside the note: `Trimmed the note. 2 pitch points outside it were removed. Cmd+Z to undo` · Drag readout pill: `+23¢ · B3 -2¢` · Status hint while a point is hovered: `Drag a point to bend the pitch there` · Status hint on a note whose points are too small to grab: `Zoom in to move pitch points` |
| undo labels | `Move Pitch Point` · `Add Pitch Point` · `Reset Pitch Point` · `Remove Pitch Point` · `Reset Pitch Points` |
| Help modal rows | `Drag a pitch point` — `Bend the pitch at that moment (Cmd = fine)` · `Double-click a pitch point` — `Put it back to 0` · `Double-click the pitch line` — `Add a pitch point` · `Right-click a pitch point` — `Point menu: type a value, Reset, Remove` |
| Shortcuts panel row | group Edit: `Pitch point` — `Drag dot` |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Detected point (circle), added point (square) | none: canvas draw list, as today | canvas palette `spot`; radius `Theme.layout.sm` (the existing dot size) |
| Start / end point (diamond) | none: canvas draw list, as today | canvas palette `anchor`; half-diagonal `Theme.layout.sm` + `Theme.layout.xs` (the existing diamond size) |
| Hovered or dragged point | none: canvas draw list | fill as at rest, drawn at the diamond size; outline canvas palette `handle_hover` |
| Stem | none: canvas draw list | canvas palette `spot` for dots and squares, `anchor` for diamonds |
| Hollow add-square | none: canvas draw list | outline canvas palette `spot`; size as the dot |
| Grab distance | none | `Theme.layout.sm` × 2 (the note edge grab size), capped at half the gap to the neighbouring point |
| Readout pill, status pill | the script's existing canvas pill helpers | canvas palette `pill_text` and the pill's existing keys |
| Point tooltip, pitch-line tooltip, Layers tooltip | `Theme.tooltip` (behind a hover check with the for-tooltip flag, RB15) | theme defaults |
| Point menu, note menu entries | stock popup and menu items, as the note menu today; Offset uses the script's existing value-drag control | theme push defaults; inline reasons in the disabled text colour |
| Layers menu entry and swatch | the script's existing layer checkbox with a swatch | canvas palette `spot` |

## Library proposals

None. Every colour and size is an existing canvas palette key or layout token.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | A note with moved points shows as edited at rest (green block, edit mark, Preview Curve through the moved shape); on a hovered or selected note each moved point carries its stem |
| ST2 | A point press, drag, double-click and every menu command changes the canvas in the same frame; Reset and Remove also post a status message; a refused add or a press on a bypassed note's point posts a status message, never a silent return |
| ST3 | n/a: the write on release is as fast as a note edit |
| ST4 | The readout shows the point's own offset and the pitch the note aims for there; the Preview Curve is what is written, including the blend inside a glide at a joined edge; Strength is not applied to points and the readout does not pretend otherwise |
| ST5 | n/a: lifecycle unchanged |
| ST6 | A note with no peaks shows its two diamonds; no blank state is added |
| ST7 | "No pitch detected here…" and the bypass message are in the window, in user terms |
| UC1 | One named undo point per drag, add, reset, remove, typed value and Reset Pitch Points; none when the value did not change (a click without a drag, a drag back to the start, Esc); no undo block opened while dragging |
| UC2, HC5 | Esc: point menu → point drag (revert) → selection → window when floating; all through `Shortcut()` |
| UC3 | Points are stored in the note model on the take, written inside the edit's undo block; the script's existing reload on project state change restores them on undo and redo |
| UC4 | REAPER's item, track and time selection are never changed by a point gesture |
| UC5, HC3 | Double-click a point: back to 0, one undo point. The Offset field in the point menu resets on double-click and takes a typed value on Ctrl/Cmd-click. "Reset Pitch Points" resets the note's group |
| EP1, HC4 | Reset Point, Remove Point and Reset Pitch Points need no confirm: all their writes are in one undo block, the model reloads on project state change, and no ExtState, JSON or file is touched; each posts a status message |
| EP2 | Every disabled menu entry shows its reason beside it; the bypassed-note reason is on the status pill, so it is visible with Show Tooltips off |
| EP3 | Offsets are held within ±300 ¢ on the canvas and in the Offset field (always clamped, linear) |
| EP4 | A point belongs to its note in the take's model (takes by GUID as today); a point is identified by its time, not by a list position |
| EP5 | Menu entries are disabled with a reason, never hidden; points appear only by hover / selection (the existing disclosure) and the layer toggle |
| EP6 | No new keys; Esc during a point drag goes through `Shortcut()`; a Shift press is left to the note |
| CN1 | Tooltips through `Theme.tooltip`; the Offset field is the script's existing value-drag control; no hand-built substitute for an existing helper |
| CN2, CN3 | Tokens and existing palette keys only; no new colour, size or font |
| CN4 | One term: "pitch point" ("point" inside its own menu). "Pitch Center Spots", "smart spots" and "anchor" no longer appear in user-facing text |
| CN5, HP1 | The Help modal lists the four gestures and the Shortcuts panel one row; they match the handlers; the CHANGELOG entry matches the code |
| CN6, HC2 | Ctrl/Cmd-drag is fine adjust on a point and in the Offset field; Shift and Alt are not given a new meaning; right-click opens a menu; the Alt+click deviation from REAPER's envelope points is recorded under References |
| RC1 | The point shapes are explained in the Layers entry's tooltip and in the Help modal rows; nothing depends on a tooltip alone (the status hint names the drag) |
| RC2 | Cents with a sign and note names; no semitone fractions, frame numbers or internal names in any string |
| EF1 | Double-click reset, Ctrl/Cmd-drag fine, a context menu on the point and a group action on the note menu. No wheel adjust: the canvas scrolls |
| EF2, HC6 | Space forwarding unchanged, also while a point is dragged or hovered |
| EF3 | The pitch and time scales are frozen during a point drag, as for a note drag; zoom, scroll and ruler unchanged |
| IA1 | Points and their gestures Tier 1; the two menus Tier 2; nothing in Settings |
| IA2 | Two disclosure levels: hover / select, then right-click |
| IA3 | Primary display and primary action unchanged; no new text size or weight |
| IA4 | The Diagnostics entry "Pitch Center Spots" is removed from Settings (it is now a layer the user edits); no dead toggle is left behind |
| LG1, LG2, LG3 | Point menu: one value row, a separator, two commands; the inline reasons share the entries' baseline; widths come from the text |
| LG4 | Works in a ~260 px docker and a 1200 × 150 strip as wireframed: all points drawn; points too small to grab are half size and inert, with the zoom hint; notes stay draggable and trimmable; pills clamped |
| MT1 | A point's grab area is 16 px across at rest (larger than the 8 px dot), capped at half the gap to its neighbour and at half the block's height where it lies over its note; a trim handle under a start or end point keeps at least half its height; "Remove Point" is a full-width menu row |
| MT2 | Points have a rest, hover and drag look, a cursor, a tooltip, and a grab area larger than the drawn shape; hit-testing follows the canvas's existing pattern for notes and edges |
| CL1, HC1 | Points, stems and the add-square are at least 3:1 on rows and note fills in both theme modes (the palette keys are already fitted for it); readout and status text at least 4.5:1 on their pill |
| CL2 | Point kind by shape (circle, diamond, square, hollow square); moved by the stem; none by colour alone |
| CL3 | No red |
| CL4 | Checked in Fancy Dark and Match Theme |
| HI1, HI2, HI3 | n/a: window lifecycle, flags and toolbar unchanged; the point menu is a popup inside the window's visible block |
| HI4 | The model is written on release or command, never per frame; the layer toggle is saved on change |
| HI5 | The offset curve of a note is computed when its points change, not per frame; the hit-test walks only the points of the notes whose points are shown |
| HI6 | The point menu has one stable ID; "Reset Pitch Points (3)" keeps its ID as the count changes (`###`) |
| HI7 | n/a |
| RB9, RB15, RB19 | No modal is added; tooltips go through the for-tooltip hover check; every ReaImGui name is checked against the names file before use |

## Open questions / assumptions

Approaches considered (the first was chosen in chat, 2026-11-19, by the three answers at the checkpoint):

- **An offset curve through points (chosen).** Every dot is a point at 0; moving one bends the pitch between its two neighbours; the user can add points. It covers all three confirmed goals and keeps note drags as they are.
- **Scale each swing.** A dot would only shrink or grow the swing it marks. It cannot fix a sag between dots or a note's start and end, and there is nothing to add.
- **Free pitch drawing with a pencil.** Most freedom, but it needs a tool mode that takes over note drags, and "redraw the pitch freely" was not chosen.

Calls made in this doc, for you to check:

- **Double-click on the pitch line adds a point where it used to snap.** Only within the grab distance of the line (about 8 px); a double-click elsewhere in the note's centre, and the `S` key, still snap to the semitone. Say so if you would rather keep every double-click as Snap and add points from the note menu only.
- **Points sit on the corrected pitch, not on the white trace.** On a note with no correction the two are the same line, so it looks as today; once a note is shifted the points travel with it, next to the block you are editing.
- **Glides between joined notes keep their shape.** At a joined edge a point's move is blended into the neighbour over the Transition, as every edit of a joined note is today; it lands exactly only on free-standing edges and away from the glide. Reshaping the glides so a point always lands exactly would change what every existing joined item writes, so it is not done.
- **Points give way when there is no room.** A point takes at most half the block's height, and on a note whose points are too crowded or whose row is too short they are drawn small and cannot be grabbed until you zoom in. The thresholds (one grab distance, about 8 px) are starting values for the builder to tune in real REAPER.
- **Cmd/Ctrl on a point never drops your selection.** A Cmd-drag is a fine drag and adds the note to the selection; a Cmd-click without a drag still toggles the note, as today.
- **A dot that has not been moved pins the curve at 0.** That is what keeps "one swing" from leaking into its neighbours, as confirmed. The cost: lifting a long sag takes a move on each point across it (or the note's Stability drag, which exists for that).
- **Points do not move in time.** A detected point is a measurement; an added point is removed and added again to change its time.
- **Limit ±300 ¢ per point**, the same limit the Scoop pull already has. A larger move is a note shift.
- **Strength does not scale points**, and the note tone does not sound while a point is dragged (it follows the note's centre, which a point does not change).
- **Only one point is dragged at a time**, also with several notes selected. Multi-point selection is not in scope.
- **Split, Merge and Trim keep the bend you made.** The pitch inside what remains of a note does not change: a cut through a bend gives the two new edge points the value the curve had there; a merge keeps a square at the old boundary when dropping it would change the curve; a trim gives the new edge the curve's value and drops the points left outside (same undo step, status message names the count). This can leave a square you did not add yourself; it counts in "Reset Pitch Points (N)".
- **After a split, trim or merge the detected dots are measured again.** A moved or added point is kept by its exact time and value and keeps its shape (a moved dot stays a circle). A newly detected dot closer than three analysed moments to a kept point is not made a point, so two points never sit a few milliseconds apart with different values. A moved dot that is reset to 0 and has no detected dot near it any more disappears.
- **Re-Analyze discards points with the rest of the note edits**, behind its existing confirm.
- **The layer keeps its stored on/off value** and its default (on).
- **Esc reverting a drag is new for points only.** Note drags do not revert on Esc today; noticed, not changed here.
- **REAPER's default envelope mouse modifiers** (double-click a point resets it, double-click the envelope adds one) are quoted from memory; QA confirms them in Preferences → Mouse Modifiers before the reference is relied on.
- **Storage and writing** (for the builder): a per-note list of `{ time, offset in semitones, added }` in the note's controls, holding only moved and added points; older saved items have none and load unchanged. A note with a point off 0 is written as a contour (moment by moment), and up to its edge on a side that is not joined; the glide and ramp code is not changed.
- HC6 conflicts: None.
