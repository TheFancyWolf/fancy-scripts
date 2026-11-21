-- @noindex
-- Fancy Pitch Correct: the pitch canvas (draw_graph): the frame's layout and view, then its steps in order.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme, fonts = App.K, App.state, App.Theme, App.fonts
local canvas_double_click = App.canvas_double_click
local canvas_draw_bypassed = App.canvas_draw_bypassed
local canvas_draw_curves = App.canvas_draw_curves
local canvas_draw_notes = App.canvas_draw_notes
local canvas_draw_overlays = App.canvas_draw_overlays
local canvas_draw_rows = App.canvas_draw_rows
local canvas_keys = App.canvas_keys
local canvas_navigate = App.canvas_navigate
local canvas_note_menu = App.canvas_note_menu
local canvas_point_menu = App.canvas_point_menu
local canvas_pointer = App.canvas_pointer
local is_take_pitch_bypassed = App.is_take_pitch_bypassed
local start_analysis = App.start_analysis

-- The frame table handed to every step (see canvas_input.lua): one table, filled again each frame
local cv = {}

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

  ---------------------------------------------------------------------------
  -- THE STEPS (canvas_input.lua, canvas_draw.lua, canvas_menus.lua)
  ---------------------------------------------------------------------------
  -- What the steps share for this frame. The view stays in the locals above (set_view, set_pitch_view and
  -- fit_pitch_view change it); sync_view copies it to cv, at the start and after every change.
  cv.draw_ctx, cv.w, cv.h, cv.draw_list, cv.px, cv.py = draw_ctx, w, h, draw_list, px, py
  cv.P, cv.L, cv.C, cv.is_canvas_hovered, cv.canvas_tip_ready = P, L, C, is_canvas_hovered, canvas_tip_ready
  cv.line_h, cv.full_px, cv.full_w, cv.full_h, cv.target_take = line_h, full_px, full_w, full_h, target_take
  cv.target_item, cv.is_bypassed, cv.canvas_button, cv.fit_min = target_item, is_bypassed, canvas_button, fit_min
  cv.fit_max, cv.ext_min, cv.ext_max, cv.pv_w, cv.duration = fit_max, ext_min, ext_max, pv_w, duration
  cv.gesture, cv.item_t0, cv.t_to_x, cv.x_to_t, cv.visible_range = gesture, item_t0, t_to_x, x_to_t, visible_range
  cv.mx, cv.my, cv.ruler_h, cv.on_ruler, cv.on_overview = mx, my, ruler_h, on_ruler, on_overview
  cv.on_pstrip, cv.pitch_ext, cv.overview_thumb, cv.pitch_thumb = on_pstrip, pitch_ext, overview_thumb, pitch_thumb
  cv.pill_text, cv.pill_fits = pill_text, pill_fits
  local function sync_view()
    cv.vt0, cv.vt1, cv.min_note, cv.max_note, cv.note_range, cv.px_per_st = vt0, vt1, min_note, max_note, note_range, px_per_st
  end
  cv.set_view = function(anchor_t, frac, span) set_view(anchor_t, frac, span); sync_view() end
  cv.set_pitch_view = function(p0, p1) set_pitch_view(p0, p1); sync_view() end
  cv.fit_pitch_view = function() fit_pitch_view(); sync_view() end
  sync_view()

  canvas_navigate(cv)

  -- Nothing on a note is hovered, clicked or dragged from the ruler or a strip, nor while a strip is dragged
  local off_notes = on_ruler or on_overview or on_pstrip or state.view_drag ~= nil
  cv.off_notes = off_notes

  canvas_pointer(cv)
  canvas_keys(cv)
  canvas_double_click(cv)

  -- The mapping is final (zoom, scroll and the gesture's frozen pitch range are applied): the cached coordinate arrays
  -- below are valid only for this one
  K.canvas_cache_begin(px, py, w, h, vt0, vt1, min_note, note_range)

  cv.root_pc, cv.is_chromatic = canvas_draw_rows(cv)
  cv.labels = canvas_draw_notes(cv)
  canvas_draw_curves(cv)
  canvas_draw_overlays(cv)
  canvas_draw_bypassed(cv)
  canvas_note_menu(cv)
  canvas_point_menu(cv)

  restore_canvas_layout()
  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

-- What the files loaded after this one use
App.draw_graph = draw_graph
