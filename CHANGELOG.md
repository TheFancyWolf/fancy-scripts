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
  - `FANCY_PALETTE` simplified to base colors; derived states (`accent_h/d/e`, `green_h/d`, `red_h/d`) computed dynamically with consistent alpha ratios (80% / 33%)
  - Safe color math: `icon_btn` hover uses `lighten()` and `section_divider` uses `with_alpha()`
  - Added minimal template and full API token references in `theme.lua`
- **Fancy Design System v1.2.0** — Added live interactive demonstrations for `Theme.progress_bar()`, `Theme.toggle_button()`, `Theme.badge()`, `Theme.combo()`, and `L.btn_sm` table controls, eliminated raw hex color literals
- **Fancy Parameter Link v5.1.0** — "All" button in Link Builder to select/deselect all parameters at once

### Fixed
- **Theme Engine Hardening & Bug Fixes (`_lib/theme.lua`)**:
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
