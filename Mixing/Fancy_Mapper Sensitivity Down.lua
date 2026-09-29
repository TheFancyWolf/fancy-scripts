-- @description Fancy Mapper Sensitivity Down
-- @author Fancy Scripts
-- @version 5.1.0
-- @changelog
--   + v5.1: Added sensitivity scaling for volume, width, MIDI CC, velocity, and item slip
-- @about
--   Decreases the sensitivity of the currently active Fancy Mapper mode.
--   Shows a brief toast with the new value. Step size is configurable
--   in Fancy Mapper Settings.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Mapper Sensitivity Down -- Missing ReaImGui", 0)
  return
end

reaper.set_action_options(1)

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path
local Theme = require("theme")

-------------------------------------------------------------------------------
-- 1. ADJUST
-------------------------------------------------------------------------------

local MODE_KEYS   = {
  scrub     = "scrub_seconds",
  fx        = "fx_sensitivity",
  pan       = "pan_sensitivity",
  volume    = "vol_step_db",
  width     = "width_sensitivity",
  midi_cc   = "midi_cc_sensitivity",
  midi_vel  = "midi_vel_sensitivity",
  item_slip = "slip_step_ms",
}
local MODE_DEFS   = {
  scrub     = 2.0,
  fx        = 1.0,
  pan       = 1.0,
  volume    = 1.0,
  width     = 1.0,
  midi_cc   = 1.0,
  midi_vel  = 1.0,
  item_slip = 10,
}
local MODE_MIN    = {
  scrub     = 0.5,
  fx        = 0.1,
  pan       = 0.1,
  volume    = 0.1,
  width     = 0.1,
  midi_cc   = 0.1,
  midi_vel  = 0.1,
  item_slip = 1,
}
local MODE_LABELS = {
  scrub     = "Scrub Speed",
  fx        = "FX Sensitivity",
  pan       = "Pan Sensitivity",
  volume    = "Volume Step",
  width     = "Width Sensitivity",
  midi_cc   = "MIDI CC Sensitivity",
  midi_vel  = "Velocity Sensitivity",
  item_slip = "Item Slip Step",
}
local MODE_SUFFIX = {
  scrub     = "s",
  fx        = "x",
  pan       = "x",
  volume    = " dB",
  width     = "x",
  midi_cc   = "x",
  midi_vel  = "x",
  item_slip = " ms",
}
local MODE_IS_INT = {
  item_slip = true,
}

local function adjust()
  local mode = reaper.GetExtState("FancyMapper", "mode")
  if mode == "" then mode = reaper.GetExtState("FancyMapper", "default_mode") end
  if mode == "" then mode = "scrub" end

  local key = MODE_KEYS[mode]
  if not key then return nil end

  local is_int = MODE_IS_INT[mode]
  local step = tonumber(reaper.GetExtState("FancyMapper", "sensitivity_step") or "") or 1.0
  if is_int then step = math.max(1, math.floor(step + 0.5)) end

  local cur = tonumber(reaper.GetExtState("FancyMapper", key) or "") or MODE_DEFS[mode]
  local new_val = math.max(cur - step, MODE_MIN[mode] or 0.1)
  if is_int then new_val = math.floor(new_val + 0.5) end

  reaper.SetExtState("FancyMapper", key, is_int and tostring(new_val) or string.format("%.1f", new_val), true)

  local fmt = is_int and "%s: %d%s" or "%s: %.1f%s"
  return string.format(fmt, MODE_LABELS[mode], new_val, MODE_SUFFIX[mode] or "")
end

-------------------------------------------------------------------------------
-- 2. TOAST
-------------------------------------------------------------------------------

local function show_toast(text)
  if not text then return end
  if reaper.GetExtState("FancyMapper", "toast_enabled") == "0" then return end

  local duration = tonumber(reaper.GetExtState("FancyMapper", "toast_duration") or "") or 1.5
  local position = reaper.GetExtState("FancyMapper", "toast_position")
  if position == "" then position = "center" end

  local ctx = reaper.ImGui_CreateContext("Fancy Mapper Sens Toast")
  local fonts = Theme.create_fonts(ctx)
  Theme.attach_fonts(ctx, fonts)

  local start_time = reaper.time_precise()
  local my_ts = tostring(start_time)
  reaper.SetExtState("FancyMapper", "sens_toast_ts", my_ts, false)

  local flags = reaper.ImGui_WindowFlags_NoTitleBar()
              | reaper.ImGui_WindowFlags_NoResize()
              | reaper.ImGui_WindowFlags_NoMove()
              | reaper.ImGui_WindowFlags_NoScrollbar()
              | reaper.ImGui_WindowFlags_AlwaysAutoResize()
              | reaper.ImGui_WindowFlags_NoFocusOnAppearing()
              | reaper.ImGui_WindowFlags_NoNav()
              | reaper.ImGui_WindowFlags_NoSavedSettings()

  local function loop()
    if reaper.GetExtState("FancyMapper", "sens_toast_ts") ~= my_ts then return end
    local elapsed = reaper.time_precise() - start_time
    if elapsed >= duration then return end

    local alpha = elapsed < (duration - 0.3) and 0.92
      or math.max(0.0, ((duration - elapsed) / 0.3)) * 0.92

    local vp = reaper.ImGui_GetMainViewport(ctx)
    local vp_x, vp_y = reaper.ImGui_Viewport_GetWorkPos(vp)
    local vp_w, vp_h = reaper.ImGui_Viewport_GetWorkSize(vp)
    local px, py, ax, ay
    local m = 20
    if position == "top-right" then        px, py, ax, ay = vp_x+vp_w-m, vp_y+m,     1, 0
    elseif position == "bottom-right" then px, py, ax, ay = vp_x+vp_w-m, vp_y+vp_h-m, 1, 1
    elseif position == "bottom-left" then  px, py, ax, ay = vp_x+m,      vp_y+vp_h-m, 0, 1
    else                                    px, py, ax, ay = vp_x+vp_w*0.5, vp_y+vp_h*0.5, 0.5, 0.5 end

    reaper.ImGui_SetNextWindowPos(ctx, px, py, reaper.ImGui_Cond_Always(), ax, ay)

    local P = Theme.get_palette()
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), alpha)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 24, 16)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), Theme.with_alpha(P.bg, 0.85))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0)

    local vis = reaper.ImGui_Begin(ctx, "##sens_toast", false, flags)
    if vis then
      local pushed = Theme.push_font(ctx, fonts.header)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text)
      reaper.ImGui_Text(ctx, text)
      reaper.ImGui_PopStyleColor(ctx)
      Theme.pop_font(ctx, pushed)
      reaper.ImGui_End(ctx)
    end

    reaper.ImGui_PopStyleColor(ctx, 2)
    reaper.ImGui_PopStyleVar(ctx, 3)
    reaper.defer(loop)
  end

  reaper.defer(loop)
end

-------------------------------------------------------------------------------
-- 3. MAIN
-------------------------------------------------------------------------------

local function main()
  show_toast(adjust())
end

main()
