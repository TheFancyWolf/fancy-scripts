-- @description Fancy Mapper Cycle Mode
-- @author Fancy Scripts
-- @version 5.1.0
-- @changelog
--   + v5.1: Added Width, Multi-CC, Velocity, Track Nav, Marker, Transient, Item Slip
--   + v5.1: Cut Send mode
--   + v5.1: Dynamic sector geometry supporting custom enabled modes in Settings
-- @about
--   Directional action ring for switching Fancy Mapper modes.
--   Assign to a shortcut or controller button (e.g. keyboard hotkey, controller button, or middle click):
--   - Tap to open around the mouse cursor.
--   - Flick your mouse in the direction of the mode you want to select it instantly.
--   - Or hover over a mode for 350ms to auto-select.
--   - Stay in the center circle or press Escape to cancel with no change.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

-------------------------------------------------------------------------------
-- 0. DEPENDENCY CHECK
-------------------------------------------------------------------------------
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Mapper Cycle Mode -- Missing ReaImGui", 0)
  return
end

-------------------------------------------------------------------------------
-- 1. BOOTSTRAP & DEDUPLICATION / SECOND-TAP CONFIRMATION
-------------------------------------------------------------------------------
reaper.set_action_options(1)

local now_ts = reaper.time_precise()
local is_ring_active = reaper.GetExtState("FancyMapper", "ring_active")

-- If already open, tapping the shortcut again confirms the hovered mode
if is_ring_active == "1" then
  local last_tap = tonumber(reaper.GetExtState("FancyMapper", "ring_last_tap") or "0") or 0
  if (now_ts - last_tap) > 0.15 then
    reaper.SetExtState("FancyMapper", "ring_second_tap", "1", false)
  end
  return
end

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")

-------------------------------------------------------------------------------
-- 2. MODE DEFINITIONS
-------------------------------------------------------------------------------
local ALL_MODE_LABELS = {
  scrub     = "Scrub",
  fx        = "FX Param",
  pan       = "Pan",
  volume    = "Volume",
  width     = "Width",
  track_nav = "Track Nav",
  midi_cc   = "MIDI CC",
  midi_vel  = "Velocity",
  marker    = "Marker",
  transient = "Transient",
  item_slip = "Item Slip",
}

local DEFAULT_MODES = {
  { id = "scrub",     label = "Scrub",     active = true },
  { id = "fx",        label = "FX Param",  active = true },
  { id = "pan",       label = "Pan",       active = true },
  { id = "volume",    label = "Volume",    active = true },
  { id = "width",     label = "Width",     active = true },
  { id = "track_nav", label = "Track Nav", active = true },
  { id = "midi_cc",   label = "MIDI CC",   active = true },
  { id = "midi_vel",  label = "Velocity",  active = true },
}

local MODES = DEFAULT_MODES
local NUM_MODES = #MODES

-------------------------------------------------------------------------------
-- 3. GEOMETRY & TIMING CONSTANTS & CONFIG
-------------------------------------------------------------------------------
local DEAD_R     = 28    -- inner dead-zone radius (cancel zone)
local INNER_R    = 36    -- selectable area begins
local OUTER_R    = 96    -- selectable area outer border
local LABEL_R    = 132   -- mode label distance from centre
local WIN_HALF   = 230   -- half the window dimension (px)
local TWO_PI     = 2 * math.pi
local SECTOR     = TWO_PI / NUM_MODES
local HALF_SEC   = SECTOR / 2
local TOP        = -math.pi / 2  -- 12-o'clock angle offset
local ARC_TRIS   = 16   -- triangles per sector wedge
local CONFIRM_S  = 0.08  -- duration of crisp confirmation flash before closing

local cfg = {
  flick_enabled   = false,
  flick_distance  = 74,
  dwell_enabled   = false,
  dwell_s         = 0.35,
  timeout_enabled = false,
  timeout_s       = 3.0,
}

local function load_ring_config()
  local rm = reaper.GetExtState("FancyMapper", "ring_modes")
  if rm ~= "" then
    local loaded = {}
    for id in string.gmatch(rm, "[%w_]+") do
      local lbl = ALL_MODE_LABELS[id]
      if lbl then
        loaded[#loaded + 1] = { id = id, label = lbl, active = true }
      end
    end
    if #loaded >= 3 then
      MODES = loaded
      NUM_MODES = #MODES
      SECTOR = TWO_PI / NUM_MODES
      HALF_SEC = SECTOR / 2
      if NUM_MODES > 8 then
        LABEL_R = 138
        WIN_HALF = 240
      else
        LABEL_R = 132
        WIN_HALF = 230
      end
    end
  end

  local ext = reaper.GetExtState("FancyMapper", "ring_flick_enabled")
  if ext ~= "" then cfg.flick_enabled = (ext == "1" or ext == "true") end

  ext = reaper.GetExtState("FancyMapper", "ring_flick_distance")
  if ext ~= "" then cfg.flick_distance = tonumber(ext) or 74 end

  ext = reaper.GetExtState("FancyMapper", "ring_dwell_enabled")
  if ext ~= "" then cfg.dwell_enabled = (ext == "1" or ext == "true") end

  ext = reaper.GetExtState("FancyMapper", "ring_dwell_ms")
  if ext ~= "" then
    local ms = tonumber(ext) or 350
    cfg.dwell_s = ms / 1000.0
  end

  ext = reaper.GetExtState("FancyMapper", "ring_timeout_enabled")
  if ext ~= "" then cfg.timeout_enabled = (ext == "1" or ext == "true") end

  ext = reaper.GetExtState("FancyMapper", "ring_timeout_s")
  if ext ~= "" then cfg.timeout_s = tonumber(ext) or 3.0 end
end

-------------------------------------------------------------------------------
-- 4. RUNTIME STATE
-------------------------------------------------------------------------------
local ctx, fonts
local cx, cy                 -- ring centre in ReaImGui screen coordinates
local hovered = -1           -- hovered sector index (-1 = dead zone)
local start_time             -- time_precise() at spawn
local dwell_sector = -1
local dwell_start = 0
local confirmed = nil
local confirm_time = 0

-------------------------------------------------------------------------------
-- 5. SECTOR MATH & HELPERS
-------------------------------------------------------------------------------

--- Midpoint angle for sector i (0-based).
local function mid_angle(i)
  return TOP + i * SECTOR
end

--- Draw a filled pie-wedge from centre to OUTER_R using a triangle fan.
local function draw_wedge(dl, idx, col)
  local sa = mid_angle(idx) - HALF_SEC
  local da = SECTOR / ARC_TRIS
  for j = 0, ARC_TRIS - 1 do
    local a1 = sa + j * da
    local a2 = sa + (j + 1) * da
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      cx, cy,
      cx + OUTER_R * math.cos(a1), cy + OUTER_R * math.sin(a1),
      cx + OUTER_R * math.cos(a2), cy + OUTER_R * math.sin(a2),
      col)
  end
end

--- Current mode id from ExtState.
local function current_mode_id()
  local m = reaper.GetExtState("FancyMapper", "mode")
  if m == "" then m = reaper.GetExtState("FancyMapper", "default_mode") end
  if m == "" then m = "scrub" end
  return m
end

-------------------------------------------------------------------------------
-- 6. DRAWING
-------------------------------------------------------------------------------

local function draw_ring(dl, P)
  -------------------------------------------------------------------
  -- 6a. Subtle shadow halo
  -------------------------------------------------------------------
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, OUTER_R + 6,
    Theme.with_alpha(P.bg, 0.40), 64)

  -------------------------------------------------------------------
  -- 6b. Ring body background
  -------------------------------------------------------------------
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, OUTER_R,
    Theme.with_alpha(P.panel, 0.90), 64)

  -------------------------------------------------------------------
  -- 6c. Hovered sector fill
  -------------------------------------------------------------------
  if hovered >= 0 then
    local mode = MODES[hovered + 1]
    local col = mode.active
      and Theme.with_alpha(P.accent, 0.32)
      or  Theme.with_alpha(P.text_dim, 0.08)
    draw_wedge(dl, hovered, col)
  end

  -------------------------------------------------------------------
  -- 6d. Confirmation flash
  -------------------------------------------------------------------
  if confirmed then
    for i = 0, NUM_MODES - 1 do
      if MODES[i + 1].id == confirmed then
        draw_wedge(dl, i, Theme.with_alpha(P.accent, 0.65))
        break
      end
    end
  end

  -------------------------------------------------------------------
  -- 6e. Sector dividers
  -------------------------------------------------------------------
  for i = 0, NUM_MODES - 1 do
    local a = mid_angle(i) - HALF_SEC
    reaper.ImGui_DrawList_AddLine(dl,
      cx + DEAD_R * math.cos(a), cy + DEAD_R * math.sin(a),
      cx + OUTER_R * math.cos(a), cy + OUTER_R * math.sin(a),
      Theme.with_alpha(P.border, 0.35), 1.0)
  end

  -------------------------------------------------------------------
  -- 6f. Ring border
  -------------------------------------------------------------------
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, OUTER_R,
    Theme.with_alpha(P.border, 0.50), 64, 1.0)

  -------------------------------------------------------------------
  -- 6g. Centre dead-zone circle (Cancel zone)
  -------------------------------------------------------------------
  local is_in_dead_zone = (hovered == -1)
  local dead_bg = is_in_dead_zone
    and Theme.with_alpha(P.card, 0.95)
    or  Theme.with_alpha(P.bg, 0.95)
  local dead_border = is_in_dead_zone
    and Theme.with_alpha(P.accent, 0.50)
    or  Theme.with_alpha(P.border, 0.40)

  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, DEAD_R, dead_bg, 32)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, DEAD_R, dead_border, 32, 1.0)

  -------------------------------------------------------------------
  -- 6h. Centre label: shows "Cancel" in dead zone, else current mode
  -------------------------------------------------------------------
  local cur_id = current_mode_id()
  local center_text, center_col
  if is_in_dead_zone then
    center_text = "Cancel"
    center_col  = P.text_dim
  else
    center_text = cur_id
    for _, m in ipairs(MODES) do
      if m.id == cur_id then center_text = m.label; break end
    end
    center_col = P.text
  end

  local tw, th = reaper.ImGui_CalcTextSize(ctx, center_text)
  reaper.ImGui_DrawList_AddText(dl,
    cx - tw * 0.5, cy - th * 0.5, center_col, center_text)

  -------------------------------------------------------------------
  -- 6i. Mode labels (around the ring)
  -------------------------------------------------------------------
  for i = 0, NUM_MODES - 1 do
    local mode = MODES[i + 1]
    local a = mid_angle(i)
    local lx = cx + LABEL_R * math.cos(a)
    local ly = cy + LABEL_R * math.sin(a)

    local lbl = mode.label
    local lw, lh = reaper.ImGui_CalcTextSize(ctx, lbl)

    local col
    if not mode.active then
      col = Theme.with_alpha(P.text_dim, 0.35)
    elseif i == hovered then
      col = P.text
    else
      col = P.text_dim
    end

    reaper.ImGui_DrawList_AddText(dl,
      lx - lw * 0.5, ly - lh * 0.5, col, lbl)
  end

  -------------------------------------------------------------------
  -- 6j. Active-mode dot on ring perimeter
  -------------------------------------------------------------------
  for i = 0, NUM_MODES - 1 do
    if MODES[i + 1].id == cur_id then
      local a = mid_angle(i)
      reaper.ImGui_DrawList_AddCircleFilled(dl,
        cx + (OUTER_R + 8) * math.cos(a),
        cy + (OUTER_R + 8) * math.sin(a),
        3.5, P.accent, 16)
      break
    end
  end
end

-------------------------------------------------------------------------------
-- 7. MAIN LOOP
-------------------------------------------------------------------------------

local function loop()
  local now = reaper.time_precise()
  local elapsed = now - start_time

  -- Confirmation animation complete → close
  if confirmed and (now - confirm_time) > CONFIRM_S then
    reaper.SetExtState("FancyMapper", "ring_active", "0", false)
    return
  end

  -- Safety net auto-close (inactivity)
  if not confirmed and cfg.timeout_enabled and elapsed > cfg.timeout_s then
    reaper.SetExtState("FancyMapper", "ring_active", "0", false)
    return
  end

  -- Capture mouse coordinates in ReaImGui screen space on first frame
  if not cx or not cy then
    local rmx, rmy = reaper.ImGui_GetMousePos(ctx)
    if rmx and rmy and (rmx ~= 0 or rmy ~= 0) then
      cx, cy = rmx, rmy
    else
      local smx, smy = reaper.GetMousePosition()
      if reaper.ImGui_PointConvertNative then
        cx, cy = reaper.ImGui_PointConvertNative(ctx, smx, smy, false)
      else
        cx, cy = smx, smy
      end
    end
  end

  -------------------------------------------------------------------
  -- Window setup
  -------------------------------------------------------------------
  local P = Theme.get_palette()

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x00000001)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x00000000)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 0)

  reaper.ImGui_SetNextWindowPos(ctx,
    cx - WIN_HALF, cy - WIN_HALF, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx,
    WIN_HALF * 2, WIN_HALF * 2, reaper.ImGui_Cond_Always())

  local wflags = reaper.ImGui_WindowFlags_NoTitleBar()
               | reaper.ImGui_WindowFlags_NoResize()
               | reaper.ImGui_WindowFlags_NoMove()
               | reaper.ImGui_WindowFlags_NoScrollbar()
               | reaper.ImGui_WindowFlags_NoSavedSettings()

  local visible, open = reaper.ImGui_Begin(ctx, "##fancy_ring", true, wflags)
  local keep_going = open

  if visible then
    local pf = Theme.push_font(ctx, fonts.default)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)

    local mx, my = reaper.ImGui_GetMousePos(ctx)
    local dx, dy = mx - cx, my - cy
    local dist = math.sqrt(dx * dx + dy * dy)

    -- Update hovered sector
    if not confirmed then
      if dist < INNER_R then
        hovered = -1
        dwell_sector = -1
        dwell_start = 0
      else
        local a = math.atan(dy, dx)
        local s = (a - TOP + HALF_SEC) % TWO_PI
        local sector_idx = math.floor(s / SECTOR) % NUM_MODES
        hovered = sector_idx

        if sector_idx ~= dwell_sector then
          dwell_sector = sector_idx
          dwell_start = now
        end
      end
    end

    -- Draw the radial action ring
    draw_ring(dl, P)

    local trigger_confirm = false
    local trigger_cancel  = false

    if not confirmed then
      -- 1. Check for second-tap of the shortcut action
      if reaper.GetExtState("FancyMapper", "ring_second_tap") == "1" then
        reaper.SetExtState("FancyMapper", "ring_second_tap", "0", false)
        if hovered >= 0 and MODES[hovered + 1].active then
          trigger_confirm = true
        else
          trigger_cancel = true
        end
      end

      -- 2. Directional Flick Selection: mouse moved outward into active sector
      if not trigger_confirm and cfg.flick_enabled and hovered >= 0 and dist >= cfg.flick_distance then
        if MODES[hovered + 1].active then
          trigger_confirm = true
        end
      end

      -- 3. Dwell Selection: mouse rested in active sector for cfg.dwell_s
      if not trigger_confirm and cfg.dwell_enabled and hovered >= 0 and dwell_start > 0 and (now - dwell_start) >= cfg.dwell_s then
        if MODES[hovered + 1].active then
          trigger_confirm = true
        end
      end

      -- 4. Left-Click: clicking an active sector confirms immediately
      if not trigger_confirm and reaper.ImGui_IsMouseClicked(ctx, 0) then
        if hovered >= 0 and MODES[hovered + 1].active then
          trigger_confirm = true
        else
          -- Clicked in center dead zone or placeholder
          trigger_cancel = true
        end
      end

      -- 5. Escape or Right-Click cancels
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
         or reaper.ImGui_IsMouseClicked(ctx, 1) then
        trigger_cancel = true
      end
    end

    -- Process confirmation
    if trigger_confirm and not confirmed then
      confirmed = MODES[hovered + 1].id
      confirm_time = now
      reaper.SetExtState("FancyMapper", "mode", confirmed, false)
    elseif trigger_cancel then
      keep_going = false
    end

    Theme.pop_font(ctx, pf)
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 2)

  if keep_going then
    reaper.defer(loop)
  else
    reaper.SetExtState("FancyMapper", "ring_active", "0", false)
    reaper.SetExtState("FancyMapper", "ring_second_tap", "0", false)
  end
end

-------------------------------------------------------------------------------
-- 8. MAIN
-------------------------------------------------------------------------------

local function main()
  load_ring_config()
  start_time = reaper.time_precise()

  -- Mark ring active in ExtState
  reaper.SetExtState("FancyMapper", "ring_active", "1", false)
  reaper.SetExtState("FancyMapper", "ring_last_tap", tostring(start_time), false)
  reaper.SetExtState("FancyMapper", "ring_second_tap", "0", false)

  ctx   = reaper.ImGui_CreateContext("Fancy Mapper Ring")
  fonts = Theme.create_fonts(ctx)
  Theme.attach_fonts(ctx, fonts)

  -- Initial coordinate estimation using ReaImGui PointConvertNative
  local smx, smy = reaper.GetMousePosition()
  if reaper.ImGui_PointConvertNative then
    cx, cy = reaper.ImGui_PointConvertNative(ctx, smx, smy, false)
  else
    cx, cy = smx, smy
  end

  reaper.atexit(function()
    reaper.SetExtState("FancyMapper", "ring_active", "0", false)
    reaper.SetExtState("FancyMapper", "ring_second_tap", "0", false)
  end)

  reaper.defer(loop)
end

main()
