-- @noindex
-- Fancy Pitch Correct: multi-item session, project persistence and writing the envelope.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, ctx, JSON = App.K, App.state, App.ctx, App.JSON
local ensure_take_pitch_envelope = App.ensure_take_pitch_envelope
local extract_note_features = App.extract_note_features
local get_effective = App.get_effective
local get_take_guid = App.get_take_guid
local get_target_take = App.get_target_take
local is_note_modified = App.is_note_modified
local is_pitch_in_scale = App.is_pitch_in_scale
local note_own_write = App.note_own_write
local rdp_simplify = App.rdp_simplify
local read_take_raw = App.read_take_raw
local reset_analysis_model = App.reset_analysis_model
local resolve_take_by_guid = App.resolve_take_by_guid
local set_status = App.set_status
local smoothstep = App.smoothstep
local update_scale_pitch_classes = App.update_scale_pitch_classes

-- Forward declarations: each is assigned below, after the functions it calls
local reset_selected_note
local snap_selected_note
local quantize_selected_notes_to_scale
local flush_nudge_burst -- commits a pending arrow-key nudge as one undo point (defined after apply_envelope_to_take)

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
    scale_idx = data.scale_idx or state.scale_idx,
    overrides = data.overrides or nil
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
  reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, json_str, true)

  -- Remember what is now stored (read back) so the resync never treats our own write as external; what was stored
  -- before (readable or not) is replaced
  local guid = get_take_guid(take)
  if guid then
    state.raw_cache[guid] = read_take_raw(take)
    state.unreadable_takes[guid] = nil
  end
end

--- Save the active Key/Scale. The global ExtState write stays outside undo; the per-take model
--- write is one named undo point so Cmd+Z reverts it together with the Key/Scale selection.
local function save_current_scale_settings()
  reaper.SetExtState("FancyScripts", "pitch_key_idx", tostring(state.key_idx), true)
  reaper.SetExtState("FancyScripts", "pitch_scale_idx", tostring(state.scale_idx), true)
  if state.target_take_guid and state.session_takes[state.target_take_guid] then
    local data = state.session_takes[state.target_take_guid]
    data.key_idx = state.key_idx
    data.scale_idx = state.scale_idx
    local take = resolve_take_by_guid(state.target_take_guid)
    if take then
      reaper.Undo_BeginBlock()
      save_take_data(take, data)
      reaper.Undo_EndBlock("Change Key/Scale", -1)
      note_own_write()
    end
  end
end

--- Parse the pitch model stored on a take. raw is the P_EXT string when the caller already read it.
--- Records the raw string in state.raw_cache so the resync can tell own loads from external changes.
--- Stored data that cannot be used (it does not decode, or holds no analysis) is not dropped silently: the take is
--- recorded in state.unreadable_takes (the Pitched Items banner reports it); nothing stored, or data that loads,
--- clears the record. Returns the model, or nil.
local function load_take_data(take, raw)
  if not take then return nil end
  local guid = get_take_guid(take)
  local json_str = raw
  if json_str == nil then json_str = read_take_raw(take) end
  if guid then
    state.raw_cache[guid] = (json_str ~= "") and json_str or nil
  end
  if json_str == "" then
    if guid then state.unreadable_takes[guid] = nil end
    return nil
  end
  local success, data = pcall(JSON.decode, json_str)
  local readable = success and type(data) == "table" and data.results and data.notes
  if readable then
    -- A note that does not hold what the model needs makes the whole take unreadable, not the window fail
    readable = pcall(function()
      for _, note in ipairs(data.notes) do
        note.count = #note.frames
        -- The saved controls (including the per-note overrides) are kept across the re-extraction
        local saved_controls = note.controls
        extract_note_features(note)
        K.controls_load(note.controls, saved_controls)
        K.points_sanitize(note)
      end
    end)
  end
  if guid then state.unreadable_takes[guid] = (not readable) or nil end
  if readable then return data end
  return nil
end

--- True when the take's pitch envelope is bypassed. The envelope chunk is read once per take and project state
--- (state.cache.bypass), not on every frame and sidebar row.
local function is_take_pitch_bypassed(take)
  if not take then return false end
  local bypass = state.cache.bypass
  local known = bypass[take]
  if known ~= nil then return known end
  local bypassed = false
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if env then
    local retval, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if retval and chunk then
      bypassed = chunk:match("ACT%s+0") ~= nil
    end
  end
  bypass[take] = bypassed
  return bypassed
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
    reaper.Undo_EndBlock("Toggle Pitch Envelope Bypass", -1)
  end
  note_own_write()
end

--- Drop every in-flight gesture and selection, and show the whole item again (used when the model under
--- them is replaced).
local function clear_interaction_state()
  K.reset_view()
  state.selected_note = nil
  state.selected_notes = {}
  state.hovered_note = nil
  state.hovered_zone = nil
  state.hovered_edge = nil
  state.context_menu_note = nil
  state.context_edit = nil
  state.bar_edit = nil
  state.drag = nil
  state.edge_drag = nil
  state.marquee = nil
  state.point_drag = nil
  state.context_point = nil
  state.hovered_point = nil
  state.point_ghost = nil
  state.points_hover_note = nil
  state.points_zoom_hint = false
  state.shift_mode = false
  state.nudge_burst = nil
  K.tone_kill()   -- the drag that was sounding is gone
end

--- Make a session take's data the editing model (canvas, notes, key/scale). Does not touch
--- REAPER's item selection.
local function adopt_take_data(guid, data)
  local same_target = (state.target_take_guid == guid)
  local view_t0, view_t1, view_p0, view_p1 = state.view_t0, state.view_t1, state.view_p0, state.view_p1
  state.target_take_guid = guid
  state.target_take_name = data.name
  state.results = data.results
  state.notes = data.notes
  state.start_time = data.start_time
  state.end_time = data.end_time
  state.item_len = data.item_len
  state.sample_rate = data.sample_rate
  -- An analysed item that has no notes is "analysed, nothing found" (not "ready to analyze")
  state.analysis_empty = (data.notes ~= nil and #data.notes == 0 and data.results ~= nil and #data.results > 0)
  clear_interaction_state()   -- also shows the whole item and the fitted pitch range again (K.reset_view) ...
  if same_target then   -- ... unless the same take was reloaded (undo / redo): the zoom stays
    state.view_t0, state.view_t1, state.view_p0, state.view_p1 = view_t0, view_t1, view_p0, view_p1
  end

  if data.key_idx then state.key_idx = data.key_idx end
  if data.scale_idx then state.scale_idx = data.scale_idx end
  update_scale_pitch_classes()
end

--- Cancel the running analysis (header Cancel, closing the window, an error): stop reading audio, put the
--- previous model back and say so in the status line. Nothing was written for the new analysis (the model is saved
--- when it completes) and no undo block is open between frames, so there is nothing to close or undo.
--- Returns true when an analysis was running.
K.cancel_analysis = function()
  if not state.is_analyzing and not state.accessor then return false end
  K.release_analysis()
  state.progress = 0
  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if data then
    adopt_take_data(guid, data)   -- the item was analysed before: its saved model comes back
  else
    reset_analysis_model()        -- a first analysis: back to "not analysed"
  end
  -- The resync paused while analysing: a project change made meanwhile (undo etc.) is picked up next frame
  if state.last_change_count ~= reaper.GetProjectStateChangeCount(0) then state.last_change_count = nil end
  set_status(K.CANCELLED_TEXT)
  return true
end

local function switch_active_target(guid, take_obj)
  -- A pending arrow-key nudge belongs to the take being left: commit it first
  flush_nudge_burst()

  local data = state.session_takes[guid]
  if not data and take_obj then
    data = load_take_data(take_obj)
    if data then
      state.session_takes[guid] = data
      local found = false
      for _, g in ipairs(state.session_order) do if g == guid then found = true; break end end
      if not found then table.insert(state.session_order, guid) end
      state.stale_queue[#state.stale_queue + 1] = guid   -- a take that just joined the session: compare its envelope
    end
  end

  if data then
    adopt_take_data(guid, data)
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

--- Re-read the pitch model of every session take when REAPER's project state changed
--- (undo, redo, project-tab switch, item delete...). One GetProjectStateChangeCount call per
--- frame; the per-take work only runs when the count moved, and a take is only reloaded when its
--- stored P_EXT differs from what this script last wrote or loaded (state.raw_cache), so the
--- script's own edits never trigger a reload.
local function sync_with_project()
  if state.is_analyzing then return end
  local count = reaper.GetProjectStateChangeCount(0)
  if state.last_change_count == count then return end
  state.last_change_count = count
  K.queue_stale_checks()   -- an undo, a redo or an edit in REAPER may have changed an envelope

  local i = 1
  while i <= #state.session_order do
    local guid = state.session_order[i]
    local take = resolve_take_by_guid(guid, true)
    if not take then
      -- Item deleted (or project switched): keep the row, flag it
      state.missing_takes[guid] = true
      i = i + 1
    else
      state.missing_takes[guid] = nil
      local raw = read_take_raw(take)
      if raw == (state.raw_cache[guid] or "") then
        i = i + 1
      else
        local data = load_take_data(take, raw)
        local is_active = (guid == state.target_take_guid)
        if data then
          state.session_takes[guid] = data
          if is_active then adopt_take_data(guid, data) end
          i = i + 1
        elseif raw == "" then
          -- The analysis was undone away: the take has no pitch data any more
          state.session_takes[guid] = nil
          state.stale_takes[guid] = nil
          table.remove(state.session_order, i)
          if is_active then
            clear_interaction_state()
            state.results = {}
            state.notes = nil
            state.split_points = nil
            state.progress = 0
            state.analysis_empty = false
          end
        else
          -- Stored data is unreadable: keep the in-memory model (raw_cache now holds the bad string)
          i = i + 1
        end
      end
    end
  end

  -- Items whose saved analysis could not be read, and that are not listed: the data may have been fixed, cleared or
  -- restored (undo / redo) since. Such an item is re-read only when what is stored differs from what was last seen.
  for guid in pairs(state.unreadable_takes) do
    local take = (not state.session_takes[guid]) and resolve_take_by_guid(guid, true) or nil
    if take then
      local raw = read_take_raw(take)
      if raw ~= (state.raw_cache[guid] or "") then
        local data = load_take_data(take, raw)
        if data then
          state.session_takes[guid] = data
          table.insert(state.session_order, guid)
          if guid == state.target_take_guid then adopt_take_data(guid, data) end
        end
      end
    end
  end

  -- The active target has no session entry: an undone analysis may have been redone
  local target_guid = state.target_take_guid
  if target_guid and not state.session_takes[target_guid] then
    local take = resolve_take_by_guid(target_guid, true)
    if take then
      local raw = read_take_raw(take)
      if raw ~= "" and raw ~= (state.raw_cache[target_guid] or "") then
        local data = load_take_data(take, raw)
        if data then
          state.session_takes[target_guid] = data
          table.insert(state.session_order, target_guid)
          adopt_take_data(target_guid, data)
        end
      end
    end
  end
end

--- Persist the target's note model to its take (P_EXT) so it lands inside the caller's open undo block.
local function persist_take_model(take)
  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if not data or not take then return end
  if state.notes then data.notes = state.notes end
  save_take_data(take, data)
end

--- Close the undo block opened by apply_envelope_to_take: model (P_EXT) first, so Cmd+Z reverts
--- the envelope points and the note model together; then record the change count.
local function end_apply(take, undo_desc)
  persist_take_model(take)
  reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)
  state.undo_open = false
  note_own_write()
end

--- The pitch correction of `notes` as a trajectory: what the take pitch envelope holds and what the canvas
--- draws, from one calculation. Pure (no REAPER calls); it sets note.frame_shifts on every note.
--- Returns { points, spans, ranges }:
---   points  { time, val } in semitones, in generation order (the envelope writer simplifies and sorts them)
---   spans   { kind, t0, t1, a, b }: where a timing value acts. "onset" / "release" (the fade before / after
---           note a), "glide" (the blend between notes a and b; its length is note b's Transition), "gap" (the
---           joined gap between a and b), "scoop" (the bent onset of note a). a and b are note indices.
---   ranges  { t0, t1 }, sorted and merged: the time ranges an edited, non-bypassed note corrects (with its
---           ramps and glides)
K.correction_build = function(notes, item_len)
  local all_points, spans, ranges = {}, {}, {}
  local scooped = {}   -- [note index] = true: its onset frames carry a scoop correction
  local num_notes = #notes

  -- 1. Precalculate continuous frame shifts for every note
  for idx = 1, num_notes do
    local n = notes[idx]
    n.frame_shifts = {}
    -- Per-note bypass: zero out all shifts
    if n.controls and n.controls.bypassed then
      if n.frames then
        for i = 1, #n.frames do
          n.frame_shifts[i] = 0.0
        end
      end
    else
      local is_mod = is_note_modified(n)
      local retune = get_effective(n, "retune_speed")
      local coarse = is_mod and (n.controls.center_pitch - n.avg_note) * retune or 0.0
      -- Tighten takes the note's slower movement away: literal, like a pitch point (Strength does not scale it)
      local tight = is_mod and K.tighten_line(n) or nil
      if n.frames then
        for i = 1, #n.frames do
          n.frame_shifts[i] = tight and (coarse - (tight[i] or 0)) or coarse
        end

        -- Scoop: flatten the slide into the note. The onset frames are pulled toward the pitch the corrected
        -- note settles at right after the onset: fully on the first frame at 100 %, easing out to the note's
        -- normal correction by the end of the onset (so the onset meets the body without a step). 0 % leaves
        -- the slide as sung. The pull of one frame is limited to K.SCOOP_MAX_ST, so a mis-detected onset frame
        -- (an octave error) cannot write a jump of that size into the envelope.
        local scoop = (n.controls and n.controls.scoop_shape) or 0
        if scoop > 0 and is_mod and n.voiced_start_idx then
          local onset_end = math.min(n.voiced_start_idx + 8, #n.frames)
          local settle = n.frames[onset_end + 1]
          if onset_end > 1 and onset_end < #n.frames and settle and settle.note then
            local settle_pitch = settle.note + n.frame_shifts[onset_end + 1]
            for i = 1, onset_end do
              local sung = n.frames[i].note
              if sung then
                local natural = n.frame_shifts[i]
                local pull = (settle_pitch - sung) - natural   -- what would put this frame on the settled pitch
                pull = math.max(-K.SCOOP_MAX_ST, math.min(K.SCOOP_MAX_ST, pull))
                n.frame_shifts[i] = natural + pull * scoop * (1 - (i - 1) / onset_end)
              end
            end
            scooped[idx] = true
            spans[#spans + 1] = { kind = "scoop", t0 = n.frames[1].time, t1 = n.frames[onset_end].time, a = idx }
          end
        end

        -- Pitch points: the note's own offset curve, last and literal (Strength does not scale it)
        local offsets = K.points_offsets(n)
        if offsets then
          for i = 1, #n.frames do
            n.frame_shifts[i] = n.frame_shifts[i] + (offsets[i] or 0)
          end
        end
      end
    end
  end

  -- 2. Build continuous trajectory across notes and boundaries
  local legato_thresh = get_effective(nil, "legato_threshold_ms") * 0.001

  for idx = 1, num_notes do
    local n = notes[idx]
    local prev_n = notes[idx - 1]
    local next_n = notes[idx + 1]

    -- Bypassed notes produce zero shifts — skip trajectory generation
    if n.controls and n.controls.bypassed then
      goto continue_note
    end

    local is_mod = is_note_modified(n)
    local prev_mod = is_note_modified(prev_n)
    local next_mod = is_note_modified(next_n)

    -- If this note and both its neighbors are untouched, skip entirely
    if not is_mod and not prev_mod and not next_mod then
      goto continue_note
    end

    local start_shift = (n.frame_shifts and n.frame_shifts[1]) or 0.0
    local end_shift = (n.frame_shifts and n.frame_shifts[#n.frame_shifts]) or 0.0

    local trans_dur = math.min(get_effective(n, "transition_ms") * 0.001, 0.060)
    trans_dur = math.min(trans_dur, (n.end_time - n.start_time) * 0.4)

    -- The time range this note corrects (grown below by its ramps and glides)
    local range = is_mod and { t0 = n.start_time, t1 = n.end_time } or nil

    -- A. START TRANSITION
    local prev_gap = prev_n and (n.start_time - prev_n.end_time) or 999
    if prev_gap < legato_thresh and prev_n then
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
      if is_mod or prev_mod then
        spans[#spans + 1] = { kind = "glide", t0 = t_start, t1 = t_end, a = idx - 1, b = idx }
        spans[#spans + 1] = { kind = "gap", t0 = prev_n.end_time, t1 = n.start_time, a = idx - 1, b = idx }
        -- The glide belongs to the range of whichever side is edited; the previous note's range is the last one
        if range then range.t0 = math.min(range.t0, t_start) end
        local last = ranges[#ranges]
        if prev_mod and last and not (prev_n.controls and prev_n.controls.bypassed) then
          last.t1 = math.max(last.t1, t_end)
        end
      end
    else
      -- Onset from silence / start of take: smooth ramp into pitch shift
      if is_mod and math.abs(start_shift) > 0.001 then
        local onset_ramp = get_effective(n, "onset_ramp_ms") * 0.001
        local ramp_t = math.min(onset_ramp, (n.end_time - n.start_time) * 0.25)
        local t_pre = math.max(0.0, n.start_time - ramp_t)
        table.insert(all_points, { time = t_pre, val = 0.0 })
        local steps = 4
        for s = 1, steps do
          local u = s / steps
          local t = t_pre + u * (n.start_time - t_pre)
          local val = start_shift * smoothstep(u)
          table.insert(all_points, { time = t, val = val })
        end
        spans[#spans + 1] = { kind = "onset", t0 = t_pre, t1 = n.start_time, a = idx }
        range.t0 = math.min(range.t0, t_pre)
      end
    end

    -- B. NOTE BODY
    -- A tightened note and a scooped onset differ from frame to frame: their frames are written.
    -- A note with pitch points is also written frame by frame, up to each edge that is not joined to a neighbour.
    local has_points = K.points_offsets(n) ~= nil
    local fine_changed = is_mod and (scooped[idx] == true or has_points or K.tighten_line(n) ~= nil)
    local body_t_start = n.start_time + trans_dur * 0.5
    local body_t_end = n.end_time - trans_dur * 0.5
    local start_written = false   -- section A already wrote a point at body_t_start (the end of its onset ramp)
    if has_points then
      if not (prev_gap < legato_thresh and prev_n) then
        body_t_start = n.start_time
        start_written = math.abs(start_shift) > 0.001
      end
      if not (next_n and (next_n.start_time - n.end_time) < legato_thresh) then
        body_t_end = n.end_time   -- section C's release ramp starts after n.end_time (Onset Ramp >= 5 ms)
      end
    end

    if not fine_changed then
      -- Coarse shift or untouched: hold shift across body
      if is_mod then
        table.insert(all_points, { time = math.min(item_len, body_t_start), val = start_shift })
        table.insert(all_points, { time = math.min(item_len, body_t_end), val = end_shift })
      end
    else
      -- Fine contour: one point per frame across the body
      if n.frames then
        for i = 1, #n.frames do
          local t = n.frames[i].time
          if (t > body_t_start or (t == body_t_start and not start_written)) and t <= body_t_end then
            table.insert(all_points, { time = math.min(item_len, t), val = n.frame_shifts[i] })
          end
        end
      end
    end

    -- C. END TRANSITION TO SILENCE (if next note is far or this is last note)
    local next_gap = next_n and (next_n.start_time - n.end_time) or 999
    if next_gap >= legato_thresh then
      if is_mod and math.abs(end_shift) > 0.001 then
        local onset_ramp = get_effective(n, "onset_ramp_ms") * 0.001
        local ramp_t = math.min(onset_ramp, (n.end_time - n.start_time) * 0.25)
        local steps = 4
        for s = 1, steps do
          local u = s / steps
          local t = math.min(item_len, n.end_time + u * ramp_t)
          local val = end_shift * (1.0 - smoothstep(u))
          table.insert(all_points, { time = t, val = val })
        end
        local t_post = math.min(item_len, n.end_time + ramp_t + 0.001)
        table.insert(all_points, { time = t_post, val = 0.0 })
        spans[#spans + 1] = { kind = "release", t0 = n.end_time, t1 = math.min(item_len, n.end_time + ramp_t), a = idx }
        range.t1 = math.max(range.t1, t_post)
      end
    end

    if range then ranges[#ranges + 1] = range end

    ::continue_note::
  end

  -- Ranges are in note order; merge the ones that touch
  local merged = {}
  for _, r in ipairs(ranges) do
    local last = merged[#merged]
    if last and r.t0 <= last.t1 then
      last.t1 = math.max(last.t1, r.t1)
    else
      merged[#merged + 1] = r
    end
  end

  return { points = all_points, spans = spans, ranges = merged }
end

--- Rewrite the take pitch envelope from state.notes and persist the model, as one undo point.
--- keep_pitch_mode leaves the item's I_PITCHMODE untouched (used by re-analysis, which applies no correction); so does
--- the Settings option "Keep each item's own pitch algorithm" (state.keep_pitch_mode).
--- Returns true when the envelope and the model were written (one undo point); false when they were not, after
--- saying why in the status line (so a caller must not then claim an undo point).
local function apply_envelope_to_take(undo_desc, keep_pitch_mode)
  -- A pending arrow-key nudge is committed as its own undo point first
  if state.nudge_burst then flush_nudge_burst() end

  local take, item = get_target_take()
  if not take or not item then
    set_status("This item is no longer in the project")
    return false
  end

  -- The envelope is rewritten from the model with today's defaults and overrides: the take is current again
  if state.target_take_guid then
    state.stale_takes[state.target_take_guid] = nil
    state.stale_env[state.target_take_guid] = nil
  end

  reaper.Undo_BeginBlock()
  state.undo_open = true
  K.frame_view_memo.frame = nil   -- the canvas fetches the changed correction again (K.frame_view)

  -- Set pitch shift mode (Elastique Soloist Monophonic by default), unless the user keeps each item's own
  if not keep_pitch_mode and not state.keep_pitch_mode and state.pitchmode_value ~= -1 then
    reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", state.pitchmode_value)
  end

  -- Ensure pitch envelope exists
  local env = ensure_take_pitch_envelope(take, item)
  if not env then
    set_status("Couldn't show the pitch envelope on this item. Check that the item is an audio item on an unlocked track, then try again.")
    end_apply(take, "Apply Pitch Correction")
    return false
  end

  local item_len = math.max(0.1, reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))

  -- Clear existing points across the entire item
  reaper.DeleteEnvelopePointRange(env, 0, item_len + 1.0)

  local SHAPE = 5   -- Bezier
  local TENSION = 0 -- Neutral tension

  if not state.notes or #state.notes == 0 then
    reaper.Envelope_SortPointsEx(env, -1)
    reaper.UpdateArrange()
    end_apply(take, undo_desc)
    return true
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
    end_apply(take, undo_desc)
    return true
  end

  -- 1-2. The trajectory (frame shifts, scoop, ramps, glides): the same one the canvas draws
  local all_points = K.correction_build(state.notes, item_len).points

  -- 3. Adaptive decimation with sub-cent tolerance (0.01 st / 1 cent)
  local simplified = rdp_simplify(all_points, 0.01)
  for _, pt in ipairs(simplified) do
    local t = math.max(0.0, math.min(item_len, pt.time))
    reaper.InsertEnvelopePointEx(env, -1, t, pt.val, SHAPE, TENSION, 0, true)
  end

  reaper.Envelope_SortPointsEx(env, -1)
  reaper.UpdateArrange()
  end_apply(take, undo_desc)
  return true
end

--- Whether the pitch envelope of the session take `guid` differs from what its note model and today's settings
--- would write: a global default changed while another item was open, the script that wrote it computed the
--- correction differently, or the item was changed since. It is read from the project, so it is true after a
--- restart of the script too (a flag kept in memory was lost there, and the item then looked current).
--- Returns stale (boolean) and, when stale, the points { time, val } the envelope holds, sorted by time.
K.envelope_check = function(guid)
  local data = state.session_takes[guid]
  local take = data and resolve_take_by_guid(guid, true) or nil
  if not take then return false end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return false end
  local notes = (guid == state.target_take_guid) and state.notes or data.notes
  local item_len = math.max(0.1, reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0)

  local function by_time(p, q)
    if p.time ~= q.time then return p.time < q.time end
    return p.val < q.val
  end

  -- What apply_envelope_to_take would write. get_effective reads the item values of the target take, so the
  -- take stands in as the target for the length of the calculation.
  local expected = {}
  if notes and #notes > 0 then
    local saved = state.target_take_guid
    state.target_take_guid = guid
    local ok, build = pcall(K.correction_build, notes, item_len)
    state.target_take_guid = saved
    if not ok then return false end   -- a model this script cannot compute is not called stale
    for _, pt in ipairs(rdp_simplify(build.points, 0.01)) do
      expected[#expected + 1] = { time = math.max(0.0, math.min(item_len, pt.time)), val = pt.val }
    end
    table.sort(expected, by_time)
  end

  -- What the item holds. The script writes Bezier points (shape 5); a point of another shape is not its own
  -- (REAPER keeps a default point at the start of an envelope).
  local actual, written = {}, {}
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if env then
    for i = 0, (reaper.CountEnvelopePointsEx(env, -1) or 0) - 1 do
      local ok, t, v, shape = reaper.GetEnvelopePointEx(env, -1, i)
      if ok then
        local pt = { time = t, val = v }
        actual[#actual + 1] = pt
        if shape == 5 then written[#written + 1] = pt end
      end
    end
  end
  table.sort(actual, by_time)
  table.sort(written, by_time)
  -- That default point is Bezier when the user's default point shape is: one extra zero at the very start is not a difference
  if #written == #expected + 1 and math.abs(written[1].time) < 0.0001 and math.abs(written[1].val) < 0.0001 then
    table.remove(written, 1)
  end

  local same = (#written == #expected)
  if same then
    for i = 1, #expected do
      if math.abs(written[i].time - expected[i].time) > 0.0002 or math.abs(written[i].val - expected[i].val) > 0.0002 then
        same = false
        break
      end
    end
  end
  if same then return false end
  return true, actual
end

--- Ask for the envelope of every session take to be compared again (after the project changed, or a global
--- default did). The work is done one take per frame by K.stale_check_step.
K.queue_stale_checks = function()
  local q = state.stale_queue
  for i = #q, 1, -1 do q[i] = nil end
  for i, guid in ipairs(state.session_order) do q[i] = guid end
end

--- Compare the envelope of one queued take (once per frame at most; nothing when the queue is empty). It waits
--- while a gesture or an analysis is in progress: the model is then ahead of the envelope on purpose.
K.stale_check_step = function(sctx)
  local q = state.stale_queue
  if #q == 0 then return end
  if state.is_analyzing or state.drag or state.edge_drag or state.point_drag or state.nudge_burst or state.undo_open
      or reaper.ImGui_IsAnyItemActive(sctx) then
    return
  end
  local guid = table.remove(q)
  local stale, points = false, nil
  if state.session_takes[guid] and not state.missing_takes[guid] then
    stale, points = K.envelope_check(guid)
  end
  state.stale_takes[guid] = stale or nil
  state.stale_env[guid] = stale and { points = points } or nil
end

--- Commit the pending arrow-key nudge (if any) as ONE named undo point.
flush_nudge_burst = function()
  local burst = state.nudge_burst
  if not burst then return end
  state.nudge_burst = nil
  -- Drop bursts whose model is gone (target switched, analysis cleared, project reloaded)
  if not state.notes or burst.guid ~= state.target_take_guid then return end
  if math.abs(burst.total_st) < 0.001 then return end
  apply_envelope_to_take(string.format("Nudge Pitch %+.1f st", burst.total_st))
end

--- Nudge the selected notes by delta semitones. Only the preview (center_pitch) changes here;
--- the envelope and the undo point are committed once per burst by service_nudge_burst().
local function nudge_selected_notes(delta, key_name)
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then table.insert(indices, idx) end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then return end

  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    if n and n.controls then
      n.controls.center_pitch = n.controls.center_pitch + delta
    end
  end

  local burst = state.nudge_burst
  if burst and burst.guid ~= state.target_take_guid then
    flush_nudge_burst()
    burst = nil
  end
  if not burst then
    burst = { total_st = 0, last_time = 0, keys = {}, guid = state.target_take_guid }
    state.nudge_burst = burst
  end
  burst.total_st = burst.total_st + delta
  burst.last_time = reaper.time_precise()
  burst.keys[key_name] = true
end

--- Once per frame: commit the pending nudge burst when no nudge arrow is down any more, or 0.25 s
--- after the last event, or immediately when force is set (window closing / popup open).
--- A frame with a nudge arrow held counts as an event, so holding a key (whose first repeat arrives
--- after ~0.275 s) stays ONE burst instead of splitting into two undo points.
local function service_nudge_burst(force)
  local burst = state.nudge_burst
  if not burst then return end
  if force then
    flush_nudge_burst()
    return
  end
  local now = reaper.time_precise()
  local held = (burst.keys.up and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_UpArrow()))
    or (burst.keys.down and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_DownArrow()))
  if held then burst.last_time = now end
  if not held or now - burst.last_time > K.NUDGE_IDLE_S then
    flush_nudge_burst()
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

-- Snaps selected note(s) to the nearest valid in-scale pitch.
-- Returns how many notes moved (0 = nothing to change) and whether the change was written to the take (an undo point).
quantize_selected_notes_to_scale = function()
  if not state.notes then return 0 end
  local changed_count = 0
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
  if #indices == 0 then return 0 end

  for _, idx in ipairs(indices) do
    local note = state.notes[idx]
    if note and note.controls then
      local target_pitch = find_nearest_in_scale_pitch(note.controls.center_pitch)
      if math.abs(note.controls.center_pitch - target_pitch) > 0.001 then
        note.controls.center_pitch = target_pitch
        any_changed = true
        changed_count = changed_count + 1
      end
    end
  end

  local written = false
  if any_changed then
    written = apply_envelope_to_take("Quantize Pitch to Scale")
  end
  return changed_count, written
end

-- Resets the selected note(s) back to [Untouched], clearing envelope contribution.
-- Returns true when at least one note actually changed (and the envelope was rewritten).
reset_selected_note = function()
  if not state.notes then return false end
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
  if #indices == 0 then return false end

  for _, idx in ipairs(indices) do
    local sel = state.notes[idx]
    if sel and sel.controls then
      local ctrl = sel.controls
      -- Only a control that actually differs from its reset value counts as a change
      if math.abs(ctrl.center_pitch - sel.avg_note) > 0.001 or ctrl.bypassed then any_changed = true end
      if K.controls_clear(ctrl) then any_changed = true end
      if K.points_reset(sel) > 0 then any_changed = true end
      ctrl.center_pitch = sel.avg_note
      ctrl.bypassed = false
    end
  end

  -- Nothing differed: no envelope rewrite and no undo point
  if any_changed then
    apply_envelope_to_take("Reset Pitch Correction")
  end
  return any_changed
end

-- Snaps selected note(s) to the nearest exact semitone (0¢ deviation).
-- Returns how many notes moved (0 = nothing to change) and whether the change was written to the take (an undo point).
snap_selected_note = function()
  if not state.notes then return 0 end
  local changed_count = 0
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
  if #indices == 0 then return 0 end

  for _, idx in ipairs(indices) do
    local sel = state.notes[idx]
    if sel and sel.controls then
      local target_pitch = math.floor(sel.controls.center_pitch + 0.5)
      if math.abs(sel.controls.center_pitch - target_pitch) > 0.001 then
        sel.controls.center_pitch = target_pitch
        any_changed = true
        changed_count = changed_count + 1
      end
    end
  end

  local written = false
  if any_changed then
    written = apply_envelope_to_take("Snap Note to Semitone")
  end
  return changed_count, written
end

-- What the files loaded after this one use
App.apply_envelope_to_take = apply_envelope_to_take
App.clear_interaction_state = clear_interaction_state
App.flush_nudge_burst = flush_nudge_burst
App.is_take_pitch_bypassed = is_take_pitch_bypassed
App.nudge_selected_notes = nudge_selected_notes
App.quantize_selected_notes_to_scale = quantize_selected_notes_to_scale
App.reset_selected_note = reset_selected_note
App.save_current_scale_settings = save_current_scale_settings
App.scan_project_for_saved_takes = scan_project_for_saved_takes
App.service_nudge_burst = service_nudge_burst
App.snap_selected_note = snap_selected_note
App.switch_active_target = switch_active_target
App.sync_with_project = sync_with_project
App.toggle_take_pitch_bypass = toggle_take_pitch_bypass
