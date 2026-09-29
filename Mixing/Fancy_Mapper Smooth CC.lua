-- @description Fancy Mapper Smooth CC
-- @author Fancy Scripts
-- @version 5.2.0
-- @changelog
--   + Initial release: Convert CC lane events in active take to smooth linear curves
-- @about
--   Converts stepped or square MIDI CC events in the active take or selected item
--   into smooth linear ramps (shape = 1) for seamless vector playback.
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

-------------------------------------------------------------------------------
-- 2. MAIN EXECUTION
-------------------------------------------------------------------------------
local function main()
  local count = MapperEngine.linearize_take_cc(nil, nil)
  if reaper.TrackCtl_SetToolTip then
    local mx, my = reaper.GetMousePosition()
    if count > 0 then
      local tip = string.format("Fancy Mapper: Smoothed %d CC points to Linear", count)
      reaper.TrackCtl_SetToolTip(tip, mx + 16, my + 16, true)
    else
      reaper.TrackCtl_SetToolTip("Fancy Mapper: No MIDI CC events found to smooth", mx + 16, my + 16, true)
    end
  end
end

main()
