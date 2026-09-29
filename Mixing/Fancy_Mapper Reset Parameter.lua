-- @description Fancy Mapper Reset Parameter
-- @author Fancy Scripts
-- @version 5.1.0
-- @changelog
--   + v5.1: Context-aware reset across all modes (FX default, pan center, volume 0dB, width 100%, MIDI vel, MIDI CC, item slip)
-- @about
--   Resets the active parameter based on current Fancy Mapper mode.
--   - FX: resets last-touched FX parameter to default value.
--   - Pan: centers track pan (0%).
--   - Volume: resets track volume to 0.0 dB.
--   - Width: resets track width to 100% stereo.
--   - MIDI Velocity: resets selected note velocities to default (96).
--   - MIDI CC: resets selected CC events to default (0 or 64).
--   - Item Slip: resets item audio offset to 0.
--   Assign to a Fancy Mapper button slot or any keyboard shortcut.
--   Requirements: REAPER 7.0+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local MapperEngine = require("mapper_engine")

local function main()
  MapperEngine.reset_current_context()
end

main()
