# Design: Fancy Pitch Correct — Analysis Settings at the Analyze Button

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); the new "Analyze with" form on the empty canvas → part of the canvas (Editor / canvas); the Analyze / Re-Analyze / Analyze Selected Items modal and the Save as Default confirm → the window's modal family (Editor / canvas)
Status: Approved
Date: 2026-11-24
Approver: TheFancyWolf (in chat, 2026-11-24)

## Summary

Today every analysis silently uses the Vocal Range, Detection Mode, Quality and Advanced DSP values in Settings, and the item does not remember which values it was analysed with, so Re-Analyze may use different values than the first pass. This design puts those choices next to the action: the empty canvas shows an "Analyze with" form above the Analyze button, and Re-Analyze and Analyze Selected Items open a small modal holding the same form. Settings keeps the values as **defaults** ("Analysis Defaults"); a value changed at the button applies to that analysis only, is saved on the item with its notes, and is reused when the item is re-analysed. "Save as Default" copies the form into Settings. The window's primary display (the note canvas) and primary action (dragging a note) do not change; on the empty canvas the primary action stays Analyze.

### How other apps solve it (research behind the model)

| Pattern | Apps | Fit for us |
|---|---|---|
| Settings beside the action, last choice sticky | Auto-Tune Pro (Input Type in the main view), REAPER Render and Dynamic Split dialogs | Good placement; but a one-off tweak silently becomes everyone's setting |
| A saved default plus presets | Revoice Pro (factory "Default" preset per process, user can save a default) | Gives us "Save as Default" and the Settings role |
| The object remembers what it was processed with | Revoice Pro (reuses the settings of the last same process), Melodyne (detection algorithm per clip) | Gives us per-item settings reused by Re-Analyze |

Chosen at checkpoint 2b: defaults in Settings + per-item override saved on the item (combination of rows 2 and 3, placed as in row 1).

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Change a value in the "Analyze with" form (Vocal Range, Detection Mode, Quality / CPU; Advanced: block, hop, threshold, min / max Hz) | the target take's stored analysis settings | nothing | none (an in-memory working copy for the target item; see Open questions) | n/a: nothing is written |
| Row Reset in the form (back to the default) | Settings defaults | nothing | none | n/a: nothing is written |
| Analyze Item (canvas button; "…" → Analyze) with the form's values | the target take's audio, the form | the take's note model and, new, its analysis settings (`analysis` in the take JSON), pitch envelope as today | take data (`P_EXT`) inside the existing undo block | Y: the settings ride in the same `P_EXT` write as the notes, inside the same undo block; the model reloads on `GetProjectStateChangeCount` |
| Re-Analyze… ("…" menu, and the "No pitched notes found" canvas) → modal with the form seeded from the item's stored settings | the take's stored settings and notes | as Analyze; replaces the notes and the stored settings | take data inside the undo block | Y: same block; Ctrl/Cmd+Z brings back the old notes and the old stored settings (the form reseeds from them) |
| Analyze All Selected Items (canvas) / Analyze Selected Items (N)… ("…" → modal) with one set of values for all | the arrange selection, each take's audio | per item: notes + the same analysis settings, in the batch's one undo block | take data inside the undo block | Y: unchanged batch behaviour plus the settings field |
| Save as Default (form and modal) | the form | ExtState `pitch_threshold`, `pitch_min_freq`, `pitch_max_freq`, `pitch_block_size`, `pitch_hop_size` (existing keys) | ExtState | N: ExtState is outside undo → confirm modal naming what changes (HC4) |
| Settings → Analysis Defaults (renamed section; same controls, Reset, Reset section, Advanced DSP) | ExtState | ExtState (existing) | ExtState | N: unchanged (edits save on change; Reset section already confirms) |
| Show what an item was analysed with ("…" → Re-Analyze… tooltip; the modal) | the take's stored settings | nothing | none | n/a |

## References

- Native REAPER analogues: the **Render to File** and **Dynamic Split** dialogs (settings sit above the action button, the dialog opens with the values it will use, the action button is bottom-right, Cancel/Esc closes without changes); REAPER's right-click context menus. Conventions matched (CN6): Hz shown with units, discrete choices as combos, no Alt/Shift repurposing; dB and pan do not appear here.
- Redesigns only: baseline capture: code-only plus the user's screenshot of Settings → Analysis & Detection Presets (2026-11-24); no live capture taken for this doc. `ds-lint.py` summary: not available — the linter stops with "theme.lua palette drifted from ds-lint's port of build_palette" (a tooling issue, recorded under Open questions).

## Context and job stories

Confirmed at 2b: lives in the existing Pitch Correct window, floating or docked; used a few times per project; playback may be running; mostly mouse.

1. When a new singer's take turns up mid-session, I want to pick their Vocal Range right where I press Analyze, so the first pass is right without a detour into Settings.
2. When an analysis found no notes or jumped octaves, I want to change the range or mode and re-analyse from the canvas, so the fix is one move.
3. When I re-analyse an item days later, I want it to start from the settings it was analysed with, so the result does not change behind my back.
4. When I batch-analyse a stack of takes from one singer (docked under the arrange, playback looping), I want to set the values once for all of them.
5. When most of my work is one voice type, I want to make that the default once and stop thinking about it.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | On the empty canvas: Analyze button, Vocal Range, Detection Mode, Quality / CPU, a "changed from defaults" count | Every first analysis; range is the most common reason an analysis fails |
| 2 one disclosure away | Advanced (block, hop, threshold, min / max Hz) folded under the form; Save as Default; per-row Reset; the Re-Analyze / batch modal | Occasional tuning; re-analysis is occasional |
| 3 Settings | Analysis Defaults (the same controls as defaults) and Advanced DSP defaults | Set once |

## Information architecture

Regions:

1. **Empty canvas, not analysed** (existing region, reorganised, top to bottom): section label "Analyze with" + changed count → form (3 rows: label | combo | Reset) → "Advanced" collapsing header (level 1 disclosure, closed by default; same row layout) → Save as Default (small text button, right-aligned under the form) → the Analyze Item / Analyze All Selected Items button (large accent, unchanged) → the existing hint lines.
2. **Empty canvas, analysed, no notes found**: title "No pitched notes found" → hint → the same form seeded from the item's stored settings → **Re-Analyze** (accent) in place of "Open Settings".
3. **Analysis modal** (one modal, three titles): "Re-analyze <item>?" / "Analyze <N> items" / "Analyze <item>" — the form, the Advanced fold, Save as Default, then the consequence lines (edits discarded, items that already have notes, values back to defaults), then Cancel | primary.
4. **Settings → "Analysis Defaults"** (renamed from "Analysis & Detection Presets"): a one-line explanation under the divider; rows unchanged; "Advanced DSP Parameters" stays its collapsing header.
5. **"…" menu**: "Analyze" (no ellipsis, runs with the canvas form's values) on an unanalysed item; "Re-Analyze…" (opens the modal) on an analysed item; "Analyze Selected Items (N)…" (opens the modal).

Primary display: the note canvas. Primary action of the empty canvas: Analyze. Disclosure: form → Advanced (1 level on the canvas; modal → Advanced = 2 levels, IA2 OK).

## Wireframes

### Default floating size, empty canvas, not analysed

```
┌ PITCH CORRECT ─────────────────────────────────── … ─┐
│ ┌──────────────────────────────────────────────────┐ │
│ │                                                  │ │
│ │        ANALYZE WITH · 1 changed from defaults    │ │
│ │   Vocal Range     [Soprano             ▾] [Reset]│ │
│ │   Detection Mode  [Clean / Strict      ▾] [Reset]│ │  ← Reset disabled: "Already the default"
│ │   Quality / CPU   [Standard (Realtime) ▾] [Reset]│ │
│ │   ▸ Advanced                     Save as Default │ │
│ │                                                  │ │
│ │            ┏━━━━━━━━━━━━━━━━━━━━━━━┓             │ │
│ │            ┃      Analyze Item      ┃             │ │
│ │            ┗━━━━━━━━━━━━━━━━━━━━━━━┛             │ │
│ │   No data. Select an item and click Analyze.     │ │
│ │ Select several items in REAPER to analyze them…  │ │
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

Advanced open (pushes the button down; the canvas scrolls nothing, the hint lines drop first when height runs out):

```
│   ▾ Advanced                                       │
│     Block size (samples)  [1024 ▾]        [Reset]  │
│     Hop size (samples)    [512  ▾]        [Reset]  │
│     Detection Threshold   [ 0.08 ]        [Reset]  │
│     Min Freq (Hz)         [250 Hz]        [Reset]  │
│     Max Freq (Hz)         [1200 Hz]       [Reset]  │
```

### No pitched notes found (analysed)

```
│              No pitched notes found               │
│   Try another Vocal Range or Detection Mode.      │
│   Vocal Range     [Generic Vocal       ▾] [Reset] │
│   Detection Mode  [Clean / Strict      ▾] [Reset] │
│   Quality / CPU   [Standard (Realtime) ▾] [Reset] │
│   ▸ Advanced                     Save as Default  │
│              ┏━━━━━━━━━━━━━━━━━┓                  │
│              ┃   Re-Analyze    ┃                  │
│              ┗━━━━━━━━━━━━━━━━━┛                  │
```

### Analysis modal (Re-Analyze…, item with edited notes)

```
┌ Re-analyze Lead Vox take 3? ──────────────────────┐
│ ANALYZE WITH · as analyzed before                 │
│ Vocal Range     [Soprano             ▾] [Reset]   │
│ Detection Mode  [Breathy / Lenient   ▾] [Reset]   │
│ Quality / CPU   [Standard (Realtime) ▾] [Reset]   │
│ ▸ Advanced                       Save as Default  │
│ ───────────────────────────────────────────────── │
│ This replaces the detected notes and discards     │
│ your edits to 4 notes.                            │
│ Its values go back to the defaults; Key and Scale │
│ stay. Cmd+Z restores them once the analysis has   │
│ finished.                                         │
│                          [ Cancel ] [ Re-Analyze ]│
└───────────────────────────────────────────────────┘
```

Batch variant: title "Analyze 5 items", header line "ANALYZE WITH · your defaults" (seeded from defaults), then the existing batch lines ("2 already have notes…" and their list), primary "Analyze 5 Items". Single unanalysed item from "…" has no modal (it runs with the canvas form's values, which are on screen).

### Narrow docker (~260 px)

```
┌ PITCH CORRECT ─ … ┐
│ ANALYZE WITH      │
│ 1 changed         │
│ Vocal Range       │
│ [Soprano ▾][Reset]│
│ Detection Mode    │
│ [Clean /…▾][Reset]│   ← combo text truncates, tooltip shows the full name
│ Quality / CPU     │
│ [Standar…▾][Reset]│
│ ▸ Advanced        │
│ Save as Default   │
│ ┏━━━━━━━━━━━━━━━┓ │
│ ┃  Analyze Item ┃ │
│ ┗━━━━━━━━━━━━━━━┛ │
└───────────────────┘
```

Below the width that fits label | combo | Reset on one line, each label sits above its combo; Reset keeps its text and the combo takes the remaining width. The modal at this width is sized by `K.fit_modal` to the parent and stacks the same way (RB9: never wider than the parent).

### Wide short strip (1200 × 150)

The form does not fit in the canvas height: it collapses to one summary line beside the button.

```
┌ PITCH CORRECT ───────────────────────────────────────────────────────────────────────── … ┐
│  Analyze with: Soprano · Clean / Strict · Standard (Realtime)  [Change…]  ┏ Analyze Item ┓ │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

"Change…" opens the analysis modal in its "Analyze <item>" variant. The summary truncates from the right with a tooltip holding the full text (LG4).

### Settings → Analysis Defaults

```
ANALYSIS DEFAULTS
New analyses start with these. Each item keeps the settings it was analyzed with.
Vocal Range      [Generic Vocal        ▾] [Reset]
Detection Mode   [Clean / Strict       ▾] [Reset]
Quality / CPU    [Standard (Realtime)  ▾] [Reset]
                 [Reset section]
▸ Advanced DSP Parameters
```

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Canvas form | empty | No item: the form is shown disabled with reason "Select an audio item in REAPER to analyze it." (existing tip, now also inline as the hint line) | ST6 |
| Canvas form | working | While analysing, the form and Save as Default are disabled with the inline reason "Locked while analyzing"; the "…" button shows the % as today | ST3 |
| Canvas form | error | Analysis fails to start: existing status "Couldn't read this item's audio…"; the form keeps its values so Retry is one click | ST7 |
| Canvas form | disabled with reason | Row Reset disabled: tooltip "Already the default"; Save as Default disabled: inline text "Matches your defaults" in its place | EP2 |
| Canvas form | overflow / long names | Combo text truncates with tooltip; narrow layout stacks label above combo; short canvas collapses to the summary line + Change… | LG4 |
| Canvas form | missing dependency | n/a: no SWS / js dependency; ReaImGui check is the script's existing header check | HI7 |
| Canvas form | Fancy Dark / Match Theme | The form sits on the canvas `bg`; combos, Reset and the header use theme widgets; checked in both modes | CL4 |
| Analysis modal | empty | Batch with 0 audio items cannot open (the menu item is disabled with its existing reason) | ST6 |
| Analysis modal | working | Opening it while analysing is impossible (menu shows Cancel instead) | ST3 |
| Analysis modal | error | Target changed while open: existing status "The active item changed. Nothing was re-analyzed." | ST7 |
| Analysis modal | disabled with reason | Primary is never disabled (re-analysing with the same values is a valid retry); Save as Default as on the canvas | EP2 |
| Analysis modal | overflow / long names | Title truncates the item name with a tooltip; batch list uses the existing confirm list | LG4 |
| Analysis modal | missing dependency | n/a | HI7 |
| Analysis modal | Fancy Dark / Match Theme | `panel` surface via the existing modal recipe | CL4 |
| Item without stored settings (analysed before this change) | data honesty | Header line reads "ANALYZE WITH · not recorded, your defaults" instead of "as analyzed before" | ST4 |
| Settings → Analysis Defaults | locked | Existing "Locked while analyzing" line | ST3 |
| Save as Default confirm | — | Names the values that change, Cancel first, Esc = Cancel | EP1 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Vocal Range combo (form) | click opens list; HC2/HC3 n/a: discrete; no wheel | the item's stored value, else the Settings default | preset names; "Custom" when Advanced Hz match no preset | list only | none (no write) | none |
| Detection Mode combo (form) | as above | as above | preset names / "Custom" | list only | none | none |
| Quality / CPU combo (form) | as above | as above | preset names / "Custom" | list only | none | none |
| Block / Hop size combos (Advanced) | discrete, as Settings | as above | samples | list only; hop ≤ block | none | none |
| Detection Threshold (Advanced) | Drag per HC2 (Ctrl/Cmd fine), HC3 double-click → the Settings default, Ctrl/Cmd-click types | as above | `%.2f` | `AlwaysClamp`, linear, K.LIMITS.threshold | none | none |
| Min / Max Freq (Advanced) | as Threshold | as above | `%.0f Hz` | `AlwaysClamp`, linear (as Settings today; range under 100×), K.LIMITS | none | none |
| Row Reset (form) | click | — | "Reset" | — | none | none (restores the default into the form only) |
| Save as Default | click → confirm modal | — | — | — | none (ExtState) | confirm: names the changed values, Cancel first, Esc = Cancel |
| Analyze Item / Analyze All Selected Items (canvas) | click | — | — | — | existing ("Analyze Pitch" / batch label) | batch: existing replace confirm |
| Re-Analyze (no-notes canvas) | click | — | — | — | existing | none: the item has no notes to lose |
| "…" → Re-Analyze… | click → modal | — | tooltip: "Analyzed with Soprano · Breathy / Lenient · Standard (Realtime)" | — | — | — |
| Modal primary (Re-Analyze / Analyze N Items / Analyze) | click, Enter | — | — | — | existing | the modal itself is the confirm (edits / notes lost are named) |
| Modal Cancel | click, Esc | — | — | — | — | — |
| Change… (wide strip) | click → modal | — | — | — | — | — |

Keyboard map: Esc closes the innermost first (HC5): open combo → Save as Default confirm → analysis modal → active text edit in Advanced (reverts) → window only when floating. Enter in the analysis modal = primary (routed via `Shortcut()`, not while a combo or text field is active). Space forwarded per HC6 while no modal is open and no field is active; inside the modal Space is not forwarded (a modal is open). No new key-repeat toggles (EP6). The Info modal gains: "Re-Analyze… opens the analysis settings; Enter analyzes, Esc cancels" (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | "ANALYZE WITH" · "1 changed from defaults" / "2 changed from defaults" · "as analyzed before" · "your defaults" · "not recorded, your defaults" · "Vocal Range" · "Detection Mode" · "Quality / CPU" · "Advanced" · "Reset" · "Save as Default" · "Matches your defaults" · "Analyze Item" · "Analyze All Selected Items" · "Re-Analyze" · "Change…" · "Analyze with: <range> · <mode> · <quality>" · menu "Analyze", "Re-Analyze…", "Analyze Selected Items (N)…" · Settings section "Analysis Defaults" + "New analyses start with these. Each item keeps the settings it was analyzed with." |
| tooltips | Vocal Range: "Vocal Range\n\nThe pitch range searched for this analysis. Pick the singer's range to avoid octave errors." · Detection Mode: "Detection Mode\n\nHow sure the detector must be before it calls a sound a note. Lenient finds breathy notes; Strict ignores noise." · Quality / CPU: "Quality / CPU\n\nFiner timing or finer pitch, and how long the analysis takes." · Reset: "Back to your default (from Settings)" / disabled "Already the default" · Save as Default: "Use these values for every new analysis" · Re-Analyze… menu: "Analyzed with <range> · <mode> · <quality>" · Change…: "Change the values this item is analyzed with" |
| empty / error / confirm | Save as Default confirm title "Make these your defaults?" body "New analyses will start with: Soprano (was Generic Vocal), Breathy / Lenient (was Clean / Strict). Items already analyzed keep their own settings." buttons "Cancel" / "Save as Default" · Re-analyze modal title "Re-analyze <item>?" (existing body lines kept) · batch modal title "Analyze <N> items" · no-notes hint "Try another Vocal Range or Detection Mode." |
| status messages | "Defaults saved." · existing "Re-analyzing <item>…" · existing analysis-start error |
| undo labels | unchanged: "Analyze Pitch", the batch label, "Show Pitch Envelope" |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| "ANALYZE WITH" label + changed count | `Theme.section_divider` (label) + `reaper.ImGui_TextColored` | `P.yellow` (as Settings), `P.text_dim` |
| Form rows (label \| combo \| Reset) | the existing Settings `draw_form` table (generalised to take a value table) + `Theme.align` | `L.md`, `L.sm` |
| Combos | `Theme.combo` with `placeholder = K.CUSTOM_PRESET` | `Theme.calc_combo_width` |
| Reset / Save as Default | the Settings `reset_button` pattern (`reaper.ImGui_Button` + EP2 tooltip) | `L.md`, `P.text_dim` |
| Advanced fold | `Theme.collapsing_header` | — |
| Analyze / Re-Analyze button | existing `canvas_button` with `K.ANALYZE_BTN` (`Theme.push_button_preset`, `Theme.toggle_button`) | `L.xxl`, `L.lg` |
| Form surface on the canvas | `reaper.ImGui_BeginChild` placed over the canvas (AllowOverlap) | `P.bg`, `P.border` |
| Analysis modal | modal recipe: `Theme.center_next_window`, `K.fit_modal`, `Theme.modal_scrim`, `reaper.ImGui_BeginPopupModal` | `L.modal_sm` |
| Save as Default confirm | existing `request_confirm` | — |
| Tooltips | `Theme.tooltip` behind `HoveredFlags_ForTooltip` (+ `AllowWhenDisabled`) | — |
| Wide-strip summary line | `reaper.ImGui_Text` + truncate + `Theme.tooltip`; "Change…" `reaper.ImGui_Button` with `###change` | `P.text_dim` |

## Library proposals

None. The form reuses the Settings form code inside the script (generalised to read and write a value table instead of `state`), so no shared helper is needed.

## Acceptance criteria

- ST1: on an analysed item, the settings it used are discoverable (Re-Analyze… tooltip and modal header).
- ST2: every button responds at once; Save as Default posts "Defaults saved."
- ST3: form and Save as Default locked while analysing with the inline reason; progress unchanged.
- ST4: the form never shows defaults as the item's own: "not recorded, your defaults" when the item has no stored settings.
- ST5: n/a: lifecycle unchanged.
- ST6: no-item canvas names the next step.
- ST7: analysis-start errors unchanged and in user terms; the form keeps its values for a retry.
- UC1: no new undo points; the stored settings ride in the existing analysis undo point; nothing written when only the form changes.
- UC2: Esc innermost first (combo → confirm → modal → field → window).
- UC3: stored settings are written in the same `P_EXT` write and undo block as the notes; Ctrl/Cmd+Z reseeds the form from the restored item.
- UC4: no selection change.
- UC5: per-row Reset in the form; Settings keeps row Reset and Reset section.
- EP1: Save as Default confirms (ExtState); Re-Analyze modal names the edits it discards.
- EP2: every disabled Reset / Save as Default / form shows its reason.
- EP3: Advanced drags `AlwaysClamp` within K.LIMITS; hop ≤ block; discrete values are combos.
- EP4: target by take GUID (existing).
- EP5: the form keeps its place while locked (disabled, not hidden); only width/height collapses it (LG4).
- EP6: Enter / Esc via `Shortcut()`; no repeat.
- CN1: theme widgets and the existing Settings form code; no hand-built headers.
- CN2: tokens only; modal via `Theme.modal_scrim`.
- CN3: only existing `Theme.*` names.
- CN4: "Analyze" / "Re-Analyze" / "Save as Default" / "Reset" used consistently; "…" marks items that open a modal.
- CN5: Info modal and CHANGELOG list the new behaviour.
- CN6: Hz with units; dialog layout follows Render / Dynamic Split (settings above, action bottom-right, Esc cancels).
- RC1: no icon-only controls added.
- RC2: tooltips in singer terms, no "threshold" jargon outside Advanced.
- HP1: Info modal lists the modal's Enter / Esc and where the settings live.
- EF1: Advanced drags keep HC2/HC3; no wheel on combos.
- EF2: Space forwarded when no modal is open (HC6).
- EF3: n/a: canvas zoom and ruler unchanged.
- IA1: tiers as listed.
- IA2: canvas 1 disclosure level, modal 2.
- IA3: the Analyze button stays the single accent CTA on the empty canvas; ≤ 3 type sizes in the region.
- IA4: no dead UI: Settings section still drives the defaults.
- LG1: form group separated from the button by at least 2× the row gap.
- LG2: `Theme.align` on form labels.
- LG3: widths from `CalcTextSize` / `Theme.calc_combo_width`.
- LG4: three layouts (wide row, stacked narrow, summary line on a short canvas); truncation with tooltips.
- MT1: no new destructive icon targets.
- MT2: n/a: no new DrawList-only controls (the form uses real widgets).
- CL1: text on `bg` and `panel` meets HC1 in both modes.
- CL2: "changed" is text (count, enabled Reset), not colour.
- CL3: no red added.
- CL4: checked in Fancy Dark and Match Theme.
- DV1: n/a: excluded by the Editor / canvas archetype.
- HI1: modal inside the window's `if visible`; RB1 lifecycle.
- HI2: modal `Cond_Appearing`.
- HI3: n/a: toolbar unchanged.
- HI4: form edits never persist; Save as Default writes once on confirm.
- HI5: the form reads the item's stored settings once per target change, not per frame.
- HI6: `###` IDs on dynamic labels (summary, changed count, modal primary).
- HI7: n/a: no new dependency.
- HC1: contrast checked on the canvas `bg` and modal `panel`.
- HC2: Advanced drags fine-adjust with Ctrl/Cmd; combos n/a: discrete.
- HC3: Advanced drags double-click → the Settings default; combos n/a: discrete.
- HC4: Save as Default confirms; analysis writes stay one undo point.
- HC5: Esc order as in the keyboard map; window closes only when floating.
- HC6: Space forwarded when no modal / field is active.
- RB9: the modal is fitted to the parent (`K.fit_modal`), stacked at narrow widths.
- RB15: tooltips through `Theme.tooltip` with `HoveredFlags_ForTooltip`.
- RB17: `###` IDs.

## Open questions / assumptions

- **Unanalysed item, form edited, then another item clicked:** assumed the edit is dropped and the next item's form starts from its own stored settings or the defaults (per-item model). Alternative: keep the edit while the window is open for every unanalysed item (session-sticky, closer to Revoice Pro's "settings you used last"). Decide before implementation.
- **Batch modal seed:** assumed it starts from the defaults, not the open item's settings. Every item in the batch stores the values used (confirmed at 2b: one set for all).
- **Re-analyse keeps the item's values reset to defaults** ("Its values go back to the defaults; Key and Scale stay") — unchanged by this design.
- **Items analysed before this change** have no stored settings; no migration (active development). They show "not recorded, your defaults".
- **Narrow Reset:** at ~260 px the text "Reset" stays and the combo shrinks; if it gets too tight on screen, a reset icon would be a Library proposal later.
- **Tooling:** `ds-lint.py` currently stops on a palette drift between `_lib/theme.lua` and its port; the baseline could not be taken. Worth fixing separately.
- HC6 conflicts: None.

## Changed 2026-11-25 (user)

- The heading "Analyze with" is now "Analysis Settings" (canvas, modal, and the summary line "Analysis Settings: …").
- The canvas form no longer shows the line under the heading ("your defaults", "N changed from defaults", "as analyzed before"); the modal keeps it.
- On the empty canvas the Analyze button and its hint lines come first, the form under them (the summary layout is unchanged).
- While an analysis runs the locked form shows only until its first slice; then the pitch line draws in.
- "Matches your defaults" beside Advanced is gone (the slot stays empty), and the hint reads "Select an item and click Analyze." (no "No data.").
- The Vocal Range, Detection Mode and Quality / CPU tooltips list each choice in its own paragraph with its key difference.
- The empty canvas is one column: the line naming what Analyze will analyse (the open item, or "N items: a, b, +k more" with every name in its tooltip; the instruction when there is nothing), the form, then the button as wide as the form. The form no longer repeats "Select an audio item…" when there is no item.
