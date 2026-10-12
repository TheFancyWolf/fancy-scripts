-- @description Fancy Cheat Sheet
-- @author Fancy Scripts
-- @version 1.0.0
-- @changelog
--   + Initial release
-- @about
--   Builds a printable cheat sheet for playing a keyswitched part live.
--   A new row starts only when there is something new to play (an
--   articulation switch or a new figure). Each row shows the time, the full
--   lyrics until the next row, what each hand plays, and the articulation
--   name where it changes. Key, Run, Gliss and Trill values print at the top.
--
--   Select the MIDI track (keyswitches + played notes) and the audio track
--   (a recording with vocals), then run the action. The choice is remembered
--   per project, so later runs need no selection. The sheet opens in your
--   browser; print it with Cmd+P.
--
--   Keyswitches are the pitches you have named in the MIDI editor's piano
--   roll (e.g. LEG, SHORT). Lyrics are transcribed from the audio with
--   Whisper and cached, so re-runs are fast. For correct wording, put the
--   song's lyrics in "Cheat Sheets/<Project>.lyrics.txt" (one sung line per
--   line; a Genius paste works): its wording is used, lines Whisper missed
--   are filled in, and heard lines that match nothing are left out.
--
--   The sheet is written to "Cheat Sheets/<Project>.md" next to the project.
--   Edit that Markdown file freely and run the action again: your edits are
--   kept, new switches are added, and rows that no longer match the MIDI are
--   marked for you to check. Add "(hide)" to a row's heading to leave it off
--   the printout.
--
--   Under an instruction, "keys B-E: D C# C" draws a small keyboard with
--   dots on those keys ("line" numbers them in playing order). Set
--   "auto_keys: yes" at the top of the .md to generate a first pass.
--
--   In the browser, the Show bar at the top hides lyrics, part notes or
--   keyboards before you print (the bar itself does not print).
--
--   After hand edits you don't need REAPER: double-click "Render Cheat
--   Sheets.command" in the Cheat Sheets folder, pick the songs (edited ones
--   are preselected), and they are turned into HTML (without changing the
--   .md) and opened.
--
--   Requirements: REAPER 7.0+, macOS on Apple Silicon, Python 3.9+ with the
--   packages mlx-whisper and markdown, and ffmpeg (brew install ffmpeg).
--   One-time setup in Terminal:
--     python3 -m venv ~/Library/Application\ Support/REAPER/Data/Fancy\ Cheat\ Sheet/venv
--     ~/Library/Application\ Support/REAPER/Data/Fancy\ Cheat\ Sheet/venv/bin/pip install mlx-whisper markdown
--   The first transcription downloads the Whisper model (about 1.6 GB).
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua
--   [nomain] ../_lib/cheatsheet/*.py

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local JSON = require("json")

-------------------------------------------------------------------------------
-- 1. CONSTANTS
-------------------------------------------------------------------------------

local SCRIPT_NAME = "Fancy Cheat Sheet"
local EXT = "FancyCheatSheet"
local HELPER = script_dir .. "../_lib/cheatsheet/fancy_cheatsheet.py"
local VENV_DIR = reaper.GetResourcePath() .. "/Data/Fancy Cheat Sheet/venv"
local PYTHON_CANDIDATES = {
  VENV_DIR .. "/bin/python3",
  "/opt/homebrew/bin/python3",
  "/usr/local/bin/python3",
  "/usr/bin/python3",
}
local POLL_INTERVAL = 0.25     -- seconds between checks for the result
local TIMEOUT = 20 * 60        -- seconds; covers the first model download
local BUSY_STALE = 5           -- seconds; an older heartbeat means no run is active

-------------------------------------------------------------------------------
-- 2. SMALL HELPERS
-------------------------------------------------------------------------------

local function msg(text)
  reaper.ShowMessageBox(text, SCRIPT_NAME, 0)
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function write_file(path, text)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local function tail(text, n)
  local lines = {}
  for line in (text or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  local first = math.max(1, #lines - n + 1)
  return table.concat(lines, "\n", first)
end

local function open_in_browser(path)
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(path)
  else
    os.execute('open "' .. path .. '"')
  end
end

local function setup_command()
  return 'python3 -m venv "' .. VENV_DIR .. '"\n"'
      .. VENV_DIR .. '/bin/pip" install mlx-whisper markdown'
end

-------------------------------------------------------------------------------
-- 3. TRACKS
-------------------------------------------------------------------------------

--- Returns "midi", "audio" or nil, from the active takes of the track's items.
local function track_kind(track)
  local has_midi, has_audio = false, false
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = item and reaper.GetActiveTake(item)
    if take then
      if reaper.TakeIsMIDI(take) then has_midi = true else has_audio = true end
    end
  end
  if has_midi then return "midi" end
  if has_audio then return "audio" end
  return nil
end

local function track_by_guid(guid)
  if not guid or guid == "" then return nil end
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if track and reaper.GetTrackGUID(track) == guid then return track end
  end
  return nil
end

--- Resolves the MIDI and audio tracks from the selection or the saved choice.
--- Returns midi_track, audio_track (may be nil), or nil plus an error message.
local function resolve_tracks()
  local midi, audio
  local count = reaper.CountSelectedTracks(0)
  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local kind = track and track_kind(track)
    if kind == "midi" and not midi then midi = track
    elseif kind == "audio" and not audio then audio = track
    end
  end

  if midi then
    reaper.Undo_BeginBlock()
    reaper.SetProjExtState(0, EXT, "midi_track", reaper.GetTrackGUID(midi))
    reaper.SetProjExtState(0, EXT, "audio_track", audio and reaper.GetTrackGUID(audio) or "")
    reaper.Undo_EndBlock("Cheat Sheet: remember tracks", -1)
    return midi, audio
  end

  local _, midi_guid = reaper.GetProjExtState(0, EXT, "midi_track")
  local _, audio_guid = reaper.GetProjExtState(0, EXT, "audio_track")
  midi = track_by_guid(midi_guid)
  if midi then return midi, track_by_guid(audio_guid) end

  return nil, "Select the MIDI track (keyswitches and played notes) and the "
    .. "audio track with the vocals, then run " .. SCRIPT_NAME .. " again.\n\n"
    .. "Your choice is remembered for this project."
end

-------------------------------------------------------------------------------
-- 4. COLLECTING PROJECT DATA
-------------------------------------------------------------------------------

local function collect_notes(track)
  local notes, names, first, last = {}, {}, math.huge, -math.huge
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take)
        and reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local stop = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      first, last = math.min(first, pos), math.max(last, stop)
      local _, note_count = reaper.MIDI_CountEvts(take)
      for n = 0, note_count - 1 do
        local ok, _, muted, sppq, eppq, chan, pitch = reaper.MIDI_GetNote(take, n)
        if ok and not muted then
          local s = reaper.MIDI_GetProjTimeFromPPQPos(take, sppq)
          local e = math.min(reaper.MIDI_GetProjTimeFromPPQPos(take, eppq), stop)
          if s >= pos - 0.001 and s < stop then
            notes[#notes + 1] = { pitch, s, e }
            if names[pitch] == nil then
              local name = reaper.GetTrackMIDINoteNameEx(0, track, pitch, chan)
              names[pitch] = (name and name ~= "") and name or false
            end
          end
        end
      end
    end
  end
  local keyswitches = {}
  for pitch, name in pairs(names) do
    if name then keyswitches[#keyswitches + 1] = { pitch, name } end
  end
  table.sort(keyswitches, function(a, b) return a[1] < b[1] end)
  return notes, keyswitches, first, last
end

--- Returns the longest unmuted audio item's file and timing, or nil.
local function collect_audio(track)
  if not track then return nil end
  local best
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = item and reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take)
        and reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if not best or len > best.item_len then
        local source = reaper.GetMediaItemTake_Source(take)
        local parent = source and reaper.GetMediaSourceParent(source)
        local file = (parent or source) and reaper.GetMediaSourceFileName(parent or source) or ""
        if file ~= "" then
          best = {
            file = file,
            item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
            item_len = len,
            offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
            rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
          }
        end
      end
    end
  end
  return best
end

-------------------------------------------------------------------------------
-- 5. PYTHON
-------------------------------------------------------------------------------

local function find_python()
  local saved = reaper.GetExtState(EXT, "python")
  if saved ~= "" and reaper.file_exists(saved) then return saved end
  for _, path in ipairs(PYTHON_CANDIDATES) do
    if reaper.file_exists(path) then return path end
  end
  return nil
end

--- Explains the one-time setup and offers to pick an existing Python.
local function python_setup_help(reason)
  local text = reason .. "\n\nOne-time setup: paste these two lines into Terminal:\n\n"
    .. setup_command()
    .. "\n\nThen run " .. SCRIPT_NAME .. " again.\n\n"
    .. "Already have a Python with mlx-whisper and markdown? Click Yes to choose it."
  if reaper.CF_SetClipboard then
    reaper.CF_SetClipboard(setup_command())
    text = text .. "\n(The commands are on your clipboard.)"
  end
  if reaper.ShowMessageBox(text, SCRIPT_NAME .. " -- Setup needed", 4) == 6 then
    local ok, path = reaper.GetUserFileNameForRead(VENV_DIR .. "/bin/python3", "Choose python3", "")
    if ok and path ~= "" then
      reaper.SetExtState(EXT, "python", path, true)
      msg("Saved. Run " .. SCRIPT_NAME .. " again.")
    end
  end
end

-------------------------------------------------------------------------------
-- 6. WAITING FOR THE RESULT
-------------------------------------------------------------------------------

local function finish(job)
  reaper.SetExtState(EXT, "busy", "", false)
  local text = read_file(job.result)
  local result = text and JSON.decode(text)
  if not result then
    msg("The cheat sheet helper stopped without a result.\n\nLast lines of the log:\n"
      .. tail(read_file(job.log), 8))
    return
  end
  if not result.ok then
    if result.code == "missing_deps" then
      python_setup_help(result.error or "A Python package is missing.")
    else
      msg((result.error or "Unknown error.") .. "\n\nLog: " .. job.log)
    end
    return
  end
  reaper.Help_Set(string.format("Cheat Sheet: %d rows, %d switches -- opened in your browser.",
    result.rows or 0, result.switches or 0), true)
  open_in_browser(result.html)
  if result.warnings and #result.warnings > 0 then
    msg(table.concat(result.warnings, "\n\n"))
  end
end

local function poll(job)
  if reaper.file_exists(job.result) then
    finish(job)
    return
  end
  if reaper.time_precise() - job.started > TIMEOUT then
    reaper.SetExtState(EXT, "busy", "", false)
    msg("The cheat sheet took too long and was abandoned.\n\nLog: " .. job.log)
    return
  end
  if reaper.time_precise() - job.last_poll >= POLL_INTERVAL then
    job.last_poll = reaper.time_precise()
    reaper.SetExtState(EXT, "busy", tostring(os.time()), false)
    local status = read_file(job.status)
    local dots = string.rep(".", math.floor(job.last_poll * 2) % 4)
    reaper.Help_Set((status and status ~= "" and status or "Cheat Sheet: working") .. dots, true)
  end
  reaper.defer(function() poll(job) end)
end

-------------------------------------------------------------------------------
-- 7. MAIN
-------------------------------------------------------------------------------

local function main()
  local busy = tonumber(reaper.GetExtState(EXT, "busy"))
  if busy and os.time() - busy < BUSY_STALE then
    msg("A cheat sheet is still being built. Wait for it to open, then try again.")
    return
  end

  local _, project_file = reaper.EnumProjects(-1)
  if not project_file or project_file == "" then
    msg("Save the project first. The cheat sheet is written next to the project file.")
    return
  end
  local project_dir = project_file:match("^(.*)[/\\]")
  local song = project_file:match("([^/\\]+)%.[Rr][Pp][Pp]$") or "Cheat Sheet"

  local midi_track, audio_track_or_err = resolve_tracks()
  if not midi_track then
    msg(audio_track_or_err)
    return
  end
  local audio_track = audio_track_or_err

  local notes, keyswitches, first, last = collect_notes(midi_track)
  if #notes == 0 then
    msg("The MIDI track has no notes.")
    return
  end
  if #keyswitches == 0 then
    msg("No keyswitch names found on the MIDI track.\n\n"
      .. "Name your keyswitch notes in the MIDI editor's piano roll "
      .. "(e.g. LEG, SHORT), then run " .. SCRIPT_NAME .. " again.")
    return
  end
  local audio = collect_audio(audio_track)
  if audio then
    first = math.min(first, audio.item_pos)
    last = math.max(last, audio.item_pos + audio.item_len)
  end

  local python = find_python()
  if not python then
    python_setup_help("Python 3 was not found.")
    return
  end
  if not reaper.file_exists(HELPER) then
    msg("The helper file is missing:\n" .. HELPER .. "\n\nReinstall " .. SCRIPT_NAME .. " from ReaPack.")
    return
  end

  local out_dir = project_dir .. "/Cheat Sheets"
  local cache_dir = out_dir .. "/.cache"
  reaper.RecursiveCreateDirectory(cache_dir, 0)
  local base = cache_dir .. "/" .. song
  local job = {
    input = base .. ".input.json",
    result = base .. ".result.json",
    status = base .. ".status",
    log = base .. ".log",
    started = reaper.time_precise(),
    last_poll = 0,
  }
  os.remove(job.result)
  write_file(job.status, "")

  local input = {
    song = song,
    out_dir = out_dir,
    origin = first,
    length = last - first,
    keyswitches = keyswitches,
    notes = notes,
    audio = audio or false,
  }
  if not write_file(job.input, JSON.encode(input)) then
    msg("Could not write to:\n" .. cache_dir)
    return
  end

  local cmd = string.format('"%s" "%s" "%s" "%s"', python, HELPER, job.input, job.log)
  reaper.SetExtState(EXT, "busy", tostring(os.time()), false)
  reaper.ExecProcess(cmd, -1)
  reaper.Help_Set("Cheat Sheet: starting…", true)
  reaper.defer(function() poll(job) end)
end

main()
