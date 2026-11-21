-- @noindex
-- Fancy Pitch Correct: per-note values, pitch points, Tighten and Tolerance.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K = App.K
local get_effective = App.get_effective

-------------------------------------------------------------------------------
-- 4. SIGNAL PROCESSING & PITCH EXTRACTION HELPERS
-------------------------------------------------------------------------------

local function gaussian_filter(arr, sigma_frames)
  local n = #arr
  if n == 0 then return {} end
  if n == 1 then return { arr[1] } end
  local res = {}
  local radius = math.max(1, math.ceil(sigma_frames * 2.5))
  local weight = {}   -- [distance in frames + 1]
  for d = 0, math.min(radius, n - 1) do
    local dist = d / sigma_frames
    weight[d + 1] = math.exp(-0.5 * dist * dist)
  end
  for i = 1, n do
    local sum, w_sum = 0, 0
    for j = math.max(1, i - radius), math.min(n, i + radius) do
      local w = weight[(j < i and i - j or j - i) + 1]
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

-------------------------------------------------------------------------------
-- PER-NOTE VALUES: a note's own settings, each in note.controls[key] (nil = not set). Its pitch
-- (controls.center_pitch), its bypass (controls.bypassed) and its pitch points (controls.points) are handled apart.
--   merge    what a merged note gets: "weighted" = the merged notes' average by length, "first" = the first note's
--   edited   when the value makes its note count as edited: "positive" = above 0; "set" = stored at all (an
--            override that equals the inherited value still counts)
-------------------------------------------------------------------------------
K.NOTE_CONTROLS = {
  { key = "tighten",       merge = "weighted", edited = "positive" },   -- 0 (as sung) .. 1 (a flat line)
  { key = "tolerance",     merge = "first",    edited = "set" },        -- cents; inherits item -> global
  { key = "transition_ms", merge = "first",    edited = "set" },        -- inherits
  { key = "onset_ramp_ms", merge = "first",    edited = "set" },        -- inherits
  { key = "retune_speed",  merge = "first",    edited = "set" },        -- inherits
  { key = "scoop_shape",   merge = "first",    edited = "positive" },   -- 0 (natural) .. 1 (corrected)
}

--- The values a note cut from the note with `old_ctrl` keeps (Split, Trim): all of them, and its bypass.
K.controls_carry = function(old_ctrl)
  local out = { bypassed = old_ctrl and old_ctrl.bypassed or false }
  if old_ctrl then
    for _, d in ipairs(K.NOTE_CONTROLS) do out[d.key] = old_ctrl[d.key] end
  end
  return out
end

--- The values of the note merged from `notes` (in time order); it is not bypassed.
K.controls_merge = function(notes)
  local out = { bypassed = false }
  local first = notes[1] and notes[1].controls
  local total = 0
  for _, n in ipairs(notes) do total = total + (n.end_time - n.start_time) end
  for _, d in ipairs(K.NOTE_CONTROLS) do
    if d.merge == "weighted" then
      local sum = 0
      for _, n in ipairs(notes) do
        sum = sum + (tonumber(n.controls and n.controls[d.key]) or 0) * (n.end_time - n.start_time)
      end
      out[d.key] = (total > 0 and sum > 0) and (sum / total) or nil
    elseif first then
      out[d.key] = first[d.key]
    end
  end
  return out
end

--- True when one of the values makes its note count as edited.
K.controls_edited = function(ctrl)
  for _, d in ipairs(K.NOTE_CONTROLS) do
    local v = ctrl[d.key]
    if d.edited == "set" then
      if v ~= nil then return true end
    elseif (tonumber(v) or 0) > 0 then
      return true
    end
  end
  return false
end

--- Unset every value; true when one was stored.
K.controls_clear = function(ctrl)
  local changed = false
  for _, d in ipairs(K.NOTE_CONTROLS) do
    if ctrl[d.key] ~= nil then changed = true end
    ctrl[d.key] = nil
  end
  return changed
end

--- Take the saved controls of a note over into `ctrl` (a new note's defaults): its pitch, its bypass, its points
--- (checked afterwards by K.points_sanitize) and the values above, each a number; Tighten and Tolerance are held
--- in range. Anything else that was saved is dropped (Stability and Vibrato of builds before 2.12).
K.controls_load = function(ctrl, saved)
  if type(saved) ~= "table" then return end
  if type(saved.center_pitch) == "number" then ctrl.center_pitch = saved.center_pitch end
  ctrl.bypassed = saved.bypassed == true
  ctrl.points = saved.points
  for _, d in ipairs(K.NOTE_CONTROLS) do ctrl[d.key] = tonumber(saved[d.key]) end
  local lim = K.LIMITS.tolerance
  if ctrl.tighten then ctrl.tighten = (ctrl.tighten > 0) and math.min(1, ctrl.tighten) or nil end
  if ctrl.tolerance then ctrl.tolerance = math.max(lim[1], math.min(lim[2], ctrl.tolerance)) end
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

  -- 2. Zero-phase Gaussian filtering: the smooth pitch (what Tighten works on) and the slow trend
  --    Smooth pitch (sigma ~1.5 frames) removes micro-jitters without phase distortion
  --    Trend (sigma ~7.0 frames, ~2 Hz cutoff) isolates slow drift without vibrato ripple
  local smooth_pitch = gaussian_filter(raw_pitch, 1.5)
  local trend = gaussian_filter(raw_pitch, 7.0)

  -- 3. Modulation: the fast movement around the trend (its peaks and valleys are the pitch points, step 5)
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
  -- These peaks and valleys also define where saved pitch points (bends) are pinned: changing the 0.05 threshold
  -- or the filters below reshapes every stored bend and marks those items outdated.
  local smart_spots = {}

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
        table.insert(smart_spots, { index = extrema_idx, type = s_type })
      end
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    end
  end

  if extrema_idx and math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
    local s_type = current_sign == 1 and "peak" or "valley"
    table.insert(smart_spots, { index = extrema_idx, type = s_type })
  end


  note.smooth = smooth_pitch   -- the lightly smoothed pitch Tighten works on (K.tighten_line)
  note.smart_spots = smart_spots

  -- Default controls: NO correction (green preview = raw pitch). Every value of K.NOTE_CONTROLS starts unset.
  note.controls = {
    center_pitch = note.avg_note,
    bypassed = false,          -- per-note bypass toggle
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

-------------------------------------------------------------------------------
-- PITCH POINTS: a per-note offset curve through the note's start and end, its detected peaks and valleys and the
-- points the user added. Stored in note.controls.points (sorted by t): { t = item seconds (a frame's time),
-- st = semitones, added = true | nil }, only for an added point or one off 0; nil when there is none.
-------------------------------------------------------------------------------

--- The index of the frame of `frames` (sorted by time, at least one) nearest to the time t.
K.points_frame_at = function(frames, t)
  local lo, hi = 1, #frames
  while lo < hi do
    local mid = (lo + hi) // 2
    if frames[mid].time < t then lo = mid + 1 else hi = mid end
  end
  if lo > 1 and math.abs(frames[lo - 1].time - t) <= math.abs(frames[lo].time - t) then return lo - 1 end
  return lo
end

--- An offset as stored: within ±K.POINT_MAX_ST, rounded to 1e-6 st (a value the take data's JSON, %.10g, keeps
--- exactly, so the envelope written now and the one rebuilt after a reload come from the same number), and 0
--- under K.POINT_EPS.
K.points_clamp = function(st)
  st = math.max(-K.POINT_MAX_ST, math.min(K.POINT_MAX_ST, st))
  st = math.floor(st * 1e6 + 0.5) / 1e6
  if math.abs(st) < K.POINT_EPS then return 0 end
  return st
end

--- Make the stored points of `note` usable (saved data may be old, edited or damaged): an entry whose t or st is
--- not a number or whose t lies outside the note is dropped, st is clamped, t snaps to the nearest frame, of two
--- entries on one frame the first is kept, an entry the rule does not allow (not added, at 0) is dropped; the list
--- is sorted, and nil when empty.
K.points_sanitize = function(note)
  local ctrl = note.controls
  if not ctrl then return end
  local list, frames = ctrl.points, note.frames
  local kept, used = {}, {}
  if type(list) == "table" and frames and #frames > 0 then
    for _, e in ipairs(list) do
      if type(e) == "table" and type(e.t) == "number" and type(e.st) == "number" and e.st == e.st
          and e.t >= note.start_time and e.t <= note.end_time then
        local f = K.points_frame_at(frames, e.t)
        local st = K.points_clamp(e.st)
        local added = (e.added == true) or nil
        if not used[f] and (added or st ~= 0) then
          used[f] = true
          kept[#kept + 1] = { t = frames[f].time, st = st, added = added }
        end
      end
    end
  end
  table.sort(kept, function(a, b) return a.t < b.t end)
  ctrl.points = (#kept > 0) and kept or nil
  note.points_rev = (note.points_rev or 0) + 1
end

--- The knots of the note's offset curve, ordered by frame: { frame, t, st, kind, entry }. kind = "start" (frame 1),
--- "end" (the last frame), "added", or "spot" (a detected peak / valley, or a stored entry that was not added).
--- A detected dot closer than K.POINT_MIN_GAP frames to a stored entry is not a knot. Cached on the note with the
--- per-frame offsets (K.points_offsets) until note.points_rev, its frames, its dots or its stored list change.
K.points_knots = function(note)
  local frames, spots = note.frames, note.smart_spots
  local list = note.controls and note.controls.points
  local rev = note.points_rev or 0
  local pc = note.points_cache
  if pc and pc.rev == rev and pc.frames == frames and pc.spots == spots and pc.list == list then return pc.knots end

  local knots, offsets = {}, nil
  local nf = frames and #frames or 0
  if nf > 0 then
    local by_frame = {}   -- [frame] = knot
    local function kind_of(f, added)
      if f == 1 then return "start" elseif f == nf then return "end" end
      return added and "added" or "spot"
    end
    local stored = {}     -- frames that hold a stored entry
    for _, e in ipairs(list or {}) do
      local f = K.points_frame_at(frames, e.t)
      if not by_frame[f] then
        by_frame[f] = { frame = f, t = frames[f].time, st = e.st, kind = kind_of(f, e.added), entry = e }
        stored[#stored + 1] = f
      end
    end
    local function near_stored(f)
      for _, s in ipairs(stored) do
        if math.abs(s - f) < K.POINT_MIN_GAP then return true end
      end
      return false
    end
    for _, f in ipairs({ 1, nf }) do
      if not by_frame[f] then by_frame[f] = { frame = f, t = frames[f].time, st = 0, kind = kind_of(f) } end
    end
    for _, spot in ipairs(spots or {}) do
      local f = spot.index
      if (spot.type == "peak" or spot.type == "valley") and f and frames[f] and not by_frame[f] and not near_stored(f) then
        by_frame[f] = { frame = f, t = frames[f].time, st = 0, kind = "spot" }
      end
    end
    for _, k in pairs(by_frame) do knots[#knots + 1] = k end
    table.sort(knots, function(a, b) return a.frame < b.frame end)

    -- Offsets: between two neighbouring knots a smoothstep from one value to the other (flat at both, no
    -- overshoot); nil when every knot is at 0
    for _, k in ipairs(knots) do
      if k.st ~= 0 then offsets = {} break end
    end
    if offsets then
      if #knots == 1 then offsets[1] = knots[1].st end
      for j = 1, #knots - 1 do
        local a, b = knots[j], knots[j + 1]
        local span = b.frame - a.frame
        for i = a.frame, b.frame do
          offsets[i] = a.st + (b.st - a.st) * smoothstep((i - a.frame) / span)
        end
      end
    end
  end
  note.points_cache = { rev = rev, frames = frames, spots = spots, list = list, knots = knots, offsets = offsets }
  return knots
end

--- The per-frame offset (semitones) of the note's points, or nil when every point is at 0. Pure, cached.
K.points_offsets = function(note)
  K.points_knots(note)
  return note.points_cache.offsets
end

--- The knot of `note` on frame `frame`, or nil.
K.point_knot_at = function(note, frame)
  for _, k in ipairs(K.points_knots(note)) do
    if k.frame == frame then return k end
  end
  return nil
end

--- Set the offset of `knot` (a knot of `note`, or { frame, t, st = 0 } for a frame that has none) to st semitones:
--- clamped, 0 under K.POINT_EPS; the stored entry is created, updated or removed by the entry rule. No REAPER calls:
--- the caller writes the change (apply_envelope_to_take).
K.point_set = function(note, knot, st)
  local ctrl = note.controls
  if not ctrl or not knot then return end
  st = K.points_clamp(st)
  local list = ctrl.points
  local entry = knot.entry
  if entry and list then
    if st == 0 and not entry.added then
      for i = #list, 1, -1 do
        if list[i] == entry then table.remove(list, i) end
      end
      if #list == 0 then ctrl.points = nil end
    else
      entry.st = st
    end
  elseif st ~= 0 then
    list = list or {}
    local pos = #list + 1
    for i, e in ipairs(list) do
      if e.t > knot.t then pos = i break end
    end
    table.insert(list, pos, { t = knot.t, st = st })
    ctrl.points = list
  end
  note.points_rev = (note.points_rev or 0) + 1
end

--- How many points the note stores (moved or added).
K.points_count = function(note)
  local list = note and note.controls and note.controls.points
  return list and #list or 0
end

--- Clear the note's stored points; returns how many there were.
K.points_reset = function(note)
  local n = K.points_count(note)
  if n > 0 then
    note.controls.points = nil
    note.points_rev = (note.points_rev or 0) + 1
  end
  return n
end

--- Remove the added point `knot` of `note` (a detected, start or end point stays: it has no stored entry to drop,
--- and a moved one is put back with K.point_set). Returns true when something was removed. No REAPER calls.
K.point_remove = function(note, knot)
  local list = note and note.controls and note.controls.points
  if not (list and knot and knot.kind == "added" and knot.entry) then return false end
  for i = #list, 1, -1 do
    if list[i] == knot.entry then table.remove(list, i) end
  end
  if #list == 0 then note.controls.points = nil end
  note.points_rev = (note.points_rev or 0) + 1
  return true
end

--- The offset (semitones) the points curve of whichever of `notes` holds the time t has at its frame nearest to t;
--- 0 outside all of them or where that note's points are all at 0. Pure.
K.points_curve_at = function(notes, t)
  for _, n in ipairs(notes) do
    if n.frames and #n.frames > 0 and t >= n.start_time and t <= n.end_time then
      local offsets = K.points_offsets(n)
      return offsets and (offsets[K.points_frame_at(n.frames, t)] or 0) or 0
    end
  end
  return 0
end

--- Carry the bend of `old_notes` (the notes as they were before a split, merge or trim, unchanged) over to
--- `new_note` (run after extract_note_features(new_note, ...)): (1) every stored entry of old_notes whose time lies
--- inside new_note is copied, on new_note's nearest frame (of two closer than K.POINT_MIN_GAP frames the first in
--- time is kept); (2) every other knot of new_note (its start, end and re-detected dots) takes the old curve's value
--- at its time; (3) at each knot time of old_notes and each of `pin_times` inside new_note where the new curve now
--- differs from the old one by K.POINT_EPS or more, an added entry holds the old curve's value (when no knot is within
--- K.POINT_MIN_GAP frames). Returns how many stored entries lay outside new_note (dropped). No REAPER calls: the
--- caller writes the change.
K.points_transfer = function(new_note, old_notes, pin_times)
  local frames, ctrl = new_note.frames, new_note.controls
  if not (frames and #frames > 0 and ctrl) then return 0 end
  local dropped = 0

  -- 1. Stored entries, each normalised by its place in new_note: on its first or last frame it is that start / end
  -- point (not added, and not stored at 0); an old start or end point that is now inside the note is added (a square)
  local entries = {}
  for _, old in ipairs(old_notes) do
    local of = old.frames
    local o_first = of and #of > 0 and of[1].time
    local o_last = of and #of > 0 and of[#of].time
    for _, e in ipairs((old.controls and old.controls.points) or {}) do
      if e.t >= new_note.start_time and e.t <= new_note.end_time then
        entries[#entries + 1] = { e = e, was_edge = (e.t == o_first or e.t == o_last) }
      else
        dropped = dropped + 1
      end
    end
  end
  table.sort(entries, function(a, b) return a.e.t < b.e.t end)
  local kept, last_f, nf = {}, nil, #frames
  for _, c in ipairs(entries) do
    local f = K.points_frame_at(frames, c.e.t)
    if not last_f or f - last_f >= K.POINT_MIN_GAP then
      local st = K.points_clamp(c.e.st)
      local added = (c.e.added == true) or nil
      if f == 1 or f == nf then
        added = nil
      elseif c.was_edge then
        added = true
      end
      if added or st ~= 0 then kept[#kept + 1] = { t = frames[f].time, st = st, added = added } end
      last_f = f
    end
  end
  ctrl.points = (#kept > 0) and kept or nil
  new_note.points_rev = (new_note.points_rev or 0) + 1

  -- 2. Knots without an entry follow the old curve
  local free = {}
  for _, k in ipairs(K.points_knots(new_note)) do
    if not k.entry then free[#free + 1] = k.frame end
  end
  for _, f in ipairs(free) do
    local k = K.point_knot_at(new_note, f)  -- an entry set just before can have taken a nearby dot
    if k and not k.entry then K.point_set(new_note, k, K.points_curve_at(old_notes, k.t)) end
  end

  -- 3. Squares where the old curve had a knot (or an old edge was) that the new curve no longer follows: each old
  -- knot time and pin time inside the note, in time order, where the new offset differs from the old curve by
  -- K.POINT_EPS or more and no knot is within K.POINT_MIN_GAP frames, gets an added entry holding the old value
  local times = {}
  for _, old in ipairs(old_notes) do
    for _, k in ipairs(K.points_knots(old)) do times[#times + 1] = k.t end
  end
  for _, pt in ipairs(pin_times or {}) do times[#times + 1] = pt end
  table.sort(times)
  for _, t in ipairs(times) do
    if t >= new_note.start_time and t <= new_note.end_time then
      local f = K.points_frame_at(frames, t)
      local want = K.points_curve_at(old_notes, t)
      local offs = K.points_offsets(new_note)
      if math.abs(((offs and offs[f]) or 0) - want) >= K.POINT_EPS then
        local clear = true
        for _, k in ipairs(K.points_knots(new_note)) do
          if math.abs(k.frame - f) < K.POINT_MIN_GAP then clear = false break end
        end
        if clear then
          local list = ctrl.points or {}
          local entry = { t = frames[f].time, st = K.points_clamp(want), added = true }
          local pos = #list + 1
          for n, e in ipairs(list) do
            if e.t > entry.t then pos = n break end
          end
          table.insert(list, pos, entry)
          ctrl.points = list
          new_note.points_rev = new_note.points_rev + 1
        end
      end
    end
  end
  return dropped
end

-------------------------------------------------------------------------------
-- TIGHTEN and TOLERANCE: the two values on the sides of a note.
-- Tighten (controls.tighten, 0..1, nil = 0) removes the note's movement around its centre that is slower than a
-- time window; the window shrinks as the value rises (K.TIGHTEN_WINDOW_S at 0 %, nothing left at 100 % = a flat
-- line), so slow drift goes first, then wobble, then vibrato. Tolerance (cents; the note's own controls.tolerance,
-- else the item's, else the global default) leaves that slow line alone where it is within Tolerance of the
-- centre: only the part beyond it is removed.
-------------------------------------------------------------------------------

K.TIGHTEN_BODY_ST = 0.5     -- the note's body: from its first to its last frame this close to its centre
K.TIGHTEN_WINDOW_S = 0.4    -- the time window at 0 %
K.TIGHTEN_FADE = 0.1        -- the first tenth of the dial fades the correction in

--- The per-frame pitch (semitones) Tighten takes away from `note`, or nil when it takes nothing (Tighten at 0, or
--- a note with no body to measure). No REAPER calls. Only the body of the note is measured, so a slide into or
--- out of the note does not bend the line; the frames before and after the body take the value at the body's edge
--- (the slide keeps its shape and lands on the tightened note). Cached on the note: the filtered line until the
--- note's analysis or its Tighten changes, the result until the Tolerance it uses changes too.
K.tighten_line = function(note)
  local ctrl, sm, frames = note.controls, note.smooth, note.frames
  local amount = ctrl and tonumber(ctrl.tighten) or 0
  if amount <= 0 or not sm or not frames or #frames < 3 or #sm ~= #frames then return nil end
  amount = math.min(1, amount)
  local nf, centre = #frames, note.avg_note

  local tc = note.tighten_cache
  if not (tc and tc.frames == frames and tc.smooth == sm and tc.avg == centre and tc.amount == amount) then
    tc = { frames = frames, smooth = sm, avg = centre, amount = amount, line = false }
    note.tighten_cache = tc
    local a, b
    for i = 1, nf do
      if math.abs(sm[i] - centre) <= K.TIGHTEN_BODY_ST then a = i break end
    end
    for i = nf, 1, -1 do
      if math.abs(sm[i] - centre) <= K.TIGHTEN_BODY_ST then b = i break end
    end
    local hop = (frames[nf].time - frames[1].time) / (nf - 1)
    if a and b - a >= 2 and hop > 0 then
      local dev = {}
      for i = a, b do dev[#dev + 1] = sm[i] - centre end
      local window = K.TIGHTEN_WINDOW_S * (1 - amount) ^ 2
      local line = (window > 0) and gaussian_filter(dev, window / hop) or dev
      local gain = smoothstep(amount / K.TIGHTEN_FADE)
      for k = 1, #line do line[k] = line[k] * gain end
      tc.line, tc.a, tc.b = line, a, b
    end
  end
  local line = tc.line
  if not line then return nil end

  local tol = math.max(0, tonumber(get_effective(note, "tolerance")) or 0) / 100
  if tc.tol ~= tol then
    local a, b = tc.a, tc.b
    local out = {}
    for k = 1, #line do
      local v = line[k]
      if tol > 0 then
        local mag = math.abs(v)
        v = (mag > tol) and v * (1 - tol / mag) or 0
      end
      out[a + k - 1] = v
    end
    for i = 1, a - 1 do out[i] = out[a] end
    for i = b + 1, nf do out[i] = out[b] end
    tc.tol, tc.out = tol, out
  end
  return tc.out
end

local function is_note_modified(note)
  if not note or not note.controls then return false end
  local ctrl = note.controls
  if ctrl.bypassed then return true end
  return math.abs(ctrl.center_pitch - note.avg_note) > 0.001 or K.controls_edited(ctrl)
    or K.points_offsets(note) ~= nil
end

-- What the files loaded after this one use
App.extract_note_features = extract_note_features
App.is_note_modified = is_note_modified
App.rdp_simplify = rdp_simplify
App.smoothstep = smoothstep
