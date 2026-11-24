# Changelog

All notable changes to Fancy Scripts will be documented here.

## [Unreleased]

- **Fancy Pitch Correct v2.22.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Value levels and Apply to other items:
  - **Items keep their own copy of the starting values**: every item takes a copy of the starting values (Key, Scale, Separation, Mode, Tighten, Tolerance, Strength, Slide In) when it is first analysed or loaded, and keeps it. Changing the starting values later does not change any item that already has its copy. Analysing an item again keeps its values. Items analysed by an earlier version take the current starting values whenever they are opened, until you edit them once in 2.22: one edit saves their own copy. Analysing them again also gives them their own copy, but discards their note edits.
  - **Separation starts at 50%**: the earlier "Separation" preference is not carried over; new items start at 50%.
  - **Item values now reach every note**: an item's value is used by every note of the item that has no value of its own, edited or not (before, a note you had not edited ignored the item's Tighten). So raising the item's Tighten on an item with no edits now writes a correction.
  - **The bar no longer changes other items**: the top bar edits only the open item, or the selected notes, and the pill at its left says which ("This item", "N notes"). Its drags and typed values no longer save the starting values.
  - **Key no longer sets the key for new items**: Key and Scale in the top bar change the open item only. New items take the starting Key and Scale.
  - **Apply to other items**: click the pill, then "Apply to other items…", to give this item's values to the selected items, to every pitched item, or to new items only. The confirm names what will be lost (items' and notes' own values, a change of key, notes split again). With "Keep changes already made to items and notes" ticked, values an item or a note already had of its own are kept, and an item with edited notes is not split again. All the item changes are one undo step; the starting values are saved too, and that part cannot be undone with Cmd/Ctrl+Z. A single value can be applied from its right-click menu ("Apply Tolerance to other items…"), and Key and Scale from theirs ("Apply Key to other items…").
  - **Reset this item**: the pill menu shows the starting values and resets the open item to them in one undo step.
  - **Separation per item, and for a stretch**: Separation is now a value of each item. With notes selected, changing it splits only the stretch from the first to the last selected note again, as one undo step "Re-split selected notes"; the notes outside it are not changed and the new notes come back selected.
  - **Three groups**: the values are grouped under small captions, Notes (Separation), Correction (Mode, Tighten, Tolerance) and Shaping (Strength, Slide In), with Shaping drawn smaller. When the window is too narrow for the captions, each value's tooltip names its group.
  - **No undo step when nothing changed**: a drag that ends where it started, or a typed value equal to the old one, adds no undo step.
- **Fancy Pitch Correct v2.21.1 (`Pitch/Fancy_Pitch Correct.lua`)** — Octave spikes on a moving pitch:
  - **Put back while the voice glides**: a short spike an octave too low or too high inside a note was left in when the pitch moved during the spike, so the jump back was not a whole octave (down 12.4 semitones, back up 10.7). A jump back soon after counts as one if it is within 2 semitones of an octave; a jump into the wrong octave still has to be within 1.
  - **Analyze again**: items analysed before keep their old readings until you analyze them again.
- **Fancy Pitch Correct v2.21.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Analyze All Selected Items:
  - **Analyze many items at once**: with two or more audio items selected in REAPER, the button on an item that is not analysed yet reads "Analyze All Selected Items" and analyses them one after another. The lines under it say how many items it will take; MIDI and empty items are skipped. With one item selected it is "Analyze Item" as before, and a note says that several can be analysed at once.
  - **From any item**: "Analyze Selected Items (N)" in the "…" menu does the same from an item that already has notes. With fewer than two audio items selected it is greyed out and says why. Analyze / Re-Analyze still acts on the open item only.
  - **Asks once**: when some of the selected items already have notes, one dialog lists those items (name, track and position) before anything starts. With nothing to replace it starts at once.
  - **One undo step**: the whole batch is a single undo step, "Analyze Pitch (N items)". Redo brings every item back, also in the Pitched Items list.
  - **Progress and Cancel**: the "…" button and the status line show one percentage for the whole batch, and the status line says which item of how many. "Cancel Batch" in the "…" menu stops and keeps the items already finished; closing the window does the same.
  - **What happened**: a closing message says how many items were analysed, how many have no pitched notes and how many could not be analysed. It stays until your next click or key in the window, or until an undo or redo changes one of the items.
  - **Carries on**: an item that cannot be analysed (deleted meanwhile, media offline) is left as it was and the batch goes on with the next one.
  - **Key and Scale**: an item that was analysed before keeps its own Key and Scale through a batch.
  - **Re-Analyze reads the true pitch**: an item that had corrections was analysed as corrected, so an edited note came out shifted by its old correction. Every analysis now reads the uncorrected audio; nothing is heard and the corrections stay exactly as they were if you cancel.
  - **Offline media**: an item whose media is offline is no longer stored as "no pitched notes"; the status line says its audio could not be read.
  - **Pitched Items is read-only while an analysis runs**: rows cannot be switched, bypassed or removed until it ends (a click on a row used to switch the item under a running analysis) Clear and Wipe in Settings wait for it too.
  - **For development**: when the ExtState `FancyScripts` / `pitch_dev_dump` holds a folder, every analysis also writes what the detector saw to a text file there, one per item. It is empty by default and has no control in the window.
- **Fancy Pitch Correct v2.20.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Pitch detection chooses across moments:
  - **Octaves read right**: each moment's pitch is now chosen together with the moments around it, not on its own. A note read an octave too high (a strong overtone) or too low (a shaky note start) is now read right at the source; the repair added in 2.19.1 stays as a second line.
  - **Detection setting**: it now only decides what counts as a pitched sound. It no longer changes which octave a note is read in (at Standard, a held note with a strong overtone could be read an octave high throughout).
  - **Timing**: the pitch line and the notes sit half an analysis block later (about 10 ms at Standard quality, 21 ms at High Quality), where the sound actually is; they were drawn early. The line now starts and ends that far inside the item.
  - **Item ends**: no more false low reading at the very end of an item.
  - **Analyze again**: items analysed before keep their old readings and timing until you analyze them again.
- **Fancy Pitch Correct v2.19.1 (`Pitch/Fancy_Pitch Correct.lua`)** — Octave errors in the analysis:
  - **No more spikes and drops**: a short stretch the analysis read one octave too high or too low (up to 150 ms, with the right octave around it) is put back in the octave of the singing around it.
  - **Note blocks sit on the pitch line**: a note's centre leaves out any pitch reading still in the wrong octave, so the block is drawn where the note was sung and Quantize picks the right note.
  - **Analyze again**: items analysed before keep their old readings until you analyze them again, and some of their notes may show as edited.
- **Fancy Pitch Correct v2.19.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Mode: how an edited note is corrected:
  - **Three modes**: **Natural** is as before; nothing about it has changed. **Classic** is the auto-tuned effect: the pitch jumps between the notes of the scale, and Tighten sets how fast (0% glides, 100% steps at once). **Hard** is one flat note of the scale.
  - **Where to set it**: the Mode dropdown directly left of Tighten in the top bar changes this item when nothing is selected (every edited note without its own mode) and the selected notes otherwise; the note's right-click menu has a Mode row. Each choice is one undo step, and changing the item's mode says how many edited notes it changed.
  - **Follows the note and the key**: Classic and Hard follow where a note was moved and the item's Key and Scale. A Key or Scale change rewrites them at once, as one undo step, and says how many notes follow the new key.
  - **Values a mode does not use**: Strength, Tolerance and Slide In are not used in Classic or Hard (nor Tighten in Hard). They stay visible but dimmed, and their tooltips, drag readouts and the status line say so.
  - **Untouched notes stay as sung**: a note you have not edited is never corrected, in any mode. Analysing an item again puts its mode back to Natural.
  - **One colour per value**: each value has one colour everywhere (Tighten green, Strength blue, Tolerance yellow, Slide In orange): its bar in the top bar, the same bar on its row in the note's right-click menu, a bar under the readout while it is dragged on a note, and its highlight on the notes. The bar's colour no longer tells a note's own value from the default; the `*` mark and the tooltip still do.
- **`_lib/theme.lua`** — New palette colour `orange` (between yellow and red, clearly apart from the error red); new canvas colours `param_tighten`, `param_strength`, `param_tolerance` and `param_slide_in` (green, accent, yellow and orange in Fancy Dark, the orange lightened at its own hue to reach 3:1 on the note blocks; in Match Theme each is fitted at its own hue, keeping its colour, to 3:1 on the rows and on the note blocks, and kept clearly apart from the others; in a light theme Slide In keeps the distance and 3:1 on the rows, and comes to about 2.5:1 on the note blocks).
- **Fancy Pitch Correct v2.18.0 (`Pitch/Fancy_Pitch Correct.lua`)** — The time ruler blends in with REAPER's timeline: it uses your REAPER theme's timeline colours (background, grey ticks, labels) in both theme modes and is no longer see-through; it follows REAPER's ruler unit instead of counting seconds from the start of the item: bars and beats (`33.1`, `33.1.50` when zoomed in) placed by REAPER's tempo map when REAPER's ruler shows measures, project time (`0:52.5`, the project start time included) otherwise; the line under the ruler is gone; a faint light line runs along the top of the note column, the ruler and the side panel.
- **Fancy Design System v1.6.0 (`Utility/Fancy_Design System.lua`) and `_lib/theme.lua`** — The canvas ruler colours read REAPER's timeline colours (`col_tl_bg`, `col_tl_fg2`, `col_tl_fg`) in both theme modes: `ruler_bg` is now opaque, and `ruler_tick`, `ruler_text` and `ruler_edge` are new (labels fitted to 4.5:1 on the strip).
- **Fancy Design System v1.5.0 (`Utility/Fancy_Design System.lua`) and `_lib/theme.lua`** — Five new icons, `Theme.icons.snap`, `quantize`, `cursor_to_note`, `split` and `merge` (a note is a rounded bar, the edit cursor a triangle with a line), shown in the icon gallery; the canvas colours gain `gutter_bg_dim`, the darker cell behind an out-of-key note name.
- **Fancy Pitch Correct v2.17.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Note action bar, and fixes after review:
  - **Note action bar**: Snap, Quantize, Split and Merge are a small bar of icon buttons centred right under the selected note (above it when the note is at the bottom of the view). Drag the grip at its left end to move it out of the way: it keeps that offset for every note, and a double-click on the grip puts it back. It hides while you drag, box-select or have a menu open. A button that cannot act is dimmed and its tooltip says why. The four text buttons are gone from the top bar, so the values there stay visible at narrower widths. The S / Q / X / M keys and the right-click note menu work as before. Settings > Appearance & Options has a Note Action Bar Size (Small, Medium, Large: 24, 32 and 40 px buttons; Medium by default). The bar starts with the selected note's name and cents (`E3 -3¢`) in place of its separate label, or the count when several notes are selected; that part has a fixed width, so the buttons stay put as the value changes. A Cursor button (key C) moves the edit cursor to the middle of the selected note, ready for Split; hold C and turn the wheel to move the edit cursor from there (Cmd/Ctrl for finer steps).
  - **Quieter key rows**: the key's root row is no longer tinted; its name in the note column keeps the accent colour and strip. Out-of-key note names sit on a darker cell in a dimmer grey, like their rows.
  - **Shortcuts list**: Q (Quantize), X (Split) and M (Merge) are now listed.
  - **Undo restores Separation**: undoing or redoing a Separation change now puts the Separation value back as well as the notes.
  - **Bypassed notes stay uncorrected**: next to an edited note, the blend between the two now stays on the edited note instead of reaching into the bypassed one.
  - **Fine adjust for Slide In**: Shift + Cmd/Ctrl-drag on a note changes Slide In finely, like Tighten and Tolerance.
  - **Clearer Slide In message**: on a note with no slide into it, the status line says there is nothing to flatten.
- **Fancy Pitch Correct v2.16.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Automatic joins, Slide In and Separation:
  - **Joins are automatic**: the correction blends across the slide you actually sang, with a short fixed fade into and out of silence. Transition, Onset Ramp and Legato Gap are gone, along with the `Timing` button and the Timing row in the top bar.
  - **Slide In** replaces Scoop Shape: it flattens the slide into a note up to where the note actually settles (not a fixed length), and at 100 % it removes the slide completely. Shift + drag anywhere on a note adjusts it; it is also in the top bar and the note's right-click menu.
  - **Separation** (top bar, 0–100 %, default 50 %): how readily the analysis splits the singing into notes. Raise it when separate notes are joined, lower it when one note is cut up. Changing it re-splits the current item straight away as one undo step; notes whose start and end did not move keep their edits, and it asks first if an edited note would lose its edits.
  - **Better note splitting**: notes joined by a sung slide and re-articulations on the same pitch are found as separate notes; vibrato and short pitch-detection dropouts no longer cut a held note.
  - **Known limit**: a note that differs from its neighbours only in pitch must last about 100 ms to be found as its own note, whatever the Separation (a quick dip in loudness separates notes from about 40–50 ms). Very wide vibrato (beyond about ±0.7 semitone) can still split at 100 %.
  - **Re-analyze older items**: items analysed with an earlier version must be analysed again (Re-Analyze). Stored Transition, Onset Ramp, Legato Gap and Scoop values are not carried over.
- **Fancy Pitch Correct v2.15.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Two new shortcuts:
  - **B** bypasses the selected notes; pressed again when they are all bypassed, it turns bypass off. One undo point, and the status line says how many notes changed.
  - **W** moves the edit cursor to the start of the item (like REAPER's Go to start of project); playback follows and a zoomed view scrolls back to the start.
  - Both show in the side panel's Shortcuts list.
- **Fancy Pitch Correct v2.14.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Design pass on the top bar, the canvas curves and the side panel:
  - **Side panel toggle**: a panel button in the top bar (next to `…`) shows and hides the panel and is lit while it shows. The panel has its own darker surface. The `▶` in the Pitched Items header and the closed strip are gone: hidden, the panel leaves the whole width to the canvas.
  - **Timing row**: a secondary bar on a recessed band across the window, with its values under the `Timing` button instead of at the far left.
  - **Quieter pitch trace**: dimmed over a note block and barely visible everywhere else, so the preview curve stands out; the preview is opaque and as saturated as its contrast allows.
  - **Ruler and hint**: time labels keep room between them when zoomed in, and the idle hint on the canvas (`Select a note to edit it`) steps aside while a note is under it.
  - **Value fills** use the accent colour (a note's own value keeps the selection pill's colour).
- **Fancy Design System (`Utility/Fancy_Design System.lua`, `_lib/theme.lua`)** — New `panel_right` icon; canvas tokens `trace_note` and `trace_far`; palette colour `inset` (a recessed surface for secondary bars and side panels).
- **Fancy Pitch Correct v2.13.0 (`Pitch/Fancy_Pitch Correct.lua`)** — The top bar follows your selection:
  - **One bar for defaults and notes**: with no note selected, the values in the top bar are the defaults (the pill reads `Defaults`). Select one or more notes and the same controls show and change those notes (`3 notes`). A note with its own value no longer greys the bar out.
  - **Change many notes at once**: with several notes selected, a drag moves them all by the same amount and keeps the differences between them; mixed values show as a range such as `20–60%`. Cmd/Ctrl-click a value and type a number to make them all equal. Double-click puts them back to what they inherit.
  - **Tighten, Strength and Tolerance always visible**, each with a bar under it that shows where the value sits between its lowest and highest setting. A `*` marks a value that is not the default.
  - **Timing row**: the `Timing` button opens a row with Transition, Onset Ramp, Scoop Shape and Legato Gap, and it stays open until you close it. It replaces the three badges and their popups: every value now drags directly.
  - **Tooltips say what a value does**: each one explains the effect on the sound first, then what a drag changes right now, then the gestures.
  - **Note menu**: every value row (not only Tighten and Tolerance) writes to all selected notes when you right-click one of them.
  - The "…" button's tooltip now begins "Menu".

- **Fancy Pitch Correct v2.12.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Tighten and Tolerance replace Stability and Vibrato:
  - **Tighten** (drag the left side of a note up): one dial that takes the note's wandering away, slowest movement first. Around 50 % removes drift and sag and leaves vibrato as sung; around 70 % also halves the vibrato; 100 % is a flat line. The slide into a note and the fall out of it keep their shape. Cmd/Ctrl-drag adjusts finely.
  - **Tolerance** (drag the right side of a note up): how far a tightened note may stray from its centre before anything is pulled in, 0 to 50 cents. It only acts on notes with Tighten above 0 %; the readout says so while it is not in use. While you hover or drag it, a band on the note shows the range.
  - **Tolerance default in the top bar**: a `Tolerance: 8¢` badge next to Strength, with the same chain as the other values: the global default, an override for one item (right-click), or a note's own value.
  - **Note menu**: Tighten and Tolerance are the first two value rows. With several notes selected, a right-click on one of them keeps the selection and the two rows write to all of them (the row says how many). Scoop Shape no longer shows a level it does not have.
  - **Removed**: Stability, Vibrato, the Vibrato Shading layer and the Trend Line diagnostic. Stability and Vibrato values stored on earlier items are dropped, not converted: such an item shows as outdated and is rewritten without them on its next edit.
  - **Fixed: Esc during a note drag**: pressing Esc while dragging a note (its pitch or one of its side values) left the value changed on screen but not written to the item. It now puts the value back.
  - Under the hood: the per-note values and the drag zones are each described in one table; vibrato detection and about 190 lines that served the old controls are gone; a tightened note's line is computed once per change, not on every redraw of the correction.

- **Fancy Pitch Correct v2.11.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Pitch points you can drag:
  - **Drag a pitch point**: the dots and diamonds on the hovered and selected notes are now pitch points. Drag one up or down to bend the pitch at that moment; the bend eases to nothing at the point on either side. Cmd/Ctrl-drag adjusts finely, a point holds up to ±300 cents, and Esc during a drag puts it back. A note with moved points shows as edited, and the Preview Curve follows the bend.
  - **Add your own**: double-click the pitch line to add a point (drawn as a square); double-click a point to put it back to 0.
  - **Two menus**: right-click a point for a menu with a typed Offset, Reset Point and Remove Point. The note menu has "Add Pitch Point Here" and "Reset Pitch Points (N)".
  - **Reset, Split, Merge and Trim**: "Reset to Original" also clears a note's points. Split, Merge and Trim keep the bend you made; Trim drops the points left outside the note and says how many.
  - **Crowded notes**: when a note is too crowded, or its row too short, its points are drawn small and cannot be grabbed until you zoom in.
  - **New name and place**: the layer that was "Pitch Center Spots" in Settings → Diagnostics is now "Pitch Points" in the Layers menu. Help lists the new gestures and the Shortcuts list has a row for them.
  - Items without points are written exactly as before.
  - **Fixed: Split, Merge and Trim moved the note's pitch**: a note you split, merged or trimmed was shifted as a whole, often by 20 to 50 cents, and an untouched note came out marked as edited. The new note now keeps exactly the shift it had before (none for an untouched note), and trimming an edge back and forth no longer adds up. Notes already split, merged or trimmed keep the pitch they were written with.
  - **Fixed: Esc during a slider drag saved the value**: pressing Esc while dragging a value saved it. This was so for the sliders in a note's right-click menu (Onset Ramp, Scoop Shape, Transition, Correction Strength), for Correction Strength and the timing values in the top bar, and for the sliders in Settings. Esc now puts the value back to what it was before the drag, with nothing written or saved; a menu or popup the slider sits in still closes. The same Esc no longer also clears the note selection.

- **Fancy Pitch Correct v2.10.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Every correction setting shows on the notes:
  - **Preview Curve is the written shape**: the green curve is now drawn from the same calculation that writes the item's pitch envelope, so it also shows the Scoop at a note's start, the fade in before a note and out after it (Onset Ramp), and the glide between two joined notes (Transition, Legato Gap). It follows Strength and the timing values live while you drag them in the top bar.
  - **Highlights while you hover or drag a setting**: Strength outlines every edited note it reaches; Transition shades each glide; Onset Ramp shades the fade before and after each note; Legato Gap shades every gap that is joined; Scoop shades the note's onset. The same shows from the Timing popup, the note menu's sliders and a Shift+Drag on a note. A note with its own value for a setting is not lit by the top bar. If nothing in view uses the value you are dragging, the status pill says so.
  - **Scoop now works**: it used to change nothing on a note without a Stability or Vibrato edit, and its onset was never written to the item. At 100 % the slide into the note is pulled onto the pitch the corrected note settles at, easing out to the note's normal correction by the end of the onset; 0 % leaves the slide as sung. One onset frame is moved by 3 semitones at most. A Scoop you set earlier takes effect the next time that item's correction is written.
  - **Shift+Drag readout**: while you Shift+Drag a note, the readout beside the pointer names the value that is changing (Onset Ramp, Transition or Scoop). It used to show Stability, the pitch or Vibrato.
  - **Outdated items are found from the item itself**: an item is marked "outdated" when its pitch envelope is not what its notes and the current settings would write. The mark used to be kept in memory only, so it was lost when the script restarted and an item written with older settings looked current. Every stored item is now compared when the script starts and whenever the project changes (undo, redo, an edit in REAPER); putting a setting back to the value an item was written with clears its mark.
  - **An outdated item shows what it really holds**: while the open item is outdated, the Preview Curve is drawn from the envelope stored on the item, not from the current settings, and the status line says "Outdated: this item's envelope is from other settings. Edit a note to rewrite it." While you drag a value or a note, the curve previews what the release will write.
  - Untouched notes get no correction, so nothing is drawn on them. The Preview Curve entry of the Layers menu switches the curve and the highlights together. No gesture, value range or undo point changed, and the envelope that is written is the same as before.

- **Design system (`_lib/theme.lua`)** — Two canvas colours for the highlights above: `canvas.span_fill` (a faint yellow wash) and `canvas.span_edge` (its edge and the note outline, at least 3:1 on every row and note fill in both theme modes).

- **Fancy Pitch Correct v2.9.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Shortcuts in the right panel:
  - **Shortcuts list**: a new section under Pitched Items lists the keys and gestures that nothing on screen shows: selecting (Cmd/Ctrl+A, arrows, Shift-click, Cmd/Ctrl-click, box select, Esc), editing (arrow nudges, R, double-click to snap, the note menu, Shift-drag, trimming a note edge), the view (Z, F and the wheel chords) and Space. Keys that a button or a hover hint already names (S, Q, X, M, the note zones) are left to those; the full list stays in Keyboard Shortcuts & Help.
  - **Folding sections**: Pitched Items and Shortcuts each have a header that folds them. With both open, Pitched Items takes the height its rows need (at most half the panel) and Shortcuts scrolls in the rest; fold one and the other gets the whole panel. Both states are remembered between sessions.
  - **Default width**: a panel you have never resized opens just wide enough for every shortcut to sit on one line. The width is measured from the text in the font in use; once you drag the divider, your width is kept as before.
  - **H** shows or hides the Shortcuts list. If the panel is hidden, H brings it back with the list open; in a window too narrow for the panel the status pill says "Widen the window to show Shortcuts".
  - **Help**: Keyboard Shortcuts & Help lists H and the fold arrows.

- **Fancy Pitch Correct v2.8.1 (`Pitch/Fancy_Pitch Correct.lua`)** — Scrolling follows your mouse: the wheel scrolls the pitch axis (up and down), and a horizontal scroll scrolls the timeline, whether it comes from Shift + wheel, a trackpad, a tilt wheel or a mouse's own horizontal-scroll button. The two were the other way round. Cmd/Ctrl + wheel still zooms the timeline and Alt + wheel the pitch axis. The Help rows are updated.

- **Fancy Pitch Correct v2.8.0 (`Pitch/Fancy_Pitch Correct.lua`)** — New look: matches the Reapertips Theme. Greys with a blue accent, flat outlined buttons, recessed slider grooves and input boxes, square-ish corners, tighter spacing and Fira Sans type. The canvas follows the same look: quiet recessed rows, blue notes (green once edited), a violet for split markers and the drift zone. Layout, controls and behaviour are unchanged. Symbols the new font lacks (check marks, arrows, dots) are drawn as small icons or plain text.

- **Design system (`_lib/theme.lua`, `_lib/fonts/`)** — The curated mode takes the look of the Reapertips REAPER theme, and the mode that was called "Fancy Dark" is now called **"Fancy"** (your saved choice carries over):
  - **Colours and shapes**: grey surfaces, a blue accent (`#46B9FE`) and a soft violet for the secondary accent, which was blue. Buttons, combos and toggles are flat, outlined and 2 px rounded; a toggle that is on is a solid accent fill with a dark label. Sliders, checkboxes and inputs sit in recessed wells with a light slider thumb; tabs, scrollbars, hovered and selected rows, title strips, tooltips and popups follow the theme. A selected row in a library list also gets a thin accent bar.
  - **Type and spacing**: Fira Sans (Regular and Bold) is bundled in `_lib/fonts/` under the SIL Open Font License, with its licence text. If the files cannot be loaded, an installed Fira Sans and then the system font are used, with no error. Sizes are 11 / 13 / 14 / 16 / 18; spacing is tighter (4 px between items, 8 px window padding) and buttons are 15 / 21 / 22 px tall.
  - **Match Theme** keeps reading surfaces, text and accent from the active REAPER theme and gets the same shapes, spacing and font. Text stays readable (4.5:1) on every surface and every button, tab and row face, including hovered and pressed ones, and state markers (the accent, check marks, selection bars, the control outline on a white theme) stay visible.
  - **For script authors**: new palette roles (`btn`, `btn_h`, `btn_a`, `btn_on`, `on_text`, `outline`, `well`, `thumb`, `tab`, `hover`, `select`, `scroll`, `title` and their variants), `Theme.label_on(fill)`, `Theme.mode_labels`, the icons `check`, `dot` and `ring`, and `Theme.push` now returns the counts it pushed (`Theme.pop` with no counts pops them). No existing field, token or widget was removed.
  - **Contrast**: text and labels stay at 4.5:1 and state that carries meaning at 3:1; the resting outline and face of a control now follow the theme with no minimum. See `docs/design/README.md`.

- **Fancy Design System v1.4.0 (`Utility/Fancy_Design System.lua`)** — Shows the new control roles and a row of raw ImGui controls (button, checkbox, slider, input, tabs, scrollbar); the mode is labelled "Fancy".

- **Other scripts** — These scripts ship the design system's font files and pick up the new look: Fancy Parameter Link v5.4.2, Fancy Mapper Settings v5.2.1, Fancy Mapper Cycle Mode v5.1.1, Fancy Mapper Sensitivity Up v5.1.1, Fancy Mapper Sensitivity Down v5.1.1, Fancy Tap Tempo Slew Settings v1.0.1, Fancy Pan Snap v1.8.0 (the menu entry "Secondary Accent (Blue)" is now "Secondary Accent", since that colour is violet), and Fancy Selected Track Meter v9.67.2 (fonts only; its own drawing is unchanged).

- **Fancy Pitch Correct v2.7.1 (`Pitch/Fancy_Pitch Correct.lua`)** — Fix: Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z now undo and redo in REAPER while the Pitch Correct window is focused. The window kept those keys to itself, so nothing happened. A pending arrow-key nudge is committed first, so the undo takes that nudge back.

- **Fancy Pitch Correct v2.7.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Note tone while dragging:
  - **Hear the pitch as you drag**: while you drag a note up or down, a sine tone sounds at the pitch the note is on and glides with it (in 1-cent steps), so you can place the note by ear. With several notes dragged together it follows the note you grabbed. It stops when you release the mouse. The lowest tone is A0 (MIDI 21): lower notes sound at A0.
  - **Pitch drags only**: a click that only selects, Stability and Vibrato drags, Shift drags, edge trims, arrow-key nudges, Snap and Quantize stay silent.
  - **Never part of the project**: the sound comes from REAPER's own "JS: Tone Generator", which the script puts on the Monitoring FX chain for the length of the drag and removes afterwards. It adds no track and no undo point, and there is nothing extra to install.
  - **Note Tone** in the "…" menu, between Layers and Settings, switches it on and off (ticked = on). It is on by default and remembered between sessions. Its tooltip reads "Play a tone at the note's pitch while you drag it". The More button's tooltip and the Help row now read "More: Analyze, Reset, Layers, Note Tone, Settings, Help".

- **Fancy Pitch Correct v2.6.1 (`Pitch/Fancy_Pitch Correct.lua`)** — Fix: clicking the time ruler moves the edit cursor there (playback follows, as on REAPER's own ruler), so you can split or play from that spot. The ruler added in v2.6.0 took clicks along the top of the notes without acting on them. Double-click still shows the whole item.

- **Fancy Pitch Correct v2.6.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Readable canvas, zoom on both axes, one top bar:
  - **Notes first**: notes are solid blocks in the accent colour (green once edited) with the item's own waveform drawn inside (REAPER's peaks for the item, scaled to its loudest sample; the analysis loudness stands in while the peaks are not built); the pitch trace and the playhead are the text colour, and the playhead has a head in the ruler. Note labels and pitch-centre spots show for the hovered and the selected notes only, on a pill beside the block.
  - **Pitch range**: the range fits the notes (at least an octave), not every analysis frame, so a stray octave error in the raw curve no longer squeezes the melody. A strip at the right edge shows the visible range within everything there is to see: drag it to scroll, drag an end to zoom, double-click to fit the notes. Alt+wheel zooms the pitch axis, Shift+wheel scrolls it.
  - **Overview strip**: a strip under the notes shows every note of the item and the visible time window: drag it to scroll, drag an end to zoom, double-click for the whole item. The item still opens whole. Z zooms both axes to the selected notes; F shows the whole item with the fitted range.
  - **Note column and rows**: a flat column names every row (when a row is tall enough) in place of the piano keys; the rows are one quiet surface with a hairline between them, out-of-scale rows a step darker and the root row marked.
  - **One top bar**: Correction Strength (now "Strength", with a pill saying whether the value is the global default, the item's or the note's), Transition / Onset Ramp / Legato Gap and Snap / Quantize / Split / Merge moved from the bottom dock into the top bar, next to the item, Key and Scale. Analyze, Reset, Layers, Settings and Help are under "…". When the window is narrow the three timing values fold into one "Timing" button, then the groups wrap onto more rows. The wordmark and the "Key:" / "Scale:" labels are gone.
  - **Status on the canvas**: status messages, the analysis progress, the selection count and the "Select a note to edit it" hint show on a pill in the bottom-left corner of the notes; there is no bottom bar. The canvas and the Pitched Items panel run to the window's left, right and bottom edges.

- **Design system (`_lib/theme.lua`)** — Canvas palette for the new Pitch Correct canvas: calmer `row*` / `grid*` values, near-opaque accent / green `note_*` fills with a text-colour selection border, `trace` and `playhead` in the text colour, a lighter `preview`, `handle_drag` in yellow; new tokens `gutter_bg`, `gutter_text`, `gutter_text_dim`, `gutter_text_tonic`, `gutter_strip`, `note_wave`, `overview_bg`, `overview_note`, `view_fill`, `view_border`, `view_grip`. Match Theme fits the new text tokens to 4.5:1 and the new boundaries to 3:1, like the existing ones. The piano-key tokens stay in the palette.

- **Fancy Design System v1.3.2 (`Utility/Fancy_Design System.lua`)** — Lists the new canvas tokens in their own groups.

- **Fancy Tap Tempo Slew v1.0.0 (`Transport/Fancy_Tap Tempo Slew.lua`, `Transport/Fancy_Tap Tempo Slew Stop.lua`, `Transport/Fancy_Tap Tempo Slew Settings.lua`, `_lib/tap_tempo_settings.lua`)** — New scripts for following a live player:
  - **Tap action**: after a set number of taps (default 4) the tempo changes to their average. Instant mode (default) inserts a tempo marker at the play position, so what has already played keeps its timing and sounding notes are not cut and retriggered. Glide mode moves the tempo in effect toward the tapped value at a set rate. After the first change, the tempo updates once per group of taps (default) or on every tap (rolling average). A pause longer than the restart gap (default 2 s) starts a new count. Each press replaces a running glide without a prompt; one undo point per change.
  - **Stop action**: stops a glide where it is and clears the tap count.
  - **Settings window**: change mode, glide rate, taps per change, group or rolling updates, restart gap and tempo range. Changes save at once and apply on the next tap; a summary line describes what tapping will do; Reset all asks first. Settings are shared through `_lib/tap_tempo_settings.lua`.

- **Fancy Pitch Correct v2.5.0 (`Pitch/Fancy_Pitch Correct.lua`)** — UX review: safer edits, clearer interface:
  - **Undo and data safety**: the editor follows Cmd/Ctrl+Z and Redo (the note model is saved inside the same undo point as the pitch envelope); Re-Analyze, Reset all, Clear, Remove and Wipe ask before discarding edits; Wipe and Remove no longer reset a take's own pitch and Wipe is one undo step; re-analysis no longer leaves a stale envelope; holding an arrow key to nudge is one undo step; the note-menu sliders now apply their changes.
  - **Keyboard and input**: Esc closes the innermost popup or dialog, then deselects, then closes a floating window (never a docked one); Space and its Shift/Ctrl/Alt chords run the action bound in REAPER; shortcuts need exact modifiers and ignore open menus; Cmd/Ctrl-drag is fine adjust; value controls are drag widgets with fine adjust, double-click reset, Cmd/Ctrl-click typing and clamping; Block and Hop size are lists.
  - **Canvas**: timeline zoom (Cmd/Ctrl+wheel), scroll and a time ruler; the pitch scale stays fixed while dragging; higher-contrast labels, notes and handles; messages for "no pitched notes", bypassed items and too-short windows; distinct marker shapes and an edited-note mark in addition to colour; cursors and tooltips follow the zone under the pointer.
  - **Layout**: responsive header (down to about 260 px), a wrapping dock with state-aware hints and Snap / Quantize / Split / Merge buttons, a resizable Pitched Items panel that collapses in narrow windows, larger destructive targets, a first-use window wide enough for the full header.
  - **Settings and help**: form layout with per-setting and per-section Reset, "Custom" preset names, units shown, settings and layer toggles kept between sessions, a locked state while analyzing; the Info modal documents every gesture; consistent terms (Pitched Items, Correction Strength, Onset Ramp, Legato Gap).
  - **Reliability**: analysis can be cancelled and works in small time slices; an error shows an in-window message with Retry instead of the window disappearing; actions that do nothing say why; fewer per-frame lookups (cached project queries, reused buffers, list clipping); unreadable saved data is reported with a Clear action; the toolbar button reflects the running state.
  - **Theme**: the piano-roll colours now come from the shared theme (`P.canvas`), so the canvas follows Match Theme.

- **Design system (`_lib/theme.lua`)** — Shared canvas palette and widget polish: new `P.canvas` colour group (68 tokens; Fancy Dark equals the previous piano-roll colours, Match Theme derives legible colours from the REAPER theme), `Theme.layout.icon_target` (24 px target), tooltips in theme widgets respect the Show Tooltips preference and also appear on disabled items, icon buttons show the hand cursor, `Theme.badge` and `Theme.toggle_button` ids no longer change with their label, `Theme.selectable` clips labels that are too long. Contrast: dim text is lighter (`text_dim`), every frame (buttons, inputs, checkboxes, combos) now has a 1 px border in a lighter `border` colour so unchecked boxes and input boundaries are visible, and pressed buttons use a darker accent (`accent_press`); `Theme.push` now pushes one more style variable (`FrameBorderSize`), and Match Theme derives the same colours through the contrast fit. Visible in every script that uses the theme.

- **Fancy Design System v1.3.1 (`Utility/Fancy_Design System.lua`)** — Shows the canvas palette (`P.canvas`) and the `icon_target` preset.

- **Fancy Mapper Settings Reorganization v5.2.0 (`Mixing/Fancy_Mapper Settings.lua`, `_lib/mapper_engine.lua`)**:
  - **One Mode Panel**: A single "Configure Mode" dropdown shows only the selected mode's settings and its six button actions, replacing the per-mode sections and the separate Button Actions section. It opens on the dial's live mode and follows it while you're viewing it; a "Current" chip jumps back to it.
  - **Guided Calibration**: "Calibrate…" next to Ticks per Rotation opens a dialog that counts ticks from the normal dial actions while it's open, so the dial no longer has to be rebound to `Calibrate Tick` (which still works). Either direction counts, turning back corrects an overshoot, and Apply writes the result.
  - **Action Ring Mode Chips**: Toggle exactly which modes appear in the ring (minimum 3, canonical clockwise order). The Curated 8 / All 11 presets light up when they match.
  - **Per-Mode Smoothing**: Each smoothable mode has its own Smooth toggle in its panel; the Smooth Dial section keeps the engine controls, preset chips that show the active speed, and a summary of smoothed modes.
  - **Feedback Settings in General**: The value HUD toggle (previously under MIDI CC, though it applies to every mode) and the Sensitivity Up/Down toast settings now live in General; the standalone Toast and Calibrate sections are gone.
  - **Fixes**: Reset All now restores MIDI channel, auto-arm, value HUD, and velocity audition, and writes each default explicitly instead of relying on clearing the whole ExtState section; the reset dialog now dims the window behind it; values changed by Sensitivity Up/Down update live while Settings is open; long button action names no longer overlap the pick/clear controls.

- **Fancy Mapper Universal Smooth Dial & Analog Slew Daemon v5.2.0 (`Mixing/Fancy_Mapper Daemon.lua`, `_lib/mapper_engine.lua`, `Mixing/Fancy_Mapper Settings.lua`)**:
  - **Universal Smooth Dial (Producer-Consumer Slew Engine)**: Offloads discrete notched encoder clicks into continuous 60 Hz exponential slew interpolation (`1.0 - math.exp(-speed * dt)`), giving rotary dials the weighted feel of high-end analog potentiometers across continuous parameters: Volume, Pan, Width, FX Parameters, MIDI CC, Timeline Scrub, and Item Slip.
  - **Zero ReaScript Task Control Prompts**: Keeps dial actions (`Up.lua` and `Down.lua`) 100% synchronous (<0.05ms execution) by accumulating floating-point targets in ExtState and delegating all deferred interpolation to a dedicated standalone consumer daemon (`Fancy_Mapper Daemon.lua`).
  - **Option A (Lazy / Auto-Sleep Daemon)**: The background daemon auto-wakes seamlessly when turning the dial, executes 60 Hz interpolation during parameter movement, and auto-sleeps after 10 seconds of idle dial activity (0% CPU when not actively mixing).
  - **Single-Point Clean Undo**: Dial movements no longer pollute REAPER's undo history with per-frame or empty steps; a single consolidated undo point is recorded when parameter slewing settles to its target.
  - **Comprehensive Settings Hub Card**: Dedicated "Smooth Dial (Analog Slew Engine)" card in `Fancy_Mapper Settings.lua` with a live daemon status badge (`● Active (60 Hz)` / `○ Standby`), manual wake/stop button, master toggle, slew responsiveness slider (5 to 80 /s) with presets (Tape 12, Balanced 25, Snappy 45), and individual toggles for each continuous mode.
  - **Context-Aware Reset Synchronization**: Resetting any parameter via `Fancy_Mapper Reset Parameter.lua` immediately clears active slew targets in ExtState, preventing interpolation fighting on reset.
  - **Action Ring Settings Default to Off for New Users**: Directional Flick, Dwell Hover Selection, and Inactivity Auto-Close now all default to `false` out of the box, ensuring the radial ring remains open, stable, and predictable for new users until a mode is clicked or dismissed, while remaining fully customizable in Settings.

- **Fancy Mapper Linear CC Curves & 1-Click Smoothing v5.2.0 (`_lib/mapper_engine.lua`, `Mixing/Fancy_Mapper Settings.lua`, `Mixing/Fancy_Mapper Smooth CC.lua`)**:
  - **Zero Background Overhead (100% Synchronous)**: Dial movements run instantly with zero background defer tasks, completely eliminating REAPER's "ReaScript task control" prompt when turning the rotary encoder rapidly.
  - **CC Lane Linearization (`shape = 1`)**: Sets MIDI CC curves to Linear ramps instead of REAPER's default Square hold steps, connecting recorded points with smooth vector lines and enabling continuous audio-rate interpolation during playback.
  - **Active MIDI Editor Integration**: Automatically sets REAPER's active MIDI Editor default CC curve shape to Linear via Action 42087.
  - **1-Click Smoothing Tool (`Fancy_Mapper Smooth CC.lua`)**: Standalone action and dedicated button in Settings hub ("Smooth Active Take CC Lane") to instantly convert any existing take's stepped CC events into smooth linear curves.
  - **Selection-Aware Smoothing**: If CC events are selected, only selected points are smoothed; if none are selected, the entire take's CC lane is linearized.
  - **Smart Take Resolution**: Intelligently locates target takes from active MIDI editors, items under cursor, selected items, or items on the armed track.

- **Fancy Mapper Suite v5.1.0 (`Mixing/Fancy_Mapper *.lua`, `_lib/mapper_engine.lua`)** — Expanded Mode Suite & Shared Core Engine:
  - **Shared Core Engine (`_lib/mapper_engine.lua`)**: Replaced 500+ lines of duplicate code between `Fancy_Mapper Up.lua` and `Fancy_Mapper Down.lua` with a unified engine handling configuration, throttling, mode detection, context targeting (including focused FX detection), undo management, and contextual resets.
  - **Width Mode**: Nudges stereo width of track under cursor, focused FX track, or selected track. Automatically promotes track pan mode to Stereo Pan (`I_PANMODE = 5`) if track was in default or balance mode, and repaints TCP/MCP windows immediately so width knobs are visible and active.
  - **Live Multi-CC Mode**: Sends real-time MIDI signals via REAPER's Virtual MIDI Keyboard queue (`StuffMIDIMessage`) and Control Path simultaneously, allowing live real-time control of virtual instruments (e.g. CC 1 Modulation + CC 11 Expression for orchestral libraries like Pocket Strings) while playing or recording. Automatically arms and monitors target tracks. Also supports nudging selected CC events in active MIDI takes.
  - **Live Velocity Mode**: Dynamically manages live note velocity across sessions and updates `default_note_vel` in active MIDI editors for instant writing, with optional audition note preview. Also nudges selected note velocities in takes.
  - **Real-Time HUD Tooltips**: Floating on-screen HUD near cursor shows real-time values for MIDI CC, Velocity, Width, Pan, and Volume as dials turn.
  - **Track Navigation Mode**: Clockwise / counter-clockwise dial turns navigate up/down tracks in project, with automatic TCP scrolling.
  - **Marker Jump Mode**: Dial jumps edit cursor to next / previous marker or region.
  - **Transient Jump Mode**: Dial jumps edit cursor to next / previous transient in selected audio items.
  - **Item Slip Mode**: Slips audio content inside item boundaries via take start offset (`D_STARTOFFS`), leaving item position and length intact.
  - **Context-Aware Reset (`Fancy_Mapper Reset Parameter.lua`)**: Resets last-touched FX parameter (FX mode), centers pan (Pan mode), 0 dB (Volume mode), 100% stereo (Width mode), 96 velocity (Velocity mode), 0/64 CC (MIDI CC mode), and 0s offset (Item Slip mode).
  - **Extended Sensitivity Up/Down**: Sensitivity scaling added for Volume, Width, MIDI CC, Velocity, and Item Slip.
  - **Dynamic Action Ring (`Fancy_Mapper Cycle Mode.lua`)**: Radial ring mathematically adapts to any number of active modes (8 curated default modes or all 11 modes). Removed placeholder tags; cut Send mode.
  - **Settings Hub Enhancements (`Fancy_Mapper Settings.lua`)**: Added dedicated configuration sections for Width, MIDI CC (with preset quick-buttons for Mod, Expr, Mod+Expr, Vol), Velocity, Navigation & Editing, Ring Presets, and multi-mode button action mapping.


- **Fancy Mapper Cycle Mode v5.0.0 (`Mixing/Fancy_Mapper Cycle Mode.lua`)** — Radial Action Ring (Directional Gesture):
  - **Directional Flick Selection**: Hands-free mode switching without clicking or holding buttons. Move your mouse outward in the direction of the mode to select it immediately.
  - **Dwell Selection**: Resting the cursor in an active sector for 350ms (configurable) automatically confirms that mode.
  - **Full Input Flexibility**: Left-clicking an active sector or tapping the shortcut button a second time also confirms instantly.
  - **Clean Codebase**: Completely removed all legacy hold-and-release polling hacks, modifier state masks, and synthetic key detection loops.
  - **Pixel-Accurate Cursor Centering**: Centered around the mouse cursor via `PointConvertNative`.
  - **Center Dead Zone**: Moving into or clicking the center dead zone cancels with zero mode change and dynamic "Cancel" feedback.
  - **8-Mode Radial Roster**: 4 active modes (Scrub, FX Parameter, Pan, Volume) and 4 placeholder slots (Send, Width, MIDI CC, Velocity) marked with `soon` badges.
  - **Integrated Volume Mode**: Added Volume mode handling to `Fancy_Mapper Up.lua`, `Fancy_Mapper Down.lua`, and `Fancy_Mapper Settings.lua`.
  - **Action Ring Configuration in Settings**: Exposed Directional Flick toggle & threshold distance, Dwell Hover toggle & duration, and Auto-Close inactivity timeout in `Fancy_Mapper Settings.lua`.

- **Fancy Mapper v3.0.0 (`Mixing/Fancy_Mapper *.lua`)** — Settings Hub, Context Buttons, Scrub Mode:
  - **Fancy Mapper Settings** (NEW): Centralized ReaImGui settings hub — configure calibration, modes, scrub behavior, sensitivity, button actions, toast appearance, and more. No more editing script files.
  - **Mode-Aware Context Buttons** (NEW): Six assignable button scripts (`Button 1–6`) whose actions change based on the current dial mode. Configure any REAPER action per button × mode slot using REAPER's built-in Action List picker (`PromptForAction`). Enable/disable buttons individually.
  - **Scrub Mode** (default): Silent timeline jog via `MoveEditCursor`/`SetEditCurPos`. Four scrub units — Free (smooth by time), Grid (SWS `BR_GetNextGridDivision`), Beat (action-based), Measure (action-based). Configurable speed and view scrolling.
  - **FX Parameter Mode**: Migrated from deprecated `GetLastTouchedFX()` to modern `GetTouchedOrFocusedFX(0)`. Removed FX window focus gate — any touched parameter works regardless of window focus. Added item/take FX support.
  - **Pan Mode**: Adjusts pan on track under mouse cursor with selected-track fallback. Configurable sensitivity.
  - **Mode-Switch Toast**: Self-terminating ImGui overlay (configurable position, duration, enable/disable) replaces console output. Fades out gracefully, handles rapid presses via timestamp deduplication.
  - **Controller-Agnostic Design**: Removed all Logitech MX Creative Console references. Works with any hardware dial, rotary encoder, or MIDI controller.
  - **Settings-Driven Config**: All hardcoded values (ticks per rotation, throttle, step sizes, sensitivities) moved to ExtState, managed by the Settings app.
  - **Calibration Absorbed**: Standalone Calibrate window removed; calibration integrated into Settings with header shortcut button.
  - **Volume Scripts**: Now read step size and throttle from ExtState.

- **Fancy Pitch Correct v2.4.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Production UX Modern Studio Dock Layout:
  - Unified Single Top Bar: Consolidated title, settings, info, close, take badge, musical key, scale, analyze, and reset onto a single high-efficiency row, maximizing vertical canvas real estate
  - Track Color Matching: Target take badge background dynamically retrieves and displays the active track's REAPER color via `GetTrackColor()` and `Theme.bgr_to_rgba()`, with automatic luminance contrast adjustment for text
  - Eliminated Dead Vertical Spacing: Removed redundant `NewLine` and `Spacing` calls between top toolbar and piano roll canvas, and between canvas and bottom footer, ensuring seamless edge-to-edge layout
  - Bottom Footer Sizing & No Cutoff: Refactored canvas height budgeting (`total_h = math.max(60, avail_h - footer_h)`) and dynamic button right-alignment, ensuring all footer controls and text fit completely without clipping in docked windows
  - Generous Button Widths: Widened Analyze (`96px`), Reset (`66px`), Layers (`80px`), Quantize (`98px`), Split (`74px`), Merge (`78px`), Reset (`80px`), and Select All (`86px`) buttons to comfortably fit all label variations
  - Text Wrapping in Pitched Items: Replaced raw text clipping with `ImGui_TextWrapped()` when the drawer is empty
  - ReaImGui & REAPER Docker Integration: Enabled `ImGui_ConfigFlags_DockingEnable()` at context creation, restored native window title bar/dock tabs, and used `ImGui_Cond_Once()` for initial window centering so users can dock the window into any REAPER docker tab, drag between dockers, or float seamlessly
  - Redesigned Active/Bypassed State: Removed toolbar bypass toggle; added REAPER FX chain-style checkboxes to the left of each item in the Pitched Items drawer; rendered a dimmed canvas with a centered "BYPASSED" overlay badge when inactive
  - Collapsible Drawer Tag: Replaced top toolbar button with an edge tab tag button (`◀`) on the canvas boundary when the drawer is closed
  - Full-Width Item Selection Bar: Active item highlight bar now spans across the entire row encompassing checkbox, name, and delete button; removed obsolete `>` arrow marker
  - Centered Empty Canvas State: Centered "No data. Select an item and click Analyze." with a large "Analyze Item" button centered above it
  - Full Session Wipe: Added "Wipe Entire Session (All Items)" button to Settings modal to completely clear take envelopes, chunks, and metadata across all items
  - High-Contrast Text: Ensured 100% white (`0xFFFFFFFF`) text on all dropdowns, buttons, and badges for perfect legibility across all theme modes
  - Toolbar Streamlining: Removed redundant "Apply to Take" button (live auto-commit writes to take envelope continuously)
  - Display Layers Popover: Replaced 7 sprawling checkboxes with a clean, space-efficient `Layers ▾` dropdown menu
  - Bottom Contextual Inspector Dock: Real-time badges for note pitch, in/out-of-scale status, drift stability %, vibrato %, transition ms, and tuning status, alongside right-aligned quick actions (Quantize, Split, Merge, Reset, Select All)
  - Audio Engine & Settings Modal: Dedicated modal dialog (`Theme.modal_scrim`) housing Vocal Range, Detection Strictness, Quality, REAPER Pitch Shift algorithm selector, Advanced DSP parameters, theme switcher, and onset diagnostic toggle
  - Keyboard Shortcuts & Help Modal: Interactive shortcut reference dialog accessible from the header info button
  - Design System Additions (`_lib/theme.lua`): Added vector `Theme.icons.gear`, `Theme.icons.tri_left`, and `Theme.icons.tri_right` primitives

- **Fancy Pitch Correct v2.3.0 (`Pitch/Fancy_Pitch Correct.lua`)** — High-Fidelity Note Blending, Stability & Vibrato Engine:
  - S-Curve Note Blending: Seamless smoothstep Hermite transitions ($3t^2 - 2t^3$, 35ms default) across all note boundaries, including transitions to/from untouched notes and silence onsets, eliminating 1ms cliff artifacts and phase vocoder chirps
  - True Stability Drift Correction: Samples the continuous drift cancellation trajectory ($E_{\text{drift}}(t) = (\text{center} - \text{trend}(t)) \cdot (1 - \text{drift\_scale})$) into REAPER Take Pitch Envelope with sub-cent accuracy, ensuring 100% Stability audibly flattens pitch drift to match the visual preview
  - Zero-Phase Drift & Vibrato Filter: Replaces crude simple moving average (SMA) with symmetric zero-phase Gaussian filtering ($\sigma = 7.0$ frames, ~2 Hz cutoff), eliminating vibrato ripple from the trend line and preserving pristine vibrato waveforms
  - Anti-Chatter Vibrato Detection: Dual-threshold Schmitt trigger hysteresis and asymmetric envelope follower (~100ms attack, ~60ms release) prevent flickering and odd-spot vibrato highlights during sustained singing
  - Robust Core Pitch Center: Calculates `avg_note` from an RMS-energy-weighted interior window (12% to 88%), preventing onset scoops and release sags from pulling the target pitch off-center
  - Adaptive Envelope Decimation (RDP): Functional Ramer-Douglas-Peucker polyline simplification converts continuous mathematical trajectories into the minimal optimal set of REAPER Bezier points with $<1$ cent tolerance
  - UI / Audio Parity: Preview line in graph and actual take envelope points share identical mathematical formulation
  - Transition Readout: Displays transition duration in milliseconds in the active note status inspector

- **Fancy Pitch Correct v2.2.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Multi-Note Selection & Batch Operations (Milestone 4):
  - Marquee Box Select: Click and drag on empty canvas to select multiple notes with real-time accent box, note count indicator, and AABB intersection
  - Additive Marquee: Shift+drag adds newly intersected notes to existing selection without clearing prior selections
  - Multi-Note Drag: Move pitch center, stability (drift), or vibrato across all selected notes simultaneously
  - Phrase Interval Preservation: Shift-snap snaps anchor note to nearest semitone while strictly preserving the musical intervals of all other selected notes
  - Select All (Cmd/Ctrl + A): Fast phrase-wide selection via keyboard shortcut and toolbar action button
  - Cmd/Ctrl + Click: Toggle individual notes in and out of multi-selection
  - Deselect All (Escape): Instant clearing of active selection
  - Shift + Left / Right Arrow: Expand selection range across adjacent notes
  - Multi-Note Double Click: Double-clicking pitch zone snaps all selected notes to nearest semitones
  - Dynamic Status Readout: Displays total notes selected, cumulative duration, anchor note pitch, and batch tuned/untouched counter
  - Contextual Toolbar Actions: Dynamic note count indicators on Quantize (%d) (Q) and Reset (%d) buttons
  - Updated Keyboard Shortcuts Tooltip: Documents Cmd/Ctrl+A, Escape, and Marquee Drag

- **Fancy Pitch Correct v2.1.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Scale Snapping & Piano Roll In-Scale Tinting (Milestone 3):
  - Key & Scale Selector: Dropdowns for musical Key (C, D, etc.) and Scale (Major, Natural Minor, Dorian, Pentatonic, Minor Pentatonic, Chromatic)
  - Visual Piano Roll Tinting: In-scale note rows highlighted with subtle theme accent tinting; out-of-scale rows and piano keys dimmed
  - Root Key Highlighting: Distinct tonic accent strip on piano keys and enhanced tinting on root pitch rows
  - Quantize Key (Q): Snaps selected note(s) to the nearest valid in-scale pitch
  - Quantize (Q) action bar button with contextual enable/disable and dynamic key/scale tooltip
  - Batch Quantize, Snap, and Reset: Supports both single note and multi-note Shift+Click selections
  - Status display: Real-time `[In Scale]` vs `[Out of Scale]` indicator on the active note inspection bar
  - Persistence: Stores musical Key and Scale per-take in take JSON data and globally across sessions via REAPER ExtState
  - Keyboard Shortcuts Tooltip: Updated with `Q` shortcut entry

- **Fancy Pitch Correct v2.0.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Note Topology (Milestone 2):
  - Split Note (X key): Cuts a note into two independent notes at the edit cursor, automatically re-extracts features for both halves
  - Merge Notes (M key or button): Glues contiguous selected notes back into a single entity with gap frame recovery from raw analysis data
  - Edge Trimming: Drag left/right edges of any note to adjust boundaries with live preview; commits frame re-filtering and feature re-extraction on release
  - Multi-select: Shift+Click for range selection; merge operates on all selected notes
  - Tuning intent preservation: Split/merge carry forward the user's pitch offset, drift scale, and vibrato scale via `preserve_controls` parameter on `extract_note_features`
  - Visual edge handles: Small grab rectangles on note block edges, brighten on hover, accent color during drag
  - Split/Merge buttons in toolbar action bar with contextual enable/disable (greyed when unavailable)
  - Updated keyboard shortcuts info tooltip with all new interactions
  - `ResizeEW` cursor feedback when hovering edge trim handles

- **Fancy Pitch Correct v1.1.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Scalpel Keyboard Controls:
  - Arrow nudging: Up/Down = ±1 semitone, Shift+Up/Down = ±10 cents fine-tune
  - Left/Right arrow keys: Jump note selection to previous/next note in phrase
  - S key: Snap selected note to nearest exact semitone (0¢ deviation)
  - Double-click pitch zone: Snap note to nearest semitone
  - R / Backspace / Delete: Reset selected note back to [Untouched], clearing envelope points
  - Spacebar passthrough: Triggers REAPER Play/Stop even when ImGui window has focus
  - Info icon (ⓘ) in toolbar with keyboard shortcuts tooltip on hover
  - Deduplicated Reset Selected button logic via shared helper function

- **Fancy Pitch Correct v2.4.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Scale Intelligence:
  - Scale auto-detection: Krumhansl-Kessler key profiling from pitch histogram data
  - "Detect" button in toolbar: analyzes pitch frames and auto-sets root note + scale type
  - "Measured" scale entry: auto-populated with the top detected pitch classes
  - "Custom" scale: click piano keys to toggle individual pitch classes on/off
  - Scale indicator dots on piano keys showing which notes are in the active scale
  - Root note (0 / tonic) is protected — cannot be removed from Custom scale

- **Fancy Pitch Correct v2.3.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Tool System:
  - Multi-tool paradigm: Q=Selector, S=Split, J=Join, V=Shaper, X=Pan/Zoom
  - Split tool: click on a note to split at cursor position, red preview line overlay
  - Join tool: click on a note to merge with next, green boundary highlight overlay
  - Pan/Zoom tool: dedicated navigation mode (all clicks become pan/zoom, no selection)
  - Shaper tool: placeholder for future curve editing (acts like Selector)
  - Active tool indicator in toolbar with tooltip showing all hotkeys
  - Tool-specific cursor feedback and interaction dispatch

- **Fancy Pitch Correct v2.2.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Transition Blocks & Smoothing:
  - First-class transition blocks between adjacent notes (amber/gold overlay)
  - Transition tension control: drag diamond handle vertically to adjust smoothness (0 = step, 1 = smooth S-curve)
  - Transition curve rendering with cosine/linear interpolation path
  - `M` key for progressive smoothing on selected transition (+15% per press)
  - Transition data integrated into envelope writer (interpolated pitch points between note boundaries)
  - Click on transition control point to select, drag to adjust, Escape to deselect
  - Auto-generated after analysis, split, and merge operations

- **Fancy Pitch Correct v2.1.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Selection & Navigation:
  - Lasso/marquee selection: drag on empty area to select multiple notes at once
  - Shift+lasso: additive selection mode (keeps existing selection)
  - Cmd/Ctrl+click: toggle individual note without clearing selection
  - Select All (`A` key), Deselect All (`Escape`)
  - Arrow key navigation: `Left`/`Right` to step through notes sequentially
  - Shift+Arrow: extend selection left/right
  - Zoom to Selection (`Z` key, falls back to Fit All if nothing selected)
  - Keyboard Undo/Redo (`Cmd+Z`, `Shift+Cmd+Z`)
  - Lasso rectangle visual overlay with accent-colored fill and border

- **Fancy Pitch Correct v2.0.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Per-Note Control Points:
  - Per-note shaping controls: Correction % (right edge), Drift (left edge), Vibrato (top center), Tilt (Alt+edge)
  - Per-frame pitch trace curve rendered within note blocks showing raw detected pitch
  - Per-frame corrected pitch envelope output with drift/vibrato separation via moving-average trend line
  - Envelope density selector: Low (20 pts/s), Medium (40 pts/s), High (100 pts/s) with persistent settings
  - Control zone hit-testing with distinct cursor feedback per zone type
  - Full shaping undo/redo support: all 6 fields (pitch_offset, correction_pct, drift_amount, vibrato_scale, level_db, tilt)
  - Info bar shows active control zone name and all shaping parameter values on hover
  - Compact pitch_frames cache serialization (v2 format, backward compatible with v1)
  - Control point visual indicators (handles) on note blocks when hovered or selected
  - Note label shows active shaping values (C%, D%, V%, T) alongside pitch name

- **Fancy Pitch Correct v1.0.0 (`Pitch/Fancy_Pitch Correct.lua`)** — NEW:
  - Monophonic pitch correction tool with visual piano-roll editor
  - Pure Lua YIN pitch detection engine (no external dependencies)
  - Audio waveform visualization rendered directly behind notes, centered along sung pitch
  - Cents detune display: shows exact cents off from perfect equal temperament pitch on note blocks and info bar
  - Full piano roll key labeling: all 12 chromatic notes labeled on keys (C, C#, D, D#, etc.)
  - Fit to Screen: one-click button and `F` hotkey to auto-zoom and center viewport horizontally and vertically
  - Drag notes up/down to adjust pitch; semitone snap (Cmd/Ctrl for fine 1-cent resolution)
  - Live preview: pitch envelope updates during drag for real-time audible feedback
  - Scale-constrained "Correct All" (10 scales: Major, Minor, Dorian, Blues, etc.)
  - Note split and merge operations
  - Script-level undo/redo stack (separate from REAPER undo)
  - Toggleable 5ms transition smoothing between notes
  - Analysis caching to JSON (notes + waveform) for instant re-open on same item
  - Non-destructive pitch adjustment via take pitch envelope (action 41612)
  - Fancy Scripts design system integration (dark/match-theme modes)
  - Requirements: REAPER 7.0+, ReaImGui, SWS Extension

- **Fancy Pan Snap v1.7.0 (`Routing/Fancy_Pan Snap.lua`)**:
  - Multi-Project Tab Switching: Automatic session switch detection via `reaper.EnumProjects(-1)`, resetting parameter tracking and tooltips to prevent cross-session pointer leaks, dead memory reads, and ReaImGui desync
  - Zero-Allocation Fast-Path Engine: Eliminated thousands of heap allocations per second during idle (avoiding table allocations, per-tick `GetTrackGUID`, per-tick `GetTrackName`, and string key concatenations)
  - Pre-Cached Track Descriptors: Cached track GUIDs, track names, and parameter keys (`tinfo.key_pan`, `tinfo.key_width`, send keys), rebuilding only on project structure/state changes (`GetProjectStateChangeCount`)
  - Mousewheel, Trackpad, and MIDI Controller Support: Implemented `mouse_down_seen` state tracking so wheel scrolling, rotary encoders, and control surfaces debounce smoothly (120ms) instead of snapping on every individual tick
  - Context Lifecycle Hardening: Guarded `is_bypass_active` to only query `ImGui_GetKeyMods` when `hud_open` is active and context is validated; used precise `JS_Mouse_GetState(40)` for Shift/Alt DAW-wide modifier detection
  - Periodic Stale Cleanup: Cleaned up deleted track pointers every 5 seconds without per-frame table scanning or allocation
  - Action Lifecycle: Re-ordered `set_action_options` and guarded `atexit` ExtState clearing to ensure rock-solid toolbar toggle and multi-instance restarts
- **Fancy Pan Snap v1.6.1 (`Routing/Fancy_Pan Snap.lua`)**:
  - Fixed intermittent `ImGui_GetKeyMods: expected a valid ImGui_Context*` runtime error occurring during background execution when HUD was closed
  - Added robust ReaImGui context lifecycle management (`ensure_imgui_context()` and `is_context_valid()`) using `reaper.ImGui_ValidatePtr` to prevent stale pointer access after ReaImGui GC
  - Wrapped `reaper.ImGui_GetKeyMods` with `reaper.ImGui_ValidatePtr` and `pcall` fallback for crash-proof modifier detection
- **Fancy Pan Snap v1.6.0 (`Routing/Fancy_Pan Snap.lua`)**:
  - Added `50%` preset button to standard step increments and replaced `12.5%` (`5%`, `10%`, `20%`, `25%`, `50%`)
  - Cleaned up header: removed "Auto Detent" subtitle and added dedicated `[Info]` and `[Settings]` modal dialog buttons matching Parameter Link layout
  - Moved target parameters (`Track Pan`, `Track Width / Dual Pan`, `Send Pans`, `Include Master Track`) into the **Settings** modal popup dialog
  - Converted the collapsible Overlay Styling drawer into an open, permanent **STYLING** section using standard section dividers
  - Removed "STATUS & MONITOR" section and repositioned Shift/Alt bypass modifier hints and background execution tip directly under the master `ACTIVE (ON)` / `PAUSED (OFF)` button
  - Added high-visibility red `[STOP]` utility button directly to the top master row beside the status monitor badge
  - Added Info & Guide modal dialog with Quick Guide, Keyboard & Controls, and About tabs
- **Fancy Pan Snap v1.5.0 (`Routing/Fancy_Pan Snap.lua`)**:
  - Added dedicated **Overlay Styling & Theme** section letting users customize floating badge appearance by selecting REAPER theme elements and roles (not raw hex colors)
  - Customizable theme elements: Background Surface (`Card`, `Panel`, `Window`, `Accent Tint`), Border Element (`Accent/Cursor`, `Secondary Blue`, `3D Frame`, `Green`, `Yellow`, `None`), Value Highlight Color, and Label Color
  - Added Corner Rounding (`Rounded 4px`, `Pill 8px`, `Sharp 0px`) and Background Opacity (`40%`–`100%`) controls
  - Built-in real-time **Live Overlay Preview** card inside the HUD demonstrating styling adjustments instantly
  - Removed theme mode dropdown from the window header and relocated it directly into the Overlay Styling section for a cleaner header bar
  - Dedicated "Reset Overlay Style" button to restore default theme element assignments
  - Seamless background execution when closing the HUD menu window (`keep_in_background = true` by default with automatic configuration migration)
  - Intelligent 3-state toggle action lifecycle (`set_action_options(3)`): re-triggering the action or clicking the toolbar button while running in the background re-opens the HUD menu immediately
  - Re-triggering the action or clicking the toolbar button while the HUD is already open toggles the script off cleanly
  - Added explicit "Stop Utility & Exit" action button in the Settings drawer to terminate background execution directly from the GUI
  - Replaced native OS tooltips (`reaper.TrackCtl_SetToolTip`) with a smooth, GPU-rendered ReaImGui floating cursor badge, eliminating macOS window flashing and white/black box artifacts
  - Completely decoupled live mouse dragging from REAPER parameter writes so native TCP/MCP knob turning remains 100% smooth without rubber-banding or value fighting
  - Real-time detent preview displayed directly beside the mouse cursor showing track name, parameter, and target snapped value (e.g. `Lead Vocal • Pan → 20% L (10%)`)
  - Clean snap-on-release execution with a single consolidated undo point (`Utils.undo_block`)
  - Background auto-snap engine quantizes Track Pan, Track Width, and Send Pans across all tracks to configurable percentage increments (default 10%)
  - Smart motion and release detection with instant snap on mouse button release (`JS_Mouse_GetState`) and fallback 120ms debounce settling timer
  - Shift/Alt key modifier detection to temporarily bypass snapping for freehand fine panning
  - Compact ReaImGui HUD interface with quick presets (5%, 10%, 12.5%, 20%, 25%), custom step slider, target selectors, and live activity card
  - Single-instance enforcement, ExtState persistence, and REAPER toolbar toggle state integration (`Utils.init_toolbar_toggle()`)
- **Global Tooltip Preference (`_lib/theme.lua`)**:
  - Added global tooltip visibility state persisted via REAPER ExtState (`FancyScripts`, `show_tooltips`) and cached in memory with cache invalidation support
  - Added `Theme.get_show_tooltips()`, `Theme.set_show_tooltips(enabled)` and developer aliases `Theme.get_tooltips_enabled()`, `Theme.set_tooltips_enabled()`, `Theme.tooltips_enabled()`
  - Added `Theme.tooltip_setting_widget(ctx, [opts])` standardized checkbox component for toggling tooltips in settings panels
  - Updated `Theme.tooltip()` to automatically suppress all tooltips across built-in widgets (`icon_btn`, `section_divider`, `badge`, `toggle_button`, `combo`, `header`) when disabled
- **Fancy Parameter Link v5.4.0**:
  - Added "Show Tooltips" preference checkbox in the Settings & Preferences modal under "UI Density & Appearance"
  - Updated "Last Touched" button custom tooltip to respect global tooltip visibility
- **Fancy Design System v1.3.0**:
  - Added live interactive demonstration for `Theme.tooltip_setting_widget()` alongside theme mode controls
- **Fancy Selected Track Meter**:
  - Updated `DrawTooltip` to respect global `Theme.get_show_tooltips()` preference
- **Shared Library (`_lib/`)** — shared modules loaded via `require()`
  - `theme.lua` — 2-mode palette builder (Fancy Dark / Match Theme), shared font management, ImGui push/pop, settings combo widget
  - `json.lua` — lightweight JSON encoder/decoder (consolidated from inline copies)
  - `utils.lua` — dependency checks, undo block wrapper, track helpers, math utilities, REAPER toolbar toggle state lifecycle helper (`Utils.init_toolbar_toggle()`)
- **Fancy Parameter Link v5.3.0** — Bundled custom 3-state horizontal strip toolbar icons across 100% (`90x30`), 150% (`135x45` in `150/`), and 200% Retina (`180x60` in `200/`), enabled automatic ReaPack `[data]` extraction to REAPER's `Data/toolbar_icons/`, and hooked action toggle command state to light up the toolbar icon while the script is active and running.
- **Design System & Theme Engine**
  - Added `Theme.header(ctx, opts)` composite widget to standardize window headers with brand icon, title, subtitle, theme dropdown, and close button with pixel-perfect alignment
  - Added `Theme.progress_bar(ctx, fraction, [opts])` for crisp value meters and progress indicators with preset support (`opts.preset = L.btn_sm`)
  - Added `Theme.toggle_button(ctx, id, label, is_active, [opts])` button-derived toggle widget supporting button size presets (`opts.preset = L.btn_sm`)
  - Added `Theme.badge(ctx, label, [opts])` button-derived status badge with centered text and preset support (`opts.preset = L.btn_sm`)
  - Added `Theme.push_button_preset(ctx, fonts, preset)` and `Theme.pop_button_preset(ctx, ...)` for seamless styling of native ImGui controls (e.g. sliders, combo boxes)
  - Added `Theme.combo(ctx, id, items, selected_idx, [opts])` for standardized, search-friendly dropdown menus
  - Added `Theme.align(ctx, [row_h], [item_h])` single unified vertical centering function supporting standard rows, table cells with automatic `CellPadding.y` compensation, and mixed-height `SameLine` rows
  - Fixed text baseline misalignment in `Theme.toggle_button()` and `Theme.badge()` by letting button heights flow naturally from `Font + FramePadding` (`h = 0`) instead of forcing fixed bounding box heights
  - Deprecated `Theme.vcenter()` as low-level escape hatch in favor of `Theme.align()`
  - Unified scale extended to `xxl=24` and `xxxl=32`
  - Streamlined theme modes to 2: **Fancy Dark** (curated palette) and **Match Theme** (extracts surfaces, text, borders, and edit cursor accent `col_cursor` from REAPER)
  - All layout tokens (`rounding`, `icon_sm/md/lg`, `row_h`, `chk_col_w`, `indent`, `section_gap`) strictly derive from scale tokens; dropdowns and combo boxes calculate reactive width dynamically via `Theme.calc_combo_width()`
  - Added blue secondary accent color `accent2` / `blue` (`0x4DA6FFFF`) to `FANCY_PALETTE` with derived states `accent2_h`/`blue_h` (80%), `accent2_d`/`blue_d` (33%), and `accent2_e`/`blue_e` (12.5%) for info indicators, links, and secondary badge highlights
  - `FANCY_PALETTE` simplified to base colors; derived states (`accent_h/d/e`, `accent2_h/d/e`, `green_h/d`, `red_h/d`, `blue_h/d/e`) computed dynamically with consistent alpha ratios (80% / 33% / 12.5%)
  - Safe color math: `icon_btn` hover uses `lighten()` and `section_divider` uses `with_alpha()`
    - Added high-contrast text tokens (`accent_l`, `accent2_l`/`blue_l`, `green_l`, `red_l`, `yellow_l`) derived via 70% lightening for WCAG AAA badge text and active controls
    - Hardened `Theme.badge()` and `Theme.toggle_button()` defaults to automatically derive high-contrast text and 33% alpha background from base semantic colors
- **Fancy Design System v1.2.0** — Added live interactive demonstrations for `Theme.progress_bar()`, `Theme.toggle_button()`, `Theme.badge()`, `Theme.combo()`, `_l` high-contrast text tokens, and `L.btn_sm` table controls, secondary accent / blue swatches and info badges, eliminated raw hex color literals
- **Fancy Parameter Link v5.2.0** — Updated Track B name labels and Track B Live Values indicators to use the secondary accent color (`P.accent2` / `P.blue`), and transitioned all badges and toolbar buttons to first-class `P.*_l` high-contrast palette tokens

### Fixed
- **Fancy Parameter Link v5.4.1 (`FX/Fancy_Parameter Link.lua`)** — ReaImGui window lifecycle correction:
  - `reaper.ImGui_End(ctx)` and the preset, info, and settings modals now run only inside `if vis then`. Previously `ImGui_End` ran even when `ImGui_Begin` returned false (window in an inactive dock tab or fully clipped), causing a double End and a ReaImGui stack error.
  - Corrects the v5.2.0 "guarantee `reaper.ImGui_End(ctx)` is called when `reaper.ImGui_Begin()` returns false" fix: that is the Dear ImGui C++ rule. ReaImGui's `Begin` and `BeginChild` already call `End`/`EndChild` themselves when they return false, so scripts must only call them when Begin returned true.
- **Fancy Pitch Correct v2.4.1 (`Pitch/Fancy_Pitch Correct.lua`)** — ReaImGui window lifecycle correction:
  - `reaper.ImGui_End(ctx)` and the settings and info modals now run only when `ImGui_Begin` returns true, fixing a double End and ReaImGui stack error when the window is in an inactive dock tab or fully clipped. The window padding and item spacing style vars are still popped every frame.
- **Fancy Selected Track Meter v9.67.1 (`Metering/Fancy_Selected Track Meter.lua`)** — ReaImGui window lifecycle correction:
  - The Track Meters, Recent Clips, and Meter Settings windows now call `reaper.ImGui_End(ctx)` only when their `ImGui_Begin` returns true, fixing a double End and ReaImGui stack error when a window is collapsed, fully clipped, or in an inactive dock tab.
- **Fancy Pan Snap v1.7.1 (`Routing/Fancy_Pan Snap.lua`)** — ReaImGui window lifecycle correction:
  - The HUD window and the floating cursor tooltip now call `reaper.ImGui_End(ctx)` (and, for the HUD, draw the info and settings modals) only when `ImGui_Begin` returns true, fixing a double End and ReaImGui stack error when the window is in an inactive dock tab or fully clipped.
- **UI Legibility & WCAG Contrast Hardening**:
  - Added first-class `_l` palette tokens (70% lightened text) and updated `Theme.badge()` / `Theme.toggle_button()` defaults to eliminate low-contrast badge text (boosting contrast ratios from ~3.3:1 – 5.5:1 up to 6.5:1 – 8.1:1, passing WCAG AAA on toolbar action buttons and badges)
  - Fixed `OFFLINE` status badge in `Fancy_Parameter Link.lua` to automatically use `P.red_l` / high-contrast red instead of unlightened `P.red` (raising contrast from 3.3:1 to 7.5:1)
- **Section Dividers & Info Tooltips (`_lib/theme.lua`)**:
  - Increased default info icon size in `Theme.section_divider()` from `icon_sm` (8px) to `icon_md` (12px) for improved visibility and legibility next to section titles (e.g. Tracks, Plugin, Link Builder)
  - Added vertical alignment using `Theme.align()` to align the section title baseline and center the info button within the frame height
- **Theme Engine Hardening & Bug Fixes (`_lib/theme.lua`)**:
  - Fixed `Theme.center_next_window()` to dynamically center relative to the active parent window (with viewport fallback) using `(0.5, 0.5)` pivot alignment, fixing off-center horizontal positioning when opening modals (e.g. Settings, Info & Guide, Preset Manager)
  - Added missing `ImGui_Col_Text`, `ImGui_Col_TextDisabled`, `ImGui_Col_Border`, and `ImGui_Col_ScrollbarGrabActive` to `Theme.push()` (updating push/pop stack parity to 32 colors)
  - Fixed 64-bit Lua 5.4 integer underflow/overflow and sign extension in `darken()`, `lighten()`, and `with_alpha()` via strict boundary clamping
  - Fixed custom REAPER color flag (bit 24) decoding in `bgr_to_rgba()` by unconditionally masking `0x00FFFFFF`
  - Eliminated per-frame closure allocations in `Theme.combo()` by factoring item label resolution to file scope
  - Eliminated per-widget C-API `reaper.GetExtState` queries by caching `_cached_mode` in memory
  - Eliminated per-frame table churn in `Theme.settings_widget()` and `Theme.header()` by using static option tables
  - Added public `Theme.get_palette()` accessor and optimized `Theme.push()` to consume cached palette
  - Fixed `Theme.layout.btn_lg.h` token from 26 to 24px to match natural button height flow (`16 + 4*2`)
  - Fixed string preset normalization in `Theme.push_button_preset()` (`"sm"`, `"small"`, `"lg"`, `"large"`)
  - Fixed `Theme.toggle_button()` crash when `id` argument is `nil`
  - Fixed `Theme.header()` right-aligned width allocation and spacing with custom widgets, and added vertical alignment for close button
  - Removed orphaned docblock above `Theme.push_button_preset()`
- **Parameter Link Engine Hardening & Optimization (`FX/Fancy_Parameter Link.lua`)**:
  - Preserved and hardened direct bidirectional parameter modulation and full-mesh topology across all linked tracks
  - Added FX GUID resolution and validation (`resolve_fx`) to guard against FX reordering, movement, or deletion
  - Added Master Track support to track caching and selector lists
  - Added project tab change detection to automatically persist and switch project configuration files
  - Fixed ReaImGui window lifecycle to guarantee `reaper.ImGui_End(ctx)` is called when `reaper.ImGui_Begin()` returns false
  - Eliminated per-frame link group table allocations with dirty-flag invalidation caching (`get_link_groups`)
  - Eliminated per-frame row string concatenations by scoping table rows with `reaper.ImGui_PushID(ctx, i)`
  - Gated `poll_last_touched()` behind integer target change checks to eliminate redundant string and regex operations
  - Added "Delete Selected" batch action button to Active Links toolbar
  - Added Enter key confirmation to Save Preset popup and Escape key dismissal across all modal dialogs
  - Standardized Live Values display with dual `Theme.badge()` indicators with natural button height flow (`preset = L.btn_sm`)
  - Fixed table cell vertical alignments using `Theme.align(ctx, row_h)` and `Theme.align(ctx, row_h, item_h)`
  - Fixed Section 10 numbering and removed phantom undo points from internal state mutations

### Changed
- **Fancy Parameter Link v5.2.0** — Complete Design System & Theme Engine migration
  - Replaced all hardcoded colors, spacing, and font definitions with `_lib/theme.lua` tokens and dynamic palette
  - Standardized Active Links table controls to `Theme.layout.btn_sm` (16px height, small typography, and frame padding across Live Values, Mode, and Strength)
  - Set Active Links parameter groups to start closed by default
  - Converted custom UI widgets to `Theme.progress_bar()`, `Theme.badge_button()`, and `Theme.combo()`
  - Set Active Links parameter groups to start closed by default
  - Standardized window header with `Theme.header()` featuring brand icon, dynamic subtitle status toasts, right widgets, and reactive theme switcher
  - Converted dialogs and modals to use `Theme.center_next_window()`, `Theme.section_divider()`, `Theme.push_font()`, and `Theme.settings_widget()`
  - Replaced custom buttons and icons with `Theme.icon_btn()`, `Theme.icon_btn_colored()`, `Theme.collapsing_header()`, and `Theme.icons.*`
  - Integrated `_lib/utils.lua` for clean undo blocks and safety guards
- **Fancy Parameter Link v5.0.0** — Major redesign
  - **Bidirectional links**: either side of a link can drive the other (no more source/target distinction)
  - **Multi-track selection**: select N tracks and link them all at once (full-mesh topology)
  - **Grouped active links**: links in the table are grouped by plugin/parameter for cleaner display
  - Presets now apply across all selected tracks (not just 2)
  - Last Touched adds tracks to selection instead of overwriting source/target
  - Data model changed from src/dst to symmetric a/b naming

## [1.0.0] - 2026-08-27

### Added
- **Fancy ParameterLink** — Link FX parameters between tracks (Follow/Inverse/adjustable strength)
- **Fancy Selected Track Meter** — Real-time visual metering for selected tracks
- **Fancy Copy Fader to Send** — Copy Main Fader volume to a Send
- ReaPack distribution with automated CI/CD pipeline
- GitHub Sponsors integration

---

*This changelog follows [Keep a Changelog](https://keepachangelog.com/) format.*
