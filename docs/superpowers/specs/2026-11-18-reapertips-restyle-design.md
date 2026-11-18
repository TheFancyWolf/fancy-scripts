# Fancy Scripts: the Reaper Tips look replaces Fancy Dark

Status: Approved by the user on 2026-11-18
Date: 2026-11-18
Target files: `_lib/theme.lua` (the design system), `Pitch/Fancy_Pitch Correct.lua` (first script tuned
against it), `_lib/fonts/` (new), `Utility/Fancy_Design System.lua` (showcase), the `@provides` header of
every script that loads the theme library

## Intent

The user's favourite REAPER theme is the Reapertips Theme. Fancy Scripts windows should look like they belong
to it: the same greys, the same blue, the same button, slider, tab and scrollbar shapes, the same typeface
and the same density. Today they are navy and purple with tinted, rounded, bordered controls in the system
font, so they read as a foreign app next to the theme.

This is a restyle of every visual aspect, not a recolour. The user said so explicitly: "its not just colors,
its all the styling for every aspect."

## Goals

- The curated mode of the design system (today "Fancy Dark") becomes the Reaper Tips look. There is no purple
  mode afterwards.
- Buttons, toggles, badges, combos, sliders, checkboxes, tabs, selectables, scrollbars, separators, tables,
  popups, tooltips and the window header all take the theme's shapes, fills, outlines and states.
- Type is Fira Sans at the theme's sizes; spacing and control height match the theme's density.
- Fancy Pitch Correct is the reference script: every part of it, including the hand-drawn canvas (rows,
  note column, notes, ruler, strips, pills, sidebar), is checked and tuned against the new look.
- Every other script that uses the library picks the look up without code changes of its own.

## Non-goals

- Redesigning any layout or interaction. Where controls sit, what they do and what they say stays as it is;
  only how they are drawn changes. `docs/design/pitch-correct.md` stays the layout authority.
- A per-script tuning pass for the other scripts (Parameter Link, Pan Snap, Mapper Settings, Tap Tempo Slew
  Settings). They inherit the look; individual touch-ups are later work, one script at a time.
- Edits in the other scripts beyond three narrow exceptions: the `@provides` line for the font files, a
  missing-symbol swap (section 4), and a label that names a colour that changed (Pan Snap's menu says
  "Secondary Accent (Blue)").
- `Metering/Fancy_Selected Track Meter.lua`. It draws with its own 39 hex literals and barely uses the
  library, so it does not change here.
- Matching Reapertips v1.95. The measurements below come from v1.82, the version installed on the user's
  machine.
- The theme's light, hybrid, green and purple variants.

## Anti-goals

- Shipping or loading the theme's own PNG images. They are not ours to redistribute, and the look must not
  depend on the theme being installed.
- A look that only works when the Reapertips Theme is the active REAPER theme. The curated mode uses fixed
  values and looks the same under any REAPER theme.
- Breaking the library's API. Every existing palette field, layout token, widget and option keeps working,
  so no script fails to load or draws an unstyled control.
- Text that is hard to read. Fidelity to the theme never takes body or label text below 4.5:1.
- A script that fails or looks broken when the bundled font cannot be loaded.

## Constraints

- All styling flows through `_lib/theme.lua`: palette (`Theme.build_palette`), layout tokens
  (`Theme.layout`), fonts (`Theme.create_fonts`), the style stack (`Theme.push`, 32 colours and 10 vars) and
  the widgets. Pitch Correct contains no colour literals; the other themed scripts contain almost none.
- The theme mode is one global setting (`ExtState "FancyScripts" / "theme_mode"`, values `fancy` and
  `match`), shared by every script. A library change shows up everywhere at once.
- Scripts are published through ReaPack. Each script's `@provides` lists the shared files it needs
  (`[nomain] ../_lib/*.lua` today); a font file has to be listed the same way to reach users.
- Scripts use the layout scale as raw pixels in their own layouts (`L.sm` 145 times, `L.md` 143 times). The
  scale values (2 / 4 / 8 / 12 / 16 / 24 / 32) therefore do not change; density changes come from which
  token each style var uses and from the font size.
- Raw `ImGui_Button`, `ImGui_SliderDouble`, `ImGui_Checkbox` calls in scripts are styled only through the
  style stack, so the look has to work at that level, not only inside the library's own widgets.
- ReaImGui's font API differs between versions (the library already wraps `PushFont` in `pcall` for this).
  Font loading has to work on the versions the scripts support and degrade safely on the rest.
- There is no test suite. `luac -p` and `luacheck` (`.luacheckrc`, Lua 5.4) are available; nothing here can
  launch REAPER, so the final look is confirmed by the user in REAPER.

## What the theme looks like (measured from Reapertips Theme v1.82)

Values were read from the theme's `.ReaperTheme` colour table and sampled from its control images at 100 %.

| Element | Measurement |
|---|---|
| Window / list background | `#323232` |
| Raised surface | `#3E3E3E`; track rows `#424242` / `#454545` |
| Recessed well (edit boxes, editor background) | `#2A2A2A` |
| Docker / title strip | `#2D2D2D` |
| Text | `#D9D9D9` on controls, `#C8C8C8` in lists; secondary `#A0A0A0`; faint `#7B7B7B` |
| Accent | `#46B9FE` (edit cursor, active toolbar text, meters, transport "on") |
| Button, resting | flat `#454545` face, 1 px `#181818` outline, square to very slightly rounded corners, 20 px tall |
| Button, hover | face `#585858` |
| Button, pressed / toolbar "down" | face `#2E2E2E`, outline `#252525` |
| Button, on | solid fill: blue `#46B9FE` family for general state, red `#BB3B4F` for mute, yellow `#D2A436` for solo; label stays light on red and yellow, dark `#0F2B3B` on blue |
| Slider | groove is a dark translucent strip (black at about 10 %); thumb `#C2C2C2` with a `#282828` outline |
| Tabs | selected `#AAAAAA` with dark text, unselected `#383838` |
| Scrollbar | grab is white at about 17 % (26 % on hover) over `#333333` |
| Hairlines | `#1D1D1D` (list grid), `#333333` (track divider) |
| Selection in lists | `#2E51DE` with white text; inactive `#282828` |
| Semantic hues | green `#44CD8C`, red `#E45E65` / `#BB3B4F`, amber `#FEC13A` |
| MIDI editor (model for the canvas) | rows `#4C4C4C` / `#424242`, outer `#333333`, row lines `#2D2D2D`, ruler `#333333` with `#C8C8C8` text, keys `#BABABA` / `#282828`, play cursor amber `#FEC13A`, edit cursor blue |
| Typeface | Fira Sans Regular; 11 px for most UI text, 13 px for larger labels; Fira Sans Bold in the timeline; Roboto Bold only in the transport clock |

## Approaches

**A. Recolour only.** Change the values in `FANCY_PALETTE` and leave everything else. A few lines, no risk.
Rejected: buttons stay accent-tinted, translucent, 4 px rounded and light-bordered; the font and the spacing
do not change. It is a different colour scheme on the same look, which is what the user ruled out.

**B. Full restyle in the library (chosen by the user).** Give the palette real control roles (button face,
hover, pressed, on, outline, well, thumb, tab), map the style stack and every library widget to them, change
rounding, spacing and control height, and switch the typeface. Then sweep Pitch Correct's hand-drawn parts.
More work, touches every widget, but it is the only way the shapes and states match.

**C. Skin the controls with the theme's PNGs.** Pixel-identical. Rejected: only works where the theme is
installed, the images cannot be shipped through ReaPack, and bitmaps do not scale with the font.

The user picked B from side-by-side mockups in the conversation on 2026-11-18.

## Design

### 1. Modes

- The curated mode keeps its stored value `fancy`, so nobody's saved setting breaks. Its label in the
  settings combo changes from "Fancy Dark" to **"Fancy"** *(my call: "Dark" described the old navy look; the
  user may prefer another name)*.
- **Match Theme** stays. It keeps reading surfaces, text and accent from the active REAPER theme, and gets the
  same control roles, shapes, spacing and font as the curated mode. Its role values are derived from what it
  reads (button face from the theme's `col_buttonbg`, well from `col_main_editbk`, and so on) and fitted for
  contrast the way the mode already does it.

### 2. Palette

Existing fields keep their names and get new values in the curated mode:

| Field | New value | Note |
|---|---|---|
| `bg` | `#323232` | window |
| `panel` | `#3E3E3E` | popups, raised strips, note column |
| `card` | `#424242` | cards, table header |
| `text` | `#D9D9D9` | |
| `text_dim` | starts at `#A0A0A0`, lifted only as far as 4.5:1 needs on `bg`, `panel`, `card` and the button face | uses the library's existing contrast fitter |
| `accent` | `#46B9FE` | |
| `accent2` / `blue` | `#A990F5` (a soft violet) | *my call*: the secondary accent can no longer be blue, since blue is now the primary. The theme's teal `#40BF9F` was considered and dropped: it sits 13 degrees of hue from the green and 1.13:1 from it in brightness, and the two meet on the canvas and in Parameter Link. Violet is far from blue, green, cyan and yellow. The field names `blue*` stay as aliases |
| `green` | `#44CD8C` | |
| `red` | `#E45E65` | |
| `yellow` | `#FEC13A` | |
| `border` | `#181818` | the control outline; see "Contrast" |
| `sep` | `#1D1D1D` | hairline, no longer an accent tint |

The derived fields (`accent_h`, `accent_d`, `accent_e`, `accent_l`, `*_h`, `*_d`, `*_l`, `table_row*`,
`dim_bg`, `slider_grab_active`) stay, so existing script code keeps working, but the style stack stops using
accent tints for resting controls.

New fields, in both modes:

| Field | Curated value | Used for |
|---|---|---|
| `btn` | `#454545` | resting face of buttons, combos, inactive toggles |
| `btn_h` | `#585858` | hovered face |
| `btn_a` | `#2E2E2E` | pressed face |
| `btn_on` | `#46B9FE` | face of an active toggle |
| `on_text` | `#0F2B3B` | label on `btn_on` (fitted to 4.5:1) |
| `outline` | `#181818` | 1 px frame around controls (same value as `border`) |
| `well` | `#2A2A2A` | recessed inputs, slider grooves, checkbox boxes, progress track |
| `thumb` | `#C2C2C2` | slider grab; `thumb_a` `#D9D9D9` while dragged |
| `tab` / `tab_h` / `tab_sel` | `#383838` / `#4D4D4D` / `#585858` | tab faces. The selected tab also gets an accent line along its top edge. The theme's own selected tab is light (`#AAAAAA`) with dark text; three scripts draw tabs with raw ImGui calls, where the label colour cannot change per tab, so a light tab would carry light text and be unreadable |
| `hover` | `#4D4D4D` | hovered selectable / menu row |
| `select` | accent at 25 % over the surface, text stays `text` | selected selectable / menu row. 25 % keeps the label at 4.5:1 on `bg`, `panel` and `card` (35 % does not). The tint alone cannot reach 3:1 against these greys, so library widgets add a marker; see section 5 *(my call: the theme's `#2E51DE` list selection is a second blue that fights the accent)* |
| `scroll` / `scroll_h` / `scroll_a` | white at 17 % / 26 % / 35 % | scrollbar grab |
| `title` | `#2D2D2D` | title bar, docked header strip |

Overrides passed to `Theme.build_palette` keep working for old and new fields alike.

### 3. Style stack (`Theme.push`)

The counts returned to callers may change; every caller already pops with the returned counts.

| ImGui colour | Role |
|---|---|
| `Button` / `ButtonHovered` / `ButtonActive` | `btn` / `btn_h` / `btn_a` |
| `FrameBg` / `FrameBgHovered` / `FrameBgActive` | `well` / a step lighter / a step lighter again |
| `SliderGrab` / `SliderGrabActive` | `thumb` / `thumb_a` |
| `CheckMark` | `accent` |
| `Header` / `HeaderHovered` / `HeaderActive` | `select` / `hover` / `select` (stronger) |
| `Tab`, `TabHovered`, `TabSelected`, `TabSelectedOverline`, `TabDimmed*` | `tab`, `tab_h`, `tab_sel`, `accent`, and `tab` / `tab_sel` for the dimmed pair |
| `ScrollbarBg` / `ScrollbarGrab*` | transparent over the surface / `scroll*` |
| `Separator` | `sep`; hovered and active keep the accent (they mark a draggable splitter) |
| `TitleBg*` | `title` |
| `PopupBg` | `panel` |
| `Border` | `outline` |
| `TableBorder*`, `TableRowBg*`, `TableHeaderBg` | hairline `sep`, `bg` and a step lighter, `card` |
| `Text` / `TextDisabled` | `text` / `text_dim` |

| ImGui var | Value |
|---|---|
| `FrameRounding`, `GrabRounding`, `WindowRounding` (`L.rounding`) | 2 px *(my call: the theme's buttons are square to barely rounded; 0 reads harsh at ImGui's sizes, 4 is today's and too soft)* |
| `FrameBorderSize` | 1 px, in `outline` |
| `FramePadding` | 8 / 4 (unchanged tokens): with the 13 px default font a control is 21 px tall, against the theme's 20 |
| `ItemSpacing` | 4 px horizontal and vertical (today 8 / 4) |
| `WindowPadding` | 8 px (today 12) |
| `CellPadding`, `ItemInnerSpacing`, `IndentSpacing` | unchanged unless they look wrong against the above |

### 4. Type

- Family: **Fira Sans** Regular and Bold, loaded from files shipped in `_lib/fonts/`, with the licence text
  next to them (Fira Sans is under the SIL Open Font License, which allows bundling).
- The files are copies of the Fira Sans Regular and Bold already installed on the user's machine
  (`~/Library/Fonts/FiraSans-Regular.otf`, `FiraSans-Bold.otf`; version 4.203, "Digitized data copyright
  2012-2016, The Mozilla Foundation and Telefonica S.A.", OFL 1.1 per the font's own name table).
- The user's ReaImGui is 0.10.0.5 (Dear ImGui 1.92.1), which exposes `ImGui_CreateFontFromFile`.
- Sizes: small 11, default 13, medium 14, large 16, header 18 (today 12 / 14 / 16 / 18 / 20).
- Fallback order when the file cannot be loaded: the installed family named "Fira Sans", then the current
  system sans-serif. No error dialog; the script runs either way.
- **Symbols Fira Sans does not have.** The two files contain no glyph for ✓ ▸ ◀ ▾ ↔ ● ○, which scripts
  print as text: the check prefix of `Theme.multi_combo` (`_lib/theme.lua`), "Timing ▾" and "▸ / ◀" in
  Pitch Correct, "✓" in Parameter Link's status messages (one place also searches for it to pick a colour),
  "●" / "○" badges in Mapper Settings. Whether ReaImGui 0.10 substitutes a system glyph for a file-loaded
  font cannot be told without running REAPER. So the first thing built is a font check: the Design System
  script shows these seven symbols in the bundled font, and the user looks at it in REAPER before any other
  work depends on the answer.
  - If they render: nothing else to do.
  - If they show as blanks or boxes: the library and Pitch Correct draw them with the library's vector icons
    (`Theme.icons`, adding a check mark and a dot) or plain ASCII, keeping the wording of the approved copy
    deck otherwise. Parameter Link and Mapper Settings get the smallest edit that swaps the symbol; that is
    the one allowed exception to "no code changes" in those scripts, and each gets a version bump.
- `Theme.create_fonts`, `attach_fonts`, `push_font`, `pop_font` keep their signatures and the same eight
  font keys. Roboto is not used: nothing in these scripts corresponds to the transport clock.
- Every script that loads the library gets `_lib/fonts/*` added to its `@provides` and a version bump, so
  ReaPack delivers the files.

### 5. Library widgets

Each keeps its signature and options. Explicit colour options passed by a script still win.

| Widget | New look |
|---|---|
| `toggle_button` | off: `btn` face, `text` label. On: solid `btn_on`, `on_text` label. Hover lightens either. No tint, no accent-coloured text. |
| `badge` | a quiet tag: `well` face, `outline`, `text` label; a coloured badge (`opts.color`) is a solid fill of that colour with a fitted dark or light label |
| `combo`, `multi_combo` | preview looks like a button (`btn` face, outline, chevron); the list is `panel` with `hover` / `select` rows |
| `icon_btn`, `icon_btn_colored` | transparent at rest (the theme's transparent track buttons), `btn_h` on hover, `btn_a` pressed; icon in `text` |
| `selectable` | `hover` / `select` rows, 2 px rounding. A selected row also carries a 2 px solid accent bar on its left edge: that bar is the 3:1 selection marker. The same bar marks the selected row in `combo` and `multi_combo` lists |
| `progress_bar` | `well` track, accent fill, outline |
| `section_divider`, `collapsing_header` | hairline `sep`, label in `text_dim`; header rows use `btn` / `btn_h` |
| `header` (window header bar) | `title` strip, 1 px hairline under it, title in the bold font |
| `settings_widget`, `tooltip_setting_widget` | follow combo and checkbox |
| `tooltip`, `modal_scrim` | `panel` with outline; scrim stays a darkened `bg` |
| Button presets (`btn_sm`, `btn_default`, `btn_lg`) | paddings unchanged, fonts small / default / medium; heights follow from font + padding: 15 / 21 / 22 (today 16 / 22 / 24) |

Sliders, checkboxes, radio buttons and text inputs have no library widget; they take the look from the style
stack: `well` groove or box, `thumb` grab, accent check mark, outline.

### 6. Pitch Correct

No layout or behaviour changes. The sweep covers:

- **Top bar and menus**: item badge as a quiet tag; Key / Scale as button-faced combos; Strength and the
  other sliders with the groove and thumb; Snap / Quantize / Split / Merge as plain theme buttons (they are
  one-shot commands and have no "on" state; the mockup shown in the conversation drew Snap as "on" by
  mistake); the scope pill and the "…" menu. Pitch Correct's on/off controls are checkboxes and one
  checkable menu item, and stay that: `well` box, accent check mark. No control changes type.
- **Canvas** (`P.canvas`, section 4A of the library), modelled on the theme's MIDI editor:
  - rows: a recessed surface, as in the approved mockup. In-scale rows around `#2E2E2E`, black-key rows a
    small step darker, out-of-scale rows a further step darker toward `#262626`, the root row a faint blue
    tint; row hairlines `#1D1D1D`. *(My call: the theme's MIDI editor rows are lighter, `#4C4C4C` /
    `#424242`, but on those a note fill dark enough for its label separates from the row by only about
    1.4:1, which works against "notes first" in `docs/design/pitch-correct.md`.)*
  - note column and ruler: `#333333` with `#C8C8C8` text
  - notes: untouched = a shade of the accent blue, edited = a shade of the green, each dark enough for the
    label to read. The border is the note's own hue (accent / green), at 3:1 or more on every row, exactly
    as today and as Match Theme does it; notes do not get the dark `outline` frame, which would be 1.8:1.
    Selected = brighter fill inside a light border (`#EDEDED`), 3:1 or more. Corner radius follows
    `L.rounding`
  - layers that can overlap stay apart by hue as the library's comments require: notes blue, edited and
    preview green, split markers and the drift zone violet (the secondary accent), spots yellow. The trend
    line and anchor are cyan today, which is now close to the accent; the builder moves them only if they
    cannot be told from a note border in practice, and says so
  - the colour roles approved in `docs/design/pitch-correct.md` stay: pitch trace and playhead in the text
    colour, smart spots and the dragged trim handle in yellow, split markers in the secondary accent
  - overview and range strips: `well` track, accent notes, accent-outlined thumb
  - pills and the status pill: `panel` at 90 % with `text`
- **Sidebar, Settings, Info and confirm dialogs**: checked against the new widgets; any spacing that was
  tuned by eye for the old 22 px controls is re-tuned for 20 px.
- Match Theme's canvas keeps its derivation and its contrast fitting; it only has to keep working with the
  new roles.

### 7. Contrast

The library today requires borders at 3:1 against the surfaces. The theme's own control outline
(`#181818` on `#323232`) is about 1.4:1, and a button face on the window is about 1.3:1, so a faithful
look cannot keep that rule for outlines. *My call:*

- Text and labels: 4.5:1, always, in both modes. This is not relaxed.
- State that carries meaning (toggle on, focus, slider thumb, check mark, the playhead, note borders on
  the canvas, the selection marker of library rows): 3:1 against what it sits on. Not relaxed.
- Selection in rows: the `select` tint is exempt from 3:1 (no tint that light text reads on can reach it
  on these greys). Library rows carry the accent bar, which meets 3:1. Rows drawn by a script with raw
  `ImGui_Selectable` or `ImGui_MenuItem` get the tint only; that is accepted.
- The resting outline and face of a labelled control: follows the theme, no minimum. The label already
  identifies the control.

`docs/design/README.md` and the library's header comment are updated to say this, so later reviews check
against the new rule.

### 8. Documents

- The library's header comment (API quick reference) is updated for the new fields, sizes and rules.
- `CHANGELOG.md` gets an entry for the design system and one for each script whose version is bumped.
- Mentions of "Fancy Dark" in the library and in `Utility/Fancy_Design System.lua` follow the new label.
  Older plans and specs under `docs/` are history and stay as written.
- `Utility/Fancy_Design System.lua` shows the new roles (button states, well, thumb, tabs, scrollbar) so the
  whole kit can be judged in one window.

## Left to the builder

- Exact `FramePadding` values and the in-between shades (hovered well, table alt row, hovered tab), within
  the measurements above.
- How the new roles are derived in Match Theme, as long as text stays at 4.5:1 and meaningful state at 3:1.
- Which ReaImGui call loads the font file on each supported version, and the order of the fallbacks' checks.
- Whether a role is a new palette field or a derived local, where no script needs to read it.
- Fine tuning of Pitch Correct's hand-drawn sizes that were set by eye.

## Verification

- `luac -p` and `luacheck` pass on every changed file.
- First, before the rest is built: the font check of section 4, looked at by the user in REAPER.
- A throwaway Lua harness with a stubbed `reaper` table builds the palette in both modes and asserts the
  contrast rules of section 7 and that every pre-existing palette field and layout token still exists.
- The user opens `Utility/Fancy_Design System.lua` and `Pitch/Fancy_Pitch Correct.lua` in REAPER, in the
  curated mode and in Match Theme, and compares them with the Reapertips Theme. Nothing in this environment
  can run REAPER, so this step is the user's and the work is not called done before it.
- With the font files removed, both scripts still open and fall back to the next font.
