-- @description Fancy Mapper Settings
-- @author Fancy Scripts
-- @version 5.2.0
-- @changelog
--   + v5.2: Mode panel: pick a mode to see only its settings and button actions
--   + v5.2: Guided calibration dialog (counts ticks without rebinding the dial)
--   + v5.2: Action Ring mode chips, per-mode smoothing toggles, HUD & toast settings in General
--   + v5.2: Smooth CC recording (60 Hz real-time slew streamer)
--   + v5.2: CC lane linearization (vector ramps instead of staircase)
--   + v5.2: Auto-linearize take on record stop & 1-click smooth take button
--   + v5.1: Added Width, Multi-CC, Velocity, Track Nav, Marker, Transient, Item Slip
--   + v5.1: Configurable Multi-CC targets and presets (e.g. 1, 11)
--   + v5.1: Multi-mode button action mapping
--   + v5.1: Cut Send mode
-- @about
--   Central settings hub for all Fancy Mapper scripts.
--   Configure calibration, modes, scrub behavior, sensitivity,
--   button actions, toast appearance, and more.
--   No need to edit script files — everything is here.
--   Requirements: REAPER 7.0+, ReaImGui, SWS Extension
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
    .. "To install:\n"
    .. "  1.  Extensions  ->  ReaPack  ->  Browse Packages\n"
    .. "  2.  Search for 'ReaImGui'\n"
    .. "  3.  Install and restart REAPER, then run this script again.",
    "Fancy Mapper Settings -- Missing ReaImGui", 0)
  return
end

-------------------------------------------------------------------------------
-- 2. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")
local MapperEngine = require("mapper_engine")

local L = Theme.layout

-------------------------------------------------------------------------------
-- 3. CONSTANTS & DEFAULTS
-------------------------------------------------------------------------------
local EXTSTATE_SECTION = "FancyMapper"
local RELOAD_INTERVAL_S = 0.5  -- re-read settings changed by other scripts
local RING_MIN_MODES = 3       -- Cycle Mode falls back to the curated ring below this
local POPUP_CALIBRATE = "Calibrate Dial##fm_calibrate"
local POPUP_RESET = "Reset Confirmation##fm_reset"
local SENS_NOTE = "\n\nSensitivity Up/Down adjusts this value."

-- Canonical mode order (also the Action Ring's clockwise order).
-- `smooth` names the per-mode Smooth Dial key for modes the slew engine interpolates.
local MODE_ITEMS = {
  { id = "scrub",     label = "Scrub",        smooth = "smooth_scrub" },
  { id = "fx",        label = "FX Parameter", smooth = "smooth_fx" },
  { id = "pan",       label = "Pan",          smooth = "smooth_pan" },
  { id = "volume",    label = "Volume",       smooth = "smooth_vol" },
  { id = "width",     label = "Width",        smooth = "smooth_width" },
  { id = "track_nav", label = "Track Nav" },
  { id = "midi_cc",   label = "MIDI CC",      smooth = "smooth_midi_cc" },
  { id = "midi_vel",  label = "Velocity" },
  { id = "marker",    label = "Marker" },
  { id = "transient", label = "Transient" },
  { id = "item_slip", label = "Item Slip",    smooth = "smooth_slip" },
}

local CURATED_RING = "scrub,fx,pan,volume,width,track_nav,midi_cc,midi_vel"
local ALL_RING_IDS = {}
for _, m in ipairs(MODE_ITEMS) do ALL_RING_IDS[#ALL_RING_IDS + 1] = m.id end
local ALL_RING = table.concat(ALL_RING_IDS, ",")

local SCRUB_UNIT_ITEMS = {
  { id = "free",    label = "Free" },
  { id = "grid",    label = "Grid" },
  { id = "beat",    label = "Beat" },
  { id = "measure", label = "Measure" },
}

local SCRUB_JUMP_HINTS = {
  grid    = "Jumps one grid division per tick.",
  beat    = "Jumps one beat per tick.",
  measure = "Jumps one measure per tick.",
}

local TOAST_POS_ITEMS = {
  { id = "center",       label = "Center" },
  { id = "top-right",    label = "Top-Right" },
  { id = "bottom-right", label = "Bottom-Right" },
  { id = "bottom-left",  label = "Bottom-Left" },
}

local SPEED_PRESETS = {
  { label = "Tape (12)",     value = 12.0 },
  { label = "Balanced (25)", value = 25.0 },
  { label = "Snappy (45)",   value = 45.0 },
}

local CC_PRESETS = {
  { label = "Mod (1)",            value = "1" },
  { label = "Expr (11)",          value = "11" },
  { label = "Mod + Expr (1, 11)", value = "1, 11" },
  { label = "Volume (7)",         value = "7" },
}

-- Single source of truth for every persisted setting (used by load and reset)
local DEFAULTS = {
  -- General
  ticks_per_rotation    = 26,
  throttle_ms           = 60,
  default_mode          = "scrub",
  midi_show_tooltip     = true,  -- global value HUD (key name predates the move to General)
  sensitivity_step      = 1.0,
  toast_enabled         = true,  -- Sensitivity Up/Down toast
  toast_position        = "center",
  toast_duration        = 1.5,
  -- Smooth Dial
  smooth_dial_enabled   = true,
  smooth_dial_speed     = 25.0,
  smooth_scrub          = true,
  smooth_fx             = true,
  smooth_pan            = true,
  smooth_vol            = true,
  smooth_width          = true,
  smooth_midi_cc        = true,
  smooth_slip           = true,
  -- Modes
  scrub_unit            = "free",
  scrub_seconds         = 2.0,
  scrub_move_view       = true,
  fx_sensitivity        = 1.0,
  fx_pan_fallback       = true,
  pan_sensitivity       = 1.0,
  vol_step_db           = 1.0,
  width_sensitivity     = 1.0,
  width_auto_stereo_pan = true,
  track_nav_scroll      = true,
  midi_cc_targets       = "1",
  midi_cc_sensitivity   = 1.0,
  midi_cc_linear        = true,
  midi_channel          = 1,
  midi_auto_arm         = true,
  midi_vel_sensitivity  = 1.0,
  midi_vel_audition     = false,
  slip_step_ms          = 10,
  -- Action Ring
  ring_modes            = CURATED_RING,
  ring_flick_enabled    = false,
  ring_flick_distance   = 74,
  ring_dwell_enabled    = false,
  ring_dwell_ms         = 350,
  ring_timeout_enabled  = false,
  ring_timeout_s        = 3.0,
}

-- Button actions: btnN_enabled is shared by all modes; btnN_<mode> holds a command ID
for i = 1, 6 do
  DEFAULTS["btn" .. i .. "_enabled"] = false
  for _, m in ipairs(MODE_ITEMS) do
    DEFAULTS["btn" .. i .. "_" .. m.id] = ""
  end
end

-- Script-specific layout — uses Theme.layout values as building blocks
local UI = {
  win_w     = L.modal_md.w + L.xxl + L.xl,         -- 600
  win_h     = L.modal_xl.h + L.xxxl * 6 + L.md,    -- 800
  label_w   = L.xxxl * 5,                          -- 160: form label column
  field_w   = L.xxxl * 4,                          -- 128: numeric fields & combos
  text_w    = L.xxxl * 5,                          -- 160: CC target list
  icon_w    = L.icon_md.size + L.icon_md.pad * 2,  -- 20: icon button
  ring_cols = 4,                                   -- Action Ring chip grid columns
}

-------------------------------------------------------------------------------
-- 4. CONFIG I/O
-------------------------------------------------------------------------------
local config = {}
for k, v in pairs(DEFAULTS) do config[k] = v end

local function get_setting_str(key, default)
  local v = reaper.GetExtState(EXTSTATE_SECTION, key)
  if v == "" then return default end
  return v
end

--- Reads every setting from ExtState. Missing keys fall back to DEFAULTS so
--- resets made elsewhere show up too; integer settings stay integral because
--- DragInt/InputInt reject fractional values.
local function load_config()
  for k, def in pairs(DEFAULTS) do
    local ext = reaper.GetExtState(EXTSTATE_SECTION, k)
    if ext == "" then
      config[k] = def
    elseif type(def) == "boolean" then
      config[k] = (ext == "1" or ext == "true")
    elseif type(def) == "number" then
      local n = tonumber(ext)
      if n and math.type(def) == "integer" then n = math.floor(n + 0.5) end
      config[k] = n or def
    else
      config[k] = ext
    end
  end
end

local function save_setting(k)
  local v = config[k]
  if v == "" then
    reaper.DeleteExtState(EXTSTATE_SECTION, k, true)
    return
  end
  if type(v) == "boolean" then
    v = v and "1" or "0"
  else
    v = tostring(v)
  end
  reaper.SetExtState(EXTSTATE_SECTION, k, v, true)
end

--- Restores every setting (including button assignments) to its default.
--- Runtime state such as the live mode and calibration count is left alone.
local function reset_all_to_defaults()
  for k, v in pairs(DEFAULTS) do
    config[k] = v
    save_setting(k)
  end
end

local function find_idx(items, id)
  for i, it in ipairs(items) do if it.id == id then return i end end
  return 1
end

local function mode_label(id)
  for _, m in ipairs(MODE_ITEMS) do
    if m.id == id then return m.label end
  end
  return id
end

--- The dial's active mode (runtime state written by Cycle Mode).
local function get_live_mode()
  return get_setting_str("mode", config.default_mode)
end

--- Normalises a CC target list the way the engine parses it ("1, 11" == "11,1").
local function norm_cc(s)
  local list, seen = {}, {}
  for token in string.gmatch(s or "", "%d+") do
    local n = tonumber(token)
    if n <= 127 and not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  table.sort(list)
  return table.concat(list, ",")
end

--- Parses ring_modes into a set of known mode ids (Cycle Mode ignores unknown ids).
local function ring_set(csv)
  local found = {}
  for id in string.gmatch(csv or "", "[%w_]+") do found[id] = true end
  local set, count = {}, 0
  for _, m in ipairs(MODE_ITEMS) do
    if found[m.id] then
      set[m.id] = true
      count = count + 1
    end
  end
  return set, count
end

--- Serialises a mode set to ring_modes in canonical (clockwise) order.
local function ring_csv(set)
  local ids = {}
  for _, m in ipairs(MODE_ITEMS) do
    if set[m.id] then ids[#ids + 1] = m.id end
  end
  return table.concat(ids, ",")
end

load_config()

-------------------------------------------------------------------------------
-- 5. RUNTIME STATE
-------------------------------------------------------------------------------
local ctx
local fonts
local is_running = true

local view_mode_idx = 1       -- mode shown in the Mode section
local last_live_mode = nil    -- live mode seen last frame; the view follows it
local last_reload = 0
local pending_popup = nil     -- opened at window scope so popup IDs match
local calib_hb_set = false    -- calibration heartbeat currently written
local calib_drawn = false     -- calibrate dialog drawn this frame
local action_picker_target = nil
local show_gear_popover = false
local smooth_feedback_msg = nil
local smooth_feedback_time = 0

-------------------------------------------------------------------------------
-- 6. WIDGET HELPERS
-------------------------------------------------------------------------------
local function hover_tip(text)
  if text and reaper.ImGui_IsItemHovered(ctx) then Theme.tooltip(ctx, text) end
end

local function dim_text(text)
  local P = Theme.get_palette()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

--- Draws a form label and moves the cursor to the shared control column.
local function form_label(label)
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetCursorPosX(ctx, x0 + UI.label_w)
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function drag_double_row(label, key, speed, min, max, fmt, tip)
  form_label(label)
  reaper.ImGui_SetNextItemWidth(ctx, UI.field_w)
  local rv, v = reaper.ImGui_DragDouble(ctx, "##" .. key, config[key], speed, min, max, fmt)
  if rv then config[key] = clamp(v, min, max); save_setting(key) end
  hover_tip(tip)
end

local function drag_int_row(label, key, speed, min, max, fmt, tip)
  form_label(label)
  reaper.ImGui_SetNextItemWidth(ctx, UI.field_w)
  local rv, v = reaper.ImGui_DragInt(ctx, "##" .. key, config[key], speed, min, max, fmt)
  if rv then config[key] = clamp(v, min, max); save_setting(key) end
  hover_tip(tip)
end

local function checkbox_row(label, key, tip)
  local rv, v = reaper.ImGui_Checkbox(ctx, label .. "##" .. key, config[key])
  if rv then config[key] = v; save_setting(key) end
  hover_tip(tip)
end

local function combo_row(label, key, items, tip)
  form_label(label)
  local new_idx, changed = Theme.combo(ctx, "##" .. key, items, find_idx(items, config[key]),
    { w = UI.field_w, tooltip = tip })
  if changed then config[key] = items[new_idx].id; save_setting(key) end
end

--- Small toggle chip on a default-height row; lit when `active`.
local function chip(id, label, active, tip)
  Theme.align(ctx, nil, L.btn_sm.h)
  return Theme.toggle_button(ctx, id, label, active, { preset = L.btn_sm, fonts = fonts, tooltip = tip })
end

-------------------------------------------------------------------------------
-- 7. BUTTON ACTIONS
-------------------------------------------------------------------------------
local function poll_action_picker()
  if not action_picker_target then return end
  local res = reaper.PromptForAction(0, 0, 0)
  if res > 0 then
    -- ReverseNamedCommandLookup returns nil for built-in actions
    local named = reaper.ReverseNamedCommandLookup(res)
    local cmd_str = named and ("_" .. named) or tostring(res)
    config[action_picker_target] = cmd_str
    save_setting(action_picker_target)
    reaper.PromptForAction(-1, 0, 0)  -- close session
    action_picker_target = nil
  elseif res < 0 then
    reaper.PromptForAction(-1, 0, 0)  -- close session
    action_picker_target = nil
  end
end

local function get_action_name(cmd_str)
  if not cmd_str or cmd_str == "" then return "(none)" end
  -- Resolve to numeric command ID: try direct number first, then named lookup
  local cmd_id = tonumber(cmd_str)
  if not cmd_id then
    cmd_id = reaper.NamedCommandLookup(cmd_str)
  end
  if cmd_id and cmd_id > 0 then
    if reaper.CF_GetCommandText then
      local name = reaper.CF_GetCommandText(0, cmd_id)
      if name and name ~= "" then return name end
    end
  end
  return cmd_str
end

--- Action name as a clickable cell: click to pick; long names clip at the column edge.
local function draw_action_cell(key, dim)
  local P = Theme.get_palette()
  local assigned = config[key] ~= ""
  local name = get_action_name(config[key])
  local col = assigned and P.text or P.text_dim
  if dim then col = Theme.with_alpha(col, 0.5) end
  if Theme.selectable(ctx, name .. "##pick_" .. key, false, nil, nil, nil, { text_col = col }) then
    action_picker_target = key
    reaper.PromptForAction(1, 0, 0)
  end
  hover_tip(assigned and (name .. "\n\nClick to choose a different action.")
    or "Click to choose a REAPER action for this button in this mode.")
end

local function draw_button_table(mode, is_live)
  local P = Theme.get_palette()
  reaper.ImGui_TextColored(ctx, P.text_dim, "Button Actions")

  local flags = reaper.ImGui_TableFlags_BordersInnerH() | reaper.ImGui_TableFlags_RowBg()
  if not reaper.ImGui_BeginTable(ctx, "btn_actions_tbl", 4, flags) then return end
  reaper.ImGui_TableSetupColumn(ctx, "##ena", reaper.ImGui_TableColumnFlags_WidthFixed(), L.chk_col_w)
  reaper.ImGui_TableSetupColumn(ctx, "Button", reaper.ImGui_TableColumnFlags_WidthFixed())
  reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())
  reaper.ImGui_TableSetupColumn(ctx, "##clr", reaper.ImGui_TableColumnFlags_WidthFixed(), UI.icon_w)

  local headers = { "", "Button", mode.label .. " Action", "" }
  reaper.ImGui_TableNextRow(ctx, reaper.ImGui_TableRowFlags_Headers())
  for col = 0, 3 do
    reaper.ImGui_TableSetColumnIndex(ctx, col)
    if col == 2 and is_live then
      reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_CellBg(), P.accent_e)
    end
    Theme.align(ctx, L.row_h)
    reaper.ImGui_Text(ctx, headers[col + 1])
  end

  for row = 1, 6 do
    reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
    local ena_key = "btn" .. row .. "_enabled"
    local key = "btn" .. row .. "_" .. mode.id

    reaper.ImGui_TableNextColumn(ctx)
    Theme.align(ctx, L.row_h)
    local rv, v = reaper.ImGui_Checkbox(ctx, "##" .. ena_key, config[ena_key])
    if rv then config[ena_key] = v; save_setting(ena_key) end
    hover_tip("Enable Button " .. row .. ". Applies in every mode.")

    local dim = not config[ena_key]
    if dim then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.5) end

    reaper.ImGui_TableNextColumn(ctx)
    Theme.align(ctx, L.row_h)
    reaper.ImGui_Text(ctx, "Button " .. row)

    reaper.ImGui_TableNextColumn(ctx)
    draw_action_cell(key, dim)

    reaper.ImGui_TableNextColumn(ctx)
    if config[key] ~= "" then
      Theme.align(ctx, L.row_h, UI.icon_w)
      if Theme.icon_btn(ctx, "clr_" .. key, Theme.icons.close, { preset = L.icon_md, tooltip = "Clear this action" }) then
        config[key] = ""
        save_setting(key)
      end
    end

    if dim then reaper.ImGui_PopStyleVar(ctx, 1) end
  end
  reaper.ImGui_EndTable(ctx)
end

-------------------------------------------------------------------------------
-- 8. MODE PANELS
-------------------------------------------------------------------------------
-- Each panel draws only its own mode's settings. SENS_NOTE marks the value
-- that Sensitivity Up/Down adjusts for that mode.

--- Per-mode Smooth Dial toggle; disabled while the Smooth Dial engine is off.
local function smooth_row(key)
  local master_off = not config.smooth_dial_enabled
  if master_off then reaper.ImGui_BeginDisabled(ctx) end
  checkbox_row("Smooth dial (analog slew)", key,
    "Interpolate this mode's dial ticks into a continuous sweep using the Smooth Dial engine.")
  if master_off then
    reaper.ImGui_EndDisabled(ctx)
    local P = Theme.get_palette()
    reaper.ImGui_SameLine(ctx, 0, L.md)
    Theme.align(ctx)
    reaper.ImGui_TextColored(ctx, P.text_dim, "(Smooth Dial is off)")
  end
end

--- MIDI settings shared by the MIDI CC and Velocity modes (same keys in both).
local function draw_midi_shared()
  drag_int_row("MIDI Channel:", "midi_channel", 1, 1, 16, "Ch %d",
    "MIDI channel for live CC signals and the Velocity audition note (1-16). Shared by MIDI CC and Velocity.")
  checkbox_row("Auto-arm & monitor target instrument track", "midi_auto_arm",
    "Record-arms and enables monitoring on the target track so live MIDI reaches plugins like Pocket Strings. Shared by MIDI CC and Velocity.")
end

local function panel_scrub(mode)
  combo_row("Unit:", "scrub_unit", SCRUB_UNIT_ITEMS,
    "How the dial moves the cursor. Free = smooth by time. Grid = snap to grid divisions. Beat/Measure = jump by musical unit.")
  local unit = config.scrub_unit
  if unit == "free" then
    drag_double_row("Seconds per Rotation:", "scrub_seconds", 0.1, 0.5, 10.0, "%.1f s",
      "Seconds of timeline per full dial rotation." .. SENS_NOTE)
  elseif SCRUB_JUMP_HINTS[unit] then
    form_label("")
    dim_text(SCRUB_JUMP_HINTS[unit])
  end
  -- Beat/Measure jump via REAPER actions, which scroll on their own
  if unit == "free" or unit == "grid" then
    checkbox_row("Scroll view with cursor", "scrub_move_view", "Scroll the arrange view to follow the cursor.")
  end
  if unit == "free" then smooth_row(mode.smooth) end
end

local function panel_fx(mode)
  drag_double_row("Sensitivity:", "fx_sensitivity", 0.1, 0.1, 5.0, "%.1fx",
    "Multiplier on FX parameter step size. Higher = faster knob movement." .. SENS_NOTE)
  checkbox_row("Fall back to Pan when no FX parameter is touched", "fx_pan_fallback",
    "When no FX parameter has been touched, the dial adjusts pan instead, using Pan mode's sensitivity and smoothing.")
  smooth_row(mode.smooth)
end

local function panel_pan(mode)
  drag_double_row("Sensitivity:", "pan_sensitivity", 0.1, 0.1, 5.0, "%.1fx",
    "Multiplier on pan step size. Also used by FX mode's pan fallback." .. SENS_NOTE)
  smooth_row(mode.smooth)
end

local function panel_volume(mode)
  drag_double_row("Step:", "vol_step_db", 0.1, 0.1, 6.0, "%.1f dB",
    "Decibels per dial tick. Also used by the Fancy_Mapper Volume Up/Down actions." .. SENS_NOTE)
  smooth_row(mode.smooth)
end

local function panel_width(mode)
  drag_double_row("Sensitivity:", "width_sensitivity", 0.1, 0.1, 5.0, "%.1fx",
    "Multiplier on stereo width step size." .. SENS_NOTE)
  checkbox_row("Auto-promote track to Stereo Pan mode", "width_auto_stereo_pan",
    "When adjusting width on a track in balance mode, automatically switches pan mode to Stereo Pan so width is active.")
  smooth_row(mode.smooth)
end

local function panel_track_nav()
  checkbox_row("Auto-scroll TCP when navigating tracks", "track_nav_scroll",
    "Keep the selected track in view in the TCP when using Track Nav mode.")
end

local function panel_midi_cc(mode)
  local P = Theme.get_palette()

  form_label("Target CC(s):")
  reaper.ImGui_SetNextItemWidth(ctx, UI.text_w)
  local rv, v = reaper.ImGui_InputText(ctx, "##midi_cc_targets", config.midi_cc_targets)
  if rv then config.midi_cc_targets = v; save_setting("midi_cc_targets") end
  hover_tip("Single CC number or comma-separated list to adjust simultaneously (e.g. '1' for Mod Wheel, '1, 11' for Mod + Expression).")

  form_label("Presets:")
  local current = norm_cc(config.midi_cc_targets)
  for i, preset in ipairs(CC_PRESETS) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, L.sm) end
    if chip("cc_preset_" .. i, preset.label, current == norm_cc(preset.value)) then
      config.midi_cc_targets = preset.value
      save_setting("midi_cc_targets")
    end
  end

  drag_double_row("Sensitivity:", "midi_cc_sensitivity", 0.1, 0.1, 5.0, "%.1fx",
    string.format("Multiplier on CC step size. At 1.0x, exactly one full rotation (%d ticks) sweeps 0 to 127.",
      config.ticks_per_rotation) .. SENS_NOTE)
  draw_midi_shared()
  checkbox_row("Auto-set MIDI Editor CC shape to Linear", "midi_cc_linear",
    "Sets the active MIDI Editor's default CC curve shape to Linear so recorded and drawn CCs connect as smooth ramps instead of square steps.")
  smooth_row(mode.smooth)

  reaper.ImGui_Dummy(ctx, 0, L.sm)
  if reaper.ImGui_Button(ctx, "Smooth Active Take CC Lane (Linearize)##smooth_take_btn") then
    local count = MapperEngine.linearize_take_cc(nil, nil) or 0
    if count > 0 then
      smooth_feedback_msg = string.format("Smoothed %d CC points to Linear!", count)
    else
      smooth_feedback_msg = "No MIDI CC events found to smooth in active take."
    end
    smooth_feedback_time = reaper.time_precise()
  end
  hover_tip("Converts CC events in the active or selected take to linear shape (1-click smoothing for recorded takes).")

  if smooth_feedback_msg and (reaper.time_precise() - smooth_feedback_time < 3.0) then
    reaper.ImGui_SameLine(ctx, 0, L.md)
    Theme.align(ctx)
    reaper.ImGui_TextColored(ctx, P.accent, smooth_feedback_msg)
  end
end

local function panel_midi_vel()
  drag_double_row("Sensitivity:", "midi_vel_sensitivity", 0.1, 0.1, 5.0, "%.1fx",
    string.format("Multiplier on velocity step size. At 1.0x, exactly one full rotation (%d ticks) sweeps 1 to 127.",
      config.ticks_per_rotation) .. SENS_NOTE)
  checkbox_row("Audition note preview when dial turns (stopped transport)", "midi_vel_audition",
    "Sends a short preview note at the new velocity when REAPER transport is stopped.")
  draw_midi_shared()
end

local function panel_marker()
  dim_text("No settings for this mode. Turning the dial jumps the edit cursor between markers and regions.")
end

local function panel_transient()
  dim_text("No settings for this mode. Turning the dial jumps between transients in the selected items, "
    .. "using REAPER's transient detection settings.")
end

local function panel_item_slip(mode)
  drag_int_row("Step:", "slip_step_ms", 1, 1, 100, "%d ms",
    "Milliseconds of audio source offset to slip per dial tick." .. SENS_NOTE)
  smooth_row(mode.smooth)
end

local MODE_PANELS = {
  scrub     = panel_scrub,
  fx        = panel_fx,
  pan       = panel_pan,
  volume    = panel_volume,
  width     = panel_width,
  track_nav = panel_track_nav,
  midi_cc   = panel_midi_cc,
  midi_vel  = panel_midi_vel,
  marker    = panel_marker,
  transient = panel_transient,
  item_slip = panel_item_slip,
}

-------------------------------------------------------------------------------
-- 9. SECTIONS
-------------------------------------------------------------------------------
local function draw_header()
  Theme.header(ctx, {
    title = "DIAL SETTINGS",
    fonts = fonts,
    right_width = UI.icon_w,
    right_widgets = function(hctx, hdr_h)
      Theme.align(hctx, hdr_h, UI.icon_w)
      if Theme.icon_btn(hctx, "hdr_gear", Theme.icons.gear, { preset = L.icon_md, tooltip = "Theme & tooltip settings" }) then
        show_gear_popover = true
      end
    end,
  })

  if show_gear_popover then
    reaper.ImGui_OpenPopup(ctx, "SettingsPopover")
    show_gear_popover = false
  end

  if reaper.ImGui_BeginPopup(ctx, "SettingsPopover") then
    Theme.settings_widget(ctx)
    Theme.tooltip_setting_widget(ctx)
    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_general()
  Theme.section_divider(ctx, "General")

  form_label("Ticks per Rotation:")
  reaper.ImGui_SetNextItemWidth(ctx, UI.field_w)
  local rv, v = reaper.ImGui_InputInt(ctx, "##ticks_per_rotation", config.ticks_per_rotation)
  if rv then config.ticks_per_rotation = math.max(1, v); save_setting("ticks_per_rotation") end
  hover_tip("Number of events your dial sends per full 360° rotation. Click Calibrate to measure it.")
  reaper.ImGui_SameLine(ctx, 0, L.md)
  if reaper.ImGui_Button(ctx, "Calibrate…##open_calibrate") then
    pending_popup = POPUP_CALIBRATE
  end
  hover_tip("Measure ticks per rotation by turning your dial once.")

  drag_int_row("Throttle:", "throttle_ms", 1, 0, 500, "%d ms",
    "Minimum milliseconds between accepted dial events. Prevents event queue buildup.")
  combo_row("Default Mode:", "default_mode", MODE_ITEMS, "Mode the dial starts in when REAPER launches.")
  checkbox_row("Show value HUD while turning", "midi_show_tooltip",
    "Floating readout near the mouse showing the current value in FX, Pan, Volume, Width, MIDI CC, Velocity, and Item Slip modes, and on Reset Parameter.")

  reaper.ImGui_Dummy(ctx, 0, L.md)

  drag_double_row("Sensitivity Step:", "sensitivity_step", 0.05, 0.1, 5.0, "%.2f",
    "Amount each press of Sensitivity Up/Down changes the active mode's main value (noted in its tooltip in the Mode section).")
  checkbox_row("Show toast when sensitivity changes", "toast_enabled",
    "On-screen overlay when Sensitivity Up/Down changes the active mode's value.")
  if config.toast_enabled then
    combo_row("Toast Position:", "toast_position", TOAST_POS_ITEMS, "Where the sensitivity toast appears on screen.")
    drag_double_row("Toast Duration:", "toast_duration", 0.1, 0.5, 3.0, "%.1f s",
      "How long the sensitivity toast stays visible.")
  end
end

local function draw_smooth()
  local P = Theme.get_palette()
  Theme.section_divider(ctx, "Smooth Dial (Analog Slew Engine)")

  local daemon_on = MapperEngine.is_daemon_alive()
  if daemon_on then
    Theme.badge(ctx, "● Slew Daemon: Active (60 Hz)", { color = P.green })
  else
    Theme.badge(ctx, "○ Slew Daemon: Standby (Auto-Wake)", { color = P.text_dim })
  end
  hover_tip("Background 60 Hz consumer daemon. Auto-wakes when you turn the dial, slews parameters smoothly, and auto-sleeps after 10 seconds of idle dial activity (0% CPU when not in use).")

  reaper.ImGui_SameLine(ctx, 0, L.md)
  if daemon_on then
    if chip("daemon_toggle", "Stop Daemon", false) then
      reaper.SetExtState(EXTSTATE_SECTION, "daemon_stop", "1", false)
    end
  elseif chip("daemon_toggle", "Wake Daemon", false) then
    MapperEngine.ensure_daemon_running()
  end

  checkbox_row("Enable Smooth Dial Interpolation", "smooth_dial_enabled",
    "Converts discrete notched hardware dial clicks into continuous, analog potentiometer-style parameter sweeps. Eliminates background task dialogs completely.")
  if not config.smooth_dial_enabled then return end

  drag_double_row("Responsiveness:", "smooth_dial_speed", 1.0, 5.0, 80.0, "%.0f /s",
    "Exponential slew rate per second. Higher = snappy & immediate; lower = silky, weighted tape feel.")
  for i, preset in ipairs(SPEED_PRESETS) do
    reaper.ImGui_SameLine(ctx, 0, L.sm)
    if chip("speed_preset_" .. i, preset.label, math.abs(config.smooth_dial_speed - preset.value) < 0.5) then
      config.smooth_dial_speed = preset.value
      save_setting("smooth_dial_speed")
    end
  end

  local names = {}
  for _, m in ipairs(MODE_ITEMS) do
    if m.smooth and config[m.smooth] then names[#names + 1] = m.label end
  end
  dim_text("Smoothed: " .. (#names > 0 and table.concat(names, " · ") or "none")
    .. "  (toggle per mode in the Mode section)")
end

local function draw_mode(live_mode)
  Theme.section_divider(ctx, "Mode")

  form_label("Configure Mode:")
  local new_idx, changed = Theme.combo(ctx, "##view_mode", MODE_ITEMS, view_mode_idx, { w = UI.field_w })
  if changed then view_mode_idx = new_idx end

  reaper.ImGui_SameLine(ctx, 0, L.md)
  local viewing_live = MODE_ITEMS[view_mode_idx].id == live_mode
  if chip("jump_live_mode", "Current: " .. mode_label(live_mode), viewing_live,
      "The mode your dial is in right now. Click to configure it.") then
    view_mode_idx = find_idx(MODE_ITEMS, live_mode)
  end

  local mode = MODE_ITEMS[view_mode_idx]
  reaper.ImGui_Dummy(ctx, 0, L.sm)
  local panel = MODE_PANELS[mode.id]
  if panel then panel(mode) end

  reaper.ImGui_Dummy(ctx, 0, L.lg)
  draw_button_table(mode, mode.id == live_mode)
end

local function draw_ring()
  Theme.section_divider(ctx, "Action Ring (Mode Selector)", {
    tooltip = "Modes appear clockwise from the top, in the order listed here.",
  })

  -- Show what Cycle Mode will actually draw: it uses the curated ring below the minimum
  local set, count = ring_set(config.ring_modes)
  if count < RING_MIN_MODES then set, count = ring_set(CURATED_RING) end

  reaper.ImGui_Text(ctx, string.format("Modes in Ring (%d of %d):", count, #MODE_ITEMS))
  if reaper.ImGui_BeginTable(ctx, "ring_modes_tbl", UI.ring_cols) then
    for _, m in ipairs(MODE_ITEMS) do
      reaper.ImGui_TableNextColumn(ctx)
      local on = set[m.id] == true
      local locked = on and count <= RING_MIN_MODES
      local tip
      if locked then
        tip = string.format("The ring needs at least %d modes.", RING_MIN_MODES)
      elseif on then
        tip = "In the ring. Click to remove."
      else
        tip = "Click to add to the ring."
      end
      local clicked = Theme.toggle_button(ctx, "ring_" .. m.id, m.label, on,
        { preset = L.btn_sm, fonts = fonts, w = -1, tooltip = tip })
      if clicked and not locked then
        set[m.id] = (not on) or nil
        config.ring_modes = ring_csv(set)
        save_setting("ring_modes")
      end
    end
    reaper.ImGui_EndTable(ctx)
  end

  form_label("Presets:")
  local csv = ring_csv(set)
  if chip("ring_preset_curated", "Curated 8", csv == CURATED_RING,
      "Scrub, FX Parameter, Pan, Volume, Width, Track Nav, MIDI CC, Velocity") then
    config.ring_modes = CURATED_RING
    save_setting("ring_modes")
  end
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  if chip("ring_preset_all", string.format("All %d", #MODE_ITEMS), csv == ALL_RING, "Every mode") then
    config.ring_modes = ALL_RING
    save_setting("ring_modes")
  end

  reaper.ImGui_Dummy(ctx, 0, L.sm)

  checkbox_row("Enable Directional Flick", "ring_flick_enabled",
    "Flick the mouse outward into a sector to instantly select that mode.")
  if config.ring_flick_enabled then
    drag_int_row("Flick Distance:", "ring_flick_distance", 1, 50, 120, "%d px",
      "Distance from center (in pixels) required to trigger a flick selection.")
  end

  checkbox_row("Enable Dwell Hover Selection", "ring_dwell_enabled",
    "Hovering over an active mode without flicking will auto-select it after a brief pause.")
  if config.ring_dwell_enabled then
    drag_int_row("Dwell Time:", "ring_dwell_ms", 5, 80, 600, "%d ms",
      "Milliseconds of hovering a sector before it auto-selects.")
  end

  checkbox_row("Enable Inactivity Auto-Close", "ring_timeout_enabled",
    "Automatically closes the radial ring after a period of inactivity without selecting a mode.")
  if config.ring_timeout_enabled then
    drag_double_row("Auto-Close Timeout:", "ring_timeout_s", 0.1, 1.0, 10.0, "%.1f s",
      "Seconds before the ring auto-closes if kept open without selecting.")
  end
end

local function draw_reset_row()
  Theme.section_divider(ctx, "")
  if reaper.ImGui_Button(ctx, "Reset All to Defaults", -1) then
    pending_popup = POPUP_RESET
  end
end

-------------------------------------------------------------------------------
-- 10. MODALS
-------------------------------------------------------------------------------
--- While the calibrate dialog is drawn, a fresh heartbeat tells the engine to
--- count dial ticks instead of acting on them (see MapperEngine.run).
local function set_calibrating(on)
  if on then
    reaper.SetExtState(EXTSTATE_SECTION, "calibrating", tostring(reaper.time_precise()), false)
    calib_hb_set = true
  elseif calib_hb_set then
    reaper.DeleteExtState(EXTSTATE_SECTION, "calibrating", false)
    calib_hb_set = false
  end
end

local function draw_calibrate_modal()
  local P = Theme.get_palette()
  Theme.center_next_window(ctx, L.modal_sm.w, 0)
  Theme.modal_scrim(ctx, POPUP_CALIBRATE)
  if not reaper.ImGui_BeginPopupModal(ctx, POPUP_CALIBRATE, true, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    return
  end
  calib_drawn = true
  set_calibrating(true)

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_Text(ctx, "Turn your dial slowly, exactly one full rotation.")
  dim_text("Either direction works; turn back to correct an overshoot. While this dialog is open, "
    .. "dial turns are only counted and nothing else moves.")

  reaper.ImGui_Dummy(ctx, 0, L.lg)

  local ticks = math.floor(math.abs(tonumber(get_setting_str("calibrate_count", "0")) or 0))
  local count_str = tostring(ticks)
  local pushed_h = Theme.push_font(ctx, fonts.header)
  Theme.hcenter(ctx, (reaper.ImGui_CalcTextSize(ctx, count_str)))
  reaper.ImGui_Text(ctx, count_str)
  Theme.pop_font(ctx, pushed_h)

  local caption = string.format("ticks counted  ·  current setting: %d", config.ticks_per_rotation)
  Theme.hcenter(ctx, (reaper.ImGui_CalcTextSize(ctx, caption)))
  reaper.ImGui_TextColored(ctx, P.text_dim, caption)

  reaper.ImGui_Dummy(ctx, 0, L.lg)

  if reaper.ImGui_Button(ctx, "Reset Count##calib_reset") then
    reaper.SetExtState(EXTSTATE_SECTION, "calibrate_count", "0", false)
  end
  reaper.ImGui_SameLine(ctx, 0, L.md)
  if reaper.ImGui_Button(ctx, "Cancel##calib_cancel") then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx)
  local can_apply = ticks > 0
  if not can_apply then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, string.format("Apply (%d)###calib_apply", ticks)) then
    config.ticks_per_rotation = ticks
    save_setting("ticks_per_rotation")
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  if not can_apply then reaper.ImGui_EndDisabled(ctx) end

  reaper.ImGui_EndPopup(ctx)
end

local function draw_reset_modal()
  Theme.center_next_window(ctx, L.modal_sm.w, 0)
  Theme.modal_scrim(ctx, POPUP_RESET)
  if not reaper.ImGui_BeginPopupModal(ctx, POPUP_RESET, nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    return
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_Text(ctx, "Reset all Fancy Mapper settings to defaults?")
  dim_text("This also clears every button action assignment.")
  reaper.ImGui_Dummy(ctx, 0, L.lg)
  if reaper.ImGui_Button(ctx, "Cancel##reset_cancel") then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Reset##reset_confirm") then
    reset_all_to_defaults()
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

local function draw_modals()
  if pending_popup then
    if pending_popup == POPUP_CALIBRATE then
      reaper.SetExtState(EXTSTATE_SECTION, "calibrate_count", "0", false)
    end
    reaper.ImGui_OpenPopup(ctx, pending_popup)
    pending_popup = nil
  end
  draw_calibrate_modal()
  draw_reset_modal()
end

-------------------------------------------------------------------------------
-- 11. MAIN LOOP
-------------------------------------------------------------------------------
local function loop()
  -- Pick up changes made by other scripts (e.g. Sensitivity Up/Down),
  -- but never while a field is being dragged or typed into
  local now = reaper.time_precise()
  if now - last_reload >= RELOAD_INTERVAL_S and not reaper.ImGui_IsAnyItemActive(ctx) then
    load_config()
    last_reload = now
  end

  local P = Theme.get_palette()
  local nc, nv = Theme.push(ctx, P)
  local pushed = Theme.push_font(ctx, fonts.default)

  poll_action_picker()

  Theme.center_next_window(ctx, UI.win_w, UI.win_h, reaper.ImGui_Cond_FirstUseEver())

  local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
  local visible, open = reaper.ImGui_Begin(ctx, "Fancy Mapper Settings", true, win_flags)
  if not open then
    is_running = false
  end

  calib_drawn = false
  if visible then
    -- Keep the Mode section on the live mode while that's what the user is viewing
    local live_mode = get_live_mode()
    if live_mode ~= last_live_mode then
      if last_live_mode == nil or MODE_ITEMS[view_mode_idx].id == last_live_mode then
        view_mode_idx = find_idx(MODE_ITEMS, live_mode)
      end
      last_live_mode = live_mode
    end

    draw_header()
    reaper.ImGui_Dummy(ctx, 0, L.md)
    draw_general()
    reaper.ImGui_Dummy(ctx, 0, L.xl)
    draw_smooth()
    reaper.ImGui_Dummy(ctx, 0, L.xl)
    draw_mode(live_mode)
    reaper.ImGui_Dummy(ctx, 0, L.xl)
    draw_ring()
    reaper.ImGui_Dummy(ctx, 0, L.xl)
    draw_reset_row()
    draw_modals()

    reaper.ImGui_End(ctx)
  end

  -- The dial goes back to normal as soon as the calibrate dialog isn't drawn
  if not calib_drawn then set_calibrating(false) end

  Theme.pop_font(ctx, pushed)
  Theme.pop(ctx, nc, nv)

  if is_running then
    reaper.defer(loop)
  end
end

-------------------------------------------------------------------------------
-- 12. BOOTSTRAP
-------------------------------------------------------------------------------
local function cleanup()
  set_calibrating(false)
  if action_picker_target then
    reaper.PromptForAction(-1, 0, 0)  -- close an open picker session
  end
end

local function main()
  local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
  ctx = reaper.ImGui_CreateContext("Fancy Mapper Settings", dock_flag)
  fonts = Theme.create_fonts(ctx)
  Theme.attach_fonts(ctx, fonts)
  reaper.atexit(cleanup)
  reaper.defer(loop)
end

main()
