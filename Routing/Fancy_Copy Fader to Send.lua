-- @description Fancy Copy Fader to Send
-- @author Fancy Scripts
-- @version 1.1.0
-- @changelog
--   + Migrated to shared _lib/ modules
-- @about
--   Sets specified Send volume to match the Main Track Fader.
--   Useful for copying your current Main Mix to a Pre-Fader Headphone Send.
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

-------------------------------------------------------------------------------
-- 1. BOOTSTRAP & MODULES
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Utils = require("utils")

-------------------------------------------------------------------------------
-- 2. MAIN LOGIC
-------------------------------------------------------------------------------
local function main()
  -- 1. Prompt user for which Send to overwrite (default is Send 1)
  local ret, user_input = reaper.GetUserInputs("Copy Fader to Send", 1, "Target Send (1-based):", "1")
  if not ret then return end -- User cancelled

  local send_idx = tonumber(user_input)
  if not send_idx or send_idx < 1 then
    reaper.ShowMessageBox("Invalid send index.", "Error", 0)
    return
  end

  -- Convert to 0-based index for API
  send_idx = math.floor(send_idx) - 1

  -- 2. Modify selected tracks inside undo block
  Utils.undo_block("Copy Fader to Send " .. (send_idx + 1), function()
    local count_sel_tracks = reaper.CountSelectedTracks(0)
    for i = 0, count_sel_tracks - 1 do
      local track = reaper.GetSelectedTrack(0, i)
      if track and reaper.GetTrackNumSends(track, 0) > send_idx then
        -- Get the Main Track Volume
        local main_vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
        -- Set the Send Volume to match
        reaper.SetTrackSendInfo_Value(track, 0, send_idx, "D_VOL", main_vol)
      end
    end
  end)
end

-------------------------------------------------------------------------------
-- 3. ENTRY POINT
-------------------------------------------------------------------------------
main()
