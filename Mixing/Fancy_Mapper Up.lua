-- @description Fancy Mapper Up
-- @author Fancy Scripts
-- @version 5.1.0
-- @changelog
--   + v5.1: Powered by shared MapperEngine
--   + v5.1: Added Width (auto-stereo pan), Multi-CC, Velocity, Track Nav, Marker, Transient, Item Slip
-- @about
--   Context-sensitive dial control for hardware dials and rotary encoders (clockwise / up).
--   Reads all configuration from Fancy Mapper Settings.
--   Requirements: REAPER 7.0+, SWS Extension (optional for Grid scrub)
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local MapperEngine = require("mapper_engine")

local function main()
  MapperEngine.run(1)
end

main()
