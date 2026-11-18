-- Theme tests. Run from the repo root: lua docs/superpowers/tests/theme_spec.lua
package.path = "_lib/?.lua;docs/superpowers/tests/?.lua;" .. package.path

local stub_lib = require("reaper_stub")

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Fresh stub installed as the global `reaper`, fresh library.
local function load_theme(opts)
  local stub = stub_lib.new(opts)
  reaper = stub.reaper
  package.loaded.theme = nil
  local Theme = require("theme")
  return Theme, stub
end

local function all(calls, name)
  local out = {}
  for _, c in ipairs(calls) do
    if c[1] == name then out[#out + 1] = c end
  end
  return out
end

local function count(calls, name) return #all(calls, name) end
local function first(calls, name) return all(calls, name)[1] end
local function last(calls, name)
  local list = all(calls, name)
  return list[#list]
end

local function contains(list, value) -- luacheck: ignore 211 (used by later tasks)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local REAPERTIPS, LIGHT = stub_lib.REAPERTIPS, stub_lib.LIGHT

--- WCAG 2.x relative luminance of 0xRRGGBBAA (alpha ignored), written independently of the library.
local function lum(c)
  local function ch(shift)
    local v = ((c >> shift) & 0xFF) / 255
    if v <= 0.03928 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * ch(24) + 0.7152 * ch(16) + 0.0722 * ch(8)
end

--- Alpha-composites fg over the opaque colour under; returns an opaque colour.
local function composite(fg, under)
  local a = (fg & 0xFF) / 255
  local out = 0
  for shift = 24, 8, -8 do
    local f, u = (fg >> shift) & 0xFF, (under >> shift) & 0xFF
    out = out | (math.floor(f * a + u * (1 - a) + 0.5) << shift)
  end
  return out | 0xFF
end

--- WCAG contrast of fg (alpha composited first) over the opaque colour bg.
local function contrast(fg, bg)
  local l1, l2 = lum(composite(fg, bg)), lum(bg)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

--- Colours pushed by Theme.push, keyed by enum name (last push wins).
local function pushed_colors(stub)
  local out = {}
  for _, c in ipairs(all(stub.calls, "ImGui_PushStyleColor")) do out[stub.enum_name(c[2])] = c[3] end
  return out
end

--- Style vars pushed by Theme.push, keyed by enum name; value is { a, b }.
local function pushed_vars(stub)
  local out = {}
  for _, c in ipairs(all(stub.calls, "ImGui_PushStyleVar")) do out[stub.enum_name(c[2])] = { c[3], c[4] } end
  return out
end

--- Recorded AddRectFilled calls: true when one fills with `colour`.
local function find_fill(fills, colour)
  for _, f in ipairs(fills) do
    if f.color == colour then return f end
  end
  return nil
end

local function has_fill(fills, colour) return find_fill(fills, colour) ~= nil end

--- Sum of the counts popped by the recorded calls named `name` (a pop without a count pops one).
local function popped(calls, name)
  local n = 0
  for _, c in ipairs(all(calls, name)) do n = n + (c[2] or 1) end
  return n
end

-------------------------------------------------------------------------------
-- Runner
-------------------------------------------------------------------------------

local failures, total = 0, 0

local function test(name, fn)
  total = total + 1
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    print("ok    " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. "\n" .. tostring(err))
  end
end

-------------------------------------------------------------------------------
-- Task 1: fonts
-------------------------------------------------------------------------------

test("fonts: new API loads the bundled files", function()
  local T, stub = load_theme({})                      -- CreateFontFromFile present
  local fonts = T.create_fonts(nil)
  local n = count(stub.calls, "ImGui_CreateFontFromFile")
  assert(n == 8, "8 fonts from file, got " .. n)
  assert(first(stub.calls, "ImGui_CreateFontFromFile")[2]:match("_lib[/\\]fonts[/\\]FiraSans%-Regular%.otf$"))
  assert(T.font_source == "file")
  for _, k in ipairs({ "default", "small", "medium", "large", "header", "default_bold", "medium_bold", "large_bold", "tooltip" }) do
    assert(fonts[k] ~= nil, k)
  end
  assert(T._font_sizes[fonts.default] == 13 and T._font_sizes[fonts.small] == 11 and T._font_sizes[fonts.header] == 18)
end)

test("fonts: missing file falls back to the family, no error", function()
  local T, stub = load_theme({})
  T.font_dir = "/nonexistent/"
  T.create_fonts(nil)
  assert(count(stub.calls, "ImGui_CreateFontFromFile") == 0)
  assert(first(stub.calls, "ImGui_CreateFont")[2] == "Fira Sans")
  assert(T.font_source == "family")
end)

test("fonts: file load failing falls back, no error", function()
  local T = load_theme({ fail = { "ImGui_CreateFontFromFile" } })
  local fonts = T.create_fonts(nil)
  assert(fonts.default ~= nil and T.font_source == "family")
end)

test("fonts: family failing falls back to sans-serif", function()
  local T, stub = load_theme({ fail = { "ImGui_CreateFontFromFile", "ImGui_CreateFont:Fira Sans" } })
  T.create_fonts(nil)
  assert(T.font_source == "system")
  assert(last(stub.calls, "ImGui_CreateFont")[2]:match("^sans%-serif"))
end)

test("fonts: old ReaImGui without CreateFontFromFile still works", function()
  local T, stub = load_theme({ missing = { "ImGui_CreateFontFromFile" } })
  local fonts = T.create_fonts(nil)
  assert(fonts.default ~= nil and fonts.default_bold ~= nil)
  local c = first(stub.calls, "ImGui_CreateFont")
  assert(c[3] == 13, "old API passes the size as the second argument")
end)

-------------------------------------------------------------------------------
-- Task 2: palette
-------------------------------------------------------------------------------

test("palette: curated values", function()
  local T = load_theme({ mode = "fancy" })
  local P = T.build_palette()
  local want = {
    bg = 0x323232FF, panel = 0x3E3E3EFF, card = 0x424242FF, text = 0xD9D9D9FF, accent = 0x46B9FEFF,
    accent2 = 0xA990F5FF, blue = 0xA990F5FF, green = 0x44CD8CFF, red = 0xE45E65FF, yellow = 0xFEC13AFF,
    border = 0x181818FF, outline = 0x181818FF, sep = 0x1D1D1DFF,
    btn = 0x454545FF, btn_h = 0x585858FF, btn_a = 0x2E2E2EFF, btn_on = 0x46B9FEFF,
    well = 0x2A2A2AFF, thumb = 0xC2C2C2FF, thumb_a = 0xD9D9D9FF,
    tab = 0x383838FF, tab_h = 0x4D4D4DFF, tab_sel = 0x585858FF, hover = 0x4D4D4DFF, title = 0x2D2D2DFF,
    scroll = 0xFFFFFF2B, scroll_h = 0xFFFFFF42, scroll_a = 0xFFFFFF59,
  }
  for k, v in pairs(want) do assert(P[k] == v, string.format("%s: want %08X got %08X", k, v, P[k] or 0)) end
  assert(P.select == T.with_alpha(P.accent, 0.25))
end)

test("palette: every pre-existing field is still there", function()
  local P = load_theme({ mode = "fancy" }).build_palette()
  for _, k in ipairs({ "bg", "panel", "card", "text", "text_dim", "accent", "accent_h", "accent_d", "accent_e",
    "accent_l", "accent_press", "accent2", "accent2_h", "accent2_d", "accent2_e", "accent2_l", "blue", "blue_h",
    "blue_d", "blue_e", "blue_l", "green", "green_h", "green_d", "green_l", "red", "red_h", "red_d", "red_l",
    "yellow", "yellow_l", "border", "sep", "dim_bg", "table_row", "table_row_alt", "slider_grab_active", "canvas" }) do
    assert(P[k] ~= nil, k)
  end
end)

local function contrast_rules(P)
  for _, s in ipairs({ P.bg, P.panel, P.card, P.btn, P.well }) do
    assert(contrast(P.text, s) >= 4.5, "text")
    assert(contrast(P.text_dim, s) >= 4.5, "text_dim")
  end
  assert(contrast(P.on_text, P.btn_on) >= 4.5, "on_text on btn_on")
  assert(contrast(P.btn_on, P.btn) >= 3.0, "on vs off face")
  assert(contrast(P.thumb, P.well) >= 3.0, "thumb on well")
  assert(contrast(P.accent, P.well) >= 3.0, "check mark on well")
  for _, s in ipairs({ P.bg, P.panel, P.card }) do
    assert(contrast(P.text, composite(P.select, s)) >= 4.5, "text on selected row")
    assert(contrast(P.accent, s) >= 3.0, "selection bar")
  end
end

test("palette: contrast rules, curated", function() contrast_rules(load_theme({ mode = "fancy" }).build_palette()) end)
test("palette: contrast rules, Match Theme on Reapertips", function()
  contrast_rules(load_theme({ mode = "match", theme = REAPERTIPS }).build_palette()) end)
test("palette: contrast rules, Match Theme on a light theme", function()
  contrast_rules(load_theme({ mode = "match", theme = LIGHT }).build_palette()) end)

test("palette: curated mode ignores the REAPER theme", function()
  local a = load_theme({ mode = "fancy", theme = LIGHT }).build_palette()
  assert(a.bg == 0x323232FF and a.btn == 0x454545FF)
end)

test("palette: overrides win for old and new fields", function()
  local P = load_theme({ mode = "fancy" }).build_palette({ accent = 0xFF0000FF, btn = 0x111111FF, well = 0x222222FF })
  assert(P.accent == 0xFF0000FF and P.btn == 0x111111FF and P.well == 0x222222FF)
  assert(P.btn_on == 0xFF0000FF, "btn_on follows an overridden accent")
end)

test("palette: Match outline is bg moved away from the text, unfitted; border stays fitted", function()
  local P = load_theme({ mode = "match", theme = REAPERTIPS }).build_palette()
  assert(P.outline ~= P.border and lum(P.outline) < lum(P.bg), "darker than bg on a dark theme")
  assert(contrast(P.border, P.bg) >= 3.0, "border still fitted")
  local L = load_theme({ mode = "match", theme = LIGHT }).build_palette()
  assert(lum(L.outline) >= lum(L.bg), "lighter than bg on a light theme")
  local O = load_theme({ mode = "match", theme = REAPERTIPS }).build_palette({ outline = 0x123456FF })
  assert(O.outline == 0x123456FF)
  local C = load_theme({ mode = "fancy" }).build_palette()
  assert(C.outline == 0x181818FF and C.border == 0x181818FF)
end)

test("palette: Match text is the stronger of the two theme text colours", function()
  for _, fx in ipairs({ REAPERTIPS, LIGHT }) do
    local P = load_theme({ mode = "match", theme = fx }).build_palette()
    assert(P.text ~= P.text_dim and contrast(P.text, P.bg) > contrast(P.text_dim, P.bg))
  end
end)

-------------------------------------------------------------------------------
-- Task 3: layout tokens and style stack
-------------------------------------------------------------------------------

test("push: counts match what was pushed, and pop balances", function()
  local T, stub = load_theme({ mode = "fancy" })
  local nc, nv = T.push("ctx", T.build_palette())
  assert(nc == count(stub.calls, "ImGui_PushStyleColor") and nv == count(stub.calls, "ImGui_PushStyleVar"))
  T.pop("ctx") -- no counts: defaults must match
  assert(last(stub.calls, "ImGui_PopStyleColor")[2] == nc and last(stub.calls, "ImGui_PopStyleVar")[2] == nv)
  T.pop("ctx", 3, 2) -- explicit counts win
  assert(last(stub.calls, "ImGui_PopStyleColor")[2] == 3 and last(stub.calls, "ImGui_PopStyleVar")[2] == 2)
end)

test("push: role mapping", function()
  local T, stub = load_theme({ mode = "fancy" })
  local P = T.build_palette(); T.push("ctx", P)
  local col = pushed_colors(stub)
  local want = {
    Button = P.btn, ButtonHovered = P.btn_h, ButtonActive = P.btn_a,
    FrameBg = P.well, FrameBgHovered = P.well_h, FrameBgActive = P.well_a,
    SliderGrab = P.thumb, SliderGrabActive = P.thumb_a, CheckMark = P.accent,
    Header = P.select, HeaderHovered = P.hover,
    Tab = P.tab, TabHovered = P.tab_h, TabSelected = P.tab_sel, TabSelectedOverline = P.accent,
    TabDimmed = P.tab, TabDimmedSelected = P.tab_sel,
    ScrollbarGrab = P.scroll, ScrollbarGrabHovered = P.scroll_h, ScrollbarGrabActive = P.scroll_a,
    Separator = P.sep, SeparatorHovered = P.accent_h, SeparatorActive = P.accent,
    TitleBg = P.title, TitleBgActive = P.title, PopupBg = P.panel, Border = P.outline,
    WindowBg = P.bg, Text = P.text, TextDisabled = P.text_dim,
    TableHeaderBg = P.card, TableBorderStrong = P.sep, TableBorderLight = P.sep, TableRowBg = P.bg,
  }
  for k, v in pairs(want) do assert(col["ImGui_Col_" .. k] == v, k) end
  assert(col.ImGui_Col_ScrollbarBg & 0xFF == 0, "scrollbar track is transparent")
  assert(col.ImGui_Col_HeaderActive >> 8 == P.select >> 8 and (col.ImGui_Col_HeaderActive & 0xFF) > (P.select & 0xFF),
    "HeaderActive is select, stronger")
  assert(col.ImGui_Col_TableRowBgAlt ~= P.bg and col.ImGui_Col_TableRowBgAlt == T.lighten(P.bg, 0.03))
end)

test("push: style vars", function()
  local T, stub = load_theme({ mode = "fancy" })
  T.push("ctx", T.build_palette())
  local v = pushed_vars(stub)
  assert(v.ImGui_StyleVar_FrameRounding[1] == 2 and v.ImGui_StyleVar_GrabRounding[1] == 2 and v.ImGui_StyleVar_WindowRounding[1] == 2)
  assert(v.ImGui_StyleVar_ItemSpacing[1] == 4 and v.ImGui_StyleVar_ItemSpacing[2] == 4)
  assert(v.ImGui_StyleVar_WindowPadding[1] == 8 and v.ImGui_StyleVar_WindowPadding[2] == 8)
  assert(v.ImGui_StyleVar_FramePadding[1] == 8 and v.ImGui_StyleVar_FramePadding[2] == 4)
  assert(v.ImGui_StyleVar_FrameBorderSize[1] == 1)
end)

test("push: an older ReaImGui without the Tab colours still balances", function()
  local T, stub = load_theme({ mode = "fancy", missing = { "ImGui_Col_TabSelected", "ImGui_Col_TabSelectedOverline",
    "ImGui_Col_TabDimmed", "ImGui_Col_TabDimmedSelected" } })
  local nc = T.push("ctx", T.build_palette())
  assert(nc == count(stub.calls, "ImGui_PushStyleColor"))
  assert(pushed_colors(stub).ImGui_Col_TabSelected == nil and pushed_colors(stub).ImGui_Col_Tab ~= nil)
  T.pop("ctx"); assert(last(stub.calls, "ImGui_PopStyleColor")[2] == nc)
end)

test("layout: scale unchanged, rounding 2", function()
  local L = load_theme({}).layout
  assert(L.xs == 2 and L.sm == 4 and L.md == 8 and L.lg == 12 and L.xl == 16 and L.xxl == 24 and L.xxxl == 32)
  assert(L.rounding == 2 and L.border == 1)
  assert(L.btn_sm.h == 15 and L.btn_default.h == 21 and L.btn_lg.h == 22)
end)


-------------------------------------------------------------------------------
-- Task 4: library widgets
-------------------------------------------------------------------------------

test("toggle_button: on is solid, off is a plain button", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.toggle_button("ctx", "id", "Label", true)
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == P.btn_on and c.ImGui_Col_Text == P.on_text)
  assert(c.ImGui_Col_ButtonHovered == T.lighten(P.btn_on, 0.12) and c.ImGui_Col_ButtonActive == T.darken(P.btn_on, 0.12))
  stub.calls = {}; T.toggle_button("ctx", "id", "Label", false)
  c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == P.btn and c.ImGui_Col_ButtonHovered == P.btn_h and c.ImGui_Col_Text == P.text)
  assert(c.ImGui_Col_ButtonActive == P.btn_a)
end)

test("toggle_button: a script's colours win", function()
  local T, stub = load_theme({ mode = "fancy" })
  T.toggle_button("ctx", "id", "L", true, { active_bg = 0x112233FF, active_text = 0xEEEEEEFF })
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == 0x112233FF and c.ImGui_Col_Text == 0xEEEEEEFF)
  stub.calls = {}; T.toggle_button("ctx", "id", "L", true, { active_bg = 0xFEC13AFF })
  c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == 0xFEC13AFF and contrast(c.ImGui_Col_Text, 0xFEC13AFF) >= 4.5, "fitted label")
end)

test("badge: default is a quiet tag; a coloured badge is solid with a readable label", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.badge("ctx", "Lead Vox")
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == P.well and c.ImGui_Col_Text == P.text)
  for _, col in ipairs({ P.green, P.red, P.yellow, P.accent, P.accent2, P.text_dim }) do
    stub.calls = {}; T.badge("ctx", "x", { color = col })
    c = pushed_colors(stub)
    assert(c.ImGui_Col_Button == col, "solid fill")
    assert(contrast(c.ImGui_Col_Text, col) >= 4.5, "label readable")
  end
  stub.calls = {}; T.badge("ctx", "x", { color = P.green, bg = 0x101010FF, text_color = 0xFAFAFAFF })
  c = pushed_colors(stub); assert(c.ImGui_Col_Button == 0x101010FF and c.ImGui_Col_Text == 0xFAFAFAFF)
end)

test("badge: colour plus bg from a script keeps a readable label; interactive hover follows the fill", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  for _, pair in ipairs({ { P.green_l, P.green_d }, { P.red_l, P.red_d }, { P.accent_l, P.accent_d },
                          { P.yellow, T.with_alpha(P.yellow, 0.22) }, { P.red, T.with_alpha(P.red, 0.2) } }) do
    stub.calls = {}; T.badge("ctx", "x", { color = pair[1], bg = pair[2] })
    local c = pushed_colors(stub)
    assert(c.ImGui_Col_Button == pair[2], "bg wins")
    assert(contrast(c.ImGui_Col_Text, composite(pair[2], P.bg)) >= 4.5, "label readable on the bg")
  end
  stub.calls = {}; T.badge("ctx", "x", { color = P.green, interactive = true })
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_ButtonHovered == T.lighten(P.green, 0.12) and c.ImGui_Col_ButtonActive == T.darken(P.green, 0.12))
end)

test("label_on: P.text when it reads, else the better of dark and white, fitted", function()
  local T = load_theme({ mode = "fancy" }); local P = T.get_palette()
  assert(T.label_on(P.well) == P.text and T.label_on(P.btn) == P.text)
  assert(T.label_on(P.accent) == 0x0F2B3BFF)
  assert(T.label_on(0x2E51DEFF) == 0xFFFFFFFF)
  assert(contrast(T.label_on(P.red), P.red) >= 4.5)
end)

test("selectable: selected row is the tint plus a 2 px accent bar", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.selectable("ctx", "Row", true)
  local fills = all(stub.calls, "ImGui_DrawList_AddRectFilled")
  assert(has_fill(fills, P.select), "tint")
  local bar = find_fill(fills, P.accent); assert(bar and (bar.x2 - bar.x1) == 2, "bar")
  assert(bar.x1 == 0 and bar.y1 == 0 and bar.y2 == 20, "bar spans the row at its left edge")
  assert(last(stub.calls, "ImGui_DrawList_AddText").color == P.text)
  stub.calls = {}; T.selectable("ctx", "Row", false)
  assert(count(stub.calls, "ImGui_DrawList_AddRectFilled") == 0, "nothing at rest")
  stub.calls = {}; T.selectable("ctx", "Row", true, nil, nil, nil, { bg_sel = 0x123456FF, text_col = 0xABCDEFFF })
  fills = all(stub.calls, "ImGui_DrawList_AddRectFilled")
  assert(has_fill(fills, 0x123456FF) and last(stub.calls, "ImGui_DrawList_AddText").color == 0xABCDEFFF)
end)

test("selectable: hover fill", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  stub.reaper.ImGui_IsItemHovered = function() return true end
  T.selectable("ctx", "Row", false)
  assert(has_fill(all(stub.calls, "ImGui_DrawList_AddRectFilled"), P.hover))
end)

test("icon_btn: transparent at rest", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.icon_btn("ctx", "##x", T.icons.close)
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Button & 0xFF == 0 and c.ImGui_Col_ButtonHovered == P.btn_h and c.ImGui_Col_ButtonActive == P.btn_a)
end)

test("icon_btn_colored and progress_bar defaults", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.icon_btn_colored("ctx", "##y", T.icons.plus)
  local c = pushed_colors(stub); assert(c.ImGui_Col_Button == P.btn and c.ImGui_Col_ButtonHovered == P.btn_h)
  stub.calls = {}; T.progress_bar("ctx", 0.5)
  local fills = all(stub.calls, "ImGui_DrawList_AddRectFilled")
  assert(has_fill(fills, P.well) and has_fill(fills, P.accent))
  assert(first(stub.calls, "ImGui_DrawList_AddRect").color == P.outline)
end)

test("combo: the preview is a button face", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.combo("ctx", "##c", { "A", "B" }, 1)
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_FrameBg == P.btn and c.ImGui_Col_FrameBgHovered == P.btn_h)
end)

test("section_divider, collapsing_header, tooltip, brand_icon, header colours", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.section_divider("ctx", "Section")
  assert(pushed_colors(stub).ImGui_Col_Separator == P.sep)
  stub.calls = {}; T.collapsing_header("ctx", "Head")
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Header == P.btn and c.ImGui_Col_HeaderHovered == P.btn_h and c.ImGui_Col_HeaderActive == P.btn_a)
  stub.calls = {}; T.tooltip("ctx", "Tip")
  c = pushed_colors(stub)
  assert(c.ImGui_Col_PopupBg == P.panel and c.ImGui_Col_Border == P.outline)
  stub.calls = {}; T.brand_icon("ctx", 24)
  assert(first(stub.calls, "ImGui_DrawList_AddRectFilled").color == P.well)
  assert(first(stub.calls, "ImGui_DrawList_AddRect").color == P.outline)
  stub.calls = {}; T.header("ctx", { title = "T", icon_fn = false })
  local fills = all(stub.calls, "ImGui_DrawList_AddRectFilled")
  local strip, line = find_fill(fills, P.title), find_fill(fills, P.sep)
  assert(strip and line and line.y2 - line.y1 == 1 and line.y1 == strip.y2, "title strip with a hairline under it")
  local fonts = T.create_fonts(nil)
  stub.calls = {}; T.header("ctx", { title = "T", icon_fn = false, fancy_prefix = false, fonts = fonts })
  assert(first(stub.calls, "ImGui_PushFont")[2] == fonts.default_bold, "title in the bold font")
end)

test("settings label", function()
  assert(load_theme({}).mode_labels[1] == "Fancy" and load_theme({}).mode_labels[2] == "Match Theme")
end)

test("widgets: every push has its pop, on every path", function()
  local function run(fn, hovered)
    local T, stub = load_theme({ mode = "fancy" })
    local fonts = T.create_fonts(nil)
    local r = stub.reaper
    for _, n in ipairs({ "ImGui_BeginCombo", "ImGui_BeginTooltip", "ImGui_IsItemHovered", "ImGui_IsPopupOpen",
                         "ImGui_CollapsingHeader" }) do
      r[n] = function() return hovered end
    end
    stub.calls = {}
    fn(T, fonts)
    local tag = hovered and " (hovered/open)" or " (at rest)"
    assert(count(stub.calls, "ImGui_PushStyleColor") == popped(stub.calls, "ImGui_PopStyleColor"), "colours" .. tag)
    assert(count(stub.calls, "ImGui_PushStyleVar") == popped(stub.calls, "ImGui_PopStyleVar"), "vars" .. tag)
    assert(count(stub.calls, "ImGui_PushFont") == count(stub.calls, "ImGui_PopFont"), "fonts" .. tag)
  end
  local cases = {
    function(T, f) T.toggle_button("ctx", "a", "A", true, { preset = "small", fonts = f, rounding = 3, tooltip = "t" }) end,
    function(T, f) T.toggle_button("ctx", "a", "A", false, { preset = "large", fonts = f, pad_x = 2 }) end,
    function(T, f) T.badge("ctx", "B", { preset = "small", fonts = f, rounding = 3, interactive = true, tooltip = "t" }) end,
    function(T) T.badge("ctx", "B", { color = 0xE45E65FF }) end,
    function(T) T.selectable("ctx", "a very long label that does not fit##s", true) end,
    function(T) T.icon_btn("ctx", "x", T.icons.close, { tooltip = "t" }) end,
    function(T) T.icon_btn_colored("ctx", "y", T.icons.plus, { tooltip = "t" }) end,
    function(T, f) T.progress_bar("ctx", 0.5, { preset = "small", fonts = f, overlay = "50%", tooltip = "t" }) end,
    function(T) T.combo("ctx", "##c", { "A", "B" }, 1, { disabled = true, tooltip = "t" }) end,
    function(T) T.multi_combo("ctx", "##m", { "A", "B" }, { true }, { tooltip = "t" }) end,
    function(T) T.section_divider("ctx", "S", { tooltip = "t" }) end,
    function(T) T.collapsing_header("ctx", "H##h", { close_id = "c", close_tooltip = "t" }) end,
    function(T) T.tooltip("ctx", "t") end,
    function(T) T.brand_icon("ctx", 24) end,
    function(T) T.settings_widget("ctx") end,
    function(T, f) T.header("ctx", { title = "T", subtitle = "S", fonts = f, show_settings = true, show_close = true }) end,
    function(T, f) T.header("ctx", { title = "T", fonts = f, show_separator = false, icon_fn = T.icons.gear }) end,
  }
  for i, fn in ipairs(cases) do
    for _, hovered in ipairs({ false, true }) do
      local ok, err = pcall(run, fn, hovered)
      if not ok then error("case " .. i .. ": " .. tostring(err), 0) end
    end
  end
end)

-------------------------------------------------------------------------------
-- Task 4, fix round 1: hover / pressed states keep labels and icons readable in every palette
-------------------------------------------------------------------------------

local PALETTES = {
  { "fancy", { mode = "fancy" } },
  { "match reapertips", { mode = "match", theme = REAPERTIPS } },
  { "match light", { mode = "match", theme = LIGHT } },
}

test("states: labels stay 4.5:1 on rest, hover and pressed fills, all palettes", function()
  for _, pal in ipairs(PALETTES) do
    local T, stub = load_theme(pal[2]); local P = T.get_palette()
    local cases = {
      { "toggle on", function() T.toggle_button("ctx", "id", "L", true) end },
      { "toggle off", function() T.toggle_button("ctx", "id", "L", false) end },
      { "toggle off, own bg", function() T.toggle_button("ctx", "id", "L", false, { inactive_bg = P.green }) end },
      { "badge interactive", function() T.badge("ctx", "x", { interactive = true }) end },
    }
    for _, k in ipairs({ "green", "red", "yellow", "accent", "accent2" }) do
      cases[#cases + 1] = { "badge " .. k, function() T.badge("ctx", "x", { color = P[k], interactive = true }) end }
    end
    for _, case in ipairs(cases) do
      stub.calls = {}; case[2]()
      local c = pushed_colors(stub)
      local tag = pal[1] .. ", " .. case[1]
      for _, state in ipairs({ "ImGui_Col_Button", "ImGui_Col_ButtonHovered", "ImGui_Col_ButtonActive" }) do
        local fill = composite(c[state], P.bg)
        local r = contrast(c.ImGui_Col_Text, fill)
        assert(r >= 4.5, string.format("%s: %s %.2f", tag, state, r))
      end
      assert(c.ImGui_Col_ButtonHovered ~= c.ImGui_Col_Button, tag .. ": hover differs from rest")
      assert(c.ImGui_Col_ButtonActive ~= c.ImGui_Col_Button, tag .. ": pressed differs from rest")
    end
  end
end)

test("states: icons stay 3:1 at rest, hovered and pressed, all palettes", function()
  for _, pal in ipairs(PALETTES) do
    for _, which in ipairs({ "text", "text_dim" }) do
      for _, state in ipairs({ "rest", "hover", "active" }) do
        local T, stub = load_theme(pal[2]); local P = T.get_palette()
        local seen
        local function icon(_, _, _, _, col) seen = col end
        stub.reaper.ImGui_IsItemHovered = function() return state ~= "rest" end
        stub.reaper.ImGui_IsItemActive = function() return state == "active" end
        stub.calls = {}
        T.icon_btn("ctx", "##i", icon, which == "text_dim" and { color = P.text_dim } or nil)
        local c = pushed_colors(stub)
        local face = state == "rest" and P.bg
          or composite(state == "hover" and c.ImGui_Col_ButtonHovered or c.ImGui_Col_ButtonActive, P.bg)
        local r = contrast(seen, face)
        assert(r >= 3.0, string.format("%s, icon_btn %s %s: %.2f", pal[1], which, state, r))
        if state == "hover" and which == "text" then
          local dark_ui = contrast(P.text, 0x000000FF) > contrast(P.text, 0xFFFFFFFF)
          assert(dark_ui == (contrast(seen, 0x000000FF) >= contrast(P.text, 0x000000FF)),
            pal[1] .. ": hover brightening moves toward the text colour's extreme")
        end
        if which == "text" then
          stub.calls = {}; seen = nil
          T.icon_btn_colored("ctx", "##c", icon)
          c = pushed_colors(stub)
          local key = state == "rest" and "ImGui_Col_Button" or state == "hover" and "ImGui_Col_ButtonHovered"
            or "ImGui_Col_ButtonActive"
          r = contrast(seen, composite(c[key], P.bg))
          assert(r >= 3.0, string.format("%s, icon_btn_colored %s: %.2f", pal[1], state, r))
        end
      end
    end
  end
end)

test("states: a caller's own hover and pressed colours are pushed unchanged", function()
  local T, stub = load_theme({ mode = "match", theme = LIGHT })
  T.toggle_button("ctx", "id", "L", true, { active_hover = 0x010203FF, active_active = 0x040506FF })
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_ButtonHovered == 0x010203FF and c.ImGui_Col_ButtonActive == 0x040506FF)
  stub.calls = {}; T.badge("ctx", "x", { interactive = true, bg_hover = 0x070809FF, bg_active = 0x0A0B0CFF })
  c = pushed_colors(stub)
  assert(c.ImGui_Col_ButtonHovered == 0x070809FF and c.ImGui_Col_ButtonActive == 0x0A0B0CFF)
  stub.calls = {}; T.icon_btn_colored("ctx", "##c", function() end, { bg_hover = 0x0D0E0FFF })
  assert(pushed_colors(stub).ImGui_Col_ButtonHovered == 0x0D0E0FFF)
end)

-------------------------------------------------------------------------------

print(string.format("\n%d tests, %d failed", total, failures))
os.exit(failures == 0 and 0 or 1)
