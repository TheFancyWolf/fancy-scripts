-- @description Fancy Mapper Daemon
-- @author Fancy Scripts
-- @version 5.2.0
-- @changelog
--   + Initial release: 60 Hz background slew engine for universal Smooth Dial
-- @about
--   Background consumer daemon for Fancy Mapper.
--   Interpolates parameter movements at 60 Hz for smooth, analog-style
--   continuous control (Volume, Pan, Width, FX, MIDI CC, Scrub, Item Slip).
--   Auto-wakes when you turn the dial and auto-sleeps after 10 seconds of inactivity.
--   Requirements: REAPER 7.0+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

-------------------------------------------------------------------------------
-- 1. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local MapperEngine = require("mapper_engine")
local EXTSTATE_SECTION = "FancyMapper"

-------------------------------------------------------------------------------
-- 2. ACTION TOGGLE STATE
-------------------------------------------------------------------------------
local _, _, sec_id, cmd_id = reaper.get_action_context()

local function set_toggle_state(state)
  if sec_id and cmd_id and cmd_id > 0 then
    reaper.SetToggleCommandState(sec_id, cmd_id, state)
    reaper.RefreshToolbar2(sec_id, cmd_id)
  end
end

-------------------------------------------------------------------------------
-- 3. MAIN RUNNER (60 Hz SLEW ENGINE)
-------------------------------------------------------------------------------
local function main()
  local now = reaper.time_precise()
  local last_ping = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "daemon_ping") or "0") or 0

  -- If already running and invoked manually (e.g. toolbar click), toggle off
  if (now - last_ping) < 1.0 then
    reaper.SetExtState(EXTSTATE_SECTION, "daemon_stop", "1", false)
    return
  end

  set_toggle_state(1)
  reaper.SetExtState(EXTSTATE_SECTION, "daemon_ping", tostring(now), false)
  reaper.SetExtState(EXTSTATE_SECTION, "daemon_stop", "0", false)

  local last_time = now
  local last_activity = now

  local function cleanup()
    reaper.SetExtState(EXTSTATE_SECTION, "daemon_ping", "0", false)
    set_toggle_state(0)
  end

  reaper.atexit(cleanup)

  local function step()
    -- Check for stop signal
    if reaper.GetExtState(EXTSTATE_SECTION, "daemon_stop") == "1" then
      reaper.SetExtState(EXTSTATE_SECTION, "daemon_stop", "0", false)
      cleanup()
      return
    end

    local t = reaper.time_precise()
    reaper.SetExtState(EXTSTATE_SECTION, "daemon_ping", tostring(t), false)

    local dt = math.min(0.1, math.max(0.001, t - last_time))
    last_time = t

    local is_busy = MapperEngine.process_smooth_step(dt)

    local last_tick = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "smooth_last_tick") or "0") or 0
    if is_busy or (t - last_tick) < 0.5 then
      last_activity = t
    end

    -- Option A: Auto-sleep after 10 seconds of inactivity
    if (t - last_activity) > 10.0 then
      cleanup()
      return
    end

    reaper.defer(step)
  end

  reaper.defer(step)
end

main()
