-- @description Fancy Mapper Button 2
-- @author Fancy Scripts
-- @version 3.0.0
-- @changelog
--   + v3: Initial release — mode-aware context button
-- @about
--   Context-sensitive button whose action changes based on the current
--   Fancy Mapper mode (Scrub / FX / Pan). Configure actions in the
--   Fancy Mapper Settings window. Assign this script to any button on
--   your hardware controller.
--   Requirements: REAPER 7.0+
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

-------------------------------------------------------------------------------
-- 1. CONFIGURATION
-------------------------------------------------------------------------------

local BUTTON_NUM = 2

-------------------------------------------------------------------------------
-- 2. MAIN
-------------------------------------------------------------------------------

local function main()
  -- Check if this button is enabled
  local enabled = reaper.GetExtState("FancyMapper", "btn" .. BUTTON_NUM .. "_enabled")
  if enabled ~= "1" then return end

  -- Resolve current mode
  local mode = reaper.GetExtState("FancyMapper", "mode")
  if mode == "" then
    mode = reaper.GetExtState("FancyMapper", "default_mode")
  end
  if mode == "" then mode = "scrub" end

  -- Look up action for this button × mode
  local key = "btn" .. BUTTON_NUM .. "_" .. mode
  local cmd_str = reaper.GetExtState("FancyMapper", key)
  if cmd_str == "" then return end

  -- Resolve command ID and execute
  local cmd_id = tonumber(cmd_str)
  if not cmd_id then
    cmd_id = reaper.NamedCommandLookup(cmd_str)
  end
  if cmd_id and cmd_id ~= 0 then
    reaper.Main_OnCommand(cmd_id, 0)
  end
end

main()
