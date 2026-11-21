-- @description Fancy Pitch Correct
-- @author Fancy Scripts
-- @version 2.14.1
-- @changelog
--   No change in how the script works or looks
--   Under the hood: the script is split into several files (the pitch_correct folder next to it), installed and updated with it
--   The shared library files (_lib) now come from the "Fancy Scripts Library" package: install it once from ReaPack
-- @about
--   Native Lua pitch correction and tracking.
--   Requirements: REAPER 7.0+, ReaImGui, Fancy Scripts Library
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] pitch_correct/*.lua

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Pitch Correct -- Missing ReaImGui", 0)
  return
end

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "?.lua;" .. script_dir .. "../_lib/?.lua;" .. package.path
if not reaper.file_exists(script_dir .. "../_lib/theme.lua") then
  reaper.ShowMessageBox(
    "This script needs the \"Fancy Scripts Library\" package.\n\n"
    .. "Install it via Extensions > ReaPack > Browse Packages, then run this script again.",
    "Fancy Pitch Correct -- Missing library", 0)
  return
end

local Theme = require("theme")
local JSON  = require("json")

local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
local ctx = reaper.ImGui_CreateContext('Fancy Pitch Correct', dock_flag)
local fonts = Theme.create_fonts(ctx)
Theme.attach_fonts(ctx, fonts)


local VOCAL_RANGES = {
  { name = "Generic Vocal", min = 65,  max = 1000 },
  { name = "Soprano",       min = 250, max = 1200 },
  { name = "Alto",          min = 170, max = 800  },
  { name = "Tenor",         min = 130, max = 500  },
  { name = "Bass",          min = 80,  max = 350  }
}

local DETECTION_MODES = {
  { name = "Clean / Strict",   threshold = 0.08 },
  { name = "Standard",         threshold = 0.15 },
  { name = "Breathy / Lenient", threshold = 0.25 }
}

local QUALITY_MODES = {
  { name = "High Quality (Offline)", block = 2048, hop = 256 },
  { name = "Standard (Realtime)",    block = 1024, hop = 512 },
  { name = "Low Latency",            block = 512,  hop = 256 }
}

-- Discrete choices for Settings > Advanced DSP (every QUALITY_MODES value is listed); the hop never exceeds the block
local BLOCK_SIZES = { 256, 512, 1024, 2048, 4096 }
local HOP_SIZES   = { 64, 128, 256, 512, 1024 }

local SCALE_KEYS = {
  { name = "C",       display = "C" },
  { name = "C# / Db", display = "C#" },
  { name = "D",       display = "D" },
  { name = "D# / Eb", display = "D#" },
  { name = "E",       display = "E" },
  { name = "F",       display = "F" },
  { name = "F# / Gb", display = "F#" },
  { name = "G",       display = "G" },
  { name = "G# / Ab", display = "G#" },
  { name = "A",       display = "A" },
  { name = "A# / Bb", display = "A#" },
  { name = "B",       display = "B" }
}

local SCALE_DEFINITIONS = {
  { name = "Major",            intervals = {0, 2, 4, 5, 7, 9, 11} },
  { name = "Natural Minor",    intervals = {0, 2, 3, 5, 7, 8, 10} },
  { name = "Dorian",           intervals = {0, 2, 3, 5, 7, 9, 10} },
  { name = "Pentatonic",       intervals = {0, 2, 4, 7, 9} },
  { name = "Minor Pentatonic", intervals = {0, 3, 5, 7, 10} },
  { name = "Chromatic",        intervals = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11} },
}

-- Discover available pitch shift modes at startup
local PITCH_SHIFT_MODES = {}
local DEFAULT_PITCH_MODE_IDX = 1
do
  local mode_idx = 0
  local consecutive_fails = 0
  while mode_idx < 64 do
    local retval, name = reaper.EnumPitchShiftModes(mode_idx)
    if not retval then
      consecutive_fails = consecutive_fails + 1
      if consecutive_fails >= 5 then break end
    else
      consecutive_fails = 0
      -- Supported modes return a valid name; unsupported modes return nil / empty string
      if name and name ~= "" then
        local submodes = {}
        local sub_idx = 0
        while sub_idx < 128 do
          local sub_name = reaper.EnumPitchShiftSubModes(mode_idx, sub_idx)
          if not sub_name or sub_name == "" then break end
          local packed = (mode_idx << 16) | sub_idx
          table.insert(submodes, { name = sub_name, value = packed })
          sub_idx = sub_idx + 1
        end
        if #submodes > 0 then
          table.insert(PITCH_SHIFT_MODES, { name = name, submodes = submodes })
        else
          local packed = (mode_idx << 16)
          table.insert(PITCH_SHIFT_MODES, { name = name, submodes = { { name = "Default", value = packed } } })
        end
      end
    end
    mode_idx = mode_idx + 1
  end
end

local PITCHMODE_FLAT = { { name = "Project Default", value = -1 } }
for _, mode in ipairs(PITCH_SHIFT_MODES) do
  for _, sub in ipairs(mode.submodes) do
    table.insert(PITCHMODE_FLAT, { name = mode.name .. " - " .. sub.name, value = sub.value })
  end
end

-- Find best Soloist Monophonic entry in the flat list:
-- 1. Prefer exact "Soloist ... - Monophonic" (standard mono, not Mid/Side or Multi-Stereo)
for i, entry in ipairs(PITCHMODE_FLAT) do
  local lower = entry.name:lower()
  if lower:find("soloist") and lower:match("%-%s*monophonic$") then
    DEFAULT_PITCH_MODE_IDX = i
    break
  end
end

-- 2. Fallback to any entry with both "soloist" and "mono"
if DEFAULT_PITCH_MODE_IDX == 1 then
  for i, entry in ipairs(PITCHMODE_FLAT) do
    local lower = entry.name:lower()
    if lower:find("soloist") and lower:find("mono") then
      DEFAULT_PITCH_MODE_IDX = i
      break
    end
  end
end

-- Every label each combo can show, so its width comes from the longest one (Theme.calc_combo_width)
local COMBO_LABELS = {}
do
  local function labels_of(list, field)
    local out = {}
    for i, item in ipairs(list) do out[i] = item[field] end
    return out
  end
  COMBO_LABELS.keys = labels_of(SCALE_KEYS, "display")  -- the top bar's Key combo previews the short name ...
  COMBO_LABELS.key_names = labels_of(SCALE_KEYS, "name") -- ... and lists the long one
  COMBO_LABELS.scales = labels_of(SCALE_DEFINITIONS, "name")
  COMBO_LABELS.pitchmodes = labels_of(PITCHMODE_FLAT, "name")
  COMBO_LABELS.ranges = labels_of(VOCAL_RANGES, "name")
  COMBO_LABELS.detection = labels_of(DETECTION_MODES, "name")
  COMBO_LABELS.quality = labels_of(QUALITY_MODES, "name")
end

-------------------------------------------------------------------------------
-- THE PARTS OF THE SCRIPT (pitch_correct/*.lua)
-------------------------------------------------------------------------------

-- Every file of pitch_correct/ shares the App table: it takes what it needs from it and adds what later files use.
-- The order below is the order they depend on each other, so it must not change.
local App = require("pitch_correct.app")
App.show_settings_modal = false
App.show_info_modal = false
App.BLOCK_SIZES = BLOCK_SIZES
App.COMBO_LABELS = COMBO_LABELS
App.ctx = ctx
App.DEFAULT_PITCH_MODE_IDX = DEFAULT_PITCH_MODE_IDX
App.DETECTION_MODES = DETECTION_MODES
App.fonts = fonts
App.HOP_SIZES = HOP_SIZES
App.JSON = JSON
App.PITCHMODE_FLAT = PITCHMODE_FLAT
App.QUALITY_MODES = QUALITY_MODES
App.SCALE_DEFINITIONS = SCALE_DEFINITIONS
App.SCALE_KEYS = SCALE_KEYS
App.Theme = Theme
App.VOCAL_RANGES = VOCAL_RANGES

for _, part in ipairs({
  "state", "dsp", "analysis", "notes", "session", "note_edit", "segmentation", "canvas_support",
  "canvas_input", "canvas_draw", "canvas_menus", "canvas", "item_actions", "panels", "top_bar"
}) do
  require("pitch_correct." .. part)
end

local K, state = App.K, App.state
local BODY = App.BODY
local clear_interaction_state = App.clear_interaction_state
local draw_body_split = App.draw_body_split
local draw_confirm_modal = App.draw_confirm_modal
local draw_graph = App.draw_graph
local draw_header = App.draw_header
local draw_info_modal = App.draw_info_modal
local draw_settings_modal = App.draw_settings_modal
local flush_nudge_burst = App.flush_nudge_burst
local forward_space_to_reaper = App.forward_space_to_reaper
local forward_undo_to_reaper = App.forward_undo_to_reaper
local get_take_guid = App.get_take_guid
local get_target_take = App.get_target_take
local hdr_min_content_w = App.hdr_min_content_w
local measure_header_static = App.measure_header_static
local note_own_write = App.note_own_write
local plural = App.plural
local process_analysis_step = App.process_analysis_step
local resolve_take_by_guid = App.resolve_take_by_guid
local scan_project_for_saved_takes = App.scan_project_for_saved_takes
local service_nudge_burst = App.service_nudge_burst
local set_status = App.set_status
local switch_active_target = App.switch_active_target
local sync_with_project = App.sync_with_project

-------------------------------------------------------------------------------
-- FRAME LOOP
-------------------------------------------------------------------------------
local hdr_was_docked = nil    -- IsWindowDocked of the previous frame (nil until known): size constraints are for floating windows only
local function loop_body()
  -- What REAPER answered earlier stays valid only while the project state is the same: check that first, before
  -- anything reads it (the target of the previous frame is not trusted either)
  K.refresh_project_cache()
  state.frame.guid, state.frame.take, state.frame.item = nil, nil, nil

  -- Follow REAPER's undo / redo / project changes (one cheap count check per frame)
  sync_with_project()
  process_analysis_step()
  K.stale_check_step(ctx)

  local P = Theme.get_palette()
  local L = Theme.layout
  local nc, nv = Theme.push(ctx, P)
  local pushed_font = Theme.push_font(ctx, fonts.default)

  -- The window itself has no padding: the canvas and the Pitched Items panel run to its left, right and bottom
  -- edges. ImGui takes a window's padding when Begin is called, so it is 0 for that call only (see below): the top
  -- bar keeps pad_x / pad_v around it by hand, and the popups opened from the window get the usual padding.
  local pad_x = L.md + L.xs
  local pad_v = L.sm + L.xs
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), L.md, pad_v)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  nv = nv + 2

  -- First use: 920 x 620, wider when the top bar on two rows needs it, so it opens
  -- unabbreviated. A saved size wins over this (Cond_FirstUseEver)
  App.hdr_static = App.hdr_static or measure_header_static()
  Theme.center_next_window(ctx, math.max(920, math.ceil(hdr_min_content_w(App.hdr_static, true) + pad_x * 2)), 620,
    reaper.ImGui_Cond_FirstUseEver())
  -- A floating window never gets narrower, nor shorter, than the narrowest top bar needs (its last plan: every
  -- group on a row of its own); a docked one takes its dock's size, and the bar is clipped (see TOP BAR)
  if hdr_was_docked == false then
    local min_content_w, min_rows = hdr_min_content_w(App.hdr_static)
    reaper.ImGui_SetNextWindowSizeConstraints(ctx,
      min_content_w + pad_x * 2,
      App.hdr_static.frame_h + pad_v * (min_rows + 1) + App.hdr_static.row_h * min_rows,
      K.SIZE_UNBOUNDED, K.SIZE_UNBOUNDED)
  end
  local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoNavInputs()

  local visible, open = reaper.ImGui_Begin(ctx, 'Fancy Pitch Correct', true, win_flags)
  -- The window has taken its (zero) padding: everything opened from here on gets the usual one
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), pad_x, pad_v)
  -- HC5: cached right after Begin (IsWindowDocked reports the current window). A docked window never
  -- closes on Esc. Whether a popup was already open when the frame started is remembered too, so the
  -- press that closes a modal can never also reach the window-level Esc handler below.
  local docked = visible and reaper.ImGui_IsWindowDocked(ctx) or false
  hdr_was_docked = docked
  local popup_open_at_start = visible and reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
  if visible then
    -- Automatic selection tracking from REAPER (edge-triggered): switch target only when the first
    -- selected audio item CHANGES (or the current target no longer exists). A sidebar click sets the
    -- target without touching REAPER's selection, so it must not be overridden by the old selection.
    if not state.is_analyzing then
      local cur_sel_item = reaper.GetSelectedMediaItem(0, 0)
      local cur_sel_take = cur_sel_item and reaper.GetActiveTake(cur_sel_item)
      local cur_guid = nil
      local sel_is_midi = cur_sel_take ~= nil and reaper.TakeIsMIDI(cur_sel_take)
      if cur_sel_take and not sel_is_midi then
        cur_guid = get_take_guid(cur_sel_take)
      end
      -- Why the selected item cannot be a target (the status pill and the badge tooltip say it); nil for an
      -- audio item or no selection
      state.selection_issue = nil
      if cur_sel_item and not cur_guid then
        state.selection_issue = sel_is_midi and BODY.issue_midi or BODY.issue_no_audio
      end
      local sel_changed = (cur_guid ~= state.last_seen_sel_guid)
      state.last_seen_sel_guid = cur_guid

      if cur_guid and cur_guid ~= state.target_take_guid then
        local target_lost = state.target_take_guid ~= nil
          and not resolve_take_by_guid(state.target_take_guid, true)
        if sel_changed or target_lost then
          -- Commit a pending arrow-key nudge to the take being left
          flush_nudge_burst()
          local switched = switch_active_target(cur_guid, cur_sel_take)
          if not switched then
            state.target_take_guid = cur_guid
            state.target_take_name = reaper.GetTakeName(cur_sel_take) or "Selected Item"
            state.results = {}
            state.notes = nil
            state.analysis_empty = false
            state.selected_note = nil
            state.selected_notes = {}
            state.hovered_note = nil
            state.drag = nil
            state.marquee = nil
            state.point_drag = nil
            state.context_point = nil
            state.hovered_point = nil
            state.point_ghost = nil
            state.points_hover_note = nil
            state.points_zoom_hint = false
            K.reset_view()
            state.start_time = 0
            state.item_len = reaper.GetMediaItemInfo_Value(cur_sel_item, "D_LENGTH")
            state.end_time = state.item_len
          end
        end
      end
    end

    -- The target, asked once per frame: the top bar, canvas and sidebar read it from state.frame
    local target_take, target_item = get_target_take()
    state.frame.guid, state.frame.take, state.frame.item = state.target_take_guid, target_take, target_item
    local has_target = (target_take ~= nil and state.target_take_name ~= nil)
    local has_notes = (state.notes and #state.notes > 0)

    -- 1. Top bar: every control (widths and wrapping: see TOP BAR above). The window has no padding, so the bar
    -- brings its own margins: pad_v above it, pad_x on its left (the indent) and on its right (draw_header)
    reaper.ImGui_SetCursorPosY(ctx, (reaper.ImGui_GetCursorPosY(ctx) or 0) + pad_v)
    reaper.ImGui_Indent(ctx, pad_x)
    if draw_header(P, docked, has_target, has_notes, target_take, target_item, pad_x) then
      open = false
    end
    reaper.ImGui_Unindent(ctx, pad_x)

    -- 2. Main Body: Canvas + (optional) Pitched Items Sidebar. It takes everything below the top bar: there is
    -- no bottom row (the status line is a pill on the canvas, see K.canvas_status)
    local avail_w, body_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local total_h = math.max(60, body_h)

    -- The panel is drawn only when the window has room for it beside a usable canvas; otherwise the
    -- canvas takes the whole body without touching the saved open / closed preference
    local sidebar_fits = avail_w >= BODY.min_graph_w + BODY.splitter_w + BODY.min_sidebar_w
    state.sidebar_fits = sidebar_fits

    -- H: show or hide the panel's Shortcuts list. Same guards as the window-level Esc below (no popup, no active
    -- widget or text entry), exact modifiers and no key repeat; it works with no notes and on a bypassed item too.
    if not popup_open_at_start
       and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and not reaper.ImGui_IsAnyItemActive(ctx)
       and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_H()) then
      K.toggle_shortcuts()
    end

    local split_drawn = false
    if total_h > 80 then
      if state.sidebar_open and sidebar_fits then
        split_drawn = draw_body_split(P, avail_w, total_h)
      else
        draw_graph(ctx, avail_w, total_h)   -- panel hidden, or no room for it: the canvas takes the whole body
      end
    elseif body_h >= (reaper.ImGui_GetTextLineHeight(ctx) or 0) then
      -- Too short for the canvas: say why in the space the body would have had (a window with less room than
      -- one text line shows nothing)
      local msg = "Window too short: make it taller to edit notes"
      local msg_w, msg_h = reaper.ImGui_CalcTextSize(ctx, msg)
      msg_w, msg_h = msg_w or 0, msg_h or 0
      local msg_x, msg_y = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_Dummy(ctx, avail_w, body_h)
      reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
        msg_x + math.max(0, (avail_w - msg_w) * 0.5), msg_y + (body_h - msg_h) * 0.5, P.text_dim, msg)
    end
    state.sidebar_tabled = split_drawn
  end

  -- Pop custom window padding & item spacing before rendering modals
  reaper.ImGui_PopStyleVar(ctx, 2)
  nv = nv - 2

  -- 3. Render Modals (ReaImGui's Begin calls End itself when it returns false)
  if visible then
    draw_settings_modal()
    draw_info_modal()
    draw_confirm_modal()

    -- HC5: Esc, innermost first, only through Shortcut(). Modals own Esc while open (handled inside each
    -- BeginPopupModal); an active edit consumes it itself. What is left: the note selection, then the
    -- window, which closes on Esc only when it is floating.
    local esc_used = K.drag_hot.esc_used   -- this frame's Esc cancelled a slider drag: it is spent
    K.drag_hot.esc_used = false
    if not popup_open_at_start
       and not esc_used
       and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and not reaper.ImGui_IsAnyItemActive(ctx)
       and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      if state.selected_note or next(state.selected_notes) ~= nil then
        state.selected_note = nil
        state.selected_notes = {}
        state.drag = nil
        state.marquee = nil
      elseif not docked then
        open = false
      end
    end

    -- HC6: Space and its modifier chords go to the user's own REAPER bindings
    forward_space_to_reaper()

    -- Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z go to REAPER's Undo / Redo
    forward_undo_to_reaper()

    reaper.ImGui_End(ctx)
  end

  -- Arrow-key nudge burst: commit when the key is released; always before the window closes or hides,
  -- or a popup / modal opens
  local popup_open = visible and reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
  service_nudge_burst(not visible or not open or popup_open)

  -- The note tone follows a pitch drag, once per frame whatever was drawn (a hidden window or an open modal must
  -- still let a fade-out finish). It gets a pitch only while the left button is physically down: the drag ends in
  -- draw_graph, which does not run while the window is hidden, so a release then would leave state.drag set
  local tone_pitch = nil
  local drag = state.drag
  if state.note_tone and drag and drag.zone == "pitch" and drag.dirty and not drag.shift_mode
      and reaper.ImGui_IsMouseDown(ctx, 0) then
    local note = state.notes and state.notes[drag.note_idx]
    tone_pitch = note and note.controls and note.controls.center_pitch or nil
  end
  K.tone_tick(tone_pitch)

  Theme.pop_font(ctx, pushed_font)
  Theme.pop(ctx, nc, nv)

  return open
end

--- The window drawn while state.fatal is set (a frame failed): minimal and self-contained, so whatever broke the
--- normal window cannot break this one. It says what happened, in the user's words, and offers Retry (back to the
--- normal window next frame) and Close. Returns false when the script should end.
K.draw_fatal = function()
  local P = Theme.get_palette()
  local L = Theme.layout
  local fatal = state.fatal
  local keep_open = true
  local nc, nv = Theme.push(ctx, P)
  local pushed_font = Theme.push_font(ctx, fonts.default)
  Theme.center_next_window(ctx, L.modal_sm.w, L.modal_sm.h, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, 'Fancy Pitch Correct', true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoNavInputs())
  if visible then
    reaper.ImGui_TextWrapped(ctx, fatal.message)
    if fatal.count > 1 then
      reaper.ImGui_Dummy(ctx, 0, L.sm)
      reaper.ImGui_TextWrapped(ctx, K.FATAL_AGAIN_TEXT)
    end
    reaper.ImGui_Dummy(ctx, 0, L.lg)
    local retry_w = reaper.ImGui_CalcTextSize(ctx, "Retry") + L.md * 2
    local close_w = reaper.ImGui_CalcTextSize(ctx, "Close") + L.md * 2
    if reaper.ImGui_Button(ctx, "Retry###fatal_retry", retry_w, 0) then
      -- Back to the normal window: an analysis or gesture that was in flight is dropped, nothing is written
      state.fatal = nil
      K.cancel_analysis()
      clear_interaction_state()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_Button(ctx, "Close###fatal_close", close_w, 0) then keep_open = false end
    -- HC5: Esc closes a floating window only
    if not reaper.ImGui_IsWindowDocked(ctx) and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      keep_open = false
    end
    reaper.ImGui_End(ctx)
  end
  Theme.pop_font(ctx, pushed_font)
  Theme.pop(ctx, nc, nv)
  return keep_open and open
end

--- One frame of the window, every cycle. A frame that fails does not end the script: the failure is logged to the
--- console (for support), the running analysis is cancelled (its audio accessor must never outlive a failed
--- frame) and the window switches to K.draw_fatal's message. If that message cannot be drawn either, the
--- console line is all that is left and the script stops.
local function loop()
  local ok, open
  if state.fatal then
    ok, open = pcall(K.draw_fatal)
    if not ok then
      reaper.ShowConsoleMsg("Fancy Pitch Correct Error: the error window failed as well: " .. tostring(open) .. "\n")
      pcall(K.cancel_analysis)
      pcall(K.tone_kill)
      return
    end
  else
    ok, open = xpcall(loop_body, debug.traceback)
    if ok then
      state.error_streak = 0
    else
      reaper.ShowConsoleMsg("Fancy Pitch Correct Error: " .. tostring(open) .. "\n")
      pcall(K.cancel_analysis)
      pcall(K.tone_kill)
      if state.undo_open then   -- the frame failed inside apply_envelope_to_take: close its undo block
        state.undo_open = false
        pcall(reaper.Undo_EndBlock, "Apply Pitch Correction (interrupted)", -1)
      end
      K.drop_project_cache()    -- what the failed frame asked REAPER is not trusted any more
      state.clipper = nil       -- nor is a list clipper it may have left begun (a new one is made when needed)
      state.error_streak = state.error_streak + 1
      state.fatal = { message = K.FATAL_TEXT, count = state.error_streak }
      open = true
    end
  end

  if open then
    reaper.defer(loop)
  else
    pcall(K.cancel_analysis)   -- closed while analysing: stop reading audio before the script ends
    pcall(K.tone_kill)         -- and never leave the tone on the Monitoring FX chain
  end
end

-------------------------------------------------------------------------------
-- 6. MAIN
-------------------------------------------------------------------------------
local function main()
  -- The toolbar button shows the script as running and resets when it ends; closing the window or ending the script
  -- mid-analysis also destroys the audio accessor
  local Utils = require("utils")
  local release_toolbar = Utils.init_toolbar_toggle()
  reaper.atexit(function()
    K.release_analysis()
    K.tone_kill()
    release_toolbar()
  end)

  scan_project_for_saved_takes()
  -- Items whose saved analysis could not be read are not listed: say so once (the Pitched Items banner stays)
  local unreadable = #K.unreadable_guids()
  if unreadable > 0 then
    set_status(string.format("%d %s: saved analysis couldn't be read (see Pitched Items)", unreadable,
      plural(unreadable, "item", "items")))
  end

  local sel_item = reaper.GetSelectedMediaItem(0, 0)
  if sel_item then
    local sel_take = reaper.GetActiveTake(sel_item)
    if sel_take and not reaper.TakeIsMIDI(sel_take) then
      local _, guid = reaper.GetSetMediaItemTakeInfo_String(sel_take, "GUID", "", false)
      if guid then
        -- No target exists yet, so REAPER's selection is the right starting point; remember it so the
        -- edge-triggered tracker in loop_body only reacts to later selection changes
        state.last_seen_sel_guid = guid
        local loaded = switch_active_target(guid, sel_take)
        if not loaded then
          state.target_take_guid = guid
          state.target_take_name = reaper.GetTakeName(sel_take) or "Selected Item"
          state.start_time = 0
          state.item_len = reaper.GetMediaItemInfo_Value(sel_item, "D_LENGTH")
          state.end_time = state.item_len
        end
      end
    end
  elseif #state.session_order > 0 then
    local first_guid = state.session_order[1]
    local first_take = reaper.GetMediaItemTakeByGUID(0, first_guid)
    switch_active_target(first_guid, first_take)
  end

  -- Startup reads (scan / load) are in sync with the project: start watching for changes from here
  note_own_write()
  K.queue_stale_checks()   -- which of the stored envelopes are not what today's settings would write

  K.tone_kill()   -- removes a tone a crashed session left on the Monitoring FX chain
  loop()
end

main()
