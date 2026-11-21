-- @noindex
-- Fancy Pitch Correct: the pitch canvas (draw_graph).
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme, fonts = App.K, App.state, App.Theme, App.fonts
local apply_envelope_to_take = App.apply_envelope_to_take
local DEFAULTS = App.DEFAULTS
local flush_nudge_burst = App.flush_nudge_burst
local get_effective = App.get_effective
local get_override_level = App.get_override_level
local is_note_modified = App.is_note_modified
local is_pitch_in_scale = App.is_pitch_in_scale
local is_take_pitch_bypassed = App.is_take_pitch_bypassed
local midi_to_name = App.midi_to_name
local nudge_selected_notes = App.nudge_selected_notes
local param_drag = App.param_drag
local PARAM_LABELS = App.PARAM_LABELS
local plural = App.plural
local reset_selected_note = App.reset_selected_note
local SCALE_DEFINITIONS = App.SCALE_DEFINITIONS
local set_status = App.set_status
local start_analysis = App.start_analysis
local toggle_take_pitch_bypass = App.toggle_take_pitch_bypass
local trim_note_edge = App.trim_note_edge

local function draw_graph(draw_ctx, w, h)
  local draw_list = reaper.ImGui_GetWindowDrawList(draw_ctx)
  local px, py = reaper.ImGui_GetCursorScreenPos(draw_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout
  local C = P.canvas   -- the canvas colours (Theme section 4A): rows, keys, notes, curves, pills; they follow the theme mode

  -- Claim canvas space and enable mouse interaction. A Button submitted later on top of it (the empty-state and
  -- BYPASSED actions) takes the hover where it sits, so the canvas allows itself to be overlapped.
  reaper.ImGui_SetNextItemAllowOverlap(draw_ctx)
  reaper.ImGui_InvisibleButton(draw_ctx, "##pitch_canvas", w, h)
  local is_canvas_hovered = reaper.ImGui_IsItemHovered(draw_ctx)
  local canvas_tip_ready = reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip())   -- the hover hint waits like every tooltip

  -- Draw background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + h, P.bg)
  reaper.ImGui_DrawList_AddRect(draw_list, px, py, px + w, py + h, P.border)

  -- The canvas rectangle (full_px, py, full_w, full_h) is carved into the note-name column on the left, the note
  -- area (px, py, w, h: every time / pitch conversion below maps onto it), the pitch strip on the right and the
  -- overview strip along the bottom. The two strips come off w and h once there is something to show (see below).
  local line_h = reaper.ImGui_GetTextLineHeight(draw_ctx) or 0
  local piano_w = math.max(L.xxxl + L.md, (reaper.ImGui_CalcTextSize(draw_ctx, "G#-1") or 0) + L.sm * 2)
  local full_px = px
  local full_w = w
  local full_h = h
  px = px + piano_w
  w = w - piano_w

  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, full_px + full_w, py + h, true)

  local target_take, target_item = K.frame_target()
  local is_bypassed = is_take_pitch_bypassed(target_take)

  -- The one button the canvas draws (Analyze Item, Open Settings, Enable): a real Button on the large preset,
  -- centred on cx with its top edge at y (its height is Theme.layout.btn_lg.h), hand cursor and tooltip.
  -- Returns true when it was clicked (never while it is disabled). It moves the layout cursor into the canvas:
  -- whoever used it calls restore_canvas_layout() before leaving draw_graph.
  local buttons_used = false
  local function canvas_button(label, id, cx, y, enabled, tip)
    buttons_used = true
    local var_count, pushed_font = Theme.push_button_preset(draw_ctx, fonts, "lg")
    local btn_w = (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) + L.btn_lg.pad_x * 2
    reaper.ImGui_SetCursorScreenPos(draw_ctx, cx - btn_w * 0.5, y)
    if not enabled then reaper.ImGui_BeginDisabled(draw_ctx) end
    local clicked = reaper.ImGui_Button(draw_ctx, label .. "###" .. id, btn_w, 0)
    if not enabled then reaper.ImGui_EndDisabled(draw_ctx) end
    local hovered = reaper.ImGui_IsItemHovered(draw_ctx)
    local tip_ready = reaper.ImGui_IsItemHovered(draw_ctx,   -- a disabled button explains itself too
      reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled())
    Theme.pop_button_preset(draw_ctx, var_count, pushed_font)   -- before the tooltip: it is drawn in the default font
    if enabled and hovered then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if tip_ready then Theme.tooltip(draw_ctx, tip) end
    return clicked and enabled
  end

  -- After canvas_button the last item is a button inside the canvas and the cursor sits in it: a canvas-sized
  -- Dummy at the canvas origin puts both back, so the caller's SameLine / next item lands as it does without buttons
  local function restore_canvas_layout()
    if buttons_used then
      reaper.ImGui_SetCursorScreenPos(draw_ctx, full_px, py)
      reaper.ImGui_Dummy(draw_ctx, full_w, full_h)
    end
  end

  -- Nothing to edit yet: not analysed (Analyze Item above a hint), or analysed without finding a pitched note
  if #state.results == 0 or state.analysis_empty then
    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5
    local gap = L.lg

    if #state.results == 0 then
      local msg = "No data. Select an item and click Analyze."
      local text_w, text_h = reaper.ImGui_CalcTextSize(draw_ctx, msg)
      local start_y = cy - (L.btn_lg.h + gap + text_h) * 0.5

      local can_analyze = (target_take ~= nil and not state.is_analyzing)
      local tip = can_analyze and "Detect the pitch of the selected audio item"
        or (state.is_analyzing and "Analysis in progress" or "Select an audio item in REAPER to analyze it.")
      if canvas_button("Analyze Item", "cv_analyze", cx, start_y, can_analyze, tip) then
        start_analysis()
      end

      -- Centered text below the button
      reaper.ImGui_DrawList_AddText(draw_list, cx - text_w * 0.5, start_y + L.btn_lg.h + gap, P.text_dim, msg)
    else
      local title = "No pitched notes found"
      local hint = "Try another Vocal Range or Detection Mode in Settings."
      -- The title is measured and drawn in the same (bold) font
      local pushed_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
      local title_w, title_h = reaper.ImGui_CalcTextSize(draw_ctx, title)
      Theme.pop_font(draw_ctx, pushed_font)
      local hint_w, hint_h = reaper.ImGui_CalcTextSize(draw_ctx, hint)
      local start_y = cy - (title_h + L.xs + hint_h + gap + L.btn_lg.h) * 0.5

      pushed_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
      reaper.ImGui_DrawList_AddText(draw_list, cx - title_w * 0.5, start_y, P.text, title)
      Theme.pop_font(draw_ctx, pushed_font)
      reaper.ImGui_DrawList_AddText(draw_list, cx - hint_w * 0.5, start_y + title_h + L.xs, P.text_dim, hint)

      if canvas_button("Open Settings", "cv_open_settings", cx, start_y + title_h + L.xs + hint_h + gap, true,
          "Open Settings to change the Vocal Range or Detection Mode") then
        App.show_settings_modal = true
      end
    end

    -- The empty canvases carry their own centred message: the pill adds only a status message or the selection issue
    K.canvas_status(draw_list, full_px + L.sm, py + full_h - L.sm, full_w - L.sm * 2, false)
    restore_canvas_layout()
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end

  -- PITCH RANGE. The fit follows the notes (their centre and their original pitch), not every analysis frame: a
  -- stray octave error in the raw curve must not squeeze the melody into a third of the canvas. While there are no
  -- notes yet (an analysis in progress) the frames are all there is. ext_min .. ext_max is everything there is to
  -- see (the fit widened to the raw curve): the track of the pitch strip and the limit of a range the user chose.
  local has_frames, raw_min, raw_max = K.results_range(state.results)   -- cached, see K.results_range
  if not has_frames then
    K.canvas_status(draw_list, full_px + L.sm, py + full_h - L.sm, full_w - L.sm * 2, false)
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end
  local has_fit, fit_min, fit_max = K.notes_pitch_fit(state.notes)
  if not has_fit then fit_min, fit_max = raw_min, raw_max end
  fit_min = math.floor(fit_min - K.PITCH_PAD_ST)
  fit_max = math.ceil(fit_max + K.PITCH_PAD_ST)
  if fit_max - fit_min < K.PITCH_MIN_FIT_ST then
    local grow = K.PITCH_MIN_FIT_ST - (fit_max - fit_min)
    fit_min = fit_min - grow // 2
    fit_max = fit_max + (grow - grow // 2)
  end
  local ext_min = math.min(fit_min, math.floor(raw_min - K.PITCH_PAD_ST))
  local ext_max = math.max(fit_max, math.ceil(raw_max + K.PITCH_PAD_ST))

  -- The range on screen: the fit, or the one the user chose (state.view_p0 / view_p1), kept inside the extent
  local min_note, max_note = fit_min, fit_max
  if state.view_p0 and state.view_p1 then
    local span = math.max(math.min(K.PITCH_MIN_VIEW_ST, ext_max - ext_min), math.min(ext_max - ext_min, state.view_p1 - state.view_p0))
    min_note = math.max(ext_min, math.min(ext_max - span, state.view_p0))
    max_note = min_note + span
  end
  local note_range = math.max(1, max_note - min_note)

  -- There is something to show: the strips take their room from the note area
  local ov_h = math.min(line_h * 2, h * 0.25)   -- overview strip (below the note area)
  local pv_w = L.xl                             -- pitch strip (right of the note area)
  h = h - ov_h
  w = w - pv_w

  local duration = state.end_time - state.start_time
  if duration <= 0 then duration = 1 end
  local px_per_st = h / note_range -- pixels per semitone

  -- A gesture keeps the pitch range it began with (view_min / view_max, stored when it starts): the range
  -- above follows every note, so a note dragged out of it would rescale the canvas under the cursor.
  -- After the release the range follows the notes again.
  local gesture = state.drag or state.edge_drag or state.marquee or state.point_drag
  if gesture and gesture.view_min and gesture.view_max then
    min_note, max_note = gesture.view_min, gesture.view_max
    note_range = math.max(1, max_note - min_note)
    px_per_st = h / note_range
  end

  ---------------------------------------------------------------------------
  -- TIMELINE VIEW (horizontal zoom and scroll)
  ---------------------------------------------------------------------------
  -- Every time <-> x conversion below goes through t_to_x / x_to_t, which map the visible window [vt0, vt1]
  -- (seconds relative to the item start: the whole item unless the user zoomed, state.view_t0 / view_t1) onto
  -- the note area. The vertical pitch range is not affected by the window.
  local item_t0 = state.start_time
  local item_t1 = state.start_time + duration
  local vt0, vt1 = item_t0, item_t1
  local function t_to_x(t) return px + (t - vt0) / (vt1 - vt0) * w end
  local function x_to_t(x) return vt0 + (x - px) / math.max(w, 1) * (vt1 - vt0) end

  -- Show `span` seconds with the time `anchor_t` at fraction `frac` (0..1) of the note area's width. The span
  -- stays within [MIN_VIEW_SPAN_S, the item], the window inside the item, and a window covering the whole
  -- item is stored as nil.
  local function set_view(anchor_t, frac, span)
    span = math.max(math.min(K.MIN_VIEW_SPAN_S, duration), math.min(duration, span))
    local t0 = math.max(item_t0, math.min(item_t1 - span, anchor_t - frac * span))
    if span >= duration - K.VIEW_EPS_S then
      vt0, vt1 = item_t0, item_t1
      state.view_t0, state.view_t1 = nil, nil
    else
      vt0, vt1 = t0, t0 + span
      state.view_t0, state.view_t1 = vt0, vt1
    end
  end
  if state.view_t0 and state.view_t1 then   -- an item that changed length keeps the window inside it
    set_view(state.view_t0, 0, state.view_t1 - state.view_t0)
  end

  -- The same for the pitch axis: show p0 .. p1 (semitones), never fewer than PITCH_MIN_VIEW_ST and never outside
  -- the extent. The range stays the user's until K.reset_view (F, a double-click on the pitch strip, a new model).
  local function set_pitch_view(p0, p1)
    local span = math.max(math.min(K.PITCH_MIN_VIEW_ST, ext_max - ext_min), math.min(ext_max - ext_min, p1 - p0))
    p0 = math.max(ext_min, math.min(ext_max - span, p0))
    state.view_p0, state.view_p1 = p0, p0 + span
    min_note, max_note = p0, p0 + span
    note_range = math.max(1, span)
    px_per_st = h / note_range
  end
  -- Back to the range fitted to the notes
  local function fit_pitch_view()
    state.view_p0, state.view_p1 = nil, nil
    min_note, max_note = fit_min, fit_max
    note_range = math.max(1, max_note - min_note)
    px_per_st = h / note_range
  end

  -- Index range [i0, i1] of `list` (entries sorted by .time) that reaches the visible window, with one entry of
  -- margin on each side so a curve still runs off the canvas edge. Empty list -> 1, 0.
  local function visible_range(list)
    local n = #list
    if n == 0 then return 1, 0 end
    local lo, hi = 1, n + 1                         -- first entry at or after the window start
    while lo < hi do
      local mid = (lo + hi) // 2
      if list[mid].time < vt0 then lo = mid + 1 else hi = mid end
    end
    local i0 = math.max(1, lo - 1)
    lo, hi = i0, n + 1                              -- first entry after the window end
    while lo < hi do
      local mid = (lo + hi) // 2
      if list[mid].time <= vt1 then lo = mid + 1 else hi = mid end
    end
    return i0, math.min(n, lo)
  end

  ---------------------------------------------------------------------------
  -- MOUSE INTERACTION
  ---------------------------------------------------------------------------
  local mx, my = reaper.ImGui_GetMousePos(draw_ctx)

  -- The time ruler is an overlay along the top of the note area: it owns the pointer there. So do the overview
  -- strip (below the note area, the corner under the pitch strip included) and the pitch strip (right of it).
  local ruler_h = line_h + L.xs * 2
  local on_ruler = is_canvas_hovered and mx >= px and mx <= px + w and my >= py and my <= py + ruler_h
  local on_overview = is_canvas_hovered and my > py + h
  local on_pstrip = is_canvas_hovered and mx > px + w and my <= py + h

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

  ---------------------------------------------------------------------------
  -- OVERVIEW STRIP and PITCH STRIP: the one visible zoom / scroll control of each axis
  ---------------------------------------------------------------------------
  -- Each strip is a track (the whole item / the whole pitch extent) with a thumb marking what the note area shows.
  -- Dragging the thumb scrolls, dragging one of its ends zooms (the other end stays put), a double-click shows
  -- everything again (the whole item / the range fitted to the notes), and a press outside the thumb brings the
  -- window there. The thumbs are worked out again when they are drawn: a gesture below moves them.
  local pitch_ext = math.max(1, ext_max - ext_min)
  local function overview_thumb()   -- left x, right x
    return px + (vt0 - item_t0) / duration * w, px + (vt1 - item_t0) / duration * w
  end
  local function pitch_thumb()      -- top y, bottom y
    return py + (ext_max - max_note) / pitch_ext * h, py + (ext_max - min_note) / pitch_ext * h
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
  -- Nothing on a note is hovered, clicked or dragged from the ruler or a strip, nor while a strip is dragged
  local off_notes = on_ruler or on_overview or on_pstrip or state.view_drag ~= nil

  -- Text on a small panel-coloured pill (C.pill_bg), so it stays readable over any canvas surface (HC1): the text tokens
  -- (C.pill_text, C.marquee_text) are fitted to >= 4.5:1 on the pill over every row and every note fill. The pill
  -- is kept inside the note area (below the ruler); with flip_dx it moves to the left of x when it would run past the right edge.
  local function pill_text(x, y, text, col, flip_dx)
    local tw, th = reaper.ImGui_CalcTextSize(draw_ctx, text)
    local pill_w, pill_h = tw + L.sm * 2, th + L.xs * 2
    if flip_dx and x + pill_w > px + w then x = x - pill_w - flip_dx end
    x = math.max(px, math.min(x, px + w - pill_w))
    y = math.max(py + ruler_h, math.min(y, py + h - pill_h))
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + pill_w, y + pill_h, C.pill_bg, L.rounding)
    reaper.ImGui_DrawList_AddText(draw_list, x + L.sm, y + L.xs, col, text)
  end

  --- True when `text` on a pill fits `room` pixels: the pill pill_text draws, plus the offset the zone labels start at.
  local function pill_fits(text, room)
    return (reaper.ImGui_CalcTextSize(draw_ctx, text)) + L.sm * 2 + L.xs <= room
  end

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

  -- The mapping is final (zoom, scroll and the gesture's frozen pitch range are applied): the cached coordinate arrays
  -- below are valid only for this one
  K.canvas_cache_begin(px, py, w, h, vt0, vt1, min_note, note_range)

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

  -- Note Context Menu
  local note_menu_open = reaper.ImGui_BeginPopup(draw_ctx, "##note_context_menu")
  if note_menu_open then
    -- HC5: Esc closes this menu, unless a popup opened from it (a typed-entry field) is open: that one is innermost.
    -- Esc also ends a slider drag in the same frame (ImGui reports it as an edit released): that is a cancel, not a
    -- commit
    local nm_esc = false
    if not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
      nm_esc = true
    end
    local note_idx = state.context_menu_note
    local note = state.notes[note_idx]
    if note and note.controls then
      local ctrl = note.controls
      local cp = ctrl.center_pitch
      local nearest = math.floor(cp + 0.5)
      local cents = math.floor((cp - nearest) * 100 + 0.5)
      local sign = cents >= 0 and "+" or ""
      local note_name = midi_to_name(nearest)
      local in_scale = is_pitch_in_scale(nearest)
      local scale_str = in_scale and "(In Scale)" or "(Out of Scale)"
      local header = string.format("%s %s%d\xC2\xA2 %s", note_name, sign, cents, scale_str)

      local pushed = Theme.push_font(draw_ctx, fonts.medium_bold)
      reaper.ImGui_Text(draw_ctx, header)
      Theme.pop_font(draw_ctx, pushed)

      reaper.ImGui_Separator(draw_ctx)

      local bp = ctrl.bypassed or false
      local changed, new_bp = reaper.ImGui_Checkbox(draw_ctx, "Bypass This Note", bp)
      if changed then
        ctrl.bypassed = new_bp
        apply_envelope_to_take("Toggle Note Bypass")
      end

      reaper.ImGui_Separator(draw_ctx)

      reaper.ImGui_PushItemWidth(draw_ctx, 120)

      -- How many notes a row with `spread` writes to: every selected note when the menu's note is one of several
      local spread_n = 0
      if state.selected_notes[note_idx] then
        for idx in pairs(state.selected_notes) do
          if state.notes[idx] and state.notes[idx].controls then spread_n = spread_n + 1 end
        end
      end

      --- One value row. `spread`: the value is written to every selected note (see spread_n), and the row says
      --- how many. A value outside the cascade (Tighten, Scoop Shape) has nothing to inherit and shows no level.
      local function draw_cm_slider(label, key, min_v, max_v, fmt, scale, default, spread)
         local level = get_override_level(note, key)
         local cur_val = ctrl[key] or get_effective(note, key) or default or 0
         if scale then cur_val = cur_val * scale end
         spread = spread and spread_n > 1

         -- param_drag tests the gestures right after the control (not after SameLine / TextDisabled, which would test the text)
         local name = PARAM_LABELS[key] or label
         local s_changed, new_val, committed, reset = param_drag(draw_ctx, "cm_" .. key, label, cur_val, min_v, max_v, fmt)
         if K.drag_hot.hovered or K.drag_hot.active then
            -- The canvas shades where this value acts on the menu's note
            local set = state.setting_hint.menu_set
            for k in pairs(set) do set[k] = nil end
            set[note_idx] = true
            if spread then
               for idx in pairs(state.selected_notes) do set[idx] = true end
            end
            K.setting_hint(draw_ctx, key, K.drag_hot.active, set)
         end
         local edit = state.context_edit
         if reset then
            -- Double-click: drop the per-note override so the note inherits again (one undo point)
            if edit and edit.key == key then state.context_edit = nil end
            local had = ctrl[key] ~= nil
            ctrl[key] = nil
            if spread then
               for idx in pairs(state.selected_notes) do
                  local o = state.notes[idx]
                  if o and o ~= note and o.controls and o.controls[key] ~= nil then
                     o.controls[key] = nil
                     had = true
                  end
               end
            end
            if had then
               apply_envelope_to_take("Reset " .. name)
            end
         else
            if s_changed then
               -- The model is ahead of the envelope until the commit: remember the value to go back to (nil = inherit)
               if not (edit and edit.note == note and edit.key == key) then
                  edit = { note = note, key = key, raw = ctrl[key] }
                  -- Each of the other selected notes remembers its own value for Esc
                  if spread then
                     edit.others = {}
                     for idx in pairs(state.selected_notes) do
                        local o = state.notes[idx]
                        if o and o ~= note and o.controls then
                           edit.others[#edit.others + 1] = { note = o, raw = o.controls[key] }
                        end
                     end
                  end
                  state.context_edit = edit
               end
               if scale then new_val = new_val / scale end
               ctrl[key] = new_val
               for _, o in ipairs(edit.others or {}) do o.note.controls[key] = new_val end
            end
            if committed and not nm_esc then
               apply_envelope_to_take("Adjust " .. name)
               state.context_edit = nil
            end
         end
         if DEFAULTS[key] ~= nil then
            reaper.ImGui_SameLine(draw_ctx)
            reaper.ImGui_TextDisabled(draw_ctx, "[" .. level .. "]")
         end
         if spread then
            reaper.ImGui_SameLine(draw_ctx)
            reaper.ImGui_TextDisabled(draw_ctx, string.format("(%d notes)", spread_n))
         end
      end

      draw_cm_slider(PARAM_LABELS.tighten, "tighten", 0, 100, "%.0f%%", 100, nil, true)
      draw_cm_slider(PARAM_LABELS.tolerance, "tolerance", K.LIMITS.tolerance[1], K.LIMITS.tolerance[2], "%.0f \xC2\xA2", nil, nil, true)
      draw_cm_slider("Onset Ramp", "onset_ramp_ms", 5, 60, "%.0f ms", nil, nil, true)
      draw_cm_slider("Scoop Shape", "scoop_shape", 0, 100, "%.0f%%", 100, nil, true)
      draw_cm_slider("Transition", "transition_ms", 5, 60, "%.0f ms", nil, nil, true)
      draw_cm_slider(PARAM_LABELS.retune_speed, "retune_speed", 0, 100, "%.0f%%", 100, nil, true)

      reaper.ImGui_PopItemWidth(draw_ctx)
      reaper.ImGui_Separator(draw_ctx)

      if reaper.ImGui_MenuItem(draw_ctx, "Snap to Semitone", "S") then
        K.note_action("snap")
      end
      if reaper.ImGui_MenuItem(draw_ctx, "Quantize to Scale", "Q") then
        K.note_action("quantize")
      end
      if reaper.ImGui_MenuItem(draw_ctx, "Split at Cursor", "X") then
        K.note_action("split", note_idx)
      end
      -- Pitch points: add one where the menu was opened, or put the note's points back (disabled with the reason)
      local _, add_reason = K.point_can_add(note, state.context_menu_time or note.start_time)
      local add_why = (not state.show_smart_spots) and "layer is off"
        or ctrl.bypassed and "note is bypassed"
        or (not state.context_menu_live) and "zoom in first"
        or add_reason == "no_pitch" and "no pitch here"
        or add_reason == "too_close" and "a point is already here" or nil
      if reaper.ImGui_MenuItem(draw_ctx, "Add Pitch Point Here", add_why, false, add_why == nil) then
        local knot, reason = K.point_add(note, state.context_menu_time or note.start_time)
        if knot then
          apply_envelope_to_take("Add Pitch Point")
        elseif reason == "no_pitch" then
          set_status("No pitch detected here: a point needs a pitch to sit on.")
        end
      end
      local n_points = K.points_count(note)
      if reaper.ImGui_MenuItem(draw_ctx, string.format("Reset Pitch Points (%d)###reset_points", n_points),
          n_points == 0 and "none moved or added" or nil, false, n_points > 0) then
        local n_done = K.points_reset(note)
        if n_done > 0 and apply_envelope_to_take("Reset Pitch Points") then
          set_status(string.format("Reset %d pitch %s on %s. %s+Z to undo", n_done, plural(n_done, "point", "points"),
            note_name, K.MOD_LABEL))
        end
      end
      if reaper.ImGui_MenuItem(draw_ctx, "Reset to Original", "R") then
        reset_selected_note()
      end
    end
    reaper.ImGui_EndPopup(draw_ctx)
  end
  -- The note menu closed (Esc during a slider drag) with a slider value not written: the note gets back the value it
  -- had before the drag, with no write and no undo point (HC5: Esc reverts the active edit)
  local cm_edit = state.context_edit
  if not note_menu_open and cm_edit then
    if cm_edit.note.controls then cm_edit.note.controls[cm_edit.key] = cm_edit.raw end
    for _, o in ipairs(cm_edit.others or {}) do   -- the other selected notes the value was written to
      if o.note.controls then o.note.controls[cm_edit.key] = o.raw end
    end
    state.context_edit = nil
  end

  -- Point Context Menu: the offset of one pitch point, put it back, remove it (added points only)
  local point_menu_open = reaper.ImGui_BeginPopup(draw_ctx, "##point_context_menu")
  if point_menu_open then
    -- HC5: Esc closes this menu, unless its typed-entry popup is open (that one is innermost). Esc also ends an
    -- Offset drag in the same frame (ImGui reports it as an edit released): that is a cancel, not a commit
    local pt_esc = false
    if not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
      pt_esc = true
    end
    local cpt = state.context_point
    local pt_note = cpt and state.notes and state.notes[cpt.note_idx]
    local pt_knot = pt_note and K.point_knot_at(pt_note, cpt.frame)
    if not pt_knot then
      -- The point is gone (an undo, a trim, a reload, or a live Offset of 0 dropped its entry): the menu closes,
      -- and an uncommitted Offset is put back below
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
      point_menu_open = false
    else
      local pt_hint = string.format(" %s+Z to undo", K.MOD_LABEL)
      reaper.ImGui_PushItemWidth(draw_ctx, 120)
      local ch, val, committed, reset = param_drag(draw_ctx, "pt_offset", "Offset", pt_knot.st * 100,
        -K.POINT_MAX_ST * 100, K.POINT_MAX_ST * 100, "%+.0f \xC2\xA2")
      reaper.ImGui_PopItemWidth(draw_ctx)
      cpt.active = K.drag_hot.active   -- the Offset is being dragged or typed (the Preview Curve follows it)
      if reset then
        if pt_knot.st ~= 0 then
          K.point_set(pt_note, pt_knot, 0)
          apply_envelope_to_take("Reset Pitch Point")
        end
        cpt.start_st, cpt.live = 0, nil
      else
        if ch then
          K.point_set(pt_note, pt_knot, val / 100)
          cpt.live, cpt.note = true, pt_note   -- the model is ahead of the envelope until the commit
        end
        if committed and not pt_esc then
          local now = K.point_knot_at(pt_note, cpt.frame)
          if not now or K.points_clamp(now.st) ~= K.points_clamp(cpt.start_st) then
            apply_envelope_to_take("Move Pitch Point")
          end
          cpt.start_st, cpt.live = now and now.st or 0, nil
        end
      end

      reaper.ImGui_Separator(draw_ctx)

      local cur = K.point_knot_at(pt_note, cpt.frame) or pt_knot
      if reaper.ImGui_MenuItem(draw_ctx, "Reset Point", cur.st == 0 and "already at 0" or nil, false, cur.st ~= 0) then
        K.point_set(pt_note, cur, 0)
        cpt.start_st, cpt.live = 0, nil
        if apply_envelope_to_take("Reset Pitch Point") then set_status("Reset the pitch point." .. pt_hint) end
      end
      local can_remove = cur.kind == "added"
      if reaper.ImGui_MenuItem(draw_ctx, "Remove Point", not can_remove and "detected points stay" or nil, false, can_remove) then
        if K.point_remove(pt_note, cur) then
          if apply_envelope_to_take("Remove Pitch Point") then set_status("Removed the pitch point." .. pt_hint) end
          state.context_point = nil
        end
      end
    end
    reaper.ImGui_EndPopup(draw_ctx)
  end
  -- The point menu closed (Esc, a click away, or by itself) with its Offset not committed: the point goes back to
  -- the value it had when the menu opened or was last committed, with no write and no undo point
  local cpt_closed = state.context_point
  if not point_menu_open and cpt_closed then
    if cpt_closed.live and state.notes and state.notes[cpt_closed.note_idx] == cpt_closed.note then
      local n = cpt_closed.note
      local f = n.frames and n.frames[cpt_closed.frame]
      local knot = K.point_knot_at(n, cpt_closed.frame) or (f and { frame = cpt_closed.frame, t = f.time, st = 0 })
      if knot then K.point_set(n, knot, cpt_closed.start_st) end
    end
    state.context_point = nil
  end

  restore_canvas_layout()
  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

-- What the files loaded after this one use
App.draw_graph = draw_graph
