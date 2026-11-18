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

print(string.format("\n%d tests, %d failed", total, failures))
os.exit(failures == 0 and 0 or 1)
