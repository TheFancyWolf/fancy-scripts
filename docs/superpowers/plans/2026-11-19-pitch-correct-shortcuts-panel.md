# Pitch Correct Shortcuts Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The right panel of Fancy Pitch Correct gets two collapsible sections, Pitched Items and a condensed Shortcuts list, and `H` shows or hides the list.

**Architecture:** `render_pitched_items_sidebar` becomes a two-section panel: each section is a `Theme.collapsing_header` followed by a child window whose height comes from one pure function (`K.panel_heights`). The Shortcuts rows are read from the Help modal's own table (`K.INFO_SECTIONS`), where a row that also belongs in the panel carries a `panel = { group, text [, key] }` field. `H` flips `state.shortcuts_open` and the header follows it through `reaper.ImGui_SetNextItemOpen`.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui 0.10, `_lib/theme.lua` (no library change).

**Spec:** `docs/design/pitch-correct-shortcuts.md` (Approved 2026-11-19, TheFancyWolf). Implement it exactly. Do not invoke skills.

## Global Constraints

- Target file: `Pitch/Fancy_Pitch Correct.lua`, v2.8.1 → v2.9.0; `CHANGELOG.md` under `[Unreleased]`. No change to `_lib/`, `index.xml`, `.github/` or `_fancy_*.json`.
- Copy is fixed by the spec's Copy deck: labels `Pitched Items (%d)`, `Shortcuts`; groups `Select`, `Edit`, `View`, `General`; the 20 rows; status `Widen the window to show Shortcuts`; Help additions `H` → `Show / hide the Shortcuts list` and `▾ / ▸ (section header)` → `Collapse / expand the section`. `Cmd` comes from `K.MOD_LABEL`.
- ExtState section `FancyScripts`, keys `pitch_items_open` and `pitch_shortcuts_open`, values `"1"` / `"0"`, written only when the value changes. Missing or unreadable = open.
- No project state is read or written by anything in this plan; no undo point.
- The script chunk is near Lua's 200-locals limit: new constants and functions go into the existing `K`, `BODY` and `state` tables, not new top-level locals.
- Tokens only (`Theme.layout.*`, palette keys, `Theme.font_sizes.*`); `reaper.*` called directly; every variable `local`; nil-guard API returns.
- No test framework, mock or fake REAPER. Tests are `luacheck .` and real REAPER through the bridge, following `.agents/skills/reaper-screenshot/references/testing-protocol.md` (sweep strays before and after every action; put back what you changed, including the user's open/closed panel state and Theme Mode).
- Work on branch `feat/pitch-correct-shortcuts`. Commit only when the user says so; never push. Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- If a permission prompt fails or the bridge times out: stop and tell the user.

## Review Focus

1. **Many pitched items with both sections open.** The item list must stay inside its half and scroll there with its clipper; Shortcuts stays visible below. (Task 1 test c.)
2. **A very short panel** (wide short strip, body just over 80 px). Heights never go negative and no child is opened with a height under 1 px; folding one section gives the other the room. (Task 1 `K.panel_heights` cases; test d.)
3. **`H` while typing a value** (Cmd-click text entry on a top bar value) or with a menu / modal open. Nothing toggles. (Task 2 test c.)
4. **`H` with the panel hidden, and in a window too narrow for the panel.** First: panel shows with Shortcuts open. Second: nothing changes and the status pill says why. (Task 2 tests d, e.)
5. **Match Theme with a low-contrast accent.** Key text falls back to the text colour when the accent is under 4.5:1 on the window background. (Task 2 `K.panel_key_color`; test f.)

---

### Task 1: Collapsible sections and height sharing

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` — `state` (near line 436), the ExtState init block (near line 662), `BODY` (near line 5461), `render_pitched_items_sidebar` (near line 5520), `draw_body_split` (near line 5818, only if the child call needs it)

**Interfaces:**
- Produces:
  - `state.items_open`, `state.shortcuts_open` (booleans, default `true`, loaded from ExtState at start).
  - `K.set_panel_open(which, open)` — `which` is `"items"` or `"shortcuts"`; sets the state field and writes its ExtState key only when the value changed.
  - `K.panel_heights(avail_h, items_content_h, items_open, shortcuts_open) -> items_h, shortcuts_h` — pure; `avail_h` is the room left under the two headers. Both open: `items_h = min(items_content_h, floor(avail_h / 2))`, `shortcuts_h = avail_h - items_h`. One open: it gets `avail_h`, the other `0`. Both closed: `0, 0`. Results are clamped to `>= 0`; a section whose height is under 1 is not drawn.
  - `K.draw_shortcuts_body(sidebar_ctx)` — a stub in this task that draws nothing (Task 2 fills it).

- [ ] **Step 1: Branch.** `git checkout -b feat/pitch-correct-shortcuts`

- [ ] **Step 2: State and persistence.** Add the two state fields, load them beside `pitch_sidebar_open` (same "0"/"false" = closed rule), add `K.set_panel_open`.

- [ ] **Step 3: `K.panel_heights`.** Implement as specified above. Check it by reading against these cases: `(400, 150, true, true) → 150, 250`; `(400, 900, true, true) → 200, 200`; `(400, 900, true, false) → 400, 0`; `(400, 150, false, true) → 0, 400`; `(-12, 150, true, true) → 0, 0`; `(1, 150, true, true) → 0, 1`.

- [ ] **Step 4: Sectioned panel.** In `render_pitched_items_sidebar`:
  - Replace the text header row with `Theme.collapsing_header(sidebar_ctx, string.format("Pitched Items (%d)###pitch_items_hdr", n), { action_fn = <the existing hide-panel icon_btn> })`, preceded by `reaper.ImGui_SetNextItemOpen(sidebar_ctx, state.items_open, reaper.ImGui_Cond_Always())`. If the returned open state differs from `state.items_open`, call `K.set_panel_open("items", ...)`. Check in `_lib/theme.lua` how `collapsing_header` derives its ID from the label so the count never changes the ID (HI6); if `###` is not honoured, use a fixed `##pitch_items_hdr` suffix as the helper expects.
  - Add the second header `Shortcuts##pitch_shortcuts_hdr` the same way (no action).
  - Both headers are drawn first-then-body in order: items header, items body, shortcuts header, shortcuts body. Measure one header's height (`reaper.ImGui_GetFrameHeight` plus item spacing) to get `avail_h` = panel height − two headers.
  - Items body: everything the function draws today after the separator (unreadable banner, empty text, "On" label, clipper rows) moves into `reaper.ImGui_BeginChild(sidebar_ctx, "##pitch_items_body", 0, items_h)` (End only when Begin returned true). `items_content_h` = banner height when present + "On" label height + `#state.session_order * (row_h + spacing_y)`, or the wrapped empty text's height when the list is empty; computed from the same geometry values the rows use, not hardcoded.
  - Shortcuts body: `reaper.ImGui_BeginChild(sidebar_ctx, "##pitch_shortcuts_body", 0, shortcuts_h)` calling `K.draw_shortcuts_body`.
  - The outer `##pitched_items_sidebar` child must not scroll itself: give it `reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()`.
  - The Remove confirm request (`to_remove`) keeps working from inside the items child.

- [ ] **Step 5: Lint.** Run: `luacheck .` Expected: `0 warnings / 0 errors`.

- [ ] **Step 6: Real REAPER.** Follow the testing protocol. Note the user's current panel state first and restore it at the end.
  - a. Relaunch the script; screenshot: two headers, items listed as before, Shortcuts body empty.
  - b. Click each header: it folds and unfolds; relaunch: the state was remembered.
  - c. With both open and the user's 7 items: items take only their content height; if the panel is made short enough, the item list scrolls inside its half.
  - d. Fold Shortcuts: items fill the panel as before this change. Fold both: two headers only.
  - e. Hide-panel button still hides the panel; the tag brings it back; Remove on a row still opens its confirm (Cancel it).

- [ ] **Step 7: Commit (when the user says so).** `feat(pitch-correct): collapsible Pitched Items and Shortcuts sections`

### Task 2: Shortcut rows, `H`, Help modal

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` — `K.INFO_SECTIONS` (near line 6352), the Shortcuts body, the key handling beside the Esc block in the main window (near line 7924), `BODY` texts

**Interfaces:**
- Consumes: `state.shortcuts_open`, `state.sidebar_open`, `K.set_panel_open`, `K.draw_shortcuts_body` (stub) from Task 1; `set_status`; the `sidebar_fits` value computed in the main body.
- Produces:
  - `panel = { group = "Select"|"Edit"|"View"|"General", text = "<short description>", key = "<short key, optional>" }` on the Help rows that are in the panel, and new Help rows where none exists.
  - `K.panel_rows()` → cached list `{ { group = "Select", rows = { { key, text }, ... } }, ... }` in the order Select, Edit, View, General, built once from `K.INFO_SECTIONS`.
  - `K.panel_key_color(P)` → `P.accent` when its WCAG contrast on `P.bg` is ≥ 4.5, else `P.text`; cached per palette (recomputed when the theme mode changes).
  - `K.toggle_shortcuts(sidebar_fits)` — the `H` behaviour.

- [ ] **Step 1: Mark the rows.** `K.INFO_SECTIONS` is defined after the sidebar function today; move the table (not `draw_info_modal`) above `render_pitched_items_sidebar` so the panel can read it. Add `panel` to these rows (key shown in the panel → text), adding a Help row where the spec's row has no exact Help row:

  | Group | Panel key | Panel text | Help row |
  |---|---|---|---|
  | Select | `<Mod> + A` | `Select all` | existing |
  | Select | `← / →` | `Prev / next note` | existing |
  | Select | `Shift + Click` | `Select range` | existing |
  | Select | `<Mod> + Click` | `Add / remove` | existing |
  | Select | `Drag empty` | `Box select` | existing "Marquee Drag" |
  | Select | `Esc` | `Deselect` | existing "Escape" |
  | Edit | `↑ / ↓` | `±1 semitone` | existing |
  | Edit | `Shift + ↑ / ↓` | `±10 cents` | existing |
  | Edit | `R` | `Reset pitch` | existing "R / Backspace / Delete" |
  | Edit | `Double-click` | `Snap to semitone` | existing "S / Double-Click" |
  | Edit | `Right-click` | `Note menu` | existing "Right-click a note" |
  | Edit | `Shift + Drag` | `Onset Ramp · Transition · Scoop` | on "Shift + Drag Left Zone" (one panel row for the three) |
  | Edit | `Drag edge` | `Trim note` | existing "Drag Note Edge" |
  | View | `Z` | `Zoom to selection` | existing |
  | View | `F` | `Fit whole item` | existing |
  | View | `<Mod> + Wheel` | `Zoom time` | existing |
  | View | `Shift + Wheel` | `Scroll time` | existing "Shift + Wheel or horizontal scroll" |
  | View | `Alt + Wheel` | `Zoom pitch` | existing |
  | General | `Space` | `Play / stop` | existing |
  | General | `H` | `Hide this list` | **new** Help row `H` → `Show / hide the Shortcuts list`, in "Selection & Navigation" |

  Also add the Help row `▾ / ▸ (section header)` → `Collapse / expand the section` to "Icons". The Help modal reads only `row[1]` and `row[2]`, so the extra field does not affect it. Within a group the panel order is the order of this table (give `panel` an `order` number if the Help order differs).

- [ ] **Step 2: Draw the list.** `K.draw_shortcuts_body`: per group, `Theme.section_divider(ctx, group, { color = P.yellow })`, then a 2-column table (`TableFlags_SizingFixedFit`, first column fixed at the widest panel key measured with `CalcTextSize` + `L.sm`, second column stretch). Key with `reaper.ImGui_TextColored(ctx, K.panel_key_color(P), key)`, description with `reaper.ImGui_TextWrapped`. `reaper.ImGui_Dummy(ctx, 0, L.md)` between groups. No hover, no click, no tooltip. The widest-key width is measured once and cached, invalidated when the font size changes.

- [ ] **Step 3: `H`.** Next to the window-level Esc block (same guards: no popup at frame start, no popup open now, no item active, window focused), `reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_H())` (no repeat flag, no modifier) calls `K.toggle_shortcuts(sidebar_fits)`:
  - `not sidebar_fits` → `set_status("Widen the window to show Shortcuts")`, no state change;
  - panel hidden (`not state.sidebar_open`) → set `state.sidebar_open = true` (and its ExtState, as the tag button does) and `K.set_panel_open("shortcuts", true)`;
  - else → `K.set_panel_open("shortcuts", not state.shortcuts_open)`.
  `sidebar_fits` is computed inside the body block today; keep its last value in `state.frame` (or hoist it) so the key handler can read it. `H` must work with no notes and on a bypassed item, so it does not go inside the note-editing key block in `draw_graph`.

- [ ] **Step 4: Lint.** Run: `luacheck .` Expected: `0 warnings / 0 errors`.

- [ ] **Step 5: Real REAPER.**
  - a. Screenshot with both sections open: 4 group headings, 20 rows, text exactly as the table above, keys in the accent colour, nothing clipped.
  - b. Drag the divider to the panel's minimum width: descriptions wrap, the key column holds, nothing overlaps. Restore the width.
  - c. Click the canvas, press `H`: the list folds; `H` again: it unfolds. Cmd-click a top bar value to type, press `h`: nothing toggles (Esc out). Open the More menu, press `H`: nothing toggles.
  - d. Hide the panel with its button, press `H`: the panel returns with Shortcuts open.
  - e. Float or narrow the window until the panel shows as the tag, press `H`: status pill reads `Widen the window to show Shortcuts`. Restore.
  - f. Open Help: the `H` row and the collapse-arrow row are there; everything else unchanged. Switch Theme Mode to Match Theme, screenshot the panel, check the key text is readable, switch back to the user's mode.
  - g. `S`, `Q`, `Z`, `F`, arrows, Esc and Space still behave as before (one check each).

- [ ] **Step 6: Commit (when the user says so).** `feat(pitch-correct): Shortcuts list in the right panel, H toggles it`

### Task 3: Version and changelog

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua:3-5` (`@version 2.9.0`, `@changelog` one line), `CHANGELOG.md` (`[Unreleased]`, new entry above v2.8.1)

- [ ] **Step 1:** Header `@version 2.9.0`; `@changelog`: `Shortcuts list in the right panel (H shows or hides it); Pitched Items and Shortcuts fold from their headers`.
- [ ] **Step 2:** `CHANGELOG.md` entry `Fancy Pitch Correct v2.9.0` in the house style: what the list holds and why (the keys nothing on screen shows), the two folding headers and that their state is remembered, `H`, the Help modal additions.
- [ ] **Step 3:** `luacheck .` → `0 warnings / 0 errors`; relaunch once more in REAPER, final screenshot, sweep, restore the user's panel state.
- [ ] **Step 4: Commit (when the user says so).** `docs(pitch-correct): v2.9.0 changelog`
