-- @description Fancy Selected Track Meter
-- @author Fancy Scripts
-- @version 9.66.0
-- @changelog
--   + Added ReaPack distribution support
-- @about
--   Real-time visual metering display for selected tracks.
--   Features customizable colors, peak hold, and docking support.
--   Requirements: ReaImGui extension (install via ReaPack)
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .

-------------------------------------------------------------------------------
-- 1. DEPENDENCY CHECK
-------------------------------------------------------------------------------
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Selected Track Meter -- Missing ReaImGui", 0)
  return
end

local ctx = reaper.ImGui_CreateContext('Selected Track Meter', reaper.ImGui_ConfigFlags_DockingEnable())

-------------------------------------------------------------------------------
-- 2. VISUAL SETTINGS
-------------------------------------------------------------------------------
local VisualSettings = {
    Window_Padding   = 15,   
    
    -- Meter Theming (Edit these HEX values to customize)
    Color_Background = 0x202020FF,
    Color_MeterBG    = 0x1A1A1AFF, 
    Color_Safe       = 0x0088CCFF, 
    Color_Warn       = 0xE0B000FF, 
    Color_Clip       = 0xDD0000FF, 
    Color_Text       = 0xAAAAAAFF,
    Color_TextDim    = 0x777777FF, 
    Color_GridLine   = 0x444444FF,
    Color_TextShadow = 0x000000AA,
    Color_TrackName  = 0xFFFFFFFF,
    Color_DefaultTrk = 0x666666FF, 
    Color_TargetLine = 0x00FFCCFF, 
    Color_TargetDim  = 0x444444FF, 
    
    -- Settings Controls Theming
    Color_SettingsFrame  = 0x333333FF,
    Color_SettingsHover  = 0x4A4A4AFF,
    Color_SettingsAccent = 0x0088CCFF,
    
    -- Tab Navigation Theming
    Tab_Inactive         = 0x2A2A2AFF,
    Tab_Hovered          = 0x4A4A4AFF,
    Tab_Active           = 0x0088CCFF,
    
    -- Settings Window Title Bar Theming
    Color_TitleBg        = 0x1A1A1AFF,
    Color_TitleActive    = 0x333333FF,
    
    Color_DimFactor  = 0.85, 
    Dim_Opacity_Pct  = 0.75, 

    Meter_Spacing    = 2, 
    Meter_Kerning    = 2,
    Header_Height    = 50,
    
    -- Typography Controls
    Global_Font_Family     = 'Verdana', 
    Tooltip_Font_Size      = 16,       
    Settings_Font_Size     = 16,
    Target_Large_Font_Size = 16,
    Tooltip_Padding        = 12,       
}

-------------------------------------------------------------------------------
-- 3. FUNCTIONAL STATE & DEFAULTS
-------------------------------------------------------------------------------
local State = {
    show_settings       = false,
    show_balance_meter  = true, 
    
    meter_scale_mode    = 1, 
    
    is_locked           = false,
    locked_track        = nil,
    last_active_track   = nil, 
    
    -- Balance Drift Parameters
    balance_meter_height   = 80,
    balance_db_scale       = 12.0,
    balance_window_sec     = 2.0,   
    balance_window_sec_fast= 0.15,  
    balance_val            = 0.0, 
    balance_val_fast       = 0.0,
    
    column_gap    = 12,
    peak_warn_db  = -6.0,
    
    peak_db_min   = -60.0,
    peak_db_max   = 0.0,
    rms_db_min    = -60.0,
    rms_db_max    = 0.0,
    
    meter_width   = 50, 
    falloff_db_sec= 20.0, 
    damping       = 0.15, 
    
    peak_max_l    = -150,
    peak_max_r    = -150,
    rms_smooth_l  = 0,
    rms_smooth_r  = 0,
    
    num_peak_max  = -150,
    num_rms_max   = -150,
    
    tgt_peak_active = false,
    tgt_peak_db     = -10.0,
    tgt_rms_active  = false,
    tgt_rms_db      = -18.0,
    
    -- Target Marker Appearance
    tgt_marker_size     = 1,    -- 0: Small, 1: Large (Defaulted to Large)
    tgt_marker_indent   = 8.0,  -- px
    tgt_marker_bg_alpha = 0.75, -- Glassy Opacity
    
    audio_history      = {},
    rolling_window_sec = 3.0,
    roll_peak_max      = -150,
    roll_rms_max       = -150,
    
    disp_roll_peak     = -150,
    disp_roll_rms      = -150,
    
    -- Actionable Clip Logging State
    clip_log           = {},
    show_clip_log      = false,
    last_clip_time     = -100, 
    
    play_state         = 0,
    play_start_time    = 0,
    last_time          = reaper.time_precise()
}

local PersistStateKeys = {
    "show_balance_meter", "meter_scale_mode",
    "balance_meter_height", "balance_db_scale", "balance_window_sec", "balance_window_sec_fast",
    "column_gap", "peak_db_min", "peak_db_max", "rms_db_min", "rms_db_max",
    "falloff_db_sec", "damping",
    "tgt_peak_active", "tgt_peak_db", "tgt_rms_active", "tgt_rms_db",
    "tgt_marker_size", "tgt_marker_indent", "tgt_marker_bg_alpha",
    "rolling_window_sec"
}

local PersistVisualKeys = {
    "Color_Safe", "Color_Warn", "Color_Clip", "Color_TargetLine",
    "Color_MeterBG", "Color_Background", "Dim_Opacity_Pct",
    "Tooltip_Font_Size", "Settings_Font_Size",
    "Tab_Inactive", "Tab_Hovered", "Tab_Active"
}

-------------------------------------------------------------------------------
-- 4. STATE PERSISTENCE
-------------------------------------------------------------------------------
local function LoadSettings()
    -- Load Functional State
    for _, k in ipairs(PersistStateKeys) do
        local val = reaper.GetExtState("FW_TrackMeter", "S_"..k)
        if val ~= "" then
            if type(State[k]) == "boolean" then State[k] = (val == "true")
            elseif type(State[k]) == "number" then State[k] = tonumber(val) or State[k]
            else State[k] = val end
        end
    end
    -- Load Visual Settings (Colors and Sizes)
    for _, k in ipairs(PersistVisualKeys) do
        local v = VisualSettings[k]
        local val = reaper.GetExtState("FW_TrackMeter", "V_"..k)
        if val ~= "" then
            if type(v) == "boolean" then VisualSettings[k] = (val == "true")
            elseif type(v) == "number" then VisualSettings[k] = tonumber(val) or v
            else VisualSettings[k] = val end
        end
    end
end

local function SaveSettings()
    -- Save Functional State
    for _, k in ipairs(PersistStateKeys) do
        reaper.SetExtState("FW_TrackMeter", "S_"..k, tostring(State[k]), true)
    end
    -- Save Visual Settings
    for _, k in ipairs(PersistVisualKeys) do
        local v = VisualSettings[k]
        reaper.SetExtState("FW_TrackMeter", "V_"..k, tostring(v), true)
    end
end

-- Force save on script exit
reaper.atexit(SaveSettings)

-- Load previously saved settings before generating fonts
LoadSettings()

-- Attach the dynamic font objects using the user's preferred sizes
local base_font = reaper.ImGui_CreateFont(VisualSettings.Global_Font_Family, 16)
local bold_font = reaper.ImGui_CreateFont(VisualSettings.Global_Font_Family .. ' Bold', 13)
local tooltip_font = reaper.ImGui_CreateFont(VisualSettings.Global_Font_Family, VisualSettings.Tooltip_Font_Size)
local settings_font = reaper.ImGui_CreateFont(VisualSettings.Global_Font_Family, VisualSettings.Settings_Font_Size)

reaper.ImGui_Attach(ctx, base_font)
reaper.ImGui_Attach(ctx, bold_font)
reaper.ImGui_Attach(ctx, tooltip_font)
reaper.ImGui_Attach(ctx, settings_font)

local cached_tooltip_size = VisualSettings.Tooltip_Font_Size
local cached_settings_size = VisualSettings.Settings_Font_Size

-------------------------------------------------------------------------------
-- 5. MATH & UTILITY FUNCTIONS
-------------------------------------------------------------------------------
local function AmpToDb(amp)
    if not amp or amp <= 0.0000001 then return -150.0 end
    return 20.0 * math.log(amp, 10)
end

local function MapRange(val, in_min, in_max, out_min, out_max)
    if not val or not in_min or not in_max or not out_min or not out_max then return 0 end
    if val ~= val then val = in_min end 
    local lowest_in = math.min(in_min, in_max)
    local highest_in = math.max(in_min, in_max)
    local clamped_val = math.max(lowest_in, math.min(val, highest_in))
    local denominator = (in_max - in_min)
    if denominator == 0 then return out_min end 
    return (clamped_val - in_min) * (out_max - out_min) / denominator + out_min
end

local function GetYForDb(db, h, mode, min_db, max_db)
    if mode == 2 and min_db < -24.0 then 
        local pivot_db = -24.0
        local pivot_y = h * 0.65 
        if db >= pivot_db then return MapRange(db, pivot_db, max_db, pivot_y, 0)
        else return MapRange(db, min_db, pivot_db, h, pivot_y) end
    else
        return MapRange(db, min_db, max_db, h, 0) 
    end
end

local function GetDbForY(y, h, mode, min_db, max_db)
    if mode == 2 and min_db < -24.0 then 
        local pivot_db = -24.0
        local pivot_y = h * 0.65
        if y <= pivot_y then return MapRange(y, pivot_y, 0, pivot_db, max_db)
        else return MapRange(y, h, pivot_y, min_db, pivot_db) end
    else
        return MapRange(y, h, 0, min_db, max_db) 
    end
end

local function NativeToImGuiColor(native_col, dim)
    if native_col == 0 then return VisualSettings.Color_DefaultTrk end
    local r_val, g_val, b_val = reaper.ColorFromNative(native_col)
    r_val = math.floor(r_val * dim)
    g_val = math.floor(g_val * dim)
    b_val = math.floor(b_val * dim)
    return (r_val * 16777216) + (g_val * 65536) + (b_val * 256) + 255
end

local function GetReadoutStr(val)
    if not val or val <= -140 then return "-inf" end
    if val > 0.0 then return string.format("+%.1f", val) end
    return string.format("%.1f", val)
end

local function DrawTooltip(ctx, text)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), VisualSettings.Tooltip_Padding, VisualSettings.Tooltip_Padding)
        reaper.ImGui_PushFont(ctx, tooltip_font, VisualSettings.Tooltip_Font_Size)
        if reaper.ImGui_BeginTooltip(ctx) then
            reaper.ImGui_Text(ctx, text)
            reaper.ImGui_EndTooltip(ctx)
        end
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_PopStyleVar(ctx, 1)
    end
end

local function DrawThickText(draw_list, font, size, x, y, color, text, shadow_color, kerning)
    kerning = kerning or 0
    if kerning <= 0 then
        if shadow_color then
            reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x + 1, y + 1, shadow_color, text)
            reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x + 2, y + 1, shadow_color, text)
        end
        reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x, y, color, text)
        reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, x + 1, y, color, text)
    else
        local cx = x
        reaper.ImGui_PushFont(ctx, font, size)
        for i = 1, #text do
            local char = text:sub(i, i)
            if shadow_color then
                reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx + 1, y + 1, shadow_color, char)
                reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx + 2, y + 1, shadow_color, char)
            end
            reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx, y, color, char)
            reaper.ImGui_DrawList_AddTextEx(draw_list, font, size, cx + 1, y, color, char)
            
            local cw = reaper.ImGui_CalcTextSize(ctx, char)
            cx = cx + cw + kerning
        end
        reaper.ImGui_PopFont(ctx)
    end
end

local function DrawBalanceMeter(draw_list, width, x_pos, y_pos, balance_val, balance_val_fast, current_height)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, y_pos, x_pos + width, y_pos + current_height + 10, VisualSettings.Color_MeterBG, 6.0)

    local center_x = x_pos + (width / 2)
    local center_y = y_pos + (current_height / 2 + 2)

    local track_w = width - 60
    local track_x1 = center_x - (track_w / 2)
    local track_x2 = center_x + (track_w / 2)
    
    reaper.ImGui_DrawList_AddLine(draw_list, track_x1, center_y, track_x2, center_y, VisualSettings.Color_GridLine, 2.0)
    reaper.ImGui_DrawList_AddLine(draw_list, center_x, center_y - 8, center_x, center_y + 8, VisualSettings.Color_TextDim, 2.0)
    
    local max_db = State.balance_db_scale or 12.0
    local half_db = max_db / 2.0
    local ticks = {-max_db, -half_db, half_db, max_db}
    
    for _, db in ipairs(ticks) do
        local px = center_x + (db / max_db) * (track_w / 2)
        reaper.ImGui_DrawList_AddLine(draw_list, px, center_y - 4, px, center_y + 4, VisualSettings.Color_GridLine, 1.5)
        
        local txt = ""
        if math.floor(db) == db then txt = tostring(math.abs(db))
        else txt = string.format("%.1f", math.abs(db)) end
        
        reaper.ImGui_PushFont(ctx, bold_font, 11)
        local tw, th = reaper.ImGui_CalcTextSize(ctx, txt)
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_DrawList_AddTextEx(draw_list, bold_font, 11, px - (tw/2), center_y + 10, VisualSettings.Color_TextDim, txt)
    end

    local title_tw, title_th = reaper.ImGui_CalcTextSize(ctx, "STEREO BALANCE DRIFT")
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 12, center_x - (title_tw/2), y_pos + 10, VisualSettings.Color_Text, "STEREO BALANCE DRIFT")
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 12, track_x1, y_pos + 10, VisualSettings.Color_TextDim, "L")
    
    local r_tw, r_th = reaper.ImGui_CalcTextSize(ctx, "R")
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 12, track_x2 - r_tw, y_pos + 10, VisualSettings.Color_TextDim, "R")

    local safe_slow = balance_val or 0.0
    local safe_fast = balance_val_fast or 0.0
    local clamped_val_slow = math.max(-max_db, math.min(safe_slow, max_db))
    local clamped_val_fast = math.max(-max_db, math.min(safe_fast, max_db))
    
    local bubble_x_slow = center_x + (clamped_val_slow / max_db) * (track_w / 2)
    local bubble_x_fast = center_x + (clamped_val_fast / max_db) * (track_w / 2)
    
    reaper.ImGui_DrawList_AddCircle(draw_list, bubble_x_fast, center_y, 9, 0xFFFFFF44, 12, 1.5)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, bubble_x_slow, center_y, 6, VisualSettings.Color_Safe)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, bubble_x_slow, center_y, 2, VisualSettings.Color_Background)
    
    local diff_str = ""
    if math.abs(safe_slow) < 0.1 then diff_str = "Perfectly Centered"
    elseif safe_slow < 0 then diff_str = string.format("Left leaning by %.1f dB", math.abs(safe_slow))
    else diff_str = string.format("Right leaning by %.1f dB", math.abs(safe_slow)) end
    
    local diff_tw, diff_th = reaper.ImGui_CalcTextSize(ctx, diff_str)
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 12, center_x - (diff_tw/2), y_pos + current_height - 10, VisualSettings.Color_TextDim, diff_str)

    reaper.ImGui_SetCursorScreenPos(ctx, x_pos, y_pos)
    reaper.ImGui_InvisibleButton(ctx, "balance_tt", width, current_height)
    DrawTooltip(ctx, "Stereo Balance Drift\n\nShows the spatial center of mass for the mix.\nCalculated by taking the difference between Left and Right RMS,\nthen passing it through dual RC integration filters\n(Slow for gravity, Fast for transients).\n\nShortcut: B")
end

local function DrawStereoMeterPair(draw_list, x_pos, start_y, val_l, val_r, label, db_min, db_max, w, h, inf_val, roll_val, tgt_active, tgt_db, scale_mode)
    local s = VisualSettings.Meter_Spacing
    local total_w = (w * 2) + s
    local clicked_inf_reset = false
    local clicked_roll_reset = false
    local new_tgt_active = tgt_active
    local new_tgt_db = tgt_db or -6.0 
    
    local label_y = start_y
    local box_y = label_y + 25
    local meter_y = box_y + 36 + 15
    local box_h = 36
    local box_w = math.floor((total_w - s) / 2)

    local lw, lh = reaper.ImGui_CalcTextSize(ctx, label)
    local btn_size = 14
    local btn_spacing = 6
    local group_w = lw + btn_spacing + btn_size
    local start_x = x_pos + (total_w / 2) - (group_w / 2)
    
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 14, start_x, label_y, VisualSettings.Color_Text, label)
    
    reaper.ImGui_SetCursorScreenPos(ctx, start_x, label_y)
    reaper.ImGui_InvisibleButton(ctx, label.."_lbl_tt", lw, lh)
    local tt_text = nil
    if label == "PEAK" then
        tt_text = "Peak Amplitude\n\nShows the absolute highest instantaneous digital volume.\nCalculated by querying REAPER's raw audio-rate peak telemetry."
    elseif label == "RMS" then
        tt_text = "RMS (Root Mean Square)\n\nShows the sustained average energy, representing perceived loudness.\nCalculated natively by REAPER's audio engine and\nsmoothed via the script's RC damping filter."
    end
    if tt_text then DrawTooltip(ctx, tt_text) end
    
    local btn_x = start_x + lw + btn_spacing
    local btn_y = label_y
    reaper.ImGui_SetCursorScreenPos(ctx, btn_x, btn_y)
    if reaper.ImGui_InvisibleButton(ctx, label.."_tgt_toggle", btn_size, btn_size) then
        new_tgt_active = not new_tgt_active
    end
    DrawTooltip(ctx, "Gain Stage Target Marker\n\nA visual reference line for gain staging.\nClick anywhere on the meter track to set the level.\nUse this to match your signal to a specific dB target.\nClick this icon to toggle visibility.")
    
    local icon_col = new_tgt_active and VisualSettings.Color_TargetLine or VisualSettings.Color_TargetDim
    local center_px = btn_x + (btn_size / 2)
    local center_py = btn_y + (btn_size / 2)
    reaper.ImGui_DrawList_AddCircle(draw_list, center_px + 2, center_py + 2, (btn_size/2) - 1, icon_col, 12, 1.5)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_px + 2, center_py + 2, 2, icon_col)

    -- 🔴 ALERT BLOCK STYLING: INFINITY HOLD
    local inf_is_clipping = inf_val >= 0.0
    local inf_bg_col  = inf_is_clipping and VisualSettings.Color_Clip or VisualSettings.Color_MeterBG
    local inf_txt_col = inf_is_clipping and 0x000000FF or VisualSettings.Color_Text
    local inf_icn_col = inf_is_clipping and 0x000000FF or VisualSettings.Color_TextDim
    
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, box_y, x_pos + box_w, box_y + box_h + 4, inf_bg_col, 2.0)
    
    local inf_title = "∞"
    local inf_tw, inf_th = reaper.ImGui_CalcTextSize(ctx, inf_title)
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 15, x_pos + (box_w/2) - (inf_tw/2), box_y + 1, inf_icn_col, inf_title)
    
    local inf_str = GetReadoutStr(inf_val)
    reaper.ImGui_PushFont(ctx, bold_font, 14)
    local isw, ish = reaper.ImGui_CalcTextSize(ctx, inf_str)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_DrawList_AddTextEx(draw_list, bold_font, 14, x_pos + (box_w/2) - (isw/2) - 2, box_y + 18, inf_txt_col, inf_str)
    
    reaper.ImGui_SetCursorScreenPos(ctx, x_pos, box_y)
    if reaper.ImGui_InvisibleButton(ctx, label.."_inf_btn", box_w, box_h) then clicked_inf_reset = true end
    DrawTooltip(ctx, "Infinite Hold.\nLogs the absolute highest value.\nClick or press 'R' to reset.\nPress 'C' to clear clips and reset.")
    
    -- 🔴 ALERT BLOCK STYLING: ROLLING HOLD
    local roll_is_clipping = roll_val >= 0.0
    local roll_bg_col  = roll_is_clipping and VisualSettings.Color_Clip or VisualSettings.Color_MeterBG
    local roll_txt_col = roll_is_clipping and 0x000000FF or VisualSettings.Color_Text
    local roll_icn_col = roll_is_clipping and 0x000000FF or VisualSettings.Color_TextDim

    local b2_x = x_pos + box_w + s
    reaper.ImGui_DrawList_AddRectFilled(draw_list, b2_x, box_y, b2_x + box_w, box_y + box_h + 4, roll_bg_col, 2.0)
    
    local roll_title = "↻"
    local roll_tw, roll_th = reaper.ImGui_CalcTextSize(ctx, roll_title)
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 14, b2_x + (box_w/2) - (roll_tw/2), box_y + 2, roll_icn_col, roll_title)
    
    local roll_str = GetReadoutStr(roll_val)
    local roll_col = roll_val >= 0.0 and VisualSettings.Color_Clip or VisualSettings.Color_Text
    reaper.ImGui_PushFont(ctx, bold_font, 14)
    local rsw, rsh = reaper.ImGui_CalcTextSize(ctx, roll_str)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_DrawList_AddTextEx(draw_list, bold_font, 14, b2_x + (box_w/2) - (rsw/2) - 2, box_y + 18, roll_txt_col, roll_str)
    
    reaper.ImGui_SetCursorScreenPos(ctx, b2_x, box_y)
    if reaper.ImGui_InvisibleButton(ctx, label.."_roll_btn", box_w, box_h) then clicked_roll_reset = true end
    DrawTooltip(ctx, string.format("Rolling Window.\nHighest value recorded in the last %.1f seconds.\nClick or press 'R' to reset.\nPress 'C' to clear clips and reset.", State.rolling_window_sec))

    reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, meter_y, x_pos + w, meter_y + h, VisualSettings.Color_MeterBG)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos + w + s, meter_y, x_pos + total_w, meter_y + h, VisualSettings.Color_MeterBG)
    
    -- 🧲 METER HITBOX (Click anywhere to activate and set Target)
    reaper.ImGui_SetCursorScreenPos(ctx, x_pos, meter_y)
    reaper.ImGui_InvisibleButton(ctx, label.."_meter_hitbox", total_w, h)
    
    local is_meter_hovered = false
    local hover_mx, hover_my = 0, 0
    
    if reaper.ImGui_IsItemActive(ctx) then
        new_tgt_active = true 
        local mx, my = reaper.ImGui_GetMousePos(ctx)
        local local_y = my - meter_y
        new_tgt_db = GetDbForY(local_y, h, scale_mode, db_min, db_max)
        if new_tgt_db > db_max then new_tgt_db = db_max end
        if new_tgt_db < db_min then new_tgt_db = db_min end
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        is_meter_hovered = true
        hover_mx, hover_my = reaper.ImGui_GetMousePos(ctx)
    end
    
    -- 🎨 Threshold Logic 
    local current_warn_db = State.peak_warn_db
    local current_clip_db = 0.0
    
    if new_tgt_active then
        current_warn_db = new_tgt_db + 1.0
        current_clip_db = new_tgt_db + 3.0
    end

    local y_l = GetYForDb(val_l, h, scale_mode, db_min, db_max)
    local y_r = GetYForDb(val_r, h, scale_mode, db_min, db_max)
    local y_warn = GetYForDb(current_warn_db, h, scale_mode, db_min, db_max)
    local y_clip = GetYForDb(current_clip_db, h, scale_mode, db_min, db_max)
    
    -- 📏 Segmented Fill: Left Meter
    if y_l < h then
        local safe_top = math.max(y_l, y_warn)
        if safe_top < h then
            reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, meter_y + safe_top, x_pos + w, meter_y + h, VisualSettings.Color_Safe)
        end
        if val_l > current_warn_db then
            local warn_top = math.max(y_l, y_clip)
            if warn_top < y_warn then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, meter_y + warn_top, x_pos + w, meter_y + y_warn, VisualSettings.Color_Warn)
            end
        end
        if val_l > current_clip_db then
            if y_l < y_clip then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, x_pos, meter_y + y_l, x_pos + w, meter_y + y_clip, VisualSettings.Color_Clip)
            end
        end
    end
    
    -- 📏 Segmented Fill: Right Meter
    local rx1 = x_pos + w + s
    local rx2 = x_pos + total_w
    if y_r < h then
        local safe_top = math.max(y_r, y_warn)
        if safe_top < h then
            reaper.ImGui_DrawList_AddRectFilled(draw_list, rx1, meter_y + safe_top, rx2, meter_y + h, VisualSettings.Color_Safe)
        end
        if val_r > current_warn_db then
            local warn_top = math.max(y_r, y_clip)
            if warn_top < y_warn then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, rx1, meter_y + warn_top, rx2, meter_y + y_warn, VisualSettings.Color_Warn)
            end
        end
        if val_r > current_clip_db then
            if y_r < y_clip then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, rx1, meter_y + y_r, rx2, meter_y + y_clip, VisualSettings.Color_Clip)
            end
        end
    end
    
    -- 📏 Dynamic Grid Ticks
    local ticks = {}
    if scale_mode == 2 then 
        ticks = {0, -3, -6, -9, -12, -15, -18, -21, -24, -36, -48, -60}
    else 
        for d = 0, math.floor(db_min or -60), -6 do
            table.insert(ticks, d)
        end
    end
    
    for _, db in ipairs(ticks) do
        if db <= db_max and db >= db_min then
            local y_offset = GetYForDb(db, h, scale_mode, db_min, db_max)
            local line_y = meter_y + y_offset
            reaper.ImGui_DrawList_AddLine(draw_list, x_pos, line_y, x_pos + total_w, line_y, VisualSettings.Color_GridLine, 1.0)
            
            local db_str = db == 0 and "-0-" or "-" .. tostring(math.abs(db)) .. "-"
            reaper.ImGui_PushFont(ctx, bold_font, 13)
            local str_w, str_h = reaper.ImGui_CalcTextSize(ctx, db_str)
            reaper.ImGui_PopFont(ctx)
            
            local kerned_w = str_w + (#db_str - 1) * VisualSettings.Meter_Kerning
            local str_x = x_pos + (total_w / 2) - (kerned_w / 2)
            local str_y = line_y - (str_h / 2)
            
            local is_covered = math.max(val_l, val_r) >= db
            local txt_col = is_covered and VisualSettings.Color_Background or VisualSettings.Color_Text
            
            if not is_covered then
                DrawThickText(draw_list, bold_font, 13, str_x, str_y, txt_col, db_str, VisualSettings.Color_TextShadow, VisualSettings.Meter_Kerning)
            else
                DrawThickText(draw_list, bold_font, 13, str_x, str_y, txt_col, db_str, nil, VisualSettings.Meter_Kerning)
            end
        end
    end
    
    -- 🎯 Target Marker Rendering
    if new_tgt_active then
        local ty_offset = GetYForDb(new_tgt_db, h, scale_mode, db_min, db_max)
        local ty = meter_y + ty_offset
        
        -- Full width base line spanning the entire meter column
        reaper.ImGui_DrawList_AddLine(draw_list, x_pos, ty, x_pos + total_w, ty, VisualSettings.Color_TargetLine, 2.0)
        
        local inf_delta_str = "---"
        if inf_val and inf_val > -140 then
            local delta = new_tgt_db - inf_val
            if delta > 0.0 then inf_delta_str = string.format("+%.1f", delta)
            else inf_delta_str = string.format("%.1f", delta) end
        end
        
        local roll_delta_str = "---"
        if roll_val and roll_val > -140 then
            local delta = new_tgt_db - roll_val
            if delta > 0.0 then roll_delta_str = string.format("+%.1f", delta)
            else roll_delta_str = string.format("%.1f", delta) end
        end
        
        -- Target Marker Background Opacity Logic
        local rgb_int = math.floor(VisualSettings.Color_Background / 256)
        local alpha_int = math.floor(255 * State.tgt_marker_bg_alpha)
        local bg_col = (rgb_int * 256) + alpha_int
        
        -- Icon Decoupling and Sizing
        local l_icon = "∞"
        local r_icon = "↻"
        local l_val = inf_delta_str
        local r_val = roll_delta_str
        
        local icon_scale_inf = 1.45
        local icon_scale_roll = 0.9
        
        if State.tgt_marker_size == 1 then
            -- LARGE (Stacked Layout via Math Scaling)
            reaper.ImGui_PushFont(ctx, base_font, 18)
            
            local inf_sz = 18 * icon_scale_inf
            local roll_sz = 18 * icon_scale_roll
            local val_sz = 18
            
            local li_tw, li_th = reaper.ImGui_CalcTextSize(ctx, l_icon)
            li_tw, li_th = li_tw * (inf_sz/16.0), li_th * (inf_sz/16.0)
            
            local ri_tw, ri_th = reaper.ImGui_CalcTextSize(ctx, r_icon)
            ri_tw, ri_th = ri_tw * (roll_sz/16.0), ri_th * (roll_sz/16.0)
            
            local lv_tw, lv_th = reaper.ImGui_CalcTextSize(ctx, l_val)
            lv_tw, lv_th = lv_tw * (val_sz/16.0), lv_th * (val_sz/16.0)
            
            local rv_tw, rv_th = reaper.ImGui_CalcTextSize(ctx, r_val)
            rv_tw, rv_th = rv_tw * (val_sz/16.0), rv_th * (val_sz/16.0)
            
            local pad_y = 4
            local icon_h = math.max(li_th, ri_th)
            local val_h = math.max(lv_th, rv_th)
            
            -- Box Shrinking Logic
            local min_w = math.max(li_tw, lv_tw) + math.max(ri_tw, rv_tw) + 24
            local handle_w = math.max(min_w, total_w - (State.tgt_marker_indent * 2))
            local handle_x = x_pos + (total_w / 2) - (handle_w / 2)
            
            local handle_h = icon_h + val_h + (pad_y * 3)
            local handle_y = ty - (handle_h / 2)
            
            reaper.ImGui_DrawList_AddRectFilled(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, bg_col, 4.0)
            reaper.ImGui_DrawList_AddRect(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, VisualSettings.Color_TargetLine, 4.0, 0, 1.5)
            
            local div_x = handle_x + (handle_w / 2)
            reaper.ImGui_DrawList_AddLine(draw_list, div_x, handle_y, div_x, handle_y + handle_h, VisualSettings.Color_TargetLine, 1.0)
            
            local q1_x = handle_x + (handle_w / 4)
            local q3_x = div_x + (handle_w / 4)
            
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, inf_sz, q1_x - (li_tw/2) + 4, handle_y + pad_y + (icon_h/2 - li_th/2) + 2, VisualSettings.Color_TargetLine, l_icon)
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, val_sz, q1_x - (lv_tw/2) + 2, handle_y + pad_y*2 + icon_h + (val_h/2 - lv_th/2), VisualSettings.Color_TargetLine, l_val)
            
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, roll_sz, q3_x - (ri_tw/2)+ 2, handle_y + pad_y + (icon_h/2 - ri_th/2), VisualSettings.Color_TargetLine, r_icon)
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, val_sz, q3_x - (rv_tw/2) + 2, handle_y + pad_y*2 + icon_h + (val_h/2 - rv_th/2), VisualSettings.Color_TargetLine, r_val)
            
            reaper.ImGui_PopFont(ctx)
        else
            -- SMALL (Inline Layout)
            reaper.ImGui_PushFont(ctx, base_font, 13)
            
            local inf_sz = 13 * icon_scale_inf
            local roll_sz = 13 * icon_scale_roll
            local val_sz = 13
            
            local li_tw, li_th = reaper.ImGui_CalcTextSize(ctx, l_icon)
            li_tw, li_th = li_tw * (inf_sz/16.0), li_th * (inf_sz/16.0)
            
            local ri_tw, ri_th = reaper.ImGui_CalcTextSize(ctx, r_icon)
            ri_tw, ri_th = ri_tw * (roll_sz/16.0), ri_th * (roll_sz/16.0)
            
            local lv_tw, lv_th = reaper.ImGui_CalcTextSize(ctx, l_val)
            lv_tw, lv_th = lv_tw * (val_sz/16.0), lv_th * (val_sz/16.0)
            
            local rv_tw, rv_th = reaper.ImGui_CalcTextSize(ctx, r_val)
            rv_tw, rv_th = rv_tw * (val_sz/16.0), rv_th * (val_sz/16.0)
            
            reaper.ImGui_PopFont(ctx)
            
            local icon_val_gap = 4
            local l_total_w = li_tw + icon_val_gap + lv_tw
            local r_total_w = ri_tw + icon_val_gap + rv_tw
            
            local pad_y = 2
            
            local min_w = l_total_w + r_total_w + 24
            local handle_w = math.max(min_w, total_w - (State.tgt_marker_indent * 2))
            local handle_x = x_pos + (total_w / 2) - (handle_w / 2) 
            
            local handle_h = math.max(li_th, ri_th, lv_th, rv_th) + (pad_y * 2)
            local handle_y = ty - (handle_h / 2)
            
            reaper.ImGui_DrawList_AddRectFilled(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, bg_col, 4.0)
            reaper.ImGui_DrawList_AddRect(draw_list, handle_x, handle_y, handle_x + handle_w, handle_y + handle_h, VisualSettings.Color_TargetLine, 4.0, 0, 1.5)
            
            local div_x = handle_x + (handle_w / 2)
            reaper.ImGui_DrawList_AddLine(draw_list, div_x, handle_y, div_x, handle_y + handle_h, VisualSettings.Color_TargetLine, 1.0)
            
            local left_text_x = handle_x + (handle_w / 4) - (l_total_w / 2)
            local right_text_x = div_x + (handle_w / 4) - (r_total_w / 2)
            
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, inf_sz, left_text_x, handle_y + pad_y + (handle_h - pad_y*2 - li_th)/2, VisualSettings.Color_TargetLine, l_icon)
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, val_sz, left_text_x + li_tw + icon_val_gap, handle_y + pad_y + (handle_h - pad_y*2 - lv_th)/2, VisualSettings.Color_TargetLine, l_val)
            
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, roll_sz, right_text_x, handle_y + pad_y + (handle_h - pad_y*2 - ri_th)/2, VisualSettings.Color_TargetLine, r_icon)
            reaper.ImGui_DrawList_AddTextEx(draw_list, base_font, val_sz, right_text_x + ri_tw + icon_val_gap, handle_y + pad_y + (handle_h - pad_y*2 - rv_th)/2, VisualSettings.Color_TargetLine, r_val)
        end
    end
    
    -- 🖱️ Cursor Target Icon
    if is_meter_hovered then
        local icon_x = hover_mx + 10
        local icon_y = hover_my - 10
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, icon_x, icon_y, 7, VisualSettings.Color_Background)
        reaper.ImGui_DrawList_AddCircle(draw_list, icon_x, icon_y, 6, VisualSettings.Color_TargetLine, 12, 1.5)
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, icon_x, icon_y, 2, VisualSettings.Color_TargetLine)
    end
    
    return clicked_inf_reset, clicked_roll_reset, new_tgt_active, new_tgt_db
end

-------------------------------------------------------------------------------
-- 6. MAIN LOOP
-------------------------------------------------------------------------------

local function loop()
    local now = reaper.time_precise()
    local dt = math.min(now - State.last_time, 0.1) 
    State.last_time = now

    local current_play_state = reaper.GetPlayState()
    local is_playing = (current_play_state == 1 or current_play_state == 5)
    local was_playing = (State.play_state == 1 or State.play_state == 5)
    
    if is_playing and not was_playing then
        State.num_peak_max = -150
        State.num_rms_max  = -150
        State.balance_val  = 0.0
        State.balance_val_fast = 0.0
        State.audio_history = {}
        State.disp_roll_peak = -150
        State.disp_roll_rms  = -150
        State.play_start_time = now
        State.last_clip_time = -100 
    end
    
    State.play_state = current_play_state

    -- Dynamic Font Regeneration Engine
    if cached_tooltip_size ~= VisualSettings.Tooltip_Font_Size then
        reaper.ImGui_Detach(ctx, tooltip_font)
        tooltip_font = reaper.ImGui_CreateFont(VisualSettings.Global_Font_Family, VisualSettings.Tooltip_Font_Size)
        reaper.ImGui_Attach(ctx, tooltip_font)
        cached_tooltip_size = VisualSettings.Tooltip_Font_Size
    end
    if cached_settings_size ~= VisualSettings.Settings_Font_Size then
        reaper.ImGui_Detach(ctx, settings_font)
        settings_font = reaper.ImGui_CreateFont(VisualSettings.Global_Font_Family, VisualSettings.Settings_Font_Size)
        reaper.ImGui_Attach(ctx, settings_font)
        cached_settings_size = VisualSettings.Settings_Font_Size
    end

    local warmup_duration = 0.5 
    local is_warming_up = (is_playing and (now - State.play_start_time < warmup_duration))
    local do_roll_reset = false

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), VisualSettings.Color_Background)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0) 
    
    local main_flags = reaper.ImGui_WindowFlags_NoCollapse()
    local visible, open = reaper.ImGui_Begin(ctx, 'Track Meters', true, main_flags)
    
    if visible then
        local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
        local win_pos_x, win_pos_y = reaper.ImGui_GetCursorScreenPos(ctx)
        local win_width = reaper.ImGui_GetWindowWidth(ctx)
        local win_height = reaper.ImGui_GetWindowHeight(ctx)
        
        -- ⌨️ KEYBOARD SHORTCUTS
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_R()) then
            State.num_peak_max = -150
            State.num_rms_max  = -150
            do_roll_reset      = true
        end
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_C()) then
            State.num_peak_max = -150
            State.num_rms_max  = -150
            do_roll_reset      = true
            State.clip_log = {}
            State.last_clip_time = -100
        end
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_B()) then
            State.show_balance_meter = not State.show_balance_meter
        end
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_M()) then
            State.meter_scale_mode = State.meter_scale_mode == 1 and 2 or 1
        end
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_L()) then
            State.is_locked = not State.is_locked
            if State.is_locked then
                State.locked_track = reaper.GetSelectedTrack(0, 0)
            else
                State.locked_track = nil
            end
        end

        -- 🎯 Robust Track Locking Logic
        local track = reaper.GetSelectedTrack(0, 0)
        if State.is_locked then
            if State.locked_track and reaper.ValidatePtr(State.locked_track, "MediaTrack*") then
                track = State.locked_track
            else
                State.is_locked = false
                State.locked_track = track
            end
        else
            State.locked_track = track
        end
        
        -- 🧹 Reset when selected track changes
        if track ~= State.last_active_track then
            State.num_peak_max = -150
            State.num_rms_max  = -150
            State.balance_val  = 0.0
            State.balance_val_fast = 0.0
            State.audio_history = {}
            State.disp_roll_peak = -150
            State.disp_roll_rms  = -150
            State.clip_log       = {}
            State.last_clip_time = -100 
            State.last_active_track = track
        end

        local cur_peak_l, cur_peak_r = -150.0, -150.0
        local cur_rms_l, cur_rms_r   = -150.0, -150.0
        
        local track_name = "No Track Selected"
        local track_color_imgui = VisualSettings.Color_DefaultTrk
        
        if track then
            local retval, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
            if name ~= "" then track_name = name
            else
                local tr_num = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
                if tr_num == -1 then track_name = "Master"
                elseif tr_num > 0 then track_name = "Track " .. math.floor(tr_num) end
            end
            
            local native_color = reaper.GetTrackColor(track) or 0
            track_color_imgui = NativeToImGuiColor(native_color, VisualSettings.Color_DimFactor)
            
            local peak_l_amp = reaper.Track_GetPeakInfo(track, 0) or 0.0
            local peak_r_amp = reaper.Track_GetPeakInfo(track, 1) or 0.0
            
            cur_peak_l = AmpToDb(peak_l_amp)
            cur_peak_r = AmpToDb(peak_r_amp)
            
            local rms_l_amp = reaper.Track_GetPeakInfo(track, 1024) or 0.0
            local rms_r_amp = reaper.Track_GetPeakInfo(track, 1025) or 0.0
            
            if rms_l_amp > 0 or rms_r_amp > 0 then
                cur_rms_l = AmpToDb(rms_l_amp)
                cur_rms_r = AmpToDb(rms_r_amp)
            else
                cur_rms_l = AmpToDb(peak_l_amp * 0.7071)
                cur_rms_r = AmpToDb(peak_r_amp * 0.7071)
            end
            
            local max_incoming_peak = math.max(cur_peak_l, cur_peak_r)
            local max_incoming_rms = math.max(cur_rms_l, cur_rms_r)
            
            -- 🛡️ WAKE UP FROM SILENCE FIX
            -- Snaps the smoothed RMS filter to the incoming volume if waking up from absolute digital silence.
            -- This prevents the mathematical illusion of a 140 dB Crest Factor spike on block 1!
            if State.rms_smooth_l < -100.0 then State.rms_smooth_l = cur_rms_l end
            if State.rms_smooth_r < -100.0 then State.rms_smooth_r = cur_rms_r end

            -- 📡 Actionable Clip Logging
            if is_playing and max_incoming_peak >= 0.0 and not is_warming_up then
                local play_pos = reaper.GetPlayPosition()
                if (play_pos - State.last_clip_time) > 0.5 then
                    table.insert(State.clip_log, 1, {time = play_pos, val = max_incoming_peak})
                    if #State.clip_log > 10 then table.remove(State.clip_log) end
                    State.last_clip_time = play_pos
                end
            end

            if max_incoming_peak > -140 and max_incoming_rms > -140 then
                if max_incoming_peak > State.num_peak_max then State.num_peak_max = max_incoming_peak end
                if max_incoming_rms > State.num_rms_max then State.num_rms_max = max_incoming_rms end
                
                local current_smoothed_rms = math.max(State.rms_smooth_l, State.rms_smooth_r)
                
                if not is_warming_up then
                    table.insert(State.audio_history, {
                        time = now, 
                        peak = max_incoming_peak, 
                        rms = current_smoothed_rms
                    })
                end
            end
            
            State.peak_max_l = State.peak_max_l - (State.falloff_db_sec * dt)
            if cur_peak_l > State.peak_max_l then State.peak_max_l = cur_peak_l end
            
            State.peak_max_r = State.peak_max_r - (State.falloff_db_sec * dt)
            if cur_peak_r > State.peak_max_r then State.peak_max_r = cur_peak_r end
            
            State.rms_smooth_l = State.rms_smooth_l + (cur_rms_l - State.rms_smooth_l) * (State.damping * 0.5)
            State.rms_smooth_r = State.rms_smooth_r + (cur_rms_r - State.rms_smooth_r) * (State.damping * 0.5)
            
            local target_balance_slow = 0.0
            local target_balance_fast = 0.0
            
            if max_incoming_rms > -70.0 then target_balance_slow = State.rms_smooth_r - State.rms_smooth_l end
            if max_incoming_peak > -70.0 then target_balance_fast = cur_peak_r - cur_peak_l end
            
            local alpha_bal_slow = 1.0 - math.exp(-dt / State.balance_window_sec)
            State.balance_val = State.balance_val + (target_balance_slow - State.balance_val) * alpha_bal_slow
            
            local alpha_bal_fast = 1.0 - math.exp(-dt / State.balance_window_sec_fast)
            State.balance_val_fast = State.balance_val_fast + (target_balance_fast - State.balance_val_fast) * alpha_bal_fast
            
        else
             State.peak_max_l = State.peak_max_l - (State.falloff_db_sec * dt)
             State.peak_max_r = State.peak_max_r - (State.falloff_db_sec * dt)
             State.rms_smooth_l = State.rms_smooth_l + (-150.0 - State.rms_smooth_l) * (State.damping * 0.5)
             State.rms_smooth_r = State.rms_smooth_r + (-150.0 - State.rms_smooth_r) * (State.damping * 0.5)
             local alpha_bal_slow = 1.0 - math.exp(-dt / State.balance_window_sec)
             State.balance_val = State.balance_val + (0.0 - State.balance_val) * alpha_bal_slow
             local alpha_bal_fast = 1.0 - math.exp(-dt / State.balance_window_sec_fast)
             State.balance_val_fast = State.balance_val_fast + (0.0 - State.balance_val_fast) * alpha_bal_fast
        end

        local max_history_window = State.rolling_window_sec
        while #State.audio_history > 0 and (now - State.audio_history[1].time) > max_history_window do
            table.remove(State.audio_history, 1)
        end
        
        State.roll_peak_max = -150
        State.roll_rms_max = -150
        
        if #State.audio_history > 0 then
            for i = 1, #State.audio_history do
                local entry = State.audio_history[i]
                local age = now - entry.time
                if age <= State.rolling_window_sec then
                    if entry.peak > State.roll_peak_max then State.roll_peak_max = entry.peak end
                    if entry.rms > State.roll_rms_max then State.roll_rms_max = entry.rms end
                end
            end
        end

        if is_playing then
            if State.roll_peak_max > State.disp_roll_peak then State.disp_roll_peak = State.roll_peak_max
            else State.disp_roll_peak = State.disp_roll_peak - (State.falloff_db_sec * dt)
                if State.disp_roll_peak < State.roll_peak_max then State.disp_roll_peak = State.roll_peak_max end
            end
            if State.roll_rms_max > State.disp_roll_rms then State.disp_roll_rms = State.roll_rms_max
            else State.disp_roll_rms = State.disp_roll_rms - (State.falloff_db_sec * dt)
                if State.disp_roll_rms < State.roll_rms_max then State.disp_roll_rms = State.roll_rms_max end
            end
        else
            State.disp_roll_peak = -150
            State.disp_roll_rms  = -150
        end

        local header_h = VisualSettings.Header_Height
        reaper.ImGui_DrawList_AddRectFilled(draw_list, win_pos_x, win_pos_y, win_pos_x + win_width, win_pos_y + header_h, track_color_imgui)
        
        -- ⚙️ Settings Hamburger Icon
        local hw = 16 
        local hh = 12 
        local btn_w = 30
        local gear_x = win_pos_x + win_width - btn_w - 5
        local gear_y = win_pos_y + (header_h / 2) - (hh / 2)
        
        reaper.ImGui_SetCursorScreenPos(ctx, gear_x, gear_y - 5)
        if reaper.ImGui_InvisibleButton(ctx, "settings_btn", btn_w, hh + 10) then State.show_settings = not State.show_settings end
        local btn_col = reaper.ImGui_IsItemHovered(ctx) and 0x000000FF or 0x222222FF
        reaper.ImGui_DrawList_AddLine(draw_list, gear_x, gear_y, gear_x + hw, gear_y, btn_col, 2.0)
        reaper.ImGui_DrawList_AddLine(draw_list, gear_x, gear_y + (hh / 2), gear_x + hw, gear_y + (hh / 2), btn_col, 2.0)
        reaper.ImGui_DrawList_AddLine(draw_list, gear_x, gear_y + hh, gear_x + hw, gear_y + hh, btn_col, 2.0)
        DrawTooltip(ctx, "Open Settings")
        
        local header_space_used = gear_x
        
        -- 🚨 Clip Log Header Warning
        if #State.clip_log > 0 then
            reaper.ImGui_PushFont(ctx, settings_font, VisualSettings.Settings_Font_Size)
            local log_txt = tostring(#State.clip_log) .. " CLIPS"
            local log_tw, log_th = reaper.ImGui_CalcTextSize(ctx, log_txt)
            local log_w = log_tw + 20
            local log_x = header_space_used - log_w - 15
            local log_y = win_pos_y + (header_h/2) - (20/2)
            
            reaper.ImGui_DrawList_AddRectFilled(draw_list, log_x, log_y, log_x + log_w, log_y + 20, VisualSettings.Color_Clip, 10.0)
            reaper.ImGui_DrawList_AddTextEx(draw_list, nil, VisualSettings.Settings_Font_Size, log_x + 10, log_y + (20/2) - (log_th/2), 0x000000FF, log_txt)
            
            reaper.ImGui_SetCursorScreenPos(ctx, log_x, log_y)
            if reaper.ImGui_InvisibleButton(ctx, "clip_log_btn", log_w, 20) then State.show_clip_log = not State.show_clip_log end
            DrawTooltip(ctx, "Clips Detected. Click to view log.")
            reaper.ImGui_PopFont(ctx)
            
            header_space_used = log_x
        else
            State.show_clip_log = false
        end

        -- Header Pill Background
        local pill_padding_y = 6
        local pill_x = win_pos_x + 10
        local pill_w = (header_space_used - 10) - pill_x
        
        if pill_w > 20 then
            local pill_h = header_h - (pill_padding_y * 2)
            local pill_y = win_pos_y + pill_padding_y
            reaper.ImGui_DrawList_AddRectFilled(draw_list, pill_x, pill_y, pill_x + pill_w, pill_y + pill_h, VisualSettings.Color_MeterBG, pill_h / 2)
            
            local lock_x_offset = 0
            if track then
                local lock_size = 28
                local lock_w = lock_size
                local lock_h = lock_size
                local lock_x = pill_x + pill_w - lock_w - 4
                local lock_y = pill_y + (pill_h / 2) - (lock_h / 2)
                lock_x_offset = lock_w + 12
                
                local lock_bg_col = State.is_locked and VisualSettings.Color_Warn or 0x444444FF
                local icon_col = State.is_locked and VisualSettings.Color_MeterBG or VisualSettings.Color_Text
                
                local cx = lock_x + (lock_w / 2)
                local cy = lock_y + (lock_h / 2)
                reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, lock_w / 2, lock_bg_col)
                
                local body_w = 12
                local body_h = 10
                local body_y_offset = 0
                local shackle_r = 4.25
                local rot_open = math.pi / 1.25
                local rot_closed = math.pi / 1
                
                if State.is_locked then
                    reaper.ImGui_DrawList_PathClear(draw_list)
                    reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy - body_y_offset - 4, shackle_r, math.pi + rot_closed, 0 , 10)
                    reaper.ImGui_DrawList_PathStroke(draw_list, icon_col, 0, 2.0)
                else
                    reaper.ImGui_DrawList_PathClear(draw_list)
                    reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy - body_y_offset - 4, shackle_r, math.pi + rot_open, 0 + rot_open, 10)
                    reaper.ImGui_DrawList_PathStroke(draw_list, icon_col, 0, 2.0)
                end
                
                reaper.ImGui_DrawList_AddRectFilled(draw_list, cx - (body_w/2), cy + body_y_offset - 2, cx + (body_w/2), cy + body_h + body_y_offset - 2, icon_col, 2.0)
                
                reaper.ImGui_SetCursorScreenPos(ctx, lock_x, lock_y)
                if reaper.ImGui_InvisibleButton(ctx, "lock_btn", lock_w, lock_h) then
                    State.is_locked = not State.is_locked
                    if State.is_locked then State.locked_track = track end
                end
                DrawTooltip(ctx, State.is_locked and "Unlock to follow selected track\n\nShortcut: L" or "Lock meter to current track\n\nShortcut: L")
            end
            
            local tw, th = reaper.ImGui_CalcTextSize(ctx, track_name)
            local tx = pill_x + 15
            local clip_max_x = track and (pill_x + pill_w - lock_x_offset - 5) or (pill_x + pill_w - 10)
            
            reaper.ImGui_PushClipRect(ctx, pill_x, pill_y, clip_max_x, pill_y + pill_h, true)
            reaper.ImGui_DrawList_AddTextEx(draw_list, nil, 16, tx, pill_y + (pill_h / 2) - (th / 2) - 2, VisualSettings.Color_TrackName, track_name)
            reaper.ImGui_PopClipRect(ctx)
        end

        local content_start_y = win_pos_y + header_h + 15 
        local v_meter_start_y = content_start_y
        
        local available_w = win_width - (VisualSettings.Window_Padding * 2)
        
        if State.show_balance_meter and available_w > 100 then
            local bal_x = win_pos_x + VisualSettings.Window_Padding
            DrawBalanceMeter(draw_list, available_w, bal_x, content_start_y, State.balance_val, State.balance_val_fast, State.balance_meter_height)
            v_meter_start_y = content_start_y + State.balance_meter_height + 20
        end
        
        local shared_box_y = v_meter_start_y + 25
        local shared_meter_y = shared_box_y + 36 + 15
        
        local combo_height = 30
        local bottom_padding = 15 + combo_height + 15 
        local dynamic_h = win_height - (shared_meter_y - win_pos_y) - bottom_padding
        if dynamic_h < 150 then dynamic_h = 150 end 
        
        local spacing = VisualSettings.Meter_Spacing
        
        local calc_meter_w = 10
        if available_w > 50 then
            local fixed_w = (2 * spacing) + State.column_gap
            calc_meter_w = math.floor((available_w - fixed_w) / 4)
        end
        State.meter_width = math.max(10, calc_meter_w) 
        
        local pair_w = (State.meter_width * 2) + spacing
        
        local total_block_w = pair_w + State.column_gap + pair_w
        
        local start_x = win_pos_x + (win_width / 2) - (total_block_w / 2)
        local peak_x = start_x
        local rms_x = peak_x + pair_w + State.column_gap
        
        -- 🔴 PEAK METER
        local p_inf_reset, p_roll_reset, p_tgt_act, p_tgt_db = DrawStereoMeterPair(
            draw_list, peak_x, v_meter_start_y, State.peak_max_l, State.peak_max_r, "PEAK", 
            State.peak_db_min, State.peak_db_max, State.meter_width, dynamic_h, 
            State.num_peak_max, State.disp_roll_peak, State.tgt_peak_active, State.tgt_peak_db, State.meter_scale_mode
        )
        if p_inf_reset then State.num_peak_max = -150 end
        if p_roll_reset then do_roll_reset = true end
        State.tgt_peak_active = p_tgt_act
        State.tgt_peak_db = p_tgt_db
        
        --  RMS METER
        local r_inf_reset, r_roll_reset, r_tgt_act, r_tgt_db = DrawStereoMeterPair(
            draw_list, rms_x, v_meter_start_y, State.rms_smooth_l, State.rms_smooth_r, "RMS", 
            State.rms_db_min, State.rms_db_max, State.meter_width, dynamic_h, 
            State.num_rms_max, State.disp_roll_rms, State.tgt_rms_active, State.tgt_rms_db, State.meter_scale_mode
        )
        if r_inf_reset then State.num_rms_max = -150 end
        if r_roll_reset then do_roll_reset = true end
        State.tgt_rms_active = r_tgt_act
        State.tgt_rms_db = r_tgt_db or -18.0
        
        if do_roll_reset then
            State.audio_history = {}
            State.roll_peak_max = -150
            State.roll_rms_max = -150
            State.disp_roll_peak = -150
            State.disp_roll_rms = -150
        end
        
        -- 🎚️ METER SCALE DROPDOWN
        reaper.ImGui_PushFont(ctx, settings_font, VisualSettings.Settings_Font_Size) 
        local combo_w = total_block_w
        local combo_x = start_x
        local combo_y = shared_meter_y + dynamic_h + 15
        reaper.ImGui_SetCursorScreenPos(ctx, combo_x, combo_y)
        reaper.ImGui_SetNextItemWidth(ctx, combo_w)
        
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), VisualSettings.Color_SettingsFrame)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), VisualSettings.Color_SettingsHover)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), VisualSettings.Color_SettingsAccent)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), VisualSettings.Color_Text)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), VisualSettings.Color_SettingsFrame)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 2.0)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 6)
        
        local scale_opts = "Linear\0Mixer's Curve\0"
        local changed, new_mode_idx = reaper.ImGui_Combo(ctx, "##ScaleMode", State.meter_scale_mode - 1, scale_opts)
        if changed then State.meter_scale_mode = new_mode_idx + 1 end
        
        DrawTooltip(ctx, "Meter Scale Mode\n\nLinear: Evenly spaced decibel increments.\nMixer's Curve: Expands the top 24 dB for high-resolution critical mixing.\n\nShortcut: M")
        
        reaper.ImGui_PopStyleVar(ctx, 2)
        reaper.ImGui_PopStyleColor(ctx, 5)
        reaper.ImGui_PopFont(ctx)

        -- 🌑 DIM OVERLAY WHEN NO TRACK
        if not track then
            local dim_alpha = math.floor(VisualSettings.Dim_Opacity_Pct * 255)
            local hex_alpha = dim_alpha 
            reaper.ImGui_DrawList_AddRectFilled(draw_list, win_pos_x, win_pos_y + header_h, win_pos_x + win_width, win_pos_y + win_height, hex_alpha)
        end

    end
    
    reaper.ImGui_End(ctx) 
    reaper.ImGui_PopStyleVar(ctx, 1) 
    reaper.ImGui_PopStyleColor(ctx, 1)

    -------------------------------------------------------------------------------
-- 7. FLOATING CLIP LOG
-------------------------------------------------------------------------------
    if State.show_clip_log then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), VisualSettings.Color_Background)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(), VisualSettings.Color_TitleBg)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), VisualSettings.Color_Clip)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), VisualSettings.Color_SettingsFrame)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), VisualSettings.Color_SettingsHover)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), VisualSettings.Color_SettingsAccent)
        
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 10, 10) 
        reaper.ImGui_PushFont(ctx, settings_font, VisualSettings.Settings_Font_Size) 
        
        local clip_flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
        local c_visible, c_open = reaper.ImGui_Begin(ctx, 'Recent Clips', true, clip_flags)
        
        if c_visible then
            if #State.clip_log == 0 then
                reaper.ImGui_Text(ctx, "No clips detected.")
            else
                reaper.ImGui_Text(ctx, "Click timestamp to jump to location:")
                reaper.ImGui_Separator(ctx)
                for i, clip in ipairs(State.clip_log) do
                    local time_str = reaper.format_timestr_pos(clip.time, "", -1)
                    local val_str = string.format("+%.1f dB", clip.val)
                    if reaper.ImGui_Button(ctx, time_str .. "  |  " .. val_str .. "##" .. i, -1, 30) then
                        reaper.SetEditCurPos(clip.time, true, false)
                    end
                end
                reaper.ImGui_Dummy(ctx, 0, 10)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), VisualSettings.Color_Clip)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x000000FF)
                if reaper.ImGui_Button(ctx, "Clear Log", -1, 30) then
                    State.clip_log = {}
                    State.last_clip_time = -100
                end
                reaper.ImGui_PopStyleColor(ctx, 2)
            end
        end
        reaper.ImGui_End(ctx)
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_PopStyleVar(ctx, 1)
        reaper.ImGui_PopStyleColor(ctx, 6)
        if not c_open then State.show_clip_log = false end
    end

    -------------------------------------------------------------------------------
-- 8. FLOATING SETTINGS MODAL
-------------------------------------------------------------------------------
    if State.show_settings then
        
        local num_style_colors = 0
        local function SafePushColor(enum_func, fallback_int, hex_color)
            local col_id = fallback_int
            if type(enum_func) == "function" then col_id = enum_func()
            elseif type(enum_func) == "number" then col_id = enum_func end
            reaper.ImGui_PushStyleColor(ctx, col_id, hex_color)
            num_style_colors = num_style_colors + 1
        end

        SafePushColor(reaper.ImGui_Col_TitleBg, 10, VisualSettings.Color_TitleBg)
        SafePushColor(reaper.ImGui_Col_TitleBgActive, 11, VisualSettings.Color_TitleActive)
        SafePushColor(reaper.ImGui_Col_TitleBgCollapsed, 12, VisualSettings.Color_TitleBg)
        
        SafePushColor(reaper.ImGui_Col_WindowBg, 2, VisualSettings.Color_Background)
        SafePushColor(reaper.ImGui_Col_FrameBg, 7, VisualSettings.Color_SettingsFrame)
        SafePushColor(reaper.ImGui_Col_FrameBgHovered, 8, VisualSettings.Color_SettingsHover)
        SafePushColor(reaper.ImGui_Col_SliderGrab, 19, VisualSettings.Color_SettingsAccent)
        SafePushColor(reaper.ImGui_Col_SliderGrabActive, 20, VisualSettings.Color_SettingsAccent)
        SafePushColor(reaper.ImGui_Col_CheckMark, 18, VisualSettings.Color_SettingsAccent)
        
        SafePushColor(reaper.ImGui_Col_Tab, 33, VisualSettings.Tab_Inactive)
        SafePushColor(reaper.ImGui_Col_TabHovered, 34, VisualSettings.Tab_Hovered)
        SafePushColor(reaper.ImGui_Col_TabActive, 35, VisualSettings.Tab_Active)
        SafePushColor(reaper.ImGui_Col_TabUnfocused, 36, VisualSettings.Tab_Inactive)
        SafePushColor(reaper.ImGui_Col_TabUnfocusedActive, 37, VisualSettings.Tab_Active)
        
        SafePushColor(reaper.ImGui_Col_Header, 24, VisualSettings.Color_SettingsFrame)
        SafePushColor(reaper.ImGui_Col_HeaderHovered, 25, VisualSettings.Color_SettingsHover)
        SafePushColor(reaper.ImGui_Col_HeaderActive, 26, VisualSettings.Color_SettingsAccent)
        
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 8, 8) 
        reaper.ImGui_PushFont(ctx, settings_font, VisualSettings.Settings_Font_Size) 
        
        local set_flags = reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoCollapse()
        local set_visible, set_open = reaper.ImGui_Begin(ctx, 'Meter Settings', true, set_flags)
        
        if set_visible then
            if reaper.ImGui_BeginTabBar(ctx, "SettingsTabs") then
                
                -- TAB 1: Appearance
                if reaper.ImGui_BeginTabItem(ctx, "Appearance") then
                    reaper.ImGui_Text(ctx, "Meter Colors")
                    reaper.ImGui_Separator(ctx)
                    local c_changed, c_new
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Safe Zone", VisualSettings.Color_Safe, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Color_Safe = c_new end
                    DrawTooltip(ctx, "Color for normal operating levels.")
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Warning Zone", VisualSettings.Color_Warn, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Color_Warn = c_new end
                    DrawTooltip(ctx, "Color when signal exceeds the warning threshold.")
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Clip Zone", VisualSettings.Color_Clip, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Color_Clip = c_new end
                    DrawTooltip(ctx, "Color when signal hits or exceeds 0 dBFS.")
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Target Line", VisualSettings.Color_TargetLine, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Color_TargetLine = c_new end
                    DrawTooltip(ctx, "Color of the draggable target markers.")
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Meter Background", VisualSettings.Color_MeterBG, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Color_MeterBG = c_new end
                    DrawTooltip(ctx, "Background color of the meter tracks.")
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Window Background", VisualSettings.Color_Background, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Color_Background = c_new end
                    DrawTooltip(ctx, "Main window background color.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Tab Navigation Colors")
                    reaper.ImGui_Separator(ctx)
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Active Tab", VisualSettings.Tab_Active, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Tab_Active = c_new end
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Inactive Tab", VisualSettings.Tab_Inactive, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Tab_Inactive = c_new end
                    
                    c_changed, c_new = reaper.ImGui_ColorEdit4(ctx, "Hovered Tab", VisualSettings.Tab_Hovered, reaper.ImGui_ColorEditFlags_NoInputs())
                    if c_changed then VisualSettings.Tab_Hovered = c_new end
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    if reaper.ImGui_Button(ctx, "Reset All Colors to Default") then
                        VisualSettings.Color_Safe = 0x0088CCFF
                        VisualSettings.Color_Warn = 0xE0B000FF
                        VisualSettings.Color_Clip = 0xDD0000FF
                        VisualSettings.Color_TargetLine = 0x00FFCCFF
                        VisualSettings.Color_MeterBG = 0x1A1A1AFF
                        VisualSettings.Color_Background = 0x202020FF
                        VisualSettings.Tab_Inactive = 0x2A2A2AFF
                        VisualSettings.Tab_Hovered = 0x4A4A4AFF
                        VisualSettings.Tab_Active = 0x0088CCFF
                    end
                    
                    local changed
                    changed, VisualSettings.Dim_Opacity_Pct = reaper.ImGui_SliderDouble(ctx, "Unselected Dim Opacity", VisualSettings.Dim_Opacity_Pct, 0.0, 1.0, "%.2f")
                    DrawTooltip(ctx, "Darkness of the overlay when no track is selected.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Typography")
                    reaper.ImGui_Separator(ctx)
                    changed, VisualSettings.Tooltip_Font_Size = reaper.ImGui_SliderInt(ctx, "Tooltip Font Size", VisualSettings.Tooltip_Font_Size, 10, 36)
                    DrawTooltip(ctx, "Size of the hover tooltips.")
                    
                    changed, VisualSettings.Settings_Font_Size = reaper.ImGui_SliderInt(ctx, "Settings Font Size", VisualSettings.Settings_Font_Size, 10, 36)
                    DrawTooltip(ctx, "Size of the text in this menu.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Layout")
                    reaper.ImGui_Separator(ctx)
                    changed, State.column_gap = reaper.ImGui_SliderInt(ctx, "Column Gap (px)", State.column_gap, 0, 100)
                    DrawTooltip(ctx, "Space between the Left/Right meters and the Crest Factor column.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Separator(ctx)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), VisualSettings.Color_TextDim)
                    reaper.ImGui_Text(ctx, "💡 Tip: Ctrl/Cmd + Click any slider to type a value.")
                    reaper.ImGui_PopStyleColor(ctx)
                    
                    reaper.ImGui_EndTabItem(ctx)
                end
                
                -- TAB 2: Stereo Balance
                if reaper.ImGui_BeginTabItem(ctx, "Stereo Balance") then
                    reaper.ImGui_Text(ctx, "Visibility")
                    reaper.ImGui_Separator(ctx)
                    local changed
                    changed, State.show_balance_meter = reaper.ImGui_Checkbox(ctx, "Show Stereo Balance Drift", State.show_balance_meter)
                    DrawTooltip(ctx, "Toggle the top horizontal balance meter.\nShortcut: B")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Range")
                    reaper.ImGui_Separator(ctx)
                    changed, State.balance_db_scale = reaper.ImGui_SliderDouble(ctx, "Max Range (+/- dB)", State.balance_db_scale, 1.0, 24.0, "%.1f")
                    DrawTooltip(ctx, "Decibel range from center to edge.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Drift Speeds")
                    reaper.ImGui_Separator(ctx)
                    changed, State.balance_window_sec = reaper.ImGui_SliderDouble(ctx, "Slow Drift Speed (sec)", State.balance_window_sec, 0.1, 10.0, "%.1f")
                    DrawTooltip(ctx, "Integration time for sustained RMS balance.")
                    
                    changed, State.balance_window_sec_fast = reaper.ImGui_SliderDouble(ctx, "Fast Drift Speed (sec)", State.balance_window_sec_fast, 0.033, 2.0, "%.3f")
                    DrawTooltip(ctx, "Integration time for instantaneous Peak balance.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Separator(ctx)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), VisualSettings.Color_TextDim)
                    reaper.ImGui_Text(ctx, "💡 Tip: Ctrl/Cmd + Click any slider to type a value.")
                    reaper.ImGui_PopStyleColor(ctx)
                    
                    reaper.ImGui_EndTabItem(ctx)
                end
                
                -- TAB 3: Level Meters
                if reaper.ImGui_BeginTabItem(ctx, "Level Meters") then
                    reaper.ImGui_Text(ctx, "Peak Settings")
                    reaper.ImGui_Separator(ctx)
                    local changed
                    changed, State.peak_db_min = reaper.ImGui_SliderDouble(ctx, "Min DB##Peak", State.peak_db_min, -100.0, 0.0, "%.1f")
                    DrawTooltip(ctx, "Lowest decibel value shown on Peak meters.")
                    
                    changed, State.peak_db_max = reaper.ImGui_SliderDouble(ctx, "Max DB##Peak", State.peak_db_max, -100.0, 0.0, "%.1f")
                    DrawTooltip(ctx, "Highest decibel value shown on Peak meters.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "RMS Settings")
                    reaper.ImGui_Separator(ctx)
                    changed, State.rms_db_min = reaper.ImGui_SliderDouble(ctx, "Min DB##RMS", State.rms_db_min, -100.0, 0.0, "%.1f")
                    DrawTooltip(ctx, "Lowest decibel value shown on RMS meters.")
                    
                    changed, State.rms_db_max = reaper.ImGui_SliderDouble(ctx, "Max DB##RMS", State.rms_db_max, -100.0, 0.0, "%.1f")
                    DrawTooltip(ctx, "Highest decibel value shown on RMS meters.")
                    
                    changed, State.damping = reaper.ImGui_SliderDouble(ctx, "Smoothing", State.damping, 0.01, 1.0, "%.2f")
                    DrawTooltip(ctx, "RC filter speed for the RMS calculation. Lower is slower.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Global")
                    reaper.ImGui_Separator(ctx)
                    changed, State.falloff_db_sec = reaper.ImGui_SliderDouble(ctx, "Meter Falloff (dB/s)", State.falloff_db_sec, 5.0, 100.0, "%.1f")
                    DrawTooltip(ctx, "Speed at which the meter bars drop (dB per second).")
                    
                    changed, State.rolling_window_sec = reaper.ImGui_SliderDouble(ctx, "Rolling Window (sec)", State.rolling_window_sec, 1.0, 10.0, "%.1f")
                    DrawTooltip(ctx, "Time in seconds before the rolling maximum resets.")
                    
                    if State.peak_db_min >= State.peak_db_max then State.peak_db_min = State.peak_db_max - 1 end
                    if State.rms_db_min >= State.rms_db_max then State.rms_db_min = State.rms_db_max - 1 end
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Separator(ctx)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), VisualSettings.Color_TextDim)
                    reaper.ImGui_Text(ctx, "💡 Tip: Ctrl/Cmd + Click any slider to type a value.")
                    reaper.ImGui_PopStyleColor(ctx)
                    
                    reaper.ImGui_EndTabItem(ctx)
                end
                
                -- TAB 4: Target Markers
                if reaper.ImGui_BeginTabItem(ctx, "Target Markers") then
                    reaper.ImGui_Text(ctx, "Peaks")
                    reaper.ImGui_Separator(ctx)
                    local changed
                    changed, State.tgt_peak_active = reaper.ImGui_Checkbox(ctx, "Enable Peak Target by Default##Peak", State.tgt_peak_active)
                    DrawTooltip(ctx, "Turn on the Peak target line automatically.")
                    
                    changed, State.tgt_peak_db = reaper.ImGui_SliderDouble(ctx, "Default Peak Target (dB)##Peak", State.tgt_peak_db, -60.0, 0.0, "%.1f")
                    DrawTooltip(ctx, "Default decibel level for the Peak target.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "RMS")
                    reaper.ImGui_Separator(ctx)
                    changed, State.tgt_rms_active = reaper.ImGui_Checkbox(ctx, "Enable RMS Target by Default##RMS", State.tgt_rms_active)
                    DrawTooltip(ctx, "Turn on the RMS target line automatically.")
                    
                    changed, State.tgt_rms_db = reaper.ImGui_SliderDouble(ctx, "Default RMS Target (dB)##RMS", State.tgt_rms_db, -60.0, 0.0, "%.1f")
                    DrawTooltip(ctx, "Default decibel level for the RMS target.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Appearance")
                    reaper.ImGui_Separator(ctx)
                    
                    local size_opts = "Small (Inline)\0Large (Stacked)\0"
                    changed, State.tgt_marker_size = reaper.ImGui_Combo(ctx, "Marker Size", State.tgt_marker_size, size_opts)
                    DrawTooltip(ctx, "Choose the size and layout of the target value handle.")
                    
                    changed, State.tgt_marker_indent = reaper.ImGui_SliderDouble(ctx, "Box Indent (px)", State.tgt_marker_indent, 0.0, 50.0, "%.1f")
                    DrawTooltip(ctx, "Shrinks the target box to expose the target line underneath.")
                    
                    changed, State.tgt_marker_bg_alpha = reaper.ImGui_SliderDouble(ctx, "Box Opacity", State.tgt_marker_bg_alpha, 0.0, 1.0, "%.2f")
                    DrawTooltip(ctx, "Transparency of the target handle background.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Separator(ctx)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), VisualSettings.Color_TextDim)
                    reaper.ImGui_Text(ctx, "💡 Tip: Ctrl/Cmd + Click any slider to type a value.")
                    reaper.ImGui_PopStyleColor(ctx)
                    
                    reaper.ImGui_EndTabItem(ctx)
                end
                
                -- TAB 5: Shortcuts
                if reaper.ImGui_BeginTabItem(ctx, "Shortcuts") then
                    reaper.ImGui_Text(ctx, "Keyboard Shortcuts")
                    reaper.ImGui_Separator(ctx)
                    
                    reaper.ImGui_Text(ctx, "R : Reset infinite and rolling meters.")
                    reaper.ImGui_Text(ctx, "C : Clear clip log and reset meters.")
                    reaper.ImGui_Text(ctx, "B : Toggle Stereo Balance visibility.")
                    reaper.ImGui_Text(ctx, "M : Switch Meter Scale Mode (Linear/Mixer).")
                    reaper.ImGui_Text(ctx, "L : Lock/Unlock current track.")
                    
                    reaper.ImGui_Dummy(ctx, 0, 10)
                    reaper.ImGui_Text(ctx, "Mouse Shortcuts")
                    reaper.ImGui_Separator(ctx)
                    reaper.ImGui_Text(ctx, "Click Meter : Enable and set target marker.")
                    reaper.ImGui_Text(ctx, "Click Infinite Box (∞) : Reset infinite peak/rms.")
                    reaper.ImGui_Text(ctx, "Click Rolling Box (↻) : Reset rolling peak/rms.")
                    reaper.ImGui_Text(ctx, "Ctrl/Cmd + Click Slider : Type exact value manually.")
                    
                    reaper.ImGui_EndTabItem(ctx)
                end
                
                reaper.ImGui_EndTabBar(ctx)
            end
        end
        
        reaper.ImGui_End(ctx) 
        reaper.ImGui_PopFont(ctx) 
        reaper.ImGui_PopStyleVar(ctx, 1) 
        reaper.ImGui_PopStyleColor(ctx, num_style_colors)
        
        if not set_open then State.show_settings = false end
    end

    if open then
        reaper.defer(loop)
    end
end

function main()
  reaper.defer(loop)
end

main()