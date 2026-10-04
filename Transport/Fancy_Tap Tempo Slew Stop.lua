-- @description Fancy Tap Tempo Slew Stop
-- @author Fancy Scripts
-- @version 1.0.0
-- @changelog
--   + Initial release
-- @about
--   Stops a running Fancy Tap Tempo Slew glide. The tempo stays where it
--   is and the tap history is cleared, so the next tap starts fresh.
--   Requirements: REAPER 7.03+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

-------------------------------------------------------------------------------
-- 1. MAIN
-------------------------------------------------------------------------------

local EXT = "FancyTapTempoSlew"

local function main()
  -- The glide loop sees this flag on its next frame and exits.
  reaper.SetExtState(EXT, "stop", "1", false)
  reaper.SetExtState(EXT, "taps", "", false)
  reaper.SetExtState(EXT, "target", "", false)
end

main()
