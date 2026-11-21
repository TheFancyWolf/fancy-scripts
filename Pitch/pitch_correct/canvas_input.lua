-- @noindex
-- Fancy Pitch Correct: the pitch canvas, input: zoom and scroll, the pointer on the notes, the keyboard.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme = App.K, App.state, App.Theme
local apply_envelope_to_take = App.apply_envelope_to_take
local flush_nudge_burst = App.flush_nudge_burst
local nudge_selected_notes = App.nudge_selected_notes
local plural = App.plural
local reset_selected_note = App.reset_selected_note
local set_status = App.set_status
local trim_note_edge = App.trim_note_edge

-- Each function here is one step of draw_graph (canvas.lua) and takes its frame table `cv`: the geometry, the
-- colours, the pointer and the helpers draw_graph worked out for this frame. The view (vt0, vt1, min_note,
-- max_note, note_range, px_per_st) belongs to draw_graph: a step reads it from cv and changes it only through
-- cv.set_view, cv.set_pitch_view and cv.fit_pitch_view.

--- Zoom and scroll: the wheel, the ruler, the overview strip and the pitch strip.
local function canvas_navigate(cv)
  local is_canvas_hovered, gesture, draw_ctx, mx, px = cv.is_canvas_hovered, cv.gesture, cv.draw_ctx, cv.mx, cv.px
  local w, x_to_t, py, h, my, duration = cv.w, cv.x_to_t, cv.py, cv.h, cv.my, cv.duration
  local on_ruler, item_t0, on_overview, on_pstrip = cv.on_ruler, cv.item_t0, cv.on_overview, cv.on_pstrip
  local is_bypassed, overview_thumb, pitch_thumb = cv.is_bypassed, cv.overview_thumb, cv.pitch_thumb
  local canvas_tip_ready, ext_max, pitch_ext, ext_min = cv.canvas_tip_ready, cv.ext_max, cv.pitch_ext, cv.ext_min
  local vt0, vt1, min_note, max_note, note_range = cv.vt0, cv.vt1, cv.min_note, cv.max_note, cv.note_range
  -- A change of the view goes through draw_graph, which owns it; the copies above follow it
  local function set_view(anchor_t, frac, span)
    cv.set_view(anchor_t, frac, span)
    vt0, vt1, min_note, max_note, note_range = cv.vt0, cv.vt1, cv.min_note, cv.max_note, cv.note_range
  end
  local function set_pitch_view(p0, p1)
    cv.set_pitch_view(p0, p1)
    vt0, vt1, min_note, max_note, note_range = cv.vt0, cv.vt1, cv.min_note, cv.max_note, cv.note_range
  end
  local function fit_pitch_view()
    cv.fit_pitch_view()
    vt0, vt1, min_note, max_note, note_range = cv.vt0, cv.vt1, cv.min_note, cv.max_note, cv.note_range
  end

  if is_canvas_hovered and not gesture and not state.view_drag then
    -- Scrolling follows the axis the device sends: a vertical wheel scrolls the pitch axis, a horizontal one
    -- (trackpad, tilt wheel, a mouse's own horizontal-scroll button) scrolls the timeline (a no-op while the
    -- whole item is visible). Shift + wheel scrolls the timeline too: macOS already sends it as a horizontal
    -- wheel, elsewhere it is turned sideways here. Ctrl/Cmd + wheel zooms the timeline around the pointer and
    -- Alt + wheel zooms the pitch axis around it. Ignored during a gesture (the mapping must not change under
    -- it) and while the script window itself can scroll (the wheel belongs to it then).
    local wheel_y, wheel_x = reaper.ImGui_GetMouseWheel(draw_ctx)
    wheel_y, wheel_x = wheel_y or 0, wheel_x or 0
    if (reaper.ImGui_GetScrollMaxY(draw_ctx) or 0) > 0 then wheel_y, wheel_x = 0, 0 end
    local span = vt1 - vt0
    local wheel_mods = reaper.ImGui_GetKeyMods(draw_ctx) or 0
    if wheel_x == 0 and (wheel_mods & reaper.ImGui_Mod_Shift()) ~= 0 then wheel_y, wheel_x = 0, wheel_y end
    local notches = wheel_y ~= 0 and wheel_y or wheel_x   -- the zooms take either axis
    if notches ~= 0 and (wheel_mods & reaper.ImGui_Mod_Ctrl()) ~= 0 then
      local frac = math.max(0, math.min(1, (mx - px) / math.max(w, 1)))
      set_view(x_to_t(px + frac * w), frac, span / K.ZOOM_STEP ^ notches)
    elseif notches ~= 0 and (wheel_mods & reaper.ImGui_Mod_Alt()) ~= 0 then
      local frac = math.max(0, math.min(1, (py + h - my) / math.max(h, 1)))   -- 0 = bottom of the note area, 1 = top
      local anchor = min_note + frac * note_range
      local new_span = note_range / K.ZOOM_STEP ^ notches
      set_pitch_view(anchor - frac * new_span, anchor + (1 - frac) * new_span)
    else
      if wheel_y ~= 0 then
        local step = wheel_y * K.SCROLL_STEP * note_range   -- wheel up = higher notes
        set_pitch_view(min_note + step, max_note + step)
      end
      if wheel_x ~= 0 and span < duration - K.VIEW_EPS_S then
        set_view(vt0 - wheel_x * K.SCROLL_STEP * span, 0, span)   -- wheel left = earlier
      end
    end
    -- Double-click on the ruler shows the whole item again
    if on_ruler and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
      set_view(item_t0, 0, duration)
    elseif on_ruler and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
      -- Click on the ruler moves the edit cursor there, and playback follows it (as on REAPER's own ruler)
      local _, ruler_item = K.frame_target()
      if ruler_item then
        local item_pos = reaper.GetMediaItemInfo_Value(ruler_item, "D_POSITION")
        reaper.SetEditCurPos(item_pos + x_to_t(mx), false, true)
      end
    end
  end

  if (on_overview or on_pstrip) and not is_bypassed and not gesture and not state.view_drag then
    local a0, a1, pos
    if on_overview then
      a0, a1 = overview_thumb()
      pos = math.max(px, math.min(px + w, mx))
    else
      a0, a1 = pitch_thumb()
      pos = my
    end
    local grab = math.min(K.VIEW_GRIP, (a1 - a0) * K.EDGE_GRAB_MAX_FRAC)
    local on_start = math.abs(pos - a0) <= grab   -- the thumb's left end / top end
    local on_end = math.abs(pos - a1) <= grab     -- its right end / bottom end
    if on_start or on_end then
      reaper.ImGui_SetMouseCursor(draw_ctx, on_overview and reaper.ImGui_MouseCursor_ResizeEW() or reaper.ImGui_MouseCursor_ResizeNS())
    else
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if canvas_tip_ready then
      Theme.tooltip(draw_ctx, on_overview and "Drag to scroll. Drag an end to zoom. Double-click: whole item"
        or "Drag to scroll. Drag an end to zoom. Double-click: fit the notes")
    end

    if reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
      if on_overview then set_view(item_t0, 0, duration) else fit_pitch_view() end
    elseif reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
      flush_nudge_burst()   -- a new gesture starts: commit a pending arrow-key nudge first
      local kind = on_start and "0" or (on_end and "1" or "_pan")
      if kind == "_pan" and (pos < a0 or pos > a1) then
        -- Outside the thumb: the window is centred on the press, and the drag carries on from there
        if on_overview then
          local span = vt1 - vt0
          set_view(item_t0 + (pos - px) / math.max(w, 1) * duration - span * 0.5, 0, span)
        else
          local centre = ext_max - (pos - py) / math.max(h, 1) * pitch_ext
          set_pitch_view(centre - note_range * 0.5, centre + note_range * 0.5)
        end
      end
      if on_overview then
        state.view_drag = { kind = "t" .. kind, start = mx, a0 = vt0, a1 = vt1 }
      else
        -- p0 = the bottom end (the lowest pitch shown), p1 = the top end; the thumb's top is its "start"
        state.view_drag = { kind = "p" .. (kind == "0" and "1" or (kind == "1" and "0" or kind)), start = my, a0 = min_note, a1 = max_note }
      end
    end
  end

  if state.view_drag then
    local vd = state.view_drag
    if not reaper.ImGui_IsMouseDown(draw_ctx, 0) then
      state.view_drag = nil
    elseif vd.kind:sub(1, 1) == "t" then
      reaper.ImGui_SetMouseCursor(draw_ctx, vd.kind == "t_pan" and reaper.ImGui_MouseCursor_Hand() or reaper.ImGui_MouseCursor_ResizeEW())
      local dt = (mx - vd.start) / math.max(w, 1) * duration
      if vd.kind == "t_pan" then
        set_view(vd.a0 + dt, 0, vd.a1 - vd.a0)
      elseif vd.kind == "t0" then
        set_view(vd.a1, 1, vd.a1 - (vd.a0 + dt))   -- the right end stays where it is
      else
        set_view(vd.a0, 0, (vd.a1 + dt) - vd.a0)   -- the left end stays where it is
      end
    else
      reaper.ImGui_SetMouseCursor(draw_ctx, vd.kind == "p_pan" and reaper.ImGui_MouseCursor_Hand() or reaper.ImGui_MouseCursor_ResizeNS())
      local dp = -(my - vd.start) / math.max(h, 1) * pitch_ext   -- the strip runs downwards: down = lower notes
      local min_span = math.min(K.PITCH_MIN_VIEW_ST, pitch_ext)
      if vd.kind == "p_pan" then
        set_pitch_view(vd.a0 + dp, vd.a1 + dp)
      elseif vd.kind == "p1" then
        set_pitch_view(vd.a0, math.max(vd.a0 + min_span, math.min(ext_max, vd.a1 + dp)))   -- the bottom end stays
      else
        set_pitch_view(math.min(vd.a1 - min_span, math.max(ext_min, vd.a0 + dp)), vd.a1)   -- the top end stays
      end
    end
  end
end

--- The pointer on the notes: hover, click, right-click, and the note, point, edge and marquee drags.
local function canvas_pointer(cv)
  local is_canvas_hovered, is_bypassed, gesture, py, h = cv.is_canvas_hovered, cv.is_bypassed, cv.gesture, cv.py, cv.h
  local draw_ctx, target_item, mx, my, t_to_x, px = cv.draw_ctx, cv.target_item, cv.mx, cv.my, cv.t_to_x, cv.px
  local x_to_t, w, off_notes, vt0, vt1, min_note = cv.x_to_t, cv.w, cv.off_notes, cv.vt0, cv.vt1, cv.min_note
  local max_note, note_range, px_per_st = cv.max_note, cv.note_range, cv.px_per_st

  -- Hit-test: find hovered note, zone, and edge handles
  local prev_edge = state.hovered_edge   -- the edge the pointer rested on last frame keeps a larger grab zone
  if is_canvas_hovered and not off_notes and not is_bypassed and not gesture and state.notes then
    local p_to_y = function(p) return py + h - ((p - min_note) / note_range) * h end
    local pt_build = state.show_smart_spots and K.frame_view(draw_ctx, state.notes, target_item) or nil
    -- The note whose points were shown by hover keeps them while the pointer stays in the box around its block
    -- and its points (so a dot above or below the block can be reached)
    local phn = state.points_hover_note
    if phn and not (state.notes[phn] and K.points_box_has(state.notes[phn], mx, my, vt0, vt1, t_to_x, p_to_y, pt_build)) then
      state.points_hover_note = nil
    end
    -- A live pitch point under the pointer (on last frame's hovered, box or selected notes) is found first. With
    -- Shift held no point is hovered and no add-square shown: a Shift press goes to the note beneath.
    local hover_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
    state.hovered_point = not hover_shift
      and K.point_hit(state.notes, state.hovered_note, mx, my, vt0, vt1, t_to_x, p_to_y, pt_build) or nil
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
    for n_idx, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        local sx = t_to_x(note.start_time)
        local ex = t_to_x(note.end_time)
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h

        -- Edge grab zones, per side: EDGE_GRAB wide (EDGE_GRAB_HOVER on the edge the pointer rests on), never more than
        -- a quarter of the block, so both edges stay usable at any zoom and the body stays reachable
        local cap = (ex - sx) * K.EDGE_GRAB_MAX_FRAC
        local grab_l = math.min(cap, (prev_edge and prev_edge.note_idx == n_idx and prev_edge.edge == "left") and K.EDGE_GRAB_HOVER or K.EDGE_GRAB)
        local grab_r = math.min(cap, (prev_edge and prev_edge.note_idx == n_idx and prev_edge.edge == "right") and K.EDGE_GRAB_HOVER or K.EDGE_GRAB)

        -- Check edge handles first (higher priority than zone hover); the note-name column is not part of the note
        -- area, so a note running past the window's left edge is not grabbed from the keys
        if mx >= px - grab_l and my >= top_y and my <= bot_y then
          if math.abs(mx - sx) <= grab_l then
            state.hovered_edge = { note_idx = n_idx, edge = "left" }
            state.hovered_note = n_idx
            state.hovered_zone = nil
            break
          elseif math.abs(mx - ex) <= grab_r then
            state.hovered_edge = { note_idx = n_idx, edge = "right" }
            state.hovered_note = n_idx
            state.hovered_zone = nil
            break
          end
        end

        -- Standard zone hit-test (only if no edge match)
        if mx >= px and mx >= sx and mx <= ex and my >= top_y and my <= bot_y then
          state.hovered_note = n_idx
          state.hovered_zone = K.note_zone(mx, sx, ex)
          break
        end
      end
    end
    if state.hovered_point then
      state.points_hover_note = state.hovered_point.note_idx
    elseif state.hovered_note then
      state.points_hover_note = state.hovered_note
    end

    -- The hollow add-square: on a live note whose points are shown, no point and no edge under the pointer, the
    -- pointer within a point's reach of the pitch line at its nearest frame, and a point allowed there
    state.point_ghost = nil
    if not hover_shift and not state.hovered_point and not state.hovered_edge and state.show_smart_spots then
      local pt_t = x_to_t(mx)
      for n_idx, note in ipairs(state.notes) do
        if note.frames and pt_t >= note.start_time and pt_t <= note.end_time
            and not (note.controls and note.controls.bypassed) and K.points_shown(n_idx, state.hovered_note)
            and K.points_live_at(note, t_to_x, p_to_y) then
          local f = K.point_can_add(note, pt_t)
          local aim = f and K.point_aim(note, f, pt_build)
          if aim then
            local y = p_to_y(aim)
            if math.abs(y - my) <= K.point_reach_y(note, y, p_to_y) then
              state.point_ghost = { note_idx = n_idx, frame = f }
              break
            end
          end
        end
      end
    end

    -- The status says "zoom in" while the hovered note's points are too small to grab
    local zn = state.points_hover_note and state.notes[state.points_hover_note]
    state.points_zoom_hint = (state.show_smart_spots and zn and zn.frames and #zn.frames > 0
      and not (zn.controls and zn.controls.bypassed) and not K.points_live_at(zn, t_to_x, p_to_y)) and true or false

    -- Mouse cursor by what a drag here does: resize arrows on a pitch point, the edges and the pitch zone, a hand
    -- on the Tighten / Tolerance zones
    if state.hovered_point then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    elseif state.hovered_edge then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    elseif state.hovered_zone == "pitch" then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    elseif state.hovered_zone == "tighten" or state.hovered_zone == "tolerance" then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if state.hovered_zone == "tolerance" and state.hovered_note and not hover_shift and not state.hovered_point
        and not state.hovered_edge then
      local set = state.setting_hint.zone_set
      for k in pairs(set) do set[k] = nil end
      if state.selected_notes[state.hovered_note] then
        for idx in pairs(state.selected_notes) do set[idx] = true end
      else
        set[state.hovered_note] = true
      end
      K.setting_hint(draw_ctx, "tolerance", false, set)
    end
  elseif (not is_canvas_hovered or is_bypassed or off_notes) and not gesture then
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
    state.hovered_point = nil
    state.point_ghost = nil
    state.points_hover_note = nil
    state.points_zoom_hint = false
  end

  -- Click: select note (Shift/Cmd/Ctrl = multi-select), begin drag, edge drag, or marquee box select
  if is_canvas_hovered and not off_notes and not is_bypassed and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
    -- A new gesture starts: commit any pending arrow-key nudge as its own undo point first
    flush_nudge_burst()

    -- Resolve modifiers for selection modes (cross-platform macOS/Win/Linux)
    -- Cmd on macOS is Mod_Ctrl (MacOSXBehaviors); the Windows key / physical Ctrl are not treated as Ctrl
    local cur_mods = reaper.ImGui_GetKeyMods(draw_ctx) or 0
    local has_shift = (cur_mods & reaper.ImGui_Mod_Shift()) ~= 0
    local has_cmd_or_ctrl = (cur_mods & reaper.ImGui_Mod_Ctrl()) ~= 0

    local hp = state.hovered_point
    local hp_note = hp and state.notes and state.notes[hp.note_idx]
    local hp_knot = hp_note and K.point_knot_at(hp_note, hp.frame)
    local bp_select = nil   -- a bypassed note's point pressed with no note beneath: select that note, no drag
    if not hp_knot and not has_shift and state.notes then
      -- A press on a point of a bypassed note: say why it does not move, then handle the press as a press on the
      -- note block beneath, or, with none beneath, as a plain click on the point's note without a drag
      local bp = K.point_hit(state.notes, state.hovered_note, mx, my, vt0, vt1, t_to_x,
        function(p) return py + h - ((p - min_note) / note_range) * h end,
        state.show_smart_spots and K.frame_view(draw_ctx, state.notes, target_item) or nil, true)
      if bp then
        set_status("This note is bypassed, so its pitch points do nothing. Right-click the note to turn bypass off.")
        if not state.hovered_note and not state.hovered_edge then bp_select = bp.note_idx end
      end
    end
    -- A press on the add-square with no note block or edge beneath (the pitch line runs outside the block): no
    -- marquee, so neither press of the double-click that adds the point clears the selection or moves the edit
    -- cursor; the square's note is selected alone if it was not, so its points stay shown after the add
    local pg = state.point_ghost
    local pg_select = not bp_select and not hp_knot and not has_shift and pg and state.notes and state.notes[pg.note_idx]
      and not state.hovered_note and not state.hovered_edge and pg.note_idx or nil
    if bp_select then
      state.selected_note = bp_select
      state.selected_notes = { [bp_select] = true }
    elseif pg_select then
      if not state.selected_notes[pg_select] then
        state.selected_note = pg_select
        state.selected_notes = { [pg_select] = true }
      end
    elseif hp_knot and not has_shift then
      -- A press on a pitch point grabs the point (not the note beneath). A plain press selects its note alone unless
      -- it already was selected. Ctrl/Cmd = fine, and the selection is left as it is: a drag adds the note to it, a
      -- release without a drag is today's Ctrl/Cmd-click on the note under the pointer. A Shift press is left to the note.
      if not has_cmd_or_ctrl and not state.selected_notes[hp.note_idx] then
        state.selected_note = hp.note_idx
        state.selected_notes = { [hp.note_idx] = true }
      end
      state.point_drag = {
        note_idx = hp.note_idx,
        frame = hp.frame,
        start_st = hp_knot.st,
        st = hp_knot.st,
        last_y = my,      -- the press until the dead zone is passed, then the previous frame's pointer Y
        dirty = false,
        ctrl = has_cmd_or_ctrl or nil,                         -- pressed with Ctrl/Cmd
        under = has_cmd_or_ctrl and state.hovered_note or nil, -- the note under the pointer then
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    elseif state.hovered_edge then
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
        dirty = false,
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    elseif state.hovered_note then
      -- Note click → update selection and prepare the drag of the zone under the pointer (K.ZONE_CONTROLS)
      local pending_single_select = nil
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
        K.toggle_note_selection(state.hovered_note)
      else
        -- Normal click
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
      end

      state.shift_mode = has_shift and (state.hovered_note ~= nil)

      -- What each dragged note starts from: the value its zone changes (K.ZONE_CONTROLS), else its pitch.
      -- raw_values keeps what the note itself stored (false = nothing: it inherited), for Esc.
      local zone_ctl = K.zone_control(state.hovered_zone, state.shift_mode)
      local orig_values, raw_values = {}, {}
      for idx in pairs(state.selected_notes) do
        local n = state.notes[idx]
        if n and n.controls then
          orig_values[idx] = zone_ctl and K.zone_value(zone_ctl, n) or n.controls.center_pitch
          local raw = n.controls[zone_ctl and zone_ctl.key or "center_pitch"]
          raw_values[idx] = (raw ~= nil) and raw or false
        end
      end

      state.drag = {
        note_idx = state.hovered_note,
        zone = state.hovered_zone,
        shift_mode = state.shift_mode,
        start_mouse_y = my,
        last_y = my,      -- previous frame's pointer Y (pitch drag accumulates its movement per frame)
        pitch_st = 0,     -- semitones moved so far by a pitch drag (fine adjust scales each frame's share)
        acc = 0,          -- value units moved so far by a zone drag (K.ZONE_CONTROLS), accumulated the same way
        orig_values = orig_values,
        raw_values = raw_values,
        pending_single_select = pending_single_select,
        dirty = false,
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
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
        init_sel = init_sel,
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    end
  end

  -- Right-click on note: open context menu
  if is_canvas_hovered and not off_notes and reaper.ImGui_IsMouseClicked(draw_ctx, 1) then
    local hp = state.hovered_point
    local hp_note = hp and state.notes[hp.note_idx]
    local hp_knot = hp_note and K.point_knot_at(hp_note, hp.frame)
    if hp_knot then
      -- A live point: its own menu, ahead of the note's
      if not state.selected_notes[hp.note_idx] then
        state.selected_note = hp.note_idx
        state.selected_notes = { [hp.note_idx] = true }
      end
      state.context_point = { note_idx = hp.note_idx, frame = hp.frame, start_st = hp_knot.st }
      reaper.ImGui_OpenPopup(draw_ctx, "##point_context_menu")
    elseif state.hovered_note and state.notes[state.hovered_note] then
      -- A right-click on a note that is already selected keeps the selection: Tighten and Tolerance in the menu
      -- write to every selected note
      if not state.selected_notes[state.hovered_note] then
        state.selected_note = state.hovered_note
        state.selected_notes = { [state.hovered_note] = true }
      end
      state.context_menu_note = state.hovered_note
      state.context_menu_time = x_to_t(mx)
      -- Whether the note's points can be added to at this zoom (the menu is drawn without the canvas mapping)
      state.context_menu_live = K.points_live_at(state.notes[state.hovered_note], t_to_x,
        function(p) return py + h - ((p - min_note) / note_range) * h end)
      reaper.ImGui_OpenPopup(draw_ctx, "##note_context_menu")
    end
  end

  -- HC5: Esc during a note drag puts every dragged note back to what it stored before and writes nothing
  if state.drag and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
    local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
    local key = zone_ctl and zone_ctl.key or "center_pitch"
    for idx, raw in pairs(state.drag.raw_values) do
      local n = state.notes[idx]
      if n and n.controls then
        if raw == false then n.controls[key] = nil else n.controls[key] = raw end
      end
    end
    state.drag = nil
    state.shift_mode = false
  end

  -- Process active drag (single-note or multi-note batch drag: pitch, or the zone's value)
  if state.drag then
    -- The cursor keeps the zone's meaning for the whole drag (pitch: vertical resize arrows, the others: a hand)
    reaper.ImGui_SetMouseCursor(draw_ctx, state.drag.zone == "pitch"
      and reaper.ImGui_MouseCursor_ResizeNS() or reaper.ImGui_MouseCursor_Hand())
    local delta_y = state.drag.start_mouse_y - my -- up = positive

    if math.abs(delta_y) > 2 then -- dead zone: click vs. drag
      state.drag.dirty = true
      state.drag.pending_single_select = nil -- drag occurred, cancel single-select collapse

      local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
      -- HC2: Cmd/Ctrl held (read every frame) = fine adjust. Each frame's pointer movement is scaled and
      -- accumulated, so pressing or releasing the modifier mid-drag never makes the value jump.
      local fine = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
      if zone_ctl then
        -- The canvas shades where the dragged value acts on the dragged notes
        if zone_ctl.hint then K.setting_hint(draw_ctx, zone_ctl.hint, true, state.drag.orig_values) end
        local per_px = zone_ctl.px or (zone_ctl.hi - zone_ctl.lo) / (px_per_st * zone_ctl.rows)
        state.drag.acc = state.drag.acc
          + (state.drag.last_y - my) * per_px * ((fine and zone_ctl.fine) and K.FINE_ADJUST_SCALE or 1)
        state.drag.last_y = my
        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            local v = math.max(zone_ctl.lo, math.min(zone_ctl.hi, orig_val + state.drag.acc))
            n.controls[zone_ctl.key] = not (zone_ctl.zero_nil and v <= 0) and v or nil
          end
        end
      else
        -- The pitch drag. Snapping to a semitone stays on the S key and on double-click.
        state.drag.pitch_st = state.drag.pitch_st
          + (state.drag.last_y - my) / px_per_st * (fine and K.FINE_ADJUST_SCALE or 1)
        state.drag.last_y = my
        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.center_pitch = math.max(0, math.min(127, orig_val + state.drag.pitch_st))   -- MIDI range
          end
        end
      end
    end

    -- End drag → commit envelope to take or resolve single click
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.drag.dirty then
        local count = 0
        for _ in pairs(state.drag.orig_values) do count = count + 1 end
        -- Label follows the modifier x zone (K.ZONE_CONTROLS); the plain centre zone is the pitch drag
        local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
        local action_name = zone_ctl and zone_ctl.undo or "Pitch Shift"
        local undo_title = count > 1 and string.format("%s (%d notes)", action_name, count) or action_name
        apply_envelope_to_take(undo_title)
      elseif state.drag.pending_single_select then
        -- Released without dragging: collapse multi-selection to clicked note
        state.selected_note = state.drag.pending_single_select
        state.selected_notes = { [state.drag.pending_single_select] = true }
      end
      state.drag = nil
      state.shift_mode = false
    end
  end

  -- Process an active pitch point drag: vertical only, 1:1 with the pitch scale (Ctrl/Cmd = fine), written on release
  if state.point_drag then
    local pd = state.point_drag
    local pd_note = state.notes and state.notes[pd.note_idx]
    reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    if not (pd_note and pd_note.frames and pd_note.frames[pd.frame]) then
      state.point_drag = nil   -- the model under it was replaced
    elseif reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      -- HC5: Esc during the drag puts the point back and writes nothing
      K.point_set(pd_note, K.point_knot_at(pd_note, pd.frame)
        or { frame = pd.frame, t = pd_note.frames[pd.frame].time, st = 0 }, pd.start_st)
      state.point_drag = nil
    else
      if not pd.dirty and math.abs(pd.last_y - my) > 2 then   -- dead zone: click vs. drag
        pd.dirty = true
        if pd.ctrl and not state.selected_notes[pd.note_idx] then   -- a Ctrl/Cmd drag adds the note to the selection
          state.selected_notes[pd.note_idx] = true
          state.selected_note = pd.note_idx
        end
      end
      if pd.dirty then
        local fine = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
        -- Accumulated unsnapped (held at the limit), so a slow fine drag is not snapped back to 0 frame by frame
        local st = math.max(-K.POINT_MAX_ST, math.min(K.POINT_MAX_ST,
          pd.st + (pd.last_y - my) / h * note_range * (fine and K.FINE_ADJUST_SCALE or 1)))
        pd.last_y = my
        if st ~= pd.st then
          pd.st = st
          -- A frame whose knot went away (a stored point moved back to 0) is set again from 0
          K.point_set(pd_note, K.point_knot_at(pd_note, pd.frame)
            or { frame = pd.frame, t = pd_note.frames[pd.frame].time, st = 0 }, st)
        end
      end
      if reaper.ImGui_IsMouseReleased(draw_ctx, 0) or not reaper.ImGui_IsMouseDown(draw_ctx, 0) then
        state.point_drag = nil
        if K.points_clamp(pd.st) ~= pd.start_st then apply_envelope_to_take("Move Pitch Point") end
        if pd.ctrl and not pd.dirty and pd.under and state.notes[pd.under] then K.toggle_note_selection(pd.under) end
      end
    end
  end

  -- Process active edge drag (trimming)
  if state.edge_drag then
    reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    local delta_x = mx - state.edge_drag.start_mouse_x
    if math.abs(delta_x) > 3 then -- horizontal dead zone
      state.edge_drag.dirty = true
      -- Convert the pixel delta to a time delta through the visible window
      local delta_time = x_to_t(mx) - x_to_t(state.edge_drag.start_mouse_x)
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
        local dropped = trim_note_edge(ed.note_idx, ed.edge, target_time)
        if dropped and dropped > 0 then
          set_status(string.format("Trimmed the note. %d pitch %s removed. %s+Z to undo",
            dropped, plural(dropped, "point outside it was", "points outside it were"), K.MOD_LABEL))
        end
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

  -- Process active marquee box select
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
            local sx = t_to_x(note.start_time)
            local ex = t_to_x(note.end_time)
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
        local item_time = x_to_t(math.max(px, math.min(px + w, state.marquee.start_x)))
        local _, item = K.frame_target()
        if item then
          local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          reaper.SetEditCurPos(item_pos + item_time, false, false)
        end
      end
      state.marquee = nil
    end
  end
end

--- The keyboard shortcuts of the canvas.
local function canvas_keys(cv)
  local draw_ctx, is_bypassed, gesture, item_t0 = cv.draw_ctx, cv.is_bypassed, cv.gesture, cv.item_t0
  local duration = cv.duration
  -- A change of the view goes through draw_graph, which owns it; the copies above follow it
  local function set_view(anchor_t, frac, span)
    cv.set_view(anchor_t, frac, span)
  end
  local function set_pitch_view(p0, p1)
    cv.set_pitch_view(p0, p1)
  end
  local function fit_pitch_view()
    cv.fit_pitch_view()
  end

  ---------------------------------------------------------------------------
  -- KEYBOARD CONTROLS (Scalpel Workflow)
  ---------------------------------------------------------------------------
  -- Guard: skip keyboard shortcuts if any widget (combo, input, slider)
  -- is active — prevents arrow keys from leaking into toolbar combos.
  local ok_aia, any_active = pcall(reaper.ImGui_IsAnyItemActive, draw_ctx)
  local widget_capturing = ok_aia and any_active

  -- Shortcuts do nothing while a modal / combo / context menu is open or the window is not focused (EP6).
  -- Every key goes through Shortcut(): exact modifiers, no repeat unless InputFlags_Repeat is passed, so
  -- Cmd/Ctrl+S never snaps and a held command key fires once.
  local shortcuts_live = not widget_capturing
    and not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
    and reaper.ImGui_IsWindowFocused(draw_ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())

  -- A bypassed take is not edited at all: neither by the mouse (gated above) nor by the keys
  if not state.drag and not state.edge_drag and not state.point_drag and shortcuts_live and not is_bypassed and state.notes and #state.notes > 0 then
    local shift_mod = reaper.ImGui_Mod_Shift()
    local repeat_flag = reaper.ImGui_InputFlags_Repeat()

    -- Cmd/Ctrl + A: Select All notes
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_A()) then
      state.selected_notes = {}
      for i = 1, #state.notes do
        state.selected_notes[i] = true
      end
      if not state.selected_note or not state.selected_notes[state.selected_note] then
        state.selected_note = 1
      end
    end

    -- Esc is routed once, innermost first, by the window-level handler in loop_body (HC5).

    -- Up / Down: Nudge pitch (±1 semitone, or ±10 cents with Shift)
    local has_selection = (state.selected_note and state.notes[state.selected_note])
      or (next(state.selected_notes) ~= nil)
    if has_selection then
      local sel = state.selected_note and state.notes[state.selected_note]

      -- Only the preview moves on each (repeating) press; the envelope write and the undo point
      -- are committed once per burst by service_nudge_burst() when the key is released.
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_UpArrow(), repeat_flag) then
        nudge_selected_notes(1.0, "up")
      elseif reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_UpArrow(), repeat_flag) then
        nudge_selected_notes(0.10, "up")
      end

      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_DownArrow(), repeat_flag) then
        nudge_selected_notes(-1.0, "down")
      elseif reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_DownArrow(), repeat_flag) then
        nudge_selected_notes(-0.10, "down")
      end

      -- S: Snap to nearest semitone (the status line reports it, as for the top bar's Snap button)
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_S()) then
        K.note_action("snap")
      end

      -- Q: Quantize selected note(s) to active scale
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Q()) then
        K.note_action("quantize")
      end

      -- R / Backspace / Delete: Reset to [Untouched]
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_R())
        or reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Backspace())
        or reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Delete()) then
        reset_selected_note()
      end

      -- X: Split note at edit cursor position (outside the note it says so)
      if sel and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_X()) then
        K.note_action("split", state.selected_note)
      end
    end

    -- M: Merge selected notes (requires 2+ contiguous selected; with fewer it says so)
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_M()) then
      K.note_action("merge")
    end

    -- Left / Right: Jump or range-extend (Shift) selection to previous / next note
    local left_plain = reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_LeftArrow(), repeat_flag)
    local left_extend = reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_LeftArrow(), repeat_flag)
    if left_plain or left_extend then
      if left_extend and state.selected_note and state.selected_note > 1 then
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

    local right_plain = reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_RightArrow(), repeat_flag)
    local right_extend = reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_RightArrow(), repeat_flag)
    if right_plain or right_extend then
      if right_extend and state.selected_note and state.selected_note < #state.notes then
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

    -- F: the whole item again, with the pitch range fitted to the notes. Z: both axes zoom to the selected notes.
    -- Not during a marquee: the mapping must not change under a gesture. Both need exact modifiers, so
    -- Cmd/Ctrl+Z is left for forward_undo_to_reaper() in loop_body.
    if not gesture then
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_F()) then
        set_view(item_t0, 0, duration)
        fit_pitch_view()
      elseif reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Z()) then
        local t_lo, t_hi, p_lo, p_hi = math.huge, -math.huge, math.huge, -math.huge
        local function include(idx)
          local n = state.notes[idx]
          if n and n.controls then
            t_lo, t_hi = math.min(t_lo, n.start_time), math.max(t_hi, n.end_time)
            p_lo, p_hi = math.min(p_lo, n.controls.center_pitch), math.max(p_hi, n.controls.center_pitch)
          end
        end
        for idx in pairs(state.selected_notes) do include(idx) end
        if state.selected_note then include(state.selected_note) end
        if t_hi > t_lo then
          local pad = math.max((t_hi - t_lo) * K.ZOOM_SEL_PAD, K.MIN_VIEW_SPAN_S * 0.5)
          set_view(t_lo - pad, 0, (t_hi - t_lo) + pad * 2)
          set_pitch_view(p_lo - K.ZOOM_SEL_PAD_ST, p_hi + K.ZOOM_SEL_PAD_ST)
        else
          set_status("Select a note to zoom to it")
        end
      end
    end

    -- Space is forwarded to the user's own REAPER binding by forward_space_to_reaper() in loop_body (HC6).
  end
end

--- Double-click on a note, a pitch point or the empty canvas.
local function canvas_double_click(cv)
  local is_canvas_hovered, draw_ctx, py, h = cv.is_canvas_hovered, cv.draw_ctx, cv.py, cv.h
  local target_item, x_to_t, mx, t_to_x, my, vt0 = cv.target_item, cv.x_to_t, cv.mx, cv.t_to_x, cv.my, cv.vt0
  local vt1, min_note, note_range = cv.vt1, cv.min_note, cv.note_range

  -- Double-click: a pitch point back to 0, a point added on the add-square, else on the pitch zone: Snap to nearest
  -- semitone (single or batch). With Shift held the points are left alone, as for a press.
  if is_canvas_hovered and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
    local dc_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
    local hp = not dc_shift and state.hovered_point
    local hp_note = hp and state.notes and state.notes[hp.note_idx]
    local hp_knot = hp_note and K.point_knot_at(hp_note, hp.frame)
    local pg = not dc_shift and state.point_ghost
    local pg_note = pg and state.notes and state.notes[pg.note_idx]
    local pg_fr = pg_note and pg_note.frames and pg_note.frames[pg.frame]
    -- On a shown, live note: a double-click on the pitch line too close to a point does nothing (on the line the
    -- double-click belongs to the points), and one on a stretch without a pitch, off the pitch zone, says why
    -- nothing is added
    local no_pitch, line_busy = false, false
    if not dc_shift and not hp_knot and not pg_fr and state.notes and state.show_smart_spots then
      local p_to_y = function(p) return py + h - ((p - min_note) / note_range) * h end
      local pt_build = K.frame_view(draw_ctx, state.notes, target_item)
      local pt_t = x_to_t(mx)
      for n_idx, note in ipairs(state.notes) do
        if note.frames and #note.frames > 0 and pt_t >= note.start_time and pt_t <= note.end_time
            and not (note.controls and note.controls.bypassed) and K.points_shown(n_idx, state.hovered_note)
            and K.points_live_at(note, t_to_x, p_to_y) then
          local _, reason = K.point_can_add(note, pt_t)
          if reason == "too_close" then
            local aim = K.point_aim(note, K.points_frame_at(note.frames, pt_t), pt_build)
            local y = aim and p_to_y(aim)
            line_busy = y ~= nil and math.abs(y - my) <= K.point_reach_y(note, y, p_to_y)
          elseif reason == "no_pitch" then
            no_pitch = not (state.hovered_note == n_idx and state.hovered_zone == "pitch")
              and K.points_box_has(note, mx, my, vt0, vt1, t_to_x, p_to_y, pt_build)
          end
          break
        end
      end
    end
    if hp_knot then
      state.point_drag = nil   -- the press of this double-click grabbed the point: it is reset instead
      local was = hp_knot.st
      K.point_set(hp_note, hp_knot, 0)
      if was ~= 0 then apply_envelope_to_take("Reset Pitch Point") end
    elseif pg_fr then
      local knot, reason = K.point_add(pg_note, pg_fr.time)
      if knot then
        apply_envelope_to_take("Add Pitch Point")
      elseif reason == "no_pitch" then
        set_status("No pitch detected here: a point needs a pitch to sit on.")
      end
      state.point_ghost = nil
    elseif no_pitch then
      set_status("No pitch detected here: a point needs a pitch to sit on.")
    elseif not line_busy and state.hovered_note and state.hovered_zone == "pitch" then
      -- (line_busy: on the line too close to a point for another one, so nothing happens; the line is not the
      -- note's snap target)
      if not state.selected_notes[state.hovered_note] then
        state.selected_note = state.hovered_note
        state.selected_notes = { [state.hovered_note] = true }
      end
      K.note_action("snap")
    end
  end
end

-- What the files loaded after this one use
App.canvas_navigate = canvas_navigate
App.canvas_pointer = canvas_pointer
App.canvas_keys = canvas_keys
App.canvas_double_click = canvas_double_click
