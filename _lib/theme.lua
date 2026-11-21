-- @noindex
-- Fancy Scripts -- Design System & Theme Engine
-- Single source of truth for ALL visual decisions. local Theme = require("theme")
--
-- =============================================================================
-- API QUICK REFERENCE
-- =============================================================================
--
-- PALETTE -- Theme.build_palette([overrides]) / Theme.get_palette() returns table with:
--   Look:       Fancy = the Reaper Tips look, fixed values (greys, blue accent). Match Theme = surfaces, text and
--               accent read from the active REAPER theme; every role below is derived and contrast-fitted.
--   Surfaces:   bg, panel, card               (window, popups / raised strips, cards / table header)
--   Text:       text, text_dim                (primary, secondary; both fitted to 4.5:1 on the surfaces and control faces)
--               text_dim is fitted for bg, panel, card, btn, well; on hover, pressed and tab faces use `text`
--               (Match Theme caps the btn_h / tab / tab_h / tab_sel / hover steps so `text` keeps 4.5:1 on them)
--   Accent:     accent      = active state    (CheckMark, TabSelectedOverline, selection bar, toggle-on face)
--               accent_h    = hover  (40%)    (SeparatorHovered)
--               accent_d    = dim    (20%)    (kept for scripts; the style stack no longer tints resting controls)
--               accent_e    = subtle (12.5%)  (kept for scripts)
--               accent_l    = light  (70%)    (High-contrast text on badges/active toggles)
--   Secondary:  accent2 / blue = a soft violet in Fancy (secondary accent, info, badge highlights; blue* are aliases)
--               accent2_h / blue_h = hover (40%)
--               accent2_d / blue_d = dim   (20%)
--               accent2_e / blue_e = subtle (12.5%)
--               accent2_l / blue_l = light (70%) (High-contrast text on badges/info)
--   Semantic:   green/green_h/green_d/green_l (success, enabled, positive)
--               red/red_h/red_d/red_l         (error, delete, destructive)
--               yellow/yellow_l               (warning, caution)
--   Structure:  border, sep, dim_bg           (border = control outline, same value as outline in Fancy; sep = neutral
--                                              hairline, no accent tint; dim_bg = modal overlay)
--   Table:      table_row, table_row_alt      (alternating row backgrounds; kept for scripts, the style stack uses bg)
--   Controls:   btn / btn_h / btn_a           resting / hovered / pressed face of buttons, combos, inactive toggles
--               btn_on, on_text               face of an active toggle, and its label (fitted to 4.5:1)
--               outline                       1 px frame around controls
--               well, well_h, well_a          recessed inputs, slider grooves, checkbox boxes, progress track
--               thumb, thumb_a                slider grab, and while dragged (slider_grab_active is kept)
--               tab, tab_h, tab_sel           tab faces (the selected tab also has an accent line on top, drawn
--                                             when the tab bar passes TabBarFlags_DrawSelectedOverline)
--               hover, select                 hovered / selected row of a selectable or menu item (select = accent at 25%)
--               scroll, scroll_h, scroll_a    scrollbar grab: 17 / 26 / 35% (white in Fancy, text colour in Match Theme)
--               title                         title bar and docked header strip
--   Canvas:     canvas = { row*, grid*, gutter_*, key_*, note_*, zone_*, span_*, handle*, trace, preview, overview_*, view_*, ... }
--               Colours for custom-drawn editors (piano roll, notes, curves, pills). Fixed in Fancy,
--               derived and contrast-fitted (text >= 4.5:1, boundaries >= 3:1) in Match Theme. See section 4A.
--   Helpers:    Theme.with_alpha(rgba, a) / .lighten(rgba, f) / .darken(rgba, f) / .bgr_to_rgba(bgr)
--               Theme.label_on(fill) -> a dark or light label colour that reads on fill (4.5:1)
--
-- CONTRAST RULE (docs/design/README.md, "Contrast")
--   Text and labels: 4.5:1 always, in both modes.
--   Meaningful state (toggle on, focus, slider thumb, check mark, playhead, note borders, the selection bar of library
--   rows): 3:1 against what it sits on.
--   The resting outline and face of a labelled control follow the theme, no minimum (outline is about 1.4:1 on bg).
--   The select tint of rows is exempt from 3:1; library rows add a 2 px accent bar that carries it.
--
-- THEME MODES & PREFS -- Theme.get_mode() / .set_mode(mode) / .invalidate_palette()
--   MODE_FANCY="fancy"  Curated Reaper Tips look (label "Fancy")
--   MODE_MATCH="match"  Everything from REAPER theme (including edit cursor accent) (label "Match Theme")
--   Theme.mode_labels   = { "Fancy", "Match Theme" } (settings combo labels, in mode order)
--   Theme.get_show_tooltips() / .set_show_tooltips(bool) Global tooltip visibility
--
-- LAYOUT TOKENS -- Theme.layout.*
--   Scale:      xs=2  sm=4  md=8  lg=12  xl=16  xxl=24  xxxl=32 (unified scale)
--   Rounding:   rounding=xs (2) (universal: windows, frames, grabs, drawlist)
--   Table:      row_h=xxl (24)  chk_col_w=xxl (24)  indent=xxxl (32)
--   Modals:     modal_sm/md/lg/xl = {w, h}
--   Misc:       tooltip_wrap=300  section_gap=sm (4)
--
-- BUTTON PRESETS -- height flows from font + padding (no hardcoded heights)
--   btn_sm = {pad_x=sm, pad_y=xs, font="small", h=15}   Push FramePadding + font
--   btn_default = global FramePadding (md,sm) (h=21)    No override needed
--   btn_lg = {pad_x=lg, pad_y=sm, font="medium", h=22}  Push FramePadding + font
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
-- ICONS -- Theme.icons.<name>(dl, cx, cy, half_size, color), vector shapes for the draw list:
--   play pause close plus info tri_down tri_up tri_left tri_right slider gear check dot ring
--
-- FONTS -- Theme.font_sizes: small=11 default=13 medium=14 large=16 header=18  (Fira Sans, bundled in _lib/fonts/)
--   create_fonts(ctx)          -> {default,small,medium,large,header,default_bold,medium_bold,large_bold}
--   attach_fonts(ctx, fonts)   -> call once before first frame
--   push_font(ctx, font, [sz]) -> bool (safe pcall, auto-resolves size from registry)
--   pop_font(ctx, pushed)      -> conditional pop
--   fonts.tooltip = fonts.default (backward-compat alias)
--   Font source: _lib/fonts/FiraSans-Regular.otf and -Bold.otf (SIL OFL 1.1, fonts/OFL.txt); if a file cannot be
--   loaded, an installed "Fira Sans", then the system sans-serif. Theme.font_source = "file" | "family" | "system".
--
-- STYLE -- Theme.push(ctx, [palette]) -> nc, nv / Theme.pop(ctx, [nc], [nv])
--   Counts are returned, not fixed: pass them to pop (no counts = those of the last push).
--   Colors: Button*3 btn / btn_h / btn_a, FrameBg*3 well (+ a step each), SliderGrab*2 thumb / thumb_a,
--           CheckMark accent, Header select / hover / stronger select, Tab* tab / tab_h / tab_sel (skipped on
--           ReaImGui without them), Scrollbar* scroll (bg transparent), TitleBg*2 title, PopupBg panel,
--           Border outline, Separator sep (hovered / active keep the accent), Table* sep / bg / card,
--           Text, TextDisabled
--   Vars:   Window/Frame/GrabRounding (2), ItemSpacing (4,4), FramePadding (8,4), WindowPadding (8,8),
--           CellPadding, ItemInnerSpacing, IndentSpacing, FrameBorderSize (1)
--
-- WIDGETS -- toggle_button: off = btn face, on = solid btn_on with on_text. badge: quiet well tag; with opts.color a
--   solid fill and a fitted label. combo / multi_combo: preview is a button face. icon_btn: transparent at rest.
--   selectable: hover / select tint plus a 2 px accent bar on the left of a selected row.

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

-- Widget colour fits (hover / pressed shades, icon colours), kept so a widget does not search for contrast on
-- every frame. Keyed by every colour that enters the computation (never by a palette table alone), so a palette
-- built with overrides cannot be served another palette's entry. Cleared by set_mode and invalidate_palette,
-- and when it grows past _FIT_CACHE_MAX entries (a script that animates colours).
local _fit_cache, _fit_cache_n = {}, 0
local _FIT_CACHE_MAX = 1024

local function _fit_cache_clear()
  _fit_cache, _fit_cache_n = {}, 0
end

--- Cached value for the keys (kind, a, b, c, d, e), or nil.
local function _fit_cache_get(kind, a, b, c, d, e)
  local t = _fit_cache[kind]
  t = t and t[a]; t = t and t[b]; t = t and t[c]; t = t and t[d]
  return t and t[e]
end

--- Stores `v` under the keys (kind, a, b, c, d, e) and returns it.
local function _fit_cache_put(v, kind, a, b, c, d, e)
  if _fit_cache_n >= _FIT_CACHE_MAX then _fit_cache_clear() end
  local t = _fit_cache
  for _, k in ipairs({ kind, a, b, c, d }) do
    local n = t[k]
    if not n then n = {}; t[k] = n end
    t = n
  end
  t[e] = v
  _fit_cache_n = _fit_cache_n + 1
  return v
end

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
  _fit_cache_clear()
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
  _fit_cache_clear()
end

-------------------------------------------------------------------------------
-- 3. CURATED FANCY PALETTE (BASE COLORS)
-------------------------------------------------------------------------------
local FANCY_PALETTE = {
  -- Base surfaces
  bg       = 0x323232FF,
  panel    = 0x3E3E3EFF,
  card     = 0x424242FF,

  -- Text (text_dim starts here and is fitted to 4.5:1 on the surfaces by build_palette)
  text     = 0xD9D9D9FF,
  text_dim = 0xA0A0A0FF,

  -- Accent (primary blue)
  accent   = 0x46B9FEFF,

  -- Accent (secondary violet; the blue* fields are aliases)
  accent2  = 0xA990F5FF,

  -- Semantic base colors
  green    = 0x44CD8CFF,
  red      = 0xE45E65FF,
  yellow   = 0xFEC13AFF,
  blue     = 0xA990F5FF,

  -- Structural base
  border   = 0x181818FF,
  sep      = 0x1D1D1DFF,

  -- Control roles
  btn      = 0x454545FF,  -- resting face of buttons, combos, inactive toggles
  btn_h    = 0x585858FF,  -- hovered face
  btn_a    = 0x2E2E2EFF,  -- pressed face
  on_text  = 0x0F2B3BFF,  -- label on the "on" face (fitted)
  outline  = 0x181818FF,  -- 1 px control frame
  well     = 0x2A2A2AFF,  -- recessed inputs, slider grooves, checkbox boxes
  thumb    = 0xC2C2C2FF,  -- slider grab
  thumb_a  = 0xD9D9D9FF,  -- slider grab while dragged
  tab      = 0x383838FF,
  tab_h    = 0x4D4D4DFF,
  tab_sel  = 0x585858FF,
  hover    = 0x4D4D4DFF,  -- hovered selectable / menu row
  scroll   = 0xFFFFFF2B,  -- scrollbar grab: white at 17 %
  scroll_h = 0xFFFFFF42,  -- 26 %
  scroll_a = 0xFFFFFF59,  -- 35 %
  title    = 0x2D2D2DFF,  -- title bar, docked header strip
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
--- Colours for custom-drawn editor canvases (piano-roll rows and grid, the note-name column, piano keys and their
--- labels, note blocks, zone highlights, trim handles, curves and markers, marquee, playhead, pills, ruler, the
--- overview / range strips, scrim). Built by
--- Theme.build_palette() into P.canvas for both modes:
---   Fancy        fixed values, plus the ones that are a palette colour, a shade or an alpha of it (noted per
---                token). Notes are solid blocks in the accent colour (green once edited); the rows are one quiet
---                surface, so the notes are the first thing the eye lands on.
---   Match Theme  derived from P.bg / P.panel / P.text / P.accent / P.green / P.blue / P.yellow so the canvas
---                follows a dark or a light REAPER theme. Every text token is fitted to >= 4.5:1 and every object
---                boundary to >= 3:1 (WCAG 2.x, alpha composited first) against the surfaces it is drawn on.
---                The curves and markers (trace, playhead, trend, anchor, spot, preview, marker_split) are fitted
---                against the persistent surfaces they are drawn on: the rows, every note fill over the rows, the vibrato
---                wash (and the ruler strip for the playhead), moved toward white or black only as far as that takes so
---                each keeps its hue; the transient zone highlights (Shift-hover, drag) are not part of the fit. The
---                BYPASSED badge (bypass_title, bypass_border) is fitted against the card and the dimmed canvas.
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

--- Fancy (curated) canvas values, modelled on the Reapertips MIDI editor: recessed grey rows, #1D1D1D
--- hairlines, a #333333 note column and ruler. Literal tokens are the colours Pitch Correct drew with hex literals; the ones
--- built from P are exactly the palette colour (or an alpha of it) the script used next to them.
local function build_canvas_fancy(P)
  local C = {}
  -- Rows (what a note sits on). row* = in the scale, row_tonic = the key's root, row_dim* = out of the scale,
  -- row_plain* = no scale chosen (Chromatic). *_black = the row of a black piano key.
  -- The steps between them are small on purpose: the rows are a background, the notes carry the picture.
  C.row             = 0x2E2E2EFF
  C.row_black       = 0x2B2B2BFF
  C.row_tonic       = 0x2E2E2EFF
  C.row_dim         = 0x282828FF
  C.row_dim_black   = 0x262626FF
  C.row_plain       = 0x2E2E2EFF
  C.row_plain_black = 0x2A2A2AFF
  -- Accent tints drawn over the in-scale / root rows (follow P.accent)
  C.row_tint        = with_alpha(P.accent, 0.03)
  C.row_tonic_tint  = with_alpha(P.accent, 0.10)
  -- Grid lines between rows: hairlines in the text colour, the root row's in the accent
  C.grid            = with_alpha(P.text, 0.05)
  C.grid_tonic      = with_alpha(P.accent, 0.25)
  C.grid_dim        = 0x1D1D1DFF
  C.grid_plain      = 0x1D1D1DFF
  C.grid_plain_black = 0x1D1D1DFF
  -- Note-name column (a flat strip left of the rows): labels >= 4.5:1 on gutter_bg, the root row's strip >= 3:1
  C.gutter_bg         = 0x333333FF
  C.gutter_text       = 0xC8C8C8FF
  C.gutter_text_dim   = P.text_dim
  C.gutter_text_tonic = P.accent_l
  C.gutter_strip      = P.accent
  -- Piano keys (fixed in both modes: a piano does not change colour with the REAPER theme)
  C.key_white       = 0xBABABAFF
  C.key_black       = 0x282828FF
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
  -- Note blocks: near-opaque shades of the accent (untouched) and of green (edited), dark enough for P.text to
  -- read on them (>= 4.5:1 on every row; the light blue accent needs a deeper shade than green). The border is
  -- the note's own hue (>= 3:1 on every row). A selected block is a brighter shade inside a light border
  -- (#EDEDED, >= 3:1 on every row), so the selection does not rest on the fill alone. note_wave is the
  -- amplitude envelope drawn inside a block.
  C.note_fill            = with_alpha(darken(P.accent, 0.58), 0.92)
  C.note_border          = P.accent
  C.note_edited          = with_alpha(darken(P.green, 0.50), 0.92)
  C.note_edited_border   = P.green
  C.note_selected        = with_alpha(darken(P.accent, 0.48), 0.96)
  C.note_selected_edited = with_alpha(darken(P.green, 0.48), 0.96)
  C.note_selected_border = 0xEDEDEDFF
  C.note_bypassed        = 0x2A2A2A55
  C.note_bypassed_border = 0x555555AA
  C.note_label           = P.text
  C.note_label_selected  = P.text
  C.note_label_edited    = P.text
  C.note_edit_mark       = P.text
  C.note_wave            = with_alpha(P.text, 0.22)
  -- Zone highlights and trim handles (over a note block)
  C.zone_drift      = with_alpha(P.blue, 0.267)
  C.zone_shift      = 0xFFAA4444
  C.zone_divider    = with_alpha(P.text, 0.20)
  -- Setting highlights (where a timing value acts, shown while it is hovered or dragged): a wash of the Shift
  -- zone's hue with an opaque edge; the edge is also the outline of a note a value reaches
  C.span_fill       = 0xFFAA4428
  C.span_edge       = 0xFFAA44FF
  C.handle          = with_alpha(P.text, 0.80)
  C.handle_hover    = P.text
  C.handle_drag     = P.yellow   -- not the accent: the blocks are accent-coloured
  -- Curves, markers, selection, playhead. The trace and the playhead are the text colour (the blocks own the
  -- accent); the preview is a light green that reads on the edited (green) block it is drawn over.
  C.trace           = with_alpha(P.text, 0.90)
  C.trace_note      = with_alpha(P.text, 0.55)   -- the trace under a note block: behind the preview
  C.trace_far       = with_alpha(P.text, 0.08)   -- the trace between notes: context only
  C.preview         = lighten(P.green, 0.15)
  C.vibrato         = 0xFFAA4418
  C.trend           = 0x00FFFFFF
  C.spot            = 0xFFFF00FF
  C.anchor          = 0x00FFFFFF
  C.marker_split      = with_alpha(P.blue, 0.67)
  C.marker_split_text = P.blue_l
  C.marquee_fill    = with_alpha(P.accent, 0.18)
  C.marquee_border  = with_alpha(P.accent, 0.85)
  C.marquee_text    = P.accent_l
  C.playhead        = P.text
  -- Overview strip (every note, small, under the rows) and range strip (beside them): the track, the notes on
  -- it, and the thumb that marks the visible window (fill, border and end grips)
  C.overview_bg     = P.inset or P.well   -- the recessed surface of secondary bars and side panels
  C.overview_note   = P.accent
  C.view_fill       = with_alpha(P.accent, 0.16)
  C.view_border     = P.accent
  C.view_grip       = P.accent_l
  -- Overlays: pills (readouts, zone names), ruler strip, scrim
  C.pill_bg         = with_alpha(P.panel, 0.90)
  C.pill_text       = P.text
  C.ruler_bg        = with_alpha(0x333333FF, 0.90)   -- the note column's #333333, as the theme's MIDI ruler
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
--- zone_divider, marquee_fill, marquee_border, view_fill, pill_bg, scrim).
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
  C.row             = toward(bg, 0.045 * k)   -- in scale, white key
  C.row_black       = toward(bg, 0.035 * k)   -- in scale, black key
  C.row_tonic       = toward(bg, 0.05 * k)    -- the key's root (plus the accent tint)
  C.row_dim         = bg                      -- out of scale: the window background
  C.row_dim_black   = away(bg, 0.04 * k)      -- out of scale, black key
  C.row_plain       = toward(bg, 0.04 * k)    -- no scale chosen, white key
  C.row_plain_black = toward(bg, 0.02 * k)    -- no scale chosen, black key
  C.grid_dim        = toward(bg, 0.05)        -- grid lines: fixed steps toward the text colour
  C.grid_plain      = toward(bg, 0.14)
  C.grid_plain_black = toward(bg, 0.07)

  -- The rows as they show (accent tint included): every other token is fitted against these
  local rows = {
    composite_over(C.row_tint, C.row), composite_over(C.row_tint, C.row_black),
    composite_over(C.row_tonic_tint, C.row_tonic), C.row_dim, C.row_dim_black, C.row_plain, C.row_plain_black,
  }
  local row_ends = add_ends({}, rows)

  -- Keys: the fixed colours of build_canvas_fancy, plus the tokens that follow the palette
  local key_tonics = { C.key_tonic_white, C.key_tonic_black }
  C.key_tonic_strip      = fit_contrast(P.accent, key_tonics, 3.0)                   -- accent, >= 3:1 on both root keys
  C.key_text_tonic_black = fit_contrast(P.accent_l, { C.key_tonic_black }, 4.5)      -- accent_l, >= 4.5:1 on the root black key
  C.key_text_dim_white   = fit_contrast(P.text, { C.key_dim_white }, 4.5)            -- text, >= 4.5:1 on the dimmed white key
  C.key_text_dim_black   = fit_contrast(P.text, { C.key_dim_black }, 4.5)            -- text, >= 4.5:1 on the dimmed black key

  -- Note-name column: the panel colour; its labels fitted to >= 4.5:1 and the root row's strip to >= 3:1 on it
  C.gutter_bg         = P.panel                                                      -- the curated #333333 does not follow a theme
  C.ruler_bg          = with_alpha(P.panel, 0.90)                                    -- the time ruler: the same panel colour
  local gutter = { C.gutter_bg }
  C.gutter_text       = fit_contrast(with_alpha(P.text, 0.80), gutter, 4.5)          -- in-scale row name
  C.gutter_text_dim   = fit_contrast(P.text_dim, gutter, 4.5)                        -- out-of-scale row name
  C.gutter_text_tonic = fit_contrast(P.accent_l, gutter, 4.5)                        -- the root row's name
  C.gutter_strip      = fit_contrast(P.accent, gutter, 3.0)                          -- the root row's strip

  -- Note blocks: near-opaque shades of the accent (untouched, selected) and of green (edited) moved "away" from
  -- the text colour (darker on a dark theme, lighter on a light one), so a label can always read on them; borders
  -- are the palette hue fitted to >= 3:1 on every row
  C.note_fill            = with_alpha(away(P.accent, 0.28), 0.92)  -- untouched note: a shade of the accent
  C.note_edited          = with_alpha(away(P.green, 0.50), 0.92)   -- edited note: a shade of green
  C.note_selected        = with_alpha(away(P.accent, 0.15), 0.96)  -- selected note: closer to the accent
  C.note_selected_edited = with_alpha(away(P.green, 0.45), 0.96)   -- selected edited note
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
  C.note_border          = fit_contrast(P.accent, rows, 3.0)      -- accent, >= 3:1 on every row
  C.note_edited_border   = fit_contrast(P.green, rows, 3.0)       -- green, >= 3:1 on every row
  -- The selection border is the text colour, fitted to >= 3:1 on every row and on both selected fills
  C.note_selected_border = fit_contrast(P.text,
    concat_lists(rows, over_each({ C.note_selected, C.note_selected_edited }, row_ends)), 3.0, rows)
  C.note_wave            = with_alpha(ink, 0.22)                  -- the amplitude envelope inside a block (decoration)

  -- Labels on the block fills as they show over the rows (>= 4.5:1)
  local plain_fills    = over_each({ C.note_fill, C.note_bypassed }, row_ends)
  local selected_fills = over_each({ C.note_selected }, row_ends)
  local edited_fills   = over_each({ C.note_edited, C.note_selected_edited }, row_ends)
  C.note_label          = fit_contrast(with_alpha(P.text, 0.867), plain_fills, 4.5)   -- text (87 % alpha), untouched / bypassed fills
  C.note_label_selected = fit_contrast(P.text, selected_fills, 4.5)                   -- text on the selected fill
  C.note_label_edited   = fit_contrast(P.text, edited_fills, 4.5)                     -- text on both edited fills
  C.note_edit_mark      = fit_contrast(P.text, edited_fills, 3.0)                     -- the corner square: >= 3:1 on both edited fills

  -- Zone highlights: violet (P.blue, the secondary accent) for the drift zone (as in Fancy), yellow for the vibrato zone and while Shift is held
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
  C.handle_drag  = fit_contrast(P.yellow, edge_on, 3.0)                          -- yellow while the edge is dragged (the blocks are accent-coloured)

  -- Curves and markers are drawn straight on a row or on a note block, and the vibrato wash goes over all of that: each
  -- palette hue is fitted to >= 3:1 on every one of those persistent surfaces (and the playhead also on the ruler strip),
  -- moved toward white or black as little as that takes, so it keeps its hue and the layers stay apart by colour. The
  -- zone highlights (zone_drift, zone_shift) are NOT part of the fit: they show only while the pointer is over a block,
  -- and making every curve clear the brightest of them would turn the curves into near-white. A surface set this wide can
  -- still leave no colour that reaches 3:1 (a mid-grey theme): then the best worst case wins, with the rows held at 3:1
  -- first; the vibrato band itself is decoration.
  C.vibrato = with_alpha(P.yellow, 0.094)                               -- vibrato band: a faint yellow wash
  local blocks   = over_each({ C.note_fill, C.note_edited, C.note_selected, C.note_selected_edited, C.note_bypassed }, rows)
  local shown    = concat_lists(rows, blocks)                           -- rows and note blocks (no wash): split markers and their label
  -- Setting highlights: a yellow wash (decoration, like the vibrato band) inside a yellow edge fitted on rows and blocks
  C.span_fill = with_alpha(P.yellow, 0.16)
  C.span_edge = fit_contrast(P.yellow, shown, 3.0, rows, true)
  local curve_on = concat_lists(shown, over_each({ C.vibrato }, shown)) -- ... and the wash over those: every persistent surface
  local line_on  = concat_lists(curve_on, over_each({ C.ruler_bg }, rows))    -- the playhead also crosses the ruler strip
  C.trace      = fit_contrast(with_alpha(P.text, 0.90), line_on, 3.0, rows, true)   -- raw pitch trace: text colour (90 % alpha)
  C.playhead   = fit_contrast(P.text, line_on, 3.0, rows, true)                  -- the playhead line: text colour
  -- The trace steps back where the preview matters: dimmer under a note block, faint between notes (a reference
  -- layer, deliberately under 3:1; the legend and the full-strength swatch use C.trace)
  C.trace_note = with_alpha(C.trace, 0.55)
  C.trace_far  = with_alpha(C.trace, 0.08)
  C.preview    = fit_contrast(toward(P.green, 0.15), curve_on, 3.0, rows, true)   -- corrected-pitch preview: opaque, as saturated a green as 3:1 allows
  C.trend      = fit_contrast(C.trend, curve_on, 3.0, rows, true)                -- trend line: the Fancy cyan (apart from marker_split's violet)
  C.anchor     = C.trend                                                         -- trend anchor diamond: same as the trend
  C.spot       = fit_contrast(P.yellow, curve_on, 3.0, rows, true)               -- smart-spot circle: yellow
  -- Split markers are drawn before the wash: the line on rows and blocks, its label on rows and blocks
  C.marker_split      = fit_contrast(with_alpha(P.blue, 0.67), shown, 3.0, rows, true)   -- split-point line: blue (67 % alpha)
  C.marker_split_text = fit_contrast(P.blue_l, shown, 4.5, rows)                    -- split-point label: blue_l, >= 4.5:1

  -- Overview and range strips: a track a step away from the background; the notes on it, the thumb's border and
  -- its grips are fitted to >= 3:1 on the track, with and without the thumb's own fill over it
  C.overview_bg   = P.inset or away(bg, 0.25)   -- the recessed surface a side panel beside the canvas also uses
  local track     = { C.overview_bg, composite_over(C.view_fill, C.overview_bg) }
  C.overview_note = fit_contrast(P.accent, track, 3.0)
  C.view_border   = fit_contrast(P.accent, track, 3.0)
  C.view_grip     = fit_contrast(P.accent_l, track, 3.0)

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
    C = build_canvas_fancy(P)
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
  local F = FANCY_PALETTE
  local fancy = mode == Theme.MODE_FANCY

  -- Surfaces, accent and the control faces the text has to read on
  if fancy then
    P.bg     = overrides.bg     or F.bg
    P.panel  = overrides.panel  or F.panel
    P.card   = overrides.card   or F.card
    P.accent = overrides.accent or F.accent
    P.btn    = overrides.btn    or F.btn
    P.well   = overrides.well   or F.well
  else
    -- Everything from the REAPER theme (surfaces, accent from the edit cursor, control faces)
    P.bg     = overrides.bg     or read_theme_color("col_main_bg2",    F.bg)
    P.panel  = overrides.panel  or read_theme_color("col_tr1_bg",      F.panel)
    P.card   = overrides.card   or read_theme_color("col_tr2_bg",      F.card)
    P.btn    = overrides.btn    or read_theme_color("col_buttonbg",    F.btn)
    P.well   = overrides.well   or read_theme_color("col_main_editbk", F.well)
    -- The edit cursor colour, fitted to 3:1 on the surfaces and the well (check mark, selection bar), keeping
    -- its hue, before anything is derived from it. An overridden accent is used as given.
    P.accent = overrides.accent or fit_contrast(read_theme_color("col_cursor", F.accent),
      { P.bg, P.panel, P.card, P.well }, 3.0, nil, true)
  end
  P.select = overrides.select or with_alpha(P.accent, 0.25)

  -- Text is fitted (4.5:1) on the three surfaces, the control face, the well and a selected row (the select
  -- tint over each surface); text_dim on the surfaces and faces. A curated, un-overridden text already reaches it.
  local base_surfaces = { P.bg, P.panel, P.card }
  local faces = { P.bg, P.panel, P.card, P.btn, P.well }      -- text_dim: the surfaces and control faces
  local surfaces = { P.bg, P.panel, P.card, P.btn, P.well }   -- text: those plus a selected row
  for _, s in ipairs(base_surfaces) do surfaces[#surfaces + 1] = composite_over(P.select, s) end
  if fancy then
    P.text     = overrides.text     or F.text
    P.text_dim = overrides.text_dim or fit_contrast(F.text_dim, faces, 4.5)
    P.border   = overrides.border   or F.border
  else
    -- Of the theme's two text colours the one with more contrast on bg starts text, the other text_dim
    local t1 = read_theme_color("col_main_text", F.text)
    local t2 = read_theme_color("col_tcp_text", F.text_dim)
    if contrast_over(t2, P.bg) > contrast_over(t1, P.bg) then t1, t2 = t2, t1 end
    P.text     = overrides.text     or fit_contrast(t1, surfaces, 4.5)
    P.text_dim = overrides.text_dim or fit_contrast(t2, faces, 4.5)
    P.border   = overrides.border   or fit_contrast(read_theme_color("col_main_3dhl", F.border), base_surfaces, 3.0)
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

  -- accent_press = the accent moved toward white/black only as far as P.text needs to read on it (4.5:1).
  -- Kept for scripts; the style stack does not use it (ButtonActive is btn_a).
  P.accent_press = overrides.accent_press or fit_contrast(P.accent, { P.text }, 4.5)

  -- Derive accent states from the resolved primary accent color
  -- accent_h = Hover state (40% alpha): SeparatorHovered in the style stack; also kept for scripts
  P.accent_h = overrides.accent_h or with_alpha(P.accent, 0.40)
  -- accent_d = Dim state (20% alpha): kept for scripts; the style stack no longer tints resting controls
  P.accent_d = overrides.accent_d or with_alpha(P.accent, 0.20)
  -- accent_e = Extra-dim (12.5% alpha): kept for scripts (TableBorderLight is the neutral sep)
  P.accent_e = overrides.accent_e or with_alpha(P.accent, 0.125)

  -- High-contrast text states (lightened 70% toward white for badges, active states, and dense grids)
  P.accent_l  = overrides.accent_l  or lighten(P.accent, 0.70)
  P.accent2_l = overrides.accent2_l or overrides.blue_l or lighten(P.accent2, 0.70)
  P.blue_l    = P.accent2_l
  P.green_l   = overrides.green_l   or lighten(P.green, 0.70)
  P.red_l     = overrides.red_l     or lighten(P.red, 0.70)
  P.yellow_l  = overrides.yellow_l  or lighten(P.yellow, 0.70)

  -- Derive structural colors
  -- sep = hairline (Separator): a fixed grey in the curated mode, a step darker than the window in Match Theme
  local sep_default = F.sep
  if not fancy then sep_default = darken(P.bg, luminance(P.bg) > 0.179 and 0.12 or 0.42) end
  P.sep    = overrides.sep    or sep_default
  -- dim_bg = Modal overlay background (85% darkened bg): ModalWindowDimBg
  P.dim_bg = overrides.dim_bg or with_alpha(darken(P.bg, 0.70), 0.85)

  -- Derive table row colors from panel/card
  -- table_row = Default row bg (darkened panel): kept for scripts (TableRowBg is bg)
  P.table_row     = overrides.table_row     or darken(P.panel, 0.10)
  -- table_row_alt = Alternating row bg (panel): kept for scripts (TableRowBgAlt is bg a step lighter)
  P.table_row_alt = overrides.table_row_alt or P.panel

  -- slider_grab_active = Lighter accent: kept for scripts (SliderGrabActive is thumb_a)
  P.slider_grab_active = overrides.slider_grab_active or lighten(P.accent, 0.15)

  -- inset = a recessed surface a step darker than the window: secondary bars and side panels (well is for inputs)
  P.inset = overrides.inset or darken(P.bg, 0.18)

  -- Control roles (see the design spec, section 2)
  local dark_text = luminance(P.text) > 0.179          -- light text on a dark theme: "toward text" is lighter
  local function toward(c, f) return dark_text and lighten(c, f) or darken(c, f) end
  local function away(c, f) return dark_text and darken(c, f) or lighten(c, f) end
  -- Match Theme: bg darkened, unfitted (the resting frame has no minimum): 52 % on a dark theme, 18 % on a light
  -- one. Always darker than the window, so on a light theme whose well is as white as the window the frame
  -- still shows where checkboxes, empty inputs, slider grooves and progress tracks are.
  P.outline = overrides.outline or (fancy and F.outline or darken(P.bg, dark_text and 0.52 or 0.18))
  P.btn_on  = overrides.btn_on  or (fancy and P.accent or fit_contrast(P.accent, { P.btn }, 3.0))
  -- on_text: the dark label colour on btn_on, or white / black when that cannot reach 4.5:1
  local on_text = fit_contrast(F.on_text, { P.btn_on }, 4.5)
  if contrast_over(on_text, P.btn_on) < 4.5 then
    on_text = contrast_over(0xFFFFFFFF, P.btn_on) >= contrast_over(0x000000FF, P.btn_on) and 0xFFFFFFFF or 0x000000FF
  end
  P.on_text = overrides.on_text or on_text
  P.well_h  = overrides.well_h  or lighten(P.well, 0.06)
  P.well_a  = overrides.well_a  or lighten(P.well, 0.12)
  if fancy then
    P.btn_h    = overrides.btn_h    or F.btn_h
    P.btn_a    = overrides.btn_a    or F.btn_a
    P.thumb    = overrides.thumb    or F.thumb
    P.thumb_a  = overrides.thumb_a  or F.thumb_a
    P.tab      = overrides.tab      or F.tab
    P.tab_h    = overrides.tab_h    or F.tab_h
    P.tab_sel  = overrides.tab_sel  or F.tab_sel
    P.hover    = overrides.hover    or F.hover
    P.scroll   = overrides.scroll   or F.scroll
    P.scroll_h = overrides.scroll_h or F.scroll_h
    P.scroll_a = overrides.scroll_a or F.scroll_a
    P.title    = overrides.title    or F.title
  else
    -- Steps of the same size as the curated ones, toward / away from the text colour. A step toward the text
    -- colour lowers the label's contrast, so each is capped where P.text would fall under 4.5:1 on the face
    -- (P.text itself is not changed). The tab faces keep their order (tab < tab_h < tab_sel) when the
    -- selected tab's step is capped.
    local text_need = 4.5 + FIT_MARGIN
    local function capped(base, f)
      local s = f
      while s > 0 and contrast_over(P.text, toward(base, s)) < text_need do s = s - 0.005 end
      return math.max(0, s)
    end
    local sel_step = capped(P.bg, 0.23)
    local h_step   = math.min(capped(P.bg, 0.16), math.max(0, sel_step - 0.07))
    local tab_step = math.min(0.04, math.max(0, h_step - 0.05))
    P.btn_h    = overrides.btn_h    or toward(P.btn, capped(P.btn, 0.13))
    P.btn_a    = overrides.btn_a    or away(P.btn, 0.33)
    P.thumb    = overrides.thumb    or fit_contrast(toward(P.well, 0.75), { P.well }, 3.0)
    P.thumb_a  = overrides.thumb_a  or P.text
    P.tab      = overrides.tab      or toward(P.bg, tab_step)
    P.tab_h    = overrides.tab_h    or toward(P.bg, h_step)
    P.tab_sel  = overrides.tab_sel  or toward(P.bg, sel_step)
    P.hover    = overrides.hover    or toward(P.bg, capped(P.bg, 0.16))
    P.scroll   = overrides.scroll   or with_alpha(P.text, 0.17)
    P.scroll_h = overrides.scroll_h or with_alpha(P.text, 0.26)
    P.scroll_a = overrides.scroll_a or with_alpha(P.text, 0.35)
    P.title    = overrides.title    or read_theme_color("docker_bg", F.title)
  end

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
  sm   = S.sm,    -- small: item spacing, related items, inner spacing, frame padding Y, section gap
  md   = S.md,    -- standard: window padding, frame padding X, tooltips
  lg   = S.lg,    -- large: group breaks
  xl   = S.xl,    -- extra: major sections, modal padding
  xxl  = S.xxl,   -- 2x: table row height, checkbox column
  xxxl = S.xxxl,  -- 3x: tree/hierarchy indent

  -- ── Rounding ───────────────────────────────────────────────────────────
  rounding     = S.xs,  -- universal corner radius (windows, frames, grabs, drawlist)
  border       = 1,     -- hairline border width (FrameBorderSize); colour is P.outline (no contrast minimum)

  -- ── Button size presets ─────────────────────────────────────────────────
  -- Height flows from font + padding. Default uses global FramePadding (md, sm).
  -- Pass opts.preset (or use push_button_preset) for sm/lg variants.
  btn_sm       = { pad_x = S.sm, pad_y = S.xs, font = "small",   h = 15 },
  btn_default  = { pad_x = S.md, pad_y = S.sm, font = "default", h = 21 },
  btn_lg       = { pad_x = S.lg, pad_y = S.sm, font = "medium",  h = 22 },

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
--- @return integer color_count  Number of style colors pushed (pass to Theme.pop)
--- @return integer var_count  Number of style vars pushed (pass to Theme.pop)
-- Counts of the last push on this library. Every push pushes the same number on a
-- given ReaImGui, so a pop without counts can use them, whichever context pushed.
local pushed_nc, pushed_nv = 0, 0

-- Push helpers of Theme.push, built once (not per frame): they push on _push_ctx and count into _push_nc / _push_nv.
local _push_ctx, _push_nc, _push_nv = nil, 0, 0
local function _push_col(name, value)
  reaper.ImGui_PushStyleColor(_push_ctx, reaper["ImGui_Col_" .. name](), value)
  _push_nc = _push_nc + 1
end
-- Tab colours: names newer than ReaImGui 0.9 are skipped when the enum does not exist.
local function _push_col_opt(name, value)
  if reaper["ImGui_Col_" .. name] then _push_col(name, value) end
end
local function _push_var(name, a, b)
  reaper.ImGui_PushStyleVar(_push_ctx, reaper["ImGui_StyleVar_" .. name](), a, b)
  _push_nv = _push_nv + 1
end

function Theme.push(ctx, palette)
  local P = palette or Theme.get_palette()
  local L = Theme.layout
  _push_ctx, _push_nc, _push_nv = ctx, 0, 0

  local select_a = P.select & 0xFF

  _push_col("WindowBg",             P.bg)
  _push_col("TitleBg",              P.title)
  _push_col("TitleBgActive",        P.title)
  _push_col("Header",               P.select)
  _push_col("HeaderHovered",        P.hover)
  _push_col("HeaderActive",         (P.select & 0xFFFFFF00) | math.min(255, select_a * 2))
  _push_col("Button",               P.btn)
  _push_col("ButtonHovered",        P.btn_h)
  _push_col("ButtonActive",         P.btn_a)
  _push_col("FrameBg",              P.well)
  _push_col("FrameBgHovered",       P.well_h)
  _push_col("FrameBgActive",        P.well_a)
  _push_col("SliderGrab",           P.thumb)
  _push_col("SliderGrabActive",     P.thumb_a)
  _push_col("CheckMark",            P.accent)
  _push_col("PopupBg",              P.panel)
  _push_col("ModalWindowDimBg",     0x00000000) -- transparent: manual scrim via Theme.modal_scrim()
  _push_col("Separator",            P.sep)
  _push_col("SeparatorHovered",     P.accent_h) -- hovered / active mark a draggable splitter
  _push_col("SeparatorActive",      P.accent)
  _push_col_opt("Tab",                 P.tab)
  _push_col_opt("TabHovered",          P.tab_h)
  _push_col_opt("TabSelected",         P.tab_sel)
  _push_col_opt("TabSelectedOverline", P.accent)
  _push_col_opt("TabDimmed",           P.tab)
  _push_col_opt("TabDimmedSelected",   P.tab_sel)
  _push_col("TableHeaderBg",        P.card)
  _push_col("TableBorderStrong",    P.sep)
  _push_col("TableBorderLight",     P.sep)
  _push_col("TableRowBg",           P.bg)
  _push_col("TableRowBgAlt",        lighten(P.bg, 0.03))
  _push_col("ScrollbarBg",          with_alpha(P.bg, 0)) -- transparent: the surface shows through
  _push_col("ScrollbarGrab",        P.scroll)
  _push_col("ScrollbarGrabHovered", P.scroll_h)
  _push_col("ScrollbarGrabActive",  P.scroll_a)
  _push_col("Text",                 P.text)
  _push_col("TextDisabled",         P.text_dim)
  _push_col("Border",               P.outline)

  _push_var("WindowRounding",   L.rounding)
  _push_var("FrameRounding",    L.rounding)
  _push_var("GrabRounding",     L.rounding)
  _push_var("ItemSpacing",      L.sm, L.sm)
  _push_var("FramePadding",     L.md, L.sm)
  _push_var("WindowPadding",    L.md, L.md)
  _push_var("CellPadding",      L.sm, L.xs)
  _push_var("ItemInnerSpacing", L.sm, L.sm)
  _push_var("IndentSpacing",    L.indent)
  _push_var("FrameBorderSize",  L.border)

  local nc, nv = _push_nc, _push_nv
  _push_ctx = nil
  pushed_nc, pushed_nv = nc, nv
  return nc, nv
end

--- Pops the styles pushed by Theme.push().
--- Call after ImGui_End, using the counts returned by Theme.push(). Without counts,
--- the counts of the last push are used.
--- @param ctx userdata  ImGui context
--- @param nc integer|nil  Number of colors to pop (default: what push pushed)
--- @param nv integer|nil  Number of vars to pop (default: what push pushed)
function Theme.pop(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc or pushed_nc)
  reaper.ImGui_PopStyleVar(ctx, nv or pushed_nv)
end

-------------------------------------------------------------------------------
-- 8. DESIGN TOKENS — TYPOGRAPHY
-------------------------------------------------------------------------------
--- Font families and size scale. Scripts must use Theme.font_sizes.* tokens
--- and Theme.create_fonts() instead of calling ImGui_CreateFont directly.
--- The bundled typeface is Fira Sans (SIL OFL 1.1, see fonts/OFL.txt), loaded
--- from files in Theme.font_dir. If a file is missing or unreadable the same
--- family is requested from the system, then plain sans-serif. Never an error.

-- Directory of this file, with a trailing separator ("" if it has none).
local _lib_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.*[/\\])") or ""

Theme.font_dir             = _lib_dir .. "fonts/"
Theme.font_files           = { regular = "FiraSans-Regular.otf", bold = "FiraSans-Bold.otf" }
Theme.font_family          = "Fira Sans"
Theme.font_bold_family     = "Fira Sans Bold"  -- used by ReaImGui < 0.10 only
Theme.font_fallback_family = "sans-serif"
--- "file", "family" or "system": where the regular weight came from.
--- Set by Theme.create_fonts(). nil until then.
Theme.font_source          = nil

Theme.font_sizes = {
  small   = 11,    -- labels, secondary text, table metadata
  default = 13,    -- body text, standard UI elements
  medium  = 14,    -- emphasized text, settings labels
  large   = 16,    -- section headers, dialog titles
  header  = 18,    -- primary headers, window titles
  tooltip = 13,    -- tooltip text (kept for backward compat, = default)
}

-------------------------------------------------------------------------------
-- 9. FONT MANAGEMENT
-------------------------------------------------------------------------------

--- Creates one font, trying the font file, then the family, then sans-serif.
--- Each attempt is pcall-protected; the first non-nil result wins.
--- @param bold boolean  true for the bold weight
--- @param size number  Pixel size (only used to pick the call shape on old ReaImGui)
--- @param overrides table  create_fonts overrides (family / bold_family)
--- @return userdata|nil font
--- @return string source  "file", "family" or "system"
local function _make_font(bold, size, overrides)
  local new_api = reaper.ImGui_CreateFontFromFile ~= nil
  local flags = 0
  if bold and new_api and reaper.ImGui_FontFlags_Bold then
    local okf, f = pcall(reaper.ImGui_FontFlags_Bold)
    if okf and f then flags = f end
  end

  -- 1. bundled file (skipped when the caller names its own family)
  if new_api and not overrides.family and not overrides.bold_family then
    local path = Theme.font_dir .. (bold and Theme.font_files.bold or Theme.font_files.regular)
    local fh = io.open(path, "rb")
    if fh then
      fh:close()
      local ok, font = pcall(reaper.ImGui_CreateFontFromFile, path, 0, 0)
      if ok and font then return font, "file" end
    end
  end

  -- 2 and 3. family, then fallback family
  local regular = overrides.family or Theme.font_family
  local candidates = {}
  if new_api then
    if bold and overrides.bold_family then
      candidates[1] = { overrides.bold_family, 0 }
    else
      candidates[1] = { regular, flags }
    end
    candidates[2] = { Theme.font_fallback_family, flags }
  else
    candidates[1] = { bold and (overrides.bold_family or Theme.font_bold_family) or regular, size }
    candidates[2] = { Theme.font_fallback_family .. (bold and " Bold" or ""), size }
  end
  for i, c in ipairs(candidates) do
    local ok, font = pcall(reaper.ImGui_CreateFont, c[1], c[2])
    if ok and font then return font, (i == 1) and "family" or "system" end
  end
  return nil, "system"
end

--- Creates a complete set of shared fonts for a ReaImGui context.
--- Call once at script startup, before the defer loop.
--- Produces 8 fonts: default, small, medium, large, header (regular)
---                    default_bold, medium_bold, large_bold (bold)
--- Sets Theme.font_source to where the regular weight came from.
--- @param _ctx userdata  ImGui context (unused but kept for API consistency)
--- @param overrides table|nil  Optional: { family="Arial", bold_family="Arial Bold", large=24, ... }
--- @return table  Font table with keys: default, small, medium, large, header,
---                default_bold, medium_bold, large_bold, tooltip
function Theme.create_fonts(_ctx, overrides)
  overrides = overrides or {}
  local sizes = {
    small   = overrides.small   or Theme.font_sizes.small,
    default = overrides.default or Theme.font_sizes.default,
    medium  = overrides.medium  or Theme.font_sizes.medium,
    large   = overrides.large   or Theme.font_sizes.large,
    header  = overrides.header  or Theme.font_sizes.header,
  }

  local fonts = {}
  -- Regular weights
  fonts.default, Theme.font_source = _make_font(false, sizes.default, overrides)
  fonts.small   = _make_font(false, sizes.small,   overrides)
  fonts.medium  = _make_font(false, sizes.medium,  overrides)
  fonts.large   = _make_font(false, sizes.large,   overrides)
  fonts.header  = _make_font(false, sizes.header,  overrides)
  -- Bold weights
  fonts.default_bold = _make_font(true, sizes.default, overrides)
  fonts.medium_bold  = _make_font(true, sizes.medium,  overrides)
  fonts.large_bold   = _make_font(true, sizes.large,   overrides)
  -- Backward compat alias
  fonts.tooltip = fonts.default

  -- Store font→size mapping for push_font (ImGui_PushFont requires size arg)
  Theme._font_sizes = Theme._font_sizes or {}
  local function register(font, size)
    if font then Theme._font_sizes[font] = size end
  end
  register(fonts.default,      sizes.default)
  register(fonts.small,        sizes.small)
  register(fonts.medium,       sizes.medium)
  register(fonts.large,        sizes.large)
  register(fonts.header,       sizes.header)
  register(fonts.default_bold, sizes.default)
  register(fonts.medium_bold,  sizes.medium)
  register(fonts.large_bold,   sizes.large)

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

--- Check mark (two line segments: short stroke down, long stroke up).
--- Use for: selected rows, "done" / "on" markers.
function Theme.icons.check(dl, cx, cy, hs, col)
  local th = math.max(1.5, hs * 0.3)
  local ox, oy = math.floor(cx), math.floor(cy)
  local x1, y1 = ox - math.floor(hs * 0.8), oy
  local x2, y2 = ox - math.floor(hs * 0.25), oy + math.floor(hs * 0.6)
  local x3, y3 = ox + math.floor(hs * 0.85), oy - math.floor(hs * 0.6)
  reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, th)
  reaper.ImGui_DrawList_AddLine(dl, x2, y2, x3, y3, col, th)
end

--- Filled dot (filled circle).
--- Use for: "on" / active status markers.
function Theme.icons.dot(dl, cx, cy, hs, col)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, hs * 0.7, col)
end

--- Ring (circle outline).
--- Use for: "off" / inactive status markers.
function Theme.icons.ring(dl, cx, cy, hs, col)
  local th = math.max(1.0, hs * 0.25)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, hs * 0.7, col, 0, th)
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

--- Side panel toggle (a window outline whose right-hand pane is filled).
--- Use for: showing or hiding a panel docked on the right of a window.
function Theme.icons.panel_right(dl, cx, cy, hs, col)
  local ox, oy = math.floor(cx), math.floor(cy)
  local w, h = math.floor(hs * 0.95), math.floor(hs * 0.75)
  local th = math.max(1, hs * 0.2)
  local split = ox + math.floor(w * 0.25)
  reaper.ImGui_DrawList_AddRectFilled(dl, split, oy - h, ox + w, oy + h, col, 1)
  reaper.ImGui_DrawList_AddRect(dl, ox - w, oy - h, ox + w, oy + h, col, 1, 0, th)
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

--- Label colour for text drawn on a solid `fill`: palette.text when it reaches 4.5:1 there, otherwise whichever
--- of the dark label 0x0F2B3BFF and white contrasts more, moved toward black or white when even that falls
--- short (a mid-tone red reaches 4.5:1 with neither). A translucent fill is judged over palette.bg.
--- @param fill integer  Fill colour 0xRRGGBBAA
--- @return integer  Label colour 0xRRGGBBAA
function Theme.label_on(fill)
  local P = _get_palette()
  local under = composite_over(fill, P.bg)
  if contrast_over(P.text, under) >= 4.5 then return P.text end
  local dark, light = 0x0F2B3BFF, 0xFFFFFFFF
  local pick = contrast_over(dark, under) >= contrast_over(light, under) and dark or light
  return fit_contrast(pick, { under }, 4.5)
end
local label_on = Theme.label_on

--- Hover and pressed shades of `fill` that keep `label` at `need`:1 (judged over palette.bg when translucent).
--- Hover tries the fill lightened 12 % and pressed darkened 12 %, as on a dark UI; a step that takes the label
--- under `need` is replaced by the same step the other way, then by smaller steps (9, 6, 3 %), so both states stay
--- visibly apart from the rest fill. Pressed also avoids the hover colour (falling back to a stronger shade of the
--- hover direction). When nothing reaches `need`, the candidate with the best contrast is used.
--- @param fill integer  Rest fill 0xRRGGBBAA
--- @param label integer  Label (or icon) colour drawn on it
--- @param need number|nil  Required contrast (default 4.5)
--- @return integer hover, integer pressed
local function _shade_states(fill, label, need)
  need = need or 4.5
  local P = _get_palette()
  local hit = _fit_cache_get("shade", fill, label, need, P.bg, 0)
  if hit then return hit[1], hit[2] end
  local function ratio(c) return contrast_over(label, composite_over(c, P.bg)) end
  local function pick(first, second, avoid, extra)
    local best, best_r
    local list = {}
    for _, f in ipairs({ 0.12, 0.09, 0.06, 0.03 }) do
      list[#list + 1] = first(fill, f)
      list[#list + 1] = second(fill, f)
    end
    for _, c in ipairs(extra or {}) do list[#list + 1] = c end
    for _, c in ipairs(list) do
      if c ~= fill and c ~= avoid then
        local r = ratio(c)
        if r >= need then return c end
        if not best_r or r > best_r then best, best_r = c, r end
      end
    end
    return best or first(fill, 0.12)
  end
  local hover = pick(lighten, darken)
  local hover_dir = (luminance(hover) >= luminance(fill)) and lighten or darken
  local other = hover_dir == lighten and darken or lighten
  local pressed = pick(other, hover_dir, hover, { hover_dir(fill, 0.24), hover_dir(fill, 0.18) })
  _fit_cache_put({ hover, pressed }, "shade", fill, label, need, P.bg, 0)
  return hover, pressed
end

--- Icon colour for a hovered or pressed icon button: `col` moved 25 % toward the text colour's extreme
--- (lighter on a dark UI, darker on a light one), then fitted to 3:1 on both faces it is drawn on. Cached.
--- @param col integer  Resting icon colour
--- @param face_h integer  Hovered face behind the icon (judged over palette.bg when translucent)
--- @param face_a integer  Pressed face behind the icon
--- @return integer
local function _icon_on(col, face_h, face_a)
  local P = _get_palette()
  local hit = _fit_cache_get("icon", col, face_h, face_a, P.bg, P.text)
  if hit then return hit end
  local dark_ui = luminance(P.text) > luminance(P.bg)
  local c = dark_ui and lighten(col, 0.25) or darken(col, 0.25)
  local under = { composite_over(face_h, P.bg), composite_over(face_a, P.bg) }
  return _fit_cache_put(fit_contrast(c, under, 3.0), "icon", col, face_h, face_a, P.bg, P.text)
end

--- A caller's own hover icon colour, fitted to 3:1 on the hovered and pressed faces keeping its hue (the
--- caller chose it for a transparent background; the face behind it is new). Cached like _icon_on.
--- @return integer
local function _icon_hover_fit(col, face_h, face_a)
  local P = _get_palette()
  local hit = _fit_cache_get("icon_hover", col, face_h, face_a, P.bg, 0)
  if hit then return hit end
  local under = { composite_over(face_h, P.bg), composite_over(face_a, P.bg) }
  return _fit_cache_put(fit_contrast(col, under, 3.0, nil, true), "icon_hover", col, face_h, face_a, P.bg, 0)
end

--- Default icon colour of icon_btn_colored: palette.text fitted to 3:1 on `face` (judged over palette.bg). Cached.
--- @return integer
local function _icon_on_face(face)
  local P = _get_palette()
  local hit = _fit_cache_get("icon_face", face, P.text, P.bg, 0, 0)
  if hit then return hit end
  return _fit_cache_put(fit_contrast(P.text, { composite_over(face, P.bg) }, 3.0), "icon_face", face, P.text, P.bg, 0, 0)
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

--- Draws a manual fullscreen dim overlay (scrim) behind a modal popup.
---
--- Call BEFORE `ImGui_BeginPopupModal` while inside the parent window's
--- `Begin`/`End` block.  The scrim is drawn on the parent window's draw
--- list with a fullscreen clip rect, so it renders behind the modal but
--- over the parent — exactly replicating Dear ImGui's built-in behaviour
--- without the first-frame colour lag that occurs in ReaImGui.
---
--- Theme.push() sets ImGuiCol_ModalWindowDimBg to transparent, so the
--- built-in mechanism never fires. Use this function everywhere instead.
---
--- **Standard pattern:**
--- ```
--- Theme.modal_scrim(ctx, "My Modal##id")
--- local visible = reaper.ImGui_BeginPopupModal(ctx, "My Modal##id", ...)
--- ```
---
---
--- @param ctx  userdata  ImGui context
--- @param popup_name string  Exact popup ID (same string passed to OpenPopup / BeginPopupModal)
local _scrim_was_open = {}
function Theme.modal_scrim(ctx, popup_name)
  local is_open = reaper.ImGui_IsPopupOpen(ctx, popup_name)
  if not is_open then
    _scrim_was_open[popup_name] = nil
    return
  end
  -- Skip the very first frame the popup appears — Dear ImGui hides the
  -- modal window for one frame on creation (HiddenFramesCannotSkipItems).
  -- Drawing the scrim on that frame produces a dark flash with no modal.
  if not _scrim_was_open[popup_name] then
    _scrim_was_open[popup_name] = true
    return
  end
  local P = _get_palette()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- Expand clip rect to cover the entire screen (not just the parent window)
  reaper.ImGui_DrawList_PushClipRectFullScreen(dl)
  -- Get the parent window's viewport bounds for the fill rect
  local vp = reaper.ImGui_GetWindowViewport(ctx)
  local vp_x, vp_y = reaper.ImGui_Viewport_GetPos(vp)
  local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(vp)
  reaper.ImGui_DrawList_AddRectFilled(dl, vp_x, vp_y, vp_x + vp_w, vp_y + vp_h, P.dim_bg)
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

--- Renders a borderless button with a DrawList vector icon overlay.
--- Transparent at rest (like the theme's transparent track buttons), palette.btn_h face on hover,
--- palette.btn_a pressed; the icon also lightens on hover. Optionally shows a tooltip.
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique ImGui ID for the button (e.g. "delete_btn")
--- @param icon_fn function  Icon drawing function from Theme.icons.*
--- @param opts table|nil  Optional overrides:
---   opts.preset    (table)   Icon preset   (default: Theme.layout.icon_md)
---   opts.w         (number)  Button width override
---   opts.h         (number)  Button height override
---   opts.icon_size (number)  Icon size override
---   opts.color     (number)  Icon color    (default: palette.text)
---   opts.hover_color (number) Icon color on hover (default: icon color moved 25% toward the text colour's
---                             extreme, fitted to 3:1 on the hover and pressed faces). A colour given here is
---                             also fitted to 3:1 on those faces, keeping its hue: the one place a caller's
---                             colour is adjusted, since it was chosen for a transparent background
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        with_alpha(P.btn, 0))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.btn_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  P.btn_a)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  local btn_label = id:find("##", 1, true) and id or ("##" .. id)   -- never draws a text label
  local pressed = reaper.ImGui_Button(ctx, btn_label, btn_w, btn_h)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 3)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx = (rx + rx2) * 0.5
  local cy = (ry + ry2) * 0.5
  local hs = icon_sz * 0.5
  local hover = reaper.ImGui_IsItemHovered(ctx)
  local base_col = opts.color or P.text
  local draw_col = base_col
  if hover then
    if opts.hover_color then
      draw_col = _icon_hover_fit(opts.hover_color, P.btn_h, P.btn_a)
    else
      draw_col = _icon_on(base_col, P.btn_h, P.btn_a)
    end
  end
  icon_fn(dl, cx, cy, hs, draw_col)
  if hover then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())   -- hovered and enabled
  end
  if opts.tooltip and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end
  return pressed
end

--- Renders a button with a DrawList vector icon overlay.
--- Unlike icon_btn, this renders a visible button face (a plain button by default).
---
--- @param ctx userdata  ImGui context
--- @param id string  Unique ImGui ID (the "##" prefix is added automatically)
--- @param icon_fn function  Icon drawing function from Theme.icons.*
--- @param opts table|nil  Optional overrides:
---   opts.preset    (table)   Icon preset   (default: Theme.layout.icon_md)
---   opts.w         (number)  Button width override
---   opts.h         (number)  Button height override
---   opts.icon_size (number)  Icon size override
---   opts.icon_color (number) Icon color    (default: palette.text, fitted to 3:1 on the face of each state)
---   opts.bg        (number)  Button bg     (default: palette.btn)
---   opts.bg_hover  (number)  Hover bg      (default: palette.btn_h)
---   opts.bg_active (number)  Active bg     (default: palette.btn_a)
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
  local bg, bg_h, bg_a = opts.bg or P.btn, opts.bg_hover or P.btn_h, opts.bg_active or P.btn_a
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_a)
  local pressed = reaper.ImGui_Button(ctx, "##" .. id, btn_w, btn_h)
  reaper.ImGui_PopStyleColor(ctx, 3)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx = (rx + rx2) * 0.5
  local cy = (ry + ry2) * 0.5
  local hs = icon_sz * 0.5
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local icon_col = opts.icon_color
  if not icon_col then
    -- Default icon: palette.text, fitted to 3:1 on the face it sits on in this state
    local face = reaper.ImGui_IsItemActive(ctx) and bg_a or hovered and bg_h or bg
    icon_col = _icon_on_face(face)
  end
  icon_fn(dl, cx, cy, hs, icon_col)
  if hovered then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())   -- hovered and enabled
  end
  if opts.tooltip and _hovered_for_tooltip(ctx) then
    Theme.tooltip(ctx, opts.tooltip)
  end
  return pressed
end

--- Renders a tooltip with automatic text wrapping: a palette.panel popup with a palette.outline border.
--- Respects the global Theme.get_show_tooltips() setting.
--- Uses consistent padding from layout tokens.
---
--- @param ctx userdata  ImGui context
--- @param text string  Tooltip text content
--- @param max_w number|nil  Max wrap width (default: Theme.layout.tooltip_wrap)
function Theme.tooltip(ctx, text, max_w)
  if not Theme.get_show_tooltips() then return end
  max_w = max_w or Theme.layout.tooltip_wrap
  local P = _get_palette()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), P.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  P.outline)
  if reaper.ImGui_BeginTooltip(ctx) then
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + max_w)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_EndTooltip(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
end

--- Renders a labeled section divider with optional info tooltip: label in palette.text_dim over a
--- palette.sep hairline. Adds consistent spacing above and below from layout tokens.
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), P.sep)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
end

--- Renders a standardized collapsing header widget.
--- Encapsulates ReaImGui's argument order and default flags to prevent
--- argument-misalignment bugs (such as accidental close buttons).
--- Supports optional right-aligned close/action button.
--- The header row is a button face: palette.btn, palette.btn_h on hover, palette.btn_a pressed.
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

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        P.btn)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), P.btn_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  P.btn_a)
  local is_open = reaper.ImGui_CollapsingHeader(ctx, "##ch_" .. id, nil, flags)
  reaper.ImGui_PopStyleColor(ctx, 3)
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
---   opts.bg_color     (number)  Background color (default: palette.well, a recessed track)
---   opts.border_color (number)  Border color (default: palette.outline)
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
  local bg_col = opts.bg_color or opts.bg or P.well
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
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, opts.border_color or P.outline, rounding)

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
---   opts.active_bg      (number)  Active background (default: palette.btn_on, a solid fill)
---   opts.active_hover   (number)  Active hovered background (default: active background lightened 12%, or
---                                 shaded the other way / less where that keeps the label at 4.5:1)
---   opts.active_active  (number)  Active pressed background (default: active background darkened 12%, same rule)
---   opts.active_text    (number)  Active text color (default: palette.on_text; Theme.label_on(active_bg)
---                                 when only active_bg is given)
---   opts.inactive_bg    (number)  Inactive background (default: palette.btn, a plain button face)
---   opts.inactive_hover (number)  Inactive hovered background (default: palette.btn_h, or inactive_bg shaded
---                                 as for active_hover)
---   opts.inactive_active(number)  Inactive pressed background (default: palette.btn_a, or inactive_bg shaded)
---   opts.inactive_text  (number)  Inactive text color (default: palette.text; Theme.label_on(inactive_bg)
---                                 when only inactive_bg is given)
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
    -- On: a solid fill (no tint); hover lightens it, press darkens it
    bg       = opts.active_bg     or P.btn_on
    text_col = opts.active_text   or (opts.active_bg and label_on(bg) or P.on_text)
    local sh, sa
    if not (opts.active_hover and opts.active_active) then sh, sa = _shade_states(bg, text_col) end
    bg_h     = opts.active_hover  or sh
    bg_a     = opts.active_active or sa
  else
    -- Off: a plain button face
    local custom = opts.inactive_bg
    bg       = custom or P.btn
    text_col = opts.inactive_text   or (custom and label_on(bg) or P.text)
    local sh, sa
    if custom and not (opts.inactive_hover and opts.inactive_active) then sh, sa = _shade_states(bg, text_col) end
    bg_h     = opts.inactive_hover  or sh or P.btn_h
    bg_a     = opts.inactive_active or sa or P.btn_a
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
---   opts.color          (number)  Semantic colour: without opts.bg the badge is a solid fill of it
---                                 (default: none, a quiet tag: palette.well face, outline, palette.text label)
---   opts.text_color     (number)  Explicit text color override (default: Theme.label_on(fill); with both
---                                 opts.color and opts.bg, color lightened 70% when that reads on bg)
---   opts.bg             (number)  Explicit background color override (default: opts.color or palette.well)
---   opts.bg_hover       (number)  Hover background when interactive (default: fill lightened 12%, or shaded
---                                 the other way / less where that keeps the label at 4.5:1)
---   opts.bg_active      (number)  Pressed background when interactive (default: fill darkened 12%, same rule)
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

  -- Default: a quiet tag (well face, outline from FrameBorderSize, text label).
  -- opts.color alone: a solid fill of that colour with a fitted dark or light label.
  local bg       = opts.bg or opts.color or P.well
  local text_col = opts.text_color
  if not text_col then
    if opts.color and opts.bg then
      -- A script's colour + background pair: keep its tinted label where it reads on that background
      local tinted = lighten(opts.color, 0.70)
      local under = composite_over(bg, P.bg)
      text_col = contrast_over(tinted, under) >= 4.5 and tinted or label_on(bg)
    elseif opts.color or opts.bg then
      text_col = label_on(bg)
    else
      text_col = P.text
    end
  end
  -- Hover and pressed shades only for an interactive badge, and only those the caller did not give
  local bg_h, bg_a = bg, bg
  if opts.interactive then
    local sh, sa
    if not (opts.bg_hover and opts.bg_active) then sh, sa = _shade_states(bg, text_col) end
    bg_h = opts.bg_hover or sh
    bg_a = opts.bg_active or sa
  end

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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_a)
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
--- Replaces native square-cornered Selectables. A hovered row is palette.hover; a selected row is the
--- palette.select tint plus a 2 px solid accent bar along its left edge (the 3:1 selection marker).
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
---   opts.bg_hover (number) Hover color (default: palette.hover)
---   opts.bg_sel   (number) Selected color, hovered or not (default: palette.select; a stronger tint would
---                          take the label under 4.5:1)
---   opts.text_col (number) Text color override (default: palette.text)
---   opts.pad_x    (number) Left padding for text (default: Theme.layout.sm)
--- @return boolean clicked
function Theme.selectable(ctx, label, is_selected, flags, w, h, opts)
  opts = opts or {}
  local P = _get_palette()
  local L = Theme.layout
  local rounding = opts.rounding or L.rounding
  local bg_hover = opts.bg_hover or P.hover
  local bg_sel   = opts.bg_sel   or P.select
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
    local bg = sel_state and bg_sel or bg_hover
    reaper.ImGui_DrawList_AddRectFilled(dl, rx1, ry1, rx2, ry2, bg, rounding)
  end
  -- Selection marker: a 2 px solid accent bar along the row's left edge, full row height
  if sel_state then
    reaper.ImGui_DrawList_AddRectFilled(dl, rx1, ry1, rx1 + 2, ry2, P.accent)
  end

  -- 2. Draw text on top if visible label is non-empty
  local clipped = false
  if visible_label ~= "" then
    local text_col = opts.text_col or P.text
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

--- Opens a combo whose preview looks like a button: palette.btn face (btn_h hovered, btn_a open), outline
--- and chevron from the style stack. The colours are popped before the list, which stays a palette.panel popup.
--- @return boolean open  Result of ImGui_BeginCombo
local function _begin_combo_btn(ctx, id, preview, flags)
  local P = _get_palette()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        P.btn)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), P.btn_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  P.btn_a)
  local open = reaper.ImGui_BeginCombo(ctx, id, preview, flags)
  reaper.ImGui_PopStyleColor(ctx, 3)
  return open
end

--- Renders a standardized combo box wrapping ImGui_BeginCombo.
--- Handles label resolution, item iteration, and selection state.
--- The preview is a button face; list rows are Theme.selectable rows (hover, select tint, accent bar).
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

  if _begin_combo_btn(ctx, id, preview) then
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

--- Renders a standardized, compact multi-select combo box (preview and rows look like Theme.combo's).
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
---   opts.check_mark      (string)   Text prefix for selected items (default: a Theme.icons.check drawn in the prefix slot)
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

  if _begin_combo_btn(ctx, id, preview) then
    local pushed_vars = 0
    if opts.compact ~= false then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), L.md, L.xs)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), L.sm, L.xs)
      pushed_vars = 2
    end

    local sel_flags = opts.close_on_select and reaper.ImGui_SelectableFlags_None()
                      or (reaper.ImGui_SelectableFlags_NoAutoClosePopups and reaper.ImGui_SelectableFlags_NoAutoClosePopups() or reaper.ImGui_SelectableFlags_None())
    -- Selected rows draw Theme.icons.check in the prefix slot (same reserved width as unselected rows);
    -- a caller's own opts.check_mark text still replaces it.
    local check_prefix = opts.check_mark
    local blank_prefix = "   "

    for i, item in ipairs(items) do
      local is_sel = _is_item_selected(selected, item, i, opts.get_id)
      local prefix = (is_sel and check_prefix) or blank_prefix
      local label_text = _get_combo_item_label(item, i, opts.get_label)
      local row_label = prefix .. label_text .. "##mitem_" .. i

      if Theme.selectable(ctx, row_label, is_sel, sel_flags) then
        toggled_idx = i
        is_now_selected = not is_sel
        changed = true
      end
      if is_sel and not check_prefix then
        -- Theme.selectable left the row as the last item: draw the check in its prefix slot
        local rx1, ry1 = reaper.ImGui_GetItemRectMin(ctx)
        local _, ry2 = reaper.ImGui_GetItemRectMax(ctx)
        local slot_w = reaper.ImGui_CalcTextSize(ctx, blank_prefix)
        local hs = math.max(2, math.floor((ry2 - ry1) * 0.2))
        Theme.icons.check(reaper.ImGui_GetWindowDrawList(ctx), rx1 + L.sm + slot_w * 0.5,
          (ry1 + ry2) * 0.5, hs, _get_palette().text)
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
--- Draws a recessed card (palette.well, palette.outline frame) with the signature bezier curve and colored dots.
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
  reaper.ImGui_DrawList_AddRectFilled(dl, bx1, by1, bx2, by2, P.well, r_bg)
  reaper.ImGui_DrawList_AddRect(dl, bx1, by1, bx2, by2, P.outline, r_bg, 0, stroke_w)
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

local SETTINGS_LABELS = { "Fancy", "Match Theme" }
local SETTINGS_VALUES = { Theme.MODE_FANCY, Theme.MODE_MATCH }
--- Visible labels of the theme modes, in the order of the settings combo (read-only).
Theme.mode_labels = SETTINGS_LABELS

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
  if _begin_combo_btn(ctx, combo_label, SETTINGS_LABELS[current]) then
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
--- The row sits on a palette.title strip across the window with a 1 px palette.sep hairline under it
--- (the hairline is left out with show_separator = false).
---
--- @param ctx userdata  ImGui context
--- @param opts table|nil  Header configuration:
---   opts.title          (string)      Window title text (required)
---   opts.prefix         (string|nil)  Brand prefix text (default: "FANCY")
---   opts.fancy_prefix   (boolean|nil) Whether to show "FANCY" prefix (default: true)
---   opts.prefix_color   (number|nil)  Prefix text color (default: palette.yellow)
---   opts.subtitle       (string|nil)  Secondary subtitle text (optional)
---   opts.fonts          (table|nil)   Font table from Theme.create_fonts() (optional)
---   opts.font_header    (userdata|nil) Title font override (default: opts.fonts.default_bold)
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
---   opts.show_separator (boolean|nil) Whether to render the hairline below the header strip (default: true)
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

  -- 0. Title strip behind the row, edge to edge (drawn first, so the row draws over it), and its hairline.
  --    The strip runs from the window padding above the row to the item spacing below it (both read from the
  --    style in effect), inside the window border: inset by WindowBorderSize on the top, left and right, so a
  --    window without a title bar keeps its 1 px frame. Where the strip meets the window's top edge and the
  --    window is rounded, its top corners take L.rounding.
  do
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local row_x, row_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local pad_x, pad_y, spacing_y, border, win_round = L.md, L.md, L.sm, 0, 0
    if reaper.ImGui_GetStyleVar then
      pad_x, pad_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
      local _, sy = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
      spacing_y = sy
      if reaper.ImGui_StyleVar_WindowBorderSize then
        border = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize()) or 0
      end
      win_round = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding()) or 0
    end
    local x1 = win_x + border
    -- Right edge: the content edge plus its padding, so a vertical scrollbar stays uncovered
    local x2 = math.min(win_x + win_w - border, row_x + avail_w + pad_x)
    local top = win_y + border
    local y1 = math.max(top, row_y - pad_y)
    local y2 = row_y + hdr_h + spacing_y
    reaper.ImGui_DrawList_PushClipRect(dl, win_x, win_y, win_x + win_w, win_y + win_h, false)
    if win_round > 0 and y1 <= top and reaper.ImGui_DrawFlags_RoundCornersTop then
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, P.title, L.rounding, reaper.ImGui_DrawFlags_RoundCornersTop())
    else
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, P.title)
    end
    if opts.show_separator ~= false then
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y2, x2, y2 + 1, P.sep)
    end
    reaper.ImGui_DrawList_PopClipRect(dl)
  end

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
    local font_title = opts.font_header or (opts.fonts and (opts.fonts.default_bold or opts.fonts.medium or opts.fonts.large))
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

  -- Clear the strip and its hairline before the content below
  reaper.ImGui_Dummy(ctx, 0, 1)
  reaper.ImGui_Spacing(ctx)

  return not close_clicked
end

return Theme


