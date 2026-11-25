# Pitch Correct icon — short design

**Status:** approved in the brainstorm on 2026-11-25 (mockup "V1, refined").

## Intent
Pitch Correct borrows the shared Fancy logo (`Theme.brand_icon`, first made for Parameter Link). It should get its own icon
that says what it does, both in its window header and as a toolbar button users can pick.

## The icon (24-unit artwork)
- Two thin grey lane lines (y 6.8 and 17.2), like the canvas's note lanes.
- A white vibrato line that wobbles **between** the lanes (above the bottom one), rises and runs straight to the end of…
- …a green note block (rounded bar, x 12.4–22.4, y 4.3–9.3) sitting **in front of** the top lane.
- Colour (header): lanes `text_dim` at 35 %, note `green`, line `text`, on the same recessed card as `brand_icon`
  (`well` fill, `outline` frame). The white line is drawn in front of the note.
- One colour (toolbar): everything in one colour; the line through the note is **cut out** of the note (a same-colour
  line would vanish), and the top lane stops at the note. Frames as Parameter Link's strip: normal `#C2C6CE`,
  hover `#FFFFFF`, on = Fancy accent `#46B9FE` (my call: today's accent, not Parameter Link's older purple).

## Approaches considered
- A Settle, B note blob, C snap (dots), D brand remix → user liked C's snap but wanted notes, not circles.
- C1–C4 note-block snaps → user combined C2's two lane lines with C4's line-into-note.
- V1 smooth / V2 jagged / V3 waveform line → V1, refined as above.

## Deliverables
- `toolbar_icons/svg/fancy_pitch_correct.svg` (colour master) and `toolbar_icons/svg/toolbar_fancy_pitch_correct.svg`
  (3-frame one-colour master).
- `toolbar_icons/toolbar_fancy_pitch_correct.png` 90×30, `150/` 135×45, `200/` 180×60, rendered from the master with
  headless Chrome (transparent background).
- Script: a local header-icon draw function replacing `Theme.brand_icon` in the header; `[data]` lines in `@provides`
  so ReaPack installs the PNGs into REAPER's `Data/toolbar_icons/`; version 2.28.0; CHANGELOG entry.

## Non-goals
- No change to `Theme.brand_icon` or other scripts' icons. Parameter Link's toolbar strip stays as it is.
