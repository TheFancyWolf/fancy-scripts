-- @description Fancy Mapper Calibrate Tick
-- @author Fancy Scripts
-- @version 3.0.0
-- @changelog
--   + v3: Controller-agnostic language
-- @about
--   Companion to the Fancy Mapper Settings calibration section.
--   Assign THIS script to your dial's clockwise shortcut.
--   Each invocation increments the tick counter displayed in Settings.
--   Requirements: REAPER 7.0+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

local function main()
  local count = tonumber(reaper.GetExtState("FancyMapper", "calibrate_count") or "0") or 0
  reaper.SetExtState("FancyMapper", "calibrate_count", tostring(count + 1), false)
end

main()
