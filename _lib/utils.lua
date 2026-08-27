-- Fancy Scripts — Shared Utilities
-- Common helpers for REAPER scripting: dependency checks, undo blocks, math.
-- Loaded via: local Utils = require("utils")

local Utils = {}

-------------------------------------------------------------------------------
-- 1. PATH HELPERS
-------------------------------------------------------------------------------

--- Returns the directory of the calling script (the file that called this function).
--- Uses debug.getinfo to resolve the absolute path at runtime.
--- @return string|nil  Absolute directory path with trailing separator, or nil
function Utils.script_dir()
  local info = debug.getinfo(2, "S")
  if not info or not info.source then return nil end
  return info.source:match([[^@?(.*[\/])[^\/]-$]])
end

-------------------------------------------------------------------------------
-- 2. DEPENDENCY CHECKS
-------------------------------------------------------------------------------

--- Checks whether the ReaImGui extension is installed.
--- Shows a user-friendly install message if missing.
--- @param script_name string  Display name for the error dialog title
--- @return boolean  true if ReaImGui is available, false otherwise
function Utils.check_imgui(script_name)
  if reaper.ImGui_CreateContext then return true end
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    (script_name or "Fancy Scripts") .. " -- Missing ReaImGui", 0)
  return false
end

--- Checks whether the SWS extension is installed.
--- Shows a user-friendly install message if missing.
--- @param script_name string  Display name for the error dialog title
--- @return boolean  true if SWS is available, false otherwise
function Utils.check_sws(script_name)
  if reaper.CF_GetSWSVersion then return true end
  reaper.ShowMessageBox(
    "This script requires the SWS extension.\n\n"
    .. "Download from https://www.sws-extension.org/",
    (script_name or "Fancy Scripts") .. " -- Missing SWS", 0)
  return false
end

-------------------------------------------------------------------------------
-- 3. UNDO HELPERS
-------------------------------------------------------------------------------

--- Wraps a function call in an undo block.
--- Calls Undo_BeginBlock, executes fn, then Undo_EndBlock + UpdateArrange.
--- @param name string  Short description for the undo history
--- @param fn function  The function to execute inside the undo block
--- @return any  Whatever fn() returns
function Utils.undo_block(name, fn)
  reaper.Undo_BeginBlock()
  local result = fn()
  reaper.Undo_EndBlock(name, -1)
  reaper.UpdateArrange()
  return result
end

-------------------------------------------------------------------------------
-- 4. TRACK HELPERS
-------------------------------------------------------------------------------

--- Returns an array of all currently selected track pointers.
--- @return table  Array of MediaTrack userdata (may be empty)
function Utils.get_selected_tracks()
  local tracks = {}
  local count = reaper.CountSelectedTracks(0)
  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    if track then
      tracks[#tracks + 1] = track
    end
  end
  return tracks
end

--- Returns the name of a track, or a fallback string if unnamed.
--- @param track userdata  MediaTrack pointer
--- @param fallback string|nil  Fallback if no name (default: "Track N")
--- @return string
function Utils.get_track_name(track, fallback)
  if not track then return fallback or "Unknown" end
  local _, name = reaper.GetTrackName(track)
  if not name or name == "" then
    local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    return fallback or ("Track " .. math.floor(idx))
  end
  return name
end

-------------------------------------------------------------------------------
-- 5. MATH HELPERS
-------------------------------------------------------------------------------

--- Clamps a value between min and max.
--- @param val number
--- @param lo number  Minimum value
--- @param hi number  Maximum value
--- @return number
function Utils.clamp(val, lo, hi)
  if val < lo then return lo end
  if val > hi then return hi end
  return val
end

--- Linear interpolation between two values.
--- @param a number  Start value
--- @param b number  End value
--- @param t number  Interpolation factor (0–1)
--- @return number
function Utils.lerp(a, b, t)
  return a + (b - a) * t
end

--- Formats a raw volume value (0–4+) as a dB string.
--- @param val number  Volume scalar (1.0 = 0 dB)
--- @return string  Formatted string like "-6.0 dB" or "-inf dB"
function Utils.format_db(val)
  if not val or val <= 0 then return "-inf dB" end
  local db = 20 * math.log(val, 10)
  return string.format("%.1f dB", db)
end

return Utils
