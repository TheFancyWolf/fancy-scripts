# Pitch Correct Auto Range and Key, Revision 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

docs/design/pitch-correct-auto-range-key.md is Approved (2026-11-27, TheFancyWolf). Implement it exactly. Do not invoke skills.

**Goal:** Change the interface of the already-built Auto Vocal Range and Key feature: the Key list loses "Auto" (a key is found unless picked), the top bar shows the range in use, and one Analysis card in the middle of the note window carries all analysis progress and results.

**Architecture:** The listening pass (`K.pre_*`), the per-track record and its undo rules are untouched. Key index `0` stays the internal "not set" value but is shown as "–" and is no longer a list entry. A new card model `K.card` (pure builders `K.card_*` returning rows and strings, plus one draw function using the window's modal recipe) replaces the three places analysis progress was shown and the "Found …" / "Used …" status messages.

**Tech Stack:** Lua 5.4, ReaScript, ReaImGui, `_lib/theme.lua`. Spec harness: `lua docs/superpowers/tests/pitch_correct_spec.lua` (now "ok 407 tests"). Lint: `luacheck .`.

**Spec:** `docs/design/pitch-correct-auto-range-key.md` (revision 2; wireframes, State inventory and Copy deck are binding; every user-visible string is copied from the Copy deck verbatim).

## Global Constraints

- Only `Pitch/Fancy_Pitch Correct.lua`, `docs/superpowers/tests/pitch_correct_spec.lua` and (Task 3) `CHANGELOG.md` change. Never `index.xml`, `.github/`, `_fancy_*.json`, `_lib/`.
- No new `Theme` helper, colour, font size or spacing number: `Theme.badge`, `Theme.progress_bar`, `Theme.combo`, `Theme.align`, `Theme.right_align`, `Theme.tooltip`, `Theme.center_next_window`, `Theme.modal_scrim`, `Theme.layout.*`, palette keys only. Check each helper's signature in `/Users/macstudio/Development/fancy-scripts/_lib/theme.lua` before use.
- `reaper.Name()` called directly; every variable `local`; new functions hang off `K`; nil-check API returns; no fabricated API.
- Kept from revision 1 and not to be weakened: after any failed or cancelled analysis, batch or pre-run, `K.track_records_pending` is empty and `K.auto_run` is nil; a track's record is written only inside an undo block that also holds what it belongs to (Find Range and Key Again's own block is the one exception); the pre-analysis writes no ExtState; key index `0` never reaches `SCALE_KEYS[...]` or an item's stored model.
- Modal recipe (AGENTS.md "Modal scrims"): pending flag → `OpenPopup` once → `Theme.center_next_window` → `Theme.modal_scrim` → `BeginPopupModal`; Esc and Enter through `reaper.ImGui_Shortcut`; all inside the main window's `if visible` block; `End*` only when `Begin*` returned true.
- Disabled controls show their reason through `Theme.tooltip` gated by `HoveredFlags_ForTooltip | HoveredFlags_AllowWhenDisabled`.
- No real-REAPER run by implementers (the controller verifies with the user). No migration code. Version stays `2.29.0`. Commit only where a step says so; do not push; `git add` named files only.

## Review Focus

- A key picked by hand on an item not analysed yet, then Analyze with Vocal Range Auto → the item and the track's record both hold the user's key, never the found one; the card says "(your choice)".
- Switching the target between two unanalysed items → a key picked for the first must not leak to the second (each new item starts "–" or at its track's key).
- Cancel (button, Esc, window close, frame error) while the card is open in either step → card gone, nothing pending, no undo point, `state.is_analyzing` false.
- The card left open at "done" while the user changes the item selection in REAPER, undoes the analysis, or the project changes → the card still closes cleanly and "Set Key" from a stale card writes nothing to a vanished item.
- A batch of items on two tracks, one track with no singing → the card lists both tracks, the silent one with its problem text, and still ends at "done".
- Analysis that finishes in under one frame (a very short item, track already heard) → the card still appears at "done" and waits for OK.

---

### Task 1: Key is "–" until picked or found

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`K.new_key`, `K.key_resolve` ~556, `K.new_item_values` / `K.item_seed`, `K.PERSIST` key group, `K.adopt_new_item_values` ~4317, `K.scale_changed` ~5235, `K.find_key_request` / `K.find_key_finish` ~5283–5350, `K.auto_begin`'s record handling, `hdr_draw_key` ~14921, `COMBO_LABELS.keys`, the Key tooltip texts)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces:
  - Key index `0` = not set, shown as "–". The Key combo's list is the twelve keys only (no "Auto" entry; `COMBO_LABELS.keys` and the long names lose it); its preview for `0` is "–"; its tooltip while `0` is the Copy deck's "Pick the key if you know it. Otherwise it is found from the whole track when you analyze." The Scale combo while Key is `0`: preview "–", disabled, reason "Pick a key first, or it is found when you analyze".
  - `K.new_key` keeps only `hand_key_idx` / `hand_scale_idx` (the fallback when no key can be found; ExtState `pitch_key_hand_idx` / `pitch_scale_hand_idx`). `key_idx` / `scale_idx` of `K.new_key` and the ExtState keys `pitch_key_idx` / `pitch_scale_idx` are no longer read or written.
  - `K.pending_key[guid] = { key_idx, scale_idx }`: the key the user picked on item `guid` before its first analysis (in memory only; dropped when the item is analysed, removed or the project changes with the item gone).
  - `K.new_item_key(guid) -> key_idx, scale_idx, source` where `source` is `"picked"` (from `K.pending_key`), `"track"` (the track record's key) or `"unset"` (`0`, `1`). `K.adopt_new_item_values` puts this on the bar for an unanalysed target.
  - Picking a key in the bar on an unanalysed item: stores `K.pending_key[guid]` with Scale Major (`1`) unless a scale was already picked for it, updates `hand_*`, writes nothing to REAPER. Picking a scale then updates the pending entry.
  - `K.key_resolve(key_idx, scale_idx, guid) -> key_idx, scale_idx, from_track`: unchanged contract for `0` (track's key → `from_track = true`; else hand key).
  - Analyze: an item seeded with a picked key gets `key_from_track = true` when a listening pass ran or a record exists for its track, and that track's record takes the picked key and scale (`alt_*` cleared) inside the analysis's undo block; with no record and no pass (hand-picked range) the item just keeps its key.
  - `K.auto_needed(values, guid)`: true when `values.auto_range`, or the item is not analysed and `K.new_item_key(guid)` gives `"unset"`.
  - `K.item_key_source(data) -> "picked" | "track" | "found" | nil` recorded on the item model at analysis as `data.key_source` (`"found"` = found by this analysis's own listening pass, `"track"` = taken from a record that existed, `"picked"` = the user's): Task 2's card reads it.
  - Removed: `K.find_key_request`, `K.find_key_finish`, the "Find Key: <item>" undo label, their tests, and every user-visible "Auto" string for Key / Scale.

- [ ] **Step 1: Write the failing tests** — `key_list_has_twelve_keys` (no "Auto" label; preview for 0 is "–"); `new_item_key_sources` (pending → "picked"; record with key → "track"; neither → 0, 1, "unset"); `picked_key_does_not_leak` (pick on item A, adopt item B → B is "unset"); `picked_key_survives_analysis` (item with pending key 3 / scale 2, Auto range, stubbed listening pass that would find key 5 → stored item key 3 / 2, `key_source == "picked"`, the track write in the analysis block holds key 3 / 2 and no `alt_*`, `K.pending_key[guid] == nil` afterwards); `picked_key_fixed_range_no_pass` (`K.auto_needed` false; no track write); `unset_key_is_found` (stored key = the record's, `key_source == "found"`); `reused_record_key_source_track`; `scale_locked_while_unset` (the disabled reason string exact); `new_key_extstate_not_written` (picking a key on an unanalysed item writes neither `pitch_key_idx` nor `pitch_scale_idx`; `pitch_key_hand_idx` follows); `find_key_is_gone` (`K.find_key_request == nil`).
- [ ] **Step 2: Run the spec** — the new tests FAIL; delete the revision-1 tests of removed behaviour (Key "Auto" entry, Find Key, `K.new_key.key_idx` persistence) and say which in the report.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): a key is found unless picked; no Auto in the Key list`

---

### Task 2: The Analysis card and the range box

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`K.locked_reason` ~2790 and its users, `K.auto_status` / `K.auto_run_status` ~2748–2790, `K.analysis_progress` ~4302, `process_analysis_step`'s finish, `K.batch_finish` and its `K.status_hold(K.batch_summary(...))` ~4172, `K.find_again_request` / `K.find_again_finish` ~5355, `K.cancel_analysis`, `K.recover_after_error`, the "…" menu's Cancel item ~15041, the top bar draw after `hdr_draw_key` ~15188, the main window's modal section)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: Task 1's `data.key_source`; revision 1's `K.auto_run`, `K.pre_progress`, `state.pre`, `K.batch`, `K.track_record`, `K.pre_range_text`, `K.range_name`, the key-name helper used by `K.auto_status`, `K.scale_changed`.
- Produces:
  - `K.card` (nil when closed): `{ kind = "single" | "batch" | "again", phase = "listen" | "notes" | "done", title, step, progress (0..1), rows = { { label, value, dim, choices = { { text, key_idx, scale_idx } }, note } }, lines = { text… }, guid, track, picked = 1 }`.
  - `K.card_open(kind, info)`, `K.card_update()` (called every frame while something runs: sets `phase`, `step`, `progress`, fills rows from live state), `K.card_done(result)` (builds the final rows; called where the analysis, batch or Find Again finishes), `K.card_close(confirm)` (`confirm == true` on OK / Enter: applies a changed key choice through the existing key-change path, one undo point "Set Key"; Esc on a done card closes without applying), `K.card_cancel()` (running card: `K.cancel_analysis()` then closes).
  - Pure text builders, each tested for exact Copy deck strings: `K.card_title(kind, phase, name, i, n)`, `K.card_step(phase, track_name)`, `K.card_range_value(info)`, `K.card_key_value(info)`, `K.card_notes_value(info)`, `K.card_lines(info)`, `K.card_batch_row(track_name, record)`.
  - `K.card_draw()`: the modal (`L.modal_sm` wide, height from content, centred on the note canvas), title = `K.card.title`, step line, `Theme.progress_bar`, a two-column table of rows (label `P.text_dim`, value `P.text`, `dim` values `P.text_dim`), key candidates as `reaper.ImGui_RadioButton` rows with the note "These two fit equally well.", the lines, then `Cancel` (running) or `OK` (done) right-aligned. The batch list scrolls after six track rows.
  - `K.range_box_text(target_state) -> text, tooltip` and its draw: a read-only `Theme.badge` after the Scale combo: "–" with no item; the form's Vocal Range name before analysis; "A3–F4" or the preset name after; tooltips from the Copy deck. It is the first header element dropped when the bar runs out of width (use the header's existing width-priority mechanism; read how `hdr_min_content_w` / `measure_header_static` decide).
  - Removed: the stage-1 line in `K.locked_reason` (it returns the plain existing locked reason again), the percentage in the "…" menu's Cancel label and on the "…" button, analysis progress in the status line, `K.auto_status` / `K.auto_run_status` status posts ("Found …", "Used …", "Couldn't find a range …", "Not enough singing …", "Couldn't read N of M …") — their facts move into the card's rows and lines; the batch's end summary moves into the done card (no `K.status_hold` for it). The existing cancelled / unreadable-audio / item-gone status messages stay in the status line.

- [ ] **Step 1: Write the failing tests**
  - Text builders, exact strings: titles ("Analyzing 07_LeadVox copy.wav", "Analyzing 3 of 12: Lead take 3.wav", "Finding range and key", "Analysis done"); steps ("Listening to track \"Test\"…", "Finding notes…"); range values ("listening…", "A3 – F4", "A3 – F4 (from track \"Test\")", "Tenor (your choice)", "No singing found: used Generic Vocal"); key values ("listening…", "C Minor", "D Major (your choice)", "Not enough singing to tell: kept E Major"); notes ("waiting", "finding…", "31", "none found. Try another Vocal Range or Detection Mode."); lines ("Couldn't read 2 of 12 items on \"Test\" (media offline). Used the rest.", "Items already analyzed keep theirs."); batch row ("Lead Vox   B2 – A4 · E Major").
  - `card_follows_a_single_analysis` (with revision 1's `auto_world`): after `start_analysis` → `K.card.phase == "listen"`; after stage 1 → `"notes"` with the range and key rows filled; at the end → `"done"`, notes row = the note count, `state.is_analyzing == false`, the card still open; no "Found" / "Used" status was posted.
  - `card_close_call_offers_both` (record with `alt_*`) → the Key row has two choices, the best first; `K.card_close(true)` with `picked = 2` → item and track record hold the other key, log is one block labelled "Set Key"; with `picked = 1` → nothing written, no undo block.
  - `card_esc_on_done_applies_nothing`.
  - `card_cancel_in_each_phase` → card nil, pending empty, no undo block, `state.is_analyzing == false`.
  - `card_reused_track_and_hand_range` (values "(from track …)" and "(your choice)").
  - `card_batch_lists_tracks` (two tracks, one silent → two rows, the silent one with its problem text; done card holds the batch summary line; no key choices).
  - `card_find_again` (kind "again": title, step 1 only, done rows, the "Items already analyzed keep theirs." line; nothing-found and deleted-track outcomes close the card and post the existing status message).
  - `card_survives_a_vanished_item` (done card open, the item's take no longer resolves → `K.card_close(true)` with a changed choice writes nothing and closes).
  - `card_short_analysis_still_waits` (record covers the take: phase goes straight to "notes" then "done"; the card is open at "done").
  - `frame_error_closes_the_card` (`K.recover_after_error()` → `K.card == nil`).
  - `locked_reason_has_no_progress`, `more_menu_cancel_has_no_percent` (the format strings hold no `%d%%`).
  - `range_box_texts` (no item → "–"; unanalysed with Auto → "Auto"; unanalysed Tenor → "Tenor"; analysed Auto → "A3–F4"; analysed fixed → preset name; the three tooltips exact).
- [ ] **Step 2: Run the spec** — FAIL. Update or delete revision-1 tests that asserted the removed status messages / progress line, moving their facts to card assertions; list them in the report.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the spec and `luacheck .`** — PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(pitch-correct): analysis progress and results in one card; range shown in the top bar`

---

### Task 3: Words that changed

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (`K.INFO_NOTES` ~11234, the header's `@changelog` line), `CHANGELOG.md` (the v2.29.0 entry)
- Test: `docs/superpowers/tests/pitch_correct_spec.lua` (the Info test)

- [ ] **Step 1:** Rewrite the two `K.INFO_NOTES` sentences for revision 2 (Vocal Range on Auto hears the whole track once before its first analysis; the key is found the same way unless you pick one first; Find Range and Key Again in the "…" menu hears the track afresh and items already analyzed keep theirs) and adjust the Info test.
- [ ] **Step 2:** Rewrite the v2.29.0 `CHANGELOG.md` entry and the one-line `@changelog` so they describe revision 2: no Key "Auto" choice (found unless picked, shown as "–" until then), the range box in the top bar, the Analysis card (progress in the middle of the note window, results stay until OK, the other key candidate offered on a close call), Vocal Range "Auto", remembered per track, a corrected key follows the track, Find Range and Key Again. Remove the "Find Key" and "Progress: Finding range and key… NN%" bullets. No speed or accuracy claims. Version stays 2.29.0; no other header line changes.
- [ ] **Step 3:** Run the spec and `luacheck .` — PASS, 0 warnings.
- [ ] **Step 4: Commit** `docs(pitch-correct): release notes for the Analysis card and found keys`
