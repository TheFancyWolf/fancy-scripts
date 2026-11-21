-- @noindex
-- Fancy Pitch Correct: the top bar and its controls.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme, ctx = App.K, App.state, App.Theme, App.ctx
local apply_envelope_to_take = App.apply_envelope_to_take
local BODY = App.BODY
local COMBO_LABELS = App.COMBO_LABELS
local count_selected_notes = App.count_selected_notes
local DEFAULTS = App.DEFAULTS
local get_effective = App.get_effective
local get_override_level = App.get_override_level
local get_target_track_color = App.get_target_track_color
local global_defaults = App.global_defaults
local is_note_modified = App.is_note_modified
local param_drag = App.param_drag
local PARAM_LABELS = App.PARAM_LABELS
local PITCHMODE_FLAT = App.PITCHMODE_FLAT
local plural = App.plural
local request_analyze = App.request_analyze
local request_reset = App.request_reset
local save_current_scale_settings = App.save_current_scale_settings
local SCALE_DEFINITIONS = App.SCALE_DEFINITIONS
local SCALE_KEYS = App.SCALE_KEYS
local script_set_pitch_mode = App.script_set_pitch_mode
local set_status = App.set_status
local update_scale_pitch_classes = App.update_scale_pitch_classes

-------------------------------------------------------------------------------
-- TOP BAR
-------------------------------------------------------------------------------
-- Every control of the window, in one place above the canvas, in four groups read from broad to specific:
--   Clip          brand, target badge, Key, Scale
--   Values        the selection pill (what a drag changes: the defaults, or the selected notes), Tighten,
--                 Strength, Tolerance, and "Timing", which opens and closes the Timing row
--   Note actions  Snap, Quantize, Split, Merge
--   Right         "…" (Analyze / Cancel, Reset, Layers, Note Tone, Settings, Help) and Close, right-aligned on row 1
--   Timing row    Transition, Onset Ramp, Scoop Shape, Legato Gap: the last row(s) of the bar while it is open
-- The Values, Note action and Timing row units are drawn by K.bar_frame (see TOP BAR CONTROLS below); this
-- section places them. Every width is measured from the longest text its control can show. On how many rows the
-- units sit is a HDR_PLANS entry chosen from the content width alone (never from the selected item or the note
-- selection), so nothing jumps while working: as the width shrinks the groups wrap onto more rows, and at the
-- narrowest the Values group wraps inside itself. The item badge takes the width its row has left and truncates
-- its text with an ellipsis.

App.hdr_static = nil        -- widths that depend only on fonts and style (measured once)

-- Chunk-level names of this section (loop_body and the top bar controls use them): everything else stays
-- private to the block below, so it does not count against the chunk's 200-local limit.
local measure_header_static, hdr_min_content_w, hdr_fit_text, draw_header

do
  local HDR_NO_TARGET_TEXT = "No Audio Item"
  local HDR_ELLIPSIS = "…"
  local HDR_PROGRESS_LONGEST = "100%"
  -- Why Analyze / Reset are disabled (in the More popup, beside the item)
  local HDR_REASON_NO_TARGET = "Select an audio item"
  local HDR_REASON_NO_NOTES = "Analyze an item first"
  local HDR_MORE_TIP = "Menu: Analyze, Reset, Layers, Note Tone, Settings, Help"

  -- The units of each group, and the group every unit belongs to (a separator is drawn where the group changes)
  local HDR_CLIP = { "brand", "badge", "key", "scale" }
  local HDR_VALUES = { "pill", "tight", "strength", "tol", "timing" }
  local HDR_TIMING = { "trans", "ramp", "scoop", "legato" }   -- the Timing row (shown while state.timing_open)
  local HDR_ACTIONS = { "snap", "quantize", "split", "merge" }
  local HDR_GROUP = {}
  for _, id in ipairs(HDR_CLIP) do HDR_GROUP[id] = "clip" end
  for _, id in ipairs(HDR_VALUES) do HDR_GROUP[id] = "values" end
  for _, id in ipairs(HDR_TIMING) do HDR_GROUP[id] = "timing" end
  for _, id in ipairs(HDR_ACTIONS) do HDR_GROUP[id] = "actions" end

  --- One row holding the units of every list given, in order.
  local function hdr_row(...)
    local row = {}
    for _, list in ipairs({ ... }) do
      for _, id in ipairs(list) do row[#row + 1] = id end
    end
    return row
  end

  local HDR_PLANS = {
    { rows = { hdr_row(HDR_CLIP, HDR_VALUES, HDR_ACTIONS) } },
    { rows = { HDR_CLIP, hdr_row(HDR_VALUES, HDR_ACTIONS) } },
    { rows = { HDR_CLIP, HDR_VALUES, HDR_ACTIONS } },
    { rows = { { "brand", "badge" }, { "key", "scale" }, HDR_VALUES, HDR_ACTIONS } },
    { rows = { { "brand", "badge" }, { "key", "scale" }, { "pill", "timing" }, { "tight", "strength" }, { "tol" }, HDR_ACTIONS } },
  }
  -- The plan a first-use window is sized for: two rows
  local HDR_FIRST_USE_PLAN = HDR_PLANS[2]
  for _, plan in ipairs(HDR_PLANS) do
    for r, row in ipairs(plan.rows) do
      for _, id in ipairs(row) do
        if id == "badge" then plan.badge_row = r end
      end
    end
  end

  local hdr_fit_cache = {}      -- fit_text results, keyed by text and width
  local hdr_fit_cache_n = 0

  local function hdr_text_w(text)
    return (reaper.ImGui_CalcTextSize(ctx, text))
  end

  local function hdr_max_text_w(list)
    local w = 0
    for _, text in ipairs(list) do w = math.max(w, hdr_text_w(text)) end
    return w
  end

  --- Measure everything in the top bar that does not change from frame to frame. Call with the default
  --- font and the Theme style pushed (before Begin is fine).
  measure_header_static = function()
    local L = Theme.layout
    local s = {}
    s.frame_h = reaper.ImGui_GetFrameHeight(ctx)
    s.pad_x = L.md * 2                                    -- FramePadding.x on both sides of a label
    s.close_sz = L.icon_target.size + L.icon_target.pad * 2   -- Close is destructive: the 24 px minimum target (WCAG 2.5.8)
    s.brand_sz = L.row_h
    s.row_h = math.max(L.row_h, s.brand_sz, s.close_sz, s.frame_h)

    s.key_w = Theme.calc_combo_width(ctx, COMBO_LABELS.keys)
    -- Width of the Key list: Theme.selectable draws its text itself, so the popup only grows to fit if the
    -- rows are given the width of the longest name ("C# / Db") plus the text padding on both sides
    s.key_list_w = math.max(s.key_w, hdr_max_text_w(COMBO_LABELS.key_names) + L.sm * 2)
    s.scale_w = Theme.calc_combo_width(ctx, COMBO_LABELS.scales)
    s.more_w = math.max(hdr_text_w(HDR_ELLIPSIS), hdr_text_w(HDR_PROGRESS_LONGEST)) + s.pad_x
    s.no_target_w = hdr_text_w(HDR_NO_TARGET_TEXT) + s.pad_x  -- the badge never plans narrower than this
    s.badge_min_w = hdr_text_w(HDR_ELLIPSIS) + s.pad_x
    -- More, Panel, Close: the real gaps between them (see hdr_draw_right)
    s.right_w = s.more_w + L.sm + s.close_sz + L.lg + s.close_sz
    -- The Values, Timing row and Note action units (see TOP BAR CONTROLS): s.bar.unit_w[id]
    s.bar = K.bar_measure(ctx)
    return s
  end

  --- `text` shortened with a trailing ellipsis to at most max_w wide (cached: the top bar runs every frame).
  hdr_fit_text = function(text, max_w)
    if hdr_text_w(text) <= max_w then return text end
    local key = text .. "\0" .. tostring(math.floor(max_w))
    local hit = hdr_fit_cache[key]
    if hit then return hit end
    local n = utf8.len(text)
    local by_char = (n ~= nil)
    if not by_char then n = #text end
    local result = HDR_ELLIPSIS
    for k = n - 1, 1, -1 do
      local head = by_char and text:sub(1, utf8.offset(text, k + 1) - 1) or text:sub(1, k)
      local candidate = (head:gsub("%s+$", "")) .. HDR_ELLIPSIS
      if hdr_text_w(candidate) <= max_w then
        result = candidate
        break
      end
    end
    if hdr_fit_cache_n >= 64 then
      hdr_fit_cache = {}
      hdr_fit_cache_n = 0
    end
    hdr_fit_cache[key] = result
    hdr_fit_cache_n = hdr_fit_cache_n + 1
    return result
  end

  --- Gap placed before the unit `id` when it follows `prev` on the same row: a group break (with a separator
  --- line in it) where the group changes, the standard gap inside the Clip group, tight everywhere else.
  local function hdr_gap_before(prev, id)
    local L = Theme.layout
    if HDR_GROUP[prev] ~= HDR_GROUP[id] then return L.xl end
    if HDR_GROUP[id] == "clip" then return L.md end
    return L.sm
  end

  local function hdr_element_w(id, s, badge_w)
    if id == "brand" then return s.brand_sz end
    if id == "badge" then return badge_w end
    if id == "key" then return s.key_w end
    if id == "scale" then return s.scale_w end
    return s.bar.unit_w[id] or 0
  end

  local function hdr_row_w(row, s, badge_w)
    local w = 0
    for i, id in ipairs(row) do
      if i > 1 then w = w + hdr_gap_before(row[i - 1], id) end
      w = w + hdr_element_w(id, s, badge_w)
    end
    return w
  end

  --- First plan whose rows all fit in avail_w (row 1 also holds the right group). The badge is planned at
  --- its floor and then takes whatever its row has left. Returns the plan and the badge width.
  local function hdr_choose_plan(s, avail_w, badge_natural_w)
    local L = Theme.layout
    local chosen, badge_room = HDR_PLANS[#HDR_PLANS], 0
    for pi, plan in ipairs(HDR_PLANS) do
      local fits, room = true, 0
      for r, row in ipairs(plan.rows) do
        local reserved = (r == 1) and (L.xl + s.right_w) or 0
        local left = avail_w - hdr_row_w(row, s, 0) - reserved
        if r == plan.badge_row then
          room = left
          if left < s.no_target_w then fits = false end
        elseif left < 0 then
          fits = false
        end
      end
      if fits or pi == #HDR_PLANS then
        chosen, badge_room = plan, room
        if fits then break end
      end
    end
    return chosen, math.min(badge_natural_w, math.max(badge_room, s.badge_min_w))
  end

  --- Content width a plan needs to be chosen: its widest row, the badge at its floor, row 1 with the right group.
  local function hdr_plan_w(plan, s)
    local L = Theme.layout
    local w = 0
    for r, row in ipairs(plan.rows) do
      w = math.max(w, hdr_row_w(row, s, s.no_target_w) + ((r == 1) and (L.xl + s.right_w) or 0))
    end
    return w
  end

  --- How many values of the Timing row fit side by side in avail_w: all four, two, or one.
  local function hdr_timing_per_row(s, avail_w)
    local L = Theme.layout
    local n = #HDR_TIMING
    if hdr_row_w(HDR_TIMING, s, 0) <= avail_w then return n end
    local pair_w = 0
    for i = 1, n, 2 do
      local w = hdr_element_w(HDR_TIMING[i], s, 0)
      if HDR_TIMING[i + 1] then w = w + L.sm + hdr_element_w(HDR_TIMING[i + 1], s, 0) end
      pair_w = math.max(pair_w, w)
    end
    return (pair_w <= avail_w) and 2 or 1
  end

  --- Content width the narrowest floating window keeps (the last plan). With `full`: the width a first-use
  --- window opens with (two rows). The second value is the number of rows the bar then has, the Timing row's
  --- own rows included while it is open.
  hdr_min_content_w = function(s, full)
    local plan = full and HDR_FIRST_USE_PLAN or HDR_PLANS[#HDR_PLANS]
    local w = hdr_plan_w(plan, s)
    -- Rows: what the bar drew last frame at the window's real width (s.rows_now), so a wide window may be as
    -- short as its bar allows; before the first frame, the plan's own count
    local rows = (not full) and s.rows_now or nil
    if not rows then
      rows = #plan.rows
      if state.timing_open then rows = rows + math.ceil(#HDR_TIMING / hdr_timing_per_row(s, w)) end
    end
    return w, rows
  end

  --- The pitch algorithm line of the item badge tooltip: the algorithm the item uses now, and who chose it
  --- (this script writes it with every apply unless "Keep each item's own pitch algorithm" is on).
  local function hdr_pitch_algorithm_line(take)
    local mode = take and reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    local name = "Unknown"
    for _, entry in ipairs(PITCHMODE_FLAT) do
      if entry.value == mode then name = entry.name; break end
    end
    local by_script = not state.keep_pitch_mode and script_set_pitch_mode(take)
    return string.format("Pitch algorithm: %s %s", name, by_script and "(set by Fancy Pitch Correct)" or "(your own setting)")
  end

  local function hdr_draw_target_badge(hs)
    local P, s = hs.P, hs.s
    if hs.has_target then
      local track_col = get_target_track_color(hs.target_take, hs.target_item)
      local badge_bg = track_col or (hs.has_notes and P.well or Theme.with_alpha(P.yellow, 0.25))   -- analysed: a quiet tag
      Theme.badge(ctx, hdr_fit_text(state.target_take_name, hs.badge_w - s.pad_x), {
        id = "target",
        bg = badge_bg,
        text_color = Theme.label_on(badge_bg),
        w = hs.badge_w,
      })
      -- The tooltip is built on hover only: it reads the item's pitch algorithm from REAPER
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, string.format("Active item: %s\nStatus: %s\n%s\nSelect any audio item in REAPER to switch to it.",
          state.target_take_name, hs.has_notes and "Analyzed & Active" or "Ready to Analyze",
          hdr_pitch_algorithm_line(hs.target_take)))
      end
    else
      Theme.badge(ctx, hdr_fit_text(HDR_NO_TARGET_TEXT, hs.badge_w - s.pad_x), {
        id = "target",
        bg = P.card,
        text_color = P.text,
        w = hs.badge_w,
        tooltip = state.selection_issue or "Select an audio item in REAPER to pitch-correct.",
      })
    end
  end

  local function hdr_draw_key(hs)
    local P, s = hs.P, hs.s
    -- Previews the short name ("C#") but lists the full one ("C# / Db"), so it stays a plain BeginCombo.
    -- Its preview takes the button face, like Scale's Theme.combo; popped before the list draws.
    reaper.ImGui_SetNextItemWidth(ctx, s.key_w)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        P.btn)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), P.btn_h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  P.btn_a)
    local key_open = reaper.ImGui_BeginCombo(ctx, "##key_selector", SCALE_KEYS[state.key_idx].display)
    reaper.ImGui_PopStyleColor(ctx, 3)
    if key_open then
      for i, k_info in ipairs(SCALE_KEYS) do
        local is_sel = (state.key_idx == i)
        if Theme.selectable(ctx, k_info.name .. "##key_" .. i, is_sel, nil, s.key_list_w) and not is_sel then
          state.key_idx = i
          update_scale_pitch_classes()
          save_current_scale_settings()
        end
        if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "Key: the root note of the scale")
    end
  end

  local function hdr_draw_scale(hs)
    local s = hs.s
    local new_idx, changed = Theme.combo(ctx, "##scale_selector", SCALE_DEFINITIONS, state.scale_idx, {
      w = s.scale_w,
      tooltip = "Scale: marks the in-scale rows on the canvas and sets the scale Quantize (Q) snaps to",
    })
    if changed and new_idx ~= state.scale_idx then
      state.scale_idx = new_idx
      update_scale_pitch_classes()
      save_current_scale_settings()
    end
  end

  --- The Layers submenu of More: each layer shows how it looks on the canvas, a swatch from the same canvas
  --- tokens and shape, before its label (the labels carry no colour word).
  local function hdr_draw_layers(hs)
    local P, L = hs.P, Theme.layout
    local LC = P.canvas
    local sw_w, sw_h = L.xl, reaper.ImGui_GetFrameHeight(ctx)
    local function layer_checkbox(label, key, draw_swatch)
      reaper.ImGui_Dummy(ctx, sw_w, sw_h)
      local sx, sy = reaper.ImGui_GetItemRectMin(ctx)
      draw_swatch(reaper.ImGui_GetWindowDrawList(ctx), sx, sy + sw_h * 0.5)
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      K.layer_checkbox(label, key)
    end
    layer_checkbox("Note Blocks", "show_note_blocks", function(dl, x, cy)
      reaper.ImGui_DrawList_AddRectFilled(dl, x, cy - L.sm, x + sw_w, cy + L.sm, LC.note_fill)
      reaper.ImGui_DrawList_AddRect(dl, x, cy - L.sm, x + sw_w, cy + L.sm, LC.note_border)
    end)
    layer_checkbox("Pitch Trace", "show_raw_pitch", function(dl, x, cy)
      reaper.ImGui_DrawList_AddLine(dl, x, cy, x + sw_w, cy, LC.trace, 2.0)
    end)
    layer_checkbox("Preview Curve", "show_preview", function(dl, x, cy)
      reaper.ImGui_DrawList_AddLine(dl, x, cy, x + sw_w, cy, LC.preview, 2.0)
    end)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "The pitch after correction. Hover or drag a setting to see where it acts.")
    end
    layer_checkbox("Pitch Points", "show_smart_spots", function(dl, x, cy)
      reaper.ImGui_DrawList_AddCircleFilled(dl, x + sw_w * 0.5, cy, K.SPOT_R, LC.spot)
    end)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "The points on a note that bend its pitch: peaks and valleys, the note's start and end, and points you add")
    end
  end

  --- "…" (More) and its popup: Analyze / Re-Analyze and Reset (with the reason beside a disabled one), then
  --- Layers, Settings and Help. While analysing the button reads the progress ("42%") and the popup offers
  --- Cancel in place of Analyze (Esc is not bound to Cancel: on a floating window Esc closes the window, which
  --- cancels too).
  local function hdr_draw_more(hs)
    local s = hs.s
    local analyzing = state.is_analyzing
    local pct = math.floor(state.progress * 100)
    if reaper.ImGui_Button(ctx, (analyzing and string.format("%d%%", pct) or HDR_ELLIPSIS) .. "###hdr_more", s.more_w, 0) then
      reaper.ImGui_OpenPopup(ctx, "##hdr_more_popup")
    end
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, analyzing and "Analyzing. Open to cancel" or HDR_MORE_TIP)
    end
    if reaper.ImGui_BeginPopup(ctx, "##hdr_more_popup") then
      -- HC5: Esc closes this popup (innermost); the window-level handler ignores Esc while a popup is open
      if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
      if analyzing then
        if reaper.ImGui_MenuItem(ctx, string.format(K.CANCEL_FMT, pct) .. "###more_analyze") then
          K.cancel_analysis()
        end
      elseif reaper.ImGui_MenuItem(ctx, hs.analyze_label .. "###more_analyze",
          (not hs.has_target) and HDR_REASON_NO_TARGET or nil, false, hs.has_target) then
        request_analyze()
      end
      if reaper.ImGui_MenuItem(ctx, hs.reset_label .. "###more_reset",
          (not hs.has_notes) and HDR_REASON_NO_NOTES or nil, false, hs.has_notes) then
        request_reset(hs.reset_sel_n, hs.reset_note_n)
      end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_BeginMenu(ctx, "Layers") then
        hdr_draw_layers(hs)
        reaper.ImGui_EndMenu(ctx)
      end
      if reaper.ImGui_MenuItem(ctx, "Note Tone", nil, state.note_tone) then
        state.note_tone = not state.note_tone
        state.tone_failed = false
        K.save_settings("tone")
      end
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(ctx, "Play a tone at the note's pitch while you drag it")
      end
      if reaper.ImGui_MenuItem(ctx, "Settings") then
        App.show_settings_modal = true
      end
      if reaper.ImGui_MenuItem(ctx, "Keyboard Shortcuts & Help") then
        App.show_info_modal = true
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  --- More and Close, right-aligned on the current row. Returns true when Close was clicked.
  local function hdr_draw_right(hs)
    local L, s = Theme.layout, hs.s
    reaper.ImGui_SameLine(ctx, 0, 0)
    -- Never start left of the previous element plus a group gap, however narrow the row is
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx) - hs.margin
    Theme.right_align(ctx, math.min(s.right_w, math.max(0, avail_w - L.xl)), hs.margin)

    hdr_draw_more(hs)

    -- The side panel's switch: lit while the panel shows, dim while the window has no room for it
    reaper.ImGui_SameLine(ctx, 0, L.sm)
    Theme.align(ctx, nil, s.close_sz)
    local panel_shown = state.sidebar_open and state.sidebar_fits
    if Theme.icon_btn(ctx, "##hdr_panel", Theme.icons.panel_right, {
      preset = L.icon_target,
      icon_size = L.icon_md.size,
      w = s.close_sz, h = s.close_sz,
      color = panel_shown and hs.P.accent or (state.sidebar_fits and hs.P.text or hs.P.text_dim),
      tooltip = panel_shown and BODY.panel_tip_hide
        or (state.sidebar_fits and string.format(BODY.panel_tip_show, #state.session_order) or BODY.panel_tip_narrow),
    }) then
      K.toggle_sidebar()
    end

    -- The destructive Close sits a group gap away. An icon shorter than the frame is centred on the row's
    -- framed widgets.
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    Theme.align(ctx, nil, s.close_sz)
    return Theme.icon_btn(ctx, "##hdr_close", Theme.icons.close, {
      preset = L.icon_target,
      icon_size = L.icon_md.size,   -- the glyph of the medium icons; only the click target is 24 px
      w = s.close_sz, h = s.close_sz,   -- icon_btn sizes the button from icon_size unless told otherwise
      tooltip = hs.docked and "Close. Your corrections stay on the items" or "Close (Esc). Your corrections stay on the items",
    })
  end

  --- Draws the top bar. `right_margin` is the room kept free at the right end of every row (the window has no
  --- padding of its own). Returns true when Close was clicked.
  draw_header = function(P, docked, has_target, has_notes, target_take, target_item, right_margin)
    local L = Theme.layout
    local s = App.hdr_static
    right_margin = right_margin or 0
    -- Real booleans: a nil reaching MenuItem's `enabled` would mean "enabled"
    has_target = has_target and true or false
    has_notes = has_notes and true or false
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx) - right_margin

    local badge_text = has_target and state.target_take_name or HDR_NO_TARGET_TEXT
    local plan, badge_w = hdr_choose_plan(s, avail_w, hdr_text_w(badge_text) + s.pad_x)

    local reset_sel_n = has_notes and count_selected_notes() or 0
    local reset_note_n = has_notes and #state.notes or 0
    local reset_label = "Reset"
    if reset_sel_n > 0 then
      reset_label = string.format("Reset selected (%d)", reset_sel_n)
    elseif reset_note_n > 0 then
      reset_label = string.format("Reset %d %s", reset_note_n, plural(reset_note_n, "note", "notes"))
    end

    local hs = {
      P = P, s = s, docked = docked, badge_w = badge_w, margin = right_margin,
      has_target = has_target, has_notes = has_notes, target_take = target_take, target_item = target_item,
      analyze_label = has_notes and "Re-Analyze" or "Analyze",
      reset_label = reset_label, reset_sel_n = reset_sel_n, reset_note_n = reset_note_n,
    }
    -- The Values, Timing row and Note action units draw themselves (see TOP BAR CONTROLS)
    local draw_unit = K.bar_frame(ctx, has_target, target_item, s.bar)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

    local close_clicked = false
    for r, row in ipairs(plan.rows) do
      for i, id in ipairs(row) do
        if i > 1 then
          local gap = hdr_gap_before(row[i - 1], id)
          reaper.ImGui_SameLine(ctx, 0, gap)
          if HDR_GROUP[row[i - 1]] ~= HDR_GROUP[id] then
            -- A hairline in the middle of the group break
            local sep_x, sep_y = reaper.ImGui_GetCursorScreenPos(ctx)
            sep_x = sep_x - math.floor(gap * 0.5)
            reaper.ImGui_DrawList_AddLine(draw_list, sep_x, sep_y + L.xs, sep_x, sep_y + s.frame_h - L.xs, P.border)
          end
        end
        if id == "brand" then
          Theme.brand_icon(ctx, s.brand_sz, s.row_h)
        elseif id == "badge" then
          hdr_draw_target_badge(hs)
        elseif id == "key" then
          hdr_draw_key(hs)
        elseif id == "scale" then
          hdr_draw_scale(hs)
        else
          draw_unit(id)
        end
      end
      if r == 1 then close_clicked = hdr_draw_right(hs) end
    end
    -- The Timing row: the last row(s) of the bar while it is open, as many values per row as the width holds
    s.rows_now = #plan.rows
    if state.timing_open then
      local per_row = hdr_timing_per_row(s, avail_w)
      local timing_rows = math.ceil(#HDR_TIMING / per_row)
      s.rows_now = s.rows_now + timing_rows
      -- The row is a secondary bar: a recessed band across the whole window (the side panel's surface) with its
      -- values, when they fit on one line, starting under the button that opened it (never past the bar's end)
      local row_x, row_y = reaper.ImGui_GetCursorScreenPos(ctx)
      local _, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
      local indent = 0
      if timing_rows == 1 then
        local tray_w = hdr_row_w(HDR_TIMING, s, 0)
        indent = math.max(0, math.min((K.timing_btn_x or row_x) - row_x, avail_w - tray_w))
      end
      local win_x = reaper.ImGui_GetWindowPos(ctx)
      local win_w = reaper.ImGui_GetWindowSize(ctx)
      reaper.ImGui_DrawList_PushClipRect(draw_list, win_x, row_y - L.xs, win_x + win_w, row_y + 1e4, false)
      reaper.ImGui_DrawList_AddRectFilled(draw_list,
        win_x, row_y - L.xs,
        win_x + win_w, row_y + timing_rows * s.frame_h + timing_rows * (spacing_y or 0),   -- down to the body: no gap
        P.inset)
      reaper.ImGui_DrawList_PopClipRect(draw_list)
      for i, id in ipairs(HDR_TIMING) do
        if (i - 1) % per_row ~= 0 then
          reaper.ImGui_SameLine(ctx, 0, L.sm)
        elseif indent > 0 then
          reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + indent)
        end
        draw_unit(id)
      end
    end
    return close_clicked
  end
end

-------------------------------------------------------------------------------
-- TOP BAR CONTROLS
-------------------------------------------------------------------------------
-- The units of the Values group, the Timing row and the Note action group, drawn in every state (disabled, with
-- the reason, when there is nothing to act on): the selection pill, one value control per entry of BAR_VALUES
-- (a drag with its text inside and a range fill under it), the Timing toggle, and the actions (Snap, Quantize,
-- Split, Merge). A value control edits what the pill names: the selected notes, else the item's own value, else
-- the default.
-- K.bar_measure gives their widths, each from its longest label, so a value, an override mark or a selection
-- never changes the layout; K.bar_frame returns the function that draws one unit this frame. The top bar
-- (above) decides where they go. The status line that used to sit beside them is a pill on the canvas
-- (K.canvas_status).

do
  -- Appended to a value that is not the default: an item's own value, or a selected note's own value
  local BAR_OVERRIDE_MARK = "*"
  -- Shown in place of a value that does not exist for what is selected
  local BAR_NO_VALUE = "\xE2\x80\x93"
  local BAR_RANGE_SEP = "\xE2\x80\x93"   -- between the lowest and highest value of a mixed selection
  -- The selection pill: what a drag in the bar changes
  local BAR_PILL_NONE, BAR_PILL_ONE, BAR_PILL_MANY = "Defaults", "1 note", "%d notes"
  local BAR_PILL_TIP_NONE = "Nothing is selected: the values here are the defaults. Select notes to change only those notes."
  local BAR_PILL_TIP_NOTES = "The values here belong to the selected notes. Press Esc to go back to the defaults."
  -- The Timing toggle; %s is the mark when a value of the closed row is not the default. A triangle (half size
  -- BAR_TIMING_ICON_HS) is drawn after the label; the gap and the icon's width are reserved in the button's width.
  local BAR_TIMING_FMT = "Timing%s"
  local BAR_TIMING_ICON_HS = 4
  local BAR_TIMING_ICON_GAP = Theme.layout.sm
  local BAR_TIMING_ICON_W = math.ceil(BAR_TIMING_ICON_HS * 1.4)
  local BAR_TIMING_TIP_OPEN = "Show Transition, Onset Ramp, Scoop Shape and Legato Gap"
  local BAR_TIMING_TIP_CLOSE = "Hide the timing values"
  -- Why the controls are disabled (the tooltips say it; the canvas pill carries the state)
  local BAR_REASON_ANALYZING = "Wait for the analysis to finish"
  local BAR_REASON_NO_TARGET = "Select an audio item"
  local BAR_REASON_NOT_ANALYZED = "Analyze an item first"
  local BAR_REASON_NEEDS_NOTES = string.format("Select notes to change it (%s+A selects all)", K.MOD_LABEL)
  local BAR_REASON_PER_ITEM = "Set per item: press Esc to deselect, then change it"
  local BAR_HINT_SELECT_NOTE = "Select a note to edit it"
  local BAR_HINT_OUTDATED = "Outdated: this item's envelope is from other settings. Edit a note to rewrite it."
  -- What a drag changes, by its target (a line of every value tooltip), and the gestures
  local BAR_SCOPE_DEFAULT = "Changes the default for every item without its own value."
  local BAR_SCOPE_ITEM = "Changes this item's own value (" .. BAR_OVERRIDE_MARK .. ")."
  local BAR_SCOPE_NOTE = "Changes the selected note."
  local BAR_SCOPE_NOTES = "Changes the %d selected notes; each keeps its difference from the others."
  local BAR_GESTURES = string.format("Drag to change (%s-drag: fine). Double-click: reset. %s-click: type a value. Right-click: more.",
    K.MOD_LABEL, K.MOD_LABEL)
  local BAR_TOLERANCE_IDLE = "Used once Tighten is above 0%."

  -- The values of the bar, in the order they are shown. key = the model's key; label = the name on the control;
  -- lo / hi / num / unit = the range and the text in display units (scale x the stored value); levels = where the
  -- value exists: "all" (default, item, note), "note" (notes only) or "item" (default and item only); timing = it
  -- sits on the Timing row; zero_nil = 0 is stored as "no value"; tip = what the value does to the sound.
  local BAR_VALUES = {
    { id = "tight", key = "tighten", label = "Tighten", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "note", zero_nil = true,
      tip = "Tighten: steadies a wobbly note. Low values take out slow drift, higher values also take out wobble and then vibrato; 100% is a flat line." },
    { id = "strength", key = "retune_speed", label = "Strength", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "all",
      tip = "Correction Strength: how far each note is pulled to its target pitch. 0% leaves the singing as recorded, 100% puts the note fully in tune." },
    { id = "tol", key = "tolerance", label = "Tolerance", lo = K.LIMITS.tolerance[1], hi = K.LIMITS.tolerance[2], scale = 1,
      num = "%.0f", unit = "\xC2\xA2", levels = "all",
      tip = "Tolerance: how far a tightened note may wander from its centre before Tighten pulls it in. Higher values keep more natural movement." },
    { id = "trans", key = "transition_ms", label = "Transition", lo = 5, hi = 60, scale = 1, num = "%.0f", unit = "ms",
      levels = "all", timing = true,
      tip = "Transition: how long the glide from one note to the next takes. Short sounds tight and robotic, long sounds smooth and natural." },
    { id = "ramp", key = "onset_ramp_ms", label = "Onset Ramp", lo = 5, hi = 60, scale = 1, num = "%.0f", unit = "ms",
      levels = "all", timing = true,
      tip = "Onset Ramp: how quickly correction comes in at the start of a note. Short corrects the attack at once, long lets the singer's attack through first." },
    { id = "scoop", key = "scoop_shape", label = "Scoop Shape", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "note", timing = true,
      tip = "Scoop Shape: how much of the slide into the note is corrected. 0% keeps the slide as sung, 100% removes it." },
    { id = "legato", key = "legato_threshold_ms", label = "Legato Gap", lo = 50, hi = 300, scale = 1, num = "%.0f", unit = "ms",
      levels = "item", timing = true,
      tip = "Legato Gap: notes closer together than this are joined with a glide instead of treated as separate notes." },
  }
  -- Actions: same commands as the keys
  local BAR_ACTIONS = {
    { id = "snap",     label = "Snap",     tip = "Snap to nearest semitone (S)" },
    { id = "quantize", label = "Quantize", tip = "Quantize to the active scale (Q)" },
    { id = "split",    label = "Split",    tip = "Split at the edit cursor (X)" },
    { id = "merge",    label = "Merge",    tip = "Merge the selected notes (M)" },
  }
  local BAR_VALUE_BY_ID, BAR_ACTION_BY_ID = {}, {}
  for _, spec in ipairs(BAR_VALUES) do BAR_VALUE_BY_ID[spec.id] = spec end
  for _, spec in ipairs(BAR_ACTIONS) do BAR_ACTION_BY_ID[spec.id] = spec end

  local function bar_text_w(bctx, text)
    return (reaper.ImGui_CalcTextSize(bctx, text)) or 0
  end

  --- Widths that depend only on the font and the tokens: every label is measured at its longest, so a value,
  --- an override mark or a selection never changes the layout. unit_w[id] is the width of the unit `id`.
  K.bar_measure = function(bctx)
    local L = Theme.layout
    local s = { unit_w = {} }
    s.frame_h = reaper.ImGui_GetFrameHeight(bctx) or 0
    s.pad_x = L.md * 2                  -- FramePadding.x on both sides of a label (what Theme.badge and Button use)
    local mark_w = bar_text_w(bctx, " " .. BAR_OVERRIDE_MARK)
    for _, spec in ipairs(BAR_VALUES) do
      local hi_t = string.format(spec.num, spec.hi)
      local widest = math.max(
        bar_text_w(bctx, spec.label .. " " .. hi_t .. spec.unit),
        bar_text_w(bctx, spec.label .. " " .. hi_t .. BAR_RANGE_SEP .. hi_t .. spec.unit),
        bar_text_w(bctx, spec.label .. " " .. BAR_NO_VALUE))
      s.unit_w[spec.id] = widest + mark_w + s.pad_x
    end
    s.unit_w.pill = math.max(bar_text_w(bctx, BAR_PILL_NONE), bar_text_w(bctx, BAR_PILL_ONE),
      bar_text_w(bctx, string.format(BAR_PILL_MANY, 999))) + s.pad_x
    s.unit_w.timing = bar_text_w(bctx, string.format(BAR_TIMING_FMT, " " .. BAR_OVERRIDE_MARK))
      + BAR_TIMING_ICON_GAP + BAR_TIMING_ICON_W + s.pad_x
    for _, spec in ipairs(BAR_ACTIONS) do
      s.unit_w[spec.id] = bar_text_w(bctx, spec.label) + s.pad_x
    end
    return s
  end

  --- Flag the other session items whose stored envelope was written with the old global default of `key`:
  --- those without an item value for it and with an edited note that inherits it (an untouched item has no
  --- envelope to go stale). Returns how many were flagged.
  local function mark_stale_takes(key)
    local n = 0
    for _, guid in ipairs(state.session_order) do
      local data = state.session_takes[guid]
      if guid ~= state.target_take_guid and data
         and not (data.overrides and data.overrides[key] ~= nil) then
        for _, note in ipairs(data.notes or {}) do
          local own = key ~= "legato_threshold_ms" and note.controls and note.controls[key] ~= nil
          if is_note_modified(note) and not own then
            state.stale_takes[guid] = true
            n = n + 1
            break
          end
        end
      end
    end
    K.queue_stale_checks()   -- the envelopes are compared next: a value put back to what an item was written with clears its mark
    return n
  end

  --- Status text of a global default change / reset: it is saved outside the undo history, and the other
  --- items keep the envelope they have until they are edited.
  local function global_change_status(prefix, stale_n)
    if stale_n <= 0 then return prefix end
    if stale_n == 1 then
      return prefix .. ". 1 other item keeps its old envelope until edited."
    end
    return string.format("%s. %d other items keep their old envelope until edited.", prefix, stale_n)
  end

  --- The selected notes that hold values, in one reused table (no table per frame), and how many.
  local bar_sel = {}
  -- The press now held on a value control: what it was aimed at when it began (see draw_value)
  local bar_gesture = { id = nil, target = nil, notes = nil, dead = false }
  local function bar_sel_notes()
    local n = 0
    if state.notes then
      for idx in pairs(state.selected_notes) do
        local note = state.notes[idx]
        if note and note.controls then n = n + 1; bar_sel[n] = note end
      end
      if n == 0 and state.selected_note then
        local note = state.notes[state.selected_note]
        if note and note.controls then n = 1; bar_sel[1] = note end
      end
    end
    for i = #bar_sel, n + 1, -1 do bar_sel[i] = nil end
    return bar_sel, n
  end

  --- The value of `spec` in effect on `note`, in display units.
  local function bar_note_value(note, spec)
    return (tonumber(get_effective(note, spec.key)) or DEFAULTS[spec.key] or 0) * spec.scale
  end

  --- Give `note` its own value of `spec` (display units, clamped to the range).
  local function bar_note_write(note, spec, v)
    v = math.max(spec.lo, math.min(spec.hi, v)) / spec.scale
    if spec.zero_nil and v <= 0 then v = nil end
    note.controls[spec.key] = v
  end

  --- Give every note of a bar drag back what it held when the drag began (false = no own value).
  local function bar_edit_restore(edit, key)
    for note, raw in pairs(edit.raws) do
      if raw == false then note.controls[key] = nil else note.controls[key] = raw end
    end
  end

  --- The range fill of a value control, drawn on the item just submitted: a track along the bottom edge of the
  --- frame and, on it, the part from lo_frac to hi_frac (0..1 of the range) in `color`.
  K.bar_value_fill = function(bctx, lo_frac, hi_frac, color)
    local L = Theme.layout
    local x1, _ = reaper.ImGui_GetItemRectMin(bctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(bctx)
    if not (x1 and x2 and y2) then return end
    local dl = reaper.ImGui_GetWindowDrawList(bctx)
    local w = x2 - x1
    local top = y2 - L.xs
    reaper.ImGui_DrawList_AddRectFilled(dl, x1, top, x2, y2, Theme.get_palette().outline)
    lo_frac = math.max(0, math.min(1, lo_frac))
    hi_frac = math.max(lo_frac, math.min(1, hi_frac))
    local fx1, fx2 = x1 + w * lo_frac, x1 + w * hi_frac
    if lo_frac > 0 and fx2 - fx1 < L.xs then   -- a mixed range too narrow to see: keep a visible mark
      fx1 = math.max(x1, fx2 - L.xs)
    end
    if fx2 > fx1 then reaper.ImGui_DrawList_AddRectFilled(dl, fx1, top, fx2, y2, color) end
  end

  --- How many notes are selected, and the index of one of them (the note itself when exactly one is).
  local function bar_selection()
    local sel_count, sel_idx = 0, nil
    if state.notes then
      for idx in pairs(state.selected_notes) do
        if state.notes[idx] then sel_count = sel_count + 1; sel_idx = idx end
      end
      if sel_count == 0 and state.selected_note and state.notes[state.selected_note] then
        sel_count, sel_idx = 1, state.selected_note
      end
    end
    return sel_count, sel_idx
  end

  --- The status line: a status message (set_status) while it lasts, else what the window is doing or waiting
  --- for; "" when there is nothing to say. `editing` = notes are on the canvas and can be edited (an empty
  --- canvas carries its own centred message, and a bypassed one its badge, so neither adds a hint).
  K.status_line = function(editing)
    if state.status.text ~= "" and reaper.time_precise() < state.status.until_time then
      return state.status.text
    end
    if state.is_analyzing then
      return string.format("Analyzing %s… %d%%", state.target_take_name or "this item", math.floor((state.progress or 0) * 100))
    end
    if not (state.frame.take and state.target_take_name) then
      return state.selection_issue or ""
    end
    if editing then
      if state.hovered_point then return "Drag a point to bend the pitch there" end
      -- The zoom hint is for a pointer that rests (the hit-test that sets it does not run during a gesture), and
      -- the Outdated hint wins over it
      local in_gesture = state.drag or state.edge_drag or state.marquee or state.point_drag or state.view_drag
      if state.points_zoom_hint and not in_gesture then
        local guid = state.target_take_guid
        if guid and state.stale_takes[guid] then return BAR_HINT_OUTDATED end
        return "Zoom in to move pitch points"
      end
      local sel_count = bar_selection()
      if sel_count == 0 then
        local guid = state.target_take_guid
        if guid and state.stale_takes[guid] then return BAR_HINT_OUTDATED end
        return BAR_HINT_SELECT_NOTE, true
      end
      if sel_count > 1 then return string.format("%d notes selected", sel_count), true end
    end
    return ""
  end

  --- Draw the status line on a pill whose bottom-left corner is (x, bottom_y), at most max_w wide (the text is
  --- shortened with an ellipsis). The canvas calls it on every path it leaves by, so a status message shows in
  --- every state. C.pill_text is >= 4.5:1 on the pill over every canvas surface.
  --- An idle hint (the second value of K.status_line) gives way to the notes: it is not drawn while covered(x1, y1,
  --- x2, y2) says a note block lies under the pill. A message always shows.
  K.canvas_status = function(draw_list, x, bottom_y, max_w, editing, covered)
    local text, idle = K.status_line(editing)
    if text == "" then return end
    local L = Theme.layout
    local C = Theme.get_palette().canvas
    local room = max_w - L.sm * 2
    if room <= 0 then return end
    text = hdr_fit_text(text, room)
    local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, text)
    if (text_w or 0) > room then return end   -- not even the ellipsis fits
    local top_y = bottom_y - text_h - L.xs * 2
    if idle and covered and covered(x, top_y, x + text_w + L.sm * 2, bottom_y) then return end
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, top_y, x + text_w + L.sm * 2, bottom_y, C.pill_bg, L.rounding)
    reaper.ImGui_DrawList_AddText(draw_list, x + L.sm, top_y + L.xs, C.pill_text, text)
  end

  --- The units of this frame. `has_target` / `target_item` come from loop_body (the top bar's view of the
  --- target); `s` from K.bar_measure. Returns draw_unit(id) for "pill", "timing", the ids of BAR_VALUES and the
  --- ids of BAR_ACTIONS.
  K.bar_frame = function(bctx, has_target, target_item, s)
    local P = Theme.get_palette()
    if has_target == nil then has_target = (state.target_take_guid ~= nil) end

    local has_data = (#state.results > 0 and state.notes ~= nil and #state.notes > 0)
    local take_data = state.target_take_guid and state.session_takes[state.target_take_guid] or nil

    -- Selection: how many notes, and the note itself when there is exactly one
    local sel_count, sel_idx = bar_selection()
    local single_note = (sel_count == 1) and state.notes[sel_idx] or nil

    -- Why the values and the actions are disabled (nil = usable)
    local inspector_reason = nil
    if state.is_analyzing then
      inspector_reason = BAR_REASON_ANALYZING
    elseif not has_target then
      inspector_reason = BAR_REASON_NO_TARGET
    elseif not has_data then
      inspector_reason = BAR_REASON_NOT_ANALYZED
    end

    -- What the value controls act on: the selected notes that hold values (none = the defaults)
    local sel_notes, sel_n = bar_sel_notes()

    --- What the control of `spec` shows and what a drag on it writes to (worked out once per frame):
    ---   lo_v, hi_v  the value in display units; with several notes, their lowest and highest
    ---   mixed       the selected notes do not all show the same value
    ---   level       "global" (the default), "item" or "note": where the value comes from
    ---   target      "default", "item" or "notes": what a drag changes
    ---   blank       there is no value to show; disabled / reason: the control cannot be used, and why
    local views = {}
    local function bar_view(spec)
      local view = views[spec.id]
      if view then return view end
      local key = spec.key
      view = { lo_v = spec.lo, hi_v = spec.lo, mixed = false, level = "global", target = "default" }
      views[spec.id] = view
      if sel_n > 0 and spec.levels ~= "item" then
        view.target = "notes"
        local lo_v, hi_v = math.huge, -math.huge
        for i = 1, sel_n do
          local note = sel_notes[i]
          local v = bar_note_value(note, spec)
          if v < lo_v then lo_v = v end
          if v > hi_v then hi_v = v end
          if note.controls[key] ~= nil then view.level = "note" end
        end
        if view.level ~= "note" and get_override_level(nil, key) == "item" then view.level = "item" end
        view.lo_v, view.hi_v = lo_v, hi_v
        view.mixed = string.format(spec.num, lo_v) ~= string.format(spec.num, hi_v)
      else
        local v = get_effective(nil, key)
        if v == nil then v = DEFAULTS[key] end
        view.lo_v = (tonumber(v) or 0) * spec.scale
        view.hi_v = view.lo_v
        view.level = (get_override_level(nil, key) == "item") and "item" or "global"
        if view.level == "item" then view.target = "item" end
      end
      if inspector_reason then
        view.disabled, view.reason = true, inspector_reason
        view.blank = not (has_target and has_data)
      elseif spec.levels == "note" and sel_n == 0 then
        view.disabled, view.reason, view.blank = true, BAR_REASON_NEEDS_NOTES, true
      elseif spec.levels == "item" and sel_n > 0 then
        view.disabled, view.reason = true, BAR_REASON_PER_ITEM
      end
      return view
    end

    --- The control's text as a DragDouble format: a real number format when it shows one value (the drag and
    --- the typed entry format with it), literal text otherwise.
    local function value_format(spec, view)
      local unit = spec.unit:gsub("%%", "%%%%")
      if view.blank then return spec.label .. " " .. BAR_NO_VALUE end
      local mark = (view.level ~= "global") and (" " .. BAR_OVERRIDE_MARK) or ""
      if view.mixed then
        return spec.label .. " " .. string.format(spec.num, view.lo_v) .. BAR_RANGE_SEP
          .. string.format(spec.num, view.hi_v) .. unit .. mark
      end
      return spec.label .. " " .. spec.num .. unit .. mark
    end

    --- Write an edited value: to the item override when there is one, else to the global default. The global default is
    --- saved (K.save_settings) when the edit is committed, not on every frame of a drag.
    local function write_cascade_value(key, v)
      if take_data and take_data.overrides and take_data.overrides[key] ~= nil then
        take_data.overrides[key] = v
      else
        global_defaults[key] = v
      end
    end

    --- An edit was committed: when it went to the global default, the other items still hold an envelope
    --- written with the old value; say so (a global default is not part of the undo history).
    local function note_global_edit(key)
      if take_data and take_data.overrides and take_data.overrides[key] ~= nil then return end
      local n = mark_stale_takes(key)
      if n > 0 then set_status(global_change_status("Global default changed (not undoable)", n)) end
    end

    --- Item override on / off (right-click menu): a new override starts at the current global default.
    local function toggle_item_override(key)
      if not take_data then return end
      take_data.overrides = take_data.overrides or {}
      if take_data.overrides[key] ~= nil then
        take_data.overrides[key] = nil
      else
        take_data.overrides[key] = global_defaults[key]
      end
      apply_envelope_to_take("Toggle Item Override: " .. (PARAM_LABELS[key] or key))
    end

    --- Double-click / "Reset to default": an item override goes back to inheriting (one undo point);
    --- otherwise the global default returns to its DEFAULTS value, which is saved and applied to the take
    --- but not part of the undo history.
    local function reset_cascade_param(key)
      local name = PARAM_LABELS[key] or key
      if take_data and take_data.overrides and take_data.overrides[key] ~= nil then
        take_data.overrides[key] = nil
        apply_envelope_to_take("Reset Item Override: " .. name)
      elseif DEFAULTS[key] ~= nil and global_defaults[key] ~= DEFAULTS[key] then
        global_defaults[key] = DEFAULTS[key]
        K.save_settings("cascade")
        if take_data then apply_envelope_to_take("Reset Default: " .. name) end
        set_status(global_change_status("Global default reset (not undoable)", mark_stale_takes(key)))
      end
    end

    --- Right-click menu of a cascade control (call right after the control).
    local function item_override_menu(key)
      if not reaper.ImGui_BeginPopupContextItem(bctx, "##ctx_" .. key) then return end
      -- HC5: Esc closes this menu (innermost)
      if reaper.ImGui_Shortcut(bctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(bctx) end
      local has_override = take_data ~= nil and take_data.overrides ~= nil and take_data.overrides[key] ~= nil
      if reaper.ImGui_MenuItem(bctx, "Override for this item", nil, has_override, take_data ~= nil) then
        toggle_item_override(key)
      end
      if reaper.ImGui_MenuItem(bctx, "Reset to default") then
        reset_cascade_param(key)
      end
      reaper.ImGui_EndPopup(bctx)
    end

    --- Tooltip for the item just drawn, gated on the hover delay. A disabled item passes
    --- HoveredFlags_AllowWhenDisabled as `extra_flags` so its reason still shows.
    local function bar_tooltip(text, extra_flags)
      local flags = reaper.ImGui_HoveredFlags_ForTooltip() | (extra_flags or 0)
      if reaper.ImGui_IsItemHovered(bctx, flags) and not reaper.ImGui_IsItemActive(bctx) then
        Theme.tooltip(bctx, text)
      end
    end

    --- Put the selected notes back to inheriting the value of `spec` (Tighten, Scoop Shape: to 0), as one undo point.
    local function reset_notes(spec)
      state.bar_edit = nil
      local had = false
      for i = 1, sel_n do
        local ctrl = sel_notes[i].controls
        if ctrl[spec.key] ~= nil then
          ctrl[spec.key] = nil
          had = true
        end
      end
      if had then apply_envelope_to_take("Reset " .. (PARAM_LABELS[spec.key] or spec.label)) end
    end

    --- One value of the bar: a drag with its text inside and the range fill under it. It edits what the pill
    --- names: the selected notes (each moves by the same amount from its own value, as a drag on the canvas
    --- does; a typed value sets them all), else the item's own value, else the default.
    local function draw_value(spec)
      local view = bar_view(spec)
      local key, id = spec.key, "bv_" .. spec.id
      local name = PARAM_LABELS[key] or spec.label

      reaper.ImGui_BeginDisabled(bctx, view.disabled == true)
      reaper.ImGui_PushItemWidth(bctx, s.unit_w[spec.id])
      local changed, v, committed, reset, cancelled = param_drag(bctx, id, nil, view.lo_v, spec.lo, spec.hi, value_format(spec, view))
      local back = K.drag_revert(id, view.lo_v / spec.scale, cancelled)
      local hovered, active, typed = K.drag_hot.hovered, K.drag_hot.active, K.drag_hot.typed
      local held, pressed = K.drag_hot.held, K.drag_hot.activated
      reaper.ImGui_PopItemWidth(bctx)
      reaper.ImGui_EndDisabled(bctx)

      -- A press belongs to what it was aimed at. When that changes under it (the notes were reloaded by an undo,
      -- the selection went away, another item became the target), the rest of the gesture does nothing: it must
      -- never turn a drag on notes into a change of the default.
      local gest = bar_gesture
      if pressed then gest.id, gest.target, gest.notes, gest.dead = spec.id, view.target, state.notes, false end
      local dead = false
      if gest.id == spec.id then
        if view.disabled or gest.target ~= view.target or gest.notes ~= state.notes then gest.dead = true end
        dead = gest.dead
        if not held then gest.id = nil end   -- the press is over (this frame still counts as part of it)
      end
      if dead or view.disabled then
        local stale = state.bar_edit
        if stale and stale.id == spec.id then
          if stale.notes == state.notes then bar_edit_restore(stale, key) end
          state.bar_edit = nil
        end
      end

      if view.disabled then
        bar_tooltip(spec.tip .. "\n" .. view.reason, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
        return
      end

      -- The fill says where the value comes from as well (the mark and the tooltip say it without colour)
      local span = spec.hi - spec.lo
      K.bar_value_fill(bctx, view.mixed and (view.lo_v - spec.lo) / span or 0, (view.hi_v - spec.lo) / span,
        (view.level == "note") and P.accent2 or P.accent)

      local scope = BAR_SCOPE_DEFAULT
      if view.target == "notes" then
        scope = (sel_n == 1) and BAR_SCOPE_NOTE or string.format(BAR_SCOPE_NOTES, sel_n)
        if key == "tolerance" then
          local idle = true
          for i = 1, sel_n do
            if (tonumber(sel_notes[i].controls.tighten) or 0) > 0 then idle = false break end
          end
          if idle then scope = BAR_TOLERANCE_IDLE .. "\n" .. scope end
        end
      elseif view.target == "item" then
        scope = BAR_SCOPE_ITEM
      end
      bar_tooltip(spec.tip .. "\n" .. scope .. "\n" .. BAR_GESTURES)
      if dead then return end

      if hovered or active then
        -- The canvas shades where the value acts: on the selected notes, or wherever the default reaches
        local set = nil
        if view.target == "notes" then
          set = state.setting_hint.menu_set
          for k in pairs(set) do set[k] = nil end
          for idx in pairs(state.selected_notes) do set[idx] = true end
          if state.selected_note then set[state.selected_note] = true end
        end
        K.setting_hint(bctx, key, active, set)
      end

      if view.target ~= "notes" then
        item_override_menu(key)
        if back ~= nil then
          write_cascade_value(key, back)   -- Esc during the drag: the value from before it, nothing saved or written
        elseif reset then
          reset_cascade_param(key)
        else
          if changed then write_cascade_value(key, v / spec.scale) end
          if committed then K.save_settings("cascade") end   -- the drag is over: one write, only the key that changed
          if committed and take_data then
            apply_envelope_to_take("Adjust " .. name)
            note_global_edit(key)
          end
        end
        return
      end

      -- Right-click with notes selected: back to what the notes inherit
      if reaper.ImGui_BeginPopupContextItem(bctx, "##ctxn_" .. key) then
        -- HC5: Esc closes this menu (innermost)
        if reaper.ImGui_Shortcut(bctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(bctx) end
        if reaper.ImGui_MenuItem(bctx, (spec.levels == "note") and "Reset to 0%" or "Reset to inherited") then
          reset_notes(spec)
        end
        reaper.ImGui_EndPopup(bctx)
      end

      -- The drag in progress: what each note held (raws; false = no own value) and showed (starts) when it began,
      -- and how far the pointer has moved since, in value units (acc). The pointer is followed here, not through
      -- the value the widget returns: a drag past the end of the range and back then lands where it started. It
      -- is dropped when it belongs to another control or to a note model that has been replaced since.
      local edit = state.bar_edit
      if edit and (edit.id ~= spec.id or edit.notes ~= state.notes) then
        if edit.id == spec.id then state.bar_edit = nil end
        edit = nil
      end
      if cancelled then
        -- Esc during the drag: every note gets back what it held, nothing is written
        if edit then
          bar_edit_restore(edit, key)
          state.bar_edit = nil
        end
      elseif reset then
        reset_notes(spec)
      elseif changed and typed then
        -- A typed value sets every selected note to it
        state.bar_edit = nil
        for i = 1, sel_n do bar_note_write(sel_notes[i], spec, v) end
        apply_envelope_to_take("Adjust " .. name)
      elseif held and reaper.ImGui_IsMouseDragging(bctx, 0) then
        if not edit then
          edit = { id = spec.id, notes = state.notes, acc = 0, raws = {}, starts = {} }
          for i = 1, sel_n do
            local note = sel_notes[i]
            local raw = note.controls[key]
            edit.raws[note] = (raw == nil) and false or raw
            edit.starts[note] = bar_note_value(note, spec)
          end
          state.bar_edit = edit
        end
        local dx = reaper.ImGui_GetMouseDelta(bctx) or 0
        if dx ~= 0 then
          -- HC2: Cmd/Ctrl held (read every frame) = fine adjust; the control's width sweeps the whole range.
          -- acc is not clamped (each note is): however far the pointer goes, coming back undoes it.
          local fine = ((reaper.ImGui_GetKeyMods(bctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
          edit.acc = edit.acc + dx * span / math.max(s.unit_w[spec.id], 1) * (fine and K.FINE_ADJUST_SCALE or 1)
          for note, start in pairs(edit.starts) do bar_note_write(note, spec, start + edit.acc) end
        end
      elseif edit and not held then
        -- Released: one write and one undo point, and only when a note now shows another value than it did
        -- (a drag against the end of the range, or back to where it began, leaves every note what it held)
        state.bar_edit = nil
        local moved = false
        for note, start in pairs(edit.starts) do
          if math.abs(bar_note_value(note, spec) - start) > 1e-9 then moved = true break end
        end
        if moved then
          apply_envelope_to_take("Adjust " .. name)
        else
          bar_edit_restore(edit, key)
        end
      end
    end

    --- The selection pill: what a drag on a value changes.
    local function draw_pill()
      local text = (sel_n == 0) and BAR_PILL_NONE or (sel_n == 1) and BAR_PILL_ONE or string.format(BAR_PILL_MANY, sel_n)
      local fg, bg = P.text, P.well
      if sel_n > 0 then fg, bg = Theme.label_on(P.accent2), P.accent2 end
      Theme.align(bctx)
      Theme.badge(bctx, text, { color = fg, bg = bg, text_color = fg, id = "bar_pill", w = s.unit_w.pill })
      bar_tooltip((sel_n == 0) and BAR_PILL_TIP_NONE or BAR_PILL_TIP_NOTES)
    end

    --- "Timing": opens and closes the Timing row (Transition, Onset Ramp, Scoop Shape, Legato Gap). While the
    --- row is closed, a mark says that one of its values is not the default.
    local function draw_timing()
      local marked = false
      if not state.timing_open then
        for _, spec in ipairs(BAR_VALUES) do
          if spec.timing then
            local view = bar_view(spec)
            if view.level ~= "global" and not view.blank then marked = true end
          end
        end
      end

      -- Label and icon are centred together: the label is aligned so the icon's slot fits to its right
      local label = string.format(BAR_TIMING_FMT, marked and (" " .. BAR_OVERRIDE_MARK) or "")
      local label_w = bar_text_w(bctx, label)
      local slack = s.unit_w.timing - s.pad_x - label_w
      local align_x = slack > 0 and math.max(0, math.min(1, (slack - BAR_TIMING_ICON_GAP - BAR_TIMING_ICON_W) * 0.5 / slack)) or 0.5
      reaper.ImGui_PushStyleVar(bctx, reaper.ImGui_StyleVar_ButtonTextAlign(), align_x, 0.5)
      local pressed = reaper.ImGui_Button(bctx, label .. "###bar_timing", s.unit_w.timing, 0)
      reaper.ImGui_PopStyleVar(bctx)
      do
        local bx1, by1 = reaper.ImGui_GetItemRectMin(bctx)
        local bx2, by2 = reaper.ImGui_GetItemRectMax(bctx)
        K.timing_btn_x = bx1   -- the Timing row starts under its button (see draw_header)
        local text_x = bx1 + s.pad_x * 0.5 + (bx2 - bx1 - s.pad_x - label_w) * align_x
        local icon = state.timing_open and Theme.icons.tri_down or Theme.icons.tri_right
        icon(reaper.ImGui_GetWindowDrawList(bctx),
          text_x + label_w + BAR_TIMING_ICON_GAP + BAR_TIMING_ICON_W * 0.5, (by1 + by2) * 0.5, BAR_TIMING_ICON_HS, P.text)
      end
      bar_tooltip(state.timing_open and BAR_TIMING_TIP_CLOSE or BAR_TIMING_TIP_OPEN)
      if pressed then
        state.timing_open = not state.timing_open
        K.save_settings("bar")
      end
    end

    --- The edit cursor relative to the target item's start (note times are item-relative); nil when unknown
    local function edit_cursor_offset()
      local item = target_item
      if not item then
        local _, target = K.frame_target()
        item = target
      end
      if not item then return nil end
      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local cursor = reaper.GetCursorPosition()
      if not item_pos or not cursor then return nil end
      return cursor - item_pos
    end

    -- Split needs the edit cursor strictly inside the selected note, as the X key does (asked once per frame)
    local cursor_in_note_cache = nil
    local function edit_cursor_in_note(note)
      if cursor_in_note_cache == nil then
        local t = edit_cursor_offset()
        cursor_in_note_cache = (note ~= nil and t ~= nil and t > note.start_time and t < note.end_time)
      end
      return cursor_in_note_cache
    end

    --- Why an action is unavailable (nil = available)
    local function action_reason(id)
      if inspector_reason then return inspector_reason end
      if id == "merge" then
        if sel_count < 2 then return "Select 2 or more notes" end
        return nil
      end
      if sel_count == 0 then return "Select a note" end
      if id == "split" then
        if sel_count > 1 then return "Select one note to split" end
        if not edit_cursor_in_note(single_note) then return "Move the edit cursor into the selected note" end
      end
      return nil
    end

    local function draw_action(spec)
      local reason = action_reason(spec.id)
      reaper.ImGui_BeginDisabled(bctx, reason ~= nil)
      local clicked = reaper.ImGui_Button(bctx, spec.label .. "###bar_" .. spec.id, s.unit_w[spec.id], 0)
      reaper.ImGui_EndDisabled(bctx)
      bar_tooltip(reason and (spec.tip .. "\n" .. reason) or spec.tip,
        reason and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
      if clicked and not reason then K.note_action(spec.id, sel_idx) end
    end

    return function(id)
      if id == "pill" then
        draw_pill()
      elseif id == "timing" then
        draw_timing()
      elseif BAR_VALUE_BY_ID[id] then
        draw_value(BAR_VALUE_BY_ID[id])
      elseif BAR_ACTION_BY_ID[id] then
        draw_action(BAR_ACTION_BY_ID[id])
      end
    end
  end
end

-- What the files loaded after this one use
App.draw_header = draw_header
App.hdr_min_content_w = hdr_min_content_w
App.measure_header_static = measure_header_static
