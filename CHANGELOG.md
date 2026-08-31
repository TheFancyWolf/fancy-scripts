# Changelog

All notable changes to Fancy Scripts will be documented here.

## [Unreleased]

### Added
- **Shared Library (`_lib/`)** — shared modules loaded via `require()`
  - `theme.lua` — 2-mode palette builder (Fancy Dark / Match Theme), shared font management, ImGui push/pop, settings combo widget
  - `json.lua` — lightweight JSON encoder/decoder (consolidated from inline copies)
  - `utils.lua` — dependency checks, undo block wrapper, track helpers, math utilities
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
