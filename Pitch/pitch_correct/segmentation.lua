-- @noindex
-- Fancy Pitch Correct: note segmentation and the per-frame analysis step.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state = App.K, App.state
local apply_envelope_to_take = App.apply_envelope_to_take
local extract_note_features = App.extract_note_features
local freq_to_note = App.freq_to_note
local resolve_take_by_guid = App.resolve_take_by_guid
local yin_process_block = App.yin_process_block

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

  -- The parameters frozen by start_analysis (an analysis always has them; the copy only guards a state set up by hand)
  local params = state.analysis_params
  if not params then
    params = {
      block_size = state.block_size, hop_size = state.hop_size, threshold = state.threshold,
      min_freq = state.min_freq, max_freq = state.max_freq,
    }
    state.analysis_params = params
  end

  -- Work for one short slice, then yield to the window (the progress and Cancel stay responsive)
  local slice_start = reaper.time_precise()

  while state.current_time < state.end_time do
    if reaper.time_precise() - slice_start > K.ANALYSIS_SLICE_S then
      break
    end

    -- Read samples
    local num_read = reaper.GetAudioAccessorSamples(
      state.accessor,
      state.sample_rate,
      state.num_channels,
      state.current_time,
      params.block_size,
      state.buffer
    )

    if num_read > 0 then
      local rms, freq = yin_process_block(state.buffer, state.sample_rate, params)
      local note = nil
      if freq and freq >= params.min_freq and freq <= params.max_freq then
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
    state.current_time = state.current_time + (params.hop_size / state.sample_rate)
  end

  if state.current_time >= state.end_time then
    -- The resync is paused while analysing: remember whether the project changed meanwhile so the
    -- next frame still picks up external changes (undo etc.) after this script's own writes.
    local external_change = (state.last_change_count ~= reaper.GetProjectStateChangeCount(0))

    reaper.DestroyAudioAccessor(state.accessor)
    state.accessor = nil
    state.is_analyzing = false
    state.analysis_params = nil
    state.progress = 1.0
    run_hybrid_segmentation()
    state.analysis_empty = (not state.notes or #state.notes == 0)
    K.reset_view()   -- the new model is shown whole

    -- Store into multi-item session cache, then persist inside ONE named undo block
    if state.target_take_guid then
      state.stale_takes[state.target_take_guid] = nil   -- a fresh analysis has no stale envelope
      local take_data = {
        guid = state.target_take_guid,
        name = state.target_take_name or "Item",
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

      -- Re-apply the envelope from the fresh (untouched) notes: this clears every stale point left by
      -- a previous analysis and writes the new model to the take inside the same "Analyze Pitch" block.
      -- The take's pitch mode is left alone (no correction is applied yet).
      if resolve_take_by_guid(state.target_take_guid, true) then
        apply_envelope_to_take("Analyze Pitch", true)
      else
        state.missing_takes[state.target_take_guid] = true
      end
    end
    if external_change then state.last_change_count = nil end
  elseif state.item_len > 0 then
    state.progress = state.current_time / state.item_len
  end
end

-- What the files loaded after this one use
App.process_analysis_step = process_analysis_step
