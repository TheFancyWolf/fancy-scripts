# Design: Fancy Pitch Correct — value levels and the Values group

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (top bar Values group, redesigned); "Apply to other items" confirm → the window's existing confirm modal (same archetype)
Status: Approved
Amended 2026-11-24 after use: captions removed; item reset goes to defaults; the Apply confirm's target radios became a checklist of the pitched items. Amended again 2026-11-24, the user's decision "Always defaults": no starting values; new and re-analysed items start at `DEFAULTS`; Apply writes only the ticked items and is fully undoable.
Date: 2026-11-24
Approver: TheFancyWolf (in chat, 2026-11-24)

## Summary

The top bar's Values group (the scope pill, then Mode, Tighten, Strength, Tolerance, Slide In and Separation, all at the same weight) is reorganised. It now has three groups split by hairline separators, **Notes** (Separation), **Correction** (Mode, Tighten, Tolerance) and **Shaping** (Strength, Slide In), all in the default font; each value's tooltip names its group. Every value now has the same levels: the script's default (`DEFAULTS`) → this item → notes. The bar only ever edits **this item**, or the selected notes, and the pill says which. Other items change only through one deliberate command, **Apply to other items…**, which pushes this item's values onto the items the user ticks, as a starting point. A new or re-analysed item always starts at the defaults (amended 2026-11-24, "Always defaults": there are no saved starting values). Separation and Key / Scale join the same model: Separation becomes per item, plus a re-split of just the selected notes' stretch. Primary display: the note canvas (unchanged). Primary action: dragging a value in the bar, or a note on the canvas (unchanged).

## Approaches

Three ways were considered in the brainstorming conversation (2026-11-24):

- **A. A scope switch in the bar** (`[This item | All items]`, with drags in "All items" held back until an Apply button is pressed). You can always see the level, but it means two modes in one control, held-back values to track, and the most UI in the bar.
- **B. The bar edits this item or the selected notes; "all items" is one command behind the pill (picked).** It fixes the wrong label at its source, adds one menu and no mode, and gives the multi-item "starting point" flow without making the bar heavier.
- **C. The every-item values live in Settings**, with their own Apply. The clearest place to manage starting values, but it is a second copy of every control and a trip to Settings for every session.

The user picked **B** (2026-11-24) and added: Separation is per item (50% stays the default), per-note Separation if possible, and Key is per item too.

## Feature inventory

Levels used below: **default** = the script's `DEFAULTS` (code, never stored); **item** = the take's value (take data, `P_EXT`); **note** = a note's own value (take data). A lower level overrides the one above it. The only ExtState left is the Key and Scale a new item starts in (`pitch_key_idx` / `pitch_scale_idx`).

**The model (decided by the user, 2026-11-24, after the builder check; amended 2026-11-24, "Always defaults"):**

- **Always defaults.** A new item, and an item analysed again (Re-Analyze, Analyze Selected Items), starts at the script's `DEFAULTS`: Separation 50%, Mode Natural, Tighten 0%, Tolerance 8¢, Strength 100%, Slide In 0%. Re-analysis does not keep the item's old values; it splits at 50%, and the notes are new anyway. From then on the item holds a value for every key. There are no saved starting values: the `global_defaults` table and its ExtState keys (`pitch_tighten`, `pitch_slide_in`, `pitch_correct_mode`, `pitch_start_separation`, `pitch_tolerance`, `pitch_retune_speed`) are gone and no longer read. Old values stored in a take are simply that item's values; an item analysed before 2.22 with no values gets `DEFAULTS`. No migrations, no compatibility shims (project rule). One exception to "a new item starts at the defaults": an item not analysed yet whose Separation the user sets in the bar before its first analysis is split at that value ("This item's first analysis uses it.").
- **Key and Scale (controller's call, 2026-11-24).** They describe the song, not the analysis: a re-analysis keeps the item's own Key and Scale. A new item starts in the Key and Scale last chosen in the bar, stored as before 2.22 in ExtState `pitch_key_idx` / `pitch_scale_idx` whenever the user changes Key or Scale (a preference outside the item's undo point). Apply can still push Key and Scale onto ticked items.
- **An item value reaches every note** in the item, not only edited notes. That is an engine change: today `K.correction_build` corrects only notes where `is_note_modified` is true. Now every note that is not bypassed gets the item's Mode, Tighten, Tolerance and Slide In (and its Strength, which only scales a note's pitch move, so it has no effect on a note nobody moved). A note to be left as sung uses the existing Bypass. Fresh items still sound as sung, because the starting Tighten and Slide In are 0%.
- **Note values are explicit.** For Tighten and Slide In, `nil` now means "follow the item" and `0` is a real value a note can hold (the `zero_nil` storage goes). This lets a note sit at 0% under an item at 40%. "Edited" for the engine and for the note colours means "has a value of its own, or a pitch move", not "Tighten above 0".
- **The `*` mark** on the item means it differs from the default (`DEFAULTS`). On notes, it means a selected note differs from the item.

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Changed: drag / type / reset a value with **no note selected** (Separation, Mode, Tighten, Tolerance, Strength, Slide In) | the open take, its note model | the item's own value in take data; the take's pitch envelope | take data (`P_EXT`) inside the undo block | **Y**. Today the same gesture writes the every-item value (ExtState, not undoable) unless a hidden item override exists. That path is removed: the bar's values never write ExtState |
| Changed ("Always defaults"): a **new item**, and an item **analysed again** (Re-Analyze, Analyze Selected Items), starts at `DEFAULTS` for every value (Separation 50%: a re-analysis splits at 50%); a re-analysis keeps the item's Key and Scale, a new item takes the Key and Scale last chosen | the take's stored model (Key, Scale only) | the new model with the default values | take data | **Y** (the analysis's undo step, as today) |
| Changed: Tighten and Slide In gain an item level (today note-only, disabled with nothing selected) | same | same | take data | **Y** |
| Unchanged: drag / type / reset a value with **notes selected** (Mode, Tighten, Tolerance, Strength, Slide In) | same | the selected notes' own values; envelope | take data | **Y** (as today) |
| Changed: Separation with no note selected re-splits **this item** at its own Separation (today: one value for every item, ExtState `pitch_separation`) | the take's stored analysis frames | the item's notes and the Separation they were split at (already stored per take as `data.separation`); envelope | take data | **Y**: one undo step, as today's re-split. Its existing "may ask first" confirm (K.resplit) is kept |
| New: Separation with **notes selected** re-splits only the stretch from the first selected note's start to the last selected note's end; the notes outside it are untouched; the new notes come back selected | the take's analysis frames inside that stretch | the notes inside the stretch; envelope | take data | **Y**: one undo step "Re-split selected notes" |
| Unchanged: Key / Scale stay per item (already stored per take as `key_idx` / `scale_idx`), and choosing them also sets the Key and Scale a new item starts in (ExtState `pitch_key_idx` / `pitch_scale_idx`, as before 2.22; amended 2026-11-24: this write is allowed again) | the open take | the item's key / scale; envelope | take data; ExtState for the new-item key | **Y** for the item. The new-item key is a preference, not undone |
| New: pill menu → **Apply to other items…** opens a confirm; it applies all of this item's values (Key, Scale, Separation, Mode, Tighten, Tolerance, Strength, Slide In) | every take with Pitch Correct data in the project (the Pitched Items list) but the open item, shown as a checklist in the confirm; the arrange selection only decides which rows start ticked; each ticked target's item and note values | per ticked target item: its item values set to this item's; its notes' own values for those keys cleared; a re-split where Separation changed; its envelope. With **"Keep changes already made to items and notes"** ticked: a target's item value that differs from the **default** (`DEFAULTS`) is the user's and is kept (Key and Scale have no default, so Keep does not hold them back), notes with their own value keep it, and a target whose notes carry edits (pitch moves, points, own values) is **not** re-split. Unticked: everything is overwritten, and re-splits go ahead even where edited notes are lost; the confirm counts those notes. Nothing else is written: no ExtState ("New items only" is removed). A Cancel partway keeps the finished items, and its status says so | take data for every ticked target in **one** undo block | **Y**: one Cmd+Z restores every item. The confirm stays as the target picker (Cancel first, Esc = Cancel) and still names the consequence and counts |
| New: right-click a value → **Apply <Value> to other items…** opens the same confirm with only that value | same | same, that key only | same | **Y** (as above) |
| New: pill menu → **Reset this item to defaults** sets every value of this item to the script's `DEFAULTS` (Separation 50%, Mode Natural, Tighten 0%, Tolerance 8¢, Strength 100%, Slide In 0%; Key and Scale are not changed; a re-split if Separation differs, with K.resplit's existing ask-first when edits would be lost). Its notes' own values are kept (amended after use: it used to copy the starting values, Key and Scale included) | the open take | item values, envelope, notes when re-split | take data | **Y**: one undo step |
| New: a whole-item re-split (item Separation drag, Apply, Reset) replaces any stretch that was re-split on its own: per-note Separation is not stored. With notes selected, Separation shows the item's value. A stretch re-split leaves `data.separation` unchanged, and `K.follow_resplit_undo` learns the new label "Re-split selected notes" and does not move the item value for it | | | | |
| Changed (engine): every non-bypassed note gets the item's values, not only edited notes; `zero_nil` storage for Tighten / Slide In goes (see the model above) | | | | |
| Removed: right-click → "Override for this item" (the bar now always edits the item); right-click → "Reset to default" stays **Reset to default** on the item (it sets `DEFAULTS[key]`) and reads **Reset to item value** with notes selected | | | | |
| Unchanged: Key / Scale combos' place in the Clip group, the target badge, "…" menu, Close, the note action bar, the canvas | | | | |

## References

- Native REAPER analogues: Item Properties (F2), which edits the selected item's own pitch and playrate and has no hidden global; Project Settings → "Default for new items", which only affects items created later; actions on all selected items that report once (Item: Normalize). Conventions matched (CN6): the arrange selection only pre-ticks the Apply list and is never changed (UC4); one undo point named with the count; right-click menus on values; Ctrl/Cmd-drag fine and double-click reset (HC2, HC3); no Alt or Shift given a new meaning.
- Redesigns only: baseline capture **not taken**: the script was not running in the user's REAPER session (2026-11-24), and launching it would clear their selection and zoom. The baseline is read from code: `HDR_VALUES = { "pill", "mode", "tight", "strength", "tol", "slide", "sep" }` drawn by `K.bar_frame`, pill texts `Defaults` / `1 note` / `%d notes`. `ds-lint.py` summary: **did not run** ("theme.lua palette drifted from ds-lint's port of build_palette", 22 unknown keys), a tool fault noted in earlier Pitch Correct designs too.

## Context and job stories

Confirmed in the brainstorming conversation (2026-11-24); window context carried over from the value bar checkpoint (`pitch-correct-value-bar.md`, confirmed then): docked with the bar at the top, values dragged during looped playback, edited by mouse, keys for note actions.

1. When I open a new vocal item, I want to see at a glance which controls find the notes, which correct them and which fine-tune them, so I can start with the few that matter (Mode, Tighten, Tolerance, Separation).
2. When a take needs different settings from my usual (a breathy verse), I want my drags to change only this item, so my other items are not changed behind my back.
3. When a vocal is cut into many items, I want to push one item's values (or just its Tolerance) onto the items I tick (the selected ones to begin with) as a starting point, so I can then go through each item and fix it.
4. When I've already hand-tuned some items, I want an "apply to all" to leave that work alone if I say so, so a batch never wipes careful edits.
5. When two notes are wrongly joined in one phrase, I want to raise Separation for just those notes, so the rest of the item stays split as it is.
6. When a song changes key between sections that are separate items, I want each item to keep its own key.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Key, Scale; the pill; Separation; Mode, Tighten, Tolerance; Strength, Slide In (Shaping, last) | used constantly while tuning; the user named Mode, Tighten, Tolerance and Separation as the main ones. Strength and Slide In stay visible (they are still used) and come last |
| 2 one disclosure away | pill menu: Apply to other items…, Reset this item to defaults; value right-click: Apply <Value> to other items…, Reset | a few times per project |
| 3 Settings | none new | |

## Information architecture

Top bar groups, read left to right from broad to specific:

- **Clip** (unchanged): brand, target badge (names the item), Key, Scale. Key and Scale are item values: they sit with the item's name, not after the pill, because they have no note level.
- **Values**: the pill, then three groups split by hairline separators (no captions).
  - **Notes**: Separation. How the singing is split into notes.
  - **Correction**: Mode, Tighten, Tolerance. How a note is pulled in.
  - **Shaping**: Strength, Slide In. Fine-tuning. Drawn in the default font, the same size as the other values (amended: the small font is gone).
- **Right** (unchanged): "…", Panel, Close.

**The pill is the one statement of level.** It reads `This item` with nothing selected, or `1 note` / `N notes`. Every control right of it edits what it names, with no exceptions: Separation's note level is the re-split of the selected stretch. Clicking the pill opens its menu (disclosure level 1). "Apply to other items…" opens the confirm (level 2). IA2 is met.

**No group captions** (amended after use: the captions `Notes`, `Correction`, `Shaping` did not help, the separators did). The hairline separators and the `L.xl` group gaps show where a group ends, and each value's tooltip always starts with its group name ("Notes ·", "Correction ·", "Shaping ·").

**Where the defaults are shown:** in each value's tooltip ("Default: 8¢. This item: 12¢."). The pill menu has no readout line (removed with the starting values). The `*` mark: this item's value differs from the default, or a note's from the item.

## Wireframes

Default floating / wide docked (one row):
```
[◆] [V_Main E251.wav] [E▾] [Major▾] │ (This item▾) │ Separation 50% │ Mode Natural▾  Tighten 40%*  Tolerance 8¢ │ Strength 100%  Slide In 0%  │ […][▭][×]
```
With 3 notes selected (the pill turns accent, values follow the notes):
```
[◆] [V_Main E251.wav] [E▾] [Major▾] │ (3 notes▾) │ Separation 50% │ Mode Mixed▾  Tighten 20–60%*  Tolerance 8¢ │ Strength 100%  Slide In 0%  │ […][▭][×]
```
Medium width (two rows: the Clip row, then the Values row; the window a first use opens with):
```
[◆] [V_Main E251.wav] [E▾] [Major▾]                                                     […][▭][×]
(This item▾) │ Separation 50% │ Mode Natural▾  Tighten 40%*  Tolerance 8¢ │ Strength 100%  Slide In 0%
```
Narrow docker (~260 px): the Values group wraps by group, Shaping on its own row, so the main controls stay together:
```
[◆] [V_Main E25…]     […][▭][×]
[E▾] [Major▾]
(This item▾)  Separation 50%
Mode Natural▾  Tighten 40%*
Tolerance 8¢
Strength 100%  Slide In 0%
```
Wide short strip (1200×150): the one-row plan; the canvas fills the rest.

Pill menu (a popup under the pill, sized to its content):
```
┌──────────────────────────────────────────────┐
│ Edits go to: this item                       │  (dim; "the 3 selected notes")
│──────────────────────────────────────────────│
│ Apply to other items…                        │
│ Reset this item to defaults                  │  (disabled: "Already at the defaults")
└──────────────────────────────────────────────┘
```
Apply confirm (sized to the parent; at the narrow docker its text wraps, RB9; the list scrolls past 6 rows, RB13):
```
┌ Apply this item's values to other items? ─────────────────┐
│ Key E Major · Separation 50% · Mode Natural · Tighten 40% │
│ Tolerance 8¢ · Strength 100% · Slide In 0%                │
│                                                           │
│ Apply to:  [All] [None]                                   │
│ ┌───────────────────────────────────────────────────────┐ │
│ │ [x] Verse 1 Lead                                      │ │
│ │ [x] Verse 2 Lead                                      │ │
│ │ [ ] Chorus Lead Double (take 3, comped from the bes…  │ │  (tooltip: full name)
│ │ [ ] Synth Pad                    Not an audio item    │ │  (disabled, dim reason)
│ │ [ ] Old Bridge Take              No longer in the pr… │ │  (disabled)
│ │ [x] Outro Lead                                        │▒│
│ └───────────────────────────────────────────────────────┘ │
│ [ ] Keep changes already made to items and notes          │
│                                                           │
│ 3 items lose their own values, 41 notes lose theirs,      │
│ 2 items change key, 2 are split again (7 edited notes     │
│ in them are lost).                                        │
│                                        [Cancel] [Apply (3)]│
└───────────────────────────────────────────────────────────┘
```
Rows start ticked from REAPER's arrange-view selection (the listed items that are selected); when none of them is selected, every row starts ticked. Only the ticked items change ("New items only" and the footnote about starting values are removed, 2026-11-24).

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Values group | empty | no item: every value disabled with "Select an audio item"; item not analysed: Correction and Shaping disabled with "Analyze an item first", while Separation, Key and Scale stay usable and are used by the first analysis | ST6 |
| Values group | working | during an analysis or a batch Apply: values disabled with "Analyzing…"; the "…" button shows progress (existing) | ST3 |
| Apply confirm | working | Apply over many items runs time-sliced with progress on the "…" button and Cancel in "…" (same as Analyze All Selected Items); Cancel keeps the items already done as the one undo step | ST3 |
| Apply | error | an item that cannot be written (take gone, MIDI) is skipped and counted: "Applied to 3 items. 1 skipped: no audio." | ST7 |
| Pill menu | disabled with reason | "Apply to other items…" disabled with "No other pitched items" when there are none; "Reset this item to defaults" disabled with "Already at the defaults" | EP2 |
| Apply confirm | disabled with reason | a row whose item cannot be written is disabled, never ticked, with its reason beside the name: "Not an audio item" (MIDI take), "No longer in the project" (take gone); Apply (0) disabled with "Tick at least one item" when no row is ticked, "No item here can be changed" when no row can be ticked, or "Nothing would change" when the ticked items already have the values | EP2, AR5 |
| Apply confirm | many items | the checklist is a bordered region of at most 6 rows (`K.CHECKLIST_MAX_ROWS`) that scrolls; only the rows in view are drawn (ListClipper); a long name is shortened with an ellipsis and its tooltip shows it in full (LG4) | RB13, LG4 |
| Separation | disabled with reason | with notes selected but no analysis frames for that stretch: "This stretch has no analysis: Re-analyze the item" | EP2 |
| Pill | overflow / long names | pill width fixed to its longest text (`999 notes`) | LG4 |
| — | missing dependency | none beyond ReaImGui (existing check) | HI7 |
| All | Fancy Dark / Match Theme | every value `P.text` in the default font; pill `P.well` / `P.accent2` as today; checked against `bg` for HC1 | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Separation | drag; Ctrl/Cmd-drag fine; double-click reset; Ctrl/Cmd-click type; right-click menu (Reset, Apply Separation to other items…); no wheel (EF1: the top bar scrolls) | `DEFAULTS.separation` (50%) | `Separation %.0f%%` | 0–100, linear, `AlwaysClamp` | "Re-split item" / "Re-split selected notes" | item, notes: undoable, no confirm (existing re-split confirm only when edits would be lost) |
| Mode | combo; right-click menu (Reset, Apply Mode to other items…) | `DEFAULTS.correct_mode` (Natural) | `Mode <name>`, `Mixed` | n/a: discrete | "Set Mode" | undoable |
| Tighten | as Separation | `DEFAULTS.tighten` (0%) | `Tighten %.0f%%` | 0–100, linear | "Adjust Tighten" | undoable |
| Tolerance | as Separation | `DEFAULTS.tolerance` (8¢) | `Tolerance %.0f¢` | 0–50, linear | "Adjust Tolerance" | undoable |
| Strength | as Separation | `DEFAULTS.retune_speed` (100%) | `Strength %.0f%%` | 0–100, linear | "Adjust Correction Strength" | undoable |
| Slide In | as Separation | `DEFAULTS.slide_in` (0%) | `Slide In %.0f%%` | 0–100, linear | "Adjust Slide In" | undoable |
| Key, Scale | combos (unchanged); right-click menu: Apply Key to other items… | the item's own; a new item: the Key and Scale last chosen (ExtState `pitch_key_idx` / `pitch_scale_idx`) | key names as today | n/a: discrete | "Set Key" / "Set Scale" | the item: undoable; the new-item key in ExtState is a preference, not undone |
| Pill | click opens its menu; tooltip | n/a | `This item` / `1 note` / `%d notes` | n/a | n/a | n/a |
| Pill menu: Apply to other items… | click → confirm | n/a | n/a | n/a | n/a | undoable in one step; the confirm stays as the target picker |
| Pill menu: Reset this item to defaults | click: every value of the item (Separation, Mode, Tighten, Tolerance, Strength, Slide In) to `DEFAULTS`; Key and Scale not changed; a re-split when Separation changes (the existing ask-first when edits would be lost: "Reset <item> to the defaults?", button "Reset") | `DEFAULTS` | n/a | n/a | "Reset item to defaults" (none when already at the defaults) | undoable, no confirm; status message |
| Apply confirm | checklist (one checkbox per other pitched item; click the box or the name), All / None small buttons, one checkbox ("Keep changes…"), Cancel first, Apply (N); Esc = Cancel; Enter does nothing (no default button on a destructive confirm). The consequence and Apply (N) follow the ticked rows, recomputed only when the ticked set or "Keep changes…" changes (HI5). The arrange selection is only read when the confirm opens (UC4) | ticked: the listed items selected in the arrange view, else every row that can be written; "Keep changes…" off | counts in the consequence line | n/a | "Apply values to N items" | the confirm itself; one Cmd+Z undoes the Apply |

What a double-click reset (or the right-click Reset) restores (HC3): on notes, the item's value ("Reset to item value"); on the item, the script's `DEFAULTS` value ("Reset to default"), as one undo point "Reset <Value>" (Separation: its re-split, "Re-split item"), and none when the item is at the default already (UC1). Amended after use: the item reset used to go to the starting value.

Keyboard map: HC5 Esc, innermost first: the Apply confirm (Cancel) → the pill menu / value right-click menu → an active value edit (revert) → the note selection (the pill goes back to `This item`) → the window (floating only). All through `Shortcut()` (RB6). HC6 Space is unchanged and is not forwarded while the confirm or a menu is open. No new keys. The Info modal's Edit rows gain "Click the pill: Apply values to other items, or reset this item to defaults" and "Double-click a value: Back to the item's value (notes) or the default (item)" (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | `This item` · `1 note` · `%d notes` · value labels as today (no captions) |
| tooltips | pill, item: "Your edits change this item only. Select notes to change just those notes. Click for: apply to other items." · pill, notes: "Your edits change the selected notes. Esc goes back to this item. Click for: apply to other items." · Separation, notes: "Splits the selected stretch again: only the notes from the first to the last selected one change." · every value's last line: "Default: <v>. This item: <v>." · each value's tooltip always starts with its group: "Notes ·", "Correction ·", "Shaping ·" |
| empty / error / confirm | confirm title "Apply this item's values to other items?" / "Apply Tolerance to other items?" · list heading "Apply to:" · buttons "All" / "None" · row reasons "Not an audio item" / "No longer in the project" · checkbox "Keep changes already made to items and notes" · consequence "%d items lose their own values, %d notes lose theirs, %d items change key, %d are split again (%d edited notes in them are lost)." (with Keep changes ticked: "%d items with edited notes are not split again.") · buttons "Cancel", "Apply (%d)" · disabled reasons as in the State inventory, including "Tick at least one item" · Info modal: "* after a value: Differs from the default (a note: from its item)" |
| status messages | "Applied to %d items (%s+Z undoes them)." · "Applied to %d items. %d skipped: no audio." · "Apply cancelled. No item was changed." · "Apply cancelled. %d of %d items were changed and kept (%s+Z undoes them)." · "Item reset to the defaults." · "Re-split %d notes into %d." |
| undo labels | "Adjust Tighten" etc. (as today) · "Re-split item" · "Re-split selected notes" · "Apply values to %d items" · "Apply Tolerance to %d items" · "Reset item to defaults" · "Reset <Value>" |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| pill | `Theme.badge` with `interactive = true`, `id`, then a popup (as today, now clickable) | `P.well`, `P.text`; notes: `P.accent2`, `Theme.label_on` |
| pill menu rows | `Theme.selectable` / `reaper.ImGui_MenuItem`, readout via `reaper.ImGui_TextDisabled`-free dim text | `P.text_dim`, `L.sm` |
| group separators | existing hairline (`P.border`) | `L.xl` group gap (existing `hdr_gap_before`) |
| Notes, Correction and Shaping values | existing `param_drag`, the default font | as today; width measured in the font drawn (LG3) |
| Apply confirm | the existing confirm modal path (`request_confirm`), `Theme.center_next_window`, `Theme.modal_scrim` | `L.modal_md` |
| radios / checkbox | `reaper.ImGui_RadioButton`, `reaper.ImGui_Checkbox` (stock, themed by `Theme.push`) | |
| tooltips | `Theme.tooltip` via the bar's `bar_tooltip` (AllowWhenDisabled) | |

## Library proposals

None.

## Acceptance criteria

- ST1: the pill always names the level being edited (`This item` / `N notes`); the item badge names the item.
- ST2: every Apply, reset and re-split posts one status message on the canvas pill.
- ST3: Apply over many items is time-sliced with progress and Cancel, like Analyze All Selected Items.
- ST4: every value shows the value in effect for what the pill names; tooltips give the default and the item value.
- ST5: n/a: closing behaviour is unchanged.
- ST6: no item / not analysed states name the next step.
- ST7: skipped items are counted in user terms.
- UC1: one named undo point per drag, typed entry, reset, re-split and Apply; none when nothing changed.
- UC2: Esc order as in the keyboard map.
- UC3: item and note writes and their `P_EXT` share one undo block; Apply writes no ExtState, so one Cmd+Z restores it all. The new-item Key / Scale (ExtState) is never claimed as undoable.
- UC4: Apply reads the arrange selection (to tick the first rows) and never changes it; re-split reselects only notes inside the script.
- UC5: double-click reset per value; "Reset this item to defaults" as the group reset.
- EP1: Apply is behind a confirm that names the consequence and counts.
- EP2: every disabled entry and control has a reason, visible with tooltips off where it is inline (pill menu, confirm).
- EP3: all values `AlwaysClamp`, linear.
- EP4: target items are referenced by take GUID.
- EP5: no control moves or hides because of selection.
- EP6: no new shortcuts.
- CN1: only existing Theme helpers and the existing confirm path.
- CN2: no literals; `L.modal_md`; scrim before the confirm.
- CN3: all names exist.
- CN4: one term each: "this item", "default", "pitched items", "re-split".
- CN5: Info rows and CHANGELOG match the handlers.
- CN6: deviations recorded (reset on notes restores the item's value; on the item it is `DEFAULTS`, as HC3).
- RC1: n/a: no new icon-only controls.
- RC2: no internal terms ("override", "cascade", "global default") in the UI.
- HP1: the Info modal lists the pill click and the reset meaning.
- EF1: right-click menus on every value; no wheel in the bar.
- EF2: Space forwarded as today.
- EF3: n/a: canvas unchanged.
- IA1: tiers as in the Priority tiers table.
- IA2: two levels: pill menu → confirm.
- IA3: every value uses the default font; Correction reads first by position.
- IA4: the removed "Override for this item" leaves no dead entry.
- LG1: group gaps (`L.xl`) are at least twice the gaps inside a group.
- LG2: every value control is centred on the row as today (no captions).
- LG3: every width comes from its longest text in the font it is drawn with.
- LG4: one row, two rows (Clip row + Values row) and the narrow docker as wireframed.
- MT1: the pill is at least frame height.
- MT2: n/a: no new DrawList controls.
- CL1: every value's text meets 4.5:1 on `bg` in both modes.
- CL2: the notes state is text (`3 notes`) as well as colour.
- CL3: no red added.
- CL4: checked in Fancy Dark and Match Theme.
- DV1: n/a: Editor / canvas excludes it.
- HI1–HI7: unchanged window lifecycle; HI5: Apply's counts are computed when the confirm opens and again only when the ticked rows or a checkbox change, not every frame.
- RB6: Esc via `Shortcut()`. RB9: the confirm fits the parent at the narrow docker. RB15: tooltips through `Theme.tooltip`. RB17: pill label uses `###bar_pill`.
- HC1: as CL1. HC2, HC3: on every value control. HC4: Apply confirm; the other writes are undoable. HC5: as the keyboard map. HC6: unchanged.

## Open questions / assumptions

- Decided by the user (2026-11-24): an item holds its own values and does not follow anything live (first as a copy of the starting values; since "Always defaults", the defaults). An item value reaches every note that is not bypassed. See "The model" under Feature inventory.
- Decided by the user (2026-11-24, "Always defaults"): there are no saved starting values. A new item and a re-analysed item (Re-Analyze, Analyze Selected Items) always start at `DEFAULTS`; a re-analysis does not keep the item's old values, Separation included (it splits at 50%). Apply pushes values only onto the ticked items, writes no ExtState and is undone by one Cmd+Z; "New items only" and the footnote about starting values are removed. "Keep changes" keeps an item value that differs from the default (it used to compare with the previous starting value) and notes' own values, and skips the re-split of any item whose notes carry edits. Unticked, the confirm counts the edited notes a re-split will lose. The `*` mark means "differs from the default"; the value tooltips read "Default: <v>. This item: <v>."; the pill menu has no starting values line.
- Controller's call (2026-11-24, with "Always defaults"): a re-analysis keeps the item's own Key and Scale (they describe the song, not the analysis); a new item takes the Key and Scale last chosen in the bar, stored in ExtState `pitch_key_idx` / `pitch_scale_idx` when the user changes them (as before 2.22). Key and Scale have no default, so "Keep changes" does not hold them back. An item not analysed yet keeps a Separation the user set in the bar before its first analysis.
- Superseded (2026-11-24): the builder-check call that the starting values are saved when Apply starts and survive a Cancel.
- My call (builder check): a whole-item re-split replaces stretch-only splits. Separation with notes selected shows the item's value.
- My call (builder check): Mode's item text changes from "Notes you edit will use it" to a statement that every note uses it.
- Decided by the user (amended 2026-11-24 after use): reset on the item restores the script's `DEFAULTS` value ("Reset to default"; Separation re-splits at 50%), which is HC3-compliant; reset on notes restores the item's value. The pill menu's group reset is "Reset this item to defaults" (Key and Scale not changed). The `*` mark now means "differs from the default" ("Always defaults").
- Superseded (2026-11-24, "Always defaults"): Key and Scale stopping to set the key for new items, and the "New items only" checkbox. Key and Scale set the new-item key again; "New items only" is removed.
- My call: "Apply to other items" applies every value, Key and Scale included. A single value is applied from its right-click menu. Quantize and other note actions across items are a later, separate design.
- Decided by the user (amended 2026-11-24 after use): no group captions, and Shaping is drawn in the default font like the other values. The hairline separators stay.
- My call: Separation per note re-splits a stretch. It is not stored as a lasting note value, because a re-split replaces the notes themselves. Edits on surviving notes are kept, as in the auto-joins design.
- HC6 conflicts: None.
