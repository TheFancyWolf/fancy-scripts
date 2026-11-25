# Pitch Correct Analysis Settings at the Analyze Button Implementation Plan

docs/design/pitch-correct-analyze-settings.md is Approved (2026-11-24, TheFancyWolf). Implement it exactly. Do not invoke skills.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Vocal Range, Detection Mode, Quality / CPU and the Advanced DSP values at the Analyze button. Analysis values changed there apply to that item only and are saved on it, so Re-Analyze reuses them. Settings keeps the defaults, and "Save as Default" copies the form into them.

**Architecture:**
- **The defaults stay where they are.** `state.min_freq`, `max_freq`, `threshold`, `block_size` and `hop_size` keep their ExtState persistence ("engine" group). From now on they mean "defaults" only.
- **The analysis form.** A new `state.analysis_form` holds the values for the next analysis of the target item. It is seeded from that item's stored `data.analysis`, or from the defaults.
- **Analysis reads its values from the caller.** `K.analysis_begin` takes them from `opts.values` instead of `state`. The finished analysis stores them in the take JSON as `analysis`, in the existing undo block.
- **Shared form rows.** The Settings detection and DSP rows are generalised to edit any value table, so the canvas form, the analysis modal and Settings draw the same rows.
- **The modal is the existing confirm.** `request_confirm` gains a `form` field, which draws the form at the top of the modal body.

**Tech Stack:** Lua 5.4, ReaScript API, ReaImGui 0.10, `_lib/theme.lua` (unchanged). Tests: plain Lua, `lua docs/superpowers/tests/pitch_correct_spec.lua` from the repo root.

**Spec:** `docs/design/pitch-correct-analyze-settings.md`. Read it in full before Task 1. The Feature inventory, Information architecture, Wireframes, State inventory, Interaction spec and Copy deck are binding. Its "Open questions / assumptions" were approved as written: unanalysed-item form edits are dropped on target switch; the batch modal seeds from the defaults; there is no migration.

## Global Constraints

- **Branch and commits.** Work on branch `pitch-correct-analyze-settings` (cut from `main` at `7f36bf4`; the design doc is commit `af1d876`). Never push. Commit once per task.
- **Test baseline.** One test fails before any change: `batch_copy` expects the tooltip without its paragraph break (stale since `4a8b367`). Task 1, Step 1 fixes the expectation; after that every task ends with all tests passing.
- **Analysis value keys, exactly:** `K.ANALYSIS_KEYS = { "min_freq", "max_freq", "threshold", "block_size", "hop_size" }`. Valid stored values:
  - `min_freq` and `max_freq` within `K.LIMITS`;
  - `threshold` within `K.LIMITS.threshold`;
  - `block_size` a member of `BLOCK_SIZES`;
  - `hop_size` a member of `HOP_SIZES` and ≤ `block_size`.
- **Form changes are never persisted.** Only Settings controls and the confirmed Save as Default call `K.save_settings("engine")`.
- **No new undo points.** The stored `analysis` rides in the existing analysis and batch undo blocks; labels stay "Analyze Pitch", the batch label and "Show Pitch Envelope".
- **No new chunk-level `local`** in `Pitch/Fancy_Pitch Correct.lua` (the chunk is near Lua's 200-local limit). New functions and tables go on `K`.
- **Copy.** User-facing strings come verbatim from the spec's Copy deck. "Custom" comes from `K.CUSTOM_PRESET`; "Locked while analyzing" from `K.LOCKED_REASON`.
- **House rules (AGENTS.md):**
  - call `reaper.X()` directly, and declare every variable `local`;
  - use tokens only (`Theme.layout`, the palette, `Theme.font_sizes`);
  - check every ReaImGui name you add with the `reaper-dev` tools (at least `ImGui_BeginChild`, `ImGui_ChildFlags_AutoResizeY`, `ImGui_Key_Enter`, `ImGui_Key_KeypadEnter`) — "not found" means don't use it (RB19);
  - never edit `index.xml`, `.github/workflows/` or `_fancy_*.json`;
  - `luacheck .` must be clean before every commit.
- **No new fakes.** Use no REAPER stand-in beyond the spec file's existing stub (`load_script`, `with_write_stubs`, `docs/superpowers/tests/reaper_stub.lua`).
- **Real-REAPER checks.** Follow `.agents/skills/reaper-screenshot/references/testing-protocol.md` and the memory note `reaper-real-testing-limits.md`: sweep strays before and after, screenshot, close. A failed or declined permission prompt means stop and tell the user.

## Review Focus

1. **An item analysed with Soprano is re-analysed after Settings changed to Bass.** The Re-Analyze modal shows Soprano ("as analyzed before"), not Bass. Test `form_seeds_from_item_not_defaults` (Task 2).
2. **Ctrl/Cmd+Z after a re-analysis.** It restores the old notes and the old stored `analysis`, and the form reseeds from the restored values, not the ones just used. Test `form_reseeds_when_stored_analysis_changes` (Task 2); checked live in Task 4.
3. **A stored `analysis` that is malformed** (hop > block, a block size not in the list, a string, Hz out of range) is treated as "not recorded", never used for an analysis. Test `analysis_values_rejects_bad` (Task 1).
4. **A batch started from the modal analyses every item with the modal's values,** even when Settings or the open item hold others, and every item stores those values. Test `batch_uses_and_stores_modal_values` (Task 5).
5. **Settings changed while the canvas form shows an unanalysed item.** The unchanged rows of the form follow the new defaults, and the rows the user changed keep their values. Test `form_follows_defaults_for_untouched_rows` (Task 2).

---

### Task 1: The item remembers the values it was analysed with

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`:
  - `K.analysis_begin` (~1688);
  - `start_analysis` (~1751);
  - the take data built at the end of `process_analysis_step` (~5336);
  - `K.take_json` (~2465);
  - `load_take_data` (~2542);
  - the `FANCY_PITCH_TEST` export (~14223), which adds nothing (everything new is on `K`).
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Produces:
  - `K.ANALYSIS_KEYS` (above);
  - `K.analysis_defaults() -> values` (a fresh table of the five keys copied from `state`);
  - `K.analysis_values(t) -> values | nil` (a validated copy of `t`'s five keys, or nil when any is missing or invalid per Global Constraints);
  - `K.analysis_begin(take, item, opts)`, with new `opts.values` (a values table; omitted means `K.analysis_defaults()`);
  - take data field `data.analysis` (a values table), written by `K.take_json` and kept by `load_take_data` only when `K.analysis_values` accepts it (else `data.analysis = nil`);
  - `start_analysis(values)` (values optional, passed through as `opts.values`).

- [ ] **Step 1: Fix the stale baseline test.** In `batch_copy` (spec line ~2489), expect `"Detect the pitch of the 12 selected audio items, one after another.\n\nOne undo step for all of them."`. Run `lua docs/superpowers/tests/pitch_correct_spec.lua`. Expected: no FAIL line.

- [ ] **Step 2: Write the failing tests**

```lua
test("analysis_defaults_copies_state", function()
  local d = S.K.analysis_defaults()
  eq(d.min_freq, S.state.min_freq); eq(d.hop_size, S.state.hop_size)
  d.min_freq = 1; eq(S.state.min_freq ~= 1, true, "a copy, not state")
end)
test("analysis_values_accepts_good", function()
  local v = S.K.analysis_values({ min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 })
  eq(v.max_freq, 1200); eq(v.block_size, 2048)
end)
test("analysis_values_rejects_bad", function()
  local K = S.K
  eq(K.analysis_values(nil), nil)
  eq(K.analysis_values({ min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 512, hop_size = 1024 }), nil, "hop > block")
  eq(K.analysis_values({ min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 1000, hop_size = 256 }), nil, "block not listed")
  eq(K.analysis_values({ min_freq = "250", max_freq = 1200, threshold = 0.25, block_size = 1024, hop_size = 256 }), nil, "string")
  eq(K.analysis_values({ min_freq = 5, max_freq = 1200, threshold = 0.25, block_size = 1024, hop_size = 256 }), nil, "Hz below limit")
end)
test("take_json_round_trips_analysis", function()
  local v = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 }
  local json = S.K.take_json({ guid = "{a}", results = {}, notes = {}, analysis = v })
  eq(json:find('"analysis"') ~= nil, true)
end)
test("analysis_begin_snapshots_opts_values", function()
  -- stubs: CreateTakeAudioAccessor -> "acc", new_array -> {}, GetTakeName -> "t"; opts.sample_rate = 48000, defer_envelope = true
  -- call K.analysis_begin("take", "item", { sample_rate = 48000, defer_envelope = true, values = <Soprano values, block 2048 hop 256> })
  -- expect state.analysis_params.min_freq == 250, .block_size == 2048, and state.min_freq unchanged (the default)
end)
```

The last test's body follows the comments, using the stub pattern of `with_write_stubs`; restore every stubbed name afterwards. Also add a load test, `load_take_data_drops_bad_analysis`: a stored JSON whose `analysis` has hop > block loads with `data.analysis == nil`, and a good one loads unchanged.

- [ ] **Step 3: Run the tests.** Run `lua docs/superpowers/tests/pitch_correct_spec.lua`. Expected: the new tests FAIL (`K.analysis_defaults` is nil).

- [ ] **Step 4: Implement.**
  - `K.analysis_begin` builds `state.analysis_params` from `opts.values or K.analysis_defaults()`, with the existing block/hop clamp applied to the snapshot. It no longer writes `state.block_size` or `state.hop_size`.
  - `process_analysis_step` sets `take_data.analysis = params` (the frozen snapshot, five keys only).
  - `K.take_json` writes `analysis = data.analysis`.
  - `load_take_data` replaces `data.analysis` with `K.analysis_values(data.analysis)`.

- [ ] **Step 5: Run the tests and luacheck.** Run `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`. Expected: no FAIL line; `0 warnings / 0 errors`.

- [ ] **Step 6: Commit.** Message: `feat(pitch-correct): store the analysis values on the item`.

### Task 2: The analysis form model

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`:
  - `state` (~240, add `analysis_form = nil`);
  - new functions on `K` next to `K.analysis_begin`;
  - `switch_active_target` (~3107) and `sync_with_project` (~3161) call `K.form_sync`.
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.analysis_defaults`, `K.analysis_values`, `data.analysis` (Task 1).
- Produces:
  - `state.analysis_form = { guid, values, edited = { [key] = true }, source, seed }`.
    - `source` is `"item"` (seeded from `data.analysis`), `"unrecorded"` (the item has notes but no stored analysis) or `"defaults"` (unanalysed item, or a batch).
    - `seed` is the `data.analysis` table it was seeded from (identity compare).
  - `K.form_new(guid, data) -> form` (a fresh seed; `guid` may be `"batch"`, with `data` nil).
  - `K.form_sync(guid, data)`: reseeds `state.analysis_form` when `guid` differs from the form's, or `data.analysis` is not the form's `seed` (an undo replaced it). Otherwise it copies the defaults into every key not in `form.edited` while `source ~= "item"`.
  - `K.form_set(form, key, value)`: sets the value and marks it edited, both for `min_freq` and `max_freq` when a range preset is picked.
  - `K.form_reset_row(form, row_id)`, where `row_id` is one of `"range"`, `"mode"`, `"quality"`, `"block"`, `"hop"`, `"threshold"`, `"min_freq"`, `"max_freq"`: copies the default(s) back and clears edited.
  - `K.form_changed_rows(values) -> 0..3`: the count of Vocal Range (`min_freq` or `max_freq`), Detection Mode (`threshold`) and Quality (`block_size` or `hop_size`) rows that differ from `K.analysis_defaults()`.
  - `K.form_header(form) -> string`: `"ANALYZE WITH · as analyzed before"` (item), `"ANALYZE WITH · not recorded, your defaults"` (unrecorded), `"ANALYZE WITH · your defaults"` (defaults, 0 changed). With 1+ changed and source defaults: `"ANALYZE WITH · 1 changed from defaults"` / `"· 2 changed from defaults"`.
  - `K.form_summary(values) -> string`: `"Soprano · Clean / Strict · Standard (Realtime)"`, with `K.CUSTOM_PRESET` for a part that matches no preset.
  - `K.analyzed_with_tip(data) -> string | nil`: `"Analyzed with " .. K.form_summary(data.analysis)`, or nil without `data.analysis`.
  - `K.form_defaults_request(values) -> req`: a `request_confirm` request.
    - `title`: `"Make these your defaults?"`.
    - `body_lines`: `"New analyses will start with: <changed parts as 'New (was Old)', joined by ', '>."` and `"Items already analyzed keep their own settings."`.
    - `confirm_label`: `"Save as Default"`.
    - `on_confirm`: copies the five values into `state`, then `K.save_settings("engine")`, then `set_status("Defaults saved.")`.

- [ ] **Step 1: Write the failing tests**

```lua
test("form_seeds_from_item_not_defaults", function()
  local f = S.K.form_new("{a}", { notes = { {} }, analysis = <Soprano values> })
  eq(f.source, "item"); eq(f.values.min_freq, 250)
  eq(S.K.form_header(f), "ANALYZE WITH · as analyzed before")
end)
test("form_unrecorded_item_uses_defaults", function()
  local f = S.K.form_new("{a}", { notes = { {} } })
  eq(f.source, "unrecorded"); eq(f.values.min_freq, S.state.min_freq)
  eq(S.K.form_header(f), "ANALYZE WITH · not recorded, your defaults")
end)
test("form_reseeds_when_stored_analysis_changes", function()
  -- form_sync("{a}", d1); K.form_set(form, "threshold", 0.25); form_sync("{a}", d1) keeps 0.25;
  -- form_sync("{a}", d2) with d2.analysis a different table -> values from d2.analysis, edited empty
end)
test("form_follows_defaults_for_untouched_rows", function()
  -- unanalysed: form_sync("{b}", nil); K.form_set(form, "threshold", 0.25); state.min_freq = 80 (Bass);
  -- form_sync("{b}", nil) -> form.values.min_freq == 80, threshold still 0.25; restore state.min_freq
end)
test("form_changed_rows_counts_rows_not_keys", function()
  local v = S.K.analysis_defaults(); v.min_freq, v.max_freq = 250, 1200
  eq(S.K.form_changed_rows(v), 1)
  v.threshold = 0.25; eq(S.K.form_changed_rows(v), 2)
end)
test("form_summary_names_presets_and_custom", function()
  local v = S.K.analysis_defaults()
  eq(S.K.form_summary(v), "Generic Vocal · Clean / Strict · Standard (Realtime)")
  v.max_freq = 999; eq(S.K.form_summary(v):match("^Custom") ~= nil, true)
end)
test("form_defaults_request_names_changes", function()
  local v = S.K.analysis_defaults(); v.min_freq, v.max_freq = 250, 1200
  local req = S.K.form_defaults_request(v)
  eq(req.title, "Make these your defaults?")
  eq(req.body_lines[1], "New analyses will start with: Soprano (was Generic Vocal).")
  eq(req.confirm_label, "Save as Default")
end)
```

Spell out the commented bodies from their comments. Every test restores any `state` value it changes.

- [ ] **Step 2: Run the tests.** Run `lua docs/superpowers/tests/pitch_correct_spec.lua`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement** the Produces list. Call `K.form_sync(guid, state.session_takes[guid])`:
  - at the end of `switch_active_target`;
  - in `sync_with_project`, after the model reload;
  - from the frame loop when `state.analysis_form` is nil or its guid differs from `state.target_take_guid` (no per-frame work otherwise: HI5).

- [ ] **Step 4: Run the tests and luacheck.** Expected: no FAIL line, luacheck clean.

- [ ] **Step 5: Commit.** Message: `feat(pitch-correct): analysis form model (per item, seeded from defaults)`.

### Task 3: Shared form rows; Settings becomes "Analysis Defaults"

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`:
  - `settings_drag` (~10491);
  - `K.SETTINGS_SECTIONS` detection and dsp rows (~10576–10670);
  - `draw_settings_modal` (~10748).
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: `K.form_set`, `K.form_reset_row` (Task 2).
- Produces:
  - **Row signatures.** Detection and dsp rows take a binding `b = { v = <values table>, base = <defaults table>, set = fn(key, value), reset = fn(row_id), commit = fn() }`. The row functions become `is_default(b)`, `reset(b)` and `draw(w, b)`; `reset(b)` calls `b.reset(row.id)`.
  - **Settings binding:** `K.settings_binding()`, with `v = state`, `base = DEFAULTS`, `set` writing `state`, `reset` restoring from `DEFAULTS`, and `commit = function() K.save_settings("engine") end`.
  - **Form binding:** `K.form_binding(form)`, with `v = form.values`, `base = K.analysis_defaults()`, `set = K.form_set`, `reset = K.form_reset_row`, and a no-op `commit`.
  - `settings_drag(id, key, fmt, width, b)`: double-click resets to `b.base[key]`, and a release calls `b.commit()`.
  - `K.form_rows_draw(section, b, opts)`: the existing `draw_form` body lifted out of `draw_settings_modal`.
    - `opts = { locked, stacked, label_w, control_w, reset_w, reset_hint }`.
    - `stacked`: label above control, and the control takes the width left after Reset.
    - The Settings modal calls it with `reset_hint` "Restore the default value"; the form calls it with "Back to your default (from Settings)". The disabled reason is "Already the default" for the form and the existing text for Settings.
  - **Settings section copy.** Rename the detection section title to `"Analysis Defaults"`. Under its divider, draw the dim line `"New analyses start with these. Each item keeps the settings it was analyzed with."`.
  - **New tooltips.** Use the spec Copy deck's Vocal Range, Detection Mode and Quality / CPU tooltips for both the Settings and the form rows.

- [ ] **Step 1: Write the failing tests**

```lua
test("rows_edit_the_bound_table", function()
  local form = S.K.form_new("batch", nil)
  local b = S.K.form_binding(form)
  local range = <the row with id "range" in S.K.SETTINGS_SECTIONS[2].rows>
  b.set("min_freq", 250); b.set("max_freq", 1200)
  eq(range.is_default(b), false); eq(S.state.min_freq ~= 250, true, "state untouched")
  range.reset(b); eq(range.is_default(b), true); eq(form.edited.min_freq, nil)
end)
test("settings_binding_resets_to_factory", function()
  -- b = K.settings_binding(); state.threshold = 0.25; threshold row reset(b) -> state.threshold == DEFAULTS.threshold
end)
test("settings_section_renamed", function() eq(S.K.SETTINGS_SECTIONS[2].title, "Analysis Defaults") end)
```

- [ ] **Step 2: Run the tests.** Expected: the new tests FAIL.

- [ ] **Step 3: Implement** the Produces list. The Settings modal keeps its look: same columns, Reset, Reset section and Advanced DSP header. `K.request_settings_reset` walks the rows with `K.settings_binding()`.

- [ ] **Step 4: Run the tests and luacheck.** Expected: no FAIL line, luacheck clean.

- [ ] **Step 5: Live check.** Follow the protocol. Open Settings and take a screenshot. Expected: the "ANALYSIS DEFAULTS" divider, the explanation line, and the rows as before. Change Vocal Range, then Reset, then Reset section (confirm, Cancel); the behaviour should be unchanged. Close Settings and the window, then sweep strays.

- [ ] **Step 6: Commit.** Message: `refactor(pitch-correct): settings rows edit any value table; Analysis Defaults`.

### Task 4: The "Analyze with" form on the empty canvas

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`, the empty-canvas branch of `draw_graph` (~6774–6845), plus a new `K.form_canvas_draw`.
- Test: `docs/superpowers/tests/pitch_correct_spec.lua` (layout choice only)

**Interfaces:**
- Consumes: Tasks 1–3 (`state.analysis_form`, `K.form_binding`, `K.form_rows_draw`, `K.form_header`, `K.form_summary`, `K.form_defaults_request`, `start_analysis(values)`).
- Produces:
  - `K.form_layout(avail_w, avail_h, need) -> "full" | "stacked" | "summary"`.
    - `need = { row_w, stacked_w, full_h, stacked_h, button_h }`.
    - Returns `"full"` when `avail_w >= row_w` and `avail_h >= full_h + button_h`.
    - Else `"stacked"` when `avail_h >= stacked_h + button_h`.
    - Else `"summary"`.
  - `K.form_canvas_draw(form, x, y, w, layout) -> h`: draws the header, the rows and the Advanced fold, then Save as Default right-aligned. Returns the height used.
    - The form is a child window (`ImGui_BeginChild` with `ChildFlags_AutoResizeY`) placed over the canvas, allowed to overlap like `canvas_button`.
    - Save as Default is disabled when `K.form_changed_rows(form.values) == 0`. While disabled, its place shows the dim text "Matches your defaults" instead (EP2 inline).
    - Clicking Save as Default calls `request_confirm(K.form_defaults_request(form.values))`.
    - While `state.is_analyzing`, everything is inside `BeginDisabled`, and the inline reason `K.LOCKED_REASON` sits under the header.
  - **Unanalysed canvas.** Draw the form above the Analyze button, separated by `L.lg` (LG1). The button calls `start_analysis(form.values)`, or `K.batch_request(form.values)` for a batch (signature in Task 5). The hint lines stay under the button and drop first when height runs out, as today.
  - **No-notes canvas.** The hint becomes `"Try another Vocal Range or Detection Mode."`. The form sits under it, then a `K.ANALYZE_BTN` button "Re-Analyze" calling `start_analysis(form.values)`, replacing "Open Settings".
  - **Summary layout.** One line: dim `"Analyze with: " .. K.form_summary(values)`, truncated with a tooltip; then `"Change…"` (`###change`), which opens the Task 5 modal in its "analyze" variant; then the Analyze button, all on the button's row.

- [ ] **Step 1: Write the failing test.** `form_layout_picks_by_space` asserts `"full"`, `"stacked"` and `"summary"` for three sizes from one `need` table (for example `need = { row_w = 400, stacked_w = 200, full_h = 120, stacked_h = 200, button_h = 40 }`):
  - (600, 300) gives `"full"`;
  - (250, 300) gives `"stacked"`;
  - (1200, 110) gives `"summary"`.

- [ ] **Step 2: Run the tests.** Expected: FAIL.

- [ ] **Step 3: Implement** the Produces list. Measure `need` from the fonts in use (`CalcTextSize`, `Theme.calc_combo_width`, `GetFrameHeightWithSpacing`). Cache it per font size, not per frame.

- [ ] **Step 4: Run the tests and luacheck.** Expected: no FAIL line, luacheck clean.

- [ ] **Step 5: Live check.** Follow the protocol. In each case, take a screenshot and say what you saw.
  1. Floating, unanalysed item, default size: the form, then the button, then the hints.
  2. Pick Soprano: the header reads "1 changed from defaults", Reset is enabled, Save as Default is enabled.
  3. Analyze. After it finishes, open the take's stored data with the bridge (`P_EXT:fancy_pitch_data`) and check that `"analysis"` holds `min_freq` 250.
  4. Ctrl/Cmd+Z: the item is back to unanalysed, with no stored analysis.
  5. Dock the window narrow (~260 px): stacked rows.
  6. Resize it to a short strip: the summary line with Change….
  7. Fancy Dark and Match Theme.

  Close and sweep.

- [ ] **Step 6: Commit.** Message: `feat(pitch-correct): Analyze with form on the empty canvas`.

### Task 5: Analysis modal: Re-Analyze…, Analyze Selected Items (N)…, Change…

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua`:
  - `request_confirm` (~698) and `draw_confirm_modal` (~11226);
  - `K.request_analyze` (~11504);
  - `K.batch_request` (~11543), `K.batch_start` (~3086) and `K.batch_next` (~3014);
  - `hdr_draw_more` (~12705) and the `analyze_label` (~12837);
  - `K.INFO_SECTIONS` (~9657).
- Test: `docs/superpowers/tests/pitch_correct_spec.lua`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - **`request_confirm` gains `req.form`** (an analysis form). When it is set:
    - `draw_confirm_modal` draws `K.form_rows_draw` for the detection rows, then the Advanced fold (`Theme.collapsing_header`), then Save as Default, all above `body_lines`, with the header from `K.form_header`;
    - Enter or KeypadEnter, via `reaper.ImGui_Shortcut`, runs the primary when no item is active;
    - `on_confirm` receives `form.values`;
    - the modal stays fitted to the parent through the existing `fit` / `K.fit_modal` path (RB9).
  - **`K.reanalyze_request(edited, name, form) -> req`**:
    - `title`: `string.format("Re-analyze %s?", name)`;
    - `form`: a copy of `form` (edits in the modal never touch the canvas form);
    - `body_lines`: the existing three lines when `edited > 0`, otherwise only `K.REANALYZE_VALUES_LINE`;
    - `confirm_label`: `"Re-Analyze"`, with `fit = true`.
    - `K.request_analyze` always uses it on an analysed item. On an unanalysed item it runs `start_analysis(state.analysis_form.values)` directly, with no modal.
  - **`K.batch_request(values)`.** With `values` (the canvas button), it behaves as today and passes `values` to `K.batch_start`. Without `values` ("…" menu), it opens a modal built by `K.batch_modal_request(sel_takes) -> req`:
    - `title`: `string.format("Analyze %d items", n)`;
    - `form`: `K.form_new("batch", nil)`;
    - the `body_lines` and `list` that `K.batch_confirm` would give, when any item has notes;
    - `confirm_label`: `string.format("Analyze %d Items", n)`;
    - `on_confirm(values)` calls `K.batch_start(sel_takes, values)`.
  - **`K.batch_start(entries, values)`** stores `K.batch.values = values or K.analysis_defaults()`, and `K.batch_next` passes `values = K.batch.values` to `K.analysis_begin`.
  - **`K.analyze_change_request() -> req`** (the summary layout's Change…):
    - `title`: `string.format("Analyze %s", name)`;
    - `form`: a copy of the canvas form;
    - `confirm_label`: `"Analyze"`;
    - `on_confirm(values)` copies `values` into `state.analysis_form` (marking the changed keys edited) and then runs `start_analysis(values)`.
  - **Menu labels and tooltips:**
    - "…" reads `"Re-Analyze…"` on an analysed item and `"Analyze"` otherwise, and `"Analyze Selected Items (N)…"` when the batch is enabled.
    - The Re-Analyze… tooltip is `K.analyzed_with_tip(data)`.
    - The disabled reasons stay as they are.
  - **Info modal (HP1).** Add the row `"Re-Analyze… opens the analysis settings; Enter analyzes, Esc cancels"` to the Analyze section of `K.INFO_SECTIONS`.

- [ ] **Step 1: Write the failing tests**

```lua
test("reanalyze_request_carries_form_copy", function()
  local f = S.K.form_new("{a}", { notes = { {} }, analysis = <Soprano values> })
  local req = S.K.reanalyze_request(4, "Lead Vox", f)
  eq(req.title, "Re-analyze Lead Vox?"); eq(req.confirm_label, "Re-Analyze")
  eq(req.form ~= f, true); eq(req.form.values.min_freq, 250)
  eq(#req.body_lines, 3)
  eq(#S.K.reanalyze_request(0, "Lead Vox", f).body_lines, 1)
end)
test("batch_modal_request_titles_and_seeds_defaults", function()
  -- two fake entries without notes -> title "Analyze 2 items", confirm "Analyze 2 Items", form.source "defaults"
end)
test("batch_uses_and_stores_modal_values", function()
  -- with stubs as in analysis_begin_snapshots_opts_values: K.batch_start(entries, <Soprano values>);
  -- state.analysis_params.min_freq == 250 for the first item; K.batch.values.min_freq == 250; state.min_freq unchanged
  -- cancel the batch (K.cancel_analysis) and restore stubs
end)
test("confirm_enter_runs_primary_only_with_form", function()
  -- a request without form: no Enter handling (existing confirms unchanged); assert via a flag K.confirm_enter(c) -> bool
end)
```

For the last test, expose `K.confirm_enter(c) -> boolean` (true only when `c.form` is set), and use it inside `draw_confirm_modal`.

- [ ] **Step 2: Run the tests.** Expected: the new tests FAIL.

- [ ] **Step 3: Implement** the Produces list.

- [ ] **Step 4: Run the tests and luacheck.** Expected: no FAIL line, luacheck clean.

- [ ] **Step 5: Live check.** Follow the protocol, with a screenshot each time.
  1. On an item analysed with Soprano, change Settings to Bass, then open "…" → Re-Analyze…. Expected: Soprano, with "as analyzed before".
  2. Edit a note, then Re-Analyze…: the discard lines show; Esc cancels and nothing changes.
  3. Select 3 items, open "…" → Analyze Selected Items (3)…, pick Tenor, then Analyze 3 Items. Then check that each take's `analysis.min_freq` is 130.
  4. Ctrl/Cmd+Z: all three are restored.
  5. Docked narrow: the modal stays inside the window.
  6. Save as Default from the modal: the confirm appears, then the Settings rows show the new defaults.
  7. Restore the factory defaults afterwards with Reset section.

  Close and sweep.

- [ ] **Step 6: Commit.** Message: `feat(pitch-correct): analysis modal for Re-Analyze and batches`.

### Task 6: Version, changelog, final pass

**Files:**
- Modify: `Pitch/Fancy_Pitch Correct.lua` (header `@version 2.25.0` → `2.26.0`, plus a `@changelog` entry) and `CHANGELOG.md` (under `[Unreleased]`, newest first).

- [ ] **Step 1: Bump the version and write the changelog.** The entry is in the user's terms, in the house style of the 2.25.0 entry. Its bullets:
  - "Analyze with" at the button;
  - each item remembers its analysis settings;
  - Re-Analyze… opens them;
  - Analyze Selected Items (N)… sets one set for all;
  - Save as Default;
  - Settings section renamed "Analysis Defaults".

- [ ] **Step 2: Run the full suite and luacheck.** Run `lua docs/superpowers/tests/pitch_correct_spec.lua && luacheck .`. Expected: no FAIL line, luacheck clean.

- [ ] **Step 3: Final live pass.** Walk the spec's Acceptance criteria that need a screen (ST3 lock while analysing, LG4 three layouts, CL4 both theme modes, HC5 Esc order, HC6 Space with no modal open). Say what you saw, and what could not be checked.

- [ ] **Step 4: Commit.** Message: `chore(pitch-correct): v2.26.0 changelog for analysis settings at the button`.
