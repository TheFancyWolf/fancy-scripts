-- @description Fancy Pan Snap
-- @author Fancy Scripts
-- @version 1.7.0
-- @changelog
--   + Multi-project tab switching support: automatic session switch detection via EnumProjects(-1)
--   + Prevents cross-session pointer leaks, stale track pointers, and ReaImGui context desync
--   + High-performance zero-allocation fast-path engine eliminates GC churn during idle
--   + Pre-cached track descriptors, GUIDs, and parameter keys eliminate string allocations in defer loops
--   + Fixed mousewheel and MIDI controller snapping: tracks mouse_down_seen to allow smooth scrolling without premature snap
--   + Hardened ReaImGui context lifecycle and bypass modifier query to prevent context pointer errors
--   + Periodic stale track cleanup without per-tick table diffing
--   + Fixed intermittent ImGui_GetKeyMods context error during background idle execution
--   + Added context validation and dynamic recreation for seamless background running
--   + Added 50% preset button and replaced 12.5% step
--   + Removed "Auto Detent" subtitle from header
--   + Added Info and Settings modal dialogs matching Parameter Link layout
--   + Moved target parameters into Settings modal
--   + Added STOP button to top master control row with tips placed directly beneath
--   + Refactored Styling section to permanent section using standard section divider
--   + Added comprehensive Overlay Styling with REAPER theme element pickers
--   + Seamless background execution when closing HUD window with toolbar re-open
--   + Initial release
-- @about
--   Background auto-snap utility that snaps Track Pan, Track Width / Dual Pan,
--   and Send Pans to configurable percentage increments (default 10%) on release.
--   Features a sleek ReaImGui HUD, floating cursor tooltip badge, customizable step buttons,
--   bypass modifier (Shift/Alt), and docking support.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

-------------------------------------------------------------------------------
-- 1. DEPENDENCY CHECK
-------------------------------------------------------------------------------
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "To install:\n"
    .. "  1.  Extensions  ->  ReaPack  ->  Browse Packages\n"
    .. "  2.  Search for 'ReaImGui'\n"
    .. "  3.  Install and restart REAPER, then run this script again.",
    "Fancy Pan Snap -- Missing ReaImGui", 0)
  return
end

-------------------------------------------------------------------------------
-- 2. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")
local JSON  = require("json")
local Utils = require("utils")

-------------------------------------------------------------------------------
-- 3. CONSTANTS & CONFIGURATION
-------------------------------------------------------------------------------
local EXTSTATE_SECTION = "FancyScripts"
local EXTSTATE_KEY     = "pan_snap_config"

local PRESET_STEPS = { 5, 10, 20, 25, 50, 100 }

local DEFAULT_CONFIG = {
  version            = 2,
  enabled            = true,
  show_hover_tooltip = true,      -- Custom ReaImGui floating tooltip showing snapped target while adjusting
  step_pct           = 10.0,
  target_pan         = true,
  target_width       = true,
  target_sends       = true,
  include_master     = true,
  keep_in_background = true,       -- Run in background when HUD is closed
  show_styling       = true,       -- Overlay styling & theme section
  show_settings      = false,      -- Settings drawer section
  -- Overlay element styling preferences (Theme element roles)
  overlay_bg         = "card",     -- "card", "panel", "bg", "accent_tint"
  overlay_border     = "accent",   -- "accent", "accent2", "border", "green", "yellow", "none"
  overlay_val        = "accent_l", -- "accent_l", "accent2_l", "green_l", "yellow_l", "text"
  overlay_label      = "text_dim", -- "text_dim", "text", "accent_l"
  overlay_rounding   = "rounded",  -- "rounded", "pill", "sharp"
  overlay_opacity    = 1.0,        -- 0.4 to 1.0
}

local OVERLAY_BG_ITEMS = {
  { id = "card",        label = "Card Surface (Default)" },
  { id = "panel",       label = "Panel Surface" },
  { id = "bg",          label = "Window Surface" },
  { id = "accent_tint", label = "Accent Tint (Wash)" },
}

local OVERLAY_BORDER_ITEMS = {
  { id = "accent",  label = "Theme Accent (Cursor)" },
  { id = "accent2", label = "Secondary Accent (Blue)" },
  { id = "border",  label = "Subtle Frame (3D Border)" },
  { id = "green",   label = "Detent Green (Success)" },
  { id = "yellow",  label = "Brand Yellow" },
  { id = "none",    label = "None (Borderless)" },
}

local OVERLAY_VAL_ITEMS = {
  { id = "accent_l",  label = "Theme Accent (Default)" },
  { id = "accent2_l", label = "Secondary Accent (Blue)" },
  { id = "green_l",   label = "Detent Green" },
  { id = "yellow_l",  label = "Brand Yellow" },
  { id = "text",      label = "White (High Contrast)" },
}

local OVERLAY_LABEL_ITEMS = {
  { id = "text_dim", label = "Muted Text (Default)" },
  { id = "text",     label = "Primary Text" },
  { id = "accent_l", label = "Theme Accent" },
}

local OVERLAY_ROUNDING_ITEMS = {
  { id = "rounded", label = "Rounded (4px)" },
  { id = "pill",    label = "Pill (8px)" },
  { id = "sharp",   label = "Sharp (0px)" },
}

local function find_item_index(items, id, default_idx)
  for i, item in ipairs(items) do
    if item.id == id then return i end
  end
  return default_idx or 1
end

local config = {}
for k, v in pairs(DEFAULT_CONFIG) do
  config[k] = v
end

local function save_config()
  local ok, encoded = pcall(JSON.encode, config)
  if ok and encoded then
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY, encoded, true)
  end
end

local function load_config()
  local raw = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY)
  if raw and raw ~= "" then
    local ok, parsed = pcall(JSON.decode, raw)
    if ok and type(parsed) == "table" then
      for k, v in pairs(parsed) do
        if DEFAULT_CONFIG[k] ~= nil then
          config[k] = v
        end
      end
      -- Version 2 migration: Default keep_in_background to true for older configs
      if not parsed.version or parsed.version < 2 then
        config.keep_in_background = true
        config.version = 2
        save_config()
      end
    end
  else
    save_config()
  end
end

-------------------------------------------------------------------------------
-- 4. STATE & RUNTIME TRACKING
-------------------------------------------------------------------------------
local ctx
local fonts
local is_running = true
local hud_open = true

--- Checks whether the current ReaImGui context pointer is valid and alive.
--- Clears ctx to nil if ReaImGui destroyed it during idle/background execution.
--- @return boolean
local function is_context_valid()
  if not ctx then return false end
  if reaper.ImGui_ValidatePtr then
    local valid = reaper.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    if not valid then
      ctx = nil
      fonts = nil
      return false
    end
    return true
  end
  return true
end

--- Ensures a valid ReaImGui context and font set are initialized and ready for rendering.
--- @return userdata
local function ensure_imgui_context()
  if not is_context_valid() then
    local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
    ctx = reaper.ImGui_CreateContext("Fancy Pan Snap", dock_flag)
    fonts = Theme.create_fonts(ctx)
    Theme.attach_fonts(ctx, fonts)
  end
  return ctx
end

-- Modal dialog state
local show_info_modal     = false
local show_settings_modal = false

-- UI button sizing derived from Theme.layout tokens
local UI = {
  btn_info_w = Theme.layout.xxxl + Theme.layout.xl,      -- 48
  btn_sett_w = Theme.layout.xxxl * 2 + Theme.layout.md,  -- 72
}

-- Table of tracked parameters: key -> record
local tracked_params = {}

-- Multi-project session and track descriptor cache
local last_proj = nil
local last_proj_state = -1
local last_track_count = -1
local cached_track_list = {}
local last_cleanup_time = 0

-- Custom ReaImGui floating cursor tooltip state
local active_tip_data = nil
local tooltip_hide_deadline = 0

-- Status message feedback
local status_msg = ""
local status_msg_time = 0

local function set_status(msg)
  status_msg = msg
  status_msg_time = reaper.time_precise()
end

-------------------------------------------------------------------------------
-- 5. HELPERS & UTILITIES
-------------------------------------------------------------------------------

--- Calculates nearest snap value for a given percentage step.
--- @param val number  Current pan/width value (-1.0 to 1.0)
--- @param step_pct number  Step percentage (e.g. 10 for 10% / 0.10)
--- @return number  Snapped value clamped to [-1.0, 1.0]
local function calculate_snap(val, step_pct)
  local step = step_pct / 100.0
  if step <= 0 then return val end
  local steps = math.floor((val / step) + 0.5)
  local snapped = steps * step
  snapped = math.max(-1.0, math.min(1.0, snapped))
  snapped = math.floor(snapped * 10000 + 0.5) / 10000
  if math.abs(snapped) < 1e-5 then
    snapped = 0.0
  end
  return snapped
end

--- Formats a pan or width value for user display.
--- @param val number  Value (-1.0 to 1.0)
--- @param param_type string  "pan", "width", "dual_l", "dual_r", "send"
--- @return string  Human-readable string
local function format_param_value(val, param_type)
  if param_type == "width" then
    local pct = math.floor(val * 100 + 0.5)
    if pct == 0 then
      return "0% (Mono)"
    elseif pct == 100 then
      return "100% (Stereo)"
    elseif pct < 0 then
      return string.format("%d%% (Inv)", pct)
    else
      return string.format("%d%%", pct)
    end
  end

  local pct = math.floor(math.abs(val) * 100 + 0.5)
  if pct == 0 or math.abs(val) < 0.005 then
    return "Center"
  elseif val < 0 then
    return string.format("%d%% L", pct)
  else
    return string.format("%d%% R", pct)
  end
end

--- Checks whether the user is holding Shift or Alt to bypass snapping.
--- Supports both DAW-wide js_ReaScriptAPI and ReaImGui key states.
--- @param imgui_ctx userdata|nil
--- @return boolean
local function is_bypass_active(imgui_ctx)
  -- 1. Check JS_Mouse_GetState if available (DAW-wide: Bit 3=Shift [8], Bit 5=Alt/Option [32])
  if reaper.JS_Mouse_GetState then
    local s = reaper.JS_Mouse_GetState(40)
    if s and s ~= 0 then return true end
  end

  -- 2. Check ReaImGui key modifiers only if HUD is open and a valid ImGui context is active
  if hud_open and imgui_ctx and is_context_valid() then
    if reaper.ImGui_GetKeyMods then
      local ok, mods = pcall(reaper.ImGui_GetKeyMods, imgui_ctx)
      if ok and mods then
        local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
        local alt_mod   = reaper.ImGui_Mod_Alt and reaper.ImGui_Mod_Alt() or 0
        if (mods & (shift_mod | alt_mod)) ~= 0 then
          return true
        end
      end
    end
  end

  return false
end

--- Checks left mouse button state if js_ReaScriptAPI is installed.
--- @return boolean|nil  true if pressed, false if released, nil if unknown
local function is_mouse_lbutton_down()
  if reaper.JS_Mouse_GetState then
    local b = reaper.JS_Mouse_GetState(1)
    if b then
      return (b & 1) ~= 0
    end
  end
  return nil
end

--- Checks whether an envelope exists on a track for a parameter during playback.
--- Prevents auto-snapping from fighting automated envelope playback.
--- @param track userdata  MediaTrack pointer
--- @param param_type string
--- @return boolean
local function has_playback_envelope(track, param_type)
  if (reaper.GetPlayState() & 1) == 0 then return false end
  local env_name
  if param_type == "pan" then
    env_name = "Pan"
  elseif param_type == "width" then
    env_name = "Width"
  elseif param_type == "dual_l" then
    env_name = "Pan (Left)"
  elseif param_type == "dual_r" then
    env_name = "Pan (Right)"
  end
  if env_name then
    local env = reaper.GetTrackEnvelopeByName(track, env_name)
    if env and reaper.CountEnvelopePoints(env) > 0 then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- 6. PAN SNAPPING ENGINE
-------------------------------------------------------------------------------

--- Reads current value of a parameter from REAPER.
--- @param track userdata
--- @param param_type string
--- @param send_idx integer|nil
--- @return number|nil
local function get_param_value(track, param_type, send_idx)
  if param_type == "pan" then
    return reaper.GetMediaTrackInfo_Value(track, "D_PAN")
  elseif param_type == "width" then
    return reaper.GetMediaTrackInfo_Value(track, "D_WIDTH")
  elseif param_type == "dual_l" then
    return reaper.GetMediaTrackInfo_Value(track, "D_DUALPANL")
  elseif param_type == "dual_r" then
    return reaper.GetMediaTrackInfo_Value(track, "D_DUALPANR")
  elseif param_type == "send" and send_idx then
    return reaper.GetTrackSendInfo_Value(track, 0, send_idx, "D_PAN")
  end
  return nil
end

--- Writes a snapped value to REAPER.
--- @param track userdata
--- @param param_type string
--- @param send_idx integer|nil
--- @param val number
local function set_param_value(track, param_type, send_idx, val)
  if param_type == "pan" then
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", val)
  elseif param_type == "width" then
    reaper.SetMediaTrackInfo_Value(track, "D_WIDTH", val)
  elseif param_type == "dual_l" then
    reaper.SetMediaTrackInfo_Value(track, "D_DUALPANL", val)
  elseif param_type == "dual_r" then
    reaper.SetMediaTrackInfo_Value(track, "D_DUALPANR", val)
  elseif param_type == "send" and send_idx then
    reaper.SetTrackSendInfo_Value(track, 0, send_idx, "D_PAN", val)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

--- Scans a single track parameter and triggers snap if motion settled or released.
local function process_param(track, guid, track_name, param_type, param_name, send_idx, key, now, mouse_down, bypass)
  local val = get_param_value(track, param_type, send_idx)
  if val == nil then return end

  local rec = tracked_params[key]
  if not rec then
    tracked_params[key] = {
      key = key,
      guid = guid,
      track = track,
      track_name = track_name,
      param_type = param_type,
      param_name = param_name,
      send_idx = send_idx,
      last_val = val,
      is_moving = false,
      last_change_time = 0,
      mouse_down_seen = false,
    }
    return
  end

  rec.track = track
  rec.track_name = track_name

  local diff = math.abs(val - rec.last_val)

  -- FAST PATH: If value has not changed and parameter is not in motion, exit immediately
  if diff <= 0.0005 and not rec.is_moving then
    return
  end

  -- Check if value has changed
  if diff > 0.0005 then
    if not has_playback_envelope(track, param_type) then
      if not rec.is_moving then
        rec.is_moving = true
        rec.drag_start_val = rec.last_val
        rec.mouse_down_seen = (mouse_down == true)
      else
        if mouse_down == true then
          rec.mouse_down_seen = true
        end
      end
      rec.last_change_time = now
      rec.last_val = val
    else
      rec.last_val = val
      rec.is_moving = false
      rec.mouse_down_seen = false
      rec.drag_start_val = nil
    end
  end

  -- If parameter was in motion, determine if it has settled or was released
  if rec.is_moving then
    local should_snap = false

    if rec.mouse_down_seen then
      -- User was dragging with left mouse button: snap immediately on mouse release
      if mouse_down == false then
        should_snap = true
      end
    else
      -- User adjusted via mousewheel, MIDI controller, OSC, or when mouse state is unavailable:
      -- Wait for 120ms debounce settling timer
      if (now - rec.last_change_time) >= 0.120 then
        should_snap = true
      end
    end

    if should_snap then
      rec.is_moving = false
      rec.mouse_down_seen = false
      rec.drag_start_val = nil

      -- If bypass modifier is held, allow free panning without snapping
      if bypass then
        set_status("Bypassed via Shift/Alt")
        rec.last_val = val
        active_tip_data = nil
        return
      end

      -- If engine is disabled, do not snap
      if not config.enabled then
        rec.last_val = val
        active_tip_data = nil
        return
      end

      local snapped = calculate_snap(val, config.step_pct)
      local snap_diff = math.abs(snapped - val)

      -- Snap now upon release
      if snap_diff >= 0.0005 then
        local snapped_str = format_param_value(snapped, param_type)
        local undo_title = string.format("Snap %s: %s (%s)", param_name, track_name, snapped_str)

        Utils.undo_block(undo_title, function()
          set_param_value(track, param_type, send_idx, snapped)
        end)

        rec.last_val = snapped

        active_tip_data = {
          track = track_name,
          param = param_name,
          val_str = snapped_str,
          step_pct = config.step_pct,
          is_moving = false,
          is_bypassed = false,
        }
        tooltip_hide_deadline = now + 0.35
      else
        rec.last_val = val
        active_tip_data = nil
      end
      return
    end

    -- While in motion: update active_tip_data for real-time smooth floating tooltip
    if config.enabled then
      local target_val = calculate_snap(val, config.step_pct)
      local snapped_str = format_param_value(target_val, param_type)
      active_tip_data = {
        track = track_name,
        param = param_name,
        val_str = snapped_str,
        step_pct = config.step_pct,
        is_moving = true,
        is_bypassed = bypass,
      }
      tooltip_hide_deadline = now + 0.35
    end
  end
end

--- Executes a project-wide scan of all tracks and monitored parameters.
local function snap_engine_tick(imgui_ctx)
  local cur_proj = reaper.EnumProjects(-1)

  -- 1. Multi-project tab switch handling
  if cur_proj ~= last_proj then
    last_proj = cur_proj
    last_proj_state = -1
    last_track_count = -1
    tracked_params = {}
    active_tip_data = nil
    cached_track_list = {}
    if not hud_open then
      if ctx and reaper.ImGui_DestroyContext then
        pcall(reaper.ImGui_DestroyContext, ctx)
      end
      ctx = nil
      fonts = nil
    end
  end

  local now = reaper.time_precise()
  local mouse_down = is_mouse_lbutton_down()
  local bypass = is_bypass_active(imgui_ctx)

  local proj_state = reaper.GetProjectStateChangeCount(cur_proj)
  local track_count = reaper.CountTracks(cur_proj)

  -- 2. Refresh cached track descriptor list when project structure changes
  if proj_state ~= last_proj_state or track_count ~= last_track_count or #cached_track_list == 0 then
    cached_track_list = {}

    if config.include_master then
      local mtr = reaper.GetMasterTrack(cur_proj)
      if mtr then
        local _, mnm = reaper.GetTrackName(mtr)
        local mguid = reaper.GetTrackGUID(mtr)
        cached_track_list[#cached_track_list + 1] = {
          tr = mtr,
          guid = mguid,
          name = (mnm and mnm ~= "") and mnm or "Master",
          key_pan = mguid .. ":pan",
          key_width = mguid .. ":width",
          key_dual_l = mguid .. ":dual_l",
          key_dual_r = mguid .. ":dual_r",
          send_keys = {},
          send_names = {},
        }
      end
    end

    for i = 0, track_count - 1 do
      local tr = reaper.GetTrack(cur_proj, i)
      if tr then
        local _, tnm = reaper.GetTrackName(tr)
        local guid = reaper.GetTrackGUID(tr)
        cached_track_list[#cached_track_list + 1] = {
          tr = tr,
          guid = guid,
          name = (tnm and tnm ~= "") and tnm or string.format("Track %d", i + 1),
          key_pan = guid .. ":pan",
          key_width = guid .. ":width",
          key_dual_l = guid .. ":dual_l",
          key_dual_r = guid .. ":dual_r",
          send_keys = {},
          send_names = {},
        }
      end
    end

    last_proj_state = proj_state
    last_track_count = track_count
  end

  -- 3. Scan parameters across cached track descriptors
  for idx = 1, #cached_track_list do
    local tinfo = cached_track_list[idx]
    local tr = tinfo.tr

    if reaper.ValidatePtr2(cur_proj, tr, "MediaTrack*") then
      local pan_mode = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_PANMODE") + 0.5)

      -- 1. Track Pan (D_PAN)
      if config.target_pan and pan_mode ~= 6 then
        process_param(tr, tinfo.guid, tinfo.name, "pan", "Pan", nil, tinfo.key_pan, now, mouse_down, bypass)
      end

      -- 2. Track Width / Dual Pan
      if config.target_width then
        if pan_mode == 6 then
          process_param(tr, tinfo.guid, tinfo.name, "dual_l", "Dual Pan L", nil, tinfo.key_dual_l, now, mouse_down, bypass)
          process_param(tr, tinfo.guid, tinfo.name, "dual_r", "Dual Pan R", nil, tinfo.key_dual_r, now, mouse_down, bypass)
        elseif pan_mode == 5 then
          process_param(tr, tinfo.guid, tinfo.name, "width", "Width", nil, tinfo.key_width, now, mouse_down, bypass)
        end
      end

      -- 3. Send Pans
      if config.target_sends then
        local num_sends = reaper.GetTrackNumSends(tr, 0)
        if num_sends > 0 then
          for s = 0, num_sends - 1 do
            local skey = tinfo.send_keys[s]
            if not skey then
              skey = tinfo.guid .. ":send:" .. s
              tinfo.send_keys[s] = skey
            end
            local sname = tinfo.send_names[s]
            if not sname then
              sname = string.format("Send %d Pan", s + 1)
              tinfo.send_names[s] = sname
            end
            process_param(tr, tinfo.guid, tinfo.name, "send", sname, s, skey, now, mouse_down, bypass)
          end
        end
      end
    else
      last_proj_state = -1 -- Trigger refresh on next tick
    end
  end

  -- 4. Periodic stale cleanup (every 5 seconds) without per-frame table allocations
  if (now - last_cleanup_time) > 5.0 then
    last_cleanup_time = now
    for k, rec in pairs(tracked_params) do
      if not rec.is_moving then
        if not reaper.ValidatePtr2(cur_proj, rec.track, "MediaTrack*") then
          tracked_params[k] = nil
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- 7. UI DRAWING FUNCTIONS
-------------------------------------------------------------------------------

----- Resolves active overlay visual tokens based on theme element configuration.
--- @param P table  Palette table from Theme.build_palette()
--- @return table  Table containing resolved bg, border, border_size, val, label, rounding
local function resolve_overlay_style(P)
  local bg_color = P.card
  if config.overlay_bg == "panel" then
    bg_color = P.panel
  elseif config.overlay_bg == "bg" then
    bg_color = P.bg
  elseif config.overlay_bg == "accent_tint" then
    bg_color = Theme.darken(P.accent, 0.70)
  end

  local alpha = config.overlay_opacity or 1.0
  bg_color = Theme.with_alpha(bg_color, alpha)

  local border_color = P.accent
  local border_size = 1.0
  if config.overlay_border == "accent2" then
    border_color = P.accent2
  elseif config.overlay_border == "border" then
    border_color = P.border
  elseif config.overlay_border == "green" then
    border_color = P.green
  elseif config.overlay_border == "yellow" then
    border_color = P.yellow
  elseif config.overlay_border == "none" then
    border_color = 0
    border_size = 0.0
  end

  local val_color = P.accent_l
  if config.overlay_val == "accent2_l" then
    val_color = P.accent2_l
  elseif config.overlay_val == "green_l" then
    val_color = P.green_l
  elseif config.overlay_val == "yellow_l" then
    val_color = P.yellow_l
  elseif config.overlay_val == "text" then
    val_color = P.text
  end

  local label_color = P.text_dim
  if config.overlay_label == "text" then
    label_color = P.text
  elseif config.overlay_label == "accent_l" then
    label_color = P.accent_l
  end

  local rounding = Theme.layout.rounding
  if config.overlay_rounding == "pill" then
    rounding = Theme.layout.rounding * 2
  elseif config.overlay_rounding == "sharp" then
    rounding = 0
  end

  return {
    bg = bg_color,
    border = border_color,
    border_size = border_size,
    val = val_color,
    label = label_color,
    rounding = rounding,
  }
end

--- Renders our custom ReaImGui floating cursor tooltip near the mouse when turning knobs.
local function draw_floating_cursor_tooltip()
  if not config.show_hover_tooltip or not active_tip_data then return end

  local now = reaper.time_precise()
  if not active_tip_data.is_moving and now >= tooltip_hide_deadline then
    active_tip_data = nil
    return
  end

  ensure_imgui_context()
  if not is_context_valid() then return end

  local P = Theme.build_palette()
  local L = Theme.layout
  local nc, nv = Theme.push(ctx, P)
  local pushed_default = Theme.push_font(ctx, fonts.default)

  local tip_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                  | reaper.ImGui_WindowFlags_NoResize()
                  | reaper.ImGui_WindowFlags_NoMove()
                  | reaper.ImGui_WindowFlags_NoScrollbar()
                  | reaper.ImGui_WindowFlags_AlwaysAutoResize()
                  | reaper.ImGui_WindowFlags_NoSavedSettings()
                  | reaper.ImGui_WindowFlags_NoInputs()
                  | reaper.ImGui_WindowFlags_NoFocusOnAppearing()

  if reaper.ImGui_WindowFlags_Tooltip then
    tip_flags = tip_flags | reaper.ImGui_WindowFlags_Tooltip()
  end
  if reaper.ImGui_WindowFlags_TopMost then
    tip_flags = tip_flags | reaper.ImGui_WindowFlags_TopMost()
  end

  local smx, smy = reaper.GetMousePosition()
  local mx, my = smx, smy
  if reaper.ImGui_PointConvertNative then
    mx, my = reaper.ImGui_PointConvertNative(ctx, smx, smy, false)
  end

  reaper.ImGui_SetNextWindowPos(ctx, mx + 10, my + 8, reaper.ImGui_Cond_Always())

  local style = resolve_overlay_style(P)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), style.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), style.border)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), L.md, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), style.rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), style.border_size)

  local visible, _ = reaper.ImGui_Begin(ctx, "##fancy_pan_cursor_tooltip", nil, tip_flags)
  if visible then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), style.label)
    reaper.ImGui_Text(ctx, active_tip_data.track .. " • " .. active_tip_data.param)
    reaper.ImGui_PopStyleColor(ctx, 1)

    local pushed_bold = Theme.push_font(ctx, fonts.bold)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), style.val)
    reaper.ImGui_Text(ctx, active_tip_data.val_str)
    reaper.ImGui_PopStyleColor(ctx, 1)
    Theme.pop_font(ctx, pushed_bold)

    reaper.ImGui_SameLine(ctx, 0, L.sm)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), style.label)
    local step_str = active_tip_data.step_pct >= 100
      and "(LCR)"
      or string.format("(%g%%)", active_tip_data.step_pct)
    reaper.ImGui_Text(ctx, step_str)
    reaper.ImGui_PopStyleColor(ctx, 1)

    if active_tip_data.is_bypassed then
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
      reaper.ImGui_Text(ctx, "[Bypass]")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
  end
  reaper.ImGui_End(ctx)

  reaper.ImGui_PopStyleVar(ctx, 3)
  reaper.ImGui_PopStyleColor(ctx, 2)

  Theme.pop_font(ctx, pushed_default)
  Theme.pop(ctx, nc, nv)
end

--- Renders the window header bar.
--- @return boolean  true if HUD should remain open
local function draw_hud_header()
  local L = Theme.layout
  local right_w = UI.btn_info_w + UI.btn_sett_w + L.sm
  local header_open = Theme.header(ctx, {
    title          = "PAN SNAP",
    fonts          = fonts,
    icon_fn        = Theme.icons.slider,
    right_width    = right_w,
    right_widgets  = function(hdr_ctx, hdr_h)
      Theme.align(hdr_ctx, hdr_h)
      if reaper.ImGui_Button(hdr_ctx, "Info##hdr_info", UI.btn_info_w, 0) then
        show_info_modal = true
      end
      reaper.ImGui_SameLine(hdr_ctx, 0, L.sm)
      Theme.align(hdr_ctx, hdr_h)
      if reaper.ImGui_Button(hdr_ctx, "Settings##hdr_settings", UI.btn_sett_w, 0) then
        show_settings_modal = true
      end
    end,
    show_settings  = false,
    show_close     = true,
    close_id       = "pan_snap_close",
    close_tooltip  = config.keep_in_background
      and "Close menu (Snapping stays active in background)"
      or "Close menu & Stop Utility",
  })
  return header_open
end

--- Renders the master engine enable toggle, live status badge, STOP button, and bypass hints.
local function draw_master_row(P, bypass_active)
  local L = Theme.layout
  local btn_text = config.enabled and "ACTIVE (ON)" or "PAUSED (OFF)"

  local clicked = Theme.toggle_button(ctx, "pan_snap_master_toggle", btn_text, config.enabled, {
    fonts = fonts,
    active_bg = P.green_d,
    active_hover = P.green_h,
    active_active = P.green,
    active_text = P.green_l,
    tooltip = "Click to toggle pan auto-snapping on or off",
  })
  if clicked then
    config.enabled = not config.enabled
    save_config()
  end

  reaper.ImGui_SameLine(ctx, 0, L.md)
  Theme.align(ctx)

  if bypass_active then
    Theme.badge(ctx, "BYPASS (Shift/Alt)", {
      color = P.yellow,
      bg = Theme.with_alpha(P.yellow, 0.22),
      tooltip = "Auto-snapping is bypassed while holding Shift or Alt",
    })
  elseif not config.enabled then
    Theme.badge(ctx, "ENGINE PAUSED", {
      color = P.red,
      bg = Theme.with_alpha(P.red, 0.2),
      tooltip = "Auto-snapping is currently paused",
    })
  else
    local step_label = config.step_pct >= 100
      and "LCR"
      or string.format("Snap: %g%%", config.step_pct)
    Theme.badge(ctx, step_label, {
      color = P.accent_l,
      bg = P.accent_d,
      tooltip = "Current active detent increment",
    })
  end

  -- STOP utility button right-aligned on the master row
  local stop_btn_w = 56
  reaper.ImGui_SameLine(ctx, 0, 0)
  Theme.right_align(ctx, stop_btn_w)
  Theme.align(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.red_l)
  local stop_clicked = reaper.ImGui_Button(ctx, "STOP##pan_snap_top_stop", stop_btn_w, 0)
  reaper.ImGui_PopStyleColor(ctx, 4)
  if stop_clicked then
    is_running = false
    hud_open = false
    reaper.DeleteExtState(EXTSTATE_SECTION, "pan_snap_hud_open", false)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, "Completely stops the background snapping engine and exits the script")
  end

  -- Tips positioned directly under the ACTIVE / PAUSED control row
  reaper.ImGui_Dummy(ctx, 0, L.xs)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  local pushed_sm = Theme.push_font(ctx, fonts.small)
  reaper.ImGui_Text(ctx, "Tip: Hold Shift or Alt while adjusting to bypass snap.")
  reaper.ImGui_Text(ctx, "Close window to keep running in background.")
  Theme.pop_font(ctx, pushed_sm)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

--- Renders the preset increment buttons and custom step slider.
local function draw_increment_section()
  local L = Theme.layout
  Theme.section_divider(ctx, "SNAP INCREMENT", { tooltip = "Configure percentage detent increments" })

  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local item_spacing = L.sm
  local count = #PRESET_STEPS
  local total_gaps = item_spacing * (count - 1)
  local btn_w = math.floor((avail_w - total_gaps) / count)
  if btn_w < 35 then btn_w = 0 end

  for i, step_val in ipairs(PRESET_STEPS) do
    if i > 1 then
      reaper.ImGui_SameLine(ctx, 0, item_spacing)
    end

    local is_active = (math.abs(config.step_pct - step_val) < 0.01)
    local lbl = step_val >= 100 and "LCR" or string.format("%g%%", step_val)
    local tip = step_val >= 100
      and "LCR mode: snap to Left (-100%), Center (0%), or Right (+100%) only"
      or string.format("Set snap increment to %g%%", step_val)
    local clicked = Theme.toggle_button(ctx, "step_btn_" .. i, lbl, is_active, {
      fonts = fonts,
      w = btn_w,
      tooltip = tip,
    })
    if clicked then
      config.step_pct = step_val
      save_config()
    end
  end

  reaper.ImGui_Dummy(ctx, 0, L.sm)

  -- Custom step slider
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_pct = reaper.ImGui_SliderDouble(ctx, "##custom_step_slider", config.step_pct, 1.0, 50.0, "Custom Step: %.1f%%")
  if changed then
    config.step_pct = math.floor(new_pct * 10 + 0.5) / 10
    save_config()
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, "Drag to dial any custom snap increment between 1.0% and 50.0%")
  end
end

--- Renders the permanent overlay styling and theme section.
local function draw_styling_section(P)
  local L = Theme.layout
  Theme.section_divider(ctx, "STYLING", { tooltip = "Configure theme mode and overlay appearance" })

  local label_col_w = 115
  local combo_w = -1

  -- 1. Theme Mode
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Theme Mode:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  local theme_changed = Theme.settings_widget(ctx, { w = combo_w })
  if theme_changed then
    save_config()
  end

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 2. Background Surface Element
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Background:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  local bg_idx = find_item_index(OVERLAY_BG_ITEMS, config.overlay_bg, 1)
  local new_bg_idx, bg_changed = Theme.combo(ctx, "##overlay_bg_combo", OVERLAY_BG_ITEMS, bg_idx, {
    w = combo_w,
    get_label = function(item) return item.label end,
    tooltip = "Theme surface color element to use for the floating tooltip background",
  })
  if bg_changed then
    config.overlay_bg = OVERLAY_BG_ITEMS[new_bg_idx].id
    save_config()
  end

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 3. Border Element
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Border Element:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  local b_idx = find_item_index(OVERLAY_BORDER_ITEMS, config.overlay_border, 1)
  local new_b_idx, b_changed = Theme.combo(ctx, "##overlay_border_combo", OVERLAY_BORDER_ITEMS, b_idx, {
    w = combo_w,
    get_label = function(item) return item.label end,
    tooltip = "Theme color element to use for the overlay border",
  })
  if b_changed then
    config.overlay_border = OVERLAY_BORDER_ITEMS[new_b_idx].id
    save_config()
  end

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 4. Value Text Element
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Value Color:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  local v_idx = find_item_index(OVERLAY_VAL_ITEMS, config.overlay_val, 1)
  local new_v_idx, v_changed = Theme.combo(ctx, "##overlay_val_combo", OVERLAY_VAL_ITEMS, v_idx, {
    w = combo_w,
    get_label = function(item) return item.label end,
    tooltip = "Theme color element used to display the snapped detent value",
  })
  if v_changed then
    config.overlay_val = OVERLAY_VAL_ITEMS[new_v_idx].id
    save_config()
  end

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 5. Label Text Element
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Label Color:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  local l_idx = find_item_index(OVERLAY_LABEL_ITEMS, config.overlay_label, 1)
  local new_l_idx, l_changed = Theme.combo(ctx, "##overlay_label_combo", OVERLAY_LABEL_ITEMS, l_idx, {
    w = combo_w,
    get_label = function(item) return item.label end,
    tooltip = "Theme color element for track name, parameter, and grid label",
  })
  if l_changed then
    config.overlay_label = OVERLAY_LABEL_ITEMS[new_l_idx].id
    save_config()
  end

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 6. Corner Rounding
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Rounding:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  local r_idx = find_item_index(OVERLAY_ROUNDING_ITEMS, config.overlay_rounding, 1)
  local new_r_idx, r_changed = Theme.combo(ctx, "##overlay_rnd_combo", OVERLAY_ROUNDING_ITEMS, r_idx, {
    w = combo_w,
    get_label = function(item) return item.label end,
    tooltip = "Corner rounding style for the floating overlay badge",
  })
  if r_changed then
    config.overlay_rounding = OVERLAY_ROUNDING_ITEMS[new_r_idx].id
    save_config()
  end

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 7. Background Opacity
  Theme.align(ctx)
  reaper.ImGui_Text(ctx, "Opacity:")
  reaper.ImGui_SameLine(ctx, label_col_w + L.md)
  reaper.ImGui_SetNextItemWidth(ctx, combo_w)
  local cur_op_pct = math.floor((config.overlay_opacity or 1.0) * 100 + 0.5)
  local op_changed, new_op_pct = reaper.ImGui_SliderInt(ctx, "##overlay_opacity_slider", cur_op_pct, 40, 100, "%d%%")
  if op_changed then
    config.overlay_opacity = new_op_pct / 100.0
    save_config()
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, "Adjust background opacity of the floating cursor overlay")
  end

  reaper.ImGui_Dummy(ctx, 0, L.sm)

  -- 8. Live Preview Card
  Theme.align(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  local pushed_sm = Theme.push_font(ctx, fonts.small)
  reaper.ImGui_Text(ctx, "LIVE PREVIEW:")
  Theme.pop_font(ctx, pushed_sm)
  reaper.ImGui_PopStyleColor(ctx, 1)

  local style = resolve_overlay_style(P)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), style.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), style.border)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), L.md, L.sm)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), style.rounding)

  local prev_child_border = (style.border_size > 0)
  if reaper.ImGui_ChildFlags_Border then
    prev_child_border = prev_child_border and reaper.ImGui_ChildFlags_Border() or 0
  elseif reaper.ImGui_ChildFlags_Borders then
    prev_child_border = prev_child_border and reaper.ImGui_ChildFlags_Borders() or 0
  end

  local preview_h = L.row_h * 2 + L.sm
  if reaper.ImGui_BeginChild(ctx, "overlay_style_preview", 0, preview_h, prev_child_border) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), style.label)
    reaper.ImGui_Text(ctx, "Lead Vocal • Pan")
    reaper.ImGui_PopStyleColor(ctx, 1)

    local pushed_bold = Theme.push_font(ctx, fonts.bold)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), style.val)
    reaper.ImGui_Text(ctx, "20% L")
    reaper.ImGui_PopStyleColor(ctx, 1)
    Theme.pop_font(ctx, pushed_bold)

    reaper.ImGui_SameLine(ctx, 0, L.sm)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), style.label)
    local preview_step = config.step_pct >= 100
      and "(LCR)"
      or string.format("(%g%%)", config.step_pct)
    reaper.ImGui_Text(ctx, preview_step)
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 2)

  reaper.ImGui_Dummy(ctx, 0, L.xs)

  -- 9. Reset Overlay Style button
  local reset_style_clicked = reaper.ImGui_Button(ctx, "Reset Overlay Style##reset_overlay_style")
  if reset_style_clicked then
    config.overlay_bg       = DEFAULT_CONFIG.overlay_bg
    config.overlay_border   = DEFAULT_CONFIG.overlay_border
    config.overlay_val      = DEFAULT_CONFIG.overlay_val
    config.overlay_label    = DEFAULT_CONFIG.overlay_label
    config.overlay_rounding = DEFAULT_CONFIG.overlay_rounding
    config.overlay_opacity  = DEFAULT_CONFIG.overlay_opacity
    save_config()
    set_status("Overlay style reset to defaults")
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, "Revert overlay styling to default theme elements")
  end

  if status_msg ~= "" and (reaper.time_precise() - status_msg_time) < 3.0 then
    reaper.ImGui_SameLine(ctx, 0, L.md)
    Theme.align(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
    reaper.ImGui_Text(ctx, status_msg)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
end

--- Renders the Info & Guide modal dialog.
local function draw_info_modal()
  local P = Theme.build_palette()
  local L = Theme.layout
  if show_info_modal then
    reaper.ImGui_OpenPopup(ctx, "Fancy Pan Snap -- Info & Guide##pan_snap_info_modal")
    show_info_modal = false
  end

  Theme.center_next_window(ctx, 500, 360)
  Theme.modal_scrim(ctx, "Fancy Pan Snap -- Info & Guide##pan_snap_info_modal")
  local visible = reaper.ImGui_BeginPopupModal(ctx, "Fancy Pan Snap -- Info & Guide##pan_snap_info_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    if reaper.ImGui_BeginTabBar(ctx, "pan_snap_info_tabs") then
      if reaper.ImGui_BeginTabItem(ctx, "Quick Guide") then
        reaper.ImGui_Spacing(ctx)

        local pf = Theme.push_font(ctx, fonts.bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "1. Background Auto-Snapping")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Fancy Pan Snap monitors your pan adjustments in the TCP, MCP, Envelope lanes, and sends. When you release a knob, it automatically snaps to the nearest configured grid increment.")
        reaper.ImGui_Dummy(ctx, 0, L.sm)

        pf = Theme.push_font(ctx, fonts.bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "2. Live Snapped Overlay Tooltip")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "While adjusting any pan or width knob, a smooth floating badge follows your mouse cursor displaying the exact target value in real time.")
        reaper.ImGui_Dummy(ctx, 0, L.sm)

        pf = Theme.push_font(ctx, fonts.bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "3. Free Pan Bypass Modifier")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Hold Shift or Alt while adjusting or releasing any knob to temporarily bypass detents and pan completely freely.")

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Keyboard & Controls") then
        reaper.ImGui_Spacing(ctx)

        local pf = Theme.push_font(ctx, fonts.bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent_l)
        reaper.ImGui_Text(ctx, "Shift / Alt")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_SameLine(ctx, 120)
        reaper.ImGui_TextWrapped(ctx, "Hold while panning to bypass snap detents.")

        reaper.ImGui_Dummy(ctx, 0, L.xs)

        pf = Theme.push_font(ctx, fonts.bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent_l)
        reaper.ImGui_Text(ctx, "Esc")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_SameLine(ctx, 120)
        reaper.ImGui_TextWrapped(ctx, "Close current modal or minimize HUD to background.")

        reaper.ImGui_Dummy(ctx, 0, L.xs)

        pf = Theme.push_font(ctx, fonts.bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent_l)
        reaper.ImGui_Text(ctx, "Toolbar Button")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_SameLine(ctx, 120)
        reaper.ImGui_TextWrapped(ctx, "Click the toolbar icon or run the action to show/hide the HUD menu.")

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "About") then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Text(ctx, "Fancy Pan Snap")
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, "Version 1.7.0 -- Fancy Scripts")
        reaper.ImGui_Text(ctx, "Designed for REAPER 7.0+ with ReaImGui")
        reaper.ImGui_Dummy(ctx, 0, L.md)
        reaper.ImGui_TextWrapped(ctx, "Part of the Fancy Scripts workflow collection. Released under GNU GPL v3.")
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_EndTabItem(ctx)
      end

      reaper.ImGui_EndTabBar(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    Theme.right_align(ctx, 80)
    if reaper.ImGui_Button(ctx, "Close##pan_snap_info_close_btn", 80, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

--- Renders the Settings & Targets modal dialog.
local function draw_settings_modal()
  local P = Theme.build_palette()
  local L = Theme.layout
  if show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, "Pan Snap Settings##pan_snap_settings_modal")
    show_settings_modal = false
  end

  Theme.center_next_window(ctx, 480, 420)
  Theme.modal_scrim(ctx, "Pan Snap Settings##pan_snap_settings_modal")
  local visible = reaper.ImGui_BeginPopupModal(ctx, "Pan Snap Settings##pan_snap_settings_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_Spacing(ctx)

    Theme.section_divider(ctx, "TARGET PARAMETERS", { tooltip = "Choose which parameters are automatically snapped" })

    local changed_pan, new_pan = reaper.ImGui_Checkbox(ctx, "Track Pan (D_PAN)##set_pan", config.target_pan)
    if changed_pan then
      config.target_pan = new_pan
      save_config()
      last_track_count = -1
      tracked_params = {}
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Snaps main track pan positions (-100% L to +100% R)")
    end

    local changed_w, new_w = reaper.ImGui_Checkbox(ctx, "Track Width / Dual Pan##set_width", config.target_width)
    if changed_w then
      config.target_width = new_w
      save_config()
      last_track_count = -1
      tracked_params = {}
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Snaps stereo track width (0% to 100%) or Dual Pan L/R positions")
    end

    local changed_s, new_s = reaper.ImGui_Checkbox(ctx, "Send Pans##set_sends", config.target_sends)
    if changed_s then
      config.target_sends = new_s
      save_config()
      last_track_count = -1
      tracked_params = {}
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Snaps send pan positions for all track sends")
    end

    local changed_m, new_m = reaper.ImGui_Checkbox(ctx, "Include Master Track##set_master", config.include_master)
    if changed_m then
      config.include_master = new_m
      save_config()
      last_track_count = -1
      tracked_params = {}
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Also monitor and snap pan/width adjustments on the REAPER Master Track")
    end

    reaper.ImGui_Dummy(ctx, 0, L.md)

    Theme.section_divider(ctx, "ENGINE & OVERLAY BEHAVIOR", { tooltip = "Background execution and display settings" })

    local changed_bg, new_bg = reaper.ImGui_Checkbox(ctx, "Keep running in background when HUD is closed##set_bg", config.keep_in_background)
    if changed_bg then
      config.keep_in_background = new_bg
      save_config()
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "When enabled (default), closing the HUD window keeps the snapping engine active in the background.")
    end

    local changed_ht, new_ht = reaper.ImGui_Checkbox(ctx, "Show snapped hover tooltip while adjusting##set_ht", config.show_hover_tooltip)
    if changed_ht then
      config.show_hover_tooltip = new_ht
      save_config()
      if not new_ht then
        active_tip_data = nil
      end
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Displays a smooth ReaImGui floating badge at your mouse cursor showing the snapped target while turning any knob")
    end

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    Theme.tooltip_setting_widget(ctx)

    reaper.ImGui_Dummy(ctx, 0, L.lg)

    -- Bottom controls
    local reset_clicked = reaper.ImGui_Button(ctx, "Reset All to Defaults##pan_snap_modal_reset")
    if reset_clicked then
      for k, v in pairs(DEFAULT_CONFIG) do
        config[k] = v
      end
      save_config()
      last_track_count = -1
      tracked_params = {}
      set_status("All settings reset to defaults")
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      Theme.tooltip(ctx, "Restore all default Pan Snap settings and overlay styling")
    end

    if status_msg ~= "" and (reaper.time_precise() - status_msg_time) < 3.0 then
      reaper.ImGui_SameLine(ctx, 0, L.md)
      Theme.align(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
      reaper.ImGui_Text(ctx, status_msg)
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_SameLine(ctx, 0, 0)
    Theme.right_align(ctx, 80)
    if reaper.ImGui_Button(ctx, "Done##sett_done_btn", 80, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
end

-------------------------------------------------------------------------------
-- 8. MAIN DEFER LOOP
-------------------------------------------------------------------------------
local function loop()
  -- Always run the background pan-snapping engine tick
  snap_engine_tick(ctx)

  -- Render smooth custom ReaImGui cursor tooltip if active
  if config.show_hover_tooltip and active_tip_data then
    draw_floating_cursor_tooltip()
  end

  -- Render HUD window if open
  if hud_open then
    ensure_imgui_context()
    if is_context_valid() then
      local P = Theme.build_palette()
      local L = Theme.layout
      local nc, nv = Theme.push(ctx, P)
      local pushed_default = Theme.push_font(ctx, fonts.default)

      Theme.center_next_window(ctx, 380, 0, reaper.ImGui_Cond_Once())
      local win_flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoTitleBar()

      local visible, open = reaper.ImGui_Begin(ctx, "Fancy Pan Snap", true, win_flags)

      if visible then
        local keep_open = draw_hud_header()
        if not keep_open then
          open = false
        end

        local bypass_active = is_bypass_active(ctx)

        draw_master_row(P, bypass_active)
        reaper.ImGui_Dummy(ctx, 0, L.md)

        draw_increment_section()
        reaper.ImGui_Dummy(ctx, 0, L.md)

        draw_styling_section(P)
      end

      -- Modals rendering
      draw_info_modal()
      draw_settings_modal()

      reaper.ImGui_End(ctx)

      local modal_open = reaper.ImGui_IsPopupOpen(ctx, "Fancy Pan Snap -- Info & Guide##pan_snap_info_modal")
        or reaper.ImGui_IsPopupOpen(ctx, "Pan Snap Settings##pan_snap_settings_modal")
      if not modal_open and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        open = false
      end

      Theme.pop_font(ctx, pushed_default)
      Theme.pop(ctx, nc, nv)

      if not open then
        if config.keep_in_background then
          hud_open = false
          reaper.SetExtState(EXTSTATE_SECTION, "pan_snap_hud_open", "0", false)
          set_status("Running in background (snap active)")
        else
          is_running = false
          reaper.DeleteExtState(EXTSTATE_SECTION, "pan_snap_hud_open", false)
        end
      end
    end
  end

  if is_running then
    reaper.defer(loop)
  end
end

-------------------------------------------------------------------------------
-- 9. ENTRY POINT
-------------------------------------------------------------------------------
local function main()
  -- 1. Configure REAPER action multi-instance options first
  local app_ver = tonumber(reaper.GetAppVersion():match("[%d.]+")) or 7.0
  if reaper.set_action_options then
    if app_ver >= 7.03 then
      reaper.set_action_options(3)
    else
      reaper.set_action_options(1)
    end
  end

  -- 2. Check previous HUD state
  local prev_hud_state = reaper.GetExtState(EXTSTATE_SECTION, "pan_snap_hud_open")
  if prev_hud_state == "1" then
    -- Script was already running and HUD was visible -> user clicked toolbar/action to turn it OFF
    reaper.DeleteExtState(EXTSTATE_SECTION, "pan_snap_hud_open", false)
    local _, _, sec_id, cmd_id = reaper.get_action_context()
    if sec_id and cmd_id and cmd_id > 0 then
      reaper.SetToggleCommandState(sec_id, cmd_id, 0)
      reaper.RefreshToolbar2(sec_id, cmd_id)
    end
    return
  end

  load_config()

  ensure_imgui_context()

  Utils.init_toolbar_toggle()
  reaper.SetExtState(EXTSTATE_SECTION, "pan_snap_hud_open", "1", false)

  reaper.atexit(function()
    -- Only delete ExtState if stopping intentionally (not when replaced by a new instance)
    if not is_running then
      reaper.DeleteExtState(EXTSTATE_SECTION, "pan_snap_hud_open", false)
    end
    if reaper.TrackCtl_SetToolTip then
      reaper.TrackCtl_SetToolTip("", 0, 0, false)
    end
  end)

  reaper.defer(loop)
end

main()
