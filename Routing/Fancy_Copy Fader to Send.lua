-- @description Fancy Copy Fader to Send
-- @author Fancy Scripts
-- @version 1.0.0
-- @changelog
--   + Initial ReaPack release
-- @about
--   Sets specified Send volume to match the Main Track Fader.
--   Useful for copying your current Main Mix to a Pre-Fader Headphone Send.
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

function main()
    -- 1. Prompt user for which Send to overwrite (default is Send 1)
    local ret, user_input = reaper.GetUserInputs("Copy Fader to Send", 1, "Target Send (1-based):", "1")
    
    if not ret then return end -- User cancelled
    
    local send_idx = tonumber(user_input)
    if not send_idx or send_idx < 1 then 
        reaper.ShowMessageBox("Invalid send index.", "Error", 0)
        return 
    end
    
    -- Convert to 0-based index for API
    send_idx = send_idx - 1 

    reaper.Undo_BeginBlock()
    
    -- 2. Loop through selected tracks
    local count_sel_tracks = reaper.CountSelectedTracks(0)
    
    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        
        -- Check if the track actually has a send at this index
        if reaper.GetTrackNumSends(track, 0) > send_idx then
            -- Get the Main Track Volume
            local main_vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
            
            -- Set the Send Volume to match
            reaper.SetTrackSendInfo_Value(track, 0, send_idx, "D_VOL", main_vol)
        end
    end

    reaper.Undo_EndBlock("Copy Fader to Send " .. (send_idx + 1), -1)
    reaper.UpdateArrange()
end

main()
