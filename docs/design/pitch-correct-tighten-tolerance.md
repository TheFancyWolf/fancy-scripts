# Design: Fancy Pitch Correct — Tighten and Tolerance replace Stability and Vibrato

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); note menu → popup of the same window (same archetype)
Status: Approved
Date: 2026-11-20
Approver: TheFancyWolf (in chat, 2026-11-20)

## Summary

Two per-note values change what they do. Dragging the left side of a note sets **Tighten** (today: Stability): one dial that takes the note's wandering away, slowest movement first, and ends in a flat line at 100 %. Dragging the right side sets **Tolerance** (today: Vibrato): how far a tightened note may stray from its centre before anything is pulled in. Tolerance has a default of 8 ¢ in the top bar with the same Global → Item → Note chain as Strength. Stability, Vibrato and the two layers that only existed for them are removed. The window's primary display (the note canvas) and primary action (dragging a note) do not change.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Drag the left side of a note: Tighten (replaces the Stability drag) | none new (the analysed note in memory) | take pitch envelope points; the note model on the take | take data (`P_EXT`), inside the edit's undo block | Y: one undo block holds envelope and model; the script reloads the model when the project state changes; nothing else is stored |
| Drag the right side of a note: that note's Tolerance (replaces the Vibrato drag) | none new | envelope points; note model | take data, inside the undo block | Y: as above |
| Note menu → Tighten, Tolerance (value rows) | none new | envelope points; note model | take data, inside the undo block | Y |
| Top bar → Tolerance badge, item override on / off | none new | envelope points; the item's overrides in the take data | take data, inside the undo block | Y: an item override is part of the take data |
| Top bar → Tolerance badge, global default | none new | envelope points of the open item | ExtState (`pitch_tolerance`), saved when the edit is committed | N: a global default is not part of the undo history, as for Strength, Transition, Onset Ramp and Legato Gap today. Not destructive: the value is put back by setting it again or by Reset to default; the status line says so (see Interaction spec) |
| Existing "Reset to Original" (`R`) also clears the note's Tighten and its own Tolerance | as today | as today | as today | Y (as today) |
| Existing Split, Trim and Merge carry both values over | as today | as today | as today | Y |
| Removed: the Stability drag and the Vibrato drag, their readouts, tooltips and Help rows | n/a | n/a | values stored on notes by earlier builds are ignored and not written again | n/a |
| Removed: "Vibrato Shading" (Layers menu) and "Trend Line" (Settings → Diagnostics) | n/a | n/a | their two ExtState keys are no longer read or written | n/a |
| Existing, unchanged: the pitch drag, Shift+Drag (Onset Ramp, Transition, Scoop), edge trims, pitch points, marquee, keys, Strength and the timing values, the write on release | as today | as today | as today | as today |

**What Tighten does.** It looks at how the sung pitch moves around the note's centre and removes the part of that movement that is slower than a time window. The window shrinks as the value rises, so the slowest movement goes first:

| Tighten | What is removed | What is left |
|---|---|---|
| 0 % | nothing | the note as sung (only moved to where its block sits) |
| about 50 % | slow drift and sag | vibrato essentially as sung |
| about 70 % | drift and wobble, and about half of the vibrato depth | a shallow, even vibrato |
| 100 % | everything | a flat line: the hard-tuned sound |

The slide into a note and the fall out of it are not part of the measurement and keep their shape; they move by the same amount as the edge of the note's body, so they land on the tightened note.

**What Tolerance does.** On a tightened note, the slow line that Tighten would remove is left alone wherever it is within Tolerance of the centre; only the part beyond it is removed. With Tolerance at 0 ¢ Tighten removes everything it finds. Tolerance does nothing on a note whose Tighten is 0 %.

**How it combines with the rest of the correction.** In this order: the note's pitch shift (scaled by Strength, as today) → Tighten with Tolerance (literal: Strength does not scale it, as for pitch points) → Scoop → pitch points. Ramps, glides, Onset Ramp, Transition and Legato Gap work exactly as today. A note with Tighten above 0 % is written moment by moment, as a note with Stability was.

**Earlier work.** Items corrected with Stability or Vibrato lose those two values (confirmed 2026-11-20: nothing is converted, the script is not public and items can be analysed again). Such an item shows as "Outdated", as it does today whenever a setting changes, and is rewritten without them on the next edit.

## References

- Native REAPER analogue: none for the dial itself. Closest in REAPER: ReaTune's Attack time (one time-based value from natural to hard-tuned). Conventions matched (CN6): Ctrl/Cmd-drag is fine adjust; right-click opens a menu; Shift and Alt keep their current meanings (Shift+Drag stays Onset Ramp / Transition / Scoop); values are percent for Tighten and cents for Tolerance, as the note readout already uses cents.
- Baseline capture: the session's captures of 2026-11-20 (the docked window with the note menu open, try-out build). `ds-lint.py` summary: did not run ("theme.lua palette drifted from ds-lint's port of build_palette"), so there is no mechanical baseline; that is a tool fault, separate from this design.
- Try-out: branch `spike/pitch-tighten-dial` (two note-menu sliders, checked in real REAPER and by ear by the user, who chose it over Stability and Vibrato). This design replaces the try-out; its code is the starting point, its "(try-out)" labels and the behaviour "Tighten stands in for Stability and Vibrato" go away with the two old controls.

## Context and job stories

Confirmed at the checkpoint (2026-11-20): old Stability / Vibrato values are dropped; the default Tolerance lives in the top bar next to Strength with the Global → Item → Note chain; both old layers are removed. Carried over from the earlier Pitch Correct designs and not contradicted: lives on the existing canvas, used all session, during playback, by mouse.

1. When a held note wanders, I want to drag one side of it until it sits steady, so I can fix it without flattening its vibrato.
2. When a note sounds over-corrected, I want to widen how much straying is left alone on that note, so it keeps its natural movement.
3. When I start a song, I want to set one Tolerance for it, so every note I tighten behaves the same without setting it each time.
4. When I want a hard-tuned effect, I want to push the same dial to its top and Tolerance to 0, so I do not need a second tool.
5. When playback loops over the phrase, I want to hear the change as soon as I release the drag, so I can tune by ear.
6. When I open an item I corrected with the old controls, I want to be told its correction is from other settings, so nothing changes silently.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | The Tighten drag and the Tolerance drag on a note, their readouts; the Tolerance badge in the top bar | The two drags are the main per-note correction after pitch, used on most notes; the default is tuned by ear during playback |
| 2 one disclosure away | Note menu rows Tighten and Tolerance (exact value, reset, back to the default); the badge's edit popup and its right-click menu (item override, reset) | Exact values and clean-up: a few times per session |
| 3 Settings | None | Nothing is rare enough; the two removed diagnostics leave Settings |

## Information architecture

Regions touched (the window's regions are unchanged):

1. **Note canvas, drag zones.** A note block keeps its three zones: left quarter, centre, right quarter. Left is Tighten, right is Tolerance; the centre stays pitch. With Shift held the three zones are Onset Ramp, Transition and Scoop, as today.
2. **Top bar, Correction group.** One unit added: the Tolerance badge, between Strength and the timing values. It is shown in every layout of the bar and is never folded into "Timing" (it is not a timing value).
3. **Note menu** (right-click a note): two value rows, Tighten and Tolerance, placed first among the value rows (they are the note's main values); Onset Ramp, Scoop Shape, Transition and Correction Strength follow, unchanged.
4. **Layers menu and Settings → Diagnostics:** one entry removed from each ("Vibrato Shading", "Trend Line"). Diagnostics keeps its other entry ("Split Markers").
5. **Help modal and Shortcuts panel:** the two drag rows are reworded; one row is added to the panel.

Primary display: the note canvas (unchanged). Primary action: dragging a note (unchanged). Disclosure levels: the drags and the badge are level 1; the note menu and the badge's popup are level 2 (IA2).

**Where a Tolerance value comes from.** The same chain as Strength: the note's own value when it has one, else the item's override when there is one, else the global default (8 ¢). A drag on a note's right side, or its menu row, writes the note's own value. The badge writes the item override when there is one, else the global default. A note's own value is removed by a double-click on its menu row or by Reset to Original.

**Selection.** The two drags act on every selected note when the pressed note is one of them, as every note drag does today. The two menu rows do the same: a right-click on a note that is already selected keeps the selection (today it collapses it), and the rows then write to all selected notes; the row says how many. The other menu entries act as today.

**Seeing Tolerance.** While the pointer is on a note's right side, on the Tolerance badge or its popup, or on the Tolerance menu row, a band from centre − Tolerance to centre + Tolerance is shaded across each note the value reaches that has Tighten above 0 %, with the script's existing setting-highlight look. The Preview Curve already shows what Tighten does, live.

## Wireframes

Default floating size, one selected note being tightened (`░` = the Tolerance band while the right side is hovered):

```
┌ FANCY PITCH CORRECT ──────────────────────────────────────────────────────── … × ┐
│ ◆ [item] [Key][Scale] │ [Global] Strength [====] [Tolerance: 8¢] [Transition: 35ms]│
│                       │ [Onset Ramp: 35ms] [Legato Gap: 120ms] │ [Snap][Quantize]… │
├────┬───────────────────────────────────────────────────────────────┬─────────────┤
│ D4 │ 0:07          0:08          0:09                              │ SHORTCUTS   │
│    │     C#4 +0¢                                                   │ Tighten ·   │
│ C#4│  ╭─┬──────────────────┬─╮                                     │  Tolerance  │
│    │  │T│░░░░░~~~~~~~░░░░░░│o│   left quarter: Tighten             │  Drag note  │
│    │  │ │░░~~~░░░░░░~~~~░░░│ │   right quarter: Tolerance          │  side       │
│ C4 │  ╰─┴──────────────────┴─╯                                     │ PITCHED     │
│    │ [ Tighten: 55% ]                                              │ ITEMS …     │
└────┴───────────────────────────────────────────────────────────────┴─────────────┘
```

Top bar, the Correction group in its two forms (the Tolerance badge is in both):

```
full:    [Global] Strength [=====]  [Tolerance: 8¢]  [Transition: 35ms] [Onset Ramp: 35ms] [Legato Gap: 120ms]
folded:  [Global] Strength [=====]  [Tolerance: 8¢]  [Timing ▾]
item override:   [Tolerance: 12¢*]        note selected with its own value:  [Tolerance: 20¢*] (locked, reason in the tooltip)
```

Badge popup (left-click the badge) and its right-click menu, as the timing badges have today:

```
┌──────────────────────┐        ┌───────────────────────────┐
│ [      8 ¢       ]   │        │ ✓ Override for this item  │
└──────────────────────┘        │   Reset to default        │
                                └───────────────────────────┘
```

Note menu (two rows added at the top of the value rows; the rest unchanged):

```
┌───────────────────────────────────────────┐
│ C#4 +0¢ (In Scale)                        │
│ ───────────────────────────────────────── │
│ [ ] Bypass This Note                      │
│ ───────────────────────────────────────── │
│ [   55%   ] Tighten                       │   3 notes selected:  Tighten  (3 notes)
│ [   8 ¢   ] Tolerance  [global]           │                      Tolerance  [note] (3 notes)
│ [  35 ms  ] Onset Ramp  [global]          │
│ [   0%    ] Scoop Shape                   │
│ [  35 ms  ] Transition  [global]          │
│ [  100%   ] Correction Strength  [global] │
│ ───────────────────────────────────────── │
│ Snap to Semitone                        S │
│ …                                         │
└───────────────────────────────────────────┘
```

Narrow docker (~260 px): the top bar is in its four-row layout; the Correction row holds the scope pill, Strength, the Tolerance badge and "Timing". If that row is now the widest one, the narrowest width the bar is planned for grows by the badge's width; below it the bar clips at the right edge as it does today, and the window's minimum floating width follows the widest row as today.

```
┌ FANCY PITCH CORRECT ──────── … × ┐
│ ◆ [item…]                        │
│ [Key][Scale]                     │
│ [Global] Strength [==] [Tol…: 8¢] [Timing ▾]
│ [Snap][Quantize][Split][Merge]   │
├───┬──────────────────────────────┤
│C#4│ ╭┬────┬╮  [ Tighten: 55% ]   │
└───┴──────────────────────────────┘
```

On a very narrow block each side zone keeps its existing minimum width (12 px), so the centre zone shrinks first, as today; Tighten and Tolerance are also in the note menu. The badge label is never shortened: the row wraps or clips before the label changes ("Tol…" above only marks where it would clip).

Wide short strip (1200 × 150): one top bar row with every badge; the pitch axis is short, so a zone drag sweeps its range in few pixels. Ctrl/Cmd-drag (fine) and the note menu rows give exact values.

```
┌ ◆ [item] [Key][Scale] │ [Global] Strength [===] [Tolerance: 8¢] [Transition: 35ms] [Onset Ramp…] [Legato…] │ [Snap]… … × ┐
│ C#4 │ ╭┬──────────┬╮      ╭┬─────┬╮         [ Tolerance: 12¢ (3 notes) ]                                            │
└─────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Canvas zones | empty | An item with no notes keeps today's canvas message; nothing new | ST6 |
| Canvas zones | working | n/a: the write on release takes well under 1 s, as every note edit today | ST3 |
| Canvas zones | error | n/a: a drag cannot fail; values are clamped | ST7 |
| Canvas zones | disabled with reason | A bypassed note: the drags move the values but the note stays uncorrected, as every note drag today; the block shows its bypass look. Under the script's Bypassed overlay the canvas is inert as today. Tolerance on a note whose Tighten is 0 %: the readout and the hover tooltip say it is not used yet (see Copy deck), visible with tooltips off through the drag readout | EP2 |
| Canvas zones | overflow / long names | On a very narrow block each side zone keeps its existing minimum width (12 px) and the centre zone shrinks, as today; the values are also in the note menu. Readout pills keep their existing clamping to the note area | LG4 |
| Canvas zones | missing dependency | n/a: nothing new is required | HI7 |
| Canvas zones | Fancy Dark / Match Theme | The zone tints, the Tolerance band and the readout pill use existing canvas palette keys, fitted for contrast in Match Theme | CL4 |
| Tolerance badge | empty | No item analysed: the badge is drawn disabled with the reason the Correction group already gives ("Select an audio item" / "Analyze an item first") | ST6 |
| Tolerance badge | working | While an item is analysed: disabled, "Wait for the analysis to finish" | ST3 |
| Tolerance badge | disabled with reason | One note selected that has its own Tolerance: the badge shows that value with the note colour and is locked, "Overridden on this note. Right-click the note to change it." | EP2 |
| Tolerance badge | overflow / long names | Its width is measured from its longest label ("Tolerance: 50¢*"), so a value or mark never moves the bar; at narrow widths the bar's existing layouts wrap it with the Correction group | LG4 |
| Tolerance badge | Fancy Dark / Match Theme | The same badge colours by level as the timing badges | CL4 |
| Note menu rows | disabled with reason | n/a: both rows are always editable; the Tolerance row shows where its value comes from | EP2 |
| Note menu rows | overflow / long names | n/a: fixed short strings; "(12 notes)" is the longest suffix in practice | LG4 |
| Note menu rows | Fancy Dark / Match Theme | Standard popup colours from the theme push | CL4 |
| Whole item | error | An item whose envelope was written with Stability or Vibrato: the existing "Outdated" mark in Pitched Items and the status hint "Outdated: this item's envelope is from other settings. Edit a note to rewrite it." | ST7 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Left side of a note (canvas): Tighten | Press and drag vertically: up = more. The Preview Curve follows live; written on release. Ctrl/Cmd held: fine, with the note drag's fine factor (HC2). Acts on every selected note when the pressed note is selected (each keeps its own offset from where it started, as today). No double-click reset on the canvas (double-click stays Snap to Semitone); reset is in the note menu and Reset to Original (HC3 through DV1). Right-click: note menu. No wheel (the canvas scrolls) | 0 % | `%.0f%%` | 0 to 100 %, always clamped, linear; a drag as tall as two semitone rows sweeps the range (the Stability drag's feel) | "Adjust Tighten", with " (N notes)" for several | n/a |
| Right side of a note (canvas): Tolerance | As above: up = more is left alone. A drag starts from the value the note uses now (its own, or the inherited one) and writes the note's own value | inherits (8 ¢ global) | `%.0f¢` | 0 to 50 ¢, always clamped, linear; a drag as tall as one semitone row sweeps the range | "Adjust Tolerance", with " (N notes)" | n/a |
| Note menu → Tighten | The script's existing value-drag control: drag (Ctrl/Cmd-drag fine), Ctrl/Cmd-click types a number, double-click resets to 0 % (HC2, HC3). Live preview, written on release or Enter. Writes to every selected note when the menu's note is one of several selected | 0 % | `%.0f%%` | 0 to 100 %, always clamped, linear | "Adjust Tighten" · "Reset Tighten" | n/a |
| Note menu → Tolerance | The same control. Double-click removes the note's own value, so it inherits again. Shows where the value comes from: `[note]`, `[item]` or `[global]`. Writes to every selected note as above | inherits | `%.0f ¢` | 0 to 50 ¢, always clamped, linear | "Adjust Tolerance" · "Reset Tolerance" | n/a |
| Top bar → Tolerance badge | Left-click: a popup with the value-drag control (drag, Ctrl/Cmd-drag fine, Ctrl/Cmd-click types, double-click resets). Right-click: "Override for this item" (checkable), "Reset to default". Exactly the timing badges' behaviour. An edit goes to the item override when there is one, else to the global default | 8 ¢ | badge `Tolerance: %.0f¢`, with `*` when overridden; popup `%.0f ¢` | 0 to 50 ¢, always clamped, linear | "Adjust Tolerance" · "Toggle Item Override: Tolerance" · "Reset Item Override: Tolerance" · "Reset Default: Tolerance" | A global default change is saved outside the undo history, as for the other top bar values: no confirm (nothing is lost; the value is set back by hand or by Reset to default), and the status line says "Global default changed (not undoable)" with the count of other items that keep their old envelope (HC4) |
| Existing: Reset to Original (`R`, Backspace, Delete, note menu) | As today; it also clears Tighten and the note's own Tolerance, and a note whose only change is one of them counts as changed | as today | as today | as today | "Reset Pitch Correction" (unchanged) | As today |
| Existing: Split, Trim, Merge | Split and Trim: each resulting note keeps Tighten and its own Tolerance. Merge: Tighten is the average of the merged notes weighted by their length (as Stability was); the note's own Tolerance is the first note's (as the other inherited values) | as today | as today | as today | as today | as today |

Keyboard map: no new keys. Esc (HC5): an open menu or popup closes first; Esc during a Tighten or Tolerance drag on the canvas, in the note menu or in the badge popup puts the value back and writes nothing, as for the existing drags; then selection, then the window when floating. Space is forwarded as today (HC6), also during the drags. No key repeats are added (EP6). The two drags and the badge are listed in the Help modal, and one row in the Shortcuts panel (HP1).

Hover feedback: the left and right quarters keep their zone tint and hand cursor. The hover tooltip names the value and what it is at now. While dragging, the readout pill shows the value and the note count.

## Copy deck

| Where | String |
|---|---|
| labels | Note menu rows: `Tighten`, `Tolerance` · Top bar badge: `Tolerance: 8¢` (`Tolerance: 12¢*` when overridden) · Menu-row suffix with several notes selected: `(3 notes)` |
| tooltips | Left side of a note: `Tighten: 55%` · Right side: `Tolerance: 8¢`; on a note whose Tighten is 0 %: `Tolerance: 8¢ (used once Tighten is above 0%)` · Badge: `Tolerance: 8 ¢` / `How far a tightened note may stray from its centre before it is pulled in.` / the existing line that says where the value comes from / `Left-click to edit. Right-click for item override and reset.` · Badge popup row: the existing scope line and `Right-click for item override and reset.` |
| empty / error / confirm | No new empty or error text and no confirm dialog. Existing reasons reused on the badge: `Select an audio item` · `Analyze an item first` · `Wait for the analysis to finish` · `Overridden on this note. Right-click the note to change it.` |
| status messages | Drag readout pill: `Tighten: 55%` · `Tighten: 55% (3 notes)` · `Tolerance: 12¢` · `Tolerance: 12¢ (3 notes)` · on a note whose Tighten is 0 %: `Tolerance: 12¢ (used once Tighten is above 0%)` · Global default edit (existing wording): `Global default changed (not undoable). 2 other items keep their old envelope until edited.` · Tolerance highlight with no tightened note in reach: `No note uses Tolerance yet: raise Tighten on a note first` |
| undo labels | `Adjust Tighten` · `Adjust Tolerance` · `Reset Tighten` · `Reset Tolerance` · `Toggle Item Override: Tolerance` · `Reset Item Override: Tolerance` · `Reset Default: Tolerance` |
| Help modal rows | `Drag Left Zone` — `Tighten: steady the note, slow drift first; 100% is a flat line (Cmd = fine)` · `Drag Right Zone` — `Tolerance: how far the note may stray from its centre untouched (Cmd = fine)` (the modifier is named per platform). The rows for Stability and Vibrato are removed |
| Shortcuts panel row | group Edit: `Tighten · Tolerance` — `Drag note side` |
| removed strings | `Stability: …`, `Vibrato: …`, `Adjust Stability`, `Adjust Vibrato`, `Adjust drift stability tracking`, `Scale natural vibrato depth`, `Vibrato Shading`, `Trend Line`, and every "(try-out)" label |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Left and right zone tints on a hovered note | none: canvas draw list, as today | canvas palette `zone_drift`, `zone_shift` (unchanged keys and use) |
| Tolerance band on a note | none: canvas draw list, the script's existing setting-highlight drawing | canvas palette `span_fill`, `span_edge` |
| Readout pill, status pill | the script's existing canvas pill helpers | canvas palette `pill_text` and the pill's existing keys |
| Zone hover tooltip | `Theme.tooltip` | theme defaults |
| Tolerance badge | `Theme.badge` (interactive, fixed width), as the timing badges | palette `well`, `text`, `accent`, `accent2` by level, through the script's existing level colours |
| Badge alignment in the bar | `Theme.align` | `Theme.layout.sm`, `Theme.layout.md`, `Theme.layout.xl` (the bar's existing gaps) |
| Badge popup, note menu rows | stock popup; the script's existing value-drag control | theme push defaults; the level tag in the disabled text colour |
| Removed layer swatch (Vibrato Shading) and trend line | n/a | canvas palette `vibrato` and `trend` are no longer read by this script (they stay in the palette; see Open questions) |

## Library proposals

None. Every colour and size is an existing palette key, canvas palette key or layout token.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | A note with Tighten above 0 % shows as edited at rest (green block, edit mark, Preview Curve through the tightened shape). The Tolerance badge shows its value and an override mark at rest |
| ST2 | Every drag frame moves the Preview Curve and the readout; a release writes and the canvas shows it in the same frame; a global default edit posts a status message |
| ST3 | n/a: the write on release is as fast as a note edit |
| ST4 | The Preview Curve is what is written. The readout and tooltip say when Tolerance is not used yet (Tighten at 0 %); the badge shows the value the selected note really uses and locks when that is the note's own; menu rows say how many notes they write to |
| ST5 | n/a: lifecycle unchanged |
| ST6 | No blank state is added; the badge is drawn disabled with a reason when there is nothing to act on |
| ST7 | An item written with the old controls is reported as "Outdated" in the window, in user terms; it is never rewritten silently |
| UC1 | One named undo point per drag, menu edit, reset and item override; none when the value did not change (a click without a drag, a drag back to the start, Esc); no undo block opened while dragging |
| UC2, HC5 | Esc: menu or popup → active drag (revert) → selection → window when floating; all through `Shortcut()` |
| UC3 | Tighten and a note's own Tolerance are stored in the note model on the take, the item override in the take data, both inside the edit's undo block; the script's existing reload on project state change restores them on undo and redo. The global default is ExtState, outside undo, and the status line says so |
| UC4 | REAPER's item, track and time selection are never changed by these gestures |
| UC5, HC3 | Double-click a menu row or the badge's drag: Tighten to 0 %, a note's Tolerance back to inheriting, an item override back to inheriting, the global default to 8 ¢. Ctrl/Cmd-click types a value. Reset to Original clears both on a note |
| EP1, HC4 | No destructive action is added. A global default change is not undoable and not confirmed, as for the other top bar values; the status message names it and the count of items affected |
| EP2 | The badge shows its disabled reason; the Tolerance-not-used-yet note is in the drag readout as well as the tooltip, so it is visible with Show Tooltips off |
| EP3 | Tighten is held within 0 to 100 % and Tolerance within 0 to 50 ¢ on the canvas, in the menu, in the popup and when typed (always clamped, linear); a stored value outside the range is clamped when read |
| EP4 | Values belong to the note and the take (by GUID, as today), never to a list position |
| EP5 | The badge is disabled with a reason, never hidden; no control appears or disappears with the selection |
| EP6 | No new keys; Esc during a drag goes through `Shortcut()`; Shift on a note still means the Shift+Drag values |
| CN1 | The badge is `Theme.badge`, tooltips go through `Theme.tooltip`, value rows are the script's existing value-drag control; no hand-built substitute |
| CN2, CN3 | Tokens and existing palette keys only; no new colour, size or font |
| CN4 | One name each: "Tighten" and "Tolerance". "Stability", "Vibrato", "drift", "trend" and "(try-out)" no longer appear in user-facing text |
| CN5, HP1 | The Help modal lists the two drags and the Shortcuts panel one row; they match the handlers; the CHANGELOG entry matches the code |
| CN6, HC2 | Ctrl/Cmd-drag is fine adjust on both canvas drags, in both menu rows and in the badge popup; Shift and Alt are not given a new meaning; right-click opens a menu |
| RC1 | Each value is explained in the Help modal row and in the badge tooltip; the drag readout names the value, so nothing depends on a tooltip alone |
| RC2 | Percent for Tighten and whole cents for Tolerance; no semitone fractions, time windows, frame counts or internal names in any string |
| EF1 | Ctrl/Cmd-drag fine everywhere; double-click reset and typed entry in the menu rows and the popup; a context menu on the badge. No wheel adjust: the canvas scrolls |
| EF2, HC6 | Space forwarding unchanged, also during these drags and with the badge popup open (no text field is active unless a value is being typed) |
| EF3 | The pitch and time scales are frozen during a zone drag, as for the existing drags; zoom, scroll and ruler unchanged |
| IA1 | The two drags and the badge are Tier 1; the menu rows and the badge popup Tier 2; nothing in Settings |
| IA2 | Two disclosure levels: the canvas and the bar, then a menu or popup |
| IA3 | Primary display and primary action unchanged; no new text size or weight |
| IA4 | "Vibrato Shading" and "Trend Line" are removed with the code that fed them; no dead toggle is left behind (Diagnostics keeps "Split Markers") |
| LG1, LG2, LG3 | The badge sits on the bar's baseline with the bar's existing gaps; the two menu rows share the value column and label column of the rows below them |
| LG4 | Works in a ~260 px docker and a 1200 × 150 strip as wireframed: the bar wraps with the badge in the Correction group; narrow blocks keep their zones at the existing minimum width and the values are also in the menu; pills clamped |
| MT1 | The side zones keep today's size rule (a quarter of the block each, at least 12 px); the badge is a full-height bar control |
| MT2 | Both zones have a rest, hover and drag look, a cursor and a tooltip, as today; the badge has hover, pressed and disabled looks from `Theme.badge` |
| CL1, HC1 | Badge text at least 4.5:1 on each of its level colours (the timing badges' pairs); the Tolerance band edge at least 3:1 on rows and note fills in both theme modes (the existing highlight keys are fitted for it) |
| CL2 | Where a value comes from is shown by the `*` mark and the level tag as well as the badge colour; the Tolerance band is a shape, not a colour change of the note |
| CL3 | No red |
| CL4 | Checked in Fancy Dark and Match Theme |
| DV1 | The canvas zones keep editor gestures: drag to change, fine with Ctrl/Cmd, live preview, commit on release; reset and typed entry live in the note menu |
| HI1, HI2, HI3 | n/a: window lifecycle, flags and toolbar unchanged; the badge popup is a popup inside the window's visible block |
| HI4 | The model is written on release or command, never per frame; the global default is saved when the edit is committed |
| HI5 | A note's tightened line is computed when its values or its analysis change, not per frame; the correction is rebuilt only when the existing signature changes, which now includes both values |
| HI6 | The badge keeps one stable ID while its label changes (`###`); the menu rows keep theirs with and without the "(N notes)" suffix |
| HI7 | n/a |
| RB9, RB15, RB19 | No modal is added; tooltips go through the for-tooltip hover check; every ReaImGui name is checked against the names file before use |

## Open questions / assumptions

Approaches considered (the first was chosen in chat, 2026-11-20, after a try-out the user listened to):

- **A time-window dial with a tolerance (chosen).** One value per note removes movement slowest-first and ends in a flat line; a second value says how much straying is left alone. No vibrato detection is needed, so the depth changes evenly across a note.
- **Staged amounts** (centre and drift up to 100 %, then vibrato, then note edges). Very safe in its natural range, but it depends on separating vibrato from drift cleanly, which is what failed in the Vibrato control.
- **Keep Stability and Vibrato and repair them.** Least change, no simplification; measured on the user's notes it kept the overshoot at note starts.

Calls made in this doc, for you to check:

- **The Tolerance badge is always visible** and is not folded into "Timing". It makes the Correction group one badge wider in every layout of the bar.
- **Up means more on both sides**: more Tighten on the left, more Tolerance (more left alone) on the right. The two therefore pull in opposite directions musically: up on the left is tighter, up on the right is looser. Say so if you would rather have "up = tighter" on both.
- **Drag ranges.** Tighten sweeps 0 to 100 % over two rows of drag (as Stability did); Tolerance sweeps 0 to 50 ¢ over one row. Starting values for the builder to tune in real REAPER.
- **Tolerance stops at 50 ¢.** A larger value leaves almost every note alone.
- **Strength does not scale Tighten**, as it does not scale pitch points: a note at Strength 50 % and Tighten 100 % is flat, half-way to its target.
- **A note's own Tolerance counts as an edit of that note** (it turns green), like a note's own Transition or Strength today, even while its Tighten is 0 %.
- **Only Tighten and Tolerance write to the whole selection from the note menu.** The four older rows and Bypass act on the menu's note alone, as today. A right-click on a selected note now keeps the selection, which also means Snap and Quantize from that menu act on all selected notes (they already act on the selection from the keys and the top bar).
- **Menu order.** Tighten and Tolerance come first among the value rows; Tighten shows no level tag (it has no default to inherit).
- **The dial's law is the try-out's**: window = 0.4 s × (1 − Tighten)², the first tenth of the dial fades in, the note's body is what lies within half a semitone of its centre, and Tolerance is taken off the slow line, not off every wiggle. Known weak spot, seen in real REAPER: a fast fall at the end of a note can leave a bump of about 10 ¢ just before it at mid settings. Not addressed here.
- **Palette keys `vibrato` and `trend` stay in `_lib/theme.lua`**, unused by this script. Removing them is a library change and belongs to the clean-up that follows this design.
- **No default Tighten.** Every note starts at 0 %; a top bar Tighten was not asked for.
- **Next, not in this doc:** showing the dial's result as pitch points (agreed to follow), and the code clean-up.

HC6 conflicts: None.
