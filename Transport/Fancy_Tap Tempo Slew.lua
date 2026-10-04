-- @description Fancy Tap Tempo Slew
-- @author Fancy Scripts
-- @version 1.0.0
-- @changelog
--   + Initial release
-- @about
--   Tap tempo for following a live player. After the 4th tap the tempo
--   changes at once, or glides at a configurable slew rate.
--   Bind the action to a key and press it on each beat. The target BPM is
--   the average of the last few tap intervals. Use the "Fancy Tap Tempo
--   Slew Settings" action to change the mode, taps per change and limits.
--   An instant change inserts a tempo marker at the play position, so the
--   play position does not jump and sounding notes are not retriggered.
--   Requirements: REAPER 7.03+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

-------------------------------------------------------------------------------
-- 1. SETTINGS
-------------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Settings = require("tap_tempo_settings")
local CONFIG = Settings.load() -- re-read on every press (each press relaunches)

local EXT = Settings.EXT
local EPSILON = 0.001

-------------------------------------------------------------------------------
-- 2. TAP STATE (non-persistent ExtState, shared across relaunches)
-------------------------------------------------------------------------------

local function load_taps()
  local taps = {}
  for t in reaper.GetExtState(EXT, "taps"):gmatch("[^,]+") do
    local n = tonumber(t)
    if n then taps[#taps + 1] = n end
  end
  return taps
end

local function save_taps(taps)
  local parts = {}
  for i, t in ipairs(taps) do parts[i] = string.format("%.6f", t) end
  reaper.SetExtState(EXT, "taps", table.concat(parts, ","), false)
end

-- Records a tap and returns the new target BPM, or nil until tap_count taps.
local function register_tap(now)
  local taps = load_taps()
  if #taps > 0 and now - taps[#taps] > CONFIG.restart_gap then
    taps = {}
  end
  taps[#taps + 1] = now
  while #taps > CONFIG.taps_per_change do table.remove(taps, 1) end

  if #taps < CONFIG.taps_per_change then
    save_taps(taps)
    return nil
  end
  local avg = (taps[#taps] - taps[1]) / (#taps - 1)
  -- Group mode: the next change needs a fresh group of taps.
  save_taps(CONFIG.update == "group" and {} or taps)
  if avg <= 0 then return nil end
  local bpm = 60.0 / avg
  return math.max(CONFIG.min_bpm, math.min(CONFIG.max_bpm, bpm))
end

-------------------------------------------------------------------------------
-- 3. TEMPO ACCESS
-------------------------------------------------------------------------------

-- Returns get(), set(bpm) for the tempo in effect at the play position (or
-- edit cursor when stopped): the tempo marker there, or the project tempo
-- when there is no marker at or before that position.
local function tempo_at_position()
  local playing = reaper.GetPlayState() & 1 == 1
  local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local idx = reaper.FindTempoTimeSigMarker(0, pos)

  if idx >= 0 then
    local get = function()
      local ok, _, _, _, bpm = reaper.GetTempoTimeSigMarker(0, idx)
      return ok and bpm or nil
    end
    local set = function(bpm)
      local ok, timepos, _, _, _, num, denom, linear =
        reaper.GetTempoTimeSigMarker(0, idx)
      if not ok then return end
      reaper.SetTempoTimeSigMarker(0, idx, timepos, -1, -1, bpm, num, denom, linear)
      reaper.UpdateTimeline()
    end
    return get, set
  end

  return reaper.Master_GetTempo, function(bpm)
    reaper.SetCurrentBPM(0, bpm, false)
  end
end

-------------------------------------------------------------------------------
-- 4. INSTANT CHANGE
-------------------------------------------------------------------------------

-- Puts the new tempo in a marker at the next audio block (or the edit cursor
-- when stopped). Everything already played keeps its timing, so the play
-- position does not jump and sounding notes are not cut and retriggered.
local function apply_instant(target)
  local playing = reaper.GetPlayState() & 1 == 1
  local pos = playing and reaper.GetPlayPosition2() or reaper.GetCursorPosition()

  if math.abs(reaper.TimeMap2_GetDividedBpmAtTime(0, pos) - target) <= EPSILON then
    return
  end

  reaper.Undo_BeginBlock()
  local idx = reaper.FindTempoTimeSigMarker(0, pos)
  local ok, timepos, _, _, _, num, denom, linear = false, 0, 0, 0, 0, 0, 0, false
  if idx >= 0 then
    ok, timepos, _, _, _, num, denom, linear = reaper.GetTempoTimeSigMarker(0, idx)
  end
  if ok and math.abs(timepos - pos) < 0.001 then
    -- A marker already sits here: change it rather than stacking another.
    reaper.SetTempoTimeSigMarker(0, idx, timepos, -1, -1, target, num, denom, linear)
  else
    reaper.SetTempoTimeSigMarker(0, -1, pos, -1, -1, target, 0, 0, false)
  end
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock("Tap tempo", -1)
end

-------------------------------------------------------------------------------
-- 5. GLIDE LOOP
-------------------------------------------------------------------------------

local function start_glide(target)
  local get_bpm, set_bpm = tempo_at_position()
  local last_time = reaper.time_precise()

  local function step()
    local now = reaper.time_precise()
    local dt = now - last_time
    last_time = now

    local current = get_bpm()
    if not current then return end -- marker was deleted mid-glide
    local diff = target - current
    local stopped = reaper.GetExtState(EXT, "stop") == "1"
    if stopped or math.abs(diff) <= EPSILON then
      reaper.SetExtState(EXT, "target", "", false)
      reaper.Undo_OnStateChange("Tap tempo slew")
      return
    end

    local max_step = CONFIG.glide_rate * dt
    local new_bpm
    if math.abs(diff) <= max_step then
      new_bpm = target
    else
      new_bpm = current + (diff > 0 and max_step or -max_step)
    end
    set_bpm(new_bpm)
    reaper.defer(step)
  end

  reaper.defer(step)
end

-------------------------------------------------------------------------------
-- 6. MAIN
-------------------------------------------------------------------------------

local function main()
  -- A new press terminates the running glide and relaunches this script;
  -- tap history and target survive in ExtState.
  reaper.set_action_options(1 | 2)
  reaper.SetExtState(EXT, "stop", "", false)

  local target = register_tap(reaper.time_precise())

  if CONFIG.mode ~= "glide" then
    if target then apply_instant(target) end
    return
  end

  if target then
    reaper.SetExtState(EXT, "target", tostring(target), false)
  else
    -- Not enough taps yet: keep gliding toward any previous target.
    target = tonumber(reaper.GetExtState(EXT, "target"))
  end

  if target then start_glide(target) end
end

main()
