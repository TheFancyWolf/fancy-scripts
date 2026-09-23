-- @description Fancy Pitch Correct
-- @author Fancy Scripts
-- @version 1.1.0
-- @changelog
--   + Arrow nudging: Up/Down = ±1 semitone, Shift+Up/Down = ±10 cents
--   + Left/Right arrow: Jump selection to previous/next note
--   + S key or double-click pitch zone: Snap note to nearest semitone (0¢)
--   + R / Backspace / Delete: Reset selected note to [Untouched]
--   + Spacebar passthrough: Triggers REAPER Play/Stop from ImGui window
--   + Info icon in toolbar with keyboard shortcuts tooltip
-- @about
--   Native Lua pitch correction and tracking.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Pitch Correct -- Missing ReaImGui", 0)
  return
end

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")
local JSON  = require("json")

local ctx = reaper.ImGui_CreateContext('Fancy Pitch Correct')

local VOCAL_RANGES = {
  { name = "Generic Vocal", min = 65,  max = 1000 },
  { name = "Soprano",       min = 250, max = 1200 },
  { name = "Alto",          min = 170, max = 800  },
  { name = "Tenor",         min = 130, max = 500  },
  { name = "Bass",          min = 80,  max = 350  }
}

local DETECTION_MODES = {
  { name = "Clean / Strict",   threshold = 0.08 },
  { name = "Standard",         threshold = 0.15 },
  { name = "Breathy / Lenient", threshold = 0.25 }
}

local QUALITY_MODES = {
  { name = "High Quality (Offline)", block = 2048, hop = 256 },
  { name = "Standard (Realtime)",    block = 1024, hop = 512 },
  { name = "Low Latency",            block = 512,  hop = 256 }
}

-- Discover available pitch shift modes at startup
local PITCH_SHIFT_MODES = {}
local DEFAULT_PITCH_MODE_IDX = 1
do
  local mode_idx = 0
  while true do
    local retval, name = reaper.EnumPitchShiftModes(mode_idx)
    if not retval or not name or name == "" then break end
    local submodes = {}
    local sub_idx = 0
    while true do
      local sub_name = reaper.EnumPitchShiftSubModes(mode_idx, sub_idx)
      if not sub_name or sub_name == "" then break end
      local packed = (mode_idx << 16) | sub_idx
      table.insert(submodes, { name = sub_name, value = packed })
      -- Detect Soloist Monophonic as default
      if name:lower():find("soloist") and sub_name:lower():find("mono") then
        DEFAULT_PITCH_MODE_IDX = #PITCH_SHIFT_MODES + 1
      end
      sub_idx = sub_idx + 1
    end
    if #submodes > 0 then
      table.insert(PITCH_SHIFT_MODES, { name = name, submodes = submodes })
    else
      local packed = (mode_idx << 16)
      table.insert(PITCH_SHIFT_MODES, { name = name, submodes = { { name = "Default", value = packed } } })
    end
    mode_idx = mode_idx + 1
  end
end

local PITCHMODE_FLAT = { { name = "Project Default", value = -1 } }
for _, mode in ipairs(PITCH_SHIFT_MODES) do
  for _, sub in ipairs(mode.submodes) do
    table.insert(PITCHMODE_FLAT, { name = mode.name .. " - " .. sub.name, value = sub.value })
  end
end

-- Find the Soloist Monophonic entry in the flat list
for i, entry in ipairs(PITCHMODE_FLAT) do
  if entry.name:lower():find("soloist") and entry.name:lower():find("mono") then
    DEFAULT_PITCH_MODE_IDX = i
    break
  end
end

-- Will be applied to state after state table is defined
local INITIAL_PITCHMODE_IDX = DEFAULT_PITCH_MODE_IDX
local INITIAL_PITCHMODE_VALUE = PITCHMODE_FLAT[DEFAULT_PITCH_MODE_IDX] and PITCHMODE_FLAT[DEFAULT_PITCH_MODE_IDX].value or -1
local INITIAL_PITCHMODE_NAME = PITCHMODE_FLAT[DEFAULT_PITCH_MODE_IDX] and PITCHMODE_FLAT[DEFAULT_PITCH_MODE_IDX].name or "Project Default"

-------------------------------------------------------------------------------
-- 1. STATE & SETTINGS
-------------------------------------------------------------------------------
local state = {
  is_analyzing = false,
  progress = 0,
  results = {}, -- array of { time, freq, note }

  preset_range_idx = 1,
  preset_mode_idx = 1,
  preset_quality_idx = 2,
  preset_pitchmode_idx = INITIAL_PITCHMODE_IDX,
  pitchmode_value = INITIAL_PITCHMODE_VALUE,
  pitchmode_name = INITIAL_PITCHMODE_NAME,
  advanced_mode = false,

  -- YIN Parameters
  block_size = 1024,
  threshold = 0.08,
  min_freq = 65,
  max_freq = 1000,
  hop_size = 512, -- How many samples to advance per block

  -- Analysis state
  accessor = nil,
  sample_rate = 44100,
  num_channels = 1,
  start_time = 0,
  end_time = 0,
  current_time = 0,
  item_len = 0,
  buffer = nil,

  -- Interaction state
  hovered_note = nil,   -- index of note block under cursor
  hovered_zone = nil,   -- "drift" / "pitch" / "vibrato"
  selected_note = nil,  -- index of currently selected note
  drag = nil,           -- { note_idx, zone, start_mouse_y, original_value, dirty }

  -- Visualization toggles
  show_note_blocks = true,
  show_raw_pitch = true,
  show_trend = false,
  show_smart_spots = true,
  show_split_points = false,
  show_preview = true,
  show_vibrato_regions = false,

  -- Target item binding (persistent GUID lock)
  target_take_guid = nil,
  target_take_name = nil,

  -- Multi-item Session state
  session_takes = {},  -- [guid] = take_data table
  session_order = {},  -- array of guids
  sidebar_w = 200      -- resizable sidebar width
}

-- Robustly resolve a media item take by GUID with SWS and item-scan fallbacks
local function resolve_take_by_guid(guid)
  if not guid then return nil end
  local take = reaper.GetMediaItemTakeByGUID(0, guid)
  if take then return take end
  if reaper.SNM_GetMediaItemTakeByGUID then
    take = reaper.SNM_GetMediaItemTakeByGUID(0, guid)
    if take then return take end
  end
  local num_items = reaper.CountMediaItems(0)
  for i = 0, num_items - 1 do
    local it = reaper.GetMediaItem(0, i)
    if it then
      local num_takes = reaper.CountTakes(it)
      for t = 0, num_takes - 1 do
        local tk = reaper.GetTake(it, t)
        if tk then
          local _, g = reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false)
          if g == guid then return tk end
        end
      end
    end
  end
  return nil
end

-- Resolve the target take reliably, even if the item becomes deselected in REAPER
local function get_target_take(auto_select)
  local take = nil
  if state.target_take_guid then
    take = resolve_take_by_guid(state.target_take_guid)
  end

  if not take then
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if sel_item then
      local sel_take = reaper.GetActiveTake(sel_item)
      if sel_take and not reaper.TakeIsMIDI(sel_take) then
        take = sel_take
        local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
        state.target_take_guid = guid
        state.target_take_name = reaper.GetTakeName(take)
      end
    end
  end

  if not take then return nil, nil end

  local item = reaper.GetMediaItemTake_Item(take)
  if item and auto_select then
    if not reaper.IsMediaItemSelected(item) then
      reaper.SetMediaItemSelected(item, true)
      reaper.UpdateArrange()
    end
  end

  return take, item
end

-- Ensure the Take Pitch Envelope is active on the take, creating it if needed.
-- If force_unbypass is true (e.g. during analysis), guarantees it is active (ACT 1).
local function ensure_take_pitch_envelope(take, item, force_unbypass)
  if not take or not item then return nil end
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  local is_new = false

  if not env then
    is_new = true
    -- Item must be selected and take active for action to target it
    local was_selected = reaper.IsMediaItemSelected(item)
    if not was_selected then
      reaper.SetMediaItemSelected(item, true)
    end
    reaper.SetActiveTake(take)

    -- SWS command is "Show take pitch envelope" (explicit, non-toggling)
    local sws_cmd = reaper.NamedCommandLookup("_S&M_TAKEENV10")
    if sws_cmd > 0 then
      reaper.Main_OnCommand(sws_cmd, 0)
    else
      -- Native REAPER command 41612: "Take: Toggle take pitch envelope"
      reaper.Main_OnCommand(41612, 0)
    end

    reaper.UpdateArrange()
    env = reaper.GetTakeEnvelopeByName(take, "Pitch")

    if not was_selected then
      reaper.SetMediaItemSelected(item, false)
    end
  end

  -- Guarantee envelope is ACTIVE (unbypassed, ACT 1) and VISIBLE (VIS 1)
  -- when newly created or when explicitly requested (e.g. upon analysis)
  if env and (is_new or force_unbypass) then
    local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if ok and chunk then
      local modified = false
      if chunk:match("ACT%s+0") then
        chunk = chunk:gsub("ACT%s+0", "ACT 1")
        modified = true
      end
      if chunk:match("VIS%s+0") then
        chunk = chunk:gsub("VIS%s+0", "VIS 1")
        modified = true
      end
      if modified then
        reaper.SetEnvelopeStateChunk(env, chunk, false)
        reaper.UpdateItemInProject(item)
        reaper.UpdateArrange()
      end
    end
  end

  return env
end

-------------------------------------------------------------------------------
-- 2. DSP LOGIC (YIN ALGORITHM)
-------------------------------------------------------------------------------

-- Convert frequency to MIDI note (fractional)
local function freq_to_note(freq)
  if freq <= 0 then return 0 end
  return 69 + 12 * (math.log(freq / 440.0) / math.log(2))
end

local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local function midi_to_name(midi)
  if not midi then return "" end
  local note_idx = (midi % 12) + 1
  local octave = math.floor(midi / 12) - 1
  return NOTE_NAMES[note_idx] .. octave
end

-- Process a single block of audio using the YIN algorithm
local function yin_process_block(samples, sample_rate, params)
  local b_size = params.calc_block_size or params.block_size

  -- Cache to native Lua table. reaper.array metamethods are extremely slow inside nested loops!
  local s = {}
  for i = 1, b_size do
    s[i] = samples[i]
  end

  local rms_sum = 0
  for i = 1, b_size do
    rms_sum = rms_sum + s[i] * s[i]
  end
  local rms = math.sqrt(rms_sum / b_size)

  local W = math.floor(b_size / 2)
  local max_tau = math.floor(sample_rate / params.min_freq)
  local min_tau = math.floor(sample_rate / params.max_freq)

  if max_tau > W then max_tau = W end
  if min_tau < 1 then min_tau = 1 end

  local diff = {}
  local cmndf = {}

  -- 1. Difference function
  for tau = 0, max_tau do
    local sum = 0
    for j = 1, W do
      local d = s[j] - s[j + tau]
      sum = sum + d * d
    end
    diff[tau] = sum
  end

  -- 2. Cumulative Mean Normalized Difference Function (CMNDF)
  cmndf[0] = 1.0
  local running_sum = 0
  for tau = 1, max_tau do
    running_sum = running_sum + diff[tau]
    if running_sum == 0 then
      cmndf[tau] = 1.0
    else
      cmndf[tau] = diff[tau] / (running_sum / tau)
    end
  end

  -- 3. Absolute threshold
  local tau_estimate = -1
  for tau = min_tau, max_tau do
    if cmndf[tau] < params.threshold then
      -- Find local minimum
      while tau + 1 <= max_tau and cmndf[tau + 1] < cmndf[tau] do
        tau = tau + 1
      end
      tau_estimate = tau
      break
    end
  end

  if tau_estimate == -1 then
    -- Fallback to global minimum if nothing is below threshold
    local min_val = 1
    for tau = min_tau, max_tau do
      if cmndf[tau] < min_val then
        min_val = cmndf[tau]
        tau_estimate = tau
      end
    end
    -- If even the global minimum is high, it's likely unvoiced
    if min_val > params.threshold * 2 then
      return rms, nil
    end
  end

  -- 4. Parabolic interpolation for better precision
  local better_tau = tau_estimate
  if tau_estimate > 0 and tau_estimate < max_tau then
    local s0 = cmndf[tau_estimate - 1]
    local s1 = cmndf[tau_estimate]
    local s2 = cmndf[tau_estimate + 1]
    local denom = (2 * (2 * s1 - s2 - s0))
    if denom ~= 0 then
      local adjustment = (s2 - s0) / denom
      if math.abs(adjustment) < 1 then
         better_tau = better_tau + adjustment
      end
    end
  end

  return rms, sample_rate / better_tau
end

-------------------------------------------------------------------------------
-- 3. ANALYSIS ROUTINE (DEFERRED)
-------------------------------------------------------------------------------

local function reset_analysis()
  state.results = {}
  state.notes = nil
  state.split_points = nil
  state.progress = 0
  state.is_analyzing = false
  state.hovered_note = nil
  state.hovered_zone = nil
  state.selected_note = nil
  state.drag = nil

  if state.accessor then
    reaper.DestroyAudioAccessor(state.accessor)
    state.accessor = nil
  end

  local take, item = get_target_take(false)
  if take and item then
    local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
    if env then
      reaper.Undo_BeginBlock()
      reaper.DeleteEnvelopePointRange(env, 0, reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
      reaper.Envelope_SortPointsEx(env, -1)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Clear Pitch Envelope", -1)
    end
  end
end

local function start_analysis()
  local sel_item = reaper.GetSelectedMediaItem(0, 0)
  local item = nil
  local take = nil

  if sel_item then
    local sel_take = reaper.GetActiveTake(sel_item)
    if sel_take and not reaper.TakeIsMIDI(sel_take) then
      item = sel_item
      take = sel_take
      local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
      state.target_take_guid = guid
      state.target_take_name = reaper.GetTakeName(take)
    end
  end

  -- If no item is selected in arrange view, try using the existing locked target
  if not take and state.target_take_guid then
    take, item = get_target_take(true)
  end

  if not item or not take then
    reaper.ShowMessageBox("Please select an audio item.", "Error", 0)
    return
  end

  state.start_time = 0 -- Relative to item start
  state.item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  state.end_time = state.item_len
  state.current_time = 0

  local source = reaper.GetMediaItemTake_Source(take)
  state.sample_rate = reaper.GetMediaSourceSampleRate(source)

  state.accessor = reaper.CreateTakeAudioAccessor(take)
  state.buffer = reaper.new_array(state.block_size)

  state.results = {}
  state.is_analyzing = true
  state.progress = 0

  -- Ensure take pitch envelope is created and active on the take upfront
  ensure_take_pitch_envelope(take, item, true)
end

local function extract_note_features(note)
  if note.count == 0 then return end

  -- 1. Extract raw pitch array
  local raw_pitch = {}
  for i, frame in ipairs(note.frames) do
    raw_pitch[i] = frame.note
  end

  -- Median filter (3-point) to remove YIN tracking outliers
  local function median3(a, b, c)
    if a > b then a, b = b, a end
    if b > c then b = c end
    if a > b then b = a end
    return b
  end

  local filtered = {}
  filtered[1] = raw_pitch[1]
  for i = 2, #raw_pitch - 1 do
    filtered[i] = median3(raw_pitch[i-1], raw_pitch[i], raw_pitch[i+1])
  end
  filtered[#raw_pitch] = raw_pitch[#raw_pitch]
  raw_pitch = filtered

  -- Simple moving average helper
  local function get_sma(arr, win_size)
    local res = {}
    local half = math.floor(win_size / 2)
    for i = 1, #arr do
      local sum = 0
      local count = 0
      for j = math.max(1, i - half), math.min(#arr, i + half) do
        sum = sum + arr[j]
        count = count + 1
      end
      res[i] = sum / count
    end
    return res
  end

  -- 2. Calculate Trend (Heavy smoothing to find the true center, ~240ms window)
  local trend = get_sma(raw_pitch, 21)

  -- 3. Calculate smooth pitch (Light smoothing to remove YIN micro-jitters, ~58ms window)
  local smooth_pitch = get_sma(raw_pitch, 5)

  -- 4. Calculate Modulation
  local mod = {}
  for i = 1, #raw_pitch do
    mod[i] = smooth_pitch[i] - trend[i]
  end

  -- 5. Find Smart Spots via Zero-Crossing (1 peak per vibrato wave)
  local smart_spots = {}
  table.insert(smart_spots, { index = 1, time = note.frames[1].time, type = "anchor_start" })

  local current_sign = nil
  local extrema_idx = nil
  local extrema_val = 0

  for i = 1, #mod do
    local val = mod[i]
    local sign = val >= 0 and 1 or -1

    if current_sign == nil then
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    elseif sign == current_sign then
      if sign == 1 and val > extrema_val then
        extrema_idx = i
        extrema_val = val
      elseif sign == -1 and val < extrema_val then
        extrema_idx = i
        extrema_val = val
      end
    else
      -- Zero crossing! Save the previous extrema if it's prominent enough (ignore micro-wobbles under 5 cents)
      if math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
         local s_type = current_sign == 1 and "peak" or "valley"
         table.insert(smart_spots, { index = extrema_idx, time = note.frames[extrema_idx].time, type = s_type, mod_val = extrema_val })
      end
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    end
  end

  -- Push the last one if prominent
  if extrema_idx and math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
     local s_type = current_sign == 1 and "peak" or "valley"
     table.insert(smart_spots, { index = extrema_idx, time = note.frames[extrema_idx].time, type = s_type, mod_val = extrema_val })
  end

  table.insert(smart_spots, { index = #raw_pitch, time = note.frames[#raw_pitch].time, type = "anchor_end" })

  note.trend = trend
  note.modulation = mod
  note.smart_spots = smart_spots

  -- 6. Vibrato detection — three-gate approach
  --    Gate 1: Onset/offset exclusion (pitch settling is not vibrato)
  --    Gate 2: Periodicity validation (must be 4-8 Hz, not a one-shot scoop)
  --    Gate 3: Energy threshold (modulation must be large enough)
  local VIB_FLOOR = 0.04    -- below = no vibrato (semitones RMS)
  local VIB_CEILING = 0.12  -- above = full vibrato
  local ONSET_SEC = 0.12    -- exclude first 120ms (attack phase)
  local OFFSET_SEC = 0.08   -- exclude last 80ms (release tail)
  local VIB_FREQ_MIN = 3.5  -- Hz (generous low bound for vibrato)
  local VIB_FREQ_MAX = 9.0  -- Hz (generous high bound)

  local vib_win = math.max(3, math.min(#mod, 26)) -- ~300ms window
  local half_vw = math.floor(vib_win / 2)
  local vibrato_weight = {}

  -- Estimate frame duration from actual timing
  local frame_dur = #note.frames > 1
    and (note.frames[#note.frames].time - note.frames[1].time) / (#note.frames - 1)
    or 0.012

  for i = 1, #mod do
    local t = note.frames[i].time

    -- Gate 1: Onset/offset exclusion
    if (t - note.start_time) < ONSET_SEC or (note.end_time - t) < OFFSET_SEC then
      vibrato_weight[i] = 0.0
    else
      -- Gate 2: Periodicity — zero-crossing rate must be in vibrato band
      local zc_count = 0
      local win_start = math.max(2, i - half_vw)
      local win_end = math.min(#mod, i + half_vw)
      for j = win_start, win_end do
        if (mod[j] >= 0) ~= (mod[j - 1] >= 0) then
          zc_count = zc_count + 1
        end
      end
      local win_dur = (win_end - win_start + 1) * frame_dur
      local zc_freq = win_dur > 0 and (zc_count / (2 * win_dur)) or 0
      local is_periodic = zc_freq >= VIB_FREQ_MIN and zc_freq <= VIB_FREQ_MAX

      -- Gate 3: Energy threshold (RMS of modulation in window)
      local sum_sq = 0
      local cnt = 0
      for j = math.max(1, i - half_vw), math.min(#mod, i + half_vw) do
        sum_sq = sum_sq + mod[j] * mod[j]
        cnt = cnt + 1
      end
      local rms = math.sqrt(sum_sq / cnt)

      -- All three gates must pass
      if not is_periodic or rms < VIB_FLOOR then
        vibrato_weight[i] = 0.0
      elseif rms > VIB_CEILING then
        vibrato_weight[i] = 1.0
      else
        vibrato_weight[i] = (rms - VIB_FLOOR) / (VIB_CEILING - VIB_FLOOR)
      end
    end
  end

  note.vibrato_weight = vibrato_weight

  -- Default controls: NO correction (green preview = raw pitch)
  note.controls = {
    center_pitch = note.avg_note,
    drift_scale = 1.0,
    vibrato_scale = 1.0,
    transition_ms = 15
  }

  -- 7. ONSET ANALYSIS — scoop magnitude and voiced start detection
  local scoop_frames = math.min(10, math.floor(#raw_pitch * 0.3))
  local scoop_sum = 0
  for i = 1, scoop_frames do
    scoop_sum = scoop_sum + math.abs(raw_pitch[i] - note.avg_note)
  end
  note.scoop_magnitude = scoop_frames > 0 and (scoop_sum / scoop_frames) or 0

  -- Find first frame with stable voicing (3+ consecutive voiced frames)
  note.voiced_start_idx = 1
  for i = 1, math.min(#note.frames, 15) do
    if i + 2 <= #note.frames
      and note.frames[i].note and note.frames[i+1].note and note.frames[i+2].note then
      note.voiced_start_idx = i
      break
    end
  end
  note.voiced_start_time = note.frames[note.voiced_start_idx].time
end

local function is_note_modified(note)
  if not note or not note.controls then return false end
  local ctrl = note.controls
  local pitch_changed = math.abs(ctrl.center_pitch - note.avg_note) > 0.001
  local fine_changed = (ctrl.drift_scale ~= 1.0) or (ctrl.vibrato_scale ~= 1.0)
  return pitch_changed or fine_changed
end

-- Forward declaration; will be set after apply_envelope_to_take is defined
local reset_selected_note
local snap_selected_note

-------------------------------------------------------------------------------
-- MULTI-ITEM SESSION & PROJECT PERSISTENCE
-------------------------------------------------------------------------------

local function save_take_data(take, data)
  if not take or not data then return end
  local save_data = {
    guid = data.guid,
    name = data.name,
    start_time = data.start_time,
    end_time = data.end_time,
    item_len = data.item_len,
    sample_rate = data.sample_rate,
    results = data.results,
    notes = {}
  }
  if data.notes then
    for _, note in ipairs(data.notes) do
      table.insert(save_data.notes, {
        start_time = note.start_time,
        end_time = note.end_time,
        avg_note = note.avg_note,
        display_note = note.display_note,
        controls = note.controls,
        scoop_magnitude = note.scoop_magnitude,
        voiced_start_idx = note.voiced_start_idx,
        voiced_start_time = note.voiced_start_time,
        frames = note.frames
      })
    end
  end
  local json_str = JSON.encode(save_data)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:fancy_pitch_data", json_str, true)
end

local function load_take_data(take)
  if not take then return nil end
  local ok, json_str = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:fancy_pitch_data", "", false)
  if not ok or not json_str or json_str == "" then return nil end
  local success, data = pcall(JSON.decode, json_str)
  if success and data and data.results and data.notes then
    for _, note in ipairs(data.notes) do
      note.count = #note.frames
      extract_note_features(note)
    end
    return data
  end
  return nil
end

local function is_take_pitch_bypassed(take)
  if not take then return false end
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if not env then return false end
  local retval, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if retval and chunk then
    return chunk:match("ACT%s+0") ~= nil
  end
  return false
end

local function toggle_take_pitch_bypass(take)
  if not take then return end
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  local item = reaper.GetMediaItemTake_Item(take)
  if not env and item then
    env = ensure_take_pitch_envelope(take, item, true)
  end
  if env then
    reaper.Undo_BeginBlock()
    local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if ok and chunk then
      if chunk:match("ACT%s+0") then
        chunk = chunk:gsub("ACT%s+0", "ACT 1")
        if chunk:match("VIS%s+0") then
          chunk = chunk:gsub("VIS%s+0", "VIS 1")
        end
      else
        chunk = chunk:gsub("ACT%s+1", "ACT 0")
      end
      reaper.SetEnvelopeStateChunk(env, chunk, false)
      if item then reaper.UpdateItemInProject(item) end
      reaper.UpdateArrange()
    end
    reaper.Undo_EndBlock("Toggle Take Pitch Envelope Bypass", -1)
  end
end

local function switch_active_target(guid, take_obj)
  local data = state.session_takes[guid]
  if not data and take_obj then
    data = load_take_data(take_obj)
    if data then
      state.session_takes[guid] = data
      local found = false
      for _, g in ipairs(state.session_order) do if g == guid then found = true; break end end
      if not found then table.insert(state.session_order, guid) end
    end
  end

  if data then
    state.target_take_guid = guid
    state.target_take_name = data.name
    state.results = data.results
    state.notes = data.notes
    state.start_time = data.start_time
    state.end_time = data.end_time
    state.item_len = data.item_len
    state.sample_rate = data.sample_rate
    state.selected_note = nil
    state.hovered_note = nil
    state.drag = nil

    local item = take_obj and reaper.GetMediaItemTake_Item(take_obj)
    if not item then
      local t = resolve_take_by_guid(guid)
      item = t and reaper.GetMediaItemTake_Item(t)
    end
    if item and not reaper.IsMediaItemSelected(item) then
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.UpdateArrange()
    end
    return true
  end
  return false
end

local function scan_project_for_saved_takes()
  local num_items = reaper.CountMediaItems(0)
  for i = 0, num_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
      local num_takes = reaper.CountTakes(item)
      for t = 0, num_takes - 1 do
        local take = reaper.GetTake(item, t)
        if take and not reaper.TakeIsMIDI(take) then
          local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
          if guid and not state.session_takes[guid] then
            local data = load_take_data(take)
            if data then
              state.session_takes[guid] = data
              local found = false
              for _, g in ipairs(state.session_order) do if g == guid then found = true; break end end
              if not found then table.insert(state.session_order, guid) end
            end
          end
        end
      end
    end
  end
end

local function apply_envelope_to_take()
  local take, item = get_target_take(true)
  if not take or not item then return end

  reaper.Undo_BeginBlock()

  -- Set pitch shift mode (Elastique Soloist Monophonic by default)
  if state.pitchmode_value ~= -1 then
    reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", state.pitchmode_value)
  end

  -- Ensure pitch envelope exists
  local env = ensure_take_pitch_envelope(take, item)
  if not env then
    reaper.ShowMessageBox("Failed to activate Take Pitch Envelope.", "Error", 0)
    reaper.Undo_EndBlock("Apply Pitch Correction", -1)
    return
  end

  -- Clear existing points
  reaper.DeleteEnvelopePointRange(env, 0, reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))

  local SHAPE = 5   -- Bezier
  local TENSION = 0 -- Neutral tension

  for n_idx, note in ipairs(state.notes) do
    -- SCALPEL RULE: Untouched notes receive zero envelope points
    if not is_note_modified(note) then
      goto continue_note
    end

    local ctrl = note.controls
    local prev_note = state.notes[n_idx - 1]
    local next_note = state.notes[n_idx + 1]

    -- STRICT BOUNDARY CONTRACT:
    -- Legato connection ONLY exists if the neighbor is ALSO MODIFIED and within 50ms!
    local prev_is_mod = is_note_modified(prev_note)
    local next_is_mod = is_note_modified(next_note)

    local is_legato_prev = prev_is_mod and ((note.start_time - prev_note.end_time) < 0.05)
    local is_legato_next = next_is_mod and ((next_note.start_time - note.end_time) < 0.05)

    local note_dur = note.end_time - note.start_time
    local half_dur = note_dur * 0.5

    -- Onset ramp duration for fine adjustments (scales with scoop)
    local scoop = note.scoop_magnitude or 0
    local base_onset = 0.08 -- 80ms
    local scoop_extra = math.min(0.07, scoop * 0.05)
    local onset_ramp_sec = math.min(base_onset + scoop_extra, half_dur * 0.6)

    -- Crossfade duration between two modified notes
    local xfade_sec = math.min(0.04, half_dur * 0.4)

    -- Coarse pitch shift (rigid DC offset)
    local coarse_shift = ctrl.center_pitch - note.avg_note
    local fine_changed = (ctrl.drift_scale ~= 1.0) or (ctrl.vibrato_scale ~= 1.0)

    -- Store debug info
    note.onset_debug = {
      onset_ramp_ms = onset_ramp_sec * 1000,
      scoop_st = scoop,
      voicing_delay_ms = 0,
      is_legato_prev = is_legato_prev,
      is_legato_next = is_legato_next
    }

    if not fine_changed then
      -- =====================================================================
      -- 1. COARSE-ONLY MODE (Uniform pitch shift across the note)
      -- =====================================================================
      -- START BOUNDARY
      if not is_legato_prev then
        -- Strict 0.0 isolation: pin envelope to 0 before note start
        reaper.InsertEnvelopePointEx(env, -1, note.start_time - 0.001, 0, 0, 0, 0, false)
        reaper.InsertEnvelopePointEx(env, -1, note.start_time, coarse_shift, SHAPE, TENSION, 0, false)
      else
        -- Both notes modified: blend at boundary
        local prev_shift = prev_note.controls.center_pitch - prev_note.avg_note
        local blend_val = (prev_shift + coarse_shift) * 0.5
        reaper.InsertEnvelopePointEx(env, -1, note.start_time, blend_val, SHAPE, TENSION, 0, false)
        reaper.InsertEnvelopePointEx(env, -1, note.start_time + xfade_sec, coarse_shift, SHAPE, TENSION, 0, false)
      end

      -- END BOUNDARY
      if not is_legato_next then
        -- Strict 0.0 isolation: hold coarse shift to note end, pin to 0 immediately after
        reaper.InsertEnvelopePointEx(env, -1, note.end_time, coarse_shift, SHAPE, TENSION, 0, false)
        reaper.InsertEnvelopePointEx(env, -1, note.end_time + 0.001, 0, 0, 0, 0, false)
      else
        -- Both notes modified: hold coarse shift up to crossfade start
        reaper.InsertEnvelopePointEx(env, -1, note.end_time - xfade_sec, coarse_shift, SHAPE, TENSION, 0, false)
      end

    else
      -- =====================================================================
      -- 2. FINE CONTOUR MODE (Drift reduction / vibrato scaling)
      -- =====================================================================
      -- Decoupled formula: env_val = coarse_shift + drift_corr + vib_corr
      -- Avoids injecting YIN (smooth - raw) noise into the take envelope.
      local num_spots = #note.smart_spots
      for s_idx, spot in ipairs(note.smart_spots) do
        local i = spot.index
        local t = spot.time
        local vw = note.vibrato_weight and note.vibrato_weight[i] or 1.0
        local drift_corr = (note.trend[i] - note.avg_note) * (ctrl.drift_scale - 1.0)
        local vib_corr = note.modulation[i] * (ctrl.vibrato_scale - 1.0) * vw
        local env_val = coarse_shift + drift_corr + vib_corr

        if s_idx == 1 or spot.type == "anchor_start" then
          -- START BOUNDARY
          if not is_legato_prev then
            -- Strict 0.0 isolation: pin envelope to 0 before note start
            reaper.InsertEnvelopePointEx(env, -1, note.start_time - 0.001, 0, 0, 0, 0, false)
            -- Coarse shift engages immediately
            reaper.InsertEnvelopePointEx(env, -1, note.start_time, coarse_shift, SHAPE, TENSION, 0, false)
            -- Ease into fine contour
            local fine_at_ramp = env_val - coarse_shift
            if math.abs(fine_at_ramp) > 0.01 and onset_ramp_sec > 0.02 then
              reaper.InsertEnvelopePointEx(env, -1, note.start_time + onset_ramp_sec * 0.5, coarse_shift + fine_at_ramp * 0.5, SHAPE, TENSION, 0, false)
              t = note.start_time + onset_ramp_sec
            else
              t = nil
            end
          else
            -- Both notes modified: blend at boundary
            local prev_ctrl = prev_note.controls
            local prev_shift = prev_ctrl.center_pitch - prev_note.avg_note
            local prev_drift_corr = (prev_note.trend[#prev_note.trend] - prev_note.avg_note) * (prev_ctrl.drift_scale - 1.0)
            local prev_vw = prev_note.vibrato_weight and prev_note.vibrato_weight[#prev_note.vibrato_weight] or 1.0
            local prev_vib_corr = prev_note.modulation[#prev_note.modulation] * (prev_ctrl.vibrato_scale - 1.0) * prev_vw
            local prev_env_val = prev_shift + prev_drift_corr + prev_vib_corr

            local blend_val = (prev_env_val + env_val) * 0.5
            reaper.InsertEnvelopePointEx(env, -1, note.start_time, blend_val, SHAPE, TENSION, 0, false)
            t = note.start_time + xfade_sec
          end

        elseif s_idx == num_spots or spot.type == "anchor_end" then
          -- END BOUNDARY
          if not is_legato_next then
            -- Strict 0.0 isolation: note finishes at env_val, then pin to 0.0 immediately
            reaper.InsertEnvelopePointEx(env, -1, note.end_time, env_val, SHAPE, TENSION, 0, false)
            reaper.InsertEnvelopePointEx(env, -1, note.end_time + 0.001, 0, 0, 0, 0, false)
            t = nil
          else
            -- Both notes modified: end slightly before boundary so next note can blend
            reaper.InsertEnvelopePointEx(env, -1, note.end_time - xfade_sec, env_val, SHAPE, TENSION, 0, false)
            t = nil
          end
        end

        if t then
          reaper.InsertEnvelopePointEx(env, -1, t, env_val, SHAPE, TENSION, 0, false)
        end
      end
    end

    ::continue_note::
  end

  reaper.Envelope_SortPointsEx(env, -1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Apply Pitch Correction", -1)

  -- Update session cache and persist edits to take P_EXT
  if state.target_take_guid and state.session_takes[state.target_take_guid] then
    state.session_takes[state.target_take_guid].notes = state.notes
    save_take_data(take, state.session_takes[state.target_take_guid])
  end
end

-- Resets the selected note back to [Untouched], clearing its envelope contribution.
reset_selected_note = function()
  if not state.selected_note or not state.notes then return end
  local sel = state.notes[state.selected_note]
  if not sel or not sel.controls then return end
  sel.controls.center_pitch = sel.avg_note
  sel.controls.drift_scale = 1.0
  sel.controls.vibrato_scale = 1.0
  apply_envelope_to_take()
end

-- Snaps the selected note to the nearest exact semitone (0¢ deviation).
snap_selected_note = function()
  if not state.selected_note or not state.notes then return end
  local sel = state.notes[state.selected_note]
  if not sel or not sel.controls then return end
  sel.controls.center_pitch = math.floor(sel.controls.center_pitch + 0.5)
  apply_envelope_to_take()
end

local function run_hybrid_segmentation()
  state.notes = {}
  state.split_points = {} -- For debugging display

  if #state.results == 0 then return end

  -- Configuration
  local min_note_dur = 0.08 -- 80ms
  local debounce_dur = 0.08 -- 80ms
  local pitch_jump_threshold = 0.75 -- Semitones
  local rms_noise_floor = 0.005 -- Absolute RMS threshold for silence

  -- Calculate derivatives (applying a simple median filter logic by looking at 3 frames would be better, but we keep it simple for now)
  for i, frame in ipairs(state.results) do
    if i > 1 then
      local prev = state.results[i-1]
      if frame.note and prev.note then
        frame.delta_note = frame.note - prev.note
      else
        frame.delta_note = 0
      end
      frame.delta_rms = frame.rms - prev.rms
    else
      frame.delta_note = 0
      frame.delta_rms = 0
    end
  end

  local current_note = nil
  local last_split_time = -1

  for _, frame in ipairs(state.results) do
    local is_voiced = (frame.note ~= nil and frame.rms > rms_noise_floor)

    local should_split = false
    local split_reason = ""

    if is_voiced then
      if not current_note then
        should_split = true
        split_reason = "Onset (from silence)"
      else
        -- Check for pitch jump (legato)
        if math.abs(frame.delta_note) > pitch_jump_threshold then
          should_split = true
          split_reason = "Pitch Jump"
        end

        -- Check for amplitude spike (articulation)
        if frame.delta_rms > frame.rms * 0.5 and frame.delta_rms > 0.02 then
          should_split = true
          split_reason = "Amplitude Spike"
        end
      end
    else
      -- Unvoiced gap
      if current_note then
        -- End current note
        if (frame.time - current_note.start_time) >= min_note_dur then
          table.insert(state.notes, current_note)
        end
        current_note = nil
      end
    end

    if should_split and (frame.time - last_split_time) >= debounce_dur then
      if current_note then
        current_note.end_time = frame.time
        if (current_note.end_time - current_note.start_time) >= min_note_dur then
          table.insert(state.notes, current_note)
        end
      end

      current_note = {
        start_time = frame.time,
        end_time = frame.time,
        sum_note = 0,
        count = 0,
        frames = {}
      }

      table.insert(state.split_points, { time = frame.time, reason = split_reason })
      last_split_time = frame.time
    end

    if current_note and is_voiced then
      current_note.sum_note = current_note.sum_note + frame.note
      current_note.count = current_note.count + 1
      current_note.end_time = frame.time
      table.insert(current_note.frames, frame)
    end
  end

  -- Push last note
  if current_note and (current_note.end_time - current_note.start_time) >= min_note_dur then
    table.insert(state.notes, current_note)
  end

  -- Calculate anchor pitch
  for _, n in ipairs(state.notes) do
    if n.count > 0 then
      n.avg_note = n.sum_note / n.count
      n.display_note = math.floor(n.avg_note + 0.5)
      extract_note_features(n)
    end
  end
end

local function process_analysis_step()
  if not state.is_analyzing then return end

  -- Maximize CPU usage by processing for 100ms straight before yielding to UI
  local start_time_ms = reaper.time_precise()

  while state.current_time < state.end_time do
    if reaper.time_precise() - start_time_ms > 0.1 then
      break -- yield to update the progress bar
    end

    -- Read samples
    local num_read = reaper.GetAudioAccessorSamples(
      state.accessor,
      state.sample_rate,
      state.num_channels,
      state.current_time,
      state.block_size,
      state.buffer
    )

    if num_read > 0 then
      local rms, freq = yin_process_block(state.buffer, state.sample_rate, state)
      local note = nil
      if freq and freq >= state.min_freq and freq <= state.max_freq then
        note = freq_to_note(freq)
      end
      table.insert(state.results, {
        time = state.current_time,
        freq = freq,
        note = note,
        rms = rms
      })
    end

    -- Advance time by hop size
    state.current_time = state.current_time + (state.hop_size / state.sample_rate)
  end

  if state.current_time >= state.end_time then
    reaper.DestroyAudioAccessor(state.accessor)
    state.accessor = nil
    state.is_analyzing = false
    state.progress = 1.0
    run_hybrid_segmentation()

    -- Store into multi-item session cache and persist to take P_EXT
    if state.target_take_guid then
      local take_data = {
        guid = state.target_take_guid,
        name = state.target_take_name or "Take",
        start_time = state.start_time,
        end_time = state.end_time,
        item_len = state.item_len,
        sample_rate = state.sample_rate,
        results = state.results,
        notes = state.notes
      }
      state.session_takes[state.target_take_guid] = take_data

      local found = false
      for _, g in ipairs(state.session_order) do
        if g == state.target_take_guid then found = true; break end
      end
      if not found then table.insert(state.session_order, state.target_take_guid) end

      local t = resolve_take_by_guid(state.target_take_guid)
      if t then save_take_data(t, take_data) end
    end
  elseif state.item_len > 0 then
    state.progress = state.current_time / state.item_len
  end
end

-------------------------------------------------------------------------------
-- 4. GUI
-------------------------------------------------------------------------------

local function draw_graph(draw_ctx, w, h)
  local draw_list = reaper.ImGui_GetWindowDrawList(draw_ctx)
  local px, py = reaper.ImGui_GetCursorScreenPos(draw_ctx)
  local P = Theme.get_palette()

  -- Claim canvas space and enable mouse interaction
  reaper.ImGui_InvisibleButton(draw_ctx, "##pitch_canvas", w, h)
  local is_canvas_hovered = reaper.ImGui_IsItemHovered(draw_ctx)

  -- Draw background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + h, 0x1A1A1AFF)
  reaper.ImGui_DrawList_AddRect(draw_list, px, py, px + w, py + h, 0x444444FF)

  local piano_w = 40
  local full_px = px
  local full_w = w
  px = px + piano_w
  w = w - piano_w

  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, full_px + full_w, py + h, true)

  if #state.results == 0 then
    reaper.ImGui_DrawList_AddText(draw_list, px + 10, py + 10, P.text,
      "No data. Select an item and click Analyze.")
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end

  -- Find min/max notes for vertical scaling
  local min_note = 127
  local max_note = 0
  local has_notes = false
  for _, pt in ipairs(state.results) do
    if pt.note then
      has_notes = true
      if pt.note < min_note then min_note = pt.note end
      if pt.note > max_note then max_note = pt.note end
    end
  end
  -- Include moved blocks in range calculation
  if state.notes then
    for _, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        if cp + 0.5 > max_note then max_note = cp + 0.5 end
        if cp - 0.5 < min_note then min_note = cp - 0.5 end
      end
    end
  end

  if not has_notes then
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end

  -- Add padding
  min_note = math.floor(min_note - 2)
  max_note = math.ceil(max_note + 2)
  local note_range = max_note - min_note
  if note_range < 1 then note_range = 1 end

  local duration = state.end_time - state.start_time
  if duration <= 0 then duration = 1 end
  local px_per_st = h / note_range -- pixels per semitone

  ---------------------------------------------------------------------------
  -- MOUSE INTERACTION
  ---------------------------------------------------------------------------
  local mx, my = reaper.ImGui_GetMousePos(draw_ctx)

  -- Hit-test: find hovered note and zone
  if is_canvas_hovered and not state.drag and state.notes then
    state.hovered_note = nil
    state.hovered_zone = nil
    for n_idx, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        local sx = px + ((note.start_time - state.start_time) / duration) * w
        local ex = px + ((note.end_time - state.start_time) / duration) * w
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h

        if mx >= sx and mx <= ex and my >= top_y and my <= bot_y then
          state.hovered_note = n_idx
          local block_w = ex - sx
          local zone_w = math.max(12, block_w * 0.25)
          if mx < sx + zone_w then
            state.hovered_zone = "drift"
          elseif mx > ex - zone_w then
            state.hovered_zone = "vibrato"
          else
            state.hovered_zone = "pitch"
          end
          break
        end
      end
    end
  elseif not is_canvas_hovered and not state.drag then
    state.hovered_note = nil
    state.hovered_zone = nil
  end

  -- Click: select note and begin drag, or deselect
  if is_canvas_hovered and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
    get_target_take(true)
    if state.hovered_note then
      state.selected_note = state.hovered_note
      local note = state.notes[state.hovered_note]
      local original_val
      if state.hovered_zone == "pitch" then
        original_val = note.controls.center_pitch
      elseif state.hovered_zone == "drift" then
        original_val = note.controls.drift_scale
      else
        original_val = note.controls.vibrato_scale
      end
      state.drag = {
        note_idx = state.hovered_note,
        zone = state.hovered_zone,
        start_mouse_y = my,
        original_value = original_val,
        dirty = false
      }
    else
      state.selected_note = nil
      -- Click on empty canvas: move REAPER edit cursor to this time position
      local rel_x = (mx - px) / w  -- 0..1 across canvas
      rel_x = math.max(0, math.min(1, rel_x))
      local item_time = state.start_time + rel_x * duration
      -- Convert item-relative time to project time
      local _, item = get_target_take(false)
      if item then
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        reaper.SetEditCurPos(item_pos + item_time, false, false)
      end
    end
  end

  -- Process active drag
  if state.drag then
    local d_note = state.notes[state.drag.note_idx]
    if d_note and d_note.controls then
      local delta_y = state.drag.start_mouse_y - my -- up = positive

      if math.abs(delta_y) > 2 then -- dead zone: click vs. drag
        state.drag.dirty = true

        if state.drag.zone == "pitch" then
          local delta_st = delta_y / px_per_st
          local new_pitch = state.drag.original_value + delta_st
          -- Shift modifier = snap to semitones
          local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
          if shift_mod > 0 then
            local ok, mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
            if ok and mods and (mods & shift_mod) ~= 0 then
              new_pitch = math.floor(new_pitch + 0.5)
            end
          end
          d_note.controls.center_pitch = new_pitch
        elseif state.drag.zone == "drift" then
          -- 2 semitones of vertical drag = full range (up = more stable = less drift)
          local delta = delta_y / (px_per_st * 2)
          d_note.controls.drift_scale = math.max(0, math.min(1,
            state.drag.original_value - delta))
        elseif state.drag.zone == "vibrato" then
          -- 2 semitones of vertical drag = full 0→2 range
          local delta = delta_y / px_per_st
          d_note.controls.vibrato_scale = math.max(0, math.min(2,
            state.drag.original_value + delta))
        end
      end
    end

    -- End drag → apply envelope to take
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.drag.dirty then
        apply_envelope_to_take()
      end
      state.drag = nil
    end
  end

  ---------------------------------------------------------------------------
  -- KEYBOARD CONTROLS (Scalpel Workflow)
  ---------------------------------------------------------------------------
  -- Guard: skip keyboard shortcuts if any widget (combo, input, slider)
  -- is active — prevents arrow keys from leaking into toolbar combos.
  local ok_aia, any_active = pcall(reaper.ImGui_IsAnyItemActive, draw_ctx)
  local widget_capturing = ok_aia and any_active

  if not state.drag and not widget_capturing and state.notes and #state.notes > 0 then
    -- Resolve Shift modifier for fine-tune (cross-platform, no OS conflicts)
    local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
    local ok_mods, cur_mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
    local has_shift = ok_mods and cur_mods and (cur_mods & shift_mod) ~= 0

    -- Up / Down: Nudge pitch (±1 semitone, or ±10 cents with Shift)
    if state.selected_note and state.notes[state.selected_note] then
      local sel = state.notes[state.selected_note]

      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_UpArrow()) then
        get_target_take(true)
        if has_shift then
          sel.controls.center_pitch = sel.controls.center_pitch + 0.10  -- +10 cents
        else
          sel.controls.center_pitch = sel.controls.center_pitch + 1.0   -- +1 semitone
        end
        apply_envelope_to_take()
      end

      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_DownArrow()) then
        get_target_take(true)
        if has_shift then
          sel.controls.center_pitch = sel.controls.center_pitch - 0.10  -- -10 cents
        else
          sel.controls.center_pitch = sel.controls.center_pitch - 1.0   -- -1 semitone
        end
        apply_envelope_to_take()
      end

      -- S: Snap to nearest semitone
      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_S()) then
        get_target_take(true)
        snap_selected_note()
      end

      -- R / Backspace / Delete: Reset to [Untouched]
      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_R())
        or reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Backspace())
        or reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Delete()) then
        get_target_take(true)
        reset_selected_note()
      end
    end

    -- Left / Right: Jump selection to previous / next note
    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_LeftArrow()) then
      if state.selected_note and state.selected_note > 1 then
        state.selected_note = state.selected_note - 1
      elseif not state.selected_note then
        state.selected_note = 1
      end
    end

    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_RightArrow()) then
      if state.selected_note and state.selected_note < #state.notes then
        state.selected_note = state.selected_note + 1
      elseif not state.selected_note then
        state.selected_note = 1
      end
    end

    -- Spacebar: Pass through to REAPER Play/Stop
    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Space()) then
      reaper.Main_OnCommand(40044, 0)  -- Transport: Play/Stop
    end
  end

  -- Double-click pitch zone: Snap to nearest semitone
  if is_canvas_hovered and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
    if state.hovered_note and state.hovered_zone == "pitch" then
      state.selected_note = state.hovered_note
      get_target_take(true)
      snap_selected_note()
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE GRID & PIANO ROLL
  ---------------------------------------------------------------------------
  for n = math.floor(min_note), math.ceil(max_note) do
    local y = py + h - ((n - min_note) / note_range) * h
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local is_black_key = (n % 12 == 1 or n % 12 == 3 or n % 12 == 6
                          or n % 12 == 8 or n % 12 == 10)

    local grid_color = is_black_key and 0x222222FF or 0x333333FF
    reaper.ImGui_DrawList_AddLine(draw_list, px, y, px + w, y, grid_color)

    local key_color = is_black_key and 0x1A1A1AFF or 0xDDDDDDFF
    local text_col = is_black_key and 0x888888FF or 0x333333FF

    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, key_top, full_px + piano_w, key_bot, key_color)
    reaper.ImGui_DrawList_AddRect(draw_list, full_px, key_top, full_px + piano_w, key_bot, 0x000000FF)

    if n % 12 == 0 then
      local label = "C" .. tostring(math.floor(n / 12) - 1)
      reaper.ImGui_DrawList_AddText(draw_list, full_px + 2, key_top + (key_bot - key_top) * 0.5 - 7, text_col, label)
    else
      local label = midi_to_name(n)
      reaper.ImGui_DrawList_AddText(draw_list, full_px + 2, key_top + (key_bot - key_top) * 0.5 - 7, text_col, label)
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE BLOCKS (interactive, positioned by center_pitch)
  ---------------------------------------------------------------------------
  if state.show_note_blocks and state.notes then
    for n_idx, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        local sx = px + ((note.start_time - state.start_time) / duration) * w
        local ex = px + ((note.end_time - state.start_time) / duration) * w
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h
        local block_w = ex - sx
        local zone_w = math.max(12, block_w * 0.25)

        local is_selected = (state.selected_note == n_idx)
        local is_hov = (state.hovered_note == n_idx)
        local is_mod = is_note_modified(note)

        local fill
        local border
        if is_selected then
          fill = is_mod and 0x3FA34D99 or 0x4477AA88
          border = P.accent
        elseif is_mod then
          fill = 0x3FA34D77  -- Vivid green for edited notes
          border = 0x56E39FFF
        else
          fill = 0x2A364466  -- Muted slate for untouched notes
          border = 0x4A586888
        end

        -- Zone-colored hover highlights
        if is_hov and not state.drag then
          if state.hovered_zone == "drift" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, sx + zone_w, bot_y, 0x4DA6FF44)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx + zone_w, top_y, ex, bot_y, fill)
          elseif state.hovered_zone == "vibrato" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex - zone_w, bot_y, fill)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              ex - zone_w, top_y, ex, bot_y, 0xFFAA4444)
          else -- pitch zone
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex, bot_y, fill)
          end
        else
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx, top_y, ex, bot_y, fill)
        end

        -- Border
        reaper.ImGui_DrawList_AddRect(draw_list,
          sx, top_y, ex, bot_y, border)

        -- Zone divider lines on hover/select
        if is_hov or is_selected then
          reaper.ImGui_DrawList_AddLine(draw_list,
            sx + zone_w, top_y, sx + zone_w, bot_y, 0xFFFFFF33)
          reaper.ImGui_DrawList_AddLine(draw_list,
            ex - zone_w, top_y, ex - zone_w, bot_y, 0xFFFFFF33)
        end

        -- Note label: name + cents deviation (always visible)
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        local label = string.format("%s %s%d\xC2\xA2", midi_to_name(nearest), sign, cents)
        local text_y = (top_y + bot_y) * 0.5 - 7
        local text_color = is_mod and 0xFFFFFFFF or 0xCCCCCCAA
        reaper.ImGui_DrawList_AddText(draw_list,
          sx + 4, text_y, text_color, label)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW SPLIT POINTS
  ---------------------------------------------------------------------------
  if state.show_split_points and state.split_points then
    for _, sp in ipairs(state.split_points) do
      local x = px + ((sp.time - state.start_time) / duration) * w
      reaper.ImGui_DrawList_AddLine(draw_list, x, py, x, py + h, 0xFF5555AA, 1.0)
      reaper.ImGui_DrawList_AddText(draw_list, x + 2, py + 2, 0xFF5555FF, sp.reason)
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW RAW PITCH CURVE (purple)
  ---------------------------------------------------------------------------
  if state.show_raw_pitch then
    local valid_pts = 0
    for _, pt in ipairs(state.results) do
      if pt.note then valid_pts = valid_pts + 1 end
    end

    if valid_pts > 0 then
      local polyline = reaper.new_array(valid_pts * 2)
      local p_idx = 1
      for _, pt in ipairs(state.results) do
        if pt.note then
          local x = px + ((pt.time - state.start_time) / duration) * w
          local y = py + h - ((pt.note - min_note) / note_range) * h
          polyline[p_idx] = x
          polyline[p_idx + 1] = y
          p_idx = p_idx + 2
        end
      end
      reaper.ImGui_DrawList_AddPolyline(draw_list, polyline, 0x8B70FAFF, 0, 2.0)
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW TREND, SMART SPOTS, VIBRATO REGIONS & CORRECTED PITCH PREVIEW
  ---------------------------------------------------------------------------
  if state.notes then
    for _, note in ipairs(state.notes) do
      -- Vibrato regions (amber bands where vibrato was detected)
      if state.show_vibrato_regions and note.vibrato_weight and note.frames then
        local in_region = false
        local region_start_x = 0
        for i, frame in ipairs(note.frames) do
          local is_vib = note.vibrato_weight[i] > 0.3
          local x = px + ((frame.time - state.start_time) / duration) * w
          if is_vib and not in_region then
            region_start_x = x
            in_region = true
          elseif not is_vib and in_region then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              region_start_x, py, x, py + h, 0xFFAA4418)
            in_region = false
          end
        end
        -- Close trailing region
        if in_region then
          local last_x = px + ((note.frames[#note.frames].time - state.start_time) / duration) * w
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            region_start_x, py, last_x, py + h, 0xFFAA4418)
        end
      end

      -- Trend line (cyan)
      if state.show_trend and note.trend then
        local t_poly = reaper.new_array(#note.frames * 2)
        local tp_idx = 1
        for i, frame in ipairs(note.frames) do
          local x = px + ((frame.time - state.start_time) / duration) * w
          local y = py + h - ((note.trend[i] - min_note) / note_range) * h
          t_poly[tp_idx] = x
          t_poly[tp_idx + 1] = y
          tp_idx = tp_idx + 2
        end
        reaper.ImGui_DrawList_AddPolyline(draw_list, t_poly, 0x00FFFFFF, 0, 1.0)
      end

      -- Smart spots (yellow/white circles)
      if state.show_smart_spots and note.smart_spots then
        for _, spot in ipairs(note.smart_spots) do
          local x = px + ((spot.time - state.start_time) / duration) * w
          local raw_pitch = note.frames[spot.index].note
          local y = py + h - ((raw_pitch - min_note) / note_range) * h

          local spot_color = 0xFFFF00FF
          if spot.type == "anchor_start" or spot.type == "anchor_end" then
            spot_color = 0x00FFFFFF
          end

          reaper.ImGui_DrawList_AddCircleFilled(draw_list, x, y, 3, spot_color)
        end
      end

      -- Corrected pitch preview line (green) — rendered for modified notes
      if state.show_preview and is_note_modified(note) and note.controls and note.trend and note.modulation then
        local ctrl = note.controls
        local coarse_shift = ctrl.center_pitch - note.avg_note
        local cp_poly = reaper.new_array(#note.frames * 2)
        local cp_idx = 1
        for i, frame in ipairs(note.frames) do
          local vw = note.vibrato_weight and note.vibrato_weight[i] or 1.0
          local drift_corr = (note.trend[i] - note.avg_note) * (ctrl.drift_scale - 1.0)
          local vib_corr = note.modulation[i] * (ctrl.vibrato_scale - 1.0) * vw
          local target = frame.note + coarse_shift + drift_corr + vib_corr
          local x = px + ((frame.time - state.start_time) / duration) * w
          local y = py + h - ((target - min_note) / note_range) * h
          cp_poly[cp_idx] = x
          cp_poly[cp_idx + 1] = y
          cp_idx = cp_idx + 2
        end
        reaper.ImGui_DrawList_AddPolyline(draw_list, cp_poly, 0x56E39FCC, 0, 2.0)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- TOOLTIPS (drag value / hover hint)
  ---------------------------------------------------------------------------
  if state.drag and state.drag.dirty then
    local d_note = state.notes[state.drag.note_idx]
    if d_note and d_note.controls then
      local tip
      if state.drag.zone == "pitch" then
        local cp = d_note.controls.center_pitch
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        tip = string.format("%s %s%d\xC2\xA2",
          midi_to_name(nearest), sign, cents)
      elseif state.drag.zone == "drift" then
        tip = string.format("Stability: %.0f%%",
          (1 - d_note.controls.drift_scale) * 100)
      else
        tip = string.format("Vibrato: %.0f%%",
          d_note.controls.vibrato_scale * 100)
      end
      reaper.ImGui_DrawList_AddText(draw_list, mx + 15, my - 10,
        0xFFFFFFFF, tip)
    end
  elseif state.hovered_note and not state.drag then
    local h_note = state.notes[state.hovered_note]
    if h_note and h_note.controls then
      local tip
      if state.hovered_zone == "drift" then
        tip = string.format("Stability: %.0f%%",
          (1 - h_note.controls.drift_scale) * 100)
      elseif state.hovered_zone == "vibrato" then
        tip = string.format("Vibrato: %.0f%%",
          h_note.controls.vibrato_scale * 100)
      else
        tip = "Drag to retune (Shift=snap)"
      end
      reaper.ImGui_DrawList_AddText(draw_list, mx + 15, my - 10,
        0xFFFFFFBB, tip)
    end
  end
  ---------------------------------------------------------------------------
  -- PLAYHEAD CURSOR LINE
  ---------------------------------------------------------------------------
  local _, item_for_cursor = get_target_take(false)
  if item_for_cursor then
    local item_pos = reaper.GetMediaItemInfo_Value(item_for_cursor, "D_POSITION")
    -- Use play position when playing, edit cursor when stopped
    local play_state = reaper.GetPlayState()
    local project_pos = (play_state & 1) ~= 0
      and reaper.GetPlayPosition()
      or  reaper.GetCursorPosition()
    local item_rel = project_pos - item_pos
    -- Only draw if cursor is within the item's time range
    if item_rel >= state.start_time and item_rel <= state.end_time then
      local cursor_x = px + ((item_rel - state.start_time) / duration) * w
      reaper.ImGui_DrawList_AddLine(draw_list,
        cursor_x, py, cursor_x, py + h, P.accent, 1.5)
    end
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

local function strip_pitchenv_from_str(str)
  local s_start = str:find("<PITCHENV")
  if not s_start then return str end
  local depth = 0
  local pos = s_start
  local s_end = nil
  while pos <= #str do
    local b_start, b_end, tag = str:find("([<>])", pos)
    if not b_start then break end
    if tag == "<" then
      depth = depth + 1
    elseif tag == ">" then
      depth = depth - 1
      if depth == 0 then
        if str:sub(b_end + 1, b_end + 2) == "\r\n" then
          s_end = b_end + 2
        elseif str:sub(b_end + 1, b_end + 1) == "\n" then
          s_end = b_end + 1
        else
          s_end = b_end
        end
        break
      end
    end
    pos = b_end + 1
  end

  if s_end then
    return str:sub(1, s_start - 1) .. str:sub(s_end + 1)
  end
  return str
end

local function remove_take_pitch_envelope_chunk(item, take_guid)
  if not item then return end
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or not chunk or not chunk:find("<PITCHENV") then return end

  local num_takes = reaper.CountTakes(item)
  if num_takes <= 1 or not take_guid then
    local new_chunk = strip_pitchenv_from_str(chunk)
    reaper.SetItemStateChunk(item, new_chunk, false)
    return
  end

  -- Multi-take item: split chunk at "\nTAKE" boundaries
  local sections = {}
  local last_pos = 1
  while true do
    local t_start = chunk:find("\nTAKE", last_pos)
    if not t_start then
      table.insert(sections, chunk:sub(last_pos))
      break
    end
    table.insert(sections, chunk:sub(last_pos, t_start))
    last_pos = t_start + 1
  end

  local modified = false
  for i, sec in ipairs(sections) do
    if sec:find(take_guid, 1, true) then
      local new_sec = strip_pitchenv_from_str(sec)
      if new_sec ~= sec then
        sections[i] = new_sec
        modified = true
      end
      break
    end
  end

  if modified then
    local new_chunk = table.concat(sections, "")
    reaper.SetItemStateChunk(item, new_chunk, false)
  end
end

local function remove_take_from_session(guid)
  if not guid then return end

  local data = state.session_takes[guid]
  local take_name = (data and data.name) or "Take"
  local take_obj = resolve_take_by_guid(guid)

  reaper.Undo_BeginBlock()

  if take_obj then
    local item = reaper.GetMediaItemTake_Item(take_obj)

    -- 1. Wipe all pitch envelope points and automation items first
    local env = reaper.GetTakeEnvelopeByName(take_obj, "Pitch")
    if env then
      local ai_count = reaper.CountAutomationItems(env)
      for a = ai_count - 1, 0, -1 do
        reaper.DestroyAutomationItem(env, a)
      end
      reaper.DeleteEnvelopePointRange(env, -1000000, 1000000)
      reaper.Envelope_SortPoints(env)
    end

    -- 2. Completely remove the <PITCHENV> block from the media item chunk
    if item then
      remove_take_pitch_envelope_chunk(item, guid)
    end

    -- 3. Reset pitch shift mode to project default (-1) and pitch offset to 0.0
    reaper.SetMediaItemTakeInfo_Value(take_obj, "I_PITCHMODE", -1)
    reaper.SetMediaItemTakeInfo_Value(take_obj, "D_PITCH", 0.0)

    -- 4. Purge persistent project metadata on this take
    reaper.GetSetMediaItemTakeInfo_String(take_obj, "P_EXT:fancy_pitch_data", "", true)

    if item then
      reaper.UpdateItemInProject(item)
    end
    reaper.UpdateArrange()
  end

  -- 5. Remove from session cache and order
  state.session_takes[guid] = nil
  for idx, g in ipairs(state.session_order) do
    if g == guid then
      table.remove(state.session_order, idx)
      break
    end
  end

  -- 6. If active target was this take, switch to next take or reset to empty
  if state.target_take_guid == guid then
    if #state.session_order > 0 then
      local next_guid = state.session_order[1]
      local next_take = resolve_take_by_guid(next_guid)
      switch_active_target(next_guid, next_take)
    else
      state.target_take_guid = nil
      state.target_take_name = nil
      state.results = {}
      state.notes = nil
      state.selected_note = nil
      state.hovered_note = nil
      state.drag = nil
      state.start_time = nil
      state.end_time = nil
      state.item_len = nil
      state.sample_rate = nil
    end
  end

  reaper.Undo_EndBlock(string.format("Delete %s from Pitch Session and Reset Take", take_name), -1)
end

local function render_session_sidebar(sidebar_ctx)
  local P = Theme.get_palette()

  reaper.ImGui_Text(sidebar_ctx, string.format("Session Takes (%d)", #state.session_order))
  reaper.ImGui_Separator(sidebar_ctx)

  if #state.session_order == 0 then
    reaper.ImGui_TextDisabled(sidebar_ctx, "No takes stored.\n\nSelect an audio item in REAPER and click Analyze.")
    return
  end

  local to_remove = nil

    for _, guid in ipairs(state.session_order) do
    local data = state.session_takes[guid]
    if data then
      local is_active = (guid == state.target_take_guid)
      local take_obj = resolve_take_by_guid(guid)
      if not take_obj and is_active then
        take_obj = get_target_take(false)
      end

      reaper.ImGui_PushID(sidebar_ctx, guid)

      -- Active marker
      if is_active then
        reaper.ImGui_TextColored(sidebar_ctx, P.accent, ">")
      else
        reaper.ImGui_TextDisabled(sidebar_ctx, " ")
      end
      reaper.ImGui_SameLine(sidebar_ctx)

      -- Selectable take name
      local avail_w = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)
      local btn_reserve = 72 -- reserve space for bypass and remove buttons
      local name_w = math.max(30, avail_w - btn_reserve)

      local sel_flags = reaper.ImGui_SelectableFlags_AllowOverlap and reaper.ImGui_SelectableFlags_AllowOverlap() or 0
      local sel_text = data.name or "Take"
      if reaper.ImGui_Selectable(sidebar_ctx, sel_text .. "##sel", is_active, sel_flags, name_w, 0) then
        switch_active_target(guid, take_obj)
      end
      if reaper.ImGui_IsItemHovered(sidebar_ctx) then
        Theme.tooltip(sidebar_ctx, string.format("Take: %s\nNotes: %d\nClick to switch editing target",
          data.name or "Take", data.notes and #data.notes or 0))
      end

      -- Bypass button
      reaper.ImGui_SameLine(sidebar_ctx)
      local is_bp = is_take_pitch_bypassed(take_obj)
      if is_bp then
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Button(), 0xCC4444FF)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_ButtonHovered(), 0xDD5555FF)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_ButtonActive(), 0xBB3333FF)
      end
      if reaper.ImGui_SmallButton(sidebar_ctx, (is_bp and "Byp" or "Act") .. "##bp") then
        toggle_take_pitch_bypass(take_obj)
      end
      if is_bp then
        reaper.ImGui_PopStyleColor(sidebar_ctx, 3)
      end
      if reaper.ImGui_IsItemHovered(sidebar_ctx) then
        Theme.tooltip(sidebar_ctx, is_bp and "Envelope Bypassed — click to re-enable" or "Envelope Active — click to bypass")
      end

      -- Remove button
      reaper.ImGui_SameLine(sidebar_ctx)
      if reaper.ImGui_SmallButton(sidebar_ctx, "x##del") then
        to_remove = guid
      end
      if reaper.ImGui_IsItemHovered(sidebar_ctx) then
        Theme.tooltip(sidebar_ctx, "Remove from session, clear envelope, and reset take")
      end

      reaper.ImGui_PopID(sidebar_ctx)
    end
  end

  if to_remove then
    remove_take_from_session(to_remove)
  end
end

local function loop()
  local _
  Theme.push(ctx)

  process_analysis_step()

  local visible, open = reaper.ImGui_Begin(ctx, 'Fancy Pitch Correct', true, reaper.ImGui_WindowFlags_NoNavInputs())
  if visible then
    reaper.ImGui_Text(ctx, "YIN Pitch Detection Test Bench")
    reaper.ImGui_Separator(ctx)

    -- Automatic selection tracking from REAPER:
    -- If a new item is selected in REAPER, switch to it (from cache) or prepare for analysis
    local cur_sel_item = reaper.GetSelectedMediaItem(0, 0)
    if cur_sel_item then
      local cur_sel_take = reaper.GetActiveTake(cur_sel_item)
      if cur_sel_take and not reaper.TakeIsMIDI(cur_sel_take) then
        local _, cur_guid = reaper.GetSetMediaItemTakeInfo_String(cur_sel_take, "GUID", "", false)
        if cur_guid and cur_guid ~= state.target_take_guid and not state.is_analyzing then
          local switched = switch_active_target(cur_guid, cur_sel_take)
          if not switched then
            state.target_take_guid = cur_guid
            state.target_take_name = reaper.GetTakeName(cur_sel_take) or "Selected Item"
            state.results = {}
            state.notes = nil
            state.selected_note = nil
            state.hovered_note = nil
            state.drag = nil
            state.start_time = 0
            state.item_len = reaper.GetMediaItemInfo_Value(cur_sel_item, "D_LENGTH")
            state.end_time = state.item_len
          end
        end
      end
    end

    -- Target item status header
    local target_take = get_target_take(false)
    if target_take and state.target_take_name then
      local P = Theme.get_palette()
      reaper.ImGui_TextColored(ctx, P.accent, "Target:")
      reaper.ImGui_SameLine(ctx)
      local is_analyzed = state.notes and #state.notes > 0
      local status_label = is_analyzed and " (Active)" or " (Ready to analyze — click Analyze)"
      reaper.ImGui_Text(ctx, state.target_take_name .. status_label)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Active editing target. Stored in Session Takes list on the right.")
      end
    else
      reaper.ImGui_TextDisabled(ctx, "Target: None (Select an audio item in REAPER)")
    end
    reaper.ImGui_Separator(ctx)


    -- Compact preset combos (no labels) + action buttons
    reaper.ImGui_PushItemWidth(ctx, 100)
    if reaper.ImGui_BeginCombo(ctx, "##range", VOCAL_RANGES[state.preset_range_idx].name) then
      for i, range in ipairs(VOCAL_RANGES) do
        if reaper.ImGui_Selectable(ctx, range.name, state.preset_range_idx == i) then
          state.preset_range_idx = i
          state.min_freq = range.min
          state.max_freq = range.max
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Vocal Range — limits frequency search to avoid octave errors")
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_BeginCombo(ctx, "##mode", DETECTION_MODES[state.preset_mode_idx].name) then
      for i, mode in ipairs(DETECTION_MODES) do
        if reaper.ImGui_Selectable(ctx, mode.name, state.preset_mode_idx == i) then
          state.preset_mode_idx = i
          state.threshold = mode.threshold
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Detection Mode — strictness for pitched note detection")
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_BeginCombo(ctx, "##quality", QUALITY_MODES[state.preset_quality_idx].name) then
      for i, mode in ipairs(QUALITY_MODES) do
        if reaper.ImGui_Selectable(ctx, mode.name, state.preset_quality_idx == i) then
          state.preset_quality_idx = i
          state.block_size = mode.block
          state.hop_size = mode.hop
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Quality / CPU — time vs frequency resolution trade-off")
    end
    reaper.ImGui_PopItemWidth(ctx)

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushItemWidth(ctx, 180)
    if reaper.ImGui_BeginCombo(ctx, "##pitchmode", state.pitchmode_name) then
      for i, entry in ipairs(PITCHMODE_FLAT) do
        local is_selected = (state.preset_pitchmode_idx == i)
        if reaper.ImGui_Selectable(ctx, entry.name, is_selected) then
          state.preset_pitchmode_idx = i
          state.pitchmode_value = entry.value
          state.pitchmode_name = entry.name
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Pitch Shift Algorithm — Elastique Soloist (Monophonic) recommended for vocals.\nSet automatically when applying correction.")
    end
    reaper.ImGui_PopItemWidth(ctx)

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Analyze") then
      start_analysis()
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reset") then
      reset_analysis()
    end

    -- Keyboard shortcuts info icon
    reaper.ImGui_SameLine(ctx)
    Theme.icon_btn(ctx, "##kb_shortcuts_info", Theme.icons.info, {
      preset = Theme.layout.icon_md,
      tooltip = "Keyboard Shortcuts\n"
        .. "─────────────────────────────\n"
        .. "↑ / ↓           Nudge ±1 semitone\n"
        .. "Shift + ↑/↓      Fine-tune ±10 cents\n"
        .. "← / →           Select prev / next note\n"
        .. "S               Snap to nearest semitone\n"
        .. "Double-Click    Snap (in pitch zone)\n"
        .. "R / Del          Reset note to original\n"
        .. "Space           Play / Stop (REAPER)",
    })

    if state.is_analyzing then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Text(ctx, string.format("Analyzing... %d%%", math.floor(state.progress * 100)))
      reaper.ImGui_ProgressBar(ctx, state.progress, -1, 14)
    end

    -- Advanced DSP Parameters (toggle)
    _, state.advanced_mode = reaper.ImGui_Checkbox(ctx, "Show Advanced DSP Parameters", state.advanced_mode)

    if state.advanced_mode then
      reaper.ImGui_Indent(ctx, 10)
      _, state.block_size = reaper.ImGui_InputInt(ctx, "Block Size", state.block_size)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "The number of samples analyzed per window. Larger sizes provide better low-frequency resolution but reduce time precision.")
      end

      _, state.hop_size = reaper.ImGui_InputInt(ctx, "Hop Size", state.hop_size)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "The number of samples to advance between analysis windows. Smaller values increase time resolution but use more CPU.")
      end

      _, state.threshold = reaper.ImGui_SliderDouble(ctx, "YIN Threshold", state.threshold, 0.05, 0.5)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Confidence threshold for pitch detection. Lower values are stricter, reducing false positives but potentially missing quiet or breathy notes.")
      end

      _, state.min_freq = reaper.ImGui_SliderDouble(ctx, "Min Freq (Hz)", state.min_freq, 20, 200)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "The lowest expected frequency. Limits the maximum lag time analyzed by the algorithm.")
      end

      _, state.max_freq = reaper.ImGui_SliderDouble(ctx, "Max Freq (Hz)", state.max_freq, 200, 2000)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "The highest expected frequency. Limits the minimum lag time analyzed by the algorithm.")
      end
      reaper.ImGui_Unindent(ctx, 10)
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, string.format("Points detected: %d", #state.results))

    -- Visualization toggles
    if #state.results > 0 then
      _, state.show_note_blocks = reaper.ImGui_Checkbox(ctx, "Blocks", state.show_note_blocks)
      reaper.ImGui_SameLine(ctx)
      _, state.show_raw_pitch = reaper.ImGui_Checkbox(ctx, "Pitch", state.show_raw_pitch)
      reaper.ImGui_SameLine(ctx)
      _, state.show_trend = reaper.ImGui_Checkbox(ctx, "Trend", state.show_trend)
      reaper.ImGui_SameLine(ctx)
      _, state.show_smart_spots = reaper.ImGui_Checkbox(ctx, "Spots", state.show_smart_spots)
      reaper.ImGui_SameLine(ctx)
      _, state.show_split_points = reaper.ImGui_Checkbox(ctx, "Splits", state.show_split_points)
      reaper.ImGui_SameLine(ctx)
      _, state.show_preview = reaper.ImGui_Checkbox(ctx, "Preview", state.show_preview)
      reaper.ImGui_SameLine(ctx)
      _, state.show_vibrato_regions = reaper.ImGui_Checkbox(ctx, "Vibrato", state.show_vibrato_regions)
    end

    if #state.results > 0 and state.notes and #state.notes > 0 then
      reaper.ImGui_Separator(ctx)

      if state.selected_note and state.notes[state.selected_note] then
        local sel = state.notes[state.selected_note]
        local ctrl = sel.controls
        local nearest = math.floor(ctrl.center_pitch + 0.5)
        local cents = math.floor((ctrl.center_pitch - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        local is_mod = is_note_modified(sel)
        local status_str = is_mod and "[Tuned]" or "[Untouched]"
        reaper.ImGui_Text(ctx, string.format(
          "Selected: %s %s%d\xC2\xA2  |  Stability: %.0f%%  |  Vibrato: %.0f%%  |  %s",
          midi_to_name(nearest), sign, cents, (1 - ctrl.drift_scale) * 100,
          ctrl.vibrato_scale * 100, status_str))
        -- Onset debug info
        if sel.onset_debug then
          local od = sel.onset_debug
          reaper.ImGui_TextDisabled(ctx, string.format(
            "Onset: ramp=%.0fms  scoop=%.2fst  voicing_delay=%.0fms  |  %s | %s",
            od.onset_ramp_ms, od.scoop_st, od.voicing_delay_ms,
            od.is_legato_prev and "legato-in" or "attack",
            od.is_legato_next and "legato-out" or "release"))
        end
      else
        reaper.ImGui_TextDisabled(ctx,
          "Click a note block to select. Drag: center=pitch, left=stability, right=vibrato")
      end

      if reaper.ImGui_Button(ctx, "Apply to Take Pitch Envelope") then
        apply_envelope_to_take()
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Reset Selected") then
        reset_selected_note()
      end
      reaper.ImGui_SameLine(ctx)
      -- Check actual bypass state from envelope
      local bp_take = get_target_take(false)
      local is_bypassed = is_take_pitch_bypassed(bp_take)
      if is_bypassed then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xCC4444FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xDD5555FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xBB3333FF)
      end
      if reaper.ImGui_Button(ctx, (is_bypassed and "Bypassed" or "Bypass") .. "##top_bp") then
        if bp_take then
          toggle_take_pitch_bypass(bp_take)
        end
      end
      if is_bypassed then
        reaper.ImGui_PopStyleColor(ctx, 3)
      end
      reaper.ImGui_Separator(ctx)
    end

    -- Main body layout: Piano roll graph (left) + Resizable Splitter + Session Takes Sidebar (right)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local total_h = math.max(120, avail_h - 10)

    local min_graph_w = 200
    local min_sidebar_w = 140
    local splitter_w = 6
    local max_sidebar_w = math.max(min_sidebar_w, avail_w - min_graph_w - splitter_w)

    state.sidebar_w = math.max(min_sidebar_w, math.min(max_sidebar_w, state.sidebar_w or 200))
    local graph_w = math.max(min_graph_w, avail_w - state.sidebar_w - splitter_w)

    if total_h > 80 then
      -- Left: Piano roll canvas
      draw_graph(ctx, graph_w, total_h)

      reaper.ImGui_SameLine(ctx, 0, 0)

      -- Center: Resizable Splitter
      reaper.ImGui_InvisibleButton(ctx, "##v_splitter", splitter_w, total_h)
      local is_split_hov = reaper.ImGui_IsItemHovered(ctx)
      local is_split_act = reaper.ImGui_IsItemActive(ctx)
      if is_split_hov or is_split_act then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
      end
      if is_split_act then
        local delta_x = select(1, reaper.ImGui_GetMouseDelta(ctx))
        state.sidebar_w = math.max(min_sidebar_w, math.min(max_sidebar_w, state.sidebar_w - delta_x))
      end
      -- Draw splitter visual bar
      local split_dl = reaper.ImGui_GetWindowDrawList(ctx)
      local sp_min_x, sp_min_y = reaper.ImGui_GetItemRectMin(ctx)
      local sp_max_x, sp_max_y = reaper.ImGui_GetItemRectMax(ctx)
      local sp_mid_x = (sp_min_x + sp_max_x) * 0.5
      local P = Theme.get_palette()
      local sp_col = is_split_act and P.accent or (is_split_hov and P.accent_h or P.sep)
      reaper.ImGui_DrawList_AddLine(split_dl, sp_mid_x, sp_min_y, sp_mid_x, sp_max_y, sp_col, is_split_act and 2.0 or 1.0)

      reaper.ImGui_SameLine(ctx, 0, 0)

      -- Right: Session Takes Sidebar
      local child_border = reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or (reaper.ImGui_ChildFlags_Borders and reaper.ImGui_ChildFlags_Borders() or 0)
      if reaper.ImGui_BeginChild(ctx, "##session_sidebar", state.sidebar_w, total_h, child_border) then
        render_session_sidebar(ctx)
        reaper.ImGui_EndChild(ctx)
      end
    end

    reaper.ImGui_End(ctx)
  end

  Theme.pop(ctx)

  if open then
    reaper.defer(loop)
  end
end

-------------------------------------------------------------------------------
-- 5. MAIN
-------------------------------------------------------------------------------
local function main()
  scan_project_for_saved_takes()

  local sel_item = reaper.GetSelectedMediaItem(0, 0)
  if sel_item then
    local sel_take = reaper.GetActiveTake(sel_item)
    if sel_take and not reaper.TakeIsMIDI(sel_take) then
      local _, guid = reaper.GetSetMediaItemTakeInfo_String(sel_take, "GUID", "", false)
      if guid then
        local loaded = switch_active_target(guid, sel_take)
        if not loaded then
          state.target_take_guid = guid
          state.target_take_name = reaper.GetTakeName(sel_take) or "Selected Item"
          state.start_time = 0
          state.item_len = reaper.GetMediaItemInfo_Value(sel_item, "D_LENGTH")
          state.end_time = state.item_len
        end
      end
    end
  elseif #state.session_order > 0 then
    local first_guid = state.session_order[1]
    local first_take = reaper.GetMediaItemTakeByGUID(0, first_guid)
    switch_active_target(first_guid, first_take)
  end

  loop()
end

main()
