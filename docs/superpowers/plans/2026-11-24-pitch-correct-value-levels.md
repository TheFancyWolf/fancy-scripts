# Pitch Correct Value Levels Implementation Plan

docs/design/pitch-correct-value-levels.md is Approved (2026-11-24, TheFancyWolf). Implement it exactly. Do not invoke skills.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every value in Fancy Pitch Correct three levels: starting values, then this item, then notes. Items copy the starting values once, and item values reach every note. The top bar edits only this item or the selected notes, in three named groups. One "Apply to other items…" confirm pushes values onto other items.

**Architecture:**
- **Item values.** Each analysed take holds a value for every key in `data.overrides` (value keys) and in `data.key_idx`, `data.scale_idx` and `data.separation`, all seeded once from `global_defaults` (the starting values, ExtState). `get_effective` keeps its signature. The engine's "edited notes only" gate becomes "not bypassed".
- **Writing envelopes for items that aren't open.** This reuses the existing trick in `K.envelope_check`: point `state.target_take_guid` at the other take for the length of a build. The writing half of `apply_envelope_to_take` becomes a helper without its own undo block, so Apply can write many takes in one block.
- **The top bar.** It keeps its structure (`HDR_PLANS`, `K.bar_frame`, `BAR_VALUES`). It gains groups, captions, a pill menu, and an extended `request_confirm`.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui, `_lib/theme.lua` (unchanged). Tests: plain Lua, `lua docs/superpowers/tests/pitch_correct_spec.lua` from the repo root (175 tests pass at `800b36d`).

**Spec:** `docs/design/pitch-correct-value-levels.md`. Read it in full before Task 1. "The model" (under Feature inventory), the Interaction spec and the Copy deck are binding.

## Global Constraints

- Branch `feat/pitch-correct-value-levels`, cut from `main` at `800b36d`. Never push; commit per task.
- No backward compatibility and no migrations (project rule): stored `overrides` keep their field name. An analysed take without item values is seeded on load (Task 1); nothing else is converted.
- Keys, exactly: `K.ITEM_KEYS = { "separation", "correct_mode", "tighten", "tolerance", "retune_speed", "slide_in" }` (value keys, in `data.overrides`, except `separation`, which stays `data.separation`), plus `key_idx` and `scale_idx` (in `data`).
- Starting values: `global_defaults` holds every key above. Its defaults come from `DEFAULTS`: separation 0.5, correct_mode 0, tighten 0, tolerance `DEFAULTS.tolerance`, retune_speed `DEFAULTS.retune_speed`, slide_in 0. key_idx and scale_idx come from the existing ExtState keys `pitch_key_idx` / `pitch_scale_idx`. They are saved by `K.save_settings("cascade")` and **only** from Apply (Task 6).
- The bar never calls `K.save_settings("cascade")`, never calls `K.save_settings("engine")` for Separation, and never writes `pitch_key_idx` / `pitch_scale_idx`.
- No new chunk-level `local` in `Pitch/Fancy_Pitch Correct.lua` (the chunk is near Lua's 200-local limit). New functions and tables go on `K`.
- User-facing strings are copied verbatim from the spec's Copy deck. The words "override", "cascade" and "global default" appear in no user-facing string.
- House rules (AGENTS.md):
  - call `reaper.X()` directly, and declare every variable `local`;
  - no hardcoded colours, sizes or spacing: use `Theme.layout`, the palette and `Theme.font_sizes`;
  - check every ReaImGui name you add (`ImGui_RadioButton`, `ImGui_Checkbox`, `ImGui_BeginPopup`) with the `reaper-dev` tools;
  - never edit `index.xml`, `.github/workflows/` or `_fancy_*.json`;
  - `luacheck .` must be clean before every commit.
- No fake or mock of REAPER beyond the stub the spec file already has (`docs/superpowers/tests/reaper_stub.lua`, the `FANCY_PITCH_TEST` guard). Real-REAPER steps follow `.agents/skills/reaper-screenshot/references/testing-protocol.md` and the memory note `reaper-real-testing-limits.md`. A failed permission prompt means stop and tell the user.

## Review Focus

1. **A take analysed before this change** (no item values) is opened. It is seeded from the starting values, and with the starting values at `DEFAULTS` its correction is unchanged. Test `seed_old_take_same_build` (Task 1).
2. **A note explicitly at Tighten 0%** under an item at 40% stays at 0% through save, load, merge and split. Test `note_zero_survives_load` (Task 2).
3. **Undo after Apply** restores every target's notes and envelope in one step, and the starting values stay. Checked live in Task 7; the status copy says so (Task 6).
4. **A target take deleted, or switched to MIDI, between opening the confirm and running Apply** is skipped and counted, not an error. Test `apply_plan_skips_missing` (Task 6).
5. **A stretch re-split whose selection is not contiguous** re-splits the unselected notes between the first and last selected note too, and leaves the notes outside it byte-identical. Test `segment_stretch_outside_untouched` (Task 4).

---

### Task 1: Starting values and per-item values (copy once)

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`:
  - `global_defaults` (~196);
  - the settings `number("cascade", …)` loader (~680), adding the four new keys under `pitch_tighten`, `pitch_slide_in`, `pitch_correct_mode` and `pitch_start_separation`;
  - `get_effective` (~510);
  - `get_override_level` (~523);
  - `load_take_data` (~2298), plus the analysis-complete path that creates a take's data (~4950).
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces:
  - `K.ITEM_KEYS` (list above).
  - `K.item_seed(data) -> boolean`: fills every missing item key of `data` from `global_defaults` and returns true when it filled one.
  - `K.start_values() -> table`: a copy of `global_defaults` with `key_idx` and `scale_idx`.
  - `get_effective(note, key)`: note, else the target's item value, else `global_defaults[key]`, the last only for a take not yet seeded.
  - `get_override_level(note, key) -> "note" | "item" | "start"`. `"item"` now means "the item differs from the starting value" (the `*` mark).

- [ ] **Step 1: Write the failing tests**:
  - `item_seed_fills_all`: an empty `data` gets all six value keys plus `key_idx`, `scale_idx` and `separation` equal to `K.start_values()`; a second call returns false.
  - `item_copy_once`: after seeding, changing `global_defaults.tolerance` leaves `get_effective(nil, "tolerance")` for that target unchanged.
  - `seed_old_take_same_build`: a fixture take without `overrides`, seeded with `global_defaults` at `DEFAULTS`, gives the same `K.correction_build` points as before seeding.
- [ ] **Step 2: Run** `lua docs/superpowers/tests/pitch_correct_spec.lua`. Expected: the three new tests FAIL (`K.item_seed` is nil).
- [ ] **Step 3: Implement.**
  - Call `K.item_seed` in `load_take_data` (seeding is a model change only, not written until the next save) and where a first analysis creates `data`.
  - `state.separation`, `state.key_idx` and `state.scale_idx` keep mirroring the open item (`adopt_take_data`), so existing readers keep working.
- [ ] **Step 4: Run** the spec. Expected: `ok 178 tests`.
- [ ] **Step 5:** `luacheck .` clean; commit `feat(pitch-correct): items copy the starting values once`.

### Task 2: Item values reach every note; explicit note values

**Files:**
- Modify:
  - `K.NOTE_CONTROLS` (~1622): `tighten` and `slide_in` become `edited = "set"`;
  - `K.controls_merge`: the weighted merge uses each note's effective value and gives `nil` when no merged note had its own;
  - `K.controls_load`: no 0 → nil for tighten;
  - `K.tighten_line` and the Slide In reader: read `get_effective(note, key)`, not `ctrl[key]`;
  - `K.note_mode`, and the `is_mod` gate in `K.natural_build`'s note loop (~3032): a note is reached when it has controls and is not bypassed;
  - `K.mode_unused` (~3321).
- Test: spec file.

**Interfaces:**
- Produces: `K.note_reached(note) -> boolean` (has controls and is not bypassed). Every engine reader uses it instead of `is_note_modified`. `is_note_modified` keeps its meaning for display (note colours, reset, re-split matching).

- [ ] **Step 1: Write the failing tests**:
  - `item_tighten_reaches_unedited`: an unedited note under item tighten 1 gives a flat build.
  - `note_zero_survives_load`: `controls_load({ tighten = 0 })` keeps 0, and that note builds as sung under item tighten 0.4.
  - `bypassed_untouched`: a bypassed note under item tighten 1 is unchanged.
  - `item_mode_reaches_unedited`: K.note_mode is "hard" for an unedited note when the item's correct_mode is 2.
  - `fresh_item_as_sung`: with the starting values at DEFAULTS, the build of an unedited item is all zeros.
- [ ] **Step 2: Run** the spec. Expected: the five FAIL.
- [ ] **Step 3: Implement** as listed under Files. Strength stays as it is (`coarse` is 0 for a note with no pitch move). Change the Mode status texts at ~3306 to the Copy deck's wording: the item text says every note uses the Mode; it no longer says "Notes you edit will use it".
- [ ] **Step 4: Run** the spec. Expected: every test passes. Some existing tests assume "unedited notes are never corrected"; update only those whose expectation the spec reverses, and say which ones in the commit message.
- [ ] **Step 5:** luacheck; commit `feat(pitch-correct): item values reach every note`.

### Task 3: The bar edits this item or the notes, never the starting values

**Files:**
- Modify:
  - `BAR_VALUES` (~11400): tighten and slide_in get `levels = "all"` and lose `zero_nil`; sep gets `levels = "all"`;
  - `bar_view`, `write_cascade_value` and `note_global_edit` (removed), `toggle_item_override` (removed), `reset_cascade_param`, `item_override_menu`, `draw_separation`;
  - `save_current_scale_settings` (~2275) and `K.scale_changed` (~3650): remove the ExtState writes;
  - `K.resplit` and `K.follow_resplit_undo`: Separation reads and writes `data.separation`; no `K.save_settings("engine")`;
  - `BAR_PILL_NONE`, `BAR_PILL_TIP_*`, `BAR_SCOPE_*`.
- Test: spec file.

**Interfaces:**
- Consumes: Task 1's `K.item_seed`, `get_override_level`.
- Produces:
  - `K.reset_target(key, sel_notes, sel_n) -> boolean`: with notes, clears their own value (to the item's); else sets the item's value to the starting value. One undo point, labels from the Copy deck.
  - `K.value_menu(bctx, key)`: the right-click menu: "Reset to starting value" / "Reset to item value", and "Apply <Value> to other items…", which calls `K.apply_open({ key })` from Task 6. Until Task 6 lands, that entry is drawn disabled with the reason "No other pitched items".

- [ ] **Step 1: Write the failing tests** (pure parts):
  - `reset_item_to_start`: `K.reset_target("tolerance", {}, 0)` sets the item's value to `global_defaults.tolerance`.
  - `reset_notes_to_item`: clears the notes' `tolerance`.
  - `bar_never_saves_cascade`: wrap `K.save_settings` to count calls, run a simulated committed item edit through the bar's write path (`K.bar_write(key, v, sel_notes, 0)`, the extracted write function), and expect 0 calls.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Extract the bar's write path into `K.bar_write(key, v, sel_notes, sel_n)`.
  - The pill text with nothing selected is `This item`. Pill and value tooltips come from the Copy deck, including "Starting value: <v>. This item: <v>.".
  - Separation with nothing selected re-splits the item (`K.resplit(prev)`, now with an item value). On an item that is not analysed yet, Separation, Key and Scale stay usable: they write the item's value (seeded by `K.item_seed` at that moment), and the first analysis uses it. Correction and Shaping stay disabled with "Analyze an item first". With notes selected, it calls Task 4's `K.resplit_stretch`; until Task 4 lands, it re-splits the item.
- [ ] **Step 4: Run** the spec; expected all pass. Then real REAPER, following the protocol: relaunch the script, select no note, drag Tolerance, and check in REAPER's Edit menu that the undo label is "Adjust Tolerance" and that ExtState `FancyScripts/pitch_tolerance` is unchanged (read it with the bridge's `run_action_by_name` only if available, otherwise through a temporary `-- TEMP-DIAG` line, removed before the commit). Undo it. Screenshot the bar showing `This item`.
- [ ] **Step 5:** luacheck; commit `feat(pitch-correct): the bar edits this item or the selected notes`.

### Task 4: Re-split the selected notes' stretch

**Files:**
- Modify: near `K.resplit` (~10629); `K.follow_resplit_undo`; `draw_separation`.
- Test: spec file.

**Interfaces:**
- Produces:
  - `K.segment_stretch(results, sep, old_notes, t0, t1) -> new_notes, split_points`: pure.
    - It runs `K.segment` on the frames with `t0 <= time <= t1`.
    - It returns `old_notes` before `t0` (unchanged tables), then the new notes, then `old_notes` after `t1`.
    - `split_points` is merged the same way.
    - The re-split notes keep edits by `K.resplit_match` against the old notes inside the stretch.
  - `K.resplit_stretch(sep)`: wraps it for the open item.
    - The stretch runs from the first selected note's `start_time` to the last selected note's `end_time`.
    - Same confirm as `K.resplit` when edits would be lost.
    - Undo label `K.RESPLIT_STRETCH_UNDO = "Re-split selected notes"`.
    - The notes inside the stretch end up selected.
    - Status "Re-split %d notes into %d.".
    - `data.separation` is not changed.
  - `K.follow_resplit_undo` returns without changing the item value when the step is `K.RESPLIT_STRETCH_UNDO`.

- [ ] **Step 1: Write the failing tests** with the existing `frames()` helper:
  - `segment_stretch_outside_untouched`: three phrases; the stretch over the middle one re-splits only it; the notes before and after are the same tables (`rawequal`).
  - `segment_stretch_higher_sep_more_notes`: a slide joined at sep 0.2 becomes two notes at sep 0.9 inside the stretch.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement**, and wire `draw_separation` with notes selected to `K.resplit_stretch`. Separation shows the item's value while notes are selected (the spec's "My call").
- [ ] **Step 4: Run** the spec; all pass.
- [ ] **Step 5:** luacheck; commit `feat(pitch-correct): Separation re-splits just the selected notes`.

### Task 5: Groups, captions, Shaping and the pill menu

**Files:**
- Modify:
  - the TOP BAR section (~10845–11335): `HDR_VALUES`, `HDR_GROUP` (new groups `notes`, `correction`, `shaping`, each a separator break), `HDR_PLANS`, `hdr_gap_before`, `measure_header_static`;
  - `K.bar_measure`;
  - `K.bar_frame`'s `draw_unit`, `draw_pill`;
  - the Info modal Edit rows (~9071).

**Interfaces:**
- Produces:
  - `HDR_VALUES = { "pill", "sep", "mode", "tight", "tol", "strength", "slide" }`.
  - Group of each: pill → `values`, sep → `notes`, mode/tight/tol → `correction`, strength/slide → `shaping`. The pill and the first group share no separator break: the pill is followed by the `L.xl` gap and a hairline, like every other group change.
  - `K.bar_caption(bctx, group)`: draws `Notes` / `Correction` / `Shaping` with `Theme.push_font` at `Theme.font_sizes.small`, `P.text_dim`, and `Theme.align`.
  - The captions are units of their own: `cap_notes`, `cap_correction`, `cap_shaping`.
  - New `HDR_PLANS`, chosen by width as today, from widest to narrowest:
    1. one row with captions;
    2. one row without captions;
    3. Clip row + Values row with captions;
    4. Clip row + Values row without captions;
    5. the narrow plan from the spec's wireframe: `{brand, badge}`, `{key, scale}`, `{pill, sep}`, `{mode, tight}`, `{tol}`, `{strength, slide}`.
  - Shaping units are measured and drawn with the small font pushed (LG3: measured in the font they are drawn in).
  - The pill: `Theme.badge` with `interactive = true, id = "bar_pill"`; a click opens popup `##bar_pill_menu`. It holds:
    - the dim "Edits go to: this item" / "Edits go to: the %d selected notes";
    - a dim starting-values line, truncated with `hdr_fit_text` and a tooltip holding the full line;
    - "Apply to other items…" (`K.apply_open(nil)`, all keys);
    - "Reset this item to the starting values". It is disabled with "Already at the starting values" when no item value differs. It runs `K.reset_item_all()`: one undo point "Reset item to starting values", a re-split if Separation differs, and status "Item reset to the starting values.".
  - Esc closes the menu (HC5, `reaper.ImGui_Shortcut`).
  - When the active plan has no captions, each value's tooltip starts with its group: "Notes ·", "Correction ·" or "Shaping ·".

- [ ] **Step 1: Write the failing tests**:
  - `hdr_plan_widths_ordered`: each plan's minimum content width (`hdr_min_content_w`) is strictly larger than the next plan's.
  - `reset_item_all_counts`: after an item tolerance change, `K.item_differs(data)` is 1, and 0 after `K.reset_item_all`'s model part (`K.item_reset_values(data)`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Info rows (HP1):
  - "Click the pill: apply values to other items, or reset this item";
  - "Double-click a value: back to the item's value (notes) or the starting value (item)".
- [ ] **Step 4: Run** the spec; all pass. Then real REAPER (protocol):
  - screenshot the docked window at its current width and check the captions, the separators and the smaller Shaping;
  - open the pill menu and capture it with a region `screencapture` (popups are not in a main-window capture);
  - press Esc to close it.

  Docked width changes cannot be driven (memory note), so plans 3–5 are checked only by the test and reported as not seen live.
- [ ] **Step 5:** luacheck; commit `feat(pitch-correct): Values group in three named groups with a pill menu`.

### Task 6: Apply to other items

**Files:**
- Modify:
  - `request_confirm` (~line found by `grep -n '^local function request_confirm'`) and the confirm modal drawer (`draw_confirm_modal`);
  - `apply_envelope_to_take` (~3564): split its write part out;
  - batch machinery (section 3b) for the time-sliced run and Cancel.
- Test: spec file.

**Interfaces:**
- Produces:
  - `request_confirm` gains three optional fields:
    - `req.choices = { { label, value, reason } }`: radios; `reason` non-nil means drawn disabled with that reason inline (EP2);
    - `req.check = { label = string, value = boolean }`;
    - `req.consequence = function(choice, checked) -> { lines }`: called only when the choice or the check changes (HI5), and its result is cached in `state.confirm`.
  - `on_confirm(choice, checked)`. Cancel is drawn first; Esc = Cancel; Enter does nothing.
  - `K.write_take_envelope(guid, data) -> boolean`: writes one take's envelope and its take data, with no undo block of its own. It swaps `state.target_take_guid` for the build, as `K.envelope_check` does. `apply_envelope_to_take` uses it inside its own block.
  - `K.apply_targets(choice) -> entries, skipped`:
    - `"selected"`: `K.batch_selection()` minus the open item, analysed takes only;
    - `"all"`: every `state.session_order` take except the open item;
    - `"new"`: an empty list.
  - `K.apply_plan(src, entries, keys, keep, old_start) -> plan`: pure.
    - `plan.items[i] = { guid, set = { key = v }, clear_note_keys = { key… }, resplit = bool, key_change = bool, lost = n }`;
    - `plan.counts = { items_lose, notes_lose, key_change, resplit, lost, not_resplit, skipped }`.
    - With `keep`, an item key whose value differs from `old_start[key]` is left out of `set`, note keys are not cleared, and an item with `is_note_modified` notes gets `resplit = false` (counted in `not_resplit`).
    - Without `keep`, everything is set and cleared, and `lost` counts the edited notes a re-split would not match (`K.resplit_match`).
    - Entries whose take no longer resolves, or whose active take is MIDI, are counted in `skipped` and get no item row.
  - `K.apply_open(keys)`: keys nil = `K.ITEM_KEYS` plus `key_idx` and `scale_idx`. It opens the confirm:
    - the title is "Apply this item's values to other items?" or, for one key, "Apply %s to other items?";
    - the choices are "The %d selected items" (reason "Select items in the arrange view" at 0), "All %d pitched items" (reason "No other pitched items" at 0) and "New items only";
    - the default choice is selected when at least 1 is selected, else all;
    - the check is "Keep changes already made to items and notes", off;
    - the consequence lines are the Copy deck's, filled from `plan.counts`, plus the footnote;
    - the confirm label is "Apply (%d)", or "Save starting values" for New items only; it is disabled with "Nothing would change" when the plan changes nothing.
  - `K.apply_run(plan, keys, src)`:
    1. Saves the starting values first (`global_defaults` = the source's values for `keys`; `K.save_settings("cascade")`; `pitch_key_idx` / `pitch_scale_idx` when they are in `keys`).
    2. Computes one item per defer cycle within the existing analysis time budget, with progress on the "…" button and Cancel through `K.cancel_analysis`'s batch branch.
    3. Writes every finished item in one undo block "Apply values to %d items" (one key: "Apply %s to %d items") with `K.write_take_envelope`.
    4. Posts the status: "Applied to %d items (%s+Z undoes the items).", or "Applied to %d items. %d skipped: no audio.", or "Starting values saved for new items.".
    - A Cancel partway writes the finished items as the one undo step and keeps the starting values. Its status says both.

- [ ] **Step 1: Write the failing tests**:
  - `apply_plan_overwrites`: two targets with different tolerance and notes with their own tolerance, keep = false; both items are set, the note keys are cleared, and `counts.items_lose` is 2.
  - `apply_plan_keep`: the same with keep = true; the target whose tolerance differs from `old_start` is not set, and its notes are kept.
  - `apply_plan_keep_no_resplit`: a target with an edited note and a Separation change; with keep, `resplit = false` and `not_resplit = 1`; without keep, `resplit = true` and `lost` > 0.
  - `apply_plan_skips_missing`: an entry with `take = nil` is counted in `skipped`.
  - `apply_plan_new_only`: an empty entry list gives empty items.
  - `confirm_consequence_cached`: the consequence function runs once for two draws with the same choice.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** as listed, and enable the right-click "Apply <Value> to other items…" from Task 3. Add "Apply Key to other items…" (keys `{ "key_idx", "scale_idx" }`) to the Key and Scale right-click menus.
- [ ] **Step 4: Run** the spec; all pass. luacheck clean.
- [ ] **Step 5:** commit `feat(pitch-correct): Apply to other items with a keep-changes option`.

### Task 7: Live check, changelog and version

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` header: `@version 2.22.0`, plus `@changelog` lines.
- Modify: `CHANGELOG.md` (Keep a Changelog, section `2.22.0`).

- [ ] **Step 1: Real REAPER**, protocol and memory note first. Before you start, note the edit cursor, the selection, the view and the Theme Mode.
  1. With at least two analysed items, select them in the arrange view.
  2. Open the pill menu, then "Apply to other items…". Capture the confirm: check the counts, Cancel drawn first, and Esc = Cancel.
  3. Run it with the check off. Check that the status says the items can be undone.
  4. Press Cmd+Z once, through the Edit menu, reading its label twice. Check that every target is back and that the starting values stay.
  5. Repeat with the check on, and confirm that a hand-edited item keeps its value.
  6. Select three notes, raise Separation and let go. Check the "Re-split selected notes" undo label and that the notes outside the stretch are unchanged.
  7. Put back what you changed.
- [ ] **Step 2:** Run the full spec (`ok N tests`, where N is every test in the file) and `luacheck .`. Both must be clean.
- [ ] **Step 3:** Write the CHANGELOG. Name the behaviour changes plainly:
  - items keep their own copy of the starting values;
  - item values now reach every note;
  - the bar no longer changes other items;
  - Key no longer sets the key for new items.
- [ ] **Step 4:** commit `feat(pitch-correct): v2.22.0, value levels and Apply to other items`. Report what was seen live and what was not (the narrow plans, Match Theme if it wasn't switched).
