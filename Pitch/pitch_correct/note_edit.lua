-- @noindex
-- Fancy Pitch Correct: note topology: split, merge and edge trimming.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state = App.K, App.state
local apply_envelope_to_take = App.apply_envelope_to_take
local extract_note_features = App.extract_note_features
local set_status = App.set_status

-- Forward declarations: each is assigned below, after the functions it calls
local split_note_at
local merge_selected_notes
local trim_note_edge

-------------------------------------------------------------------------------
-- NOTE TOPOLOGY: SPLIT, MERGE & EDGE TRIMMING
-------------------------------------------------------------------------------

-- Splits the note at note_idx into two independent notes at split_time.
-- Preserves user tuning offsets on both halves and re-extracts features.
-- Returns true and whether the change was written to the take (an undo point) when the note was split, else false and
-- the reason in the user's words (the caller puts it in the status line).
split_note_at = function(note_idx, split_time)
  local too_short = "Can't split: the note needs at least 3 analysis frames on each side"
  if not state.notes or not state.notes[note_idx] then return false, "Select a note to split" end
  local note = state.notes[note_idx]
  if not note.frames or #note.frames < 6 then return false, too_short end -- need at least 3 per half
  if split_time <= note.start_time or split_time >= note.end_time then
    return false, "Move the edit cursor into the note to split it"
  end

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
  if #frames_a < 3 or #frames_b < 3 then return false, too_short end

  -- Preserve the user's pitch offset (semitones from original avg). extract_note_features replaces avg_note with its
  -- own centre (energy-weighted, over the sustained core), so each half's target is set from that centre afterwards:
  -- a target built on the plain frame mean would shift the half by the difference between the two.
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
  extract_note_features(note_a, K.controls_carry(old_ctrl))
  note_a.controls.center_pitch = note_a.avg_note + pitch_offset
  K.points_transfer(note_a, { note }, {})

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
  extract_note_features(note_b, K.controls_carry(old_ctrl))
  note_b.controls.center_pitch = note_b.avg_note + pitch_offset
  K.points_transfer(note_b, { note }, {})

  -- Splice into notes array
  state.notes[note_idx] = note_a
  table.insert(state.notes, note_idx + 1, note_b)

  -- Update selection: select left half, adjust any indices above split
  state.selected_note = note_idx
  state.selected_notes = { [note_idx] = true }

  return true, apply_envelope_to_take("Split Note")
end

-- Merges all contiguous selected notes into a single note.
-- The merged note is shifted by the duration-weighted average of the shifts the old notes had (0 when none was moved).
-- Returns true and whether the change was written to the take (an undo point) when the notes were merged, else false
-- and the reason in the user's words (the caller puts it in the status line).
merge_selected_notes = function()
  if not state.notes or not state.selected_notes then return false, "Select 2 or more notes" end

  -- Collect and sort selected indices
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  table.sort(indices)

  if #indices < 2 then return false, "Select 2 or more notes" end -- need at least 2 notes to merge

  -- Validate contiguity: indices must be consecutive
  for i = 2, #indices do
    if indices[i] ~= indices[i - 1] + 1 then
      return false, "Can't merge: notes must be next to each other"
    end
  end

  -- Validate gap size: no gap > 300ms between any pair
  for i = 2, #indices do
    local prev_note = state.notes[indices[i - 1]]
    local curr_note = state.notes[indices[i]]
    local gap = curr_note.start_time - prev_note.end_time
    if gap > 0.3 then
      return false, "Can't merge: the gap is longer than 300 ms"
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

  if #merged_frames < 3 then return false, "Can't merge: the merged note would have too few analysis frames" end

  -- Duration-weighted pitch offset (target minus detected centre) from user tuning
  local total_dur = 0
  local weighted_offset = 0
  local merged_from = {}
  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    local dur = n.end_time - n.start_time
    total_dur = total_dur + dur
    merged_from[#merged_from + 1] = n
    if n.controls then
      weighted_offset = weighted_offset + (n.controls.center_pitch - n.avg_note) * dur
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

  extract_note_features(merged, K.controls_merge(merged_from))
  -- The target follows the centre extract_note_features found (see split_note_at)
  merged.controls.center_pitch = merged.avg_note + (total_dur > 0 and (weighted_offset / total_dur) or 0)
  -- The bend of every old note carries over; a square holds each old boundary (inner end and start)
  local old_notes, pin_times = {}, {}
  for i, idx in ipairs(indices) do
    local n = state.notes[idx]
    old_notes[i] = n
    if i > 1 then pin_times[#pin_times + 1] = n.start_time end
    if i < #indices then pin_times[#pin_times + 1] = n.end_time end
  end
  K.points_transfer(merged, old_notes, pin_times)

  -- Replace in array: put merged note at first index, remove the rest
  local first_idx = indices[1]
  state.notes[first_idx] = merged
  for i = #indices, 2, -1 do
    table.remove(state.notes, indices[i])
  end

  -- Update selection
  state.selected_note = first_idx
  state.selected_notes = { [first_idx] = true }

  return true, apply_envelope_to_take("Merge Notes")
end

-- Trims the left or right edge of a note to a new time boundary.
-- Filters or extends frames, preserves pitch offset, re-extracts features. A trim that would leave the note with
-- fewer than 3 frames is refused (the edge snaps back) and says so in the status line. The note's pitch points carry
-- over (K.points_transfer); returns how many stored points lay outside the trimmed note and were removed.
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

  if #new_frames < 3 then -- too few frames remaining: the edge snaps back
    set_status("That edge can't move any further")
    return
  end

  -- Rebuild note
  local sum_note = 0
  for _, f in ipairs(new_frames) do sum_note = sum_note + f.note end
  local avg_note = sum_note / #new_frames

  -- The note as it was (rebuilt in place below), for its points; when it grew, a square holds the old edge
  local old_note = { start_time = note.start_time, end_time = note.end_time, frames = note.frames,
    smart_spots = note.smart_spots, controls = old_ctrl, points_rev = note.points_rev, points_cache = note.points_cache }
  local old_edge = (edge == "left") and note.start_time or note.end_time
  local grew = (edge == "left" and new_start < old_edge) or (edge == "right" and new_end > old_edge)

  note.start_time = new_start
  note.end_time = new_end
  note.frames = new_frames
  note.sum_note = sum_note
  note.count = #new_frames
  note.avg_note = avg_note
  note.display_note = math.floor(avg_note + 0.5)

  extract_note_features(note, K.controls_carry(old_ctrl))
  note.controls.center_pitch = note.avg_note + pitch_offset   -- from the centre extract_note_features found
  local dropped = K.points_transfer(note, { old_note }, grew and { old_edge } or {})

  -- `dropped` only when the write made an undo point (the caller's status names it)
  if not apply_envelope_to_take("Trim Note Edge") then return 0 end
  return dropped
end

-- What the files loaded after this one use
App.merge_selected_notes = merge_selected_notes
App.split_note_at = split_note_at
App.trim_note_edge = trim_note_edge
