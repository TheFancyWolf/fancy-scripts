# Design: Fancy Pitch Correct — Auto Vocal Range and Key (pre-analysis)

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); the "Analysis Settings" form on the empty canvas and the top bar's Key / Scale → part of the main window (Editor / canvas); the existing analysis modal (Re-Analyze, Analyze Selected Items) → the window's modal family (Editor / canvas)
Status: Approved
Date: 2026-11-25
Approver: TheFancyWolf (in chat, 2026-11-25)

## Summary

Today the user guesses the Vocal Range and picks the Key and Scale by hand before analysing. This design makes finding them the first stage of Analyze: a quick, coarse pass over the whole track (the "pre-analysis") works out the singer's lowest and highest notes and the song's key, then the normal analysis carries on with them. On screen it costs **no new row, button or modal**: Vocal Range gains the choice "Auto" and the top bar's Key gains the choice "Auto". The result is remembered on the track, so the pre-analysis runs once per track and later items only add what it has not heard yet. The window's primary display (the note canvas) and the empty canvas's primary action (Analyze) do not change.

Replaces the earlier draft "Scan Track" (a separate scan row, button and result modal), dropped on 2026-11-25 in favour of this approach.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Vocal Range → "Auto" (new first choice in the form, the analysis modal and Settings → Analysis Defaults; the factory default) | Settings defaults, the item's stored analysis settings | nothing (a form value, as the other choices today) | none in the form; ExtState when saved as the default (existing Save as Default / Settings path) | n/a in the form; Settings / Save as Default unchanged (N, already confirmed by the existing modal) |
| Key → "Auto" (new first choice in the top bar's Key list) on an unanalysed item: new items start with the key found on their track | the "Key for new items" (existing) | the "Key for new items" | ExtState (existing key, existing behaviour: the bar's choice for new items is not undoable today) | N: unchanged existing behaviour; nothing destructive, no confirm |
| Analyze / Analyze All Selected Items with Vocal Range or Key on Auto, track not heard yet: pre-analysis of every audio item on the track, then the analysis | every audio item on the track (active takes, media online), read coarsely; then the item's audio as today | the track's record (the tally of pitches heard, which items it covers, lowest / highest note, key, scale, the runner-up key) in the track's `P_EXT`; then the item's notes, analysis settings and Key / Scale as today | track and take data inside the analysis's one undo block | Y: one undo block on project objects; the model reloads on `GetProjectStateChangeCount`; no ExtState is written by the pre-analysis |
| The same on a track already heard | the track's record; only items the record does not cover are read | the record grows by those items (the range can widen; the key stays) | as above | Y: same block |
| Cancel during the pre-analysis (the existing Cancel) | nothing | nothing | none | n/a: nothing was written |
| Key or Scale changed in the top bar on an analysed item whose key came from its track: the item changes as today, and the track's key changes with it, so later items on the track follow | the item, the track's record | the item's Key / Scale and envelope as today; the track's record | take and track data inside the existing key-change undo block | Y: one undo block, model reload. In this case the "Key for new items" ExtState is left on Auto |
| Key → "Auto" on an analysed item: the item takes its track's key (the track is heard first if it has no record) | the track's record or its audio | the item's Key / Scale and envelope; the record if new | take and track data inside one undo block | Y |
| "…" → Find Range and Key Again: hear the whole track afresh and replace its record; analysed items are not changed | every audio item on the target item's track | the track's record | track data inside one undo block | Y: one undo block, model reload, nothing else persisted → no confirm (HC4); status message posted |
| What an item was analysed with (existing tooltip and modal) now reads "Auto: E2–A4" | the item's stored analysis settings | nothing | none | n/a |

## References

- Native REAPER analogues: **Dynamic Split** and **Render to File** (the settings sit above the action and show the values it will use); the "Auto" entries follow REAPER's own lists that lead with an automatic choice (item pitch shift mode "Project default", render sample rate / channels "Auto"). Conventions matched (CN6): discrete choices as combos, notes as note names with octave (the script's existing naming), Hz with units in tooltips, no Alt / Shift repurposing. dB and pan do not appear.
- Redesigns only: baseline capture: the user's screenshot of the empty canvas, 2026-11-25 (`/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/3a5a9677-13b1-4d63-856d-2c923d42d844/images/1.webp`: docked, 1 item selected, top bar Key `E` / Scale `Major`, Analysis Settings form with three rows, Advanced, Analyze Item); no further live capture taken. `ds-lint.py` summary: not available (see Open questions).

## Context and job stories

Confirmed in chat on 2026-11-25: lives in the existing Analysis Settings form and top bar; used on every first analysis of a track; mostly mouse; playback may be running. Decisions: find the range and key as a pre-analysis inside Analyze, taking up little or no space; the pre-analysis hears the whole track once and remembers it. Given up with the earlier draft: a pause to review the result before it is used, and an offer to push the key onto items analysed earlier.

1. When a new singer's track lands in the session, I want Analyze to work out their range and the song's key by itself, so my first analysis is right without guessing.
2. When I batch-analyse a stack of takes (docked under the arrange, playback looping), I want every item on a track to get the same range and key, so the takes agree.
3. When the key was a close call, I want to be told the other candidate, so I can switch in one move.
4. When I correct a wrong key once, I want the rest of the track to follow, so I do not correct it again per item.
5. When I know better (a bass, a song in Dorian), I want to pick the range or key myself, so Auto never overrules me.
6. When I come back days later, I want to see that a value came from Auto, so I know why it is what it is.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | "Auto" as the shown Vocal Range and Key choice; the pre-analysis stage in the analysis progress; the found values after analysis ("Auto: E2–A4" in what the item was analysed with; the key in the top bar); the status line naming what was found | Every first analysis; a wrong range is the commonest reason an analysis fails |
| 2 one disclosure away | The other Vocal Range and Key choices (the open combos); "…" → Find Range and Key Again; the Key combo's tooltip naming the runner-up | Occasional correction |
| 3 Settings | Vocal Range "Auto" as the default in Analysis Defaults (the existing row) | Set once |

## Information architecture

No region is added. Changes inside existing regions:

1. **Analysis Settings form** (empty canvas, analysis modal, Settings → Analysis Defaults): the Vocal Range combo's first entry is "Auto". With Auto chosen the Advanced rows Min Freq and Max Freq are disabled with the reason "Found from the track" (they stay in place, EP5).
2. **Top bar Key / Scale**: the Key combo's first entry is "Auto". While Key is Auto (only possible on an item not analysed yet) the Scale combo shows "Auto" and is disabled with the reason "Found with the key". An analysed item always shows its real key and scale (ST4).
3. **Analysis progress** (existing: the pitch line drawing in, "…" → Cancel NN%): gains a first stage, shown where the form's locked reason already sits: "Finding range and key… 42%".
4. **Status line** (existing): reports what was found.
5. **"…" menu**: one new item, "Find Range and Key Again".

Primary display: the note canvas. Primary action of the empty canvas: Analyze. Disclosure: unchanged (form → Advanced; "…" menu), at most 2 levels (IA2).

## Wireframes

### Default floating / wide docked, empty canvas (new item, nothing heard yet)

```
[V _ Main E251 - 79.wav] [Auto ▾] [Auto      ▾] │ This item │ Separation 50% │ …
                                     ↑ Scale: disabled, "Found with the key"

              1 item selected: V _ Main E251 - 79.wav
        ┌──────────────────────────────────────────────┐
        │ ANALYSIS SETTINGS                            │
        │ ──────────────────────────────────────────── │
        │ Vocal Range     [Auto               ▾] [Reset]│  ← Reset disabled: "Already the default"
        │ Detection Mode  [Clean / Strict     ▾] [Reset]│
        │ Quality / CPU   [Standard (Realtime)▾] [Reset]│
        │ ▸ Advanced                    Save as Default│
        └──────────────────────────────────────────────┘
        ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
        ┃                 Analyze Item                 ┃
        ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

The form is the same size as today.

### Analyze pressed, stage 1 (pre-analysis)

```
        │ ANALYSIS SETTINGS                            │
        │ Finding range and key… 42%                   │  ← the existing locked-reason line
        │ Vocal Range     [Auto               ▾] [Reset]│  ← rows disabled as during any analysis
        …
        ┃           Analyze Item (disabled)            ┃
```

"…" → "Cancel 42%" as today. When stage 1 ends the analysis starts by itself and the pitch line draws in as today.

### After the analysis

```
[V _ Main E251 - 79.wav] [E ▾] [Major     ▾] │ This item │ …
┌ canvas: the notes ───────────────────────────────────────────────┐
│ …                                                                │
└──────────────────────────────────────────────────────────────────┘
 Found E2–A4, E Major (C# Minor also fits). Cmd+Z to undo.            ← status line
```

Re-Analyze… (the existing modal) shows `Vocal Range [Auto: E2–A4 ▾]`. A later new item on the same track: the top bar shows `[Auto ▾]` until analysed, the pre-analysis stage is skipped or lasts only as long as the items it has not heard.

### Narrow docker (~260 px): the form's stacked layout

```
┌ ANALYSIS SETTINGS ───────┐
│ Vocal Range              │
│ [Auto                 ▾] │
│ Detection Mode           │
│ [Clean / Strict       ▾] │
│ …                        │
│ [     Analyze Item     ] │
```

Unchanged except the combo's entry. The stage-1 line wraps under the heading. The top bar behaves as today; the Key combo is as wide as its longest short name, now "Auto" (LG3). Long track names in the status line are truncated with the full text in a tooltip.

### Wide short strip (e.g. 1200×150): the form's summary layout

```
Analysis Settings: Auto · Clean / Strict · Standard   Change…   [ Analyze Item ]
```

While stage 1 runs the summary reads "Finding range and key… 42%".

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Form, top bar | empty (no target item) | Unchanged: "Select an audio item in REAPER to analyze it."; controls disabled with that reason | ST6, EP2 |
| Form | working, stage 1 | "Finding range and key… 42%" in the locked-reason line; with several tracks "Finding range and key: V _ Main… 42%"; time-sliced with the existing per-frame budget constant; Cancel as today | ST3 |
| Form | working, stage 2 | Unchanged analysis progress | ST3 |
| Status line | found | "Found E2–A4, E Major. Cmd+Z to undo." | ST2 |
| Status line | close call on the key | "Found E2–A4, E Major (C# Minor also fits). Cmd+Z to undo." The runner-up is also in the Key combo's tooltip for that item | ST4 |
| Status line | track already heard | "Used V _ Main's range and key: E2–A4, E Major." | ST2, ST4 |
| Status line | error: no singing found on the track | "Couldn't find a range on V _ Main: used Generic Vocal." The item's stored settings read "Auto: Generic Vocal (nothing found)" | ST4, ST7 |
| Status line | error: too little singing for a key | "Not enough singing to tell the key: kept E Major." (the key last chosen by hand) | ST4, ST7 |
| Status line | error: some media unreadable | "Couldn't read 2 of 12 items on V _ Main (media offline). Used the rest." None readable: the existing "Couldn't read this item's audio…" message, nothing written | ST7 |
| Status line | cancelled | The existing cancelled message; nothing was written | ST2 |
| Advanced: Min Freq, Max Freq | disabled with reason while Vocal Range is Auto | Disabled, "Found from the track" inline beside the first of them and as each one's tooltip | EP2, EP5 |
| Scale combo | disabled with reason while Key is Auto | Shows "Auto"; tooltip "Found with the key" | EP2 |
| "…" → Find Range and Key Again | disabled with reason | No target item, or an analysis is running: disabled with the menu's existing reason pattern | EP2 |
| Status line, modal | overflow / long names | Track names truncated to the width with the full text in a tooltip | LG4 |
| All | missing dependency | None new | HI7 |
| All | Fancy Dark / Match Theme | No new colour is used | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Vocal Range combo, entry "Auto" | Click; the row's existing Reset and right-click menu. HC2 / HC3 n/a: discrete | "Auto" (factory default) | On an analysed item "Auto: E2–A4" (note names); the tooltip gives Hz | The found notes with a safety margin below and above, held inside the Min / Max Freq limits | None (form value); part of the analysis's undo point when used | n/a |
| Key combo, entry "Auto" | Click. HC2 / HC3 n/a: discrete | "Auto" on a fresh install; otherwise the stored "Key for new items" | Short name "Auto" in the bar | Only Major and Natural Minor are found | Unanalysed item: none (as today). Analysed item: "Find Key: <item>" | n/a |
| Scale combo while Key is Auto | Disabled | "Auto" | n/a | n/a | n/a | n/a |
| Key / Scale changed on an analysed item whose key came from its track | As today | n/a | As today | As today | The existing key-change label | None: one undo block covers the item and the track's record. Status: "Key for V _ Main is now C# Minor. New items on this track follow." |
| Analyze Item / Analyze All Selected Items / Re-Analyze | As today | n/a | n/a | n/a | The existing analysis labels (the track's record rides in the same undo point) | As today |
| Cancel during stage 1 | As today ("…" → Cancel NN%) | n/a | Whole percent across both stages | n/a | None | None: nothing was written |
| "…" → Find Range and Key Again | Click | n/a | n/a | n/a | "Find Range and Key: <track>" | No confirm: one undo point, nothing outside the project written. Status: "Found E2–A4, E Major on V _ Main. Items already analyzed keep theirs. Cmd+Z to undo." |

Keyboard map: no new shortcut and no change to Esc (HC5) or Space (HC6). A running pre-analysis is cancelled the same way as a running analysis. The Info modal's text on analysis gains one sentence on Auto (HP1); there is no hidden gesture.

## Copy deck

| Where | String |
|---|---|
| labels | "Auto" (Vocal Range entry; Key entry; Scale preview while Key is Auto) · "Auto: E2–A4" (an analysed item's Vocal Range) · "Auto: Generic Vocal (nothing found)" · "Find Range and Key Again" ("…" menu) |
| tooltips | Vocal Range "Auto": "Auto\n\nListens through the whole track first to find the singer's lowest and highest notes. Done once per track." · Key "Auto": "Auto\n\nFinds the song's key from the whole track the first time one of its items is analyzed." · Key combo on an item whose key was found: "Found from V _ Main. C# Minor also fits." / "Found from V _ Main." · "Auto: E2–A4": "82–440 Hz, with a little room either side" · disabled Min / Max Freq: "Found from the track" · disabled Scale: "Found with the key" |
| empty / error / confirm | "Finding range and key… 42%" · "Finding range and key: V _ Main… 42%" |
| status messages | "Found E2–A4, E Major. Cmd+Z to undo." · "Found E2–A4, E Major (C# Minor also fits). Cmd+Z to undo." · "Used V _ Main's range and key: E2–A4, E Major." · "Couldn't find a range on V _ Main: used Generic Vocal." · "Not enough singing to tell the key: kept E Major." · "Couldn't read 2 of 12 items on V _ Main (media offline). Used the rest." · "Key for V _ Main is now C# Minor. New items on this track follow." · "Found E2–A4, E Major on V _ Main. Items already analyzed keep theirs. Cmd+Z to undo." |
| undo labels | The existing analysis labels · "Find Key: <item>" · "Find Range and Key: V _ Main" |

"Cmd" reads "Ctrl" on Windows and Linux (the script's existing modifier label). With only the range on Auto the messages leave the key out ("Found E2–A4."), and the other way round ("Found E Major.").

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Vocal Range "Auto" entry | `Theme.combo` (the existing row; one more entry in its list) | n/a |
| Key "Auto" entry, Scale "Auto" preview | `Theme.combo` (the existing top bar combos; width from the longest label) | n/a |
| Stage-1 progress line | the form's existing locked-reason text | `P.text_dim` |
| Disabled reasons (Min / Max Freq, Scale, menu item) | inline text; `Theme.tooltip` behind `HoveredFlags_ForTooltip | HoveredFlags_AllowWhenDisabled` | `P.text_dim` |
| Entry and combo tooltips | the combos' existing per-choice tooltip option | n/a |
| "…" menu item | `Theme.selectable` in the existing menu | n/a |
| Status messages | the window's existing status line | `P.text_dim` |

## Library proposals

None.

## Acceptance criteria

- ST1: the Vocal Range and Key in effect are shown at rest ("Auto" before, the found values after).
- ST2: every path (found, track already heard, nothing found, key unclear, media unreadable, cancelled) posts a status message.
- ST3: the pre-analysis is time-sliced with the existing per-frame budget constant, shows a percentage, and is cancellable at any moment.
- ST4: an analysed item never shows "Auto" as its key; a fallback range and a kept key are labelled as such; the runner-up key is named.
- ST5: n/a: no lifecycle change.
- ST6: no new region; the existing empty states are unchanged.
- ST7: failures are reported in the window, in user terms, with what was used instead.
- UC1: the track's record rides in the analysis's undo point; no undo point when cancelled; "Find Key" and "Find Range and Key" are one point each, labelled in user terms.
- UC2: see HC5.
- UC3: the record and the item data are written inside the same undo block; the model reloads on project state change; the pre-analysis writes no ExtState.
- UC4: the item and track selection are never changed.
- UC5: Vocal Range Reset returns to the default (Auto from the factory); no new value control.
- EP1: n/a: nothing destructive is added (see HC4).
- EP2: Min / Max Freq, Scale and the menu item show their reason when disabled, also with tooltips off (inline for Min / Max Freq).
- EP3: the found range is held inside the Min / Max Freq limits.
- EP4: the track's record names tracks and takes by GUID.
- EP5: no row is added, hidden or moved by state; Min / Max Freq and Scale are disabled in place.
- EP6: n/a: no new shortcut.
- CN1: only existing `Theme.*` helpers.
- CN2: tokens only; no new modal.
- CN3: every helper and token named in Theme mapping exists.
- CN4: "Auto" is the one word for the choice; "Found" for a result; "Analyze" stays the name of the whole action.
- CN5: the Info modal and CHANGELOG describe Auto as built.
- CN6: combos for discrete choices; note names and Hz with units; no Alt / Shift use.
- RC1: no icon-only control is added.
- RC2: notes as names, Hz with units, no internal keys.
- HP1: the Info modal explains Auto and Find Range and Key Again.
- EF1: n/a: no new value control.
- EF2: see HC6.
- EF3: n/a: the canvas timeline is unchanged.
- IA1: tiers as listed.
- IA2: no new disclosure level.
- IA3: Analyze stays the one primary action; no new type size or accent.
- IA4: no developer toggle; nothing that does nothing.
- LG1: n/a: no new group.
- LG2: the inline reason uses `Theme.align`; no nudges.
- LG3: the Key combo's width comes from its longest label, now "Auto".
- LG4: full, stacked and summary layouts as wireframed; long track names truncated with a tooltip.
- MT1: n/a: no new target.
- MT2: n/a: no custom DrawList control.
- CL1: see HC1.
- CL2: n/a: no colour-coded state is added.
- CL3: no red is used.
- CL4: no new colour; checked in Fancy Dark and Match Theme.
- DV1: n/a: excluded for this archetype.
- HI1: n/a: no new window or child.
- HI2: n/a: no new window.
- HI3: n/a: no toolbar or close change.
- HI4: the record is written once per analysis, never per frame.
- HI5: whether a track has a record is cached per project state-change count; nothing is enumerated per frame.
- HI6: the combos keep stable IDs although their previews change.
- HI7: n/a: no new dependency.
- AR (Editor / canvas): canvas objects and their gestures are untouched.
- HC1: n/a: no new text colour or surface; the disabled controls are exempt.
- HC2: n/a: no new parameter value control.
- HC3: n/a: no new parameter value control.
- HC4: Find Range and Key Again and Find Key need no confirm (one undo block, model reload, no ExtState / JSON / file / cache change) and each posts a status message.
- HC5: unchanged.
- HC6: unchanged.

## Open questions / assumptions

- **Assumption (my call): "Auto" is the factory default for both Vocal Range and Key.** A user who already saved a default range or last chose a key keeps theirs until they pick Auto.
- **Assumption (my call): a result is used at once, with no pause to review it.** The status line and the Key tooltip name the runner-up key; the user corrects in the top bar.
- **Assumption (my call): correcting the key on an item whose key came from its track also corrects the track**, so later items follow. Items analysed earlier keep their own key.
- **Assumption (my call): the key is found once per track and then stays** (until the user corrects it or runs Find Range and Key Again); the range may widen as new items are heard.
- **Assumption (my call): only Major and Natural Minor are found.** Dorian and the pentatonic scales cannot be told apart reliably from a melody.
- **Assumption (my call): the key is remembered per track.** Two tracks of one song are each heard separately and may be given different keys; there is no project-wide key.
- **Assumption (my call): with a hand-picked Vocal Range and a hand-picked Key no pre-analysis runs at all.**
- **Speed is not measured.** The pre-analysis is expected to take a few seconds per track (coarser steps, lower sample rate). This is an estimate; it must be timed in real REAPER on real vocal tracks before the plan fixes how coarse it is. The UI holds either way (progress and Cancel).
- **Accuracy is not measured.** How often the found key and range are right must be checked on the singer test set before release.
- `ds-lint.py` baseline: not available. Run on 2026-11-25, the linter stops with "theme.lua palette drifted from ds-lint's port of build_palette" (a tooling issue, also recorded in the 2026-11-24 design doc).
- HC6 conflicts: None.
