# Reaper Tips Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The curated mode of the Fancy Scripts design system stops being navy and purple and takes the full look of the Reapertips Theme: colours, control shapes and states, spacing, and Fira Sans.

**Architecture:** Everything visual flows through `_lib/theme.lua`. The palette gains control roles (`btn`, `well`, `thumb`, ...), `Theme.push` and the library widgets map to them, layout tokens and font sizes change, and Fira Sans is loaded from files in `_lib/fonts/`. Pitch Correct has no colour literals, so it follows; a sweep then fixes the few places where it picks palette fields by hand. A Lua test file with a stubbed `reaper` table pins the palette values, the contrast rules and the style mapping.

**Tech Stack:** Lua 5.4, REAPER ReaScript, ReaImGui 0.10.0.5 (Dear ImGui 1.92.1) on the user's machine, `luac`, `luacheck`, plain `lua` for the test file.

**Spec:** `docs/superpowers/specs/2026-11-18-reapertips-restyle-design.md` (approved 2026-11-18). Read it before any task; this plan does not repeat its tables.

## Global Constraints

- No existing palette field, layout token, widget, option or function signature is removed or renamed. Scripts other than Pitch Correct and Design System get no code changes beyond the three exceptions in the spec's Non-goals.
- The stored mode values stay `fancy` and `match`. Only the label "Fancy Dark" becomes "Fancy".
- Layout scale values stay 2 / 4 / 8 / 12 / 16 / 24 / 32.
- Text and labels 4.5:1 in both modes. Meaningful state 3:1. Resting control outline and face have no minimum (spec section 7).
- No theme PNGs are shipped or loaded. The curated mode uses fixed values and does not read the active REAPER theme.
- A missing or unloadable font file never raises an error or a dialog.
- Colours are `0xRRGGBBAA` integers. Hex values in the spec are opaque unless an alpha is stated.
- `luac -p <file>` and `luacheck <file>` pass on every changed Lua file (`.luacheckrc`, std lua54).
- Commit after each task with a conventional-commit message, on branch `feat/reapertips-restyle`. Do not push.
- The user checks the look in REAPER. Tasks 1, 4 and 6 end with a stop for that; do not go past a stop without the user's answer.

## Review Focus

1. **Font file absent or unreadable** (a ReaPack user whose install predates the font files, or a read-only path): the script opens in the fallback font, no dialog. Test in Task 1.
2. **A ReaImGui older than 0.10** (no `ImGui_CreateFontFromFile`, no `ImGui_Col_TabSelected`): the library loads and `Theme.push` / `Theme.pop` counts still balance. Tests in Tasks 1 and 3.
3. **Match Theme under a light REAPER theme**: every new role still meets the contrast rules; `on_text` and `text_dim` flip toward dark as needed. Test in Task 2.
4. **A script passing its own colours** (`toggle_button` `active_bg`, `badge` `color`, `selectable` `bg_sel`, `build_palette` overrides): the script's value wins and the label is still readable. Tests in Tasks 2 and 4.
5. **A script that pops with the old literal counts** (`Theme.pop(ctx)` with no arguments): the defaults inside `Theme.pop` match what `Theme.push` now pushes. Test in Task 3.

---

## File Structure

| File | Responsibility |
|---|---|
| `_lib/theme.lua` | modified: palette roles, canvas palette, layout tokens, style stack, fonts, widgets, header comment |
| `_lib/fonts/FiraSans-Regular.otf`, `_lib/fonts/FiraSans-Bold.otf`, `_lib/fonts/OFL.txt` | new: bundled typeface and its licence |
| `docs/superpowers/tests/theme_spec.lua` | new: test file, run with `lua docs/superpowers/tests/theme_spec.lua` from the repo root. Lives under `docs/` because `.reapack-index.conf` ignores `docs`, so it never ships |
| `docs/superpowers/tests/reaper_stub.lua` | new: the stubbed `reaper` table the tests load |
| `Utility/Fancy_Design System.lua` | modified: font check block, new role swatches and control states |
| `Pitch/Fancy_Pitch Correct.lua` | modified: the palette picks listed in Task 6, header, version |
| Other themed scripts | header only (`@provides`, `@version`, `@changelog`); Pan Snap also one label |
| `CHANGELOG.md`, `docs/design/README.md` | modified in Task 7 |

## The test stub (used by every task)

`docs/superpowers/tests/reaper_stub.lua` returns a function `new_stub(opts)` that builds a fresh `reaper` table:

- `opts.theme` is a table of REAPER theme keys to `0xRRGGBB` values; `GetThemeColor(key)` returns the value as a native colour, or `-1` for a missing key. `ColorFromNative(n)` returns r, g, b. Two fixtures are exported: `REAPERTIPS` (the values in the spec's measurement table: `col_main_bg2=0x3E3E3E`, `col_tr1_bg=0x424242`, `col_tr2_bg=0x454545`, `col_main_text=0xA0A0A0`, `col_tcp_text=0xD9D9D9`, `col_cursor=0x46B9FE`, `col_main_3dhl=0x323232`, `col_buttonbg=0x464646`, `col_main_editbk=0x2A2A2A`, `docker_bg=0x2D2D2D`) and `LIGHT` (`col_main_bg2=0xE6E6E6`, `col_tr1_bg=0xDADADA`, `col_tr2_bg=0xD0D0D0`, `col_main_text=0x202020`, `col_tcp_text=0x303030`, `col_cursor=0x1565C0`, `col_main_3dhl=0xFFFFFF`, `col_buttonbg=0xC8C8C8`, `col_main_editbk=0xFFFFFF`, `docker_bg=0xD0D0D0`).
- `GetExtState` / `SetExtState` are backed by an in-memory table; `opts.mode` presets `FancyScripts/theme_mode`.
- Any `ImGui_Col_*`, `ImGui_StyleVar_*`, `ImGui_*Flags_*` or `ImGui_Cond_*` function returns a stable unique integer per name, and `stub.enum_name(int)` maps it back.
- `ImGui_PushStyleColor`, `ImGui_PopStyleColor`, `ImGui_PushStyleVar`, `ImGui_PopStyleVar`, `ImGui_DrawList_AddRectFilled`, `ImGui_DrawList_AddRect`, `ImGui_DrawList_AddText`, `ImGui_CreateFont`, `ImGui_CreateFontFromFile`, `ImGui_PushFont` append `{name, args...}` to `stub.calls`.
- Other ImGui functions the widgets call get explicit return values in one table inside the stub (for example `ImGui_Button -> false`, `ImGui_CalcTextSize -> 40, 13`, `ImGui_GetCursorScreenPos -> 0, 0`). An ImGui function that is neither an enum nor in that table raises `error("unstubbed: " .. name)`, so a gap is loud.
- `opts.missing` is a list of function names the stub leaves `nil` (to imitate an older ReaImGui); `opts.fail` is a list of function names that raise when called.

`theme_spec.lua` sets `package.path` to `_lib/?.lua`, installs a stub as the global `reaper`, clears `package.loaded.theme`, requires the library, and runs named test functions; it prints one line per test and exits non-zero on any failure. Helpers in the test file: `load_theme(opts) -> Theme, stub` (fresh stub, fresh library); `contrast(fg, bg)` and `composite(fg, under)` implementing WCAG 2.x and alpha compositing independently of the library's own; `count`, `first`, `last`, `all` over `stub.calls` by function name; `pushed_colors(stub)` / `pushed_vars(stub)` returning tables keyed by enum name; `has_fill(fills, colour)` / `find_fill(fills, colour)` over recorded `AddRectFilled` calls (each with `x1, y1, x2, y2, color`); `contains(list, value)`.

---

### Task 1: Fira Sans, font loading and the font check

**Files:**
- Create: `_lib/fonts/FiraSans-Regular.otf`, `_lib/fonts/FiraSans-Bold.otf`, `_lib/fonts/OFL.txt`
- Create: `docs/superpowers/tests/reaper_stub.lua`, `docs/superpowers/tests/theme_spec.lua`
- Modify: `_lib/theme.lua` sections 8 and 9 (lines 1050-1159)
- Modify: `Utility/Fancy_Design System.lua` (`draw_typography_section`, line 382)

**Interfaces:**
- Produces: `Theme.font_dir` (string, the directory holding the font files, ending in a path separator; defaults to `<directory of theme.lua>fonts/`), `Theme.font_files = { regular = "FiraSans-Regular.otf", bold = "FiraSans-Bold.otf" }`, `Theme.font_family = "Fira Sans"`, `Theme.font_fallback_family = "sans-serif"`, `Theme.font_source` (`"file"`, `"family"` or `"system"`, set by `create_fonts` for the regular weight).
- Produces: `Theme.font_sizes = { small = 11, default = 13, medium = 14, large = 16, header = 18, tooltip = 13 }`.
- `Theme.create_fonts(_ctx, overrides)`, `attach_fonts`, `push_font`, `pop_font` keep their signatures and the eight keys plus `tooltip`. `overrides.family` / `overrides.bold_family`, when given, skip the file and are used as today.

- [ ] **Step 1: Copy the font files.** `cp ~/Library/Fonts/FiraSans-Regular.otf ~/Library/Fonts/FiraSans-Bold.otf _lib/fonts/`. Write `_lib/fonts/OFL.txt`: first line `Copyright (c) 2012-2016, The Mozilla Foundation and Telefonica S.A.`, a blank line, then the unmodified SIL Open Font License 1.1 text from `https://openfontlicense.org/open-font-license-official-text/`.

- [ ] **Step 2: Write the stub and the failing tests.**

```lua
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
```

(`fail = { "name:arg" }` makes the stub raise only when the first argument equals `arg`.)

- [ ] **Step 3: Run and see them fail.** `lua docs/superpowers/tests/theme_spec.lua`. Expected: the five `fonts:` tests fail (8 fonts not created from file; sizes 14 / 12 / 20).

- [ ] **Step 4: Implement font loading in `_lib/theme.lua`.** Resolve the library's own directory once at load from `debug.getinfo(1, "S").source`. In `create_fonts`, for each of the eight fonts try in order, each inside `pcall`, and take the first that returns a non-nil font:
  1. only when `reaper.ImGui_CreateFontFromFile` exists and the file opens with `io.open(path, "rb")`: `reaper.ImGui_CreateFontFromFile(path, 0, 0)`;
  2. `Theme.font_family`: on the new API `reaper.ImGui_CreateFont("Fira Sans", flags)` with `flags = reaper.ImGui_FontFlags_Bold()` for the bold weight and `0` otherwise; on the old API (no `ImGui_CreateFontFromFile`) `reaper.ImGui_CreateFont("Fira Sans", size)` / `("Fira Sans Bold", size)`;
  3. `Theme.font_fallback_family`, same two call shapes (`"sans-serif"`, and `"sans-serif Bold"` on the old API).

  Note for the implementer: today's code calls `ImGui_CreateFont(family, size)` on every version; on ReaImGui 0.10 the second parameter is `flags`, so the new-API branch must not pass a size there. Sizes reach ImGui through `push_font`, which is unchanged.

- [ ] **Step 5: Run the tests, see them pass.** Then `luac -p _lib/theme.lua && luacheck _lib/theme.lua`.

- [ ] **Step 6: Add the font check to the Design System script.** At the top of `draw_typography_section`: a `Theme.section_divider(ctx, "FONT CHECK")`, then one line of text `"Font source: " .. Theme.font_source`, then the seven symbols as text in the default font, spaced apart: `✓  ▸  ◀  ▾  ↔  ●  ○`, then a dim line `"Seven symbols should show above. Boxes or gaps mean the font lacks them."`. `luac -p` and `luacheck` the script.

- [ ] **Step 7: Commit.** `git add _lib/fonts docs/superpowers/tests _lib/theme.lua "Utility/Fancy_Design System.lua" && git commit -m "feat(theme): bundle Fira Sans and load it with fallbacks"`

- [ ] **Step 8: STOP for the user.** Ask the user to run `Utility/Fancy_Design System.lua` in REAPER and report (a) the "Font source" line and (b) whether all seven symbols show. Record the answer at the bottom of this plan under "Font check result". If any symbol is missing, Task 5 is required; otherwise skip it.

---

### Task 2: Palette values and control roles

**Files:**
- Modify: `_lib/theme.lua` sections 3-5 (lines 272-316, 807-916)
- Test: `docs/superpowers/tests/theme_spec.lua`

**Interfaces:**
- Produces, on every palette from `Theme.build_palette` / `Theme.get_palette`, in both modes: `btn`, `btn_h`, `btn_a`, `btn_on`, `on_text`, `outline`, `well`, `well_h`, `well_a`, `thumb`, `thumb_a`, `tab`, `tab_h`, `tab_sel`, `hover`, `select`, `scroll`, `scroll_h`, `scroll_a`, `title`. All existing fields remain.
- `overrides` accepts every new field name; an override always wins.

- [ ] **Step 1: Write the failing tests.**

```lua
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
```

- [ ] **Step 2: Run, see them fail.** `lua docs/superpowers/tests/theme_spec.lua`

- [ ] **Step 3: Implement.** Replace the `FANCY_PALETTE` values and add the role values from the spec's section 2. Rules the tests do not fully pin:
  - `text_dim` (curated): `fit_contrast(0xA0A0A0FF, { bg, panel, card, btn, well }, 4.5)`.
  - `on_text`: `fit_contrast(0x0F2B3BFF, { btn_on }, 4.5)`; when that cannot reach 4.5 (a dark overridden accent), use whichever of `0xFFFFFFFF` / `0x000000FF` contrasts more.
  - `well_h` / `well_a`: `well` lightened 6 % / 12 %.
  - `btn_on` defaults to `accent`; `outline` defaults to `border`.
  - `sep` is no longer an accent alpha.
  - Match Theme reads `btn` from `col_buttonbg`, `well` from `col_main_editbk`, `title` from `docker_bg`, each falling back to the curated value; `btn_h` / `btn_a` / `tab*` / `hover` are steps toward / away from the text colour of the same size as the curated ones; then every role is put through the same fits so the contrast tests hold on the `LIGHT` fixture.
  - Keep the `P.sep`-dependent and `P.accent_d`-dependent fields computing as before where they still exist.

- [ ] **Step 4: Run the tests, see them pass; `luac -p` and `luacheck` the library.**

- [ ] **Step 5: Commit.** `git commit -am "feat(theme): Reaper Tips palette and control roles"`

---

### Task 3: Layout tokens and the style stack

**Files:**
- Modify: `_lib/theme.lua` sections 6 and 7 (lines 918-1048)
- Test: `docs/superpowers/tests/theme_spec.lua`

**Interfaces:**
- Consumes: the roles of Task 2.
- Produces: `Theme.layout.rounding == 2`; `Theme.layout.btn_sm.h == 15`, `btn_default.h == 21`, `btn_lg.h == 22`; `Theme.push(ctx, palette) -> nc, nv` and `Theme.pop(ctx, nc, nv)` whose no-argument defaults equal the counts `push` returns on the running ReaImGui.

- [ ] **Step 1: Write the failing tests.**

```lua
test("push: counts match what was pushed, and pop balances", function()
  local T, stub = load_theme({ mode = "fancy" })
  local nc, nv = T.push("ctx", T.build_palette())
  assert(nc == count(stub.calls, "ImGui_PushStyleColor") and nv == count(stub.calls, "ImGui_PushStyleVar"))
  T.pop("ctx")                                  -- no counts: defaults must match
  assert(last(stub.calls, "ImGui_PopStyleColor")[3] == nc and last(stub.calls, "ImGui_PopStyleVar")[3] == nv)
end)

test("push: role mapping", function()
  local T, stub = load_theme({ mode = "fancy" })
  local P = T.build_palette(); T.push("ctx", P)
  local col = pushed_colors(stub)               -- { [enum name] = value }
  local want = {
    Button = P.btn, ButtonHovered = P.btn_h, ButtonActive = P.btn_a,
    FrameBg = P.well, FrameBgHovered = P.well_h, FrameBgActive = P.well_a,
    SliderGrab = P.thumb, SliderGrabActive = P.thumb_a, CheckMark = P.accent,
    Header = P.select, HeaderHovered = P.hover,
    Tab = P.tab, TabHovered = P.tab_h, TabSelected = P.tab_sel, TabSelectedOverline = P.accent,
    ScrollbarGrab = P.scroll, ScrollbarGrabHovered = P.scroll_h, ScrollbarGrabActive = P.scroll_a,
    Separator = P.sep, TitleBg = P.title, TitleBgActive = P.title, PopupBg = P.panel, Border = P.outline,
    WindowBg = P.bg, Text = P.text, TextDisabled = P.text_dim,
  }
  for k, v in pairs(want) do assert(col["ImGui_Col_" .. k] == v, k) end
  assert(col.ImGui_Col_ScrollbarBg & 0xFF == 0, "scrollbar track is transparent")
end)

test("push: style vars", function()
  local T, stub = load_theme({ mode = "fancy" })
  T.push("ctx", T.build_palette())
  local v = pushed_vars(stub)                   -- { [enum name] = { a, b } }
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
  T.pop("ctx"); assert(last(stub.calls, "ImGui_PopStyleColor")[3] == nc)
end)

test("layout: scale unchanged, rounding 2", function()
  local L = load_theme({}).layout
  assert(L.xs == 2 and L.sm == 4 and L.md == 8 and L.lg == 12 and L.xl == 16 and L.xxl == 24 and L.xxxl == 32)
  assert(L.rounding == 2 and L.border == 1)
  assert(L.btn_sm.h == 15 and L.btn_default.h == 21 and L.btn_lg.h == 22)
end)
```

- [ ] **Step 2: Run, see them fail.**

- [ ] **Step 3: Implement.** `rounding = S.xs`. In `Theme.push`: the mapping in the spec's section 3; `HeaderActive = select` at double alpha; `TabDimmed = tab`, `TabDimmedSelected = tab_sel`; `SeparatorHovered` / `SeparatorActive` stay `accent_h` / `accent`; table colours `TableHeaderBg = card`, `TableBorderStrong = TableBorderLight = sep`, `TableRowBg = bg`, `TableRowBgAlt = bg` lightened 3 %. Each Tab colour is pushed only when its enum function exists. `push` counts what it pushes and stores the counts in module locals; `pop` uses them when called without counts.

- [ ] **Step 4: Run, see them pass; `luac -p`, `luacheck`.**

- [ ] **Step 5: Commit.** `git commit -am "feat(theme): Reaper Tips style stack, rounding and spacing"`

---

### Task 4: Library widgets

**Files:**
- Modify: `_lib/theme.lua` sections 11-13 (lines 1324-2688)
- Modify: `Utility/Fancy_Design System.lua` (`draw_colors_section` line 293, `draw_widgets_section` line 566)
- Test: `docs/superpowers/tests/theme_spec.lua`

**Interfaces:**
- Consumes: roles of Task 2, tokens of Task 3.
- Produces: no new public functions. Private helper `label_on(fill) -> colour` in the library: `P.text` when it has 4.5:1 on the opaque `fill`, otherwise whichever of `0x0F2B3BFF` / `0xFFFFFFFF` contrasts more.

- [ ] **Step 1: Write the failing tests.** Each test calls the widget against the stub and inspects `stub.calls`.

```lua
test("toggle_button: on is solid, off is a plain button", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.toggle_button("ctx", "id", "Label", true)
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == P.btn_on and c.ImGui_Col_Text == P.on_text)
  stub.calls = {}; T.toggle_button("ctx", "id", "Label", false)
  c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == P.btn and c.ImGui_Col_ButtonHovered == P.btn_h and c.ImGui_Col_Text == P.text)
end)

test("toggle_button: a script's colours win", function()
  local T, stub = load_theme({ mode = "fancy" })
  T.toggle_button("ctx", "id", "L", true, { active_bg = 0x112233FF, active_text = 0xEEEEEEFF })
  local c = pushed_colors(stub)
  assert(c.ImGui_Col_Button == 0x112233FF and c.ImGui_Col_Text == 0xEEEEEEFF)
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

test("selectable: selected row is the tint plus a 2 px accent bar", function()
  local T, stub = load_theme({ mode = "fancy" }); local P = T.get_palette()
  T.selectable("ctx", "Row", true)
  local fills = all(stub.calls, "ImGui_DrawList_AddRectFilled")
  assert(has_fill(fills, P.select), "tint")
  local bar = find_fill(fills, P.accent); assert(bar and (bar.x2 - bar.x1) == 2, "bar")
  assert(last(stub.calls, "ImGui_DrawList_AddText").color == P.text)
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

test("settings label", function()
  assert(load_theme({}).mode_labels[1] == "Fancy" and load_theme({}).mode_labels[2] == "Match Theme")
end)
```

(Expose the existing private `SETTINGS_LABELS` as `Theme.mode_labels` so the last test and the Design System script can read it.)

- [ ] **Step 2: Run, see them fail.**

- [ ] **Step 3: Implement the widget changes**, one widget at a time, per the spec's section 5. Decisions not pinned by the tests:
  - `toggle_button` hover: on = `btn_on` lightened 12 %, pressed = `btn_on` darkened 12 %; off = `btn_h` / `btn_a`.
  - `badge`: hover / active of an `interactive` badge = fill lightened / darkened 12 %; `opts.color` given without `opts.text_color` uses `label_on(color)`.
  - `selectable`: hover fill `P.hover`; the bar spans the row's full height at its left edge; `opts.bg_hover`, `opts.bg_sel`, `opts.text_col` still win.
  - `multi_combo`: rows use the same hover / tint / bar. Its check prefix stays text unless Task 5 runs.
  - `section_divider`: separator colour `P.sep`, no longer an alpha of the label colour.
  - `collapsing_header`: header row colours `P.btn` / `P.btn_h` / `P.btn_a`.
  - `header`: draws a `P.title` strip behind the row and a 1 px `P.sep` line under it; the title uses `fonts.default_bold` when the caller passes fonts (as today).
  - `tooltip`: popup `P.panel`, border `P.outline`.
  - `brand_icon`: background `P.well`, frame `P.outline`; curve and dots keep `accent`, `green`, `yellow`.
  - Replace `"Fancy Dark"` with `"Fancy"` in `SETTINGS_LABELS`.

- [ ] **Step 4: Run, see them pass; `luac -p`, `luacheck`.**

- [ ] **Step 5: Update the Design System script.** In `draw_colors_section` add a swatch row "CONTROL ROLES" listing every field Task 2 produced. In `draw_widgets_section`, under "STANDARD BUTTONS", add a row with a raw `ImGui_Button`, a raw `ImGui_Checkbox`, a raw `ImGui_SliderDouble`, a raw `ImGui_InputText`, a two-tab `ImGui_BeginTabBar`, and a short scrolling child so the scrollbar shows. Replace any "Fancy Dark" text with "Fancy". Bump `@version` to 1.4.0 with a changelog line. `luac -p`, `luacheck`.

- [ ] **Step 6: Commit.** `git commit -am "feat(theme): Reaper Tips widgets and Design System showcase"`

- [ ] **Step 7: STOP for the user.** Ask the user to open `Utility/Fancy_Design System.lua` in REAPER next to the Reapertips Theme, in "Fancy" and in "Match Theme", and say what looks off (a screenshot helps). Apply corrections as further commits in this task before moving on.

---

### Task 5: Symbols the font lacks (only if Task 1's font check failed)

**Files:**
- Modify: `_lib/theme.lua` (section 10 icons, `multi_combo` line 2256), `Pitch/Fancy_Pitch Correct.lua:6444`, `:7308`, `FX/Fancy_Parameter Link.lua:722`, `:1837`, `:2101`, `Mixing/Fancy_Mapper Settings.lua:715`, `:717`
- Test: `docs/superpowers/tests/theme_spec.lua`

**Interfaces:**
- Produces: `Theme.icons.check(dl, cx, cy, hs, col)`, `Theme.icons.dot(dl, cx, cy, hs, col)`, `Theme.icons.ring(dl, cx, cy, hs, col)`, same signature as the other icons.

- [ ] **Step 1: Failing test:** `Theme.icons.check`, `.dot`, `.ring` are functions; `multi_combo` with a selected item issues no `AddText` containing "✓".
- [ ] **Step 2: Implement** the three icons; `multi_combo` draws `icons.check` in the prefix slot.
- [ ] **Step 3: Replace the text symbols.** Pitch Correct: "Timing ▾" keeps the word and draws `icons.tri_down` after it at the same width the glyph took; the help row "▸ / ◀" becomes "> / <". Parameter Link: "✓" becomes "OK:" in both messages and in the colour search. Mapper Settings: drop "● " / "○ " from the two badge labels (the badge colour already carries the state). Bump Parameter Link to 5.4.2 and Mapper Settings to 5.2.1 with changelog lines.
- [ ] **Step 4:** tests pass, `luac -p` and `luacheck` on all four files, commit `fix: draw symbols Fira Sans lacks as icons or ASCII`.

---

### Task 6: Canvas palette and the Pitch Correct sweep

**Files:**
- Modify: `_lib/theme.lua` section 4A (`build_canvas_fancy` line 527; `build_canvas_match` line 636 only if a test requires)
- Modify: `Pitch/Fancy_Pitch Correct.lua` (lines below), header lines 1-13
- Test: `docs/superpowers/tests/theme_spec.lua`

**Interfaces:**
- Consumes: palette of Task 2.
- Produces: `P.canvas` with exactly the same set of keys as before this plan.

- [ ] **Step 1: Capture the key set, then write the failing tests.** Before editing, print the sorted keys of `Theme.get_palette().canvas` from `main` and paste them into the test as `CANVAS_KEYS`.

```lua
test("canvas: key set unchanged, both modes", function()
  for _, o in ipairs({ { mode = "fancy" }, { mode = "match", theme = REAPERTIPS }, { mode = "match", theme = LIGHT } }) do
    local C = load_theme(o).build_palette().canvas
    for _, k in ipairs(CANVAS_KEYS) do assert(C[k] ~= nil, k) end
    for k in pairs(C) do assert(contains(CANVAS_KEYS, k), "new key " .. k) end
  end
end)

test("canvas: curated values", function()
  local P = load_theme({ mode = "fancy" }).build_palette(); local C = P.canvas
  assert(C.row == 0x2E2E2EFF and C.row_black == 0x2B2B2BFF and C.row_tonic == 0x2E2E2EFF)
  assert(C.row_dim == 0x282828FF and C.row_dim_black == 0x262626FF)
  assert(C.row_plain == 0x2E2E2EFF and C.row_plain_black == 0x2A2A2AFF)
  assert(C.grid_dim == 0x1D1D1DFF and C.grid_plain == 0x1D1D1DFF and C.grid_plain_black == 0x1D1D1DFF)
  assert(C.gutter_bg == 0x333333FF and C.overview_bg == P.well)
  assert(C.note_border == P.accent and C.note_edited_border == P.green and C.note_selected_border == 0xEDEDEDFF)
  assert(C.marker_split & 0xFFFFFF00 == P.accent2 & 0xFFFFFF00, "split markers follow the secondary accent")
end)

test("canvas: contrast, all three palettes", function()
  for _, o in ipairs({ { mode = "fancy" }, { mode = "match", theme = REAPERTIPS }, { mode = "match", theme = LIGHT } }) do
    local C = load_theme(o).build_palette().canvas
    local rows = { C.row, C.row_black, C.row_tonic, C.row_dim, C.row_dim_black, C.row_plain, C.row_plain_black }
    for _, r in ipairs(rows) do
      assert(contrast(C.note_border, r) >= 3.0 and contrast(C.note_edited_border, r) >= 3.0, "note borders")
      assert(contrast(C.note_selected_border, r) >= 3.0, "selection border")
      assert(contrast(C.note_label, composite(C.note_fill, r)) >= 4.5, "label on untouched note")
      assert(contrast(C.note_label_edited, composite(C.note_edited, r)) >= 4.5, "label on edited note")
      assert(contrast(C.note_label_selected, composite(C.note_selected, r)) >= 4.5, "label on selected note")
      assert(contrast(C.playhead, r) >= 3.0 and contrast(C.trace, r) >= 3.0, "trace and playhead")
    end
    assert(contrast(C.gutter_text, C.gutter_bg) >= 4.5 and contrast(C.gutter_text_dim, C.gutter_bg) >= 4.5)
    assert(contrast(C.pill_text, composite(C.pill_bg, C.row)) >= 4.5)
  end
end)
```

- [ ] **Step 2: Run, see the curated tests fail.**

- [ ] **Step 3: Implement `build_canvas_fancy`.** Row, grid and gutter literals as in the test; `row_tint` / `row_tonic_tint` / `grid_tonic` stay accent alphas; `grid` stays the text colour at 5 %; `gutter_text = 0xC8C8C8FF`; `overview_bg = P.well`; `note_selected_border = 0xEDEDEDFF`; `note_fill` and `note_edited` keep their formulas (the accent and green are new, so re-check the label tests; darken further only if a label test fails). The piano-key tokens are unused by the current canvas but keep their keys: set `key_white = 0xBABABAFF`, `key_black = 0x282828FF`, leave the rest. `trend` / `anchor` stay cyan. Leave `build_canvas_match` alone unless a test fails on it.

- [ ] **Step 4: Run, see all canvas tests pass.**

- [ ] **Step 5: Pitch Correct palette picks.** Change only these:

| Line | Today | Becomes |
|---|---|---|
| 4968 | BYPASSED card radius `6.0` | `L.rounding` |
| 5522, 5689-5694 | sidebar row cards: accent alphas for the active and hovered fill and border | hovered = `P.hover`, no border; active = `P.select` fill plus the existing accent bar at 5691, no border |
| 6170-6172 | danger button `red_d` / `red_h` / `red_h` | keep; confirm the label still has 4.5:1 over `P.panel` (the comment at 6166 states that rule) and adjust the alpha only if it does not |
| 7065 | item badge background `P.accent_d` when the item has notes | `P.well` (a quiet tag); the track-colour and the yellow no-notes cases stay |
| 7495-7497 | scope pill: note = `accent2_l` on `accent2_d`, item = `accent_l` on `accent_d`, global = `text_dim` on `card` | note = `label_on`-style readable text on solid `P.accent2`; item = `P.on_text` on solid `P.accent`; global = `P.text` on `P.well` |

  Every other `P.border` use in the file (3337, 4721, 4771, 4894-4915, 5836-5837, 7268) is a hairline and stays `P.border`, which is now `#181818`.

- [ ] **Step 6: Header.** `@version 2.8.0`; `@changelog` one line "New look: matches the Reapertips Theme (greys, blue accent, flat outlined controls, Fira Sans)"; add `--   [nomain] ../_lib/fonts/*` under `@provides`. `luac -p` and `luacheck` the file.

- [ ] **Step 7: Commit.** `git commit -am "feat(pitch-correct): v2.8.0 Reaper Tips look"`

- [ ] **Step 8: STOP for the user.** Ask the user to open Pitch Correct on an analysed item in REAPER and go through: top bar, "…" menu, Settings, Info, a confirm dialog, the sidebar with an active and a hovered row, the canvas with untouched / edited / selected notes, the overview and range strips, the status pill. Fix what they report as further commits in this task. Spacing tuned by eye for 22 px controls is the likeliest thing to be off.

---

### Task 7: Ship list and documents

**Files:**
- Modify: headers of `FX/Fancy_Parameter Link.lua`, `Mixing/Fancy_Mapper Cycle Mode.lua`, `Mixing/Fancy_Mapper Sensitivity Up.lua`, `Mixing/Fancy_Mapper Sensitivity Down.lua`, `Mixing/Fancy_Mapper Settings.lua`, `Routing/Fancy_Pan Snap.lua`, `Transport/Fancy_Tap Tempo Slew Settings.lua`, `Utility/Fancy_Design System.lua`, `Metering/Fancy_Selected Track Meter.lua`
- Modify: `Routing/Fancy_Pan Snap.lua:80`, `:89`; `_lib/theme.lua` lines 1-135 (header comment) and the "Fancy Dark" mentions in comments; `docs/design/README.md`; `CHANGELOG.md`

- [ ] **Step 1: `@provides`.** In each script above add `--   [nomain] ../_lib/fonts/*` after the `../_lib/*.lua` line, bump the patch version (minor for Pan Snap, whose label changes), and add a changelog line "New look from the shared design system: matches the Reapertips Theme". Skip a bump already made in Task 5. Selected Track Meter loads the library, so it must ship the fonts too, though its own drawing does not change.
- [ ] **Step 2: Pan Snap label.** "Secondary Accent (Blue)" becomes "Secondary Accent" at both lines.
- [ ] **Step 3: Library header comment.** Rewrite the API quick reference for: the new palette roles and what each maps to, font sizes 11 / 13 / 14 / 16 / 18 and the bundled Fira Sans with its fallbacks, rounding 2, preset heights 15 / 21 / 22, the `push` colour list, `Theme.mode_labels`, and the contrast rule of the spec's section 7 in place of "border >= 3:1". Replace "Fancy Dark" with "Fancy" in comments.
- [ ] **Step 4: `docs/design/README.md`.** Add a short "Contrast" paragraph stating the three-part rule of the spec's section 7.
- [ ] **Step 5: `CHANGELOG.md`.** Under `[Unreleased]`: one entry for the design system (what changed, that "Fancy Dark" is now "Fancy", that Fira Sans is bundled under the OFL), one for Pitch Correct v2.8.0, one line listing the other bumped scripts.
- [ ] **Step 6: Verify everything.**

```bash
lua docs/superpowers/tests/theme_spec.lua
for f in _lib/theme.lua */Fancy_*.lua; do luac -p "$f" || echo "FAIL $f"; done
luacheck _lib/theme.lua "Pitch/Fancy_Pitch Correct.lua" "Utility/Fancy_Design System.lua" "Routing/Fancy_Pan Snap.lua"
grep -rn "Fancy Dark" _lib "Utility/Fancy_Design System.lua" "Pitch/Fancy_Pitch Correct.lua"
```

  Expected: every test line `ok`, no `FAIL`, luacheck reports no new warnings against `main` (compare with `git stash`-free runs on `main`'s copies if unsure), and the grep prints nothing.
- [ ] **Step 7: Commit.** `git commit -am "chore: ship fonts with every themed script; docs for the Reaper Tips look"`

---

## Font check result

(Filled in at the Task 1 stop: font source reported, which of the seven symbols showed.)
