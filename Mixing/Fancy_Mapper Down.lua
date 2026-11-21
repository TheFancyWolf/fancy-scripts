-- @description Fancy Mapper Down
-- @author Fancy Scripts
-- @version 5.1.1
-- @changelog
--   The shared library files (_lib) now come from the "Fancy Scripts Library" package: install it once from ReaPack
-- @about
--   Context-sensitive dial control for hardware dials and rotary encoders (counter-clockwise / down).
--   Reads all configuration from Fancy Mapper Settings.
--   Requirements: REAPER 7.0+, SWS Extension (optional for Grid scrub), Fancy Scripts Library
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path
if not reaper.file_exists(script_dir .. "../_lib/mapper_engine.lua") then
  reaper.ShowMessageBox(
    "This script needs the \"Fancy Scripts Library\" package.\n\n"
    .. "Install it via Extensions > ReaPack > Browse Packages, then run this script again.",
    "Fancy Mapper Down -- Missing library", 0)
  return
end

local MapperEngine = require("mapper_engine")

local function main()
  MapperEngine.run(-1)
end

main()
