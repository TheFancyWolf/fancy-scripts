# Design: Fancy Pitch Correct — value bar that follows the selection

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (the top bar's Correction group and the note context menu's value rows)
Status: Approved
Date: 2026-11-20
Approver: TheFancyWolf

## Summary

The top bar's Correction group becomes one compact **value bar** that edits whatever is selected: with no note selected it edits the defaults, with notes selected it edits those notes. Tighten, Strength and Tolerance are always visible as direct drags with a fill bar that shows where the value sits in its range; Transition, Onset Ramp, Scoop Shape and Legato Gap sit on a row the user opens with one "Timing" toggle. No value opens a popup before it can be dragged. The note right-click menu keeps every value row, and every row now writes to all selected notes. Primary display: the canvas (unchanged). Primary action: dragging a value in the bar.

## Feature inventory

Scope is the seven values below, where they are edited, and their tooltips. Clip group (brand, item badge, Key, Scale), note actions (Snap, Quantize, Split, Merge), the "…" menu, Close, the canvas drags and the sidebar are unchanged.

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Edit a default (Strength, Tolerance, Transition, Onset Ramp, Legato Gap), no note selected, item has no override | active take, its note model | take pitch envelope of the open item | ExtState (`FancyScripts`, cascade keys) | **N**: the default is ExtState. Unchanged from today: the status pill says "not undoable" and how many other items are now outdated. Not destructive, so no confirm (HC4) |
| Edit an item override (same five values), no note selected, item has an override | same | take pitch envelope, take model (P_EXT) | none | **Y**: one undo block, model reloads on project change |
| Toggle "Override for this item" / "Reset to default" (right-click a value, no note selected) | same | same | ExtState only when a default is reset | override: **Y**; default reset: **N** (as above) |
| Edit a note value from the bar (Tighten, Strength, Tolerance, Transition, Onset Ramp, Scoop Shape), 1..N notes selected | same | take pitch envelope, take model (P_EXT) | none | **Y**: one undo block per drag, typed entry or reset |
| Reset note values from the bar (double-click; right-click → reset) | same | same | none | **Y** |
| Edit a note value from the note right-click menu (all six rows) | same | same | none | **Y**; **changed**: Onset Ramp, Scoop Shape, Transition and Strength now write to every selected note, as Tighten and Tolerance already do |
| Open / close the Timing row | none | none | ExtState (`FancyScripts`, `pitch_timing_open`) | n/a: view state, nothing to undo |
| Read a value's source (default / item / note) | note model | none | none | n/a |
| Canvas shading of where a value acts, while a bar control is hovered or dragged | note model | none | none | n/a (existing `K.setting_hint`) |

Removed UI: the scope pill + "Strength" label + slider unit, the four value badges and their edit popups, the folded "Timing" popup. Every value they edited is in the new bar; nothing loses access.

## References

- Native REAPER analogues: the track panel's volume/pan knobs and the MIDI editor's CC lane header: drag on the control itself, Ctrl/Cmd-drag fine, double-click reset, right-click menu, no Alt/Shift repurposing (CN6). The fill bar matches REAPER's FX parameter sliders, which show the value as a filled portion of the control.
- Redesigns only: baseline capture `scratchpad/main.png` (docked at the top of the script's dock, one note selected: pill reads "Note", Strength and Tolerance are greyed out, three timing badges each need a popup). `ds-lint.py` summary: **did not run**: the lint stopped with "theme.lua palette drifted from ds-lint's port of build_palette" (20 unknown keys), so there is no definite/check count for the baseline.

## Context and job stories

Confirmed at the checkpoint: the script is docked, with its bar at the top of the window; Tighten, Strength and Tolerance are used constantly while tuning, the timing values a few times per item; values are dragged during looped playback; values are edited by mouse, keys are for note actions.

1. When a phrase sounds too corrected while it loops, I want to select its notes and drag one value, so they all change together.
2. When one note wobbles, I want to select it and drag Tighten in the bar, so I do not have to find the note's left edge.
3. When a new item sounds stiff overall, I want to change the default once with nothing selected, so every note without its own value follows.
4. When I am not sure what a note is set to, I want to select it and read its values in the bar, so I do not open a menu to find out.
5. When I do not know where to change a note, I want to right-click it and find every value there, so the menu still works as the fallback.
6. When I hover a value I have not used, I want the tooltip to tell me what it does to the sound, so I know which way to drag.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Selection pill; Tighten, Strength, Tolerance; Timing toggle | used several times a minute; these three shape the sound most |
| 2 one disclosure away | Transition, Onset Ramp, Scoop Shape, Legato Gap (the Timing row) | a few times per item; the row stays open once opened |
| 3 Settings | none | nothing moves to Settings |

## Information architecture

Regions of the top bar, left to right (unchanged except Values):

- **Clip**: brand, item badge, Key, Scale.
- **Values** (replaces Correction): selection pill, Tighten, Strength, Tolerance, Timing toggle.
- **Note actions**: Snap, Quantize, Split, Merge.
- **Right**: "…" and Close.
- **Timing row** (new, optional): Transition, Onset Ramp, Scoop Shape, Legato Gap. It is the last row of the bar, shown while the Timing toggle is on.

One rule decides what a drag changes, and the pill states it:

| Selection | Pill | A drag writes to |
|---|---|---|
| no note selected | `Defaults` | the item override when this item has one for that value, else the default used by every item |
| 1 note | `1 note` | that note |
| N notes | `N notes` | every selected note |

Disclosure levels: one (the Timing row). The value bar never opens a popup to edit; the only popups left are the right-click menu and the typed entry (Ctrl/Cmd-click), both existing.

Layout stability (EP5): every control keeps its place for any selection. A value that does not apply is disabled with its reason, never hidden: Tighten and Scoop Shape with no note selected (they exist only on notes), Legato Gap with notes selected (it exists only per item). Which row a unit sits on still depends on the content width alone.

## Wireframes

A value control is one frame: label, value, an optional `*`, and a fill bar along its bottom edge. The fill runs from the left edge (minimum) to the value. `▓` = fill, `░` = rest of the range.

```
┌───────────────┐   ┌───────────────┐   ┌─────────────────┐   ┌───────────────┐
│ Strength  80% │   │ Strength 80% *│   │ Tighten  20–60% │   │ Tighten    –  │
│▓▓▓▓▓▓▓▓▓▓▓▓░░░│   │▓▓▓▓▓▓▓▓▓▓▓▓░░░│   │░░░▓▓▓▓▓▓░░░░░░░░│   │               │
└───────────────┘   └───────────────┘   └─────────────────┘   └───────────────┘
  default             own value (*,        mixed: lowest–highest   disabled: no fill,
  (quiet fill)        accent fill)         as a segment            reason in tooltip
```

**Wide (one row), nothing selected, Timing closed:**

```
[◆] [V_Main E251-80-glued.wav] [E▾] [Major▾] │ (Defaults) [Tighten –] [Strength 80%] [Tolerance 8¢] [Timing ▸] │ [Snap][Quantize][Split][Merge]      […][×]
```

**Wide, three notes selected, Timing open** (the Timing row is the bar's last row):

```
[◆] [V_Main E251-80-glued.wav] [E▾] [Major▾] │ (3 notes) [Tighten 20–60%] [Strength 80% *] [Tolerance 8¢] [Timing ▾] │ [Snap][Quantize][Split][Merge]   […][×]
[Transition 35ms] [Onset Ramp 60ms *] [Scoop Shape 0%] [Legato Gap 120ms]
```

**Default floating size (two rows, as today's first-use plan):**

```
[◆] [V_Main E251-80-glued.wav…] [E▾] [Major▾]                              […][×]
(Defaults) [Tighten –] [Strength 80%] [Tolerance 8¢] [Timing ▸] │ [Snap][Quantize][Split][Merge]
```

**Narrow docker (~260 px):** the groups wrap as today (Clip over two rows, actions on their own row). The Values group wraps inside itself: pill and Timing toggle first, then the three values.

```
[◆] [V_Main E25…]      […][×]
[E▾] [Major▾]
(3 notes) [Timing ▾]
[Tighten 20–60%] [Strength 80% *]
[Tolerance 8¢]
[Transition 35ms] [Onset Ramp 60ms *]      ← Timing row, wraps two per row
[Scoop Shape 0%] [Legato Gap 120ms]
[Snap][Quantize][Split][Merge]
```

**Wide short strip (e.g. 1200×150):** the one-row plan; with the Timing row open the bar is two rows and the canvas keeps the rest.

What truncates, wraps or hides (LG4): only the item badge truncates (ellipsis + tooltip, as today). Value controls never truncate: each has a fixed width measured from its longest text (label, widest mixed range, `*`). Nothing is hidden by width; the folded "Timing" popup of today's narrow plans is gone because the Timing row replaces it at every width.

Width compared with today: the Values group is the pill + three controls + toggle. Today's unfolded Correction group is the pill + label + slider + four badges, so the one-row plan fits in a narrower window than it does now.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Values, Timing row | empty (no audio item, or item not analysed) | all controls disabled, values shown as `–`, no fill; tooltip gives the reason ("Select an audio item" / "Analyze an item first"); the canvas shows its own empty state as today | ST6 |
| Values, Timing row | working (analysis running) | all controls disabled; tooltip "Wait for the analysis to finish"; progress stays where it is today | ST3 |
| Values, Timing row | error | none of its own: a value edit cannot fail. Outdated items are reported by the existing status pill and the sidebar's "outdated" tag | ST7 |
| Tighten, Scoop Shape | disabled with reason (no note selected) | `–`, no fill; tooltip explains the value, then "Select notes to change it (Cmd+A selects all)" | EP2 |
| Legato Gap | disabled with reason (notes selected) | its item value, dimmed; tooltip explains the value, then "Set per item: press Esc to deselect, then change it" | EP2 |
| Selection pill | 0 / 1 / N notes | `Defaults` / `1 note` / `N notes`; width fixed to the longest text (`999 notes`) | ST1, EP5 |
| Value control | own value | `*` after the value and the fill in the accent colour (item override: accent; note value: secondary accent). The `*` and the tooltip's source line carry the meaning without colour | CL2, ST4 |
| Value control | mixed across selected notes | text shows lowest–highest, fill shows that segment | ST4 |
| Tolerance | Tighten is 0% on every selected note | value shown normally; tooltip adds "Used once Tighten is above 0%" | ST4 |
| Timing toggle | a hidden value has its own value | `Timing *` while the row is closed | ST1 |
| Item badge | overflow / long names | truncates with ellipsis and tooltip, unchanged | LG4 |
| All | missing dependency | unchanged: the script's ReaImGui check | HI7 |
| All | Fancy Dark / Match Theme | fill and track colours come from the palette; the three fill colours are checked against the control background in both modes | CL4 |

## Interaction spec

All seven controls are the same widget, built on the script's existing `param_drag` (Drag widget with `SliderFlags_AlwaysClamp | NoInput | NoSpeedTweaks`).

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Tighten | drag; Ctrl/Cmd-drag fine; double-click reset; Ctrl/Cmd-click types; right-click menu. No wheel (unchanged) | 0% (per note only) | `%.0f%%` | 0–100, linear, clamped | "Adjust Tighten" / "Reset Tighten" | undoable, no confirm |
| Strength | same | `DEFAULTS.retune_speed` (100%) | `%.0f%%` | 0–100, linear, clamped | "Adjust Correction Strength" / reset labels as today | default: not undoable, status says so (existing); item, note: undoable |
| Tolerance | same | `DEFAULTS.tolerance` (8 ¢) | `%.0f¢` | 0–50, linear, clamped | "Adjust Tolerance" | as Strength |
| Transition | same | `DEFAULTS.transition_ms` (35 ms) | `%.0fms` | 5–60, linear (12×, under the 100× log threshold) | "Adjust Transition" | as Strength |
| Onset Ramp | same | `DEFAULTS.onset_ramp_ms` (35 ms) | `%.0fms` | 5–60, linear | "Adjust Onset Ramp" | as Strength |
| Scoop Shape | same | 0% (per note only) | `%.0f%%` | 0–100, linear | "Adjust Scoop Shape" | undoable, no confirm |
| Legato Gap | same | `DEFAULTS.legato_threshold_ms` (120 ms) | `%.0fms` | 50–300, linear | "Adjust Legato Gap" | as Strength (no note level) |
| Timing toggle | click opens / closes the Timing row | closed | n/a: discrete (HC2/HC3 n/a) | n/a | none (view state) | n/a |
| Selection pill | none (display); tooltip only | n/a | n/a | n/a | n/a | n/a |

Behaviour that applies to every value control:

- **What a drag changes** follows the pill (see Information architecture). The value is previewed while dragging and committed once on release: one undo point, one envelope write (UC1).
- **Several notes, relative drag.** Each selected note moves by the same amount from its own value and is clamped at the ends, exactly as dragging a note's side on the canvas does. Differences between notes are kept.
- **Typed entry with several notes** sets every selected note to the typed value. This is the way to make them equal.
- **Double-click (HC3).** No note selected: an item override goes back to inheriting; otherwise the default returns to its `DEFAULTS` value (as today). Notes selected: every selected note drops its own value and inherits again (Tighten and Scoop Shape return to 0%). One undo point.
- **Right-click.** No note selected: "Override for this item" (checkmark) and "Reset to default", as today. Notes selected: "Reset to inherited" (Tighten, Scoop Shape: "Reset to 0%").
- **Esc during a drag (HC5)** puts back the value, or each note's own value, from before the drag; nothing is saved or written.
- **Hover or drag** shades on the canvas the notes the value acts on: the selected notes, or every note the default reaches (existing `K.setting_hint`).
- **A note with its own value no longer disables the bar.** The control shows the note's value with `*` and edits it.

Note right-click menu (kept as the fallback): all six value rows stay. When the right-clicked note is one of several selected notes, **every** row writes to all of them and says how many ("(3 notes)"); today only Tighten and Tolerance do. The menu row shows the right-clicked note's value and sets the others to it, as its two spreading rows do today.

Keyboard map: no new keys. Esc ownership (HC5) innermost first: typed entry → right-click menu → active drag (revert) → note selection → window (floating only), unchanged. Space is forwarded as today (HC6). The Info modal's shortcut table (HP1) changes two entries: "Drag note side: Tighten · Tolerance" stays, and a line is added for the bar ("Drag a value in the top bar: changes the selected notes, or the defaults when nothing is selected").

## Copy deck

`{Mod}` is "Cmd" on macOS, "Ctrl" elsewhere. Every value tooltip has three parts in this order: what it does to the sound, what a drag changes right now, the gestures.

| Where | String |
|---|---|
| labels | `Defaults` · `1 note` · `%d notes` · `Tighten` · `Strength` · `Tolerance` · `Timing` · `Transition` · `Onset Ramp` · `Scoop Shape` · `Legato Gap` · own-value mark `*` · no value `–` |
| tooltip: Tighten | "Tighten: steadies a wobbly note. Low values take out slow drift, higher values also take out wobble and then vibrato; 100% is a flat line." |
| tooltip: Strength | "Correction Strength: how far each note is pulled to its target pitch. 0% leaves the singing as recorded, 100% puts the note fully in tune." |
| tooltip: Tolerance | "Tolerance: how far a tightened note may wander from its centre before Tighten pulls it in. Higher values keep more natural movement." (+ "Used once Tighten is above 0%." when it applies) |
| tooltip: Transition | "Transition: how long the glide from one note to the next takes. Short sounds tight and robotic, long sounds smooth and natural." |
| tooltip: Onset Ramp | "Onset Ramp: how quickly correction comes in at the start of a note. Short corrects the attack at once, long lets the singer's attack through first." |
| tooltip: Scoop Shape | "Scoop Shape: how much of the slide into the note is corrected. 0% keeps the slide as sung, 100% removes it." |
| tooltip: Legato Gap | "Legato Gap: notes closer together than this are joined with a glide instead of treated as separate notes." |
| tooltip: scope line (one of) | "Changes the default for every item without its own value." · "Changes this item's own value (`*`)." · "Changes the selected note." · "Changes the %d selected notes; each keeps its difference from the others." |
| tooltip: gesture line | "Drag to change ({Mod}-drag: fine). Double-click: reset. {Mod}-click: type a value. Right-click: more." |
| tooltip: pill | `Defaults`: "Nothing is selected: the values here are the defaults. Select notes to change only those notes." · notes: "The values here belong to the selected notes. Press Esc to go back to the defaults." |
| tooltip: Timing toggle | "Show Transition, Onset Ramp, Scoop Shape and Legato Gap" / "Hide the timing values" |
| disabled reasons | "Select an audio item" · "Analyze an item first" · "Wait for the analysis to finish" · "Select notes to change it ({Mod}+A selects all)" · "Set per item: press Esc to deselect, then change it" |
| right-click menu (bar) | "Override for this item" · "Reset to default" · "Reset to inherited" · "Reset to 0%" |
| status messages | unchanged: "Global default changed (not undoable)…", "Global default reset (not undoable)…" |
| undo labels | "Adjust <name>" · "Reset <name>" · "Reset Item Override: <name>" · "Toggle Item Override: <name>" (existing forms; `<name>` from `PARAM_LABELS`) |
| removed | "Overridden on this note. Right-click the note to change it." · "Where Correction Strength comes from." |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Selection pill | `Theme.badge` (display only, fixed `w`) | `P.well`, `P.text`; notes selected: `P.accent2` with `Theme.label_on` |
| Value control frame, label and value | script's `param_drag` (Drag widget) after `Theme.align` | frame colours from `Theme.push`; `L.md` padding; `L.sm` gap between controls |
| Fill bar under a value | `Theme.value_fill` (Library proposal) | track `P.outline`; fill `P.text_dim` (default), `P.accent` (item), `P.accent2` (note); height `L.xs` |
| Timing toggle | `Theme.toggle_button` with `Theme.icons.tri_right` / `Theme.icons.tri_down` | `L.sm` icon gap |
| Tooltips | `Theme.tooltip`, gated by `HoveredFlags_ForTooltip` (+ `AllowWhenDisabled` on disabled controls) | — |
| Group separators, row spacing | existing bar layout (`K.bar_frame`, `HDR_PLANS`) | `L.sm`, `L.md` |
| Right-click menus | `BeginPopupContextItem` + `MenuItem`, as today | — |

## Library proposals

`Theme.value_fill(ctx, lo_frac, hi_frac, opts)` — draws a range fill along the bottom edge of the item just submitted: a track across the item's width and a filled segment from `lo_frac` to `hi_frac` (0..1; `lo_frac = 0` for a single value). `opts.color` (palette colour of the fill), `opts.disabled` (draw nothing). Why no helper fits: `Theme.progress_bar` is a standalone item with its own height, not an overlay on a Drag. Beneficiaries: Pitch Correct now; Parameter Link and Mapper Settings value rows later. Until it is approved through the review skill's Tier C flow, the builder draws the same thing script-locally from the same tokens.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | The pill names what a drag changes at rest; own values show `*` at rest |
| ST2 | Every drag updates the canvas within a frame; default edits post the existing status message |
| ST3 | n/a: no long work added; controls are disabled during analysis |
| ST4 | The shown value is the one in effect; mixed selections show lowest–highest, never one note's value as if shared |
| ST5 | n/a: close behaviour unchanged |
| ST6 | With no item or no analysis the controls show `–` and a reason |
| ST7 | n/a: value edits cannot fail; outdated items use the existing status pill |
| UC1 | One undo point per drag, typed entry or reset; none when nothing changed; labels from `PARAM_LABELS` |
| UC2 | See HC5 |
| UC3 | Note and item values are written inside the edit's undo block; defaults stay ExtState and say "not undoable" |
| UC4 | No bar or menu action changes the note selection; a right-click on a selected note keeps it |
| UC5 | Double-click resets on all seven controls |
| EP1 | n/a: nothing destructive added |
| EP2 | Every disabled control gives its reason in a tooltip with `AllowWhenDisabled` |
| EP3 | `AlwaysClamp` on all seven; all linear (largest range is 12×) |
| EP4 | n/a: no new references to tracks, takes or FX |
| EP5 | No control appears, disappears or moves with the selection; only the Timing toggle and the width change the layout |
| EP6 | No new shortcuts |
| CN1 | Pill, toggle and tooltips use the helpers in Theme mapping |
| CN2 | No raw colours, sizes or spacing; widths from `CalcTextSize` plus tokens |
| CN3 | Every `Theme.*`, `L.*` and palette key used exists (or is the approved proposal) |
| CN4 | "Defaults" (not "Global") for the default level in the bar; "Timing" for the second row; the "…" tooltip no longer overlaps with it |
| CN5 | Info modal and CHANGELOG describe the bar as built |
| CN6 | Drag on the control, Ctrl/Cmd fine, double-click reset, right-click menu; Shift and Alt untouched |
| RC1 | The Timing toggle has a text label; nothing is tooltip-only |
| RC2 | Units on every value (%, ¢, ms); no raw 0–1 values or key names |
| HP1 | The Info modal lists the bar's drag and its modifiers |
| EF1 | Double-click reset, Ctrl/Cmd fine and a context menu on every value; wheel adjust is not added (unchanged) |
| EF2 | See HC6 |
| EF3 | n/a: canvas zoom, scroll and ruler unchanged |
| IA1 | Tier 1 always visible, Tier 2 behind the Timing toggle, nothing in Settings |
| IA2 | One disclosure level; "Timing" predicts its four values |
| IA3 | Canvas stays the primary display; no new type size or weight in the bar |
| IA4 | No control that does nothing: disabled ones state why |
| LG1 | Gaps between groups stay at least twice the gap between value controls |
| LG2 | `Theme.align` before text on the bar rows; no nudges |
| LG3 | Each control's width is measured from its longest text |
| LG4 | Works at ~260 px (wraps as wireframed) and as a wide short strip; only the item badge truncates |
| MT1 | Value controls and the toggle are frame height, at least `L.icon_md` |
| MT2 | The fill bar is drawn on a real Drag item: hit area, hover and active states and cursor come from the widget; text is measured in the font it is drawn in |
| CL1 | See HC1 |
| CL2 | Own values are marked by `*` and the tooltip, not by fill colour alone |
| CL3 | No red used |
| CL4 | Fill and track colours come from the palette; checked in Fancy Dark and Match Theme |
| HI1 | Begin/End pairing unchanged |
| HI2 | Window conditions and context label unchanged |
| HI3 | n/a: toolbar and close behaviour unchanged |
| HI4 | Defaults and the Timing row state are saved on release / on toggle, never per frame |
| HI5 | No REAPER calls and no new table per frame for the bar: the lowest/highest of a mixed selection is one pass over the selected notes, like the correction view's own per-frame check |
| HI6 | Controls use `###` ids, since their labels carry the value |
| HI7 | n/a: no new dependency |
| HC1 | Label and value text ≥ 4.5:1 on the control background; each fill colour ≥ 3:1 against it (the fill is the state indicator); the unfilled track is a pure separator and exempt, as are disabled controls |
| HC2 | Ctrl/Cmd-drag fine adjust on all seven; Shift and Alt not used |
| HC3 | Double-click reset as one undo point; Ctrl/Cmd-click types; right-click opens the menu |
| HC4 | No confirm: nothing destructive. Default edits are not undoable and say so in the status pill (existing) |
| HC5 | Esc: typed entry → menu → active drag (revert) → selection → window when floating |
| HC6 | Space forwarding unchanged; typed entry and menus still block it |
| RB15 | Tooltips go through `Theme.tooltip` behind `HoveredFlags_ForTooltip` |
| RB17 | Value text in the label never changes the control's id |

## Open questions / assumptions

HC6 conflicts: None.

Assumptions made, each open to correction before approval:

1. **"Timing", not "More".** The second row's toggle is labelled "Timing": the bar already has a "…" button whose tooltip begins "More", and "Timing" is the name today's folded button uses for the same values. Scoop Shape joins it there.
2. **Tighten stays note-only.** With nothing selected Tighten is disabled with "Select notes to change it (Cmd+A selects all)". Giving Tighten a default would be a new feature and is not part of this design.
3. **Bar drag is relative, menu row is absolute.** In the bar, several notes move together and keep their differences (as on the canvas); in the note menu, the row sets all selected notes to the right-clicked note's value (as its Tighten and Tolerance rows do today). Typing a value in the bar also sets them equal.
4. **"Defaults" replaces "Global"** as the bar's word for the default level, and the pill no longer shows "Item": an item's own value is marked with `*` on the value itself.
5. **Tooltip wording for Transition, Onset Ramp, Scoop Shape and Legato Gap** is written from the code's comments, not from listening. Please check that each sentence matches what you hear.
6. **Fill colour by source** (quiet for a default, accent for an item's value, secondary accent for a note's value), as the badges are coloured today.
7. **Narrow widths.** The baseline lint did not run (tool drift, see References), and the ~260 px wrap is drawn from the existing plan logic, not yet seen in REAPER.
