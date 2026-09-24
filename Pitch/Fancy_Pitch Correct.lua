-- @description Fancy Pitch Correct
-- @author Fancy Scripts
-- @version 2.4.0
-- @changelog
--   + Production UX: Streamlined Modern Studio Dock layout maximizing vertical and horizontal piano roll canvas
--   + Integrated Theme.header with custom title bar, branding, and responsive window controls
--   + Pitched Items Panel: Renamed from Session Takes with collapsible flyout drawer and live count indicator
--   + Bottom Contextual Inspector: Clean note pitch badges, scale indicator, drift/vibrato/transition status, and quick action bar
--   + Audio Engine & Settings Modal: Dedicated modal for vocal range, detection strictness, quality, REAPER pitch shift algorithm, and advanced DSP parameters
--   + Keyboard Shortcuts & Help Modal: Accessible via header info button
--   + Layers Popover: Consolidated display toggles into a clean dropdown
--   + High-Fidelity Note Blending: S-curve smoothstep transitions (35ms default) across all note boundaries, eliminating 1ms cliff artifacts and vocoder chirps
--   + True Stability Drift Correction: Continuous pitch drift tracking sampled with sub-cent RDP decimation into REAPER Take Pitch Envelope
--   + Natural Vibrato Modeling: Zero-phase Gaussian filter separates slow drift from vibrato; hysteresis gate and smooth envelope follower prevent chattering
--   + Robust Energy-Weighted Pitch Center: Excludes onset scoops and release sag to calculate true stable pitch center
--   + UI / Audio Parity: Green preview line and take envelope points generated from identical continuous trajectory
--   + Transition Readout: Displays transition duration in active note status readout
--   + Multi-Note Selection & Batch Operations (Milestone 4)
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

local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
local ctx = reaper.ImGui_CreateContext('Fancy Pitch Correct', dock_flag)
local fonts = Theme.create_fonts(ctx)
Theme.attach_fonts(ctx, fonts)

local show_settings_modal = false
local show_info_modal = false

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

local SCALE_KEYS = {
  { name = "C",       display = "C" },
  { name = "C# / Db", display = "C#" },
  { name = "D",       display = "D" },
  { name = "D# / Eb", display = "D#" },
  { name = "E",       display = "E" },
  { name = "F",       display = "F" },
  { name = "F# / Gb", display = "F#" },
  { name = "G",       display = "G" },
  { name = "G# / Ab", display = "G#" },
  { name = "A",       display = "A" },
  { name = "A# / Bb", display = "A#" },
  { name = "B",       display = "B" }
}

local SCALE_DEFINITIONS = {
  { name = "Major",            intervals = {0, 2, 4, 5, 7, 9, 11} },
  { name = "Natural Minor",    intervals = {0, 2, 3, 5, 7, 8, 10} },
  { name = "Dorian",           intervals = {0, 2, 3, 5, 7, 9, 10} },
  { name = "Pentatonic",       intervals = {0, 2, 4, 7, 9} },
  { name = "Minor Pentatonic", intervals = {0, 3, 5, 7, 10} },
  { name = "Chromatic",        intervals = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11} },
}

-- Discover available pitch shift modes at startup
local PITCH_SHIFT_MODES = {}
local DEFAULT_PITCH_MODE_IDX = 1
do
  local mode_idx = 0
  local consecutive_fails = 0
  while mode_idx < 64 do
    local retval, name = reaper.EnumPitchShiftModes(mode_idx)
    if not retval then
      consecutive_fails = consecutive_fails + 1
      if consecutive_fails >= 5 then break end
    else
      consecutive_fails = 0
      -- Supported modes return a valid name; unsupported modes return nil / empty string
      if name and name ~= "" then
        local submodes = {}
        local sub_idx = 0
        while sub_idx < 128 do
          local sub_name = reaper.EnumPitchShiftSubModes(mode_idx, sub_idx)
          if not sub_name or sub_name == "" then break end
          local packed = (mode_idx << 16) | sub_idx
          table.insert(submodes, { name = sub_name, value = packed })
          sub_idx = sub_idx + 1
        end
        if #submodes > 0 then
          table.insert(PITCH_SHIFT_MODES, { name = name, submodes = submodes })
        else
          local packed = (mode_idx << 16)
          table.insert(PITCH_SHIFT_MODES, { name = name, submodes = { { name = "Default", value = packed } } })
        end
      end
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

-- Find best Soloist Monophonic entry in the flat list:
-- 1. Prefer exact "Soloist ... - Monophonic" (standard mono, not Mid/Side or Multi-Stereo)
for i, entry in ipairs(PITCHMODE_FLAT) do
  local lower = entry.name:lower()
  if lower:find("soloist") and lower:match("%-%s*monophonic$") then
    DEFAULT_PITCH_MODE_IDX = i
    break
  end
end

-- 2. Fallback to any entry with both "soloist" and "mono"
if DEFAULT_PITCH_MODE_IDX == 1 then
  for i, entry in ipairs(PITCHMODE_FLAT) do
    local lower = entry.name:lower()
    if lower:find("soloist") and lower:find("mono") then
      DEFAULT_PITCH_MODE_IDX = i
      break
    end
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
  hovered_edge = nil,   -- { note_idx, edge ("left"/"right") } for edge trimming
  selected_note = nil,  -- index of primary selected note (for single-note ops)
  selected_notes = {},  -- set { [note_idx] = true } for multi-select (merge, batch drag, quantize)
  drag = nil,           -- { note_idx, anchor_idx, zone, start_mouse_y, original_value, orig_values, dirty }
  edge_drag = nil,      -- { note_idx, edge, start_mouse_x, original_time, dirty }
  marquee = nil,        -- { start_x, start_y, cur_x, cur_y, active, has_shift, init_sel }

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

  -- Multi-item Pitched Items state
  session_takes = {},  -- [guid] = take_data table
  session_order = {},  -- array of guids
  sidebar_w = 200,     -- resizable sidebar width
  sidebar_open = true, -- Pitched Items drawer visibility (defaults open)
  show_onset_debug = false, -- opt-in onset diagnostic readout

  -- Key & Scale state
  key_idx = 1,       -- 1..12 (1 = C)
  scale_idx = 1,     -- 1..6 (1 = Major)
  scale_pc_set = {}  -- pitch class lookup set [0..11] = true/false
}

local function update_scale_pitch_classes()
  local scale = SCALE_DEFINITIONS[state.scale_idx]
  local root_pc = (state.key_idx - 1) % 12
  state.scale_pc_set = {}
  if scale then
    for _, intv in ipairs(scale.intervals) do
      local pc = (root_pc + intv) % 12
      state.scale_pc_set[pc] = true
    end
  end
end

local function is_pitch_in_scale(pitch_class)
  if not state.scale_pc_set or not pitch_class then return true end
  local pc = (math.floor(pitch_class + 0.5) % 12 + 12) % 12
  return state.scale_pc_set[pc] == true
end

-- Initialize key, scale, and sidebar preferences from ExtState
do
  local saved_key = tonumber(reaper.GetExtState("FancyScripts", "pitch_key_idx"))
  local saved_scale = tonumber(reaper.GetExtState("FancyScripts", "pitch_scale_idx"))
  if saved_key and saved_key >= 1 and saved_key <= #SCALE_KEYS then
    state.key_idx = saved_key
  end
  if saved_scale and saved_scale >= 1 and saved_scale <= #SCALE_DEFINITIONS then
    state.scale_idx = saved_scale
  end
  update_scale_pitch_classes()

  local saved_sidebar = reaper.GetExtState("FancyScripts", "pitch_sidebar_open")
  if saved_sidebar == "0" or saved_sidebar == "false" then
    state.sidebar_open = false
  else
    state.sidebar_open = true
  end
end

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

--- Get effective track color for active take/item, converting native REAPER color to ImGui RGBA
local function get_target_track_color(take, item)
  if not take then return nil end
  if not item then
    item = reaper.GetMediaItemTake_Item(take)
  end
  if not item then return nil end

  -- 1. Check track color explicitly first
  local track = reaper.GetMediaItem_Track(item)
  if track then
    local tr_col = reaper.GetTrackColor(track)
    if tr_col and tr_col ~= 0 then
      return Theme.bgr_to_rgba(tr_col)
    end
  end

  -- 2. Fall back to displayed item color if track has default 0
  if reaper.GetDisplayedMediaItemColor then
    local disp_col = reaper.GetDisplayedMediaItemColor(item)
    if disp_col and disp_col ~= 0 then
      return Theme.bgr_to_rgba(disp_col)
    end
  end

  return nil
end

--- Returns dark text for high-luminance background colors and white text for dark/mid backgrounds
local function get_contrasting_text_color(rgba)
  if not rgba then return 0xFFFFFFFF end
  local r = ((rgba >> 24) & 0xFF) / 255
  local g = ((rgba >> 16) & 0xFF) / 255
  local b = ((rgba >> 8) & 0xFF) / 255
  local lum = 0.299 * r + 0.587 * g + 0.114 * b
  return (lum > 0.6) and 0x141418FF or 0xFFFFFFFF
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
      local cur_tau = tau
      while cur_tau + 1 <= max_tau and cmndf[cur_tau + 1] < cmndf[cur_tau] do
        cur_tau = cur_tau + 1
      end
      tau_estimate = cur_tau
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
  state.selected_notes = {}
  state.drag = nil
  state.marquee = nil

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

-------------------------------------------------------------------------------
-- 3. SIGNAL PROCESSING & PITCH EXTRACTION HELPERS
-------------------------------------------------------------------------------

local function gaussian_filter(arr, sigma_frames)
  local n = #arr
  if n == 0 then return {} end
  if n == 1 then return { arr[1] } end
  local res = {}
  local radius = math.max(1, math.ceil(sigma_frames * 2.5))
  for i = 1, n do
    local sum, w_sum = 0, 0
    for j = math.max(1, i - radius), math.min(n, i + radius) do
      local dist = (i - j) / sigma_frames
      local w = math.exp(-0.5 * dist * dist)
      sum = sum + arr[j] * w
      w_sum = w_sum + w
    end
    res[i] = sum / w_sum
  end
  return res
end

local function smoothstep(u)
  local c = math.max(0, math.min(1, u))
  return c * c * (3 - 2 * c)
end

local function rdp_simplify(points, epsilon)
  if #points <= 2 then return points end

  local function perpendicular_dist(pt, l1, l2)
    local dx = l2.time - l1.time
    if dx <= 0.00001 then
      return math.abs(pt.val - l1.val)
    end
    local u = (pt.time - l1.time) / dx
    local py = l1.val + u * (l2.val - l1.val)
    return math.abs(pt.val - py)
  end

  local function rdp_recursive(pts, first, last, eps, out)
    local dmax = 0
    local index = 0
    for i = first + 1, last - 1 do
      local d = perpendicular_dist(pts[i], pts[first], pts[last])
      if d > dmax then
        index = i
        dmax = d
      end
    end
    if dmax > eps then
      rdp_recursive(pts, first, index, eps, out)
      table.insert(out, pts[index])
      rdp_recursive(pts, index, last, eps, out)
    end
  end

  local out = { points[1] }
  rdp_recursive(points, 1, #points, epsilon, out)
  table.insert(out, points[#points])
  table.sort(out, function(a, b) return a.time < b.time end)

  local dedup = { out[1] }
  for i = 2, #out do
    if out[i].time > dedup[#dedup].time + 0.0001 then
      table.insert(dedup, out[i])
    end
  end
  return dedup
end

local function compute_vibrato_weights(mod, frame_dur, total_dur)
  local n = #mod
  local weights = {}
  for i = 1, n do weights[i] = 0.0 end
  if n < 8 then return weights end

  local half_win = math.max(2, math.floor(0.12 / frame_dur)) -- ~240ms window
  local raw_gate = {}
  local is_active = false

  for i = 1, n do
    local t = (i - 1) * frame_dur
    -- Onset & offset exclusion (pitch settling and release tail are not vibrato)
    if t < 0.10 or t > (total_dur - 0.06) then
      raw_gate[i] = false
      is_active = false
    else
      local w_start = math.max(1, i - half_win)
      local w_end = math.min(n, i + half_win)
      local count = w_end - w_start + 1
      local sum_sq = 0
      local zc = 0
      for j = w_start, w_end do
        sum_sq = sum_sq + mod[j] * mod[j]
        if j > w_start and (mod[j] >= 0) ~= (mod[j-1] >= 0) then
          zc = zc + 1
        end
      end
      local rms = math.sqrt(sum_sq / count)
      local win_time = count * frame_dur
      local freq = win_time > 0 and (zc / (2 * win_time)) or 0
      local is_periodic = (freq >= 3.5 and freq <= 8.5 and zc >= 2)

      -- Schmitt trigger (turn on at 0.045 st / 4.5 cents, hold down to 0.028 st / 2.8 cents)
      if not is_active then
        if is_periodic and rms >= 0.045 then
          is_active = true
        end
      else
        if not is_periodic or rms < 0.028 then
          is_active = false
        end
      end
      raw_gate[i] = is_active
    end
  end

  -- Asymmetric envelope follower (Attack: ~100ms, Release: ~60ms)
  local attack_coef = math.exp(-frame_dur / 0.10)
  local release_coef = math.exp(-frame_dur / 0.06)
  local current_env = 0.0

  for i = 1, n do
    local target = raw_gate[i] and 1.0 or 0.0
    if target > current_env then
      current_env = target + (current_env - target) * attack_coef
    else
      current_env = target + (current_env - target) * release_coef
    end
    weights[i] = current_env > 0.05 and current_env or 0.0
  end

  return weights
end

local function extract_note_features(note, preserve_controls)
  if note.count == 0 or not note.frames or #note.frames == 0 then return end

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

  -- 2. Zero-phase Gaussian filtering for smooth pitch and low-frequency drift trend
  --    Smooth pitch (sigma ~1.5 frames) removes micro-jitters without phase distortion
  --    Trend (sigma ~7.0 frames, ~2 Hz cutoff) isolates slow drift without vibrato ripple
  local smooth_pitch = gaussian_filter(raw_pitch, 1.5)
  local trend = gaussian_filter(raw_pitch, 7.0)

  -- 3. Calculate Modulation: clean, zero-phase vibrato waveform
  local mod = {}
  for i = 1, #raw_pitch do
    mod[i] = smooth_pitch[i] - trend[i]
  end

  -- 4. Calculate robust pitch center (energy-weighted median/mean of sustained core)
  --    Excludes initial onset scoop (first 12%) and release tail (last 12%)
  local total_w = 0
  local weighted_sum = 0
  local start_f = math.max(1, math.floor(#note.frames * 0.12))
  local end_f = math.min(#note.frames, math.ceil(#note.frames * 0.88))
  for i = start_f, end_f do
    local f = note.frames[i]
    local w = math.max(0.0001, (f.rms or 0.05))
    weighted_sum = weighted_sum + f.note * w
    total_w = total_w + w
  end
  if total_w > 0 then
    note.avg_note = weighted_sum / total_w
    note.display_note = math.floor(note.avg_note + 0.5)
  end

  -- 5. Find Smart Spots via Zero-Crossing (for visual rendering / anchor points)
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
      -- Zero crossing! Save the previous extrema if it's prominent enough
      if math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
        local s_type = current_sign == 1 and "peak" or "valley"
        table.insert(smart_spots, { index = extrema_idx, time = note.frames[extrema_idx].time, type = s_type, mod_val = extrema_val })
      end
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    end
  end

  if extrema_idx and math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
    local s_type = current_sign == 1 and "peak" or "valley"
    table.insert(smart_spots, { index = extrema_idx, time = note.frames[extrema_idx].time, type = s_type, mod_val = extrema_val })
  end

  table.insert(smart_spots, { index = #raw_pitch, time = note.frames[#raw_pitch].time, type = "anchor_end" })

  note.trend = trend
  note.modulation = mod
  note.smart_spots = smart_spots

  -- 6. Vibrato detection with Schmitt trigger hysteresis & asymmetric envelope follower
  local total_dur = note.end_time - note.start_time
  local frame_dur = #note.frames > 1
    and (note.frames[#note.frames].time - note.frames[1].time) / (#note.frames - 1)
    or 0.012

  note.vibrato_weight = compute_vibrato_weights(mod, frame_dur, total_dur)

  -- Default controls: NO correction (green preview = raw pitch)
  note.controls = {
    center_pitch = note.avg_note,
    drift_scale = 1.0,
    vibrato_scale = 1.0,
    transition_ms = 35
  }

  -- Restore user tuning offsets when splitting/merging notes
  if preserve_controls then
    for k, v in pairs(preserve_controls) do
      note.controls[k] = v
    end
  end

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
local quantize_selected_notes_to_scale
local split_note_at
local merge_selected_notes
local trim_note_edge

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
    notes = {},
    key_idx = data.key_idx or state.key_idx,
    scale_idx = data.scale_idx or state.scale_idx
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

local function save_current_scale_settings()
  reaper.SetExtState("FancyScripts", "pitch_key_idx", tostring(state.key_idx), true)
  reaper.SetExtState("FancyScripts", "pitch_scale_idx", tostring(state.scale_idx), true)
  if state.target_take_guid and state.session_takes[state.target_take_guid] then
    local data = state.session_takes[state.target_take_guid]
    data.key_idx = state.key_idx
    data.scale_idx = state.scale_idx
    local take = resolve_take_by_guid(state.target_take_guid)
    if take then save_take_data(take, data) end
  end
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
    state.selected_notes = {}
    state.hovered_note = nil
    state.drag = nil
    state.marquee = nil

    if data.key_idx then state.key_idx = data.key_idx end
    if data.scale_idx then state.scale_idx = data.scale_idx end
    update_scale_pitch_classes()

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

local function apply_envelope_to_take(undo_desc)
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

  local item_len = math.max(0.1, reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))

  -- Clear existing points across the entire item
  reaper.DeleteEnvelopePointRange(env, 0, item_len + 1.0)

  local SHAPE = 5   -- Bezier
  local TENSION = 0 -- Neutral tension

  if not state.notes or #state.notes == 0 then
    reaper.Envelope_SortPointsEx(env, -1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)
    return
  end

  -- Check if any note in the phrase is modified
  local any_modified = false
  for _, n in ipairs(state.notes) do
    if is_note_modified(n) then
      any_modified = true
      break
    end
  end

  if not any_modified then
    -- Clean envelope: untouched takes have no points
    reaper.Envelope_SortPointsEx(env, -1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)
    if state.target_take_guid and state.session_takes[state.target_take_guid] then
      state.session_takes[state.target_take_guid].notes = state.notes
      save_take_data(take, state.session_takes[state.target_take_guid])
    end
    return
  end

  -- 1. Precalculate continuous frame shifts for every note
  for _, n in ipairs(state.notes) do
    n.frame_shifts = {}
    local is_mod = is_note_modified(n)
    local coarse = is_mod and (n.controls.center_pitch - n.avg_note) or 0.0
    local d_scale = (n.controls and n.controls.drift_scale) or 1.0
    local v_scale = (n.controls and n.controls.vibrato_scale) or 1.0
    if n.frames then
      for i = 1, #n.frames do
        if not is_mod then
          n.frame_shifts[i] = 0.0
        else
          local vw = (n.vibrato_weight and n.vibrato_weight[i]) or 0.0
          local drift_corr = (n.trend and n.trend[i]) and ((n.trend[i] - n.avg_note) * (d_scale - 1.0)) or 0.0
          local vib_corr = (n.modulation and n.modulation[i]) and (n.modulation[i] * (v_scale - 1.0) * vw) or 0.0
          n.frame_shifts[i] = coarse + drift_corr + vib_corr
        end
      end
    end
  end

  -- 2. Build continuous trajectory across notes and boundaries
  local all_points = {}
  local num_notes = #state.notes

  for idx = 1, num_notes do
    local n = state.notes[idx]
    local prev_n = state.notes[idx - 1]
    local next_n = state.notes[idx + 1]

    local is_mod = is_note_modified(n)
    local prev_mod = is_note_modified(prev_n)
    local next_mod = is_note_modified(next_n)

    -- If this note and both its neighbors are untouched, skip entirely
    if not is_mod and not prev_mod and not next_mod then
      goto continue_note
    end

    local start_shift = (n.frame_shifts and n.frame_shifts[1]) or 0.0
    local end_shift = (n.frame_shifts and n.frame_shifts[#n.frame_shifts]) or 0.0

    local trans_dur = math.min(((n.controls and n.controls.transition_ms) or 35) * 0.001, 0.060)
    trans_dur = math.min(trans_dur, (n.end_time - n.start_time) * 0.4)

    local is_legato_prev = false
    local is_legato_next = false

    -- A. START TRANSITION
    local prev_gap = prev_n and (n.start_time - prev_n.end_time) or 999
    if prev_gap < 0.12 and prev_n then
      is_legato_prev = true
      -- Legato transition with previous note: smoothstep blend centered at boundary
      local prev_end_shift = (prev_n.frame_shifts and prev_n.frame_shifts[#prev_n.frame_shifts]) or 0.0
      local t_bnd = (prev_n.end_time + n.start_time) * 0.5
      local t_start = math.max(0.0, t_bnd - trans_dur * 0.5)
      local t_end = math.min(item_len, t_bnd + trans_dur * 0.5)

      local steps = 5
      for s = 0, steps do
        local u = s / steps
        local t = t_start + u * (t_end - t_start)
        local val = prev_end_shift + (start_shift - prev_end_shift) * smoothstep(u)
        table.insert(all_points, { time = t, val = val })
      end
    else
      -- Onset from silence / start of take: smooth ramp into pitch shift
      if is_mod and math.abs(start_shift) > 0.001 then
        local ramp_t = math.min(0.035, (n.end_time - n.start_time) * 0.25)
        local t_pre = math.max(0.0, n.start_time - ramp_t)
        table.insert(all_points, { time = t_pre, val = 0.0 })
        local steps = 4
        for s = 1, steps do
          local u = s / steps
          local t = t_pre + u * (n.start_time - t_pre)
          local val = start_shift * smoothstep(u)
          table.insert(all_points, { time = t, val = val })
        end
      end
    end

    -- B. NOTE BODY
    local fine_changed = is_mod and (((n.controls.drift_scale or 1.0) ~= 1.0) or ((n.controls.vibrato_scale or 1.0) ~= 1.0))
    local body_t_start = n.start_time + trans_dur * 0.5
    local body_t_end = n.end_time - trans_dur * 0.5

    if not fine_changed then
      -- Coarse shift or untouched: hold shift across body
      if is_mod then
        table.insert(all_points, { time = math.min(item_len, body_t_start), val = start_shift })
        table.insert(all_points, { time = math.min(item_len, body_t_end), val = end_shift })
      end
    else
      -- Fine contour: sample frames across body to counteract drift / scale vibrato
      if n.frames then
        for i = 1, #n.frames do
          local t = n.frames[i].time
          if t >= body_t_start and t <= body_t_end then
            table.insert(all_points, { time = math.min(item_len, t), val = n.frame_shifts[i] })
          end
        end
      end
    end

    -- C. END TRANSITION TO SILENCE (if next note is far or this is last note)
    local next_gap = next_n and (next_n.start_time - n.end_time) or 999
    if next_gap >= 0.12 then
      if is_mod and math.abs(end_shift) > 0.001 then
        local ramp_t = math.min(0.035, (n.end_time - n.start_time) * 0.25)
        local steps = 4
        for s = 1, steps do
          local u = s / steps
          local t = math.min(item_len, n.end_time + u * ramp_t)
          local val = end_shift * (1.0 - smoothstep(u))
          table.insert(all_points, { time = t, val = val })
        end
        local t_post = math.min(item_len, n.end_time + ramp_t + 0.001)
        table.insert(all_points, { time = t_post, val = 0.0 })
      end
    else
      is_legato_next = true
    end

    -- Store onset debug info
    n.onset_debug = {
      onset_ramp_ms = trans_dur * 1000,
      scoop_st = n.scoop_magnitude or 0,
      voicing_delay_ms = 0,
      is_legato_prev = is_legato_prev,
      is_legato_next = is_legato_next
    }

    ::continue_note::
  end

  -- 3. Adaptive decimation with sub-cent tolerance (0.01 st / 1 cent)
  local simplified = rdp_simplify(all_points, 0.01)
  for _, pt in ipairs(simplified) do
    local t = math.max(0.0, math.min(item_len, pt.time))
    reaper.InsertEnvelopePointEx(env, -1, t, pt.val, SHAPE, TENSION, 0, true)
  end

  reaper.Envelope_SortPointsEx(env, -1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)

  -- Update session cache and persist edits to take P_EXT
  if state.target_take_guid and state.session_takes[state.target_take_guid] then
    state.session_takes[state.target_take_guid].notes = state.notes
    save_take_data(take, state.session_takes[state.target_take_guid])
  end
end

local function find_nearest_in_scale_pitch(pitch)
  local clamped_pitch = math.max(0, math.min(127, pitch))
  local nearest_st = math.floor(clamped_pitch + 0.5)
  local best_cand = nearest_st
  local min_diff = 999999

  for dist = 0, 12 do
    local cands = (dist == 0) and { nearest_st } or { nearest_st + dist, nearest_st - dist }
    for _, cand in ipairs(cands) do
      if cand >= 0 and cand <= 127 then
        local pc = (cand % 12 + 12) % 12
        if is_pitch_in_scale(pc) then
          local diff = math.abs(cand - clamped_pitch)
          if diff < min_diff then
            min_diff = diff
            best_cand = cand
          end
        end
      end
    end
    if min_diff <= dist + 0.5 then
      break
    end
  end

  return best_cand
end

-- Snaps selected note(s) to the nearest valid in-scale pitch (Milestone 3: Quantize Key).
quantize_selected_notes_to_scale = function()
  if not state.notes then return end
  local any_changed = false
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then return end

  for _, idx in ipairs(indices) do
    local note = state.notes[idx]
    if note and note.controls then
      local target_pitch = find_nearest_in_scale_pitch(note.controls.center_pitch)
      if math.abs(note.controls.center_pitch - target_pitch) > 0.001 then
        note.controls.center_pitch = target_pitch
        any_changed = true
      end
    end
  end

  if any_changed then
    apply_envelope_to_take("Quantize Pitch to Scale")
  end
end

-- Resets the selected note(s) back to [Untouched], clearing envelope contribution.
reset_selected_note = function()
  if not state.notes then return end
  local any_changed = false
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then
    for i = 1, #state.notes do
      table.insert(indices, i)
    end
  end
  if #indices == 0 then return end

  for _, idx in ipairs(indices) do
    local sel = state.notes[idx]
    if sel and sel.controls then
      sel.controls.center_pitch = sel.avg_note
      sel.controls.drift_scale = 1.0
      sel.controls.vibrato_scale = 1.0
      any_changed = true
    end
  end

  if any_changed then
    apply_envelope_to_take("Reset Pitch Correction")
  end
end

-- Snaps selected note(s) to the nearest exact semitone (0¢ deviation).
snap_selected_note = function()
  if not state.notes then return end
  local any_changed = false
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then return end

  for _, idx in ipairs(indices) do
    local sel = state.notes[idx]
    if sel and sel.controls then
      local target_pitch = math.floor(sel.controls.center_pitch + 0.5)
      if math.abs(sel.controls.center_pitch - target_pitch) > 0.001 then
        sel.controls.center_pitch = target_pitch
        any_changed = true
      end
    end
  end

  if any_changed then
    apply_envelope_to_take("Snap Note to Semitone")
  end
end

-------------------------------------------------------------------------------
-- NOTE TOPOLOGY: SPLIT, MERGE & EDGE TRIMMING
-------------------------------------------------------------------------------

-- Splits the note at note_idx into two independent notes at split_time.
-- Preserves user tuning offsets on both halves and re-extracts features.
split_note_at = function(note_idx, split_time)
  if not state.notes or not state.notes[note_idx] then return end
  local note = state.notes[note_idx]
  if not note.frames or #note.frames < 6 then return end -- need at least 3 per half
  if split_time <= note.start_time or split_time >= note.end_time then return end

  -- Partition frames
  local frames_a = {}
  local frames_b = {}
  for _, frame in ipairs(note.frames) do
    if frame.time < split_time then
      table.insert(frames_a, frame)
    else
      table.insert(frames_b, frame)
    end
  end

  -- Validate minimum size (3 frames, ~35ms)
  if #frames_a < 3 or #frames_b < 3 then
    reaper.ShowConsoleMsg("Split: both halves need at least 3 frames.\n")
    return
  end

  -- Preserve the user's pitch offset (semitones from original avg)
  local old_ctrl = note.controls
  local pitch_offset = old_ctrl and (old_ctrl.center_pitch - note.avg_note) or 0

  -- Build note A (left half)
  local sum_a = 0
  for _, f in ipairs(frames_a) do sum_a = sum_a + f.note end
  local avg_a = sum_a / #frames_a
  local note_a = {
    start_time = frames_a[1].time,
    end_time = frames_a[#frames_a].time,
    sum_note = sum_a,
    count = #frames_a,
    avg_note = avg_a,
    display_note = math.floor(avg_a + 0.5),
    frames = frames_a,
  }
  extract_note_features(note_a, {
    center_pitch = avg_a + pitch_offset,
    drift_scale = old_ctrl and old_ctrl.drift_scale or 1.0,
    vibrato_scale = old_ctrl and old_ctrl.vibrato_scale or 1.0,
    transition_ms = old_ctrl and old_ctrl.transition_ms or 35,
  })

  -- Build note B (right half)
  local sum_b = 0
  for _, f in ipairs(frames_b) do sum_b = sum_b + f.note end
  local avg_b = sum_b / #frames_b
  local note_b = {
    start_time = frames_b[1].time,
    end_time = frames_b[#frames_b].time,
    sum_note = sum_b,
    count = #frames_b,
    avg_note = avg_b,
    display_note = math.floor(avg_b + 0.5),
    frames = frames_b,
  }
  extract_note_features(note_b, {
    center_pitch = avg_b + pitch_offset,
    drift_scale = old_ctrl and old_ctrl.drift_scale or 1.0,
    vibrato_scale = old_ctrl and old_ctrl.vibrato_scale or 1.0,
    transition_ms = old_ctrl and old_ctrl.transition_ms or 35,
  })

  -- Splice into notes array
  state.notes[note_idx] = note_a
  table.insert(state.notes, note_idx + 1, note_b)

  -- Update selection: select left half, adjust any indices above split
  state.selected_note = note_idx
  state.selected_notes = { [note_idx] = true }

  apply_envelope_to_take()
end

-- Merges all contiguous selected notes into a single note.
-- Uses duration-weighted pitch averaging to preserve user tuning intent.
merge_selected_notes = function()
  if not state.notes or not state.selected_notes then return end

  -- Collect and sort selected indices
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  table.sort(indices)

  if #indices < 2 then return end -- need at least 2 notes to merge

  -- Validate contiguity: indices must be consecutive
  for i = 2, #indices do
    if indices[i] ~= indices[i - 1] + 1 then
      reaper.ShowConsoleMsg("Merge: selected notes must be adjacent.\n")
      return
    end
  end

  -- Validate gap size: no gap > 300ms between any pair
  for i = 2, #indices do
    local prev_note = state.notes[indices[i - 1]]
    local curr_note = state.notes[indices[i]]
    local gap = curr_note.start_time - prev_note.end_time
    if gap > 0.3 then
      reaper.ShowConsoleMsg("Merge: gap between notes exceeds 300ms.\n")
      return
    end
  end

  local first_note = state.notes[indices[1]]
  local last_note = state.notes[indices[#indices]]

  -- Concatenate frames from all selected notes + recover gap frames
  local merged_frames = {}
  for i, idx in ipairs(indices) do
    local n = state.notes[idx]

    -- Before this note (except the first), try to recover gap frames
    if i > 1 then
      local prev_n = state.notes[indices[i - 1]]
      local gap_start = prev_n.end_time
      local gap_end = n.start_time
      if gap_end > gap_start then
        for _, frame in ipairs(state.results) do
          if frame.time > gap_start and frame.time < gap_end
              and frame.note and frame.rms and frame.rms > 0.005 then
            table.insert(merged_frames, frame)
          end
        end
      end
    end

    -- Add this note's frames
    for _, frame in ipairs(n.frames) do
      table.insert(merged_frames, frame)
    end
  end

  if #merged_frames < 3 then return end

  -- Duration-weighted pitch target from user tuning
  local total_dur = 0
  local weighted_pitch = 0
  local weighted_drift = 0
  local weighted_vibrato = 0
  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    local dur = n.end_time - n.start_time
    total_dur = total_dur + dur
    if n.controls then
      weighted_pitch = weighted_pitch + n.controls.center_pitch * dur
      weighted_drift = weighted_drift + n.controls.drift_scale * dur
      weighted_vibrato = weighted_vibrato + n.controls.vibrato_scale * dur
    else
      weighted_pitch = weighted_pitch + n.avg_note * dur
      weighted_drift = weighted_drift + 1.0 * dur
      weighted_vibrato = weighted_vibrato + 1.0 * dur
    end
  end

  local sum_note = 0
  for _, f in ipairs(merged_frames) do sum_note = sum_note + f.note end
  local avg_note = sum_note / #merged_frames

  local merged = {
    start_time = first_note.start_time,
    end_time = last_note.end_time,
    sum_note = sum_note,
    count = #merged_frames,
    avg_note = avg_note,
    display_note = math.floor(avg_note + 0.5),
    frames = merged_frames,
  }

  extract_note_features(merged, {
    center_pitch = total_dur > 0 and (weighted_pitch / total_dur) or avg_note,
    drift_scale = total_dur > 0 and (weighted_drift / total_dur) or 1.0,
    vibrato_scale = total_dur > 0 and (weighted_vibrato / total_dur) or 1.0,
    transition_ms = first_note.controls and first_note.controls.transition_ms or 35,
  })

  -- Replace in array: put merged note at first index, remove the rest
  local first_idx = indices[1]
  state.notes[first_idx] = merged
  for i = #indices, 2, -1 do
    table.remove(state.notes, indices[i])
  end

  -- Update selection
  state.selected_note = first_idx
  state.selected_notes = { [first_idx] = true }

  apply_envelope_to_take()
end

-- Trims the left or right edge of a note to a new time boundary.
-- Filters or extends frames, preserves pitch offset, re-extracts features.
trim_note_edge = function(note_idx, edge, new_time)
  if not state.notes or not state.notes[note_idx] then return end
  local note = state.notes[note_idx]
  if not note.frames or #note.frames < 3 then return end

  local min_dur = 0.05 -- 50ms minimum note duration
  local gap_margin = 0.005 -- 5ms gap to prevent overlap

  -- Clamp to prevent overlap with neighbors
  if edge == "left" then
    local prev_note = state.notes[note_idx - 1]
    local min_t = prev_note and (prev_note.end_time + gap_margin) or 0
    local max_t = note.end_time - min_dur
    new_time = math.max(min_t, math.min(max_t, new_time))
  elseif edge == "right" then
    local next_note = state.notes[note_idx + 1]
    local min_t = note.start_time + min_dur
    local max_t = next_note and (next_note.start_time - gap_margin) or state.end_time
    new_time = math.max(min_t, math.min(max_t, new_time))
  else
    return
  end

  -- Preserve pitch offset
  local old_ctrl = note.controls
  local pitch_offset = old_ctrl and (old_ctrl.center_pitch - note.avg_note) or 0

  -- Rebuild frames within the new boundary
  local new_start = (edge == "left") and new_time or note.start_time
  local new_end = (edge == "right") and new_time or note.end_time

  -- Collect frames: from existing note + from state.results for any extensions
  local frame_set = {} -- time → frame (deduplicate)
  for _, frame in ipairs(note.frames) do
    if frame.time >= new_start and frame.time <= new_end then
      frame_set[frame.time] = frame
    end
  end

  -- If extending, pull in unassigned frames from the raw results pool
  if (edge == "left" and new_time < note.start_time)
      or (edge == "right" and new_time > note.end_time) then
    for _, frame in ipairs(state.results) do
      if frame.time >= new_start and frame.time <= new_end
          and frame.note and frame.rms and frame.rms > 0.005
          and not frame_set[frame.time] then
        frame_set[frame.time] = frame
      end
    end
  end

  -- Sort frames by time
  local new_frames = {}
  for _, frame in pairs(frame_set) do
    table.insert(new_frames, frame)
  end
  table.sort(new_frames, function(a, b) return a.time < b.time end)

  if #new_frames < 3 then return end -- too few frames remaining

  -- Rebuild note
  local sum_note = 0
  for _, f in ipairs(new_frames) do sum_note = sum_note + f.note end
  local avg_note = sum_note / #new_frames

  note.start_time = new_start
  note.end_time = new_end
  note.frames = new_frames
  note.sum_note = sum_note
  note.count = #new_frames
  note.avg_note = avg_note
  note.display_note = math.floor(avg_note + 0.5)

  extract_note_features(note, {
    center_pitch = avg_note + pitch_offset,
    drift_scale = old_ctrl and old_ctrl.drift_scale or 1.0,
    vibrato_scale = old_ctrl and old_ctrl.vibrato_scale or 1.0,
    transition_ms = old_ctrl and old_ctrl.transition_ms or 35,
  })

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
        notes = state.notes,
        key_idx = state.key_idx,
        scale_idx = state.scale_idx
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
  reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + h, P.bg)
  reaper.ImGui_DrawList_AddRect(draw_list, px, py, px + w, py + h, P.border)

  local piano_w = 40
  local full_px = px
  local full_w = w
  px = px + piano_w
  w = w - piano_w

  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, full_px + full_w, py + h, true)

  local target_take = get_target_take(false)
  local is_bypassed = is_take_pitch_bypassed(target_take)

  if #state.results == 0 then
    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5

    local btn_w = 180
    local btn_h = 42
    local gap = 14

    local msg = "No data. Select an item and click Analyze."
    local text_w, text_h = reaper.ImGui_CalcTextSize(draw_ctx, msg)
    local total_block_h = btn_h + gap + text_h
    local start_y = cy - total_block_h * 0.5

    local btn_x = cx - btn_w * 0.5
    local btn_y = start_y

    local can_analyze = (target_take ~= nil and not state.is_analyzing)
    local mx, my = reaper.ImGui_GetMousePos(draw_ctx)
    local is_btn_hov = can_analyze and is_canvas_hovered and (mx >= btn_x and mx <= btn_x + btn_w and my >= btn_y and my <= btn_y + btn_h)
    local is_btn_down = is_btn_hov and reaper.ImGui_IsMouseDown(draw_ctx, 0)
    if is_btn_hov and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
      start_analysis()
    end

    -- Draw button background & border
    local btn_bg = not can_analyze and P.card
      or (is_btn_down and P.accent or (is_btn_hov and P.accent_h or P.accent_d))
    local btn_border = is_btn_hov and P.accent or P.border
    reaper.ImGui_DrawList_AddRectFilled(draw_list, btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, btn_bg, 6.0)
    reaper.ImGui_DrawList_AddRect(draw_list, btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, btn_border, 6.0, 0, 1.5)

    -- Draw button text
    local btn_txt = "Analyze Item"
    local pushed_btn_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
    local btw, bth = reaper.ImGui_CalcTextSize(draw_ctx, btn_txt)
    Theme.pop_font(draw_ctx, pushed_btn_font)

    local btn_txt_col = can_analyze and 0xFFFFFFFF or P.text_dim
    reaper.ImGui_DrawList_AddText(draw_list, cx - btw * 0.5, btn_y + (btn_h - bth) * 0.5, btn_txt_col, btn_txt)

    if is_btn_hov then
      Theme.tooltip(draw_ctx, "Run YIN pitch detection on selected audio item")
    end

    -- Centered text below button
    local text_x = cx - text_w * 0.5
    local text_y = btn_y + btn_h + gap
    reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, P.text_dim, msg)

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

  -- Hit-test: find hovered note, zone, and edge handles
  local edge_handle_px = 5 -- pixels for edge grab zone
  if is_canvas_hovered and not is_bypassed and not state.drag and not state.edge_drag and not state.marquee and state.notes then
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
    for n_idx, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        local sx = px + ((note.start_time - state.start_time) / duration) * w
        local ex = px + ((note.end_time - state.start_time) / duration) * w
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h

        -- Check edge handles first (higher priority than zone hover)
        if my >= top_y and my <= bot_y then
          if math.abs(mx - sx) <= edge_handle_px then
            state.hovered_edge = { note_idx = n_idx, edge = "left" }
            state.hovered_note = n_idx
            state.hovered_zone = nil
            break
          elseif math.abs(mx - ex) <= edge_handle_px then
            state.hovered_edge = { note_idx = n_idx, edge = "right" }
            state.hovered_note = n_idx
            state.hovered_zone = nil
            break
          end
        end

        -- Standard zone hit-test (only if no edge match)
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

    -- Set cursor for edge hover
    if state.hovered_edge then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    end
  elseif (not is_canvas_hovered or is_bypassed) and not state.drag and not state.edge_drag and not state.marquee then
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
  end

  -- Click: select note (Shift/Cmd/Ctrl = multi-select), begin drag, edge drag, or marquee box select
  if is_canvas_hovered and not is_bypassed and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
    get_target_take(true)

    -- Resolve modifiers for selection modes (cross-platform macOS/Win/Linux)
    local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
    local ctrl_mod = reaper.ImGui_Mod_Ctrl and reaper.ImGui_Mod_Ctrl() or 0
    local super_mod = reaper.ImGui_Mod_Super and reaper.ImGui_Mod_Super() or 0
    local ok_mods, cur_mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
    local has_shift = ok_mods and cur_mods and (cur_mods & shift_mod) ~= 0
    local has_cmd_or_ctrl = ok_mods and cur_mods and (((cur_mods & ctrl_mod) ~= 0) or ((cur_mods & super_mod) ~= 0))

    if state.hovered_edge then
      -- Edge click → start edge drag (trimming)
      local he = state.hovered_edge
      local note = state.notes[he.note_idx]
      state.selected_note = he.note_idx
      state.selected_notes = { [he.note_idx] = true }
      state.edge_drag = {
        note_idx = he.note_idx,
        edge = he.edge,
        start_mouse_x = mx,
        original_time = (he.edge == "left") and note.start_time or note.end_time,
        dirty = false
      }
    elseif state.hovered_note then
      -- Note click → update selection and prepare pitch / drift (stability) / vibrato drag
      if has_shift and state.selected_note then
        -- Shift+Click: range select from primary anchor to clicked note
        local lo = math.min(state.selected_note, state.hovered_note)
        local hi = math.max(state.selected_note, state.hovered_note)
        state.selected_notes = {}
        for i = lo, hi do
          state.selected_notes[i] = true
        end
        -- Primary anchor remains unchanged for range expansion
      elseif has_cmd_or_ctrl then
        -- Cmd/Ctrl+Click: toggle individual note in/out of selection
        if state.selected_notes[state.hovered_note] then
          state.selected_notes[state.hovered_note] = nil
          if state.selected_note == state.hovered_note then
            state.selected_note = next(state.selected_notes)
          end
        else
          state.selected_notes[state.hovered_note] = true
          state.selected_note = state.hovered_note
        end
      else
        -- Normal click
        local pending_single_select = nil
        if state.selected_notes[state.hovered_note] then
          local cur_count = 0
          for _ in pairs(state.selected_notes) do cur_count = cur_count + 1 end
          if cur_count > 1 then
            -- Clicked an already-selected note in a group: preserve selection for multi-drag.
            -- If mouse is released without dragging beyond deadzone, collapse to this note.
            pending_single_select = state.hovered_note
            state.selected_note = state.hovered_note
          end
        else
          -- Clicked an unselected note: select only this note
          state.selected_note = state.hovered_note
          state.selected_notes = { [state.hovered_note] = true }
        end

        local orig_values = {}
        for idx in pairs(state.selected_notes) do
          local n = state.notes[idx]
          if n and n.controls then
            if state.hovered_zone == "pitch" then
              orig_values[idx] = n.controls.center_pitch
            elseif state.hovered_zone == "drift" then
              orig_values[idx] = n.controls.drift_scale
            else
              orig_values[idx] = n.controls.vibrato_scale
            end
          end
        end

        state.drag = {
          note_idx = state.hovered_note,
          anchor_idx = state.hovered_note,
          zone = state.hovered_zone,
          start_mouse_y = my,
          original_value = orig_values[state.hovered_note] or 0,
          orig_values = orig_values,
          pending_single_select = pending_single_select,
          dirty = false
        }
      end
    else
      -- Click on empty canvas: initiate marquee drag tracking
      local init_sel = {}
      if has_shift and state.selected_notes then
        for k, v in pairs(state.selected_notes) do init_sel[k] = v end
      end
      state.marquee = {
        start_x = mx,
        start_y = my,
        cur_x = mx,
        cur_y = my,
        active = false,
        has_shift = has_shift,
        init_sel = init_sel
      }
    end
  end

  -- Process active drag (Single-note or Multi-note batch drag: Pitch, Stability, Vibrato)
  if state.drag then
    local delta_y = state.drag.start_mouse_y - my -- up = positive

    if math.abs(delta_y) > 2 then -- dead zone: click vs. drag
      state.drag.dirty = true
      state.drag.pending_single_select = nil -- drag occurred, cancel single-select collapse

      if state.drag.zone == "pitch" then
        local delta_st = delta_y / px_per_st
        local effective_delta = delta_st

        -- Shift modifier = snap anchor note to semitones, preserving phrase musical intervals
        local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
        if shift_mod > 0 then
          local ok, mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
          if ok and mods and (mods & shift_mod) ~= 0 then
            local anchor_orig = state.drag.orig_values[state.drag.anchor_idx]
            if anchor_orig then
              local target_pitch = math.floor(anchor_orig + delta_st + 0.5)
              effective_delta = target_pitch - anchor_orig
            else
              effective_delta = math.floor(delta_st + 0.5)
            end
          end
        end

        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.center_pitch = orig_val + effective_delta
          end
        end
      elseif state.drag.zone == "drift" then
        -- Stability drag: up = more stable = less drift = lower drift_scale
        local delta = delta_y / (px_per_st * 2)
        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.drift_scale = math.max(0, math.min(1, orig_val - delta))
          end
        end
      elseif state.drag.zone == "vibrato" then
        -- Vibrato scale drag
        local delta = delta_y / px_per_st
        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.vibrato_scale = math.max(0, math.min(2, orig_val + delta))
          end
        end
      end
    end

    -- End drag → commit envelope to take or resolve single click
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.drag.dirty then
        local count = 0
        for _ in pairs(state.drag.orig_values) do count = count + 1 end
        local action_name = (state.drag.zone == "pitch" and "Pitch Shift" or
                            (state.drag.zone == "drift" and "Adjust Stability" or "Adjust Vibrato"))
        local undo_title = count > 1 and string.format("%s (%d notes)", action_name, count) or action_name
        apply_envelope_to_take(undo_title)
      elseif state.drag.pending_single_select then
        -- Released without dragging: collapse multi-selection to clicked note
        state.selected_note = state.drag.pending_single_select
        state.selected_notes = { [state.drag.pending_single_select] = true }
      end
      state.drag = nil
    end
  end

  -- Process active edge drag (trimming)
  if state.edge_drag then
    reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    local delta_x = mx - state.edge_drag.start_mouse_x
    if math.abs(delta_x) > 3 then -- horizontal dead zone
      state.edge_drag.dirty = true
      -- Convert pixel delta to time delta
      local delta_time = (delta_x / w) * duration
      local new_time = state.edge_drag.original_time + delta_time
      -- Live preview: update note boundary directly (no feature re-extraction during drag)
      local ed_note = state.notes[state.edge_drag.note_idx]
      if ed_note then
        if state.edge_drag.edge == "left" then
          -- Clamp: don't go past end_time - 50ms, don't overlap previous note
          local prev_note = state.notes[state.edge_drag.note_idx - 1]
          local min_t = prev_note and (prev_note.end_time + 0.005) or 0
          new_time = math.max(min_t, math.min(ed_note.end_time - 0.05, new_time))
          ed_note.start_time = new_time
        else
          -- Clamp: don't go before start_time + 50ms, don't overlap next note
          local next_note = state.notes[state.edge_drag.note_idx + 1]
          local max_t = next_note and (next_note.start_time - 0.005) or state.end_time
          new_time = math.max(ed_note.start_time + 0.05, math.min(max_t, new_time))
          ed_note.end_time = new_time
        end
      end
    end

    -- End edge drag → commit trim
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.edge_drag.dirty then
        local ed = state.edge_drag
        local ed_note = state.notes[ed.note_idx]
        -- Capture the dragged-to position before restoring original boundary
        local target_time = (ed.edge == "left") and ed_note.start_time or ed_note.end_time
        -- Restore original boundary so trim_note_edge can detect extend vs shrink
        if ed.edge == "left" then
          ed_note.start_time = ed.original_time
        else
          ed_note.end_time = ed.original_time
        end
        trim_note_edge(ed.note_idx, ed.edge, target_time)
      else
        -- No movement beyond dead zone — restore boundary in case of micro-drift
        local ed = state.edge_drag
        local ed_note = state.notes[ed.note_idx]
        if ed_note then
          if ed.edge == "left" then
            ed_note.start_time = ed.original_time
          else
            ed_note.end_time = ed.original_time
          end
        end
      end
      state.edge_drag = nil
    end
  end

  -- Process active marquee box select (Milestone 4)
  if state.marquee then
    local delta_x = mx - state.marquee.start_x
    local delta_y = my - state.marquee.start_y

    if not state.marquee.active then
      if math.abs(delta_x) > 3 or math.abs(delta_y) > 3 then
        state.marquee.active = true
      end
    end

    if state.marquee.active then
      state.marquee.cur_x = mx
      state.marquee.cur_y = my

      local bx1 = math.min(state.marquee.start_x, state.marquee.cur_x)
      local bx2 = math.max(state.marquee.start_x, state.marquee.cur_x)
      local by1 = math.min(state.marquee.start_y, state.marquee.cur_y)
      local by2 = math.max(state.marquee.start_y, state.marquee.cur_y)

      local new_sel = {}
      if state.marquee.has_shift and state.marquee.init_sel then
        for k, v in pairs(state.marquee.init_sel) do
          new_sel[k] = v
        end
      end

      if state.notes then
        for n_idx, note in ipairs(state.notes) do
          if note.controls then
            local cp = note.controls.center_pitch
            local sx = px + ((note.start_time - state.start_time) / duration) * w
            local ex = px + ((note.end_time - state.start_time) / duration) * w
            local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
            local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h

            -- AABB intersection check
            if sx <= bx2 and ex >= bx1 and top_y <= by2 and bot_y >= by1 then
              new_sel[n_idx] = true
            end
          end
        end
      end

      state.selected_notes = new_sel

      -- Maintain valid primary selected note
      if not (state.selected_note and state.selected_notes[state.selected_note]) then
        local first_idx = nil
        if state.notes then
          for idx = 1, #state.notes do
            if state.selected_notes[idx] then
              first_idx = idx
              break
            end
          end
        end
        state.selected_note = first_idx
      end
    end

    -- End marquee
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if not state.marquee.active then
        -- Clicked on empty canvas without dragging: deselect and move edit cursor
        if not state.marquee.has_shift then
          state.selected_note = nil
          state.selected_notes = {}
        end
        local rel_x = (state.marquee.start_x - px) / w
        rel_x = math.max(0, math.min(1, rel_x))
        local item_time = state.start_time + rel_x * duration
        local _, item = get_target_take(false)
        if item then
          local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          reaper.SetEditCurPos(item_pos + item_time, false, false)
        end
      end
      state.marquee = nil
    end
  end

  ---------------------------------------------------------------------------
  -- KEYBOARD CONTROLS (Scalpel Workflow)
  ---------------------------------------------------------------------------
  -- Guard: skip keyboard shortcuts if any widget (combo, input, slider)
  -- is active — prevents arrow keys from leaking into toolbar combos.
  local ok_aia, any_active = pcall(reaper.ImGui_IsAnyItemActive, draw_ctx)
  local widget_capturing = ok_aia and any_active

  if not state.drag and not state.edge_drag and not widget_capturing and state.notes and #state.notes > 0 then
    -- Resolve modifiers for shortcuts (cross-platform, no OS conflicts)
    local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
    local ctrl_mod = reaper.ImGui_Mod_Ctrl and reaper.ImGui_Mod_Ctrl() or 0
    local super_mod = reaper.ImGui_Mod_Super and reaper.ImGui_Mod_Super() or 0
    local ok_mods, cur_mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
    local has_shift = ok_mods and cur_mods and (cur_mods & shift_mod) ~= 0
    local has_cmd_or_ctrl = ok_mods and cur_mods and (((cur_mods & ctrl_mod) ~= 0) or ((cur_mods & super_mod) ~= 0))

    -- Cmd/Ctrl + A: Select All notes (Milestone 4)
    if reaper.ImGui_Key_A and reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_A()) and has_cmd_or_ctrl then
      state.selected_notes = {}
      for i = 1, #state.notes do
        state.selected_notes[i] = true
      end
      if not state.selected_note or not state.selected_notes[state.selected_note] then
        state.selected_note = 1
      end
    end

    -- Escape: Deselect all notes (Milestone 4)
    if reaper.ImGui_Key_Escape and reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Escape()) then
      state.selected_note = nil
      state.selected_notes = {}
    end

    -- Up / Down: Nudge pitch (±1 semitone, or ±10 cents with Shift)
    local has_selection = (state.selected_note and state.notes[state.selected_note])
      or (next(state.selected_notes) ~= nil)
    if has_selection then
      local sel = state.selected_note and state.notes[state.selected_note]

      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_UpArrow()) then
        get_target_take(true)
        local delta = has_shift and 0.10 or 1.0
        local indices = {}
        for idx in pairs(state.selected_notes) do
          if state.notes[idx] then table.insert(indices, idx) end
        end
        if #indices == 0 and sel then table.insert(indices, state.selected_note) end
        for _, idx in ipairs(indices) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.center_pitch = n.controls.center_pitch + delta
          end
        end
        apply_envelope_to_take("Nudge Pitch Up")
      end

      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_DownArrow()) then
        get_target_take(true)
        local delta = has_shift and 0.10 or 1.0
        local indices = {}
        for idx in pairs(state.selected_notes) do
          if state.notes[idx] then table.insert(indices, idx) end
        end
        if #indices == 0 and sel then table.insert(indices, state.selected_note) end
        for _, idx in ipairs(indices) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.center_pitch = n.controls.center_pitch - delta
          end
        end
        apply_envelope_to_take("Nudge Pitch Down")
      end

      -- S: Snap to nearest semitone
      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_S()) then
        get_target_take(true)
        snap_selected_note()
      end

      -- Q: Quantize selected note(s) to active scale (Milestone 3)
      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Q()) then
        get_target_take(true)
        quantize_selected_notes_to_scale()
      end

      -- R / Backspace / Delete: Reset to [Untouched]
      if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_R())
        or reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Backspace())
        or reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Delete()) then
        get_target_take(true)
        reset_selected_note()
      end

      -- X: Split note at edit cursor position
      if sel and reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_X()) then
        local _, item = get_target_take(false)
        if item then
          local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local cursor = reaper.GetCursorPosition() - item_pos
          if cursor > sel.start_time and cursor < sel.end_time then
            get_target_take(true)
            split_note_at(state.selected_note, cursor)
          end
        end
      end
    end

    -- M: Merge selected notes (requires 2+ contiguous selected)
    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_M()) then
      local sel_count = 0
      for _ in pairs(state.selected_notes) do sel_count = sel_count + 1 end
      if sel_count >= 2 then
        get_target_take(true)
        merge_selected_notes()
      end
    end

    -- Left / Right: Jump or range-extend selection to previous / next note
    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_LeftArrow()) then
      if has_shift and state.selected_note and state.selected_note > 1 then
        state.selected_note = state.selected_note - 1
        state.selected_notes[state.selected_note] = true
      elseif state.selected_note and state.selected_note > 1 then
        state.selected_note = state.selected_note - 1
        state.selected_notes = { [state.selected_note] = true }
      elseif not state.selected_note then
        state.selected_note = 1
        state.selected_notes = { [1] = true }
      end
    end

    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_RightArrow()) then
      if has_shift and state.selected_note and state.selected_note < #state.notes then
        state.selected_note = state.selected_note + 1
        state.selected_notes[state.selected_note] = true
      elseif state.selected_note and state.selected_note < #state.notes then
        state.selected_note = state.selected_note + 1
        state.selected_notes = { [state.selected_note] = true }
      elseif not state.selected_note then
        state.selected_note = 1
        state.selected_notes = { [1] = true }
      end
    end

    -- Spacebar: Pass through to REAPER Play/Stop
    if reaper.ImGui_IsKeyPressed(draw_ctx, reaper.ImGui_Key_Space()) then
      reaper.Main_OnCommand(40044, 0)  -- Transport: Play/Stop
    end
  end

  -- Double-click pitch zone: Snap to nearest semitone (single or batch)
  if is_canvas_hovered and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
    if state.hovered_note and state.hovered_zone == "pitch" then
      if not state.selected_notes[state.hovered_note] then
        state.selected_note = state.hovered_note
        state.selected_notes = { [state.hovered_note] = true }
      end
      get_target_take(true)
      snap_selected_note()
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE GRID & PIANO ROLL (IN-SCALE TINTING & OUT-OF-SCALE DIMMING)
  ---------------------------------------------------------------------------
  local root_pc = (state.key_idx - 1) % 12
  local is_chromatic = (SCALE_DEFINITIONS[state.scale_idx].name == "Chromatic")

  for n = math.floor(min_note), math.ceil(max_note) do
    local y = py + h - ((n - min_note) / note_range) * h
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local is_black_key = (n % 12 == 1 or n % 12 == 3 or n % 12 == 6
                          or n % 12 == 8 or n % 12 == 10)
    local pc = (n % 12 + 12) % 12
    local in_scale = is_pitch_in_scale(pc)
    local is_root = (pc == root_pc)

    -- 1. Canvas row background & grid line
    local row_bg
    local row_tint = nil
    local grid_color

    if is_chromatic then
      row_bg = is_black_key and 0x161616FF or 0x202020FF
      grid_color = is_black_key and 0x222222FF or 0x333333FF
    elseif in_scale then
      if is_root then
        -- Tonic/Root note row: subtle theme accent tint
        row_bg = 0x222032FF
        row_tint = Theme.with_alpha(P.accent, 0.12)
        grid_color = Theme.with_alpha(P.accent, 0.35)
      else
        -- In-scale note row: subtle theme tinting
        row_bg = is_black_key and 0x1B1B26FF or 0x212230FF
        row_tint = Theme.with_alpha(P.accent, 0.05)
        grid_color = Theme.with_alpha(P.accent, 0.16)
      end
    else
      -- Out-of-scale note row: dimmed
      row_bg = is_black_key and 0x111114FF or 0x131317FF
      grid_color = 0x1A1A20FF
    end

    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_bg)
    if row_tint then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_tint)
    end
    reaper.ImGui_DrawList_AddLine(draw_list, px, y, px + w, y, grid_color)

    -- 2. Piano roll keys
    local key_color
    local text_col

    if is_chromatic then
      key_color = is_black_key and 0x1A1A1AFF or 0xDDDDDDFF
      text_col = is_black_key and 0x888888FF or 0x333333FF
    elseif in_scale then
      if is_root then
        key_color = is_black_key and 0x252338FF or 0xFFFFFFFF
        text_col = is_black_key and P.accent or 0x181824FF
      else
        key_color = is_black_key and 0x1E1E24FF or 0xDDDDDDFF
        text_col = is_black_key and 0x999999FF or 0x2B2B2BFF
      end
    else
      -- Out-of-scale keys dimmed
      key_color = is_black_key and 0x101013FF or 0x585962FF
      text_col = is_black_key and 0x3C3C46FF or 0x2B2C33FF
    end

    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, key_top, full_px + piano_w, key_bot, key_color)
    reaper.ImGui_DrawList_AddRect(draw_list, full_px, key_top, full_px + piano_w, key_bot, 0x000000FF)

    -- Accent indicator strip for root key
    if not is_chromatic and is_root then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px + piano_w - 3, key_top, full_px + piano_w, key_bot, P.accent)
    end

    local label = midi_to_name(n)
    local text_y = key_top + (key_bot - key_top) * 0.5 - 7
    reaper.ImGui_DrawList_AddText(draw_list, full_px + 2, text_y, text_col, label)
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

        local is_selected = state.selected_notes[n_idx] or false
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

        -- Border (thicker for selected notes)
        reaper.ImGui_DrawList_AddRect(draw_list,
          sx, top_y, ex, bot_y, border, 0, 0, is_selected and 2.0 or 1.0)

        -- Zone divider lines on hover/select
        if is_hov or is_selected then
          reaper.ImGui_DrawList_AddLine(draw_list,
            sx + zone_w, top_y, sx + zone_w, bot_y, 0xFFFFFF33)
          reaper.ImGui_DrawList_AddLine(draw_list,
            ex - zone_w, top_y, ex - zone_w, bot_y, 0xFFFFFF33)

          -- Edge trim handles (visible grab zones)
          local handle_w = 3
          local left_handle_col = 0xFFFFFF55
          local right_handle_col = 0xFFFFFF55

          -- Brighten the hovered edge
          if state.hovered_edge and state.hovered_edge.note_idx == n_idx then
            if state.hovered_edge.edge == "left" then
              left_handle_col = 0xFFFFFFCC
            else
              right_handle_col = 0xFFFFFFCC
            end
          end

          -- During edge drag, brighten the active edge
          if state.edge_drag and state.edge_drag.note_idx == n_idx then
            if state.edge_drag.edge == "left" then
              left_handle_col = P.accent
            else
              right_handle_col = P.accent
            end
          end

          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx - 1, top_y, sx + handle_w, bot_y, left_handle_col)
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            ex - handle_w, top_y, ex + 1, bot_y, right_handle_col)
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
          local vw = (note.vibrato_weight and note.vibrato_weight[i]) or 0.0
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
  -- DRAW MARQUEE SELECTION BOX (Milestone 4)
  ---------------------------------------------------------------------------
  if state.marquee and state.marquee.active then
    local bx1 = math.max(px, math.min(state.marquee.start_x, state.marquee.cur_x))
    local by1 = math.max(py, math.min(state.marquee.start_y, state.marquee.cur_y))
    local bx2 = math.min(px + w, math.max(state.marquee.start_x, state.marquee.cur_x))
    local by2 = math.min(py + h, math.max(state.marquee.start_y, state.marquee.cur_y))

    if bx2 > bx1 and by2 > by1 then
      local fill_col = Theme.with_alpha(P.accent, 0.18)
      local border_col = Theme.with_alpha(P.accent, 0.85)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, bx1, by1, bx2, by2, fill_col)
      reaper.ImGui_DrawList_AddRect(draw_list, bx1, by1, bx2, by2, border_col, 0, 0, 1.5)

      local m_count = 0
      for _ in pairs(state.selected_notes) do m_count = m_count + 1 end
      if m_count > 0 then
        local count_text = string.format("%d selected", m_count)
        local text_x = math.min(bx2 + 6, px + w - 75)
        if text_x < bx1 + 4 then text_x = bx1 + 4 end
        local text_y = math.max(py + 4, math.min(by2 - 14, py + h - 18))
        reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, P.accent, count_text)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- TOOLTIPS (drag value / hover hint)
  ---------------------------------------------------------------------------
  if state.drag and state.drag.dirty then
    local d_note = state.notes[state.drag.anchor_idx or state.drag.note_idx]
    if d_note and d_note.controls then
      local count = 0
      for _ in pairs(state.drag.orig_values or {}) do count = count + 1 end
      local count_suffix = count > 1 and string.format("  (%d notes)", count) or ""
      local tip
      if state.drag.zone == "pitch" then
        local cp = d_note.controls.center_pitch
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        tip = string.format("%s %s%d\xC2\xA2%s",
          midi_to_name(nearest), sign, cents, count_suffix)
      elseif state.drag.zone == "drift" then
        tip = string.format("Stability: %.0f%%%s",
          (1 - d_note.controls.drift_scale) * 100, count_suffix)
      else
        tip = string.format("Vibrato: %.0f%%%s",
          d_note.controls.vibrato_scale * 100, count_suffix)
      end
      reaper.ImGui_DrawList_AddText(draw_list, mx + 15, my - 10,
        0xFFFFFFFF, tip)
    end
  elseif state.hovered_note and not state.drag and not state.marquee then
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

  -- Bypassed Overlay
  if is_bypassed then
    local scrim_col = Theme.with_alpha(P.bg, 0.75)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, py, full_px + full_w, py + h, scrim_col)

    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5
    local badge_w = 200
    local badge_h = 60
    local bx1 = cx - badge_w * 0.5
    local by1 = cy - badge_h * 0.5
    local bx2 = cx + badge_w * 0.5
    local by2 = cy + badge_h * 0.5

    reaper.ImGui_DrawList_AddRectFilled(draw_list, bx1, by1, bx2, by2, P.card, 6.0)
    reaper.ImGui_DrawList_AddRect(draw_list, bx1, by1, bx2, by2, P.red, 6.0, 0, 1.5)

    local txt_main = "BYPASSED"
    local pushed_bp_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
    local tw, th = reaper.ImGui_CalcTextSize(draw_ctx, txt_main)
    Theme.pop_font(draw_ctx, pushed_bp_font)

    local sub_txt = "Take pitch envelope is bypassed"
    local stw, _ = reaper.ImGui_CalcTextSize(draw_ctx, sub_txt)

    reaper.ImGui_DrawList_AddText(draw_list, cx - tw * 0.5, by1 + 10, P.red_l, txt_main)
    reaper.ImGui_DrawList_AddText(draw_list, cx - stw * 0.5, by1 + 14 + th, P.text_dim, sub_txt)
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
      state.selected_notes = {}
      state.hovered_note = nil
      state.drag = nil
      state.marquee = nil
      state.start_time = nil
      state.end_time = nil
      state.item_len = nil
      state.sample_rate = nil
    end
  end

  reaper.Undo_EndBlock(string.format("Delete %s from Pitch Session and Reset Take", take_name), -1)
end

local function wipe_entire_session()
  local order_copy = {}
  for _, guid in ipairs(state.session_order) do
    table.insert(order_copy, guid)
  end
  for _, guid in ipairs(order_copy) do
    remove_take_from_session(guid)
  end
  reset_analysis()
  state.session_takes = {}
  state.session_order = {}
end

local function render_pitched_items_sidebar(sidebar_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout

  Theme.align(sidebar_ctx)
  reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  reaper.ImGui_Text(sidebar_ctx, string.format("Pitched Items (%d)", #state.session_order))
  reaper.ImGui_PopStyleColor(sidebar_ctx, 1)

  reaper.ImGui_SameLine(sidebar_ctx)
  local close_sz = L.icon_sm.size + L.icon_sm.pad * 2
  Theme.right_align(sidebar_ctx, close_sz)
  Theme.align(sidebar_ctx, nil, close_sz)
  if Theme.icon_btn(sidebar_ctx, "##close_items_panel", Theme.icons.tri_right, {
    preset = L.icon_sm,
    tooltip = "Hide Pitched Items panel"
  }) then
    state.sidebar_open = false
    reaper.SetExtState("FancyScripts", "pitch_sidebar_open", "0", true)
  end

  reaper.ImGui_Separator(sidebar_ctx)

  if #state.session_order == 0 then
    reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(sidebar_ctx, "No pitched items stored.\n\nSelect an audio item in REAPER and click Analyze.")
    reaper.ImGui_PopStyleColor(sidebar_ctx, 1)
    return
  end

  local to_remove = nil
  local avail_w = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)

  for _, guid in ipairs(state.session_order) do
    local data = state.session_takes[guid]
    if data then
      local is_active = (guid == state.target_take_guid)
      local take_obj = resolve_take_by_guid(guid)
      if not take_obj and is_active then
        take_obj = get_target_take(false)
      end

      reaper.ImGui_PushID(sidebar_ctx, guid)

      local rx, ry = reaper.ImGui_GetCursorScreenPos(sidebar_ctx)
      local row_h = reaper.ImGui_GetFrameHeight(sidebar_ctx) + 2

      -- Full-width highlight bar encompassing all row buttons
      if is_active then
        local dl = reaper.ImGui_GetWindowDrawList(sidebar_ctx)
        reaper.ImGui_DrawList_AddRectFilled(dl, rx - 2, ry, rx + avail_w + 2, ry + row_h, Theme.with_alpha(P.accent, 0.22), 4.0)
        reaper.ImGui_DrawList_AddRect(dl, rx - 2, ry, rx + avail_w + 2, ry + row_h, Theme.with_alpha(P.accent, 0.55), 4.0)
      end

      -- Checkbox on the left: mirrors REAPER FX chain
      Theme.align(sidebar_ctx)
      local is_bp = is_take_pitch_bypassed(take_obj)
      local is_enabled = not is_bp
      local cb_changed, new_en = reaper.ImGui_Checkbox(sidebar_ctx, "##bp", is_enabled)
      if cb_changed then
        toggle_take_pitch_bypass(take_obj)
      end
      if reaper.ImGui_IsItemHovered(sidebar_ctx) then
        Theme.tooltip(sidebar_ctx, new_en and "Envelope Active — click to bypass take envelope" or "Envelope Bypassed — click to enable take envelope")
      end

      reaper.ImGui_SameLine(sidebar_ctx, 0, L.xs)

      -- Selectable take name in center
      local del_btn_w = 20
      local cur_x = reaper.ImGui_GetCursorPosX(sidebar_ctx)
      local name_w = math.max(30, avail_w - cur_x - del_btn_w - L.xs)

      local sel_flags = reaper.ImGui_SelectableFlags_AllowOverlap and reaper.ImGui_SelectableFlags_AllowOverlap() or 0
      local sel_text = data.name or "Item"
      Theme.align(sidebar_ctx)
      local text_col = is_active and 0xFFFFFFFF or P.text
      reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), text_col)
      if reaper.ImGui_Selectable(sidebar_ctx, sel_text .. "##sel", false, sel_flags, name_w, 0) then
        switch_active_target(guid, take_obj)
      end
      reaper.ImGui_PopStyleColor(sidebar_ctx, 1)

      if reaper.ImGui_IsItemHovered(sidebar_ctx) then
        Theme.tooltip(sidebar_ctx, string.format("Item: %s\nNotes: %d\nClick to switch editing target",
          data.name or "Item", data.notes and #data.notes or 0))
      end

      -- Delete button on right
      reaper.ImGui_SameLine(sidebar_ctx, 0, L.xs)
      Theme.align(sidebar_ctx)
      if Theme.icon_btn(sidebar_ctx, "##del", Theme.icons.close, {
        size = 12,
        pad = 3,
        color = P.text_dim,
        hover_color = P.red,
        tooltip = "Remove from session, clear envelope, and reset take"
      }) then
        to_remove = guid
      end

      reaper.ImGui_PopID(sidebar_ctx)
    end
  end

  if to_remove then
    remove_take_from_session(to_remove)
  end
end

local function draw_settings_modal()
  local P = Theme.get_palette()
  local L = Theme.layout
  local _

  if show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, "Settings & Audio Engine##settings_modal")
    show_settings_modal = false
  end

  Theme.center_next_window(ctx, 480, 560, reaper.ImGui_Cond_Appearing())
  Theme.modal_scrim(ctx, "Settings & Audio Engine##settings_modal")
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Settings & Audio Engine##settings_modal", true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_Spacing(ctx)

    Theme.section_divider(ctx, "Pitch Shift Engine", { color = P.yellow })
    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Algorithm:")
    reaper.ImGui_SameLine(ctx, 0, L.md)
    reaper.ImGui_PushItemWidth(ctx, 280)
    if reaper.ImGui_BeginCombo(ctx, "##settings_pitchmode", state.pitchmode_name) then
      for i, entry in ipairs(PITCHMODE_FLAT) do
        local is_selected = (state.preset_pitchmode_idx == i)
        if reaper.ImGui_Selectable(ctx, entry.name, is_selected) then
          state.preset_pitchmode_idx = i
          state.pitchmode_value = entry.value
          state.pitchmode_name = entry.name
        end
        if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_PopItemWidth(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Pitch Shift Algorithm — Elastique Soloist (Monophonic) is recommended for vocals.\nApplied automatically to the take when writing envelopes.")
    end

    reaper.ImGui_Spacing(ctx)
    Theme.section_divider(ctx, "Analysis & Detection Presets", { color = P.yellow })

    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Vocal Range:")
    reaper.ImGui_SameLine(ctx, 0, L.md)
    reaper.ImGui_PushItemWidth(ctx, 160)
    if reaper.ImGui_BeginCombo(ctx, "##settings_range", VOCAL_RANGES[state.preset_range_idx].name) then
      for i, range in ipairs(VOCAL_RANGES) do
        if reaper.ImGui_Selectable(ctx, range.name, state.preset_range_idx == i) then
          state.preset_range_idx = i
          state.min_freq = range.min
          state.max_freq = range.max
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_PopItemWidth(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Vocal Range — limits frequency search to avoid octave jump errors")
    end

    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Strictness:")
    reaper.ImGui_SameLine(ctx, 0, L.md)
    reaper.ImGui_PushItemWidth(ctx, 160)
    if reaper.ImGui_BeginCombo(ctx, "##settings_mode", DETECTION_MODES[state.preset_mode_idx].name) then
      for i, mode in ipairs(DETECTION_MODES) do
        if reaper.ImGui_Selectable(ctx, mode.name, state.preset_mode_idx == i) then
          state.preset_mode_idx = i
          state.threshold = mode.threshold
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_PopItemWidth(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Detection Mode — confidence threshold for pitched note detection")
    end

    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Quality / CPU:")
    reaper.ImGui_SameLine(ctx, 0, L.md)
    reaper.ImGui_PushItemWidth(ctx, 160)
    if reaper.ImGui_BeginCombo(ctx, "##settings_quality", QUALITY_MODES[state.preset_quality_idx].name) then
      for i, mode in ipairs(QUALITY_MODES) do
        if reaper.ImGui_Selectable(ctx, mode.name, state.preset_quality_idx == i) then
          state.preset_quality_idx = i
          state.block_size = mode.block
          state.hop_size = mode.hop
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_PopItemWidth(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Quality / CPU — time vs frequency resolution trade-off")
    end

    reaper.ImGui_Spacing(ctx)
    if Theme.collapsing_header(ctx, "Advanced DSP Parameters") then
      reaper.ImGui_Indent(ctx, L.md)
      _, state.block_size = reaper.ImGui_InputInt(ctx, "Block Size##dsp", state.block_size)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Samples analyzed per window (e.g. 512, 1024, 2048).")
      end
      _, state.hop_size = reaper.ImGui_InputInt(ctx, "Hop Size##dsp", state.hop_size)
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Samples to advance between analysis windows.")
      end
      _, state.threshold = reaper.ImGui_SliderDouble(ctx, "YIN Threshold##dsp", state.threshold, 0.05, 0.5, "%.2f")
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Confidence threshold for pitch detection (lower = stricter).")
      end
      _, state.min_freq = reaper.ImGui_SliderDouble(ctx, "Min Freq (Hz)##dsp", state.min_freq, 20, 200, "%.0f Hz")
      _, state.max_freq = reaper.ImGui_SliderDouble(ctx, "Max Freq (Hz)##dsp", state.max_freq, 200, 2000, "%.0f Hz")
      reaper.ImGui_Unindent(ctx, L.md)
    end

    reaper.ImGui_Spacing(ctx)
    Theme.section_divider(ctx, "Appearance & Options", { color = P.yellow })

    Theme.align(ctx)
    Theme.settings_widget(ctx, { label = "Theme Mode" })

    Theme.align(ctx)
    Theme.tooltip_setting_widget(ctx, { label = "Show Tooltips" })

    Theme.align(ctx)
    _, state.show_onset_debug = reaper.ImGui_Checkbox(ctx, "Show Onset Diagnostics in Status Bar", state.show_onset_debug)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Displays onset ramp, scoop depth, and voicing delay details in the bottom status dock.")
    end

    reaper.ImGui_Spacing(ctx)
    Theme.section_divider(ctx, "Reset & Clear", { color = P.red })
    Theme.align(ctx)
    if reaper.ImGui_Button(ctx, "Clear Active Take Envelope##reset_take", 200, 0) then
      reset_analysis()
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Clears analysis cache and deletes pitch envelope points from the active take")
    end

    reaper.ImGui_SameLine(ctx, 0, L.sm)
    Theme.align(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    if reaper.ImGui_Button(ctx, "Wipe Entire Session (All Items)##reset_all", 230, 0) then
      wipe_entire_session()
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "WARNING: Clears all pitch envelopes, metadata, and resets all items stored in this session.")
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local btn_done_w = 120
    Theme.hcenter(ctx, btn_done_w)
    if reaper.ImGui_Button(ctx, "Done##settings_done", btn_done_w, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_info_modal()
  local P = Theme.get_palette()

  if show_info_modal then
    reaper.ImGui_OpenPopup(ctx, "Keyboard Shortcuts & Help##info_modal")
    show_info_modal = false
  end

  Theme.center_next_window(ctx, 480, 520, reaper.ImGui_Cond_Appearing())
  Theme.modal_scrim(ctx, "Keyboard Shortcuts & Help##info_modal")
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Keyboard Shortcuts & Help##info_modal", true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    Theme.section_divider(ctx, "Selection & Navigation", { color = P.yellow })

    local function shortcut_row(key_str, desc_str)
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.accent, key_str)
      reaper.ImGui_SameLine(ctx)
      Theme.right_align(ctx, 280)
      Theme.align(ctx)
      reaper.ImGui_Text(ctx, desc_str)
    end

    shortcut_row("Cmd / Ctrl + A", "Select all notes in phrase")
    shortcut_row("Escape", "Deselect all notes")
    shortcut_row("Marquee Drag", "Box select notes (Shift=Add)")
    shortcut_row("Shift + Click", "Range select notes")
    shortcut_row("Cmd / Ctrl + Click", "Toggle note in/out of selection")
    shortcut_row("← / →", "Select previous / next note (Shift=Extend)")

    reaper.ImGui_Spacing(ctx)
    Theme.section_divider(ctx, "Pitch & Note Editing", { color = P.yellow })

    shortcut_row("Drag Center Zone", "Shift note pitch (semitones / fine cents)")
    shortcut_row("Drag Left Zone", "Adjust drift stability tracking")
    shortcut_row("Drag Right Zone", "Scale natural vibrato depth")
    shortcut_row("Drag Note Edge", "Trim note start / end boundary")
    shortcut_row("↑ / ↓", "Nudge pitch ±1 semitone")
    shortcut_row("Shift + ↑ / ↓", "Fine-tune pitch ±10 cents")
    shortcut_row("S / Double-Click", "Snap note to nearest semitone")
    shortcut_row("Q", "Quantize selected note(s) to scale")
    shortcut_row("R / Delete", "Reset note(s) to original detected pitch")

    reaper.ImGui_Spacing(ctx)
    Theme.section_divider(ctx, "Note Topology & REAPER Transport", { color = P.yellow })

    shortcut_row("X", "Split note at REAPER edit cursor")
    shortcut_row("M", "Merge 2+ contiguous selected notes")
    shortcut_row("Space", "Play / Stop REAPER transport")

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local btn_close_w = 120
    Theme.hcenter(ctx, btn_close_w)
    if reaper.ImGui_Button(ctx, "Close##info_close", btn_close_w, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

local function render_bottom_dock(dock_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout

  local has_data = (#state.results > 0 and state.notes and #state.notes > 0)
  if not has_data then
    Theme.align(dock_ctx)
    reaper.ImGui_TextDisabled(dock_ctx, "Ready to analyze selected item.")
    return
  end

  local sel_count = 0
  for _ in pairs(state.selected_notes) do sel_count = sel_count + 1 end
  if sel_count == 0 and state.selected_note and state.notes[state.selected_note] then
    sel_count = 1
  end

  -- Left: Selection Status & Note Properties
  if sel_count > 1 then
    local mod_count = 0
    local total_dur = 0
    for idx in pairs(state.selected_notes) do
      local n = state.notes[idx]
      if n then
        if is_note_modified(n) then mod_count = mod_count + 1 end
        total_dur = total_dur + (n.end_time - n.start_time)
      end
    end
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, string.format("%d Notes (%.2fs)", sel_count, total_dur), {
      color = P.accent_l,
      bg = P.accent_d,
      tooltip = "Selected notes count and cumulative duration"
    })
    reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
    if state.selected_note and state.notes[state.selected_note] then
      local pn = state.notes[state.selected_note]
      local p_nearest = math.floor(pn.controls.center_pitch + 0.5)
      local p_cents = math.floor((pn.controls.center_pitch - p_nearest) * 100 + 0.5)
      local p_sign = p_cents >= 0 and "+" or ""
      Theme.align(dock_ctx)
      Theme.badge(dock_ctx, string.format("Anchor: %s %s%d¢", midi_to_name(p_nearest), p_sign, p_cents), {
        tooltip = "Anchor note for relative transposition and interval snapping"
      })
      reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
    end
    local status_str = mod_count > 0 and string.format("%d/%d Tuned", mod_count, sel_count) or "Untouched"
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, status_str, {
      color = mod_count > 0 and P.green_l or P.text_dim,
      bg = mod_count > 0 and P.green_d or P.card,
      tooltip = "Number of modified notes in selection"
    })
  elseif sel_count == 1 and state.selected_note and state.notes[state.selected_note] then
    local sel = state.notes[state.selected_note]
    local ctrl = sel.controls
    local nearest = math.floor(ctrl.center_pitch + 0.5)
    local cents = math.floor((ctrl.center_pitch - nearest) * 100 + 0.5)
    local sign = cents >= 0 and "+" or ""
    local is_mod = is_note_modified(sel)
    local is_chrom = (SCALE_DEFINITIONS[state.scale_idx].name == "Chromatic")
    local in_scale = is_pitch_in_scale(nearest % 12)

    local note_label = string.format("%s %s%d¢", midi_to_name(nearest), sign, cents)
    local note_col = (is_chrom or in_scale) and P.green_l or P.yellow_l
    local note_bg  = (is_chrom or in_scale) and P.green_d or Theme.with_alpha(P.yellow, 0.22)
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, note_label, {
      color = note_col,
      bg = note_bg,
      tooltip = string.format("Note Pitch: %s\nDeviation: %s%d cents\nScale: %s",
        midi_to_name(nearest), sign, cents, is_chrom and "Chromatic" or (in_scale and "In Scale" or "Out of Scale"))
    })

    if not is_chrom then
      reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
      Theme.align(dock_ctx)
      Theme.badge(dock_ctx, in_scale and "In Scale" or "Out of Scale", {
        color = in_scale and P.green_l or P.yellow_l,
        bg = in_scale and P.green_d or Theme.with_alpha(P.yellow, 0.22)
      })
    end

    reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, string.format("Stability: %.0f%%", (1 - ctrl.drift_scale) * 100), {
      tooltip = "Pitch stability / drift correction (Drag left zone of note block)"
    })

    reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, string.format("Vibrato: %.0f%%", ctrl.vibrato_scale * 100), {
      tooltip = "Vibrato depth scale (Drag right zone of note block)"
    })

    reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, string.format("Trans: %.0fms", ctrl.transition_ms or 35), {
      tooltip = "S-curve smoothstep transition duration into next note"
    })

    reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
    Theme.align(dock_ctx)
    Theme.badge(dock_ctx, is_mod and "Tuned" or "Original", {
      color = is_mod and P.green_l or P.text_dim,
      bg = is_mod and P.green_d or P.card
    })

    -- Optional onset debug info
    if state.show_onset_debug and sel.onset_debug then
      local od = sel.onset_debug
      reaper.ImGui_SameLine(dock_ctx, 0, L.md)
      Theme.align(dock_ctx)
      reaper.ImGui_TextDisabled(dock_ctx, string.format("[ramp=%.0fms scoop=%.2fst delay=%.0fms]",
        od.onset_ramp_ms, od.scoop_st, od.voicing_delay_ms))
    end
  else
    Theme.align(dock_ctx)
    reaper.ImGui_TextDisabled(dock_ctx, "Click note to select  •  Marquee drag to box select  •  Cmd+A to select all")
  end

  -- Right: Action Buttons
  local btn_q_w = 98
  local btn_split_w = 74
  local btn_merge_w = 78
  local btn_reset_w = 80
  local btn_all_w = 86
  local act_w = btn_q_w + btn_split_w + btn_merge_w + btn_reset_w + btn_all_w + (L.sm * 4)

  reaper.ImGui_SameLine(dock_ctx)
  local cur_x = reaper.ImGui_GetCursorPosX(dock_ctx)
  local avail_dock_w = reaper.ImGui_GetContentRegionAvail(dock_ctx)
  local target_x = cur_x + avail_dock_w - act_w
  if target_x > cur_x + L.md then
    reaper.ImGui_SetCursorPosX(dock_ctx, target_x)
  end

  -- Quantize (Q)
  local has_sel = (sel_count > 0)
  if not has_sel then reaper.ImGui_BeginDisabled(dock_ctx) end
  local q_label = sel_count > 1 and string.format("Quantize (%d)", sel_count) or "Quantize (Q)"
  if reaper.ImGui_Button(dock_ctx, q_label .. "##dock_q", btn_q_w, 0) then
    get_target_take(true)
    quantize_selected_notes_to_scale()
  end
  if reaper.ImGui_IsItemHovered(dock_ctx) then
    Theme.tooltip(dock_ctx, string.format("Quantize %s to nearest %s %s pitch (Q)",
      sel_count > 1 and string.format("%d selected notes", sel_count) or "selected note",
      SCALE_KEYS[state.key_idx].display, SCALE_DEFINITIONS[state.scale_idx].name))
  end
  if not has_sel then reaper.ImGui_EndDisabled(dock_ctx) end

  -- Split (X)
  local can_split = false
  if state.selected_note and state.notes[state.selected_note] then
    local sn = state.notes[state.selected_note]
    local _, si = get_target_take(false)
    if si then
      local ip = reaper.GetMediaItemInfo_Value(si, "D_POSITION")
      local ec = reaper.GetCursorPosition() - ip
      can_split = ec > sn.start_time and ec < sn.end_time
    end
  end
  reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
  if not can_split then reaper.ImGui_BeginDisabled(dock_ctx) end
  if reaper.ImGui_Button(dock_ctx, "Split (X)##dock_x", btn_split_w, 0) then
    if state.selected_note and state.notes[state.selected_note] then
      local sn = state.notes[state.selected_note]
      local _, si = get_target_take(false)
      if si then
        local ip = reaper.GetMediaItemInfo_Value(si, "D_POSITION")
        local ec = reaper.GetCursorPosition() - ip
        if ec > sn.start_time and ec < sn.end_time then
          get_target_take(true)
          split_note_at(state.selected_note, ec)
        end
      end
    end
  end
  if reaper.ImGui_IsItemHovered(dock_ctx) then
    Theme.tooltip(dock_ctx, "Split selected note at REAPER edit cursor (X)")
  end
  if not can_split then reaper.ImGui_EndDisabled(dock_ctx) end

  -- Merge (M)
  local can_merge = (sel_count >= 2)
  reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
  if not can_merge then reaper.ImGui_BeginDisabled(dock_ctx) end
  if reaper.ImGui_Button(dock_ctx, "Merge (M)##dock_m", btn_merge_w, 0) then
    get_target_take(true)
    merge_selected_notes()
  end
  if reaper.ImGui_IsItemHovered(dock_ctx) then
    Theme.tooltip(dock_ctx, "Merge 2 or more contiguous selected notes into one (M)")
  end
  if not can_merge then reaper.ImGui_EndDisabled(dock_ctx) end

  -- Reset (R)
  reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
  if not has_sel then reaper.ImGui_BeginDisabled(dock_ctx) end
  local r_label = sel_count > 1 and string.format("Reset (%d)", sel_count) or "Reset (R)"
  if reaper.ImGui_Button(dock_ctx, r_label .. "##dock_r", btn_reset_w, 0) then
    reset_selected_note()
  end
  if reaper.ImGui_IsItemHovered(dock_ctx) then
    Theme.tooltip(dock_ctx, "Reset selected note(s) to original pitch/drift/vibrato (R)")
  end
  if not has_sel then reaper.ImGui_EndDisabled(dock_ctx) end

  -- Select All
  reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
  if reaper.ImGui_Button(dock_ctx, "Select All##dock_all", btn_all_w, 0) then
    state.selected_notes = {}
    for i = 1, #state.notes do
      state.selected_notes[i] = true
    end
    if not state.selected_note or not state.selected_notes[state.selected_note] then
      state.selected_note = 1
    end
  end
  if reaper.ImGui_IsItemHovered(dock_ctx) then
    Theme.tooltip(dock_ctx, "Select all notes in phrase (Cmd/Ctrl + A)")
  end
end

local function loop_body()
  local _
  process_analysis_step()

  local P = Theme.get_palette()
  local L = Theme.layout
  local nc, nv = Theme.push(ctx, P)
  local pushed_font = Theme.push_font(ctx, fonts.default)

  Theme.center_next_window(ctx, 920, 620, reaper.ImGui_Cond_Once())
  local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoNavInputs()

  local visible, open = reaper.ImGui_Begin(ctx, 'Fancy Pitch Correct', true, win_flags)
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      open = false
    end

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
            state.selected_notes = {}
            state.hovered_note = nil
            state.drag = nil
            state.marquee = nil
            state.start_time = 0
            state.item_len = reaper.GetMediaItemInfo_Value(cur_sel_item, "D_LENGTH")
            state.end_time = state.item_len
          end
        end
      end
    end

    local target_take, target_item = get_target_take(false)
    local has_target = (target_take ~= nil and state.target_take_name ~= nil)
    local has_notes = (state.notes and #state.notes > 0)

    -- 1. Unified Single Top Bar
    local brand_sz = 24
    local icon_sz = L.icon_md.size + L.icon_md.pad * 2
    local row_h = math.max(L.row_h, brand_sz, icon_sz, reaper.ImGui_GetFrameHeight(ctx))

    -- Brand Icon
    Theme.brand_icon(ctx, brand_sz, row_h)
    reaper.ImGui_SameLine(ctx, 0, L.sm)

    -- "FANCY"
    local pushed_b = Theme.push_font(ctx, fonts.large_bold)
    Theme.align(ctx, row_h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
    reaper.ImGui_Text(ctx, "FANCY")
    reaper.ImGui_PopStyleColor(ctx, 1)
    Theme.pop_font(ctx, pushed_b)
    reaper.ImGui_SameLine(ctx, 0, L.xs)

    -- "PITCH CORRECT"
    local pushed_title = Theme.push_font(ctx, fonts.large)
    Theme.align(ctx, row_h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    reaper.ImGui_Text(ctx, "PITCH CORRECT")
    reaper.ImGui_PopStyleColor(ctx, 1)
    Theme.pop_font(ctx, pushed_title)
    reaper.ImGui_SameLine(ctx, 0, L.md)

    -- Target Item Badge
    Theme.align(ctx, row_h)
    if has_target then
      local track_col = get_target_track_color(target_take, target_item)
      local badge_bg = track_col or (has_notes and P.accent_d or Theme.with_alpha(P.yellow, 0.25))
      local badge_txt_col = track_col and get_contrasting_text_color(track_col) or 0xFFFFFFFF
      Theme.badge(ctx, state.target_take_name, {
        color = badge_txt_col,
        text_color = badge_txt_col,
        bg = badge_bg,
        tooltip = string.format("Active Target: %s\nStatus: %s\nSelect any audio item in REAPER to switch target.",
          state.target_take_name, has_notes and "Analyzed & Active" or "Ready to Analyze")
      })
    else
      Theme.badge(ctx, "No Target Item", {
        color = 0xFFFFFFFF,
        bg = P.card,
        tooltip = "Select an audio item in REAPER to pitch-correct."
      })
    end
    reaper.ImGui_SameLine(ctx, 0, L.sm)

    -- Dropdowns and Buttons in crisp bright white text
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)

    -- Musical Key
    Theme.align(ctx, row_h)
    reaper.ImGui_TextColored(ctx, P.accent_l, "Key:")
    reaper.ImGui_SameLine(ctx, 0, L.xs)
    reaper.ImGui_PushItemWidth(ctx, 52)
    if reaper.ImGui_BeginCombo(ctx, "##key_selector", SCALE_KEYS[state.key_idx].display) then
      for i, k_info in ipairs(SCALE_KEYS) do
        local is_sel = (state.key_idx == i)
        if reaper.ImGui_Selectable(ctx, k_info.name, is_sel) then
          state.key_idx = i
          update_scale_pitch_classes()
          save_current_scale_settings()
        end
        if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Musical Key (Root Pitch Class)")
    end
    reaper.ImGui_PopItemWidth(ctx)
    reaper.ImGui_SameLine(ctx, 0, L.sm)

    -- Musical Scale
    Theme.align(ctx, row_h)
    reaper.ImGui_TextColored(ctx, P.accent_l, "Scale:")
    reaper.ImGui_SameLine(ctx, 0, L.xs)
    reaper.ImGui_PushItemWidth(ctx, 95)
    if reaper.ImGui_BeginCombo(ctx, "##scale_selector", SCALE_DEFINITIONS[state.scale_idx].name) then
      for i, s_def in ipairs(SCALE_DEFINITIONS) do
        local is_sel = (state.scale_idx == i)
        if reaper.ImGui_Selectable(ctx, s_def.name, is_sel) then
          state.scale_idx = i
          update_scale_pitch_classes()
          save_current_scale_settings()
        end
        if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Musical Scale — highlights in-scale piano roll rows and sets target for Quantize (Q)")
    end
    reaper.ImGui_PopItemWidth(ctx)
    reaper.ImGui_SameLine(ctx, 0, L.sm)

    -- Analyze / Progress
    Theme.align(ctx, row_h)
    if state.is_analyzing then
      reaper.ImGui_ProgressBar(ctx, state.progress, 90, 0, string.format("%d%%", math.floor(state.progress * 100)))
    else
      if not has_target then reaper.ImGui_BeginDisabled(ctx) end
      local analyze_label = has_notes and "Re-Analyze" or "Analyze"
      local analyze_btn_w = 96
      if reaper.ImGui_Button(ctx, analyze_label .. "##top_analyze", analyze_btn_w, 0) then
        start_analysis()
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, has_notes and "Re-run YIN pitch detection on the active target item" or "Run YIN pitch detection on the selected audio item")
      end
      if not has_target then reaper.ImGui_EndDisabled(ctx) end
    end
    reaper.ImGui_SameLine(ctx, 0, L.sm)

    -- Reset Button
    Theme.align(ctx, row_h)
    if not has_notes then reaper.ImGui_BeginDisabled(ctx) end
    local reset_btn_w = 66
    if reaper.ImGui_Button(ctx, "Reset##top_reset", reset_btn_w, 0) then
      reset_selected_note()
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Reset selected note(s) to original pitch, or reset all notes if none selected")
    end
    if not has_notes then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Right-Aligned Controls: Layers, Settings, Info, Close
    local layers_btn_w = 80
    local right_w = layers_btn_w + L.sm + icon_sz + L.xs + icon_sz + L.xs + icon_sz
    reaper.ImGui_SameLine(ctx)
    Theme.right_align(ctx, right_w)

    -- Layers ▾
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    Theme.align(ctx, row_h)
    if reaper.ImGui_Button(ctx, "Layers ▾##top_layers", layers_btn_w, 0) then
      reaper.ImGui_OpenPopup(ctx, "##layers_popup")
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Toggle visual display layers on the piano roll canvas")
    end

    if reaper.ImGui_BeginPopup(ctx, "##layers_popup") then
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.accent, "Display Layers")
      reaper.ImGui_Separator(ctx)
      _, state.show_note_blocks = reaper.ImGui_Checkbox(ctx, "Note Blocks", state.show_note_blocks)
      _, state.show_raw_pitch = reaper.ImGui_Checkbox(ctx, "Pitch Trace (Orange)", state.show_raw_pitch)
      _, state.show_preview = reaper.ImGui_Checkbox(ctx, "Preview Curve (Green)", state.show_preview)
      _, state.show_smart_spots = reaper.ImGui_Checkbox(ctx, "Pitch Center Spots", state.show_smart_spots)
      _, state.show_vibrato_regions = reaper.ImGui_Checkbox(ctx, "Vibrato Shading", state.show_vibrato_regions)
      _, state.show_trend = reaper.ImGui_Checkbox(ctx, "Trend Line", state.show_trend)
      _, state.show_split_points = reaper.ImGui_Checkbox(ctx, "Split Markers", state.show_split_points)
      reaper.ImGui_EndPopup(ctx)
    end

    -- Settings
    reaper.ImGui_SameLine(ctx, 0, L.xs)
    Theme.align(ctx, row_h, icon_sz)
    if Theme.icon_btn(ctx, "##hdr_settings", Theme.icons.gear, { preset = L.icon_md, tooltip = "Settings & Audio Engine" }) then
      show_settings_modal = true
    end

    -- Info
    reaper.ImGui_SameLine(ctx, 0, L.xs)
    Theme.align(ctx, row_h, icon_sz)
    if Theme.icon_btn(ctx, "##hdr_info", Theme.icons.info, { preset = L.icon_md, tooltip = "Keyboard Shortcuts & Help" }) then
      show_info_modal = true
    end

    -- Close
    reaper.ImGui_SameLine(ctx, 0, L.xs)
    Theme.align(ctx, row_h, icon_sz)
    if Theme.icon_btn(ctx, "##hdr_close", Theme.icons.close, { preset = L.icon_md, tooltip = "Close Pitch Correct (Esc)" }) then
      open = false
    end

    reaper.ImGui_Separator(ctx)

    -- 2. Main Body: Canvas + (optional) Pitched Items Sidebar
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local footer_h = reaper.ImGui_GetFrameHeight(ctx) + L.sm * 2 + 2
    local total_h = math.max(60, avail_h - footer_h)

    local min_graph_w = 200
    local min_sidebar_w = 160
    local splitter_w = 6

    if state.sidebar_open then
      local max_sidebar_w = math.max(min_sidebar_w, avail_w - min_graph_w - splitter_w)
      state.sidebar_w = math.max(min_sidebar_w, math.min(max_sidebar_w, state.sidebar_w or 220))
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
        local sp_col = is_split_act and P.accent or (is_split_hov and P.accent_h or P.sep)
        reaper.ImGui_DrawList_AddLine(split_dl, sp_mid_x, sp_min_y, sp_mid_x, sp_max_y, sp_col, is_split_act and 2.0 or 1.0)

        reaper.ImGui_SameLine(ctx, 0, 0)

        -- Right: Pitched Items Sidebar
        local child_border = reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or (reaper.ImGui_ChildFlags_Borders and reaper.ImGui_ChildFlags_Borders() or 0)
        if reaper.ImGui_BeginChild(ctx, "##pitched_items_sidebar", state.sidebar_w, total_h, child_border) then
          render_pitched_items_sidebar(ctx)
          reaper.ImGui_EndChild(ctx)
        end
      end
    else
      -- Drawer is closed: render canvas + button tag on right edge
      local tag_w = 20
      if total_h > 80 then
        draw_graph(ctx, avail_w - tag_w, total_h)

        reaper.ImGui_SameLine(ctx, 0, 0)

        local tag_dl = reaper.ImGui_GetWindowDrawList(ctx)
        local tx, ty = reaper.ImGui_GetCursorScreenPos(ctx)

        -- Background strip & border
        reaper.ImGui_DrawList_AddRectFilled(tag_dl, tx, ty, tx + tag_w, ty + total_h, P.card)
        reaper.ImGui_DrawList_AddLine(tag_dl, tx, ty, tx, ty + total_h, P.sep)

        -- Centered tag button
        local tag_btn_sz = 16
        local by = ty + (total_h - tag_btn_sz) * 0.5
        reaper.ImGui_SetCursorScreenPos(ctx, tx + 2, by)
        if Theme.icon_btn(ctx, "##open_items_tag", Theme.icons.tri_left, {
          size = 12,
          pad = 2,
          tooltip = string.format("Show Pitched Items (%d)", #state.session_order)
        }) then
          state.sidebar_open = true
          reaper.SetExtState("FancyScripts", "pitch_sidebar_open", "1", true)
        end
      end
    end

    reaper.ImGui_Separator(ctx)

    -- 4. Bottom Row: Inspector & Action Bar
    render_bottom_dock(ctx)
  end

  -- 5. Render Modals
  draw_settings_modal()
  draw_info_modal()

  reaper.ImGui_End(ctx)

  Theme.pop_font(ctx, pushed_font)
  Theme.pop(ctx, nc, nv)

  return open
end

local function loop()
  local ok, open = xpcall(loop_body, debug.traceback)
  if not ok then
    reaper.ShowConsoleMsg("Fancy Pitch Correct Error: " .. tostring(open) .. "\n")
    return
  end

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
