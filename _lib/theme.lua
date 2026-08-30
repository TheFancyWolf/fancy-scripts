-- Fancy Scripts -- Design System & Theme Engine
-- Single source of truth for ALL visual decisions. local Theme = require("theme")
--
-- =============================================================================
-- API QUICK REFERENCE
-- =============================================================================
--
-- PALETTE -- Theme.build_palette([overrides]) returns table with:
--   Surfaces:   bg, panel, card               (window bg, popups, frame bg)
--   Text:       text, text_dim                (primary, secondary)
--   Accent:     accent      = active state    (ButtonActive, CheckMark, SliderGrab)
--               accent_h    = hover  (80%)    (ButtonHovered, HeaderHovered, FrameBgActive)
--               accent_d    = dim    (33%)    (Button, Header, FrameBgHovered, ScrollbarGrab)
--               accent_e    = subtle (12.5%)  (TableBorderLight)
--   Semantic:   green/green_h/green_d         (success, enabled, positive)
--               red/red_h/red_d               (error, delete, destructive)
--               yellow                        (warning, caution)
--   Structure:  border, sep, dim_bg           (borders, separators, modal overlay)
--   Table:      table_row, table_row_alt      (alternating row backgrounds)
--   Controls:   slider_grab_active            (slider grab while dragging)
--   Helpers:    Theme.with_alpha(rgba, a) / .lighten(rgba, f) / .darken(rgba, f) / .bgr_to_rgba(bgr)
--
-- THEME MODES -- Theme.get_mode() / .set_mode(mode)
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
--   btn_sm = {pad_x=sm, pad_y=xs, font="small"}   Push FramePadding + font
--   default = global FramePadding (md,sm)          No override needed
--   btn_lg = {pad_x=lg, pad_y=sm, font="medium"}  Push FramePadding + font
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
--   create_fonts(ctx)          -> {default,small,medium,large,header,default_bold,large_bold}
--   attach_fonts(ctx, fonts)   -> call once before first frame
--   push_font(ctx, font, [sz]) -> bool (safe pcall, auto-resolves size from registry)
--   pop_font(ctx, pushed)      -> conditional pop
--   fonts.tooltip = fonts.default (backward-compat alias)
--
-- STYLE -- Theme.push(ctx, [palette]) -> nc=28, nv=9 / Theme.pop(ctx, nc, nv)
--   Colors: WindowBg, Button*3, Header*3, FrameBg*3, Slider*2, CheckMark,
--           Popup, ModalDim, Separator*3, Table*5, Scrollbar*3
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
--   section_divider(ctx, label, [opts])        opts: tooltip,color
--   collapsing_header(ctx, label, [opts])      -> bool  opts: default_open,flags
--   center_next_window(ctx, w, h)
--   brand_icon(ctx, [size], [target_h])
--   invalidate_palette()                       clear internal widget palette cache
--
-- ALIGNMENT
--   vcenter(ctx, item_h, row_h)        Cursor Y: center item in row (tables, toolbars)
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
--     local P = Theme.build_palette()
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
-- Icons from icons.*. Alignment from vcenter/hcenter/right_align.
-- =============================================================================

local Theme = {}

-------------------------------------------------------------------------------
-- 1. COLOR HELPERS
-------------------------------------------------------------------------------

--- Adjusts the alpha channel of an RGBA color.
--- @param rgba integer  Color in 0xRRGGBBAA format
--- @param alpha number  Alpha value (0.0–1.0)
--- @return integer  Color with new alpha
local function with_alpha(rgba, alpha)
  return (rgba & 0xFFFFFF00) | math.floor(alpha * 255 + 0.5)
end

--- Lightens an RGBA color by blending toward white.
--- @param rgba integer  Color in 0xRRGGBBAA format
--- @param factor number  Lightening factor (0.0 = no change, 1.0 = white)
--- @return integer
local function lighten(rgba, factor)
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >> 8) & 0xFF
  local a = rgba & 0xFF
  r = math.min(255, math.floor(r + (255 - r) * factor + 0.5))
  g = math.min(255, math.floor(g + (255 - g) * factor + 0.5))
  b = math.min(255, math.floor(b + (255 - b) * factor + 0.5))
  return (r << 24) | (g << 16) | (b << 8) | a
end

--- Darkens an RGBA color by blending toward black.
--- @param rgba integer  Color in 0xRRGGBBAA format
--- @param factor number  Darkening factor (0.0 = no change, 1.0 = black)
--- @return integer
local function darken(rgba, factor)
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >> 8) & 0xFF
  local a = rgba & 0xFF
  r = math.floor(r * (1 - factor) + 0.5)
  g = math.floor(g * (1 - factor) + 0.5)
  b = math.floor(b * (1 - factor) + 0.5)
  return (r << 24) | (g << 16) | (b << 8) | a
end

--- Converts a REAPER native color integer to ImGui RGBA format.
--- REAPER's GetThemeColor returns OS-native colors (BGR on Windows, RGB on
--- macOS). We use reaper.ColorFromNative() to extract R, G, B correctly on
--- any platform, then pack into 0xRRGGBBAA for ReaImGui.
--- Negative values indicate alpha-blended or special colors; we mask them.
--- @param native integer  Native REAPER color value
--- @return integer  Color in 0xRRGGBBAA format (fully opaque)
local function bgr_to_rgba(native)
  if native < 0 then native = native & 0x00FFFFFF end
  local r, g, b = reaper.ColorFromNative(native)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Expose helpers for scripts that need direct color manipulation
Theme.with_alpha = with_alpha
Theme.lighten = lighten
Theme.darken = darken
Theme.bgr_to_rgba = bgr_to_rgba

-------------------------------------------------------------------------------
-- 2. THEME MODE CONSTANTS
-------------------------------------------------------------------------------
Theme.MODE_FANCY = "fancy"  -- Curated Fancy Scripts palette (default)
Theme.MODE_MATCH = "match"  -- Everything from REAPER theme (including edit cursor accent)

local EXTSTATE_SECTION = "FancyScripts"
local EXTSTATE_KEY     = "theme_mode"

--- Returns the current theme mode from global ExtState.
--- @return string  One of "fancy" or "match"
function Theme.get_mode()
  local mode = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY)
  if mode == Theme.MODE_MATCH or mode == "full" then
    return Theme.MODE_MATCH
  end
  return Theme.MODE_FANCY
end

--- Sets the global theme mode (persists across sessions).
--- @param mode string  One of Theme.MODE_FANCY, Theme.MODE_MATCH
function Theme.set_mode(mode)
  reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY, mode, true)
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

  -- Accent
  accent   = 0x8B70FAFF,

  -- Semantic base colors
  green    = 0x56E39FFF,
  red      = 0xF45B69FF,
  yellow   = 0xFFCC66FF,

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

  -- Semantic base colors
  P.green  = overrides.green  or FANCY_PALETTE.green
  P.red    = overrides.red    or FANCY_PALETTE.red
  P.yellow = overrides.yellow or FANCY_PALETTE.yellow

  -- Derive semantic states from base colors (consistent 80% / 33% ratios)
  P.green_h = overrides.green_h or with_alpha(P.green, 0.80)
  P.green_d = overrides.green_d or with_alpha(P.green, 0.33)
  P.red_h   = overrides.red_h   or with_alpha(P.red, 0.80)
  P.red_d   = overrides.red_d   or with_alpha(P.red, 0.33)

  -- Derive accent states from the resolved accent color
  -- accent_h = Hover state (80% alpha): ButtonHovered, HeaderHovered, FrameBgActive, SeparatorHovered, ScrollbarGrabHovered
  P.accent_h = overrides.accent_h or with_alpha(P.accent, 0.80)
  -- accent_d = Dim/default state (33% alpha): Button, Header, FrameBgHovered, ScrollbarGrab
  P.accent_d = overrides.accent_d or with_alpha(P.accent, 0.33)
  -- accent_e = Extra-dim (12.5% alpha): TableBorderLight — subtle structural lines
  P.accent_e = overrides.accent_e or with_alpha(P.accent, 0.125)

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
  -- Push FramePadding + font for sm/lg; pop after rendering.
  btn_sm       = { pad_x = S.sm, pad_y = S.xs, font = "small" },
  btn_lg       = { pad_x = S.lg, pad_y = S.sm, font = "medium" },

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
--- @param palette table|nil  Palette from build_palette() (builds default if nil)
--- @return integer color_count  Number of style colors pushed
--- @return integer var_count  Number of style vars pushed
function Theme.push(ctx, palette)
  local P = palette or Theme.build_palette()
  local L = Theme.layout

  -- Style colors (28 total)
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

  return 28, 9
end

--- Pops all Fancy Scripts ImGui styles from the stack.
--- Call after ImGui_End, using the counts returned by Theme.push().
--- @param ctx userdata  ImGui context
--- @param nc integer|nil  Number of colors to pop (default 28)
--- @param nv integer|nil  Number of vars to pop (default 9)
function Theme.pop(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc or 28)
  reaper.ImGui_PopStyleVar(ctx, nv or 9)
end

-------------------------------------------------------------------------------
-- 8. DESIGN TOKENS — TYPOGRAPHY
-------------------------------------------------------------------------------
--- Font families and size scale. Scripts must use Theme.font_sizes.* tokens
--- and Theme.create_fonts() instead of calling ImGui_CreateFont directly.

Theme.font_family      = "Verdana"
Theme.font_bold_family = "Verdana Bold"

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
--- Produces 7 fonts: default, small, medium, large, header (regular)
---                    default_bold, large_bold (bold)
--- @param _ctx userdata  ImGui context (unused but kept for API consistency)
--- @param overrides table|nil  Optional: { family="Arial", bold_family="Arial Bold", large=24, ... }
--- @return table  Font table with keys: default, small, medium, large, header,
---                default_bold, large_bold
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
  fonts.large_bold   = reaper.ImGui_CreateFont(bold_family, sizes.large)
  -- Backward compat alias
  fonts.tooltip = fonts.default

  -- Store font→size mapping for push_font (ImGui_PushFont requires size arg)
  Theme._font_sizes = {}
  Theme._font_sizes[fonts.default]      = sizes.default
  Theme._font_sizes[fonts.small]        = sizes.small
  Theme._font_sizes[fonts.medium]       = sizes.medium
  Theme._font_sizes[fonts.large]        = sizes.large
  Theme._font_sizes[fonts.header]       = sizes.header
  Theme._font_sizes[fonts.default_bold] = sizes.default
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

-- Lazy-init palette cache: built once per script session, rebuilt when
-- Theme mode changes. Widgets call _get_palette() internally.
local _cached_palette = nil
local _cached_mode = nil

local function _get_palette()
  local mode = Theme.get_mode()
  if not _cached_palette or mode ~= _cached_mode then
    _cached_palette = Theme.build_palette()
    _cached_mode = mode
  end
  return _cached_palette
end

--- Forces the internal widget palette cache to rebuild.
--- Call after Theme.set_mode() if you need widgets to reflect the change
--- within the same frame.
function Theme.invalidate_palette()
  _cached_palette = nil
  _cached_mode = nil
end

--- Vertically centers the next item within a row of a given height.
--- Call before rendering the item. Adjusts the cursor Y position so the
--- item appears centered within the row.
---
--- @param ctx userdata  ImGui context
--- @param item_h number  Height of the item to center (e.g. font size, icon size)
--- @param row_h number   Height of the containing row (e.g. Theme.layout.row_h)
function Theme.vcenter(ctx, item_h, row_h)
  if row_h and item_h < row_h then
    local cy = reaper.ImGui_GetCursorPosY(ctx)
    reaper.ImGui_SetCursorPosY(ctx, cy + math.floor((row_h - item_h) * 0.5))
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
---   opts.color   (number)  Label text color (default: palette.text_dim)
---   opts.tooltip (string)  Info icon + tooltip text shown next to label
function Theme.section_divider(ctx, label, opts)
  opts = opts or {}
  local P = _get_palette()
  local col = opts.color or P.text_dim
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  if opts.tooltip then
    reaper.ImGui_SameLine(ctx, 0, Theme.layout.section_gap)
    local btn_id = opts.id and ("info_" .. opts.id) or ("##info_" .. label)
    Theme.icon_btn(ctx, btn_id, Theme.icons.info, {
      preset = Theme.layout.icon_sm,
      color = P.text_dim,
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

--- Centers the next ImGui window on the viewport.
--- Call immediately before ImGui_Begin or ImGui_BeginPopupModal.
---
--- @param ctx userdata  ImGui context
--- @param w number  Window width in pixels
--- @param h number  Window height in pixels
function Theme.center_next_window(ctx, w, h)
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vp_x, vp_y = reaper.ImGui_Viewport_GetPos(vp)
  local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(vp)
  reaper.ImGui_SetNextWindowPos(ctx, vp_x + (vp_w - w) * 0.5, vp_y + (vp_h - h) * 0.5, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_SetNextWindowSize(ctx, w, h, reaper.ImGui_Cond_Appearing())
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
  local labels = { "Fancy Dark", "Match Theme" }
  local values = { Theme.MODE_FANCY, Theme.MODE_MATCH }
  local current = 1
  for i, v in ipairs(values) do
    if v == mode then current = i; break end
  end

  local auto_w = Theme.calc_combo_width(ctx, labels)
  local w = opts.w or auto_w

  if opts.align == "right" then
    Theme.right_align(ctx, w, opts.margin)
  end

  local changed = false
  local combo_label = opts.label or "##theme_mode"
  reaper.ImGui_SetNextItemWidth(ctx, w)
  if reaper.ImGui_BeginCombo(ctx, combo_label, labels[current]) then
    for i, label in ipairs(labels) do
      local selected = (i == current)
      if reaper.ImGui_Selectable(ctx, label, selected) then
        if not selected then
          Theme.set_mode(values[i])
          Theme.invalidate_palette()
          changed = true
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return changed, w
end

return Theme

