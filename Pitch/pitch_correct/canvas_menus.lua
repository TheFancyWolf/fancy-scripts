-- @noindex
-- Fancy Pitch Correct: the pitch canvas, the note and pitch point context menus.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme, fonts = App.K, App.state, App.Theme, App.fonts
local apply_envelope_to_take = App.apply_envelope_to_take
local DEFAULTS = App.DEFAULTS
local get_effective = App.get_effective
local get_override_level = App.get_override_level
local is_pitch_in_scale = App.is_pitch_in_scale
local midi_to_name = App.midi_to_name
local param_drag = App.param_drag
local PARAM_LABELS = App.PARAM_LABELS
local plural = App.plural
local reset_selected_note = App.reset_selected_note
local set_status = App.set_status

-- Each function here is one step of draw_graph (canvas.lua) and takes its frame table `cv`: the geometry, the
-- colours, the pointer and the helpers draw_graph worked out for this frame. The view (vt0, vt1, min_note,
-- max_note, note_range, px_per_st) belongs to draw_graph: a step reads it from cv and changes it only through
-- cv.set_view, cv.set_pitch_view and cv.fit_pitch_view.

--- The note context menu.
local function canvas_note_menu(cv)
  local draw_ctx = cv.draw_ctx

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
end

--- The pitch point context menu.
local function canvas_point_menu(cv)
  local draw_ctx = cv.draw_ctx

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
end

-- What the files loaded after this one use
App.canvas_note_menu = canvas_note_menu
App.canvas_point_menu = canvas_point_menu
