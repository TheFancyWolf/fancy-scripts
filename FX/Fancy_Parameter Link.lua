-- @description Fancy Parameter Link
-- @author Fancy Scripts
-- @version 4.1.0
-- @changelog
--   + Migrated to shared _lib/ modules (theme, json, utils)
-- @about
--   Links FX parameters between tracks: Follow or Inverse with adjustable strength.
--   Features: shared pickers for all workflows, quick single-param add,
--   auto group-scan for same plugin, global presets (save from active links,
--   apply to create links instantly), live inspector, and settings modal.
--   Requirements: ReaImGui extension (install via ReaPack)
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
    "Fancy Parameter Link -- Missing ReaImGui", 0)
  return
end

-------------------------------------------------------------------------------
-- 2. SHARED LIBRARY BOOTSTRAP
-------------------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")
local JSON  = require("json")

-------------------------------------------------------------------------------
-- 3. STATE & CONFIGURATION
-------------------------------------------------------------------------------
local ctx
local font_brand_bold
local font_brand_reg
local links  = {}   -- active links
local paused = false
local lsrc   = {}   -- last known source normalized values

-- Link selection state (for preset save flow)
local link_sel          = {}   -- set of selected link indices: link_sel[i] = true
local last_clicked_link = 0    -- for shift-click range selection
local save_preset_popup = false
local save_preset_name  = ""

-- Status message (temporary toast in Active Links header)
local preset_status_msg  = ""
local preset_status_time = 0

-- Settings & Preferences
local SETTINGS = {
  default_mode     = "smart", -- "smart", "inverse", "follow"
  default_strength = 1.0,     -- 0.0 to 1.0
  auto_touch_sync  = false,   -- auto-populate pickers on touch
  row_height       = 24,      -- row height in active links table
}

-- UI Layout Constants
local UI = {
  win_w       = 1200,
  win_h       = 820,
  btn_h       = 26,
  btn_info_w  = 48,
  btn_sett_w  = 72,
  indent_w    = 28,
  chk_col_w   = 22,
  val_col_w   = 150,
  mode_col_w  = 74,
  str_col_w   = 85,
  del_col_w   = 28,
}

-- Modal Dialog State
local show_info_modal     = false
local show_settings_modal = false
local show_preset_modal   = false
local new_preset_name     = ""

-- Track GUID cache with project state tracking
local _gc, _gn, _g_state = {}, -1, -1
local function _refresh_gc()
  local n = reaper.CountTracks(0)
  local state = reaper.GetProjectStateChangeCount(0)
  if n == _gn and state == _g_state then return end
  _gc, _gn, _g_state = {}, n, state
  for j = 0, n - 1 do
    local tr = reaper.GetTrack(0, j)
    _gc[reaper.GetTrackGUID(tr)] = tr
  end
end

local function tr_by_guid(g)
  _refresh_gc()
  return _gc[g]
end

-- Shared track list cache with project state tracking
local _tlist_n, _tlist_state, _tlist = -1, -1, nil
local function get_tlist()
  local n = reaper.CountTracks(0)
  local state = reaper.GetProjectStateChangeCount(0)
  if n ~= _tlist_n or state ~= _tlist_state then
    _tlist_n, _tlist_state, _tlist = n, state, nil
  end
  if not _tlist then
    _tlist = {}
    for j = 0, n - 1 do
      local tr = reaper.GetTrack(0, j)
      local _, nm = reaper.GetTrackName(tr)
      _tlist[#_tlist + 1] = {
        track = tr,
        name  = nm,
        guid  = reaper.GetTrackGUID(tr),
      }
    end
  end
  return _tlist
end

-- S: Shared source/target pickers
local S = {
  src_ti = 0, src_fi = 0, src_fxs = {}, src_params = {},
  dst_ti = 0, dst_fi = 0, dst_fxs = {}, dst_params = {},
}

-- M: Scan & Match state
local M = {
  groups  = {},
  scanned = false,
  filter  = "",
}

-- P: Presets state
local P = {
  list = {},
  sel  = 0,
}

-- Forward declarations for functions defined later
local use_last_touched_builder
local save_links

-- LT: Last Touched live display
local LT = { track = "", fx = "", param = "", norm = 0, tr = nil, fxi = 0, pi = 0 }
local _prev_lt_key = ""
local function poll_last_touched()
  local ok, trnum, fxnum, paramnum = reaper.GetLastTouchedFX()
  if not ok then
    LT.track = ""
    LT.tr = nil
    return
  end
  local real_fxi = fxnum & 0xFFFFFF
  local tr = (trnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, trnum - 1)
  if not tr then
    LT.track = ""
    LT.tr = nil
    return
  end
  local _, trname = reaper.GetTrackName(tr)
  local _, fxname = reaper.TrackFX_GetFXName(tr, real_fxi, "")
  local _, pname  = reaper.TrackFX_GetParamName(tr, real_fxi, paramnum, "")
  LT.track = trname
  LT.fx    = fxname:match("^%a+3?:%s*(.+)$") or fxname
  LT.param = pname
  LT.norm  = reaper.TrackFX_GetParamNormalized(tr, real_fxi, paramnum)
  LT.tr    = tr
  LT.fxi   = real_fxi
  LT.pi    = paramnum

  local cur_key = tostring(trnum) .. "_" .. tostring(real_fxi) .. "_" .. tostring(paramnum)
  if SETTINGS.auto_touch_sync and cur_key ~= _prev_lt_key and use_last_touched_builder then
    _prev_lt_key = cur_key
    use_last_touched_builder(true)
  end
end

-------------------------------------------------------------------------------
-- 4. HELPERS
-------------------------------------------------------------------------------
local function make_link(d)
  return {
    label      = d.label or (tostring(d.src_name or "?") .. "/" .. tostring(d.src_pname or "?") .. " -> " .. tostring(d.dst_name or "?") .. "/" .. tostring(d.dst_pname or "?")),
    src_guid   = d.src_guid or "",
    src_name   = d.src_name or "?",
    src_fxi    = d.src_fxi or 0,
    src_fxname = d.src_fxname or "?",
    src_pi     = d.src_pi or 0,
    src_pname  = d.src_pname or "?",
    dst_guid   = d.dst_guid or "",
    dst_name   = d.dst_name or "?",
    dst_fxi    = d.dst_fxi or 0,
    dst_fxname = d.dst_fxname or "?",
    dst_pi     = d.dst_pi or 0,
    dst_pname  = d.dst_pname or "?",
    mode       = d.mode or "inverse",
    strength   = tonumber(d.strength) or 1.0,
    link_paused = d.link_paused or false,
  }
end

local function count_checked_params()
  local count = 0
  for _, grp in ipairs(M.groups) do
    for _, item in ipairs(grp.params) do
      if item.checked then
        count = count + 1
      end
    end
  end
  return count
end

local function fx_list(tr)
  local t = {}
  for j = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, nm = reaper.TrackFX_GetFXName(tr, j, "")
    t[#t + 1] = { idx = j, name = nm:match("^%a+3?:%s*(.+)$") or nm }
  end
  return t
end

local function param_list(tr, fxi)
  local t = {}
  for j = 0, reaper.TrackFX_GetNumParams(tr, fxi) - 1 do
    local _, nm = reaper.TrackFX_GetParamName(tr, fxi, j, "")
    t[#t + 1] = { idx = j, name = nm }
  end
  return t
end

local function fmt_val(tr, fxi, pi, norm)
  if not tr then return "?" end
  local ok, s = reaper.TrackFX_FormatParamValueNormalized(tr, fxi, pi, norm, "")
  if ok and s and s ~= "" then
    local trimmed = s:match("^%s*(.-)%s*$")
    return (trimmed and trimmed ~= "") and trimmed or s
  end
  return string.format("%.3f", norm)
end

local INVERSE_KW = { "gain", "level", "volume", "vol", "output", "wet", "dry", "boost", "cut" }
local function default_mode(pname)
  if SETTINGS.default_mode == "inverse" then return "inverse" end
  if SETTINGS.default_mode == "follow"  then return "follow" end
  local lo = pname:lower()
  for _, kw in ipairs(INVERSE_KW) do
    if lo:find(kw, 1, true) then return "inverse" end
  end
  return "follow"
end

-- Natural sort: "Band 2" < "Band 10"
local function natural_less(a, b)
  local function chunks(s)
    local t = {}
    for num, str in s:gmatch("(%d*)(%D*)") do
      if num ~= "" then t[#t + 1] = { n = tonumber(num) } end
      if str ~= "" then t[#t + 1] = { s = str } end
    end
    return t
  end
  local ca, cb = chunks(a), chunks(b)
  for i = 1, math.min(#ca, #cb) do
    local ai, bi = ca[i], cb[i]
    if ai.n and bi.n then
      if ai.n ~= bi.n then return ai.n < bi.n end
    elseif ai.s and bi.s then
      if ai.s ~= bi.s then return ai.s < bi.s end
    else
      return ai.s ~= nil
    end
  end
  return #ca < #cb
end

-- Cross-platform browser URL opener
local function open_url(url)
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(url)
  else
    local os_name = reaper.GetOS()
    if os_name:match("OSX") or os_name:match("macOS") or os_name:match("Other") then
      os.execute('open "' .. url .. '"')
    elseif os_name:match("Win") then
      os.execute('start "" "' .. url .. '"')
    else
      os.execute('xdg-open "' .. url .. '"')
    end
  end
end

-- Detect group prefix: "Band 1 Dynamic Range" -> "Band 1", "Dynamic Range"
local function get_group_prefix(pname)
  local prefix = pname:match("^(.-%d+)%s+")
  if prefix then return prefix, pname:sub(#prefix + 2) end
  local first, rest = pname:match("^(%S+)%s+(.*)")
  if first then return first, rest end
  return "(General)", pname
end

local function build_groups(matched)
  local group_map, group_order = {}, {}
  for _, item in ipairs(matched) do
    local grp = get_group_prefix(item.src_p.name)
    if not group_map[grp] then
      group_map[grp] = { name = grp, open = true, params = {} }
      group_order[#group_order + 1] = grp
    end
    group_map[grp].params[#group_map[grp].params + 1] = item
  end
  local result, gen_items = {}, {}
  for _, grp in ipairs(group_order) do
    local g = group_map[grp]
    if #g.params == 1 and grp ~= "(General)" then
      gen_items[#gen_items + 1] = g.params[1]
    else
      result[#result + 1] = g
    end
  end
  if #gen_items > 0 then
    local gen = group_map["(General)"]
    if gen then
      for _, item in ipairs(gen_items) do gen.params[#gen.params + 1] = item end
    else
      result[#result + 1] = { name = "(General)", open = true, params = gen_items }
    end
  end
  table.sort(result, function(a, b) return natural_less(a.name, b.name) end)
  return result
end

-- Scan using shared S pickers
local function do_scan()
  local tlist = get_tlist()
  if S.src_ti == 0 or S.dst_ti == 0 or S.src_fi == 0 or S.dst_fi == 0 then return end
  local src_tr = tlist[S.src_ti].track
  local dst_tr = tlist[S.dst_ti].track
  local src_fxi = S.src_fxs[S.src_fi].idx
  local dst_fxi = S.dst_fxs[S.dst_fi].idx
  local sparams = param_list(src_tr, src_fxi)
  local dparams = param_list(dst_tr, dst_fxi)
  local dst_map = {}
  for _, p in ipairs(dparams) do dst_map[p.name] = p end
  local matched = {}
  for _, sp in ipairs(sparams) do
    local dp = dst_map[sp.name]
    if dp then
      matched[#matched + 1] = {
        src_p    = sp,
        dst_p    = dp,
        checked  = false,
        mode     = default_mode(sp.name),
        strength = (SETTINGS.default_strength or 1.0),
      }
    end
  end
  M.groups = build_groups(matched)
  M.scanned = true
end

-- Create links from scan results using S pickers
local function create_links_from_match()
  local tlist = get_tlist()
  local st = tlist[S.src_ti]
  local dt = tlist[S.dst_ti]
  local sf = S.src_fxs[S.src_fi]
  local df = S.dst_fxs[S.dst_fi]
  for _, grp in ipairs(M.groups) do
    for _, item in ipairs(grp.params) do
      if item.checked then
        links[#links + 1] = make_link({
          label      = st.name .. "/" .. item.src_p.name .. " -> " .. dt.name .. "/" .. item.dst_p.name,
          src_guid   = st.guid,  src_name   = st.name,
          src_fxi    = sf.idx,   src_fxname = sf.name,
          src_pi     = item.src_p.idx, src_pname = item.src_p.name,
          dst_guid   = dt.guid,  dst_name   = dt.name,
          dst_fxi    = df.idx,   dst_fxname = df.name,
          dst_pi     = item.dst_p.idx, dst_pname = item.dst_p.name,
          mode       = item.mode, strength  = item.strength,
        })
        lsrc[#links] = nil
      end
    end
  end
end

-- Find FX instances on a track by cleaned plugin name
local function find_fx_by_name(track, plugin_name)
  if not track or not plugin_name or plugin_name == "" then return {} end
  local results = {}
  for j = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, nm = reaper.TrackFX_GetFXName(track, j, "")
    local clean = nm:match("^%a+3?:%s*(.+)$") or nm
    if clean == plugin_name then
      results[#results + 1] = { idx = j, name = clean }
    end
  end
  return results
end

-- Save preset from selected active links (unified save flow)
local function save_preset_from_links(name)
  if name == "" then return false end
  -- Collect selected link indices
  local sel_indices = {}
  for i = 1, #links do
    if link_sel[i] then sel_indices[#sel_indices + 1] = i end
  end
  if #sel_indices == 0 then return false end
  -- Validate all selected links share the same plugin
  local plugin_name_val = links[sel_indices[1]].src_fxname
  for _, idx in ipairs(sel_indices) do
    if links[idx].src_fxname ~= plugin_name_val then
      reaper.ShowMessageBox(
        "Select links from a single plugin to save as a preset.\n\n"
        .. "Found: '" .. plugin_name_val .. "' and '" .. links[idx].src_fxname .. "'",
        "Preset Save", 0)
      return false
    end
  end
  -- Build params array (deduplicate by src_pname|dst_pname, last wins)
  local seen, params = {}, {}
  for _, idx in ipairs(sel_indices) do
    local lk = links[idx]
    local key = lk.src_pname .. "|" .. lk.dst_pname
    if not seen[key] then
      seen[key] = true
      params[#params + 1] = {
        src_pname = lk.src_pname,
        dst_pname = lk.dst_pname,
        mode      = lk.mode,
        strength  = lk.strength,
      }
    end
  end
  if #params == 0 then return false end
  P.list[#P.list + 1] = {
    name        = name,
    plugin_name = plugin_name_val,
    params      = params,
  }
  return true
end

-- Apply preset directly: find FX on tracks, resolve params, create links
local function apply_preset_direct(preset)
  if not preset or not preset.params or not preset.plugin_name then return false end
  -- Resolve tracks: use pickers if set, else REAPER selection
  local tlist = get_tlist()
  local src_entry, dst_entry
  if S.src_ti > 0 and S.src_ti <= #tlist then
    src_entry = tlist[S.src_ti]
  end
  if S.dst_ti > 0 and S.dst_ti <= #tlist then
    dst_entry = tlist[S.dst_ti]
  end
  -- Fall back to REAPER selected tracks
  if not src_entry or not dst_entry then
    local n_sel = reaper.CountSelectedTracks(0)
    if n_sel >= 2 then
      local t1 = reaper.GetSelectedTrack(0, 0)
      local t2 = reaper.GetSelectedTrack(0, 1)
      if not src_entry and t1 then
        local _, nm = reaper.GetTrackName(t1)
        src_entry = { track = t1, name = nm, guid = reaper.GetTrackGUID(t1) }
      end
      if not dst_entry and t2 then
        local _, nm = reaper.GetTrackName(t2)
        dst_entry = { track = t2, name = nm, guid = reaper.GetTrackGUID(t2) }
      end
    end
  end
  if not src_entry or not dst_entry then
    reaper.ShowMessageBox(
      "Please select Source and Target tracks (via the pickers or by selecting 2 tracks in REAPER).",
      "Preset Apply", 0)
    return false
  end
  -- Find matching FX on each track (use first instance)
  local src_fxs = find_fx_by_name(src_entry.track, preset.plugin_name)
  local dst_fxs = find_fx_by_name(dst_entry.track, preset.plugin_name)
  if #src_fxs == 0 then
    reaper.ShowMessageBox(
      "Plugin '" .. preset.plugin_name .. "' not found on Source track '" .. src_entry.name .. "'.",
      "Preset Apply", 0)
    return false
  end
  if #dst_fxs == 0 then
    reaper.ShowMessageBox(
      "Plugin '" .. preset.plugin_name .. "' not found on Target track '" .. dst_entry.name .. "'.",
      "Preset Apply", 0)
    return false
  end
  local src_fx = src_fxs[1]
  local dst_fx = dst_fxs[1]
  -- Get parameter lists and build lookup maps
  local sparams = param_list(src_entry.track, src_fx.idx)
  local dparams = param_list(dst_entry.track, dst_fx.idx)
  local src_map, dst_map = {}, {}
  for _, p in ipairs(sparams) do src_map[p.name] = p end
  for _, p in ipairs(dparams) do dst_map[p.name] = p end
  -- Create links for each matched parameter pair (skip duplicates)
  local existing = {}
  for _, lk in ipairs(links) do
    existing[lk.src_guid .. "|" .. lk.src_fxi .. "|" .. lk.src_pi .. "|" .. lk.dst_guid .. "|" .. lk.dst_fxi .. "|" .. lk.dst_pi] = true
  end
  local created, skipped, total = 0, 0, #preset.params
  reaper.Undo_BeginBlock()
  for _, tp in ipairs(preset.params) do
    local sp = src_map[tp.src_pname]
    local dp = dst_map[tp.dst_pname]
    if sp and dp then
      local key = src_entry.guid .. "|" .. src_fx.idx .. "|" .. sp.idx .. "|" .. dst_entry.guid .. "|" .. dst_fx.idx .. "|" .. dp.idx
      if existing[key] then
        skipped = skipped + 1
      else
        links[#links + 1] = make_link({
          src_guid   = src_entry.guid, src_name   = src_entry.name,
          src_fxi    = src_fx.idx,     src_fxname = src_fx.name,
          src_pi     = sp.idx,         src_pname  = sp.name,
          dst_guid   = dst_entry.guid, dst_name   = dst_entry.name,
          dst_fxi    = dst_fx.idx,     dst_fxname = dst_fx.name,
          dst_pi     = dp.idx,         dst_pname  = dp.name,
          mode       = tp.mode,        strength   = tp.strength,
        })
        lsrc[#links] = nil
        existing[key] = true
        created = created + 1
      end
    end
  end
  if created > 0 then save_links() end
  reaper.Undo_EndBlock("Apply Preset: " .. (preset.name or "?"), -1)
  -- Status message
  if skipped == total then
    preset_status_msg = string.format("Preset '%s': all links already exist", preset.name)
  elseif created == total then
    preset_status_msg = string.format("Preset '%s': %d links created ✓", preset.name, created)
  elseif created > 0 then
    local parts = {}
    parts[#parts + 1] = string.format("%d created", created)
    if skipped > 0 then parts[#parts + 1] = string.format("%d already existed", skipped) end
    local missing = total - created - skipped
    if missing > 0 then parts[#parts + 1] = string.format("%d not found", missing) end
    preset_status_msg = string.format("Preset '%s': %s", preset.name, table.concat(parts, ", "))
  else
    preset_status_msg = string.format("Preset '%s': no matching params found", preset.name)
  end
  preset_status_time = reaper.time_precise()
  return created > 0
end


-- Fill shared pickers & builder state from Last Touched
use_last_touched_builder = function(silent)
  local ok, trnum, fxnum, paramnum = reaper.GetLastTouchedFX()
  if not ok then
    if not silent then
      reaper.ShowMessageBox("No parameter touched yet.\nTouch a plugin knob/fader first.", "Last Touched", 0)
    end
    return
  end
  local real_fxi = fxnum & 0xFFFFFF
  local tr = (trnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, trnum - 1)
  if not tr then return end
  local tguid = reaper.GetTrackGUID(tr)
  local tlist = get_tlist()
  local found_ti = 0
  for j, t in ipairs(tlist) do
    if t.guid == tguid then found_ti = j; break end
  end
  if found_ti == 0 then return end

  -- If Source Track is not set or if user touched a different track, set Source Track
  S.src_ti = found_ti
  local tr_src = tlist[S.src_ti].track
  S.src_fxs = fx_list(tr_src)

  local found_fi = 0
  for j, f in ipairs(S.src_fxs) do
    if f.idx == real_fxi then found_fi = j; break end
  end
  if found_fi == 0 then return end
  S.src_fi = found_fi
  S.src_params = param_list(tr_src, real_fxi)

  -- Match on Target Track if target track is selected
  if S.dst_ti > 0 and tlist[S.dst_ti] then
    local tr_dst = tlist[S.dst_ti].track
    S.dst_fxs = fx_list(tr_dst)
    S.dst_fi = 0
    for j, f in ipairs(S.dst_fxs) do
      if f.name == S.src_fxs[found_fi].name then
        S.dst_fi = j
        break
      end
    end
    if S.dst_fi > 0 then
      S.dst_params = param_list(tr_dst, S.dst_fxs[S.dst_fi].idx)
    else
      S.dst_params = {}
    end
  end

  -- Trigger scan if both plugins ready
  if S.src_fi > 0 and S.dst_fi > 0 then
    do_scan()
    -- Check the touched parameter and force its group open
    local _, pname = reaper.TrackFX_GetParamName(tr_src, real_fxi, paramnum, "")
    for _, grp in ipairs(M.groups) do
      for _, item in ipairs(grp.params) do
        if item.src_p.idx == paramnum or item.src_p.name == pname then
          item.checked   = true
          grp.force_open = true
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- 5. PERSISTENCE & STORAGE
-------------------------------------------------------------------------------
local function sav_path()
  local _, f = reaper.EnumProjects(-1, "")
  if not f or f == "" then
    return reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/_fancy_ipl_noproject.json"
  end
  return (f:match("^(.+)%.rpp$") or f) .. ".fancy_ipl.json"
end

local PRESET_PATH        = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/_fancy_ipl_presets.json"
local LEGACY_TMPL_PATH   = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/_fancy_ipl_templates.json"
local SETTINGS_PATH      = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/_fancy_ipl_settings.json"

local function write_file(path, content)
  local ok, fh = pcall(io.open, path, "w")
  if ok and fh then
    fh:write(content)
    fh:close()
    return true
  end
  return false
end

local function read_file(path)
  local ok, fh = pcall(io.open, path, "r")
  if ok and fh then
    local content = fh:read("*all")
    fh:close()
    return content
  end
  return nil
end

local function serialize_links(src_links)
  local data = {}
  for _, lk in ipairs(src_links) do
    data[#data + 1] = {
      label      = lk.label or "",
      src_guid   = lk.src_guid or "",
      src_name   = lk.src_name or "?",
      src_fxi    = lk.src_fxi or 0,
      src_fxname = lk.src_fxname or "?",
      src_pi     = lk.src_pi or 0,
      src_pname  = lk.src_pname or "?",
      dst_guid   = lk.dst_guid or "",
      dst_name   = lk.dst_name or "?",
      dst_fxi    = lk.dst_fxi or 0,
      dst_fxname = lk.dst_fxname or "?",
      dst_pi     = lk.dst_pi or 0,
      dst_pname  = lk.dst_pname or "?",
      mode       = lk.mode or "inverse",
      strength   = lk.strength or 1.0,
      link_paused = lk.link_paused or false,
    }
  end
  return JSON.encode(data)
end

save_links = function()
  return write_file(sav_path(), serialize_links(links))
end

local function load_links()
  local raw = read_file(sav_path())
  if not raw then return end
  local ok, data = pcall(JSON.decode, raw)
  if not ok or type(data) ~= "table" then return end
  links = {}
  lsrc  = {}
  for _, d in ipairs(data) do
    if type(d) == "table" then
      links[#links + 1] = make_link(d)
    end
  end
end

local function save_settings()
  write_file(SETTINGS_PATH, JSON.encode(SETTINGS))
end

local function load_settings()
  local raw = read_file(SETTINGS_PATH)
  if not raw then return end
  local ok, data = pcall(JSON.decode, raw)
  if ok and type(data) == "table" then
    if data.default_mode ~= nil     then SETTINGS.default_mode     = data.default_mode end
    if data.default_strength ~= nil then SETTINGS.default_strength = tonumber(data.default_strength) or 1.0 end
    if data.auto_touch_sync ~= nil  then SETTINGS.auto_touch_sync  = data.auto_touch_sync end
    if data.row_height ~= nil       then SETTINGS.row_height       = tonumber(data.row_height) or 24 end
  end
end

local function save_presets()
  write_file(PRESET_PATH, JSON.encode(P.list))
end

local function load_presets()
  local raw = read_file(PRESET_PATH) or read_file(LEGACY_TMPL_PATH)
  if not raw then return end
  local ok, data = pcall(JSON.decode, raw)
  if ok and type(data) == "table" then
    P.list = data
    -- Migrate old plugin_hint -> plugin_name
    local migrated = false
    for _, preset in ipairs(P.list) do
      if not preset.plugin_name and preset.plugin_hint then
        preset.plugin_name = preset.plugin_hint
        preset.plugin_hint = nil
        migrated = true
      end
    end
    if migrated then save_presets() end
  end
end

local function open_config_folder()
  local p = sav_path()
  local dir = p:match("^(.*)[/\\].-$") or p
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(dir)
  else
    reaper.ShowMessageBox("Configuration folder path:\n" .. dir, "Config Location", 0)
  end
end

local function export_links_dialog()
  local default_path = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/fancy_ipl_links_backup.json"
  local ok, filename = reaper.GetUserFileNameForWrite(default_path, "Export Links JSON", "json")
  if ok and filename ~= "" then
    if write_file(filename, serialize_links(links)) then
      reaper.ShowMessageBox(string.format("Links exported successfully (%d links) to:\n%s", #links, filename), "Export Success", 0)
    else
      reaper.ShowMessageBox("Could not open file for writing:\n" .. filename, "Export Error", 0)
    end
  end
end

local function import_links_dialog()
  local default_dir = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/"
  local ok, filename = reaper.GetUserFileNameForRead(default_dir, "Import Links JSON", "json")
  if ok and filename ~= "" then
    local raw = read_file(filename)
    if not raw then
      reaper.ShowMessageBox("Could not open file for reading:\n" .. filename, "Import Error", 0)
      return
    end
    local sok, data = pcall(JSON.decode, raw)
    if not sok or type(data) ~= "table" then
      reaper.ShowMessageBox("Invalid JSON format in file.", "Import Error", 0)
      return
    end
    local added = 0
    for _, d in ipairs(data) do
      if type(d) == "table" and d.src_guid and d.dst_guid then
        links[#links + 1] = make_link(d)
        added = added + 1
      end
    end
    save_links()
    reaper.ShowMessageBox(string.format("Successfully imported %d links!", added), "Import Success", 0)
  end
end

-------------------------------------------------------------------------------
-- 6. LINK ENGINE
-------------------------------------------------------------------------------
local function apply_links()
  if paused or #links == 0 then return end
  for i, lk in ipairs(links) do
    if not lk.link_paused then
    local str = tr_by_guid(lk.src_guid)
    local dtr = tr_by_guid(lk.dst_guid)
    if str and dtr then
      local sv = reaper.TrackFX_GetParamNormalized(str, lk.src_fxi, lk.src_pi)
      if lsrc[i] ~= sv then
        lsrc[i] = sv
        local dir = (lk.mode == "follow") and 1.0 or -1.0
        local st  = lk.strength or 1.0
        local dv  = math.max(0, math.min(1, 0.5 + dir * st * (sv - 0.5)))
        reaper.TrackFX_SetParamNormalized(dtr, lk.dst_fxi, lk.dst_pi, dv)
      end
    end
    end -- link_paused
  end
end

-------------------------------------------------------------------------------
-- 7. COLORS & THEME
-------------------------------------------------------------------------------
local C = Theme.build_palette()


-------------------------------------------------------------------------------
-- 8. SHARED UI HELPERS
-------------------------------------------------------------------------------

-- === Table cell vertical centering helper ===
-- Call before rendering a widget in a table cell to vertically center it.
local function table_vcenter(item_h, row_h)
  if row_h and item_h < row_h then
    local cy = reaper.ImGui_GetCursorPosY(ctx)
    reaper.ImGui_SetCursorPosY(ctx, cy + math.floor((row_h - item_h) * 0.5))
  end
end

-- Progress bar with text centered via DrawList
local function draw_progress_bar_centered(fraction, w, h, col_bar, col_bg, text)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), col_bar)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),       col_bg)
  reaper.ImGui_ProgressBar(ctx, fraction, w, h, "")
  reaper.ImGui_PopStyleColor(ctx, 2)
  if text and text ~= "" then
    local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
    local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
    local tx = rx + math.floor((rx2 - rx - tw) * 0.5)
    local ty = ry + math.floor((ry2 - ry - th) * 0.5)
    reaper.ImGui_DrawList_AddText(dl, tx, ty, 0xFFFFFFFF, text)
  end
end

-- === DrawList Vector Icons ===
-- Each draws a small icon centered at (cx, cy) with the given half-size.

local function icon_play(dl, cx, cy, hs, col)
  -- Right-pointing filled triangle (play)
  local ox = math.floor(cx)
  local oy = math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.5), oy - math.floor(hs),
    ox + math.floor(hs),       oy,
    ox - math.floor(hs * 0.5), oy + math.floor(hs), col)
end

local function icon_pause(dl, cx, cy, hs, col)
  -- Two vertical bars (pause)
  local bw = math.max(1, math.floor(hs * 0.35))
  local gap = math.floor(hs * 0.25)
  local ox, oy = math.floor(cx), math.floor(cy)
  local h = math.floor(hs)
  reaper.ImGui_DrawList_AddRectFilled(dl, ox - gap - bw, oy - h, ox - gap, oy + h, col)
  reaper.ImGui_DrawList_AddRectFilled(dl, ox + gap, oy - h, ox + gap + bw, oy + h, col)
end

local function icon_close(dl, cx, cy, hs, col)
  -- X mark (two crossed lines)
  local th = math.max(1.5, hs * 0.3)
  local s = math.floor(hs * 0.8)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddLine(dl, ox - s, oy - s, ox + s, oy + s, col, th)
  reaper.ImGui_DrawList_AddLine(dl, ox + s, oy - s, ox - s, oy + s, col, th)
end

local function icon_plus(dl, cx, cy, hs, col)
  -- Plus sign (two crossed lines)
  local th = math.max(1.5, hs * 0.35)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddLine(dl, ox - hs, oy, ox + hs, oy, col, th)
  reaper.ImGui_DrawList_AddLine(dl, ox, oy - hs, ox, oy + hs, col, th)
end

local function icon_info(dl, cx, cy, hs, col)
  -- 1:1 match with SVG viewBox="0 0 24 24" (center at 12, 12)
  local s = hs / 10.0
  local stroke_w = math.max(1.0, 1.6 * s)

  -- 1. Outer circle: cx=12, cy=12, r=10
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, hs, col, 0, stroke_w)

  -- 2. Top dot: cx=12, cy=7.5, r=1.2
  local dot_r = math.max(0.8, 1.2 * s)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy - 4.2 * s, dot_r, col)

  -- 3. Vertical stem: cx=12, y=11.5..16.5 (exact symmetric rounded rect)
  local stem_hw = math.max(0.6, 1.0 * s)
  local stem_top = cy - 0.5 * s
  local stem_bot = cy + 4.5 * s
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - stem_hw, stem_top, cx + stem_hw, stem_bot, col, stem_hw)
end

local function icon_tri_right(dl, cx, cy, hs, col)
  -- Right-pointing triangle (▸)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.4), oy - math.floor(hs * 0.7),
    ox + math.floor(hs * 0.6), oy,
    ox - math.floor(hs * 0.4), oy + math.floor(hs * 0.7), col)
end

local function icon_tri_down(dl, cx, cy, hs, col)
  -- Down-pointing triangle (▾ expand)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.7), oy - math.floor(hs * 0.4),
    ox + math.floor(hs * 0.7), oy - math.floor(hs * 0.4),
    ox, oy + math.floor(hs * 0.6), col)
end

local function icon_tri_up(dl, cx, cy, hs, col)
  -- Up-pointing triangle (▴ collapse)
  local ox, oy = math.floor(cx), math.floor(cy)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    ox - math.floor(hs * 0.7), oy + math.floor(hs * 0.4),
    ox + math.floor(hs * 0.7), oy + math.floor(hs * 0.4),
    ox, oy - math.floor(hs * 0.6), col)
end

-- Tooltip with automatic text wrapping at max_w (default 300px)
local function show_wrapped_tooltip(text, max_w)
  max_w = max_w or 300
  if reaper.ImGui_BeginTooltip(ctx) then
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + max_w)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_EndTooltip(ctx)
  end
end

-- Icon button: invisible button + DrawList icon. Returns true if clicked.
local function icon_btn(id, icon_fn, btn_w, btn_h, icon_size, col, tooltip)
  local pressed = reaper.ImGui_InvisibleButton(ctx, id, btn_w, btn_h)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx = (rx + rx2) * 0.5
  local cy = (ry + ry2) * 0.5
  local hs = (icon_size or math.min(btn_w, btn_h) * 0.35) * 0.5
  local hover = reaper.ImGui_IsItemHovered(ctx)
  local draw_col = hover and (col + 0x40404000) or col
  icon_fn(dl, cx, cy, hs, draw_col)
  if tooltip and hover then
    show_wrapped_tooltip(tooltip, 300)
  end
  return pressed
end

-- Icon button with background color (for styled buttons)
local function icon_btn_colored(id, icon_fn, btn_w, btn_h, icon_size, icon_col, bg, bg_h, bg_a, tooltip)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_a)
  local pressed = reaper.ImGui_Button(ctx, "##" .. id, btn_w, btn_h)
  reaper.ImGui_PopStyleColor(ctx, 3)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local cx = (rx + rx2) * 0.5
  local cy = (ry + ry2) * 0.5
  local hs = (icon_size or math.min(btn_w, btn_h) * 0.3) * 0.5
  icon_fn(dl, cx, cy, hs, icon_col)
  if tooltip and reaper.ImGui_IsItemHovered(ctx) then
    show_wrapped_tooltip(tooltip, 300)
  end
  return pressed
end
local function draw_brand_icon(size, target_h)
  size = size or 24
  target_h = target_h or size
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local y_off = math.max(0, (target_h - size) * 0.5)
  local s = size / 240.0
  local dy = y + y_off

  -- Background tile (230x230, rx=50)
  local bx1, by1 = x + 5.0 * s, dy + 5.0 * s
  local bx2, by2 = x + 235.0 * s, dy + 235.0 * s
  local r_bg     = 50.0 * s
  local stroke_w = math.max(1.0, 10.0 * s)
  reaper.ImGui_DrawList_AddRectFilled(dl, bx1, by1, bx2, by2, C.card, r_bg)
  reaper.ImGui_DrawList_AddRect(dl, bx1, by1, bx2, by2, C.sep, r_bg, 0, stroke_w)

  -- Link bezier curve (M79,139 C79,101 161,139 161,101)
  local p1_x, p1_y = x + 79.0 * s, dy + 139.0 * s
  local c1_x, c1_y = x + 79.0 * s, dy + 101.0 * s
  local c2_x, c2_y = x + 161.0 * s, dy + 139.0 * s
  local p2_x, p2_y = x + 161.0 * s, dy + 101.0 * s
  local curve_w    = math.max(1.2, 15.0 * s)
  reaper.ImGui_DrawList_AddBezierCubic(dl, p1_x, p1_y, c1_x, c1_y, c2_x, c2_y, p2_x, p2_y, C.accent, curve_w)

  -- Source node (Green: cx=79, cy=169, r=30)
  reaper.ImGui_DrawList_AddCircleFilled(dl, x + 79.0 * s, dy + 169.0 * s, 30.0 * s, C.green)

  -- Target node (Yellow: cx=161, cy=71, r=30)
  reaper.ImGui_DrawList_AddCircleFilled(dl, x + 161.0 * s, dy + 71.0 * s, 30.0 * s, C.yellow)

  -- Advance cursor past the icon with target_h
  reaper.ImGui_Dummy(ctx, size, target_h)
end

local function push_font(font, sz)
  if not font or not reaper.ImGui_PushFont then return false end
  local ok = pcall(reaper.ImGui_PushFont, ctx, font, sz or 14.0)
  if not ok then
    ok = pcall(reaper.ImGui_PushFont, ctx, font)
  end
  return ok
end

local function pop_font(pushed)
  if pushed and reaper.ImGui_PopFont then
    pcall(reaper.ImGui_PopFont, ctx)
  end
end

local function draw_combo(id, items, sel)
  local new = sel
  local preview = (sel > 0 and items[sel]) and items[sel].name or "-- select --"
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (sel > 0) and 0xFFFFFFFF or C.text_dim)
  if reaper.ImGui_BeginCombo(ctx, id, preview) then
    reaper.ImGui_PopStyleColor(ctx, 1)
    for j, item in ipairs(items) do
      local is_sel = (j == sel)
      if reaper.ImGui_Selectable(ctx, item.name .. "##" .. id .. j, is_sel) then
        new = j
      end
      if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  else
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  return new
end

local function field_label(txt, col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col or C.text_dim)
  reaper.ImGui_Text(ctx, txt)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

local function mode_btn(id, mode, h)
  local is_fol = (mode == "follow")
  local bg   = is_fol and C.green_d or C.accent_d
  local bg_h = is_fol and C.green_h or C.accent_h
  local bg_a = is_fol and C.green   or C.accent
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg_a)
  local clicked = reaper.ImGui_Button(ctx, "##" .. id, -1, h or 0)
  reaper.ImGui_PopStyleColor(ctx, 3)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
  local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
  local text = is_fol and "Follow" or "Inverse"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local tx = rx + math.floor((rx2 - rx - tw) * 0.5)
  local ty = ry + math.floor((ry2 - ry - th) * 0.5)
  local text_col = is_fol and 0xD0FFD0FF or 0xD0C8FFFF
  reaper.ImGui_DrawList_AddText(dl, tx, ty, text_col, text)
  return clicked
end

-- Styled section divider: colored label + separator line
local function section_divider(label, col, tooltip)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col or C.text_dim)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 1)
  if tooltip then
    reaper.ImGui_SameLine(ctx, 0, 6)
    if icon_btn("info_" .. label, icon_info, 16, 16, 12, C.text_dim, tooltip) then end
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), (col and (col & 0xFFFFFF99) or C.sep))
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
end

-------------------------------------------------------------------------------
-- 9. SOURCE & TARGET PICKERS (Source Track, Target Track, Shared Plugin)
-------------------------------------------------------------------------------
local function draw_shared_pickers(tlist)
  -- Row 1: Source Track & Target Track side-by-side
  if reaper.ImGui_BeginTable(ctx, "spk_tr_tbl", 2, reaper.ImGui_TableFlags_None()) then
    reaper.ImGui_TableSetupColumn(ctx, "##str_col", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "##dtr_col", reaper.ImGui_TableColumnFlags_WidthStretch())

    -- Row 0: Labels with exact same baseline
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    field_label("SOURCE TRACK", C.green)

    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    field_label("TARGET TRACK", C.accent)

    -- Row 1: Dropdown combos with exact same vertical position
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local new_sti = draw_combo("##s_tr", tlist, S.src_ti)
    if new_sti ~= S.src_ti then
      S.src_ti = new_sti
      local tr = (S.src_ti > 0) and tlist[S.src_ti].track or nil
      S.src_fxs = tr and fx_list(tr) or {}
      -- Check if current plugin is present on new source track
      local cur_plugin_name = (S.src_fi > 0 and S.src_params and S.src_fxs[S.src_fi]) and S.src_fxs[S.src_fi].name or nil
      S.src_fi = 0
      if cur_plugin_name then
        for j, f in ipairs(S.src_fxs) do
          if f.name == cur_plugin_name then S.src_fi = j; break end
        end
      end
      if S.src_fi > 0 and tr then
        S.src_params = param_list(tr, S.src_fxs[S.src_fi].idx)
      else
        S.src_params = {}
      end
      M.scanned = false
      M.groups  = {}
    end

    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local new_dti = draw_combo("##d_tr", tlist, S.dst_ti)
    if new_dti ~= S.dst_ti then
      S.dst_ti = new_dti
      local tr = (S.dst_ti > 0) and tlist[S.dst_ti].track or nil
      S.dst_fxs = tr and fx_list(tr) or {}
      -- Match plugin with source plugin if source has one selected
      S.dst_fi = 0
      if S.src_fi > 0 and S.src_fxs[S.src_fi] then
        local target_name = S.src_fxs[S.src_fi].name
        for j, f in ipairs(S.dst_fxs) do
          if f.name == target_name then S.dst_fi = j; break end
        end
      end
      if S.dst_fi > 0 and tr then
        S.dst_params = param_list(tr, S.dst_fxs[S.dst_fi].idx)
      else
        S.dst_params = {}
      end
      M.scanned = false
      M.groups  = {}
    end

    reaper.ImGui_EndTable(ctx)
  end

  reaper.ImGui_Spacing(ctx)

  -- Row 2: Shared PLUGIN dropdown (full width)
  field_label("PLUGIN (Shared)")
  reaper.ImGui_SetNextItemWidth(ctx, -1)

  local fx_display_list = (S.src_ti > 0) and S.src_fxs or S.dst_fxs
  local cur_fi = (S.src_ti > 0) and S.src_fi or S.dst_fi
  local new_fi = draw_combo("##shared_fx", fx_display_list, cur_fi)

  if new_fi ~= cur_fi then
    local str = (S.src_ti > 0) and tlist[S.src_ti].track or nil
    local dtr = (S.dst_ti > 0) and tlist[S.dst_ti].track or nil

    if S.src_ti > 0 and fx_display_list[new_fi] then
      S.src_fi = new_fi
      S.src_params = str and param_list(str, S.src_fxs[new_fi].idx) or {}
      local chosen_name = S.src_fxs[new_fi].name

      -- Match on destination track
      S.dst_fi = 0
      if dtr then
        for j, f in ipairs(S.dst_fxs) do
          if f.name == chosen_name then S.dst_fi = j; break end
        end
        S.dst_params = (S.dst_fi > 0) and param_list(dtr, S.dst_fxs[S.dst_fi].idx) or {}
      else
        S.dst_params = {}
      end
    elseif S.dst_ti > 0 and fx_display_list[new_fi] then
      S.dst_fi = new_fi
      S.dst_params = dtr and param_list(dtr, S.dst_fxs[new_fi].idx) or {}
      local chosen_name = S.dst_fxs[new_fi].name

      -- Match on source track
      S.src_fi = 0
      if str then
        for j, f in ipairs(S.src_fxs) do
          if f.name == chosen_name then S.src_fi = j; break end
        end
        S.src_params = (S.src_fi > 0) and param_list(str, S.src_fxs[S.src_fi].idx) or {}
      else
        S.src_params = {}
      end
    end

    M.scanned = false
    M.groups  = {}
  end

  -- Warning if plugin missing on target track
  if S.src_ti > 0 and S.dst_ti > 0 and S.src_fi > 0 and S.dst_fi == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
    reaper.ImGui_Text(ctx, "  * Selected plugin not found on Target Track")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)
end

-------------------------------------------------------------------------------
-- 10. LINK BUILDER (unified: auto-scan + presets)
-------------------------------------------------------------------------------
local function draw_link_builder()
  local plugins_ready = (S.src_fi > 0 and S.dst_fi > 0)

  if not plugins_ready then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    if S.src_ti == 0 or S.dst_ti == 0 then
      reaper.ImGui_TextWrapped(ctx, "Select source and target tracks, then select a plugin above.")
    else
      reaper.ImGui_TextWrapped(ctx, "Select a plugin above.")
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)
    return
  end

  -- Auto-scan whenever plugins are selected and result is stale
  if not M.scanned then do_scan() end

  -- Search filter + Expand/Collapse All + Last Touched button on the SAME LINE
  reaper.ImGui_SetNextItemWidth(ctx, -170)
  local fr, nf = reaper.ImGui_InputTextWithHint(ctx, "##mf", "Search parameters...", M.filter, 256)
  if fr then M.filter = nf end

  -- Expand All (icon)
  reaper.ImGui_SameLine(ctx, 0, 6)
  if icon_btn_colored("exp_all", icon_tri_down, 24, 0, 10, 0xFFFFFFFF, C.card, C.panel, C.accent_d, "Expand All Groups") then
    for _, g in ipairs(M.groups) do g.force_open = true end
  end

  -- Collapse All (icon)
  reaper.ImGui_SameLine(ctx, 0, 4)
  if icon_btn_colored("col_all", icon_tri_up, 24, 0, 10, 0xFFFFFFFF, C.card, C.panel, C.accent_d, "Collapse All Groups") then
    for _, g in ipairs(M.groups) do g.force_open = false end
  end

  -- Last Touched button
  reaper.ImGui_SameLine(ctx, 0, 6)
  if reaper.ImGui_Button(ctx, "Last Touched##lb_lt", 100, 0) then
    use_last_touched_builder()
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    poll_last_touched()
    if reaper.ImGui_BeginTooltip(ctx) then
      reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + 300)
      if LT.track ~= "" then
        local lt_val = LT.tr and fmt_val(LT.tr, LT.fxi, LT.pi, LT.norm) or "?"
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, "Last Touched:")
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, LT.track)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, "/")
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 4)

        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, LT.fx)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, "/")
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 4)

        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, LT.param)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, "=")
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 4)

        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, lt_val)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, "Click to select parameter")
        reaper.ImGui_PopStyleColor(ctx, 1)
      else
        reaper.ImGui_Text(ctx, "Touch a plugin parameter, then click to use it")
      end
      reaper.ImGui_PopTextWrapPos(ctx)
      reaper.ImGui_EndTooltip(ctx)
    end
  end

  reaper.ImGui_Spacing(ctx)

  -- Scrollable param list
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local list_h = math.max(80, avail_h - 45)

  if reaper.ImGui_BeginChild(ctx, "lb_list", 0, list_h) then
    -- Matched params from auto-scan
    if #M.groups == 0 then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
      reaper.ImGui_Text(ctx, "  No matching parameters found.")
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local flo = M.filter:lower()
      for gi, grp in ipairs(M.groups) do
        -- Check if any param in this group matches the search filter
        local grp_has_match = false
        for _, item in ipairs(grp.params) do
          local dn = item.src_p.name
          if grp.name ~= "(General)" then
            local w = dn:sub(#grp.name + 2)
            if w ~= "" then dn = w end
          end
          if flo == "" or grp.name:lower():find(flo, 1, true) or dn:lower():find(flo, 1, true) then
            grp_has_match = true
            break
          end
        end

        if grp_has_match then
          -- Group select-all checkbox
          local all_chk = true
          for _, item in ipairs(grp.params) do
            if not item.checked then all_chk = false; break end
          end
          local crv, nc = reaper.ImGui_Checkbox(ctx, "##gc" .. gi, all_chk)
          if crv then
            for _, item in ipairs(grp.params) do item.checked = nc end
          end
          reaper.ImGui_SameLine(ctx, 0, 6)

          -- Collapsing Header
          if flo ~= "" then
            reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Always())
          elseif grp.force_open ~= nil then
            reaper.ImGui_SetNextItemOpen(ctx, grp.force_open, reaper.ImGui_Cond_Always())
            grp.force_open = nil
          end

          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x8B70FA22)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x8B70FA55)
          local hdr_label = string.format("%s  (%d)##gh%d", grp.name, #grp.params, gi)
          local is_open = reaper.ImGui_CollapsingHeader(ctx, hdr_label)
          reaper.ImGui_PopStyleColor(ctx, 2)

          if is_open then
            reaper.ImGui_Indent(ctx, UI.indent_w)
            if reaper.ImGui_BeginTable(ctx, "ptbl_" .. gi, 2, reaper.ImGui_TableFlags_None()) then
              reaper.ImGui_TableSetupColumn(ctx, "##chk",   reaper.ImGui_TableColumnFlags_WidthFixed(), UI.chk_col_w)
              reaper.ImGui_TableSetupColumn(ctx, "##pname", reaper.ImGui_TableColumnFlags_WidthStretch())

              for pi, item in ipairs(grp.params) do
                local disp = item.src_p.name
                if grp.name ~= "(General)" then
                  local w = disp:sub(#grp.name + 2)
                  if w ~= "" then disp = w end
                end
                local matches_search = (flo == "") or grp.name:lower():find(flo, 1, true) or disp:lower():find(flo, 1, true)
                if matches_search then
                  reaper.ImGui_TableNextRow(ctx, 0, 22)

                  -- Col 0: Checkbox
                  reaper.ImGui_TableSetColumnIndex(ctx, 0)
                  local ck, nc2 = reaper.ImGui_Checkbox(ctx, "##ck" .. gi .. "_" .. pi, item.checked)
                  if ck then item.checked = nc2 end

                  -- Col 1: Parameter Name
                  reaper.ImGui_TableSetColumnIndex(ctx, 1)
                  reaper.ImGui_AlignTextToFramePadding(ctx)
                  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), item.checked and 0xFFFFFFFF or C.text_dim)
                  reaper.ImGui_Text(ctx, disp)
                  reaper.ImGui_PopStyleColor(ctx, 1)
                end
              end
              reaper.ImGui_EndTable(ctx)
            end
            reaper.ImGui_Unindent(ctx, UI.indent_w)
            reaper.ImGui_Spacing(ctx)
          end
        end
      end
    end

    reaper.ImGui_EndChild(ctx)
  end

  -- Action row
  local total = count_checked_params()
  reaper.ImGui_Spacing(ctx)

  if total == 0 then reaper.ImGui_BeginDisabled(ctx) end
  local lbl = string.format("Add %d Link%s", total, total == 1 and "" or "s")
  if reaper.ImGui_Button(ctx, lbl, -1, 0) and total > 0 then
    reaper.Undo_BeginBlock()
    create_links_from_match()
    save_links()
    for _, grp in ipairs(M.groups) do
      for _, item in ipairs(grp.params) do item.checked = false end
    end
    reaper.Undo_EndBlock("Create parameter links", -1)
  end
  if total == 0 then reaper.ImGui_EndDisabled(ctx) end

  reaper.ImGui_Spacing(ctx)
end

-------------------------------------------------------------------------------
-- 11. MODAL DIALOGS (Preset Manager, Info & Guide, Settings)
-------------------------------------------------------------------------------
local function center_next_modal(modal_w, modal_h)
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  reaper.ImGui_SetNextWindowPos(ctx, wx + ww * 0.5, wy + wh * 0.5, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, modal_w, modal_h, reaper.ImGui_Cond_Appearing())
end

local function draw_preset_modal()
  if show_preset_modal then
    reaper.ImGui_OpenPopup(ctx, "Preset Library##preset_mgr_modal")
    show_preset_modal = false
  end

  center_next_modal(640, 420)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Preset Library##preset_mgr_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
    reaper.ImGui_Text(ctx, string.format("Saved Presets (%d)", #P.list))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, 12)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "Select tracks, then Apply to create links instantly.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local PFLG = reaper.ImGui_TableFlags_RowBg()
               | reaper.ImGui_TableFlags_Borders()
               | reaper.ImGui_TableFlags_ScrollY()
    if reaper.ImGui_BeginTable(ctx, "preset_modal_tbl", 4, PFLG, 0, 260) then
      reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
      reaper.ImGui_TableSetupColumn(ctx, "Preset Name",   reaper.ImGui_TableColumnFlags_WidthStretch(), 0.40)
      reaper.ImGui_TableSetupColumn(ctx, "Plugin",        reaper.ImGui_TableColumnFlags_WidthStretch(), 0.30)
      reaper.ImGui_TableSetupColumn(ctx, "Params",        reaper.ImGui_TableColumnFlags_WidthFixed(), 55)
      reaper.ImGui_TableSetupColumn(ctx, "Actions",       reaper.ImGui_TableColumnFlags_WidthFixed(), 130)
      reaper.ImGui_TableHeadersRow(ctx)

      if #P.list == 0 then
        reaper.ImGui_TableNextRow(ctx, 0, 24)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, "No presets saved yet. Save from Active Links.")
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      local to_del_p = nil
      for pi, preset in ipairs(P.list) do
        reaper.ImGui_TableNextRow(ctx, 0, 24)

        -- Col 0: Name
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (P.sel == pi) and C.accent or 0xFFFFFFFF)
        reaper.ImGui_Text(ctx, preset.name)
        reaper.ImGui_PopStyleColor(ctx, 1)

        -- Col 1: Plugin
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        local pname_display = preset.plugin_name or preset.plugin_hint or "--"
        reaper.ImGui_Text(ctx, (pname_display ~= "") and pname_display or "--")
        reaper.ImGui_PopStyleColor(ctx, 1)

        -- Col 2: Param Count
        reaper.ImGui_TableSetColumnIndex(ctx, 2)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_Text(ctx, tostring(#(preset.params or {})))

        -- Col 3: Actions
        reaper.ImGui_TableSetColumnIndex(ctx, 3)
        if reaper.ImGui_SmallButton(ctx, "Apply##papply" .. pi) then
          P.sel = pi
          apply_preset_direct(preset)
        end
        reaper.ImGui_SameLine(ctx, 0, 6)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.red_d)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.red_h)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.red)
        if reaper.ImGui_SmallButton(ctx, "Del##pdel" .. pi) then
          to_del_p = pi
        end
        reaper.ImGui_PopStyleColor(ctx, 3)
      end

      if to_del_p then
        table.remove(P.list, to_del_p)
        if P.sel > #P.list then P.sel = #P.list end
        save_presets()
      end
      reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Close##close_preset_modal", 100, 0) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_info_modal()
  if show_info_modal then
    reaper.ImGui_OpenPopup(ctx, "Fancy Parameter Link -- Info & Guide##info_modal")
    show_info_modal = false
  end

  center_next_modal(600, 374)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Fancy Parameter Link -- Info & Guide##info_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    if reaper.ImGui_BeginTabBar(ctx, "info_tab_bar") then
      -- TAB 1: Quick Start Guide
      if reaper.ImGui_BeginTabItem(ctx, "Quick Start Guide") then
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "1. Choose Tracks")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Select your Source Track (Green) and Target Track (Purple) in the left panel.")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "2. Select Plugin")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Choose the plugin inserted on both tracks. The script automatically indexes all matching parameters.")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "3. Select Parameters")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Check individual parameters or check entire group boxes. Use the search bar to filter by name.")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "4. Add Links")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Click 'Create Links' to begin real-time parameter tracking. Manage live values, modes, and strengths in the Active Links table.")
        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_EndTabItem(ctx)
      end

      -- TAB 2: Modes & Tips
      if reaper.ImGui_BeginTabItem(ctx, "Modes & Tips") then
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.green)
        reaper.ImGui_Text(ctx, "Follow Mode")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Target parameter mirrors the source parameter in the exact same direction (1:1 direct tracking).")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.accent)
        reaper.ImGui_Text(ctx, "Inverse Mode")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Target parameter moves inversely around center (0.5). Ideal for complementary EQ matching, wet/dry crossfades, makeup gains, and dynamic frequency balancing.")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "Strength Control (0% – 100%)")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Scales the depth of modulation applied to the target parameter. Adjust live directly from the Active Links table.")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "Last Touched Automation")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Touch any knob or fader in REAPER and click 'Last Touched' in the Link Builder to instantly pick up and focus that parameter.")
        reaper.ImGui_Spacing(ctx)

        local pf = push_font(font_brand_bold, 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, "Creating Presets")
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf)
        reaper.ImGui_TextWrapped(ctx, "Select one or more active links in the table and click 'Save as Preset'. Presets store matched parameter relationships and can be loaded directly onto any track pair containing the same plugin.")
        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_EndTabItem(ctx)
      end

      -- TAB 3: About
      if reaper.ImGui_BeginTabItem(ctx, "About") then
        local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

        -- Vertical centering offset
        local content_h = 160
        local top_pad = math.max(6, math.floor((avail_h - content_h) * 0.5))
        reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + top_pad)

        -- Centered Icon
        local icon_sz = 36
        reaper.ImGui_SetCursorPosX(ctx, (avail_w - icon_sz) * 0.5)
        draw_brand_icon(icon_sz)
        reaper.ImGui_Spacing(ctx)

        -- Centered Title
        local pf1 = push_font(font_brand_bold, 16)
        local t1 = "FANCY "
        local t2 = "PARAMETER LINK"
        local w1 = reaper.ImGui_CalcTextSize(ctx, t1)
        local w2 = reaper.ImGui_CalcTextSize(ctx, t2)
        local total_tw = w1 + w2
        reaper.ImGui_SetCursorPosX(ctx, (avail_w - total_tw) * 0.5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
        reaper.ImGui_Text(ctx, t1)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
        reaper.ImGui_Text(ctx, t2)
        reaper.ImGui_PopStyleColor(ctx, 1)
        pop_font(pf1)

        -- Centered Subtitle
        local sub = "v1.0 crafted by Fancy Wolf Audio & Antigravity for REAPER"
        local sw = reaper.ImGui_CalcTextSize(ctx, sub)
        reaper.ImGui_SetCursorPosX(ctx, (avail_w - sw) * 0.5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
        reaper.ImGui_Text(ctx, sub)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Spacing(ctx)

        -- Centered Support Prompt
        local prompt = "Find this useful?"
        local pw = reaper.ImGui_CalcTextSize(ctx, prompt)
        reaper.ImGui_SetCursorPosX(ctx, (avail_w - pw) * 0.5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xD0D0D0FF)
        reaper.ImGui_Text(ctx, prompt)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Spacing(ctx)

        -- Centered Coffee Button
        local btn_w, btn_h = 240, 28
        reaper.ImGui_SetCursorPosX(ctx, (avail_w - btn_w) * 0.5)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.card)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.panel)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.accent_d)
        if reaper.ImGui_Button(ctx, "Buy me a Cup of Coffee as Thanks", btn_w, btn_h) then
          open_url("https://buymeacoffee.com/fancywolf")
        end
        reaper.ImGui_PopStyleColor(ctx, 3)

        reaper.ImGui_EndTabItem(ctx)
      end

      reaper.ImGui_EndTabBar(ctx)
    end

    if not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_settings_modal()
  if show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, "Settings & Preferences##settings_modal")
    show_settings_modal = false
  end

  center_next_modal(620, 520)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Settings & Preferences##settings_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    reaper.ImGui_Spacing(ctx)

    -- Section 1: Default Behaviors
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
    reaper.ImGui_Text(ctx, "Default Link Rules")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Inverse Gain by Default:")
    reaper.ImGui_SameLine(ctx, 0, 14)
    local is_yes = (SETTINGS.default_mode ~= "follow")
    if reaper.ImGui_RadioButton(ctx, "Yes##inv_gain_yes", is_yes) then
      SETTINGS.default_mode = "smart"
      save_settings()
    end
    reaper.ImGui_SameLine(ctx, 0, 14)
    if reaper.ImGui_RadioButton(ctx, "No##inv_gain_no", not is_yes) then
      SETTINGS.default_mode = "follow"
      save_settings()
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Default Strength:")
    reaper.ImGui_SameLine(ctx, 0, 14)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local s_pct = (SETTINGS.default_strength or 1.0) * 100
    local sc, np = reaper.ImGui_SliderDouble(ctx, "##def_st", s_pct, 0, 100, "%.0f%%")
    if sc then
      SETTINGS.default_strength = np / 100
      save_settings()
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Section 2: Last Touched Automation
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
    reaper.ImGui_Text(ctx, "Last Touched Automation")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local ck_at, n_at = reaper.ImGui_Checkbox(ctx, "Auto-populate Source & Target pickers when touching FX parameter", SETTINGS.auto_touch_sync)
    if ck_at then
      SETTINGS.auto_touch_sync = n_at
      save_settings()
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_TextWrapped(ctx, "When enabled, touching any plugin control in REAPER automatically loads its track and plugin into the Link Builder.")
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Section 3: UI & Density
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
    reaper.ImGui_Text(ctx, "UI Density & Appearance")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Table Row Height:")
    reaper.ImGui_SameLine(ctx, 0, 14)
    if reaper.ImGui_RadioButton(ctx, "Compact (20px)##rh20", SETTINGS.row_height == 20) then
      SETTINGS.row_height = 20
      save_settings()
    end
    reaper.ImGui_SameLine(ctx, 0, 10)
    if reaper.ImGui_RadioButton(ctx, "Standard (24px)##rh24", SETTINGS.row_height == 24) then
      SETTINGS.row_height = 24
      save_settings()
    end
    reaper.ImGui_SameLine(ctx, 0, 10)
    if reaper.ImGui_RadioButton(ctx, "Comfortable (28px)##rh28", SETTINGS.row_height == 28) then
      SETTINGS.row_height = 28
      save_settings()
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Section 4: File Storage & Backups
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
    reaper.ImGui_Text(ctx, "File Storage & Backups")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, "Project Config: " .. sav_path())
    reaper.ImGui_Text(ctx, "Presets File: " .. PRESET_PATH)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)

    if reaper.ImGui_Button(ctx, "Open Config Folder", 180, 0) then
      open_config_folder()
    end
    reaper.ImGui_SameLine(ctx, 0, 10)
    if reaper.ImGui_Button(ctx, "Export Links JSON...", 150, 0) then
      export_links_dialog()
    end
    reaper.ImGui_SameLine(ctx, 0, 10)
    if reaper.ImGui_Button(ctx, "Import Links JSON...", 150, 0) then
      import_links_dialog()
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Close##close_settings_modal", 100, 0) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-------------------------------------------------------------------------------
-- 12. MAIN WINDOW
-------------------------------------------------------------------------------
local function draw_main()
  local nc, nv = Theme.push(ctx, C)
  reaper.ImGui_SetNextWindowSize(ctx, UI.win_w, UI.win_h, reaper.ImGui_Cond_Once())

  local vis, op = reaper.ImGui_Begin(ctx, "Fancy Parameter Link", true, reaper.ImGui_WindowFlags_NoCollapse())
  if not vis then
    Theme.pop(ctx, nc, nv)
    return op
  end

  -- Header: Title | Presets | Info | Settings
  reaper.ImGui_Spacing(ctx)
  poll_last_touched()

  local hdr_h = UI.btn_h
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 4)

  -- Left: Branded Script Title & Logo
  draw_brand_icon(24, hdr_h)
  reaper.ImGui_SameLine(ctx, 0, 8)
  reaper.ImGui_AlignTextToFramePadding(ctx)

  -- "FANCY" (Bold Accent)
  local pf_b = push_font(font_brand_bold, 15)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.yellow)
  reaper.ImGui_Text(ctx, "FANCY")
  reaper.ImGui_PopStyleColor(ctx, 1)
  pop_font(pf_b)

  -- "PARAMETER LINK" (Clean White)
  reaper.ImGui_SameLine(ctx, 0, 5)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  local pf_r = push_font(font_brand_reg, 15)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  reaper.ImGui_Text(ctx, "PARAMETER LINK")
  reaper.ImGui_PopStyleColor(ctx, 1)
  pop_font(pf_r)

  -- Center: Status messages
  local win_w = reaper.ImGui_GetWindowWidth(ctx)
  reaper.ImGui_SameLine(ctx, math.max(240, (win_w * 0.5) - 100))
  reaper.ImGui_AlignTextToFramePadding(ctx)

  -- Selection count
  local sel_count_hdr = 0
  for i = 1, #links do if link_sel[i] then sel_count_hdr = sel_count_hdr + 1 end end
  if sel_count_hdr > 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
    reaper.ImGui_Text(ctx, string.format("%d selected", sel_count_hdr))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, 12)
  end

  -- Status message (auto-fades after 4 seconds)
  if preset_status_msg ~= "" then
    local elapsed = reaper.time_precise() - preset_status_time
    if elapsed < 4.0 then
      local alpha = math.max(0, math.min(1, 1.0 - (elapsed - 3.0)))
      local status_col = (preset_status_msg:find("✓") and C.green) or C.yellow
      if elapsed > 3.0 then
        local r_c = (status_col >> 24) & 0xFF
        local g_c = (status_col >> 16) & 0xFF
        local b_c = (status_col >> 8) & 0xFF
        status_col = (r_c << 24) | (g_c << 16) | (b_c << 8) | math.floor(alpha * 255)
      end
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), status_col)
      reaper.ImGui_Text(ctx, preset_status_msg)
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      preset_status_msg = ""
    end
  end

  -- Right: Info + Settings text buttons
  local spacing = 6
  reaper.ImGui_SameLine(ctx, math.max(280, win_w - (UI.btn_info_w + UI.btn_sett_w + spacing + 16)))

  if reaper.ImGui_Button(ctx, "Info##hdr_info", UI.btn_info_w, hdr_h) then
    show_info_modal = true
  end

  reaper.ImGui_SameLine(ctx, 0, spacing)
  if reaper.ImGui_Button(ctx, "Settings##hdr_settings", UI.btn_sett_w, hdr_h) then
    show_settings_modal = true
  end

  reaper.ImGui_PopStyleVar(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Two-column resizable body
  local split_flags = reaper.ImGui_TableFlags_Resizable()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(), 0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(),  0x00000000)
  if reaper.ImGui_BeginTable(ctx, "main_split_tbl", 2, split_flags) then
    reaper.ImGui_TableSetupColumn(ctx, "LeftPane",  reaper.ImGui_TableColumnFlags_WidthStretch(), 0.25)
    reaper.ImGui_TableSetupColumn(ctx, "RightPane", reaper.ImGui_TableColumnFlags_WidthStretch(), 0.75)
    reaper.ImGui_TableNextRow(ctx)

    -- LEFT: shared pickers + link builder
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), C.bg)
    local lvis = reaper.ImGui_BeginChild(ctx, "left_col", 0, 0)
    reaper.ImGui_PopStyleColor(ctx, 1)
    if lvis then
      local tlist = get_tlist()

      section_divider("  Source & Target", C.yellow, "Pick source and target tracks. All workflows (Builder, Quick Add, Presets) use these shared pickers.")
      draw_shared_pickers(tlist)

      section_divider("  Link Builder", C.yellow, "Scan matching plugins to create links in bulk. Check parameters, then click Create Links.")
      draw_link_builder()

      reaper.ImGui_EndChild(ctx)
    end

    -- RIGHT: active links
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), C.bg)
    local rvis = reaper.ImGui_BeginChild(ctx, "right_col", 0, 0)
    reaper.ImGui_PopStyleColor(ctx, 1)
    if rvis then
      reaper.ImGui_Spacing(ctx)

      -- Pause / Resume & Clear All at top of Active Links panel
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 4)
      if paused then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.red_d)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.red_h)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.red)
        if reaper.ImGui_Button(ctx, "Resume All") then paused = false end
        reaper.ImGui_PopStyleColor(ctx, 3)
      else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.green_d)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.green_h)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.green)
        if reaper.ImGui_Button(ctx, "Pause All") then paused = true end
        reaper.ImGui_PopStyleColor(ctx, 3)
      end

      reaper.ImGui_SameLine(ctx, 0, 6)
      local no_links = (#links == 0)
      if no_links then reaper.ImGui_BeginDisabled(ctx) end
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.red_d)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.red_h)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.red)
      if reaper.ImGui_Button(ctx, "Clear All") and not no_links then
        reaper.Undo_BeginBlock()
        links = {}
        lsrc  = {}
        link_sel = {}
        save_links()
        reaper.Undo_EndBlock("Clear all parameter links", -1)
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
      if no_links then reaper.ImGui_EndDisabled(ctx) end

      -- Select All / None toggle
      reaper.ImGui_SameLine(ctx, 0, 6)
      local sel_count = 0
      for i = 1, #links do if link_sel[i] then sel_count = sel_count + 1 end end
      local all_selected = (#links > 0 and sel_count == #links)
      if no_links then reaper.ImGui_BeginDisabled(ctx) end
      if reaper.ImGui_Button(ctx, all_selected and "Select None" or "Select All") then
        link_sel = {}
        if not all_selected then
          for i = 1, #links do link_sel[i] = true end
        end
      end

      -- Save as Preset button
      reaper.ImGui_SameLine(ctx, 0, 6)
      if no_links or sel_count == 0 then
        if not no_links then reaper.ImGui_BeginDisabled(ctx) end
      end
      if reaper.ImGui_Button(ctx, "Save as Preset") and sel_count > 0 then
        local first_sel = nil
        for i = 1, #links do
          if link_sel[i] then first_sel = i; break end
        end
        save_preset_name = first_sel and (links[first_sel].src_fxname .. " Link") or ""
        save_preset_popup = true
      end
      if no_links or sel_count == 0 then
        if not no_links then reaper.ImGui_EndDisabled(ctx) end
      end
      if no_links then reaper.ImGui_EndDisabled(ctx) end

      -- Preset combo (right-aligned, flush with active links table right boundary)
      local combo_w = 154
      local menu_btn_w = 24
      local label_w = reaper.ImGui_CalcTextSize(ctx, "Preset:")
      local total_group_w = label_w + 4 + combo_w + 2 + menu_btn_w
      reaper.ImGui_SameLine(ctx, 0, 0)
      local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
      local cur_x   = reaper.ImGui_GetCursorPosX(ctx)
      local right_x = cur_x + avail_w - total_group_w
      reaper.ImGui_SetCursorPosX(ctx, math.max(cur_x + 6, right_x))
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
      reaper.ImGui_Text(ctx, "Preset:")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_SameLine(ctx, 0, 4)
      reaper.ImGui_SetNextItemWidth(ctx, combo_w)
      local tlist_p = get_tlist()
      local has_tracks = (S.src_ti > 0 and S.src_ti <= #tlist_p and S.dst_ti > 0 and S.dst_ti <= #tlist_p)
                      or (reaper.CountSelectedTracks(0) >= 2)
      local preview
      if not has_tracks then
        preview = "Select tracks..."
      elseif P.sel > 0 and P.sel <= #P.list then
        preview = P.list[P.sel].name
      else
        preview = "-- preset --"
      end
      if not has_tracks then reaper.ImGui_BeginDisabled(ctx) end
      local combo_open = reaper.ImGui_BeginCombo(ctx, "##al_preset_combo", preview)
      if combo_open then
        for i, preset in ipairs(P.list) do
          local pn = preset.plugin_name or preset.plugin_hint or ""
          local hint = (pn ~= "") and ("  [" .. pn .. "]") or ""
          local lbl  = preset.name .. hint .. "##alp" .. i
          if reaper.ImGui_Selectable(ctx, lbl, P.sel == i) then
            P.sel = i
            apply_preset_direct(preset)
          end
          if P.sel == i then reaper.ImGui_SetItemDefaultFocus(ctx) end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      if not has_tracks then reaper.ImGui_EndDisabled(ctx) end

      -- [+] Preset menu (DrawList icon)
      reaper.ImGui_SameLine(ctx, 0, 2)
      if icon_btn_colored("al_preset_menu", icon_plus, menu_btn_w, 0, 10, 0xFFFFFFFF, C.card, C.panel, C.accent_d, "Preset Options") then
        reaper.ImGui_OpenPopup(ctx, "al_preset_menu_popup")
      end
      if reaper.ImGui_BeginPopup(ctx, "al_preset_menu_popup") then
        if reaper.ImGui_Selectable(ctx, "Preset library...##alpm_lib") then
          show_preset_modal = true
        end
        if reaper.ImGui_Selectable(ctx, "Save as default##alpm_def") then
          save_settings()
        end
        reaper.ImGui_Separator(ctx)
        local can_del = (P.sel > 0 and P.sel <= #P.list)
        if not can_del then reaper.ImGui_BeginDisabled(ctx) end
        if reaper.ImGui_Selectable(ctx, "Delete preset##alpm_del") and can_del then
          table.remove(P.list, P.sel)
          if P.sel > #P.list then P.sel = #P.list end
          save_presets()
        end
        if not can_del then reaper.ImGui_EndDisabled(ctx) end
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Selectable(ctx, "Export links...##alpm_exp") then
          export_links_dialog()
        end
        if reaper.ImGui_Selectable(ctx, "Import links...##alpm_imp") then
          import_links_dialog()
        end
        reaper.ImGui_EndPopup(ctx)
      end
      reaper.ImGui_PopStyleVar(ctx, 1) -- FramePadding

      -- Save Preset popup
      if save_preset_popup then
        reaper.ImGui_OpenPopup(ctx, "Save as Preset##save_preset_popup")
        save_preset_popup = false
      end
      if reaper.ImGui_BeginPopup(ctx, "Save as Preset##save_preset_popup") then
        reaper.ImGui_Text(ctx, "Preset Name:")
        reaper.ImGui_SetNextItemWidth(ctx, 280)
        local chg, nv = reaper.ImGui_InputTextWithHint(ctx, "##save_pn", "e.g. Inverse EQ — Pro-Q 4", save_preset_name, 256)
        if chg then save_preset_name = nv end
        reaper.ImGui_Spacing(ctx)
        local can_save = (save_preset_name ~= "")
        if not can_save then reaper.ImGui_BeginDisabled(ctx) end
        if reaper.ImGui_Button(ctx, "Save##do_save_preset", 80, 0) and can_save then
          if save_preset_from_links(save_preset_name) then
            save_presets()
            P.sel = #P.list
            preset_status_msg = string.format("Preset '%s' saved ✓", save_preset_name)
            preset_status_time = reaper.time_precise()
            save_preset_name = ""
            link_sel = {}
          end
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        if not can_save then reaper.ImGui_EndDisabled(ctx) end
        reaper.ImGui_SameLine(ctx, 0, 8)
        if reaper.ImGui_Button(ctx, "Cancel##cancel_save_preset", 80, 0) then
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
      end

      reaper.ImGui_Spacing(ctx)

      local TFLG = reaper.ImGui_TableFlags_RowBg()
                 | reaper.ImGui_TableFlags_Borders()
                 | reaper.ImGui_TableFlags_ScrollY()
                 | reaper.ImGui_TableFlags_Resizable()
      local _, ah = reaper.ImGui_GetContentRegionAvail(ctx)
      local tbl_h = math.max(80, ah)
      local row_h = SETTINGS.row_height or 24
      local pb_h  = math.max(14, row_h - 6)

      -- 9 Columns: Source, Target, Plugin, Parameter, Live Values, Mode, Strength, Pause, Remove
      -- Dim selection highlight so text stays readable
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),            0x8B70FA30)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),     0x8B70FA50)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),      0x8B70FA60)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(), C.sep)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(),  C.accent_e)
      if reaper.ImGui_BeginTable(ctx, "links_tbl", 9, TFLG, 0, tbl_h) then
        reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
        reaper.ImGui_TableSetupColumn(ctx, "Source",      reaper.ImGui_TableColumnFlags_WidthStretch(), 0.13)
        reaper.ImGui_TableSetupColumn(ctx, "Target",      reaper.ImGui_TableColumnFlags_WidthStretch(), 0.13)
        reaper.ImGui_TableSetupColumn(ctx, "Plugin",      reaper.ImGui_TableColumnFlags_WidthStretch(), 0.15)
        reaper.ImGui_TableSetupColumn(ctx, "Parameter",   reaper.ImGui_TableColumnFlags_WidthStretch(), 0.19)
        reaper.ImGui_TableSetupColumn(ctx, "Live Values", reaper.ImGui_TableColumnFlags_WidthFixed(), UI.val_col_w)
        reaper.ImGui_TableSetupColumn(ctx, "Mode",        reaper.ImGui_TableColumnFlags_WidthFixed(), UI.mode_col_w)
        reaper.ImGui_TableSetupColumn(ctx, "Strength",    reaper.ImGui_TableColumnFlags_WidthFixed(), UI.str_col_w)
        reaper.ImGui_TableSetupColumn(ctx, "##pause",     reaper.ImGui_TableColumnFlags_WidthFixed(), 28)
        reaper.ImGui_TableSetupColumn(ctx, "##del",       reaper.ImGui_TableColumnFlags_WidthFixed(), UI.del_col_w)
        reaper.ImGui_TableHeadersRow(ctx)

        if #links == 0 then
          reaper.ImGui_TableNextRow(ctx, 0, 32)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
          reaper.ImGui_Text(ctx, "No links yet.")
          reaper.ImGui_PopStyleColor(ctx, 1)
        end

        local to_del = nil
        for i, lk in ipairs(links) do
          reaper.ImGui_TableNextRow(ctx, 0, row_h)
          local str = tr_by_guid(lk.src_guid)
          local dtr = tr_by_guid(lk.dst_guid)
          local ok  = (str ~= nil and dtr ~= nil)

          -- Row selection (invisible selectable spanning all columns)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                          | reaper.ImGui_SelectableFlags_AllowOverlap()
          if reaper.ImGui_Selectable(ctx, "##sel_row" .. i, link_sel[i] == true, sel_flags, 0, row_h) then
            local io_obj = ctx  -- key mods are on the context
            local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftShift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightShift())
            if shift and last_clicked_link > 0 and last_clicked_link ~= i then
              -- Range select
              local lo = math.min(last_clicked_link, i)
              local hi = math.max(last_clicked_link, i)
              for j = lo, hi do link_sel[j] = true end
            else
              -- Toggle single
              link_sel[i] = (not link_sel[i]) or nil
            end
            last_clicked_link = i
          end

          -- Dim row if link is individually paused
          local row_dimmed = lk.link_paused
          if row_dimmed then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.45) end

          -- 1. Source Track (same cell, after selectable)
          reaper.ImGui_SameLine(ctx, 0, 0)
          reaper.ImGui_AlignTextToFramePadding(ctx)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.green)
          reaper.ImGui_Text(ctx, lk.src_name)
          reaper.ImGui_PopStyleColor(ctx, 1)

          -- 2. Target Track
          reaper.ImGui_TableSetColumnIndex(ctx, 1)
          reaper.ImGui_AlignTextToFramePadding(ctx)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.accent)
          reaper.ImGui_Text(ctx, lk.dst_name)
          reaper.ImGui_PopStyleColor(ctx, 1)

          -- 3. Plugin
          reaper.ImGui_TableSetColumnIndex(ctx, 2)
          reaper.ImGui_AlignTextToFramePadding(ctx)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
          reaper.ImGui_Text(ctx, lk.src_fxname)
          reaper.ImGui_PopStyleColor(ctx, 1)

          -- 4. Parameter
          reaper.ImGui_TableSetColumnIndex(ctx, 3)
          reaper.ImGui_AlignTextToFramePadding(ctx)
          reaper.ImGui_Text(ctx, lk.src_pname)

          -- 5. Live Values
          reaper.ImGui_TableSetColumnIndex(ctx, 4)
          if ok then
            table_vcenter(pb_h, row_h)
            local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
            local bar_w = math.max(10, math.floor((avail_w - 4) * 0.5))
            local sv = reaper.TrackFX_GetParamNormalized(str, lk.src_fxi, lk.src_pi)
            local dv = reaper.TrackFX_GetParamNormalized(dtr, lk.dst_fxi, lk.dst_pi)
            draw_progress_bar_centered(sv, bar_w, pb_h, C.green_d, C.card, fmt_val(str, lk.src_fxi, lk.src_pi, sv))
            reaper.ImGui_SameLine(ctx, 0, 4)
            draw_progress_bar_centered(dv, bar_w, pb_h, C.accent_d, C.card, fmt_val(dtr, lk.dst_fxi, lk.dst_pi, dv))
          else
            reaper.ImGui_AlignTextToFramePadding(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.red)
            reaper.ImGui_Text(ctx, "Offline")
            reaper.ImGui_PopStyleColor(ctx, 1)
          end

          -- 6. Mode (Follow / Inverse toggle button)
          reaper.ImGui_TableSetColumnIndex(ctx, 5)
          table_vcenter(pb_h, row_h)
          if mode_btn("tbl_m_" .. i, lk.mode, pb_h) then
            lk.mode = (lk.mode == "follow") and "inverse" or "follow"
            save_links()
          end

          -- 7. Strength (Slider)
          reaper.ImGui_TableSetColumnIndex(ctx, 6)
          table_vcenter(pb_h, row_h)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(), 5)
          local s_pct = (lk.strength or 1.0) * 100
          local ch_s, np_s = reaper.ImGui_SliderDouble(ctx, "##tbl_s_" .. i, s_pct, 0, 100, "%.0f%%")
          reaper.ImGui_PopStyleVar(ctx, 1)
          if ch_s then
            lk.strength = np_s / 100
          end
          if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
            save_links()
          end

          -- 8. Pause (per-link toggle — DrawList icon centered)
          reaper.ImGui_TableSetColumnIndex(ctx, 7)
          if row_dimmed then reaper.ImGui_PopStyleVar(ctx, 1) end
          local pause_icon = lk.link_paused and icon_play or icon_pause
          if icon_btn("lp" .. i, pause_icon, -1, row_h, 8, C.text_dim) then
            lk.link_paused = not lk.link_paused
            if lk.link_paused then lsrc[i] = nil end
            save_links()
          end
          if row_dimmed then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.45) end

          -- 9. Remove (DrawList X icon centered)
          reaper.ImGui_TableSetColumnIndex(ctx, 8)
          if icon_btn("ld" .. i, icon_close, -1, row_h, 8, C.red) then
            to_del = i
          end
          if row_dimmed then reaper.ImGui_PopStyleVar(ctx, 1) end
        end

        if to_del then
          reaper.Undo_BeginBlock()
          table.remove(links, to_del)
          lsrc = {}
          link_sel = {}
          save_links()
          reaper.Undo_EndBlock("Remove parameter link", -1)
        end
        reaper.ImGui_EndTable(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx, 5) -- Header highlight colors & table borders

      reaper.ImGui_EndChild(ctx)
    end

    reaper.ImGui_EndTable(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- Modals rendering
  draw_preset_modal()
  draw_info_modal()
  draw_settings_modal()

  reaper.ImGui_End(ctx)
  Theme.pop(ctx, nc, nv)
  return op
end

-------------------------------------------------------------------------------
-- 13. DEFER LOOP
-------------------------------------------------------------------------------
local function loop()
  apply_links()
  local open = draw_main()
  if open then reaper.defer(loop) end
end

-------------------------------------------------------------------------------
-- 14. ENTRY POINT
-------------------------------------------------------------------------------
function main()
  load_links()
  load_presets()
  load_settings()

  local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
  ctx = reaper.ImGui_CreateContext("Fancy Parameter Link", dock_flag)

  local function safe_create_font(family, size)
    if not reaper.ImGui_CreateFont then return nil end
    local ok, font = pcall(reaper.ImGui_CreateFont, family, size)
    if ok and font then return font end
    local ok2, font2 = pcall(reaper.ImGui_CreateFont, 'sans-serif', size)
    if ok2 and font2 then return font2 end
    return nil
  end

  font_brand_bold = safe_create_font('sans-serif Bold', 15)
  font_brand_reg  = safe_create_font('sans-serif', 15)

  if font_brand_bold and reaper.ImGui_Attach then reaper.ImGui_Attach(ctx, font_brand_bold) end
  if font_brand_reg  and reaper.ImGui_Attach then reaper.ImGui_Attach(ctx, font_brand_reg) end

  reaper.atexit(function()
    save_links()
    save_presets()
    save_settings()
  end)

  reaper.defer(loop)
end

main()
