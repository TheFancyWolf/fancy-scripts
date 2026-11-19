# Design: Fancy Pitch Correct — Shortcuts section in the right panel

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); the right panel is one region of it
Status: Approved
Date: 2026-11-19
Approver: TheFancyWolf (in chat, 2026-11-19)

## Summary

The right panel gets a second section, **Shortcuts**, under Pitched Items: a short list of the keys and gestures that nothing on screen reveals (Z, F, arrows, modifier clicks, wheel chords). Both sections get a collapsible header, and `H` shows or hides the list from the keyboard. It is for someone editing notes who wants to see what they can do without opening the Help modal, which covers the canvas. The window's primary display (the note canvas) and primary action (dragging a note) do not change. The full list stays in Keyboard Shortcuts & Help.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Collapse / expand Pitched Items (header click) | none | none | ExtState `FancyScripts` / `pitch_items_open` | N, and none needed: a view preference, nothing is lost (HC4 n/a: not destructive) |
| Collapse / expand Shortcuts (header click or `H`) | none | none | ExtState `FancyScripts` / `pitch_shortcuts_open` | N, same reason |
| `H` while the panel is hidden: show the panel with Shortcuts open | none | none | the existing `pitch_sidebar_open` plus `pitch_shortcuts_open` | N, same reason |
| Read the condensed shortcut list (20 rows, 4 groups) | none | none | none | n/a: display only |
| Existing, unchanged: hide panel button, item rows, bypass checkbox, Remove, unreadable banner, resize grip | as today | as today | as today | as today |

Existing shortcut content is in `K.INFO_SECTIONS` (46 rows, Help modal only). The panel list is a subset with shorter wording, not a move: the modal keeps every row.

## References

- Native REAPER analogues: the Actions list (key on one side, action name on the other) and the collapsible sections of the Media Explorer / Track Manager side panels. Conventions matched (CN6): modifier named per OS (`Cmd` on macOS, `Ctrl` elsewhere, from `K.MOD_LABEL`), Alt and Shift not given new meanings, no new gesture on value controls.
- Baseline capture: taken 2026-11-19 from the user's running session (docked, 7 pitched items, panel about 190 px wide, roughly two thirds of the panel height empty under the list). Observe-only: the Help modal was open and was left open. `ds-lint.py` summary: did not run ("theme.lua palette drifted from ds-lint's port of build_palette"), so there is no mechanical baseline; that is a tool fault, separate from this design.

## Context and job stories

Confirmed in chat (2026-11-19): a condensed list that favours shortcuts with no physical representation, both sections collapsible, `H` toggles the list.

1. When I am editing notes and cannot remember the key for "zoom to what I selected", I want to glance right and read it, so I can stay on the canvas instead of opening Help over it.
2. When I am new to the script, I want the hidden keys and modifier gestures in view while I work, so I learn them without reading a manual.
3. When I know the keys and have many pitched items, I want to press `H` or click the header to fold the list away, so the items get the whole panel.
4. When I only work on one item, I want to fold Pitched Items away, so the shortcuts get the whole panel.
5. When the script is docked in a short or narrow strip, I want the panel to keep behaving as it does today, so the canvas never loses room to the list.

Used all session, during playback, docked or floating, mouse and keyboard together.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | The two section headers (while the panel is shown); the Pitched Items rows when open | Items are switched constantly; the headers are the toggles |
| 2 one disclosure away | The shortcut rows (header click or `H`) | Read often at first, rarely later; must be one step away either way |
| 3 Settings | None | The open / closed state is set where it is used, and remembered |

## Information architecture

Regions of the right panel, top to bottom:

1. **Pitched Items (n)** header: collapse arrow, label with count, the existing hide-panel button at the right.
2. Pitched Items body (unchanged content): unreadable banner, "On" label, item rows, or the empty text.
3. **Shortcuts** header: collapse arrow and label.
4. Shortcuts body: four groups (Select, Edit, View, General), each a small heading over two-column rows.

One disclosure level (a header opens its body). Primary display and primary action of the window are unchanged (IA3).

**Height sharing.** Each open body scrolls on its own; the panel itself never scrolls.

| Pitched Items | Shortcuts | Result |
|---|---|---|
| open | open | Pitched Items is as tall as its content, at most half of the room left under the two headers; Shortcuts takes the rest |
| open | closed | Pitched Items takes all the room (as today) |
| closed | open | Shortcuts takes all the room |
| closed | closed | Two headers, empty panel below |

**What is in the list.** A row is in when nothing on screen says it: no button, menu shortcut label, tooltip or hover hint. Left out, with where the user learns them instead:

| Left out | Shown by |
|---|---|
| S, Q, X, M | The Snap / Quantize / Split / Merge buttons and their tooltips; the note menu |
| Drag a note's left / centre / right zone, Cmd/Ctrl = fine | The hover hint on the note |
| Overview strip, pitch strip, time ruler, divider | Their tooltips |
| Double-click / right-click / Cmd-click a top bar value | The value's tooltip |
| Switching items, the icons legend | The rows and buttons themselves |
| Plain wheel, click on empty canvas | Found by doing |
| Modifier + Space chords | Help modal (rare) |

`R` stays in although the note menu shows it: that menu is itself behind a hidden right-click.

## Wireframes

Default floating size, panel at its default width (about 200 px; text column about 184 px), both sections open:

```
┌──────────────────────────┐
│▾ Pitched Items (3)     ▸ │  header; ▸ = hide panel (as today)
│  On                      │
│ ▌[x] Lead Vox - 80…    × │
│  [x] Double L          × │
│  [ ] Double R          × │
│▾ Shortcuts               │
│ SELECT ───────────────── │
│ Cmd + A      Select all  │
│ ← / →        Prev / next │
│              note        │  description wraps in its column
│ Shift+Click  Select range│
│ Cmd+Click    Add / remove│
│ Drag empty   Box select  │
│ Esc          Deselect    │
│ EDIT ─────────────────── │
│ ↑ / ↓        ±1 semitone │
│ Shift+↑ / ↓  ±10 cents   │
│ R            Reset pitch │
│ Double-click Snap        │
│ Right-click  Note menu   │
│ Shift+Drag   Onset Ramp ·│
│              Transition ·│
│              Scoop       │
│ Drag edge    Trim note   │
│ VIEW ─────────────────── │  the body scrolls from here if short
│ …                        │
└──────────────────────────┘
```

Panel at its minimum width (160 px; text column about 144 px): the key column keeps its width (the widest key), descriptions wrap to two or three lines; nothing is cut off, so no row needs a tooltip.

Shortcuts closed (today's look plus two headers) and Pitched Items closed:

```
┌──────────────────────────┐   ┌──────────────────────────┐
│▾ Pitched Items (7)     ▸ │   │▸ Pitched Items (7)     ▸ │
│  On                      │   │▾ Shortcuts               │
│ ▌[x] Lead Vox - 80…    × │   │ SELECT ───────────────── │
│  [x] …                 × │   │ Cmd + A      Select all  │
│  (rows fill the panel)   │   │ …  (fills the panel)     │
│▸ Shortcuts               │   │                          │
└──────────────────────────┘   └──────────────────────────┘
```

Narrow docker (about 260 px wide): the canvas minimum (200 px) and the panel minimum (160 px) do not both fit, so the panel shows as the existing 20 px tag and the Shortcuts section is hidden with it. `H` posts "Widen the window to show Shortcuts" on the status pill.

```
┌───────────────────────┬─┐
│ canvas                │◂│  tag, as today
└───────────────────────┴─┘
```

Wide short strip (about 1200 × 150): the panel has room for the two headers and about three rows. With both open, Pitched Items gets up to half of what is left and Shortcuts the rest, each scrolling; folding one gives the other all of it. No layout change at this size.

```
┌──────────────────────────────────────────────┬──────────────────────────┐
│ canvas                                       │▾ Pitched Items (7)     ▸ │
│                                              │ ▌[x] Lead Vox - 80…    × │
│                                              │▾ Shortcuts               │
│                                              │ Cmd + A      Select all  │
└──────────────────────────────────────────────┴──────────────────────────┘
```

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Pitched Items body | empty | Unchanged: "No pitched items stored. Select an audio item in REAPER and click Analyze." under the open header; the header reads "Pitched Items (0)" | ST6 |
| Shortcuts body | empty | Cannot be empty: the list is fixed text | ST6 |
| Both | working (analyzing) | Unchanged; the list is not dimmed or altered while analyzing | ST3 |
| Shortcuts via `H` | error (window too narrow for the panel) | Status pill: "Widen the window to show Shortcuts" | ST7 |
| Shortcuts rows | disabled with reason | Rows are reference text, never disabled or dimmed by selection, bypass or item state; the list reads the same at all times | EP2, EP5 |
| Pitched Items rows | overflow / long names | Unchanged (ellipsis and tooltip). Many items: the body scrolls inside its share (the list clipper is kept) | LG4, HI5 |
| Shortcuts rows | overflow | Descriptions wrap in their column; the body scrolls when taller than its share | LG4 |
| Both | missing dependency | None new | HI7 |
| Both | Fancy Dark / Match Theme | Keys in the accent colour, descriptions in the text colour, group headings as in the Help modal; header faces from the palette. Key text is checked at 4.5:1 on the window background in both modes; if the Match Theme accent fails, keys use the text colour | CL4, HC1 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Pitched Items header | Click anywhere on the header except the hide-panel button: collapse / expand. HC2/HC3 n/a: discrete. No context menu | Open | Label "Pitched Items (n)", n = item count | n/a | None (view preference) | n/a: nothing is removed |
| Shortcuts header | Click: collapse / expand. `H`: same. HC2/HC3 n/a: discrete. No context menu | Open | Label "Shortcuts" | n/a | None | n/a |
| Hide-panel button (existing) | Unchanged: click hides the whole panel, both sections with it | as today | as today | n/a | None | n/a |
| Shortcut rows | None: plain text, not hoverable, not clickable | n/a | Key names as in the Help modal; modifier per OS | n/a | n/a | n/a |
| Each body | Wheel scrolls the body under the pointer when it overflows (stock scrolling; no wheel-adjust controls inside, EF1 n/a) | n/a | n/a | n/a | n/a | n/a |

Keyboard map:

- `H` (no modifier, no key repeat, through `Shortcut()`): toggles Shortcuts. Live under the same guard as the other canvas keys (window focused, no popup or modal open, no widget active), but **not** tied to having notes or to bypass: it works on an empty or bypassed canvas too (EP6).
  - Panel shown: collapse or expand Shortcuts.
  - Panel hidden by the user: show the panel and expand Shortcuts (one press).
  - Window too narrow for the panel: nothing changes; the status pill says why.
- Esc (HC5): unchanged order (modal → active edit → selection → window when floating). Collapsing is not an Esc layer.
- Space (HC6): unchanged.
- `H` is added to the Help modal (HP1, CN5), and the Icons group there gains the collapse arrow.
- Open / closed state is saved when it changes, never per frame (HI4). A stored value that is missing or unreadable means open.

Implementation notes for the builder (not user-visible):

- The condensed rows come from the same table as the Help modal (`K.INFO_SECTIONS`): a row that also belongs in the panel carries its panel group and short text, so a key cannot be changed in one place only (CN5).
- The key column is as wide as the widest panel key measured with the drawn font; the description column takes the rest and wraps.
- `H` drives the header through `reaper.ImGui_SetNextItemOpen` before `Theme.collapsing_header`; both headers use that helper, the Pitched Items one with its `action_fn` for the hide-panel button.

## Copy deck

| Where | String |
|---|---|
| labels | `Pitched Items (%d)` · `Shortcuts` · group headings `Select`, `Edit`, `View`, `General` |
| Select rows | `Cmd + A` → `Select all` · `← / →` → `Prev / next note` · `Shift + Click` → `Select range` · `Cmd + Click` → `Add / remove` · `Drag empty` → `Box select` · `Esc` → `Deselect` |
| Edit rows | `↑ / ↓` → `±1 semitone` · `Shift + ↑ / ↓` → `±10 cents` · `R` → `Reset pitch` · `Double-click` → `Snap to semitone` · `Right-click` → `Note menu` · `Shift + Drag` → `Onset Ramp · Transition · Scoop` · `Drag edge` → `Trim note` |
| View rows | `Z` → `Zoom to selection` · `F` → `Fit whole item` · `Cmd + Wheel` → `Zoom time` · `Shift + Wheel` → `Scroll time` · `Alt + Wheel` → `Zoom pitch` |
| General rows | `Space` → `Play / stop` · `H` → `Hide this list` |
| tooltips | Hide-panel button: unchanged (`Hide Pitched Items panel`). Headers: none (the arrow and label say it) |
| empty / error / confirm | Unchanged empty text. No confirm |
| status messages | `Widen the window to show Shortcuts` |
| Help modal additions | `H` → `Show / hide the Shortcuts list` (Selection & Navigation) · `▾ / ▸ (section header)` → `Collapse / expand the section` (Icons) |
| undo labels | None |

`Cmd` reads `Ctrl` on Windows and Linux.

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Section headers | `Theme.collapsing_header` (`default_open`, `action_fn` for the hide-panel button) | palette `btn`, `btn_h`, `btn_a`, `text` (inside the helper) |
| Hide-panel button | `Theme.icon_btn` with `Theme.icons.tri_right` (as today) | `Theme.layout.icon_md` |
| Group heading | `Theme.section_divider` (as in the Help modal) | palette `yellow` |
| Key text | `reaper.ImGui_TextColored` | palette `accent` (fallback `text`, see State inventory) |
| Description | `reaper.ImGui_TextWrapped` | palette `text` |
| Row and group spacing | `reaper.ImGui_Dummy` between groups | `Theme.layout.md` between groups, `Theme.layout.sm` between key and description, `Theme.layout.xs` row air |
| Bodies | `reaper.ImGui_BeginChild` per body | none new |
| Fonts | `Theme.push_font` | `Theme.font_sizes.default` for rows; `Theme.font_sizes.small` only for the existing "On" label |

## Library proposals

None.

## Acceptance criteria

| Rule | Expectation |
|---|---|
| ST1 | Each header shows open / closed by its arrow at rest |
| ST2 | Header click and `H` respond in the same frame; `H` in a too-narrow window posts a status message |
| ST3, ST4, ST5 | n/a: no new work, values or lifecycle |
| ST6 | Pitched Items empty text unchanged under its header |
| ST7 | The narrow-window case is said on the status pill, in user terms |
| UC1, UC3, UC4, UC5 | n/a: no REAPER state, undo point, selection change or value control |
| UC2, HC5 | Esc order unchanged; collapsing is not an Esc layer |
| EP1, HC4 | n/a: nothing destructive |
| EP2 | n/a: no new disabled control |
| EP3, EP4 | n/a |
| EP5 | The list never changes with selection or mode; only the user's disclosure and window width hide it |
| EP6 | `H` goes through `Shortcut()`, exact modifiers, no repeat, dead while a popup, modal or text field is active |
| CN1 | Headers use `Theme.collapsing_header`; group headings `Theme.section_divider` |
| CN2, CN3 | Tokens only; every key exists |
| CN4 | "Shortcuts" everywhere (header, status, Help row); "Pitched Items" unchanged |
| CN5, HP1 | Every panel row matches a handler and its Help row; `H` and the collapse arrow are in the Help modal; panel rows come from the Help table |
| CN6, HC2, HC3 | n/a: no value control; Alt and Shift keep their meanings |
| RC1 | The hide-panel icon keeps its tooltip and Help legend row; the collapse arrow is in the legend |
| RC2 | User terms only (semitone, cents, Onset Ramp) |
| EF1 | n/a: no adjustable control; bodies scroll with the wheel |
| EF2, HC6 | Space forwarding unchanged |
| EF3 | n/a: canvas untouched |
| IA1 | Headers Tier 1, rows Tier 2, nothing in Settings |
| IA2 | One disclosure level; "Shortcuts" and "Pitched Items" predict their content |
| IA3 | Primary display and action unchanged; panel uses at most the default and small sizes, one weight plus the header's |
| IA4 | No dead UI: both headers do something in every state |
| LG1 | Group gap (`md`) at least twice the row gap |
| LG2 | Header label and hide-panel button share a baseline; key and first description line share a baseline |
| LG3 | Key column width from the measured widest key |
| LG4 | Works at the 160 px panel minimum (wraps), at about 260 px (tag, `H` explains) and in a 1200 × 150 strip (each body scrolls) |
| MT1 | Header is a full-width target at frame height; hide-panel button stays `icon_md` |
| MT2 | n/a: no custom-drawn control |
| CL1, HC1 | Key, description and heading text at least 4.5:1 on the window background in both theme modes |
| CL2, CL3 | Key vs description is also told apart by column; no red |
| CL4 | Checked in Fancy Dark and Match Theme |
| HI1 | Each body child ends only when its Begin returned true (RB1) |
| HI2, HI3 | n/a: window flags and toolbar unchanged |
| HI4 | Open / closed saved on change only |
| HI5 | Item list keeps its clipper; shortcut column widths measured once per font, not per row per frame; no REAPER calls in the list |
| HI6 | Stable `##` IDs on both headers and both children; the count in the Pitched Items label does not change its ID |
| HI7 | n/a |
| RB15, RB16, RB19 | Existing tooltips unchanged; no hand-built splitter between the sections (sizes are computed, not dragged); `SetNextItemOpen`, `Key_H` checked in the names file |

## Open questions / assumptions

- **Assumption: both sections open by default**, also for people upgrading, so the list is seen once without anyone having to find `H`. One click or `H` folds it for good.
- **Assumption: the row selection above** (20 rows). `R` is in, S / Q / X / M are out. Say which rows to add or drop.
- **Two triangles on the Pitched Items header.** The collapse arrow (left) and the existing hide-panel button (right, also a triangle) sit on one row; with the section closed both point right. Tooltip and position tell them apart. A different hide-panel icon would need a new icon in the shared library and is not proposed here.
- **Not in scope, noticed:** Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z are handled by the script but are not in the Help modal (HP1); the status messages mention undo. Not added here.
- **Not in scope:** dimming rows that do not apply right now (for example with nothing selected), clicking a row to run it, and a height divider between the two sections.
- **Doc placement:** this is a second design doc for the same script, kept apart from `pitch-correct.md` because that doc describes a different, earlier change.
- **Added after approval (requested in chat, 2026-11-19): default panel width.** With no stored width, the panel opens at the width where every Shortcuts row fits on one line, measured from the list's text in the font in use (widest key + widest description + the list's own padding and scrollbar), not a pixel constant. It is not saved; a width set by dragging the divider is stored and wins, and the existing clamps still keep the canvas its minimum.
- HC6 conflicts: None.
