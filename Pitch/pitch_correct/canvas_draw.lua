-- @noindex
-- Fancy Pitch Correct: the pitch canvas, drawing: rows, note blocks, curves, overlays.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme, fonts = App.K, App.state, App.Theme, App.fonts
local is_note_modified = App.is_note_modified
local is_pitch_in_scale = App.is_pitch_in_scale
local midi_to_name = App.midi_to_name
local SCALE_DEFINITIONS = App.SCALE_DEFINITIONS
local set_status = App.set_status
local toggle_take_pitch_bypass = App.toggle_take_pitch_bypass

-- Each function here is one step of draw_graph (canvas.lua) and takes its frame table `cv`: the geometry, the
-- colours, the pointer and the helpers draw_graph worked out for this frame. The view (vt0, vt1, min_note,
-- max_note, note_range, px_per_st) belongs to draw_graph: a step reads it from cv and changes it only through
-- cv.set_view, cv.set_pitch_view and cv.fit_pitch_view.

--- The pitch rows behind everything. Returns the root pitch class and whether the scale is chromatic.
local function canvas_draw_rows(cv)
  local draw_list, px, py, w, h, C = cv.draw_list, cv.px, cv.py, cv.w, cv.h, cv.C
  local min_note, max_note, note_range = cv.min_note, cv.max_note, cv.note_range

  ---------------------------------------------------------------------------
  -- DRAW ROWS (one quiet surface: in-scale rows a tint, out-of-scale rows a step darker, the root row marked)
  ---------------------------------------------------------------------------
  -- Everything from here to the playhead is clipped to the note area: the note-name column and the two strips
  -- are drawn after it, and a block that runs past the window's edge must not reach them.
  local root_pc = (state.key_idx - 1) % 12
  local is_chromatic = (SCALE_DEFINITIONS[state.scale_idx].name == "Chromatic")
  reaper.ImGui_DrawList_PushClipRect(draw_list, px, py, px + w, py + h, true)

  for n = math.floor(min_note), math.ceil(max_note) do
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local is_black_key = (n % 12 == 1 or n % 12 == 3 or n % 12 == 6
                          or n % 12 == 8 or n % 12 == 10)
    local pc = (n % 12 + 12) % 12
    local in_scale = is_pitch_in_scale(pc)
    local is_root = (pc == root_pc)

    local row_bg
    local row_tint = nil
    local grid_color

    if is_chromatic then
      row_bg = is_black_key and C.row_plain_black or C.row_plain
      grid_color = is_black_key and C.grid_plain_black or C.grid_plain
    elseif in_scale then
      if is_root then
        -- Tonic/Root note row: subtle theme accent tint
        row_bg = C.row_tonic
        row_tint = C.row_tonic_tint
        grid_color = C.grid_tonic
      else
        -- In-scale note row: subtle theme tinting
        row_bg = is_black_key and C.row_black or C.row
        row_tint = C.row_tint
        grid_color = C.grid
      end
    else
      -- Out-of-scale note row: dimmed
      row_bg = is_black_key and C.row_dim_black or C.row_dim
      grid_color = C.grid_dim
    end

    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_bg)
    if row_tint then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_tint)
    end
    -- A hairline along the row's lower edge (the rows differ little in colour: the line tells them apart)
    reaper.ImGui_DrawList_AddLine(draw_list, px, key_bot, px + w, key_bot, grid_color)
  end

  return root_pc, is_chromatic
end

--- The note blocks. Returns the labels collected for canvas_draw_curves, which draws them over the curves.
local function canvas_draw_notes(cv)
  local target_take, target_item, t_to_x, py, h, C = cv.target_take, cv.target_item, cv.t_to_x, cv.py, cv.h, cv.C
  local draw_ctx, draw_list, pill_fits, pill_text, L = cv.draw_ctx, cv.draw_list, cv.pill_fits, cv.pill_text, cv.L
  local px, w, x_to_t, visible_range, vt0, vt1 = cv.px, cv.w, cv.x_to_t, cv.visible_range, cv.vt0, cv.vt1
  local min_note, note_range = cv.min_note, cv.note_range

  ---------------------------------------------------------------------------
  -- DRAW NOTE BLOCKS (interactive, positioned by center_pitch)
  ---------------------------------------------------------------------------
  -- Labels are collected here and drawn after the curves (see NOTE LABELS): { x, top, bot, text }
  local labels = {}
  if state.show_note_blocks and state.notes then
    -- Inside the blocks: the item's real waveform (its peaks from REAPER), or, while those are not available, the
    -- loudness envelope of the analysis, scaled by its loudest frame
    local wave = K.take_wave(target_take, target_item)
    local peak_rms = (not wave) and K.results_peak(state.results) or 0
    local selected_n = 0
    for _ in pairs(state.selected_notes) do selected_n = selected_n + 1 end
    local label_all_selected = selected_n <= K.LABEL_MAX_SELECTED
    for n_idx, note in ipairs(state.notes) do
      -- Only blocks that reach the visible window are drawn
      if note.controls and note.end_time >= vt0 and note.start_time <= vt1 then
        local cp = note.controls.center_pitch
        local sx = t_to_x(note.start_time)
        local ex = t_to_x(note.end_time)
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h
        local block_w = ex - sx
        local zone_w = math.max(12, block_w * 0.25)

        local is_selected = state.selected_notes[n_idx] or false
        local is_hov = (state.hovered_note == n_idx)
        local is_mod = is_note_modified(note)

        local is_bypassed_note = note.controls.bypassed or false
        local fill
        local border
        if is_bypassed_note then
          fill = C.note_bypassed
          border = C.note_bypassed_border
        elseif is_selected then
          fill = is_mod and C.note_selected_edited or C.note_selected
          border = C.note_selected_border
        elseif is_mod then
          fill = C.note_edited   -- Green for edited notes (and the corner square below)
          border = C.note_edited_border
        else
          fill = C.note_fill     -- Muted blue for untouched notes, its border >= 3:1 on every row
          border = C.note_border
        end

        -- Zone-colored hover highlights
        if is_hov and not state.drag and not state.point_drag and not state.hovered_point then
          local has_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0

          if state.hovered_zone == "tighten" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, sx + zone_w, bot_y, has_shift and C.zone_shift or C.zone_drift)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx + zone_w, top_y, ex, bot_y, fill)
          elseif state.hovered_zone == "tolerance" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex - zone_w, bot_y, fill)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              ex - zone_w, top_y, ex, bot_y, C.zone_shift)
          else -- pitch zone
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex, bot_y, fill)
            if has_shift then
              reaper.ImGui_DrawList_AddRectFilled(draw_list,
                sx + zone_w, top_y, ex - zone_w, bot_y, C.zone_shift)
            end
          end

          if has_shift and block_w > 40 then
            -- The zone names sit on a pill: the text over the amber zone highlight alone is not enough. All three are
            -- drawn when each fits its zone (the pills never overlap); on a narrower block only the name of the zone
            -- under the pointer is (the hover hint names it at any width)
            local text_y = top_y + (bot_y - top_y) * 0.5 - 6
            if pill_fits("Onset Ramp", zone_w) and pill_fits("Transition", block_w - zone_w * 2)
                and pill_fits("Scoop", zone_w) then
              pill_text(sx + 2, text_y, "Onset Ramp", C.pill_text)
              pill_text(sx + zone_w + 2, text_y, "Transition", C.pill_text)
              pill_text(ex - zone_w + 2, text_y, "Scoop", C.pill_text)
            elseif state.hovered_zone == "tighten" then
              pill_text(sx + 2, text_y, "Onset Ramp", C.pill_text)
            elseif state.hovered_zone == "tolerance" then
              pill_text(ex - zone_w + 2, text_y, "Scoop", C.pill_text)
            else
              pill_text(sx + zone_w + 2, text_y, "Transition", C.pill_text)
            end
          end
        else
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx, top_y, ex, bot_y, fill, L.xs)
        end

        -- The waveform inside the block (C.note_wave), around the block's centre line: the item's own audio between
        -- the note's start and end, scaled so the loudest sample of the item just fills a block. It is linear: a
        -- quiet note looks quiet.
        local wave_half = (bot_y - top_y) * 0.5 - L.xs
        local mid_y = (top_y + bot_y) * 0.5
        if wave and wave_half >= 1 and not is_bypassed_note then
          local wave_x0, wave_x1 = math.max(sx, px), math.min(ex, px + w)
          if wave_x1 > wave_x0 then
            local cols = K.note_wave(note, wave, wave_x0, wave_x1, x_to_t)   -- cached, see K.note_wave
            local col_w = K.WAVE_COL_PX
            local c = cols.w_cols
            for k = 0, cols.w_n - 1 do
              local col_x = c[k * 3 + 1]
              local y0 = mid_y - c[k * 3 + 2] * wave_half
              local y1 = mid_y - c[k * 3 + 3] * wave_half
              if y1 - y0 < 1 then   -- silence is a hairline, not a gap
                local centre = (y0 + y1) * 0.5
                y0, y1 = centre - 0.5, centre + 0.5
              end
              reaper.ImGui_DrawList_AddRectFilled(draw_list, col_x, y0, col_x + col_w, y1, C.note_wave)
            end
          end
        -- Fallback while REAPER has no peaks for the item: the loudness (RMS) of the analysis frames, as mirrored bars.
        -- One bar per frame, or per few frames when they are closer than WAVE_STEP_PX; an analysis saved without the
        -- RMS draws none. It shows where the note is loud, not the audio itself.
        elseif peak_rms > 0 and wave_half >= 1 and note.frames and not is_bypassed_note then
          local wf0, wf1 = visible_range(note.frames)
          if wf1 > wf0 then
            local wave_w = t_to_x(note.frames[wf1].time) - t_to_x(note.frames[wf0].time)
            local stride = math.max(1, math.ceil(K.WAVE_STEP_PX * (wf1 - wf0) / math.max(wave_w, 1)))
            local i = wf0
            while i < wf1 do
              local j = math.min(wf1, i + stride)
              local rms = 0
              for k = i, j - 1 do
                local frame_rms = note.frames[k].rms
                if frame_rms and frame_rms > rms then rms = frame_rms end
              end
              local amp = wave_half * math.sqrt(math.min(1, rms / peak_rms))
              local bar_x0 = math.max(sx, t_to_x(note.frames[i].time))
              local bar_x1 = math.min(ex, t_to_x(note.frames[j].time))
              if amp >= 0.5 and bar_x1 > bar_x0 then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, bar_x0, mid_y - amp, bar_x1, mid_y + amp, C.note_wave)
              end
              i = j
            end
          end
        end

        -- Border (thicker for selected notes)
        reaper.ImGui_DrawList_AddRect(draw_list,
          sx, top_y, ex, bot_y, border, L.xs, 0, is_selected and 2.0 or 1.0)

        if is_bypassed_note then
          reaper.ImGui_DrawList_AddLine(draw_list, sx, mid_y, ex, mid_y, border, 1.5)
        end

        -- Zone divider lines on hover/select
        if is_hov or is_selected then
          reaper.ImGui_DrawList_AddLine(draw_list,
            sx + zone_w, top_y, sx + zone_w, bot_y, C.zone_divider)
          reaper.ImGui_DrawList_AddLine(draw_list,
            ex - zone_w, top_y, ex - zone_w, bot_y, C.zone_divider)

          -- Edge trim handles (visible grab zones). C.handle is >= 3:1 against every note fill, row and zone highlight at
          -- rest; the hovered edge goes opaque (C.handle_hover)
          local handle_w = 3
          local left_handle_col = C.handle
          local right_handle_col = C.handle

          -- Brighten the hovered edge
          if state.hovered_edge and state.hovered_edge.note_idx == n_idx and not state.hovered_point then
            if state.hovered_edge.edge == "left" then
              left_handle_col = C.handle_hover
            else
              right_handle_col = C.handle_hover
            end
          end

          -- During edge drag, brighten the active edge
          if state.edge_drag and state.edge_drag.note_idx == n_idx then
            if state.edge_drag.edge == "left" then
              left_handle_col = C.handle_drag
            else
              right_handle_col = C.handle_drag
            end
          end

          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx - 1, top_y, sx + handle_w, bot_y, left_handle_col)
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            ex - handle_w, top_y, ex + 1, bot_y, right_handle_col)
        end

        -- An edited note also carries a small square (C.note_edit_mark) in its top-left corner (not green alone)
        if is_mod then
          local mark_x = math.max(sx, px) + L.sm   -- stays visible while the block runs past the left edge
          local mark = math.min(K.EDIT_MARK, bot_y - top_y - L.xs * 2, block_w - L.sm * 2)
          if mark >= L.xs then
            reaper.ImGui_DrawList_AddRectFilled(draw_list, mark_x, top_y + L.xs, mark_x + mark, top_y + L.xs + mark, C.note_edit_mark)
          end
        end

        -- Note label (name + cents deviation): only for the hovered note and the selected ones, on a pill beside the
        -- block (drawn after the curves). The row already names the pitch of every other note. A selection larger than
        -- LABEL_MAX_SELECTED labels its primary note alone; the note a pitch drag holds reads the same in the drag readout.
        local held = state.drag and state.drag.dirty and state.drag.zone == "pitch"
          and state.drag.note_idx == n_idx
        if not held and (is_hov or n_idx == state.selected_note or (is_selected and label_all_selected)) then
          local nearest = math.floor(cp + 0.5)
          local cents = math.floor((cp - nearest) * 100 + 0.5)
          local sign = cents >= 0 and "+" or ""
          labels[#labels + 1] = {
            x = math.max(sx, px), top = top_y, bot = bot_y,
            text = string.format("%s %s%d\xC2\xA2", midi_to_name(nearest), sign, cents),
          }
        end
      end
    end
  end

  return labels
end

--- Split points, the pitch trace, the corrected preview, the pitch points and the note labels.
local function canvas_draw_curves(cv)
  local t_to_x, draw_list, py, h, C, ruler_h = cv.t_to_x, cv.draw_list, cv.py, cv.h, cv.C, cv.ruler_h
  local L, draw_ctx, is_bypassed, target_item = cv.L, cv.draw_ctx, cv.is_bypassed, cv.target_item
  local visible_range, line_h, pill_text, labels, vt0 = cv.visible_range, cv.line_h, cv.pill_text, cv.labels, cv.vt0
  local vt1, min_note, note_range = cv.vt1, cv.min_note, cv.note_range

  ---------------------------------------------------------------------------
  -- DRAW SPLIT POINTS
  ---------------------------------------------------------------------------
  if state.show_split_points and state.split_points then
    for _, sp in ipairs(state.split_points) do
      if sp.time >= vt0 and sp.time <= vt1 then
        local x = t_to_x(sp.time)
        reaper.ImGui_DrawList_AddLine(draw_list, x, py, x, py + h, C.marker_split, 1.0)   -- blue: red is for clip / destructive only
        -- The label sits below the time ruler, which covers the top of the note area
        reaper.ImGui_DrawList_AddText(draw_list, x + 2, py + ruler_h + L.xs, C.marker_split_text, sp.reason)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- SETTING HIGHLIGHTS: where the hovered / dragged setting acts (over the blocks, under the curves). They
  -- belong to the Preview Curve layer and show from the frame the setting reports itself to the next one.
  ---------------------------------------------------------------------------
  do
    local hint = state.setting_hint
    local live = hint.key ~= nil and hint.frame >= (reaper.ImGui_GetFrameCount(draw_ctx) or 0) - 1
    if live and state.show_preview and not is_bypassed and state.notes and #state.notes > 0 then
      local marks = K.draw_setting_hint(draw_list, hint, K.frame_view(draw_ctx, state.notes, target_item), C)
      if hint.dragging and marks == 0 and not hint.said then
        hint.said = true
        set_status(hint.key == "tolerance" and "No note uses Tolerance yet: raise Tighten on a note first"
          or "No edited note in view uses this value")
      end
    end
    if not (live and hint.dragging) then hint.said = false end
  end

  ---------------------------------------------------------------------------
  -- DRAW RAW PITCH CURVE (the text colour: the blocks own the accent)
  ---------------------------------------------------------------------------
  if state.show_raw_pitch then
    -- Only the part of the curve that reaches the visible window; unvoiced gaps at either end are skipped so
    -- the line still runs to the canvas edge
    local r0, r1 = visible_range(state.results)
    while r0 > 1 and not state.results[r0].note do r0 = r0 - 1 end
    while r1 < #state.results and not state.results[r1].note do r1 = r1 + 1 end
    local polyline = K.raw_trace(state.results, r0, r1, t_to_x)   -- cached, see K.raw_trace
    local has_notes = state.notes and #state.notes > 0
    if polyline then
      -- With notes the trace is a reference layer: barely visible everywhere, and dimmed only over a note's block
      reaper.ImGui_DrawList_AddPolyline(draw_list, polyline, has_notes and C.trace_far or C.trace, 0, 1.5)
    end
    if polyline and has_notes then
      local view = K.frame_view(draw_ctx, state.notes, target_item)
      local runs, owner, run_n = K.raw_trace_runs(state.results, r0, r1, t_to_x, state.notes, view.gen)   -- cached
      for i = 1, run_n do
        local note = owner[i]
        local cp = note.controls and note.controls.center_pitch
        if cp then
          reaper.ImGui_DrawList_PushClipRect(draw_list,
            t_to_x(note.start_time), py + h - ((cp + 0.5 - min_note) / note_range) * h,
            t_to_x(note.end_time), py + h - ((cp - 0.5 - min_note) / note_range) * h, true)
          reaper.ImGui_DrawList_AddPolyline(draw_list, runs[i], C.trace_note, 0, 1.5)
          reaper.ImGui_DrawList_PopClipRect(draw_list)
        end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW CORRECTED PITCH PREVIEW & PITCH POINTS
  ---------------------------------------------------------------------------

  -- Corrected pitch preview (green): the pitch trace plus the correction that is written to the item, over
  -- every edited note with its ramps and glides. It is the trajectory of the envelope itself
  -- (K.correction_build), so a scoop, a fade or a glide shows exactly as it will sound.
  if state.show_preview and state.notes and #state.notes > 0 and state.results and #state.results > 1 then
    local build = K.frame_view(draw_ctx, state.notes, target_item)
    -- An outdated item holds another envelope than today's settings would write: the curve shows what it really
    -- holds, except while a value or a note is being changed (then it previews what the release will write).
    local held = state.target_take_guid and state.stale_takes[state.target_take_guid]
      and state.stale_env[state.target_take_guid] or nil
    local hint = state.setting_hint
    local cpt = state.context_point   -- the point menu's Offset being dragged or typed
    local changing = state.drag or state.edge_drag or state.point_drag or state.nudge_burst
      or (cpt and (cpt.active or cpt.live))
      or (hint.dragging and hint.frame >= (reaper.ImGui_GetFrameCount(draw_ctx) or 0) - 1)
    if held and not changing then
      if held.base ~= build then
        K.held_gen = (K.held_gen or 0) - 1
        held.base, held.ranges, held.gen = build, build.ranges, K.held_gen
      end
      build = held
    end
    if #build.ranges > 0 then
      local r0, r1 = visible_range(state.results)
      local lines, line_n = K.preview_lines(state.results, r0, r1, t_to_x, build)
      for i = 1, line_n do
        reaper.ImGui_DrawList_AddPolyline(draw_list, lines[i], C.preview, 0, 2.0)
      end
    end
  end

  -- Pitch points over the Preview Curve, under the pills (same rule as the hit-test: K.points_shown)
  if state.notes and state.show_smart_spots then
    K.draw_points(draw_list, C, state.notes, vt0, vt1, t_to_x,
      function(p) return py + h - ((p - min_note) / note_range) * h end, K.frame_view(draw_ctx, state.notes, target_item))
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE LABELS (collected with the blocks): a pill above each block, or below it when the ruler is in the way
  ---------------------------------------------------------------------------
  do
    local pill_h = line_h + L.xs * 2
    for _, lb in ipairs(labels) do
      local y = lb.top - pill_h - L.xs
      if y < py + ruler_h then y = lb.bot + L.xs end
      pill_text(lb.x, y, lb.text, C.pill_text)
    end
  end
end

--- What lies over the notes and around them: the marquee, readouts, the playhead, the note names, the ruler and the two strips.
local function canvas_draw_overlays(cv)
  local px, py, w, h, draw_list, C = cv.px, cv.py, cv.w, cv.h, cv.draw_list, cv.C
  local pill_text, L, line_h, ruler_h, P, item_t0 = cv.pill_text, cv.L, cv.line_h, cv.ruler_h, cv.P, cv.item_t0
  local draw_ctx, t_to_x, on_ruler, gesture = cv.draw_ctx, cv.t_to_x, cv.on_ruler, cv.gesture
  local target_item, mx, my, canvas_tip_ready, full_px = cv.target_item, cv.mx, cv.my, cv.canvas_tip_ready, cv.full_px
  local full_h, pv_w, pitch_thumb, full_w, fit_max = cv.full_h, cv.pv_w, cv.pitch_thumb, cv.full_w, cv.fit_max
  local fit_min, duration, overview_thumb, is_chromatic = cv.fit_min, cv.duration, cv.overview_thumb, cv.is_chromatic
  local root_pc, vt0, vt1, min_note, max_note = cv.root_pc, cv.vt0, cv.vt1, cv.min_note, cv.max_note
  local note_range, px_per_st = cv.note_range, cv.px_per_st

  ---------------------------------------------------------------------------
  -- DRAW MARQUEE SELECTION BOX
  ---------------------------------------------------------------------------
  if state.marquee and state.marquee.active then
    local bx1 = math.max(px, math.min(state.marquee.start_x, state.marquee.cur_x))
    local by1 = math.max(py, math.min(state.marquee.start_y, state.marquee.cur_y))
    local bx2 = math.min(px + w, math.max(state.marquee.start_x, state.marquee.cur_x))
    local by2 = math.min(py + h, math.max(state.marquee.start_y, state.marquee.cur_y))

    if bx2 > bx1 and by2 > by1 then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, bx1, by1, bx2, by2, C.marquee_fill)
      reaper.ImGui_DrawList_AddRect(draw_list, bx1, by1, bx2, by2, C.marquee_border, 0, 0, 1.5)

      local m_count = 0
      for _ in pairs(state.selected_notes) do m_count = m_count + 1 end
      if m_count > 0 then
        -- On a pill (kept inside the note area, below the time ruler): C.marquee_text is fitted to >= 4.5:1 there
        pill_text(bx2 + L.sm, by2 - line_h - L.xs * 2, string.format("%d selected", m_count), C.marquee_text)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW TIME RULER (overlay along the top of the note area, not the note-name column)
  ---------------------------------------------------------------------------
  do
    local span = vt1 - vt0
    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + ruler_h, C.ruler_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, px, py + ruler_h, px + w, py + ruler_h, P.border)

    -- Smallest 1-2-5 x 10^n number of seconds that is at least t_min
    local function nice_step(t_min)
      local base = 10 ^ math.floor(math.log(t_min, 10))
      local ratio = t_min / base
      return base * (ratio <= 1 and 1 or (ratio <= 2 and 2 or (ratio <= 5 and 5 or 10)))
    end
    -- "12.5s" while the window ends before a minute, "1:05.5" from then on
    local show_minutes = (vt1 - item_t0) >= 60
    local function time_label(t, decimals)
      local scale = math.floor(10 ^ decimals + 0.5)
      local ticks = math.floor(math.max(t, 0) * scale + 0.5)
      local whole = ticks // scale
      local fraction = decimals > 0 and string.format(".%0" .. decimals .. "d", ticks % scale) or ""
      if show_minutes then
        return string.format("%d:%02d", whole // 60, whole % 60) .. fraction
      end
      return string.format("%d", whole) .. fraction .. "s"
    end

    -- The major step: the smallest one whose labels fit with room between them (starting from one digit per step)
    local digit_w = reaper.ImGui_CalcTextSize(draw_ctx, "0") or 0
    local interval = nice_step(span * math.max(digit_w, 1) / math.max(w, 1))
    local decimals = 0
    for attempt = 1, K.RULER_MAX_TRIES do
      decimals = interval >= 1 and 0 or math.ceil(-math.log(interval, 10) - K.VIEW_EPS_S)
      local widest = reaper.ImGui_CalcTextSize(draw_ctx, time_label(vt1 - item_t0, decimals)) or 0
      if interval / span * w >= widest * K.RULER_LABEL_ROOM or attempt == K.RULER_MAX_TRIES then break end
      interval = nice_step(interval * K.RULER_WIDEN)
    end

    -- Ticks: a label and a full-height tick at every major step, a short tick at every minor one. A label
    -- that would touch the previous one (or leave the note area) is dropped, so labels never overlap.
    local minor = interval / K.RULER_MINOR_DIV
    local label_y = py + L.xs
    local next_free_x = px
    for m = math.ceil((vt0 - item_t0) / minor - K.VIEW_EPS_S), math.floor((vt1 - item_t0) / minor + K.VIEW_EPS_S) do
      local t = item_t0 + m * minor
      local x = t_to_x(t)
      if m % K.RULER_MINOR_DIV == 0 then
        reaper.ImGui_DrawList_AddLine(draw_list, x, py, x, py + ruler_h, P.text_dim)
        local label = time_label(t - item_t0, decimals)
        local label_w = reaper.ImGui_CalcTextSize(draw_ctx, label) or 0
        local label_x = x + L.sm
        if label_x >= next_free_x and label_x + label_w <= px + w then
          reaper.ImGui_DrawList_AddText(draw_list, label_x, label_y, P.text_dim, label)
          next_free_x = label_x + label_w + L.md
        end
      else
        reaper.ImGui_DrawList_AddLine(draw_list, x, py + ruler_h - L.sm, x, py + ruler_h, P.border)
      end
    end

    if on_ruler and state.view_t0 and not gesture then
      Theme.tooltip(draw_ctx, "Click to move the edit cursor. Double-click: whole item")
    end
  end

  ---------------------------------------------------------------------------
  -- DRAG READOUT (a pill on the canvas) and HOVER HINT (a tooltip)
  ---------------------------------------------------------------------------
  if state.point_drag and state.point_drag.dirty then
    -- The point's own offset in whole cents, then the pitch the note aims for there (the note readout's format)
    local pd = state.point_drag
    local pd_note = state.notes[pd.note_idx]
    local knot = pd_note and K.point_knot_at(pd_note, pd.frame)
    local aim = pd_note and K.point_aim(pd_note, pd.frame, K.frame_view(draw_ctx, state.notes, target_item))
    if aim then
      local nearest = math.floor(aim + 0.5)
      local cents = math.floor((aim - nearest) * 100 + 0.5)
      local tip = string.format("%+d\xC2\xA2 \xC2\xB7 %s %s%d\xC2\xA2", math.floor((knot and knot.st or 0) * 100 + 0.5),
        midi_to_name(nearest), cents >= 0 and "+" or "", cents)
      pill_text(mx + L.xl, my - line_h * 0.5, tip, C.pill_text, L.xl * 2)
    end
  elseif state.drag and state.drag.dirty then
    local d_note = state.notes[state.drag.note_idx]
    if d_note and d_note.controls then
      local count = 0
      for _ in pairs(state.drag.orig_values or {}) do count = count + 1 end
      local count_suffix = count > 1 and string.format("  (%d notes)", count) or ""
      -- The readout names the value that is changing (K.ZONE_CONTROLS), as the hover hint does
      local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
      local tip
      if zone_ctl then
        tip = K.zone_text(zone_ctl, d_note, false) .. count_suffix
      else
        local cp = d_note.controls.center_pitch
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        tip = string.format("%s %s%d\xC2\xA2%s",
          midi_to_name(nearest), sign, cents, count_suffix)
      end
      -- Beside the pointer, never outside the note area (nor over the note-name column or the ruler)
      pill_text(mx + L.xl, my - line_h * 0.5, tip, C.pill_text, L.xl * 2)
    end
  elseif canvas_tip_ready and state.hovered_point and not state.drag and not state.marquee and not state.point_drag then
    Theme.tooltip(draw_ctx, string.format(
      "Drag to bend the pitch here (%s = fine). Double-click: reset. Right-click: menu", K.MOD_LABEL))
  elseif canvas_tip_ready and state.point_ghost and not state.drag and not state.marquee and not state.point_drag
      and not state.edge_drag and not state.view_drag then
    Theme.tooltip(draw_ctx, "Double-click to add a pitch point")
  elseif canvas_tip_ready and state.hovered_note and not state.drag and not state.marquee
      and not state.point_drag and not state.hovered_point then
    local h_note = state.notes[state.hovered_note]
    if h_note and h_note.controls then
      local has_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
      local zone_ctl = K.zone_control(state.hovered_zone, has_shift)
      local tip = zone_ctl and K.zone_text(zone_ctl, h_note, true)
        or string.format("Drag to change pitch (%s = fine)", K.MOD_LABEL)
      Theme.tooltip(draw_ctx, tip)   -- the Show Tooltips preference applies
    end
  end
  ---------------------------------------------------------------------------
  -- PLAYHEAD CURSOR LINE
  ---------------------------------------------------------------------------
  local playhead_t = nil   -- the cursor's time while it is inside the item (the overview strip marks it too)
  local _, item_for_cursor = K.frame_target()
  if item_for_cursor then
    local item_pos = reaper.GetMediaItemInfo_Value(item_for_cursor, "D_POSITION")
    -- Use play position when playing, edit cursor when stopped
    local play_state = reaper.GetPlayState()
    local project_pos = (play_state & 1) ~= 0
      and reaper.GetPlayPosition()
      or  reaper.GetCursorPosition()
    local item_rel = project_pos - item_pos
    if item_rel >= state.start_time and item_rel <= state.end_time then
      playhead_t = item_rel
      -- The line is drawn only inside the visible window. Its head sits in the ruler: the line is the same colour as
      -- the pitch trace, and the head is what tells it from a spike of the trace
      if item_rel >= vt0 and item_rel <= vt1 then
        local cursor_x = t_to_x(item_rel)
        reaper.ImGui_DrawList_AddLine(draw_list,
          cursor_x, py, cursor_x, py + h, C.playhead, 1.5)
        reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
          cursor_x - L.sm, py, cursor_x + L.sm, py, cursor_x, py + L.md, C.playhead)
      end
    end
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)   -- the note area

  ---------------------------------------------------------------------------
  -- DRAW NOTE-NAME COLUMN (a flat strip left of the rows; the root row carries an accent strip and an accent name)
  ---------------------------------------------------------------------------
  reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, py, px, py + full_h, C.gutter_bg)
  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, px, py + h, true)
  for n = math.floor(min_note), math.ceil(max_note) do
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local pc = (n % 12 + 12) % 12
    local is_root = (not is_chromatic) and pc == root_pc
    reaper.ImGui_DrawList_AddLine(draw_list, full_px, key_bot, px, key_bot, C.grid)
    if is_root then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, px - L.xs - L.border, key_top, px, key_bot, C.gutter_strip)
    end
    -- Every row is named while a row is at least a text line tall; below that only the C rows are, so the names
    -- never overlap. Out-of-scale rows are named in the dimmer colour (every name is >= 4.5:1 on the column).
    if px_per_st >= line_h or pc == 0 then
      local text_col = C.gutter_text_dim
      if is_root then
        text_col = C.gutter_text_tonic
      elseif is_chromatic or is_pitch_in_scale(pc) then
        text_col = C.gutter_text
      end
      reaper.ImGui_DrawList_AddText(draw_list, full_px + L.sm, (key_top + key_bot) * 0.5 - line_h * 0.5, text_col, midi_to_name(n))
    end
  end
  reaper.ImGui_DrawList_PopClipRect(draw_list)
  reaper.ImGui_DrawList_AddLine(draw_list, px, py, px, py + h, P.border)

  ---------------------------------------------------------------------------
  -- DRAW PITCH STRIP (right of the note area) and OVERVIEW STRIP (below it): track, thumb, end grips
  ---------------------------------------------------------------------------
  do
    local x0, x1 = px + w, px + w + pv_w
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, py, x1, py + h, C.overview_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, x0, py, x0, py + h, P.border)
    local ty0, ty1 = pitch_thumb()
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x0 + L.xs, ty0, x1 - L.xs, ty1, C.view_fill, L.rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, x0 + L.xs, ty0, x1 - L.xs, ty1, C.view_border, L.rounding)
    if ty1 - ty0 >= L.xxl then   -- room for a grip inside each end
      local gx0, gx1 = x0 + L.sm + L.border, x1 - L.sm - L.border
      reaper.ImGui_DrawList_AddRectFilled(draw_list, gx0, ty0 + L.sm, gx1, ty0 + L.sm + L.xs, C.view_grip)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, gx0, ty1 - L.sm - L.xs, gx1, ty1 - L.sm, C.view_grip)
    end
  end
  do
    local y0, y1 = py + h, py + full_h
    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, y0, full_px + full_w, y1, C.overview_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, full_px, y0, full_px + full_w, y0, P.border)
    -- Every note, small: placed by time over the whole item and by pitch over the fitted range
    local lane_h = (y1 - y0) - L.sm * 2
    if state.notes and lane_h > 0 then
      local fit_span = math.max(1, fit_max - fit_min)
      local bar_h = math.max(L.xs, math.min(L.sm, lane_h / fit_span))
      for _, note in ipairs(state.notes) do
        if note.controls then
          local nx0 = px + (note.start_time - item_t0) / duration * w
          local nx1 = math.max(nx0 + 1, px + (note.end_time - item_t0) / duration * w)
          local frac = math.max(0, math.min(1, (note.controls.center_pitch - fit_min) / fit_span))
          local cy = y1 - L.sm - frac * lane_h
          reaper.ImGui_DrawList_AddRectFilled(draw_list, nx0, cy - bar_h * 0.5, nx1, cy + bar_h * 0.5, C.overview_note)
        end
      end
    end
    local tx0, tx1 = overview_thumb()
    reaper.ImGui_DrawList_AddRectFilled(draw_list, tx0, y0 + L.xs, tx1, y1 - L.xs, C.view_fill, L.rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, tx0, y0 + L.xs, tx1, y1 - L.xs, C.view_border, L.rounding)
    if tx1 - tx0 >= L.xxl then   -- room for a grip inside each end
      local gy0, gy1 = y0 + L.sm + L.border, y1 - L.sm - L.border
      reaper.ImGui_DrawList_AddRectFilled(draw_list, tx0 + L.sm, gy0, tx0 + L.sm + L.xs, gy1, C.view_grip)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, tx1 - L.sm - L.xs, gy0, tx1 - L.sm, gy1, C.view_grip)
    end
    if playhead_t then
      local cursor_x = px + (playhead_t - item_t0) / duration * w
      reaper.ImGui_DrawList_AddLine(draw_list, cursor_x, y0, cursor_x, y1, C.playhead)
    end
  end
end

--- The BYPASSED overlay and the status pill.
local function canvas_draw_bypassed(cv)
  local is_bypassed, draw_list, full_px, py, full_w = cv.is_bypassed, cv.draw_list, cv.full_px, cv.py, cv.full_w
  local full_h, C, draw_ctx, h, L, P = cv.full_h, cv.C, cv.draw_ctx, cv.h, cv.L, cv.P
  local canvas_button, target_take, px, w, t_to_x = cv.canvas_button, cv.target_take, cv.px, cv.w, cv.t_to_x
  local min_note, note_range = cv.min_note, cv.note_range

  -- Bypassed Overlay: yellow (a state to get out of, not an error), with the way out as a button
  if is_bypassed then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, py, full_px + full_w, py + full_h, C.scrim)

    local txt_main = "BYPASSED"
    local sub_txt = "Pitch envelope is bypassed"
    local hint_txt = "Re-enable the envelope to edit"
    -- Every line is measured and drawn in the same font
    local pushed_bp_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
    local tw, th = reaper.ImGui_CalcTextSize(draw_ctx, txt_main)
    Theme.pop_font(draw_ctx, pushed_bp_font)
    local stw, sth = reaper.ImGui_CalcTextSize(draw_ctx, sub_txt)
    local htw, hth = reaper.ImGui_CalcTextSize(draw_ctx, hint_txt)

    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5
    local badge_w = math.max(tw, stw, htw) + L.xl * 2
    local badge_h = L.lg + th + L.xs + sth + hth + L.md + L.btn_lg.h + L.lg
    local bx1 = cx - badge_w * 0.5
    local by1 = cy - badge_h * 0.5
    local bx2 = cx + badge_w * 0.5
    local by2 = cy + badge_h * 0.5

    reaper.ImGui_DrawList_AddRectFilled(draw_list, bx1, by1, bx2, by2, P.card, L.rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, bx1, by1, bx2, by2, C.bypass_border, L.rounding, 0, 1.5)   -- yellow, >= 3:1 on the card and the dimmed canvas

    local line_y = by1 + L.lg
    pushed_bp_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
    reaper.ImGui_DrawList_AddText(draw_list, cx - tw * 0.5, line_y, C.bypass_title, txt_main)   -- yellow, >= 4.5:1 on the card
    Theme.pop_font(draw_ctx, pushed_bp_font)
    line_y = line_y + th + L.xs
    reaper.ImGui_DrawList_AddText(draw_list, cx - stw * 0.5, line_y, P.text, sub_txt)   -- P.text on the card 15.5:1 (P.text_dim was 3.8:1)
    line_y = line_y + sth
    reaper.ImGui_DrawList_AddText(draw_list, cx - htw * 0.5, line_y, P.text, hint_txt)
    line_y = line_y + hth + L.md

    if canvas_button("Enable", "cv_enable", cx, line_y, true, "Turn the item's pitch envelope back on") then
      toggle_take_pitch_bypass(target_take)
    end
  end

  -- Status pill, bottom-left of the note area (over the scrim too): a status message while it lasts, else the hint
  -- for the state the editor is in (K.status_line)
  K.canvas_status(draw_list, px + L.sm, py + h - L.sm, w - L.sm * 2, not is_bypassed, function(x1, y1, x2, y2)
    return K.note_under(state.notes, t_to_x, py, h, min_note, note_range, x1, y1, x2, y2)
  end)
end

-- What the files loaded after this one use
App.canvas_draw_rows = canvas_draw_rows
App.canvas_draw_notes = canvas_draw_notes
App.canvas_draw_curves = canvas_draw_curves
App.canvas_draw_overlays = canvas_draw_overlays
App.canvas_draw_bypassed = canvas_draw_bypassed
