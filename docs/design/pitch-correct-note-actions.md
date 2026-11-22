# Design: Fancy Pitch Correct — note action bar above the selection

Target file(s): `Pitch/Fancy_Pitch Correct.lua`, `_lib/theme.lua` (four new icons)
Archetype(s): main window → editor / canvas (unchanged); the note action bar is a control group drawn on the canvas, reviewed under the editor / canvas set plus MT2
Status: Approved
Date: 2026-11-21
Approver: TheFancyWolf (in chat, 2026-11-21)

## Summary

Snap, Quantize, Split and Merge move from four text buttons in the top bar to a small bar of icon buttons that floats just above the selected notes, so the command is next to the note you are fixing. The bar sits outside the selection's pitch traces and note labels, flips below them when there is no room above, and hides while a drag or box-select is in progress. The S / Q / X / M keys, the right-click note menu and the Shortcuts list stay as they are; the four top-bar buttons are removed. Primary display: the selected notes. Primary action on the bar: Snap.

Amendment (approved by TheFancyWolf in chat, 2026-11-21): the bar opens with a readout of the selection. One note selected: its name and cents deviation (`A3 +3¢`), which then is not repeated on a separate label pill. Several selected: the count (`3 notes`), and each note keeps its own pill. The readout has a fixed width, sized for the widest name and the widest cents value, so the buttons never move as the value changes.

Amendment 2 (approved by TheFancyWolf in chat, 2026-11-21): a **Cursor to note** button between Quantize and Split moves REAPER's edit cursor to the middle of the selected note (the primary one when several are selected), so Split can act next; key **C** does the same. **Hold C and turn the wheel** to move the edit cursor from there (wheel up = later, a few pixels per notch, Cmd/Ctrl = finer), clamped to the item; playback follows, as on the ruler. Bar order: Snap · Quantize · Cursor · Split · Merge.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Snap (selected notes to nearest semitone) | target take, edit cursor not used | take pitch envelope, one undo block "Snap Note to Semitone" | none (session data follows the take) | Y: one undo block; the model reloads on `GetProjectStateChangeCount`; nothing persisted outside the project |
| Quantize (selected notes to the active key / scale) | target take, key + scale | take pitch envelope, "Quantize Pitch to Scale" | none | Y: as Snap |
| Cursor to note (C / bar button) | selected note's start / end, item position | edit cursor (`SetEditCurPos`, playback follows) | none | n/a: navigation, like a ruler click; no undo point is written by the script |
| Hold C + wheel (move the edit cursor) | edit cursor, view span | edit cursor | none | n/a: navigation |
| Split (the selected note at the edit cursor) | edit cursor, item position | take pitch envelope, "Split Note"; selection becomes the left half (existing) | none | Y: as Snap (note topology is rebuilt from the project on undo, existing behaviour) |
| Merge (2+ contiguous selected notes) | selection | take pitch envelope, "Merge Notes" | none | Y: as Snap |
| Note Action Bar Size (Settings) | ExtState `pitch_note_bar_size` | ExtState | ExtState | n/a: a preference, outside the undo history like every Settings value |
| Selection readout on the bar | selected notes' centre pitch | nothing | none | n/a: display only |
| Note bar offset (grip drag) | mouse | ExtState `pitch_note_bar_dx`, `pitch_note_bar_dy` | ExtState | n/a: a preference, like the size |
| Show / place the bar | selection, view (time and pitch window), traces and label pills of the selected notes, drag / marquee / popup state | nothing | none | n/a: display only |

All four actions already exist and run through `K.note_action(id, note_idx)`; their enable rules already exist in `action_reason(id)` inside `K.bar_frame`. Nothing about what they do changes.

## References

- Native REAPER analogues: the MIDI editor's right-click note menu and its keyboard commands (the commands stay reachable there and by key; CN6). REAPER has no floating selection toolbar; the closest conventions are the contextual task bars of other editors. Ctrl/Cmd-drag fine adjust and Shift/Alt meanings are untouched (no value controls on the bar).
- Redesigns only: baseline capture taken this session (default dock, E Major, top bar with text buttons Snap / Quantize / Split / Merge right of Separation); `ds-lint.py` not run (no token change in drawn UI beyond the removed buttons).

## Context and job stories

Confirmed at checkpoint 2b (2026-11-21): the bar shows whenever notes are selected, stays visible during playback, holds only Snap / Quantize / Split / Merge, and replaces the top-bar buttons. Pitch Correct is used docked or floating, many times per session, mouse-first with keys for repeat work.

1. When a single note sounds sharp, I want Snap right next to it, so I can fix it without travelling to the top bar.
2. When the analysis cut one sung note into two pieces, I want to box-select them and press Merge right there, so the join takes one click.
3. When a note holds two syllables, I want to put the edit cursor inside it and press Split next to the note, so I can see the result where I am looking.
4. When the song is playing and I am fixing notes on the fly, I want the bar to stay put and out of the traces, so it never hides what I am listening to.
5. When I work by keyboard, I want S / Q / X / M to keep working exactly as now, so the bar is an addition, not a change of habit.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Snap, Quantize, Split, Merge on the bar while notes are selected; keys S / Q / X / M at all times | the most frequent note commands; they need a selection to do anything |
| 2 one disclosure away | the same four in the right-click note menu | existing second route |
| 3 Settings | Note Action Bar Size: Small / Medium (default) / Large, under Appearance & Options | set once to taste; added at the user's request after the first build (2026-11-21) |

## Information architecture

- Regions: the canvas note area gains one floating group, the **note action bar**. The top bar loses its four action buttons; the value controls and the selection pill keep their order.
- Primary display: the selected notes. Primary action on the bar: Snap (first, leftmost).
- Order on the bar: Snap · Quantize · Split · Merge (the order of the top bar, the note menu and the keys).
- Disclosure: none (IA2): the bar appears with the selection; the note menu is the one existing disclosure.

### Placement rule

Revised 2026-11-22 at the user's request (the first rule, centred over the selection and clear of every trace, moved from note to note and felt unpredictable):

1. **Anchor.** The primary selected note (the one clicked last; with none marked primary, the first selected note in view). Its block not in view → the bar is not drawn (the keys and menu still work).
2. **Default place.** Directly below the anchor's block, centred on the middle of its visible part (changed from left-aligned at the user's request, 2026-11-22), top = block bottom + `L.sm`. Traces are ignored, so the bar sits in the same place relative to every note.
3. **Offset.** A grip at the bar's left end (half a button wide, 2 × 3 dots sized from the button) drags the bar; the drag sets one offset (dx, dy, in pixels) that applies to every note from then on and is saved (ExtState `pitch_note_bar_dx` / `pitch_note_bar_dy`). Double-click the grip: offset back to 0, 0.
4. **Bottom edge.** If the bar would run past the bottom of the note area, it goes above the block instead (top = block top − `L.sm` − bar height, the vertical offset mirrored), then it is clamped inside the note area under the ruler, `L.xs` from the sides.
5. **Hidden while:** a note, edge, Slide In or pitch-point drag is active; a box-select is active; a drag on the pitch strip or overview strip is active; any popup or modal is open; the item is analysing; the take is bypassed. Dragging the grip does not hide it.

## Wireframes

Bar, at every width (four 24 px buttons: `icon_md` padding around an `L.xl` icon, enlarged in the first build so the shapes read; `L.sm` between them, `L.xs` inside the frame; it does not change with the window):

```
 ╭───────────────────────────────╮
 │ A3    +3¢ │ [═▬═] [ Q ] [▬▼▬] [▶◀▬] │   readout · Snap · Quantize · Split · Merge
 ╰───────────────────────────────╯
```

Readout slot: `L.sm` of padding, then a fixed width = widest note name (every name, octaves −1 to 9) + `L.sm` + widest cents value (−50¢ to +50¢, or the count when that is wider), then `L.sm` and a `P.border` hairline before the buttons. The name is left-aligned and the cents right-aligned in the slot, so the digits end at the same place and the buttons stay put.

Default floating / docked (about 1600 × 650, as captured):

```
 ruler  |9s      |10s     |11s     |12s
 G4     ·                 ╭──────────────╮
 F#4    ·                 │ ═▬═  Q  ▬▼▬ ▶◀▬ │   ← bar, centred over the selection
 F4     ·                 ╰──────────────╯
 E4     ·                  [F#3 +0¢]          ← label pill of the selected note
 ...    ·         ~~~~~~~ ▓▓▓▓▓▓▓▓▓▓▓▓ ~~~    ← selected note block and its trace
```

Selection near the top of the view (no room above): flips below.

```
 ruler  |9s      |10s
 A#4      ▓▓▓▓▓▓▓▓▓▓      ← selected note at the top edge
 A4     ╭──────────────╮
 G#4    │ ═▬═  Q  ▬▼▬ ▶◀▬ │
 G4     ╰──────────────╯
```

Narrow docker (~260 px wide, note area ~150 px): the bar (~100 px) still fits; it is clamped to the note area's edges, so on a selection at the right edge it sits left of centre:

```
 │C#4│          ╭──────────────╮│
 │C4 │          │ ═▬═  Q  ▬▼▬ ▶◀▬ ││
 │B3 │       ▓▓▓▓▓▓╰──────────────╯│   (clamped right; the block runs under the edge)
```

Wide short strip (e.g. 1200 × 150, note area ~70 px tall): there is often no room above or below; the bar pins under the ruler and may overlap a trace. That is the documented fallback; deselecting (Esc) or the keys remain.

```
 ruler |1s   |2s   |3s ╭──────────────╮  |5s
 E3    ▓▓▓▓~~~~~▓▓▓▓▓~ │ ═▬═  Q  ▬▼▬ ▶◀▬ │ ~~▓▓
                       ╰──────────────╯
```

Top bar after the change (default width): `[item] [key] [scale] Defaults | Tighten | Strength | Tolerance | Slide In | Separation   … ×` — the four action buttons are gone and the freed width goes to the existing LG4 order (values are hidden later than before at narrow widths).

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| note action bar | empty | no notes selected: no bar (nothing for it to act on); the canvas's existing empty / not-analysed states are unchanged | ST6 |
| note action bar | working | an action is instant (< 0.1 s); the status pill reports the result as now ("Snapped 2 notes. Cmd+Z to undo") | ST3 |
| note action bar | error | a refusal from the action itself (e.g. merge gap > 300 ms) posts its existing reason in the status pill | ST7 |
| note action bar | disabled with reason | a button that cannot act is disabled with its icon in `P.text_dim`; hovering shows its tip plus the reason, the same strings as today's top bar: "Select 2 or more notes", "Select one note to split", "Move the edit cursor into the selected note" | EP2 |
| note action bar | overflow / long names | the readout slot is sized for the widest possible text, so it never truncates or shifts the buttons; a count wider than the slot widens the bar | LG4 |
| note action bar | one / several selected | one note: `A3 +3¢` (its label pill is folded into the bar); several: `3 notes`, each note keeps its pill; the hovered unselected note keeps its pill | ST1 |
| note action bar | missing dependency | none beyond the script's own ReaImGui check | HI7 |
| note action bar | Fancy Dark / Match Theme | frame `P.panel` with a `P.border` hairline on both; icons `P.text`, hover / press faces from `Theme.icon_btn` | CL4 |
| note action bar | hidden during a gesture | gone while dragging, box-selecting, a menu is open, analysing or bypassed; back on release | EF3 |
| top bar | after removal | no action buttons; values keep their order | EP5 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Snap button | click runs `K.note_action("snap")`; HC2 / HC3 n/a: discrete command; no wheel; no context menu (right-click passes to nothing) | n/a | n/a | n/a | "Snap Note to Semitone" (only when a note moved) | no confirm: one Cmd/Ctrl+Z restores it; status message posted |
| Quantize button | click runs `K.note_action("quantize")`; as Snap | n/a | n/a | n/a | "Quantize Pitch to Scale" | as Snap |
| Cursor button | click runs `K.note_action("cursor", sel_idx)`; as Snap; key C | n/a | n/a | inside the note | none (navigation) | n/a: not destructive |
| Hold C + wheel | wheel up = later, `K.SCRUB_PX` px of the current view per notch; Cmd/Ctrl = 1/5 of that (HC2); replaces the canvas's wheel mappings only while C is held | n/a | time | clamped to the item | none | n/a |
| Grip (left end of the bar) | drag moves the bar, saved on release; double-click puts it back under the note; cursor ResizeAll on hover; HC2 n/a (a position, not a value) | 0, 0 | px | inside the note area | none (a preference) | n/a |
| Split button | click runs `K.note_action("split", sel_idx)`; as Snap | n/a | n/a | n/a | "Split Note" | as Snap |
| Merge button | click runs `K.note_action("merge")`; as Snap | n/a | n/a | n/a | "Merge Notes" | as Snap |

A click on the bar never reaches the canvas: the canvas `InvisibleButton` already allows overlap, so the bar's buttons (submitted after it) take the hover, and the canvas does not deselect, start a marquee or move the edit cursor. The mouse cursor over an enabled button is the hand (from `Theme.icon_btn`).

| Note Action Bar Size combo (Settings > Appearance & Options) | click to choose; HC2 / HC3 n/a: discrete | Medium | Small, Medium, Large: icons `L.xl`, `L.xxl`, `L.xxl + L.md` (24 / 32 / 40 px buttons; Medium and Large enlarged at the user's request, 2026-11-22) | list only | none (Settings are not undoable) | n/a: no data lost; saved at once |

Keyboard map: unchanged. Esc keeps its order (modal → active edit → selection → window, HC5); deselecting with Esc hides the bar because the selection is gone. Space is forwarded as now (HC6). S / Q / X / M keep their existing modifier guards and no-repeat (EP6). The Info modal row "Snap / Quantize / Split / Merge buttons" is reworded to the bar (HP1, CN5).

## Copy deck

| Where | String |
|---|---|
| labels | readout: `<note> <±cents>¢` (e.g. `A3 +3¢`, the label pill's format) or `<n> notes` |
| tooltips | "Snap to nearest semitone (S)" · "Quantize to the active scale (Q)" · "Edit cursor to the middle of the note (C)" · "Split at the edit cursor (X)" · "Merge the selected notes (M)" (unchanged from the top bar) |
| empty / error / confirm | disabled reasons, unchanged: "Select a note" · "Select 2 or more notes" · "Select one note to split" · "Move the edit cursor into the selected note"; action refusals unchanged |
| status messages | unchanged ("Snapped 2 notes. Cmd+Z to undo", "Already at the nearest semitone", "Merged 3 notes. …", "Split the note at the edit cursor. …") |
| undo labels | unchanged: "Snap Note to Semitone", "Quantize Pitch to Scale", "Split Note", "Merge Notes" |
| Info modal | "Note action bar (below the selected note)" · "Drag the bar's grip" → "Move the bar (double-click: back under the note)" · was "Note action bar (above the selected notes)" → "Snap · Quantize · Split · Merge, same as S / Q / X / M" |
| Settings | "Note Action Bar Size" · Small / Medium / Large · tooltip "Size of the Snap, Quantize, Split and Merge buttons above the selected notes" |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| readout | `reaper.ImGui_DrawList_AddText` + `reaper.ImGui_CalcTextSize` (fixed slot, cached per font size) | `P.text`, `P.border` (divider), `L.sm` |
| bar frame | drawn on the window draw list (rounded rect + hairline) | `P.panel`, `P.border`, `L.rounding`, `L.border`, `L.xs` |
| buttons | `Theme.icon_btn` with `opts.preset = L.icon_md`, `opts.icon_size = L.xl` inside `reaper.ImGui_BeginDisabled` | `L.icon_md`, `L.xl`, `L.sm` (gap) |
| enabled icon | `Theme.icon_btn` default colour | `P.text` |
| disabled icon | `Theme.icon_btn` with `opts.color` | `P.text_dim` |
| tooltip and reason | `Theme.tooltip`, gated on `HoveredFlags_ForTooltip \| HoveredFlags_AllowWhenDisabled` (the top bar's `bar_tooltip` pattern) | none |
| icons | `Theme.icons.snap`, `Theme.icons.quantize`, `Theme.icons.split`, `Theme.icons.merge` | see Library proposals |
| gaps to content | placement rule | `L.sm`, `L.xs` |

## Library proposals

Chosen with the user on 2026-11-21 from sketches. The four share one picture language: a note is a filled rounded bar, a pitch row is a thin line, the edit cursor is a small down-pointing triangle with a line under it. Sizes are fractions of `hs` (the icon's half size); strokes use the existing icon stroke width.

`Theme.icons.snap(dl, cx, cy, hs, col)` · a note bar centred between two row lines (the lines faint, the bar solid), no arrow: what an aligned note looks like on the Pitch Correct canvas · Pitch Correct.

`Theme.icons.quantize(dl, cx, cy, hs, col)` · a regular-weight Q drawn as a stroked circle with a short diagonal tail at its lower right, as REAPER's MIDI editor uses Q for quantize (vector shapes, not text) · Pitch Correct; any future quantize command.

`Theme.icons.split(dl, cx, cy, hs, col)` · the edit cursor (triangle at the top, line down through the middle) with a note bar on each side of it, a gap between them · Pitch Correct; item-split commands in other scripts.

`Theme.icons.merge(dl, cx, cy, hs, col)` · two filled triangles at the top pointing at each other (mirroring Split's single cursor triangle) above two note bars that meet at a hairline seam · Pitch Correct.

All four follow the existing icon contract (vector shapes on a draw list, sized by `hs`, one colour), are added to the Design System script's icon gallery, and need no new tokens.

## Acceptance criteria

- ST1: the bar is visible whenever notes are selected and not in a gesture; the selection pill in the top bar keeps naming the target.
- ST2: every click posts the existing status message within 0.1 s; no silent return.
- ST3: actions are instant; no progress state needed.
- ST4: the bar shows only the four actions and their true enabled state, read per frame.
- ST5: n/a: no lifecycle beyond the main window.
- ST6: no selection → no bar; the canvas empty states are unchanged.
- ST7: refusals post their existing reason.
- UC1: one undo point per action, only when something changed; labels unchanged.
- UC2: Esc ownership unchanged; the bar owns no Esc.
- UC3: undo / redo reload the model as now.
- UC4: no selection change from showing or clicking the bar beyond what the actions already do (Split selects the left half, existing).
- UC5: n/a: no values on the bar.
- EP1: no destructive action beyond one-undo commands (HC4).
- EP2: disabled buttons show the reason in a tooltip that fires when disabled, the same strings as today.
- EP3: n/a: no inputs.
- EP4: button IDs fixed (`##note_bar_snap` etc.).
- EP5: deviation, approved at checkpoint 2b: the bar appears and moves with the selection; the stable routes are the keys, the note menu and the Shortcuts list (see Open questions).
- EP6: keys unchanged; the bar adds no shortcut.
- CN1: built from `Theme.icon_btn`, `Theme.tooltip` and the icon contract.
- CN2: tokens only (`P.panel`, `P.border`, `P.text`, `P.text_dim`, `L.*`).
- CN3: the four new icons exist in `_lib/theme.lua` before the script uses them.
- CN4: names match the keys, the note menu and the Shortcuts list (Snap, Quantize, Split, Merge).
- CN5: Info modal row reworded; Shortcuts list rows for S / Q / X / M already present.
- CN6: REAPER conventions untouched (no Shift / Alt meaning added).
- RC1: icons carry their name and key in the tooltip; the Shortcuts list names them.
- RC2: copy unchanged, in user terms.
- HP1: the Info modal lists the bar.
- EF1: the keys stay the accelerators.
- EF2: Space and REAPER keys pass through as now.
- EF3: zoom / scroll unchanged; the bar is hidden during strip and canvas drags so the scale and view stay as the user drags them.
- IA1: tiers as above.
- IA2: no new disclosure level.
- IA3: one primary display (selected notes); Snap first on the bar.
- IA4: no dead UI: the removed top-bar buttons leave no gap or placeholder.
- LG1: the bar is grouped with what it acts on (above the selection).
- LG2: icons centred in equal-size buttons on one row.
- LG3: bar width from the button count and tokens, not a constant.
- LG4: the bar fits from the narrow docker up; at very short heights it pins under the ruler (documented fallback).
- MT1: 24 px buttons at Small (32 / 40 px at Medium / Large) with an `L.sm` gap.
- MT2: real `Button`s via `Theme.icon_btn` (hover, active, hand cursor, tooltip), so no hand-built hit testing.
- CL1: n/a for disabled icons (exempt inside `BeginDisabled`); enabled icons use `P.text` on `P.panel` (≥ 3:1 in both modes).
- CL2: state is shown by shape (each icon) and by enabled / disabled, not colour alone.
- CL3: colours keep their meanings (no accent on the bar).
- CL4: checked in Fancy Dark and Match Theme.
- DV1: n/a: excluded for editor / canvas.
- HI1: no new window; drawn inside the canvas child's existing Begin / End.
- HI2: n/a: no new window.
- HI3: n/a: no toolbar or close button involved.
- HI4: nothing persisted.
- HI5: the placement scan reads only the selected notes' frames within the visible span, once per frame.
- HI6: fixed `##` IDs.
- HI7: no new dependency.
- RB15: tooltips through `Theme.tooltip` behind `HoveredFlags_ForTooltip`.
- RB17: fixed IDs, no dynamic labels.
- RB19: every function used already exists in the script or ReaImGui 0.10.
- HC1: as CL1.
- HC2: n/a: no value controls.
- HC3: n/a: no value controls.
- HC4: no confirm: each action is one undo block, the model reloads on undo, nothing is written outside the project; a status message is posted.
- HC5: unchanged; the bar owns no Esc.
- HC6: unchanged.

## Open questions / assumptions

- EP5 deviation: the bar appears and moves with the selection. Recorded as the user's choice at checkpoint 2b (2026-11-21: "Whenever notes are selected", top-bar buttons removed). The keys, the right-click note menu and the Shortcuts list are the stable routes.
- Assumption: the bar stays visible during playback (user's choice), and the placement is recomputed every frame, so if the view auto-scrolls the bar follows the selection.
- Icon shapes chosen by the user from sketches (2026-11-21), described under Library proposals; they are checked again at real size in the first build.
- HC6 conflicts: None.
