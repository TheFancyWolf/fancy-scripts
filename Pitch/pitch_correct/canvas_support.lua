-- @noindex
-- Fancy Pitch Correct: value drags, the canvas drawing cache and canvas helpers.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme = App.K, App.state, App.Theme
local get_effective = App.get_effective
local is_note_modified = App.is_note_modified

-------------------------------------------------------------------------------
-- 5. GUI
-------------------------------------------------------------------------------

-- Press state of every param_drag control: [id] = { ctrl = Ctrl/Cmd held at press, dragged = mouse moved,
-- raw = the caller's value when the press began (K.drag_revert) }
local drag_state = {}

-- Whether the control param_drag drew last is under the pointer / being dragged or typed into, and whether its press
-- began this frame. esc_used: a drag was cancelled with Esc this frame, so that Esc is spent (HC5: the active edit is
-- innermost); the window's own Esc handling reads and clears it.
K.drag_hot = { hovered = false, active = false, activated = false, esc_used = false }

--- Report that the setting `key` is hovered (dragging = false) or being changed (true) this frame, so the canvas
--- shades where it acts. notes: nil for a top bar value (every note it reaches), or a set of note indices.
--- A drag is not replaced by a hover reported in the same frame.
K.setting_hint = function(hctx, key, dragging, notes)
  local frame = reaper.ImGui_GetFrameCount(hctx) or 0
  local h = state.setting_hint
  if h.frame == frame and h.dragging and not dragging then return end
  h.key, h.dragging, h.notes, h.frame = key, dragging, notes, frame
end

local function plural(n, one, many)
  return n == 1 and one or many
end

--- Numeric part of a display format for the typed-entry field: "%.0f%%" -> "%.0f", "%.0f ms" -> "%.0f".
local function typed_format(fmt)
  return (fmt or ""):match("%%[%d%.%-+ #]*[fFgGeE]") or "%.3f"
end

--- Value control shared by every slider of the script (HC2 / HC3, EP3): a DragDouble that cannot leave
--- [lo, hi], fine-adjusts with Ctrl/Cmd-drag (speed x FINE_ADJUST_SCALE; Shift and Alt stay REAPER's),
--- resets on double-click and opens a typed-entry popup on a Ctrl/Cmd-click released without dragging.
--- Works in display units: a percent control passes value * 100 with lo = 0, hi = 100 and converts back.
---   id     stable widget id ("###id"): the visible label may change without losing the drag
---   label  visible text right of the control (nil / "" = none)
---   speed  value units per pixel (default: (hi - lo) / the item width in pixels, so a drag across the whole
---          control sweeps the whole range whatever its width; Ctrl/Cmd fine adjust is FINE_ADJUST_SCALE x that)
--- Returns changed, value, committed, reset, cancelled:
---   changed    the value moved (a drag frame, or a typed entry confirmed); value is clamped to [lo, hi]
---   committed  the edit is done: the drag was released after an edit, the typed entry was confirmed, or reset
---   reset      double-click: the caller restores its own default (the value returned is the input, untouched)
---   cancelled  HC5: the drag ended while the mouse button was still held (Esc): nothing is committed, and a caller
---              that wrote the value while it moved puts back the one from before the drag (K.drag_revert)
--- Test the gestures right here: no other item may be submitted between this call and the caller's
--- BeginPopupContextItem / IsItemHovered.
local function param_drag(pctx, id, label, value, lo, hi, fmt, speed)
  local ctrl_down = ((reaper.ImGui_GetKeyMods(pctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0   -- Cmd on macOS
  local step = speed or (hi - lo) / math.max(reaper.ImGui_CalcItemWidth(pctx) or 0, 1)
  local rv, v = reaper.ImGui_DragDouble(pctx, (label or "") .. "###" .. id, value,
    ctrl_down and step * K.FINE_ADJUST_SCALE or step, lo, hi, fmt,
    reaper.ImGui_SliderFlags_AlwaysClamp() | reaper.ImGui_SliderFlags_NoInput() | reaper.ImGui_SliderFlags_NoSpeedTweaks())
  if type(v) ~= "number" then v = value end
  v = math.max(lo, math.min(hi, v))

  -- Item state first (it describes the drag item until another item is submitted)
  local st = drag_state[id]
  if not st then st = { ctrl = false, dragged = false }; drag_state[id] = st end
  if reaper.ImGui_IsItemActivated(pctx) then st.ctrl, st.dragged = ctrl_down, false end
  if reaper.ImGui_IsItemActive(pctx) and reaper.ImGui_IsMouseDragging(pctx, 0) then st.dragged = true end
  local released = reaper.ImGui_IsItemDeactivated(pctx)
  local committed = reaper.ImGui_IsItemDeactivatedAfterEdit(pctx) == true
  local reset = reaper.ImGui_IsItemHovered(pctx) and reaper.ImGui_IsMouseDoubleClicked(pctx, 0) or false
  K.drag_hot.hovered = reaper.ImGui_IsItemHovered(pctx) == true
  K.drag_hot.active = reaper.ImGui_IsItemActive(pctx) == true
  K.drag_hot.held = K.drag_hot.active   -- the drag itself is held (active is also true while the typed entry is open)
  K.drag_hot.activated = reaper.ImGui_IsItemActivated(pctx) == true
  K.drag_hot.typed = false   -- true when the value returned was typed (not dragged)
  -- A mouse drag ends by itself only when the button comes up: ended with the button still held, it was cancelled
  -- (Esc clears ImGui's active item, which it also reports as an edit released)
  local cancelled = released and reaper.ImGui_IsMouseDown(pctx, 0) == true
  if cancelled then
    committed, reset = false, false
    K.drag_hot.esc_used = true
  end

  -- HC3: Ctrl/Cmd-click released without dragging opens the typed entry
  local popup = "###type_" .. id
  if released and st.ctrl and not st.dragged and not reset and not cancelled then
    reaper.ImGui_OpenPopup(pctx, popup)
  end
  if released or reset then st.ctrl = false end
  if reaper.ImGui_BeginPopup(pctx, popup) then
    -- HC5: Esc discards the entry; an active field handles it itself (below), this covers a lost focus
    if reaper.ImGui_Shortcut(pctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(pctx) end
    K.drag_hot.active = true   -- the typed entry is open: the value is being changed
    if reaper.ImGui_IsWindowAppearing(pctx) then
      reaper.ImGui_SetKeyboardFocusHere(pctx)
      st.text = string.format(typed_format(fmt), value)
    end
    -- InputText, not InputDouble: InputScalar asserts on EnterReturnsTrue, and without it a number field
    -- reports every keystroke as a change. The text is kept between frames and parsed on Enter.
    local ok, text = reaper.ImGui_InputText(pctx, "##typed", st.text or "",
      reaper.ImGui_InputTextFlags_EnterReturnsTrue() | reaper.ImGui_InputTextFlags_CharsDecimal()
      | reaper.ImGui_InputTextFlags_AutoSelectAll())
    if type(text) == "string" then st.text = text end
    local typed = ok and tonumber(st.text) or nil
    if typed then
      rv, v, committed = true, math.max(lo, math.min(hi, typed)), true
      K.drag_hot.typed = true
      reaper.ImGui_CloseCurrentPopup(pctx)
    elseif ok or reaper.ImGui_IsItemDeactivated(pctx) then
      reaper.ImGui_CloseCurrentPopup(pctx)   -- Esc or a click elsewhere: the entry is discarded
    end
    reaper.ImGui_EndPopup(pctx)
  end

  if reset then return false, value, true, true, false end
  if cancelled then return false, value, false, false, true end
  return rv == true, v, committed, false, false
end

--- For a param_drag caller that writes the value while it moves. Call right after param_drag with `raw`, the caller's
--- own value as it read it before drawing the control: it is remembered when the press begins, and returned when the
--- drag was cancelled (Esc) so the caller can put it back; nil otherwise. `raw` must not be nil.
K.drag_revert = function(id, raw, cancelled)
  local st = drag_state[id]
  if not st then return nil end
  if K.drag_hot.activated then st.raw = raw end
  if cancelled then return st.raw end
  return nil
end

-------------------------------------------------------------------------------
-- Canvas drawing cache. The coordinates of the raw pitch trace and of each note's trend and preview lines are
-- reaper.arrays with thousands of points, and the raw min / max of the analysis frames is a scan over all of
-- them: none of it changes while the user only looks. They are kept in state.draw_cache and rebuilt only when
-- something they are made of changed. The key of each cached value is EVERY input of its computation, compared
-- each frame (a few numbers and table identities, no allocation), so the cache needs no revision counter that
-- every edit would have to remember to bump:
--   * the mapping from time and pitch to screen: the note area's origin and size, the visible time window and the
--     pitch range (state.draw_cache.map; gen counts its changes, and it covers zoom, scroll, resize, a window that
--     moved and the pitch range that follows the notes while they are dragged)
--   * the data: the analysis frames (state.results only ever grows by appending, a new analysis or a reload makes a
--     new table, and no frame is changed after it is made) and, per note, the identity of its frames / trend /
--     modulation / vibrato arrays (a split, merge, trim or re-extraction makes new ones; none is written in place)
--     plus, for the preview, everything the correction reads (K.correction_view compares it all each frame)
-- Edits therefore show on the very next frame, and a frame that changed nothing rebuilds nothing.
-------------------------------------------------------------------------------

--- An array of n numbers: `arr` resized when its allocation has room (reaper.array.resize stays within the
--- allocation), otherwise a new one with room to spare, so a curve that grows by a point or two per frame
--- (an analysis in progress) does not allocate on every frame.
K.fit_array = function(arr, n)
  local alloc = arr and arr.get_alloc() or 0
  if alloc < n then arr = reaper.new_array(math.max(n, alloc * 2)) end
  arr.resize(n)
  return arr
end

--- Raw min / max pitch over the analysis frames of `results` (has: some frame carries a pitch). Frames are only
--- appended, so each call looks only at the frames added since the last one (a different table starts over).
K.results_range = function(results)
  local range = state.draw_cache.range
  local n = #results
  if range.results ~= results or n < range.n then
    range.results, range.n, range.min, range.max, range.has = results, 0, 127, 0, false
  end
  for i = range.n + 1, n do
    local note = results[i].note
    if note then
      range.has = true
      if note < range.min then range.min = note end
      if note > range.max then range.max = note end
    end
  end
  range.n = n
  return range.has, range.min, range.max
end

--- The loudest frame (RMS) of `results`, for scaling the amplitude envelope drawn inside the notes; 0 when no
--- frame carries one (an analysis saved before the RMS was stored). Incremental, like K.results_range.
K.results_peak = function(results)
  local peak = state.draw_cache.peak
  local n = #results
  if peak.results ~= results or n < peak.n then
    peak.results, peak.n, peak.max = results, 0, 0
  end
  for i = peak.n + 1, n do
    local rms = results[i].rms
    if rms and rms > peak.max then peak.max = rms end
  end
  peak.n = n
  return peak.max
end

--- The waveform of the target item: its peaks from REAPER (the ones the arrange view draws), one maximum and one
--- minimum per 1 / rate seconds from the item's start, first channel. Returns the cache table (buf = reaper.array
--- holding `total` maxima then `total` minima, n = how many of each REAPER returned, rate = peaks per second,
--- peak = the largest absolute value, gen = counts the fetches), or nil while there is nothing to draw (no item,
--- peaks not built yet, a silent item): the caller then falls back to the loudness envelope of the analysis.
--- The peaks are fetched once per item and again only when something they depend on changed (another take, the
--- item's length, the take's start offset, play rate or source): that is looked at when the project state changed,
--- not on every frame.
K.take_wave = function(take, item)
  if not take or not item then return nil end
  local wv = state.draw_cache.wave
  if wv.take ~= take or wv.count ~= state.cache.count then
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
    local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local src = reaper.GetMediaItemTake_Source(take)
    if wv.take ~= take or wv.len ~= len or wv.offs ~= offs or wv.playrate ~= playrate or wv.src ~= src then
      wv.take, wv.len, wv.offs, wv.playrate, wv.src = take, len, offs, playrate, src
      wv.n, wv.stale, wv.retry_at = 0, true, 0
    end
    wv.count = state.cache.count
  end

  if wv.stale and wv.len > 0 and reaper.time_precise() >= wv.retry_at then
    local total = math.max(1, math.min(K.WAVE_MAX_SAMPLES, math.ceil(wv.len * K.WAVE_RATE)))
    local rate = total / wv.len
    local buf = K.fit_array(wv.buf, total * 2)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
    -- One channel, no extra data. The return value's low 20 bits are the number of peaks written per block
    local ret = reaper.GetMediaItemTake_Peaks(take, rate, pos, 1, total, 0, buf)
    local got = math.min(total, (math.tointeger(ret) or 0) & 0xFFFFF)
    wv.buf = buf
    if got > 0 then
      local peak = 0
      for i = 1, got do
        local hi, lo = math.abs(buf[i]), math.abs(buf[total + i])
        if hi > peak then peak = hi end
        if lo > peak then peak = lo end
      end
      wv.n, wv.total, wv.rate, wv.peak = got, total, rate, peak
      wv.stale = false
      wv.gen = (wv.gen or 0) + 1
    else
      wv.n = 0
      wv.retry_at = reaper.time_precise() + K.WAVE_RETRY_S   -- the peaks are not built yet: ask again shortly
    end
  end

  if wv.n > 0 and wv.peak > 0 then return wv end
  return nil
end

--- The waveform of `note` between the screen positions x0 and x1 (the visible part of its block), as columns
--- WAVE_COL_PX wide: e.w_cols holds, per column, its x and the highest and lowest sample in it as fractions of the
--- item's peak (-1 .. 1), and e.w_n how many columns there are. Kept per note until the mapping, the block's
--- extent or the peaks change; the block's height is not part of it, so a pitch drag reuses it.
K.note_wave = function(note, wave, x0, x1, x_to_t)
  local dc = state.draw_cache
  local e = K.note_entry(note)
  if not (e.w_cols and e.w_gen == dc.gen and e.w_wave == wave.gen and e.w_x0 == x0 and e.w_x1 == x1) then
    local cols = e.w_cols or {}
    local buf, n, total, rate, peak = wave.buf, wave.n, wave.total, wave.rate, wave.peak
    local step = K.WAVE_COL_PX
    local count = 0
    local x = x0
    while x < x1 do
      -- The peaks this column covers (times are relative to the item's start, as the note times are)
      local i0 = math.floor(x_to_t(x) * rate) + 1
      local i1 = math.floor(x_to_t(math.min(x1, x + step)) * rate) + 1
      if i0 < 1 then i0 = 1 end
      if i1 > n then i1 = n end
      if i0 <= i1 then
        local hi, lo = buf[i0], buf[total + i0]
        for i = i0 + 1, i1 do
          local a, b = buf[i], buf[total + i]
          if a > hi then hi = a end
          if b < lo then lo = b end
        end
        local base = count * 3
        cols[base + 1], cols[base + 2], cols[base + 3] = x, hi / peak, lo / peak
        count = count + 1
      end
      x = x + step
    end
    e.w_cols, e.w_n, e.w_gen, e.w_wave, e.w_x0, e.w_x1 = cols, count, dc.gen, wave.gen, x0, x1
  end
  return e
end

--- The pitch range the notes need: the lowest and highest of every note's centre pitch (where it is now) and
--- original pitch (where its raw curve is), each +- half a semitone. has = false when there are no notes.
K.notes_pitch_fit = function(notes)
  local lo, hi = math.huge, -math.huge
  for _, note in ipairs(notes or {}) do
    local cp = note.controls and note.controls.center_pitch
    if cp then
      if cp - 0.5 < lo then lo = cp - 0.5 end
      if cp + 0.5 > hi then hi = cp + 0.5 end
    end
    local avg = note.avg_note
    if avg then
      if avg - 0.5 < lo then lo = avg - 0.5 end
      if avg + 0.5 > hi then hi = avg + 0.5 end
    end
  end
  if hi < lo then return false, 0, 0 end
  return true, lo, hi
end

--- Once per frame, after the canvas mapping is final: records it (px, py = the note area's top-left corner, w, h =
--- its size, vt0 .. vt1 = the visible time window, min_note, note_range = the pitch range) and counts a change in
--- state.draw_cache.gen, which every cached array carries and compares.
K.canvas_cache_begin = function(px, py, w, h, vt0, vt1, min_note, note_range)
  local dc = state.draw_cache
  local m = dc.map
  if m.px ~= px or m.py ~= py or m.w ~= w or m.h ~= h or m.vt0 ~= vt0 or m.vt1 ~= vt1
      or m.min ~= min_note or m.range ~= note_range then
    m.px, m.py, m.w, m.h, m.vt0, m.vt1, m.min, m.range = px, py, w, h, vt0, vt1, min_note, note_range
    dc.gen = dc.gen + 1
  end
end

--- The coordinates of the raw pitch trace (frames r0 .. r1 of `results` that carry a pitch) as an array for
--- DrawList_AddPolyline, or nil when fewer than two points. t_to_x is the canvas's time-to-x mapping.
K.raw_trace = function(results, r0, r1, t_to_x)
  local dc = state.draw_cache
  local raw = dc.raw
  if not (raw.results == results and raw.n == #results and raw.r0 == r0 and raw.r1 == r1 and raw.gen == dc.gen) then
    local valid_pts = 0
    for i = r0, r1 do
      if results[i].note then valid_pts = valid_pts + 1 end
    end
    if valid_pts > 1 then
      local m = dc.map
      local arr = K.fit_array(raw.arr, valid_pts * 2)
      local idx = 1
      for i = r0, r1 do
        local pt = results[i]
        if pt.note then
          arr[idx] = t_to_x(pt.time)
          arr[idx + 1] = m.py + m.h - ((pt.note - m.min) / m.range) * m.h
          idx = idx + 2
        end
      end
      raw.arr = arr
    end
    raw.results, raw.n, raw.r0, raw.r1, raw.gen, raw.valid = results, #results, r0, r1, dc.gen, valid_pts
  end
  if raw.valid > 1 then return raw.arr end
  return nil
end

--- The parts of the raw pitch trace that fall in a note's time span, as runs for DrawList_AddPolyline: arrs[1 .. count]
--- with owner[i] = the note of run i. A run starts one point before its note and ends one point after it, so that,
--- clipped to the note's block, the line reaches both edges. `notes` is in time order; notes_gen changes whenever a
--- note's extent does.
K.raw_trace_runs = function(results, r0, r1, t_to_x, notes, notes_gen)
  local dc = state.draw_cache
  local rr = dc.rruns
  if not rr then
    rr = { arrs = {}, owner = {}, count = 0, scratch = {} }
    dc.rruns = rr
  end
  if rr.gen == dc.gen and rr.ngen == notes_gen and rr.notes == notes and rr.results == results
      and rr.n == #results and rr.r0 == r0 and rr.r1 == r1 then
    return rr.arrs, rr.owner, rr.count
  end

  local m = dc.map
  local scratch = rr.scratch
  local count, len, cur, ni = 0, 0, nil, 1
  local last_x, last_y = nil, nil
  local function close_run()
    if cur and len >= 4 then
      count = count + 1
      local arr = K.fit_array(rr.arrs[count], len)
      for j = 1, len do arr[j] = scratch[j] end
      rr.arrs[count] = arr
      rr.owner[count] = cur
    end
    len = 0
  end
  for i = r0, r1 do
    local fr = results[i]
    if fr.note then
      local t = fr.time
      while notes[ni] and notes[ni].end_time < t do ni = ni + 1 end
      local nt = notes[ni]
      local owner = (nt ~= nil and t >= nt.start_time) and nt or nil
      local x, y = t_to_x(t), m.py + m.h - ((fr.note - m.min) / m.range) * m.h
      if owner ~= cur then
        if cur then
          scratch[len + 1], scratch[len + 2] = x, y   -- one point past the note
          len = len + 2
        end
        close_run()
        cur = owner
        if owner and last_x then
          scratch[1], scratch[2] = last_x, last_y   -- one point before the note
          len = 2
        end
      end
      if cur then
        scratch[len + 1], scratch[len + 2] = x, y
        len = len + 2
      end
      last_x, last_y = x, y
    end
  end
  close_run()
  for k = count + 1, #rr.owner do rr.owner[k] = nil end   -- no note is kept alive by a run that is gone

  rr.count, rr.gen, rr.ngen, rr.notes, rr.results, rr.n, rr.r0, rr.r1 = count, dc.gen, notes_gen, notes, results, #results, r0, r1
  return rr.arrs, rr.owner, count
end

--- Whether a note block overlaps the screen rectangle (x1, y1) .. (x2, y2). The other arguments are the canvas
--- mapping of this frame: time to x, and the note area's top, height, lowest pitch and pitch range.
K.note_under = function(notes, t_to_x, py, h, min_note, note_range, x1, y1, x2, y2)
  if not notes then return false end
  for _, note in ipairs(notes) do
    local cp = note.controls and note.controls.center_pitch
    if cp and t_to_x(note.end_time) > x1 and t_to_x(note.start_time) < x2 then
      local top = py + h - ((cp + 0.5 - min_note) / note_range) * h
      if top < y2 and top + h / note_range > y1 then return true end
    end
  end
  return false
end

--- The per-note cache entry (created on first use; entries go when their note does).
K.note_entry = function(note)
  local notes = state.draw_cache.notes
  local entry = notes[note]
  if not entry then
    entry = {}
    notes[note] = entry
  end
  return entry
end

--- Store v at sig[k]; true when that changed it.
K.sig_set = function(sig, k, v)
  if sig[k] ~= v then
    sig[k] = v
    return true
  end
  return false
end

--- The correction of `notes` for the canvas: K.correction_build's result with its points sorted by time, and a
--- gen that counts the rebuilds. It is rebuilt only when something the trajectory reads changed (every note's
--- extent, arrays and controls, the effective Strength / Transition / Onset Ramp of each and the Legato Gap),
--- compared each frame without allocating; so a value dragged in the top bar shows on the next frame and a
--- frame that changed nothing rebuilds nothing. `item` gives the length the points are clamped to.
K.correction_view = function(notes, item)
  local dc = state.draw_cache
  local cv = dc.corr
  if not cv then
    cv = { sig = {}, n = 0, gen = 0 }
    dc.corr = cv
  end
  local sig, set = cv.sig, K.sig_set
  local k, changed = 1, set(cv.sig, 1, notes)
  for i = 1, #notes do
    local n = notes[i]
    local c = n.controls
    changed = set(sig, k + 1, n.start_time) or changed
    changed = set(sig, k + 2, n.end_time) or changed
    changed = set(sig, k + 3, n.frames) or changed
    changed = set(sig, k + 4, n.smooth) or changed
    changed = set(sig, k + 5, c and c.tighten or 0) or changed
    changed = set(sig, k + 6, get_effective(n, "tolerance")) or changed
    changed = set(sig, k + 7, n.avg_note) or changed
    changed = set(sig, k + 8, n.voiced_start_idx) or changed
    changed = set(sig, k + 9, c and c.bypassed or false) or changed
    changed = set(sig, k + 10, c and c.center_pitch) or changed
    changed = set(sig, k + 11, c and c.scoop_shape or 0) or changed
    changed = set(sig, k + 12, get_effective(n, "retune_speed")) or changed
    changed = set(sig, k + 13, get_effective(n, "transition_ms")) or changed
    changed = set(sig, k + 14, get_effective(n, "onset_ramp_ms")) or changed
    -- An override that equals the inherited value still makes the note "edited"
    changed = set(sig, k + 15, is_note_modified(n)) or changed
    changed = set(sig, k + 16, n.points_rev or 0) or changed
    k = k + 16
  end
  changed = set(sig, k + 1, get_effective(nil, "legato_threshold_ms")) or changed
  k = k + 1
  if cv.n ~= k then
    cv.n = k
    changed = true
  end

  if changed or not cv.build then
    local item_len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or nil
    item_len = math.max(0.1, tonumber(item_len) or math.huge)
    local build = K.correction_build(notes, item_len)
    local pts = build.points
    for i = 1, #pts do pts[i].seq = i end
    table.sort(pts, function(p, q)
      if p.time ~= q.time then return p.time < q.time end
      return p.seq < q.seq
    end)
    cv.gen = cv.gen + 1
    build.gen = cv.gen
    cv.build = build
  end
  return cv.build
end

--- K.correction_view for the canvas, fetched at most once per frame (draw_graph's first caller fetches it, the
--- others reuse it); a write (apply_envelope_to_take) or other notes / item fetch it again.
K.frame_view_memo = { frame = nil, notes = nil, item = nil, build = nil }
K.frame_view = function(fctx, notes, item)
  local m = K.frame_view_memo
  local f = reaper.ImGui_GetFrameCount(fctx) or 0
  if m.frame ~= f or m.notes ~= notes or m.item ~= item or not m.build then
    m.frame, m.notes, m.item, m.build = f, notes, item, K.correction_view(notes, item)
  end
  return m.build
end

--- True when the pitch points of note n_idx are drawn: the layer is on and the note is the hovered one (`hovered`),
--- the one whose box holds the pointer (state.points_hover_note, see K.points_box_has), or a selected one.
K.points_shown = function(n_idx, hovered)
  return state.show_smart_spots and (hovered == n_idx or state.points_hover_note == n_idx
    or state.selected_note == n_idx or state.selected_notes[n_idx] == true)
end

--- True when the note's points can be hovered, grabbed and added to: a semitone row (row_h px) is at least
--- K.POINT_GRAB tall and its knots are on average at least K.POINT_GRAB apart across its block (block_w px).
--- Otherwise they are drawn at half size and the note behaves as if it had none.
K.points_live = function(note, row_h, block_w)
  local n = #K.points_knots(note)
  return row_h >= K.POINT_GRAB and (n < 2 or block_w / (n - 1) >= K.POINT_GRAB)
end

--- K.points_live for the note as the canvas maps it (t_to_x / pitch_to_y as in K.point_hit).
K.points_live_at = function(note, t_to_x, pitch_to_y)
  return K.points_live(note, pitch_to_y(0) - pitch_to_y(1), t_to_x(note.end_time) - t_to_x(note.start_time))
end

--- How far above and below a point at canvas y its grab area reaches: K.POINT_GRAB, but at most a quarter of the
--- note's block height where y lies inside the block (the block keeps half its height for its trim handles and zones).
K.point_reach_y = function(note, y, pitch_to_y)
  local cp = note.controls and note.controls.center_pitch
  if not cp then return K.POINT_GRAB end
  local top, bot = pitch_to_y(cp + 0.5), pitch_to_y(cp - 0.5)
  if y >= top and y <= bot then return math.min(K.POINT_GRAB, (bot - top) / 4) end
  return K.POINT_GRAB
end

--- True when (mx, my) lies inside the box around the note's block and the aim pitches of its points in view
--- (t0 .. t1), padded by K.POINT_GRAB: a dot above or below the block stays shown while the pointer goes to it.
K.points_box_has = function(note, mx, my, t0, t1, t_to_x, pitch_to_y, build)
  if not (note.controls and note.frames) then return false end
  local g = K.POINT_GRAB
  if mx < t_to_x(note.start_time) - g or mx > t_to_x(note.end_time) + g then return false end
  local cp = note.controls.center_pitch
  local y0, y1 = pitch_to_y(cp + 0.5), pitch_to_y(cp - 0.5)
  for _, k in ipairs(K.points_knots(note)) do
    local aim = (k.t >= t0 and k.t <= t1) and K.point_aim(note, k.frame, build) or nil
    if aim then
      local y = pitch_to_y(aim)
      y0, y1 = math.min(y0, y), math.max(y1, y)
    end
  end
  return my >= y0 - g and my <= y1 + g
end

--- The pitch a point aims for: the sung pitch at its frame plus the note's correction there. `build` is
--- K.correction_view's result; without one the note's frame_shifts are stale and count as 0. On a bypassed note
--- the sung pitch (its correction is not in effect). nil without a pitch.
K.point_aim = function(note, frame, build)
  local fr = note.frames and note.frames[frame]
  if not (fr and fr.note) then return nil end
  local bypassed = note.controls and note.controls.bypassed
  local shift = build and note.frame_shifts and not bypassed and note.frame_shifts[frame] or 0
  return fr.note + shift
end

--- The live pitch point (K.points_live) whose grab area holds (mx, my), nearest first: { note_idx, frame }, or nil.
--- A grab area reaches K.POINT_GRAB sideways but never past half the gap to a neighbouring knot, and up and down
--- as K.point_reach_y. Only the notes whose points are shown (K.points_shown, `hovered` = last frame's hovered note)
--- and the points inside the visible window t0 .. t1; bypassed notes only when `bypassed` is true, else none.
--- t_to_x / pitch_to_y map onto the canvas; build as in K.point_aim.
K.point_hit = function(notes, hovered, mx, my, t0, t1, t_to_x, pitch_to_y, build, bypassed)
  local best, best_d = nil, math.huge
  for n_idx, note in ipairs(notes) do
    local is_bypassed = (note.controls and note.controls.bypassed) and true or false
    if is_bypassed == (bypassed == true) and note.frames and K.points_shown(n_idx, hovered)
        and K.points_live_at(note, t_to_x, pitch_to_y) then
      local knots = K.points_knots(note)
      for j, k in ipairs(knots) do
        local aim = (k.t >= t0 and k.t <= t1) and K.point_aim(note, k.frame, build) or nil
        if aim then
          local x, y = t_to_x(k.t), pitch_to_y(aim)
          local reach_x = K.POINT_GRAB
          if knots[j - 1] then reach_x = math.min(reach_x, (x - t_to_x(knots[j - 1].t)) / 2) end
          if knots[j + 1] then reach_x = math.min(reach_x, (t_to_x(knots[j + 1].t) - x) / 2) end
          local dx, dy = math.abs(x - mx), math.abs(y - my)
          if dx <= reach_x and dy <= K.point_reach_y(note, y, pitch_to_y) and dx + dy < best_d then
            best, best_d = { note_idx = n_idx, frame = k.frame }, dx + dy
          end
        end
      end
    end
  end
  return best
end

--- Where a point may be added on `note` at time t (item seconds): the frame nearest to t, or nil and a reason:
--- "no_pitch" (that frame has no pitch) or "too_close" (fewer than K.POINT_MIN_GAP frames from a knot).
K.point_can_add = function(note, t)
  local frames = note.frames
  if not (note.controls and frames and #frames > 0) then return nil, "no_pitch" end
  local f = K.points_frame_at(frames, t)
  if not frames[f].note then return nil, "no_pitch" end
  for _, k in ipairs(K.points_knots(note)) do
    if math.abs(k.frame - f) < K.POINT_MIN_GAP then return nil, "too_close" end
  end
  return f
end

--- Add a point at 0 to `note` at the frame nearest to t (K.point_can_add): returns its knot, or nil and the reason.
--- No REAPER calls: the caller writes the change (apply_envelope_to_take).
K.point_add = function(note, t)
  local f, reason = K.point_can_add(note, t)
  if not f then return nil, reason end
  local ft = note.frames[f].time
  local list = note.controls.points or {}
  local pos = #list + 1
  for i, e in ipairs(list) do
    if e.t > ft then pos = i break end
  end
  table.insert(list, pos, { t = ft, st = 0, added = true })
  note.controls.points = list
  note.points_rev = (note.points_rev or 0) + 1
  return K.point_knot_at(note, f)
end

-- What a drag on a zone of a note block changes: K.ZONE_CONTROLS[zone][Shift held]. No entry = the pitch drag.
--   key      the note value (note.controls[key]); inherit = an unset value starts from the inherited one
--   lo, hi   its range; rows = a drag as tall as that many semitone rows sweeps it, or px = units per pixel
--   show     factor from the stored value to the shown one; read / hover = the drag readout and the hover tooltip
--   fine     Ctrl/Cmd-drag is fine adjust (HC2); zero_nil = a value of 0 is stored as "not set"
--   hint     the setting highlight the canvas shows while it is dragged (K.setting_hint)
K.ZONE_CONTROLS = {
  tighten = {
    [false] = { key = "tighten", lo = 0, hi = 1, rows = 2, show = 100, fine = true, zero_nil = true,
                read = "Tighten: %.0f%%", hover = "Tighten: %.0f%%", undo = "Adjust Tighten" },
    [true]  = { key = "onset_ramp_ms", lo = 5, hi = 60, px = 0.5, inherit = true, hint = "onset_ramp_ms",
                read = "Onset Ramp: %.0f ms", hover = "Onset Ramp: %.0fms (Shift+Drag)", undo = "Adjust Onset Ramp" },
  },
  pitch = {
    [true]  = { key = "transition_ms", lo = 5, hi = 60, px = 0.5, inherit = true, hint = "transition_ms",
                read = "Transition: %.0f ms", hover = "Transition: %.0fms (Shift+Drag)", undo = "Adjust Transition" },
  },
  tolerance = {
    [false] = { key = "tolerance", lo = 0, hi = 50, rows = 1, inherit = true, fine = true, hint = "tolerance",
                read = "Tolerance: %.0f\xC2\xA2", hover = "Tolerance: %.0f\xC2\xA2", undo = "Adjust Tolerance" },
    [true]  = { key = "scoop_shape", lo = 0, hi = 1, rows = 2, show = 100, hint = "scoop_shape",
                read = "Scoop: %.0f%% corrected", hover = "Scoop: %.0f%% corrected (Shift+Drag)", undo = "Adjust Scoop" },
  },
}
K.TOLERANCE_IDLE = " (used once Tighten is above 0%)"   -- appended where a note's Tolerance is shown while its Tighten is 0

--- The entry of K.ZONE_CONTROLS for a drag on `zone` with or without Shift, or nil (the pitch drag).
K.zone_control = function(zone, shift)
  local by_shift = K.ZONE_CONTROLS[zone]
  return by_shift and by_shift[shift and true or false] or nil
end

--- The value of `note` the zone control `zc` edits: its own, else the inherited one, else 0.
K.zone_value = function(zc, note)
  local v = note.controls[zc.key]
  if v == nil and zc.inherit then v = get_effective(note, zc.key) end
  return tonumber(v) or 0
end

--- The text for the value `zc` edits on `note`: the drag readout, or the hover tooltip (hover = true).
K.zone_text = function(zc, note, hover)
  local text = string.format(hover and zc.hover or zc.read, K.zone_value(zc, note) * (zc.show or 1))
  if zc.key == "tolerance" and (tonumber(note.controls.tighten) or 0) <= 0 then text = text .. K.TOLERANCE_IDLE end
  return text
end

--- The drag zone of a note block spanning sx .. ex (px) at x: "tighten" (left quarter), "tolerance" (right quarter)
--- or "pitch", each side zone at least 12 px.
K.note_zone = function(x, sx, ex)
  local zone_w = math.max(12, (ex - sx) * 0.25)
  if x < sx + zone_w then return "tighten" elseif x > ex - zone_w then return "tolerance" end
  return "pitch"
end

--- Today's Ctrl/Cmd-click on note n_idx: toggle it in or out of the selection (an added note becomes the primary).
K.toggle_note_selection = function(n_idx)
  if state.selected_notes[n_idx] then
    state.selected_notes[n_idx] = nil
    if state.selected_note == n_idx then
      state.selected_note = next(state.selected_notes)
    end
  else
    state.selected_notes[n_idx] = true
    state.selected_note = n_idx
  end
end

--- Draw the pitch points of the notes whose points are shown (K.points_shown), each at its aim pitch (K.point_aim):
--- a circle for a detected point, a diamond for the start and end, a square for an added one (shape, not colour
--- alone); a moved point carries a 1 px stem from where it sits at 0, under the points. The hovered or dragged
--- point is drawn at the diamond size with a C.handle_hover outline. The points of a note that is not live
--- (K.points_live) are drawn at half size; a bypassed note's at the sung pitch without stems (its offsets are not in
--- effect). The add-square (state.point_ghost) is a C.spot outline the size of a dot. Arguments as for K.point_hit;
--- C = canvas palette.
K.draw_points = function(draw_list, C, notes, t0, t1, t_to_x, pitch_to_y, build)
  local pd, hp = state.point_drag, state.hovered_point
  local hot = pd or hp   -- the point with the hover look
  for n_idx, note in ipairs(notes) do
    if K.points_shown(n_idx, state.hovered_note) and note.frames then
      local knots = K.points_knots(note)
      local live = K.points_live_at(note, t_to_x, pitch_to_y)
      local bypassed = note.controls and note.controls.bypassed
      for pass = 1, 2 do   -- stems first, then the points over them
        for _, k in ipairs(knots) do
          local aim = (k.t >= t0 and k.t <= t1) and K.point_aim(note, k.frame, build) or nil
          if aim then
            local x, y = t_to_x(k.t), pitch_to_y(aim)
            local is_edge = (k.kind == "start" or k.kind == "end")
            local col = is_edge and C.anchor or C.spot
            if pass == 1 then
              if k.st ~= 0 and not bypassed then
                reaper.ImGui_DrawList_AddLine(draw_list, x, pitch_to_y(aim - k.st), x, y, col, 1.0)
              end
            else
              local is_hot = live and hot ~= nil and hot.note_idx == n_idx and hot.frame == k.frame
              local r = (is_hot or is_edge) and K.ANCHOR_R or K.SPOT_R
              if not live then r = r / 2 end
              if is_edge then
                reaper.ImGui_DrawList_AddQuadFilled(draw_list, x, y - r, x + r, y, x, y + r, x - r, y, col)
                if is_hot then reaper.ImGui_DrawList_AddQuad(draw_list, x, y - r, x + r, y, x, y + r, x - r, y, C.handle_hover, 1.5) end
              elseif k.kind == "added" then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, x - r, y - r, x + r, y + r, col)
                if is_hot then reaper.ImGui_DrawList_AddRect(draw_list, x - r, y - r, x + r, y + r, C.handle_hover, 0, 0, 1.5) end
              else
                reaper.ImGui_DrawList_AddCircleFilled(draw_list, x, y, r, col)
                if is_hot then reaper.ImGui_DrawList_AddCircle(draw_list, x, y, r, C.handle_hover, 0, 1.5) end
              end
            end
          end
        end
      end
    end
  end
  local pg = state.point_ghost   -- only while the pointer rests: never during a gesture
  local gesture = pd or state.drag or state.edge_drag or state.marquee or state.view_drag
  local pg_note = pg and not gesture and notes[pg.note_idx]
  local pg_fr = pg_note and pg_note.frames and pg_note.frames[pg.frame]
  local pg_aim = pg_fr and pg_fr.time >= t0 and pg_fr.time <= t1 and K.point_aim(pg_note, pg.frame, build)
  if pg_aim then
    local x, y, r = t_to_x(pg_fr.time), pitch_to_y(pg_aim), K.SPOT_R
    reaper.ImGui_DrawList_AddRect(draw_list, x - r, y - r, x + r, y + r, C.spot, 0, 0, 1.5)
  end
end

--- The corrected-pitch preview: the pitch trace plus the correction, over the frames r0 .. r1 of `results` that
--- lie in a corrected range of `build` (K.correction_view) and carry a pitch. Returns the lines (arrays for
--- DrawList_AddPolyline, one per corrected range in view) and how many there are. The correction at a frame
--- is read between the trajectory's points as a straight line, which is what the envelope holds there.
K.preview_lines = function(results, r0, r1, t_to_x, build)
  local dc = state.draw_cache
  local pl = dc.plines
  if not pl then
    pl = { arrs = {}, count = 0, scratch = {} }
    dc.plines = pl
  end
  if pl.gen == dc.gen and pl.bgen == build.gen and pl.results == results and pl.n == #results
      and pl.r0 == r0 and pl.r1 == r1 then
    return pl.arrs, pl.count
  end

  local pts, ranges = build.points, build.ranges
  local np = #pts
  local count = 0
  if np > 0 and #ranges > 0 then
    local m = dc.map
    local scratch = pl.scratch
    local len, run_range = 0, nil
    local ri, pi = 1, 1

    -- Close the run collected in scratch[1 .. len]: a line when it has two points or more
    local function close_run()
      if len >= 4 then
        count = count + 1
        local arr = K.fit_array(pl.arrs[count], len)
        for j = 1, len do arr[j] = scratch[j] end
        pl.arrs[count] = arr
      end
      len, run_range = 0, nil
    end

    for i = r0, r1 do
      local fr = results[i]
      local t = fr.time
      while ranges[ri] and ranges[ri].t1 < t do ri = ri + 1 end
      local rg = ranges[ri]
      -- A frame without a pitch adds no point and ends nothing: the line bridges it, as the pitch trace does
      if fr.note and rg and t >= rg.t0 then
        if run_range and run_range ~= rg then close_run() end
        run_range = rg
        while pi < np and pts[pi + 1].time <= t do pi = pi + 1 end
        local p0 = pts[pi]
        local shift = p0.val
        if t > p0.time and pi < np then
          local p1 = pts[pi + 1]
          local dt = p1.time - p0.time
          if dt > 0 then shift = p0.val + (p1.val - p0.val) * (t - p0.time) / dt end
        end
        scratch[len + 1] = t_to_x(t)
        scratch[len + 2] = m.py + m.h - ((fr.note + shift - m.min) / m.range) * m.h
        len = len + 2
      elseif fr.note and len > 0 then
        close_run()
      end
    end
    close_run()
  end

  pl.count, pl.gen, pl.bgen, pl.results, pl.n, pl.r0, pl.r1 = count, dc.gen, build.gen, results, #results, r0, r1
  return pl.arrs, count
end

-- Which spans of K.correction_build each setting shades
K.HINT_KINDS = {
  transition_ms = { glide = true },
  onset_ramp_ms = { onset = true, release = true },
  legato_threshold_ms = { gap = true },
  scoop_shape = { scoop = true },
}

--- Shade where the hovered / dragged setting `hint` (state.setting_hint) acts, on the notes in view: an outline
--- on every note Strength reaches, a span over each fade, glide, joined gap or scoop for the timing values.
--- A span is as tall as the block(s) of its note(s); one narrower than two pixels is a single edge line.
--- `build` is K.correction_view's result, C the canvas palette. Returns how many marks were drawn.
K.draw_setting_hint = function(draw_list, hint, build, C)
  local m = state.draw_cache.map
  local notes, key, set = state.notes, hint.key, hint.notes
  if not (m.w and m.h and m.range and m.vt1 and m.vt1 > m.vt0 and m.range > 0) then return 0 end
  local x_min, x_max, y_min, y_max = m.px, m.px + m.w, m.py, m.py + m.h
  local pad = Theme.layout.xs
  local drawn = 0

  -- The note takes the value that is being changed. edited_only: it must also be corrected (edited, not bypassed)
  local function reached(idx, edited_only)
    local n = notes[idx]
    if not (n and n.controls) then return false end
    if set then return set[idx] ~= nil end
    if edited_only and (n.controls.bypassed or not is_note_modified(n)) then return false end
    return key == "legato_threshold_ms" or n.controls[key] == nil
  end
  local function t_x(t) return m.px + (t - m.vt0) / (m.vt1 - m.vt0) * m.w end
  local function block_y(idx)
    local cp = notes[idx].controls.center_pitch
    return m.py + m.h - ((cp + 0.5 - m.min) / m.range) * m.h, m.py + m.h - ((cp - 0.5 - m.min) / m.range) * m.h
  end

  if key == "retune_speed" then
    for idx = 1, #notes do
      local n = notes[idx]
      if n.end_time >= m.vt0 and n.start_time <= m.vt1 and reached(idx, true) then
        local top, bot = block_y(idx)
        if bot >= y_min and top <= y_max then
          reaper.ImGui_DrawList_AddRect(draw_list, math.max(x_min, t_x(n.start_time) - pad), math.max(y_min, top - pad),
            math.min(x_max, t_x(n.end_time) + pad), math.min(y_max, bot + pad), C.span_edge)
          drawn = drawn + 1
        end
      end
    end
    return drawn
  end

  if key == "tolerance" then
    -- The band a tightened note may stray in untouched: centre - Tolerance .. centre + Tolerance across its block
    for idx = 1, #notes do
      local n = notes[idx]
      if n.end_time >= m.vt0 and n.start_time <= m.vt1 and reached(idx, true)
          and (tonumber(n.controls.tighten) or 0) > 0 then
        local cp = n.controls.center_pitch
        local tol = (tonumber(get_effective(n, "tolerance")) or 0) / 100
        local top = m.py + m.h - ((cp + tol - m.min) / m.range) * m.h
        local bot = m.py + m.h - ((cp - tol - m.min) / m.range) * m.h
        local x0, x1 = math.max(x_min, t_x(n.start_time)), math.min(x_max, t_x(n.end_time))
        if bot >= y_min and top <= y_max and x1 > x0 then
          top, bot = math.max(y_min, top), math.min(y_max, bot)
          if bot - top >= 2 then reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, top, x1, bot, C.span_fill) end
          reaper.ImGui_DrawList_AddLine(draw_list, x0, top, x1, top, C.span_edge)
          reaper.ImGui_DrawList_AddLine(draw_list, x0, bot, x1, bot, C.span_edge)
          drawn = drawn + 1
        end
      end
    end
    return drawn
  end

  local kinds = K.HINT_KINDS[key]
  if not kinds then return 0 end
  for _, sp in ipairs(build.spans) do
    if kinds[sp.kind] and sp.t1 >= m.vt0 and sp.t0 <= m.vt1 then
      -- A glide is as long as the Transition of its second note; every other span belongs to its first
      local ok
      if sp.kind == "glide" then
        ok = reached(sp.b, false)
      elseif sp.kind == "gap" then
        ok = (set == nil) or set[sp.a] ~= nil or set[sp.b] ~= nil
      else
        ok = reached(sp.a, true)
      end
      if ok and notes[sp.a] and notes[sp.a].controls and (not sp.b or (notes[sp.b] and notes[sp.b].controls)) then
        local top, bot = block_y(sp.a)
        if sp.b then
          local top_b, bot_b = block_y(sp.b)
          top, bot = math.min(top, top_b), math.max(bot, bot_b)
        end
        top, bot = math.max(y_min, top), math.min(y_max, bot)
        local x0, x1 = t_x(math.min(sp.t0, sp.t1)), t_x(math.max(sp.t0, sp.t1))
        x0, x1 = math.max(x_min, x0), math.min(x_max, x1)
        if bot > top and x1 >= x0 then
          if x1 - x0 < 2 then
            local x = (x0 + x1) * 0.5
            reaper.ImGui_DrawList_AddLine(draw_list, x, top, x, bot, C.span_edge)
          else
            reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, top, x1, bot, C.span_fill)
            reaper.ImGui_DrawList_AddLine(draw_list, x0, top, x0, bot, C.span_edge)
            reaper.ImGui_DrawList_AddLine(draw_list, x1, top, x1, bot, C.span_edge)
          end
          drawn = drawn + 1
        end
      end
    end
  end
  return drawn
end

-- What the files loaded after this one use
App.param_drag = param_drag
App.plural = plural
