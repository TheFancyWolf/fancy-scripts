-- @description Fancy Selected Track Meter
-- @author Fancy Scripts
-- @version 9.68.0
-- @changelog
--   # Uses the shared Fancy Scripts design system: theme palette and fonts, Theme Mode and Show Tooltips in Settings
--   # The second meter says what it shows: LOUDNESS from REAPER's track meter, or a dimmed "RMS est." estimate
--   # Settings tabs are no longer drawn with inverted colours; settings are drags (Cmd/Ctrl-drag fine, double-click reset, Cmd/Ctrl-click to type)
--   + Resetting colours and clearing the clip log (button or C) ask for confirmation first
--   + Esc closes Settings, Recent Clips and a floating meter; Space runs your REAPER Space binding
--   # Settings save as you change them; the toolbar button shows when the meter is running
-- @about
--   Real-time visual metering display for selected tracks.
--   Features customizable colors, peak hold, and docking support.
--   Requirements: ReaImGui extension (install via ReaPack)
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
    "Fancy Selected Track Meter -- Missing ReaImGui", 0)
  return
end

local ctx = reaper.ImGui_CreateContext('Selected Track Meter', reaper.ImGui_ConfigFlags_DockingEnable())

-------------------------------------------------------------------------------
-- 2. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")
local Utils = require("utils")

local L  = Theme.layout
local FS = Theme.font_sizes

local fonts = Theme.create_fonts(ctx)
Theme.attach_fonts(ctx, fonts)

-- Active palette (refreshed at the start of every frame, follows Theme Mode)
local P = Theme.get_palette()

-- Modifier name for help text: Cmd is reported as Mod_Ctrl on macOS (GetOS: "OSX64", "macOS-arm64", ...)
local OS = reaper.GetOS()
local MOD_LABEL = (OS:match("OSX") or OS:match("macOS")) and "Cmd" or "Ctrl"

-------------------------------------------------------------------------------
-- 3. DEFAULTS, LAYOUT CONSTANTS & USER COLOURS
-------------------------------------------------------------------------------
-- AR1: single source of truth for defaults and resets
local DEFAULTS = {
  show_balance_meter      = true,
  meter_scale_mode        = 1,       -- 1: Linear, 2: Mixer's Curve
  balance_meter_height    = 80,
  balance_db_scale        = 12.0,
  balance_window_sec      = 2.0,
  balance_window_sec_fast = 0.15,
  column_gap              = L.lg,
  peak_db_min             = -60.0,
  peak_db_max             = 0.0,
  rms_db_min              = -60.0,
  rms_db_max              = 0.0,
  falloff_db_sec          = 20.0,
  damping                 = 0.15,
  tgt_peak_active         = false,
  tgt_peak_db             = -10.0,
  tgt_rms_active          = false,
  tgt_rms_db              = -18.0,
  tgt_marker_size         = 1,       -- 0: Small, 1: Large
  tgt_marker_indent       = L.md,
  tgt_marker_bg_alpha     = 0.75,
  rolling_window_sec      = 3.0,
  -- Appearance (saved with the "V_" prefix)
  Dim_Opacity_Pct         = 0.75,
  Tooltip_Font_Size       = FS.default,
  Settings_Font_Size      = FS.default,
}

-- Window sizes: no Theme.layout token exists for a tool window's first-use / minimum size (library proposal)
local WIN = { first_w = 300, first_h = 640, min_w = 220, min_h = 460, settings_item_w = 160 }

-- DV1: the RMS smoothing coefficient was tuned per frame at ~30 fps; it is now scaled by frame time
local SMOOTH_REF_DT = 1 / 30

-- Status line: how long a message stays before the idle hint returns
local STATUS_SECS = 3.0

-- Target-marker glyph scales relative to the marker's value text
local MARKER_INF_SCALE, MARKER_ROLL_SCALE = 1.45, 0.9

-- Customisable colours. A user value overrides; nil follows the theme palette (default from P)
local COLOR_DEFAULT = {
  Color_Safe       = function() return P.green end,
  Color_Warn       = function() return P.yellow end,
  Color_Clip       = function() return P.red end,
  Color_TargetLine = function() return P.accent end,
  Color_MeterBG    = function() return P.panel end,
  Color_Background = function() return P.bg end,
  Tab_Inactive     = function() return P.card end,
  Tab_Hovered      = function() return P.accent_h end,
  Tab_Active       = function() return P.accent_press end,
}

-- One-time migration from v9.67.2 and earlier, which wrote every key at exit: a saved value equal to the old
-- hardcoded default was never chosen by the user, so it maps back to "follow the theme". Comparison only; never
-- drawn. After the first save "V_ds_migrated" is set and saved values are always kept as they are.
local LEGACY_DEFAULTS = {
  Color_Safe = 0x0088CCFF, Color_Warn = 0xE0B000FF, Color_Clip = 0xDD0000FF, Color_TargetLine = 0x00FFCCFF,
  Color_MeterBG = 0x1A1A1AFF, Color_Background = 0x202020FF,
  Tab_Inactive = 0x2A2A2AFF, Tab_Hovered = 0x4A4A4AFF, Tab_Active = 0x0088CCFF,
  Tooltip_Font_Size = 16, Settings_Font_Size = 16,
}

local user_color = {}   -- key -> 0xRRGGBBAA (nil = theme default)

local function col(key)
  return user_color[key] or COLOR_DEFAULT[key]()
end

-------------------------------------------------------------------------------
-- 4. FUNCTIONAL STATE
-------------------------------------------------------------------------------
local State = {
  show_settings      = false,
  is_locked          = false,
  locked_track       = nil,
  last_active_track  = nil,

  balance_val        = 0.0,
  balance_val_fast   = 0.0,
  meter_width        = 50,

  peak_max_l         = -150,
  peak_max_r         = -150,
  rms_smooth_l       = 0,
  rms_smooth_r       = 0,
  loudness_seen      = false,   -- ST4: REAPER reported loudness for this track at least once

  num_peak_max       = -150,
  num_rms_max        = -150,
  peak_warn_db       = -6.0,

  audio_history      = {},
  roll_peak_max      = -150,
  roll_rms_max       = -150,
  disp_roll_peak     = -150,
  disp_roll_rms      = -150,

  clip_log           = {},
  show_clip_log      = false,
  last_clip_time     = -100,

  play_state         = 0,
  play_start_time    = 0,
  last_time          = reaper.time_precise(),
}

-- Visual (V_) values that are not colours
local Vis = {
  Dim_Opacity_Pct    = DEFAULTS.Dim_Opacity_Pct,
  Tooltip_Font_Size  = nil,   -- nil = DEFAULTS
  Settings_Font_Size = nil,
}

for k, v in pairs(DEFAULTS) do
  if State[k] == nil and Vis[k] == nil and k ~= "Dim_Opacity_Pct"
     and k ~= "Tooltip_Font_Size" and k ~= "Settings_Font_Size" then
    State[k] = v
  end
end

local PERSIST_STATE_KEYS = {
  "show_balance_meter", "meter_scale_mode",
  "balance_meter_height", "balance_db_scale", "balance_window_sec", "balance_window_sec_fast",
  "column_gap", "peak_db_min", "peak_db_max", "rms_db_min", "rms_db_max",
  "falloff_db_sec", "damping",
  "tgt_peak_active", "tgt_peak_db", "tgt_rms_active", "tgt_rms_db",
  "tgt_marker_size", "tgt_marker_indent", "tgt_marker_bg_alpha",
  "rolling_window_sec",
}

local COLOR_KEYS = {
  "Color_Safe", "Color_Warn", "Color_Clip", "Color_TargetLine", "Color_MeterBG", "Color_Background",
  "Tab_Active", "Tab_Inactive", "Tab_Hovered",
}

-- HC4 confirm modals: pending flags, opened once inside the owning window
local pending_confirm = { reset_colors = false, clear_log_main = false, clear_log_clips = false }

-- HC6: Space chords -> REAPER Main-section command ids (filled from reaper-kb.ini at startup)
local space_cmds = { [0] = 40044 }

-- ST2: one status channel (main window, bottom line)
local status_msg, status_time = "", 0
local function set_status(msg)
  status_msg, status_time = msg, reaper.time_precise()
end

-------------------------------------------------------------------------------
-- 5. STATE PERSISTENCE (HI4: saved on change / release, and at exit)
-------------------------------------------------------------------------------
local EXT = "FW_TrackMeter"
local settings_dirty = false

local function font_size(key)
  return Vis[key] or DEFAULTS[key]
end

local function LoadSettings()
  for _, k in ipairs(PERSIST_STATE_KEYS) do
    local val = reaper.GetExtState(EXT, "S_" .. k)
    if val ~= "" then
      if type(DEFAULTS[k]) == "boolean" then State[k] = (val == "true")
      elseif type(DEFAULTS[k]) == "number" then State[k] = tonumber(val) or DEFAULTS[k]
      else State[k] = val end
    end
  end
  if State.meter_scale_mode ~= 2 then State.meter_scale_mode = 1 end
  if State.tgt_marker_size ~= 0 then State.tgt_marker_size = 1 end

  local dim = tonumber(reaper.GetExtState(EXT, "V_Dim_Opacity_Pct"))
  if dim then Vis.Dim_Opacity_Pct = math.max(0, math.min(1, dim)) end

  local migrated = reaper.GetExtState(EXT, "V_ds_migrated") == "1"
  local function is_legacy_default(k, n)
    return not migrated and n == LEGACY_DEFAULTS[k]
  end

  for _, k in ipairs({ "Tooltip_Font_Size", "Settings_Font_Size" }) do
    local n = tonumber(reaper.GetExtState(EXT, "V_" .. k))
    if n and not is_legacy_default(k, n) then Vis[k] = math.max(10, math.min(36, math.floor(n))) end
  end

  for _, k in ipairs(COLOR_KEYS) do
    local n = math.tointeger(tonumber(reaper.GetExtState(EXT, "V_" .. k)))
    if n and not is_legacy_default(k, n) then user_color[k] = n end
  end
end

local function SaveSettings()
  for _, k in ipairs(PERSIST_STATE_KEYS) do
    reaper.SetExtState(EXT, "S_" .. k, tostring(State[k]), true)
  end
  reaper.SetExtState(EXT, "V_Dim_Opacity_Pct", tostring(Vis.Dim_Opacity_Pct), true)
  for _, k in ipairs({ "Tooltip_Font_Size", "Settings_Font_Size" }) do
    if Vis[k] then reaper.SetExtState(EXT, "V_" .. k, tostring(Vis[k]), true)
    else reaper.DeleteExtState(EXT, "V_" .. k, true) end
  end
  for _, k in ipairs(COLOR_KEYS) do
    if user_color[k] then reaper.SetExtState(EXT, "V_" .. k, tostring(user_color[k]), true)
    else reaper.DeleteExtState(EXT, "V_" .. k, true) end
  end
  reaper.SetExtState(EXT, "V_ds_migrated", "1", true)
  settings_dirty = false
end

local function mark_dirty()
  settings_dirty = true
end

--- Writes pending changes once nothing is being dragged or edited (end of frame).
local function flush_settings()
  if settings_dirty and not reaper.ImGui_IsAnyItemActive(ctx) and not reaper.ImGui_IsMouseDown(ctx, 0) then
    SaveSettings()
  end
end

--- HC6: reads the user's Space bindings in REAPER's Main section from reaper-kb.ini.
local function load_space_bindings()
  local mod_map = {
    ["1"]  = 0,
    ["5"]  = reaper.ImGui_Mod_Shift(),
    ["9"]  = reaper.ImGui_Mod_Ctrl(),
    ["17"] = reaper.ImGui_Mod_Alt(),
  }
  local f = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  if not f then return end
  for line in f:lines() do
    local mods, cmd, section = line:match("^KEY%s+(%d+)%s+32%s+(%S+)%s+(%d+)")
    if mods and section == "0" and mod_map[mods] then
      local id = tonumber(cmd) or reaper.NamedCommandLookup(cmd)
      if id and id > 0 then space_cmds[mod_map[mods]] = id end
    end
  end
  f:close()
end

-------------------------------------------------------------------------------
-- 6. MATH, COLOUR & TEXT HELPERS
-------------------------------------------------------------------------------
local function AmpToDb(amp)
  if not amp or amp <= 0.0000001 then return -150.0 end
  return 20.0 * math.log(amp, 10)
end

local function MapRange(val, in_min, in_max, out_min, out_max)
  if not val or not in_min or not in_max or not out_min or not out_max then return 0 end
  if val ~= val then val = in_min end
  local lowest_in = math.min(in_min, in_max)
  local highest_in = math.max(in_min, in_max)
  local clamped_val = math.max(lowest_in, math.min(val, highest_in))
  local denominator = (in_max - in_min)
  if denominator == 0 then return out_min end
  return (clamped_val - in_min) * (out_max - out_min) / denominator + out_min
end

local function GetYForDb(db, h, mode, min_db, max_db)
  if mode == 2 and min_db < -24.0 then
    local pivot_db = -24.0
    local pivot_y = h * 0.65
    if db >= pivot_db then return MapRange(db, pivot_db, max_db, pivot_y, 0)
    else return MapRange(db, min_db, pivot_db, h, pivot_y) end
  else
    return MapRange(db, min_db, max_db, h, 0)
  end
end

local function GetDbForY(y, h, mode, min_db, max_db)
  if mode == 2 and min_db < -24.0 then
    local pivot_db = -24.0
    local pivot_y = h * 0.65
    if y <= pivot_y then return MapRange(y, pivot_y, 0, pivot_db, max_db)
    else return MapRange(y, h, pivot_y, min_db, pivot_db) end
  else
    return MapRange(y, h, 0, min_db, max_db)
  end
end

local function GetReadoutStr(val)
  if not val or val <= -140 then return "-inf" end
  if val > 0.0 then return string.format("+%.1f", val) end
  return string.format("%.1f", val)
end

--- Relative luminance (sRGB) of 0xRRGGBBAA.
local function luminance(c)
  local function ch(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * ch((c >> 24) & 0xFF) + 0.7152 * ch((c >> 16) & 0xFF) + 0.0722 * ch((c >> 8) & 0xFF)
end

--- HC1: pure white or pure black, whichever reads better on `bg` (>= 4.58:1 on any opaque colour).
local function ink_on(bg)
  local opaque = Theme.with_alpha(P.text, 1.0)
  if luminance(bg) > 0.179 then return Theme.darken(opaque, 1.0) end
  return Theme.lighten(opaque, 1.0)
end

--- MT2: text measured with the font and size it is drawn in.
local function text_size(font, size, text)
  local pushed = Theme.push_font(ctx, font, size)
  local w, h = reaper.ImGui_CalcTextSize(ctx, text)
  Theme.pop_font(ctx, pushed)
  return w, h
end

--- RB15: tooltip after the hover delay, honouring Show Tooltips, at the user's tooltip size.
local function tip(text, disabled)
  local flags = reaper.ImGui_HoveredFlags_ForTooltip()
  if disabled then flags = flags | reaper.ImGui_HoveredFlags_AllowWhenDisabled() end
  if reaper.ImGui_IsItemHovered(ctx, flags) then
    local pushed = Theme.push_font(ctx, fonts.default, font_size("Tooltip_Font_Size"))
    Theme.tooltip(ctx, text)
    Theme.pop_font(ctx, pushed)
  end
end

--- MT2: hover state + hand cursor for custom DrawList controls. Returns true when hovered.
local function hover_hand()
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    return true
  end
  return false
end

local function DrawThickText(draw_list, font, size, x, y, color, text, shadow_color, kerning)
  kerning = kerning or 0
  if kerning <= 0 then
    if shadow_color then
      reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x + 1, y + 1, shadow_color, text)
      reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x + 2, y + 1, shadow_color, text)
    end
    reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x, y, color, text)
    reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x + 1, y, color, text)
  else
    local cx = x
    for i = 1, #text do
      local char = text:sub(i, i)
      if shadow_color then
        reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx + 1, y + 1, shadow_color, char)
        reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx + 2, y + 1, shadow_color, char)
      end
      reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx, y, color, char)
      reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx + 1, y, color, char)
      cx = cx + text_size(font, size, char) + kerning
    end
  end
end

local function reset_holds()
  State.num_peak_max   = -150
  State.num_rms_max    = -150
  State.audio_history  = {}
  State.roll_peak_max  = -150
  State.roll_rms_max   = -150
  State.disp_roll_peak = -150
  State.disp_roll_rms  = -150
end

local function clear_clip_log()
  State.clip_log = {}
  State.last_clip_time = -100
end

--- Shared geometry of a meter pair (labels, readout boxes, bars) starting at y.
local function pair_geometry(start_y)
  local box_y = start_y + L.xxl
  local box_h = L.xxxl + L.md
  local meter_y = box_y + box_h + L.md
  return box_y, box_h, meter_y
end

-------------------------------------------------------------------------------
-- 7. METER DRAWING
-------------------------------------------------------------------------------
local function DrawBalanceMeter(draw_list, width, x_pos, y_pos, balance_val, balance_val_fast, current_height)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, y_pos, x_pos + width, y_pos + current_height + L.md,
    col("Color_MeterBG"), L.rounding)

  local center_x = x_pos + (width / 2)
  local center_y = y_pos + (current_height / 2 + L.xs)

  local track_w = width - L.xxxl * 2
  local track_x1 = center_x - (track_w / 2)
  local track_x2 = center_x + (track_w / 2)

  local grid = Theme.with_alpha(P.border, 0.8)
  reaper.ImGui_DrawList_AddLine(draw_list, track_x1, center_y, track_x2, center_y, grid, 2.0)
  reaper.ImGui_DrawList_AddLine(draw_list, center_x, center_y - L.md, center_x, center_y + L.md, P.text_dim, 2.0)

  local max_db = State.balance_db_scale or DEFAULTS.balance_db_scale
  local half_db = max_db / 2.0
  for _, db in ipairs({ -max_db, -half_db, half_db, max_db }) do
    local px = center_x + (db / max_db) * (track_w / 2)
    reaper.ImGui_DrawList_AddLine(draw_list, px, center_y - L.sm, px, center_y + L.sm, grid, 1.5)
    local txt
    if math.floor(db) == db then txt = tostring(math.abs(db))
    else txt = string.format("%.1f", math.abs(db)) end
    local tw = text_size(fonts.default_bold, FS.small, txt)
    reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default_bold, FS.small, px - (tw / 2), center_y + L.md,
      P.text_dim, txt)
  end

  local title = "STEREO BALANCE DRIFT"
  local title_tw = text_size(fonts.small, FS.small, title)
  local title_y = y_pos + L.md
  reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.small, FS.small, center_x - (title_tw / 2), title_y, P.text, title)
  reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.small, FS.small, track_x1, title_y, P.text_dim, "L")
  local r_tw = text_size(fonts.small, FS.small, "R")
  reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.small, FS.small, track_x2 - r_tw, title_y, P.text_dim, "R")

  local safe_slow = balance_val or 0.0
  local safe_fast = balance_val_fast or 0.0
  local clamped_slow = math.max(-max_db, math.min(safe_slow, max_db))
  local clamped_fast = math.max(-max_db, math.min(safe_fast, max_db))
  local bubble_x_slow = center_x + (clamped_slow / max_db) * (track_w / 2)
  local bubble_x_fast = center_x + (clamped_fast / max_db) * (track_w / 2)

  reaper.ImGui_DrawList_AddCircle(draw_list, bubble_x_fast, center_y, L.md + 1, Theme.with_alpha(P.text, 0.27), 12, 1.5)
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, bubble_x_slow, center_y, L.sm + L.xs, col("Color_Safe"))
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, bubble_x_slow, center_y, L.xs, col("Color_Background"))

  local diff_str
  if math.abs(safe_slow) < 0.1 then diff_str = "Centered"
  elseif safe_slow < 0 then diff_str = string.format("Left leaning by %.1f dB", math.abs(safe_slow))
  else diff_str = string.format("Right leaning by %.1f dB", math.abs(safe_slow)) end
  local diff_tw, diff_th = text_size(fonts.small, FS.small, diff_str)
  reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.small, FS.small, center_x - (diff_tw / 2),
    y_pos + current_height - diff_th + L.xs, P.text_dim, diff_str)

  reaper.ImGui_SetCursorScreenPos(ctx, x_pos, y_pos)
  reaper.ImGui_InvisibleButton(ctx, "balance_tt", width, current_height)
  tip("Stereo Balance Drift\n\nWhere the level sits between Left and Right.\n"
    .. "The dot follows the smoothed RMS difference (Slow Drift Speed); the ring follows the peak difference "
    .. "(Fast Drift Speed).\n\nShortcut: B shows or hides this meter.")
end

local function draw_target_toggle(label, x, y, active)
  local hit = L.xxl   -- MT1: 24 px target
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, label .. "_tgt_toggle", hit, hit)
  local hovered = hover_hand()
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cx, cy = x + hit / 2, y + hit / 2
  local r = L.sm + L.xs
  local c = active and col("Color_TargetLine") or P.text_dim
  if hovered then
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, hit / 2, Theme.with_alpha(P.text, 0.12))
    c = Theme.lighten(c, 0.25)
  end
  -- CL2: on = ring + centre dot (a target); off = ring only
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r, c, 16, 1.5)
  if active then reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, L.xs + 0.5, c) end
  tip(string.format("Target marker: %s\n\nClick to %s the target line.\n"
    .. "Click or drag on the meter to set the target level (this also turns it on).",
    active and "on" or "off", active and "hide" or "show"))
  return clicked
end

--- Draws one stereo meter pair. `head` = { text, color, tooltip } for the column label.
local function DrawStereoMeterPair(draw_list, x_pos, start_y, val_l, val_r, head, id, db_min, db_max, w, h,
                                   inf_val, roll_val, tgt_active, tgt_db, scale_mode)
  local s = L.xs
  local total_w = (w * 2) + s
  local new_tgt_active = tgt_active
  local new_tgt_db = tgt_db or -6.0
  local tgt_released = false

  local box_y, box_h, meter_y = pair_geometry(start_y)
  local box_w = math.floor((total_w - s) / 2)

  -- Column label + target toggle
  local lw, lh = text_size(fonts.default_bold, FS.default, head.text)
  local toggle = L.xxl
  local group_w = lw + L.xs + toggle
  local start_x = x_pos + (total_w / 2) - (group_w / 2)
  local label_y = start_y + (toggle - lh) / 2
  reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default_bold, FS.default, start_x, label_y, head.color, head.text)
  reaper.ImGui_SetCursorScreenPos(ctx, start_x, label_y)
  reaper.ImGui_InvisibleButton(ctx, id .. "_lbl_tt", math.max(1, lw), math.max(1, lh))
  tip(head.tooltip)

  if draw_target_toggle(id, start_x + lw + L.xs, start_y, new_tgt_active) then
    new_tgt_active = not new_tgt_active
    tgt_released = true
  end

  -- Readout boxes: infinite hold (left) and rolling window (right)
  local function readout_box(bx, value, glyph, glyph_font, glyph_size, btn_id, tooltip)
    local clipping = value >= 0.0
    local bg = clipping and col("Color_Clip") or col("Color_MeterBG")
    reaper.ImGui_SetCursorScreenPos(ctx, bx, box_y)
    local pressed = reaper.ImGui_InvisibleButton(ctx, btn_id, box_w, box_h)
    if hover_hand() then bg = Theme.lighten(bg, 0.10) end
    local txt_col = clipping and ink_on(bg) or P.text
    local icn_col = clipping and ink_on(bg) or P.text_dim
    reaper.ImGui_DrawList_AddRectFilled(draw_list, bx, box_y, bx + box_w, box_y + box_h, bg, L.xs)

    local gw, gh = text_size(glyph_font, glyph_size, glyph)
    reaper.ImGui_DrawList_AddTextEx(draw_list, glyph_font, glyph_size, bx + (box_w - gw) / 2, box_y + L.xs, icn_col, glyph)
    local str = GetReadoutStr(value)
    local sw = text_size(fonts.default_bold, FS.default, str)
    reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default_bold, FS.default, bx + (box_w - sw) / 2,
      box_y + L.xs + gh, txt_col, str)
    tip(tooltip)
    return pressed
  end

  local clicked_inf_reset = readout_box(x_pos, inf_val, "∞", fonts.medium, FS.medium, id .. "_inf_btn",
    "Infinite hold (∞): the highest value since playback started.\n\n"
    .. "Click or press R to reset.\nC clears the clip log and resets (asks first when clips are logged).")
  local clicked_roll_reset = readout_box(x_pos + box_w + s, roll_val, "↻", fonts.default, FS.default, id .. "_roll_btn",
    string.format("Rolling hold (↻): the highest value in the last %.1f seconds.\n\n"
      .. "Click or press R to reset.\nC clears the clip log and resets (asks first when clips are logged).",
      State.rolling_window_sec))

  reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, meter_y, x_pos + w, meter_y + h, col("Color_MeterBG"))
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos + w + s, meter_y, x_pos + total_w, meter_y + h, col("Color_MeterBG"))

  -- Meter hitbox: click or drag anywhere to turn the target on and set its level
  reaper.ImGui_SetCursorScreenPos(ctx, x_pos, meter_y)
  reaper.ImGui_InvisibleButton(ctx, id .. "_meter_hitbox", total_w, h)
  local is_meter_hovered = false
  local hover_mx, hover_my = 0, 0
  if reaper.ImGui_IsItemActive(ctx) then
    new_tgt_active = true
    local _, my = reaper.ImGui_GetMousePos(ctx)
    new_tgt_db = GetDbForY(my - meter_y, h, scale_mode, db_min, db_max)
    new_tgt_db = math.max(db_min, math.min(db_max, new_tgt_db))
  end
  if reaper.ImGui_IsItemDeactivated(ctx) then tgt_released = true end
  if reaper.ImGui_IsItemHovered(ctx) then
    is_meter_hovered = true
    hover_mx, hover_my = reaper.ImGui_GetMousePos(ctx)
  end

  -- Threshold logic
  local current_warn_db = State.peak_warn_db
  local current_clip_db = 0.0
  if new_tgt_active then
    current_warn_db = new_tgt_db + 1.0
    current_clip_db = new_tgt_db + 3.0
  end

  local y_warn = GetYForDb(current_warn_db, h, scale_mode, db_min, db_max)
  local y_clip = GetYForDb(current_clip_db, h, scale_mode, db_min, db_max)

  local function draw_bar(x1, x2, val)
    local y_v = GetYForDb(val, h, scale_mode, db_min, db_max)
    if y_v >= h then return end
    local safe_top = math.max(y_v, y_warn)
    if safe_top < h then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, meter_y + safe_top, x2, meter_y + h, col("Color_Safe"))
    end
    if val > current_warn_db then
      local warn_top = math.max(y_v, y_clip)
      if warn_top < y_warn then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, meter_y + warn_top, x2, meter_y + y_warn, col("Color_Warn"))
      end
    end
    if val > current_clip_db and y_v < y_clip then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, meter_y + y_v, x2, meter_y + y_clip, col("Color_Clip"))
    end
  end
  draw_bar(x_pos, x_pos + w, val_l)
  draw_bar(x_pos + w + s, x_pos + total_w, val_r)

  -- Grid ticks
  local ticks = {}
  if scale_mode == 2 then
    ticks = { 0, -3, -6, -9, -12, -15, -18, -21, -24, -36, -48, -60 }
  else
    for d = 0, math.floor(db_min or -60), -6 do ticks[#ticks + 1] = d end
  end
  local grid = Theme.with_alpha(P.border, 0.6)
  local shadow = Theme.with_alpha(P.bg, 0.8)
  for _, db in ipairs(ticks) do
    if db <= db_max and db >= db_min then
      local line_y = meter_y + GetYForDb(db, h, scale_mode, db_min, db_max)
      reaper.ImGui_DrawList_AddLine(draw_list, x_pos, line_y, x_pos + total_w, line_y, grid, 1.0)

      local db_str = db == 0 and "-0-" or "-" .. tostring(math.abs(db)) .. "-"
      local str_w, str_h = text_size(fonts.default_bold, FS.small, db_str)
      local kerned_w = str_w + (#db_str - 1) * L.xs
      local str_x = x_pos + (total_w / 2) - (kerned_w / 2)
      local str_y = line_y - (str_h / 2)
      if math.max(val_l, val_r) >= db then
        DrawThickText(draw_list, fonts.default_bold, FS.small, str_x, str_y, col("Color_Background"), db_str, nil, L.xs)
      else
        DrawThickText(draw_list, fonts.default_bold, FS.small, str_x, str_y, P.text, db_str, shadow, L.xs)
      end
    end
  end

  -- Target marker
  if new_tgt_active then
    local tcol = col("Color_TargetLine")
    local ty = meter_y + GetYForDb(new_tgt_db, h, scale_mode, db_min, db_max)
    reaper.ImGui_DrawList_AddLine(draw_list, x_pos, ty, x_pos + total_w, ty, tcol, 2.0)

    local function delta_str(v)
      if not v or v <= -140 then return "---" end
      local d = new_tgt_db - v
      if d > 0.0 then return string.format("+%.1f", d) end
      return string.format("%.1f", d)
    end
    local l_val, r_val = delta_str(inf_val), delta_str(roll_val)
    local bg_col = Theme.with_alpha(col("Color_Background"), State.tgt_marker_bg_alpha)
    local base = State.tgt_marker_size == 1 and FS.large or FS.small
    local inf_sz, roll_sz, val_sz = base * MARKER_INF_SCALE, base * MARKER_ROLL_SCALE, base
    local li_tw, li_th = text_size(fonts.default, inf_sz, "∞")
    local ri_tw, ri_th = text_size(fonts.default, roll_sz, "↻")
    local lv_tw, lv_th = text_size(fonts.default, val_sz, l_val)
    local rv_tw, rv_th = text_size(fonts.default, val_sz, r_val)

    local handle_x, handle_y, handle_w, handle_h
    if State.tgt_marker_size == 1 then
      -- Large: glyph above value in each half
      local pad_y = L.sm
      local icon_h = math.max(li_th, ri_th)
      local val_h = math.max(lv_th, rv_th)
      local min_w = math.max(li_tw, lv_tw) + math.max(ri_tw, rv_tw) + L.xxl
      handle_w = math.max(min_w, total_w - (State.tgt_marker_indent * 2))
      handle_h = icon_h + val_h + pad_y * 3
      handle_x = x_pos + (total_w / 2) - (handle_w / 2)
      handle_y = ty - (handle_h / 2)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, bg_col, L.rounding)
      reaper.ImGui_DrawList_AddRect(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, tcol, L.rounding, 0, 1.5)
      local div_x = handle_x + handle_w / 2
      reaper.ImGui_DrawList_AddLine(draw_list, div_x, handle_y, div_x, handle_y + handle_h, tcol, 1.0)
      local q1_x, q3_x = handle_x + handle_w / 4, div_x + handle_w / 4
      local icon_y, val_y = handle_y + pad_y, handle_y + pad_y * 2 + icon_h
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, inf_sz, q1_x - li_tw / 2, icon_y + (icon_h - li_th) / 2, tcol, "∞")
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, val_sz, q1_x - lv_tw / 2, val_y + (val_h - lv_th) / 2, tcol, l_val)
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, roll_sz, q3_x - ri_tw / 2, icon_y + (icon_h - ri_th) / 2, tcol, "↻")
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, val_sz, q3_x - rv_tw / 2, val_y + (val_h - rv_th) / 2, tcol, r_val)
    else
      -- Small: glyph and value inline in each half
      local gap = L.sm
      local pad_y = L.xs
      local l_total_w = li_tw + gap + lv_tw
      local r_total_w = ri_tw + gap + rv_tw
      local min_w = l_total_w + r_total_w + L.xxl
      handle_w = math.max(min_w, total_w - (State.tgt_marker_indent * 2))
      handle_h = math.max(li_th, ri_th, lv_th, rv_th) + pad_y * 2
      handle_x = x_pos + (total_w / 2) - (handle_w / 2)
      handle_y = ty - (handle_h / 2)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, bg_col, L.rounding)
      reaper.ImGui_DrawList_AddRect(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, tcol, L.rounding, 0, 1.5)
      local div_x = handle_x + handle_w / 2
      reaper.ImGui_DrawList_AddLine(draw_list, div_x, handle_y, div_x, handle_y + handle_h, tcol, 1.0)
      local lx = handle_x + handle_w / 4 - l_total_w / 2
      local rx = div_x + handle_w / 4 - r_total_w / 2
      local mid = handle_y + handle_h / 2
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, inf_sz, lx, mid - li_th / 2, tcol, "∞")
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, val_sz, lx + li_tw + gap, mid - lv_th / 2, tcol, l_val)
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, roll_sz, rx, mid - ri_th / 2, tcol, "↻")
      reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default, val_sz, rx + ri_tw + gap, mid - rv_th / 2, tcol, r_val)
    end
  end

  -- Cursor target icon (the meter's affordance) + tooltip
  if is_meter_hovered then
    local tcol = col("Color_TargetLine")
    local icon_x, icon_y = hover_mx + L.md + L.xs, hover_my - L.md - L.xs
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, icon_x, icon_y, L.sm + L.md / 2 - 1, col("Color_Background"))
    reaper.ImGui_DrawList_AddCircle(draw_list, icon_x, icon_y, L.sm + L.xs, tcol, 12, 1.5)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, icon_x, icon_y, L.xs, tcol)
  end

  return clicked_inf_reset, clicked_roll_reset, new_tgt_active, new_tgt_db, tgt_released
end

-------------------------------------------------------------------------------
-- 8. SHARED WIDGETS (param drags, confirm modals, Space / Esc)
-------------------------------------------------------------------------------
--- Danger styling for destructive buttons (red family by palette key).
local function push_danger()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.red_l)
end
local function pop_danger()
  reaper.ImGui_PopStyleColor(ctx, 4)
end

--- HC2/HC3 parameter drag: AlwaysClamp | NoInput | NoSpeedTweaks, Ctrl/Cmd-drag fine adjust,
--- double-click resets to opts.default, Ctrl/Cmd-click released without dragging opens text entry.
--- @return boolean changed, number value
local drag_state = {}
local function param_drag(id, label, value, opts)
  local ctrl = (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  local flags = reaper.ImGui_SliderFlags_AlwaysClamp() | reaper.ImGui_SliderFlags_NoInput()
              | reaper.ImGui_SliderFlags_NoSpeedTweaks()
  local speed = ctrl and opts.speed * 0.1 or opts.speed
  reaper.ImGui_SetNextItemWidth(ctx, WIN.settings_item_w)
  local rv, v
  if opts.is_int then
    rv, v = reaper.ImGui_DragInt(ctx, label .. "###" .. id, value, speed, opts.lo, opts.hi, opts.fmt, flags)
  else
    rv, v = reaper.ImGui_DragDouble(ctx, label .. "###" .. id, value, speed, opts.lo, opts.hi, opts.fmt, flags)
  end

  local st = drag_state[id] or {}
  drag_state[id] = st
  if reaper.ImGui_IsItemActivated(ctx) then st.ctrl, st.dragged = ctrl, false end
  if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then st.dragged = true end
  local open_typing = reaper.ImGui_IsItemDeactivated(ctx) and st.ctrl and not st.dragged

  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    rv, v = true, opts.default
  end

  if opts.tooltip then
    tip(opts.tooltip .. string.format("\n\nDrag to adjust (%s-drag: fine). Double-click: reset. %s-click: type a value.",
      MOD_LABEL, MOD_LABEL))
  end

  local popup_id = "type###" .. id
  if open_typing then reaper.ImGui_OpenPopup(ctx, popup_id) end
  if reaper.ImGui_BeginPopup(ctx, popup_id) then
    reaper.ImGui_Text(ctx, label)
    if reaper.ImGui_IsWindowAppearing(ctx) then
      st.typed = v
      reaper.ImGui_SetKeyboardFocusHere(ctx)
    end
    reaper.ImGui_SetNextItemWidth(ctx, WIN.settings_item_w)
    -- Scalar inputs reject InputTextFlags_EnterReturnsTrue: keep the typed value and apply it on Enter
    local _, typed
    if opts.is_int then
      _, typed = reaper.ImGui_InputInt(ctx, "##typed", st.typed or v, 0, 0)
    else
      _, typed = reaper.ImGui_InputDouble(ctx, "##typed", st.typed or v, 0, 0, opts.type_fmt or "%.2f")
    end
    st.typed = typed
    local entered = reaper.ImGui_IsItemDeactivated(ctx)
      and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
           or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false))
    if entered and typed then
      rv, v = true, math.max(opts.lo, math.min(opts.hi, typed))
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif not reaper.ImGui_IsAnyItemActive(ctx) and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return rv, v
end

--- Param drag bound to tbl[key]; `scale` shows a fraction as a percentage. Marks settings dirty on change.
local function drag_setting(tbl, key, label, opts)
  local scale = opts.scale or 1
  local cur = tbl[key] or DEFAULTS[key]
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.default = DEFAULTS[key] * scale
  local changed, v = param_drag(key, label, cur * scale, o)
  if changed then
    tbl[key] = opts.is_int and math.floor(v + 0.5) or v / scale
    mark_dirty()
  end
  return changed
end

--- HC4 confirm modal: names the consequence, Cancel first, Esc = Cancel. Call inside the owning window.
local function draw_confirm_modal(key, popup_id, message, action_label, on_confirm)
  if pending_confirm[key] then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    pending_confirm[key] = false
  end
  -- RB9: fit the owning window (a modal wider than its parent becomes its own OS window, outside the scrim)
  local w = math.min(L.modal_sm.w, reaper.ImGui_GetWindowWidth(ctx) - L.lg * 2)
  Theme.center_next_window(ctx, w, 0, reaper.ImGui_Cond_Appearing())
  Theme.modal_scrim(ctx, popup_id)
  local flags = reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  if reaper.ImGui_BeginPopupModal(ctx, popup_id, true, flags) then
    reaper.ImGui_TextWrapped(ctx, message)
    reaper.ImGui_Dummy(ctx, 0, L.md)
    if reaper.ImGui_Button(ctx, "Cancel###" .. key .. "_cancel")
       or reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    push_danger()
    local confirmed = reaper.ImGui_Button(ctx, action_label .. "###" .. key .. "_ok")
    pop_danger()
    if confirmed then
      on_confirm()
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function plural(n, word)
  return n == 1 and ("1 " .. word) or (n .. " " .. word .. "s")
end

local function clip_count_str(n)
  return plural(n, "clip")
end

local function confirm_clear_log(key, popup_id, with_reset)
  local n = #State.clip_log
  local msg = "Clear the " .. clip_count_str(n) .. " in the Recent Clips log"
    .. (with_reset and " and reset the hold readouts?" or "?")
    .. "\n\nThe log is not saved anywhere, so this cannot be undone."
  draw_confirm_modal(key, popup_id, msg, "Clear Log", function()
    clear_clip_log()
    if with_reset then reset_holds() end
    set_status("Cleared " .. clip_count_str(n) .. (with_reset and "; holds reset" or ""))
  end)
end

local function any_popup_open()
  return reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
end

--- HC6: forward Space chords to the user's Main-section binding while this window is focused.
local function forward_space()
  if any_popup_open() or reaper.ImGui_IsAnyItemActive(ctx) then return end
  if not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then return end
  for mod, cmd in pairs(space_cmds) do
    if reaper.ImGui_Shortcut(ctx, mod | reaper.ImGui_Key_Space()) then
      reaper.Main_OnCommand(cmd, 0)
    end
  end
end

--- HC5: Esc for the current window, after its modals. Returns true when the window should close.
local function esc_closes(allowed)
  return allowed and not any_popup_open() and not reaper.ImGui_IsAnyItemActive(ctx)
    and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape())
end

-------------------------------------------------------------------------------
-- 9. METERING ENGINE
-------------------------------------------------------------------------------
local function update_meters(track, now, dt, is_playing, is_warming_up)
  local smooth = 1.0 - (1.0 - math.min(0.99, State.damping * 0.5)) ^ (dt / SMOOTH_REF_DT)   -- DV1
  if track then
    local peak_l_amp = reaper.Track_GetPeakInfo(track, 0) or 0.0
    local peak_r_amp = reaper.Track_GetPeakInfo(track, 1) or 0.0
    local cur_peak_l, cur_peak_r = AmpToDb(peak_l_amp), AmpToDb(peak_r_amp)

    -- ST4: 1024/1025 report loudness only when the track's meter shows loudness (or on the master).
    -- Otherwise the column is an estimate: peak - 3 dB (exact for a sine), labelled "RMS est."
    local loud_l = reaper.Track_GetPeakInfo(track, 1024) or 0.0
    local loud_r = reaper.Track_GetPeakInfo(track, 1025) or 0.0
    if loud_l > 0 or loud_r > 0 then State.loudness_seen = true end
    local cur_rms_l, cur_rms_r
    if State.loudness_seen then
      cur_rms_l, cur_rms_r = AmpToDb(loud_l), AmpToDb(loud_r)
    else
      cur_rms_l, cur_rms_r = AmpToDb(peak_l_amp * 0.7071), AmpToDb(peak_r_amp * 0.7071)
    end

    local max_incoming_peak = math.max(cur_peak_l, cur_peak_r)
    local max_incoming_rms = math.max(cur_rms_l, cur_rms_r)

    -- Waking up from digital silence: snap the smoothed level to the input instead of ramping from -150 dB
    if State.rms_smooth_l < -100.0 then State.rms_smooth_l = cur_rms_l end
    if State.rms_smooth_r < -100.0 then State.rms_smooth_r = cur_rms_r end

    -- Clip logging
    if is_playing and max_incoming_peak >= 0.0 and not is_warming_up then
      local play_pos = reaper.GetPlayPosition()
      if (play_pos - State.last_clip_time) > 0.5 then
        table.insert(State.clip_log, 1, { time = play_pos, val = max_incoming_peak })
        if #State.clip_log > 10 then table.remove(State.clip_log) end
        State.last_clip_time = play_pos
      end
    end

    if max_incoming_peak > -140 and max_incoming_rms > -140 then
      if max_incoming_peak > State.num_peak_max then State.num_peak_max = max_incoming_peak end
      if max_incoming_rms > State.num_rms_max then State.num_rms_max = max_incoming_rms end
      if not is_warming_up then
        table.insert(State.audio_history, {
          time = now, peak = max_incoming_peak, rms = math.max(State.rms_smooth_l, State.rms_smooth_r),
        })
      end
    end

    State.peak_max_l = State.peak_max_l - (State.falloff_db_sec * dt)
    if cur_peak_l > State.peak_max_l then State.peak_max_l = cur_peak_l end
    State.peak_max_r = State.peak_max_r - (State.falloff_db_sec * dt)
    if cur_peak_r > State.peak_max_r then State.peak_max_r = cur_peak_r end

    State.rms_smooth_l = State.rms_smooth_l + (cur_rms_l - State.rms_smooth_l) * smooth
    State.rms_smooth_r = State.rms_smooth_r + (cur_rms_r - State.rms_smooth_r) * smooth

    local target_slow, target_fast = 0.0, 0.0
    if max_incoming_rms > -70.0 then target_slow = State.rms_smooth_r - State.rms_smooth_l end
    if max_incoming_peak > -70.0 then target_fast = cur_peak_r - cur_peak_l end
    State.balance_val = State.balance_val
      + (target_slow - State.balance_val) * (1.0 - math.exp(-dt / State.balance_window_sec))
    State.balance_val_fast = State.balance_val_fast
      + (target_fast - State.balance_val_fast) * (1.0 - math.exp(-dt / State.balance_window_sec_fast))
  else
    State.peak_max_l = State.peak_max_l - (State.falloff_db_sec * dt)
    State.peak_max_r = State.peak_max_r - (State.falloff_db_sec * dt)
    State.rms_smooth_l = State.rms_smooth_l + (-150.0 - State.rms_smooth_l) * smooth
    State.rms_smooth_r = State.rms_smooth_r + (-150.0 - State.rms_smooth_r) * smooth
    State.balance_val = State.balance_val * math.exp(-dt / State.balance_window_sec)
    State.balance_val_fast = State.balance_val_fast * math.exp(-dt / State.balance_window_sec_fast)
  end

  while #State.audio_history > 0 and (now - State.audio_history[1].time) > State.rolling_window_sec do
    table.remove(State.audio_history, 1)
  end
  State.roll_peak_max, State.roll_rms_max = -150, -150
  for i = 1, #State.audio_history do
    local entry = State.audio_history[i]
    if entry.peak > State.roll_peak_max then State.roll_peak_max = entry.peak end
    if entry.rms > State.roll_rms_max then State.roll_rms_max = entry.rms end
  end

  if is_playing then
    if State.roll_peak_max > State.disp_roll_peak then State.disp_roll_peak = State.roll_peak_max
    else
      State.disp_roll_peak = math.max(State.roll_peak_max, State.disp_roll_peak - State.falloff_db_sec * dt)
    end
    if State.roll_rms_max > State.disp_roll_rms then State.disp_roll_rms = State.roll_rms_max
    else
      State.disp_roll_rms = math.max(State.roll_rms_max, State.disp_roll_rms - State.falloff_db_sec * dt)
    end
  else
    State.disp_roll_peak = -150
    State.disp_roll_rms  = -150
  end
end

-------------------------------------------------------------------------------
-- 10. MAIN WINDOW
-------------------------------------------------------------------------------
local function toggle_lock(track)
  if not track then return end
  State.is_locked = not State.is_locked
  State.locked_track = State.is_locked and track or nil
end

local function handle_keys(selected_track)
  -- EP6: no modifiers, no repeat, focused window only, nothing active, no popup open
  if any_popup_open() or reaper.ImGui_IsAnyItemActive(ctx) then return end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_R()) then
    reset_holds()
    set_status("Hold readouts reset")
  end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_C()) then
    if #State.clip_log > 0 then
      pending_confirm.clear_log_main = true
    else
      reset_holds()
      set_status("Hold readouts reset (no clips logged)")
    end
  end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_B()) then
    State.show_balance_meter = not State.show_balance_meter
    mark_dirty()
  end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_M()) then
    State.meter_scale_mode = State.meter_scale_mode == 1 and 2 or 1
    mark_dirty()
  end
  if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_L()) then
    if State.is_locked then toggle_lock(State.locked_track)
    elseif selected_track then toggle_lock(selected_track)
    else set_status("Select a track to lock the meter to it") end
  end
end

--- Header band: track pill (name + lock), clip pill, Settings button, close button.
--- Returns false when the close button was clicked.
local function draw_header(draw_list, track, track_name, band_col, wx, wy, ww, header_h, docked)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, wx, wy, wx + ww, wy + header_h, band_col)
  local ink = ink_on(band_col)
  local btn = L.xxl
  local btn_y = wy + (header_h - btn) / 2
  local keep_open = true

  -- Close (ST5: closing stops metering)
  local close_x = wx + ww - btn - L.sm
  reaper.ImGui_SetCursorScreenPos(ctx, close_x, btn_y)
  if Theme.icon_btn(ctx, "close_meter", Theme.icons.close, { preset = L.icon_target, color = ink }) then
    keep_open = false
  end
  tip(docked and "Close the meter. Metering stops until you run the action again."
    or "Close the meter (Esc). Metering stops until you run the action again.")

  -- Settings (hamburger)
  local set_x = close_x - btn - L.xs
  reaper.ImGui_SetCursorScreenPos(ctx, set_x, btn_y)
  if reaper.ImGui_InvisibleButton(ctx, "settings_btn", btn, btn) then State.show_settings = not State.show_settings end
  local hovered = hover_hand()
  if hovered or State.show_settings then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, set_x, btn_y, set_x + btn, btn_y + btn,
      Theme.with_alpha(ink, hovered and 0.22 or 0.12), L.rounding)
  end
  local hw, hh = L.xl, L.lg
  local gx, gy = set_x + (btn - hw) / 2, btn_y + (btn - hh) / 2
  for i = 0, 2 do
    reaper.ImGui_DrawList_AddLine(draw_list, gx, gy + i * hh / 2, gx + hw, gy + i * hh / 2, ink, 2.0)
  end
  tip(State.show_settings and "Close Settings" or "Open Settings")

  local right_edge = set_x

  -- Clip pill
  if #State.clip_log > 0 then
    local log_txt = clip_count_str(#State.clip_log):upper()
    local tw, th = text_size(fonts.default_bold, FS.small, log_txt)
    local pill_h = L.xl + L.sm
    local log_w = tw + L.lg * 2
    local log_x = right_edge - log_w - L.md
    local log_y = wy + (header_h - pill_h) / 2
    reaper.ImGui_SetCursorScreenPos(ctx, log_x, log_y)
    if reaper.ImGui_InvisibleButton(ctx, "clip_log_btn", log_w, pill_h) then State.show_clip_log = not State.show_clip_log end
    local bg = col("Color_Clip")
    if hover_hand() then bg = Theme.lighten(bg, 0.15) end
    reaper.ImGui_DrawList_AddRectFilled(draw_list, log_x, log_y, log_x + log_w, log_y + pill_h, bg, pill_h / 2)
    reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.default_bold, FS.small, log_x + L.lg, log_y + (pill_h - th) / 2,
      ink_on(bg), log_txt)
    tip((State.show_clip_log and "Hide" or "Show") .. " Recent Clips (click a timestamp there to jump to it)")
    right_edge = log_x
  else
    State.show_clip_log = false
  end

  -- Track pill: name + lock (the lock stays visible; disabled with a reason when no track)
  local pill_x = wx + L.md
  local pill_w = (right_edge - L.md) - pill_x
  if pill_w > L.xxxl then
    local pill_h = header_h - L.md * 2
    local pill_y = wy + L.md
    reaper.ImGui_DrawList_AddRectFilled(draw_list, pill_x, pill_y, pill_x + pill_w, pill_y + pill_h, col("Color_MeterBG"), pill_h / 2)

    local lock = L.xxl
    local lock_x = pill_x + pill_w - lock - L.sm
    local lock_y = pill_y + (pill_h - lock) / 2
    reaper.ImGui_SetCursorScreenPos(ctx, lock_x, lock_y)
    reaper.ImGui_BeginDisabled(ctx, track == nil)
    if reaper.ImGui_InvisibleButton(ctx, "lock_btn", lock, lock) then toggle_lock(track) end
    reaper.ImGui_EndDisabled(ctx)
    local lock_hover = track ~= nil and hover_hand()
    local lock_bg = State.is_locked and P.yellow or P.card
    if lock_hover then lock_bg = Theme.lighten(lock_bg, 0.15) end
    local icon_col = State.is_locked and ink_on(lock_bg) or (track and P.text or P.text_dim)
    local cx, cy = lock_x + lock / 2, lock_y + lock / 2
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, lock / 2, lock_bg)
    local body_w, body_h, shackle_r = L.lg, L.md + L.xs, L.sm
    reaper.ImGui_DrawList_PathClear(draw_list)
    if State.is_locked then
      reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy - L.sm, shackle_r, math.pi * 2, 0, 10)
    else
      local rot = math.pi / 1.25
      reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy - L.sm, shackle_r, math.pi + rot, rot, 10)
    end
    reaper.ImGui_DrawList_PathStroke(draw_list, icon_col, 0, 2.0)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, cx - body_w / 2, cy - L.xs, cx + body_w / 2, cy + body_h - L.xs,
      icon_col, L.xs)
    if not track then
      tip("Select a track to lock the meter to it (L).", true)
    else
      tip(State.is_locked and "Locked to this track. Click or press L to follow the selected track again."
        or "Following the selected track. Click or press L to lock the meter to this track.")
    end

    -- Name (truncated by the pill; full name in a tooltip when cut)
    local name_x = pill_x + L.lg
    local name_max = lock_x - L.sm
    local nw, nh = text_size(fonts.medium, FS.medium, track_name)
    local name_col = track and P.text or P.text_dim
    reaper.ImGui_PushClipRect(ctx, pill_x, pill_y, name_max, pill_y + pill_h, true)
    reaper.ImGui_DrawList_AddTextEx(draw_list, fonts.medium, FS.medium, name_x, pill_y + (pill_h - nh) / 2, name_col, track_name)
    reaper.ImGui_PopClipRect(ctx)
    if name_max - name_x > 1 then
      reaper.ImGui_SetCursorScreenPos(ctx, name_x, pill_y)
      reaper.ImGui_InvisibleButton(ctx, "name_tt", name_max - name_x, pill_h)
      if nw > name_max - name_x then tip(track_name) end
    end
  end
  return keep_open
end

local function draw_status_line(x, y)
  local fresh = status_msg ~= "" and (reaper.time_precise() - status_time) < STATUS_SECS
  local text = fresh and status_msg or "Closing this window stops metering."
  local c = fresh and P.text or P.text_dim
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddTextEx(dl, fonts.small, FS.small, x, y, c, text)
end

--- Draws the main window body. Returns false when the meter should close.
local function draw_main_window(now, dt, is_playing, is_warming_up, docked)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local wx, wy = reaper.ImGui_GetCursorScreenPos(ctx)
  local ww = reaper.ImGui_GetWindowWidth(ctx)
  local wh = reaper.ImGui_GetWindowHeight(ctx)

  local selected = reaper.GetSelectedTrack(0, 0)
  handle_keys(selected)

  -- Track locking
  local track = selected
  if State.is_locked then
    if State.locked_track and reaper.ValidatePtr(State.locked_track, "MediaTrack*") then
      track = State.locked_track
    else
      State.is_locked = false
      State.locked_track = nil
    end
  end

  -- Reset when the metered track changes
  if track ~= State.last_active_track then
    reset_holds()
    State.balance_val, State.balance_val_fast = 0.0, 0.0
    State.loudness_seen = false
    clear_clip_log()
    State.last_active_track = track
  end

  local track_name = "No track selected — select a track"
  local band_col = P.card
  if track then
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name and name ~= "" then track_name = name
    else
      local tr_num = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
      if tr_num == -1 then track_name = "Master"
      elseif tr_num > 0 then track_name = "Track " .. math.floor(tr_num) end
    end
    local native = reaper.GetTrackColor(track) or 0
    if native ~= 0 then band_col = Theme.darken(Theme.bgr_to_rgba(native), 0.15) end
  end

  update_meters(track, now, dt, is_playing, is_warming_up)

  local header_h = L.xxxl + L.xl
  local keep_open = draw_header(draw_list, track, track_name, band_col, wx, wy, ww, header_h, docked)

  local pad = L.lg
  local content_y = wy + header_h + L.lg
  local v_meter_y = content_y
  local available_w = ww - pad * 2

  if State.show_balance_meter and available_w > 100 then
    DrawBalanceMeter(draw_list, available_w, wx + pad, content_y, State.balance_val, State.balance_val_fast,
      State.balance_meter_height)
    v_meter_y = content_y + State.balance_meter_height + L.md + L.lg
  end

  local _, _, shared_meter_y = pair_geometry(v_meter_y)
  local combo_h = reaper.ImGui_GetFrameHeight(ctx)
  local status_h = select(2, text_size(fonts.small, FS.small, "Ag"))
  local bottom_reserved = L.lg + combo_h + L.sm + status_h + L.md
  local dynamic_h = math.max(L.xxxl * 4, wh - (shared_meter_y - wy) - bottom_reserved)

  local spacing = L.xs
  local calc_meter_w = 10
  if available_w > 50 then
    calc_meter_w = math.floor((available_w - (2 * spacing) - State.column_gap) / 4)
  end
  State.meter_width = math.max(10, calc_meter_w)
  local pair_w = (State.meter_width * 2) + spacing
  local total_block_w = pair_w + State.column_gap + pair_w
  local start_x = wx + (ww / 2) - (total_block_w / 2)
  local rms_x = start_x + pair_w + State.column_gap

  -- Peak
  local p_inf, p_roll, p_act, p_db, p_rel = DrawStereoMeterPair(draw_list, start_x, v_meter_y,
    State.peak_max_l, State.peak_max_r,
    { text = "PEAK", color = P.text,
      tooltip = "Peak level: the highest sample level REAPER's track meter reports, with a falloff of "
        .. string.format("%.0f dB/s.", State.falloff_db_sec) },
    "PEAK", State.peak_db_min, State.peak_db_max, State.meter_width, dynamic_h,
    State.num_peak_max, State.disp_roll_peak, State.tgt_peak_active, State.tgt_peak_db, State.meter_scale_mode)
  if p_inf then State.num_peak_max = -150 end
  State.tgt_peak_active, State.tgt_peak_db = p_act, p_db
  if p_rel then mark_dirty() end

  -- RMS / loudness (ST4: say what is shown)
  local rms_head
  if State.loudness_seen then
    rms_head = { text = "LOUDNESS", color = P.text,
      tooltip = "Loudness as reported by REAPER's track meter (the track's VU meter is set to show loudness, "
        .. "or this is the master track), smoothed by the Smoothing setting." }
  else
    rms_head = { text = "RMS est.", color = P.text_dim,
      tooltip = "Estimated RMS: the peak level minus 3 dB (exact only for a sine wave), smoothed by the "
        .. "Smoothing setting.\n\nREAPER reports a measured value only when the track's VU meter is set to "
        .. "show loudness (right-click the track meter), or on the master track; this column then shows LOUDNESS." }
  end
  local r_inf, r_roll, r_act, r_db, r_rel = DrawStereoMeterPair(draw_list, rms_x, v_meter_y,
    State.rms_smooth_l, State.rms_smooth_r, rms_head, "RMS",
    State.rms_db_min, State.rms_db_max, State.meter_width, dynamic_h,
    State.num_rms_max, State.disp_roll_rms, State.tgt_rms_active, State.tgt_rms_db, State.meter_scale_mode)
  if r_inf then State.num_rms_max = -150 end
  State.tgt_rms_active, State.tgt_rms_db = r_act, r_db or DEFAULTS.tgt_rms_db
  if r_rel then mark_dirty() end

  if p_roll or r_roll then
    State.audio_history = {}
    State.roll_peak_max, State.roll_rms_max = -150, -150
    State.disp_roll_peak, State.disp_roll_rms = -150, -150
  end

  -- Scale mode
  local combo_y = shared_meter_y + dynamic_h + L.lg
  reaper.ImGui_SetCursorScreenPos(ctx, start_x, combo_y)
  local new_idx, changed = Theme.combo(ctx, "##ScaleMode", { "Linear", "Mixer's Curve" }, State.meter_scale_mode,
    { w = total_block_w })
  if changed then
    State.meter_scale_mode = new_idx
    mark_dirty()
  end
  tip("Meter scale\n\nLinear: evenly spaced dB.\nMixer's Curve: expands the top 24 dB for detail near 0 dB.\n\nShortcut: M")

  draw_status_line(start_x, combo_y + combo_h + L.sm)

  -- Dim overlay when no track
  if not track then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, wx, wy + header_h, wx + ww, wy + wh,
      Theme.with_alpha(P.bg, Vis.Dim_Opacity_Pct))
  end

  -- Modals owned by this window
  confirm_clear_log("clear_log_main", "Clear clip log?##meter_clear_main", true)

  -- HC5 / HC6
  if esc_closes(not docked) then keep_open = false end
  forward_space()
  return keep_open
end

-------------------------------------------------------------------------------
-- 11. RECENT CLIPS WINDOW
-------------------------------------------------------------------------------
local function draw_clip_log_window()
  if not State.show_clip_log then return end
  Theme.center_next_window(ctx, nil, nil, reaper.ImGui_Cond_FirstUseEver())
  local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoNavInputs()
  local visible, open = reaper.ImGui_Begin(ctx, 'Recent Clips', true, flags)
  if visible then
    -- The window shows only while the log has entries (the header pill opens it)
    reaper.ImGui_Text(ctx, "Click a timestamp to move the edit cursor there:")
    reaper.ImGui_Separator(ctx)
    for i, clip in ipairs(State.clip_log) do
      local time_str = reaper.format_timestr_pos(clip.time, "", -1)
      local val_str = string.format("%+.1f dB", clip.val)
      if reaper.ImGui_Button(ctx, time_str .. "  |  " .. val_str .. "###clip_" .. i, -1, 0) then
        reaper.SetEditCurPos(clip.time, true, false)
      end
    end
    reaper.ImGui_Dummy(ctx, 0, L.md)
    push_danger()
    if reaper.ImGui_Button(ctx, "Clear Log###clear_log", -1, 0) then pending_confirm.clear_log_clips = true end
    pop_danger()
    confirm_clear_log("clear_log_clips", "Clear clip log?##meter_clear_clips", false)

    if esc_closes(true) then open = false end
    forward_space()
    reaper.ImGui_End(ctx)
  end
  if not open then State.show_clip_log = false end
end

-------------------------------------------------------------------------------
-- 12. SETTINGS WINDOW
-------------------------------------------------------------------------------
local COLOR_UI = {
  { "Color_Safe",       "Safe Zone",         "Meter colour below the warning level." },
  { "Color_Warn",       "Warning Zone",      "Meter colour above the warning level (-6 dB, or 1 dB above the target)." },
  { "Color_Clip",       "Clip Zone",         "Meter colour at 0 dBFS (or 3 dB above the target), and the clip readouts." },
  { "Color_TargetLine", "Target Marker",     "Colour of the target line and its value box." },
  { "Color_MeterBG",    "Meter Background",  "Background of the meter bars, readouts and track name." },
  { "Color_Background", "Window Background", "Background of the meter window." },
}
local TAB_COLOR_UI = {
  { "Tab_Active",   "Active Tab",   "Settings tab that is open." },
  { "Tab_Inactive", "Inactive Tab", "Settings tabs that are not open." },
  { "Tab_Hovered",  "Hovered Tab",  "Settings tab under the mouse." },
}

local function section(label)
  Theme.section_divider(ctx, label)
end

local function color_rows(list)
  for _, row in ipairs(list) do
    local key, label, desc = row[1], row[2], row[3]
    local changed, v = reaper.ImGui_ColorEdit4(ctx, label .. "###col_" .. key, col(key),
      reaper.ImGui_ColorEditFlags_NoInputs())
    if changed then
      user_color[key] = v
      mark_dirty()
    end
    tip(desc .. (user_color[key] and "\n\nCustom colour." or "\n\nFollows the theme (default)."))
  end
end

local function count_custom_colors()
  local n = 0
  for _, k in ipairs(COLOR_KEYS) do if user_color[k] then n = n + 1 end end
  return n
end

local function draw_settings_tabs()
  if not reaper.ImGui_BeginTabBar(ctx, "SettingsTabs") then return end

  if reaper.ImGui_BeginTabItem(ctx, "Appearance") then
    section("Theme")
    Theme.settings_widget(ctx, { label = "Theme Mode" })
    tip("Fancy Dark or Match Theme (colours from your REAPER theme). Applies to every Fancy Script.")
    Theme.tooltip_setting_widget(ctx, { tooltip = "Show or hide hover tooltips in every Fancy Script." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Meter Colors")
    color_rows(COLOR_UI)

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Tab Colors")
    color_rows(TAB_COLOR_UI)

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    local n_custom = count_custom_colors()
    reaper.ImGui_BeginDisabled(ctx, n_custom == 0)
    if reaper.ImGui_Button(ctx, "Reset All Colors to Default###reset_colors") then pending_confirm.reset_colors = true end
    reaper.ImGui_EndDisabled(ctx)
    if n_custom == 0 then
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.text_dim, "All colors follow the theme")
    end

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Display")
    drag_setting(Vis, "Dim_Opacity_Pct", "No-Track Dim", { speed = 0.5, lo = 0, hi = 100, fmt = "%.0f%%",
      type_fmt = "%.0f", scale = 100, tooltip = "How much the meter is darkened while no track is selected." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Typography")
    drag_setting(Vis, "Tooltip_Font_Size", "Tooltip Text Size", { speed = 0.1, lo = 10, hi = 36, fmt = "%d pt",
      is_int = true, tooltip = "Text size of the hover tooltips." })
    drag_setting(Vis, "Settings_Font_Size", "Settings Text Size", { speed = 0.1, lo = 10, hi = 36, fmt = "%d pt",
      is_int = true, tooltip = "Text size in this window and Recent Clips." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Layout")
    drag_setting(State, "column_gap", "Meter Pair Gap", { speed = 0.2, lo = 0, hi = 100, fmt = "%d",
      is_int = true, tooltip = "Space between the PEAK and RMS meter pairs." })
    reaper.ImGui_EndTabItem(ctx)
  end

  if reaper.ImGui_BeginTabItem(ctx, "Stereo Balance") then
    section("Visibility")
    local changed, v = reaper.ImGui_Checkbox(ctx, "Show Stereo Balance Drift", State.show_balance_meter)
    if changed then State.show_balance_meter = v; mark_dirty() end
    tip("Show or hide the balance meter above the level meters.\n\nShortcut: B")

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Range")
    drag_setting(State, "balance_db_scale", "Max Range (+/- dB)", { speed = 0.05, lo = 1.0, hi = 24.0,
      fmt = "%.1f dB", type_fmt = "%.1f", tooltip = "Level difference shown at the left and right edges." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Drift Speeds")
    drag_setting(State, "balance_window_sec", "Slow Drift Speed", { speed = 0.02, lo = 0.1, hi = 10.0,
      fmt = "%.1f s", type_fmt = "%.1f", tooltip = "Time constant of the dot (smoothed RMS balance)." })
    drag_setting(State, "balance_window_sec_fast", "Fast Drift Speed", { speed = 0.005, lo = 0.033, hi = 2.0,
      fmt = "%.3f s", type_fmt = "%.3f", tooltip = "Time constant of the ring (peak balance)." })
    reaper.ImGui_EndTabItem(ctx)
  end

  if reaper.ImGui_BeginTabItem(ctx, "Level Meters") then
    section("Peak Meter")
    drag_setting(State, "peak_db_min", "Min dB###peak_min", { speed = 0.2, lo = -100.0, hi = 0.0, fmt = "%.1f dB",
      type_fmt = "%.1f", tooltip = "Lowest level shown on the PEAK meters." })
    drag_setting(State, "peak_db_max", "Max dB###peak_max", { speed = 0.2, lo = -100.0, hi = 0.0, fmt = "%.1f dB",
      type_fmt = "%.1f", tooltip = "Highest level shown on the PEAK meters." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("RMS / Loudness Meter")
    drag_setting(State, "rms_db_min", "Min dB###rms_min", { speed = 0.2, lo = -100.0, hi = 0.0, fmt = "%.1f dB",
      type_fmt = "%.1f", tooltip = "Lowest level shown on the RMS / LOUDNESS meters." })
    drag_setting(State, "rms_db_max", "Max dB###rms_max", { speed = 0.2, lo = -100.0, hi = 0.0, fmt = "%.1f dB",
      type_fmt = "%.1f", tooltip = "Highest level shown on the RMS / LOUDNESS meters." })
    drag_setting(State, "damping", "Smoothing", { speed = 0.002, lo = 0.01, hi = 1.0, fmt = "%.2f",
      tooltip = "How fast the RMS / LOUDNESS bars follow the signal. Lower is slower and smoother." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Holds")
    drag_setting(State, "falloff_db_sec", "Meter Falloff", { speed = 0.2, lo = 5.0, hi = 100.0, fmt = "%.1f dB/s",
      type_fmt = "%.1f", tooltip = "How fast the bars and the rolling hold drop." })
    drag_setting(State, "rolling_window_sec", "Rolling Window", { speed = 0.02, lo = 1.0, hi = 10.0, fmt = "%.1f s",
      type_fmt = "%.1f", tooltip = "How far back the rolling hold (↻) looks." })

    if State.peak_db_min >= State.peak_db_max then State.peak_db_min = State.peak_db_max - 1 end
    if State.rms_db_min >= State.rms_db_max then State.rms_db_min = State.rms_db_max - 1 end
    reaper.ImGui_EndTabItem(ctx)
  end

  if reaper.ImGui_BeginTabItem(ctx, "Target Markers") then
    section("Peak")
    local changed, v = reaper.ImGui_Checkbox(ctx, "Show Peak Target###tgt_peak_on", State.tgt_peak_active)
    if changed then State.tgt_peak_active = v; mark_dirty() end
    tip("Show the target line on the PEAK meters (same as the target icon next to PEAK).")
    drag_setting(State, "tgt_peak_db", "Peak Target###tgt_peak_db", { speed = 0.1, lo = -60.0, hi = 0.0,
      fmt = "%.1f dB", type_fmt = "%.1f", tooltip = "Level of the PEAK target (click the meter to set it there)." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("RMS / Loudness")
    changed, v = reaper.ImGui_Checkbox(ctx, "Show RMS Target###tgt_rms_on", State.tgt_rms_active)
    if changed then State.tgt_rms_active = v; mark_dirty() end
    tip("Show the target line on the RMS / LOUDNESS meters (same as the target icon above them).")
    drag_setting(State, "tgt_rms_db", "RMS Target###tgt_rms_db", { speed = 0.1, lo = -60.0, hi = 0.0,
      fmt = "%.1f dB", type_fmt = "%.1f", tooltip = "Level of the RMS / LOUDNESS target (click the meter to set it there)." })

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Appearance")
    reaper.ImGui_SetNextItemWidth(ctx, WIN.settings_item_w)
    local idx, size_changed = Theme.combo(ctx, "Marker Size###tgt_size", { "Small (Inline)", "Large (Stacked)" },
      State.tgt_marker_size + 1)
    if size_changed then State.tgt_marker_size = idx - 1; mark_dirty() end
    tip("Size and layout of the target value box.")
    drag_setting(State, "tgt_marker_indent", "Box Inset", { speed = 0.1, lo = 0.0, hi = 50.0, fmt = "%.0f",
      type_fmt = "%.0f", tooltip = "Narrows the target value box so more of the target line shows at its sides." })
    drag_setting(State, "tgt_marker_bg_alpha", "Box Opacity", { speed = 0.5, lo = 0, hi = 100, fmt = "%.0f%%",
      type_fmt = "%.0f", scale = 100, tooltip = "Opacity of the target value box background." })
    reaper.ImGui_EndTabItem(ctx)
  end

  if reaper.ImGui_BeginTabItem(ctx, "Shortcuts") then
    section("Keys (meter window focused)")
    reaper.ImGui_Text(ctx, "R : Reset the hold readouts (∞ and ↻).")
    reaper.ImGui_Text(ctx, "C : Clear the clip log and reset the holds (asks first when clips are logged).")
    reaper.ImGui_Text(ctx, "B : Show or hide Stereo Balance Drift.")
    reaper.ImGui_Text(ctx, "M : Switch the meter scale (Linear / Mixer's Curve).")
    reaper.ImGui_Text(ctx, "L : Lock the meter to the current track, or follow the selection again.")
    reaper.ImGui_Text(ctx, "Space : Runs your REAPER Space binding (Play/Stop by default).")
    reaper.ImGui_Text(ctx, "Esc : Closes a dialog, then Settings or Recent Clips, then a floating meter.")

    reaper.ImGui_Dummy(ctx, 0, L.md)
    section("Mouse")
    reaper.ImGui_Text(ctx, "Click or drag on a meter : Set the target level there (turns the target on).")
    reaper.ImGui_Text(ctx, "Target icon (next to PEAK / RMS) : Show or hide the target line.")
    reaper.ImGui_Text(ctx, "     Ring with a dot = target on; ring only = off.")
    reaper.ImGui_Text(ctx, "∞ box : Reset the infinite hold.   ↻ box : Reset the rolling hold.")
    reaper.ImGui_Text(ctx, "Lock button : Lock to the track, or follow the selection.")
    reaper.ImGui_Text(ctx, "Red clips pill : Open Recent Clips; click a timestamp to jump there.")
    reaper.ImGui_Text(ctx, "Settings drags : " .. MOD_LABEL .. "-drag fine adjust, double-click reset, "
      .. MOD_LABEL .. "-click type a value.")
    reaper.ImGui_EndTabItem(ctx)
  end

  reaper.ImGui_EndTabBar(ctx)
end

local function draw_settings_window()
  if not State.show_settings then return end
  Theme.center_next_window(ctx, nil, nil, reaper.ImGui_Cond_FirstUseEver())
  local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoCollapse()
              | reaper.ImGui_WindowFlags_NoNavInputs()
  local visible, open = reaper.ImGui_Begin(ctx, 'Meter Settings', true, flags)
  if visible then
    -- RB3/RB4: 0.10 tab colour names, no integer fallbacks
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(), col("Tab_Inactive"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(), col("Tab_Hovered"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabSelected(), col("Tab_Active"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabDimmed(), col("Tab_Inactive"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabDimmedSelected(), col("Tab_Active"))
    draw_settings_tabs()
    reaper.ImGui_PopStyleColor(ctx, 5)

    draw_confirm_modal("reset_colors", "Reset colors?##meter_reset_colors",
      "Reset " .. (count_custom_colors() == 1 and "the custom color" or ("the " .. plural(count_custom_colors(), "custom color")))
        .. " to the theme default?\n\nColors are saved in REAPER's settings, so this cannot be undone with "
        .. MOD_LABEL .. "+Z.",
      "Reset Colors", function()
        local n = count_custom_colors()
        user_color = {}
        mark_dirty()
        set_status("Reset " .. plural(n, "color") .. " to the theme default")
      end)

    if esc_closes(true) then open = false end
    forward_space()
    reaper.ImGui_End(ctx)
  end
  if not open then State.show_settings = false end
end

-------------------------------------------------------------------------------
-- 13. MAIN LOOP
-------------------------------------------------------------------------------
local function loop()
  P = Theme.get_palette()
  local now = reaper.time_precise()
  local dt = math.min(now - State.last_time, 0.1)
  State.last_time = now

  local play_state = reaper.GetPlayState()
  local is_playing = (play_state & 1) == 1 and (play_state & 2) == 0
  local was_playing = (State.play_state & 1) == 1 and (State.play_state & 2) == 0
  if is_playing and not was_playing then
    State.num_peak_max, State.num_rms_max = -150, -150
    State.balance_val, State.balance_val_fast = 0.0, 0.0
    State.audio_history = {}
    State.disp_roll_peak, State.disp_roll_rms = -150, -150
    State.play_start_time = now
    State.last_clip_time = -100
  end
  State.play_state = play_state
  local is_warming_up = is_playing and (now - State.play_start_time < 0.5)

  local nc, nv = Theme.push(ctx, P)
  local pushed_default = Theme.push_font(ctx, fonts.default)

  local _, flt_max = reaper.ImGui_NumericLimits_Float()
  reaper.ImGui_SetNextWindowSize(ctx, WIN.first_w, WIN.first_h, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, WIN.min_w, WIN.min_h, flt_max, flt_max)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), col("Color_Background"))
  -- NoNavInputs: Space goes to REAPER (HC6) instead of activating a nav-focused widget
  local main_flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNavInputs()
                   | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  local visible, open = reaper.ImGui_Begin(ctx, 'Track Meters', true, main_flags)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if visible then
    local docked = reaper.ImGui_IsWindowDocked(ctx)
    if not draw_main_window(now, dt, is_playing, is_warming_up, docked) then open = false end
    reaper.ImGui_End(ctx)
  end

  local pushed_settings = Theme.push_font(ctx, fonts.default, font_size("Settings_Font_Size"))
  draw_clip_log_window()
  draw_settings_window()
  Theme.pop_font(ctx, pushed_settings)

  Theme.pop_font(ctx, pushed_default)
  Theme.pop(ctx, nc, nv)

  flush_settings()

  if open then
    reaper.defer(loop)
  end
end

local function main()
  LoadSettings()
  load_space_bindings()
  Utils.init_toolbar_toggle()   -- HI3: toolbar button shows the meter is running
  reaper.atexit(SaveSettings)
  reaper.defer(loop)
end

main()
