-- @description Fancy Tap Tempo Slew
-- @author Fancy Scripts
-- @version 1.1.0
-- @changelog
--   + Shared libraries now ship in the separate "Fancy Scripts Library" package
--   # Tap tempo ignores a stray tap (median of the intervals, missed or doubled taps folded in)
--   # Restart gap is never shorter than one and a half beats at the minimum tempo
--   # Instant change inside a linear tempo ramp no longer retimes the ramp before the play position
--   # Instant change compares the quarter-note tempo, not the divided tempo, with the target
--   # Glide ramps its own marker at the play position instead of whichever marker was in effect at the start
--   # Switching to instant mode during a glide keeps an undo point for the glide
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

-------------------------------------------------------------------------------
-- 1. SETTINGS
-------------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path
if not reaper.file_exists(script_dir .. "../_lib/utils.lua") then
  reaper.MB("This script requires the \"Fancy Scripts Library\" package.\n\nInstall it via Extensions > ReaPack > Browse packages.", "Fancy Scripts", 0)
  return
end

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

-- Beat length from the tap times: the median interval sets the reference, an
-- interval near twice or half of it (a missed or doubled tap) is folded onto
-- it, intervals still more than 30% off are dropped and the rest averaged.
local function beat_interval(taps)
  local intervals = {}
  for k = 2, #taps do intervals[#intervals + 1] = taps[k] - taps[k - 1] end
  if #intervals == 0 then return nil end

  local sorted = {}
  for k, d in ipairs(intervals) do sorted[k] = d end
  table.sort(sorted)
  local m = #sorted
  local median = m % 2 == 1 and sorted[(m + 1) / 2]
                 or (sorted[m / 2] + sorted[m / 2 + 1]) / 2
  if median <= 0 then return nil end

  local sum, count = 0, 0
  for _, d in ipairs(intervals) do
    local r = d / median
    if r >= 1.7 and r <= 2.3 then
      d = d / 2
    elseif r >= 0.425 and r <= 0.575 then
      d = d * 2
    end
    if math.abs(d - median) <= 0.3 * median then
      sum, count = sum + d, count + 1
    end
  end
  if count == 0 then return median end
  return sum / count
end

-- Records a tap and returns the new target BPM, or nil until tap_count taps.
local function register_tap(now)
  local taps = load_taps()
  -- A gap longer than the restart gap starts a new tap group, but never one
  -- that would still be a valid beat at the minimum tempo.
  local gap = math.max(CONFIG.restart_gap, 60 / CONFIG.min_bpm * 1.5)
  if #taps > 0 and now - taps[#taps] > gap then
    taps = {}
  end
  taps[#taps + 1] = now
  while #taps > CONFIG.taps_per_change do table.remove(taps, 1) end

  if #taps < CONFIG.taps_per_change then
    save_taps(taps)
    return nil
  end
  local avg = beat_interval(taps)
  -- Group mode: the next change needs a fresh group of taps.
  save_taps(CONFIG.update == "group" and {} or taps)
  if not avg or avg <= 0 then return nil end
  local bpm = 60.0 / avg
  return math.max(CONFIG.min_bpm, math.min(CONFIG.max_bpm, bpm))
end

-------------------------------------------------------------------------------
-- 3. TEMPO MARKERS
-------------------------------------------------------------------------------

local AT_POS   = 0.001 -- a marker this close to a position counts as "there"
local HOLD_GAP = 0.002 -- offset of the new tempo after a held ramp end

-- Play position (next audio block) or edit cursor when stopped.
local function change_position()
  local playing = reaper.GetPlayState() & 1 == 1
  return playing and reaper.GetPlayPosition2() or reaper.GetCursorPosition()
end

-- Quarter-note tempo in effect at time t (inside a ramp: the ramp's value).
local function tempo_at(t)
  local _, _, bpm = reaper.TimeMap_GetTimeSigAtTime(0, t)
  return bpm
end

-- Index of the marker within AT_POS of t, or -1.
local function marker_at(t)
  local idx = reaper.FindTempoTimeSigMarker(0, t + AT_POS)
  if idx < 0 then return -1 end
  local ok, timepos = reaper.GetTempoTimeSigMarker(0, idx)
  if ok and math.abs(timepos - t) < AT_POS then return idx end
  return -1
end

local function marker_is_linear(idx)
  if idx < 0 then return false end
  local ok, _, _, _, _, _, _, linear = reaper.GetTempoTimeSigMarker(0, idx)
  return ok and linear
end

-- Sets bpm on the marker at t (keeping its time signature and shape) or
-- inserts a square marker there.
local function put_marker(t, bpm)
  local idx = marker_at(t)
  if idx >= 0 then
    local ok, timepos, _, _, _, num, denom, linear = reaper.GetTempoTimeSigMarker(0, idx)
    if ok then
      reaper.SetTempoTimeSigMarker(0, idx, timepos, -1, -1, bpm, num, denom, linear)
      return timepos
    end
  end
  reaper.SetTempoTimeSigMarker(0, -1, t, -1, -1, bpm, 0, 0, false)
  return t
end

-- Puts bpm into a marker at pos and returns that marker's time position.
-- When a linear ramp runs into pos, the ramp is first ended at pos with the
-- tempo it has there, and the new tempo starts just after it, so everything
-- before pos keeps its timing.
local function place_tempo(pos, bpm)
  local idx = marker_at(pos)
  local ramp_in
  if idx >= 0 then
    ramp_in = marker_is_linear(idx - 1)
  else
    ramp_in = marker_is_linear(reaper.FindTempoTimeSigMarker(0, pos))
  end

  if not ramp_in then return put_marker(pos, bpm) end

  local hold_at = pos
  if idx >= 0 then
    local _, timepos = reaper.GetTempoTimeSigMarker(0, idx)
    hold_at = timepos
  else
    reaper.SetTempoTimeSigMarker(0, -1, pos, -1, -1, tempo_at(pos), 0, 0, false)
  end
  return put_marker(hold_at + HOLD_GAP, bpm)
end

-------------------------------------------------------------------------------
-- 4. INSTANT CHANGE
-------------------------------------------------------------------------------

-- Puts the new tempo in a marker at the next audio block (or the edit cursor
-- when stopped). Everything already played keeps its timing, so the play
-- position does not jump and sounding notes are not cut and retriggered.
local function apply_instant(target)
  local pos = change_position()

  if math.abs(tempo_at(pos) - target) <= EPSILON then
    return
  end

  reaper.Undo_BeginBlock()
  place_tempo(pos, target)
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock("Tap tempo", -1)
end

-------------------------------------------------------------------------------
-- 5. GLIDE LOOP
-------------------------------------------------------------------------------

local function start_glide(target)
  local pos = change_position()
  local start_bpm = tempo_at(pos)
  if math.abs(start_bpm - target) <= EPSILON then
    reaper.SetExtState(EXT, "target", "", false)
    return
  end

  -- The glide ramps its own marker at the start position; it is found again
  -- by time position each frame, so later marker edits cannot redirect it.
  local glide_pos = place_tempo(pos, start_bpm)
  reaper.UpdateTimeline()

  local function glide_marker()
    local idx = marker_at(glide_pos)
    if idx < 0 then return nil end
    local ok, timepos, _, _, bpm, num, denom, linear = reaper.GetTempoTimeSigMarker(0, idx)
    if not ok then return nil end
    return idx, timepos, bpm, num, denom, linear
  end

  local last_time = reaper.time_precise()

  local function step()
    local now = reaper.time_precise()
    local dt = now - last_time
    last_time = now

    local idx, timepos, current, num, denom, linear = glide_marker()
    if not idx then return end -- marker was deleted mid-glide
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
    reaper.SetTempoTimeSigMarker(0, idx, timepos, -1, -1, new_bpm, num, denom, linear)
    reaper.UpdateTimeline()
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
    -- A glide left over from glide mode was just terminated by this press:
    -- give the tempo it reached its undo point before changing it again.
    if reaper.GetExtState(EXT, "target") ~= "" then
      reaper.SetExtState(EXT, "target", "", false)
      reaper.Undo_OnStateChange("Tap tempo slew")
    end
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
