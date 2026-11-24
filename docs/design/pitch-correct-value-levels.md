# Design: Fancy Pitch Correct — value levels and the Values group

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (top bar Values group, redesigned); "Apply to other items" confirm → the window's existing confirm modal (same archetype)
Status: Approved
Date: 2026-11-24
Approver: TheFancyWolf (in chat, 2026-11-24)

## Summary

The top bar's Values group (the scope pill, then Mode, Tighten, Strength, Tolerance, Slide In and Separation, all at the same weight) is reorganised. It now has three named groups, **Notes** (Separation), **Correction** (Mode, Tighten, Tolerance) and **Shaping** (Strength, Slide In), and Shaping is drawn quieter. Every value now has the same three levels: every item → this item → notes. The bar only ever edits **this item**, or the selected notes, and the pill says which. The "every item" values stop being something a drag changes silently: they change only through one deliberate command, **Apply to other items…**, which can also push this item's values onto other items as a starting point. Separation and Key / Scale join the same model: Separation becomes per item, plus a re-split of just the selected notes' stretch. Primary display: the note canvas (unchanged). Primary action: dragging a value in the bar, or a note on the canvas (unchanged).

## Approaches

Three ways were considered in the brainstorming conversation (2026-11-24):

- **A. A scope switch in the bar** (`[This item | All items]`, with drags in "All items" held back until an Apply button is pressed). You can always see the level, but it means two modes in one control, held-back values to track, and the most UI in the bar.
- **B. The bar edits this item or the selected notes; "all items" is one command behind the pill (picked).** It fixes the wrong label at its source, adds one menu and no mode, and gives the multi-item "starting point" flow without making the bar heavier.
- **C. The every-item values live in Settings**, with their own Apply. The clearest place to manage starting values, but it is a second copy of every control and a trip to Settings for every session.

The user picked **B** (2026-11-24) and added: Separation is per item (50% stays the default), per-note Separation if possible, and Key is per item too.

## Feature inventory

Levels used below: **starting values** (ExtState, `FancyScripts`); **item** = the take's value (take data, `P_EXT`); **note** = a note's own value (take data). A lower level overrides the one above it.

**The model (decided by the user, 2026-11-24, after the builder check):**

- **Copy once.** Each item copies the starting values when it is first analysed, and from then on holds a value for every key: Key, Scale, Separation, Mode, Tighten, Tolerance, Strength, Slide In. Items never follow the starting values live. Changing the starting values affects only items analysed later, unless Apply pushes them onto existing items. `get_effective`'s live fall-back to `global_defaults` for analysed items, and the "other items are now outdated" status after a global edit (`mark_stale_takes` called from `note_global_edit`), both go away. An item analysed before this change, which has no item values, copies the current starting values the first time it is opened. There are no migrations, per the project rule.
- **An item value reaches every note** in the item, not only edited notes. That is an engine change: today `K.correction_build` corrects only notes where `is_note_modified` is true. Now every note that is not bypassed gets the item's Mode, Tighten, Tolerance and Slide In (and its Strength, which only scales a note's pitch move, so it has no effect on a note nobody moved). A note to be left as sung uses the existing Bypass. Fresh items still sound as sung, because the starting Tighten and Slide In are 0%.
- **Note values are explicit.** For Tighten and Slide In, `nil` now means "follow the item" and `0` is a real value a note can hold (the `zero_nil` storage goes). This lets a note sit at 0% under an item at 40%. "Edited" for the engine and for the note colours means "has a value of its own, or a pitch move", not "Tighten above 0".
- **The `*` mark** on the item means it differs from the starting value. On notes, it means a selected note differs from the item.

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Changed: drag / type / reset a value with **no note selected** (Separation, Mode, Tighten, Tolerance, Strength, Slide In) | the open take, its note model | the item's own value in take data; the take's pitch envelope | take data (`P_EXT`) inside the undo block | **Y**. Today the same gesture writes the every-item value (ExtState, not undoable) unless a hidden item override exists. That path is removed: the bar never writes ExtState |
| Changed: Tighten and Slide In gain an item level (today note-only, disabled with nothing selected) | same | same | take data | **Y** |
| Unchanged: drag / type / reset a value with **notes selected** (Mode, Tighten, Tolerance, Strength, Slide In) | same | the selected notes' own values; envelope | take data | **Y** (as today) |
| Changed: Separation with no note selected re-splits **this item** at its own Separation (today: one value for every item, ExtState `pitch_separation`) | the take's stored analysis frames | the item's notes and the Separation they were split at (already stored per take as `data.separation`); envelope | take data | **Y**: one undo step, as today's re-split. Its existing "may ask first" confirm (K.resplit) is kept |
| New: Separation with **notes selected** re-splits only the stretch from the first selected note's start to the last selected note's end; the notes outside it are untouched; the new notes come back selected | the take's analysis frames inside that stretch | the notes inside the stretch; envelope | take data | **Y**: one undo step "Re-split selected notes" |
| Changed: Key / Scale stay per item (already stored per take as `key_idx` / `scale_idx`), but choosing them **no longer changes the starting key for new items** (today every change also writes ExtState `pitch_key_idx` / `pitch_scale_idx`) | the open take | the item's key / scale; envelope | take data | **Y** for the item. Today's ExtState write is removed from this path |
| New: pill menu → **Apply to other items…** opens a confirm; it applies all of this item's values (Key, Scale, Separation, Mode, Tighten, Tolerance, Strength, Slide In) | the arrange selection; every take with Pitch Correct data in the project (the Pitched Items list); each target's item and note values | per target item: its item values set to this item's; its notes' own values for those keys cleared; a re-split where Separation changed; its envelope. With **"Keep changes already made to items and notes"** ticked: a target's item value that differs from the *previous* starting value is kept, notes with their own value keep it, and a target whose notes carry edits (pitch moves, points, own values) is **not** re-split. Unticked: everything is overwritten, and re-splits go ahead even where edited notes are lost; the confirm counts those notes. The starting values are saved when Apply starts. A Cancel partway keeps them and the finished items, and its status says so | take data for every target in **one** undo block; **ExtState** for the starting values | **N**: the every-item values are ExtState. So HC4 requires the confirm, which names the consequence and the counts. Everything written to items is one undo step |
| New: right-click a value → **Apply <Value> to other items…** opens the same confirm with only that value | same | same, that key only | same | **N** (as above) |
| New: pill menu → **Reset this item to the starting values** copies the current starting values into this item (Key and Scale included; a re-split if Separation differs, with K.resplit's existing ask-first when edits would be lost). Its notes' own values are kept | the open take | item values, envelope, notes when re-split | take data | **Y**: one undo step |
| New: a whole-item re-split (item Separation drag, Apply, Reset) replaces any stretch that was re-split on its own: per-note Separation is not stored. With notes selected, Separation shows the item's value. A stretch re-split leaves `data.separation` unchanged, and `K.follow_resplit_undo` learns the new label "Re-split selected notes" and does not move the item value for it | | | | |
| Changed (engine): every non-bypassed note gets the item's values, not only edited notes; `zero_nil` storage for Tighten / Slide In goes (see the model above) | | | | |
| Removed: right-click → "Override for this item" (the bar now always edits the item); right-click → "Reset to default" is renamed **Reset to starting value** (item) or **Reset to item value** (notes) | | | | |
| Unchanged: Key / Scale combos' place in the Clip group, the target badge, "…" menu, Close, the note action bar, the canvas | | | | |

## References

- Native REAPER analogues: Item Properties (F2), which edits the selected item's own pitch and playrate and has no hidden global; Project Settings → "Default for new items", which only affects items created later; actions on all selected items that report once (Item: Normalize). Conventions matched (CN6): the arrange selection is the scope of "selected items" and is never changed (UC4); one undo point named with the count; right-click menus on values; Ctrl/Cmd-drag fine and double-click reset (HC2, HC3); no Alt or Shift given a new meaning.
- Redesigns only: baseline capture **not taken**: the script was not running in the user's REAPER session (2026-11-24), and launching it would clear their selection and zoom. The baseline is read from code: `HDR_VALUES = { "pill", "mode", "tight", "strength", "tol", "slide", "sep" }` drawn by `K.bar_frame`, pill texts `Defaults` / `1 note` / `%d notes`. `ds-lint.py` summary: **did not run** ("theme.lua palette drifted from ds-lint's port of build_palette", 22 unknown keys), a tool fault noted in earlier Pitch Correct designs too.

## Context and job stories

Confirmed in the brainstorming conversation (2026-11-24); window context carried over from the value bar checkpoint (`pitch-correct-value-bar.md`, confirmed then): docked with the bar at the top, values dragged during looped playback, edited by mouse, keys for note actions.

1. When I open a new vocal item, I want to see at a glance which controls find the notes, which correct them and which fine-tune them, so I can start with the few that matter (Mode, Tighten, Tolerance, Separation).
2. When a take needs different settings from my usual (a breathy verse), I want my drags to change only this item, so my other items are not changed behind my back.
3. When a vocal is cut into many items, I want to push one item's values (or just its Tolerance) onto the selected items as a starting point, so I can then go through each item and fix it.
4. When I've already hand-tuned some items, I want an "apply to all" to leave that work alone if I say so, so a batch never wipes careful edits.
5. When two notes are wrongly joined in one phrase, I want to raise Separation for just those notes, so the rest of the item stays split as it is.
6. When a song changes key between sections that are separate items, I want each item to keep its own key.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Key, Scale; the pill; Separation; Mode, Tighten, Tolerance (full weight); Strength, Slide In (quieter, Shaping) | used constantly while tuning; the user named Mode, Tighten, Tolerance and Separation as the main ones. Strength and Slide In stay visible (they are still used) but recede |
| 2 one disclosure away | pill menu: Apply to other items…, Reset this item to the starting values, the starting values readout; value right-click: Apply <Value> to other items…, Reset | a few times per project |
| 3 Settings | none new | |

## Information architecture

Top bar groups, read left to right from broad to specific:

- **Clip** (unchanged): brand, target badge (names the item), Key, Scale. Key and Scale are item values: they sit with the item's name, not after the pill, because they have no note level.
- **Values**: the pill, then three named groups, each with a small caption.
  - **Notes**: Separation. How the singing is split into notes.
  - **Correction**: Mode, Tighten, Tolerance. How a note is pulled in.
  - **Shaping**: Strength, Slide In. Fine-tuning. Drawn in `Theme.font_sizes.small` at a narrower width, but not dim: `P.text_dim` already means "this mode does not use it" in this bar, so it cannot also mean "secondary".
- **Right** (unchanged): "…", Panel, Close.

**The pill is the one statement of level.** It reads `This item` with nothing selected, or `1 note` / `N notes`. Every control right of it edits what it names, with no exceptions: Separation's note level is the re-split of the selected stretch. Clicking the pill opens its menu (disclosure level 1). "Apply to other items…" opens the confirm (level 2). IA2 is met.

**Group captions** (`Notes`, `Correction`, `Shaping`) are small text before each group, so a new user can read what each group is for without hovering. They are the first thing to go as the width shrinks (LG4: width-driven hiding, never state-driven, EP5). When hidden, the hairline separators stay and each control's tooltip starts with its group name.

**Where the every-item values are shown:** in the pill menu (a readout line) and in each value's tooltip ("Starting value: 8¢"). The `*` mark keeps its meaning: this item's or note's value differs from the level above.

## Wireframes

Default floating / wide docked (one row, captions shown):
```
[◆] [V_Main E251.wav] [E▾] [Major▾] │ (This item▾) │ Notes Separation 50% │ Correction Mode Natural▾  Tighten 40%*  Tolerance 8¢ │ Shaping Strength 100%  Slide In 0%  │ […][▭][×]
```
With 3 notes selected (the pill turns accent, values follow the notes):
```
[◆] [V_Main E251.wav] [E▾] [Major▾] │ (3 notes▾) │ Notes Separation 50% │ Correction Mode Mixed▾  Tighten 20–60%*  Tolerance 8¢ │ Shaping Strength 100%  Slide In 0%  │ […][▭][×]
```
Medium width (two rows; captions still shown when the Values row fits them, else dropped first):
```
[◆] [V_Main E251.wav] [E▾] [Major▾]                                                     […][▭][×]
(This item▾) │ Separation 50% │ Mode Natural▾  Tighten 40%*  Tolerance 8¢ │ Strength 100%  Slide In 0%
```
Narrow docker (~260 px): no captions; the Values group wraps by group, Shaping on its own row, so the main controls stay together:
```
[◆] [V_Main E25…]     […][▭][×]
[E▾] [Major▾]
(This item▾)  Separation 50%
Mode Natural▾  Tighten 40%*
Tolerance 8¢
Strength 100%  Slide In 0%
```
Wide short strip (1200×150): the one-row plan with captions; the canvas fills the rest.

Pill menu (a popup under the pill, sized to its content):
```
┌──────────────────────────────────────────────┐
│ Edits go to: this item                       │  (dim; "the 3 selected notes")
│ Starting values: Sep 50% · Natural · Tighten │  (dim, one line, truncated + tooltip)
│ 0% · Tol 8¢ · Strength 100% · Slide In 0%    │
│──────────────────────────────────────────────│
│ Apply to other items…                        │
│ Reset this item to the starting values       │  (disabled: "Already at the starting values")
└──────────────────────────────────────────────┘
```
Apply confirm (sized to the parent; at the narrow docker its text wraps, RB9):
```
┌ Apply this item's values to other items? ─────────────────┐
│ Key E Major · Separation 50% · Mode Natural · Tighten 40% │
│ Tolerance 8¢ · Strength 100% · Slide In 0%                │
│                                                           │
│ Apply to:  (•) The 4 selected items                       │
│            ( ) All 12 pitched items                       │
│            ( ) New items only                             │
│ [ ] Keep changes already made to items and notes          │
│                                                           │
│ 3 items lose their own values, 41 notes lose theirs,      │
│ 2 items change key, 2 are split again (7 edited notes     │
│ in them are lost).                                        │
│ These also become the starting values for new items       │
│ (that part can't be undone with Cmd+Z).                   │
│                                        [Cancel] [Apply (4)]│
└───────────────────────────────────────────────────────────┘
```

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Values group | empty | no item: every value disabled with "Select an audio item"; item not analysed: Correction and Shaping disabled with "Analyze an item first", while Separation, Key and Scale stay usable and are used by the first analysis | ST6 |
| Values group | working | during an analysis or a batch Apply: values disabled with "Analyzing…"; the "…" button shows progress (existing) | ST3 |
| Apply confirm | working | Apply over many items runs time-sliced with progress on the "…" button and Cancel in "…" (same as Analyze All Selected Items); Cancel keeps the items already done as the one undo step | ST3 |
| Apply | error | an item that cannot be written (take gone, MIDI) is skipped and counted: "Applied to 3 items. 1 skipped: no audio." | ST7 |
| Pill menu | disabled with reason | "Apply to other items…" disabled with "No other pitched items" when there are none; "Reset this item…" disabled with "Already at the starting values" | EP2 |
| Apply confirm | disabled with reason | "The N selected items" disabled with "Select items in the arrange view" when 0 other items are selected; Apply disabled with "Nothing would change" | EP2, AR5 |
| Separation | disabled with reason | with notes selected but no analysis frames for that stretch: "This stretch has no analysis: Re-analyze the item" | EP2 |
| Pill / captions | overflow / long names | pill width fixed to its longest text (`999 notes`); captions hide before any control wraps; the starting values line truncates with a tooltip | LG4 |
| — | missing dependency | none beyond ReaImGui (existing check) | HI7 |
| All | Fancy Dark / Match Theme | captions `P.text_dim`, Shaping `P.text` at the small size; pill `P.well` / `P.accent2` as today; both checked against `bg` for HC1 | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Separation | drag; Ctrl/Cmd-drag fine; double-click reset; Ctrl/Cmd-click type; right-click menu (Reset, Apply Separation to other items…); no wheel (EF1: the top bar scrolls) | `DEFAULTS.separation` (50%) | `Separation %.0f%%` | 0–100, linear, `AlwaysClamp` | "Re-split item" / "Re-split selected notes" | item, notes: undoable, no confirm (existing re-split confirm only when edits would be lost) |
| Mode | combo; right-click menu (Reset, Apply Mode to other items…) | Natural | `Mode <name>`, `Mixed` | n/a: discrete | "Set Mode" | undoable |
| Tighten | as Separation | 0% (`zero_nil`) | `Tighten %.0f%%` | 0–100, linear | "Adjust Tighten" | undoable |
| Tolerance | as Separation | `DEFAULTS.tolerance` (8¢) | `Tolerance %.0f¢` | 0–50, linear | "Adjust Tolerance" | undoable |
| Strength | as Separation | `DEFAULTS.retune_speed` (100%) | `Strength %.0f%%` | 0–100, linear | "Adjust Correction Strength" | undoable |
| Slide In | as Separation | 0% | `Slide In %.0f%%` | 0–100, linear | "Adjust Slide In" | undoable |
| Key, Scale | combos (unchanged); right-click menu: Apply Key to other items… | last starting values | key names as today | n/a: discrete | "Set Key" / "Set Scale" | undoable (no ExtState write any more) |
| Pill | click opens its menu; tooltip | n/a | `This item` / `1 note` / `%d notes` | n/a | n/a | n/a |
| Pill menu: Apply to other items… | click → confirm | n/a | n/a | n/a | n/a | confirm (HC4: ExtState written) |
| Pill menu: Reset this item… | click | n/a | n/a | n/a | "Reset item to starting values" | undoable, no confirm; status message |
| Apply confirm | radio (3), checkbox, Cancel first, Apply (N); Esc = Cancel; Enter does nothing (no default button on a destructive confirm) | target: the selected items when 1 or more other items are selected, else All pitched items; checkbox off | counts in the consequence line | n/a | "Apply values to N items" | the confirm itself |

What a double-click reset restores (HC3): on notes, the item's value; on the item, the starting value. That is the script's `DEFAULTS` value until the user has applied other starting values (see Open questions).

Keyboard map: HC5 Esc, innermost first: the Apply confirm (Cancel) → the pill menu / value right-click menu → an active value edit (revert) → the note selection (the pill goes back to `This item`) → the window (floating only). All through `Shortcut()` (RB6). HC6 Space is unchanged and is not forwarded while the confirm or a menu is open. No new keys. The Info modal's Edit rows gain "Click the pill: apply values to other items" and the changed reset meaning (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | `This item` · `1 note` · `%d notes` · captions `Notes` · `Correction` · `Shaping` · value labels as today |
| tooltips | pill, item: "Your edits change this item only. Select notes to change just those notes. Click for: apply to other items." · pill, notes: "Your edits change the selected notes. Esc goes back to this item. Click for: apply to other items." · Separation, notes: "Splits the selected stretch again: only the notes from the first to the last selected one change." · every value's last line: "Starting value: <v>. This item: <v>." · captions when hidden: each value's tooltip starts "Correction ·", "Shaping ·", "Notes ·" |
| empty / error / confirm | confirm title "Apply this item's values to other items?" / "Apply Tolerance to other items?" · radios "The %d selected items" / "All %d pitched items" / "New items only" · checkbox "Keep changes already made to items and notes" · consequence "%d items lose their own values, %d notes lose theirs, %d items change key, %d are split again (%d edited notes in them are lost)." (with Keep changes ticked: "%d items with edited notes are not split again.") · footnote "These also become the starting values for new items (that part can't be undone with %s+Z)." · buttons "Cancel", "Apply (%d)" (New items only: "Save starting values") · disabled reasons as in the State inventory |
| status messages | "Applied to %d items (%s+Z undoes the items)." · "Starting values saved for new items." · "Applied to %d items. %d skipped: no audio." · "Item reset to the starting values." · "Re-split %d notes into %d." |
| undo labels | "Adjust Tighten" etc. (as today) · "Re-split item" · "Re-split selected notes" · "Apply values to %d items" · "Apply Tolerance to %d items" · "Reset item to starting values" |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| pill | `Theme.badge` with `interactive = true`, `id`, then a popup (as today, now clickable) | `P.well`, `P.text`; notes: `P.accent2`, `Theme.label_on` |
| pill menu rows | `Theme.selectable` / `reaper.ImGui_MenuItem`, readout via `reaper.ImGui_TextDisabled`-free dim text | `P.text_dim`, `L.sm` |
| group captions | `Theme.push_font` at `Theme.font_sizes.small`, `Theme.align` then text | `P.text_dim`, `L.sm` gap after |
| group separators | existing hairline (`P.border`) | `L.xl` group gap (existing `hdr_gap_before`) |
| Correction values | existing `param_drag` | as today |
| Shaping values | existing `param_drag` with the small font pushed | `Theme.font_sizes.small`; width measured with that font (LG3) |
| Apply confirm | the existing confirm modal path (`request_confirm`), `Theme.center_next_window`, `Theme.modal_scrim` | `L.modal_md` |
| radios / checkbox | `reaper.ImGui_RadioButton`, `reaper.ImGui_Checkbox` (stock, themed by `Theme.push`) | |
| tooltips | `Theme.tooltip` via the bar's `bar_tooltip` (AllowWhenDisabled) | |

## Library proposals

None.

## Acceptance criteria

- ST1: the pill always names the level being edited (`This item` / `N notes`); the item badge names the item.
- ST2: every Apply, reset and re-split posts one status message on the canvas pill.
- ST3: Apply over many items is time-sliced with progress and Cancel, like Analyze All Selected Items.
- ST4: every value shows the value in effect for what the pill names; tooltips give the starting value and the item value.
- ST5: n/a: closing behaviour is unchanged.
- ST6: no item / not analysed states name the next step.
- ST7: skipped items are counted in user terms.
- UC1: one named undo point per drag, typed entry, reset, re-split and Apply; none when nothing changed.
- UC2: Esc order as in the keyboard map.
- UC3: item and note writes and their `P_EXT` share one undo block; the every-item values (ExtState) are never claimed as undoable.
- UC4: Apply reads the arrange selection and never changes it; re-split reselects only notes inside the script.
- UC5: double-click reset per value; "Reset this item to the starting values" as the group reset.
- EP1: Apply is behind a confirm that names the consequence and counts.
- EP2: every disabled entry and control has a reason, visible with tooltips off where it is inline (pill menu, confirm).
- EP3: all values `AlwaysClamp`, linear.
- EP4: target items are referenced by take GUID.
- EP5: no control moves or hides because of selection; captions hide by width only.
- EP6: no new shortcuts.
- CN1: only existing Theme helpers and the existing confirm path.
- CN2: no literals; `L.modal_md`; scrim before the confirm.
- CN3: all names exist.
- CN4: one term each: "this item", "starting values", "pitched items", "re-split".
- CN5: Info rows and CHANGELOG match the handlers.
- CN6: deviations recorded (reset restores the level above).
- RC1: n/a: no new icon-only controls.
- RC2: no internal terms ("override", "cascade", "global default") in the UI.
- HP1: the Info modal lists the pill click and the reset meaning.
- EF1: right-click menus on every value; no wheel in the bar.
- EF2: Space forwarded as today.
- EF3: n/a: canvas unchanged.
- IA1: tiers as in the Priority tiers table.
- IA2: two levels: pill menu → confirm.
- IA3: the bar uses two type sizes (default, small); Correction reads first by size and position.
- IA4: the removed "Override for this item" leaves no dead entry.
- LG1: group gaps (`L.xl`) are at least twice the gaps inside a group.
- LG2: captions use `Theme.align`.
- LG3: every width comes from its longest text in the font it is drawn with.
- LG4: one row, two rows and the narrow docker as wireframed; captions hide first.
- MT1: the pill is at least frame height.
- MT2: n/a: no new DrawList controls.
- CL1: captions and Shaping text meet 4.5:1 on `bg` in both modes.
- CL2: the notes state is text (`3 notes`) as well as colour.
- CL3: no red added.
- CL4: checked in Fancy Dark and Match Theme.
- DV1: n/a: Editor / canvas excludes it.
- HI1–HI7: unchanged window lifecycle; HI5: Apply's counts are computed when the confirm opens, not every frame.
- RB6: Esc via `Shortcut()`. RB9: the confirm fits the parent at the narrow docker. RB15: tooltips through `Theme.tooltip`. RB17: pill label uses `###bar_pill`.
- HC1: as CL1. HC2, HC3: on every value control. HC4: Apply confirm; the other writes are undoable. HC5: as the keyboard map. HC6: unchanged.

## Open questions / assumptions

- Decided by the user (2026-11-24): items copy the starting values once, and do not follow them live. An item value reaches every note that is not bypassed. See "The model" under Feature inventory.
- My call (builder check): "Keep changes" keeps item values that differ from the previous starting values and notes' own values, and it skips the re-split of any item whose notes carry edits. Unticked, the confirm counts the edited notes a re-split will lose.
- My call (builder check): the starting values are saved when Apply starts, and survive a Cancel.
- My call (builder check): a whole-item re-split replaces stretch-only splits. Separation with notes selected shows the item's value.
- My call (builder check): Mode's item text changes from "Notes you edit will use it" to a statement that every note uses it.
- My call: reset on the item restores the starting value, and reset on notes restores the item's value. HC3 says `DEFAULTS`; these are the same until you apply other starting values. This is recorded as a deviation.
- My call: Key and Scale stop updating the starting key for new items whenever they change. New items start from the starting values, which change only through Apply (including "New items only").
- My call: "Apply to other items" applies every value, Key and Scale included. A single value is applied from its right-click menu. Quantize and other note actions across items are a later, separate design.
- My call: the Shaping group is quieter through size (`font_sizes.small`), not colour, because dim text already means "unused by this mode".
- My call: Separation per note re-splits a stretch. It is not stored as a lasting note value, because a re-split replaces the notes themselves. Edits on surviving notes are kept, as in the auto-joins design.
- HC6 conflicts: None.
