# Design: Fancy Pitch Correct — Auto Vocal Range and Key (pre-analysis)

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (unchanged); the "Analysis Settings" form on the empty canvas and the top bar's Key / Scale / Range → part of the main window (Editor / canvas); the Analysis card (progress and result) and the existing analysis modal (Re-Analyze, Analyze Selected Items) → the window's modal family (Editor / canvas)
Status: Approved
Date: 2026-11-27
Approver: TheFancyWolf (in chat, 2026-11-27; revision 1 approved 2026-11-25)

## Summary

Analyze first listens through the whole track (the "pre-analysis") to find the singer's range and the song's key, then finds the notes. This revision (2) follows the user's test of revision 1 in real REAPER on 2026-11-27. Three things change: the Key list has **no "Auto" choice** — a new item's key is simply found and selected, unless the user picked one first; the range in use is **always shown** in the top bar; and all progress and results appear in **one card in the middle of the note window**, which stays open while the analysis runs, fills in what it finds, and is closed by the user when it is done. The corner status message, the progress line in the settings form and the percentage on the "…" button are no longer used for analysis. The window's primary display (the note canvas) and the empty canvas's primary action (Analyze) do not change.

Revision 1 (approved 2026-11-25) is built on branch `pitch-correct-auto-range-key`; this revision changes its interface, not its listening pass, track record or undo behaviour.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Vocal Range → "Auto" (first choice in the form, the analysis modal and Settings → Analysis Defaults; the factory default) — unchanged from revision 1 | Settings defaults, the item's stored analysis settings | nothing (a form value) | none in the form; ExtState when saved as the default (existing path) | n/a in the form; Settings / Save as Default unchanged |
| Key and Scale of an item not analysed yet: shown as "–" (not set) unless its track already has a key, which is then shown. The user may pick a key before analysing | the track's record | nothing until Analyze | none (an in-memory choice for that item; the "Key for new items" ExtState of revision 1 is no longer used) | n/a: nothing is written |
| Analyze with the key not set: the key and scale are found from the track and selected | every audio item on the track not heard yet; then the item's audio | the track's record; the item's notes, analysis settings, Key / Scale | track and take data inside the analysis's one undo block | Y: one undo block, model reload, no ExtState |
| Analyze with a key picked by the user first: that key is used; when a listening pass runs anyway (Vocal Range on Auto) the track's record takes the user's key | as above | as above | as above | Y |
| Analysis card: opens in the middle of the note window when any analysis starts (single, batch, Find Range and Key Again), shows the step and overall progress, fills in the range and key as they are found, then the note count; Cancel while running; OK when done | the running analysis | nothing | none | n/a |
| Analysis card, done, key was a close call: the two candidates are offered; picking the other one and pressing OK changes the item's key and the track's (an ordinary key change) | the item, the track's record | the item's Key / Scale and envelope, the track's record | take and track data inside one undo block ("Set Key") | Y: its own undo point after the analysis's |
| Range box in the top bar (read-only, after Scale): the range the open item uses ("A3–F4", "Tenor", or "Auto" before analysis) | the item's stored analysis settings, the form | nothing | none | n/a |
| Cancel in the card while running (either stage) | nothing | nothing | none | n/a: nothing was written |
| Key or Scale changed on an analysed item whose key came from its track: the track's key changes with it — unchanged from revision 1 | the item, the track's record | the item, the track's record | inside the existing key-change undo block | Y |
| "…" → Find Range and Key Again — unchanged from revision 1, but its progress and result are shown in the Analysis card | every audio item on the track | the track's record | track data inside one undo block | Y |
| Removed from revision 1: Key → "Auto" as a list choice; "Auto" on an analysed item (Find Key); the status-line messages "Found …" / "Used …"; "Finding range and key… NN%" in the form, the status line and on the "…" button | — | — | — | — |

## References

- Native REAPER analogues: **Render to File** (after Render the dialog stays open, shows a progress bar and what it is doing, and ends with a summary the user closes; Cancel while running); **Dynamic Split** (settings above the action). Conventions matched (CN6): notes as note names with octave (the script's existing naming), Hz with units in tooltips, discrete choices as combos and radio rows, Cancel / Esc while running, no Alt / Shift repurposing. dB and pan do not appear.
- Redesigns only: baseline captures: revision 1 running in real REAPER, 2026-11-25 and 2026-11-27 (empty canvas with Key "Auto" / Scale "Auto"; "Finding range and key… 4%" in the form and in the bottom-left corner; "Analyzing … 83%" in the bottom-left corner; "Used Test's range and key: A3–F4, C Minor." in the bottom-left corner; Re-Analyze modal with "Auto: B2–A4"), kept in the session scratchpad. `ds-lint.py` summary: not available (see Open questions).

## Context and job stories

Confirmed in chat on 2026-11-27 after the user tried revision 1: "It shouldn't have an option for auto, it should just select what we think is best in the list"; "don't lock it, someone might know their key from the start"; "it doesn't tell me what it selected as the vocal range anywhere… we should have that listed somewhere"; "scanning and analyzing should always take place in the main note window, not in any corner"; the pop-up "stays the whole time during analysis giving the user progress updates on what it's finding and then when it's done they get the option to close it". Lives in the existing window; used on every analysis; mostly mouse; playback may be running.

1. When I analyse a new singer's item, I want the key and range found and simply selected, so I never have to ask for it.
2. When I already know the key, I want to pick it before analysing, so nothing overrides me.
3. When an analysis runs, I want to watch it in the middle of the note window and see what it finds as it goes, so I am never hunting for a message in a corner.
4. When it is done, I want the result to stay on screen until I close it, so I cannot miss it.
5. When I look at an item later, I want its range shown next to its key, so I know what it was analysed with.
6. When the key was a close call, I want to pick the other candidate right there, so fixing it is one click.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Key, Scale and the Range box in the top bar; Vocal Range "Auto" in the form; the Analysis card while an analysis runs and until it is closed | Every analysis |
| 2 one disclosure away | The other key candidate (in the card, when there is one); "…" → Find Range and Key Again; the Range box's tooltip (which track, Hz) | Occasional |
| 3 Settings | Vocal Range "Auto" as the default in Analysis Defaults | Set once |

## Information architecture

1. **Top bar** (existing): Key, Scale, then the new read-only **Range box**. Key's list holds the twelve keys only. On an item not analysed yet, Key shows "–" until the user picks one or the analysis finds it; while Key is "–", Scale shows "–" and is disabled with the reason "Pick a key first, or it is found when you analyze".
2. **Analysis Settings form** (existing): unchanged from revision 1 (Vocal Range "Auto"; Min / Max Freq locked with "Found from the track"). It no longer shows a progress line; while an analysis runs it is covered by the card.
3. **Analysis card** (new; one modal, centred on the note canvas): title, one progress bar with the current step, three result rows (Vocal Range, Key, Notes; a batch shows a track list and an item counter), then Cancel (running) or OK (done).
4. **"…" menu**: Find Range and Key Again (unchanged). While anything runs, the menu's Cancel item stays, without a percentage.
5. **Status line**: no longer used for analysis progress or results.

Primary display: the note canvas. Primary action of the empty canvas: Analyze. While the card is open its primary action is Cancel, then OK. Disclosure: one level (the card); IA2 OK.

## Wireframes

### Top bar and empty canvas, item not analysed

```
[07_LeadVox copy.wav] [– ▾] [–         ▾] [Auto] │ This item │ Separation 50% │ …
                        ↑ Key: pick one, or it is found      ↑ Range box (read-only)

              1 item selected: 07_LeadVox copy.wav
        ┌──────────────────────────────────────────────┐
        │ ANALYSIS SETTINGS                            │
        │ Vocal Range     [Auto               ▾] [Reset]│
        │ Detection Mode  [Clean / Strict     ▾] [Reset]│
        │ Quality / CPU   [Standard (Realtime)▾] [Reset]│
        │ ▸ Advanced                                   │
        └──────────────────────────────────────────────┘
        ┏━━━━━━━━━━━━━━━━ Analyze Item ━━━━━━━━━━━━━━━━┓
```

### Analysis card, step 1 (listening to the track)

```
              ┌ Analyzing 07_LeadVox copy.wav ───────────┐
              │ Listening to track "Test"…               │
              │ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░  24%  │
              │                                          │
              │ Vocal Range   listening…                 │
              │ Key           listening…                 │
              │ Notes         waiting                    │
              │                                          │
              │                               [Cancel]   │
              └──────────────────────────────────────────┘
```

### Analysis card, step 2 (finding notes; range and key already shown)

```
              ┌ Analyzing 07_LeadVox copy.wav ───────────┐
              │ Finding notes…                           │
              │ ██████████████████████░░░░░░░░░░░░  65%  │
              │                                          │
              │ Vocal Range   A3 – F4                    │
              │ Key           C Minor                    │
              │ Notes         finding…                   │
              │                                          │
              │                               [Cancel]   │
              └──────────────────────────────────────────┘
```

The pitch line still draws in on the canvas behind the card.

### Analysis card, done (close call on the key)

```
              ┌ Analysis done ───────────────────────────┐
              │ 07_LeadVox copy.wav                      │
              │                                          │
              │ Vocal Range   A3 – F4                    │
              │ Key           (•) C Minor                │
              │               ( ) D# Major               │
              │               These two fit equally well.│
              │ Notes         31                         │
              │                                          │
              │                                   [OK]   │
              └──────────────────────────────────────────┘
```

Variants of the result rows: a clear key is one line ("C Minor"); a key the user picked reads "D Major (your choice)"; a hand-picked range reads "Tenor (your choice)"; a track heard earlier reads "A3 – F4 (from track "Test")". Problems are stated on the row they belong to: "No singing found: used Generic Vocal", "Not enough singing to tell: kept E Major", and under the rows "Couldn't read 2 of 12 items on "Test" (media offline). Used the rest." No pitched note: "Notes   none found. Try another Vocal Range or Detection Mode."

After OK the top bar reads `[C ▾] [Natural Minor ▾] [A3–F4]`.

### Analysis card, batch

```
              ┌ Analyzing 3 of 12: Lead take 3.wav ──────┐
              │ Finding notes…                           │
              │ ████████████░░░░░░░░░░░░░░░░░░░░░░  31%  │
              │                                          │
              │ Lead Vox      B2 – A4 · E Major          │
              │ Harmony       C3 – E4 · E Major          │
              │                                          │
              │                               [Cancel]   │
              └──────────────────────────────────────────┘
```

Done: the title reads "Analysis done", the existing batch summary line ("12 items analyzed…") sits above the track rows, the list scrolls after six tracks, and OK closes it. Key candidates are not offered in a batch.

### Find Range and Key Again

The same card with the title "Finding range and key", step 1 only; done: "Vocal Range   B2 – A4", "Key   E Major", and the line "Items already analyzed keep theirs."

### Narrow docker (~260 px)

The card is capped to the script window's size, like the window's other modals, so it stays inside the window and is dimmed like them; its width shrinks with the window and long values wrap inside their column (the two columns stay). Only a window too small for any modal makes it its own OS window (RB9, see Open questions). In the top bar the Range box is the first thing to go when the bar runs out of width (the existing header rule for what hides first); the range stays readable in the Re-Analyze dialog.

### Wide short strip (e.g. 1200×150)

The summary layout of the form is unchanged ("Analysis Settings: Auto · Clean / Strict · Standard   Change…   [Analyze Item]"). The card is centred on the note canvas, held inside the window, and may cover the whole strip; if the strip is shorter than the card can shrink to, the card opens as its own OS window (RB9).

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Key / Scale | empty (item not analysed, no key on the track) | Key "–" (enabled); Scale "–" disabled with "Pick a key first, or it is found when you analyze" | ST6, EP2 |
| Key / Scale | item not analysed, track has a key | The track's key and scale, changeable | ST4 |
| Range box | item not analysed | The Vocal Range choice of the form ("Auto", "Tenor", …) | ST4 |
| Range box | analysed | "A3–F4" (Auto) or the preset's name; tooltip: track and Hz | ST1, ST4 |
| Range box | no target item | "–" | ST6 |
| Analysis card | working, step 1 | "Listening to track "<name>"…", the bar, "listening…" on Vocal Range and Key; with several tracks the step line names the one being heard | ST3 |
| Analysis card | working, step 2 | "Finding notes…", the bar across both steps, range and key filled in | ST3 |
| Analysis card | done | Title "Analysis done", the results, OK | ST2 |
| Analysis card | cancelled | The card closes; status line: the existing cancelled message; nothing was written | ST2 |
| Analysis card | error: no singing found on the track | Vocal Range row: "No singing found: used Generic Vocal" | ST4, ST7 |
| Analysis card | error: key not told | Key row: "Not enough singing to tell: kept E Major" (the key last chosen by hand) | ST4, ST7 |
| Analysis card | error: some media unreadable | A line under the rows: "Couldn't read 2 of 12 items on "<track>" (media offline). Used the rest." | ST7 |
| Analysis card | error: nothing could be read / the item is gone | The card closes and the existing message shows in the status line (nothing was analysed) | ST7 |
| Analysis card | no pitched notes | Notes row: "none found. Try another Vocal Range or Detection Mode." | ST6, ST7 |
| Analysis card | overflow / long names | Item and track names truncated to the card's width with the full name in a tooltip; the batch track list scrolls after six | LG4 |
| Scale combo | disabled with reason | see first row | EP2 |
| Advanced: Min / Max Freq | disabled with reason while Vocal Range is Auto | Unchanged from revision 1: "Found from the track" | EP2, EP5 |
| All | missing dependency | None new | HI7 |
| All | Fancy Dark / Match Theme | The card uses the popup surface and palette keys only | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Key combo | Click. HC2 / HC3 n/a: discrete | "–" on a new item (or its track's key) | Twelve keys, as today | n/a | Not analysed: none. Analysed: the existing "Set Key" | n/a |
| Scale combo | Click; disabled while Key is "–" | "–", then Major when a key is picked by hand | As today | n/a | As today | n/a |
| Range box | Hover: tooltip. No click. HC2 / HC3 n/a: read-only | n/a | Note names; Hz in the tooltip | n/a | n/a | n/a |
| Vocal Range combo "Auto" | Unchanged from revision 1 | "Auto" | "Auto: E2–A4" on an analysed item | As revision 1 | None (form value) | n/a |
| Card: Cancel | Click; Esc | n/a | n/a | n/a | None | None: nothing was written |
| Card: key candidates (done, close call) | Click (radio). HC2 / HC3 n/a: discrete | The better-fitting one | Key name + "Major" / "Minor" | Two choices only | "Set Key" when the other one is confirmed with OK | No confirm: one undo point, item and track together; nothing outside the project |
| Card: OK | Click; Enter; Esc | n/a | n/a | n/a | None (unless the other key was picked) | n/a |
| Analyze Item / Analyze All Selected Items / Re-Analyze | As today; opens the card | n/a | n/a | n/a | The existing analysis labels (the track's record rides in the same undo point) | As today |
| "…" → Find Range and Key Again | Click; opens the card | n/a | n/a | n/a | "Find Range and Key: <track>" | As revision 1 |

Keyboard map: no new shortcut. Esc per HC5: the card is a modal, so Esc goes to it first — Cancel while running, close when done; nothing else changes. Enter closes the card when done (no key-repeat, EP6). Space per HC6 is not forwarded while the card is open (a modal is open). The Info modal's two sentences on Auto and on Find Range and Key Again are reworded to match (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | "–" (Key and Scale not set; Range box with no item) · "Auto" (Vocal Range entry; Range box before analysis) · "Auto: E2–A4" (an analysed item's Vocal Range in the form) · "Find Range and Key Again" · card titles: "Analyzing 07_LeadVox copy.wav" · "Analyzing 3 of 12: Lead take 3.wav" · "Analyzing 12 items" (a batch while it listens, before its first item) · "Finding range and key" · "Analysis done" · rows: "Vocal Range" · "Key" · "Notes" · buttons: "Cancel" · "OK" |
| card step lines | "Listening to track "Test"…" · "Finding notes…" |
| card row values | "listening…" · "waiting" · "finding…" · "A3 – F4" · "A3 – F4 (from track "Test")" · "Tenor (your choice)" · "C Minor" · "C Minor (from track "Test")" · "D Major (your choice)" · "Custom (your choice)" (a hand-set Hz range) · "31" · "none found. Try another Vocal Range or Detection Mode." · "These two fit equally well." · "No singing found: used Generic Vocal" · "Not enough singing to tell: kept E Major" · "Couldn't read 2 of 12 items on "Test" (media offline). Used the rest." · "Items already analyzed keep theirs." · "Re-analyzed: values back to the defaults (Cmd+Z undoes)." (the existing sentence, as a line of the finished card) · batch row: "Lead Vox   B2 – A4 · E Major" (a value not known yet is "–"; problem texts and "(your choice)" notes may appear on either side of the dot) |
| tooltips | Vocal Range "Auto": "Auto: Listens through the whole track first to find the singer's lowest and highest notes. Done once per track." · Key while "–": "Pick the key if you know it. Otherwise it is found from the whole track when you analyze." · Scale while disabled: "Pick a key first, or it is found when you analyze" · Key on an item whose key was found: "Found from Test. D# Major also fits." / "Found from Test." · Range box: "Vocal range found on Test: 208–370 Hz, with a little room either side" / "Vocal Range: Tenor (130–500 Hz)" / "The range is found from the whole track when you analyze" · disabled Min / Max Freq: "Found from the track" |
| status messages | "Key for Test is now D Major. New items on this track follow." (unchanged) · the existing cancelled, unreadable-audio and item-gone messages |
| undo labels | The existing analysis labels · "Set Key" · "Find Range and Key: Test" |

"Minor" stands for Natural Minor in the card and tooltips, as in revision 1.

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Key "–" preview, Scale "–" | `Theme.combo` with its placeholder option (existing top bar combos) | n/a |
| Range box | `Theme.badge` (read-only) + `Theme.tooltip` behind `HoveredFlags_ForTooltip` | palette keys of the badge preset; width from its text |
| Analysis card | pending flag → `OpenPopup` once → the window's modal size cap → centred on the note canvas each frame (window centre when no canvas is drawn) → `Theme.modal_scrim` → `BeginPopupModal`, height from its content | `L.modal_sm` |
| Step line | `Theme.align` + text | `P.text` |
| Progress bar | `Theme.progress_bar` with the percentage as its label | its preset; `L.sm` above and below |
| Row labels ("Vocal Range", "Key", "Notes"; batch track names) | `Theme.align` + text in a two-column table | `P.text_dim`; `L.md` column gap |
| Row values | text | `P.text`; waiting / listening values `P.text_dim` |
| Problem lines | text | `P.text_dim` (no red: nothing failed that the user must fix) |
| Key candidates | `reaper.ImGui_RadioButton` | `L.xs` between rows |
| Cancel / OK | `Theme.right_align` + `reaper.ImGui_Button`, both plain, like the safe confirm of the window's other modals | `L.md`, `L.sm` |
| Disabled Scale reason, Min / Max Freq reason | `Theme.tooltip` behind `HoveredFlags_ForTooltip | HoveredFlags_AllowWhenDisabled` | `P.text_dim` |

## Library proposals

None.

## Acceptance criteria

- ST1: the Key, Scale and Range in effect are shown at rest in the top bar ("–" / "Auto" before analysis, the real values after).
- ST2: every path (found, track already heard, nothing found, key unclear, media unreadable, cancelled) is reported in the Analysis card or, when the card closes without a result, in the status line.
- ST3: both steps are time-sliced with the existing per-frame budget constant; the card shows the step, a progress bar and Cancel at every moment.
- ST4: an analysed item always shows a real key; where a value came from (found, from the track, your choice) and any fallback are stated in the card; the runner-up key is offered.
- ST5: n/a: no lifecycle change.
- ST6: no new region; the existing empty states are unchanged.
- ST7: failures are reported in the window, in user terms, with what was used instead.
- UC1: the track's record rides in the analysis's undo point; no undo point when cancelled; "Find Range and Key" and the card's "Set Key" are one point each, labelled in user terms.
- UC2: see HC5.
- UC3: the record and the item data are written inside the same undo block; the model reloads on project state change; the pre-analysis writes no ExtState.
- UC4: the item and track selection are never changed.
- UC5: Vocal Range Reset returns to the default (Auto from the factory); no new value control.
- EP1: n/a: nothing destructive is added (see HC4).
- EP2: Min / Max Freq, Scale and the menu item show their reason when disabled (inline for Min / Max Freq).
- EP3: the found range is held inside the Min / Max Freq limits.
- EP4: the track's record names tracks and takes by GUID.
- EP5: no row is added, hidden or moved by state; Min / Max Freq and Scale are disabled in place.
- EP6: Enter and Esc in the card are routed through `Shortcut()`, no repeat.
- CN1: only existing `Theme.*` helpers.
- CN2: tokens only; `Theme.modal_scrim` before the card; `L.modal_sm`.
- CN3: every helper and token named in Theme mapping exists.
- CN4: "Auto" is the one word for the Vocal Range choice; "Listening" for step 1 and "Finding notes" for step 2; "Analyze" stays the name of the whole action; Close is always "OK".
- CN5: the Info modal and CHANGELOG describe Auto as built.
- CN6: combos for discrete choices; note names and Hz with units; no Alt / Shift use.
- RC1: no icon-only control is added.
- RC2: notes as names, Hz with units, no internal keys.
- HP1: the Info modal explains Auto, that the key is found when not picked, and Find Range and Key Again.
- EF1: n/a: no new value control.
- EF2: see HC6.
- EF3: n/a: the canvas timeline is unchanged.
- IA1: tiers as listed.
- IA2: no new disclosure level.
- IA3: Analyze stays the one primary action of the canvas; the card has one primary button at a time (Cancel, then OK); no new type size.
- IA4: no developer toggle; nothing that does nothing.
- LG1: in the card the gap between the progress group, the result rows and the buttons is at least twice the gap between rows.
- LG2: the inline reason uses `Theme.align`; no nudges.
- LG3: the Key combo's width comes from its longest label; the Range box's from its text.
- LG4: the form's layouts are unchanged; the Range box hides first when the top bar is narrow; long item and track names in the card are truncated with a tooltip; the batch list scrolls.
- MT1: Cancel and OK are at least the form's button height.
- MT2: n/a: no custom DrawList control.
- CL1: see HC1.
- CL2: the selected key candidate is a radio mark, not colour alone.
- CL3: no red is used.
- CL4: no new colour; checked in Fancy Dark and Match Theme.
- DV1: n/a: excluded for this archetype.
- HI1: the card follows the Begin / End modal recipe.
- HI2: the card opens with `Cond_Appearing`.
- HI3: n/a: no toolbar or close change.
- HI4: the record is written once per analysis, never per frame; the card persists nothing.
- HI5: whether a track has a record is cached per project state-change count; nothing is enumerated per frame.
- HI6: the combos keep stable IDs although their previews change.
- HI7: n/a: no new dependency.
- AR (Editor / canvas): canvas objects and their gestures are untouched.
- HC1: `P.text` and `P.text_dim` on the popup surface measure at least 4.5:1 in both theme modes.
- HC2: n/a: no new parameter value control.
- HC3: n/a: no new parameter value control.
- HC4: Find Range and Key Again and the card's key change need no confirm (one undo block each, model reload, no ExtState / JSON / file / cache change); their result is shown in the card.
- HC5: Esc goes to the card first (Cancel while running, close when done); nothing else changes.
- HC6: Space is not forwarded while the card is open; otherwise unchanged.

## Open questions / assumptions

- **Assumption (my call): the card is shown for every analysis**, including when the track was heard earlier and when range and key were both picked by hand, so progress is always in the same place. In those cases it shows where the values came from ("from track …", "your choice").
- **Assumption (my call): the card stays until OK, Enter or Esc**, also after a short analysis. It never closes by itself.
- **Assumption (my call): picking the other key candidate in the finished card is a second undo point** ("Set Key"), because the analysis has already been written when the card offers it.
- **Assumption (my call): while Key is "–", Scale is locked** with its reason; picking a key by hand sets Scale to Major and unlocks it.
- **Assumption (my call): every new item starts at "–"** (or its track's key). The key last chosen for another item is no longer carried to new items; it is only the fallback when no key can be found.
- **Assumption (my call): a key picked by the user before the first analysis becomes the track's key** when a listening pass runs, so later items on that track follow it.
- **Assumption (my call): "Auto" on an analysed item (Find Key) is removed** with the Auto entry. To find a key again: Find Range and Key Again, then pick it, or correct the key by hand.
- **Assumption (my call): a batch offers no key candidates** in its finished card; a close call is corrected per item afterwards.
- Carried from revision 1: only Major and Natural Minor are found; the key is remembered per track; the key is found once per track and then stays; a result written by a cancelled or failed analysis never survives.
- **Measured in real REAPER (2026-11-25):** the listening pass took 16.4 s for a track of 101 takes (19 minutes of audio), 0.85 s per minute. **Accuracy is not measured** beyond two tracks (E Major and C Minor found; the user has not yet confirmed C Minor).
- **RB9:** the card is capped to the script window like the window's other modals (seen in REAPER on 2026-11-27: dimmed dark, not a separate window). Only a window too small for any modal makes it its own OS window.
- **Decided while building (2026-11-27):** in a batch, the first item with a picked key leads its track, and items without a pick on that track follow it; picking a key applies Major only when Key was "–" (over a shown track key the shown scale is kept); a key changed by hand always counts as "your choice" afterwards; the finished card's OK is a plain button; a re-analysis that sets values back to the defaults says so in the card.
- `ds-lint.py` baseline: not available. The linter stops with "theme.lua palette drifted from ds-lint's port of build_palette" (a tooling issue, recorded since 2026-11-24).
- HC6 conflicts: None.
