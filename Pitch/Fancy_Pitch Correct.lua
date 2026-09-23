-- @description Fancy Pitch Correct
-- @author Fancy Scripts
-- @version 1.0.0
-- @changelog
--   + Initial release
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
  buffer = nil
}

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

local function start_analysis()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowMessageBox("Please select an audio item.", "Error", 0)
    return
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    reaper.ShowMessageBox("Selected item is not audio.", "Error", 0)
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
  
  for i, frame in ipairs(state.results) do
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

  -- Draw background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + h, 0x1A1A1AFF)
  reaper.ImGui_DrawList_AddRect(draw_list, px, py, px + w, py + h, 0x444444FF)

  if #state.results == 0 then
    reaper.ImGui_SetCursorScreenPos(draw_ctx, px + 10, py + 10)
    reaper.ImGui_Text(draw_ctx, "No data. Select an item and click Analyze.")
    reaper.ImGui_Dummy(draw_ctx, w, h)
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
  
  if not has_notes then
    reaper.ImGui_Dummy(ctx, w, h)
    return
  end

  -- Add some padding
  min_note = math.floor(min_note - 2)
  max_note = math.ceil(max_note + 2)
  local note_range = max_note - min_note
  if note_range < 1 then note_range = 1 end

  local duration = state.end_time - state.start_time
  if duration <= 0 then duration = 1 end

  -- Draw note grid
  for n = math.floor(min_note), math.ceil(max_note) do
    local y = py + h - ((n - min_note) / note_range) * h
    local is_black_key = (n % 12 == 1 or n % 12 == 3 or n % 12 == 6 or n % 12 == 8 or n % 12 == 10)
    local color = is_black_key and 0x222222FF or 0x333333FF
    reaper.ImGui_DrawList_AddLine(draw_list, px, y, px + w, y, color)
  end

  -- Draw pitch curve
  -- Draw Segmented Notes
  if state.notes then
    for _, note in ipairs(state.notes) do
      local start_x = px + ((note.start_time - state.start_time) / duration) * w
      local end_x = px + ((note.end_time - state.start_time) / duration) * w
      
      local block_top_y = py + h - ((note.display_note + 0.5 - min_note) / note_range) * h
      local block_bottom_y = py + h - ((note.display_note - 0.5 - min_note) / note_range) * h
      
      reaper.ImGui_DrawList_AddRectFilled(draw_list, start_x, block_top_y, end_x, block_bottom_y, 0x44AA4466)
      reaper.ImGui_DrawList_AddRect(draw_list, start_x, block_top_y, end_x, block_bottom_y, 0x44AA44FF)
      
      -- Draw note name
      local note_text = midi_to_name(note.display_note)
      local text_y = py + h - ((note.display_note - min_note) / note_range) * h - 7 -- roughly center text vertically
      reaper.ImGui_DrawList_AddText(draw_list, start_x + 4, text_y, 0xFFFFFFFF, note_text)
    end
  end

  -- Draw Split Points
  if state.split_points then
    for _, sp in ipairs(state.split_points) do
      local x = px + ((sp.time - state.start_time) / duration) * w
      reaper.ImGui_DrawList_AddLine(draw_list, x, py, x, py + h, 0xFF5555AA, 1.0)
      reaper.ImGui_DrawList_AddText(draw_list, x + 2, py + 2, 0xFF5555FF, sp.reason)
    end
  end

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
        polyline[p_idx+1] = y
        p_idx = p_idx + 2
      end
    end
    reaper.ImGui_DrawList_AddPolyline(draw_list, polyline, 0x8B70FAFF, 0, 2.0)
  end

  reaper.ImGui_Dummy(ctx, w, h)
end

local function loop()
  local _
  Theme.push(ctx)

  process_analysis_step()

  local visible, open = reaper.ImGui_Begin(ctx, 'Fancy Pitch Correct', true, reaper.ImGui_WindowFlags_None())
  if visible then
    reaper.ImGui_Text(ctx, "YIN Pitch Detection Test Bench")
    reaper.ImGui_Separator(ctx)


    if reaper.ImGui_CollapsingHeader(ctx, "Presets (User Friendly)", reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
      if reaper.ImGui_BeginCombo(ctx, "Vocal Range", VOCAL_RANGES[state.preset_range_idx].name) then
        for i, range in ipairs(VOCAL_RANGES) do
          local is_selected = (state.preset_range_idx == i)
          if reaper.ImGui_Selectable(ctx, range.name, is_selected) then
            state.preset_range_idx = i
            state.min_freq = range.min
            state.max_freq = range.max
          end
          if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Limits the frequency search range to avoid octave errors. Match this to your vocalist.")
      end

      if reaper.ImGui_BeginCombo(ctx, "Detection Mode", DETECTION_MODES[state.preset_mode_idx].name) then
        for i, mode in ipairs(DETECTION_MODES) do
          local is_selected = (state.preset_mode_idx == i)
          if reaper.ImGui_Selectable(ctx, mode.name, is_selected) then
            state.preset_mode_idx = i
            state.threshold = mode.threshold
          end
          if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Adjusts how strict the algorithm is about what it considers a pitched note. Use lenient for breathy vocals.")
      end

      if reaper.ImGui_BeginCombo(ctx, "Quality / CPU", QUALITY_MODES[state.preset_quality_idx].name) then
        for i, mode in ipairs(QUALITY_MODES) do
          local is_selected = (state.preset_quality_idx == i)
          if reaper.ImGui_Selectable(ctx, mode.name, is_selected) then
            state.preset_quality_idx = i
            state.block_size = mode.block
            state.hop_size = mode.hop
          end
          if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, "Balances time/frequency resolution against CPU usage.")
      end
    end

    reaper.ImGui_Spacing(ctx)
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

    if reaper.ImGui_Button(ctx, "Analyze Selected Item") then
      start_analysis()
    end

    if state.is_analyzing then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Text(ctx, string.format("Analyzing... %d%%", math.floor(state.progress * 100)))
      reaper.ImGui_ProgressBar(ctx, state.progress, -1, 14)
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, string.format("Points detected: %d", #state.results))

    -- Draw graph area
    local w, h = reaper.ImGui_GetContentRegionAvail(ctx)
    h = h - 20 -- leave some margin
    if h > 100 then
      draw_graph(ctx, w, h)
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
  loop()
end

main()
