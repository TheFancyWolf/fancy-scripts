-- @description Fancy Design System
-- @author Fancy Scripts
-- @version 1.2.0
-- @changelog
--   + Add live interactive demonstrations for Theme.progress_bar(), Theme.badge_button(), and Theme.combo()
--   + Rebuild header using shared Theme.header() composite widget
--   + Fix vertical alignment across header icon, title, subtitle, and controls
--   + Add Theme.header() component preview in Widget Components section
--   + Add SameLine vcenter ref_y pattern demonstration
--   + Eliminate raw hex color literals in color swatch alpha checkerboard
-- @about
--   Visual style guide that renders every design token, color, font size,
--   icon, and widget component from the shared design system in one window.
--   Use this to visually tune the design language before propagating changes.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

-------------------------------------------------------------------------------
-- 1. DEPENDENCY CHECK
-------------------------------------------------------------------------------
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Design System -- Missing ReaImGui", 0)
  return
end

-------------------------------------------------------------------------------
-- 2. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")

-------------------------------------------------------------------------------
-- 3. STATE & CONFIGURATION
-------------------------------------------------------------------------------
local ctx = reaper.ImGui_CreateContext("Fancy Design System",
              reaper.ImGui_ConfigFlags_DockingEnable())
local fonts = Theme.create_fonts(ctx)
Theme.attach_fonts(ctx, fonts)

local P = Theme.build_palette()
local L = Theme.layout

-- Interactive widget demo state
local demo_prog_val        = 0.65
local demo_badge_active    = true
local demo_mode_active     = false
local demo_combo_items     = { "Pro-Q 4 (FabFilter)", "Ozone 11 (iZotope)", "Decapitator (Soundtoys)", "ValhallaVintageVerb" }
local demo_combo_sel       = 1
local demo_multi_combo_sel = { [1] = true, [3] = true }

-- Script-specific layout — uses Theme.layout values as building blocks
local UI = {
  win_w       = L.modal_xl.w + L.xxxl * 3 + L.xl, -- 920
  win_h       = L.modal_xl.h + L.xxxl * 3 + L.xl, -- 720
  swatch_w    = L.xxxl * 3 + L.sm,                -- 100
  swatch_h    = L.row_h,                           -- 24
  bar_scale   = L.md + L.xs,                       -- 10
  rounding_sz = L.xxxl * 2,                        -- 64
}

-------------------------------------------------------------------------------
-- 4. HELPERS
-------------------------------------------------------------------------------

--- Adds vertical spacing using a layout token.
local function vspace(h)
  reaper.ImGui_Dummy(ctx, 0, h or L.xxxl)
end

--- Formats a palette color as a hex string.
local function hex_str(color)
  return string.format("0x%08X", color)
end

--- Draws a color swatch with label and hex value (SameLine-compatible).
--- Uses a single Dummy with DrawList for all rendering.
local function color_swatch(label, color)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local w, h = UI.swatch_w, UI.swatch_h
  local font_h = Theme.font_sizes.small or 12
  local hex = hex_str(color)
  local label_w = reaper.ImGui_CalcTextSize(ctx, label)
  local hex_w = reaper.ImGui_CalcTextSize(ctx, hex)
  local cell_w = math.max(w, label_w, hex_w)
  local cell_h = h + L.xs + font_h + L.xs + font_h

  -- Checkerboard behind transparent colors using theme palette
  local alpha = color & 0xFF
  if alpha < 0xFF then
    local ck = math.floor(w / 2)
    for row = 0, 1 do
      for col = 0, math.ceil(w / ck) - 1 do
        local dark = ((row + col) % 2 == 0)
        local ck_col = dark and P.bg or P.card
        local cx1 = x + col * ck
        local cy1 = y + row * math.floor(h / 2)
        local cx2 = math.min(cx1 + ck, x + w)
        local cy2 = math.min(cy1 + math.floor(h / 2), y + h)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx1, cy1, cx2, cy2, ck_col)
      end
    end
  end

  -- Color fill + border
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, color, L.rounding)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, P.border, L.rounding)

  -- Label (below swatch)
  local label_y = y + h + L.xs
  reaper.ImGui_DrawList_AddText(dl, x, label_y, P.text, label)

  -- Hex value (below label)
  local hex_y = label_y + font_h + L.xs
  reaper.ImGui_DrawList_AddText(dl, x, hex_y, P.text_dim, hex)

  -- Single Dummy for the entire cell
  reaper.ImGui_Dummy(ctx, cell_w, cell_h)
end

--- Draws a row of color swatches with a group title and optional description.
local function swatch_row(title, swatches, desc)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
  reaper.ImGui_Text(ctx, title)
  reaper.ImGui_PopStyleColor(ctx, 1)
  if desc then
    reaper.ImGui_SameLine(ctx, 0, L.md)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_Text(ctx, desc)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  vspace(L.sm)

  for i, s in ipairs(swatches) do
    color_swatch(s[1], s[2])
    if i < #swatches then
      reaper.ImGui_SameLine(ctx, 0, L.xl)
    end
  end
  vspace(L.xxxl)
end

--- Draws a horizontal bar showing a spacing/dimension value.
local function dimension_bar(label, value, color)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local bar_w = value * UI.bar_scale
  local bar_h = L.lg

  reaper.ImGui_DrawList_AddRectFilled(dl, x, y + 1, x + bar_w, y + bar_h - 1,
    color or P.accent, L.rounding)
  reaper.ImGui_Dummy(ctx, math.max(bar_w, 1), bar_h)

  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_Text(ctx, string.format("%s = %d px", label, value))
end

--- Draws a rounded rectangle preview with its radius value.
local function rounding_preview(label, radius)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local sz = UI.rounding_sz

  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + sz, y + sz, P.accent_d, radius)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + sz, y + sz, P.accent, radius)
  reaper.ImGui_Dummy(ctx, sz, sz)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text)
  reaper.ImGui_Text(ctx, string.format("%s = %d", label, radius))
  reaper.ImGui_PopStyleColor(ctx, 1)
end

--- Renders a single icon in a labeled cell (SameLine-compatible).
--- Uses a single Dummy for the entire cell so it works with SameLine.
local function icon_cell(label, icon_fn, half_size)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cell_w = math.max(half_size * 2 + L.lg * 2, L.xxxl + L.xl)
  local icon_area = half_size * 2 + L.lg * 2
  local label_h = Theme.font_sizes.default + L.sm
  local cell_h = icon_area + label_h
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local cx = x + cell_w * 0.5
  local cy = y + icon_area * 0.5

  -- Background circle
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, half_size + L.sm, P.card)
  -- Icon
  icon_fn(dl, cx, cy, half_size, P.text)
  -- Label centered below (via DrawList)
  local tw = reaper.ImGui_CalcTextSize(ctx, label)
  local label_x = x + (cell_w - tw) * 0.5
  reaper.ImGui_DrawList_AddText(dl, label_x, y + icon_area + L.xs, P.text_dim, label)
  -- Single Dummy for the entire cell
  reaper.ImGui_Dummy(ctx, cell_w, cell_h)
end

-------------------------------------------------------------------------------
-- 5. SECTION: HEADER
-------------------------------------------------------------------------------
local function draw_header()
  return Theme.header(ctx, {
    title         = "DESIGN SYSTEM",
    fonts         = fonts,
    show_settings = true,
    show_close    = true,
    close_id      = "ds_win_close",
  })
end

-------------------------------------------------------------------------------
-- 6. SECTION: COLOR PALETTE
-------------------------------------------------------------------------------
local function draw_colors_section()
  if not Theme.collapsing_header(ctx, "Color Palette") then return end
  reaper.ImGui_Indent(ctx, L.md)
  vspace(L.md)

  swatch_row("Surfaces", {
    { "bg",    P.bg },
    { "panel", P.panel },
    { "card",  P.card },
  }, "WindowBg, popups, frame backgrounds")

  swatch_row("Text", {
    { "text",     P.text },
    { "text_dim", P.text_dim },
  }, "Primary and secondary text")

  swatch_row("Accent — Primary", {
    { "accent",   P.accent },
    { "accent_h", P.accent_h },
    { "accent_d", P.accent_d },
    { "accent_e", P.accent_e },
    { "accent_l", P.accent_l },
  }, "active → hover (80%) → default (33%) → subtle (12%) → light text (70%)")

  swatch_row("Accent — Secondary (Blue)", {
    { "accent2",   P.accent2 },
    { "accent2_h", P.accent2_h },
    { "accent2_d", P.accent2_d },
    { "accent2_e", P.accent2_e },
    { "accent2_l", P.accent2_l },
  }, "Secondary accent, info, badge highlights (aliased to blue)")

  swatch_row("Semantic — Green", {
    { "green",   P.green },
    { "green_h", P.green_h },
    { "green_d", P.green_d },
    { "green_l", P.green_l },
  }, "Success, enabled, positive actions (green_l = 70% lightened text)")

  swatch_row("Semantic — Red", {
    { "red",   P.red },
    { "red_h", P.red_h },
    { "red_d", P.red_d },
    { "red_l", P.red_l },
  }, "Error, delete, destructive actions (red_l = 70% lightened text)")

  swatch_row("Semantic — Yellow", {
    { "yellow",   P.yellow },
    { "yellow_l", P.yellow_l },
  }, "Warning, caution, pending states (yellow_l = 70% lightened text)")

  swatch_row("Semantic — Blue", {
    { "blue",   P.blue },
    { "blue_h", P.blue_h },
    { "blue_d", P.blue_d },
    { "blue_e", P.blue_e },
    { "blue_l", P.blue_l },
  }, "Info, links, secondary accent (aliased to accent2)")

  swatch_row("Structural", {
    { "border", P.border },
    { "sep",    P.sep },
    { "dim_bg", P.dim_bg },
  }, "Borders, separators, modal overlay")

  swatch_row("Table Rows", {
    { "table_row",     P.table_row },
    { "table_row_alt", P.table_row_alt },
  }, "Alternating row backgrounds")

  swatch_row("Controls", {
    { "slider_grab_active", P.slider_grab_active },
  }, "Slider grab while dragging")

  vspace(L.md)
  reaper.ImGui_Unindent(ctx, L.md)
end

-------------------------------------------------------------------------------
-- 7. SECTION: TYPOGRAPHY
-------------------------------------------------------------------------------
local function draw_typography_section()
  if not Theme.collapsing_header(ctx, "Typography") then return end
  reaper.ImGui_Indent(ctx, L.md)
  vspace(L.md)

  local sample = "The quick brown fox jumps over the lazy dog"
  local font_list = {
    { "small",        fonts.small,        Theme.font_sizes.small,   "Labels, secondary text, metadata" },
    { "default",      fonts.default,      Theme.font_sizes.default, "Body text, standard UI elements" },
    { "medium",       fonts.medium,       Theme.font_sizes.medium,  "Emphasized text, settings labels, script titles" },
    { "large",        fonts.large,        Theme.font_sizes.large,   "Section headers, dialog titles" },
    { "header",       fonts.header,       Theme.font_sizes.header,  "Primary headers, window titles" },
    { "default_bold", fonts.default_bold, Theme.font_sizes.default, "Bold body text, labels" },
    { "medium_bold",  fonts.medium_bold,  Theme.font_sizes.medium,  "Bold brand headers, emphasized titles" },
    { "large_bold",   fonts.large_bold,   Theme.font_sizes.large,   "Bold section headers" },
  }

  for _, entry in ipairs(font_list) do
    local name, font, size, desc = entry[1], entry[2], entry[3], entry[4]

    -- Label
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
    reaper.ImGui_Text(ctx, string.format("fonts.%s  (%dpx)", name, size))
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Sample text in the font
    local pushed_f = Theme.push_font(ctx, font)
    reaper.ImGui_Text(ctx, sample)
    Theme.pop_font(ctx, pushed_f)

    -- Description
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_Text(ctx, desc)
    reaper.ImGui_PopStyleColor(ctx, 1)
    vspace(L.xxxl)
  end

  -- Font families
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, string.format("Regular: %s  |  Bold: %s",
    Theme.font_family, Theme.font_bold_family))
  reaper.ImGui_PopStyleColor(ctx, 1)

  vspace(L.lg)
  reaper.ImGui_Unindent(ctx, L.md)
end

-------------------------------------------------------------------------------
-- 8. SECTION: LAYOUT TOKENS
-------------------------------------------------------------------------------
local function draw_layout_section()
  if not Theme.collapsing_header(ctx, "Layout Tokens") then return end
  reaper.ImGui_Indent(ctx, L.md)
  vspace(L.md)

  -- Scale
  Theme.section_divider(ctx, "SCALE", {
    tooltip = "Unified spacing & padding. Use Theme.layout.xs/sm/md/lg/xl/xxl/xxxl",
  })
  dimension_bar("xs = 2",    L.xs, P.green)
  dimension_bar("sm = 4",    L.sm, P.green)
  dimension_bar("md = 8",    L.md, P.green)
  dimension_bar("lg = 12",   L.lg, P.green)
  dimension_bar("xl = 16",   L.xl, P.green)
  dimension_bar("xxl = 24",  L.xxl, P.green)
  dimension_bar("xxxl = 32", L.xxxl, P.green)
  vspace(L.sm)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Pushed by Theme.push():  FramePadding(md,sm)  WindowPadding(lg,lg)")
  reaper.ImGui_Text(ctx, "  ItemSpacing(md,sm)  CellPadding(sm,xs)  InnerSpacing(sm,sm)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- Rounding
  Theme.section_divider(ctx, "ROUNDING", {
    tooltip = "Universal corner radius. Use Theme.layout.rounding",
  })
  rounding_preview("rounding", L.rounding)
  vspace(L.xxxl)

  -- Button & icon presets
  Theme.section_divider(ctx, "BUTTON & ICON PRESETS", {
    tooltip = "Size tiers for text buttons (font+padding) and icon buttons (size+padding).",
  })
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, string.format("btn_sm  = pad(%d,%d) + font '%s'",
    L.btn_sm.pad_x, L.btn_sm.pad_y, L.btn_sm.font))
  reaper.ImGui_Text(ctx, string.format("btn_md  = pad(%d,%d) + font 'default'  (global, no override)",
    L.md, L.sm))
  reaper.ImGui_Text(ctx, string.format("btn_lg  = pad(%d,%d) + font '%s'",
    L.btn_lg.pad_x, L.btn_lg.pad_y, L.btn_lg.font))
  vspace(L.sm)
  reaper.ImGui_Text(ctx, string.format("icon_sm = size %d + pad %d  → btn %dpx",
    L.icon_sm.size, L.icon_sm.pad, L.icon_sm.size + L.icon_sm.pad * 2))
  reaper.ImGui_Text(ctx, string.format("icon_md = size %d + pad %d  → btn %dpx",
    L.icon_md.size, L.icon_md.pad, L.icon_md.size + L.icon_md.pad * 2))
  reaper.ImGui_Text(ctx, string.format("icon_lg = size %d + pad %d  → btn %dpx",
    L.icon_lg.size, L.icon_lg.pad, L.icon_lg.size + L.icon_lg.pad * 2))
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- Table dimensions
  Theme.section_divider(ctx, "TABLE & STRUCTURE", {
    tooltip = "Table and structural dimensions. Use Theme.layout.*",
  })
  dimension_bar("row_h",     L.row_h,     P.red)
  dimension_bar("chk_col_w", L.chk_col_w, P.red)
  dimension_bar("indent",    L.indent,    P.red)
  vspace(L.xxxl)

  -- Modal sizes (text only — they're tables)
  Theme.section_divider(ctx, "MODAL SIZES")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, string.format("modal_sm   = %d x %d", L.modal_sm.w, L.modal_sm.h))
  reaper.ImGui_Text(ctx, string.format("modal_md   = %d x %d", L.modal_md.w, L.modal_md.h))
  reaper.ImGui_Text(ctx, string.format("modal_lg   = %d x %d", L.modal_lg.w, L.modal_lg.h))
  reaper.ImGui_Text(ctx, string.format("modal_xl   = %d x %d", L.modal_xl.w, L.modal_xl.h))
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- Misc
  Theme.section_divider(ctx, "MISC TOKENS & REACTIVE CONTROLS")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, string.format("tooltip_wrap = %d px  |  section_gap = %d px",
    L.tooltip_wrap, L.section_gap))
  reaper.ImGui_Text(ctx, "Combo boxes & dropdowns use Theme.calc_combo_width() to scale dynamically.")
  reaper.ImGui_PopStyleColor(ctx, 1)

  vspace(L.lg)
  reaper.ImGui_Unindent(ctx, L.md)
end

-------------------------------------------------------------------------------
-- 9. SECTION: ICON PRIMITIVES
-------------------------------------------------------------------------------
local function draw_icons_section()
  if not Theme.collapsing_header(ctx, "Icon Primitives") then return end
  reaper.ImGui_Indent(ctx, L.md)
  vspace(L.md)

  local icon_list = {
    { "play",     Theme.icons.play },
    { "pause",    Theme.icons.pause },
    { "close",    Theme.icons.close },
    { "plus",     Theme.icons.plus },
    { "info",     Theme.icons.info },
    { "tri_down", Theme.icons.tri_down },
    { "tri_up",   Theme.icons.tri_up },
  }

  -- Three size tiers deriving from icon presets
  local sizes = {
    { label = string.format("Small (size=%d)", L.icon_sm.size),   hs = math.floor(L.icon_sm.size * 0.5) },
    { label = string.format("Default (size=%d)", L.icon_md.size), hs = math.floor(L.icon_md.size * 0.5) },
    { label = string.format("Large (size=%d)", L.icon_lg.size),   hs = math.floor(L.icon_lg.size * 0.5) },
  }

  for i, sz in ipairs(sizes) do
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
    reaper.ImGui_Text(ctx, sz.label)
    reaper.ImGui_PopStyleColor(ctx, 1)
    vspace(L.sm)

    for j, ic in ipairs(icon_list) do
      icon_cell(ic[1], ic[2], sz.hs)
      if j < #icon_list then
        reaper.ImGui_SameLine(ctx, 0, L.lg)
      end
    end
    if i < #sizes then
      vspace(L.xxxl)
    end
  end

  vspace(L.lg)
  reaper.ImGui_Unindent(ctx, L.md)
end

-------------------------------------------------------------------------------
-- 10. SECTION: WIDGET COMPONENTS
-------------------------------------------------------------------------------
local function draw_widgets_section()
  if not Theme.collapsing_header(ctx, "Widget Components") then return end
  reaper.ImGui_Indent(ctx, L.md)
  vspace(L.md)

  -- Standard buttons
  Theme.section_divider(ctx, "STANDARD BUTTONS", {
    tooltip = "Size = font + padding. Default uses global FramePadding. Push btn_sm/btn_lg for variants.",
  })

  -- Small
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
    L.btn_sm.pad_x, L.btn_sm.pad_y)
  local pushed_sm = Theme.push_font(ctx, fonts[L.btn_sm.font])
  reaper.ImGui_Button(ctx, "Small")
  Theme.pop_font(ctx, pushed_sm)
  reaper.ImGui_PopStyleVar(ctx, 1)

  reaper.ImGui_SameLine(ctx, 0, L.md)

  -- Default (uses global FramePadding + default font — no overrides needed)
  reaper.ImGui_Button(ctx, "Default")

  reaper.ImGui_SameLine(ctx, 0, L.md)

  -- Large
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
    L.btn_lg.pad_x, L.btn_lg.pad_y)
  local pushed_lg = Theme.push_font(ctx, fonts[L.btn_lg.font])
  reaper.ImGui_Button(ctx, "Large")
  Theme.pop_font(ctx, pushed_lg)
  reaper.ImGui_PopStyleVar(ctx, 1)

  reaper.ImGui_SameLine(ctx, 0, L.lg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, string.format("sm=(%d,%d)+%s  default=(%d,%d)+default  lg=(%d,%d)+%s",
    L.btn_sm.pad_x, L.btn_sm.pad_y, L.btn_sm.font,
    L.md, L.sm,
    L.btn_lg.pad_x, L.btn_lg.pad_y, L.btn_lg.font))
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- icon_btn
  Theme.section_divider(ctx, "Theme.icon_btn(ctx, id, icon_fn, [opts])", {
    tooltip = "Invisible button with DrawList icon overlay. Pass opts.preset for size tier.",
  })
  reaper.ImGui_Text(ctx, "sm:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn(ctx, "demo_close_sm", Theme.icons.close, { preset = L.icon_sm })
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_Text(ctx, "md:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn(ctx, "demo_close_md", Theme.icons.close)
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_Text(ctx, "lg:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn(ctx, "demo_close_lg", Theme.icons.close, { preset = L.icon_lg })
  vspace(L.xxxl)

  -- icon_btn_colored
  Theme.section_divider(ctx, "Theme.icon_btn_colored(ctx, id, icon_fn, [opts])", {
    tooltip = "Visible button with colored background. Pass opts.preset for size tier.",
  })
  reaper.ImGui_Text(ctx, "sm:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn_colored(ctx, "demo_col_sm", Theme.icons.plus, { preset = L.icon_sm })
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_Text(ctx, "md:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn_colored(ctx, "demo_col_md", Theme.icons.plus)
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_Text(ctx, "lg:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn_colored(ctx, "demo_col_lg", Theme.icons.plus, { preset = L.icon_lg })
  reaper.ImGui_SameLine(ctx, 0, L.lg)

  reaper.ImGui_Text(ctx, "Green:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn_colored(ctx, "demo_col_play", Theme.icons.play, {
    bg = P.green_d, bg_hover = P.green_h, bg_active = P.green,
  })
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_Text(ctx, "Red:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.icon_btn_colored(ctx, "demo_col_close", Theme.icons.close, {
    bg = P.red_d, bg_hover = P.red_h, bg_active = P.red,
  })
  vspace(L.xxxl)

  -- tooltip
  Theme.section_divider(ctx, "Theme.tooltip(ctx, text, [max_w])", {
    tooltip = "Wrapped tooltip with consistent padding from layout tokens.",
  })
  reaper.ImGui_Button(ctx, "Hover me for tooltip##demo_tt")
  if reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx,
      "This is a Theme.tooltip() demo. Text wraps automatically at " ..
      L.tooltip_wrap .. "px. Padding and font are consistent across all scripts.")
  end
  vspace(L.xxxl)

  -- section_divider
  Theme.section_divider(ctx, "Theme.section_divider(ctx, label, [opts])", {
    tooltip = "Labeled divider with optional info icon. This line IS the demo!",
  })
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "(The divider above is itself a live example of Theme.section_divider)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- collapsing_header
  Theme.section_divider(ctx, "Theme.collapsing_header(ctx, label, [opts])", {
    tooltip = "Standardized collapsing section. Encapsulates ReaImGui argument safety.",
  })
  if Theme.collapsing_header(ctx, "Collapsing Header Demo##demo_header", { default_open = false }) then
    reaper.ImGui_Indent(ctx, L.md)
    vspace(L.sm)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_Text(ctx, "Content inside Theme.collapsing_header()")
    reaper.ImGui_PopStyleColor(ctx, 1)
    vspace(L.sm)
    reaper.ImGui_Unindent(ctx, L.md)
  end
  vspace(L.xxxl)

  -- progress_bar
  Theme.section_divider(ctx, "Theme.progress_bar(ctx, fraction, [opts])", {
    tooltip = "Styled progress/meter bar with DrawList rendering and centered text overlay.",
  })
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Adjust Value:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_SetNextItemWidth(ctx, 180)
  local chg_pv, new_pv = reaper.ImGui_SliderDouble(ctx, "##demo_prog_slider", demo_prog_val, 0.0, 1.0, "%.2f")
  if chg_pv then demo_prog_val = new_pv end

  vspace(L.sm)
  reaper.ImGui_Text(ctx, "Accent Fill:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.progress_bar(ctx, demo_prog_val, {
    w = 200,
    overlay = string.format("%.0f%%", demo_prog_val * 100),
    tooltip = "Default Accent Bar",
  })
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  reaper.ImGui_Text(ctx, "Green dB Meter:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  local db_val = (demo_prog_val * 24.0) - 18.0
  Theme.progress_bar(ctx, demo_prog_val, {
    w = 200,
    fill_color = P.green_d,
    overlay = string.format("%+.1f dB", db_val),
    tooltip = "Green Meter Bar",
  })
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  reaper.ImGui_Text(ctx, "Red Limit:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.progress_bar(ctx, demo_prog_val, {
    w = 120,
    fill_color = P.red_d,
    overlay = demo_prog_val > 0.85 and "OVER" or "OK",
    tooltip = "Red Threshold Bar",
  })
  vspace(L.xxxl)

  -- toggle_button
  Theme.section_divider(ctx, "Theme.toggle_button(ctx, id, label, is_active, [opts])", {
    tooltip = "Button-derived toggle button inheriting parent frame padding, text centering, and rounding.",
  })
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Mode Toggle:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  local mode_label = demo_mode_active and "INVERSE" or "FOLLOW"
  if Theme.toggle_button(ctx, "demo_mode_btn", mode_label, demo_mode_active, {
    active_bg      = P.accent_d,
    active_hover   = P.accent_h,
    active_active  = P.accent,
    active_text    = P.accent_l,
    inactive_bg    = P.green_d,
    inactive_hover = P.green_h,
    inactive_active= P.green,
    inactive_text  = P.green_l,
    tooltip = "Click to toggle mode",
  }) then
    demo_mode_active = not demo_mode_active
  end

  reaper.ImGui_SameLine(ctx, 0, L.xl)
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Toggle Switch:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  local toggle_lbl = demo_badge_active and "ACTIVE" or "MUTED"
  if Theme.toggle_button(ctx, "demo_toggle_switch", toggle_lbl, demo_badge_active, {
    active_bg      = P.accent_d,
    active_hover   = P.accent_h,
    active_active  = P.accent,
    active_text    = P.accent_l,
    inactive_bg    = P.card,
    inactive_hover = P.panel,
    inactive_active= P.accent_d,
    inactive_text  = P.text_dim,
    tooltip = "Click to toggle state",
  }) then
    demo_badge_active = not demo_badge_active
  end
  vspace(L.xxxl)

  -- badge
  Theme.section_divider(ctx, "Theme.badge(ctx, label, [opts])", {
    tooltip = "Button-derived status badge with centered text, frame padding, and semantic theme colors.",
  })
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Status Badges:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.badge(ctx, "ACTIVE", { color = P.green, tooltip = "Online and running" })
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.badge(ctx, "INFO", { color = P.blue, tooltip = "Informational status (secondary accent)" })
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.badge(ctx, "INVERSE", { color = P.accent, tooltip = "Inverse tracking mode" })
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.badge(ctx, "WARNING", { color = P.yellow, tooltip = "High CPU or pending link" })
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.badge(ctx, "OFFLINE", { color = P.red, tooltip = "Track or plugin missing" })
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.badge(ctx, "BYPASS", { color = P.text_dim, tooltip = "Processing bypassed" })
  vspace(L.xxxl)

  -- Small Button Preset (btn_sm for tables)
  Theme.section_divider(ctx, "TABLE CONTROLS PRESET: Theme.layout.btn_sm", {
    tooltip = "Unified 16px compact sizing (pad_x=4, pad_y=2, font=small) for table rows and dense data grids.",
  })
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Live Values:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.align(ctx, nil, L.btn_sm.h)
  Theme.progress_bar(ctx, demo_prog_val, {
    w = 120,
    preset = L.btn_sm,
    fonts = fonts,
    fill_color = P.green_d,
    overlay = string.format("%.0f%%", demo_prog_val * 100),
  })
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Mode:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.align(ctx, nil, L.btn_sm.h)
  local sm_mode_lbl = demo_mode_active and "INV" or "FLW"
  if Theme.toggle_button(ctx, "demo_sm_mode", sm_mode_lbl, demo_mode_active, {
    w = 54,
    preset = L.btn_sm,
    fonts = fonts,
    active_bg      = P.accent_d,
    active_hover   = P.accent_h,
    active_active  = P.accent,
    active_text    = P.accent_l,
    inactive_bg    = P.green_d,
    inactive_hover = P.green_h,
    inactive_active= P.green,
    inactive_text  = P.green_l,
  }) then
    demo_mode_active = not demo_mode_active
  end
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Strength:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.align(ctx, nil, L.btn_sm.h)
  reaper.ImGui_SetNextItemWidth(ctx, 90)
  local sp_vars, sp_font = Theme.push_button_preset(ctx, fonts, L.btn_sm)
  local _, new_pct = reaper.ImGui_SliderDouble(ctx, "##demo_sm_slider", demo_prog_val * 100, 0, 100, "%.0f%%")
  Theme.pop_button_preset(ctx, sp_vars, sp_font)
  demo_prog_val = new_pct / 100
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Badge:")
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.align(ctx, nil, L.btn_sm.h)
  Theme.badge(ctx, "OFFLINE", { color = P.red, preset = L.btn_sm, fonts = fonts })
  vspace(L.xxxl)

  -- combo
  Theme.section_divider(ctx, "Theme.combo(ctx, id, items, selected_idx, [opts])", {
    tooltip = "Standardized combo box wrapping ImGui_BeginCombo with automatic item extraction.",
  })
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Plugin Selector:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  local new_sel, chg_sel = Theme.combo(ctx, "##demo_combo_box", demo_combo_items, demo_combo_sel, {
    w = 260,
    tooltip = "Select a plugin from list",
  })
  if chg_sel then demo_combo_sel = new_sel end
  reaper.ImGui_SameLine(ctx, 0, L.md)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, string.format("(Selected index: %d)", demo_combo_sel))
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- multi_combo
  Theme.section_divider(ctx, "Theme.multi_combo(ctx, id, items, selected, [opts])", {
    tooltip = "Standardized multi-select combo with full-row clicking, hover highlights, and compact density.",
  })
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Multi-Selector:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  local t_idx, is_sel, chg_multi = Theme.multi_combo(ctx, "##demo_multi_combo_box", demo_combo_items, demo_multi_combo_sel, {
    w = 260,
    show_count = true,
    placeholder = "+ Select items...",
    tooltip = "Click any row to toggle selection",
  })
  if chg_multi and t_idx then
    demo_multi_combo_sel[t_idx] = is_sel or nil
  end
  vspace(L.xxxl)

  -- center_next_window
  Theme.section_divider(ctx, "Theme.center_next_window(ctx, w, h)")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Centers the next ImGui window on the viewport. Use before Begin/BeginPopupModal.")
  reaper.ImGui_Text(ctx, "Example: Theme.center_next_window(ctx, Theme.layout.modal_md.w, Theme.layout.modal_md.h)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- brand_icon
  Theme.section_divider(ctx, "Theme.brand_icon(ctx, [size], [target_h])")
  reaper.ImGui_Text(ctx, string.format("%dpx:", L.row_h))
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.brand_icon(ctx, L.row_h, L.row_h)
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  local brand_md = L.xxl + L.lg
  reaper.ImGui_Text(ctx, string.format("%dpx:", brand_md))
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.brand_icon(ctx, brand_md, brand_md)
  reaper.ImGui_SameLine(ctx, 0, L.lg)
  local brand_lg = L.xxxl * 2
  reaper.ImGui_Text(ctx, string.format("%dpx:", brand_lg))
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.brand_icon(ctx, brand_lg, brand_lg)
  vspace(L.xxxl)

  -- Theme.header (Window header widget)
  Theme.section_divider(ctx, "Theme.header(ctx, opts)", {
    tooltip = "Composite window header widget with brand icon, title, subtitle, settings, and close button.",
  })
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Renders a toolbar header with pixel-perfect vertical alignment and right-align.")
  reaper.ImGui_Text(ctx, "Example: Theme.header(ctx, { title = 'My Script', subtitle = 'v1.0.0', fonts = fonts, show_settings = true })")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.sm)
  -- Embedded mini-header preview
  Theme.header(ctx, {
    title          = "Preview Header",
    subtitle       = "Embedded demonstration",
    fonts          = fonts,
    show_settings  = false,
    show_close     = false,
    show_separator = false,
  })
  vspace(L.xxxl)

  -- push_font / pop_font
  Theme.section_divider(ctx, "Theme.push_font / pop_font")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Safe pcall wrappers for ImGui_PushFont / PopFont.")
  reaper.ImGui_Text(ctx, "local pushed = Theme.push_font(ctx, fonts.large_bold)")
  reaper.ImGui_Text(ctx, "Theme.pop_font(ctx, pushed)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- settings_widget
  Theme.section_divider(ctx, "Theme.settings_widget(ctx)")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Theme mode combo box (shown in header above). Persists via ExtState.")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xxxl)

  -- Alignment helpers
  Theme.section_divider(ctx, "ALIGNMENT HELPERS", {
    tooltip = "Theme.align, Theme.vcenter, Theme.right_align, Theme.hcenter — position items consistently.",
  })

  -- Theme.align (primary)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
  reaper.ImGui_Text(ctx, "Theme.align(ctx, [row_h], [item_h])")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "THE primary alignment function. Call before every item on a SameLine row.")
  reaper.ImGui_Text(ctx, "No args: aligns text baseline to framed widgets. row_h: centers in explicit row.")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.sm)

  -- Live demo: text + button + badge on one row
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Label:")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.align(ctx)
  reaper.ImGui_Button(ctx, "Aligned Button##demo_align")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.align(ctx)
  Theme.badge(ctx, "BADGE", { color = P.green })
  vspace(L.xl)

  -- vcenter demo (including ref_y pattern)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
  reaper.ImGui_Text(ctx, "Theme.vcenter(ctx, item_h, row_h, [ref_y]) (low-level)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Low-level cursor math. Prefer Theme.align(ctx, row_h) for standard use cases.")
  reaper.ImGui_Text(ctx, "Example: local start_y = reaper.ImGui_GetCursorPosY(ctx)")
  reaper.ImGui_Text(ctx, "         Theme.vcenter(ctx, item_h, row_h, start_y)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  vspace(L.xl)

  -- right_align demo
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
  reaper.ImGui_Text(ctx, "Theme.right_align(ctx, item_w, [margin])")
  reaper.ImGui_PopStyleColor(ctx, 1)
  local ra_label = "Right-aligned"
  local ra_w = reaper.ImGui_CalcTextSize(ctx, ra_label) + L.md * 2
  Theme.right_align(ctx, ra_w)
  reaper.ImGui_Button(ctx, ra_label .. "##demo_ra")
  vspace(L.xl)

  -- hcenter demo
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
  reaper.ImGui_Text(ctx, "Theme.hcenter(ctx, item_w)")
  reaper.ImGui_PopStyleColor(ctx, 1)
  local hc_label = "Centered"
  local hc_w = reaper.ImGui_CalcTextSize(ctx, hc_label) + L.md * 2
  Theme.hcenter(ctx, hc_w)
  reaper.ImGui_Button(ctx, hc_label .. "##demo_hc")
  vspace(L.xxxl)

  -- Pushed style vars summary
  Theme.section_divider(ctx, "PUSHED STYLE VARS (via Theme.push)")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "32 colors + 9 style vars are pushed automatically:")
  reaper.ImGui_Text(ctx, "  WindowRounding, FrameRounding, GrabRounding,")
  reaper.ImGui_Text(ctx, "  ItemSpacing, FramePadding, WindowPadding,")
  reaper.ImGui_Text(ctx, "  CellPadding, ItemInnerSpacing, IndentSpacing")
  reaper.ImGui_PopStyleColor(ctx, 1)

  vspace(L.lg)
  reaper.ImGui_Unindent(ctx, L.md)
end

-------------------------------------------------------------------------------
-- 11. MAIN LOOP
-------------------------------------------------------------------------------
local function loop()
  -- Rebuild palette each frame (handles live theme changes)
  P = Theme.build_palette()
  L = Theme.layout

  local nc, nv = Theme.push(ctx, P)
  local pushed_default = Theme.push_font(ctx, fonts.default)

  Theme.center_next_window(ctx, UI.win_w, UI.win_h)
  local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoTitleBar()
  local visible = reaper.ImGui_Begin(ctx, "Fancy Design System", nil, flags)

  local open = true

  if visible then
    open = draw_header()
    draw_colors_section()
    draw_typography_section()
    draw_layout_section()
    draw_icons_section()
    draw_widgets_section()
    reaper.ImGui_End(ctx)
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    open = false
  end

  Theme.pop_font(ctx, pushed_default)
  Theme.pop(ctx, nc, nv)

  if open then
    reaper.defer(loop)
  end
end

-------------------------------------------------------------------------------
-- 12. ENTRY POINT
-------------------------------------------------------------------------------
local function main()
  reaper.defer(loop)
end

main()
