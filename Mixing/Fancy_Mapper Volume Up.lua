-- @description Fancy Mapper Volume Up
-- @author Fancy Scripts
-- @version 3.0.0
-- @changelog
--   + v3: Settings-driven config (reads from Fancy Mapper Settings)
--   + v3: Controller-agnostic design
-- @about
--   Nudges selected track(s) volume up by a configurable dB increment.
--   Designed for hardware dials and rotary encoders that send rapid
--   keyboard events. Includes timestamp-based throttling to prevent
--   event queue buildup from causing runaway fader movement.
--   Configure step size and throttle in Fancy Mapper Settings.
--   Requirements: REAPER 7.0+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

-------------------------------------------------------------------------------
-- 1. CONFIGURATION (from ExtState)
-------------------------------------------------------------------------------

local STEP_DB     = tonumber(reaper.GetExtState("FancyMapper", "vol_step_db") or "") or 1.0
local THROTTLE_MS = tonumber(reaper.GetExtState("FancyMapper", "throttle_ms") or "") or 60
local MAX_DB      = 12.0

-------------------------------------------------------------------------------
-- 2. THROTTLE
-------------------------------------------------------------------------------

local function should_run()
  local now = reaper.time_precise() * 1000
  local last = tonumber(reaper.GetExtState("FancyMapper", "last_vol_up") or "0") or 0
  if now - last < THROTTLE_MS then
    return false
  end
  reaper.SetExtState("FancyMapper", "last_vol_up", tostring(now), false)
  return true
end

-------------------------------------------------------------------------------
-- 3. MAIN
-------------------------------------------------------------------------------

local function main()
  if not should_run() then return end

  local count = reaper.CountSelectedTracks(0)
  if count == 0 then return end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    if track then
      local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
      local db = 20 * math.log(vol, 10)
      db = math.min(db + STEP_DB, MAX_DB)
      local new_vol = 10 ^ (db / 20)
      reaper.SetMediaTrackInfo_Value(track, "D_VOL", new_vol)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Fancy Mapper: Volume Up", -1)
end

main()
