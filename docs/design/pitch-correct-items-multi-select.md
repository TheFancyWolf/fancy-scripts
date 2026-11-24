# Design: Fancy Pitch Correct — Pitched Items multi-select and removal

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); Pitched Items panel → list region of that window; remove confirms → the window's existing confirm modal (same archetype)
Status: Approved
Date: 2026-11-24
Approver: TheFancyWolf (in chat, 2026-11-24)

## Summary

The Pitched Items list gets a row selection, so several items can be removed at once. A plain click still makes a row the active item and selects only that row. Cmd/Ctrl-click adds or removes a row and Shift-click selects a range. When two or more rows are selected, a "Remove Selected" button appears at the right end of the "On" heading line. A right-click on any row opens a menu with Remove This Item, Remove Selected Items (N) and Wipe All Items (N). The primary display (the canvas) and the primary action (editing the active item) don't change; the list is a secondary region.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Plain click on a row (existing: switch the active item; new: select only that row) | the take by GUID | none | none (the selection lives in memory) | n/a: no project change |
| Cmd/Ctrl-click a row: toggle it in the selection, active item unchanged | none | none | none | n/a |
| Shift-click a row: select the range from the anchor row, active item unchanged | none | none | none | n/a |
| Remove Selected (On line) / Remove Selected Items (N)… (menu) | each selected take, its pitch envelope, I_PITCHMODE | pitch envelope points and automation items deleted, `<PITCHENV>` removed, I_PITCHMODE back to -1 where the script set it, P_EXT model cleared (`remove_take_core` for each, inside ONE undo block) | none | N: REAPER gets the envelopes and models back, but the list only re-adopts an item once it is selected in REAPER again, so the confirm stays (HC4) |
| Remove This Item… (menu) | as the row × today | as the row × today (`request_remove_confirm`) | none | N, as today: confirm |
| Wipe All Items (N)… (menu) | as Settings > Wipe today | as Settings > Wipe today (`request_wipe_confirm`) | none | N, as today: confirm |
| Row × (existing) | unchanged: removes only its own row, even when that row is in a larger selection | unchanged | none | N, as today: confirm |
| Esc with a selection other than just the active row | none | none | none | n/a |

## References

- Native REAPER analogues: the Media Explorer and Region/Marker Manager lists. Click selects one, Cmd/Ctrl-click toggles, Shift-click extends, right-click opens a row menu. No Alt meaning is added and Shift keeps its usual meaning of extending the selection (CN6).
- Redesigns only: n/a. This adds selection to a drawn list but doesn't restructure it; the row layout, checkbox, name, tag and × stay as they are.

## Context and job stories

Lives in the existing side panel of the editor window, docked or floating. Used a few times per project, mostly with the mouse, possibly while playback runs.

1. When a project has many analysed items I no longer need, I want to select several rows and remove them in one go, so I can tidy the list without one × and one confirm per item.
2. When I'm starting over, I want to wipe every item from the list itself, so I don't have to dig through Settings.
3. When I've selected rows, I want a plain click to keep doing what it does today (open that item), so the list still works as a switcher.
4. When playback is running, I want Space to keep playing and stopping while the list has focus, so selecting rows never breaks transport.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Row selection tint; "Remove Selected" on the On line when 2+ rows are selected | Removing several items is the job; the button shows only when it applies |
| 2 one disclosure away | Right-click row menu: Remove This Item…, Remove Selected Items (N)…, Wipe All Items (N)…; the confirms | Rarer, destructive, and they confirm anyway |
| 3 Settings | Wipe N Items… (existing, unchanged) | Already there |

## Information architecture

The Pitched Items section's "On" heading line (always one frame tall) gets a "Remove Selected" button at its right end, drawn only while 2 or more rows are selected (changed in chat 2026-11-24 from a separate "N selected · Remove N… · ×" bar: the user asked for a single button on the On line). Disclosure has two levels: the row menu, then a confirm. The row menu's words follow the Help terms ("Remove drops an item · Wipe removes all").

Row looks: a selected row has the selection tint (P.select). The active row keeps its accent bar and bold name, whether or not it's selected. At rest the selection is just the active row, so the list looks the same as today.

## Wireframes

Default floating panel (~300 px), three rows selected, the active row is "Lead Vox":
```
 ▾ Pitched Items (5)
   On                [ Remove Selected ]
  ┌───────────────────────────────────┐
  │▌[x] Lead Vox                    × │   ← active + selected (tint, bar, bold)
  ├───────────────────────────────────┤
  │ [x] Harmony 1                   × │   ← selected (tint)
  │ [x] Harmony 2                   × │   ← selected (tint)
  │ [x] Double                      × │
  │ [ ] Adlib   outdated            × │
  └───────────────────────────────────┘
```
Right-click on "Harmony 2":
```
  │ Remove This Item…            │
  │ Remove Selected Items (3)…   │
  │──────────────────────────────│
  │ Wipe All Items (5)…          │
```
Narrow docker (~260 px, the panel at its minimum width): the button keeps its full label at the right end of the On line; it never overlaps the On label (its left edge is clamped after the checkbox column). Row names truncate with an ellipsis as today.
Wide short strip (1200 × 150): the panel's section heights shrink as today. The On line scrolls with the list body, so the button never covers a row.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Remove Selected | empty | Not drawn when fewer than 2 rows are selected; the list empty text is unchanged | ST6 |
| Removal | working | Removal is instant (one frame); the status pill posts "Removed 3 items. Their envelopes and saved analysis were cleared." | ST3 |
| Removal | error | An item that has left the project is still taken off the list; the message counts it as removed from the list ("Removed 3 items from Pitched Items.") | ST7 |
| Rows, button, menu | disabled with reason | During an analysis rows stay read-only as today: no selection change, Remove Selected is disabled, the menu doesn't open, and the tooltip gives K.REASON_ANALYZING. In the menu, Remove Selected Items is disabled with "no rows selected" when the selection is empty | EP2 |
| Rows, confirm | overflow / long names | Names truncate with an ellipsis (fit_text). The confirm lists up to 5 names, then "and N more" | LG4 |
| — | missing dependency | n/a: no new dependency | HI7 |
| All | Fancy Dark / Match Theme | Tint, button and menu use palette keys only; checked in both modes | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Row name (Selectable) | Click: make it active and select only it (anchor = it). Cmd/Ctrl-click: toggle in the selection (anchor = it), active item unchanged. Shift-click: select anchor..row in list order, replacing the selection, active item unchanged. Right-click: row menu, selection unchanged. HC2/HC3 n/a: not a value | selection = the active row | n/a | n/a | none (no project change) | n/a |
| Remove Selected (On line) | Click: Remove Selected confirm | — | count in the label | n/a | "Remove 3 Items from Pitched Items" | Confirm naming the count, up to 5 names and the pitch-algorithm resets; Cancel first, Esc = Cancel |
| Menu: Remove This Item… | the existing `request_remove_confirm(guid)` | — | — | — | "Remove <name> from Pitched Items" (existing) | existing confirm |
| Menu: Remove Selected Items (N)… | as Remove Selected | — | — | — | as above | as above |
| Menu: Wipe All Items (N)… | the existing `request_wipe_confirm()` | — | — | — | "Wipe Pitched Items (N)" (existing) | existing confirm |
| Row × | unchanged: removes only its own row | — | — | — | existing | existing confirm |

The selection is a set of take GUIDs in memory. Removing items, clearing an analysis, a project resync or the list losing an entry prunes it. A selection change made from REAPER (a new active item) resets it to just the active row.

Keyboard map: no new keys (no Delete for rows: Delete/Backspace/R stay note reset on the canvas). HC5 Esc order: modal → active edit → note selection → row selection (back to just the active row, when it holds anything else) → window when floating. HC6: Space is forwarded as today. EP6: no toggles on keys. HP1: Help rows are updated for click, Cmd/Ctrl-click, Shift-click and right-click on a row, and for Esc.

## Copy deck

| Where | String |
|---|---|
| labels | "Remove Selected" · menu "Remove This Item…", "Remove Selected Items (3)…", "Wipe All Items (5)…" |
| tooltips | Remove Selected: "Remove the 3 selected items from Pitched Items and clear their envelopes and saved analysis (asks to confirm)" · row name tooltip last line: "Click to make this the active item · Cmd-click to add or remove · Shift-click for a range" (Ctrl on Windows, via K.MOD_LABEL) |
| empty / error / confirm | Confirm title "Remove 3 items?"; body "This removes 3 items from Pitched Items (Lead Vox, Harmony 1, Harmony 2), deletes their pitch envelope points and clears their saved analysis." + "The pitch algorithm of 2 items returns to the project default." when it applies; confirm button "Remove 3 Items"; menu reason "no rows selected" |
| status messages | "Removed 3 items. Their envelopes and saved analysis were cleared." · "Removed 3 items from Pitched Items." (none of them in the project any more) |
| undo labels | "Remove 3 Items from Pitched Items" |

Help rows: "Click a Pitched Items row" → "Switch the active item, select only that row"; new "K.MOD_LABEL + Click a row" → "Add / remove the row from the selection"; new "Shift + Click a row" → "Select a range of rows"; new "Right-click a row" → "Remove this, the selected or all items"; the Escape row → "Close dialog, deselect notes then rows, close if floating".

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Selected row tint | draw list rect as the active card today | P.select, L.rounding |
| Active row bar, bold name | unchanged | P.accent, fonts.default_bold |
| On label (centred on the frame-tall line) | `Theme.vcenter` | P.text_dim |
| Remove Selected | `reaper.ImGui_Button` with K.push_danger / K.pop_danger, as Settings Wipe | L.md |
| Tooltips | `Theme.tooltip` | — |
| Row menu | `reaper.ImGui_BeginPopupContextItem` + `MenuItem` with a disabled reason | — |
| Confirms | the existing `request_confirm` (scrim and fit already in it) | — |

## Library proposals

None.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | The tint shows the selection and Remove Selected appears with it; both change in the frame of the click |
| ST2 | Every removal ends in a status message; a cancelled confirm changes nothing |
| ST3 | n/a: removal is one frame |
| ST4 | The button's tooltip count, the menu's count and the confirm's count are the same number; the selection never holds a GUID that's not in the list |
| ST6 | Nothing new is blank; the list's empty text is unchanged |
| ST7 | Items gone from the project are still removed from the list and counted in user terms |
| UC1 | One undo point "Remove N Items from Pitched Items" for a multi-removal; none when cancelled |
| UC2, HC5 | Esc: modal → active edit → notes → rows (back to the active row) → window when floating, through `Shortcut()` |
| UC3 | Writes go to the takes inside one undo block; the selection isn't persisted |
| UC4 | REAPER's item selection isn't read or changed by row selection |
| UC5, HC3 | n/a: no value control |
| EP1, HC4 | Multi-removal is confirmed with its count, up to 5 names and the pitch-algorithm resets; Cancel first, Esc = Cancel |
| EP2 | Disabled Remove Selected, menu entry and rows give their reason |
| EP3 | n/a: no value input |
| EP4 | The selection is take GUIDs, frozen when the confirm opens; an item gone by then is removed from the list only |
| EP5 | The menu always has all three entries (disabled with a reason, never hidden); Remove Selected appears on a line that is always reserved, so no row moves |
| EP6 | No new keys |
| CN1 | Selectable, context menu, button and icon button are stock or Theme widgets |
| CN2, CN3 | Palette keys and layout tokens only |
| CN4 | "Remove" for items, "Wipe" for all, "items" never "takes" |
| CN5, HP1 | The Help rows and the CHANGELOG match the code |
| CN6 | Click / Cmd-click / Shift-click / right-click behave as in REAPER's own lists |
| HC2 | n/a: no value control |
| RC1 | The action is a text button with a tooltip |
| RC2 | Counts and names only, no GUIDs |
| EF1 | Multi-removal is the bulk action |
| EF2, HC6 | Space is forwarded as today |
| EF3 | n/a: canvas unchanged |
| IA1 | Remove Selected Tier 1 (only when it applies), menu Tier 2, Settings Wipe Tier 3 unchanged |
| IA2 | Two levels: menu, then the confirm |
| IA3 | The canvas is still the primary display |
| IA4 | No dead entries |
| LG1 | The button shares the On heading line, so it reads with the list |
| LG2 | The On label is centred on the frame-tall line |
| LG3 | Button width from its label plus L.md padding |
| LG4 | At ~260 px the button keeps its label and never overlaps the On label; names truncate as today |
| MT1 | The button is a full frame |
| MT2 | Stock hover, pressed and disabled looks |
| CL1, HC1 | The On label's dim text reaches 4.5:1 on the panel surface in both modes (plain text otherwise); the tint row keeps P.text names as today |
| CL2 | Selection isn't told by colour alone: the button's tooltip and the menu name the count and the confirm names the items |
| CL3 | Red only on Remove Selected and the confirm's button |
| CL4 | Checked in Fancy Dark and Match Theme |
| HI1 | The confirms use the existing modal code |
| HI2 | n/a: window flags unchanged |
| HI3 | n/a: toolbar and close unchanged |
| HI4 | Nothing is written per frame |
| HI5 | The selection isn't checked against the project each frame; it's pruned when the list changes |
| HI6 | Remove Selected keeps one ID; menu entries keep IDs with "(N)" |
| HI7 | n/a |
| RB9 | The confirm is the existing one, fitted to its parent |
| RB13, RB14 | The clipper still draws only the rows in view; selection lookups are table hits |
| RB15, RB19 | Tooltips use the for-tooltip hover flag (allow-when-disabled on disabled items); every function is checked against the docs |

## Open questions / assumptions

- Agreed in chat (2026-11-24): plain click = open + select only that row (1a); bar and row menu both (2c); no Delete key (3a); the row × removes only its own row (4a).
- Changed in chat (2026-11-24, after testing): the "N selected · Remove N… · ×" bar became one "Remove Selected" button on the On line; Esc still puts the selection back to the active row.
- Changed in chat (2026-11-24): the button reads "Remove Selected" without an ellipsis (the user's call; its tooltip still says it asks to confirm).
- Assumption: Wipe in Settings stays as it is; the menu entry reuses it.
- Assumption: right-click doesn't change the selection, and Remove This Item always acts on the clicked row.
- HC6 conflicts: None.
