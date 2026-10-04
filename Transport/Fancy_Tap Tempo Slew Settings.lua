-- @description Fancy Tap Tempo Slew Settings
-- @author Fancy Scripts
-- @version 1.0.0
-- @changelog
--   + Initial release
-- @about
--   Settings window for Fancy Tap Tempo Slew: instant or glide, taps per
--   change, whether the tempo updates on every tap or once per group, the
--   restart gap and the tempo range. Changes save at once and apply on the
--   next tap.
--   Requirements: REAPER 7.03+, ReaImGui
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
    "Fancy Tap Tempo Slew Settings -- Missing ReaImGui", 0)
  return
end

-------------------------------------------------------------------------------
-- 2. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme    = require("theme")
local Settings = require("tap_tempo_settings")

local L = Theme.layout
local DEFAULTS = Settings.DEFAULTS
local RANGES = Settings.RANGES

-------------------------------------------------------------------------------
-- 3. CONSTANTS & STATE
-------------------------------------------------------------------------------
local WINDOW_TITLE  = "Fancy Tap Tempo Slew Settings"
local POPUP_RESET   = "Reset tap tempo settings###tts_reset"
local POPUP_INFO    = "Tap Tempo###tts_info"
local STATUS_HOLD_S = 4
local MOD = (reaper.GetOS():match("OSX") or reaper.GetOS():match("macOS")) and "Cmd" or "Ctrl"

local MSG_SAVED   = "Saved. Applies on your next tap."
local MSG_RESET   = "Settings reset to defaults."
local MSG_INVALID = "Some saved settings were invalid and were reset to defaults."

local ctx, fonts
local config = {}
local status_text, status_time = nil, 0
local pending_popup = nil
local drag_state = {}
local label_w = nil
local space_cmds = nil

local LABELS = { "Change", "Glide rate", "Taps per change", "After the first change",
                 "Restart after", "Minimum tempo", "Maximum tempo" }

-------------------------------------------------------------------------------
-- 4. CONFIG I/O
-------------------------------------------------------------------------------
local function set_status(text)
  status_text, status_time = text, reaper.time_precise()
end

local function load_config()
  local s, bad = Settings.load()
  config = s
  if bad then
    Settings.reset_all()
    for _, key in ipairs(Settings.KEYS) do Settings.save(key, config[key]) end
    set_status(MSG_INVALID)
  end
end

local function commit(key, value)
  config[key] = value
  Settings.save(key, value)
  set_status(MSG_SAVED)
end

local function range_of(key)
  if key == "min_bpm" then return RANGES.min_bpm[1], config.max_bpm - 1 end
  if key == "max_bpm" then return config.min_bpm + 1, RANGES.max_bpm[2] end
  return RANGES[key][1], RANGES[key][2]
end

-------------------------------------------------------------------------------
-- 5. WIDGET HELPERS
-------------------------------------------------------------------------------
local function hover_tip(text)
  if text and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()
      | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    Theme.tooltip(ctx, text)
  end
end

local function dim_text(text)
  local P = Theme.get_palette()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

--- Label column width: widest label plus a gap, capped so fields keep room
--- in a narrow docker (long labels wrap instead).
local function calc_label_w()
  local widest = 0
  for _, s in ipairs(LABELS) do
    widest = math.max(widest, (reaper.ImGui_CalcTextSize(ctx, s)))
  end
  return widest + L.lg
end

--- Draws a wrapped form label and moves the cursor to the control column.
local function form_label(label)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local col = math.min(label_w, avail * 0.45)
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  Theme.align(ctx)
  reaper.ImGui_PushTextWrapPos(ctx, x0 + col - L.sm)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopTextWrapPos(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetCursorPosX(ctx, x0 + col)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
end

--- Parameter drag per HC2/HC3: Ctrl/Cmd-drag fine, double-click reset,
--- Ctrl/Cmd-click type, right-click menu. Saves on release only (HI4).
local function param_drag(label, key, speed, fmt, is_int, tip)
  form_label(label)
  local lo, hi = range_of(key)
  local ctrl = (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  local flags = reaper.ImGui_SliderFlags_AlwaysClamp() | reaper.ImGui_SliderFlags_NoInput()
              | reaper.ImGui_SliderFlags_NoSpeedTweaks()
  local spd = ctrl and speed * 0.1 or speed
  local st = drag_state[key] or {}
  drag_state[key] = st
  local rv, v
  if is_int then
    rv, v = reaper.ImGui_DragInt(ctx, "###" .. key, config[key], spd, lo, hi, fmt, flags)
  else
    rv, v = reaper.ImGui_DragDouble(ctx, "###" .. key, config[key], spd, lo, hi, fmt, flags)
  end
  if rv then config[key] = v end
  hover_tip(tip)

  if reaper.ImGui_IsItemActivated(ctx) then st.ctrl, st.dragged = ctrl, false end
  if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then st.dragged = true end
  if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then commit(key, config[key]) end
  if reaper.ImGui_IsItemDeactivated(ctx) and st.ctrl and not st.dragged then
    reaper.ImGui_OpenPopup(ctx, "type###type_" .. key)
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    commit(key, DEFAULTS[key])
  end

  if reaper.ImGui_BeginPopupContextItem(ctx, "ctx_" .. key) then
    if reaper.ImGui_MenuItem(ctx, "Reset to default") then commit(key, DEFAULTS[key]) end
    if reaper.ImGui_MenuItem(ctx, "Type a value…") then st.open_type = true end
    reaper.ImGui_EndPopup(ctx)
  end
  if st.open_type then
    reaper.ImGui_OpenPopup(ctx, "type###type_" .. key)
    st.open_type = false
  end

  if reaper.ImGui_BeginPopup(ctx, "type###type_" .. key) then
    if reaper.ImGui_IsWindowAppearing(ctx) then
      st.typed = config[key]
      reaper.ImGui_SetKeyboardFocusHere(ctx)
    end
    local _, typed = reaper.ImGui_InputDouble(ctx, "##typed_" .. key, st.typed or config[key], 0, 0, fmt)
    st.typed = typed
    if reaper.ImGui_IsItemDeactivated(ctx)
       and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
            or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false)) then
      local val = math.max(lo, math.min(hi, typed))
      if is_int then val = math.floor(val + 0.5) end
      commit(key, val)
      st.typed = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-------------------------------------------------------------------------------
-- 6. COPY
-------------------------------------------------------------------------------
local function fmt_num(n)
  return (string.format("%.2f", n):gsub("%.?0+$", ""))
end

local function summary_text()
  local n = config.taps_per_change
  local after = config.update == "group"
    and ("once per group of %d"):format(n) or "on every tap"
  local range = ("Tempo range %s–%s BPM."):format(fmt_num(config.min_bpm), fmt_num(config.max_bpm))
  if config.mode == "glide" then
    return ("Glides at %s BPM/s after %d taps, then %s. %s"):format(
      fmt_num(config.glide_rate), n, after, range)
  end
  local then_part = config.update == "group"
    and ("then once per group of %d"):format(n) or "then on every tap"
  return ("Instant change after %d taps, %s. %s"):format(n, then_part, range)
end

-------------------------------------------------------------------------------
-- 7. SECTIONS
-------------------------------------------------------------------------------
local function draw_header(docked)
  local info_w = reaper.ImGui_CalcTextSize(ctx, "Info") + L.md * 2
  local open = Theme.header(ctx, {
    title = "TAP TEMPO",
    fonts = fonts,
    show_close = true,
    close_tooltip = docked and "Close" or "Close (Esc)",
    right_width = info_w,
    right_widgets = function(hctx, hdr_h)
      Theme.align(hctx, hdr_h)
      if reaper.ImGui_Button(hctx, "Info###info") then pending_popup = POPUP_INFO end
    end,
  })
  return open
end

local function draw_tapping()
  Theme.section_divider(ctx, "TAPPING")

  form_label("Change")
  if Theme.toggle_button(ctx, "mode_instant", "Instant", config.mode == "instant", {
      tooltip = "The new tempo starts at the play position at once. Adds a tempo marker there." }) then
    commit("mode", "instant")
  end
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  if Theme.toggle_button(ctx, "mode_glide", "Glide", config.mode == "glide", {
      tooltip = "Moves the tempo toward the tapped value at the glide rate. "
        .. "Changes the tempo in effect, which can cause audible skips." }) then
    commit("mode", "glide")
  end

  local glide_off = config.mode ~= "glide"
  reaper.ImGui_BeginDisabled(ctx, glide_off)
  param_drag("Glide rate", "glide_rate", 0.1, "%.1f BPM/s", false,
    "How fast the tempo moves toward the tapped value in Glide mode.")
  reaper.ImGui_EndDisabled(ctx)
  if glide_off then
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx)
      + math.min(label_w, reaper.ImGui_GetContentRegionAvail(ctx) * 0.45))
    dim_text("Used only in Glide mode")
  end

  local n = config.taps_per_change
  param_drag("Taps per change", "taps_per_change", 0.05, "%d", true,
    "How many taps make one tempo change.")

  form_label("After the first change")
  local items = { "Every tap (rolling average)", ("Once per %d taps"):format(n) }
  local idx = config.update == "group" and 2 or 1
  local new_idx, changed = Theme.combo(ctx, "##update", items, idx, {
    tooltip = ("Every tap: each new tap updates the tempo from your last %d taps. "
      .. "Once per %d taps: each new group of %d taps makes one change."):format(n, n, n) })
  if changed then commit("update", new_idx == 2 and "group" or "rolling") end
end

local function draw_limits()
  if not Theme.collapsing_header(ctx, "LIMITS###limits") then return end
  param_drag("Restart after", "restart_gap", 0.01, "%.1f s", false,
    "A pause longer than this starts a new count from tap 1.")
  param_drag("Minimum tempo", "min_bpm", 0.25, "%.2f BPM", false,
    "Tapped tempos are kept inside this range.")
  param_drag("Maximum tempo", "max_bpm", 0.25, "%.2f BPM", false,
    "Tapped tempos are kept inside this range.")
end

local function draw_appearance()
  if not Theme.collapsing_header(ctx, "APPEARANCE###appearance") then return end
  Theme.settings_widget(ctx)
  Theme.tooltip_setting_widget(ctx)
end

local function draw_footer()
  local P = Theme.get_palette()
  if status_text and reaper.time_precise() - status_time > STATUS_HOLD_S then
    status_text = nil
  end
  local btn_w = reaper.ImGui_CalcTextSize(ctx, "Reset all…") + L.md * 2
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if status_text then
    Theme.align(ctx)
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + math.max(avail - btn_w - L.md, btn_w))
    reaper.ImGui_TextColored(ctx, P.text_dim, status_text)
    reaper.ImGui_PopTextWrapPos(ctx)
    if avail > btn_w * 2.5 then reaper.ImGui_SameLine(ctx) end
  end
  Theme.right_align(ctx, btn_w)
  if reaper.ImGui_Button(ctx, "Reset all…###reset_all") then pending_popup = POPUP_RESET end
end

-------------------------------------------------------------------------------
-- 8. MODALS
-------------------------------------------------------------------------------
local function draw_reset_modal()
  Theme.center_next_window(ctx, L.modal_sm.w, 0, reaper.ImGui_Cond_Appearing())
  Theme.modal_scrim(ctx, POPUP_RESET)
  if not reaper.ImGui_BeginPopupModal(ctx, POPUP_RESET, true,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    return
  end
  reaper.ImGui_PushTextWrapPos(ctx, L.modal_sm.w - L.xl * 2)
  reaper.ImGui_Text(ctx, ("Reset all %d tap tempo settings to their defaults? This cannot be undone.")
    :format(#Settings.KEYS))
  reaper.ImGui_PopTextWrapPos(ctx)
  reaper.ImGui_Dummy(ctx, 0, L.lg)
  if reaper.ImGui_Button(ctx, "Cancel###reset_cancel")
     or reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx, 0, L.md)
  if reaper.ImGui_Button(ctx, "Reset###reset_confirm") then
    Settings.reset_all()
    config = Settings.load()
    set_status(MSG_RESET)
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

local INFO_TABS = {
  { "How it works", {
    "Bind \"Fancy Tap Tempo Slew\" to a key or MIDI note and tap it on each beat.",
    "After the set number of taps, the tempo changes to the average of those taps.",
    "Instant adds a tempo marker at the play position, so what has played keeps its timing.",
    "Glide moves the tempo in effect toward the tapped value at the glide rate.",
    "\"Fancy Tap Tempo Slew Stop\" stops a glide and clears the tap count.",
    "This window only holds settings. Tapping works with it closed.",
  } },
  { "Gestures", {
    "Drag a value: change it.",
    MOD .. "-drag: fine adjust.",
    "Double-click a value: reset it to its default.",
    MOD .. "-click a value: type a number, Enter to apply.",
    "Right-click a value: reset or type.",
    "Esc: close the open dialog, otherwise close the window (when floating).",
    "Space: runs your REAPER Space shortcut (play/stop).",
  } },
  { "About", {
    "Fancy Tap Tempo Slew Settings, part of Fancy Scripts.",
    "Settings are saved in REAPER and shared with the tap action.",
  } },
}

local function draw_info_modal()
  Theme.center_next_window(ctx, L.modal_md.w, L.modal_md.h, reaper.ImGui_Cond_Appearing())
  Theme.modal_scrim(ctx, POPUP_INFO)
  if not reaper.ImGui_BeginPopupModal(ctx, POPUP_INFO, true, 0) then return end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
  if reaper.ImGui_BeginTabBar(ctx, "info_tabs") then
    for _, tab in ipairs(INFO_TABS) do
      if reaper.ImGui_BeginTabItem(ctx, tab[1]) then
        for _, line in ipairs(tab[2]) do reaper.ImGui_TextWrapped(ctx, line) end
        reaper.ImGui_EndTabItem(ctx)
      end
    end
    reaper.ImGui_EndTabBar(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

local function draw_modals()
  if pending_popup then
    reaper.ImGui_OpenPopup(ctx, pending_popup)
    pending_popup = nil
  end
  draw_reset_modal()
  draw_info_modal()
end

-------------------------------------------------------------------------------
-- 9. KEYBOARD (HC5 Esc, HC6 Space)
-------------------------------------------------------------------------------
local KB_MODS = { ["1"] = 0, ["5"] = "shift", ["9"] = "ctrl", ["17"] = "alt" }

local function load_space_cmds()
  local cmds = { [0] = 40044 }
  local f = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  if f then
    for line in f:lines() do
      local mods, cmd = line:match("^KEY (%d+) 32 (%S+) 0")
      local m = mods and KB_MODS[mods]
      if m then
        local id = tonumber(cmd) or reaper.NamedCommandLookup(cmd)
        if id and id > 0 then cmds[m] = id end
      end
    end
    f:close()
  end
  return cmds
end

local function handle_keys(docked)
  if reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
     or reaper.ImGui_IsAnyItemActive(ctx) then
    return true
  end
  if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
    local chords = {
      [0]     = reaper.ImGui_Key_Space(),
      shift   = reaper.ImGui_Mod_Shift() | reaper.ImGui_Key_Space(),
      ctrl    = reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_Space(),
      alt     = reaper.ImGui_Mod_Alt() | reaper.ImGui_Key_Space(),
    }
    for m, chord in pairs(chords) do
      if space_cmds[m] and reaper.ImGui_Shortcut(ctx, chord) then
        reaper.Main_OnCommand(space_cmds[m], 0)
      end
    end
  end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) and not docked then
    return false
  end
  return true
end

-------------------------------------------------------------------------------
-- 10. MAIN LOOP
-------------------------------------------------------------------------------
local function loop()
  local P = Theme.get_palette()
  local nc, nv = Theme.push(ctx, P)
  local pushed = Theme.push_font(ctx, fonts.default)

  Theme.center_next_window(ctx, L.modal_sm.w, L.modal_md.h, reaper.ImGui_Cond_FirstUseEver())
  local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNavInputs()
  local visible, open = reaper.ImGui_Begin(ctx, WINDOW_TITLE, true, flags)
  if visible then
    local docked = reaper.ImGui_IsWindowDocked(ctx)
    label_w = label_w or calc_label_w()

    if not draw_header(docked) then open = false end
    dim_text(summary_text())
    reaper.ImGui_Dummy(ctx, 0, L.md)
    draw_tapping()
    reaper.ImGui_Dummy(ctx, 0, L.lg)
    draw_limits()
    draw_appearance()
    reaper.ImGui_Dummy(ctx, 0, L.lg)
    draw_footer()
    draw_modals()
    if not handle_keys(docked) then open = false end

    reaper.ImGui_End(ctx)
  end

  Theme.pop_font(ctx, pushed)
  Theme.pop(ctx, nc, nv)

  if open then reaper.defer(loop) end
end

-------------------------------------------------------------------------------
-- 11. BOOTSTRAP
-------------------------------------------------------------------------------
local function main()
  local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
  ctx = reaper.ImGui_CreateContext(WINDOW_TITLE, dock_flag)
  fonts = Theme.create_fonts(ctx)
  Theme.attach_fonts(ctx, fonts)
  space_cmds = load_space_cmds()
  load_config()
  reaper.defer(loop)
end

main()
