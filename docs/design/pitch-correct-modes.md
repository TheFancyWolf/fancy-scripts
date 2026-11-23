# Design: Fancy Pitch Correct — Mode: Natural, Classic and Hard

Target file(s): `Pitch/Fancy_Pitch Correct.lua`
Archetype(s): main window → Editor / canvas (the top bar's value bar, the note right-click menu's value rows and the note canvas)
Status: Approved
Date: 2026-11-23
Approver: TheFancyWolf (in chat, 2026-11-23)

## Summary

Fancy Pitch Correct gets a **Mode** with three choices. **Natural** is today's correction, left exactly as it is. **Classic** and **Hard** are the deliberate auto-tuned effect: Classic jumps between the notes of the scale (Tighten sets how fast), Hard holds one flat scale note. Mode is a dropdown next to Tighten in the top bar and a row in the note's right-click menu. This is the second attempt: the first (branch `feat/pitch-correct-overtune`, deleted 2026-11-23) made sounds the user liked but changed Natural's code in place, and Natural no longer felt right. So this design's first rule is that Natural's code is not edited at all, and that is proven before anything else is built. Primary display: the note canvas (unchanged). Primary action: dragging a value (unchanged).

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| New: Mode dropdown in the top bar, notes selected: sets the mode of the selected notes | none new (the analysed notes in memory, the item's Key and Scale) | take pitch envelope points; the note model on the take | take data (`P_EXT`), inside the edit's undo block | Y: one undo block holds envelope and model; the script reloads the model when the project state changes; nothing else is stored |
| New: Mode dropdown in the top bar, nothing selected: sets this item's mode, used by every edited note of the item that has no mode of its own | as above | as above | take data, inside the undo block. No ExtState: there is no project-wide or global mode | Y: as above |
| New: Mode row in the note right-click menu: the menu's note, or every selected note when it is one of them | as above | as above | take data, inside the undo block | Y |
| Existing Key and Scale combos: when the open item has a Classic or Hard note, a change now rewrites that item's envelope at once | the item's notes | take pitch envelope points; Key and Scale in the take data (as today) | take data inside the undo block; the last-used Key and Scale in ExtState (as today) | Y for everything the user can hear and see on the item: the envelope joins the item's Key and Scale in the undo block the change already has ("Change Key/Scale"). The ExtState copy only seeds the next new item, as today |
| Existing Tighten on a Classic note: sets how fast the pitch jumps | n/a | as today | as today | Y (as today) |
| Existing Strength, Tolerance, Slide In on a Classic or Hard note, and Tighten on a Hard note: stored but not used | n/a | as today | as today | Y (as today) |
| Existing Reset to Original, Split, Trim, Merge, Bypass | as today | as today | as today | Y (as today). Reset to Original also clears the note's mode; Split and Trim carry it; a merged note takes the first note's mode |
| Existing, unchanged in every way: everything about a Natural note (Tighten, Tolerance, Slide In, Strength, the pitch drag, pitch points, joins and fades), analysis, Separation, the stale ("Outdated") check | as today | as today | as today | as today |

## Natural stays untouched: the contract

This section comes before the sound and the interface on purpose. It is what the first attempt lacked.

**What went wrong last time.** The first attempt edited the Natural correction in place: about ten changes inside `K.correction_build` (the per-note shifts, the join rules, the blend, the note writer), a changed loader for Tighten, and a mode default saved globally in REAPER's settings. The earlier build's 60 tests still passed, and on paper the final arithmetic for a Natural note was the same, so the exact cause was never found: a direct comparison of the written envelope was started and stopped before it gave a result. The likely causes, none confirmed:

- notes saved by the early builds (Tighten above 100 %, a stored mode) were read back as Classic or Hard by the later ones;
- a mode default saved outside the project reached every edited note in every item;
- an edit inside the shared correction code that the tests did not cover.

This design removes all three routes instead of guessing which one it was.

**Rule 1: Natural's code is not edited.** These keep the exact text they have on `main` at commit `810bc35` (v2.18.0):

- the body of today's `K.correction_build` (it may be given a new name, see Rule 2; not one line inside it changes);
- `K.tighten_line`, `K.note_body`, `K.points_offsets`, `is_note_modified`, `K.controls_edited`, `K.JOIN`;
- the Tighten and Tolerance lines of `K.controls_load`;
- the zone drags on a note (`K.ZONE_CONTROLS`, their ranges, speeds and accumulation) and `param_drag`;
- the `BAR_VALUES` entries (ranges, formats, tooltips) and `_lib/theme.lua` (no change at all: no new colour, no new helper).

**Rule 2: Classic and Hard are built beside it, not inside it.** The name every caller uses today (`K.correction_build`) becomes a thin new function:

```
correction_build(notes, item_len):
  if no note of this item is Classic or Hard in effect:
      return natural_build(notes, item_len)        ← today's function, same arguments, its own result
  otherwise:
      A = natural_build(the same notes, with each Classic or Hard note shown to it as a bypassed note)
      B = mode_build(the Classic and Hard notes)   ← new code, see "Sound rules"
      return A's points outside the Classic and Hard notes' own time ranges, plus B's points
```

- "Classic or Hard in effect" means: the note is edited, is not bypassed, and its mode (its own, else the item's) is Classic or Hard.
- With no such note, which is every item that exists today, the new function does one check and hands back Natural's own result. Nothing of the new code touches the numbers.
- Showing a Classic or Hard note to the Natural build as bypassed uses a rule Natural already has: next to a note that is not corrected, a Natural note's blend stays on its own side and ends at the boundary. That is exactly the rule decided for Classic and Hard neighbours, so no join code is changed. The stand-in is a separate object; the real note is not changed, and the list keeps its order so note numbers in the result still match.
- Three things the new function must do in the mixed case, because other code reads them: put the frame shifts on the real Classic and Hard notes (the pitch-point aim reads them); add those notes' time ranges to the result (the Preview Curve draws only inside the ranges); and treat a Classic or Hard note's own range as closed when dropping Natural's points, so a Natural blend's last point and a touching note's first point never land on the same time (the envelope writer drops a point within 0.1 ms of the one before).

Checked against the code by an independent read (2026-11-23): all three callers look the build up by name at call time, the bypass branch of the join code behaves as described, the item's mode resolves correctly for other items through the existing item level, and every stored item already has its own Key and Scale.

**Rule 3: nothing outside the item decides a note's mode.** A mode lives on a note or on its item, both in the take data and both inside undo. There is no global default, so a choice made in one item or project can never change another.

**Rule 4: leftovers from the first attempt stay dead.** The new stored names must differ from the first attempt's (`tune_mode` on notes, `pitch_tune_mode` in REAPER's settings, which still holds `0` on this machine). The loader already drops note values it does not know, so an old `tune_mode` is ignored. A Tighten above 100 % saved by the first builds is read as 100 % Natural by the untouched loader line, as on `main` today.

**Rule 5: proof first.** Before any Classic or Hard code is written:

1. From `main` at `810bc35`, record what the build writes (points, spans, ranges and every note's frame shifts) for a set of note models: the existing spec's synthetic phrases covering Tighten, Tolerance, Slide In, Strength, a moved note, pitch points, joins, fades and a bypassed neighbour, plus one real analysed vocal from the user's project when its take data can be read from the project file.
2. Add a test that the working script writes exactly the same (equal, not "close") for every one of them, and a test that the text of the Natural functions in Rule 1 equals `main`'s.
3. Both tests run in the existing `docs/superpowers/tests/pitch_correct_spec.lua` with its existing loader. No new fake of REAPER is built.

The synthetic phrases and their recorded output are committed, and those tests must pass at every commit of the work. The real vocal's analysis is the user's own material and the repo is public, so it is **not committed**: its model and recorded output are kept outside the repo, the test for it runs on this machine and is skipped where the file is absent, and it must pass before the work is called done.

**The few places existing code may be touched,** each only by adding:

| Place | What is added |
|---|---|
| `K.NOTE_CONTROLS` | one row for the mode (merge: first note's; counts as edited when stored, like Strength) |
| `K.controls_load` | one line that holds a loaded mode to its three values |
| the definition line of today's `K.correction_build` | its new name, so the thin function above takes the old one |
| `K.correction_view`'s change signature | the mode of each note and the item's scale, so the Preview Curve redraws when they change |
| the Key and Scale combo handlers | a call that rewrites the envelope when the item has a Classic or Hard note, and otherwise does exactly what the handlers do today |
| the top bar | one new unit (the Mode dropdown) in the unit lists and width plans; in the value control, the dim text and one tooltip line for a value the selected notes do not use |
| the note menu | one new row; the same dim text on a value row that is not used |
| `K.zone_text` | a suffix on the readout of a value a Classic or Hard note does not use |
| the canvas highlight of a hovered or dragged value (`K.draw_setting_hint` and the status line beside it) | a Classic or Hard note gets no Tolerance band and no Strength outline; when every note the value reaches is Classic or Hard, the status line says it is not used there. The existing status texts stay for every other case |
| Help rows | one row |
| the test export at the end of the file | what the new tests need |

A Natural note never takes any of the added branches: each one is behind "this note is Classic or Hard".

## Sound rules

"Placed pitch" means the sung pitch moved by the note's own move (where the note block sits against where it was sung), so Classic and Hard follow a note the user has dragged.

| Mode | What the note sounds like | Values that act |
|---|---|---|
| Natural | as today | as today |
| Classic | the note is always on a note of the scale. When the singing crosses to another scale note the pitch goes there, so slides become stairs and wide vibrato flips between two notes | Tighten: how fast the pitch goes to the next scale note. 0 % glides (about 100 ms), 100 % steps at once |
| Hard | one dead-flat scale note for the whole note, instant steps to the next note | none |

Rules for both:

- **Scale.** The item's own Key and Scale (the take the build is for, not whatever the combos show, so the "Outdated" check of other items stays right). With Chromatic, the nearest semitone. A pitch exactly half-way goes to the lower note.
- **Whole note.** Every frame of the note is corrected, the slide into it and the fall out of it included.
- **Literal.** Strength, Tolerance and Slide In do not act (nor Tighten in Hard). Pitch points are still added on top, as for Tighten today.
- **Detection errors.** A frame more than 3 semitones from the note's sung average, or with no pitch, keeps the correction of the frame before it, so a wrong-octave frame cannot write a jump.
- **Edges.** No fade and no blend: the correction starts at the note's first frame and stops at its end as a step. A Natural neighbour keeps its own blend on its own side (Rule 2). Two Classic or Hard notes closer than two fades (60 ms) hold the pitch across the gap and step once, at the second note's first frame.
- **Steps.** A step is written as a point that holds the old value 0.5 ms before the frame.
- **Untouched notes.** A note that was never edited is not corrected in any mode. Choosing Classic or Hard for a note is an edit.
- **The note block does not move.** A Classic or Hard note is drawn where it was placed. The Preview Curve draws what is written, so it shows the stairs or the flat line.

The arithmetic, per note (this reproduces what the user heard and liked in the first attempt; the constants are named so they are easy to change after listening):

```
GLIDE_S = 0.100 s    OUTLIER_ST = 3    STEP_S = 0.0005 s

move = placed centre − sung average
trusted(frame) = the frame has a pitch within OUTLIER_ST of the sung average
last = (scale note nearest the placed centre) − sung average     ← used until the first trusted frame

Hard:
  target = scale note nearest the placed centre
  each frame:  if trusted: last = target − sung;   shift = last

Classic:
  tau = GLIDE_S × (1 − Tighten)
  each frame, in time order (dt = time since the frame before):
    if trusted:
      goal = scale note nearest (sung + move)
      first trusted frame:   line = goal
      else if tau × 3 ≤ dt:  line = goal, and a step is written before this frame when goal changed
      else:                  line = line + (1 − e^(−dt / tau)) × (goal − line)
      last = line − sung
    shift = last

Then, both modes: add the note's pitch-point offsets.
```

## References

- Native REAPER analogues: ReaTune's automatic mode (pull to the nearest note of a scale, with an attack time) for Classic; the item properties' pitch-mode dropdown for a mode chosen from a list. Conventions matched (CN6): Ctrl/Cmd-drag is fine adjust, right-click opens a menu, Shift and Alt keep their meanings, percent as whole numbers.
- Baseline capture: the docked window on `main` v2.18.0 in the user's session, taken 2026-11-23 after the first attempt was reverted (top bar reading `Defaults · Tighten – · Strength 100% · Tolerance 8¢ · Slide In – · Separation 50%`, one analysed item, notes drawn, no error window). `ds-lint.py` summary: did not run ("theme.lua palette drifted from ds-lint's port of build_palette"), so there is no mechanical baseline; that is a fault of the tool, separate from this design.
- The first attempt: deleted branch `feat/pitch-correct-overtune`, last commit `d2edb0f`, still readable with `git show d2edb0f:"Pitch/Fancy_Pitch Correct.lua"` until git cleans it up. Its `K.overtune_line` is the reference for the arithmetic above. Its code is not copied: it sits inside the Natural build, which is what this design forbids.

## Context and job stories

Carried over from the earlier Pitch Correct designs and the first attempt's checkpoint (2026-11-22): it lives on the existing canvas, docked or floating, is used all session, during playback, mostly by mouse.

1. When a phrase should sound auto-tuned, I want to pick Classic or Hard for its notes, so I can get the effect without a second tool.
2. When a whole item should be over-tuned, I want to set its mode once, so every note I edit there takes it.
3. When playback loops over the phrase, I want to switch a note's mode and hear it on the next pass, so I can choose by ear.
4. When I have moved a note, I want the effect to snap around where I put it, so my own pitch choices are kept.
5. When I change the song's key, I want the Classic and Hard notes to follow at once, so what I hear matches the key shown.
6. When I keep working in Natural or open an older project, I want everything to sound and feel exactly as before, so I can trust the update.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | The Mode dropdown next to Tighten in the top bar | It decides what the note sounds like and what Tighten means; it must be readable without opening anything |
| 2 one disclosure away | The Mode row in the note right-click menu | Per-note choice while working on one note: a few times per session |
| 3 Settings | None | The glide constants are tuned by ear once and are not user settings |

## Information architecture

Regions touched (no existing control is moved, removed or changed):

1. **Value bar.** One new unit, the Mode dropdown, right after Tighten. It follows the bar's rule: with nothing selected it shows and sets the item's mode; with notes selected it shows and sets theirs.
2. **Note menu.** One new row, Mode, above the Tighten row.
3. **Value bar and note menu, existing values.** Unchanged controls. A value the selected notes do not use is drawn dim and says why.
4. **Note canvas.** No new drawing. A Classic or Hard note looks like any edited note; its Preview Curve shows stairs or a flat line because that is what is written.
5. **Help modal.** One new row.

Primary display: the note canvas (unchanged). Primary action: dragging a value (unchanged). Disclosure levels: the bar and the canvas are level 1, the note menu is level 2 (IA2).

Who decides a note's mode, first match wins: the note's own mode → the item's mode → Natural.

## Wireframes

`‹ ›` marks a value drawn dim because the selected notes do not use it.

**Wide (one row), nothing selected:**

```
[◆] [V_Main.wav] [E▾] [Major▾] │ (Defaults) [Tighten –] [Natural ▾] [Strength 100%] [Tolerance 8¢] [Slide In –] [Separation 50%]   […][×]
```

**Wide, three Classic notes selected:**

```
[◆] [V_Main.wav] [E▾] [Major▾] │ (3 notes) [Tighten 40%] [Classic ▾] ‹Strength 100%› ‹Tolerance 8¢› ‹Slide In 0%› [Separation 50%]   […][×]
```

**The dropdown in its states** (one control, fixed width from its longest text, `Natural`):

```
[Natural ▾]   [Classic ▾]   [Hard ▾]   [Mixed ▾]          [Natural ▾]
 the item's mode, or the selected        selected notes     disabled: no item,
 notes' mode                             differ             not analysed, analysing

open:  ┌─────────┐
       │ Natural │
       │ Classic │
       │ Hard    │
       └─────────┘
```

**Default floating size (two rows, as today's first-use plan), one Hard note selected:**

```
[◆] [V_Main.wav…] [E▾] [Major▾]                                                        […][×]
(1 note) ‹Tighten 0%› [Hard ▾] ‹Strength 100%› ‹Tolerance 8¢› ‹Slide In 0%› [Separation 50%]
```

**Narrow docker (~260 px):** today's narrowest plan, two units per row, gains the dropdown and so one row:

```
[◆] [V_Main…]        […][×]
[E▾] [Major▾]
(3 notes) [Tighten 40%]
[Classic ▾] ‹Strength 100%›
‹Tolerance 8¢› ‹Slide In 0%›
[Separation 50%]
```

**Wide short strip (1200 × 150):** the one-row plan when it fits; the bar is wider than today by the dropdown, so where one row no longer fits the existing plan picker takes the two-row plan and the canvas keeps the rest.

**Note menu, the menu's note is one of three selected Classic notes:**

```
│ Bypass note                                     │
│ ─────────────────────────────────────────────── │
│ [ Classic    ▾ ] Mode [note] (3 notes)          │
│ [     40%      ] Tighten (3 notes)              │
│ ‹[    8 ¢     ]› Tolerance [global] (3 notes)   │
│ ‹[     0%     ]› Slide In (3 notes)             │
│ ‹[    100%    ]› Strength [global] (3 notes)    │
│ ─────────────────────────────────────────────── │
│ Snap to Semitone                              S │
│ …                                               │
```

What truncates, wraps or hides (LG4): nothing new. The dropdown has a fixed width and never truncates; the bar wraps by its existing plans; only the item badge truncates, as today.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Mode dropdown | empty | An analysed item with nothing selected shows the item's mode (`Natural` until changed); there is no blank state | ST6 |
| Mode dropdown | working | n/a: a mode change writes as fast as any note edit today | ST3 |
| Mode dropdown | error | n/a: three fixed choices; a stored value outside them is read as "not set" | ST7 |
| Mode dropdown | disabled with reason | No item, not analysed, or analysis running: disabled, with the value bar's existing reasons in the tooltip | EP2 |
| Mode dropdown | overflow / long names | Fixed width from its longest text, so a change never moves the bar | LG4 |
| Mode dropdown | missing dependency | n/a: nothing new is required | HI7 |
| Mode dropdown | Fancy Dark / Match Theme | The standard combo face and list in both modes; no colour of its own | CL4 |
| Mode dropdown | mixed selection | `Mixed`; choosing a mode sets every selected note | ST4 |
| Strength, Tolerance, Slide In, Tighten values | disabled with reason | Every selected note is Classic or Hard (for Tighten: every one is Hard): the text is dim, the value stays editable, and its tooltip adds why. With a mixed selection, or nothing selected, the values look as today | EP2 |
| Note on the canvas | empty | An item with no notes keeps today's canvas message | ST6 |
| Note on the canvas | error | A Classic or Hard note whose frames are all detection errors is written flat at its scale note, never with a jump | ST7 |
| Note on the canvas | overflow / long names | The drag readout keeps its clamping to the note area; its longest new text is `Tolerance: 8¢ (not used in Classic or Hard mode) (12 notes)` | LG4 |
| Note on the canvas | Fancy Dark / Match Theme | No new colour: a Classic or Hard note uses the edited-note colours, already fitted in both modes | CL4 |
| Whole item | working | A Key or Scale change with Classic or Hard notes: the envelope is rewritten in the same frame and the status pill confirms it | ST3 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Value bar → Mode | Click opens the list, click chooses. HC2 / HC3 n/a: discrete. No wheel, no right-click menu. Notes selected: the choice is stored on every selected note. Nothing selected: it is stored as the item's mode (choosing Natural removes the item's mode). Choosing what is already shown does nothing | Natural | the three names; `Mixed` when the selected notes differ | n/a: discrete | "Change Mode", one undo point per choice; none when nothing changed | Not destructive: one Ctrl/Cmd+Z restores envelope and model; nothing is stored outside the take. Setting the item's mode posts a status message with the count of notes it reached |
| Note menu → Mode | The same list. Acts on the menu's note, or on every selected note when it is one of them (as the value rows do) | the note's mode in effect | the three names; the row shows `[note]` when the note has its own mode, `[item]` when it takes the item's, and `(N notes)` as the value rows do | n/a: discrete | "Change Mode" | Not destructive, as above |
| Existing: Tighten (bar, left side of a note, note menu) | Unchanged gestures, range, speed and reset. On a Classic note the value is the jump speed; on a Hard note it is stored but not used | as today | as today; the readout on a Hard note adds ` (not used in Hard mode)` | as today | as today | n/a |
| Existing: Strength, Tolerance, Slide In | Unchanged. On a Classic or Hard note they are stored but not used; the readout of a drag on such a note adds ` (not used in Classic or Hard mode)` | as today | as today | as today | as today | n/a |
| Existing: Key combo, Scale combo | Unchanged gestures. New consequence: when the open item has a Classic or Hard note, its envelope is rewritten at once. With none, the handlers do exactly what they do today | as today | as today | n/a: discrete | "Change Key/Scale", one undo point per change, as today; with Classic or Hard notes the same undo point also holds the rewritten envelope | Not destructive: one Ctrl/Cmd+Z puts the envelope and the item's Key and Scale back; a status message names what changed (HC4) |
| Existing: Reset to Original | Unchanged gesture. It clears the note's own mode with its other values | as today | as today | n/a | as today | as today |

Keyboard map: no new keys. Esc (HC5): the open list or menu closes first, then an active drag reverts, then the selection, then the window when floating; all as today. Space is forwarded exactly as today (HC6): not while a list or menu is open, as with the Scale list and the note menu now. No key repeats are added (EP6). The new row is in the Help modal (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | Dropdown and menu choices: `Natural` · `Classic` · `Hard`. Mixed selection: `Mixed`. Menu row label: `Mode` |
| tooltips | Mode dropdown, first lines: `Mode: how an edited note is corrected.` / `Natural: Tighten, Tolerance, Slide In and Strength shape the note.` / `Classic: the auto-tuned effect. The pitch jumps between the notes of the scale; Tighten sets how fast.` / `Hard: one flat note of the scale.` Then one scope line: nothing selected `Changes this item: every edited note without its own mode.` · one note `Changes the selected note.` · several `Changes the 3 selected notes.` Added line on Strength, Tolerance and Slide In when every selected note is Classic or Hard: `Not used in Classic or Hard mode.` Added line on Tighten: every selected note Hard `Not used in Hard mode.` · every selected note Classic `In Classic mode: how fast the pitch jumps between scale notes. 0% glides, 100% steps at once.` The existing tooltip texts are not changed |
| empty / error / confirm | No new empty or error text and no confirm dialog. Disabled reasons reused from the value bar |
| status messages | Value hovered or dragged in the bar when every note it reaches is Classic or Hard: `Not used in Classic or Hard mode` (Tighten on Hard notes: `Not used in Hard mode`) · Item's mode changed: `Mode: Classic for this item (12 edited notes)` · with no edited note yet: `Mode: Classic for this item. Notes you edit will use it` · Key or Scale change that rewrote the item: `Key changed: 12 Classic / Hard notes follow E Major` · drag readout suffixes: ` (not used in Classic or Hard mode)` · ` (not used in Hard mode)` |
| undo labels | `Change Mode` (new) · `Change Key/Scale` (unchanged) |
| Help modal row | `Mode (top bar, note menu)` — `Natural, Classic (the pitch jumps between scale notes; Tighten sets how fast) or Hard (one flat scale note)` |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Mode dropdown in the bar | `Theme.combo` (width, placeholder `Mixed`, disabled, tooltip options), placed like the bar's other units | theme defaults; the bar's existing gaps (`Theme.layout.sm`) |
| Mode row in the note menu | `Theme.combo` at the value rows' width, then the row's label and tags as the value rows draw them | theme defaults; the dim text for `[note]` / `[item]` as the existing rows |
| A value not used by the selected notes | the script's existing value-drag control, its text colour pushed for that control | palette `text_dim` from `Theme.get_palette` |
| Tooltips | `Theme.tooltip` through the bar's existing for-tooltip hover check | theme defaults |
| Status and readout pills, Preview Curve, note blocks | the script's existing canvas drawing | existing canvas palette keys (unchanged) |

## Library proposals

None. `_lib/theme.lua` is not changed by this design.

## Acceptance criteria

Natural (checked before and after everything else):

| Check | Expectation |
|---|---|
| Same numbers | For every recorded note model, the working script's build equals `main`'s at `810bc35` exactly: points, spans, ranges and every note's frame shifts |
| Same text | The functions listed under Rule 1 have the text they have on `main` at `810bc35` |
| Same in REAPER | Opening a project whose envelopes were written by v2.18.0 shows no item as "Outdated", and editing a Natural note writes what v2.18.0 writes |
| Same feel | Tighten, Tolerance and Slide In drags on a Natural note have today's range, speed, readout and reset; the user confirms by ear and hand in real REAPER before the work is called done |
| No reach | With every note Natural, the new code runs one check per build and nothing else. No value is read from REAPER's settings for the mode |

Rules:

| Rule | Expectation |
|---|---|
| ST1 | The mode of the selection, or of the item, is always shown in the bar. At rest a Classic or Hard note shows by its Preview Curve (stairs, flat). There is no mode colour (decided by the user); with the Preview Curve layer off, the mode shows when the note is selected |
| ST2 | A mode choice rewrites the envelope and the Preview Curve in the same frame; setting the item's mode and a Key or Scale rewrite post a status message |
| ST3 | n/a: every write is as fast as a note edit today |
| ST4 | The Preview Curve is what is written. `Mixed` says the selected notes differ. A value that is not used says so |
| ST5 | n/a: lifecycle unchanged |
| ST6 | No blank state is added |
| ST7 | A wrong-octave frame never writes a jump; a stored mode outside the three choices is read as not set |
| UC1 | One "Change Mode" undo point per choice, none when the choice is what was shown. A Key or Scale change keeps its one undo point, which also holds the rewritten envelope when the item has Classic or Hard notes |
| UC2, HC5 | Esc: list or menu → active drag (revert) → selection → window when floating, through `Shortcut()` |
| UC3 | The note's mode and the item's mode are in the take data inside the undo block; undo and redo restore them through the existing reload |
| UC4 | REAPER's item, track and time selection are never changed |
| UC5, HC3 | n/a for Mode: discrete. Reset to Original clears a note's mode. The existing values keep their double-click reset and typed entry |
| EP1, HC4 | No destructive action is added. Mode changes and the Key or Scale rewrite are fully undone by one Ctrl/Cmd+Z, store nothing outside the take, and post a status message where many notes change; no confirm |
| EP2 | A value that is not used stays visible and editable and says why, in the tooltip and in the drag readout (so it shows with tooltips off). The disabled dropdown gives the bar's reason |
| EP3 | A loaded mode is held to its three values; the existing values keep their clamps |
| EP4 | The mode belongs to the note and the item, never to a list position |
| EP5 | No control appears or disappears with the mode or the selection |
| EP6 | No new keys; Shift and Alt are not given a new meaning |
| CN1 | The dropdown is `Theme.combo`; tooltips go through `Theme.tooltip`; no hand-built substitute |
| CN2, CN3 | Tokens and palette keys only; no colour, size or spacing is written in the script |
| CN4 | One name each: "Mode", "Natural", "Classic", "Hard". No "over-tune", "glide", "frame" or internal name in user-facing text |
| CN5, HP1 | The Help row and the tooltips match the handlers; the CHANGELOG entry matches the code |
| CN6, HC2 | n/a for Mode: discrete. The existing values keep Ctrl/Cmd-drag fine adjust; right-click on a note opens its menu |
| RC1 | The three modes are explained in the dropdown's tooltip and the Help row; the names themselves are on the control, so nothing depends on a tooltip alone |
| RC2 | Three plain names and whole percentages; no milliseconds, semitone fractions or frame counts in any string |
| EF1 | n/a for Mode: discrete, one click to open and one to choose. No wheel: the canvas scrolls |
| EF2, HC6 | Space forwarding is not changed: it pauses while the Mode list is open, as it does for the Scale list and the note menu today |
| EF3 | The pitch and time scales are not changed by a mode choice |
| IA1 | The dropdown is Tier 1, the menu row Tier 2, nothing in Settings |
| IA2 | Two disclosure levels: the bar and canvas, then the note menu |
| IA3 | Primary display and primary action unchanged; no new text size or weight |
| IA4 | One control is added and it always has an effect or a reason; no value is left without effect unexplained |
| LG1, LG2, LG3 | The dropdown sits on the bar's baseline with the bar's gaps and a fixed width |
| LG4 | Works in a ~260 px docker and a 1200 × 150 strip as wireframed; nothing truncates |
| MT1 | The dropdown has the bar's control height |
| MT2 | The dropdown has the standard combo rest, hover, open and disabled looks |
| CL1, HC1 | The dropdown's text and the dim text of an unused value are at least 4.5:1 on their faces in both theme modes (`text_dim` is fitted for control faces) |
| CL2 | The mode is told by its name in the bar and the menu and by the shape of the Preview Curve, never by colour |
| CL3 | No red is used |
| CL4 | Checked in Fancy Dark and Match Theme (a dark and a light REAPER theme) |
| DV1 | Canvas gestures are unchanged: drag to change, fine with Ctrl/Cmd, live preview, commit on release |
| HI1, HI2, HI3 | n/a: window lifecycle, flags and toolbar unchanged |
| HI4 | The model is written on a choice or on release, never per frame |
| HI5 | A note's Classic or Hard line is computed when its mode, its Tighten, its placed pitch, its analysis, its pitch points or the item's Key or Scale change, and cached; never per frame |
| HI6 | The dropdown keeps one stable ID while its text changes |
| HI7 | n/a |
| RB9, RB15, RB17, RB19 | No modal is added; tooltips go through the for-tooltip hover check; the dropdown's ID does not come from its text; every ReaImGui name is checked against the names file before use |

## Build order and checks

1. **Proof of Natural** (Rule 5), on a new branch from `main` at `810bc35`. Nothing else until it passes.
2. **The sound**, with no interface: the thin build function, the Classic and Hard arithmetic and writer, the stored mode on notes and items, the Key and Scale rewrite. Checked in the spec file (pure arithmetic, like today's correction) with the Natural tests still passing.
3. **The interface:** the dropdown, the menu row, the not-used texts, the Help row.
4. **Real REAPER,** by the testing protocol: the four "Natural" checks above first, then Classic and Hard on the user's vocal, undo and redo of a mode change and of a Key change, both theme modes, docked narrow and floating.
5. **The user listens,** to Natural first, then to Classic and Hard. The glide constants are changed only after this.

## Set aside (not in this design)

The first attempt ended with some extras that change how Natural's own controls look. They are left out so that this change cannot alter anything about Natural, and can come back as their own small design once this one is in and Natural is confirmed:

- one colour per value everywhere (Tighten green, Strength blue, Tolerance yellow, Slide In orange);
- a progress bar under the drag readout of every value dragged on a note, and the same bars in the note menu;
- Tolerance's band on a note also shown while Tighten is at 0 % (on hover or drag);
- tooltips set in short paragraphs, gestures one per line.

Tried in the first attempt and dropped by the user, not to be repeated: Tighten running to 200 % with a sticky stop at 100 %; mode text on the dial; mode colours on notes or on Tighten; a vertical gauge beside the note; a cap on drag distance when zoomed in.

Also not in this design: formant control, new detection ranges and other sound-design features (each its own later project); a user setting for the glide time.

## Open questions / assumptions

**Why.** The script corrects vocals transparently and well. The user wants it to make the over-tuned vocal on purpose too, in the same tool, and must be able to trust that the transparent correction is exactly what it was.

**Goals.** Classic and Hard as the user heard and liked them. A mode for a note, a selection or a whole item. Natural identical to v2.18.0 in sound, feel and look, and proven so.

**Non-goals.** Anything listed under "Set aside".

**Anti-goals.** Any change to how a Natural note sounds, feels or is drawn. Any change to an item saved before this work. A setting outside the item that changes its sound. Reviving data left by the first attempt.

Approaches considered for how Classic and Hard are added:

- **Beside Natural: a thin function chooses, Natural's code is not edited (chosen).** Natural is identical by construction for every item without a Classic or Hard note, and the join rule comes from Natural's existing treatment of a note that is not corrected. It costs a second pass for items that mix modes, and a stand-in object per Classic or Hard note.
- **Inside the Natural build, behind mode checks (the first attempt).** Least new code, but every check is an edit to the function that must not change, and that is where the trust was lost.
- **A separate envelope writer for Classic and Hard items.** Total separation, but an item could not mix Natural and Classic notes, which the per-note mode needs.

Calls made in this doc, for you to check. The first three differ from where the earlier chat ended:

- **The mode with nothing selected belongs to the item, not to every item.** The earlier chat made it a global default saved in REAPER's settings. That would let a choice made in one project change edited notes in another the next time they are written, which is the kind of reach this redo is meant to rule out. Here it is stored with the item and is undoable; a new item starts at Natural. Say so if you want the global default back.
- **The colour and readout extras are set aside** (see "Set aside"). They change Natural's look, and you asked for Tighten to be left as it is. They can be added as a follow-up design.
- **New stored names,** so nothing saved by the first attempt comes back to life.
- **Choosing a mode on a note stores it on that note,** even when it equals the item's mode, and makes the note count as edited (as a Strength value on a note does today). On a note that was never edited, choosing Natural changes nothing you can hear but the note is drawn as edited; Reset to Original clears it.
- **Strength is dimmed too** on Classic and Hard notes, with Tolerance and Slide In: it does not act there.
- **Tighten's own tooltip text is not changed.** The line about Classic appears only when every selected note is Classic.
- **The dropdown shows the mode name alone** (`Classic ▾`), like the Key and Scale dropdowns; its tooltip and the Help row name it "Mode".
- **Glide:** 100 ms at 0 % Tighten, falling evenly to none at 100 %, as in the last build you heard.
- **Tests:** the proof runs in the existing spec file with its existing loader. Nothing that imitates REAPER is added.
- **Your vocal is not committed.** The proof on your real vocal runs on this machine only; the public repo gets the synthetic phrases.
- **Analyze puts the item's mode back to Natural,** as it already drops an item's own Strength and Tolerance (the notes are new and unedited after it). A Separation re-split keeps the mode. Keeping it across Analyze would mean editing the analysis code, which this design avoids.
- **The canvas highlight follows the mode:** no Tolerance band and no Strength outline on a Classic or Hard note, and the status line says "not used" instead of today's advice, which would be wrong there.
- **Space is not forwarded while the Mode list is open,** the same as the Scale list today.

Left to the builder: the names of the new stored values (any but the first attempt's) and of the new functions; how the stand-in for a Classic or Hard note is made; how the two point lists are merged at a Classic or Hard note's edges; the caches; how the real vocal's model is read for the proof (and, when it cannot be read, saying so and using the synthetic phrases only).

HC6 conflicts: None.
