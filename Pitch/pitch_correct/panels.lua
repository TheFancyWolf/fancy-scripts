-- @noindex
-- Fancy Pitch Correct: the side panel, the Settings / Info / confirm modals and key forwarding.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state, Theme, ctx, fonts = App.K, App.state, App.Theme, App.ctx, App.fonts
local BLOCK_SIZES = App.BLOCK_SIZES
local COMBO_LABELS = App.COMBO_LABELS
local DEFAULTS = App.DEFAULTS
local DETECTION_MODES = App.DETECTION_MODES
local draw_graph = App.draw_graph
local flush_nudge_burst = App.flush_nudge_burst
local get_target_take = App.get_target_take
local HOP_SIZES = App.HOP_SIZES
local is_note_modified = App.is_note_modified
local is_take_pitch_bypassed = App.is_take_pitch_bypassed
local merge_selected_notes = App.merge_selected_notes
local param_drag = App.param_drag
local PITCHMODE_FLAT = App.PITCHMODE_FLAT
local plural = App.plural
local QUALITY_MODES = App.QUALITY_MODES
local quantize_selected_notes_to_scale = App.quantize_selected_notes_to_scale
local request_clear_confirm = App.request_clear_confirm
local request_confirm = App.request_confirm
local request_remove_confirm = App.request_remove_confirm
local request_wipe_confirm = App.request_wipe_confirm
local reset_selected_note = App.reset_selected_note
local resolve_take_by_guid = App.resolve_take_by_guid
local SCALE_DEFINITIONS = App.SCALE_DEFINITIONS
local SCALE_KEYS = App.SCALE_KEYS
local set_status = App.set_status
local snap_selected_note = App.snap_selected_note
local split_note_at = App.split_note_at
local start_analysis = App.start_analysis
local switch_active_target = App.switch_active_target
local toggle_take_pitch_bypass = App.toggle_take_pitch_bypass
local VOCAL_RANGES = App.VOCAL_RANGES

-- Pitched Items sidebar and body layout. The body is the canvas plus the Pitched Items panel on the right,
-- in one resizable two-column table. When the window is too narrow for both, the panel shows as a 20 px
-- closed-drawer tag (the saved open / closed preference is left alone).

-- One table for the constants and texts of this section (a script chunk holds at most 200 locals).
-- The canvas never gets narrower than min_graph_w and the panel never narrower than min_sidebar_w;
-- splitter_w is the room kept for the grip between them.
local BODY = {
  min_graph_w = 200,
  min_sidebar_w = K.SIDEBAR_MIN_W,
  splitter_w = Theme.layout.sm + Theme.layout.xs,
  -- A fixed-column width within this many pixels of the wanted one counts as equal
  width_eps = 0.5,
  -- The grip is not an item, so it gets no ForTooltip delay of its own: its tooltip waits this long instead
  grip_tip_delay_s = 0.5,
  grip_tip = "Drag to resize Pitched Items",
  panel_tip_show = "Show the side panel: Pitched Items (%d) and Shortcuts",
  panel_tip_hide = "Hide the side panel",
  panel_tip_narrow = "The side panel does not fit this window. Widen the window to show it.",
  panel_narrow_status = "Widen the window to show the side panel",
  shortcuts_narrow_status = "Widen the window to show Shortcuts",
  -- Row states and the checkbox column label (a row is never told apart by colour alone)
  col_on = "On",
  tag_missing = "Item missing",
  tag_outdated = "outdated",
  tip_missing = "The item no longer exists in this project",
  tip_outdated = "This item's envelope is not what the current settings would write (a setting changed after it was written). Edit or re-analyze it to refresh.",
  -- The banner for items whose saved analysis cannot be read (see K.unreadable_guids) and its Clear button
  unreadable_fmt = "%d %s: saved analysis couldn't be read",
  unreadable_clear = "Clear",
  unreadable_tip = "Discard the saved analysis of these items that cannot be read, so they can be analyzed again (asks to confirm)",
  -- Why REAPER's selected item is not a target (state.selection_issue)
  issue_midi = "MIDI item selected: select an audio item",
  issue_no_audio = "Selected item has no audio: select an audio item",
}

--- `text` shortened with a trailing ellipsis to at most max_w wide in the font pushed now (font_tag names
--- that font in the cache key).
local fit_text
do
  local ellipsis = "…"
  local cache, count = {}, 0
  fit_text = function(draw_ctx, text, max_w, font_tag)
    if (reaper.ImGui_CalcTextSize(draw_ctx, text)) <= max_w then return text end
    local key = font_tag .. "\0" .. text .. "\0" .. tostring(math.floor(max_w))
    local hit = cache[key]
    if hit then return hit end
    local n = utf8.len(text)
    local by_char = (n ~= nil)
    if not by_char then n = #text end
    local result = ellipsis
    for k = n - 1, 1, -1 do
      local head = by_char and text:sub(1, utf8.offset(text, k + 1) - 1) or text:sub(1, k)
      local candidate = (head:gsub("%s+$", "")) .. ellipsis
      if (reaper.ImGui_CalcTextSize(draw_ctx, candidate)) <= max_w then
        result = candidate
        break
      end
    end
    if count >= 128 then
      cache, count = {}, 0
    end
    cache[key] = result
    count = count + 1
    return result
  end
end

-- Keyboard Shortcuts & Help content: one entry per section, one { key, description } row each (draw_info_modal measures
-- the columns from these strings). Keep a description near 52 characters so the table stays narrow; the terms follow
-- the UI labels (Pitched Items, item, Correction Strength, Transition, Onset Ramp, Legato Gap, Scoop shape).
-- A row that is also in the panel's Shortcuts list carries panel = { group, order in the group, short text [, short key] }:
-- the list is built from this table (K.panel_rows), so a key is never written in two places.
K.INFO_SECTIONS = {
  { title = "Selection & Navigation", rows = {
    { K.MOD_LABEL .. " + A", "Select all notes in phrase", panel = { "Select", 1, "Select all" } },
    { "Escape", "Close dialog, deselect, close if floating", panel = { "Select", 6, "Deselect", "Esc" } },
    { "Marquee Drag", "Box select notes (Shift=Add)", panel = { "Select", 5, "Box select", "Drag empty" } },
    { "Shift + Click", "Range select notes", panel = { "Select", 3, "Select range" } },
    { K.MOD_LABEL .. " + Click", "Toggle note in/out of selection", panel = { "Select", 4, "Add / remove" } },
    { "← / →", "Select previous / next note (Shift=Extend)", panel = { "Select", 2, "Prev / next note" } },
    { "Click empty canvas", "Deselect, move the REAPER edit cursor" },
    { "Click a Pitched Items row", "Switch the active item" },
    { "Select an audio item in REAPER", "Becomes the active item" },
    { "Drag the divider", "Resize Pitched Items" },
    { "H", "Show / hide the Shortcuts list", panel = { "General", 2, "Hide this list" } },
  } },
  { title = "Pitch & Note Editing", rows = {
    { "Drag Center Zone", string.format("Move note pitch (%s = fine adjust)", K.MOD_LABEL) },
    { "Drag Left Zone", string.format("Tighten: steady the note, slow drift first; 100%% is a flat line (%s = fine)", K.MOD_LABEL),
      panel = { "Edit", 6, "Tighten · Tolerance", "Drag note side" } },
    { "Drag Right Zone", string.format("Tolerance: how far the note may stray from its centre untouched (%s = fine)", K.MOD_LABEL) },
    { "Drag a value in the top bar", string.format("Changes the selected notes, or the defaults when nothing is selected (%s = fine)", K.MOD_LABEL) },
    { "Shift + Drag Left Zone", "Adjust Onset Ramp", panel = { "Edit", 7, "Onset Ramp · Transition · Scoop", "Shift + Drag" } },
    { "Shift + Drag Center Zone", "Adjust Transition" },
    { "Shift + Drag Right Zone", "Adjust Scoop shape" },
    { "Drag Note Edge", "Trim note start / end boundary", panel = { "Edit", 8, "Trim note", "Drag edge" } },
    { "Drag a pitch point", string.format("Bend the pitch at that moment (%s = fine)", K.MOD_LABEL), panel = { "Edit", 9, "Pitch point", "Drag dot" } },
    { "Double-click a pitch point", "Put it back to 0" },
    { "Double-click the pitch line", "Add a pitch point" },
    { "Right-click a pitch point", "Point menu: type a value, Reset, Remove" },
    { "Click the time ruler", "Move the edit cursor (playback follows)" },
    { K.MOD_LABEL .. " + Wheel", "Zoom the timeline", panel = { "View", 3, "Zoom time" } },
    { "Wheel", "Scroll the pitch axis" },
    { "Alt + Wheel", "Zoom the pitch axis", panel = { "View", 5, "Zoom pitch" } },
    { "Shift + Wheel or horizontal scroll", "Scroll the timeline (when zoomed)", panel = { "View", 4, "Scroll time", "Shift + Wheel" } },
    { "Z", "Zoom to the selected notes", panel = { "View", 1, "Zoom to selection" } },
    { "F", "Show the whole item, fit the pitch range", panel = { "View", 2, "Fit whole item" } },
    { "Drag the overview strip", "Scroll; drag an end to zoom" },
    { "Drag the pitch strip", "Scroll; drag an end to zoom" },
    { "↑ / ↓", "Nudge pitch ±1 semitone", panel = { "Edit", 1, "±1 semitone" } },
    { "Shift + ↑ / ↓", "Fine-tune pitch ±10 cents", panel = { "Edit", 2, "±10 cents" } },
    { "S / Double-Click", "Snap note to nearest semitone", panel = { "Edit", 4, "Snap to semitone", "Double-click" } },
    { "Q", "Quantize selected note(s) to scale" },
    { "R / Backspace / Delete", "Reset note(s) to original detected pitch", panel = { "Edit", 3, "Reset pitch", "R" } },
    { "Right-click a note", "Note menu: bypass, overrides, Snap, Quantize, Split, Reset", panel = { "Edit", 5, "Note menu", "Right-click" } },
    { "Right-click a top bar value", "Item override and reset" },
    { "Double-click a value", "Reset to its default" },
    { K.MOD_LABEL .. "-click a value", "Type a number" },
    { "Hover or drag a setting", "Shows on the notes where it acts" },
    { "Snap / Quantize / Split / Merge buttons", "Same as S / Q / X / M" },
  } },
  { title = "Note Topology & REAPER Transport", rows = {
    { "X", "Split note at REAPER edit cursor" },
    { "M", "Merge 2+ contiguous selected notes" },
    { "Space", "Runs your REAPER action for Space (default Play/Stop)", panel = { "General", 1, "Play / stop" } },
    { "Shift / " .. K.MOD_LABEL .. " / Alt + Space", "Your REAPER actions for those chords" },
  } },
  { title = "Icons", rows = {
    { "… (top right)", "More: Analyze, Reset, Layers, Note Tone, Settings, Help" },
    { "× (top right)", "Close the window (Esc when floating)" },
    { "> / <", "Hide / show the Pitched Items panel" },
    { "▾ / ▸ (section header)", "Collapse / expand the section" },
    { "Checkbox (item row)", "Pitch envelope active / bypassed" },
    { "× (item row)", "Remove the item from Pitched Items" },
    { "* after a value", "Set for this item only" },
  } },
}
K.INFO_TERMS = "Reset reverts note edits · Clear discards analysis · Remove drops an item · Wipe removes all"

--- The body of the Pitched Items section: the unreadable-data banner, then the item rows (or the empty text).
K.draw_items_body = function(sidebar_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout

  -- Items whose saved analysis cannot be read are not in the list: say so, with or without any row (P.text_dim, not red:
  -- the project is fine, the stored data of those items is not)
  if next(state.unreadable_takes) ~= nil then
    local n = #K.unreadable_guids()
    if n > 0 then
      reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), P.text_dim)
      reaper.ImGui_TextWrapped(sidebar_ctx, string.format(BODY.unreadable_fmt, n, plural(n, "item", "items")))
      reaper.ImGui_PopStyleColor(sidebar_ctx, 1)
      local clear_w = (reaper.ImGui_CalcTextSize(sidebar_ctx, BODY.unreadable_clear)) + L.md * 2
      if reaper.ImGui_Button(sidebar_ctx, BODY.unreadable_clear .. "###clear_unreadable", clear_w, 0) then
        K.request_clear_unreadable()
      end
      if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(sidebar_ctx, BODY.unreadable_tip)
      end
      reaper.ImGui_Dummy(sidebar_ctx, 0, L.sm)
    end
  end

  if #state.session_order == 0 then
    reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(sidebar_ctx, "No pitched items stored.\n\nSelect an audio item in REAPER and click Analyze.")
    reaper.ImGui_PopStyleColor(sidebar_ctx, 1)
    return
  end

  -- Row geometry: a card as tall as a table row (or a frame, when the font is larger, or the Remove target), L.xs of
  -- air above and below it, and every element centred on the card
  local to_remove = nil
  local avail_w = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(sidebar_ctx)
  local del_sz = L.icon_target.size + L.icon_target.pad * 2   -- Remove is destructive: the 24 px minimum target (WCAG 2.5.8)
  local card_h = math.max(L.row_h, frame_h, del_sz)
  local card_pad_y = L.xs
  local row_h = card_h + card_pad_y * 2
  local card_margin_x = L.sm
  local card_pad_x = L.md
  local gap = L.sm
  local bar_w = L.sm
  local name_min_w = L.xxl

  -- Column label above the bypass checkboxes (the checkbox has no text of its own)
  do
    local pushed = Theme.push_font(sidebar_ctx, fonts.small)
    local label_w = reaper.ImGui_CalcTextSize(sidebar_ctx, BODY.col_on)
    reaper.ImGui_SetCursorPosX(sidebar_ctx, reaper.ImGui_GetCursorPosX(sidebar_ctx)
      + card_margin_x + card_pad_x + math.floor((frame_h - label_w) * 0.5))
    reaper.ImGui_TextColored(sidebar_ctx, P.text_dim, BODY.col_on)
    Theme.pop_font(sidebar_ctx, pushed)
  end

  -- Only the rows in view are drawn, and only those ask REAPER anything: the clipper skips the rest, each of which takes
  -- the height of a row here (its card plus the window's item spacing, since every row ends in a Dummy). The clipper
  -- object lives in state (a script must hold it, or it is garbage-collected) and is made again for another context.
  -- ReaImGui destroys an object that goes a frame unused unless it is attached to its context (the list is empty,
  -- and the clipper idle, whenever nothing is analysed or after an undo). Attach it, and make a new one if a stale
  -- clipper is ever found.
  if not state.clipper or state.clipper_ctx ~= sidebar_ctx
     or not reaper.ImGui_ValidatePtr(state.clipper, "ImGui_ListClipper*") then
    state.clipper = reaper.ImGui_CreateListClipper(sidebar_ctx)
    reaper.ImGui_Attach(sidebar_ctx, state.clipper)
    state.clipper_ctx = sidebar_ctx
  end
  local clipper = state.clipper
  local _, spacing_y = reaper.ImGui_GetStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_ItemSpacing())
  reaper.ImGui_ListClipper_Begin(clipper, #state.session_order, row_h + (spacing_y or 0))
  while reaper.ImGui_ListClipper_Step(clipper) do
    local first_row, end_row = reaper.ImGui_ListClipper_GetDisplayRange(clipper)   -- 0-based, end exclusive
    for index = first_row + 1, end_row do
      local guid = state.session_order[index]
      local data = guid and state.session_takes[guid]
      if data then
        local is_active = (guid == state.target_take_guid)
        -- A take flagged missing by the project resync is not looked up again (the scan is not free)
        local flagged_missing = state.missing_takes[guid] == true
        local take_obj = nil
        if not flagged_missing then
          take_obj = resolve_take_by_guid(guid)
          if not take_obj and is_active then
            take_obj = K.frame_target()
          end
        end
        local is_missing = flagged_missing or take_obj == nil
        local is_stale = (not is_missing) and state.stale_takes[guid] == true

        reaper.ImGui_PushID(sidebar_ctx, guid)

        local rx, ry = reaper.ImGui_GetCursorScreenPos(sidebar_ctx)
        local start_x = reaper.ImGui_GetCursorPosX(sidebar_ctx)
        local start_y = reaper.ImGui_GetCursorPosY(sidebar_ctx)

        -- 1. Card: the active row is the selection tint (P.select) with a leading accent bar, a hovered row the
        -- hover fill (P.hover); no border, as the library's rows
        local card_x1 = rx + card_margin_x
        local card_y1 = ry + card_pad_y
        local card_x2 = rx + avail_w - card_margin_x
        local card_y2 = card_y1 + card_h

        local dl = reaper.ImGui_GetWindowDrawList(sidebar_ctx)
        local is_row_hovered = reaper.ImGui_IsMouseHoveringRect(sidebar_ctx, card_x1, card_y1, card_x2, card_y2)
        if is_active then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1, card_x2, card_y2, P.select, L.rounding)
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1 + L.xs, card_x1 + bar_w, card_y2 - L.xs, P.accent)
        elseif is_row_hovered then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1, card_x2, card_y2, P.hover, L.rounding)
        end
        -- P.text_dim reads at 4.5:1 on the window, not on those fills (3.8:1 on the tint, 4.0:1 on the hover fill):
        -- on a filled card the dim name and the state tag take P.text (the tag's words still say the state)
        local dim_col = (is_active or is_row_hovered) and P.text or P.text_dim

        -- 2. Elements on one line inside the card, each centred on it
        local x_left = start_x + card_margin_x + card_pad_x
        local x_right = start_x + avail_w - card_margin_x - card_pad_x
        local line_y = start_y + card_pad_y
        reaper.ImGui_SetCursorPos(sidebar_ctx, x_left, line_y)

        -- Bypass checkbox: default frame padding; disabled (and unchecked) when the item no longer exists
        local is_enabled = (not is_missing) and not is_take_pitch_bypassed(take_obj)
        Theme.vcenter(sidebar_ctx, frame_h, card_h, line_y)
        if is_missing then reaper.ImGui_BeginDisabled(sidebar_ctx) end
        -- The panel's surface is the recessed one, so the box takes the button face to keep its boundary visible
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_FrameBg(), P.btn)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_FrameBgHovered(), P.btn_h)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_FrameBgActive(), P.btn_a)
        local cb_changed, new_en = reaper.ImGui_Checkbox(sidebar_ctx, "##bp", is_enabled)
        reaper.ImGui_PopStyleColor(sidebar_ctx, 3)
        if is_missing then reaper.ImGui_EndDisabled(sidebar_ctx) end
        local cb_w = reaper.ImGui_GetItemRectSize(sidebar_ctx)
        if cb_changed and not is_missing then
          toggle_take_pitch_bypass(take_obj)
        end
        if is_missing then
          if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
            Theme.tooltip(sidebar_ctx, BODY.tip_missing)
          end
        elseif reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(sidebar_ctx, new_en and "Envelope Active — click to bypass it" or "Envelope Bypassed — click to enable it")
        end

        -- Room for the name and the state tag between the checkbox and the X. The tag shows only when the
        -- name keeps a readable part; the tooltip of the name always says the state.
        local name_x = x_left + cb_w + gap
        local del_x = x_right - del_sz
        local room = del_x - gap - name_x
        local state_tag, state_tip = nil, nil
        if is_missing then
          state_tag, state_tip = BODY.tag_missing, BODY.tip_missing
        elseif is_stale then
          state_tag, state_tip = BODY.tag_outdated, BODY.tip_outdated
        end
        local tag_w, tag_h = 0, 0
        if state_tag then
          local pushed_small = Theme.push_font(sidebar_ctx, fonts.small)
          tag_w, tag_h = reaper.ImGui_CalcTextSize(sidebar_ctx, state_tag)
          Theme.pop_font(sidebar_ctx, pushed_small)
          if room - tag_w - gap < name_min_w then tag_w = 0 end  -- no room: the name tooltip carries it
        end
        local name_w = math.max(name_min_w, room - (tag_w > 0 and (tag_w + gap) or 0))

        -- Name: the whole card height is the hit area, the text is centred in it; bold marks the active row.
        -- Placed by position, not SameLine: after SameLine a Selectable inherits the checkbox's text-baseline
        -- offset (its frame padding) and ImGui pushes the whole item, and so the text, down by that amount.
        reaper.ImGui_SetCursorPos(sidebar_ctx, name_x, line_y)
        local full_name = data.name or "Item"
        local name_font = is_active and Theme.push_font(sidebar_ctx, fonts.default_bold)
        local sel_text = fit_text(sidebar_ctx, full_name, name_w, is_active and "bold" or "regular")
        local name_col = (is_missing and dim_col) or P.text
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), name_col)
        -- The row card draws its own hover fill: the selectable adds none (an opaque P.hover would cover the
        -- active row's blue tint in the name area)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_HeaderHovered(), Theme.with_alpha(P.hover, 0))
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_HeaderActive(),  Theme.with_alpha(P.hover, 0))
        reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
        reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_SelectableTextAlign(), 0, 0.5)
        reaper.ImGui_SetCursorPosY(sidebar_ctx, line_y)
        if reaper.ImGui_Selectable(sidebar_ctx, sel_text .. "###sel", false, reaper.ImGui_SelectableFlags_None(), name_w, card_h) then
          switch_active_target(guid, take_obj)
        end
        reaper.ImGui_PopStyleVar(sidebar_ctx, 2)
        reaper.ImGui_PopStyleColor(sidebar_ctx, 3)
        if name_font then Theme.pop_font(sidebar_ctx, name_font) end

        if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          local lines = { string.format("Item: %s", full_name) }
          if is_missing then
            lines[#lines + 1] = state_tip
          else
            lines[#lines + 1] = string.format("Notes: %d", data.notes and #data.notes or 0)
            if state_tip then lines[#lines + 1] = string.format("Outdated: %s", state_tip) end
          end
          lines[#lines + 1] = "Click to make this the active item"
          Theme.tooltip(sidebar_ctx, table.concat(lines, "\n"))
        end

        -- State tag (dim text, never colour alone), right before the X
        if tag_w > 0 then
          reaper.ImGui_SameLine(sidebar_ctx, 0, gap)
          local pushed_small = Theme.push_font(sidebar_ctx, fonts.small)
          Theme.vcenter(sidebar_ctx, tag_h, card_h, line_y)
          reaper.ImGui_TextColored(sidebar_ctx, dim_col, state_tag)
          if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
            Theme.tooltip(sidebar_ctx, state_tip)
          end
          Theme.pop_font(sidebar_ctx, pushed_small)
        end

        -- 3. Remove button at the right end of the card. SameLine takes the Y of the previous item (the state tag is
        -- centred lower), so the row's top is set first: Theme.vcenter does nothing when the target is as tall as the card
        reaper.ImGui_SameLine(sidebar_ctx, del_x)
        reaper.ImGui_SetCursorPosY(sidebar_ctx, line_y)
        Theme.vcenter(sidebar_ctx, del_sz, card_h, line_y)
        if Theme.icon_btn(sidebar_ctx, "##del", Theme.icons.close, {
          preset = L.icon_target,
          icon_size = L.icon_md.size,   -- the glyph matches the other icons; only the click target is 24 px
          w = del_sz, h = del_sz,       -- icon_btn sizes the button from icon_size unless told otherwise
          color = P.text_dim,
          hover_color = P.red,
          tooltip = "Remove from Pitched Items and clear its envelope and saved analysis (asks to confirm)"
        }) then
          to_remove = guid
        end

        -- End of row: one item spanning it, so the next row starts below and the list's extent is valid
        reaper.ImGui_SetCursorPos(sidebar_ctx, start_x, start_y)
        reaper.ImGui_Dummy(sidebar_ctx, avail_w, row_h)

        reaper.ImGui_PopID(sidebar_ctx)
      else
        -- An entry without data draws nothing, but the clipper counts every row the same height
        reaper.ImGui_Dummy(sidebar_ctx, avail_w, row_h)
      end
    end
  end

  if to_remove then
    request_remove_confirm(to_remove)
  end
end

-- The panel's Shortcuts groups, in the order they are drawn
K.PANEL_GROUPS = { "Select", "Edit", "View", "General" }

--- The Shortcuts list of the panel: { { group = name, rows = { { key, text }, ... } }, ... } in K.PANEL_GROUPS order,
--- built once from the rows of K.INFO_SECTIONS that carry a `panel` field.
K.panel_rows = function()
  if K.panel_rows_cache then return K.panel_rows_cache end
  local by_group = {}
  for _, name in ipairs(K.PANEL_GROUPS) do by_group[name] = {} end
  for _, section in ipairs(K.INFO_SECTIONS) do
    for _, row in ipairs(section.rows) do
      local p = row.panel
      if p and by_group[p[1]] then
        local list = by_group[p[1]]
        list[#list + 1] = { key = p[4] or row[1], text = p[3], order = p[2] }
      end
    end
  end
  local out = {}
  for _, name in ipairs(K.PANEL_GROUPS) do
    table.sort(by_group[name], function(a, b) return a.order < b.order end)
    out[#out + 1] = { group = name, rows = by_group[name] }
  end
  K.panel_rows_cache = out
  return out
end

--- The colour of the key text in the Shortcuts list: the accent, as in the Help modal, when it reads at 4.5:1 on the
--- panel's surface (HC1), else the text colour (a Match Theme accent can be too close to the background).
K.panel_key_color = function(P)
  local c = K.panel_key_cache
  if c and c.accent == P.accent and c.inset == P.inset and c.text == P.text then return c.color end
  local function luminance(rgba)
    local function channel(v)
      v = v / 255
      return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * channel((rgba >> 24) & 0xFF) + 0.7152 * channel((rgba >> 16) & 0xFF) + 0.0722 * channel((rgba >> 8) & 0xFF)
  end
  local la, lb = luminance(P.accent), luminance(P.inset)
  local ratio = (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
  local color = ratio >= 4.5 and P.accent or P.text
  K.panel_key_cache = { accent = P.accent, inset = P.inset, text = P.text, color = color }
  return color
end

--- Fold or unfold a section of the panel ("items" or "shortcuts"); the preference is stored when it changes.
K.set_panel_open = function(which, open)
  local field = which == "items" and "items_open" or "shortcuts_open"
  open = open and true or false
  if state[field] == open then return end
  state[field] = open
  reaper.SetExtState("FancyScripts", which == "items" and "pitch_items_open" or "pitch_shortcuts_open", open and "1" or "0", true)
end

--- Heights of the two section bodies. avail_h = the room under the two headers. Both unfolded: Pitched Items is as tall as
--- its content, at most half of the room, and Shortcuts takes the rest. One unfolded: it takes everything. Never negative.
K.panel_heights = function(avail_h, items_content_h, items_open, shortcuts_open)
  avail_h = math.max(0, math.floor(avail_h))
  if items_open and shortcuts_open then
    local items_h = math.max(0, math.min(math.ceil(items_content_h), avail_h // 2))
    return items_h, avail_h - items_h
  elseif items_open then
    return avail_h, 0
  elseif shortcuts_open then
    return 0, avail_h
  end
  return 0, 0
end

--- The top bar's panel button: show or hide the side panel (the preference is stored). A window too narrow for the
--- panel records the wish to see it and says why nothing changed.
K.toggle_sidebar = function()
  local open = not (state.sidebar_open and state.sidebar_fits)
  if open ~= state.sidebar_open then
    state.sidebar_open = open
    reaper.SetExtState("FancyScripts", "pitch_sidebar_open", open and "1" or "0", true)
  end
  if open and not state.sidebar_fits then set_status(BODY.panel_narrow_status) end
end

--- H: show or hide the Shortcuts list. A hidden panel comes back with the list unfolded; a window too narrow for the
--- panel changes nothing and says why.
K.toggle_shortcuts = function()
  if not state.sidebar_fits then
    set_status(BODY.shortcuts_narrow_status)
  elseif not state.sidebar_open then
    state.sidebar_open = true
    reaper.SetExtState("FancyScripts", "pitch_sidebar_open", "1", true)
    K.set_panel_open("shortcuts", true)
  else
    K.set_panel_open("shortcuts", not state.shortcuts_open)
  end
end

--- Measure the widest key and the widest description of the Shortcuts list in the font pushed now (K.panel_key_w,
--- K.panel_text_w); measured again only when the font size changes.
K.panel_measure = function(measure_ctx)
  local font_h = reaper.ImGui_GetFontSize(measure_ctx)
  if K.panel_key_w_font == font_h then return end
  local key_w, text_w = 0, 0
  for _, g in ipairs(K.panel_rows()) do
    for _, row in ipairs(g.rows) do
      key_w = math.max(key_w, (reaper.ImGui_CalcTextSize(measure_ctx, row.key)) or 0)
      text_w = math.max(text_w, (reaper.ImGui_CalcTextSize(measure_ctx, row.text)) or 0)
    end
  end
  K.panel_key_w, K.panel_text_w, K.panel_key_w_font = key_w, text_w, font_h
end

--- The panel width at which every Shortcuts row fits on one line: the default width, taken from the text in the font in
--- use (never a pixel constant). The parts mirror draw_body_split (the panel's inset) and K.draw_shortcuts_body (the
--- list's indent, the key column, both columns' cell padding) plus the room of the body's scrollbar.
K.panel_fit_w = function(measure_ctx)
  local L = Theme.layout
  K.panel_measure(measure_ctx)
  local scrollbar_w = reaper.ImGui_GetStyleVar(measure_ctx, reaper.ImGui_StyleVar_ScrollbarSize()) or 0
  return math.ceil(L.sm * 2 + L.sm * 2 + (K.panel_key_w + L.sm) + K.panel_text_w + L.xs * 4 + scrollbar_w) + 1
end

--- The body of the Shortcuts section: one heading per group, the key in a fixed column as wide as the widest key, the
--- description wrapping in the rest. Reference text only (no hover, no click).
K.draw_shortcuts_body = function(sidebar_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout
  local groups = K.panel_rows()
  local key_col = K.panel_key_color(P)

  -- The widest key in the font drawn now, measured again only when the font size changes
  K.panel_measure(sidebar_ctx)

  local avail_w = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)
  local table_w = math.max(1, avail_w - L.sm * 2)
  local table_flags = reaper.ImGui_TableFlags_SizingFixedFit() | reaper.ImGui_TableFlags_NoSavedSettings()
  reaper.ImGui_Indent(sidebar_ctx, L.sm)
  reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_CellPadding(), L.xs, L.xs)
  for i, g in ipairs(groups) do
    -- Theme.section_divider brings its own air above and below: no extra gap between the groups
    Theme.section_divider(sidebar_ctx, g.group, { color = P.yellow })
    if reaper.ImGui_BeginTable(sidebar_ctx, "##panel_keys_" .. i, 2, table_flags, table_w, 0) then
      reaper.ImGui_TableSetupColumn(sidebar_ctx, "##key", reaper.ImGui_TableColumnFlags_WidthFixed(), K.panel_key_w + L.sm)
      reaper.ImGui_TableSetupColumn(sidebar_ctx, "##text", reaper.ImGui_TableColumnFlags_WidthStretch(), 1)
      for _, row in ipairs(g.rows) do
        reaper.ImGui_TableNextRow(sidebar_ctx)
        reaper.ImGui_TableSetColumnIndex(sidebar_ctx, 0)
        reaper.ImGui_TextColored(sidebar_ctx, key_col, row.key)
        reaper.ImGui_TableSetColumnIndex(sidebar_ctx, 1)
        reaper.ImGui_TextWrapped(sidebar_ctx, row.text)
      end
      reaper.ImGui_EndTable(sidebar_ctx)
    end
  end
  reaper.ImGui_PopStyleVar(sidebar_ctx, 1)
  reaper.ImGui_Unindent(sidebar_ctx, L.sm)
  reaper.ImGui_Dummy(sidebar_ctx, 0, L.sm)
end

--- The panel: two sections, Pitched Items and Shortcuts, each a header that folds its body. Each body scrolls on its own
--- inside the height K.panel_heights gives it; the panel itself never scrolls.
local function render_pitched_items_sidebar(sidebar_ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(sidebar_ctx)
  local _, spacing_y = reaper.ImGui_GetStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_ItemSpacing())
  spacing_y = spacing_y or 0

  -- 1. Pitched Items header: the fold arrow and the count (the panel itself is shown and hidden from the top bar)
  reaper.ImGui_SetNextItemOpen(sidebar_ctx, state.items_open, reaper.ImGui_Cond_Always())
  local items_open = Theme.collapsing_header(sidebar_ctx,
    string.format("Pitched Items (%d)##pitch_items_hdr", #state.session_order))
  K.set_panel_open("items", items_open)

  -- The room under the two headers (the Shortcuts header and the gaps around the bodies come off what is left here)
  local _, left_h = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)
  local gaps = (state.items_open and 1 or 0) + (state.shortcuts_open and 1 or 0)
  local avail_h = (left_h or 0) - frame_h - spacing_y * gaps
  local items_h, shortcuts_h = K.panel_heights(avail_h, state.items_content_h or math.huge, state.items_open, state.shortcuts_open)

  -- 2. Pitched Items body
  if state.items_open and items_h >= 1 then
    if reaper.ImGui_BeginChild(sidebar_ctx, "##pitch_items_body", 0, items_h, 0) then
      K.draw_items_body(sidebar_ctx)
      -- The cursor ends under the last row (the clipper counts the rows it skipped): the content's height
      state.items_content_h = reaper.ImGui_GetCursorPosY(sidebar_ctx)
      reaper.ImGui_EndChild(sidebar_ctx)
    end
  end

  -- 3. Shortcuts header and body
  reaper.ImGui_SetNextItemOpen(sidebar_ctx, state.shortcuts_open, reaper.ImGui_Cond_Always())
  local shortcuts_open = Theme.collapsing_header(sidebar_ctx, "Shortcuts##pitch_shortcuts_hdr")
  K.set_panel_open("shortcuts", shortcuts_open)
  if state.shortcuts_open and shortcuts_h >= 1 then
    if reaper.ImGui_BeginChild(sidebar_ctx, "##pitch_shortcuts_body", 0, shortcuts_h, 0) then
      K.draw_shortcuts_body(sidebar_ctx)
      reaper.ImGui_EndChild(sidebar_ctx)
    end
  end
end

--- Body, panel open: canvas | grip | Pitched Items in a resizable two-column table (canvas stretches,
--- the panel is a fixed column). ImGui keeps a fixed column's width between frames and offers no way to
--- set it again, so a width that has to change without a drag (the window got narrower, the panel was
--- closed and reopened) is applied by starting a new table id, which takes the init width once. The live
--- width is read back each frame into state.sidebar_w. Returns whether the table was drawn.
local function draw_body_split(P, avail_w, total_h)
  local L = Theme.layout
  local left = reaper.ImGui_MouseButton_Left()
  local mouse_down = reaper.ImGui_IsMouseDown(ctx, left)

  -- No stored width: the default is the width at which every Shortcuts row fits on one line. It is not saved (only a
  -- drag of the divider is), so it follows the font; the clamps below still keep the canvas its minimum.
  if state.sidebar_auto then
    state.sidebar_auto = false
    state.sidebar_w = K.panel_fit_w(ctx)
    state.stored["pitch_sidebar_w"] = string.format("%.0f", state.sidebar_w)
    state.sidebar_tabled = false
  end

  local max_sidebar_w = math.max(BODY.min_sidebar_w, avail_w - BODY.min_graph_w - BODY.splitter_w)
  local wanted_w = math.max(BODY.min_sidebar_w, math.min(max_sidebar_w, state.sidebar_w))
  -- A drag may run past the limits while the button is down; the width snaps back on release
  if not state.sidebar_tabled or (math.abs(wanted_w - state.sidebar_w) > BODY.width_eps and not mouse_down) then
    state.sidebar_w = wanted_w
    state.sidebar_gen = state.sidebar_gen + 1
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(), 0, 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(), P.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(), P.border)
  local table_flags = reaper.ImGui_TableFlags_Resizable()
    | reaper.ImGui_TableFlags_BordersInnerV()
    | reaper.ImGui_TableFlags_NoSavedSettings()
  local drawn = reaper.ImGui_BeginTable(ctx, string.format("##body_split_%d", state.sidebar_gen), 2, table_flags, 0, total_h)
  if drawn then
    reaper.ImGui_TableSetupColumn(ctx, "##canvas", reaper.ImGui_TableColumnFlags_WidthStretch(), 1)
    reaper.ImGui_TableSetupColumn(ctx, "##pitched_items", reaper.ImGui_TableColumnFlags_WidthFixed(), state.sidebar_w)
    reaper.ImGui_TableNextRow(ctx, reaper.ImGui_TableRowFlags_None(), total_h)

    -- Left: piano roll canvas (never drawn narrower than its minimum; the cell clips the excess mid-drag)
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    local canvas_w = reaper.ImGui_GetContentRegionAvail(ctx)
    draw_graph(ctx, math.max(canvas_w, BODY.min_graph_w), total_h)

    -- Right: Pitched Items panel, inset from the grip and, by as much, from the window's edge (the window has no padding)
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    local grip_x, grip_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local column_w = reaper.ImGui_GetContentRegionAvail(ctx)
    state.sidebar_w = column_w
    -- The panel has its own recessed surface (the Timing tray's), so it reads as a panel beside the canvas
    reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
      grip_x, grip_y, grip_x + column_w, grip_y + total_h, P.inset)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + L.sm)
    local panel_w = math.max(column_w, BODY.min_sidebar_w) - L.sm * 2
    -- The panel never scrolls itself: each of its two sections scrolls its own body
    local panel_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    if reaper.ImGui_BeginChild(ctx, "##pitched_items_sidebar", panel_w, total_h, 0, panel_flags) then
      render_pitched_items_sidebar(ctx)
      reaper.ImGui_EndChild(ctx)
    end

    -- The grip: ImGui draws the divider (P.border at rest, its hover / active colours while used) and sets
    -- the resize cursor while it is used; the tooltip is ours (the divider is not an item to hover)
    local over_grip = reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_ChildWindows())
      and reaper.ImGui_IsMouseHoveringRect(ctx, grip_x - L.sm, grip_y, grip_x + L.sm, grip_y + total_h)
    local on_grip = not mouse_down and over_grip
    -- A press on the grip starts a resize; the width is saved once the button is released, not while it moves (and only
    -- when it really changed: K.save_settings compares). The automatic clamps to the window never start a save.
    if over_grip and reaper.ImGui_IsMouseClicked(ctx, left) then state.grip_pressed = true end
    if state.grip_pressed and not mouse_down then
      state.grip_pressed = false
      K.save_settings("sidebar")
    end
    if on_grip then
      reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
      local now = reaper.time_precise()
      state.grip_hover_since = state.grip_hover_since or now
      if now - state.grip_hover_since >= BODY.grip_tip_delay_s then
        Theme.tooltip(ctx, BODY.grip_tip)
      end
    else
      state.grip_hover_since = nil
    end

    reaper.ImGui_EndTable(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 1)
  return drawn
end

--- 1-based index of the list item closest to value (ties pick the lower one).
local function nearest_index(list, value)
  local target = tonumber(value) or 0
  local best, best_dist = 1, math.huge
  for i, item in ipairs(list) do
    local dist = math.abs(item - target)
    if dist < best_dist then best, best_dist = i, dist end
  end
  return best
end

--- Hop sizes that fit in a block of block_size samples (never empty: the smallest hop is always offered).
local function hop_choices(block_size)
  local hops = {}
  for _, hop in ipairs(HOP_SIZES) do
    if hop <= block_size then hops[#hops + 1] = hop end
  end
  if #hops == 0 then hops[1] = HOP_SIZES[1] end
  return hops
end

--- Settings value control: a param_drag on state[key] within K.LIMITS[key], `width` wide and without a label (the form's
--- label column names it); double-click restores DEFAULTS[key] (engine settings are not project state: no undo point).
--- The value is saved once the edit is done (the drag released, a typed entry confirmed, a reset), not while it moves.
local function settings_drag(id, key, fmt, width)
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local raw = state[key]
  local changed, v, committed, reset, cancelled = param_drag(ctx, id, nil, raw, K.LIMITS[key][1], K.LIMITS[key][2], fmt)
  local back = K.drag_revert(id, raw, cancelled)
  if back ~= nil then
    state[key] = back   -- Esc during the drag: the value from before it, nothing saved
  elseif reset then
    state[key] = DEFAULTS[key]
  elseif changed then
    state[key] = v
  end
  if committed then K.save_settings("engine") end
end

--- Index of the entry of `list` for which `same(entry)` holds, 0 when none does (its combo then reads "Custom").
K.match_preset = function(list, same)
  for i, entry in ipairs(list) do
    if same(entry) then return i end
  end
  return 0
end

--- "≈ 23 ms": how long `samples` last at the sample rate of the analysed item (44.1 kHz until there is one).
K.samples_readout = function(samples)
  local rate = tonumber(state.sample_rate)
  if not rate or rate <= 0 then rate = K.DEFAULT_SAMPLE_RATE end
  local ms = samples * 1000 / rate
  return string.format(ms < 10 and "≈ %.1f ms" or "≈ %.0f ms", ms)
end

--- A block / hop size combo (##id) with the duration of the shown size beside it, `w` pixels in all.
--- A value outside the list (older state) shows the nearest item. Returns the chosen size and whether it changed.
K.size_combo = function(id, list, current, w, tip)
  local P = Theme.get_palette()
  local L = Theme.layout
  local room = 0
  for _, samples in ipairs(list) do
    room = math.max(room, (reaper.ImGui_CalcTextSize(ctx, K.samples_readout(samples))) or 0)
  end
  local idx = nearest_index(list, current)
  local new_idx, changed = Theme.combo(ctx, id, list, idx, { w = math.max(w - room - L.sm, 1), tooltip = tip })
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  Theme.align(ctx)
  reaper.ImGui_TextColored(ctx, P.text_dim, K.samples_readout(list[idx]))
  return list[new_idx], changed
end

-- The Settings forms: Pitch Shift Engine, Analysis & Detection, Advanced DSP. A row knows its label, whether its
-- value is the factory one (DEFAULTS), how to restore it, and how to draw its control `w` pixels wide; a preset combo
-- reads "Custom" when the values match none of its presets. draw_settings_modal lays the rows out as label | control |
-- Reset, and a section's "Reset section" walks the same rows. `labels` = every text the control can show and `fit` =
-- the width it needs at least (they size the control column).
K.SETTINGS_SECTIONS = {
  { id = "engine", title = "Pitch Shift Engine", rows = {
    { id = "pitchmode", label = "Pitch Shift Algorithm", labels = COMBO_LABELS.pitchmodes,
      is_default = function() return state.preset_pitchmode_idx == DEFAULTS.preset_pitchmode_idx end,
      reset = function() K.set_pitch_algorithm(DEFAULTS.preset_pitchmode_idx) end,
      draw = function(w)
        local idx, changed = Theme.combo(ctx, "##settings_pitchmode", PITCHMODE_FLAT, state.preset_pitchmode_idx, {
          w = w,
          tooltip = "Pitch Shift Algorithm — Elastique Soloist (Monophonic) is recommended for vocals.\nApplied automatically to the item when writing envelopes.",
        })
        if changed then
          K.set_pitch_algorithm(idx)
          K.save_settings("engine")
        end
      end },
    { id = "keep_pitch", label = "", name = K.KEEP_PITCH_LABEL,
      fit = function()
        return (reaper.ImGui_CalcTextSize(ctx, K.KEEP_PITCH_LABEL)) + reaper.ImGui_GetFrameHeight(ctx) + Theme.layout.sm
      end,
      is_default = function() return state.keep_pitch_mode == DEFAULTS.keep_pitch_mode end,
      reset = function() state.keep_pitch_mode = DEFAULTS.keep_pitch_mode end,
      draw = function()
        local changed, on = reaper.ImGui_Checkbox(ctx, K.KEEP_PITCH_LABEL .. "###keep_pitch_mode", state.keep_pitch_mode)
        if changed then
          state.keep_pitch_mode = on
          K.save_settings("engine")
        end
        if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, "Fancy Pitch Correct then never changes the pitch algorithm of an item: the one set in REAPER stays, and the Pitch Shift Algorithm above is not used.")
        end
      end },
  } },
  { id = "detection", title = "Analysis & Detection Presets", rows = {
    { id = "range", label = "Vocal Range", labels = COMBO_LABELS.ranges,
      is_default = function() return state.min_freq == DEFAULTS.min_freq and state.max_freq == DEFAULTS.max_freq end,
      reset = function() state.min_freq, state.max_freq = DEFAULTS.min_freq, DEFAULTS.max_freq end,
      draw = function(w)
        local current = K.match_preset(VOCAL_RANGES, function(r) return r.min == state.min_freq and r.max == state.max_freq end)
        local idx, changed = Theme.combo(ctx, "##settings_range", VOCAL_RANGES, current, {
          w = w, placeholder = K.CUSTOM_PRESET,
          tooltip = "Vocal Range — limits frequency search to avoid octave jump errors",
        })
        if changed and VOCAL_RANGES[idx] then
          state.min_freq, state.max_freq = VOCAL_RANGES[idx].min, VOCAL_RANGES[idx].max
          K.save_settings("engine")
        end
      end },
    { id = "mode", label = "Detection Mode", labels = COMBO_LABELS.detection,
      is_default = function() return state.threshold == DEFAULTS.threshold end,
      reset = function() state.threshold = DEFAULTS.threshold end,
      draw = function(w)
        local current = K.match_preset(DETECTION_MODES, function(m) return m.threshold == state.threshold end)
        local idx, changed = Theme.combo(ctx, "##settings_mode", DETECTION_MODES, current, {
          w = w, placeholder = K.CUSTOM_PRESET,
          tooltip = "Detection Mode — confidence threshold for pitched note detection",
        })
        if changed and DETECTION_MODES[idx] then
          state.threshold = DETECTION_MODES[idx].threshold
          K.save_settings("engine")
        end
      end },
    { id = "quality", label = "Quality / CPU", labels = COMBO_LABELS.quality,
      is_default = function() return state.block_size == DEFAULTS.block_size and state.hop_size == DEFAULTS.hop_size end,
      reset = function() state.block_size, state.hop_size = DEFAULTS.block_size, DEFAULTS.hop_size end,
      draw = function(w)
        local current = K.match_preset(QUALITY_MODES, function(q) return q.block == state.block_size and q.hop == state.hop_size end)
        local idx, changed = Theme.combo(ctx, "##settings_quality", QUALITY_MODES, current, {
          w = w, placeholder = K.CUSTOM_PRESET,
          tooltip = "Quality / CPU — time vs frequency resolution trade-off",
        })
        if changed and QUALITY_MODES[idx] then
          state.block_size = QUALITY_MODES[idx].block
          state.hop_size = QUALITY_MODES[idx].hop
          K.save_settings("engine")
        end
      end },
  } },
  { id = "dsp", title = "Advanced DSP Parameters", rows = {
    -- Discrete choices; a value outside the lists (older state) shows the nearest item. The hop never exceeds the block.
    { id = "block", label = "Block size (samples)", name = "Block size",
      is_default = function() return state.block_size == DEFAULTS.block_size end,
      reset = function()
        state.block_size = DEFAULTS.block_size
        if state.hop_size > state.block_size then state.hop_size = state.block_size end
      end,
      draw = function(w)
        local size, changed = K.size_combo("##dsp_block", BLOCK_SIZES, state.block_size, w,
          "Samples analyzed per window (e.g. 512, 1024, 2048).")
        if changed then
          state.block_size = size
          -- The block shrank below the hop: clamp the hop down (every block up to 1024 is also a hop size)
          if state.hop_size > state.block_size then state.hop_size = state.block_size end
          K.save_settings("engine")
        end
      end },
    -- The factory hop never exceeds the block either: a smaller block limits what Reset can restore
    { id = "hop", label = "Hop size (samples)", name = "Hop size",
      is_default = function() return state.hop_size == math.min(DEFAULTS.hop_size, state.block_size) end,
      reset = function() state.hop_size = math.min(DEFAULTS.hop_size, state.block_size) end,
      draw = function(w)
        local size, changed = K.size_combo("##dsp_hop", hop_choices(state.block_size), state.hop_size, w,
          "Samples to advance between analysis windows.")
        if changed then
          state.hop_size = size
          K.save_settings("engine")
        end
      end },
    { id = "threshold", label = "Detection Threshold",
      is_default = function() return state.threshold == DEFAULTS.threshold end,
      reset = function() state.threshold = DEFAULTS.threshold end,
      draw = function(w)
        settings_drag("dsp_threshold", "threshold", "%.2f", w)
        if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, "Confidence threshold for pitch detection (lower = stricter).")
        end
      end },
    { id = "min_freq", label = "Min Freq (Hz)",
      is_default = function() return state.min_freq == DEFAULTS.min_freq end,
      reset = function() state.min_freq = DEFAULTS.min_freq end,
      draw = function(w) settings_drag("dsp_min_freq", "min_freq", "%.0f Hz", w) end },
    { id = "max_freq", label = "Max Freq (Hz)",
      is_default = function() return state.max_freq == DEFAULTS.max_freq end,
      reset = function() state.max_freq = DEFAULTS.max_freq end,
      draw = function(w) settings_drag("dsp_max_freq", "max_freq", "%.0f Hz", w) end },
  } },
}

--- Ask before restoring every setting of a Settings section to its DEFAULTS value. These settings are outside the
--- undo history (and are saved), so the confirm names how many change and which; the confirm is the only modal, so the
--- caller closes Settings first. Does nothing when every row already holds its default.
K.request_settings_reset = function(section)
  -- The rows are walked on a copy of the state: one row's reset can move another (the hop follows the block), so the
  -- names and the count come from exactly the sequence on_confirm runs
  local names = {}
  local saved = {}
  for k, v in pairs(state) do saved[k] = v end
  for _, row in ipairs(section.rows) do
    if not row.is_default() then
      names[#names + 1] = row.name or row.label
      row.reset()
    end
  end
  for k, v in pairs(saved) do state[k] = v end
  local n = #names
  if n == 0 then return end
  request_confirm({
    id = "reset_settings_" .. section.id,
    title = string.format("Reset %s?", section.title),
    body_lines = {
      string.format("This restores %d %s to %s: %s.", n, plural(n, "setting", "settings"),
        plural(n, "its default", "their defaults"), table.concat(names, ", ")),
      string.format("Settings are not part of the undo history: %s+Z does not bring them back.", K.MOD_LABEL),
    },
    confirm_label = string.format("Reset %d %s", n, plural(n, "Setting", "Settings")),
    on_confirm = function()
      local done = 0
      for _, row in ipairs(section.rows) do
        if not row.is_default() then
          row.reset()
          done = done + 1
        end
      end
      K.save_settings("engine")
      set_status(string.format("Reset %d %s to %s (not undoable)", done, plural(done, "setting", "settings"),
        plural(done, "its default", "their defaults")))
    end,
  })
end

--- Danger styling of the Settings "Wipe" button and the confirm modal's confirm button: the label stays P.text and
--- every state is a translucent red over the popup surface (P.panel), so the label keeps >= 4.5:1 in all of them (HC1).
--- Fancy, composited: rest (P.red_d) 6.2:1, hover and pressed (P.red_h) 4.9:1 (an opaque P.red pressed would be
--- 2.4:1). Pair every K.push_danger(P) with K.pop_danger().
K.push_danger = function(P)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red_h)
end
K.pop_danger = function()
  reaper.ImGui_PopStyleColor(ctx, 3)
end

--- A checkbox for a canvas layer (state[key]: the Layers menu and Settings > Diagnostics). The change is saved at once:
--- a click is a whole edit, so it is one write.
K.layer_checkbox = function(label, key)
  local changed, on = reaper.ImGui_Checkbox(ctx, label, state[key])
  if changed then
    state[key] = on
    K.save_settings("layers")
  end
end

--- Keep a dialog inside the window it opens from. A dialog larger than that window becomes an OS window of its
--- own, centred on the (small) docked window, and can run off the screen with its end out of reach; capped to the
--- window it stays inside and longer content scrolls. Call right before BeginPopupModal, in the host window's scope.
function K.fit_modal(modal_ctx)
  local L = Theme.layout
  local host_w, host_h = reaper.ImGui_GetWindowSize(modal_ctx)
  reaper.ImGui_SetNextWindowSizeConstraints(modal_ctx, 0, 0,
    math.max(host_w - L.xl * 2, L.xxxl), math.max(host_h - L.xl * 2, L.xxxl))
end

local function draw_settings_modal()
  local P = Theme.get_palette()
  local L = Theme.layout

  if App.show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, "Settings & Audio Engine##settings_modal")
    App.show_settings_modal = false
  end

  -- The modal is AlwaysAutoResize: its content decides the size, the preset only centres it
  Theme.center_next_window(ctx, L.modal_md.w, L.modal_md.h, reaper.ImGui_Cond_Appearing())
  K.fit_modal(ctx)
  Theme.modal_scrim(ctx, "Settings & Audio Engine##settings_modal")
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Settings & Audio Engine##settings_modal", true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    -- The engine controls are locked while an analysis runs: it works on the values it started with
    local locked = state.is_analyzing == true

    -- Form columns (label | control | Reset), measured once per draw and shared by every section so the controls line up
    local function text_w(text) return (reaper.ImGui_CalcTextSize(ctx, text)) or 0 end
    local label_w = 0
    local control_w = Theme.calc_combo_width(ctx, { K.CUSTOM_PRESET })
    for _, section in ipairs(K.SETTINGS_SECTIONS) do
      for _, row in ipairs(section.rows) do
        label_w = math.max(label_w, text_w(row.label))
        if row.labels then control_w = math.max(control_w, Theme.calc_combo_width(ctx, row.labels)) end
        if row.fit then control_w = math.max(control_w, row.fit()) end
      end
    end
    local reset_w = text_w("Reset") + L.md * 2
    local section_reset_w = text_w("Reset section") + L.md * 2
    local form_flags = reaper.ImGui_TableFlags_SizingFixedFit() | reaper.ImGui_TableFlags_NoHostExtendX()
    local fixed = reaper.ImGui_TableColumnFlags_WidthFixed()
    local section_to_reset = nil

    --- A text button that is disabled, dim and explained when `reason` is set (the tooltip waits like every tooltip and
    --- also shows on the disabled button). Returns true when it was clicked.
    local function reset_button(label, id, w, reason, hint)
      reaper.ImGui_BeginDisabled(ctx, reason ~= nil)
      if reason then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim) end
      local clicked = reaper.ImGui_Button(ctx, label .. "###" .. id, w, 0)
      if reason then reaper.ImGui_PopStyleColor(ctx, 1) end
      reaper.ImGui_EndDisabled(ctx)
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
        Theme.tooltip(ctx, locked and K.LOCKED_REASON or reason or hint)
      end
      return clicked and not locked
    end

    --- One section as a form: a row per setting (label | control | Reset), then the section's own Reset.
    local function draw_form(section)
      if not reaper.ImGui_BeginTable(ctx, "##settings_form_" .. section.id, 3, form_flags) then return end
      reaper.ImGui_TableSetupColumn(ctx, "##label", fixed, label_w + L.md)
      reaper.ImGui_TableSetupColumn(ctx, "##control", fixed, control_w + L.md)
      reaper.ImGui_TableSetupColumn(ctx, "##reset", fixed, reset_w + L.md)
      reaper.ImGui_BeginDisabled(ctx, locked)
      local differing = 0
      for _, row in ipairs(section.rows) do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        if row.label ~= "" then
          Theme.align(ctx)
          reaper.ImGui_Text(ctx, row.label)
        end
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        row.draw(control_w)
        reaper.ImGui_TableSetColumnIndex(ctx, 2)
        local at_default = row.is_default()
        if not at_default then differing = differing + 1 end
        if reset_button("Reset", "reset_" .. row.id, reset_w, at_default and "Already at its default" or nil,
            "Restore the default value") then
          row.reset()
          K.save_settings("engine")
        end
      end
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetColumnIndex(ctx, 1)
      if reset_button("Reset section", "reset_section_" .. section.id, section_reset_w,
          differing == 0 and "Already at its defaults" or nil, "Restore every setting of this section to its default") then
        section_to_reset = section
      end
      reaper.ImGui_EndDisabled(ctx)
      reaper.ImGui_EndTable(ctx)
    end

    local engine, detection, dsp = K.SETTINGS_SECTIONS[1], K.SETTINGS_SECTIONS[2], K.SETTINGS_SECTIONS[3]

    Theme.section_divider(ctx, engine.title, { color = P.yellow })
    if locked then
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.text_dim, K.LOCKED_REASON)
    end
    draw_form(engine)

    Theme.section_divider(ctx, detection.title, { color = P.yellow })
    draw_form(detection)

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if Theme.collapsing_header(ctx, dsp.title) then
      draw_form(dsp)
    end

    -- The confirm is the only modal: close Settings first
    if section_to_reset then
      reaper.ImGui_CloseCurrentPopup(ctx)
      K.request_settings_reset(section_to_reset)
    end

    Theme.section_divider(ctx, "Appearance & Options", { color = P.yellow })

    Theme.align(ctx)
    Theme.settings_widget(ctx, { label = "Theme Mode" })

    Theme.align(ctx)
    Theme.tooltip_setting_widget(ctx, { label = "Show Tooltips" })

    -- Analysis internals: extra canvas layers for checking what the detection did (off unless enabled here)
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if Theme.collapsing_header(ctx, "Diagnostics") then
      reaper.ImGui_Indent(ctx, L.md)
      Theme.align(ctx)
      K.layer_checkbox("Split Markers", "show_split_points")
      reaper.ImGui_Unindent(ctx, L.md)
    end

    Theme.section_divider(ctx, "Clear & Wipe", { color = P.red })

    -- Both buttons open a confirm modal (hence the ellipsis on Wipe); each is disabled with an inline reason
    local clear_text = "Clear Analysis & Envelope"
    local session_n = #state.session_order
    local wipe_text = string.format("Wipe %d %s…", session_n, plural(session_n, "Item", "Items"))
    local btn_w = math.max(text_w(clear_text), text_w(wipe_text)) + L.md * 2
    local clear_reason = (not state.notes or #state.notes == 0) and "No analysis to clear" or nil
    local wipe_reason = (session_n == 0) and "Pitched Items is empty" or nil

    Theme.align(ctx)
    reaper.ImGui_BeginDisabled(ctx, clear_reason ~= nil)
    local clear_clicked = reaper.ImGui_Button(ctx, clear_text .. "###reset_take", btn_w, 0)
    reaper.ImGui_EndDisabled(ctx)
    if clear_reason then
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.text_dim, clear_reason)
    elseif reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "Discards the analysis and the pitch envelope points of the active item")
    end
    if clear_clicked then
      -- The confirm is the only modal: close Settings first
      reaper.ImGui_CloseCurrentPopup(ctx)
      request_clear_confirm()
    end

    Theme.align(ctx)
    K.push_danger(P)
    reaper.ImGui_BeginDisabled(ctx, wipe_reason ~= nil)
    local wipe_clicked = reaper.ImGui_Button(ctx, wipe_text .. "###reset_all", btn_w, 0)
    reaper.ImGui_EndDisabled(ctx)
    K.pop_danger()
    if wipe_reason then
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.text_dim, wipe_reason)
    elseif reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "Removes every item from Pitched Items and clears their pitch envelopes and saved analysis")
    end
    if wipe_clicked then
      reaper.ImGui_CloseCurrentPopup(ctx)
      request_wipe_confirm()
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Changes apply live: the button only closes the window
    local btn_close_w = text_w("Close") + L.md * 2
    Theme.hcenter(ctx, btn_close_w)
    if reaper.ImGui_Button(ctx, "Close##settings_close", btn_close_w, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_info_modal()
  local P = Theme.get_palette()
  local L = Theme.layout

  if App.show_info_modal then
    reaper.ImGui_OpenPopup(ctx, "Keyboard Shortcuts & Help##info_modal")
    App.show_info_modal = false
  end

  Theme.center_next_window(ctx, L.modal_lg.w, L.modal_lg.h, reaper.ImGui_Cond_Appearing())
  K.fit_modal(ctx)
  Theme.modal_scrim(ctx, "Keyboard Shortcuts & Help##info_modal")
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Keyboard Shortcuts & Help##info_modal", true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    -- Both columns are fixed, sized once per draw from the widest key and the widest description, so no text can
    -- push the window edge and the auto-resizing window cannot oscillate
    local key_w, desc_w = 0, 0
    for _, section in ipairs(K.INFO_SECTIONS) do
      for _, row in ipairs(section.rows) do
        key_w = math.max(key_w, (reaper.ImGui_CalcTextSize(ctx, row[1])) or 0)
        desc_w = math.max(desc_w, (reaper.ImGui_CalcTextSize(ctx, row[2])) or 0)
      end
    end
    key_w = key_w + L.md
    desc_w = desc_w + L.md
    local terms_key = "Terms"
    local terms_w = ((reaper.ImGui_CalcTextSize(ctx, terms_key)) or 0) + L.md + ((reaper.ImGui_CalcTextSize(ctx, K.INFO_TERMS)) or 0) + L.md
    local table_flags = reaper.ImGui_TableFlags_SizingFixedFit() | reaper.ImGui_TableFlags_NoHostExtendX()
    local fixed = reaper.ImGui_TableColumnFlags_WidthFixed()

    local function shortcut_row(key_str, desc_str)
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetColumnIndex(ctx, 0)
      reaper.ImGui_TextColored(ctx, P.accent, key_str)
      reaper.ImGui_TableSetColumnIndex(ctx, 1)
      reaper.ImGui_Text(ctx, desc_str)
    end

    for i, section in ipairs(K.INFO_SECTIONS) do
      if i > 1 then reaper.ImGui_Dummy(ctx, 0, L.md) end
      Theme.section_divider(ctx, section.title, { color = P.yellow })
      if reaper.ImGui_BeginTable(ctx, "##info_rows_" .. i, 2, table_flags) then
        reaper.ImGui_TableSetupColumn(ctx, "##key", fixed, key_w)
        reaper.ImGui_TableSetupColumn(ctx, "##desc", fixed, desc_w)
        for _, row in ipairs(section.rows) do
          shortcut_row(row[1], row[2])
        end
        reaper.ImGui_EndTable(ctx)
      end
    end

    -- The verbs the buttons use, in one line (a one-column table keeps the text aligned with the rows above)
    reaper.ImGui_Dummy(ctx, 0, L.md)
    if reaper.ImGui_BeginTable(ctx, "##info_terms", 1, table_flags) then
      reaper.ImGui_TableSetupColumn(ctx, "##terms", fixed, terms_w)
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetColumnIndex(ctx, 0)
      reaper.ImGui_TextColored(ctx, P.accent, terms_key)
      reaper.ImGui_SameLine(ctx, 0, L.md)
      reaper.ImGui_Text(ctx, K.INFO_TERMS)
      reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local btn_close_w = ((reaper.ImGui_CalcTextSize(ctx, "Close")) or 0) + L.md * 2
    Theme.hcenter(ctx, btn_close_w)
    if reaper.ImGui_Button(ctx, "Close##info_close", btn_close_w, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

--- The one confirm modal (see request_confirm): consequence and count in the body, Cancel first,
--- Esc = Cancel, danger-styled confirm button. Called inside the main window's `if visible` block.
local function draw_confirm_modal()
  local c = state.confirm
  if not c then return end
  local P = Theme.get_palette()
  local L = Theme.layout
  -- Stable ID after ###: the visible title may carry the item name
  local popup_name = c.title .. "###confirm_" .. c.id

  if c.open_pending then
    reaper.ImGui_OpenPopup(ctx, popup_name)
    c.open_pending = false
    c.opened = true
  end

  Theme.center_next_window(ctx, L.modal_sm.w, L.modal_sm.h, reaper.ImGui_Cond_Appearing())
  K.fit_modal(ctx)
  Theme.modal_scrim(ctx, popup_name)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, popup_name, true, reaper.ImGui_WindowFlags_NoResize())
  local confirmed = false
  if visible then
    if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    for i, line in ipairs(c.body_lines) do
      if i > 1 then reaper.ImGui_Dummy(ctx, 0, L.sm) end
      reaper.ImGui_TextWrapped(ctx, line)
    end

    -- Button row pinned to the bottom of the modal, centred like the Close rows
    local cancel_w = reaper.ImGui_CalcTextSize(ctx, "Cancel") + L.md * 2
    local confirm_w = reaper.ImGui_CalcTextSize(ctx, c.confirm_label) + L.md * 2
    local btn_h = reaper.ImGui_GetFrameHeight(ctx)
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    if avail_h > btn_h + L.lg then
      reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + avail_h - btn_h)
    else
      reaper.ImGui_Dummy(ctx, 0, L.lg)
    end
    Theme.hcenter(ctx, cancel_w + L.md + confirm_w)

    if reaper.ImGui_Button(ctx, "Cancel###confirm_cancel", cancel_w, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SetItemDefaultFocus(ctx)
    reaper.ImGui_SameLine(ctx, 0, L.md)

    K.push_danger(P)
    if reaper.ImGui_Button(ctx, c.confirm_label .. "###confirm_ok", confirm_w, 0) then
      confirmed = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    K.pop_danger()

    reaper.ImGui_EndPopup(ctx)
  end

  -- The action runs once, after the modal was closed and its style / popup stacks are balanced
  if confirmed then c.on_confirm() end

  if c.opened and not reaper.ImGui_IsPopupOpen(ctx, popup_name) then
    Theme.modal_scrim(ctx, popup_name) -- not open any more: releases the scrim's first-frame latch
    state.confirm = nil
  end
end

--- Number of notes the note-level commands (Reset, R / Delete) act on: the selection, if any.
local function count_selected_notes()
  if not state.notes then return 0 end
  local n = 0
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then n = n + 1 end
  end
  if n == 0 and state.selected_note and state.notes[state.selected_note] then n = 1 end
  return n
end

local function count_modified_notes()
  local n = 0
  for _, note in ipairs(state.notes or {}) do
    if is_note_modified(note) then n = n + 1 end
  end
  return n
end

--- True when the take of the current target still exists, i.e. an edit will be written inside an undo block.
local function target_take_exists()
  return state.target_take_guid ~= nil and resolve_take_by_guid(state.target_take_guid, true) ~= nil
end

--- Run a note command and say what happened in the status line. The top bar's action buttons, their keys (S, Q, X, M),
--- the note menu and the pitch-zone double-click all come through here, so they report alike. A refusal or a
--- no-op says why; a success names the count and promises an undo point only when one was written.
---   id        "snap", "quantize", "split" (at the edit cursor) or "merge"
---   note_idx  the note to split (default: the primary selected note)
K.note_action = function(id, note_idx)
  local undo_hint = string.format(" %s+Z to undo", K.MOD_LABEL)
  if id == "merge" then
    local count = count_selected_notes()
    local ok, info = merge_selected_notes()
    if not ok then
      set_status(info)
    elseif info then
      set_status(string.format("Merged %d notes.%s", count, undo_hint))
    end
    return
  end
  if id == "split" then
    local _, item = get_target_take()
    if not item then
      set_status("This item is no longer in the project")
      return
    end
    local cursor = reaper.GetCursorPosition() - reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ok, info = split_note_at(note_idx or state.selected_note, cursor)
    if not ok then
      set_status(info)
    elseif info then
      set_status("Split the note at the edit cursor." .. undo_hint)
    end
    return
  end
  if count_selected_notes() == 0 then
    set_status("Select a note first")
    return
  end
  if id == "snap" then
    local n, written = snap_selected_note()
    if n == 0 then
      set_status("Already at the nearest semitone")
    elseif written then
      set_status(string.format("Snapped %d %s.%s", n, plural(n, "note", "notes"), undo_hint))
    end
  elseif id == "quantize" then
    local n, written = quantize_selected_notes_to_scale()
    if n == 0 then
      set_status("Already in scale")
    elseif written then
      set_status(string.format("Quantized %d %s to %s %s.%s", n, plural(n, "note", "notes"),
        SCALE_KEYS[state.key_idx].display, SCALE_DEFINITIONS[state.scale_idx].name, undo_hint))
    end
  end
end

--- Header Analyze / Re-Analyze: analyze right away, unless it would discard the user's edits.
local function request_analyze()
  local edited = count_modified_notes()
  if edited == 0 then
    start_analysis()
    return
  end
  local guid = state.target_take_guid
  local name = state.target_take_name or "this item"
  request_confirm({
    id = "reanalyze",
    title = string.format("Re-analyze %s?", name),
    body_lines = {
      string.format("This replaces the detected notes and discards your edits to %d %s.",
        edited, plural(edited, "note", "notes")),
      string.format("%s+Z restores them once the analysis has finished.", K.MOD_LABEL),
    },
    confirm_label = "Re-Analyze",
    on_confirm = function()
      -- The modal names one item: never analyze another one if the target changed meanwhile
      if state.target_take_guid ~= guid then
        set_status("The active item changed. Nothing was re-analyzed.")
        return
      end
      start_analysis()
      if state.is_analyzing then
        set_status(string.format("Re-analyzing %s…", name))
      end
    end,
  })
end

--- Header Reset. With a selection (or a single note) it acts right away; resetting every note of a
--- phrase that has edits asks first. sel_n = selected notes, note_n = all notes.
local function request_reset(sel_n, note_n)
  local guid = state.target_take_guid
  local function run(scope_text)
    local changed = reset_selected_note()
    if not changed then
      set_status("Nothing to reset: no edited notes.")
    elseif target_take_exists() then
      set_status(string.format("Reset %s. %s+Z to undo", scope_text, K.MOD_LABEL))
    else
      set_status(string.format("Reset %s.", scope_text))
    end
  end

  if sel_n > 0 then
    run(string.format("%d selected %s", sel_n, plural(sel_n, "note", "notes")))
    return
  end
  local edited = count_modified_notes()
  if note_n <= 1 or edited == 0 then
    run(string.format("%d %s", note_n, plural(note_n, "note", "notes")))
    return
  end
  local lines = {
    string.format("Reset all %d notes to their detected pitch?", note_n),
    string.format("This discards your edits to %d %s.", edited, plural(edited, "note", "notes")),
  }
  if target_take_exists() then
    lines[#lines + 1] = string.format("%s+Z restores them.", K.MOD_LABEL)
  end
  request_confirm({
    id = "reset_all_notes",
    title = "Reset all notes?",
    body_lines = lines,
    confirm_label = string.format("Reset %d Notes", note_n),
    on_confirm = function()
      if state.target_take_guid ~= guid then
        set_status("The active item changed. Nothing was reset.")
        return
      end
      run(string.format("all %d notes", note_n))
    end,
  })
end

-- Space forwarding (HC6). While the window is focused it has the keyboard, so Space (and its Shift,
-- Ctrl/Cmd and Alt chords) is forwarded to the command the user bound to it in REAPER's Main section.
-- The bindings are read once, at startup, from reaper-kb.ini (`KEY <mods> 32 <command> <section>`;
-- mods 1 = plain, 5 = Shift, 9 = Ctrl/Cmd, 17 = Alt; section 0 = Main). Plain Space falls back to
-- Transport: Play/stop.

--- Returns { [kb_mods] = command_id } for Space in the Main section; { [1] = 40044 } when unbound.
local function read_space_bindings()
  local cmds = {}
  local resource_path = reaper.GetResourcePath()
  if resource_path and resource_path ~= "" then
    local opened, fh = pcall(io.open, resource_path .. "/reaper-kb.ini", "r")
    if opened and fh then
      local read_ok, text = pcall(fh.read, fh, "a")
      fh:close()
      if read_ok and text then
        for line in text:gmatch("[^\r\n]+") do
          local mods_str, cmd_str, section = line:match("^KEY%s+(%d+)%s+32%s+(%S+)%s+(%d+)")
          local mods = tonumber(mods_str)
          if mods and section == "0" and not cmds[mods] then
            local cmd
            if cmd_str:sub(1, 1) == "_" then
              cmd = reaper.NamedCommandLookup(cmd_str)
            else
              cmd = tonumber(cmd_str)
            end
            if cmd and cmd > 0 then cmds[mods] = cmd end
          end
        end
      end
    end
  end
  cmds[1] = cmds[1] or K.SPACE_FALLBACK_CMD
  return cmds
end

local space_cmds = read_space_bindings()
local space_chords = nil  -- { { kb_mods, chord } ... }, built on first use

--- Forward Space chords to the user's bound commands. Runs at window level (after the modals), so it also
--- works with no notes and while analysing; does nothing while a modal or popup is open, a widget is
--- active, or the window is not focused.
local function forward_space_to_reaper()
  if not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
     or reaper.ImGui_IsAnyItemActive(ctx)
     or reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId()) then
    return
  end
  if not space_chords then
    local space = reaper.ImGui_Key_Space()
    space_chords = {
      { 1, space },
      { 5, reaper.ImGui_Mod_Shift() | space },
      { 9, reaper.ImGui_Mod_Ctrl() | space },
      { 17, reaper.ImGui_Mod_Alt() | space },
    }
  end
  for _, entry in ipairs(space_chords) do
    local cmd = space_cmds[entry[1]]
    if cmd and reaper.ImGui_Shortcut(ctx, entry[2]) then
      reaper.Main_OnCommand(cmd, 0)
    end
  end
end

--- Forward Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z to REAPER's Undo / Redo: ReaImGui keeps the keys of a focused
--- window, so REAPER never sees them otherwise. Same gate as the Space forwarding, and not during a mouse
--- gesture on the canvas. A pending arrow-key nudge is committed first, so the undo takes that nudge back.
local function forward_undo_to_reaper()
  if state.drag or state.edge_drag or state.marquee or state.point_drag
     or not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
     or reaper.ImGui_IsAnyItemActive(ctx)
     or reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId()) then
    return
  end
  local undo_chord = reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_Z()
  local cmd
  if reaper.ImGui_Shortcut(ctx, undo_chord) then
    cmd = K.UNDO_CMD
  elseif reaper.ImGui_Shortcut(ctx, reaper.ImGui_Mod_Shift() | undo_chord) then
    cmd = K.REDO_CMD
  end
  if cmd then
    flush_nudge_burst()
    reaper.Main_OnCommand(cmd, 0)
  end
end

-- What the files loaded after this one use
App.BODY = BODY
App.count_selected_notes = count_selected_notes
App.draw_body_split = draw_body_split
App.draw_confirm_modal = draw_confirm_modal
App.draw_info_modal = draw_info_modal
App.draw_settings_modal = draw_settings_modal
App.forward_space_to_reaper = forward_space_to_reaper
App.forward_undo_to_reaper = forward_undo_to_reaper
App.request_analyze = request_analyze
App.request_reset = request_reset
