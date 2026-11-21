-- @noindex
-- Fancy Pitch Correct: the deferred analysis routine (start, cancel, release).
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state = App.K, App.state
local DEFAULTS = App.DEFAULTS
local ensure_take_pitch_envelope = App.ensure_take_pitch_envelope
local get_take_guid = App.get_take_guid
local get_target_take = App.get_target_take
local note_own_write = App.note_own_write
local set_status = App.set_status

-------------------------------------------------------------------------------
-- 3. ANALYSIS ROUTINE (DEFERRED)
-------------------------------------------------------------------------------

--- Stop reading audio: destroy a live audio accessor and forget the running analysis's engine state. Safe at any
--- time and any number of times (Cancel, closing the window, an error recovery, atexit): it touches nothing else
--- and writes nothing to REAPER.
K.release_analysis = function()
  local accessor = state.accessor
  state.accessor = nil
  state.buffer = nil
  state.is_analyzing = false
  state.analysis_params = nil
  if accessor then pcall(reaper.DestroyAudioAccessor, accessor) end
end

--- The Monitoring FX chain's host: the master track (nil if REAPER gives none).
local function tone_master()
  return reaper.GetMasterTrack(0)
end

--- Delete the Monitoring FX at `fx` (an index with K.TONE.MON added). Never raises; returns true on success.
local function tone_delete(fx)
  local master = tone_master()
  if not master then return false end
  local ok, deleted = pcall(reaper.TrackFX_Delete, master, fx)
  return ok and deleted == true
end

--- Split a MIDI pitch into the Tone Generator's whole-step sliders: Note 0..11 (0 = A), Octave -4..4 and Fine Tune in
--- whole cents -50..50, over the fixed Base Frequency. It plays BASE_HZ * 2 ^ (octave + note / 12 + fine / 1200),
--- so 69 is 440 Hz. The pitch is clamped to MIN_PITCH..MAX_PITCH first.
K.tone_params = function(pitch)
  local T = K.TONE
  pitch = math.max(T.MIN_PITCH, math.min(T.MAX_PITCH, pitch))
  local cents = math.floor((pitch - 69) * 100 + 0.5)
  local semis = math.floor(cents / 100 + 0.5)
  local fine = cents - semis * 100
  return semis % 12, semis // 12, fine
end

--- The Monitoring FX index (K.TONE.MON added) of the tone effect: the one whose GUID is `guid` or, when `guid` is
--- nil, the first one renamed to K.TONE.TAG. nil when there is none.
K.tone_find = function(guid)
  local master = tone_master()
  if not master then return nil end
  for i = 0, reaper.TrackFX_GetRecCount(master) - 1 do
    local fx = K.TONE.MON + i
    if guid then
      if reaper.TrackFX_GetFXGUID(master, fx) == guid then return fx end
    else
      local ok, name = reaper.TrackFX_GetNamedConfigParm(master, fx, "renamed_name")
      if ok and name == K.TONE.TAG then return fx end
    end
  end
  return nil
end

--- Add the tone effect silently and remember it in state.tone. Returns false (and state.tone stays nil) on failure.
local function tone_add()
  local T = K.TONE
  local master = tone_master()
  if not master then return false end
  -- Whatever index comes back is the one used (the effect is first in the chain, so normally 0)
  local idx = reaper.TrackFX_AddByName(master, T.FX_NAME, true, T.INSERT_FIRST)
  if not idx or idx < 0 then return false end
  local fx = T.MON + idx
  -- The effect is born with Wet -12 dB and Dry -6 dB: silence it and pass the monitored audio untouched first
  reaper.TrackFX_SetParam(master, fx, T.P_WET, T.SILENT_DB)
  reaper.TrackFX_SetParam(master, fx, T.P_DRY, 0)
  if not reaper.TrackFX_SetNamedConfigParm(master, fx, "renamed_name", T.TAG) then
    tone_delete(fx)   -- an untagged effect could not be told apart from the user's own: count it as an add failure
    return false
  end
  reaper.TrackFX_SetParam(master, fx, T.P_FREQ, T.BASE_HZ)
  reaper.TrackFX_SetParam(master, fx, T.P_SHAPE, 0)
  local guid = reaper.TrackFX_GetFXGUID(master, fx)
  if not guid then
    tone_delete(fx)
    return false
  end
  state.tone = { guid = guid, gain = 0 }
  return true
end

--- Drive the note tone; call once per frame. With a pitch (MIDI note number) the tone fades in and follows it; with
--- nil it fades out and the effect is deleted. Does nothing while there is neither a tone nor a pitch. Adding or
--- deleting Monitoring FX makes no undo point, so this never opens an undo block.
K.tone_tick = function(pitch)
  local T = K.TONE
  if not state.tone then
    if not pitch or state.tone_failed then return end
    if not tone_add() then
      state.tone_failed = true
      set_status("Note tone unavailable: REAPER's Tone Generator effect was not found")
      return
    end
  end
  local tone = state.tone
  local master = tone_master()
  local fx = master and K.tone_find(tone.guid)
  if not fx then   -- the user deleted the effect mid-drag
    state.tone = nil
    return
  end
  if pitch then
    tone.gain = math.min(1, tone.gain + 1 / T.RAMP_FRAMES)
    local note, octave, fine = K.tone_params(pitch)
    -- Fine Tune first: when a semitone is crossed, Note / Octave and Fine Tune change together, and this order never
    -- lets the tone pass through a wrong in-between pitch
    if fine ~= tone.fine then
      reaper.TrackFX_SetParam(master, fx, T.P_FINE, fine)
      tone.fine = fine
    end
    if note ~= tone.note then
      reaper.TrackFX_SetParam(master, fx, T.P_NOTE, note)
      tone.note = note
    end
    if octave ~= tone.octave then
      reaper.TrackFX_SetParam(master, fx, T.P_OCTAVE, octave)
      tone.octave = octave
    end
  else
    tone.gain = math.max(0, tone.gain - 1 / T.RAMP_FRAMES)
    if tone.gain < 1e-6 then
      tone_delete(fx)
      state.tone = nil
      return
    end
  end
  local wet_db = T.LEVEL_DB + 20 * math.log(tone.gain, 10)
  wet_db = math.max(T.SILENT_DB, wet_db)
  if wet_db ~= tone.wet then   -- only when it changed since the last frame
    reaper.TrackFX_SetParam(master, fx, T.P_WET, wet_db)
    tone.wet = wet_db
  end
end

--- Remove the tone effect at once: the instance in state.tone, then every Monitoring FX tagged K.TONE.TAG (a leftover
--- of a crashed run). Idempotent, safe before any tone started and at exit; never raises.
K.tone_kill = function()
  pcall(function()
    local tone = state.tone
    if tone then
      local fx = K.tone_find(tone.guid)
      if fx then tone_delete(fx) end
    end
    for _ = 1, 64 do   -- bounded: a delete that keeps failing must not hang the exit
      local fx = K.tone_find(nil)
      if not fx or not tone_delete(fx) then break end
    end
  end)
  state.tone = nil
end

--- Drop the in-memory analysis (results, notes, selection, a running analysis). Writes nothing to
--- REAPER: callers that also clear take data own the undo block (clear_take_analysis, wipe_entire_session).
local function reset_analysis_model()
  K.release_analysis()
  state.results = {}
  state.notes = nil
  state.split_points = nil
  state.progress = 0
  state.analysis_empty = false
  state.hovered_note = nil
  state.hovered_zone = nil
  state.selected_note = nil
  state.selected_notes = {}
  state.drag = nil
  state.marquee = nil
  state.point_drag = nil
  state.context_point = nil
  state.hovered_point = nil
  state.point_ghost = nil
  state.points_hover_note = nil
  state.points_zoom_hint = false
  state.nudge_burst = nil
  K.reset_view()   -- the canvas shows the whole item again
end

--- True when the take has no Pitch envelope yet, or it is bypassed / hidden, i.e. when
--- ensure_take_pitch_envelope(take, item, true) would change project state.
local function pitch_envelope_needs_setup(take)
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if not env then return true end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not ok or not chunk then return false end
  return chunk:match("ACT%s+0") ~= nil or chunk:match("VIS%s+0") ~= nil
end

local function start_analysis()
  -- Prefer the current target (a sidebar click sets it without touching REAPER's selection);
  -- get_target_take() falls back to the selected audio item only when there is no usable target.
  local take, item = get_target_take()

  if not item or not take then
    set_status("Select an audio item first")
    return
  end

  local guid = get_take_guid(take)
  if guid then state.target_take_guid = guid end
  state.target_take_name = reaper.GetTakeName(take) or state.target_take_name

  state.start_time = 0 -- Relative to item start
  state.item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  state.end_time = state.item_len
  state.current_time = 0

  local source = reaper.GetMediaItemTake_Source(take)
  state.sample_rate = reaper.GetMediaSourceSampleRate(source)

  -- A bad engine value must never crash (negative array size) or hang (a hop of 0 never advances the
  -- analysis time) an analysis: clamp to 64 <= block, 1 <= hop <= block before anything is allocated
  local block = math.floor(tonumber(state.block_size) or DEFAULTS.block_size)
  state.block_size = math.max(K.BLOCK_SIZE_MIN, math.min(K.BLOCK_SIZE_MAX, block))
  local hop = math.floor(tonumber(state.hop_size) or DEFAULTS.hop_size)
  state.hop_size = math.max(1, math.min(state.block_size, hop))

  -- The running analysis reads this snapshot, never the live settings: the Settings controls are locked meanwhile,
  -- and a value changed some other way cannot overrun the sample buffer or mix two parameter sets
  state.analysis_params = {
    block_size = state.block_size, hop_size = state.hop_size, threshold = state.threshold,
    min_freq = state.min_freq, max_freq = state.max_freq,
  }

  state.accessor = reaper.CreateTakeAudioAccessor(take)
  state.buffer = reaper.new_array(state.analysis_params.block_size)

  state.results = {}
  state.is_analyzing = true
  state.analysis_empty = false
  state.progress = 0
  state.nudge_burst = nil
  K.reset_view()   -- the canvas shows the whole item again

  -- Ensure take pitch envelope is created and active on the take upfront (own named undo point,
  -- and only when it actually changes something)
  if pitch_envelope_needs_setup(take) then
    reaper.Undo_BeginBlock()
    ensure_take_pitch_envelope(take, item, true)
    reaper.Undo_EndBlock("Show Pitch Envelope", -1)
    note_own_write()
  end
end

-- What the files loaded after this one use
App.reset_analysis_model = reset_analysis_model
App.start_analysis = start_analysis
