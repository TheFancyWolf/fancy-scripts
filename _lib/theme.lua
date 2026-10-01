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
--   Structure:  border, sep, dim_bg           (borders, separators, modal overlay; border >= 3:1 on bg/panel/card)
--   Table:      table_row, table_row_alt      (alternating row backgrounds)
--   Controls:   slider_grab_active            (slider grab while dragging)
--   Canvas:     canvas = { row*, grid*, key_*, key_text_*, note_*, zone_*, handle*, trace, preview, trend, ... }
--               Colours for custom-drawn editors (piano roll, notes, curves, pills). Fixed in Fancy Dark,
--               derived and contrast-fitted (text >= 4.5:1, boundaries >= 3:1) in Match Theme; curves, markers and
--               note_bypassed_mark are contrast-fitted in both modes. See section 4A.
--   Helpers:    Theme.with_alpha(rgba, a) / .lighten(rgba, f) / .darken(rgba, f) / .bgr_to_rgba(bgr)
--
-- THEME MODES & PREFS -- Theme.get_mode() / .set_mode(mode) / .invalidate_palette()
--   MODE_FANCY="fancy"  Curated dark, purple accent
--   MODE_MATCH="match"  Everything from REAPER theme (including edit cursor accent)
--   Theme.get_show_tooltips() / .set_show_tooltips(bool) Global tooltip visibility
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
--   icon_target={size=xl,pad=sm}->24px (WCAG 2.5.8 minimum target for frequent / destructive icon buttons)
--   Pass via opts.preset: Theme.icon_btn(ctx, id, fn, {preset = L.icon_sm})
--
-- FONTS -- Theme.font_sizes: small=12 default=14 medium=16 large=18 header=20
--   create_fonts(ctx)          -> {default,small,medium,large,header,default_bold,medium_bold,large_bold}
--   attach_fonts(ctx, fonts)   -> call once before first frame
--   push_font(ctx, font, [sz]) -> bool (safe pcall, auto-resolves size from registry)
--   pop_font(ctx, pushed)      -> conditional pop
--   fonts.tooltip = fonts.default (backward-compat alias)
--
-- STYLE -- Theme.push(ctx, [palette]) -> nc=32, nv=10 / Theme.pop(ctx, nc, nv)
--   Colors: WindowBg, TitleBg*2, Header*3, Button*3, FrameBg*3, Slider*2, CheckMark,
--           Popup, ModalDim, Separator*3, Table*5, Scrollbar*3, ScrollbarGrabActive,
--           Text, TextDisabled, Border
--   Vars:   WindowRounding, FrameRounding, GrabRounding, ItemSpacing, FramePadding,
--           WindowPadding, CellPadding, ItemInnerSpacing, IndentSpacing, FrameBorderSize
--
-- ICONS -- function(dl, cx, cy, half_size, color)
--   Theme.icons: play, pause, close, plus, info, tri_down, tri_up, tri_left, tri_right, slider, gear
--
-- WIDGETS
--   icon_btn(ctx, id, icon_fn, [opts])         -> bool  opts: preset,w,h,icon_size,color,tooltip (hand cursor on hover)
--   icon_btn_colored(ctx, id, icon_fn, [opts]) -> bool  opts: +bg,bg_hover,bg_active,icon_color
--   selectable(ctx, label, [sel], [flags], [w], [h], [opts])  Rounded Selectable; a label wider than the item is
--                                              shortened with "..." and shown in full in a tooltip
--   tooltip(ctx, text, [max_w])                The widgets' opts.tooltip show on HoveredFlags_ForTooltip (also when disabled)
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
--   settings_widget(ctx, [opts])        Reactive theme mode combo (opts: w, label, align, margin)
--   tooltip_setting_widget(ctx, [opts]) Global show tooltips checkbox (opts: label)
--   calc_combo_width(ctx, items, [p])   Calculates reactive width from font metrics + labels
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
-- 2. THEME MODE & PREFERENCE CONSTANTS & CACHE
-------------------------------------------------------------------------------
Theme.MODE_FANCY = "fancy"  -- Curated Fancy Scripts palette (default)
Theme.MODE_MATCH = "match"  -- Everything from REAPER theme (including edit cursor accent)

local EXTSTATE_SECTION       = "FancyScripts"
local EXTSTATE_KEY_THEME     = "theme_mode"
local EXTSTATE_KEY_TOOLTIPS  = "show_tooltips"

local _cached_palette = nil
local _cached_mode = nil
local _cached_show_tooltips = nil

--- Returns the current theme mode from global ExtState (cached in memory).
--- @return string  One of "fancy" or "match"
function Theme.get_mode()
  if _cached_mode then return _cached_mode end
  local mode = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY_THEME)
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
  reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY_THEME, mode, true)
  _cached_mode = mode
  _cached_palette = Theme.build_palette()
end

--- Returns whether tooltips are enabled from global ExtState (cached in memory).
--- @return boolean  true if tooltips are enabled (default: true)
function Theme.get_show_tooltips()
  if _cached_show_tooltips ~= nil then return _cached_show_tooltips end
  local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY_TOOLTIPS)
  if val == "0" or val == "false" or val == "off" then
    _cached_show_tooltips = false
  else
    _cached_show_tooltips = true
  end
  return _cached_show_tooltips
end

--- Sets whether tooltips are enabled globally (persists across sessions and updates cache).
--- @param enabled boolean
function Theme.set_show_tooltips(enabled)
  local val = enabled and "1" or "0"
  reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY_TOOLTIPS, val, true)
  _cached_show_tooltips = not not enabled
end

-- Aliases for developer convenience
Theme.get_tooltips_enabled = Theme.get_show_tooltips
Theme.set_tooltips_enabled = Theme.set_show_tooltips
Theme.tooltips_enabled     = Theme.get_show_tooltips

--- Forces the internal widget palette and preferences cache to rebuild.
--- Call after Theme.set_mode(), Theme.set_show_tooltips(), or when live REAPER theme colors change.
function Theme.invalidate_palette()
  _cached_palette = nil
  _cached_mode = nil
  _cached_show_tooltips = nil
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
  text_dim = 0x8E8EADFF,

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
  border   = 0x737373FF,
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
-- 4A. CANVAS PALETTE (P.canvas)
-------------------------------------------------------------------------------
--- Colours for custom-drawn editor canvases (piano-roll rows and grid, piano keys and their labels, note blocks,
--- zone highlights, trim handles, curves and markers, marquee, playhead, pills, ruler, scrim). Built by
--- Theme.build_palette() into P.canvas for both modes:
---   Fancy Dark   fixed values (the colours the Pitch Correct canvas drew with hex literals), plus a few that are
---                exactly a palette colour or an alpha of it (noted per token). The curves and markers then go
---                through the same fit step as Match Theme (below), so they too read at >= 3:1 (marker label 4.5:1).
---   Match Theme  derived from P.bg / P.panel / P.text / P.accent / P.green / P.blue / P.yellow so the canvas
---                follows a dark or a light REAPER theme. Every text token is fitted to >= 4.5:1 and every object
---                boundary to >= 3:1 (WCAG 2.x, alpha composited first) against the surfaces it is drawn on.
---                The BYPASSED badge (bypass_title, bypass_border) is fitted against the card and the dimmed canvas.
---   Both modes   one shared fit step (fit_canvas_marks): the curves and markers (trace, playhead, trend, anchor,
---                spot, preview, marker_split >= 3:1, marker_split_text >= 4.5:1) are fitted against the persistent
---                surfaces they are drawn on: the rows, every note fill over the rows, the vibrato wash (and the ruler
---                strip for the playhead), moved toward white or black only as far as that takes so each keeps its
---                hue; the transient zone highlights (Shift-hover, drag) are not part of the fit. note_bypassed_mark
---                (the strike / outline of a bypassed note) is fitted to >= 3:1 on the rows and on the bypassed fill
---                over them, while the fill itself stays dim; note_bypassed_border keeps its dimmed value.
---                The piano keys keep the same fixed colours in both modes (white / black key metaphor).

-- WCAG 2.x maths (private to the library).
local function srgb_to_linear(c8)
  local c = c8 / 255
  if c <= 0.03928 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

--- Relative luminance (0 = black, 1 = white) of an 0xRRGGBBAA colour (alpha ignored).
local function luminance(rgba)
  return 0.2126 * srgb_to_linear((rgba >> 24) & 0xFF)
       + 0.7152 * srgb_to_linear((rgba >> 16) & 0xFF)
       + 0.0722 * srgb_to_linear((rgba >> 8) & 0xFF)
end

--- Alpha-composites `fg` (0xRRGGBBAA) over the opaque colour `under`; the result is opaque.
local function composite_over(fg, under)
  local a = (fg & 0xFF) / 255
  local out = 0
  for shift = 24, 8, -8 do
    local f = (fg >> shift) & 0xFF
    local u = (under >> shift) & 0xFF
    out = out | (math.floor(f * a + u * (1 - a) + 0.5) << shift)
  end
  return out | 0xFF
end

--- WCAG contrast ratio of `fg` (its alpha composited first) over the opaque surface `under`.
local function contrast_over(fg, under)
  local l1 = luminance(composite_over(fg, under))
  local l2 = luminance(under)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

-- Margin added to every fitted threshold so rounding never leaves a colour a hair under the WCAG limit.
local FIT_MARGIN = 0.05

--- Luminance of every opaque colour of `surfaces`, worked out once and kept on the list (again if the list grew).
local function surface_lums(surfaces)
  local lums = surfaces.lums
  if not lums or #lums ~= #surfaces then
    lums = {}
    for i = 1, #surfaces do lums[i] = luminance(surfaces[i]) end
    surfaces.lums = lums
  end
  return lums
end

--- WCAG contrast ratio of `col` (alpha composited first) over the opaque colour `under`, whose luminance is `l2`.
local function ratio_over(col, under, l2)
  local l1 = luminance(composite_over(col, under))
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

--- Lowest contrast of `col` (alpha composited first) over the opaque colours in `surfaces`.
local function min_contrast(col, surfaces)
  local lums = surface_lums(surfaces)
  local w = math.huge
  for i = 1, #surfaces do
    local r = ratio_over(col, surfaces[i], lums[i])
    if r < w then w = r end
  end
  return w
end

--- True when the contrast of `col` over every opaque colour in `surfaces` is at least `need` (stops at the first
--- surface that falls short, so a search that mostly fails stays cheap).
local function reaches(col, surfaces, need)
  local lums = surface_lums(surfaces)
  for i = 1, #surfaces do
    if ratio_over(col, surfaces[i], lums[i]) < need then return false end
  end
  return true
end

--- Moves `col` toward white or black, as little as possible, until its contrast against every opaque colour in
--- `surfaces` reaches `min_ratio`. Returns `col` unchanged when it already does. A translucent colour that
--- cannot get there keeps its alpha first, then becomes opaque. When nothing reaches it (the surfaces span too
--- wide a range for any one colour) the result is the candidate with the best worst case over `surfaces`; with
--- `keep` (the surfaces that matter most, a subset) a candidate that still reaches `min_ratio` on `keep` wins
--- over one that does not.
--- With `keep_hue` (the curve and marker colours, which tell the layers apart by hue) a translucent colour does not
--- take the first shade that reaches `min_ratio` with its alpha: the variant that moves least toward white or black
--- wins, whether that keeps the alpha or becomes opaque (a see-through line needs to be whitened far more than an
--- opaque one, and that turns it into a near-neutral tint); on a tie the translucent one wins.
--- @param col integer  Colour 0xRRGGBBAA
--- @param surfaces table  Array of opaque 0xRRGGBBAA surfaces the colour is drawn on
--- @param min_ratio number  Required WCAG contrast ratio (4.5 text, 3 object boundaries)
--- @param keep table|nil  Optional subset of `surfaces` to hold at `min_ratio` when `surfaces` as a whole is out of reach
--- @param keep_hue boolean|nil  Prefer the variant that shifts the colour least (see above)
--- @return integer
local function fit_contrast(col, surfaces, min_ratio, keep, keep_hue)
  local need = min_ratio + FIT_MARGIN
  if reaches(col, surfaces, need) then return col end
  local lums = surface_lums(surfaces)
  local mean = 0
  for i = 1, #surfaces do mean = mean + lums[i] end
  mean = mean / #surfaces
  -- Light surfaces: darken first (a dark mark reads on them); dark surfaces: lighten first.
  local first, second = lighten, darken
  if mean > 0.179 then first, second = darken, lighten end
  local bases = { col, (col & 0xFFFFFF00) | 0xFF }
  if keep_hue then
    -- Per direction, the smallest step over both bases (the translucent one first, so it wins a tie)
    for _, shade in ipairs({ first, second }) do
      local found, found_step
      for _, base in ipairs(bases) do
        for step = 0, found_step and found_step - 1 or 20 do
          local c = step == 0 and base or shade(base, step / 20)
          if reaches(c, surfaces, need) then found, found_step = c, step; break end
        end
      end
      if found then return found end
    end
  end
  local tried = {}
  for _, base in ipairs(bases) do
    for _, shade in ipairs({ first, second }) do
      for step = 0, 20 do
        local c = step == 0 and base or shade(base, step / 20)
        if reaches(c, surfaces, need) then return c end
        tried[#tried + 1] = c
      end
    end
  end
  -- Out of reach: the best worst case (a candidate that holds `keep` first)
  local best, best_w = col, min_contrast(col, surfaces)
  local best_keeps = keep ~= nil and reaches(col, keep, need)
  for _, c in ipairs(tried) do
    local keeps = keep ~= nil and reaches(c, keep, need)
    local w = min_contrast(c, surfaces)
    if (keeps and not best_keeps) or (keeps == best_keeps and w > best_w) then
      best, best_w, best_keeps = c, w, keeps
    end
  end
  return best
end

--- Appends the lightest and darkest of `list` (opaque colours) to `into`: a colour that clears both ends of
--- a narrow band of surfaces clears the ones between them.
local function add_ends(into, list)
  local lo, hi = list[1], list[1]
  local lo_l, hi_l = luminance(lo), luminance(hi)
  for i = 2, #list do
    local l = luminance(list[i])
    if l < lo_l then lo, lo_l = list[i], l end
    if l > hi_l then hi, hi_l = list[i], l end
  end
  into[#into + 1] = lo
  into[#into + 1] = hi
  return into
end

--- Every colour of `fills` (translucent, e.g. note fills) as it shows over every surface of `rows`.
local function over_each(fills, rows)
  local out = {}
  for _, fill in ipairs(fills) do
    for _, row in ipairs(rows) do out[#out + 1] = composite_over(fill, row) end
  end
  return out
end

--- A new list holding the entries of every list given.
local function concat_lists(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, v in ipairs(list) do out[#out + 1] = v end
  end
  return out
end

--- Moves the translucent `fill` away from `ink` (toward the opposite extreme) until `ink` reads at `min_ratio`
--- on the fill as it shows over every surface of `rows`. Keeps the hue when the fill already works.
--- @param fill integer  Fill colour 0xRRGGBBAA (translucent)
--- @param rows table  Array of opaque surfaces the fill is drawn over
--- @param ink integer  Extreme colour a label will be drawn in: 0xFFFFFFFF or 0x000000FF
--- @param min_ratio number  Required contrast
--- @return integer fill, boolean ok
local function fit_fill(fill, rows, ink, min_ratio)
  local need = min_ratio + FIT_MARGIN
  local away = ink == 0xFFFFFFFF and darken or lighten
  for step = 0, 20 do
    local f = step == 0 and fill or away(fill, step / 20)
    if min_contrast(ink, over_each({ f }, rows)) >= need then return f, true end
  end
  return fill, false
end

--- The canvas rows as they show (the accent tint included over the in-scale and root rows): the opaque surfaces
--- every fitted canvas token is checked against.
--- @param C table  Canvas palette holding the row* tokens
--- @return table  Array of opaque 0xRRGGBBAA surfaces
local function canvas_rows(C)
  return {
    composite_over(C.row_tint, C.row), composite_over(C.row_tint, C.row_black),
    composite_over(C.row_tonic_tint, C.row_tonic), C.row_dim, C.row_dim_black, C.row_plain, C.row_plain_black,
  }
end

--- The fit step both modes share: the curves, the markers and the bypassed-note mark, each starting from the colour
--- already in C, are fitted against the persistent surfaces they are drawn on, the rows, every note fill over the
--- rows and the vibrato wash over all of that (the playhead also over the ruler strip). Each is moved toward white
--- or black only as far as that takes, so it keeps its hue and the layers stay apart by colour. The zone
--- highlights (zone_drift, zone_shift) are NOT part of the fit: they show only while the pointer is over a block,
--- and making every curve clear the brightest of them would turn the curves into near-white. A surface set this
--- wide can still leave no colour that reaches 3:1 (a mid-grey theme): then the best worst case wins, with the rows
--- held at 3:1 first; the vibrato band itself is decoration.
--- @param C table  Canvas palette (changed in place): trace, preview, trend, spot, marker_split, marker_split_text,
---                 note_bypassed_border, the note fills, vibrato and ruler_bg hold their starting colours
--- @param rows table  canvas_rows(C)
--- @return table  Every persistent surface a curve is drawn on (rows, note blocks, and the wash over those)
local function fit_canvas_marks(C, rows)
  local blocks   = over_each({ C.note_fill, C.note_edited, C.note_selected, C.note_selected_edited, C.note_bypassed }, rows)
  local shown    = concat_lists(rows, blocks)                           -- rows and note blocks (no wash): split markers and their label
  local curve_on = concat_lists(shown, over_each({ C.vibrato }, shown)) -- ... and the wash over those: every persistent surface
  local line_on  = concat_lists(curve_on, over_each({ C.ruler_bg }, rows))    -- the playhead also crosses the ruler strip
  C.trace    = fit_contrast(C.trace, line_on, 3.0, rows, true)          -- raw pitch trace (accent)
  C.playhead = C.trace                                                  -- the playhead line: same as the trace
  C.preview  = fit_contrast(C.preview, curve_on, 3.0, rows, true)       -- corrected-pitch preview (green, 80 % alpha)
  C.trend    = fit_contrast(C.trend, curve_on, 3.0, rows, true)         -- trend line (cyan, apart from marker_split's blue)
  C.anchor   = C.trend                                                  -- trend anchor diamond: same as the trend
  C.spot     = fit_contrast(C.spot, curve_on, 3.0, rows, true)          -- smart-spot circle (yellow)
  -- Split markers are drawn before the wash: the line on rows and blocks, its label on rows and blocks
  C.marker_split      = fit_contrast(C.marker_split, shown, 3.0, rows, true)   -- split-point line (blue, 67 % alpha), >= 3:1
  C.marker_split_text = fit_contrast(C.marker_split_text, shown, 4.5, rows)    -- split-point label (blue_l), >= 4.5:1
  -- Bypassed note: the fill stays dim (a disabled state); its strike / outline mark reads at >= 3:1 on every row and
  -- on the bypassed fill over every row. note_bypassed_border stays as it is, for scripts that still draw with it
  C.note_bypassed_mark = fit_contrast(C.note_bypassed_border, concat_lists(rows, over_each({ C.note_bypassed }, rows)), 3.0)
  return curve_on
end

--- Fancy Dark canvas values. Literal tokens are the colours Pitch Correct drew with hex literals; the ones
--- built from P are exactly the palette colour (or an alpha of it) the script used next to them.
local function build_canvas_fancy(P)
  local C = {}
  -- Rows (what a note sits on). row* = in the scale, row_tonic = the key's root, row_dim* = out of the scale,
  -- row_plain* = no scale chosen (Chromatic). *_black = the row of a black piano key.
  C.row             = 0x212230FF
  C.row_black       = 0x1B1B26FF
  C.row_tonic       = 0x222032FF
  C.row_dim         = 0x131317FF
  C.row_dim_black   = 0x111114FF
  C.row_plain       = 0x202020FF
  C.row_plain_black = 0x161616FF
  -- Accent tints drawn over the in-scale / root rows (follow P.accent)
  C.row_tint        = with_alpha(P.accent, 0.05)
  C.row_tonic_tint  = with_alpha(P.accent, 0.12)
  -- Grid lines between rows
  C.grid            = with_alpha(P.accent, 0.16)
  C.grid_tonic      = with_alpha(P.accent, 0.35)
  C.grid_dim        = 0x1A1A20FF
  C.grid_plain      = 0x333333FF
  C.grid_plain_black = 0x222222FF
  -- Piano keys (fixed in both modes: a piano does not change colour with the REAPER theme)
  C.key_white       = 0xDDDDDDFF
  C.key_black       = 0x1E1E24FF
  C.key_plain_black = 0x1A1A1AFF
  C.key_tonic_white = 0xFFFFFFFF
  C.key_tonic_black = 0x252338FF
  C.key_dim_white   = 0x585962FF
  C.key_dim_black   = 0x101013FF
  C.key_outline     = 0x000000FF
  C.key_tonic_strip = P.accent
  -- Key labels (>= 4.5:1 on their key)
  C.key_text_white       = 0x2B2B2BFF
  C.key_text_black       = 0x999999FF
  C.key_text_plain_white = 0x333333FF
  C.key_text_plain_black = 0x888888FF
  C.key_text_tonic_white = 0x181824FF
  C.key_text_tonic_black = P.accent_l
  C.key_text_dim_white   = P.text
  C.key_text_dim_black   = P.text
  -- Note blocks: fills are translucent over the row
  C.note_fill            = 0x2A364499
  C.note_border          = 0x6F829CFF
  C.note_edited          = 0x3FA34D77
  C.note_edited_border   = P.green
  C.note_selected        = 0x4477AA88
  C.note_selected_edited = 0x3FA34D99
  C.note_selected_border = P.accent
  C.note_bypassed        = 0x2A2A2A55
  C.note_bypassed_border = 0x555555AA
  C.note_label           = 0xDDDDDDDD
  C.note_label_selected  = P.text
  C.note_label_edited    = 0xFFFFFFFF
  C.note_edit_mark       = P.text
  -- Zone highlights and trim handles (over a note block)
  C.zone_drift      = with_alpha(P.blue, 0.267)
  C.zone_shift      = 0xFFAA4444
  C.zone_divider    = with_alpha(P.text, 0.20)
  C.handle          = with_alpha(P.text, 0.80)
  C.handle_hover    = P.text
  C.handle_drag     = P.accent
  -- Curves, markers, selection, playhead
  C.trace           = P.accent
  C.preview         = with_alpha(P.green, 0.80)
  C.vibrato         = 0xFFAA4418
  C.trend           = 0x00FFFFFF
  C.spot            = 0xFFFF00FF
  C.anchor          = 0x00FFFFFF
  C.marker_split      = with_alpha(P.blue, 0.67)
  C.marker_split_text = P.blue_l
  C.marquee_fill    = with_alpha(P.accent, 0.18)
  C.marquee_border  = with_alpha(P.accent, 0.85)
  C.marquee_text    = P.accent_l
  C.playhead        = P.accent
  -- Overlays: pills (readouts, zone names), ruler strip, scrim
  C.pill_bg         = with_alpha(P.panel, 0.90)
  C.pill_text       = P.text
  C.ruler_bg        = with_alpha(P.panel, 0.90)
  C.scrim           = with_alpha(P.bg, 0.75)
  -- BYPASSED badge on the card, over the scrim: title and border are exactly P.yellow
  C.bypass_title    = P.yellow
  C.bypass_border   = P.yellow
  return C
end

--- Match Theme canvas values, derived from the REAPER-theme palette P. "toward" = toward the text colour
--- (lighter on a dark theme, darker on a light one), "away" = the other way. Fitted tokens start from the
--- palette colour named in the comment and move only as far as the contrast rule needs.
--- Tokens not assigned below keep their build_canvas_fancy value, by design: the piano keys and their
--- black/white labels and outline (key_white ... key_text_tonic_white), and the accent / text / blue / panel /
--- bg alphas that already follow the palette (row_tint, row_tonic_tint, grid, grid_tonic, zone_drift,
--- zone_divider, marquee_fill, marquee_border, pill_bg, ruler_bg, scrim).
local function build_canvas_match(P)
  local C = build_canvas_fancy(P)
  local bg = P.bg
  local dark = contrast_over(0xFFFFFFFF, bg) >= contrast_over(0x000000FF, bg)
  local toward = dark and lighten or darken
  local away = dark and darken or lighten

  -- Rows: out-of-scale rows are the window background, in-scale rows step toward the text colour. On a mid-grey
  -- background neither white nor black text can reach 4.5:1 on surfaces that differ much (the best possible
  -- is 4.58:1 at mid-grey), so the steps shrink as the background approaches mid-grey (k = 1 on clearly dark
  -- or light themes).
  local k = math.min(1, math.max(0.3, math.abs(luminance(bg) - 0.179) / 0.09))
  C.row             = toward(bg, 0.065 * k)   -- in scale, white key
  C.row_black       = toward(bg, 0.035 * k)   -- in scale, black key
  C.row_tonic       = toward(bg, 0.07 * k)    -- the key's root (plus the accent tint)
  C.row_dim         = bg                      -- out of scale: the window background
  C.row_dim_black   = away(bg, 0.10 * k)      -- out of scale, black key
  C.row_plain       = toward(bg, 0.06 * k)    -- no scale chosen, white key
  C.row_plain_black = toward(bg, 0.02 * k)    -- no scale chosen, black key
  C.grid_dim        = toward(bg, 0.05)        -- grid lines: fixed steps toward the text colour
  C.grid_plain      = toward(bg, 0.14)
  C.grid_plain_black = toward(bg, 0.07)

  -- The rows as they show (accent tint included): every other token is fitted against these
  local rows = canvas_rows(C)
  local row_ends = add_ends({}, rows)

  -- Keys: the fixed colours of build_canvas_fancy, plus the tokens that follow the palette
  local key_tonics = { C.key_tonic_white, C.key_tonic_black }
  C.key_tonic_strip      = fit_contrast(P.accent, key_tonics, 3.0)                   -- accent, >= 3:1 on both root keys
  C.key_text_tonic_black = fit_contrast(P.accent_l, { C.key_tonic_black }, 4.5)      -- accent_l, >= 4.5:1 on the root black key
  C.key_text_dim_white   = fit_contrast(P.text, { C.key_dim_white }, 4.5)            -- text, >= 4.5:1 on the dimmed white key
  C.key_text_dim_black   = fit_contrast(P.text, { C.key_dim_black }, 4.5)            -- text, >= 4.5:1 on the dimmed black key

  -- Note blocks: translucent blue (untouched, selected) and green (edited) tints moved "away" from the text
  -- colour (darker on a dark theme, lighter on a light one), so a label can always read on them; borders are
  -- the palette hue fitted to >= 3:1 on every row
  C.note_fill            = with_alpha(away(P.blue, 0.35), 0.45)    -- untouched note: muted blue
  C.note_edited          = with_alpha(away(P.green, 0.45), 0.50)   -- edited note: muted green
  C.note_selected        = with_alpha(away(P.blue, 0.15), 0.60)    -- selected note: brighter blue
  C.note_selected_edited = with_alpha(away(P.green, 0.35), 0.65)   -- selected edited note
  C.note_bypassed        = with_alpha(toward(bg, 0.10), 0.33)      -- bypassed note: a faint grey
  -- A fill that would leave the label no room (a mid-grey theme) is pushed further away until white (dark
  -- theme) or black (light theme) reads on it, so the label fit below can always succeed
  local ink, other_ink = 0xFFFFFFFF, 0x000000FF
  if not dark then ink, other_ink = other_ink, ink end
  for _, key in ipairs({ "note_fill", "note_edited", "note_selected", "note_selected_edited", "note_bypassed" }) do
    local fitted, ok = fit_fill(C[key], rows, ink, 4.5)
    if not ok then
      local alt, alt_ok = fit_fill(C[key], rows, other_ink, 4.5)
      if alt_ok then fitted = alt end
    end
    C[key] = fitted
  end
  C.note_bypassed_border = with_alpha(toward(bg, 0.30), 0.67)   -- dimmed on purpose (a disabled state)
  C.note_border          = fit_contrast(P.blue, rows, 3.0)        -- blue, >= 3:1 on every row
  C.note_edited_border   = fit_contrast(P.green, rows, 3.0)       -- green, >= 3:1 on every row
  C.note_selected_border = fit_contrast(P.accent, rows, 3.0)      -- accent, >= 3:1 on every row

  -- Labels on the block fills as they show over the rows (>= 4.5:1)
  local plain_fills    = over_each({ C.note_fill, C.note_bypassed }, row_ends)
  local selected_fills = over_each({ C.note_selected }, row_ends)
  local edited_fills   = over_each({ C.note_edited, C.note_selected_edited }, row_ends)
  C.note_label          = fit_contrast(with_alpha(P.text, 0.867), plain_fills, 4.5)   -- text (87 % alpha), untouched / bypassed fills
  C.note_label_selected = fit_contrast(P.text, selected_fills, 4.5)                   -- text on the selected fill
  C.note_label_edited   = fit_contrast(P.text, edited_fills, 4.5)                     -- text on both edited fills
  C.note_edit_mark      = fit_contrast(P.text, edited_fills, 3.0)                     -- the corner square: >= 3:1 on both edited fills

  -- Zone highlights: blue for the drift zone (as in Fancy Dark), yellow for the vibrato zone and while Shift is held
  C.zone_shift = with_alpha(P.yellow, 0.267)

  -- Trim handles, fitted to >= 3:1. At rest a handle can sit on any row, fill or zone highlight; the hovered and
  -- the dragged edge never have a zone highlight under them (an edge hit hides the zone)
  local fills = { C.note_fill, C.note_edited, C.note_selected, C.note_selected_edited }
  local edge_on = add_ends({}, rows)
  local fills_seen = over_each(fills, row_ends)
  for _, s in ipairs(fills_seen) do edge_on[#edge_on + 1] = s end
  local rest_on = {}
  for _, s in ipairs(edge_on) do rest_on[#rest_on + 1] = s end
  for _, s in ipairs(over_each({ C.zone_drift, C.zone_shift }, add_ends({}, fills_seen))) do
    rest_on[#rest_on + 1] = s
  end
  C.handle       = fit_contrast(with_alpha(P.text, 0.80), rest_on, 3.0)          -- text (80 % alpha) at rest
  C.handle_hover = fit_contrast((C.handle & 0xFFFFFF00) | 0xFF, edge_on, 3.0)   -- the resting handle made opaque
  C.handle_drag  = fit_contrast(P.accent, edge_on, 3.0)                          -- accent while the edge is dragged

  -- Curves and markers (and the bypassed-note mark): the shared fit step (fit_canvas_marks), starting from the palette
  -- hues. trace (P.accent), preview (P.green, 80 % alpha), trend (the Fancy Dark cyan), marker_split (P.blue, 67 %
  -- alpha) and marker_split_text (P.blue_l) start from their build_canvas_fancy value; the spot and the wash follow
  -- the theme's yellow
  C.vibrato = with_alpha(P.yellow, 0.094)                               -- vibrato band: a faint yellow wash
  C.spot    = P.yellow                                                  -- smart-spot circle: yellow
  local curve_on = fit_canvas_marks(C, rows)

  -- BYPASSED badge: the card, inside a border drawn over the dimmed canvas (the scrim over rows, blocks and the wash)
  local card   = { P.card }
  local dimmed = over_each({ C.scrim }, curve_on)
  C.bypass_title  = fit_contrast(P.yellow, card, 4.5)                              -- yellow, >= 4.5:1 on the card
  C.bypass_border = fit_contrast(P.yellow, concat_lists(card, dimmed), 3.0, card)  -- yellow, >= 3:1 on the card and the dimmed canvas

  -- Pills sit over rows and note fills: P.text / P.accent_l fitted on the pill as it shows
  local pill_on = over_each({ C.pill_bg }, add_ends({ C.key_tonic_white }, rows))
  C.pill_text    = fit_contrast(P.text, pill_on, 4.5)        -- readouts and zone names on the pill
  C.marquee_text = fit_contrast(P.accent_l, pill_on, 4.5)    -- the "N selected" count on the pill
  return C
end

--- Adds the canvas palette to a built palette: P.canvas (see the section comment above).
--- Kept out of Theme.build_palette so that function reads the same as before.
--- @param P table  Palette from build_palette (complete)
--- @param mode string  Theme mode the palette was built for
--- @param overrides table|nil  The build_palette overrides; overrides.canvas = { token = 0xRRGGBBAA } replaces tokens
--- @return table  P
local _match_canvas_key, _match_canvas = nil, nil
local function attach_canvas(P, mode, overrides)
  local C
  if mode == Theme.MODE_MATCH then
    -- The Match Theme derivation searches for contrast (about 0.5 ms): keep the last result, keyed by every colour
    -- it reads, and hand out a copy so callers may change their table
    local key = string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d", P.bg, P.panel, P.card, P.text, P.accent, P.accent_l,
      P.blue, P.blue_l, P.green, P.yellow)
    if key ~= _match_canvas_key then
      _match_canvas_key, _match_canvas = key, build_canvas_match(P)
    end
    C = {}
    for k, v in pairs(_match_canvas) do C[k] = v end
  else
    -- Fancy Dark: the fixed values, then the same curve / marker fit as Match Theme (most start out passing and
    -- are returned unchanged; the ones that do not, e.g. the accent trace over the selected fill, are lightened)
    C = build_canvas_fancy(P)
    fit_canvas_marks(C, canvas_rows(C))
  end
  if overrides and type(overrides.canvas) == "table" then
    for k, v in pairs(overrides.canvas) do C[k] = v end
  end
  P.canvas = C
  return P
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
    -- text_dim / border are fitted to WCAG on the three surfaces they are drawn on (text 4.5:1, border 3:1)
    local surfaces = { P.bg, P.panel, P.card }
    P.text_dim = overrides.text_dim or fit_contrast(read_theme_color("col_tcp_text", FANCY_PALETTE.text_dim), surfaces, 4.5)
    P.accent   = overrides.accent   or read_theme_color("col_cursor", FANCY_PALETTE.accent)
    P.border   = overrides.border   or fit_contrast(read_theme_color("col_main_3dhl", FANCY_PALETTE.border), surfaces, 3.0)
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

  -- accent_press = ButtonActive: the accent moved toward white/black only as far as P.text needs to read on it (4.5:1)
  P.accent_press = overrides.accent_press or fit_contrast(P.accent, { P.text }, 4.5)

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
  -- dim_bg = Modal overlay background (85% darkened bg): ModalWindowDimBg
  P.dim_bg = overrides.dim_bg or with_alpha(darken(P.bg, 0.70), 0.85)

  -- Derive table row colors from panel/card
  -- table_row = Default row bg (darkened panel): TableRowBg
  P.table_row     = overrides.table_row     or darken(P.panel, 0.10)
  -- table_row_alt = Alternating row bg (panel): TableRowBgAlt
  P.table_row_alt = overrides.table_row_alt or P.panel

  -- slider_grab_active = Lighter accent for active slider grab: SliderGrabActive
  P.slider_grab_active = overrides.slider_grab_active or lighten(P.accent, 0.15)

  -- Canvas colours for custom-drawn editors (piano roll, keys, notes, curves): see section 4A
  return attach_canvas(P, mode, overrides)
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
  border       = 1,     -- hairline border width (FrameBorderSize); colour is P.border (>= 3:1)

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
  icon_target  = { size = S.xl, pad = S.sm },   -- 16 + 4*2 -> 24px btn (WCAG 2.5.8 minimum target)

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
--- @return integer var_count  Number of style vars pushed (10)
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),         P.accent_press)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),              P.card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),       P.accent_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),        P.accent_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),           P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(),     P.slider_grab_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),            P.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),              P.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ModalWindowDimBg(),     0x00000000) -- transparent: manual scrim via Theme.modal_scrim()
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

  -- Style vars (10 total — all values from layout tokens)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),  L.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   L.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),    L.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),     L.md, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    L.md, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),   L.lg, L.lg)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(),     L.sm, L.xs)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemInnerSpacing(),L.sm, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_IndentSpacing(),   L.indent)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), L.border)

  return 32, 10
end

--- Pops all Fancy Scripts ImGui styles from the stack.
--- Call after ImGui_End, using the counts returned by Theme.push().
--- @param ctx userdata  ImGui context
--- @param nc integer|nil  Number of colors to pop (default 32)
--- @param nv integer|nil  Number of vars to pop (default 9)
function Theme.pop(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc or 32)
  reaper.ImGui_PopStyleVar(ctx, nv or 10)
end

-------------------------------------------------------------------------------
-- 8. DESIGN TOKENS — TYPOGRAPHY
-------------------------------------------------------------------------------
--- Font families and size scale. Scripts must use Theme.font_sizes.* tokens
--- and Theme.create_fonts() instead of calling ImGui_CreateFont directly.

Theme.font_family      = "sans-serif"
Theme.font_bold_family = "sans-serif"   -- bold is the Bold font flag on this family (CreateFont takes flags, not a size)

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
  fonts.default = reaper.ImGui_CreateFont(family)
  fonts.small   = reaper.ImGui_CreateFont(family)
  fonts.medium  = reaper.ImGui_CreateFont(family)
  fonts.large   = reaper.ImGui_CreateFont(family)
  fonts.header  = reaper.ImGui_CreateFont(family)
  -- Bold weights
  fonts.default_bold = reaper.ImGui_CreateFont(bold_family, reaper.ImGui_FontFlags_Bold())
  fonts.medium_bold  = reaper.ImGui_CreateFont(bold_family, reaper.ImGui_FontFlags_Bold())
  fonts.large_bold   = reaper.ImGui_CreateFont(bold_family, reaper.ImGui_FontFlags_Bold())
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

--- Slider / faders icon (horizontal rails with knobs).
--- Use for: sliders, pan, volume, mixer controls.
function Theme.icons.slider(dl, cx, cy, hs, col)
  local ox = math.floor(cx)
  local oy = math.floor(cy)
  local s = math.floor(hs * 0.85)
  local th = math.max(1.0, math.floor(hs * 0.22 + 0.5))
  local kw = math.max(2, math.floor(hs * 0.32 + 0.5))
  local kh = math.max(3, math.floor(hs * 0.6 + 0.5))
  local y_off = math.floor(hs * 0.45 + 0.5)

  -- Top rail + knob
  reaper.ImGui_DrawList_AddLine(dl, ox - s, oy - y_off, ox + s, oy - y_off, col, th)
  reaper.ImGui_DrawList_AddRectFilled(dl,
    ox - math.floor(s * 0.35) - kw, oy - y_off - kh,
    ox - math.floor(s * 0.35) + kw, oy - y_off + kh, col, 1)

  -- Bottom rail + knob
  reaper.ImGui_DrawList_AddLine(dl, ox - s, oy + y_off, ox + s, oy + y_off, col, th)
  reaper.ImGui_DrawList_AddRectFilled(dl,
    ox + math.floor(s * 0.35) - kw, oy + y_off - kh,
    ox + math.floor(s * 0.35) + kw, oy + y_off + kh, col, 1)
end

--- ◂ Triangle left (leftward-pointing).
--- Use for: collapse drawer, back/previous navigation.
function Theme.icons.tri_left(dl, cx, cy, hs, col)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox + math.floor(hs * 0.4), oy - math.floor(hs * 0.7),
    ox + math.floor(hs * 0.4), oy + math.floor(hs * 0.7),
    ox - math.floor(hs * 0.6), oy, col)
end

--- ▸ Triangle right (rightward-pointing).
--- Use for: expand drawer, forward/next navigation.
function Theme.icons.tri_right(dl, cx, cy, hs, col)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.4), oy - math.floor(hs * 0.7),
    ox - math.floor(hs * 0.4), oy + math.floor(hs * 0.7),
    ox + math.floor(hs * 0.6), oy, col)
end

--- ⚙ Gear / cog icon (central ring with radiating teeth).
--- Use for: settings, configuration, preferences modals.
function Theme.icons.gear(dl, cx, cy, hs, col)
  local ox = math.floor(cx)
  local oy = math.floor(cy)
  local s = hs * 0.9
  local r_outer = s
  local r_inner = s * 0.70
  local r_hole  = s * 0.32
  local tooth_th = math.max(1.5, s * 0.35)
  local ring_th  = r_inner - r_hole
  local mid_r    = (r_inner + r_hole) * 0.5

  -- 6 teeth radiating outward from the ring
  for i = 0, 5 do
    local angle = i * (math.pi / 3)
    local cos_a = math.cos(angle)
    local sin_a = math.sin(angle)
    local x1 = ox + (r_inner - 0.5) * cos_a
    local y1 = oy + (r_inner - 0.5) * sin_a
    local x2 = ox + r_outer * cos_a
    local y2 = oy + r_outer * sin_a
    reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, tooth_th)
  end

  -- Central ring
  reaper.ImGui_DrawList_AddCircle(dl, ox, oy, mid_r, col, 16, ring_th)
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

--- True when the last item is hovered long enough to show its tooltip: ReaImGui's own tooltip delay
--- (HoveredFlags_ForTooltip) and also while the item is disabled, so `opts.tooltip` can explain why.
--- @param ctx userdata  ImGui context
--- @return boolean
local function _hovered_for_tooltip(ctx)
  local flags = reaper.ImGui_HoveredFlags_AllowWhenDisabled()
  if reaper.ImGui_HoveredFlags_ForTooltip then
    flags = flags | reaper.ImGui_HoveredFlags_ForTooltip()
  end
  return reaper.ImGui_IsItemHovered(ctx, flags)
end

--- Draws a manual dim overlay (scrim) behind a modal popup.
---
--- Call BEFORE `ImGui_BeginPopupModal` while inside the parent window's
--- `Begin`/`End` block, right after `Theme.center_next_window` (the standard
--- pattern below). It replicates Dear ImGui's built-in dim without the
--- first-frame colour lag that occurs in ReaImGui: Theme.push() sets
--- ImGuiCol_ModalWindowDimBg to transparent, so the built-in mechanism never
--- fires. Use this function everywhere instead.
---
--- The parent's child windows (BeginChild panes) draw over the parent's own
--- draw list, so a scrim there would leave them bright. The scrim therefore goes
--- on the foreground draw list of the parent's viewport, over the child windows,
--- with a hole the shape of the modal so the modal itself is never dimmed. The
--- modal's rect comes from the placement Theme.center_next_window gave it and,
--- from then on, from a size-constraint callback run inside the modal's own
--- Begin, so the hole follows the modal when it is moved, resized or auto-fitted
--- (one frame behind while it is being dragged). Holes are also cut for every
--- modal of the same context opened after this one (a confirm opened from a
--- settings modal), which sits above it.
--- On the first visible frame the modal's final size is not known yet (an
--- auto-resizing modal can differ from the size it was given): then the scrim
--- covers the parent's own draw list (behind the modal) for that one frame,
--- or the whole foreground when the modal cannot fit the parent's viewport
--- (it is then an OS window of its own, above the scrim). Without
--- Theme.center_next_window the rect is never known and the parent's draw list
--- is used throughout.
---
--- **Standard pattern:**
--- ```
--- Theme.center_next_window(ctx, w, h)
--- Theme.modal_scrim(ctx, "My Modal##id")
--- local visible = reaper.ImGui_BeginPopupModal(ctx, "My Modal##id", ...)
--- ```
---
--- @param ctx  userdata  ImGui context
--- @param popup_name string  Exact popup ID (same string passed to OpenPopup / BeginPopupModal)

-- Per open popup (keyed by name): { ctx, order, frames, own_viewport, cx, cy, rect = { x1, y1, x2, y2 } | nil }
local _scrim_state = {}
local _scrim_order = 0   -- opening order: a modal opened later is drawn above the ones opened before it
-- Placement of the window Theme.center_next_window set up last: { ctx, frame, cx, cy, w, h } (see modal_scrim)
local _next_window_rect = nil
-- Size-constraint callbacks that report a modal's position and size, per context and popup name. Kept for the
-- context's lifetime (attached to it) and reused every time the popup opens again.
local _scrim_fns = setmetatable({}, { __mode = "k" })
local SCRIM_FN_EEL = "fs_x = Pos.x; fs_y = Pos.y; fs_w = DesiredSize.x; fs_h = DesiredSize.y; fs_n += 1;"

--- True when the popup placed by the last Theme.center_next_window call (this frame) cannot fit the viewport
--- (vp_x, vp_y, vp_w, vp_h), so Dear ImGui gives it a viewport of its own. An auto-fit height (h = 0) is checked
--- with zero height: a taller modal only sticks out further. 1 px of slack so rounding never claims a miss.
local function _popup_leaves_viewport(r, vp_x, vp_y, vp_w, vp_h)
  if not r then return false end
  local x1, x2 = r.cx - r.w * 0.5, r.cx + r.w * 0.5
  local y1, y2 = r.cy - r.h * 0.5, r.cy + r.h * 0.5
  return x1 < vp_x - 1 or y1 < vp_y - 1 or x2 > vp_x + vp_w + 1 or y2 > vp_y + vp_h + 1
end

--- The size callback of `popup_name` in `ctx` (created and attached on first use), or nil when this ReaImGui
--- has no EEL functions.
local function _scrim_size_fn(ctx, popup_name)
  if not reaper.ImGui_CreateFunctionFromEEL then return nil end
  local fns = _scrim_fns[ctx]
  if not fns then
    fns = {}
    _scrim_fns[ctx] = fns
  end
  local fn = fns[popup_name]
  if not fn or not reaper.ImGui_ValidatePtr(fn, "ImGui_Function*") then
    fn = reaper.ImGui_CreateFunctionFromEEL(SCRIM_FN_EEL)
    if not fn then return nil end
    reaper.ImGui_Attach(ctx, fn)
    fns[popup_name] = fn
  end
  return fn
end

--- Fills the rect (x1, y1)-(x2, y2) with `col` on `dl`, leaving out every rect of `holes` (each with corners
--- rounded by `rounding`, like a window). Axis-aligned cells, so neighbouring fills meet without seams.
local function _fill_around_holes(dl, x1, y1, x2, y2, holes, col, rounding)
  local xs, ys = { x1, x2 }, { y1, y2 }
  for _, h in ipairs(holes) do
    for _, x in ipairs({ h[1], h[3] }) do
      if x > x1 and x < x2 then xs[#xs + 1] = x end
    end
    for _, y in ipairs({ h[2], h[4] }) do
      if y > y1 and y < y2 then ys[#ys + 1] = y end
    end
  end
  table.sort(xs)
  table.sort(ys)
  for i = 1, #xs - 1 do
    for j = 1, #ys - 1 do
      local ax, bx, ay, by = xs[i], xs[i + 1], ys[j], ys[j + 1]
      if bx > ax and by > ay then
        local mx, my = (ax + bx) * 0.5, (ay + by) * 0.5
        local in_hole = false
        for _, h in ipairs(holes) do
          if mx > h[1] and mx < h[3] and my > h[2] and my < h[4] then in_hole = true break end
        end
        if not in_hole then reaper.ImGui_DrawList_AddRectFilled(dl, ax, ay, bx, by, col) end
      end
    end
  end
  -- The hole is the modal's rect; its corners are rounded, so dim the bits of each corner outside the curve
  if rounding > 0 then
    local hp = math.pi * 0.5
    for _, h in ipairs(holes) do
      local r = math.min(rounding, (h[3] - h[1]) * 0.5, (h[4] - h[2]) * 0.5)
      if r > 0 then
        local corners = {
          { h[1], h[2], h[1] + r, h[2] + r, 2 * hp }, { h[3], h[2], h[3] - r, h[2] + r, 3 * hp },
          { h[3], h[4], h[3] - r, h[4] - r, 0 },      { h[1], h[4], h[1] + r, h[4] - r, hp },
        }
        for _, c in ipairs(corners) do
          reaper.ImGui_DrawList_PathLineTo(dl, c[1], c[2])
          reaper.ImGui_DrawList_PathArcTo(dl, c[3], c[4], r, c[5], c[5] + hp)
          reaper.ImGui_DrawList_PathFillConcave(dl, col)
        end
      end
    end
  end
end

function Theme.modal_scrim(ctx, popup_name)
  local is_open = reaper.ImGui_IsPopupOpen(ctx, popup_name)
  if not is_open then
    _scrim_state[popup_name] = nil
    return
  end
  local vp = reaper.ImGui_GetWindowViewport(ctx)
  local vp_x, vp_y = reaper.ImGui_Viewport_GetPos(vp)
  local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(vp)
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local rec = _next_window_rect
  if rec and (rec.ctx ~= ctx or rec.frame ~= frame) then rec = nil end

  local st = _scrim_state[popup_name]
  if not st or st.ctx ~= ctx then
    -- The frame the popup appears: center_next_window placed it this frame
    _scrim_order = _scrim_order + 1
    st = { ctx = ctx, order = _scrim_order, frames = 0, own_viewport = _popup_leaves_viewport(rec, vp_x, vp_y, vp_w, vp_h),
           cx = rec and rec.cx, cy = rec and rec.cy }
    _scrim_state[popup_name] = st
  end
  st.frames = st.frames + 1

  -- What the modal's Begin reported last frame (its final size, and its position), then arm the callback for this
  -- frame's Begin. It repeats the size constraint center_next_window set (none with a fixed height), so it is only
  -- installed when that call placed the modal this frame.
  local fn = _scrim_size_fn(ctx, popup_name)
  local got, fx, fy, fw, fh = false, 0, 0, 0, 0
  if fn then
    if reaper.ImGui_Function_GetValue(fn, "fs_n") > 0 then
      got = true
      fx, fy = reaper.ImGui_Function_GetValue(fn, "fs_x"), reaper.ImGui_Function_GetValue(fn, "fs_y")
      fw, fh = reaper.ImGui_Function_GetValue(fn, "fs_w"), reaper.ImGui_Function_GetValue(fn, "fs_h")
    end
    reaper.ImGui_Function_SetValue(fn, "fs_n", 0)
    if rec then
      local _, flt_max = reaper.ImGui_NumericLimits_Float()
      if rec.h > 0 then
        reaper.ImGui_SetNextWindowSizeConstraints(ctx, 0, 0, flt_max, flt_max, fn)
      else
        reaper.ImGui_SetNextWindowSizeConstraints(ctx, rec.w, 0, rec.w, 1e6, fn)
      end
    end
  end

  -- Skip the very first frame the popup appears — Dear ImGui hides the
  -- modal window for one frame on creation (HiddenFramesCannotSkipItems).
  -- Drawing the scrim on that frame produces a dark flash with no modal.
  if st.frames == 1 then return end

  -- The modal's rect this frame. Frame 2: not known yet (its size may still change). Frame 3: the size from
  -- frame 2, where Dear ImGui centred it on the placement point (the callback ran before that move). Later: the
  -- position and size the callback reported (one frame behind while the modal is dragged)
  if got and st.frames >= 3 and fw > 0 and fh > 0 then
    fw, fh = math.floor(fw), math.floor(fh)
    if st.frames == 3 then
      if st.cx then
        st.rect = { math.floor(st.cx - fw * 0.5), math.floor(st.cy - fh * 0.5) }
      end
    else
      st.rect = { math.floor(fx), math.floor(fy) }
    end
    if st.rect then st.rect[3], st.rect[4] = st.rect[1] + fw, st.rect[2] + fh end
  end

  local P = _get_palette()
  local x1, y1, x2, y2 = vp_x, vp_y, vp_x + vp_w, vp_y + vp_h
  if st.rect then
    -- Over the child windows, around this modal and every modal of this context opened after it (above it)
    local holes = {}
    for _, other in pairs(_scrim_state) do
      if other.ctx == ctx and other.rect and other.order >= st.order then holes[#holes + 1] = other.rect end
    end
    local dl = reaper.ImGui_GetForegroundDrawList(ctx)
    reaper.ImGui_DrawList_PushClipRect(dl, x1, y1, x2, y2, false)
    -- The modal's Begin follows right after this call, under the same style: it rounds with this WindowRounding
    local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding()) or 0
    _fill_around_holes(dl, x1, y1, x2, y2, holes, P.dim_bg, rounding)
    reaper.ImGui_DrawList_PopClipRect(dl)
    return
  end
  -- Rect not known yet: the whole foreground when the modal is an OS window of its own, else the parent's draw
  -- list (behind the modal; the child windows stay bright for this frame)
  local dl = st.own_viewport and reaper.ImGui_GetForegroundDrawList(ctx) or reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x1, y1, x2, y2, false)
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, P.dim_bg)
  reaper.ImGui_DrawList_PopClipRect(dl)
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
  local draw_col = hover and (opts.hover_color or lighten(base_col, 0.25)) or base_col
  icon_fn(dl, cx, cy, hs, draw_col)
  if hover then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())   -- hovered and enabled
  end
  if opts.tooltip and _hovered_for_tooltip(ctx) then
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
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())   -- hovered and enabled
  end
  if opts.tooltip and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end
  return pressed
end

--- Renders a tooltip with automatic text wrapping.
--- Respects the global Theme.get_show_tooltips() setting.
--- Uses consistent padding from layout tokens.
---
--- @param ctx userdata  ImGui context
--- @param text string  Tooltip text content
--- @param max_w number|nil  Max wrap width (default: Theme.layout.tooltip_wrap)
function Theme.tooltip(ctx, text, max_w)
  if not Theme.get_show_tooltips() then return end
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
--- Supports optional right-aligned close/action button.
---
--- @param ctx userdata  ImGui context
--- @param label string  Section header label text
--- @param opts table|nil  Optional configuration:
---   opts.default_open (boolean)  Whether the header starts expanded (default: false)
---   opts.flags        (integer)  Additional ImGui TreeNodeFlags
---   opts.close_id     (string)   Optional ID to render an inline close/clear button on the right
---   opts.close_tooltip(string)   Tooltip for the close button (e.g. "Clear all")
---   opts.close_color  (integer)  Close icon color override (default: palette.text_dim)
---   opts.close_w      (number)   Close button width override
---   opts.close_h      (number)   Close button height override
---   opts.on_close     (function) Callback when close button is clicked
---   opts.action_fn    (function) Custom right-aligned action renderer function(ctx)
---   opts.margin       (number)   Right margin for close/action button (default: Theme.layout.sm)
--- @return boolean is_open, boolean close_clicked
function Theme.collapsing_header(ctx, label, opts)
  opts = opts or {}
  local flags = opts.flags or reaper.ImGui_TreeNodeFlags_None()
  if opts.default_open then
    flags = flags | reaper.ImGui_TreeNodeFlags_DefaultOpen()
  end
  local has_action = (opts.close_id ~= nil) or (opts.on_close ~= nil) or (opts.action_fn ~= nil)
  if has_action or opts.allow_overlap then
    local overlap_flag = (reaper.ImGui_TreeNodeFlags_AllowOverlap and reaper.ImGui_TreeNodeFlags_AllowOverlap())
                      or (reaper.ImGui_TreeNodeFlags_AllowItemOverlap and reaper.ImGui_TreeNodeFlags_AllowItemOverlap())
                      or 0
    flags = flags | overlap_flag
  end

  local cur_y = reaper.ImGui_GetCursorPosY(ctx)
  local screen_x, screen_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local P = _get_palette()
  local L = Theme.layout

  local visible_label = label:match("^(.-)##") or label
  local id = label:match("##(.+)$") or label

  local is_open = reaper.ImGui_CollapsingHeader(ctx, "##ch_" .. id, nil, flags)
  local next_y = reaper.ImGui_GetCursorPosY(ctx)

  -- Precise 8px visual gap after arrow (arrow right edge is at ~18px -> text at 26px)
  local text_offset_x = opts.text_offset or (L.md + 10 + L.md)
  local _, text_h = reaper.ImGui_CalcTextSize(ctx, visible_label)
  local text_y = screen_y + math.floor((frame_h - text_h) * 0.5)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddText(dl, screen_x + text_offset_x, text_y, P.text, visible_label)

  local close_clicked = false
  if has_action then
    local preset = opts.preset or L.icon_sm
    local btn_w = opts.close_w or (preset.size + preset.pad * 2)
    local btn_h = opts.close_h or btn_w

    reaper.ImGui_SameLine(ctx, 0, 0)
    Theme.right_align(ctx, btn_w, opts.margin or L.sm)
    reaper.ImGui_SetCursorPosY(ctx, cur_y + math.floor((frame_h - btn_h) * 0.5))

    if opts.action_fn then
      opts.action_fn(ctx)
    else
      local btn_id = opts.close_id or ("##ch_close_" .. id)
      if Theme.icon_btn(ctx, btn_id, Theme.icons.close, {
        preset = preset,
        color = opts.close_color or P.text_dim,
        tooltip = opts.close_tooltip,
      }) then
        close_clicked = true
        if opts.on_close then opts.on_close() end
      end
    end
    reaper.ImGui_SetCursorPosY(ctx, next_y)
  end

  return is_open, close_clicked
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

  if opts.tooltip and _hovered_for_tooltip(ctx) then
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
  local btn_label = string.format("%s###%s", label or "", btn_id)   -- ### hashes only the id: a changing label keeps the widget
  local pressed = reaper.ImGui_Button(ctx, btn_label, btn_w, btn_h)

  reaper.ImGui_PopStyleColor(ctx, 4)
  if pushed_font then
    Theme.pop_font(ctx, pushed_font)
  end
  if pushed_vars > 0 then
    reaper.ImGui_PopStyleVar(ctx, pushed_vars)
  end

  if opts.tooltip and _hovered_for_tooltip(ctx) then
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

  local btn_label = label .. "###badge_" .. (opts.id or label)   -- ### hashes only the id: a changing label keeps the widget

  local pressed = reaper.ImGui_Button(ctx, btn_label, btn_w, btn_h)

  reaper.ImGui_PopStyleColor(ctx, 4)
  if pushed_font then
    Theme.pop_font(ctx, pushed_font)
  end
  if pushed_vars > 0 then
    reaper.ImGui_PopStyleVar(ctx, pushed_vars)
  end

  if opts.tooltip and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  return opts.interactive and pressed or false
end

--- Shortens `text` with a trailing "..." until it fits `max_w` pixels (measured with the current font).
--- Cuts on UTF-8 character boundaries. Returns `text` itself when it already fits.
--- @param ctx userdata  ImGui context
--- @param text string  Text to fit
--- @param max_w number  Available width in pixels
--- @return string fitted, boolean clipped
local function _fit_text(ctx, text, max_w)
  if (reaper.ImGui_CalcTextSize(ctx, text)) <= max_w then return text, false end
  local ellipsis = "..."
  local lo, hi = 0, #text   -- longest prefix (in bytes) that fits with the ellipsis: binary search
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    local cut = mid
    while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end   -- never split a character
    if (reaper.ImGui_CalcTextSize(ctx, text:sub(1, cut) .. ellipsis)) <= max_w then
      lo = mid
    else
      hi = mid - 1
    end
  end
  local cut = lo
  while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return text:sub(1, cut) .. ellipsis, true
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

--- Renders a selectable item with rounded highlight corners matching the design system.
--- Replaces native square-cornered Selectables.
--- A label wider than the item is shortened with "..." inside the item and shown in full in a tooltip;
--- a label that fits is drawn exactly as before.
---
--- @param ctx userdata  ImGui context
--- @param label string  Selectable label (can include ##ID)
--- @param is_selected boolean|nil  Whether item is selected (default: false)
--- @param flags integer|nil  ImGui SelectableFlags (default: None)
--- @param w number|nil  Width (default: 0 = full available width)
--- @param h number|nil  Height (default: 0 = frame/row height)
--- @param opts table|nil  Optional overrides:
---   opts.rounding (number) Corner rounding radius (default: Theme.layout.rounding)
---   opts.bg_hover (number) Hover color (default: palette.accent_d)
---   opts.bg_sel   (number) Selected color (default: palette.accent_h)
---   opts.text_col (number) Text color override
---   opts.pad_x    (number) Left padding for text (default: Theme.layout.sm)
--- @return boolean clicked
function Theme.selectable(ctx, label, is_selected, flags, w, h, opts)
  opts = opts or {}
  local P = _get_palette()
  local L = Theme.layout
  local rounding = opts.rounding or L.rounding
  local bg_hover = opts.bg_hover or P.accent_h
  local bg_sel   = opts.bg_sel   or P.accent_d
  local sel_state = is_selected == true

  local visible_label = label:match("^(.-)##") or label
  local id = label:match("##(.+)$") or label

  -- Push transparent header colors to suppress native square highlights
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0)

  local clicked = reaper.ImGui_Selectable(ctx, "##sel_" .. id, sel_state, flags or reaper.ImGui_SelectableFlags_None(), w or 0, h or 0)
  local is_hovered = reaper.ImGui_IsItemHovered(ctx)

  reaper.ImGui_PopStyleColor(ctx, 3)

  local rx1, ry1 = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- 1. Draw rounded background highlight (using Theme.layout.rounding)
  if is_hovered or sel_state then
    local bg = sel_state and (is_hovered and P.accent or bg_sel) or bg_hover
    reaper.ImGui_DrawList_AddRectFilled(dl, rx1, ry1, rx2, ry2, bg, rounding)
  end

  -- 2. Draw text on top if visible label is non-empty
  local clipped = false
  if visible_label ~= "" then
    local text_col = opts.text_col or (sel_state and P.accent_l or P.text)
    local pad_x = opts.pad_x or L.sm
    local tw, th = reaper.ImGui_CalcTextSize(ctx, visible_label)
    local ty = ry1 + math.floor(((ry2 - ry1) - th) * 0.5)
    local shown = visible_label
    -- Text that would run past the item's right edge is cut to the item minus a padding on each side
    if tw > (rx2 - rx1) - pad_x then
      shown, clipped = _fit_text(ctx, visible_label, math.max(0, (rx2 - rx1) - pad_x * 2))
    end
    reaper.ImGui_DrawList_AddText(dl, rx1 + pad_x, ty, text_col, shown)
  end

  if clipped and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, visible_label)
  end

  return clicked
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
      if Theme.selectable(ctx, lbl, is_sel) then
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

  if opts.tooltip and _hovered_for_tooltip(ctx) then
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

      if Theme.selectable(ctx, row_label, is_sel, sel_flags) then
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

  if opts.tooltip and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  return toggled_idx, is_now_selected, changed
end

--- Centers the next ImGui window.
---
--- When `cond` is Cond_FirstUseEver (standard for main windows), it centers on the
--- REAPER main viewport (screen workspace) on initial launch, and allows ReaImGui
--- to remember window position, size, and docker state across script sessions.
--- For modal popups (default: Cond_Appearing), it centers over the currently active
--- parent window.
---
--- When `h` is 0 or nil, the window width is locked to `w` via
--- SetNextWindowSizeConstraints while height is left free to fit content.
---
--- @param ctx  userdata      ImGui context
--- @param w    number|nil    Window width in pixels (optional)
--- @param h    number|nil    Window height in pixels (0 or nil = auto-fit height)
--- @param cond number|nil    ImGui condition flag (default: Cond_Appearing; use Cond_FirstUseEver for main windows)
function Theme.center_next_window(ctx, w, h, cond)
  -- If Cond_Once was passed, map to Cond_FirstUseEver so Dear ImGui does not
  -- override the user's saved position and docking state on every script launch.
  if cond == reaper.ImGui_Cond_Once() then
    cond = reaper.ImGui_Cond_FirstUseEver()
  end
  cond = cond or reaper.ImGui_Cond_Appearing()

  local is_first_use = (cond == reaper.ImGui_Cond_FirstUseEver())
  local cx, cy
  local ok_p, wx, wy = pcall(reaper.ImGui_GetWindowPos, ctx)
  local ok_s, ww, wh = pcall(reaper.ImGui_GetWindowSize, ctx)
  -- In Dear ImGui, before any user window has begun, GetWindowPos/GetWindowSize query
  -- the internal fallback window "Debug##Default" (pos 60,112, size 400x400).
  -- A real parent window will never be this dummy fallback.
  local is_dummy = (wx == 60 and wy == 112 and ww == 400 and wh == 400)

  if not is_first_use and not is_dummy and ok_p and ok_s and ww and wh and ww > 0 and wh > 0 then
    cx = wx + ww * 0.5
    cy = wy + wh * 0.5
  else
    local vp = reaper.ImGui_GetMainViewport(ctx)
    local vp_x, vp_y = reaper.ImGui_Viewport_GetPos(vp)
    local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(vp)
    cx = vp_x + vp_w * 0.5
    cy = vp_y + vp_h * 0.5
  end

  reaper.ImGui_SetNextWindowPos(ctx, cx, cy, cond, 0.5, 0.5)
  -- Remember where a popup that appears this frame will be placed: Theme.modal_scrim() uses it to tell whether the
  -- modal gets a viewport of its own (see there). Only Cond_Appearing / Cond_Always place it there for sure.
  _next_window_rect = nil
  if w and w > 0 and (cond == reaper.ImGui_Cond_Appearing() or cond == reaper.ImGui_Cond_Always()) then
    _next_window_rect = { ctx = ctx, frame = reaper.ImGui_GetFrameCount(ctx), cx = cx, cy = cy, w = w,
                          h = (h and h > 0) and h or 0 }
  end
  if w and w > 0 then
    if h and h > 0 then
      -- Fixed width and height
      reaper.ImGui_SetNextWindowSize(ctx, w, h, cond)
    else
      -- Fixed width, auto-fit height: constrain width exactly, leave height free
      reaper.ImGui_SetNextWindowSizeConstraints(ctx, w, 0, w, 1e6)
    end
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
      if Theme.selectable(ctx, label, selected) then
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

--- Renders a standardized checkbox to toggle global tooltips on or off.
--- Reads and persists state to global ExtState automatically.
--- @param ctx userdata  ImGui context
--- @param opts table|nil  Optional overrides:
---   opts.label   (string) Checkbox label (default: "Show Tooltips")
---   opts.tooltip (string) Hover tooltip for the setting itself (optional)
--- @return boolean changed  true if the value was toggled
--- @return boolean enabled  current tooltip state
function Theme.tooltip_setting_widget(ctx, opts)
  opts = opts or {}
  local label = opts.label or "Show Tooltips##fancy_tooltips_toggle"
  local cur = Theme.get_show_tooltips()
  local changed, new_val = reaper.ImGui_Checkbox(ctx, label, cur)
  if changed then
    Theme.set_show_tooltips(new_val)
  end
  if opts.tooltip and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end
  return changed, new_val
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
      local is_drawlist_icon = false
      for _, fn in pairs(Theme.icons) do
        if fn == opts.icon_fn then
          is_drawlist_icon = true
          break
        end
      end
      if is_drawlist_icon then
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
        local cx = x + brand_sz * 0.5
        local cy = y + hdr_h * 0.5
        opts.icon_fn(dl, cx, cy, brand_sz * 0.45, opts.icon_color or P.accent)
        reaper.ImGui_Dummy(ctx, brand_sz, hdr_h)
      else
        opts.icon_fn(ctx, brand_sz, hdr_h)
      end
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


