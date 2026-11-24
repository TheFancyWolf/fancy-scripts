# Design: Fancy Pitch Correct — Analyze All Selected Items

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); batch confirm → the window's existing confirm modal (same archetype)
Status: Approved
Date: 2026-11-23
Approver: TheFancyWolf (in chat, 2026-11-23)

## Summary

Pitch Correct analyses one item at a time today. This design adds a batch: every audio item selected in REAPER's arrange view is analysed one after another, behind one undo step. It starts from the button on an empty canvas, which reads "Analyze All Selected Items" when several items are selected, and from a new entry in the "…" menu, so it can also be reached from an item that already has notes. The window's primary display (the note canvas) and primary action (dragging a note) do not change. Brief: `docs/superpowers/specs/2026-11-23-analyze-selected-items-and-singer-test-set.md`, Part A.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| New: Analyze All Selected Items (canvas button with 2 or more audio items selected; "…" → Analyze Selected Items (N)) | the arrange selection (selected items, each one's active take, audio or not), each take's stored analysis, each take's audio | per item: the note model on the take and its pitch envelope (cleared, and created and shown where it was missing), all in one block when the batch ends | take data (`P_EXT`) inside the undo block; nothing else | Y: every item is written inside one undo block; the script reloads its model when the project state changes; no ExtState, JSON or file is touched |
| New: ask once before a batch that replaces existing analyses | each selected take's stored analysis; the name, track and position of each item that has one | none | none | n/a: nothing is changed until the user confirms |
| New: Cancel during a batch (the existing Cancel entry of "…") | none | the finished items only, as one undo block; the item in progress and the items not started are left exactly as they were | take data inside the undo block | Y: as the batch |
| New: batch progress (the "…" button, the status pill) and the closing message | none | none | none | n/a: display only |
| New: the note under the canvas button (several items can be analysed at once) | the arrange selection (count only) | none | none | n/a: display only |
| Changed: the Pitched Items panel is read-only while any analysis runs (single or batch): rows cannot be switched, bypassed or removed until it ends | none | none | none | n/a. Today a row click during an analysis switches the item under the running analysis; the batch owns the open item, so the panel is locked for its duration |
| Changed: every analysis reads the uncorrected audio (the Re-Analyze fix of the brief) | the take's audio without its pitch correction | nothing lasting: the take's correction is exactly as before after Cancel or an error | none | Y: an analysis that completes is one undo step as today; one that does not leaves nothing to undo |
| Existing, unchanged: Analyze / Re-Analyze of the open item ("…" menu, and the canvas button with one item selected), its confirm when edits would be lost, Cancel of a single analysis | as today | as today (its own "Analyze Pitch" step; a first analysis may add "Show Pitch Envelope" before it, as today) | as today | Y (as today) |
| Developer switch `pitch_dev_dump` (no interface) | ExtState `FancyScripts` / `pitch_dev_dump` (a folder path, empty by default) | none | when set: one text file per analysed item in that folder | N for the files, by design: they are developer output, not project state, and nothing in the window depends on them. With the switch empty (the default) nothing is written |

**Which items qualify.** A selected item qualifies when its active take exists and is audio. Items with a MIDI active take and items with no take are skipped and counted, never analysed. The order of the batch is REAPER's own order of the selection (by track, then by position). "N" below is always the number of qualifying items.

**One undo step.** The models of finished items are held in memory and written together when the batch ends: note model, pitch envelope written from the model and the item's own values (no points at the starting values: an item that kept its own values, such as a Tighten, gets their correction, as a single Re-Analyze writes) and, where an item had no visible pitch envelope, creating and showing it. A batch therefore never adds a separate "Show Pitch Envelope" step. The take's pitch mode is left alone, as for a single analysis.

## References

- Native REAPER analogues: actions that work on all selected items and report once ("Item: Normalize items", "Item properties: Toggle take reverse" on a multi-selection); REAPER's own progress windows for long work (Render, Glue) with Cancel. Conventions matched (CN6): the arrange selection is the scope and is never changed; one undo point named after the action with the count; no Alt or Shift given a new meaning; no new right-click menu is needed (the command is in the existing "…" menu).
- Baseline capture: the docked window with an analysed item open and two Pitched Items (session capture, 2026-11-23). The empty canvas was read from code (`draw_graph`), not captured: reaching it would have meant clicking through the user's session. `ds-lint.py` summary: did not run ("theme.lua palette drifted from ds-lint's port of build_palette", 22 palette keys it does not know), so there is no mechanical baseline; a tool fault, separate from this design.

## Context and job stories

Confirmed at the checkpoint (2026-11-23, "Yes, all recommended"): Cancel keeps the finished items as the one undo step; the "…" entry is always present and disabled with a reason; the first item of the batch is shown at the end; a failing or noteless item does not stop the batch and is counted in the closing message. Changed by the user after the first draft (2026-11-23): the confirm names the items that would be replaced and does not count notes or edits. Context confirmed with it: lives in the existing window (docked or floating), used a few times per project, started by mouse with no new shortcut, may run while playback runs.

1. When a vocal is cut into many items, I want to analyse them all in one go, so I can move from item to item and start tuning without waiting on each one.
2. When some of the selected items already have notes, I want to be told how many would be replaced before anything starts, so I don't lose work without knowing.
3. When a batch is running and I picked the wrong items, I want to stop it and know exactly what was kept.
4. When the batch ends, I want one line that says what happened and one Cmd+Z that takes all of it back.
5. When I have one item selected, I want to learn from the window that several can be analysed at once.
6. When I've built the singer test project, I want to select everything, start one batch and save, so the readings can be judged without clicking through items.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | The empty-canvas button ("Analyze Item" / "Analyze All Selected Items") and the lines under it; batch progress in the "…" button and the status pill; the closing message | The canvas of an unanalysed item has nothing else to do, so its one button is the entry point; progress and outcome must be seen without opening anything |
| 2 one disclosure away | "…" → Analyze Selected Items (N); "…" → Cancel Batch; the confirm dialog | A few times per project; the menu is where Analyze, Re-Analyze and Cancel already live |
| 3 Settings | None | The developer switch has no interface at all (ExtState only) |

## Information architecture

Regions touched (the window's regions are unchanged):

1. **Empty canvas** (the open item has no analysis). One button, centred, with up to two lines of text under it. The button's label follows the arrange selection: "Analyze Item" with fewer than two audio items selected, "Analyze All Selected Items" with two or more. It is one control with one identity; only its label and its action change.
2. **"…" menu.** One entry added directly under Analyze / Re-Analyze: "Analyze Selected Items (N)". It is always in the menu; with fewer than two audio items selected, or while an analysis runs, it is disabled with the reason beside it. Analyze / Re-Analyze keeps acting on the open item only. While a batch runs, the first entry is "Cancel Batch NN%" (today: "Cancel NN%" for a single analysis).
3. **"…" button and status pill.** While a batch runs the button reads the batch's overall percentage and the pill reads "Analyzing 3 of 12: name… 42%". One number in both places: the share of the batch's total audio length that has been analysed.
4. **Confirm dialog** (the window's existing confirm modal), shown once, only when at least one item of the batch already has an analysis. It lists those items by name, so the user sees which ones would be replaced; it does not count notes or edits.
5. **Pitched Items panel.** Read-only while an analysis runs. Its rows change when the batch is written (at the end, or on Cancel), not item by item: the list always shows what is stored on the items.
6. **Help modal:** the row that lists the "…" menu's contents names the new entry.

Primary display: the note canvas (unchanged). Primary action: dragging a note (unchanged); on an empty canvas the one button is the only action, as today. Disclosure levels: the canvas button is level 1; the "…" menu and the confirm are level 2 (IA2).

**What the window shows during a batch.** The canvas follows the item being analysed, with its pitch line drawing in as today, and the top bar's item badge names it. REAPER's selection is not followed while the batch runs and is never changed. The top bar values and the engine settings are locked with their existing reason ("Wait for the analysis to finish").

**How a batch ends.** Every way a batch stops does the same thing: the finished items are written as one undo step, the item in progress and the items not started are left exactly as they were, and one closing message says what happened. That holds for the natural end, for Cancel, for closing the window and for the window's error screen. If no item finished, nothing is written and no undo step is added.

**Which item is open afterwards.** The first item of the batch that was written. If none was written, the item that was open before the batch comes back as it was. A selection change made in REAPER during the batch does not pull the window to another item when the batch ends; the next selection change does, as always.

**Items that do not work out.** An item with no pitched notes is analysed and stored like any other (it opens to "No pitched notes found", as today) and is counted in the closing message. An item that could not be analysed (it left the project, its audio could not be read, its envelope could not be shown, or its analysis raised an error) is left exactly as it was, counted, and the batch carries on. The closing message gives counts, not names: a noteless item shows its own message when opened, and an item that could not be analysed still has no analysis.

## Wireframes

Default floating size, empty canvas, 12 audio items selected of which 3 already have notes:

```
┌ ◆ [V Main Verse 1] [E][Major] │ [Defaults][Natural] Tighten – Strength 100% …        [ … ] [▣] [×] ┐
├─────┬──────────────────────────────────────────────────────────────────┬───────────────────────────┤
│     │                                                                  │ ▾ Pitched Items (3)       │
│     │                  [ Analyze All Selected Items ]                  │  ☑ Chorus Error         × │
│     │                     12 audio items selected.                     │  ☑ V Main Verse 2       × │
│     │   3 already have notes. You will be asked before they are        │  ☑ V Main Bridge        × │
│     │                           replaced.                              │ ▾ Shortcuts               │
│     │                                                                  │  …                        │
└─────┴──────────────────────────────────────────────────────────────────┴───────────────────────────┘
```

The same canvas with one item selected, and with nothing usable selected:

```
              [ Analyze Item ]                                    [ Analyze Item ]  (disabled)
   No data. Select an item and click Analyze.          No data. Select an item and click Analyze.
 Select several items in REAPER to analyze them      Select several items in REAPER to analyze them
              all at once.                                         all at once.
```

"…" menu (the reason sits where a shortcut would, as for Analyze and Reset today):

```
open item has notes, 5 audio items selected
┌──────────────────────────────────────────────────────────────┐
│ Re-Analyze                                                   │
│ Analyze Selected Items (5)                                   │
│ Reset 14 notes                                               │
│ ──────────────────────────────────────────────────────────── │
│ Layers                                                     ▸ │
│ Note Tone                                                  ✓ │
│ Settings                                                     │
│ Keyboard Shortcuts & Help                                    │
└──────────────────────────────────────────────────────────────┘

fewer than 2 audio items selected (first three rows; the rest as above)
│ Re-Analyze                                                   │
│ Analyze Selected Items          Select 2 or more audio items │
│ Reset 14 notes                                               │

batch running
│ Cancel Batch 42%                                             │
│ Analyze Selected Items       Wait for the analysis to finish │
│ Reset 14 notes                                               │

single analysis running: "Cancel 42%" as today, and the batch entry disabled with the same reason
```

Confirm dialog (the existing confirm modal, small size, fitted to its parent as today). The list names every item whose notes would be replaced, in the order of the batch, each with its track and start position in dim text; it scrolls inside the dialog when it is longer than the room:

```
┌ Analyze 12 items? ─────────────────────────────── × ┐
│ 3 of them already have notes. Analyzing replaces    │
│ their notes and any edits:                          │
│ ┌─────────────────────────────────────────────────┐ │
│ │ V Main Verse 1         Vox Lead · 23.1          │ │
│ │ V Mic - 02-glued.wav   Vox Dbl · 43.1           │ │
│ │ V Mic - 02-glued.wav   Vox Dbl · 55.3         ▒ │ │
│ └─────────────────────────────────────────────────┘ │
│ Cmd+Z restores all 12 items in one step once the    │
│ batch has finished.                                 │
│                                                     │
│              [ Cancel ]  [ Analyze 12 Items ]       │
└─────────────────────────────────────────────────────┘
```

Batch running (the canvas shows the item in progress; the bar is locked):

```
┌ ◆ [V Main Verse 3] [E][Major] │ (values disabled: Wait for the analysis to finish)   [42%] [▣] [×] ┐
├─────┬──────────────────────────────────────────────────────────────────┬───────────────────────────┤
│ C#4 │        ~~~~~~~~                                                  │ ▾ Pitched Items (3)       │
│ B3  │  ~~~~~~        ~~~~~~~~~~~   (pitch line drawing in)             │  (rows read-only)         │
│ A3  │                                                                  │                           │
│     │ [ Analyzing 3 of 12: V Main Verse 3… 42% ]                       │                           │
└─────┴──────────────────────────────────────────────────────────────────┴───────────────────────────┘
```

After the batch (the first item of the batch is open; the message stays until the next click or key in the window):

```
│     │ [ Analyzed 11 of 12 items (1 has no pitched notes). 1 could not be analyzed. Cmd+Z to undo. ]  │
```

Narrow docker (~260 px): the canvas is about 200 px wide beside the note column. The full label does not fit, so the button reads "Analyze All" (its tooltip carries the full sentence); the lines under it wrap inside the canvas width, centred; the status pill is shortened with an ellipsis as today. The Pitched Items panel is not shown at this width (as today). The confirm modal is fitted to its parent by the existing fitting, so it stays inside the dimmed window (RB9).

```
┌ ◆ [V Main Ver…]      [ … ][×] ┐
│ [E][Major]                    │
│ …                             │
├────┬──────────────────────────┤
│    │      [ Analyze All ]     │
│    │  12 audio items selected.│
│    │   3 already have notes.  │
│    │ You will be asked before │
│    │    they are replaced.    │
│    │ [ Analyzing 3 of 12: V…] │   (pill, while running)
└────┴──────────────────────────┘
```

Wide short strip (1200 × 150): one top bar row; the canvas is too short for the button and both lines. The lines are dropped from the bottom up until the block fits (the second line first, then the first); the button always stays, and its tooltip says what it will do.

```
┌ ◆ [V Main Verse 1] [E][Major] │ [Defaults][Natural] Tighten – Strength 100% Tolerance 8¢ …              [ … ] [▣] [×] ┐
│     │                              [ Analyze All Selected Items ]                              │ ▾ Pitched Items (3)   │
│     │                                 12 audio items selected.                                 │  ☑ Chorus Error     × │
└─────┴────────────────────────────────────────────────────────────────────────────────────────────┴───────────────────────┘
```

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Empty canvas | empty | The button and its lines are the empty state: what is missing ("No data"), the next step, and that several items can be done at once | ST6 |
| Empty canvas | working | The button is on the canvas only until the first analysed moment arrives; then the canvas draws the item in progress and the pill and the "…" button carry the progress | ST3 |
| Empty canvas | error | Nothing usable in the selection when the button is clicked (the selection changed in the same moment): "Select an audio item first" on the pill, nothing starts | ST7 |
| Empty canvas | disabled with reason | No audio item to act on: "Analyze Item" disabled, tooltip "Select an audio item in REAPER to analyze it."; the line under it says the same at rest, so the reason shows with tooltips off. An analysis running: disabled, "Analysis in progress" | EP2 |
| Empty canvas | overflow / long names | Narrow: label "Analyze All", lines wrap. Short: lines dropped bottom-up, button kept. Counts are numbers; no item name appears here | LG4 |
| Empty canvas | missing dependency | n/a: nothing new is required | HI7 |
| Empty canvas | Fancy Dark / Match Theme | The button is the existing large canvas button; the lines use the existing message's text colour, measured on the canvas surface in both modes | CL4 |
| Empty canvas | the open item is not in the selection | The first line adds "This item is not one of them.", so the button never claims to analyse the item on screen | ST4 |
| "…" menu | disabled with reason | "Analyze Selected Items" with "Select 2 or more audio items" beside it; while an analysis runs, "Wait for the analysis to finish" beside it. The reason is text in the menu, not a tooltip | EP2 |
| "…" menu | working | First entry "Cancel Batch 42%"; hovering it explains that finished items are kept | ST3 |
| "…" menu | overflow / long names | n/a: fixed strings and a count | LG4 |
| "…" button | working | The overall percentage in place of "…"; tooltip "Analyzing 3 of 12. Open to cancel" | ST3 |
| Status pill | working | "Analyzing 3 of 12: name… 42%"; a long item name is shortened with the pill's ellipsis, the counts stay readable because they come first | ST3, LG4 |
| Status pill | closing message | One of the closing messages of the Copy deck. It stays until the next click or key press in the window instead of the usual few seconds: a batch can end while the user is away | ST2 |
| Status pill | error | Items that could not be analysed are counted in the closing message in user terms; no raw error text, nothing console-only. A batch in which no item could be analysed says so and adds no undo step | ST7 |
| Confirm dialog | empty | n/a: it is only shown when at least one analysis would be replaced | ST6 |
| Confirm dialog | overflow / long names | The list of items scrolls inside the dialog; a long item name is shortened with an ellipsis and its full name is in the row's tooltip; the track and position give way first when the row is narrow. Items that share a name are told apart by track and position. The body text wraps; the modal is fitted to its parent | LG4 |
| Confirm dialog | Fancy Dark / Match Theme | The existing confirm modal and scrim | CL4 |
| Pitched Items panel | disabled with reason | While an analysis runs: rows, their checkboxes and their Remove buttons are disabled; hovering a row says "Wait for the analysis to finish"; the pill names the running analysis at rest, so the reason shows with tooltips off | EP2 |
| Pitched Items panel | after the batch | Every written item has a row; replaced items keep their row | ST1 |
| Whole window | error | The window's existing error screen (Retry / Close): the batch stops, finished items are written first as one undo step, and after Retry the pill carries the cancelled-batch message | ST7 |
| Whole window | closed during a batch | Closing is Cancel: finished items are kept as one undo step. The Close tooltip already says corrections stay on the items | ST5 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Canvas button, fewer than 2 audio items selected: "Analyze Item" | Click: analyse the open item, exactly as today. HC2 / HC3: n/a, a command, not a value. No wheel, no context menu | n/a | n/a | n/a | "Analyze Pitch" (unchanged) | As today (the canvas only shows this button when the open item has no analysis, so nothing is replaced) |
| Canvas button, 2 or more audio items selected: "Analyze All Selected Items" | Click: read the arrange selection again at that moment, freeze the list of items (by take GUID), then start the batch, or open the confirm first when any item of the list already has an analysis. HC2 / HC3: n/a | n/a | counts as whole numbers | n/a | "Analyze Pitch (12 items)", with the number of items actually written; "(1 item)" for one | Confirm once when at least one analysis would be replaced; no confirm otherwise (nothing is discarded and one Cmd+Z restores everything). The closing message always names the undo |
| "…" → Analyze Selected Items (N) | Click: the same action as the canvas button with 2 or more selected. Enabled with 2 or more audio items selected and no analysis running | n/a | "(N)" = qualifying items | n/a | as above | as above |
| "…" → Analyze / Re-Analyze | Unchanged: the open item only, with its own confirm when edits would be lost | n/a | n/a | n/a | "Analyze Pitch" | As today |
| Confirm dialog | Cancel (first, default focus) · "Analyze N Items" (danger look, as the existing Re-Analyze confirm) · Esc and the title bar's close = Cancel. Cancel leaves everything as it was and starts nothing. The list of items is read-only and scrolls with the wheel or its scrollbar | Cancel | counts as whole numbers; an item's position as REAPER's ruler shows it (bars and beats, or time) | n/a | none for the dialog itself | It is the HC4 confirm: names the consequence (notes and any edits replaced), the counts (items in the batch, items replaced) and each item that would be replaced. It does not count notes or edits |
| "…" → Cancel Batch NN% (while a batch runs) | Click: stop the item in progress and put its previous state back, write the finished items as one undo step, open the first written item, post the closing message. Not bound to Esc (on a floating window Esc closes the window, which cancels the same way) | n/a | whole percent of the batch's total audio length | n/a | "Analyze Pitch (N items)" when at least one item finished; none otherwise | No confirm: cancelling discards only the unfinished item's partial work, and what was written is one Cmd+Z away |
| "…" button while a batch runs | Click opens the menu as always; label = overall percent; tooltip names "3 of 12" | n/a | whole percent | 0 to 100 | n/a | n/a |
| Pitched Items rows while an analysis runs | Disabled: no switch, no bypass toggle, no Remove; hover tooltip gives the reason | n/a | n/a | n/a | n/a | n/a |

Keyboard map: no new keys. Esc (HC5): the confirm dialog owns Esc while it is open (Cancel); an open "…" menu closes on Esc; otherwise Esc behaves as today (selection, then the window when floating; closing during a batch cancels it as described). Space is forwarded as today (HC6), also while a batch runs, so playback can be started and stopped; not while the confirm is open. No key repeats are added (EP6). The Help modal's row for the "…" menu names the new entry (HP1).

The qualifying count shown on the button and in the menu is refreshed when the number of selected items or the project state changes, and a few times per second otherwise; the selection is never walked every frame. The list a batch works on is always read fresh at the click.

## Copy deck

| Where | String |
|---|---|
| labels | Canvas button: `Analyze Item` · `Analyze All Selected Items` · narrow form `Analyze All` · "…" entry: `Analyze Selected Items (5)` (enabled) · `Analyze Selected Items` (disabled) · `Cancel Batch 42%` |
| lines under the canvas button | Fewer than 2 audio items selected: `No data. Select an item and click Analyze.` (existing) and `Select several items in REAPER to analyze them all at once.` · 2 or more: `12 audio items selected.` · with other items in the selection: `12 audio items selected (2 other items are skipped).` · when the open item is not selected, added to that line: `This item is not one of them.` · second line when some are analysed already: `3 already have notes. You will be asked before they are replaced.` / `1 already has notes. You will be asked before it is replaced.` |
| tooltips | Canvas button, batch: `Detect the pitch of the 12 selected audio items, one after another. One undo step for all of them.` · single: `Detect the pitch of the selected audio item` (existing) · disabled: `Select an audio item in REAPER to analyze it.` / `Analysis in progress` (existing) · "…" button during a batch: `Analyzing 3 of 12. Open to cancel` · Cancel Batch entry: `Stops the batch. Items already finished are kept.` · "…" button at rest: `Menu: Analyze, Analyze Selected Items, Reset, Layers, Note Tone, Settings, Help` · Pitched Items row during an analysis: `Wait for the analysis to finish` |
| empty / error / confirm | Menu reasons: `Select 2 or more audio items` · `Wait for the analysis to finish` (existing wording) · Confirm title: `Analyze 12 items?` · body, first paragraph: `3 of them already have notes. Analyzing replaces their notes and any edits:` / one: `1 of them already has notes. Analyzing replaces its notes and any edits:` / all of them: `All 12 already have notes. Analyzing replaces their notes and any edits:` · list rows: the item's name, then `Vox Lead · 23.1` (its track and start position) in dim text · second paragraph: `Cmd+Z restores all 12 items in one step once the batch has finished.` (`Ctrl+Z` on Windows and Linux) · buttons: `Cancel` · `Analyze 12 Items` |
| status messages | Running: `Analyzing 3 of 12: V Main Verse 3… 42%` · Done: `Analyzed 12 items. Cmd+Z to undo.` · Done, with issues: `Analyzed 11 of 12 items (1 has no pitched notes). 1 could not be analyzed. Cmd+Z to undo.` (each part only when its count is above 0) · Cancelled: `Batch cancelled. 2 of 12 items were analyzed and kept. Cmd+Z to undo.` · Cancelled before any item finished: `Batch cancelled. Nothing was changed.` · Nothing worked: `None of the 12 items could be analyzed. Nothing was changed.` · Selection gone at the click: `Select an audio item first` (existing) |
| undo labels | `Analyze Pitch (12 items)` · `Analyze Pitch (1 item)` · unchanged for a single analysis: `Analyze Pitch`, `Show Pitch Envelope` |
| Help modal rows | Icons → `… (top right)`: `More: Analyze, Analyze Selected Items, Reset, Layers, Note Tone, Settings, Help` |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Canvas button (both labels, narrow form) | `Theme.push_button_preset` / `Theme.pop_button_preset` through the script's existing canvas button | `Theme.layout.btn_lg` |
| Button width and the narrow-form decision | none: text measured in the button's font | `Theme.layout.btn_lg` (pad_x), `Theme.layout.sm` (canvas margin) |
| Lines under the button | none: canvas draw list, as the existing message | palette `text_dim`; gaps `Theme.layout.lg` (button to first line) and `Theme.layout.xs` (between lines) |
| Button and menu tooltips | `Theme.tooltip` | theme defaults |
| "…" menu entries and their reasons | stock menu items inside the existing popup, as Analyze and Reset | theme push defaults; the reason in the menu's shortcut column |
| "…" button with the percentage | stock button, existing fixed width (measured for the widest label) | the bar's existing metrics |
| Status pill (progress, closing message) | the script's existing canvas status pill | canvas palette `pill_bg`, `pill_text`; `Theme.layout.sm`, `Theme.layout.xs` |
| Confirm dialog | the script's existing confirm modal: `Theme.center_next_window`, `Theme.modal_scrim`, `Theme.hcenter` | `Theme.layout.modal_sm`, `Theme.layout.md`, `Theme.layout.lg`; the existing danger colours on the confirm button |
| Confirm dialog, list of items | none: a scrolling child region inside the modal, rows as plain text | palette `text` (name), `text_dim` (track and position), `well` (the region's surface); `Theme.layout.sm`, `Theme.layout.xs` |
| Pitched Items rows, read-only | the panel's existing disabled drawing (as for a missing item) | palette `text_dim` |

## Library proposals

None. Every element reuses an existing helper, palette key or layout token.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | During a batch the item badge names the item in progress and the pill says which of how many; afterwards the open item and the Pitched Items rows show what is stored |
| ST2 | A click on the button or the entry answers in the same frame (progress, the confirm, or a message); the batch's outcome is one message on the status pill that stays until the next click or key; no path ends silently |
| ST3 | Progress from the first frame (percent on the "…" button, "3 of 12" and percent on the pill); Cancel always available in the "…" menu; the analysis keeps its per-frame time budget in the existing named constant. The closing write happens in one frame (an undo block cannot stay open between frames) and does nothing but write what was prepared while items finished |
| ST4 | The percentage is the same number on the button and the pill; "N" counts only items that will really be analysed; the button's line says when the item on screen is not part of the batch; the Pitched Items list changes only when items are written |
| ST5 | Closing the window during a batch keeps the finished items; the Close tooltip's statement (corrections stay on the items) stays true |
| ST6 | The empty canvas names what is missing and the next step in every selection state; nothing is blank |
| ST7 | Items that could not be analysed are counted in the closing message in user terms; no Lua error text reaches the user for a single failing item; the window's error screen still stops a batch cleanly |
| UC1 | One undo point per batch, named "Analyze Pitch (N items)" with the number written; none when nothing was written (cancelled early, everything failed, confirm cancelled); no undo block is open between frames |
| UC2, HC5 | Esc: the confirm (Cancel) → the "…" menu → selection → the window when floating; through `Shortcut()`; Esc is not bound to Cancel Batch |
| UC3 | Each item's model is written to the take inside the batch's undo block; undo and redo reload every item through the existing project-state reload; nothing goes to ExtState or JSON |
| UC4 | REAPER's item selection is read, never changed; the edit cursor, time selection and track selection are untouched |
| UC5, HC3 | n/a: no value control is added |
| EP1, HC4 | Replacing existing analyses is confirmed once, naming how many items are in the batch, how many are replaced and each item that would be replaced; Cancel first, Esc = Cancel. With nothing to replace there is no confirm, and one Cmd+Z restores every item. Cancelled and completed batches post a message naming the undo |
| EP2 | The disabled "Analyze Selected Items" shows its reason as text in the menu; the disabled canvas button's reason is also the line under it; the read-only Pitched Items rows give the reason on hover while the pill names the running analysis |
| EP3 | n/a: no value input |
| EP4 | The batch holds take GUIDs, frozen at the click; an item that has left the project is skipped and counted, never mistaken for another |
| EP5 | The menu entry is always present (disabled with a reason, never hidden); the canvas button keeps its place and identity while its label follows the selection; the lines under it change text, not layout |
| EP6 | No new shortcut; no key repeat |
| CN1 | The button is the existing canvas button, the dialog the existing confirm modal, tooltips go through `Theme.tooltip`; nothing hand-built |
| CN2, CN3 | Tokens and existing palette keys only; the modal uses the small modal size and the scrim |
| CN4 | "Analyze" for one item, "Analyze All Selected Items" on the button, "Analyze Selected Items (N)" in the menu, "batch" for the run; "items", never "takes" or "clips", in every string |
| CN5, HP1 | The Help row and the "…" tooltip list the new entry; the CHANGELOG entry matches the code |
| CN6 | The arrange selection is the scope, as for REAPER's own item actions; no Alt or Shift meaning is added; the undo point is named after the action |
| HC2 | n/a: no value control |
| RC1 | The button and the menu entry are text; nothing new is icon-only; the batch is explained on the canvas at rest, not only in a tooltip |
| RC2 | Counts and percent only; no GUIDs, frame counts, sample rates or internal names in any string |
| EF1 | The batch is the bulk action; n/a for value accelerators |
| EF2, HC6 | Space is forwarded as today, also during a batch; not while the confirm is open |
| EF3 | n/a: zoom, scroll and ruler unchanged; the view resets to the whole item for each item in progress, as a single analysis does |
| IA1 | Button, lines and progress are Tier 1; the menu entry, Cancel and the confirm Tier 2; nothing in Settings |
| IA2 | Two levels: the canvas, then the "…" menu or the confirm |
| IA3 | Primary display and action unchanged; the lines use the default text size and the button its existing preset: no new size or weight |
| IA4 | The developer switch has no control anywhere in the window; no dead entry is added |
| LG1 | The button-to-text gap is the large step and the gap between the two lines the smallest, so the lines read as one group under the button |
| LG2 | n/a: no framed row is added; the canvas block is centred as today |
| LG3 | The button's width comes from its label in the button's font plus the preset's padding |
| LG4 | ~260 px docker: "Analyze All", wrapped lines, shortened pill, modal fitted to the parent. 1200 × 150 strip: lines dropped bottom-up, button kept. As wireframed |
| MT1 | The canvas button is the existing large button; menu entries are full menu rows |
| MT2 | The canvas button keeps its hover, pressed and disabled looks, hand cursor and tooltip |
| CL1, HC1 | The confirm's item names and their dim track and position text reach 4.5:1 on the list's surface in both theme modes. The lines under the button reach 4.5:1 on the canvas surface in both theme modes (measured; if the dim text colour falls short there, the plain text colour is used); the pill text is already fitted to 4.5:1 |
| CL2 | Progress and outcome are text; nothing is told by colour alone |
| CL3 | Red appears only on the confirm's destructive button |
| CL4 | Checked in Fancy Dark and Match Theme |
| HI1 | The confirm is drawn inside the window's visible block by the existing modal code |
| HI2 | n/a: window flags and conditions unchanged; the modal opens with the existing appearing condition |
| HI3 | n/a: toolbar and close semantics unchanged; closing during a batch is covered under ST5 |
| HI4 | Nothing is written per frame; the batch writes once, at its end |
| HI5 | The selection is not walked every frame: the count is refreshed on change and a few times per second; the full check (which items have a stored analysis, their names, tracks and positions) runs once, at the click |
| HI6 | The button keeps one ID while its label changes; the menu entry keeps one ID with and without "(N)"; the Cancel entry keeps the existing one |
| HI7 | n/a |
| RB9 | The confirm uses the scrim and the open-once recipe of the existing modal and is fitted to its parent, so it never leaves the dimmed window in a narrow docker |
| RB13, RB14 | The confirm's list of items is drawn through a list clipper inside its scrolling region, so a selection of hundreds costs no more than the rows on screen; the Pitched Items list is unchanged. No accessor, state chunk or enumeration per frame outside the analysis's own time slice |
| RB15, RB19 | Tooltips go through the for-tooltip hover check, with the allow-when-disabled flag on disabled items; every ReaImGui and REAPER function is checked against the documentation before use |

## Open questions / assumptions

Answered at the checkpoint (2026-11-23): the four open questions of the brief, as recorded under "Context and job stories".

Calls made in this doc, for you to check:

- **Lines under the button.** With fewer than two items selected the existing "No data" line stays and the note about several items is a second line. With two or more, the lines say how many are selected, how many are skipped, and how many already have notes.
- **"Analyze All" in a narrow docker.** The decided label does not fit beside the note column at about 260 px, so it is shortened there only; the tooltip carries the full sentence.
- **Rows of the confirm's list** show the item's name plus its track and start position, because items often share a name (three items called "V Mic - 02-glued.wav" in the session captured for this doc). The position follows REAPER's ruler unit, as the script's own ruler does.
- **Analyze / Re-Analyze in the menu stays single-item** even with several items selected, so one item can still be analysed on its own. On an empty canvas with several selected, the button is the batch and the menu's "Analyze" is the single item.
- **One percentage.** The "…" button and the pill show the same number: the share of the batch's total audio length analysed so far, not the progress of the item in progress.
- **The closing message stays until the next click or key in the window** instead of four seconds, because a batch can end while you are away. Other status messages keep their timing.
- **Counts, not names, for items that did not work out.** A noteless item says so when opened; an item that could not be analysed simply still has no analysis.
- **The Pitched Items panel is read-only during any analysis,** single ones included. Today a row click during an analysis switches the item under it, which this closes.
- **Rows appear when the batch is written,** not as each item finishes: the list shows what is stored.
- **Closing the window or hitting the error screen during a batch acts as Cancel:** finished items are kept as one undo step. Say so if you would rather have nothing written in those two cases.
- **A selection change during the batch** does not change the batch (its list is frozen at the click) and does not pull the window away when it ends.
- **A batch folds "Show Pitch Envelope" into its one undo step.** A single analysis keeps its separate step, as today.
- **The Re-Analyze fix has no interface.** How the uncorrected audio is read is decided in the plan, after the cause is confirmed in real REAPER. If the only way is to switch an item's correction off while that item is read, it would be heard uncorrected for those seconds when playback runs, and is put back exactly on Cancel or error; I will say so before building it.
- **The developer switch** is ExtState only, as the brief says; it is not mentioned anywhere in the window or the Help modal.
- **Not checked for this doc:** the empty canvas was read from code, and the lint tool does not run against the current theme (see References).

Changed during the build (2026-11-23, found while testing in real REAPER; reported to the user with the build):

- **The closing message also ends when an undo or redo changes an analysed item, or another item is opened,** not only on the next click or key in the window. After Cmd+Z in REAPER, "Analyzed 3 items" stayed on screen over items that were no longer analysed. Other changes in REAPER (moving the edit cursor, mixing) leave it.
- **Redo lists every item of the batch again.** The Pitched Items list only re-read the open item after a redo; items an undo removed are now looked at again whenever the project changes.
- **The Re-Analyze fix switches nothing off audibly.** The audio accessor keeps the take state it was made with, so the Pitch envelope is bypassed, the accessor made and the envelope put back inside one call (measured: 0.3 ms, the envelope identical afterwards, no undo point).
- **Found by the review of the branch and fixed:** an item's own Key and Scale survive a batch (every item was given those of the item open at the start); the confirm also covers items that hold notes this window has not loaded yet (pasted or duplicated after the script started); Clear and Wipe in Settings are disabled while an analysis runs, with the reason beside them; an item that gives no audio at all in a batch counts as "could not be analyzed" and keeps what it had; an item whose pitch envelope cannot be made is left as it was, as this doc says.
- **An item's sample rate is read when the batch starts,** because REAPER reports none for every source while it is in the background ("Set media items offline when application is not active"). An item with no sample rate even then counts as "could not be analyzed"; a single analysis of such an item says its audio could not be read instead of storing an analysis without notes.

HC6 conflicts: None.
