-- @description Fancy Mapper Core Engine
-- @author Fancy Scripts
-- @version 5.1.0
-- @about
--   Shared engine for Fancy Mapper scripts.
--   Provides unified configuration, throttling, context targeting,
--   parameter math, and undo management for hardware dials and encoders.
--   Modes supported: Scrub, FX Parameter, Pan, Volume, Width, MIDI CC,
--   Velocity, Track Nav, Marker, Transient, Item Slip.

local MapperEngine = {}

local EXTSTATE_SECTION = "FancyMapper"

-------------------------------------------------------------------------------
-- 1. CONFIGURATION
-------------------------------------------------------------------------------

local function get_cfg(key, default)
  local v = reaper.GetExtState(EXTSTATE_SECTION, key)
  if v == "" then return default end
  return v
end

local function get_num(key, default)
  return tonumber(get_cfg(key, nil)) or default
end

local function get_bool(key, default)
  local v = get_cfg(key, nil)
  if v == nil then return default end
  return v == "1" or v == "true"
end

function MapperEngine.load_config()
  return {
    ticks                 = get_num("ticks_per_rotation", 26),
    throttle              = get_num("throttle_ms", 60),
    scrub_unit            = get_cfg("scrub_unit", "free"),
    scrub_secs            = get_num("scrub_seconds", 2.0),
    scrub_view            = get_bool("scrub_move_view", true),
    fx_sens               = get_num("fx_sensitivity", 1.0),
    fx_fallback           = get_bool("fx_pan_fallback", true),
    pan_sens              = get_num("pan_sensitivity", 1.0),
    vol_step              = get_num("vol_step_db", 1.0),
    width_sens            = get_num("width_sensitivity", 1.0),
    width_auto_stereo_pan = get_bool("width_auto_stereo_pan", true),
    midi_cc_targets       = get_cfg("midi_cc_targets", "1"),
    midi_cc_sens          = get_num("midi_cc_sensitivity", 1.0),
    midi_cc_linear        = get_bool("midi_cc_linear", true),
    midi_channel          = get_num("midi_channel", 1),
    midi_auto_arm         = get_bool("midi_auto_arm", true),
    midi_show_tooltip     = get_bool("midi_show_tooltip", true),
    midi_vel_sens         = get_num("midi_vel_sensitivity", 1.0),
    midi_vel_audition     = get_bool("midi_vel_audition", false),
    slip_step_ms          = get_num("slip_step_ms", 10),
    track_nav_scroll      = get_bool("track_nav_scroll", true),
    smooth_dial_enabled   = get_bool("smooth_dial_enabled", true),
    smooth_dial_speed     = get_num("smooth_dial_speed", 25.0),
    smooth_vol            = get_bool("smooth_vol", true),
    smooth_pan            = get_bool("smooth_pan", true),
    smooth_width          = get_bool("smooth_width", true),
    smooth_fx             = get_bool("smooth_fx", true),
    smooth_midi_cc        = get_bool("smooth_midi_cc", true),
    smooth_scrub          = get_bool("smooth_scrub", true),
    smooth_slip           = get_bool("smooth_slip", true),
  }
end

function MapperEngine.get_mode()
  local mode = reaper.GetExtState(EXTSTATE_SECTION, "mode")
  if mode == "" then
    mode = reaper.GetExtState(EXTSTATE_SECTION, "default_mode")
  end
  if mode == "" then mode = "scrub" end
  return mode
end

-------------------------------------------------------------------------------
-- 2. THROTTLE
-------------------------------------------------------------------------------

function MapperEngine.should_run(direction, cfg)
  local now = reaper.time_precise() * 1000
  local key = (direction > 0) and "last_up" or "last_down"
  local last = tonumber(reaper.GetExtState(EXTSTATE_SECTION, key) or "0") or 0
  if now - last < cfg.throttle then
    return false
  end
  reaper.SetExtState(EXTSTATE_SECTION, key, tostring(now), false)
  return true
end

-------------------------------------------------------------------------------
-- 3. TARGETING HELPERS
-------------------------------------------------------------------------------

local function get_track_under_cursor()
  local x, y = reaper.GetMousePosition()
  return reaper.GetTrackFromPoint(x, y)
end

local function get_target_track()
  -- Priority 1: track under mouse cursor
  local tr = get_track_under_cursor()
  if tr then return tr end

  -- Priority 2: track of currently focused FX window
  local f_ret, f_tr_idx = reaper.GetTouchedOrFocusedFX(1)
  if f_ret then
    if f_tr_idx == -1 then
      return reaper.GetMasterTrack(0)
    elseif f_tr_idx >= 0 then
      local t = reaper.GetTrack(0, f_tr_idx)
      if t then return t end
    end
  end

  -- Priority 3: track of last touched FX parameter
  local t_ret, t_tr_idx = reaper.GetTouchedOrFocusedFX(0)
  if t_ret then
    if t_tr_idx == -1 then
      return reaper.GetMasterTrack(0)
    elseif t_tr_idx >= 0 then
      local t = reaper.GetTrack(0, t_tr_idx)
      if t then return t end
    end
  end

  -- Priority 4: first selected track
  if reaper.CountSelectedTracks(0) > 0 then
    return reaper.GetSelectedTrack(0, 0)
  end

  -- Priority 5: first track in project fallback
  if reaper.CountTracks(0) > 0 then
    return reaper.GetTrack(0, 0)
  end

  return nil
end

local function get_guid_for_track(track)
  if not track then return "" end
  if track == reaper.GetMasterTrack(0) then return "MASTER" end
  return reaper.GetTrackGUID(track)
end

local function get_track_by_guid(guid_str)
  if not guid_str or guid_str == "" then return nil end
  if guid_str == "MASTER" then return reaper.GetMasterTrack(0) end
  if reaper.BR_GetMediaTrackByGUID then
    return reaper.BR_GetMediaTrackByGUID(0, guid_str)
  end
  local tr_cnt = reaper.CountTracks(0)
  for i = 0, tr_cnt - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(tr) == guid_str then
      return tr
    end
  end
  return nil
end

function MapperEngine.is_daemon_alive()
  local now = reaper.time_precise()
  local last_ping = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "daemon_ping") or "0") or 0
  return (now - last_ping) < 1.0
end

function MapperEngine.ensure_daemon_running()
  if MapperEngine.is_daemon_alive() then return true end

  local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
  local daemon_path = script_dir .. "../Mixing/Fancy_Mapper Daemon.lua"
  if not reaper.file_exists(daemon_path) then
    daemon_path = script_dir .. "Fancy_Mapper Daemon.lua"
  end

  local cmd_id = reaper.AddRemoveReaScript(true, 0, daemon_path, true)
  if cmd_id and cmd_id > 0 then
    reaper.Main_OnCommand(cmd_id, 0)
    return true
  end
  return false
end

local function ensure_track_midi_ready(track)
  if not track then return end

  -- 1. Record arm
  local recarm = reaper.GetMediaTrackInfo_Value(track, "I_RECARM")
  if recarm == 0 then
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
  end

  -- 2. Record monitoring (1 = normal)
  local recmon = reaper.GetMediaTrackInfo_Value(track, "I_RECMON")
  if recmon == 0 then
    reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)
  end

  -- 3. Record input (ensure MIDI enabled and VKB allowed)
  local recinput = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT")
  if recinput < 4096 then
    -- Set to All MIDI inputs, all channels (6112)
    reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", 6112)
  else
    local dev = (math.floor(recinput) - 4096) >> 5
    if dev ~= 63 and dev ~= 62 then
      -- Switch device to All MIDI inputs (63) while preserving track channel filter
      local chan = math.floor(recinput) & 31
      local new_input = 4096 | (63 << 5) | chan
      reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", new_input)
    end
  end
end

local function get_target_item()
  -- Priority 1: item under mouse cursor
  local x, y = reaper.GetMousePosition()
  local item = reaper.GetItemFromPoint(x, y, true)
  if item then return item end

  -- Priority 2: first selected media item
  if reaper.CountSelectedMediaItems(0) > 0 then
    return reaper.GetSelectedMediaItem(0, 0)
  end
  return nil
end

local function get_target_take()
  -- Priority 1: active take in open MIDI editor
  local midieditor = reaper.MIDIEditor_GetActive()
  if midieditor then
    local take = reaper.MIDIEditor_GetTake(midieditor)
    if take then return take, midieditor end
  end

  -- Priority 2: active take of target media item
  local item = get_target_item()
  if item then
    local take = reaper.GetActiveTake(item)
    if take then return take, nil end
  end

  -- Priority 3: item under edit cursor or last item on target track
  local track = get_target_track()
  if track then
    local cur_pos = reaper.GetCursorPosition()
    local item_count = reaper.CountTrackMediaItems(track)
    for i = item_count - 1, 0, -1 do
      local it = reaper.GetTrackMediaItem(track, i)
      local it_pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local it_len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if cur_pos >= it_pos and cur_pos <= (it_pos + it_len) then
        local take = reaper.GetActiveTake(it)
        if take then return take, nil end
      end
    end
    if item_count > 0 then
      local it = reaper.GetTrackMediaItem(track, item_count - 1)
      local take = reaper.GetActiveTake(it)
      if take then return take, nil end
    end
  end

  return nil, nil
end

-------------------------------------------------------------------------------
-- 4. MODE ADJUSTERS
-------------------------------------------------------------------------------

-- 4a. Scrub / Jog
function MapperEngine.adjust_scrub(direction, cfg)
  local unit = cfg.scrub_unit

  if unit == "beat" then
    local action = direction > 0 and 40105 or 40104
    reaper.Main_OnCommand(action, 0)
    return true
  end

  if unit == "measure" then
    local action = direction > 0 and 40103 or 40102
    reaper.Main_OnCommand(action, 0)
    return true
  end

  if unit == "grid" then
    local pos = reaper.GetCursorPosition()
    local new_pos
    if direction > 0 then
      new_pos = reaper.BR_GetNextGridDivision and reaper.BR_GetNextGridDivision(pos)
    else
      new_pos = reaper.BR_GetPrevGridDivision and reaper.BR_GetPrevGridDivision(pos)
    end
    if new_pos then
      reaper.SetEditCurPos(new_pos, cfg.scrub_view, false)
    end
    return true
  end

  -- "free": smooth time-based jog
  local step = cfg.scrub_secs / cfg.ticks
  local pos = reaper.GetCursorPosition()

  if cfg.smooth_dial_enabled and cfg.smooth_scrub then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_scrub_pos")
    local tgt_pos = tonumber(tgt_str) or pos
    if math.abs(tgt_pos - pos) > (cfg.scrub_secs * 2.0) then tgt_pos = pos end

    local new_tgt = math.max(0.0, tgt_pos + step * direction)
    reaper.SetExtState(EXTSTATE_SECTION, "target_scrub_pos", tostring(new_tgt), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_scrub_pos", tostring(pos), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    MapperEngine.ensure_daemon_running()
    return true
  end

  local new_pos = math.max(0.0, pos + step * direction)
  reaper.SetEditCurPos(new_pos, cfg.scrub_view, false)
  return true
end

-- 4b. FX Parameter
function MapperEngine.adjust_fx_param(direction, cfg)
  local retval, trackidx, itemidx, takeidx, fxidx, parm =
        reaper.GetTouchedOrFocusedFX(0)
  if not retval then return false end

  local track
  if trackidx == -1 then
    track = reaper.GetMasterTrack(0)
  else
    track = reaper.GetTrack(0, trackidx)
  end
  if not track then return false end

  local step = (1.0 / cfg.ticks) * cfg.fx_sens
  local is_take = (itemidx >= 0)
  local cur_val
  local target_take = nil

  if is_take then
    local item = reaper.GetTrackMediaItem(track, itemidx)
    if not item then return false end
    target_take = reaper.GetTake(item, takeidx)
    if not target_take then return false end
    cur_val = reaper.TakeFX_GetParamNormalized(target_take, fxidx, parm)
  else
    cur_val = reaper.TrackFX_GetParamNormalized(track, fxidx, parm)
  end

  if cfg.smooth_dial_enabled and cfg.smooth_fx then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_fx_val")
    local tgt_val = tonumber(tgt_str) or cur_val
    if math.abs(tgt_val - cur_val) > 0.3 then tgt_val = cur_val end

    local new_tgt = math.min(1.0, math.max(0.0, tgt_val + step * direction))
    reaper.SetExtState(EXTSTATE_SECTION, "target_fx_val", tostring(new_tgt), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_fx_val", tostring(cur_val), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_fx_is_take", is_take and "1" or "0", false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_fx_track_guid", get_guid_for_track(track), false)
    if is_take then
      reaper.SetExtState(EXTSTATE_SECTION, "smooth_fx_item_idx", tostring(itemidx), false)
      reaper.SetExtState(EXTSTATE_SECTION, "smooth_fx_take_idx", tostring(takeidx), false)
    end
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_fx_idx", tostring(fxidx), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_fx_parm", tostring(parm), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      local parm_name = "Param"
      if is_take and target_take then
        local _, name = reaper.TakeFX_GetParamName(target_take, fxidx, parm, "")
        if name and name ~= "" then parm_name = name end
      else
        local _, name = reaper.TrackFX_GetParamName(track, fxidx, parm, "")
        if name and name ~= "" then parm_name = name end
      end
      local tip = string.format("FX: %s (%.0f%%)", parm_name, new_tgt * 100)
      reaper.TrackCtl_SetToolTip(tip, mx + 16, my + 16, true)
    end

    MapperEngine.ensure_daemon_running()
    return true
  end

  -- Item/take FX fallback
  if is_take then
    local item = reaper.GetTrackMediaItem(track, itemidx)
    if not item then return false end
    local take = reaper.GetTake(item, takeidx)
    if not take then return false end
    local val = math.min(math.max(cur_val + step * direction, 0.0), 1.0)
    reaper.TakeFX_SetParamNormalized(take, fxidx, parm, val)
    return true
  end

  -- Track FX fallback
  local val = math.min(math.max(cur_val + step * direction, 0.0), 1.0)
  reaper.TrackFX_SetParamNormalized(track, fxidx, parm, val)
  return true
end

-- 4c. Pan
local function adjust_pan_on_track(track, direction, cfg)
  local cur_pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN")
  local step = (2.0 / cfg.ticks) * cfg.pan_sens

  if cfg.smooth_dial_enabled and cfg.smooth_pan then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_pan")
    local tgt_pan = tonumber(tgt_str) or cur_pan
    if math.abs(tgt_pan - cur_pan) > 0.5 then tgt_pan = cur_pan end

    local new_tgt_pan = math.min(1.0, math.max(-1.0, tgt_pan + (step * direction)))
    reaper.SetExtState(EXTSTATE_SECTION, "target_pan", tostring(new_tgt_pan), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_pan", tostring(cur_pan), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_track_guid", get_guid_for_track(track), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      local pan_pct = math.floor(math.abs(new_tgt_pan) * 100 + 0.5)
      local pan_str = (new_tgt_pan == 0) and "Center" or (new_tgt_pan < 0 and string.format("%d%% L", pan_pct) or string.format("%d%% R", pan_pct))
      reaper.TrackCtl_SetToolTip("Pan: " .. pan_str, mx + 16, my + 16, true)
    end

    MapperEngine.ensure_daemon_running()
    return true
  end

  local pan = math.min(math.max(cur_pan + (step * direction), -1.0), 1.0)
  reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan)

  if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
    local mx, my = reaper.GetMousePosition()
    local pan_pct = math.floor(math.abs(pan) * 100 + 0.5)
    local pan_str = (pan == 0) and "Center" or (pan < 0 and string.format("%d%% L", pan_pct) or string.format("%d%% R", pan_pct))
    reaper.TrackCtl_SetToolTip("Pan: " .. pan_str, mx + 16, my + 16, true)
  end
  return true
end

function MapperEngine.adjust_pan(direction, cfg)
  local track = get_target_track()
  if track then return adjust_pan_on_track(track, direction, cfg) end
  return false
end

-- 4d. Volume
local function adjust_volume_on_track(track, direction, cfg)
  local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
  local cur_db = (vol > 0.0000001) and (20 * math.log(vol, 10)) or -150.0

  if cfg.smooth_dial_enabled and cfg.smooth_vol then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_vol_db")
    local tgt_db = tonumber(tgt_str) or cur_db
    if math.abs(tgt_db - cur_db) > 12.0 then tgt_db = cur_db end

    local new_tgt_db = math.min(12.0, math.max(-150.0, tgt_db + cfg.vol_step * direction))
    reaper.SetExtState(EXTSTATE_SECTION, "target_vol_db", tostring(new_tgt_db), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_vol_db", tostring(cur_db), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_track_guid", get_guid_for_track(track), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      local vol_str = (new_tgt_db <= -140.0) and "-inf dB" or string.format("%+.1f dB", new_tgt_db)
      reaper.TrackCtl_SetToolTip("Volume: " .. vol_str, mx + 16, my + 16, true)
    end

    MapperEngine.ensure_daemon_running()
    return true
  end

  local db = math.min(math.max(cur_db + cfg.vol_step * direction, -150.0), 12.0)
  local new_vol = (db <= -140.0) and 0.0 or (10 ^ (db / 20))
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", new_vol)

  if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
    local mx, my = reaper.GetMousePosition()
    local vol_str = (db <= -140.0) and "-inf dB" or string.format("%+.1f dB", db)
    reaper.TrackCtl_SetToolTip("Volume: " .. vol_str, mx + 16, my + 16, true)
  end
  return true
end

function MapperEngine.adjust_volume(direction, cfg)
  local track = get_target_track()
  if track then return adjust_volume_on_track(track, direction, cfg) end
  return false
end

-- 4e. Width
local function adjust_width_on_track(track, direction, cfg)
  local pan_mode = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_PANMODE"))
  local mode_changed = false
  if cfg.width_auto_stereo_pan and pan_mode ~= 5 and pan_mode ~= 6 then
    -- Promote to Stereo Pan (mode 5) so width is active and visible
    reaper.SetMediaTrackInfo_Value(track, "I_PANMODE", 5)
    mode_changed = true
  end

  local cur_width = reaper.GetMediaTrackInfo_Value(track, "D_WIDTH")
  local step = (2.0 / cfg.ticks) * cfg.width_sens

  if mode_changed then
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
  end

  if cfg.smooth_dial_enabled and cfg.smooth_width then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_width")
    local tgt_w = tonumber(tgt_str) or cur_width
    if math.abs(tgt_w - cur_width) > 0.5 then tgt_w = cur_width end

    local new_tgt_w = math.min(1.0, math.max(-1.0, tgt_w + (step * direction)))
    reaper.SetExtState(EXTSTATE_SECTION, "target_width", tostring(new_tgt_w), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_width", tostring(cur_width), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_track_guid", get_guid_for_track(track), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      local width_pct = math.floor(new_tgt_w * 100 + 0.5)
      reaper.TrackCtl_SetToolTip(string.format("Width: %d%%", width_pct), mx + 16, my + 16, true)
    end

    MapperEngine.ensure_daemon_running()
    return true
  end

  local width = math.min(math.max(cur_width + (step * direction), -1.0), 1.0)
  reaper.SetMediaTrackInfo_Value(track, "D_WIDTH", width)

  if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
    local mx, my = reaper.GetMousePosition()
    local width_pct = math.floor(width * 100 + 0.5)
    reaper.TrackCtl_SetToolTip(string.format("Width: %d%%", width_pct), mx + 16, my + 16, true)
  end
  return true
end

function MapperEngine.adjust_width(direction, cfg)
  local track = get_target_track()
  if track then return adjust_width_on_track(track, direction, cfg) end
  return false
end

-- 4f. Multi-CC
local function parse_cc_targets(target_str)
  local list = {}
  local seen = {}
  for token in string.gmatch(target_str or "1", "%d+") do
    local num = tonumber(token)
    if num and num >= 0 and num <= 127 and not seen[num] then
      seen[num] = true
      list[#list + 1] = num
    end
  end
  if #list == 0 then list = { 1 } end
  return list, seen
end

local function format_cc_label(cc_list)
  local cc_names = {}
  for _, num in ipairs(cc_list) do
    if num == 1 then
      cc_names[#cc_names + 1] = "Mod (1)"
    elseif num == 11 then
      cc_names[#cc_names + 1] = "Expr (11)"
    elseif num == 7 then
      cc_names[#cc_names + 1] = "Vol (7)"
    else
      cc_names[#cc_names + 1] = "CC " .. num
    end
  end
  return table.concat(cc_names, " + ")
end

function MapperEngine.linearize_take_cc(target_take, target_ccs)
  local take = target_take
  if not take then
    local take_found = get_target_take()
    take = take_found
  end
  if not take or not reaper.TakeIsMIDI(take) then
    return 0
  end

  local cc_set = nil
  if type(target_ccs) == "table" and #target_ccs > 0 then
    cc_set = {}
    for _, num in ipairs(target_ccs) do
      cc_set[num] = true
    end
  end

  local _, _, cc_count = reaper.MIDI_CountEvts(take)
  if cc_count == 0 then return 0 end

  -- Check if any CC events are selected
  local has_sel = false
  for i = 0, cc_count - 1 do
    local ok, sel = reaper.MIDI_GetCC(take, i)
    if ok and sel then
      has_sel = true
      break
    end
  end

  reaper.Undo_BeginBlock()
  reaper.MIDI_DisableSort(take)
  local modified = 0
  for i = 0, cc_count - 1 do
    local ok, sel, _, _, chanmsg, _, msg2, _ = reaper.MIDI_GetCC(take, i)
    if ok and (chanmsg == 0xB0 or chanmsg == 0xE0) then
      if (not has_sel or sel) and (not cc_set or cc_set[msg2]) then
        -- Shape 1 = Linear, beztension = 0.0, noSortIn = true
        reaper.MIDI_SetCCShape(take, i, 1, 0.0, true)
        modified = modified + 1
      end
    end
  end
  reaper.MIDI_Sort(take)
  local item = reaper.GetMediaItemTake_Item(take)
  if item then
    reaper.UpdateItemInProject(item)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Fancy Mapper: Smooth CC Lane (Linearize)", -1)
  return modified
end

function MapperEngine.adjust_midi_cc(direction, cfg)
  local track = get_target_track()
  if cfg.midi_auto_arm and track then
    ensure_track_midi_ready(track)
  end

  local cc_list = parse_cc_targets(cfg.midi_cc_targets)
  local chan = math.max(1, math.min(16, math.floor(cfg.midi_channel or 1)))
  local status = 0xB0 | ((chan - 1) & 0x0F)

  -- Math: exactly 1 full rotation (cfg.ticks) = full 0 to 127 sweep
  local step = (127.0 / cfg.ticks) * cfg.midi_cc_sens

  -- High-precision float state in ExtState avoids rounding drift across turns
  local val_str = reaper.GetExtState(EXTSTATE_SECTION, "live_cc_val")
  local cur_val = tonumber(val_str) or 64.0

  -- If take has selected CC events, nudge them as well
  local take, midieditor = get_target_take()
  if take and reaper.TakeIsMIDI(take) then
    local _, _, cc_count = reaper.MIDI_CountEvts(take)
    local has_sel = false
    for i = 0, cc_count - 1 do
      local _, sel = reaper.MIDI_GetCC(take, i)
      if sel then has_sel = true; break end
    end
    if has_sel then
      local int_step = math.max(1, math.floor(step + 0.5))
      reaper.Undo_BeginBlock()
      reaper.MIDI_DisableSort(take)
      for i = 0, cc_count - 1 do
        local ok, sel, muted, ppqpos, chanmsg, c, msg2, msg3 = reaper.MIDI_GetCC(take, i)
        if ok and sel then
          local v = math.min(127, math.max(0, msg3 + int_step * direction))
          reaper.MIDI_SetCC(take, i, sel, muted, ppqpos, chanmsg, c, msg2, v, false)
        end
      end
      reaper.MIDI_Sort(take)
      reaper.Undo_EndBlock("Fancy Mapper: Nudge Selected MIDI CC", -1)
    end
  end

  -- If MIDI editor is open and linear mode is active, set default CC shape to linear
  if cfg.midi_cc_linear and midieditor then
    reaper.MIDIEditor_OnCommand(midieditor, 42087)
  end

  if cfg.smooth_dial_enabled and cfg.smooth_midi_cc then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_cc_val")
    local tgt_val = tonumber(tgt_str) or cur_val
    if math.abs(tgt_val - cur_val) > 40.0 then tgt_val = cur_val end

    local new_tgt = math.min(127.0, math.max(0.0, tgt_val + step * direction))
    reaper.SetExtState(EXTSTATE_SECTION, "target_cc_val", tostring(new_tgt), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_cc_val", tostring(cur_val), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      local tip = string.format("MIDI %s: %d", format_cc_label(cc_list), math.floor(new_tgt + 0.5))
      reaper.TrackCtl_SetToolTip(tip, mx + 16, my + 16, true)
    end

    MapperEngine.ensure_daemon_running()
    return true
  end

  -- Direct / Instant fallback
  local new_float = math.min(127.0, math.max(0.0, cur_val + step * direction))
  if math.abs(new_float) < 1e-6 then new_float = 0.0 end
  if math.abs(new_float - 127.0) < 1e-6 then new_float = 127.0 end
  reaper.SetExtState(EXTSTATE_SECTION, "live_cc_val", tostring(new_float), false)

  local new_val = math.floor(new_float + 0.5 + 1e-9)

  -- Send live MIDI signals to VKB queue (mode 0) and Control Path (mode 1)
  for _, cc_num in ipairs(cc_list) do
    reaper.StuffMIDIMessage(0, status, cc_num, new_val)
    reaper.StuffMIDIMessage(1, status, cc_num, new_val)
    reaper.SetExtState(EXTSTATE_SECTION, "live_cc_val_" .. cc_num, tostring(new_float), false)
  end

  -- Visual HUD tooltip
  if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
    local mx, my = reaper.GetMousePosition()
    local tip = string.format("MIDI %s: %d", format_cc_label(cc_list), new_val)
    reaper.TrackCtl_SetToolTip(tip, mx + 16, my + 16, true)
  end

  return true
end

-- 4g. Velocity
function MapperEngine.adjust_midi_vel(direction, cfg)
  local track = get_target_track()
  if cfg.midi_auto_arm and track then
    ensure_track_midi_ready(track)
  end

  local chan = math.max(1, math.min(16, math.floor(cfg.midi_channel or 1)))

  -- Math: exactly 1 full rotation (cfg.ticks) = full 1 to 127 sweep
  local step = (126.0 / cfg.ticks) * cfg.midi_vel_sens

  -- High-precision float state in ExtState avoids rounding drift
  local val_str = reaper.GetExtState(EXTSTATE_SECTION, "live_vel_val")
  local cur_vel = tonumber(val_str) or 96.0
  local new_float = math.min(127.0, math.max(1.0, cur_vel + step * direction))
  if math.abs(new_float - 1.0) < 1e-6 then new_float = 1.0 end
  if math.abs(new_float - 127.0) < 1e-6 then new_float = 127.0 end
  reaper.SetExtState(EXTSTATE_SECTION, "live_vel_val", tostring(new_float), false)

  local new_vel = math.floor(new_float + 0.5 + 1e-9)

  -- 1. If MIDI Editor is active, update default note velocity for all new notes drawn/entered
  local midieditor = reaper.MIDIEditor_GetActive()
  if midieditor then
    reaper.MIDIEditor_SetSetting_int(midieditor, "default_note_vel", new_vel)
  end

  -- 2. If a take has selected notes, nudge their velocities
  local take, _ = get_target_take()
  if take and reaper.TakeIsMIDI(take) then
    local _, note_count = reaper.MIDI_CountEvts(take)
    local has_sel_note = false
    for i = 0, note_count - 1 do
      local _, sel = reaper.MIDI_GetNote(take, i)
      if sel then has_sel_note = true; break end
    end
    if has_sel_note then
      local int_step = math.max(1, math.floor(step + 0.5))
      reaper.Undo_BeginBlock()
      reaper.MIDI_DisableSort(take)
      for i = 0, note_count - 1 do
        local ok, sel, muted, startppq, endppq, c, pitch, vel = reaper.MIDI_GetNote(take, i)
        if ok and sel then
          local v = math.min(127, math.max(1, vel + int_step * direction))
          reaper.MIDI_SetNote(take, i, sel, muted, startppq, endppq, c, pitch, v, false)
        end
      end
      reaper.MIDI_Sort(take)
      reaper.Undo_EndBlock("Fancy Mapper: Nudge Note Velocity", -1)
    end
  end

  -- 3. If audition is enabled in settings and transport is stopped, send a quick audition note
  if cfg.midi_vel_audition and reaper.GetPlayState() == 0 then
    local note_on = 0x90 | ((chan - 1) & 0x0F)
    local note_off = 0x80 | ((chan - 1) & 0x0F)
    reaper.StuffMIDIMessage(0, note_on, 60, new_vel)
    reaper.StuffMIDIMessage(0, note_off, 60, 0)
  end

  -- Visual HUD tooltip
  if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
    local mx, my = reaper.GetMousePosition()
    local tip = string.format("Velocity: %d", new_vel)
    reaper.TrackCtl_SetToolTip(tip, mx + 16, my + 16, true)
  end

  return true
end

-- 4h. Track Navigation
function MapperEngine.adjust_track_nav(direction, cfg)
  local action = direction > 0 and 40285 or 40286
  reaper.Main_OnCommand(action, 0)
  if cfg.track_nav_scroll and reaper.TrackList_AdjustWindows then
    reaper.TrackList_AdjustWindows(false)
  end
  return true
end

-- 4i. Marker Jump
function MapperEngine.adjust_marker(direction, _)
  local action = direction > 0 and 40172 or 40173
  reaper.Main_OnCommand(action, 0)
  return true
end

-- 4j. Transient Jump
function MapperEngine.adjust_transient(direction, _)
  -- Ensure item under cursor is selected if no items selected
  if reaper.CountSelectedMediaItems(0) == 0 then
    local x, y = reaper.GetMousePosition()
    local item = reaper.GetItemFromPoint(x, y, true)
    if item then
      reaper.SetMediaItemSelected(item, true)
      reaper.UpdateArrange()
    end
  end
  local action = direction > 0 and 40375 or 40376
  reaper.Main_OnCommand(action, 0)
  return true
end

-- 4k. Item Slip
function MapperEngine.adjust_item_slip(direction, cfg)
  local item = get_target_item()
  if not item then return false end
  local take = reaper.GetActiveTake(item)
  if not take then return false end

  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local step = cfg.slip_step_ms / 1000.0

  if cfg.smooth_dial_enabled and cfg.smooth_slip then
    local tgt_str = reaper.GetExtState(EXTSTATE_SECTION, "target_slip_offs")
    local tgt_offs = tonumber(tgt_str) or offs
    if math.abs(tgt_offs - offs) > (step * 20.0) then tgt_offs = offs end

    local new_tgt_offs = math.max(0.0, tgt_offs + (step * direction))
    local track = reaper.GetMediaItem_Track(item)
    local item_idx = math.floor(reaper.GetMediaItemInfo_Value(item, "IP_ITEMNUMBER"))

    reaper.SetExtState(EXTSTATE_SECTION, "target_slip_offs", tostring(new_tgt_offs), false)
    reaper.SetExtState(EXTSTATE_SECTION, "cur_slip_offs", tostring(offs), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_item_tr_guid", get_guid_for_track(track), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_item_idx", tostring(item_idx), false)
    reaper.SetExtState(EXTSTATE_SECTION, "smooth_last_tick", tostring(reaper.time_precise()), false)

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      reaper.TrackCtl_SetToolTip(string.format("Item Slip: %.0f ms", new_tgt_offs * 1000.0), mx + 16, my + 16, true)
    end

    MapperEngine.ensure_daemon_running()
    return true
  end

  local new_offs = math.max(0.0, offs + (step * direction))
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_offs)
  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  return true
end

-------------------------------------------------------------------------------
-- 4l. SMOOTH DIAL SLEW PROCESSOR (60 Hz CONSUMER ENGINE)
-------------------------------------------------------------------------------

function MapperEngine.process_smooth_step(dt)
  local cfg = MapperEngine.load_config()
  local speed = math.max(1.0, cfg.smooth_dial_speed or 25.0)
  local alpha = 1.0 - math.exp(-speed * dt)
  local is_busy = false

  -- 1. Volume
  local tgt_vol_str = reaper.GetExtState(EXTSTATE_SECTION, "target_vol_db")
  if tgt_vol_str and tgt_vol_str ~= "" then
    local tgt_db = tonumber(tgt_vol_str)
    local tr_guid = reaper.GetExtState(EXTSTATE_SECTION, "smooth_track_guid")
    local tr = get_track_by_guid(tr_guid)
    if tgt_db and tr then
      local vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
      local cur_db = (vol > 0.0000001) and (20 * math.log(vol, 10)) or -150.0
      local diff = tgt_db - cur_db
      if math.abs(diff) < 0.05 then
        cur_db = tgt_db
        reaper.DeleteExtState(EXTSTATE_SECTION, "target_vol_db", false)
        reaper.DeleteExtState(EXTSTATE_SECTION, "cur_vol_db", false)
        reaper.Undo_OnStateChangeEx("Fancy Mapper: Adjust Volume", -1, -1)
      else
        cur_db = cur_db + diff * alpha
        is_busy = true
      end
      local new_vol = (cur_db <= -140.0) and 0.0 or (10 ^ (cur_db / 20))
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", new_vol)
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_vol_db", false)
    end
  end

  -- 2. Pan
  local tgt_pan_str = reaper.GetExtState(EXTSTATE_SECTION, "target_pan")
  if tgt_pan_str and tgt_pan_str ~= "" then
    local tgt_pan = tonumber(tgt_pan_str)
    local tr_guid = reaper.GetExtState(EXTSTATE_SECTION, "smooth_track_guid")
    local tr = get_track_by_guid(tr_guid)
    if tgt_pan and tr then
      local cur_pan = reaper.GetMediaTrackInfo_Value(tr, "D_PAN")
      local diff = tgt_pan - cur_pan
      if math.abs(diff) < 0.005 then
        cur_pan = tgt_pan
        reaper.DeleteExtState(EXTSTATE_SECTION, "target_pan", false)
        reaper.DeleteExtState(EXTSTATE_SECTION, "cur_pan", false)
        reaper.Undo_OnStateChangeEx("Fancy Mapper: Adjust Pan", -1, -1)
      else
        cur_pan = cur_pan + diff * alpha
        is_busy = true
      end
      reaper.SetMediaTrackInfo_Value(tr, "D_PAN", cur_pan)
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_pan", false)
    end
  end

  -- 3. Width
  local tgt_w_str = reaper.GetExtState(EXTSTATE_SECTION, "target_width")
  if tgt_w_str and tgt_w_str ~= "" then
    local tgt_w = tonumber(tgt_w_str)
    local tr_guid = reaper.GetExtState(EXTSTATE_SECTION, "smooth_track_guid")
    local tr = get_track_by_guid(tr_guid)
    if tgt_w and tr then
      local cur_w = reaper.GetMediaTrackInfo_Value(tr, "D_WIDTH")
      local diff = tgt_w - cur_w
      if math.abs(diff) < 0.005 then
        cur_w = tgt_w
        reaper.DeleteExtState(EXTSTATE_SECTION, "target_width", false)
        reaper.DeleteExtState(EXTSTATE_SECTION, "cur_width", false)
        reaper.Undo_OnStateChangeEx("Fancy Mapper: Adjust Width", -1, -1)
      else
        cur_w = cur_w + diff * alpha
        is_busy = true
      end
      reaper.SetMediaTrackInfo_Value(tr, "D_WIDTH", cur_w)
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_width", false)
    end
  end

  -- 4. FX Parameter
  local tgt_fx_str = reaper.GetExtState(EXTSTATE_SECTION, "target_fx_val")
  if tgt_fx_str and tgt_fx_str ~= "" then
    local tgt_val = tonumber(tgt_fx_str)
    local tr_guid = reaper.GetExtState(EXTSTATE_SECTION, "smooth_fx_track_guid")
    local tr = get_track_by_guid(tr_guid)
    local fxidx = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "smooth_fx_idx"))
    local parm = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "smooth_fx_parm"))
    local is_take = reaper.GetExtState(EXTSTATE_SECTION, "smooth_fx_is_take") == "1"

    if tgt_val and tr and fxidx and parm then
      if is_take then
        local item_idx = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "smooth_fx_item_idx"))
        local take_idx = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "smooth_fx_take_idx"))
        local item = item_idx and reaper.GetTrackMediaItem(tr, item_idx)
        local take = item and take_idx and reaper.GetTake(item, take_idx)
        if take then
          local cur_val = reaper.TakeFX_GetParamNormalized(take, fxidx, parm)
          local diff = tgt_val - cur_val
          if math.abs(diff) < 0.002 then
            cur_val = tgt_val
            reaper.DeleteExtState(EXTSTATE_SECTION, "target_fx_val", false)
            reaper.DeleteExtState(EXTSTATE_SECTION, "cur_fx_val", false)
            reaper.Undo_OnStateChangeEx("Fancy Mapper: Adjust Parameter", -1, -1)
          else
            cur_val = cur_val + diff * alpha
            is_busy = true
          end
          reaper.TakeFX_SetParamNormalized(take, fxidx, parm, cur_val)
        else
          reaper.DeleteExtState(EXTSTATE_SECTION, "target_fx_val", false)
        end
      else
        local cur_val = reaper.TrackFX_GetParamNormalized(tr, fxidx, parm)
        local diff = tgt_val - cur_val
        if math.abs(diff) < 0.002 then
          cur_val = tgt_val
          reaper.DeleteExtState(EXTSTATE_SECTION, "target_fx_val", false)
          reaper.DeleteExtState(EXTSTATE_SECTION, "cur_fx_val", false)
          reaper.Undo_OnStateChangeEx("Fancy Mapper: Adjust Parameter", -1, -1)
        else
          cur_val = cur_val + diff * alpha
          is_busy = true
        end
        reaper.TrackFX_SetParamNormalized(tr, fxidx, parm, cur_val)
      end
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_fx_val", false)
    end
  end

  -- 5. MIDI CC
  local tgt_cc_str = reaper.GetExtState(EXTSTATE_SECTION, "target_cc_val")
  if tgt_cc_str and tgt_cc_str ~= "" then
    local tgt_val = tonumber(tgt_cc_str)
    if tgt_val then
      local cur_val = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "cur_cc_val")) or tgt_val
      local diff = tgt_val - cur_val
      if math.abs(diff) < 0.1 then
        cur_val = tgt_val
        reaper.DeleteExtState(EXTSTATE_SECTION, "target_cc_val", false)
      else
        cur_val = cur_val + diff * alpha
        is_busy = true
      end
      reaper.SetExtState(EXTSTATE_SECTION, "cur_cc_val", tostring(cur_val), false)
      reaper.SetExtState(EXTSTATE_SECTION, "live_cc_val", tostring(cur_val), false)

      local send_val = math.floor(cur_val + 0.5)
      local last_sent = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "last_sent_cc_val") or "-1")
      if send_val ~= last_sent then
        reaper.SetExtState(EXTSTATE_SECTION, "last_sent_cc_val", tostring(send_val), false)
        local cc_list = parse_cc_targets(cfg.midi_cc_targets)
        local chan = math.max(1, math.min(16, math.floor(cfg.midi_channel or 1)))
        local status = 0xB0 | ((chan - 1) & 0x0F)
        for _, cc_num in ipairs(cc_list) do
          reaper.StuffMIDIMessage(0, status, cc_num, send_val)
          reaper.StuffMIDIMessage(1, status, cc_num, send_val)
          reaper.SetExtState(EXTSTATE_SECTION, "live_cc_val_" .. cc_num, tostring(cur_val), false)
        end
      end
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_cc_val", false)
    end
  end

  -- 6. Timeline Scrub
  local tgt_scrub_str = reaper.GetExtState(EXTSTATE_SECTION, "target_scrub_pos")
  if tgt_scrub_str and tgt_scrub_str ~= "" then
    local tgt_pos = tonumber(tgt_scrub_str)
    if tgt_pos then
      local cur_pos = reaper.GetCursorPosition()
      local diff = tgt_pos - cur_pos
      if math.abs(diff) < 0.005 then
        cur_pos = tgt_pos
        reaper.DeleteExtState(EXTSTATE_SECTION, "target_scrub_pos", false)
        reaper.DeleteExtState(EXTSTATE_SECTION, "cur_scrub_pos", false)
      else
        cur_pos = cur_pos + diff * alpha
        is_busy = true
      end
      reaper.SetEditCurPos(cur_pos, cfg.scrub_view, false)
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_scrub_pos", false)
    end
  end

  -- 7. Item Slip
  local tgt_slip_str = reaper.GetExtState(EXTSTATE_SECTION, "target_slip_offs")
  if tgt_slip_str and tgt_slip_str ~= "" then
    local tgt_offs = tonumber(tgt_slip_str)
    local tr_guid = reaper.GetExtState(EXTSTATE_SECTION, "smooth_item_tr_guid")
    local item_idx = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "smooth_item_idx"))
    local tr = get_track_by_guid(tr_guid)
    if tgt_offs and tr and item_idx then
      local item = reaper.GetTrackMediaItem(tr, item_idx)
      if item then
        local take = reaper.GetActiveTake(item)
        if take then
          local cur_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
          local diff = tgt_offs - cur_offs
          if math.abs(diff) < 0.001 then
            cur_offs = tgt_offs
            reaper.DeleteExtState(EXTSTATE_SECTION, "target_slip_offs", false)
            reaper.DeleteExtState(EXTSTATE_SECTION, "cur_slip_offs", false)
            reaper.Undo_OnStateChangeEx("Fancy Mapper: Adjust Item Slip", -1, -1)
          else
            cur_offs = cur_offs + diff * alpha
            is_busy = true
          end
          reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", cur_offs)
          reaper.UpdateItemInProject(item)
          reaper.UpdateArrange()
        else
          reaper.DeleteExtState(EXTSTATE_SECTION, "target_slip_offs", false)
        end
      else
        reaper.DeleteExtState(EXTSTATE_SECTION, "target_slip_offs", false)
      end
    else
      reaper.DeleteExtState(EXTSTATE_SECTION, "target_slip_offs", false)
    end
  end

  return is_busy
end

-------------------------------------------------------------------------------
-- 5. CONTEXT ROUTER
-------------------------------------------------------------------------------

function MapperEngine.detect_and_adjust(direction, cfg)
  local mode = MapperEngine.get_mode()

  if mode == "scrub"     then return MapperEngine.adjust_scrub(direction, cfg) end
  if mode == "pan"       then return MapperEngine.adjust_pan(direction, cfg) end
  if mode == "volume"    then return MapperEngine.adjust_volume(direction, cfg) end
  if mode == "width"     then return MapperEngine.adjust_width(direction, cfg) end
  if mode == "midi_cc"   then return MapperEngine.adjust_midi_cc(direction, cfg) end
  if mode == "midi_vel"  then return MapperEngine.adjust_midi_vel(direction, cfg) end
  if mode == "track_nav" then return MapperEngine.adjust_track_nav(direction, cfg) end
  if mode == "marker"    then return MapperEngine.adjust_marker(direction, cfg) end
  if mode == "transient" then return MapperEngine.adjust_transient(direction, cfg) end
  if mode == "item_slip" then return MapperEngine.adjust_item_slip(direction, cfg) end

  -- mode == "fx": FX parameter with optional pan fallback
  if MapperEngine.adjust_fx_param(direction, cfg) then return true end
  if cfg.fx_fallback then return MapperEngine.adjust_pan(direction, cfg) end
  return false
end

-------------------------------------------------------------------------------
-- 6. CONTEXTUAL RESET
-------------------------------------------------------------------------------

function MapperEngine.reset_current_context()
  local mode = MapperEngine.get_mode()
  local cfg = MapperEngine.load_config()

  if mode == "pan" then
    reaper.DeleteExtState(EXTSTATE_SECTION, "target_pan", false)
    reaper.DeleteExtState(EXTSTATE_SECTION, "cur_pan", false)
    local tr = get_target_track()
    if tr then
      reaper.Undo_BeginBlock()
      reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0.0)
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Fancy Mapper: Reset Pan", -1)
      if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
        local mx, my = reaper.GetMousePosition()
        reaper.TrackCtl_SetToolTip("Pan: Center", mx + 16, my + 16, true)
      end
    end
    return
  end

  if mode == "volume" then
    reaper.DeleteExtState(EXTSTATE_SECTION, "target_vol_db", false)
    reaper.DeleteExtState(EXTSTATE_SECTION, "cur_vol_db", false)
    local tr = get_target_track()
    if tr then
      reaper.Undo_BeginBlock()
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1.0)
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Fancy Mapper: Reset Volume", -1)
      if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
        local mx, my = reaper.GetMousePosition()
        reaper.TrackCtl_SetToolTip("Volume: 0.0 dB", mx + 16, my + 16, true)
      end
    end
    return
  end

  if mode == "width" then
    reaper.DeleteExtState(EXTSTATE_SECTION, "target_width", false)
    reaper.DeleteExtState(EXTSTATE_SECTION, "cur_width", false)
    local tr = get_target_track()
    if tr then
      local pan_mode = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_PANMODE"))
      reaper.Undo_BeginBlock()
      if cfg.width_auto_stereo_pan and pan_mode ~= 5 and pan_mode ~= 6 then
        reaper.SetMediaTrackInfo_Value(tr, "I_PANMODE", 5)
      end
      reaper.SetMediaTrackInfo_Value(tr, "D_WIDTH", 1.0)
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Fancy Mapper: Reset Width", -1)
      if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
        local mx, my = reaper.GetMousePosition()
        reaper.TrackCtl_SetToolTip("Width: 100%", mx + 16, my + 16, true)
      end
    end
    return
  end

  if mode == "item_slip" then
    reaper.DeleteExtState(EXTSTATE_SECTION, "target_slip_offs", false)
    reaper.DeleteExtState(EXTSTATE_SECTION, "cur_slip_offs", false)
    local item = get_target_item()
    if item then
      local take = reaper.GetActiveTake(item)
      if take then
        reaper.Undo_BeginBlock()
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0.0)
        reaper.UpdateItemInProject(item)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("Fancy Mapper: Reset Item Slip", -1)
        if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
          local mx, my = reaper.GetMousePosition()
          reaper.TrackCtl_SetToolTip("Item Slip: 0 ms", mx + 16, my + 16, true)
        end
      end
    end
    return
  end

  if mode == "midi_vel" then
    local reset_vel = 96
    reaper.SetExtState(EXTSTATE_SECTION, "live_vel_val", tostring(reset_vel), false)

    local midieditor = reaper.MIDIEditor_GetActive()
    if midieditor then
      reaper.MIDIEditor_SetSetting_int(midieditor, "default_note_vel", reset_vel)
    end

    local take, _ = get_target_take()
    if take and reaper.TakeIsMIDI(take) then
      local _, note_count = reaper.MIDI_CountEvts(take)
      local has_sel_note = false
      for i = 0, note_count - 1 do
        local _, sel = reaper.MIDI_GetNote(take, i)
        if sel then has_sel_note = true; break end
      end
      if has_sel_note then
        reaper.Undo_BeginBlock()
        reaper.MIDI_DisableSort(take)
        for i = 0, note_count - 1 do
          local ok, sel, muted, startppq, endppq, chan, pitch = reaper.MIDI_GetNote(take, i)
          if ok and sel then
            reaper.MIDI_SetNote(take, i, sel, muted, startppq, endppq, chan, pitch, reset_vel, false)
          end
        end
        reaper.MIDI_Sort(take)
        reaper.Undo_EndBlock("Fancy Mapper: Reset Velocity", -1)
      end
    end

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      reaper.TrackCtl_SetToolTip("Velocity: Reset to 96", mx + 16, my + 16, true)
    end
    return
  end

  if mode == "midi_cc" then
    reaper.DeleteExtState(EXTSTATE_SECTION, "target_cc_val", false)
    reaper.DeleteExtState(EXTSTATE_SECTION, "cur_cc_val", false)
    local cc_list = parse_cc_targets(cfg.midi_cc_targets)
    local chan = math.max(1, math.min(16, math.floor(cfg.midi_channel or 1)))
    local status = 0xB0 | ((chan - 1) & 0x0F)

    local reset_val = 0
    reaper.SetExtState(EXTSTATE_SECTION, "live_cc_val", tostring(reset_val), false)

    for _, cc_num in ipairs(cc_list) do
      local def_val = (cc_num == 10) and 64 or reset_val
      reaper.StuffMIDIMessage(0, status, cc_num, def_val)
      reaper.StuffMIDIMessage(1, status, cc_num, def_val)
      reaper.SetExtState(EXTSTATE_SECTION, "live_cc_val_" .. cc_num, tostring(def_val), false)
    end

    local take, _ = get_target_take()
    if take and reaper.TakeIsMIDI(take) then
      local _, _, cc_count = reaper.MIDI_CountEvts(take)
      local has_sel = false
      for i = 0, cc_count - 1 do
        local _, sel = reaper.MIDI_GetCC(take, i)
        if sel then has_sel = true; break end
      end
      if has_sel then
        reaper.Undo_BeginBlock()
        reaper.MIDI_DisableSort(take)
        for i = 0, cc_count - 1 do
          local ok, sel, muted, ppqpos, chanmsg, c, msg2 = reaper.MIDI_GetCC(take, i)
          if ok and sel then
            local def_val = (msg2 == 10) and 64 or 0
            reaper.MIDI_SetCC(take, i, sel, muted, ppqpos, chanmsg, c, msg2, def_val, false)
          end
        end
        reaper.MIDI_Sort(take)
        reaper.Undo_EndBlock("Fancy Mapper: Reset MIDI CC", -1)
      end
    end

    if cfg.midi_show_tooltip and reaper.TrackCtl_SetToolTip then
      local mx, my = reaper.GetMousePosition()
      reaper.TrackCtl_SetToolTip("MIDI CC: Reset to 0", mx + 16, my + 16, true)
    end
    return
  end

  -- Default / "fx": Reset last-touched FX parameter to default value
  reaper.DeleteExtState(EXTSTATE_SECTION, "target_fx_val", false)
  reaper.DeleteExtState(EXTSTATE_SECTION, "cur_fx_val", false)

  local retval, trackidx, itemidx, takeidx, fxidx, parm =
        reaper.GetTouchedOrFocusedFX(0)
  if not retval then return end

  local track
  if trackidx == -1 then
    track = reaper.GetMasterTrack(0)
  else
    track = reaper.GetTrack(0, trackidx)
  end
  if not track then return end

  if itemidx >= 0 then
    local item = reaper.GetTrackMediaItem(track, itemidx)
    if not item then return end
    local take = reaper.GetTake(item, takeidx)
    if not take then return end

    local ok, default_str = reaper.TakeFX_GetNamedConfigParm(
        take, fxidx, "param." .. parm .. ".default_value")
    if not ok then return end
    local default_val = tonumber(default_str)
    if not default_val then return end

    reaper.Undo_BeginBlock()
    reaper.TakeFX_SetParamNormalized(take, fxidx, parm, default_val)
    reaper.Undo_EndBlock("Fancy Mapper: Reset Parameter", -1)
    return
  end

  local ok, default_str = reaper.TrackFX_GetNamedConfigParm(
      track, fxidx, "param." .. parm .. ".default_value")
  if not ok then return end
  local default_val = tonumber(default_str)
  if not default_val then return end

  reaper.Undo_BeginBlock()
  reaper.TrackFX_SetParamNormalized(track, fxidx, parm, default_val)
  reaper.Undo_EndBlock("Fancy Mapper: Reset Parameter", -1)
end

-------------------------------------------------------------------------------
-- 7. RUNNER
-------------------------------------------------------------------------------

-- Settings' calibrate dialog refreshes this heartbeat every frame while open
local CALIBRATE_TIMEOUT_S = 2.0

-- While calibrating, count raw dial ticks (before the throttle) instead of acting.
-- The count is signed so turning back corrects an overshoot.
local function consume_calibration_tick(direction)
  local hb = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "calibrating"))
  if not hb or reaper.time_precise() - hb > CALIBRATE_TIMEOUT_S then return false end
  local count = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "calibrate_count")) or 0
  reaper.SetExtState(EXTSTATE_SECTION, "calibrate_count", tostring(count + direction), false)
  return true
end

local function is_smooth_mode(mode, cfg)
  if not cfg.smooth_dial_enabled then return false end
  if mode == "volume"    and cfg.smooth_vol     then return true end
  if mode == "pan"       and cfg.smooth_pan     then return true end
  if mode == "width"     and cfg.smooth_width   then return true end
  if mode == "fx"        and cfg.smooth_fx      then return true end
  if mode == "midi_cc"   and cfg.smooth_midi_cc then return true end
  if mode == "scrub"     and cfg.smooth_scrub   then return true end
  if mode == "item_slip" and cfg.smooth_slip    then return true end
  return false
end

function MapperEngine.run(direction)
  if consume_calibration_tick(direction) then return end

  local cfg = MapperEngine.load_config()
  if not MapperEngine.should_run(direction, cfg) then return end

  local mode = MapperEngine.get_mode()

  -- Real-time / navigation / non-destructive modes do not create undo blocks
  if mode == "scrub" then
    MapperEngine.adjust_scrub(direction, cfg)
    return
  elseif mode == "track_nav" then
    MapperEngine.adjust_track_nav(direction, cfg)
    return
  elseif mode == "marker" then
    MapperEngine.adjust_marker(direction, cfg)
    return
  elseif mode == "transient" then
    MapperEngine.adjust_transient(direction, cfg)
    return
  elseif mode == "midi_cc" then
    MapperEngine.adjust_midi_cc(direction, cfg)
    return
  elseif mode == "midi_vel" then
    MapperEngine.adjust_midi_vel(direction, cfg)
    return
  end

  -- If smooth dial is active for this mode, let daemon handle slewing & undo point
  if is_smooth_mode(mode, cfg) then
    MapperEngine.detect_and_adjust(direction, cfg)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  MapperEngine.detect_and_adjust(direction, cfg)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Fancy Mapper: Adjust", -1)
end

return MapperEngine
