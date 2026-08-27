-- Fancy Scripts — Shared Theme Engine
-- Palette builder with 3 theme modes, font management, and ImGui push/pop.
-- Loaded via: local Theme = require("theme")

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

--- Converts a REAPER native BGR integer to ImGui RGBA format.
--- REAPER's GetThemeColor returns colors as 0x00BBGGRR (BGR, no alpha).
--- Negative values indicate alpha-blended or special colors; we mask them.
--- @param bgr integer  Native REAPER color value
--- @return integer  Color in 0xRRGGBBAA format (fully opaque)
local function bgr_to_rgba(bgr)
  if bgr < 0 then bgr = bgr & 0x00FFFFFF end
  local r = bgr & 0xFF
  local g = (bgr >> 8) & 0xFF
  local b = (bgr >> 16) & 0xFF
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
Theme.MODE_MATCH = "match"  -- Backgrounds from REAPER theme, Fancy accent
Theme.MODE_FULL  = "full"   -- Everything from REAPER theme

local EXTSTATE_SECTION = "FancyScripts"
local EXTSTATE_KEY     = "theme_mode"

--- Returns the current theme mode from global ExtState.
--- @return string  One of "fancy", "match", or "full"
function Theme.get_mode()
  local mode = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY)
  if mode == Theme.MODE_MATCH or mode == Theme.MODE_FULL then
    return mode
  end
  return Theme.MODE_FANCY
end

--- Sets the global theme mode (persists across sessions).
--- @param mode string  One of Theme.MODE_FANCY, Theme.MODE_MATCH, Theme.MODE_FULL
function Theme.set_mode(mode)
  reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY, mode, true)
end

-------------------------------------------------------------------------------
-- 3. CURATED FANCY DARK PALETTE
-------------------------------------------------------------------------------
local FANCY_PALETTE = {
  -- Base surfaces
  bg     = 0x12121EFF,
  panel  = 0x1C1C30FF,
  card   = 0x22223AFF,

  -- Text
  text     = 0xFFFFFFFF,
  text_dim = 0x7A7A9FFF,

  -- Accent + derived states
  accent   = 0x8B70FAFF,
  accent_h = 0x8B70FACC,
  accent_d = 0x8B70FA55,
  accent_e = 0x8B70FA20,

  -- Semantic colors (always hardcoded for clarity)
  green   = 0x56E39FFF,
  green_h = 0x56E39FBB,
  green_d = 0x56E39F77,
  red     = 0xF45B69FF,
  red_h   = 0xF45B69AA,
  red_d   = 0xF45B6944,
  yellow  = 0xFFCC66FF,

  -- Structural
  border = 0x444444FF,
  sep    = 0x8B70FA33,
  dim_bg = 0x0C0E24D8,

  -- Table rows (specific to the Fancy palette)
  table_row    = 0x16162AFF,
  table_row_alt = 0x1C1C32FF,

  -- Slider grab active (lighter accent)
  slider_grab_active = 0xA28CFEFF,
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
  if not bgr or bgr == 0 then return fallback end
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

  -- Semantic colors — always hardcoded regardless of mode
  P.green   = overrides.green   or FANCY_PALETTE.green
  P.green_h = overrides.green_h or FANCY_PALETTE.green_h
  P.green_d = overrides.green_d or FANCY_PALETTE.green_d
  P.red     = overrides.red     or FANCY_PALETTE.red
  P.red_h   = overrides.red_h   or FANCY_PALETTE.red_h
  P.red_d   = overrides.red_d   or FANCY_PALETTE.red_d
  P.yellow  = overrides.yellow  or FANCY_PALETTE.yellow

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
    -- Backgrounds + text from REAPER theme, Fancy accent kept
    P.bg       = overrides.bg       or read_theme_color("col_main_bg2",  FANCY_PALETTE.bg)
    P.panel    = overrides.panel    or read_theme_color("col_tr1_bg",    FANCY_PALETTE.panel)
    P.card     = overrides.card     or read_theme_color("col_tr2_bg",    FANCY_PALETTE.card)
    P.text     = overrides.text     or read_theme_color("col_main_text", FANCY_PALETTE.text)
    P.text_dim = overrides.text_dim or read_theme_color("col_tcp_text",  FANCY_PALETTE.text_dim)
    P.accent   = overrides.accent   or FANCY_PALETTE.accent
    P.border   = overrides.border   or read_theme_color("col_main_3dhl", FANCY_PALETTE.border)

  elseif mode == Theme.MODE_FULL then
    -- Everything from REAPER theme, including accent
    P.bg       = overrides.bg       or read_theme_color("col_main_bg2",  FANCY_PALETTE.bg)
    P.panel    = overrides.panel    or read_theme_color("col_tr1_bg",    FANCY_PALETTE.panel)
    P.card     = overrides.card     or read_theme_color("col_tr2_bg",    FANCY_PALETTE.card)
    P.text     = overrides.text     or read_theme_color("col_main_text", FANCY_PALETTE.text)
    P.text_dim = overrides.text_dim or read_theme_color("col_tcp_text",  FANCY_PALETTE.text_dim)
    P.accent   = overrides.accent   or read_theme_color("col_cursor",   FANCY_PALETTE.accent)
    P.border   = overrides.border   or read_theme_color("col_main_3dhl", FANCY_PALETTE.border)
  end

  -- Derive accent states from the resolved accent color
  P.accent_h = overrides.accent_h or with_alpha(P.accent, 0.8)
  P.accent_d = overrides.accent_d or with_alpha(P.accent, 0.33)
  P.accent_e = overrides.accent_e or with_alpha(P.accent, 0.125)

  -- Derive structural colors
  P.sep    = overrides.sep    or with_alpha(P.accent, 0.2)
  P.dim_bg = overrides.dim_bg or with_alpha(P.bg, 0.85)

  -- Derive table row colors from panel/card
  P.table_row     = overrides.table_row     or darken(P.panel, 0.1)
  P.table_row_alt = overrides.table_row_alt or P.panel

  -- Slider grab active (slightly lighter accent)
  P.slider_grab_active = overrides.slider_grab_active or lighten(P.accent, 0.15)

  return P
end

-------------------------------------------------------------------------------
-- 6. IMGUI STYLE PUSH / POP
-------------------------------------------------------------------------------

--- Pushes the full Fancy Scripts ImGui theme onto the style stack.
--- Call at the start of each frame, before ImGui_Begin.
--- @param ctx userdata  ImGui context
--- @param palette table|nil  Palette from build_palette() (builds default if nil)
--- @return integer color_count  Number of style colors pushed
--- @return integer var_count  Number of style vars pushed
function Theme.push(ctx, palette)
  local P = palette or Theme.build_palette()

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

  -- Style vars (4 total)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),  5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),    8, 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),   8, 4)

  return 28, 4
end

--- Pops all Fancy Scripts ImGui styles from the stack.
--- Call after ImGui_End, using the counts returned by Theme.push().
--- @param ctx userdata  ImGui context
--- @param nc integer|nil  Number of colors to pop (default 28)
--- @param nv integer|nil  Number of vars to pop (default 4)
function Theme.pop(ctx, nc, nv)
  reaper.ImGui_PopStyleColor(ctx, nc or 28)
  reaper.ImGui_PopStyleVar(ctx, nv or 4)
end

-------------------------------------------------------------------------------
-- 7. FONT MANAGEMENT
-------------------------------------------------------------------------------
Theme.font_family = "Verdana"
Theme.font_sizes = {
  default = 14,
  small   = 12,
  large   = 18,
  tooltip = 14,
}

--- Creates a set of shared fonts for a ReaImGui context.
--- Call once at script startup, before the defer loop.
--- @param ctx userdata  ImGui context
--- @param overrides table|nil  Optional overrides: { family = "Arial", large = 24, ... }
--- @return table  Font table with keys: default, small, large, tooltip
function Theme.create_fonts(_ctx, overrides)
  overrides = overrides or {}
  local family = overrides.family or Theme.font_family
  local sizes = {
    default = overrides.default or Theme.font_sizes.default,
    small   = overrides.small   or Theme.font_sizes.small,
    large   = overrides.large   or Theme.font_sizes.large,
    tooltip = overrides.tooltip or Theme.font_sizes.tooltip,
  }

  local fonts = {}
  fonts.default = reaper.ImGui_CreateFont(family, sizes.default)
  fonts.small   = reaper.ImGui_CreateFont(family, sizes.small)
  fonts.large   = reaper.ImGui_CreateFont(family, sizes.large)
  fonts.tooltip = reaper.ImGui_CreateFont(family, sizes.tooltip)
  return fonts
end

--- Attaches all fonts from a font table to a ReaImGui context.
--- Must be called before the first frame is rendered.
--- @param ctx userdata  ImGui context
--- @param fonts table  Font table from Theme.create_fonts()
function Theme.attach_fonts(ctx, fonts)
  if fonts.default then reaper.ImGui_Attach(ctx, fonts.default) end
  if fonts.small   then reaper.ImGui_Attach(ctx, fonts.small)   end
  if fonts.large   then reaper.ImGui_Attach(ctx, fonts.large)   end
  if fonts.tooltip then reaper.ImGui_Attach(ctx, fonts.tooltip) end
end

-------------------------------------------------------------------------------
-- 8. SETTINGS UI WIDGET
-------------------------------------------------------------------------------

--- Renders a theme mode combo box for use in any script's settings panel.
--- Reads and writes the global ExtState automatically.
--- @param ctx userdata  ImGui context
--- @return boolean  true if the mode was changed (caller may want to rebuild palette)
function Theme.settings_widget(ctx)
  local mode = Theme.get_mode()
  local labels = { "Fancy Dark", "Match Theme", "Full Theme" }
  local values = { Theme.MODE_FANCY, Theme.MODE_MATCH, Theme.MODE_FULL }
  local current = 1
  for i, v in ipairs(values) do
    if v == mode then current = i; break end
  end

  local changed = false
  reaper.ImGui_SetNextItemWidth(ctx, 160)
  if reaper.ImGui_BeginCombo(ctx, "Color Mode", labels[current]) then
    for i, label in ipairs(labels) do
      local selected = (i == current)
      if reaper.ImGui_Selectable(ctx, label, selected) then
        if not selected then
          Theme.set_mode(values[i])
          changed = true
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return changed
end

return Theme
