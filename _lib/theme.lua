-- Fancy Scripts -- Design System & Theme Engine
-- Single source of truth for ALL visual decisions. local Theme = require("theme")
--
-- =============================================================================
-- API QUICK REFERENCE
-- =============================================================================
--
-- PALETTE -- Theme.build_palette([overrides]) / Theme.get_palette() returns table with:
--   Surfaces:   bg, panel, card               (window bg, popups, frame bg)
--   Text:       text, text_dim                (primary, secondary)
--   Accent:     accent      = active state    (ButtonActive, CheckMark, SliderGrab)
--               accent_h    = hover  (40%)    (ButtonHovered, HeaderHovered, FrameBgActive)
--               accent_d    = dim    (20%)    (Button, Header, FrameBgHovered, ScrollbarGrab)
--               accent_e    = subtle (12.5%)  (TableBorderLight)
--               accent_l    = light  (70%)    (High-contrast text on badges/active toggles)
--   Secondary:  accent2 / blue = active state (secondary accent, info, badge highlights)
--               accent2_h / blue_h = hover (40%)
--               accent2_d / blue_d = dim   (20%)
--               accent2_e / blue_e = subtle (12.5%)
--               accent2_l / blue_l = light (70%) (High-contrast text on badges/info)
--   Semantic:   green/green_h/green_d/green_l (success, enabled, positive)
--               red/red_h/red_d/red_l         (error, delete, destructive)
--               yellow/yellow_l               (warning, caution)
--               blue/blue_h/blue_d/blue_e/blue_l (info, secondary accent)
--   Structure:  border, sep, dim_bg           (borders, separators, modal overlay)
--   Table:      table_row, table_row_alt      (alternating row backgrounds)
--   Controls:   slider_grab_active            (slider grab while dragging)
--   Helpers:    Theme.with_alpha(rgba, a) / .lighten(rgba, f) / .darken(rgba, f) / .bgr_to_rgba(bgr)
--
-- THEME MODES -- Theme.get_mode() / .set_mode(mode) / .invalidate_palette()
--   MODE_FANCY="fancy"  Curated dark, purple accent
--   MODE_MATCH="match"  Everything from REAPER theme (including edit cursor accent)
--
-- LAYOUT TOKENS -- Theme.layout.*
--   Scale:      xs=2  sm=4  md=8  lg=12  xl=16  xxl=24  xxxl=32 (unified scale)
--   Rounding:   rounding=sm (4) (universal: windows, frames, grabs, drawlist)
--   Table:      row_h=xxl (24)  chk_col_w=xxl (24)  indent=xxxl (32)
--   Modals:     modal_sm/md/lg/xl = {w, h}
--   Misc:       tooltip_wrap=300  section_gap=sm (4)
--
-- BUTTON PRESETS -- height flows from font + padding (no hardcoded heights)
--   btn_sm = {pad_x=sm, pad_y=xs, font="small", h=16}   Push FramePadding + font
--   btn_default = global FramePadding (md,sm) (h=22)    No override needed
--   btn_lg = {pad_x=lg, pad_y=sm, font="medium", h=24}  Push FramePadding + font
--   Usage:
--     PushStyleVar(ctx, FramePadding, L.btn_lg.pad_x, L.btn_lg.pad_y)
--     push_font(ctx, fonts[L.btn_lg.font])
--     Button(ctx, "Label")
--     pop_font(ctx, pushed) / PopStyleVar(ctx, 1)
--
-- ICON PRESETS -- button dim = size + pad*2
--   icon_sm={size=md,pad=xs}->12px  icon_md={size=lg,pad=sm}->20px  icon_lg={size=xl,pad=md}->32px
--   Pass via opts.preset: Theme.icon_btn(ctx, id, fn, {preset = L.icon_sm})
--
-- FONTS -- Theme.font_sizes: small=12 default=14 medium=16 large=18 header=20
--   create_fonts(ctx)          -> {default,small,medium,large,header,default_bold,medium_bold,large_bold}
--   attach_fonts(ctx, fonts)   -> call once before first frame
--   push_font(ctx, font, [sz]) -> bool (safe pcall, auto-resolves size from registry)
--   pop_font(ctx, pushed)      -> conditional pop
--   fonts.tooltip = fonts.default (backward-compat alias)
--
-- STYLE -- Theme.push(ctx, [palette]) -> nc=32, nv=9 / Theme.pop(ctx, nc, nv)
--   Colors: WindowBg, TitleBg*2, Header*3, Button*3, FrameBg*3, Slider*2, CheckMark,
--           Popup, ModalDim, Separator*3, Table*5, Scrollbar*3, ScrollbarGrabActive,
--           Text, TextDisabled, Border
--   Vars:   WindowRounding, FrameRounding, GrabRounding, ItemSpacing, FramePadding,
--           WindowPadding, CellPadding, ItemInnerSpacing, IndentSpacing
--
-- ICONS -- function(dl, cx, cy, half_size, color)
--   Theme.icons: play, pause, close, plus, info, tri_down, tri_up
--
-- WIDGETS
--   icon_btn(ctx, id, icon_fn, [opts])         -> bool  opts: preset,w,h,icon_size,color,tooltip
--   icon_btn_colored(ctx, id, icon_fn, [opts]) -> bool  opts: +bg,bg_hover,bg_active,icon_color
--   tooltip(ctx, text, [max_w])
--   section_divider(ctx, label, [opts])        opts: tooltip,color,preset,icon_size,w,h,icon_color
--   collapsing_header(ctx, label, [opts])      Safe collapsing header (opts: default_open, flags)
--   progress_bar(ctx, fraction, [opts])        Meter/progress bar (opts: preset,fonts,fill_color,bg_color,overlay)
--   toggle_button(ctx, id, label, is_act, [o]) Button-derived toggle button (opts: preset,fonts,w,h,colors)
--   badge(ctx, label, [opts])                  Button-derived status badge (opts: preset,fonts,color,bg,w,h)
--   push_button_preset(ctx, fonts, preset)     -> var_count, pushed_font (e.g. for sliders, combos)
--   pop_button_preset(ctx, var_count, pfont)   Pops styling pushed by push_button_preset
--   combo(ctx, id, items, selected_idx, [opts]) Standardized combo box (opts: w, placeholder, get_label)
--   multi_combo(ctx, id, items, sel, [opts])   Standardized multi-select combo (compact, full-row hover/click)
--   header(ctx, opts)                          Standardized window header bar (title, FANCY prefix, settings, close)
--   center_next_window(ctx, w, h)
--   brand_icon(ctx, [size], [target_h])
--   get_palette()                              Get active cached palette
--   invalidate_palette()                       Clear internal widget palette cache
--
-- ALIGNMENT
--   align(ctx, [row_h], [item_h])     PRIMARY — call before every item on a row
--                                      No args: text↔widget baseline alignment
--                                      row_h:   center item in explicit row (tables)
--                                      item_h:  custom-height item override
--                                      nil,item_h: center short item in default row
--                                                  (e.g. btn_sm next to default text)
--   vcenter(ctx, item_h, row_h)        Low-level: cursor math (use align() instead)
--   right_align(ctx, item_w, [margin]) Cursor X: right-align next item
--   hcenter(ctx, item_w)               Cursor X: center next item
--
-- SETTINGS
--   settings_widget(ctx, [opts])       Reactive theme mode combo (opts: w, label, align, margin)
--   calc_combo_width(ctx, items, [p])  Calculates reactive width from font metrics + labels
--
-- MINIMAL TEMPLATE:
--   local Theme = require("theme")
--   local ctx = reaper.ImGui_CreateContext("Script Name")
--   local fonts = Theme.create_fonts(ctx)
--   Theme.attach_fonts(ctx, fonts)
--   local function loop()
--     local P = Theme.get_palette()
--     local nc, nv = Theme.push(ctx, P)
--     local pushed = Theme.push_font(ctx, fonts.default)
--     local visible, open = reaper.ImGui_Begin(ctx, "Script Name", true)
--     if visible then reaper.ImGui_Text(ctx, "Hello"), reaper.ImGui_End(ctx) end
--     Theme.pop_font(ctx, pushed)
--     Theme.pop(ctx, nc, nv)
--     if open then reaper.defer(loop) end
--   end
--   reaper.defer(loop)
--
-- =============================================================================
-- RULES: NO hardcoded hex colors, pixel values, fonts, or icon functions.
-- Colors from build_palette(). Dims from layout.*. Fonts from create_fonts().
-- Icons from icons.*. Alignment from align() (primary) / right_align / hcenter.
-- =============================================================================

local Theme = {}

-------------------------------------------------------------------------------
-- 1. COLOR HELPERS
-------------------------------------------------------------------------------

--- Adjusts the alpha channel of an RGBA color with strict [0, 255] clamping.
--- @param rgba integer  Color in 0xRRGGBBAA format
--- @param alpha number  Alpha value (0.0–1.0)
--- @return integer  Color with new alpha
local function with_alpha(rgba, alpha)
  local a = math.max(0, math.min(255, math.floor((alpha or 1.0) * 255 + 0.5)))
  return (rgba & 0xFFFFFF00) | a
end

--- Lightens an RGBA color by blending toward white with strict bounds.
--- @param rgba integer  Color in 0xRRGGBBAA format
--- @param factor number  Lightening factor (0.0 = no change, 1.0 = white)
--- @return integer
local function lighten(rgba, factor)
  local f = math.max(0.0, math.min(1.0, factor or 0.0))
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >> 8) & 0xFF
  local a = rgba & 0xFF
  r = math.max(0, math.min(255, math.floor(r + (255 - r) * f + 0.5)))
  g = math.max(0, math.min(255, math.floor(g + (255 - g) * f + 0.5)))
  b = math.max(0, math.min(255, math.floor(b + (255 - b) * f + 0.5)))
  return (r << 24) | (g << 16) | (b << 8) | a
end

--- Darkens an RGBA color by blending toward black with strict bounds.
--- @param rgba integer  Color in 0xRRGGBBAA format
--- @param factor number  Darkening factor (0.0 = no change, 1.0 = black)
--- @return integer
local function darken(rgba, factor)
  local f = math.max(0.0, math.min(1.0, factor or 0.0))
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >> 8) & 0xFF
  local a = rgba & 0xFF
  r = math.max(0, math.min(255, math.floor(r * (1.0 - f) + 0.5)))
  g = math.max(0, math.min(255, math.floor(g * (1.0 - f) + 0.5)))
  b = math.max(0, math.min(255, math.floor(b * (1.0 - f) + 0.5)))
  return (r << 24) | (g << 16) | (b << 8) | a
end

--- Converts a REAPER native color integer to ImGui RGBA format.
--- REAPER's GetThemeColor returns OS-native colors (BGR on Windows, RGB on
--- macOS). We use reaper.ColorFromNative() to extract R, G, B correctly on
--- any platform, then pack into 0xRRGGBBAA for ReaImGui.
--- Unconditionally masks bit 24 (REAPER's custom color flag) before conversion.
--- @param native integer  Native REAPER color value
--- @return integer  Color in 0xRRGGBBAA format (fully opaque)
local function bgr_to_rgba(native)
  local clean = (native or 0) & 0x00FFFFFF
  local r, g, b = reaper.ColorFromNative(clean)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Expose helpers for scripts that need direct color manipulation
Theme.with_alpha = with_alpha
Theme.lighten = lighten
Theme.darken = darken
Theme.bgr_to_rgba = bgr_to_rgba

-------------------------------------------------------------------------------
-- 2. THEME MODE CONSTANTS & PALETTE CACHE
-------------------------------------------------------------------------------
Theme.MODE_FANCY = "fancy"  -- Curated Fancy Scripts palette (default)
Theme.MODE_MATCH = "match"  -- Everything from REAPER theme (including edit cursor accent)

local EXTSTATE_SECTION = "FancyScripts"
local EXTSTATE_KEY     = "theme_mode"

local _cached_palette = nil
local _cached_mode = nil

--- Returns the current theme mode from global ExtState (cached in memory).
--- @return string  One of "fancy" or "match"
function Theme.get_mode()
  if _cached_mode then return _cached_mode end
  local mode = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY)
  if mode == Theme.MODE_MATCH or mode == "full" then
    _cached_mode = Theme.MODE_MATCH
  else
    _cached_mode = Theme.MODE_FANCY
  end
  return _cached_mode
end

--- Sets the global theme mode (persists across sessions and updates cache).
--- @param mode string  One of Theme.MODE_FANCY, Theme.MODE_MATCH
function Theme.set_mode(mode)
  reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY, mode, true)
  _cached_mode = mode
  _cached_palette = Theme.build_palette()
end

--- Forces the internal widget palette cache to rebuild.
--- Call after Theme.set_mode() or when live REAPER theme colors change.
function Theme.invalidate_palette()
  _cached_palette = nil
  _cached_mode = nil
end

-------------------------------------------------------------------------------
-- 3. CURATED FANCY DARK PALETTE (BASE COLORS)
-------------------------------------------------------------------------------
local FANCY_PALETTE = {
  -- Base surfaces
  bg       = 0x12121EFF,
  panel    = 0x1C1C30FF,
  card     = 0x22223AFF,

  -- Text
  text     = 0xFFFFFFFF,
  text_dim = 0x7A7A9FFF,

  -- Accent (primary purple)
  accent   = 0x8B70FAFF,

  -- Accent (secondary blue)
  accent2  = 0x4DA6FFFF,

  -- Semantic base colors
  green    = 0x56E39FFF,
  red      = 0xF45B69FF,
  yellow   = 0xFFCC66FF,
  blue     = 0x4DA6FFFF,

  -- Structural base
  border   = 0x444444FF,
}

-------------------------------------------------------------------------------
-- 4. REAPER THEME COLOR READER
-------------------------------------------------------------------------------

--- Reads a color from the active REAPER theme and converts to RGBA.
--- Returns the fallback if the key is not found or returns 0.
--- @param key string  REAPER theme INI key (e.g. "col_main_bg2")
--- @param fallback integer  Fallback color in 0xRRGGBBAA format
--- @return integer  Color in 0xRRGGBBAA format
local function read_theme_color(key, fallback)
  local bgr = reaper.GetThemeColor(key, 0)
  if not bgr or bgr < 0 then return fallback end
  return bgr_to_rgba(bgr)
end

-------------------------------------------------------------------------------
-- 5. PALETTE BUILDER
-------------------------------------------------------------------------------

--- Builds a complete color palette based on the current theme mode.
--- Call once at script startup and reuse the returned table.
--- @param overrides table|nil  Optional table of color overrides (e.g. { accent = 0x0088CCFF })
--- @return table  Palette table with all color fields
function Theme.build_palette(overrides)
  local mode = Theme.get_mode()
  local P = {}
  overrides = overrides or {}

  if mode == Theme.MODE_FANCY then
    -- Curated Fancy Dark palette
    P.bg       = overrides.bg       or FANCY_PALETTE.bg
    P.panel    = overrides.panel    or FANCY_PALETTE.panel
    P.card     = overrides.card     or FANCY_PALETTE.card
    P.text     = overrides.text     or FANCY_PALETTE.text
    P.text_dim = overrides.text_dim or FANCY_PALETTE.text_dim
    P.accent   = overrides.accent   or FANCY_PALETTE.accent
    P.border   = overrides.border   or FANCY_PALETTE.border

  elseif mode == Theme.MODE_MATCH then
    -- Everything from REAPER theme (surfaces, text, borders, and accent from edit cursor)
    P.bg       = overrides.bg       or read_theme_color("col_main_bg2",  FANCY_PALETTE.bg)
    P.panel    = overrides.panel    or read_theme_color("col_tr1_bg",    FANCY_PALETTE.panel)
    P.card     = overrides.card     or read_theme_color("col_tr2_bg",    FANCY_PALETTE.card)
    P.text     = overrides.text     or read_theme_color("col_main_text", FANCY_PALETTE.text)
    P.text_dim = overrides.text_dim or read_theme_color("col_tcp_text",  FANCY_PALETTE.text_dim)
    P.accent   = overrides.accent   or read_theme_color("col_cursor", FANCY_PALETTE.accent)
    P.border   = overrides.border   or read_theme_color("col_main_3dhl", FANCY_PALETTE.border)
  end

  -- Semantic base colors & secondary accent
  P.green   = overrides.green   or FANCY_PALETTE.green
  P.red     = overrides.red     or FANCY_PALETTE.red
  P.yellow  = overrides.yellow  or FANCY_PALETTE.yellow
  local blue_base = overrides.accent2 or overrides.blue or FANCY_PALETTE.blue
  P.blue    = blue_base
  P.accent2 = blue_base

  -- Derive semantic states from base colors (consistent 40% / 20% ratios)
  P.green_h = overrides.green_h or with_alpha(P.green, 0.40)
  P.green_d = overrides.green_d or with_alpha(P.green, 0.20)
  P.red_h   = overrides.red_h   or with_alpha(P.red, 0.40)
  P.red_d   = overrides.red_d   or with_alpha(P.red, 0.20)

  -- Derive secondary accent / blue states (consistent 40% / 20% / 12.5% ratios)
  P.blue_h    = overrides.blue_h    or overrides.accent2_h or with_alpha(P.blue, 0.40)
  P.blue_d    = overrides.blue_d    or overrides.accent2_d or with_alpha(P.blue, 0.20)
  P.blue_e    = overrides.blue_e    or overrides.accent2_e or with_alpha(P.blue, 0.125)
  P.accent2_h = P.blue_h
  P.accent2_d = P.blue_d
  P.accent2_e = P.blue_e

  -- Derive accent states from the resolved primary accent color
  -- accent_h = Hover state (40% alpha): ButtonHovered, HeaderHovered, FrameBgActive, SeparatorHovered, ScrollbarGrabHovered
  P.accent_h = overrides.accent_h or with_alpha(P.accent, 0.40)
  -- accent_d = Dim/default state (20% alpha): Button, Header, FrameBgHovered, ScrollbarGrab
  P.accent_d = overrides.accent_d or with_alpha(P.accent, 0.20)
  -- accent_e = Extra-dim (12.5% alpha): TableBorderLight — subtle structural lines
  P.accent_e = overrides.accent_e or with_alpha(P.accent, 0.125)

  -- High-contrast text states (lightened 70% toward white for badges, active states, and dense grids)
  P.accent_l  = overrides.accent_l  or lighten(P.accent, 0.70)
  P.accent2_l = overrides.accent2_l or overrides.blue_l or lighten(P.accent2, 0.70)
  P.blue_l    = P.accent2_l
  P.green_l   = overrides.green_l   or lighten(P.green, 0.70)
  P.red_l     = overrides.red_l     or lighten(P.red, 0.70)
  P.yellow_l  = overrides.yellow_l  or lighten(P.yellow, 0.70)

  -- Derive structural colors
  -- sep = Separator lines (20% accent): Separator
  P.sep    = overrides.sep    or with_alpha(P.accent, 0.20)
  -- dim_bg = Modal overlay background (85% bg): ModalWindowDimBg
  P.dim_bg = overrides.dim_bg or with_alpha(P.bg, 0.85)

  -- Derive table row colors from panel/card
  -- table_row = Default row bg (darkened panel): TableRowBg
  P.table_row     = overrides.table_row     or darken(P.panel, 0.10)
  -- table_row_alt = Alternating row bg (panel): TableRowBgAlt
  P.table_row_alt = overrides.table_row_alt or P.panel

  -- slider_grab_active = Lighter accent for active slider grab: SliderGrabActive
  P.slider_grab_active = overrides.slider_grab_active or lighten(P.accent, 0.15)

  return P
end

--- Returns the active cached palette, rebuilding only when mode changes.
--- @param overrides table|nil  Optional table of color overrides (bypasses cache when provided)
--- @return table  Palette table with all color fields
function Theme.get_palette(overrides)
  if overrides then
    return Theme.build_palette(overrides)
  end
  if not _cached_palette then
    local mode = Theme.get_mode()
    _cached_palette = Theme.build_palette()
    _cached_mode = mode
  end
  return _cached_palette
end

-------------------------------------------------------------------------------
-- 6. DESIGN TOKENS — LAYOUT
-------------------------------------------------------------------------------
--- All spacing, padding, rounding, and sizing values used across scripts.
--- Scripts must reference Theme.layout.* instead of hardcoding pixel values.
--- These values are the authoritative design language for Fancy Scripts.

-- Scale defined once — everything else derives from these values.
local S = { xs = 2, sm = 4, md = 8, lg = 12, xl = 16, xxl = 24, xxxl = 32 }

Theme.layout = {
  -- ── Scale (unified spacing & padding) ──────────────────────────────────
  -- One scale for everything: gaps, padding, margins. Like CSS spacing tokens.
  xs   = S.xs,    -- tight: meter bars, cell padding
  sm   = S.sm,    -- small: related items, inner spacing, frame padding Y, section gap
  md   = S.md,    -- standard: item spacing, frame padding X, tooltips
  lg   = S.lg,    -- large: group breaks, window padding
  xl   = S.xl,    -- extra: major sections, modal padding
  xxl  = S.xxl,   -- 2x: table row height, checkbox column
  xxxl = S.xxxl,  -- 3x: tree/hierarchy indent

  -- ── Rounding ───────────────────────────────────────────────────────────
  rounding     = S.sm,  -- universal corner radius (windows, frames, grabs, drawlist)

  -- ── Button size presets ─────────────────────────────────────────────────
  -- Height flows from font + padding. Default uses global FramePadding (md, sm).
  -- Pass opts.preset (or use push_button_preset) for sm/lg variants.
  btn_sm       = { pad_x = S.sm, pad_y = S.xs, font = "small",   h = 16 },
  btn_default  = { pad_x = S.md, pad_y = S.sm, font = "default", h = 22 },
  btn_lg       = { pad_x = S.lg, pad_y = S.sm, font = "medium",  h = 24 },

  -- ── Icon size presets ───────────────────────────────────────────────────
  -- Button dimension = size + pad * 2. Default icon_btn uses icon_md.
  icon_sm      = { size = S.md, pad = S.xs },   -- 8 + 2*2  -> 12px btn
  icon_md      = { size = S.lg, pad = S.sm },   -- 12 + 4*2 -> 20px btn
  icon_lg      = { size = S.xl, pad = S.md },   -- 16 + 8*2 -> 32px btn

  -- ── Table dimensions ───────────────────────────────────────────────────
  row_h        = S.xxl,             -- standard table row height (24)
  chk_col_w    = S.xxl,             -- checkbox column width (24)
  indent       = S.xxxl,            -- tree / hierarchy indent (32)

  -- ── Modal standard sizes ───────────────────────────────────────────────
  -- Use with Theme.center_next_window(ctx, Theme.layout.modal_md.w, ...)
  modal_sm     = { w = 420, h = 300 },   -- confirmation, simple input
  modal_md     = { w = 560, h = 480 },   -- presets, medium dialogs
  modal_lg     = { w = 660, h = 580 },   -- info panels, detailed forms
  modal_xl     = { w = 800, h = 600 },   -- large editors, split views

  -- ── Tooltip ────────────────────────────────────────────────────────────
  tooltip_wrap = 300,               -- max text wrap width for tooltips

  -- ── Separator / section ────────────────────────────────────────────────
  section_gap  = S.sm,              -- space around section dividers (4)
}

-------------------------------------------------------------------------------
-- 7. IMGUI STYLE PUSH / POP
-------------------------------------------------------------------------------

--- Pushes the full Fancy Scripts ImGui theme onto the style stack.
--- Uses palette colors and layout tokens — no hardcoded values.
--- Call at the start of each frame, before ImGui_Begin.
--- @param ctx userdata  ImGui context
--- @param palette table|nil  Palette from build_palette() / get_palette() (builds default if nil)
--- @return integer color_count  Number of style colors pushed (32)
--- @return integer var_count  Number of style vars pushed (9)
function Theme.push(ctx, palette)
  local P = palette or Theme.get_palette()
  local L = Theme.layout

  -- Style colors (32 total)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),             P.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),              P.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),        P.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),               P.accent_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),        P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),         P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),               P.accent_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),        P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),         P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),              P.card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),       P.accent_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),        P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),           P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(),     P.slider_grab_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),            P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),              P.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ModalWindowDimBg(),     P.dim_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),            P.sep)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorHovered(),     P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorActive(),      P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableHeaderBg(),        P.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(),    P.sep)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(),     P.accent_e)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableRowBg(),           P.table_row)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableRowBgAlt(),        P.table_row_alt)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),          P.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),        P.accent_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(),  P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),                 P.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),         P.text_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),               P.border)

  -- Style vars (9 total — all values from layout tokens)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),  L.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   L.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),    L.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),     L.md, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    L.md, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),   L.lg, L.lg)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(),     L.sm, L.xs)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemInnerSpacing(),L.sm, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_IndentSpacing(),   L.indent)

  return 32, 9
end

--- Pops all Fancy Scripts ImGui styles from the stack.
--- Call after ImGui_End, using the counts returned by Theme.push().
--- @param ctx userdata  ImGui context
--- @param nc integer|nil  Number of colors to pop (default 32)
--- @param nv integer|nil  Number of vars to pop (default 9)
function Theme.pop(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc or 32)
  reaper.ImGui_PopStyleVar(ctx, nv or 9)
end

-------------------------------------------------------------------------------
-- 8. DESIGN TOKENS — TYPOGRAPHY
-------------------------------------------------------------------------------
--- Font families and size scale. Scripts must use Theme.font_sizes.* tokens
--- and Theme.create_fonts() instead of calling ImGui_CreateFont directly.

Theme.font_family      = "sans-serif"
Theme.font_bold_family = "sans-serif Bold"

Theme.font_sizes = {
  small   = 12,    -- labels, secondary text, table metadata
  default = 14,    -- body text, standard UI elements
  medium  = 16,    -- emphasized text, settings labels
  large   = 18,    -- section headers, dialog titles
  header  = 20,    -- primary headers, window titles
  tooltip = 14,    -- tooltip text (kept for backward compat, = default)
}

-------------------------------------------------------------------------------
-- 9. FONT MANAGEMENT
-------------------------------------------------------------------------------

--- Creates a complete set of shared fonts for a ReaImGui context.
--- Call once at script startup, before the defer loop.
--- Produces 8 fonts: default, small, medium, large, header (regular)
---                    default_bold, medium_bold, large_bold (bold)
--- @param _ctx userdata  ImGui context (unused but kept for API consistency)
--- @param overrides table|nil  Optional: { family="Arial", bold_family="Arial Bold", large=24, ... }
--- @return table  Font table with keys: default, small, medium, large, header,
---                default_bold, medium_bold, large_bold
function Theme.create_fonts(_ctx, overrides)
  overrides = overrides or {}
  local family      = overrides.family      or Theme.font_family
  local bold_family = overrides.bold_family or Theme.font_bold_family
  local sizes = {
    small   = overrides.small   or Theme.font_sizes.small,
    default = overrides.default or Theme.font_sizes.default,
    medium  = overrides.medium  or Theme.font_sizes.medium,
    large   = overrides.large   or Theme.font_sizes.large,
    header  = overrides.header  or Theme.font_sizes.header,
  }

  local fonts = {}
  -- Regular weights
  fonts.default = reaper.ImGui_CreateFont(family, sizes.default)
  fonts.small   = reaper.ImGui_CreateFont(family, sizes.small)
  fonts.medium  = reaper.ImGui_CreateFont(family, sizes.medium)
  fonts.large   = reaper.ImGui_CreateFont(family, sizes.large)
  fonts.header  = reaper.ImGui_CreateFont(family, sizes.header)
  -- Bold weights
  fonts.default_bold = reaper.ImGui_CreateFont(bold_family, sizes.default)
  fonts.medium_bold  = reaper.ImGui_CreateFont(bold_family, sizes.medium)
  fonts.large_bold   = reaper.ImGui_CreateFont(bold_family, sizes.large)
  -- Backward compat alias
  fonts.tooltip = fonts.default

  -- Store font→size mapping for push_font (ImGui_PushFont requires size arg)
  Theme._font_sizes = Theme._font_sizes or {}
  Theme._font_sizes[fonts.default]      = sizes.default
  Theme._font_sizes[fonts.small]        = sizes.small
  Theme._font_sizes[fonts.medium]       = sizes.medium
  Theme._font_sizes[fonts.large]        = sizes.large
  Theme._font_sizes[fonts.header]       = sizes.header
  Theme._font_sizes[fonts.default_bold] = sizes.default
  Theme._font_sizes[fonts.medium_bold]  = sizes.medium
  Theme._font_sizes[fonts.large_bold]   = sizes.large

  return fonts
end

--- Attaches all fonts from a font table to a ReaImGui context.
--- Must be called before the first frame is rendered.
--- @param ctx userdata  ImGui context
--- @param fonts table  Font table from Theme.create_fonts()
function Theme.attach_fonts(ctx, fonts)
  local attached = {}
  for _, font in pairs(fonts) do
    if font and not attached[font] then
      reaper.ImGui_Attach(ctx, font)
      attached[font] = true
    end
  end
end

--- Safely pushes a font onto the ImGui font stack.
--- Looks up the font size from Theme._font_sizes (populated by create_fonts).
--- Falls back to 2-arg call for older ReaImGui versions.
--- @param ctx userdata  ImGui context
--- @param font userdata  Font from Theme.create_fonts()
--- @param size number|nil  Font size override (auto-detected from registry if nil)
--- @return boolean  true if push succeeded (caller must pop with Theme.pop_font)
function Theme.push_font(ctx, font, size)
  if not font then return false end
  local sz = size or (Theme._font_sizes and Theme._font_sizes[font]) or Theme.font_sizes.default
  local ok = pcall(reaper.ImGui_PushFont, ctx, font, sz)
  if not ok then
    ok = pcall(reaper.ImGui_PushFont, ctx, font)
  end
  return ok
end

--- Conditionally pops a font from the ImGui font stack.
--- Only pops if the corresponding push_font returned true.
--- @param ctx userdata  ImGui context
--- @param pushed boolean  Return value from Theme.push_font()
function Theme.pop_font(ctx, pushed)
  if pushed then
    pcall(reaper.ImGui_PopFont, ctx)
  end
end

-------------------------------------------------------------------------------
-- 10. ICON PRIMITIVES
-------------------------------------------------------------------------------
--- Vector icon drawing functions for use with DrawList.
--- All icons share the same signature: function(dl, cx, cy, half_size, color)
---   dl        = ImGui DrawList (from GetWindowDrawList)
---   cx, cy    = center position of the icon
---   half_size = half the icon's bounding box (controls visual size)
---   color     = 0xRRGGBBAA color value
---
--- Usage:  Theme.icons.play(dl, cx, cy, 6, 0xFFFFFFFF)

Theme.icons = {}

--- ▶ Play triangle (right-pointing).
--- Use for: play/resume buttons, "active" indicators.
function Theme.icons.play(dl, cx, cy, hs, col)
  local ox = math.floor(cx)
  local oy = math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.5), oy - math.floor(hs),
    ox + math.floor(hs),       oy,
    ox - math.floor(hs * 0.5), oy + math.floor(hs), col)
end

--- ⏸ Pause bars (two vertical bars).
--- Use for: pause/suspend buttons.
function Theme.icons.pause(dl, cx, cy, hs, col)
  local bw = math.max(1, math.floor(hs * 0.35))
  local gap = math.floor(hs * 0.25)
  local ox, oy = math.floor(cx), math.floor(cy)
  local h = math.floor(hs)
  reaper.ImGui_DrawList_AddRectFilled(dl, ox - gap - bw, oy - h, ox - gap, oy + h, col)
  reaper.ImGui_DrawList_AddRectFilled(dl, ox + gap, oy - h, ox + gap + bw, oy + h, col)
end

--- ✕ Close / X mark (two crossed lines).
--- Use for: close, delete, remove buttons.
function Theme.icons.close(dl, cx, cy, hs, col)
  local th = math.max(1.5, hs * 0.3)
  local s = math.floor(hs * 0.8)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddLine(dl, ox - s, oy - s, ox + s, oy + s, col, th)
  reaper.ImGui_DrawList_AddLine(dl, ox + s, oy - s, ox - s, oy + s, col, th)
end

--- ＋ Plus / add (crossed lines, horizontal + vertical).
--- Use for: add, create, new buttons.
function Theme.icons.plus(dl, cx, cy, hs, col)
  local th = math.max(1.5, hs * 0.35)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddLine(dl, ox - hs, oy, ox + hs, oy, col, th)
  reaper.ImGui_DrawList_AddLine(dl, ox, oy - hs, ox, oy + hs, col, th)
end

--- ⓘ Info circle (circle outline with dot and stem).
--- Use for: info buttons, help/about triggers.
function Theme.icons.info(dl, cx, cy, hs, col)
  local s = hs / 10.0
  local stroke_w = math.max(1.0, 1.6 * s)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, hs, col, 0, stroke_w)
  local dot_r = math.max(0.8, 1.2 * s)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy - 4.2 * s, dot_r, col)
  local stem_hw = math.max(0.6, 1.0 * s)
  local stem_top = cy - 0.5 * s
  local stem_bot = cy + 4.5 * s
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - stem_hw, stem_top, cx + stem_hw, stem_bot, col, stem_hw)
end

--- ▾ Triangle down (downward-pointing).
--- Use for: dropdown indicators, expand/collapse, sort direction.
function Theme.icons.tri_down(dl, cx, cy, hs, col)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.7), oy - math.floor(hs * 0.4),
    ox + math.floor(hs * 0.7), oy - math.floor(hs * 0.4),
    ox, oy + math.floor(hs * 0.6), col)
end

--- ▴ Triangle up (upward-pointing).
--- Use for: collapse indicators, sort direction.
function Theme.icons.tri_up(dl, cx, cy, hs, col)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.7), oy + math.floor(hs * 0.4),
    ox + math.floor(hs * 0.7), oy + math.floor(hs * 0.4),
    ox, oy - math.floor(hs * 0.6), col)
end

-------------------------------------------------------------------------------
-- 11. WIDGET COMPONENTS
-------------------------------------------------------------------------------
--- Reusable UI components that enforce the design system automatically.
--- All widgets use ctx as the first argument (matching ImGui convention),
--- pull colors from the palette, and dimensions from Theme.layout.
--- Optional overrides are passed via an opts table as the last argument.

-- Palette accessor for widgets: delegates to Theme.get_palette().
local function _get_palette()
  return Theme.get_palette()
end

--- Low-level: vertically centers the next item within a row of a given height.
--- For standard alignment, prefer Theme.align(ctx, row_h, item_h) instead.
--- This function is retained for truly custom DrawList positioning where
--- you control the cursor entirely and need explicit ref_y tracking.
---
--- When placing multiple items on the same line (via SameLine), always pass
--- `ref_y` — the cursor Y saved **before** the first item — to every call.
--- Without `ref_y`, each call reads the current cursor Y, which already
--- includes the previous call's offset, causing elements to drift downward.
---
--- @param ctx    userdata     ImGui context
--- @param item_h number       Height of the item to center (e.g. font size, icon size)
--- @param row_h  number       Height of the containing row (e.g. Theme.layout.row_h)
--- @param ref_y  number|nil   Absolute row-start Y — pass this on SameLine rows
function Theme.vcenter(ctx, item_h, row_h, ref_y)
  if row_h and item_h < row_h then
    local base_y = ref_y or reaper.ImGui_GetCursorPosY(ctx)
    reaper.ImGui_SetCursorPosY(ctx, base_y + math.floor((row_h - item_h) * 0.5))
  end
end

--- Right-aligns the next item within the available content region.
--- Call before rendering the item. Sets the cursor X position so the
--- item's right edge aligns with the content region boundary.
---
--- @param ctx userdata  ImGui context
--- @param item_w number  Width of the item to right-align
--- @param margin number|nil  Optional right margin (default: 0)
function Theme.right_align(ctx, item_w, margin)
  margin = margin or 0
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  reaper.ImGui_SetCursorPosX(ctx, cx + avail - item_w - margin)
end

--- Horizontally centers the next item within the available content region.
--- Call before rendering the item. Sets the cursor X position so the
--- item appears centered.
---
--- @param ctx userdata  ImGui context
--- @param item_w number  Width of the item to center
function Theme.hcenter(ctx, item_w)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  reaper.ImGui_SetCursorPosX(ctx, cx + math.floor((avail - item_w) * 0.5))
end

--- Vertically aligns the next item within the current line.
---
--- THE SINGLE ALIGNMENT FUNCTION — call before every item on a row.
---
--- Three calling patterns:
---
---   Theme.align(ctx)                 Standard row: aligns text baseline to
---                                     framed widgets via AlignTextToFramePadding.
---
---   Theme.align(ctx, row_h)          Table/toolbar: centers a frame-height item
---                                     within an explicit row height.
---
---   Theme.align(ctx, row_h, item_h)  Custom item: centers item_h within row_h.
---                                     If row_h is nil, uses GetFrameHeight() as
---                                     the implicit row — this handles btn_sm
---                                     widgets on a default-height SameLine row.
---
--- When row_h is provided (table context), the function automatically adjusts
--- for CellPadding.y: the content area inside a table cell is
--- row_h - 2 * CellPadding.y. Without this, items are pushed too far down.
---
--- On SameLine rows, ImGui resets cursor Y to the line start, so
--- GetCursorPosY() always returns the correct base. No ref_y needed.
---
--- @param ctx    userdata     ImGui context
--- @param row_h  number|nil   Row height (nil = GetFrameHeight for centering,
---                             or baseline alignment when item_h is also nil)
--- @param item_h number|nil   Height of the next item (nil = frame height)
function Theme.align(ctx, row_h, item_h)
  if not row_h and not item_h then
    -- Standard row: align text baseline to framed widgets
    reaper.ImGui_AlignTextToFramePadding(ctx)
    return
  end
  -- Resolve row height: explicit or implicit from current frame height
  local explicit_row = (row_h ~= nil)
  row_h = row_h or reaper.ImGui_GetFrameHeight(ctx)
  -- In table cells, CellPadding.y is added above and below the content area.
  -- The cursor is already positioned after top padding, so the available
  -- content height is row_h minus 2 * CellPadding.y.
  -- CellPadding.y is pushed as Theme.layout.xs in Theme.push().
  if explicit_row then
    row_h = row_h - Theme.layout.xs * 2
  end
  -- Resolve item height: explicit or frame height
  item_h = item_h or reaper.ImGui_GetFrameHeight(ctx)
  if item_h < row_h then
    local cur_y = reaper.ImGui_GetCursorPosY(ctx)
    reaper.ImGui_SetCursorPosY(ctx, cur_y + math.floor((row_h - item_h) * 0.5))
  end
end

--- Renders an invisible button with a DrawList vector icon overlay.
--- The icon highlights on hover. Optionally shows a tooltip.
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique ImGui ID for the button (e.g. "delete_btn")
--- @param icon_fn function  Icon drawing function from Theme.icons.*
--- @param opts table|nil  Optional overrides:
---   opts.preset    (table)   Icon preset   (default: Theme.layout.icon_md)
---   opts.w         (number)  Button width override
---   opts.h         (number)  Button height override
---   opts.icon_size (number)  Icon size override
---   opts.color     (number)  Icon color    (default: palette.text_dim)
---   opts.tooltip   (string)  Hover tooltip text
--- @return boolean  true if the button was clicked
function Theme.icon_btn(ctx, id, icon_fn, opts)
  opts = opts or {}
  local L = Theme.layout
  local P = _get_palette()
  local preset = opts.preset or L.icon_md
  local icon_sz = opts.icon_size or preset.size
  local btn_w = opts.w or (icon_sz + preset.pad * 2)
  local btn_h = opts.h or btn_w
  local pressed = reaper.ImGui_InvisibleButton(ctx, id, btn_w, btn_h)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx = (rx + rx2) * 0.5
  local cy = (ry + ry2) * 0.5
  local hs = icon_sz * 0.5
  local hover = reaper.ImGui_IsItemHovered(ctx)
  local base_col = opts.color or P.text_dim
  local draw_col = hover and lighten(base_col, 0.25) or base_col
  icon_fn(dl, cx, cy, hs, draw_col)
  if opts.tooltip and hover then
    Theme.tooltip(ctx, opts.tooltip)
  end
  return pressed
end

--- Renders a colored button with a DrawList vector icon overlay.
--- Unlike icon_btn, this renders a visible button background.
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique ImGui ID (the "##" prefix is added automatically)
--- @param icon_fn function  Icon drawing function from Theme.icons.*
--- @param opts table|nil  Optional overrides:
---   opts.preset    (table)   Icon preset   (default: Theme.layout.icon_md)
---   opts.w         (number)  Button width override
---   opts.h         (number)  Button height override
---   opts.icon_size (number)  Icon size override
---   opts.icon_color (number) Icon color    (default: palette.text)
---   opts.bg        (number)  Button bg     (default: palette.accent_d)
---   opts.bg_hover  (number)  Hover bg      (default: palette.accent_h)
---   opts.bg_active (number)  Active bg     (default: palette.accent)
---   opts.tooltip   (string)  Hover tooltip text
--- @return boolean  true if the button was clicked
function Theme.icon_btn_colored(ctx, id, icon_fn, opts)
  opts = opts or {}
  local L = Theme.layout
  local P = _get_palette()
  local preset = opts.preset or L.icon_md
  local icon_sz = opts.icon_size or preset.size
  local btn_w = opts.w or (icon_sz + preset.pad * 2)
  local btn_h = opts.h or btn_w
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        opts.bg        or P.accent_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), opts.bg_hover  or P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  opts.bg_active or P.accent)
  local pressed = reaper.ImGui_Button(ctx, "##" .. id, btn_w, btn_h)
  reaper.ImGui_PopStyleColor(ctx, 3)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx = (rx + rx2) * 0.5
  local cy = (ry + ry2) * 0.5
  local hs = icon_sz * 0.5
  icon_fn(dl, cx, cy, hs, opts.icon_color or P.text)
  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end
  return pressed
end

--- Renders a tooltip with automatic text wrapping.
--- Uses consistent padding from layout tokens.
---
--- @param ctx userdata  ImGui context
--- @param text string  Tooltip text content
--- @param max_w number|nil  Max wrap width (default: Theme.layout.tooltip_wrap)
function Theme.tooltip(ctx, text, max_w)
  max_w = max_w or Theme.layout.tooltip_wrap
  if reaper.ImGui_BeginTooltip(ctx) then
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + max_w)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_EndTooltip(ctx)
  end
end

--- Renders a labeled section divider with optional info tooltip.
--- Adds consistent spacing above and below from layout tokens.
---
--- @param ctx userdata  ImGui context
--- @param label string  Section title text
--- @param opts table|nil  Optional overrides:
---   opts.color       (number)  Label text color (default: palette.text_dim)
---   opts.tooltip     (string)  Info icon + tooltip text shown next to label
---   opts.id          (string)  Unique ID for the info button (default: "##info_" .. label)
---   opts.preset      (table)   Icon preset (default: Theme.layout.icon_md)
---   opts.icon_size   (number)  Icon size override
---   opts.icon_color  (number)  Icon color override (default: palette.text_dim)
---   opts.w           (number)  Button width override
---   opts.h           (number)  Button height override
function Theme.section_divider(ctx, label, opts)
  opts = opts or {}
  local P = _get_palette()
  local col = opts.color or P.text_dim
  local preset = opts.preset or Theme.layout.icon_md
  local icon_sz = opts.icon_size or preset.size
  local btn_w = opts.w or (icon_sz + preset.pad * 2)
  local btn_h = opts.h or btn_w

  reaper.ImGui_Spacing(ctx)
  Theme.align(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  if opts.tooltip then
    reaper.ImGui_SameLine(ctx, 0, Theme.layout.section_gap)
    Theme.align(ctx, nil, btn_h)
    local btn_id = opts.id and ("info_" .. opts.id) or ("##info_" .. label)
    Theme.icon_btn(ctx, btn_id, Theme.icons.info, {
      preset = preset,
      icon_size = opts.icon_size,
      w = opts.w,
      h = opts.h,
      color = opts.icon_color or P.text_dim,
      tooltip = opts.tooltip,
    })
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), with_alpha(col, 0.60))
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
end

--- Renders a standardized collapsing header widget.
--- Encapsulates ReaImGui's argument order and default flags to prevent
--- argument-misalignment bugs (such as accidental close buttons).
---
--- @param ctx userdata  ImGui context
--- @param label string  Section header label text
--- @param opts table|nil  Optional configuration:
---   opts.default_open (boolean) Whether the header starts expanded (default: false)
---   opts.flags        (integer) Additional ImGui TreeNodeFlags
--- @return boolean  true if the section is expanded and its content should be rendered
function Theme.collapsing_header(ctx, label, opts)
  opts = opts or {}
  local flags = opts.flags or reaper.ImGui_TreeNodeFlags_None()
  if opts.default_open then
    flags = flags | reaper.ImGui_TreeNodeFlags_DefaultOpen()
  end
  return reaper.ImGui_CollapsingHeader(ctx, label, nil, flags)
end

--- Pushes button preset styling (FramePadding and font) onto the stack.
--- Use for standard ImGui controls (sliders, inputs, combo boxes) that should
--- match a button preset tier (e.g. Theme.layout.btn_sm, Theme.layout.btn_lg).
---
--- @param ctx userdata        ImGui context
--- @param fonts table|nil      Font table from Theme.create_fonts()
--- @param preset table|string|nil Preset table or name (default: Theme.layout.btn_sm)
--- @return integer var_count, userdata|nil pushed_font
function Theme.push_button_preset(ctx, fonts, preset)
  if preset == "small" or preset == "sm" then preset = Theme.layout.btn_sm end
  if preset == "large" or preset == "lg" then preset = Theme.layout.btn_lg end
  if preset == "default" then preset = Theme.layout.btn_default end
  preset = preset or Theme.layout.btn_sm
  local var_count = 0
  if preset.pad_x or preset.pad_y then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
      preset.pad_x or Theme.layout.md,
      preset.pad_y or Theme.layout.sm)
    var_count = var_count + 1
  end
  local pushed_font = nil
  if fonts and preset.font and fonts[preset.font] then
    pushed_font = Theme.push_font(ctx, fonts[preset.font])
  end
  return var_count, pushed_font
end

--- Pops button preset styling from the stack.
---
--- @param ctx userdata         ImGui context
--- @param var_count integer    Number of style vars pushed
--- @param pushed_font userdata|nil Font returned by Theme.push_button_preset
function Theme.pop_button_preset(ctx, var_count, pushed_font)
  if pushed_font then
    Theme.pop_font(ctx, pushed_font)
  end
  if var_count and var_count > 0 then
    reaper.ImGui_PopStyleVar(ctx, var_count)
  end
end

--- Renders a compact or standard meter/progress bar with DrawList background,
--- fill color, rounding, and optional centered text overlay.
---
--- @param ctx userdata  ImGui context
--- @param fraction number  Normalized progress/value between 0.0 and 1.0
--- @param opts table|nil  Optional configuration:
---   opts.w            (number)  Bar width in pixels (default: available region width)
---   opts.h            (number)  Bar height in pixels (default: preset.h or Theme.layout.row_h - 4)
---   opts.preset       (table|string) Button preset (e.g. Theme.layout.btn_sm or "small")
---   opts.fonts        (table)   Font table from Theme.create_fonts() (for overlay text)
---   opts.fill_color   (number)  Fill color (default: palette.accent)
---   opts.bg_color     (number)  Background color (default: palette.card)
---   opts.border_color (number)  Border color (optional)
---   opts.rounding     (number)  Corner rounding (default: Theme.layout.rounding)
---   opts.overlay      (string)  Centered text overlay (e.g. "+3.5 dB" or "75%")
---   opts.text_color   (number)  Overlay text color (default: palette.text)
---   opts.tooltip      (string)  Tooltip text on hover
function Theme.progress_bar(ctx, fraction, opts)
  opts = opts or {}
  local P = _get_palette()
  local L = Theme.layout

  local preset = opts.preset
  if preset == "small" or preset == "sm" then preset = L.btn_sm end
  if preset == "large" or preset == "lg" then preset = L.btn_lg end

  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local w = opts.w or math.max(L.xxxl, avail_w)
  local default_h = (preset and preset.h) or (L.row_h - L.sm)
  local h = opts.h or default_h
  local rounding = opts.rounding or L.rounding
  local fill_col = opts.fill_color or opts.fg or P.accent
  local bg_col = opts.bg_color or opts.bg or P.card
  local text_col = opts.text_color or P.text
  local overlay = opts.overlay or opts.text

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)

  -- Background
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg_col, rounding)

  -- Filled bar
  local frac = fraction or 0.0
  if frac ~= frac then frac = 0.0 end
  local clamped = math.max(0.0, math.min(1.0, frac))
  if clamped > 0.001 then
    local fw = math.max(rounding * 2, math.floor(w * clamped))
    if fw > w then fw = w end
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + fw, y + h, fill_col, rounding)
  end

  -- Border
  if opts.border_color then
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, opts.border_color, rounding)
  end

  -- Centered text overlay
  if overlay and overlay ~= "" then
    local pushed_font = nil
    if opts.fonts and preset and preset.font and opts.fonts[preset.font] then
      pushed_font = Theme.push_font(ctx, opts.fonts[preset.font])
    end
    local tw, th = reaper.ImGui_CalcTextSize(ctx, overlay)
    local tx = x + math.floor((w - tw) * 0.5)
    local ty = y + math.floor((h - th) * 0.5)
    reaper.ImGui_DrawList_AddText(dl, tx, ty, text_col, overlay)
    if pushed_font then
      Theme.pop_font(ctx, pushed_font)
    end
  end

  -- Advance layout cursor
  reaper.ImGui_Dummy(ctx, w, h)

  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end
end

--- Renders a toggle button derived from standard ImGui button styling.
--- Inherits parent theme padding, font, text centering, and rounding by default,
--- or follows a button preset (e.g. Theme.layout.btn_sm).
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique button ID (appended to label with ##)
--- @param label string  Button text label
--- @param is_active boolean  Whether button is in active/secondary state
--- @param opts table|nil  Optional configuration:
---   opts.preset         (table|string) Button preset (e.g. Theme.layout.btn_sm or "small")
---   opts.fonts          (table)   Font table from Theme.create_fonts() (for preset font)
---   opts.w              (number)  Button width (default: 0 = auto from text + frame padding)
---   opts.h              (number)  Button height (default: 0 = auto from font + frame padding)
---   opts.rounding       (number)  Corner rounding override (default: inherits FrameRounding)
---   opts.pad_x          (number)  Horizontal padding override (default: preset or FramePadding)
---   opts.pad_y          (number)  Vertical padding override (default: preset or FramePadding)
---   opts.active_bg      (number)  Active background (default: palette.accent_d)
---   opts.active_hover   (number)  Active hovered background (default: palette.accent_h)
---   opts.active_active  (number)  Active pressed background (default: palette.accent)
---   opts.active_text    (number)  Active text color (default: palette.accent)
---   opts.inactive_bg    (number)  Inactive background (default: palette.card)
---   opts.inactive_hover (number)  Inactive hovered background (default: palette.panel)
---   opts.inactive_active(number)  Inactive pressed background (default: palette.accent_d)
---   opts.inactive_text  (number)  Inactive text color (default: palette.text_dim)
---   opts.tooltip        (string)  Hover tooltip text
--- @return boolean  true if the button was clicked
function Theme.toggle_button(ctx, id, label, is_active, opts)
  opts = opts or {}
  local P = _get_palette()
  local L = Theme.layout

  local preset = opts.preset
  if preset == "small" or preset == "sm" then preset = L.btn_sm end
  if preset == "large" or preset == "lg" then preset = L.btn_lg end

  local btn_w = opts.w or 0
  local btn_h = opts.h or 0

  local bg, bg_h, bg_a, text_col
  if is_active then
    bg       = opts.active_bg     or P.accent_d
    bg_h     = opts.active_hover  or P.accent_h
    bg_a     = opts.active_active or P.accent
    text_col = opts.active_text   or P.accent_l
  else
    bg       = opts.inactive_bg     or P.card
    bg_h     = opts.inactive_hover  or P.panel
    bg_a     = opts.inactive_active or P.accent_d
    text_col = opts.inactive_text   or P.text_dim
  end

  local pushed_vars = 0
  if opts.rounding then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), opts.rounding)
    pushed_vars = pushed_vars + 1
  end

  local px = opts.pad_x or (preset and preset.pad_x)
  local py = opts.pad_y or (preset and preset.pad_y)
  if px or py then
    px = px or Theme.layout.md
    py = py or Theme.layout.sm
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), px, py)
    pushed_vars = pushed_vars + 1
  end

  local pushed_font = nil
  if opts.fonts and preset and preset.font and opts.fonts[preset.font] then
    pushed_font = Theme.push_font(ctx, opts.fonts[preset.font])
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_a)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          text_col)

  local btn_id = id or label or "toggle_btn"
  local btn_label = string.format("%s##%s", label or "", btn_id)
  local pressed = reaper.ImGui_Button(ctx, btn_label, btn_w, btn_h)

  reaper.ImGui_PopStyleColor(ctx, 4)
  if pushed_font then
    Theme.pop_font(ctx, pushed_font)
  end
  if pushed_vars > 0 then
    reaper.ImGui_PopStyleVar(ctx, pushed_vars)
  end

  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  return pressed
end

--- Alias for toggle_button.
Theme.badge_button = Theme.toggle_button

--- Renders a status badge derived from button styling with centered text and frame padding.
---
--- @param ctx userdata  ImGui context
--- @param label string  Badge text label
--- @param opts table|nil  Optional configuration:
---   opts.preset         (table|string) Button preset (e.g. Theme.layout.btn_sm or "small")
---   opts.fonts          (table)   Font table from Theme.create_fonts() (for preset font)
---   opts.color          (number)  Semantic base color (auto-derives 70% lightened text & 33% bg)
---   opts.text_color     (number)  Explicit text color override (default: 70% lightened color or palette.accent_l)
---   opts.bg             (number)  Explicit background color override (default: 33% alpha of color)
---   opts.w              (number)  Badge width (default: 0 = auto from text + frame padding)
---   opts.h              (number)  Badge height (default: 0 = auto from font + frame padding)
---   opts.rounding       (number)  Corner rounding override (default: inherits FrameRounding)
---   opts.pad_x          (number)  Horizontal padding override (default: preset or FramePadding)
---   opts.pad_y          (number)  Vertical padding override (default: preset or FramePadding)
---   opts.interactive    (boolean) Whether badge is clickable (default: false)
---   opts.id             (string)  Unique ID if interactive
---   opts.tooltip        (string)  Hover tooltip text
--- @return boolean  true if the badge was clicked (when interactive = true)
function Theme.badge(ctx, label, opts)
  opts = opts or {}
  local P = _get_palette()
  local L = Theme.layout

  local preset = opts.preset
  if preset == "small" or preset == "sm" then preset = L.btn_sm end
  if preset == "large" or preset == "lg" then preset = L.btn_lg end

  local base_color = opts.color or P.accent
  local text_col   = opts.text_color or (opts.color and lighten(opts.color, 0.70) or P.accent_l)
  local bg         = opts.bg or with_alpha(base_color, 0.20)
  local bg_h       = opts.bg_hover or with_alpha(base_color, 0.40)
  local bg_a       = opts.bg_active or base_color

  local btn_w = opts.w or 0
  local btn_h = opts.h or 0

  local pushed_vars = 0
  if opts.rounding then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), opts.rounding)
    pushed_vars = pushed_vars + 1
  end
  local px = opts.pad_x or (preset and preset.pad_x)
  local py = opts.pad_y or (preset and preset.pad_y)
  if px or py then
    px = px or Theme.layout.md
    py = py or Theme.layout.xs
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), px, py)
    pushed_vars = pushed_vars + 1
  end

  local pushed_font = nil
  if opts.fonts and preset and preset.font and opts.fonts[preset.font] then
    pushed_font = Theme.push_font(ctx, opts.fonts[preset.font])
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), opts.interactive and bg_h or bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  opts.interactive and bg_a or bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          text_col)

  local badge_id = opts.id and ("##badge_" .. opts.id) or ("##badge_" .. label)
  local btn_label = label .. badge_id

  local pressed = reaper.ImGui_Button(ctx, btn_label, btn_w, btn_h)

  reaper.ImGui_PopStyleColor(ctx, 4)
  if pushed_font then
    Theme.pop_font(ctx, pushed_font)
  end
  if pushed_vars > 0 then
    reaper.ImGui_PopStyleVar(ctx, pushed_vars)
  end

  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  return opts.interactive and pressed or false
end

-- File-level helper for Theme.combo to eliminate per-frame closure allocations
local function _get_combo_item_label(item, idx, custom_fn)
  if custom_fn then
    return custom_fn(item, idx)
  end
  if type(item) == "table" then
    return item.name or item.label or item.title or tostring(item)
  end
  return tostring(item)
end

--- Renders a standardized combo box wrapping ImGui_BeginCombo.
--- Handles label resolution, item iteration, and selection state.
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique combo ID (e.g. "##shared_fx")
--- @param items table  Array of items (strings or tables)
--- @param selected_idx number  1-based index of the currently selected item (0 if none)
--- @param opts table|nil  Optional configuration:
---   opts.w           (number)   Combo width override (default: full available width)
---   opts.placeholder (string)   Placeholder text when selected_idx <= 0 (default: "-- Select --")
---   opts.get_label   (function) Custom function(item, idx) -> string
---   opts.disabled    (boolean)  Whether the combo is disabled
---   opts.tooltip     (string)   Hover tooltip text
--- @return number new_idx, boolean changed  The selected 1-based index and whether it changed
function Theme.combo(ctx, id, items, selected_idx, opts)
  opts = opts or {}
  items = items or {}
  selected_idx = selected_idx or 0

  if opts.disabled then
    reaper.ImGui_BeginDisabled(ctx)
  end

  if opts.w then
    reaper.ImGui_SetNextItemWidth(ctx, opts.w)
  end

  local preview = opts.placeholder or "-- Select --"
  if selected_idx > 0 and selected_idx <= #items then
    preview = _get_combo_item_label(items[selected_idx], selected_idx, opts.get_label)
  end

  local new_idx = selected_idx
  local changed = false

  if reaper.ImGui_BeginCombo(ctx, id, preview) then
    for i, item in ipairs(items) do
      local lbl = _get_combo_item_label(item, i, opts.get_label) .. "##item_" .. i
      local is_sel = (selected_idx == i)
      if reaper.ImGui_Selectable(ctx, lbl, is_sel) then
        new_idx = i
        changed = true
      end
      if is_sel then
        reaper.ImGui_SetItemDefaultFocus(ctx)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  if opts.disabled then
    reaper.ImGui_EndDisabled(ctx)
  end

  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  return new_idx, changed
end

-- Helpers for Theme.multi_combo
local function _is_item_selected(selected, item, idx, get_id_fn)
  if not selected then return false end
  local t = type(selected)
  if t == "function" then
    return selected(item, idx) == true
  end
  if t == "table" then
    if selected[idx] == true then return true end
    if get_id_fn then
      local id_val = get_id_fn(item, idx)
      if id_val ~= nil and selected[id_val] == true then return true end
    end
    if type(item) == "table" then
      if item.guid and selected[item.guid] == true then return true end
      if item.id and selected[item.id] == true then return true end
      if item.checked == true then return true end
    end
    for _, v in ipairs(selected) do
      if v == idx then return true end
      if type(item) == "table" and (v == item.guid or v == item.id or v == item) then
        return true
      end
    end
  end
  return false
end

local function _count_selected(items, selected, get_id_fn)
  local count = 0
  for i, item in ipairs(items) do
    if _is_item_selected(selected, item, i, get_id_fn) then
      count = count + 1
    end
  end
  return count
end

--- Renders a standardized, compact multi-select combo box.
--- Supports full-row clicking, hover highlights, and compact density.
--- Does not close the popup on item selection unless opts.close_on_select is true.
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique combo ID (e.g. "##add_tracks")
--- @param items table  Array of items (strings or tables)
--- @param selected table|function|nil  Selection state (index map, array of indices/GUIDs, or predicate)
--- @param opts table|nil  Optional configuration:
---   opts.w               (number)   Combo width override (default: full available width)
---   opts.placeholder     (string)   Placeholder text when no items selected (default: "-- Select --")
---   opts.preview         (string|function) Preview text override or custom function(selected_count, total_count) -> string
---   opts.show_count      (boolean)  If true, formats preview as "N Selected" / "All Selected"
---   opts.get_label       (function) Custom function(item, idx) -> string
---   opts.get_id          (function) Custom function(item, idx) -> id
---   opts.disabled        (boolean)  Whether the combo is disabled
---   opts.tooltip         (string)   Hover tooltip text
---   opts.compact         (boolean)  Use tight vertical padding inside popup (default: true)
---   opts.close_on_select (boolean)  Close popup after selecting an item (default: false)
---   opts.check_mark      (string)   Prefix for selected items (default: "\xe2\x9c\x93 ")
--- @return number|nil toggled_idx  1-based index of the toggled item, or nil if no interaction
--- @return boolean|nil is_now_selected  New boolean selection state of the toggled item
--- @return boolean changed  Whether a selection was modified this frame
function Theme.multi_combo(ctx, id, items, selected, opts)
  opts = opts or {}
  items = items or {}

  if opts.disabled then
    reaper.ImGui_BeginDisabled(ctx)
  end

  if opts.w then
    reaper.ImGui_SetNextItemWidth(ctx, opts.w)
  end

  local L = Theme.layout
  local total_count = #items
  local sel_count = _count_selected(items, selected, opts.get_id)

  local preview = opts.placeholder or "-- Select --"
  if opts.preview then
    if type(opts.preview) == "function" then
      preview = opts.preview(sel_count, total_count)
    else
      preview = tostring(opts.preview)
    end
  elseif opts.show_count and sel_count > 0 then
    if sel_count == total_count and total_count > 1 then
      preview = "All (" .. total_count .. ") Selected"
    else
      preview = sel_count .. " Selected"
    end
  end

  local toggled_idx = nil
  local is_now_selected = nil
  local changed = false

  if reaper.ImGui_BeginCombo(ctx, id, preview) then
    local pushed_vars = 0
    if opts.compact ~= false then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), L.md, L.xs)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), L.sm, L.xs)
      pushed_vars = 2
    end

    local sel_flags = opts.close_on_select and reaper.ImGui_SelectableFlags_None()
                      or (reaper.ImGui_SelectableFlags_NoAutoClosePopups and reaper.ImGui_SelectableFlags_NoAutoClosePopups() or reaper.ImGui_SelectableFlags_None())
    local check_prefix = opts.check_mark or "\xe2\x9c\x93 "
    local blank_prefix = "   "

    for i, item in ipairs(items) do
      local is_sel = _is_item_selected(selected, item, i, opts.get_id)
      local prefix = is_sel and check_prefix or blank_prefix
      local label_text = _get_combo_item_label(item, i, opts.get_label)
      local row_label = prefix .. label_text .. "##mitem_" .. i

      if reaper.ImGui_Selectable(ctx, row_label, is_sel, sel_flags) then
        toggled_idx = i
        is_now_selected = not is_sel
        changed = true
      end
    end

    if pushed_vars > 0 then
      reaper.ImGui_PopStyleVar(ctx, pushed_vars)
    end

    reaper.ImGui_EndCombo(ctx)
  end

  if opts.disabled then
    reaper.ImGui_EndDisabled(ctx)
  end

  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  return toggled_idx, is_now_selected, changed
end

--- Centers the next ImGui window on the active window (or viewport if none is active).
--- Call immediately before ImGui_Begin or ImGui_BeginPopupModal.
---
--- @param ctx userdata  ImGui context
--- @param w number|nil  Window width in pixels (optional)
--- @param h number|nil  Window height in pixels (optional)
function Theme.center_next_window(ctx, w, h)
  local cx, cy
  local ok_p, wx, wy = pcall(reaper.ImGui_GetWindowPos, ctx)
  local ok_s, ww, wh = pcall(reaper.ImGui_GetWindowSize, ctx)
  if ok_p and ok_s and ww and wh and ww > 0 and wh > 0 then
    cx = wx + ww * 0.5
    cy = wy + wh * 0.5
  else
    local vp = reaper.ImGui_GetMainViewport(ctx)
    local vp_x, vp_y = reaper.ImGui_Viewport_GetPos(vp)
    local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(vp)
    cx = vp_x + vp_w * 0.5
    cy = vp_y + vp_h * 0.5
  end

  reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  if w and h and w > 0 and h > 0 then
    reaper.ImGui_SetNextWindowSize(ctx, w, h, reaper.ImGui_Cond_Appearing())
  end
end

--- Renders the Fancy Scripts brand icon (logo) using DrawList vectors.
--- Draws a rounded card with the signature bezier curve and colored dots.
---
--- @param ctx userdata  ImGui context
--- @param size number|nil  Icon bounding box size in pixels (default: Theme.layout.row_h)
--- @param target_h number|nil  Vertical space to consume (for alignment, default: size)
function Theme.brand_icon(ctx, size, target_h)
  size = size or Theme.layout.row_h
  target_h = target_h or size
  local P = _get_palette()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local y_off = math.max(0, (target_h - size) * 0.5)
  local s = size / 240.0
  local dy = y + y_off
  local bx1, by1 = x + 5.0 * s, dy + 5.0 * s
  local bx2, by2 = x + 235.0 * s, dy + 235.0 * s
  local r_bg     = 50.0 * s
  local stroke_w = math.max(1.0, 10.0 * s)
  reaper.ImGui_DrawList_AddRectFilled(dl, bx1, by1, bx2, by2, P.card, r_bg)
  reaper.ImGui_DrawList_AddRect(dl, bx1, by1, bx2, by2, P.sep, r_bg, 0, stroke_w)
  local p1_x, p1_y = x + 79.0 * s, dy + 139.0 * s
  local c1_x, c1_y = x + 79.0 * s, dy + 101.0 * s
  local c2_x, c2_y = x + 161.0 * s, dy + 139.0 * s
  local p2_x, p2_y = x + 161.0 * s, dy + 101.0 * s
  local curve_w    = math.max(1.2, 15.0 * s)
  reaper.ImGui_DrawList_AddBezierCubic(dl, p1_x, p1_y, c1_x, c1_y, c2_x, c2_y, p2_x, p2_y, P.accent, curve_w)
  reaper.ImGui_DrawList_AddCircleFilled(dl, x + 79.0 * s, dy + 169.0 * s, 30.0 * s, P.green)
  reaper.ImGui_DrawList_AddCircleFilled(dl, x + 161.0 * s, dy + 71.0 * s, 30.0 * s, P.yellow)
  reaper.ImGui_Dummy(ctx, size, target_h)
end

-------------------------------------------------------------------------------
-- 12. SETTINGS UI WIDGET
-------------------------------------------------------------------------------

local SETTINGS_LABELS = { "Fancy Dark", "Match Theme" }
local SETTINGS_VALUES = { Theme.MODE_FANCY, Theme.MODE_MATCH }

--- Calculates the reactive width required for a combo box to display its options
--- without truncation, based on the current font metrics and ImGui frame padding.
--- @param ctx userdata      ImGui context
--- @param items table       Array of option label strings
--- @param extra_pad number|nil Optional extra padding (default: 0)
--- @return number           Exact required width in pixels
function Theme.calc_combo_width(ctx, items, extra_pad)
  local max_w = 0
  for _, item in ipairs(items) do
    local w = reaper.ImGui_CalcTextSize(ctx, tostring(item))
    if w > max_w then max_w = w end
  end
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = Theme.layout.md * 2 + (extra_pad or 0)
  return math.ceil(max_w + frame_h + pad_x)
end

--- Renders a theme mode combo box for use in any script's settings panel.
--- Dynamically calculates required width from font metrics and option labels.
--- Reads and writes the global ExtState automatically.
--- Invalidates the palette cache when the mode changes.
--- @param ctx userdata  ImGui context
--- @param opts table|nil  Optional overrides:
---   opts.w     (number) Width override (default: dynamically measured via calc_combo_width)
---   opts.label (string) Visible label (default: nil, renders without trailing label)
---   opts.align (string) "right" to right-align automatically before rendering
---   opts.margin (number) Right margin when align = "right" (default: 0)
--- @return boolean changed  true if the mode was changed (caller may want to rebuild palette)
--- @return number  w        The resolved reactive width of the combo box in pixels
function Theme.settings_widget(ctx, opts)
  opts = opts or {}
  local mode = Theme.get_mode()
  local current = 1
  for i, v in ipairs(SETTINGS_VALUES) do
    if v == mode then current = i; break end
  end

  local auto_w = Theme.calc_combo_width(ctx, SETTINGS_LABELS)
  local w = opts.w or auto_w

  if opts.align == "right" then
    Theme.right_align(ctx, w, opts.margin)
  end

  local changed = false
  local combo_label = opts.label or "##theme_mode"
  reaper.ImGui_SetNextItemWidth(ctx, w)
  if reaper.ImGui_BeginCombo(ctx, combo_label, SETTINGS_LABELS[current]) then
    for i, label in ipairs(SETTINGS_LABELS) do
      local selected = (i == current)
      if reaper.ImGui_Selectable(ctx, label, selected) then
        if not selected then
          Theme.set_mode(SETTINGS_VALUES[i])
          Theme.invalidate_palette()
          changed = true
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return changed, w
end

-------------------------------------------------------------------------------
-- 13. WINDOW HEADER WIDGET
-------------------------------------------------------------------------------

--- Renders a standardized window header bar matching the Parameter Link layout pattern.
--- Uses ReaImGui's native AlignTextToFramePadding() for pixel-perfect vertical alignment
--- across brand icon, signature "FANCY" prefix, title, subtitle, and right controls.
---
--- @param ctx userdata  ImGui context
--- @param opts table|nil  Header configuration:
---   opts.title          (string)      Window title text (required)
---   opts.prefix         (string|nil)  Brand prefix text (default: "FANCY")
---   opts.fancy_prefix   (boolean|nil) Whether to show "FANCY" prefix (default: true)
---   opts.prefix_color   (number|nil)  Prefix text color (default: palette.yellow)
---   opts.subtitle       (string|nil)  Secondary subtitle text (optional)
---   opts.fonts          (table|nil)   Font table from Theme.create_fonts() (optional)
---   opts.font_header    (userdata|nil) Title font override (default: opts.fonts.large_bold or fonts.header)
---   opts.font_subtitle  (userdata|nil) Subtitle font override (default: opts.fonts.default)
---   opts.title_color    (number|nil)  Title text color (default: palette.text)
---   opts.subtitle_color (number|nil)  Subtitle text color (default: palette.text_dim)
---   opts.icon_fn        (function|false|nil) Custom icon function (ctx, sz, target_h).
---                                     Set false to omit icon; defaults to Theme.brand_icon.
---   opts.brand_size     (number|nil)  Brand icon size in pixels (default: 24)
---   opts.show_settings  (boolean|nil) Whether to show the theme mode dropdown (default: false)
---   opts.show_close     (boolean|nil) Whether to show the close button (default: false)
---   opts.close_id       (string|nil)  Close button ID (default: "win_hdr_close")
---   opts.close_tooltip  (string|nil)  Close button tooltip (default: "Close (Esc)")
---   opts.right_widgets  (function|nil) Callback `function(ctx, hdr_h)` for custom controls
---   opts.right_width    (number|nil)  Extra width allocated for right-aligned items
---   opts.show_separator (boolean|nil) Whether to render separator line below header (default: true)
---   opts.height         (number|nil)  Row height override (default: Theme.layout.row_h)
--- @return boolean open  Returns true if the window should stay open (false if close was clicked)
function Theme.header(ctx, opts)
  opts = opts or {}
  local P = _get_palette()
  local L = Theme.layout

  local brand_sz = opts.brand_size or 24
  local close_btn_sz = L.icon_md.size + L.icon_md.pad * 2
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local hdr_h = opts.height or math.max(L.row_h, brand_sz, close_btn_sz, frame_h)

  -- 1. Brand icon (centers itself in target_h and establishes the line height)
  local has_icon = (opts.icon_fn ~= false)
  if has_icon then
    if type(opts.icon_fn) == "function" then
      opts.icon_fn(ctx, brand_sz, hdr_h)
    else
      Theme.brand_icon(ctx, brand_sz, hdr_h)
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
  end

  -- 2. Signature "FANCY" brand prefix (yellow bold text)
  if opts.fancy_prefix ~= false then
    local font_bold = opts.font_brand or (opts.fonts and (opts.fonts.medium_bold or opts.fonts.large_bold or opts.fonts.default_bold))
    local pushed_b = Theme.push_font(ctx, font_bold)
    Theme.align(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), opts.prefix_color or P.yellow)
    reaper.ImGui_Text(ctx, opts.prefix or "FANCY")
    reaper.ImGui_PopStyleColor(ctx, 1)
    Theme.pop_font(ctx, pushed_b)
    reaper.ImGui_SameLine(ctx, 0, opts.prefix_gap or L.sm)
  end

  -- 3. Title (white text aligned to frame padding)
  if opts.title then
    local font_title = opts.font_header or (opts.fonts and (opts.fonts.medium or opts.fonts.default_bold or opts.fonts.large))
    local pushed_title = Theme.push_font(ctx, font_title)
    Theme.align(ctx)
    if opts.title_color then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), opts.title_color)
    end
    reaper.ImGui_Text(ctx, opts.title)
    if opts.title_color then
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    Theme.pop_font(ctx, pushed_title)
  end

  -- 4. Subtitle (dim text aligned to frame padding)
  if opts.subtitle then
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    Theme.align(ctx)
    local font_sub = opts.font_subtitle or (opts.fonts and (opts.fonts.default or opts.fonts.small))
    local pushed_sub = Theme.push_font(ctx, font_sub)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), opts.subtitle_color or P.text_dim)
    reaper.ImGui_Text(ctx, opts.subtitle)
    reaper.ImGui_PopStyleColor(ctx, 1)
    Theme.pop_font(ctx, pushed_sub)
  end

  -- 5. Right-aligned controls
  local show_settings = opts.show_settings
  local show_close = opts.show_close
  local right_w = opts.right_width or 0
  local combo_w = 0
  if show_settings then
    combo_w = Theme.calc_combo_width(ctx, SETTINGS_LABELS)
    if right_w > 0 then
      right_w = right_w + L.md
    end
    right_w = right_w + combo_w
  end
  if show_close then
    if right_w > 0 then
      right_w = right_w + L.md
    end
    right_w = right_w + close_btn_sz
  end

  local close_clicked = false

  if right_w > 0 or opts.right_widgets then
    reaper.ImGui_SameLine(ctx)
    if right_w > 0 then
      Theme.right_align(ctx, right_w)
    end

    if opts.right_widgets then
      opts.right_widgets(ctx, hdr_h)
      if show_settings or show_close then
        reaper.ImGui_SameLine(ctx, 0, L.md)
      end
    end

    if show_settings then
      local changed = Theme.settings_widget(ctx, { w = combo_w })
      if changed then
        Theme.invalidate_palette()
      end
      if show_close then
        reaper.ImGui_SameLine(ctx, 0, L.md)
      end
    end

    if show_close then
      Theme.align(ctx, hdr_h, close_btn_sz)
      local close_id = opts.close_id or "win_hdr_close"
      local close_tt = opts.close_tooltip or "Close (Esc)"
      if Theme.icon_btn(ctx, close_id, Theme.icons.close, { preset = L.icon_md, tooltip = close_tt }) then
        close_clicked = true
      end
    end
  end

  if opts.show_separator ~= false then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
  end

  return not close_clicked
end

return Theme


