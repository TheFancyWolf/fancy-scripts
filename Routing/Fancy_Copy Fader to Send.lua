-- @description Fancy Copy Fader to Send
-- @author Fancy Scripts
-- @version 1.1.1
-- @changelog
--   # Only copy fader volume to pre-fader sends (post-fader sends were attenuated twice)
--   # No empty undo point when nothing changes
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

  -- 2. Collect changes first so no empty undo point is created.
  --    Only pre-fader sends (I_SENDMODE 1 = pre-FX, 3 = pre-fader/post-FX)
  --    are updated: a post-fader send (0) already follows the fader, so
  --    copying D_VOL into it would apply the fader attenuation twice.
  local changes = {}
  local count_sel_tracks = reaper.CountSelectedTracks(0)
  for i = 0, count_sel_tracks - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    if track and reaper.GetTrackNumSends(track, 0) > send_idx then
      local mode = reaper.GetTrackSendInfo_Value(track, 0, send_idx, "I_SENDMODE")
      if mode == 1 or mode == 3 then
        local main_vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
        local send_vol = reaper.GetTrackSendInfo_Value(track, 0, send_idx, "D_VOL")
        if send_vol ~= main_vol then
          changes[#changes + 1] = { track = track, vol = main_vol }
        end
      end
    end
  end

  if #changes == 0 then return end

  -- 3. Apply inside a single undo block
  reaper.PreventUIRefresh(1)
  Utils.undo_block("Copy Fader to Send " .. (send_idx + 1), function()
    for _, c in ipairs(changes) do
      reaper.SetTrackSendInfo_Value(c.track, 0, send_idx, "D_VOL", c.vol)
    end
  end)
  reaper.PreventUIRefresh(-1)
end

-------------------------------------------------------------------------------
-- 3. ENTRY POINT
-------------------------------------------------------------------------------
main()
