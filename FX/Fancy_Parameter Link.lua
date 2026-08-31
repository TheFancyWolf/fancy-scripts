-- @description Fancy Parameter Link
-- @author Fancy Scripts
-- @version 5.3.0
-- @changelog
--   + Bundled 1x and 2x Retina toolbar icons (toolbar_fancy_parameter_link.png)
--   + Active toolbar button state while script is running
-- @about
--   Links FX parameters between tracks: Follow or Inverse with adjustable strength.
--   Features: multi-track selector, auto group-scan for same plugin, full-mesh linking,
--   bidirectional engine (move any linked knob), global presets, live inspector,
--   and settings modal.
--   Requirements: ReaImGui extension (install via ReaPack)
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua
--   [data] ../toolbar_icons/toolbar_fancy_parameter_link.png > toolbar_icons/toolbar_fancy_parameter_link.png
--   [data] ../toolbar_icons/150/toolbar_fancy_parameter_link.png > toolbar_icons/150/toolbar_fancy_parameter_link.png
--   [data] ../toolbar_icons/200/toolbar_fancy_parameter_link.png > toolbar_icons/200/toolbar_fancy_parameter_link.png

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
local Utils = require("utils")

-------------------------------------------------------------------------------
-- 3. STATE & CONFIGURATION
-------------------------------------------------------------------------------
local ctx
local fonts
local links   = {}   -- active links (bidirectional a <-> b)
local paused  = false

-- Link selection state (for preset save flow)
local link_sel          = {}   -- set of selected link indices: link_sel[i] = true
local last_clicked_link = 0    -- for shift-click range selection

-- Cached grouped links view (invalidated only on link mutations)
local _cached_link_groups = nil
local _link_groups_dirty  = true

local function invalidate_link_groups()
  _link_groups_dirty  = true
  _cached_link_groups = nil
end

-- Status message (temporary toast in header)
local preset_status_msg  = ""
local preset_status_time = 0

-- Settings & Preferences
local SETTINGS = {
  default_mode     = "smart", -- "smart", "inverse", "follow"
  default_strength = 1.0,     -- 0.0 to 1.0
  auto_touch_sync  = false,   -- auto-populate pickers on touch
  row_height       = 24,      -- row height in active links table
}

-- UI Layout Constants built from Theme.layout tokens
local L = Theme.layout
local UI = {
  win_w       = 1200,
  win_h       = 820,
  btn_h       = L.xxl + L.xs,              -- 26
  btn_info_w  = L.xxxl + L.xl,             -- 48
  btn_sett_w  = L.xxxl * 2 + L.md,         -- 72
  indent_w    = L.indent,                  -- 32 (from Theme.layout)
  chk_col_w   = L.chk_col_w,               -- 24 (from Theme.layout)
  val_col_w   = 150,
  mode_col_w  = 74,
  str_col_w   = 85,
  del_col_w   = L.icon_md.size + L.icon_md.pad * 2 + L.md, -- 28
}

-- Modal Dialog State
local show_info_modal     = false
local show_settings_modal = false
local show_preset_modal   = false
local save_preset_popup   = false
local save_preset_name    = ""

-- Track GUID cache with project state tracking (includes Master Track)
local _gc, _gn, _g_state, _g_proj = {}, -1, -1, nil
local function _refresh_gc()
  local n = reaper.CountTracks(0)
  local state = reaper.GetProjectStateChangeCount(0)
  local proj = reaper.EnumProjects(-1, "")
  if n == _gn and state == _g_state and proj == _g_proj then return end
  _gc, _gn, _g_state, _g_proj = {}, n, state, proj

  local mtr = reaper.GetMasterTrack(0)
  if mtr then
    _gc[reaper.GetTrackGUID(mtr)] = mtr
  end
  for j = 0, n - 1 do
    local tr = reaper.GetTrack(0, j)
    if tr then
      _gc[reaper.GetTrackGUID(tr)] = tr
    end
  end
end

local function tr_by_guid(g)
  if not g or g == "" then return nil end
  _refresh_gc()
  return _gc[g]
end

-- Shared track list cache with project state tracking (includes Master Track)
local _tlist_n, _tlist_state, _tlist_proj, _tlist = -1, -1, nil, nil
local function get_tlist()
  local n = reaper.CountTracks(0)
  local state = reaper.GetProjectStateChangeCount(0)
  local proj = reaper.EnumProjects(-1, "")
  if n ~= _tlist_n or state ~= _tlist_state or proj ~= _tlist_proj then
    _tlist_n, _tlist_state, _tlist_proj, _tlist = n, state, proj, nil
  end
  if not _tlist then
    _tlist = {}
    local mtr = reaper.GetMasterTrack(0)
    if mtr then
      local _, mnm = reaper.GetTrackName(mtr)
      _tlist[#_tlist + 1] = {
        track = mtr,
        name  = (mnm and mnm ~= "") and mnm or "Master Track",
        guid  = reaper.GetTrackGUID(mtr),
      }
    end
    for j = 0, n - 1 do
      local tr = reaper.GetTrack(0, j)
      if tr then
        local _, nm = reaper.GetTrackName(tr)
        _tlist[#_tlist + 1] = {
          track = tr,
          name  = (nm and nm ~= "") and nm or ("Track " .. (j + 1)),
          guid  = reaper.GetTrackGUID(tr),
        }
      end
    end
  end
  return _tlist
end

-- S: Multi-track selector state
local S = {
  tracks = {},     -- list of tlist indices for selected tracks
  tracks_expanded = false, -- whether track list is expanded
  fi     = 0,      -- selected FX index (into fxs list)
  fxs    = {},     -- FX list (intersection across all selected tracks)
  params = {},     -- param list for the selected plugin
}

-- M: Scan & Match state
local M = {
  groups  = {},
  scanned = false,
  filter  = "",
}

-- Presets state
local Presets = {
  list = {},
  sel  = 0,
}

-- Forward declarations for functions defined later
local use_last_touched_builder
local save_links

-- LT: Last Touched live display
local LT = { track = "", fx = "", param = "", norm = 0, tr = nil, fxi = 0, pi = 0 }
local _scroll_to_param_idx = nil  -- param index to scroll into view after Last Touched
local _prev_lt_key = ""
local _last_trnum, _last_rfxi, _last_pnum, _last_tr = -1, -1, -1, nil

local function poll_last_touched()
  local ok, trnum, fxnum, paramnum = reaper.GetLastTouchedFX()
  if not ok then
    if LT.tr ~= nil then
      LT.track = ""
      LT.tr = nil
      _last_trnum, _last_rfxi, _last_pnum, _last_tr = -1, -1, -1, nil
    end
    return
  end
  local real_fxi = fxnum & 0xFFFFFF
  local tr = (trnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, trnum - 1)
  if not tr then
    LT.track = ""
    LT.tr = nil
    return
  end

  -- Only query strings and perform regex matching if the touched target changed
  if trnum ~= _last_trnum or real_fxi ~= _last_rfxi or paramnum ~= _last_pnum or tr ~= _last_tr then
    _last_trnum, _last_rfxi, _last_pnum, _last_tr = trnum, real_fxi, paramnum, tr
    local _, trname = reaper.GetTrackName(tr)
    local _, fxname = reaper.TrackFX_GetFXName(tr, real_fxi, "")
    local _, pname  = reaper.TrackFX_GetParamName(tr, real_fxi, paramnum, "")
    LT.track = trname
    LT.fx    = fxname:match("^%a+3?:%s*(.+)$") or fxname
    LT.param = pname
    LT.tr    = tr
    LT.fxi   = real_fxi
    LT.pi    = paramnum

    local cur_key = tostring(trnum) .. "_" .. tostring(real_fxi) .. "_" .. tostring(paramnum)
    if SETTINGS.auto_touch_sync and cur_key ~= _prev_lt_key and use_last_touched_builder then
      _prev_lt_key = cur_key
      use_last_touched_builder(true)
    end
  end

  LT.norm = reaper.TrackFX_GetParamNormalized(tr, real_fxi, paramnum)
end

-------------------------------------------------------------------------------
-- 4. HELPERS
-------------------------------------------------------------------------------
-- Safely resolves an FX index on a track by verifying its GUID against moves/reordering
local function resolve_fx(tr, fxi, fxguid)
  if not tr then return -1 end
  local cnt = reaper.TrackFX_GetCount(tr)
  if fxi and fxi >= 0 and fxi < cnt then
    if not fxguid or fxguid == "" or reaper.TrackFX_GetFXGUID(tr, fxi) == fxguid then
      return fxi
    end
  end
  if fxguid and fxguid ~= "" then
    for j = 0, cnt - 1 do
      if reaper.TrackFX_GetFXGUID(tr, j) == fxguid then
        return j
      end
    end
  end
  return (fxi and fxi >= 0 and fxi < cnt) and fxi or -1
end

local function make_link(d)
  return {
    label       = d.label or (tostring(d.a_name or "?") .. " / " .. tostring(d.a_pname or "?") .. " \xe2\x86\x94 " .. tostring(d.b_name or "?") .. " / " .. tostring(d.b_pname or "?")),
    a_guid      = d.a_guid or "",
    a_name      = d.a_name or "?",
    a_fxi       = d.a_fxi or 0,
    a_fxguid    = d.a_fxguid or "",
    a_fxname    = d.a_fxname or "?",
    a_pi        = d.a_pi or 0,
    a_pname     = d.a_pname or "?",
    b_guid      = d.b_guid or "",
    b_name      = d.b_name or "?",
    b_fxi       = d.b_fxi or 0,
    b_fxguid    = d.b_fxguid or "",
    b_fxname    = d.b_fxname or "?",
    b_pi        = d.b_pi or 0,
    b_pname     = d.b_pname or "?",
    mode        = d.mode or "inverse",
    strength    = tonumber(d.strength) or 1.0,
    link_paused = d.link_paused or false,
    last_a      = d.last_a,
    last_b      = d.last_b,
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
    local grp = get_group_prefix(item.param.name)
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

-- Compute FX intersection: plugins common to ALL selected tracks
local function compute_shared_fxs()
  local tlist = get_tlist()
  if #S.tracks == 0 then
    S.fxs = {}
    return
  end
  -- Start with FX list from first track
  local first_entry = tlist[S.tracks[1]]
  if not first_entry or not first_entry.track then
    S.fxs = {}
    return
  end
  local first_fxs = fx_list(first_entry.track)
  if #S.tracks == 1 then
    S.fxs = first_fxs
    return
  end
  -- Intersect: keep only plugins present on ALL tracks
  local shared = {}
  for _, fx in ipairs(first_fxs) do
    local found_all = true
    for ti = 2, #S.tracks do
      local entry = tlist[S.tracks[ti]]
      if not entry or not entry.track then
        found_all = false
        break
      end
      local tr = entry.track
      local has_it = false
      for j = 0, reaper.TrackFX_GetCount(tr) - 1 do
        local _, nm = reaper.TrackFX_GetFXName(tr, j, "")
        local clean = nm:match("^%a+3?:%s*(.+)$") or nm
        if clean == fx.name then has_it = true; break end
      end
      if not has_it then found_all = false; break end
    end
    if found_all then
      shared[#shared + 1] = fx
    end
  end
  S.fxs = shared
end

-- Scan: get matching parameters for the selected plugin (same plugin = same params)
local function do_scan()
  local tlist = get_tlist()
  if #S.tracks < 2 or S.fi == 0 or not S.fxs[S.fi] then return end
  local plugin_name = S.fxs[S.fi].name
  -- Use first track's instance to enumerate parameters
  local first_entry = tlist[S.tracks[1]]
  if not first_entry or not first_entry.track then return end
  local first_tr = first_entry.track
  local fxi = -1
  for j = 0, reaper.TrackFX_GetCount(first_tr) - 1 do
    local _, nm = reaper.TrackFX_GetFXName(first_tr, j, "")
    local clean = nm:match("^%a+3?:%s*(.+)$") or nm
    if clean == plugin_name then fxi = j; break end
  end
  if fxi < 0 then return end
  local params = param_list(first_tr, fxi)
  local matched = {}
  for _, p in ipairs(params) do
    matched[#matched + 1] = {
      param    = p,
      checked  = false,
      mode     = default_mode(p.name),
      strength = (SETTINGS.default_strength or 1.0),
    }
  end
  S.params = params
  M.groups = build_groups(matched)
  M.scanned = true
end

-- Find the FX index of a named plugin on a track (-1 if not found)
local function find_fx_idx(track, plugin_name)
  if not track or not plugin_name or plugin_name == "" then return -1 end
  for j = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, nm = reaper.TrackFX_GetFXName(track, j, "")
    local clean = nm:match("^%a+3?:%s*(.+)$") or nm
    if clean == plugin_name then return j end
  end
  return -1
end

-- Create full-mesh links from scan results across all selected tracks
local function create_links_from_match()
  local tlist = get_tlist()
  if #S.tracks < 2 or S.fi == 0 or not S.fxs[S.fi] then return end
  local plugin_name = S.fxs[S.fi].name

  -- Resolve FX index and GUID per track
  local track_info = {}
  for _, ti in ipairs(S.tracks) do
    local t = tlist[ti]
    if t and t.track then
      local fxi = find_fx_idx(t.track, plugin_name)
      if fxi >= 0 then
        local fxguid = reaper.TrackFX_GetFXGUID(t.track, fxi) or ""
        track_info[#track_info + 1] = { guid = t.guid, name = t.name, fxi = fxi, fxguid = fxguid, track = t.track }
      end
    end
  end
  if #track_info < 2 then return end

  -- Build existing link set to avoid duplicates
  local existing = {}
  for _, lk in ipairs(links) do
    local k1 = lk.a_guid .. "|" .. lk.a_fxi .. "|" .. lk.a_pi .. "|" .. lk.b_guid .. "|" .. lk.b_fxi .. "|" .. lk.b_pi
    local k2 = lk.b_guid .. "|" .. lk.b_fxi .. "|" .. lk.b_pi .. "|" .. lk.a_guid .. "|" .. lk.a_fxi .. "|" .. lk.a_pi
    existing[k1] = true
    existing[k2] = true
  end

  local created_any = false
  for _, grp in ipairs(M.groups) do
    for _, item in ipairs(grp.params) do
      if item.checked then
        for i = 1, #track_info do
          for j = i + 1, #track_info do
            local ta = track_info[i]
            local tb = track_info[j]
            local key = ta.guid .. "|" .. ta.fxi .. "|" .. item.param.idx .. "|" .. tb.guid .. "|" .. tb.fxi .. "|" .. item.param.idx
            if not existing[key] then
              links[#links + 1] = make_link({
                a_guid   = ta.guid,   a_name   = ta.name,
                a_fxi    = ta.fxi,    a_fxguid = ta.fxguid, a_fxname = plugin_name,
                a_pi     = item.param.idx, a_pname = item.param.name,
                b_guid   = tb.guid,   b_name   = tb.name,
                b_fxi    = tb.fxi,    b_fxguid = tb.fxguid, b_fxname = plugin_name,
                b_pi     = item.param.idx, b_pname = item.param.name,
                mode     = item.mode, strength = item.strength,
              })
              existing[key] = true
              local rev = tb.guid .. "|" .. tb.fxi .. "|" .. item.param.idx .. "|" .. ta.guid .. "|" .. ta.fxi .. "|" .. item.param.idx
              existing[rev] = true
              created_any = true
            end
          end
        end
      end
    end
  end

  if created_any then
    invalidate_link_groups()
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
      local guid = reaper.TrackFX_GetFXGUID(track, j) or ""
      results[#results + 1] = { idx = j, name = clean, guid = guid }
    end
  end
  return results
end

-- Save preset from selected active links (unified save flow)
local function save_preset_from_links(name)
  if name == "" then return false end
  local sel_indices = {}
  for i = 1, #links do
    if link_sel[i] then sel_indices[#sel_indices + 1] = i end
  end
  if #sel_indices == 0 then return false end
  local plugin_name_val = links[sel_indices[1]].a_fxname
  for _, idx in ipairs(sel_indices) do
    if links[idx].a_fxname ~= plugin_name_val then
      reaper.ShowMessageBox(
        "Select links from a single plugin to save as a preset.\n\n"
        .. "Found: '" .. plugin_name_val .. "' and '" .. links[idx].a_fxname .. "'",
        "Preset Save", 0)
      return false
    end
  end
  local seen, params = {}, {}
  for _, idx in ipairs(sel_indices) do
    local lk = links[idx]
    local key = lk.a_pname
    if not seen[key] then
      seen[key] = true
      params[#params + 1] = {
        pname    = lk.a_pname,
        mode     = lk.mode,
        strength = lk.strength,
      }
    end
  end
  if #params == 0 then return false end
  Presets.list[#Presets.list + 1] = {
    name        = name,
    plugin_name = plugin_name_val,
    params      = params,
  }
  return true
end

-- Apply preset directly: find FX on tracks, resolve params, create links
local function apply_preset_direct(preset)
  if not preset or not preset.params or not preset.plugin_name then return false end
  local tlist = get_tlist()

  -- Resolve tracks from S.tracks or REAPER selection
  local track_entries = {}
  if #S.tracks >= 2 then
    for _, ti in ipairs(S.tracks) do
      if ti > 0 and ti <= #tlist and tlist[ti] and tlist[ti].track then
        track_entries[#track_entries + 1] = tlist[ti]
      end
    end
  end
  if #track_entries < 2 then
    track_entries = {}
    local n_sel = reaper.CountSelectedTracks(0)
    for i = 0, n_sel - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      if tr then
        local _, nm = reaper.GetTrackName(tr)
        track_entries[#track_entries + 1] = { track = tr, name = nm, guid = reaper.GetTrackGUID(tr) }
      end
    end
  end
  if #track_entries < 2 then
    reaper.ShowMessageBox(
      "Please select at least 2 tracks (via the pickers or by selecting tracks in REAPER).",
      "Preset Apply", 0)
    return false
  end

  -- Resolve FX on each track
  local track_info = {}
  local missing_tracks = {}
  for _, te in ipairs(track_entries) do
    local fxs = find_fx_by_name(te.track, preset.plugin_name)
    if #fxs > 0 then
      track_info[#track_info + 1] = { guid = te.guid, name = te.name, track = te.track, fxi = fxs[1].idx, fxguid = fxs[1].guid }
    else
      missing_tracks[#missing_tracks + 1] = te.name
    end
  end
  if #track_info < 2 then
    reaper.ShowMessageBox(
      "Plugin '" .. preset.plugin_name .. "' not found on enough tracks.\nMissing on: " .. table.concat(missing_tracks, ", "),
      "Preset Apply", 0)
    return false
  end

  -- Build param lookup from first track
  local first_params = param_list(track_info[1].track, track_info[1].fxi)
  local param_map = {}
  for _, p in ipairs(first_params) do param_map[p.name] = p end

  -- Build existing link set
  local existing = {}
  for _, lk in ipairs(links) do
    local k1 = lk.a_guid .. "|" .. lk.a_fxi .. "|" .. lk.a_pi .. "|" .. lk.b_guid .. "|" .. lk.b_fxi .. "|" .. lk.b_pi
    local k2 = lk.b_guid .. "|" .. lk.b_fxi .. "|" .. lk.b_pi .. "|" .. lk.a_guid .. "|" .. lk.a_fxi .. "|" .. lk.a_pi
    existing[k1] = true
    existing[k2] = true
  end

  local created, skipped, total = 0, 0, 0
  for _, tp in ipairs(preset.params) do
    local pname = tp.pname or tp.src_pname  -- compat with old presets
    local p = param_map[pname]
    if p then
      for i = 1, #track_info do
        for j = i + 1, #track_info do
          total = total + 1
          local ta = track_info[i]
          local tb = track_info[j]
          local key = ta.guid .. "|" .. ta.fxi .. "|" .. p.idx .. "|" .. tb.guid .. "|" .. tb.fxi .. "|" .. p.idx
          if existing[key] then
            skipped = skipped + 1
          else
            links[#links + 1] = make_link({
              a_guid   = ta.guid,   a_name   = ta.name,
              a_fxi    = ta.fxi,    a_fxguid = ta.fxguid, a_fxname = preset.plugin_name,
              a_pi     = p.idx,     a_pname  = p.name,
              b_guid   = tb.guid,   b_name   = tb.name,
              b_fxi    = tb.fxi,    b_fxguid = tb.fxguid, b_fxname = preset.plugin_name,
              b_pi     = p.idx,     b_pname  = p.name,
              mode     = tp.mode,   strength = tp.strength,
            })
            existing[key] = true
            local rev = tb.guid .. "|" .. tb.fxi .. "|" .. p.idx .. "|" .. ta.guid .. "|" .. ta.fxi .. "|" .. p.idx
            existing[rev] = true
            created = created + 1
          end
        end
      end
    end
  end
  if created > 0 then
    invalidate_link_groups()
    save_links()
  end
  if skipped == total then
    preset_status_msg = string.format("Preset '%s': all links already exist", preset.name)
  elseif created == total then
    preset_status_msg = string.format("Preset '%s': %d links created \xe2\x9c\x93", preset.name, created)
  elseif created > 0 then
    local parts = {}
    parts[#parts + 1] = string.format("%d created", created)
    if skipped > 0 then parts[#parts + 1] = string.format("%d already existed", skipped) end
    preset_status_msg = string.format("Preset '%s': %s", preset.name, table.concat(parts, ", "))
  else
    preset_status_msg = string.format("Preset '%s': no matching params found", preset.name)
  end
  preset_status_time = reaper.time_precise()
  return created > 0
end

-- Fill builder state from Last Touched
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

  -- Add to selected tracks if not already there
  local already = false
  for _, ti in ipairs(S.tracks) do
    if ti == found_ti then already = true; break end
  end
  if not already then
    S.tracks[#S.tracks + 1] = found_ti
  end

  -- Recompute shared FX and try to match the touched plugin
  compute_shared_fxs()
  local _, fxname = reaper.TrackFX_GetFXName(tr, real_fxi, "")
  local clean_name = fxname:match("^%a+3?:%s*(.+)$") or fxname
  S.fi = 0
  for j, f in ipairs(S.fxs) do
    if f.name == clean_name then S.fi = j; break end
  end

  -- Trigger scan if plugin found and 2+ tracks
  if S.fi > 0 and #S.tracks >= 2 then
    do_scan()
    -- Check the touched parameter and force its group open
    local _, pname = reaper.TrackFX_GetParamName(tr, real_fxi, paramnum, "")
    for _, grp in ipairs(M.groups) do
      local grp_match = false
      for _, item in ipairs(grp.params) do
        if item.param.idx == paramnum or item.param.name == pname then
          item.checked   = true
          grp_match      = true
          _scroll_to_param_idx = item.param.idx
        end
      end
      grp.force_open = grp_match
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
local SETTINGS_PATH      = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/_fancy_ipl_settings.json"

local function write_file(path, content)
  local dir = path:match([[^(.*[\/])[^\/]-$]])
  if dir and dir ~= "" then
    reaper.RecursiveCreateDirectory(dir, 0)
  end
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
      label       = lk.label or "",
      a_guid      = lk.a_guid or "",
      a_name      = lk.a_name or "?",
      a_fxi       = lk.a_fxi or 0,
      a_fxguid    = lk.a_fxguid or "",
      a_fxname    = lk.a_fxname or "?",
      a_pi        = lk.a_pi or 0,
      a_pname     = lk.a_pname or "?",
      b_guid      = lk.b_guid or "",
      b_name      = lk.b_name or "?",
      b_fxi       = lk.b_fxi or 0,
      b_fxguid    = lk.b_fxguid or "",
      b_fxname    = lk.b_fxname or "?",
      b_pi        = lk.b_pi or 0,
      b_pname     = lk.b_pname or "?",
      mode        = lk.mode or "inverse",
      strength    = lk.strength or 1.0,
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
  if not raw then links = {}; invalidate_link_groups(); return end
  local ok, data = pcall(JSON.decode, raw)
  if not ok or type(data) ~= "table" then links = {}; invalidate_link_groups(); return end
  links = {}
  for _, d in ipairs(data) do
    if type(d) == "table" then
      links[#links + 1] = make_link(d)
    end
  end
  invalidate_link_groups()
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
  write_file(PRESET_PATH, JSON.encode(Presets.list))
end

local function load_presets()
  local raw = read_file(PRESET_PATH)
  if not raw then return end
  local ok, data = pcall(JSON.decode, raw)
  if ok and type(data) == "table" then
    Presets.list = data
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
      if type(d) == "table" and d.a_guid and d.b_guid then
        links[#links + 1] = make_link(d)
        added = added + 1
      end
    end
    invalidate_link_groups()
    save_links()
    reaper.ShowMessageBox(string.format("Successfully imported %d links!", added), "Import Success", 0)
  end
end

-------------------------------------------------------------------------------
-- 6. LINK ENGINE (Bidirectional)
-------------------------------------------------------------------------------
local function apply_links()
  if paused or #links == 0 then return end
  for _, lk in ipairs(links) do
    if not lk.link_paused then
      local tra = tr_by_guid(lk.a_guid)
      local trb = tr_by_guid(lk.b_guid)
      if tra and trb then
        local fxi_a = resolve_fx(tra, lk.a_fxi, lk.a_fxguid)
        local fxi_b = resolve_fx(trb, lk.b_fxi, lk.b_fxguid)
        if fxi_a >= 0 and fxi_b >= 0 then
          lk.a_fxi = fxi_a
          lk.b_fxi = fxi_b
          local av = reaper.TrackFX_GetParamNormalized(tra, fxi_a, lk.a_pi)
          local bv = reaper.TrackFX_GetParamNormalized(trb, fxi_b, lk.b_pi)
          local dir = (lk.mode == "follow") and 1.0 or -1.0
          local st  = lk.strength or 1.0

          local a_changed = (lk.last_a ~= av)
          local b_changed = (lk.last_b ~= bv)

          if a_changed and not b_changed then
            -- A is driving -> compute and write B
            lk.last_a = av
            local nv = math.max(0, math.min(1, 0.5 + dir * st * (av - 0.5)))
            reaper.TrackFX_SetParamNormalized(trb, fxi_b, lk.b_pi, nv)
            lk.last_b = nv
          elseif b_changed and not a_changed then
            -- B is driving -> compute and write A
            lk.last_b = bv
            local nv = math.max(0, math.min(1, 0.5 + dir * st * (bv - 0.5)))
            reaper.TrackFX_SetParamNormalized(tra, fxi_a, lk.a_pi, nv)
            lk.last_a = nv
          elseif a_changed and b_changed then
            -- Both changed (initialization or concurrent update) -- record without fighting
            lk.last_a = av
            lk.last_b = bv
          end
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- 7. TRACK SELECTOR (Multi-track)
-------------------------------------------------------------------------------
local function draw_track_selector(tlist)
  local P = Theme.get_palette()
  -- Action row: Add Tracks multi-combo + Use Selected on same line
  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local use_sel_text = "Use Selected"
  local text_w = reaper.ImGui_CalcTextSize(ctx, use_sel_text)
  local use_sel_w = math.ceil(text_w + L.md * 2)
  local combo_w = avail_w - use_sel_w - L.md

  local toggled_idx, is_now_selected = Theme.multi_combo(ctx, "##add_track", tlist, S.tracks, {
    w = combo_w,
    placeholder = "+ Add Tracks...",
    preview = "+ Add Tracks...",
  })

  if toggled_idx then
    if is_now_selected then
      local already = false
      for _, ti in ipairs(S.tracks) do
        if ti == toggled_idx then already = true; break end
      end
      if not already then S.tracks[#S.tracks + 1] = toggled_idx end
    else
      for si, ti in ipairs(S.tracks) do
        if ti == toggled_idx then
          table.remove(S.tracks, si)
          break
        end
      end
    end
    compute_shared_fxs()
    -- Try to preserve FX selection
    local cur_name = (S.fi > 0 and S.fxs[S.fi]) and S.fxs[S.fi].name or nil
    if cur_name then
      S.fi = 0
      for fi, f in ipairs(S.fxs) do
        if f.name == cur_name then S.fi = fi; break end
      end
    else
      S.fi = 0
    end
    M.scanned = false
    M.groups = {}
  end

  reaper.ImGui_SameLine(ctx, 0, L.md)
  if reaper.ImGui_Button(ctx, use_sel_text, use_sel_w, 0) then
    S.tracks = {}
    local n_sel = reaper.CountSelectedTracks(0)
    for i = 0, n_sel - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      if tr then
        local tguid = reaper.GetTrackGUID(tr)
        for j, t in ipairs(tlist) do
          if t.guid == tguid then
            S.tracks[#S.tracks + 1] = j
            break
          end
        end
      end
    end
    compute_shared_fxs()
    S.fi = 0
    M.scanned = false
    M.groups = {}
  end

  reaper.ImGui_Dummy(ctx, 0, L.sm)

  -- Collapsible track list (below action buttons)
  if #S.tracks == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_Text(ctx, "  No tracks selected")
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    -- Collapsible header row (same pattern as Active Links table)
    local arrow = S.tracks_expanded and "\xe2\x96\xbe" or "\xe2\x96\xb8"
    local n = #S.tracks
    local summary = string.format("%s %d track%s selected", arrow, n, n == 1 and "" or "s")

    if reaper.ImGui_BeginTable(ctx, "trk_hdr", 2, reaper.ImGui_TableFlags_None()) then
      reaper.ImGui_TableSetupColumn(ctx, "##label", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "##clear", reaper.ImGui_TableColumnFlags_WidthFixed(), UI.del_col_w)
      reaper.ImGui_TableNextRow(ctx, 0, L.row_h)

      reaper.ImGui_TableSetColumnIndex(ctx, 0)
      local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                      | reaper.ImGui_SelectableFlags_AllowOverlap()
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
      if reaper.ImGui_Selectable(ctx, summary .. "##trk_toggle", false, sel_flags, 0, L.row_h) then
        S.tracks_expanded = not S.tracks_expanded
      end
      reaper.ImGui_PopStyleColor(ctx, 1)

      reaper.ImGui_TableSetColumnIndex(ctx, 1)
      Theme.align(ctx, L.row_h, L.icon_sm.size + L.icon_sm.pad * 2)
      if Theme.icon_btn(ctx, "trk_clear", Theme.icons.close, {
        preset = L.icon_sm,
        color = P.text_dim,
        tooltip = "Clear all tracks",
      }) then
        S.tracks = {}
        compute_shared_fxs()
        S.fi = 0
        M.scanned = false
        M.groups = {}
        S.tracks_expanded = false
      end

      reaper.ImGui_EndTable(ctx)
    end

    -- Expanded: compact vertical track list
    if S.tracks_expanded then
      local to_remove = nil
      if reaper.ImGui_BeginTable(ctx, "trk_list", 2, reaper.ImGui_TableFlags_None()) then
        reaper.ImGui_TableSetupColumn(ctx, "##name", reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, "##del",  reaper.ImGui_TableColumnFlags_WidthFixed(), UI.chk_col_w)

        for si, ti in ipairs(S.tracks) do
          local t = tlist[ti]
          reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          Theme.align(ctx, L.row_h)
          reaper.ImGui_Text(ctx, t and t.name or "?")
          reaper.ImGui_TableSetColumnIndex(ctx, 1)
          Theme.align(ctx, L.row_h, L.icon_sm.size + L.icon_sm.pad * 2)
          if Theme.icon_btn(ctx, "trk_rm" .. si, Theme.icons.close, {
            preset = L.icon_sm,
            color = P.text_dim,
          }) then
            to_remove = si
          end
        end
        reaper.ImGui_EndTable(ctx)
      end
      if to_remove then
        table.remove(S.tracks, to_remove)
        compute_shared_fxs()
        -- Re-validate FX selection
        if S.fi > 0 and S.fi > #S.fxs then S.fi = 0 end
        M.scanned = false
        M.groups = {}
      end
    end
  end
end

-------------------------------------------------------------------------------
-- 8. PLUGIN SELECTOR
-------------------------------------------------------------------------------
local function draw_plugin_selector()
  local P = Theme.get_palette()
  if #S.tracks >= 2 then
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local new_fi, chg = Theme.combo(ctx, "##shared_fx", S.fxs, S.fi)
    if chg then
      S.fi = new_fi
      M.scanned = false
      M.groups = {}
    end

    if #S.fxs == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.red)
      reaper.ImGui_TextWrapped(ctx, "  * No shared plugins across selected tracks")
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
  elseif #S.tracks == 1 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(ctx, "Select at least 2 tracks to link parameters.")
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(ctx, "Select tracks first.")
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
end

-------------------------------------------------------------------------------
-- 9. LINK BUILDER
-------------------------------------------------------------------------------
local function draw_link_builder()
  local P = Theme.get_palette()
  local plugins_ready = (S.fi > 0 and #S.tracks >= 2)

  if not plugins_ready then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    if #S.tracks < 2 then
      reaper.ImGui_TextWrapped(ctx, "Select at least 2 tracks above, then select a shared plugin.")
    else
      reaper.ImGui_TextWrapped(ctx, "Select a plugin above.")
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)
    return
  end

  -- Auto-scan whenever plugins are selected and result is stale
  if not M.scanned then do_scan() end

  -- Search filter + Expand/Collapse All + Last Touched button
  reaper.ImGui_SetNextItemWidth(ctx, -210)
  local fr, nf = reaper.ImGui_InputTextWithHint(ctx, "##mf", "Search parameters...", M.filter, 256)
  if fr then M.filter = nf end

  reaper.ImGui_SameLine(ctx, 0, L.sm)
  if Theme.icon_btn_colored(ctx, "exp_all", Theme.icons.tri_down, {
    w = L.xxl,
    h = 0,
    icon_size = 10,
    icon_color = P.text,
    bg = P.card,
    bg_hover = P.panel,
    bg_active = P.accent_d,
    tooltip = "Expand All Groups",
  }) then
    for _, g in ipairs(M.groups) do g.force_open = true end
  end

  reaper.ImGui_SameLine(ctx, 0, L.xs)
  if Theme.icon_btn_colored(ctx, "col_all", Theme.icons.tri_up, {
    w = L.xxl,
    h = 0,
    icon_size = 10,
    icon_color = P.text,
    bg = P.card,
    bg_hover = P.panel,
    bg_active = P.accent_d,
    tooltip = "Collapse All Groups",
  }) then
    for _, g in ipairs(M.groups) do g.force_open = false end
  end

  reaper.ImGui_SameLine(ctx, 0, L.sm)
  if reaper.ImGui_Button(ctx, "Last Touched##lb_lt", 100, 0) then
    use_last_touched_builder()
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    poll_last_touched()
    if reaper.ImGui_BeginTooltip(ctx) then
      reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + L.tooltip_wrap)
      if LT.track ~= "" then
        local lt_val = LT.tr and fmt_val(LT.tr, LT.fxi, LT.pi, LT.norm) or "?"
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, "Last Touched:")
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, LT.track .. " / " .. LT.fx .. " / " .. LT.param .. " = " .. lt_val)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, "Click to add track and select parameter")
        reaper.ImGui_PopStyleColor(ctx, 1)
      else
        reaper.ImGui_Text(ctx, "Touch a plugin parameter, then click to use it")
      end
      reaper.ImGui_PopTextWrapPos(ctx)
      reaper.ImGui_EndTooltip(ctx)
    end
  end

  reaper.ImGui_SameLine(ctx, 0, L.xs)
  if #M.groups == 0 then reaper.ImGui_BeginDisabled(ctx) end
  if reaper.ImGui_Button(ctx, "All##lb_all", L.xxxl, 0) then
    local all_checked = true
    for _, grp in ipairs(M.groups) do
      for _, item in ipairs(grp.params) do
        if not item.checked then all_checked = false; break end
      end
      if not all_checked then break end
    end
    local new_state = not all_checked
    for _, grp in ipairs(M.groups) do
      for _, item in ipairs(grp.params) do item.checked = new_state end
    end
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    Theme.tooltip(ctx, "Select / deselect all parameters")
  end
  if #M.groups == 0 then reaper.ImGui_EndDisabled(ctx) end

  reaper.ImGui_Spacing(ctx)

  -- Scrollable param list
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local list_h = math.max(80, avail_h - 45)

  if reaper.ImGui_BeginChild(ctx, "lb_list", 0, list_h) then
    if #M.groups == 0 then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
      reaper.ImGui_Text(ctx, "  No parameters found.")
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local flo = M.filter:lower()
      for gi, grp in ipairs(M.groups) do
        local grp_has_match = false
        for _, item in ipairs(grp.params) do
          local dn = item.param.name
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
          reaper.ImGui_SameLine(ctx, 0, L.sm)

          if flo ~= "" then
            reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Always())
          elseif grp.force_open ~= nil then
            reaper.ImGui_SetNextItemOpen(ctx, grp.force_open, reaper.ImGui_Cond_Always())
            grp.force_open = nil
          end

          local hdr_label = string.format("%s  (%d)##gh%d", grp.name, #grp.params, gi)
          local is_open = Theme.collapsing_header(ctx, hdr_label)

          if is_open then
            reaper.ImGui_Indent(ctx, UI.indent_w)
            if reaper.ImGui_BeginTable(ctx, "ptbl_" .. gi, 2, reaper.ImGui_TableFlags_None()) then
              reaper.ImGui_TableSetupColumn(ctx, "##chk",   reaper.ImGui_TableColumnFlags_WidthFixed(), UI.chk_col_w)
              reaper.ImGui_TableSetupColumn(ctx, "##pname", reaper.ImGui_TableColumnFlags_WidthStretch())

              for pi, item in ipairs(grp.params) do
                local disp = item.param.name
                if grp.name ~= "(General)" then
                  local w = disp:sub(#grp.name + 2)
                  if w ~= "" then disp = w end
                end
                local matches_search = (flo == "") or grp.name:lower():find(flo, 1, true) or disp:lower():find(flo, 1, true)
                if matches_search then
                  reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
                  reaper.ImGui_TableSetColumnIndex(ctx, 0)
                  local ck, nc2 = reaper.ImGui_Checkbox(ctx, "##ck" .. gi .. "_" .. pi, item.checked)
                  if ck then item.checked = nc2 end
                  reaper.ImGui_TableSetColumnIndex(ctx, 1)
                  Theme.align(ctx, L.row_h)
                  if reaper.ImGui_Selectable(ctx, disp .. "##psel" .. gi .. "_" .. pi, item.checked, reaper.ImGui_SelectableFlags_None()) then
                    item.checked = not item.checked
                  end
                  -- Scroll to this param if it was the Last Touched target
                  if _scroll_to_param_idx ~= nil and item.param.idx == _scroll_to_param_idx then
                    reaper.ImGui_SetScrollHereY(ctx, 0.5)
                    _scroll_to_param_idx = nil
                  end
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
  local total_params = count_checked_params()
  local n_tracks = #S.tracks
  local n_pairs = (n_tracks * (n_tracks - 1)) / 2
  local total_links = total_params * n_pairs
  reaper.ImGui_Spacing(ctx)

  if total_links == 0 then reaper.ImGui_BeginDisabled(ctx) end
  local lbl = string.format("Add %d Link%s across %d Tracks", total_links, total_links == 1 and "" or "s", n_tracks)
  if reaper.ImGui_Button(ctx, lbl, -1, 0) and total_links > 0 then
    create_links_from_match()
    save_links()
    for _, grp in ipairs(M.groups) do
      for _, item in ipairs(grp.params) do item.checked = false end
    end
  end
  if total_links == 0 then reaper.ImGui_EndDisabled(ctx) end

  reaper.ImGui_Spacing(ctx)
end

-------------------------------------------------------------------------------
-- 10. MODAL DIALOGS (Preset Manager, Info & Guide, Settings)
-------------------------------------------------------------------------------
local function draw_preset_modal()
  local P = Theme.get_palette()
  if show_preset_modal then
    reaper.ImGui_OpenPopup(ctx, "Preset Library##preset_mgr_modal")
    show_preset_modal = false
  end

  Theme.center_next_window(ctx, L.modal_lg.w, 420)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Preset Library##preset_mgr_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
    reaper.ImGui_Text(ctx, string.format("Saved Presets (%d)", #Presets.list))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
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

      if #Presets.list == 0 then
        reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, "No presets saved yet. Save from Active Links.")
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      local to_del_p = nil
      for pi, preset in ipairs(Presets.list) do
        reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        Theme.align(ctx, L.row_h)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (Presets.sel == pi) and P.accent or P.text)
        reaper.ImGui_Text(ctx, preset.name)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        Theme.align(ctx, L.row_h)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        local pname_display = preset.plugin_name or "--"
        reaper.ImGui_Text(ctx, (pname_display ~= "") and pname_display or "--")
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_TableSetColumnIndex(ctx, 2)
        Theme.align(ctx, L.row_h)
        reaper.ImGui_Text(ctx, tostring(#(preset.params or {})))

        reaper.ImGui_TableSetColumnIndex(ctx, 3)
        Theme.align(ctx, L.row_h, L.btn_sm.h)
        if reaper.ImGui_SmallButton(ctx, "Apply##papply" .. pi) then
          Presets.sel = pi
          apply_preset_direct(preset)
        end
        reaper.ImGui_SameLine(ctx, 0, L.sm)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        P.red_d)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  P.red)
        if reaper.ImGui_SmallButton(ctx, "Del##pdel" .. pi) then
          to_del_p = pi
        end
        reaper.ImGui_PopStyleColor(ctx, 3)
      end

      if to_del_p then
        table.remove(Presets.list, to_del_p)
        if Presets.sel > #Presets.list then Presets.sel = #Presets.list end
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
  local P = Theme.get_palette()
  if show_info_modal then
    reaper.ImGui_OpenPopup(ctx, "Fancy Parameter Link -- Info & Guide##info_modal")
    show_info_modal = false
  end

  Theme.center_next_window(ctx, 600, 380)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Fancy Parameter Link -- Info & Guide##info_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    if reaper.ImGui_BeginTabBar(ctx, "info_tab_bar") then
      if reaper.ImGui_BeginTabItem(ctx, "Quick Start Guide") then
        reaper.ImGui_Spacing(ctx)

        local pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "1. Select Tracks")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Add 2 or more tracks using the track selector, or click 'Use Selected' to import your current track selection.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "2. Select Plugin")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Choose the plugin that's on all selected tracks. The script shows only plugins common to every track.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "3. Select Parameters")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Check individual parameters or entire groups. Use the search bar to filter by name.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "4. Add Links")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Click 'Add Links' to create bidirectional links across all track pairs. Move any linked knob and all others follow (or inverse).")

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Modes & Tips") then
        reaper.ImGui_Spacing(ctx)

        local pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.green)
        reaper.ImGui_Text(ctx, "Follow Mode")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Linked parameters move in the same direction (1:1 tracking). Move any linked knob and all others follow.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent)
        reaper.ImGui_Text(ctx, "Inverse Mode")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Parameters move inversely around center (0.5). Ideal for complementary EQ, wet/dry crossfades, and dynamic frequency balancing.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "Bidirectional Links")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "All links are bidirectional. Move the parameter on any linked track and the others update automatically. No need to designate a 'source' or 'target'.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        pf = Theme.push_font(ctx, fonts.default_bold)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, "Multi-Track Linking")
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf)
        reaper.ImGui_TextWrapped(ctx, "Select any number of tracks. Links are created for every pair (full mesh). 3 tracks = 3 links, 4 tracks = 6 links per parameter.")

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "About") then
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
        local content_h = 160
        local top_pad = math.max(L.md, math.floor((avail_h - content_h) * 0.5))
        reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + top_pad)
        local icon_sz = L.xxxl + L.sm -- 36
        Theme.hcenter(ctx, icon_sz)
        Theme.brand_icon(ctx, icon_sz)
        reaper.ImGui_Spacing(ctx)

        local pf1 = Theme.push_font(ctx, fonts.large_bold)
        local t1 = "FANCY "
        local t2 = "PARAMETER LINK"
        local w1 = reaper.ImGui_CalcTextSize(ctx, t1)
        local w2 = reaper.ImGui_CalcTextSize(ctx, t2)
        local total_tw = w1 + w2
        Theme.hcenter(ctx, total_tw)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, t1)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text)
        reaper.ImGui_Text(ctx, t2)
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf1)

        local sub = "v5.2.0 crafted by Fancy Wolf Audio & Antigravity for REAPER"
        local sw = reaper.ImGui_CalcTextSize(ctx, sub)
        Theme.hcenter(ctx, sw)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, sub)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Spacing(ctx)

        local prompt = "Find this useful?"
        local pw = reaper.ImGui_CalcTextSize(ctx, prompt)
        Theme.hcenter(ctx, pw)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), Theme.with_alpha(P.text, 0.8))
        reaper.ImGui_Text(ctx, prompt)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Spacing(ctx)
        local btn_w = 240
        Theme.hcenter(ctx, btn_w)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        P.card)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.panel)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  P.accent_d)
        if reaper.ImGui_Button(ctx, "Buy me a Cup of Coffee as Thanks", btn_w, 0) then
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
  local P = Theme.get_palette()
  if show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, "Settings & Preferences##settings_modal")
    show_settings_modal = false
  end

  Theme.center_next_window(ctx, 620, 560)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, "Settings & Preferences##settings_modal", true, reaper.ImGui_WindowFlags_None())
  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_Spacing(ctx)

    Theme.section_divider(ctx, "Default Link Rules", { color = P.yellow })

    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Inverse Gain by Default:")
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    local is_yes = (SETTINGS.default_mode ~= "follow")
    if reaper.ImGui_RadioButton(ctx, "Yes##inv_gain_yes", is_yes) then
      SETTINGS.default_mode = "smart"
      save_settings()
    end
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    if reaper.ImGui_RadioButton(ctx, "No##inv_gain_no", not is_yes) then
      SETTINGS.default_mode = "follow"
      save_settings()
    end

    reaper.ImGui_Spacing(ctx)
    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Default Strength:")
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local s_pct = (SETTINGS.default_strength or 1.0) * 100
    local sc, np = reaper.ImGui_SliderDouble(ctx, "##def_st", s_pct, 0, 100, "%.0f%%")
    if sc then
      SETTINGS.default_strength = np / 100
      save_settings()
    end

    reaper.ImGui_Dummy(ctx, 0, L.lg)

    Theme.section_divider(ctx, "Last Touched Automation", { color = P.yellow })

    local ck_at, n_at = reaper.ImGui_Checkbox(ctx, "Auto-add track and select parameter when touching FX", SETTINGS.auto_touch_sync)
    if ck_at then
      SETTINGS.auto_touch_sync = n_at
      save_settings()
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(ctx, "When enabled, touching any plugin control in REAPER automatically adds its track and selects the parameter in the Link Builder.")
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_Dummy(ctx, 0, L.lg)

    Theme.section_divider(ctx, "UI Density & Appearance", { color = P.yellow })

    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Theme Mode:")
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    Theme.settings_widget(ctx, { label = "##theme_mode_settings" })

    reaper.ImGui_Spacing(ctx)
    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Table Row Height:")
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    if reaper.ImGui_RadioButton(ctx, "Compact (20px)##rh20", SETTINGS.row_height == 20) then
      SETTINGS.row_height = 20
      save_settings()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_RadioButton(ctx, "Standard (24px)##rh24", SETTINGS.row_height == 24) then
      SETTINGS.row_height = 24
      save_settings()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_RadioButton(ctx, "Comfortable (28px)##rh28", SETTINGS.row_height == 28) then
      SETTINGS.row_height = 28
      save_settings()
    end

    reaper.ImGui_Dummy(ctx, 0, L.lg)

    Theme.section_divider(ctx, "File Storage & Backups", { color = P.yellow })

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_Text(ctx, "Project Config: " .. sav_path())
    reaper.ImGui_Text(ctx, "Presets File: " .. PRESET_PATH)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)

    if reaper.ImGui_Button(ctx, "Open Config Folder", 180, 0) then
      open_config_folder()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_Button(ctx, "Export Links JSON...", 150, 0) then
      export_links_dialog()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
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
-- 11. MAIN WINDOW
-------------------------------------------------------------------------------

-- Build grouped view of active links: group by (plugin, parameter) with caching
local function get_link_groups()
  if not _link_groups_dirty and _cached_link_groups then
    return _cached_link_groups
  end
  local groups = {}
  local group_map = {}
  for i, lk in ipairs(links) do
    local key = lk.a_fxname .. "|" .. lk.a_pname
    if not group_map[key] then
      group_map[key] = { plugin = lk.a_fxname, param = lk.a_pname, links = {}, open = true }
      groups[#groups + 1] = group_map[key]
    end
    group_map[key].links[#group_map[key].links + 1] = { idx = i, lk = lk }
  end
  _cached_link_groups = groups
  _link_groups_dirty  = false
  return _cached_link_groups
end

local _current_proj = ""

local function draw_main()
  local P = Theme.get_palette()
  local nc, nv = Theme.push(ctx, P)
  local pushed_default = Theme.push_font(ctx, fonts.default)

  -- Track project tab switching
  local _, cur_proj = reaper.EnumProjects(-1, "")
  if _current_proj ~= "" and cur_proj ~= _current_proj then
    save_links()
    _current_proj = cur_proj
    load_links()
  else
    _current_proj = cur_proj
  end

  reaper.ImGui_SetNextWindowSize(ctx, UI.win_w, UI.win_h, reaper.ImGui_Cond_Once())

  local vis, op = reaper.ImGui_Begin(ctx, "Fancy Parameter Link", true, reaper.ImGui_WindowFlags_NoCollapse())
  if vis then
    poll_last_touched()

    -- Subtitle text logic (selection count or status toast)
    local subtitle_text = nil
    local subtitle_col = nil
    local sel_count_hdr = 0
    for i = 1, #links do if link_sel[i] then sel_count_hdr = sel_count_hdr + 1 end end

    if preset_status_msg ~= "" then
      local elapsed = reaper.time_precise() - preset_status_time
      if elapsed < 4.0 then
        local alpha = math.max(0, math.min(1, 1.0 - (elapsed - 3.0)))
        local base_col = (preset_status_msg:find("\xe2\x9c\x93") and P.green) or P.yellow
        subtitle_col = (elapsed > 3.0) and Theme.with_alpha(base_col, alpha) or base_col
        subtitle_text = preset_status_msg
      else
        preset_status_msg = ""
      end
    end

    if not subtitle_text and sel_count_hdr > 0 then
      subtitle_text = string.format("%d selected", sel_count_hdr)
      subtitle_col = P.text_dim
    end

    local right_w = UI.btn_info_w + UI.btn_sett_w + L.sm
    Theme.header(ctx, {
      title          = "PARAMETER LINK",
      fonts          = fonts,
      subtitle       = subtitle_text,
      subtitle_color = subtitle_col,
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
      show_separator = true,
    })

    -- Two-column resizable body
    local split_flags = reaper.ImGui_TableFlags_Resizable()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(), Theme.with_alpha(P.card, 0))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(),  Theme.with_alpha(P.card, 0))
    if reaper.ImGui_BeginTable(ctx, "main_split_tbl", 2, split_flags) then
      reaper.ImGui_TableSetupColumn(ctx, "LeftPane",  reaper.ImGui_TableColumnFlags_WidthStretch(), 0.25)
      reaper.ImGui_TableSetupColumn(ctx, "RightPane", reaper.ImGui_TableColumnFlags_WidthStretch(), 0.75)
      reaper.ImGui_TableNextRow(ctx)

      -- LEFT: track selector + link builder
      reaper.ImGui_TableSetColumnIndex(ctx, 0)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), P.bg)
      local lvis = reaper.ImGui_BeginChild(ctx, "left_col", 0, 0)
      reaper.ImGui_PopStyleColor(ctx, 1)
      if lvis then
        local tlist = get_tlist()

        Theme.section_divider(ctx, "Tracks", {
          color = P.yellow,
          tooltip = "Select 2 or more tracks that share the same plugin. Links are created for every pair.",
        })
        draw_track_selector(tlist)

        reaper.ImGui_Dummy(ctx, 0, L.lg)

        Theme.section_divider(ctx, "Plugin", {
          color = P.yellow,
          tooltip = "Choose the plugin shared across all selected tracks.",
        })
        draw_plugin_selector()

        reaper.ImGui_Dummy(ctx, 0, L.lg)

        Theme.section_divider(ctx, "Link Builder", {
          color = P.yellow,
          tooltip = "Select parameters to link across all selected tracks.",
        })
        draw_link_builder()

        reaper.ImGui_EndChild(ctx)
      end

      -- RIGHT: active links (grouped by parameter)
      reaper.ImGui_TableSetColumnIndex(ctx, 1)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), P.bg)
      local rvis = reaper.ImGui_BeginChild(ctx, "right_col", 0, 0)
      reaper.ImGui_PopStyleColor(ctx, 1)
      if rvis then
        reaper.ImGui_Spacing(ctx)

        -- Toolbar
        if Theme.toggle_button(ctx, "tb_pause_all", paused and "Resume All" or "Pause All", paused, {
          active_bg      = P.red_d,
          active_hover   = P.red_h,
          active_active  = P.red,
          active_text    = P.red_l,
          inactive_bg    = P.green_d,
          inactive_hover = P.green_h,
          inactive_active= P.green,
          inactive_text  = P.green_l,
        }) then
          paused = not paused
        end

        reaper.ImGui_SameLine(ctx, 0, L.sm)
        local no_links = (#links == 0)
        if no_links then reaper.ImGui_BeginDisabled(ctx) end
        if Theme.toggle_button(ctx, "tb_clear_all", "Clear All", true, {
          active_bg      = P.red_d,
          active_hover   = P.red_h,
          active_active  = P.red,
          active_text    = P.red_l,
        }) and not no_links then
          links = {}
          link_sel = {}
          invalidate_link_groups()
          save_links()
        end
        if no_links then reaper.ImGui_EndDisabled(ctx) end

        -- Select All / None toggle
        reaper.ImGui_SameLine(ctx, 0, L.sm)
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

        -- Delete Selected batch button
        if sel_count > 0 then
          reaper.ImGui_SameLine(ctx, 0, L.sm)
          if Theme.toggle_button(ctx, "tb_del_sel", string.format("Delete (%d)", sel_count), true, {
            active_bg      = P.red_d,
            active_hover   = P.red_h,
            active_active  = P.red,
            active_text    = P.red_l,
          }) then
            local new_links = {}
            for i = 1, #links do
              if not link_sel[i] then
                new_links[#new_links + 1] = links[i]
              end
            end
            links = new_links
            link_sel = {}
            invalidate_link_groups()
            save_links()
          end
        end

        -- Save as Preset button
        reaper.ImGui_SameLine(ctx, 0, L.sm)
        if no_links or sel_count == 0 then
          if not no_links then reaper.ImGui_BeginDisabled(ctx) end
        end
        if reaper.ImGui_Button(ctx, "Save as Preset") and sel_count > 0 then
          local first_sel = nil
          for i = 1, #links do
            if link_sel[i] then first_sel = i; break end
          end
          save_preset_name = first_sel and (links[first_sel].a_fxname .. " Link") or ""
          save_preset_popup = true
        end
        if no_links or sel_count == 0 then
          if not no_links then reaper.ImGui_EndDisabled(ctx) end
        end
        if no_links then reaper.ImGui_EndDisabled(ctx) end

        -- Preset combo (right-aligned)
        local combo_w = 154
        local menu_btn_w = L.icon_md.size + L.icon_md.pad * 2 + L.sm
        local label_w = reaper.ImGui_CalcTextSize(ctx, "Preset:")
        local total_group_w = label_w + L.sm + combo_w + L.xs + menu_btn_w
        reaper.ImGui_SameLine(ctx, 0, 0)
        Theme.right_align(ctx, total_group_w)
        Theme.align(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, "Preset:")
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, L.sm)
        reaper.ImGui_SetNextItemWidth(ctx, combo_w)
        local has_tracks = (#S.tracks >= 2) or (reaper.CountSelectedTracks(0) >= 2)
        local preview
        if not has_tracks then
          preview = "Select tracks..."
        elseif Presets.sel > 0 and Presets.sel <= #Presets.list then
          preview = Presets.list[Presets.sel].name
        else
          preview = "-- preset --"
        end
        if not has_tracks then reaper.ImGui_BeginDisabled(ctx) end
        local combo_open = reaper.ImGui_BeginCombo(ctx, "##al_preset_combo", preview)
        if combo_open then
          for i, preset in ipairs(Presets.list) do
            local pn = preset.plugin_name or ""
            local hint = (pn ~= "") and ("  [" .. pn .. "]") or ""
            local lbl  = preset.name .. hint .. "##alp" .. i
            if reaper.ImGui_Selectable(ctx, lbl, Presets.sel == i) then
              Presets.sel = i
              apply_preset_direct(preset)
            end
            if Presets.sel == i then reaper.ImGui_SetItemDefaultFocus(ctx) end
          end
          reaper.ImGui_EndCombo(ctx)
        end
        if not has_tracks then reaper.ImGui_EndDisabled(ctx) end

        -- [+] Preset menu
        reaper.ImGui_SameLine(ctx, 0, L.xs)
        if Theme.icon_btn_colored(ctx, "al_preset_menu", Theme.icons.plus, {
          w = menu_btn_w,
          h = 0,
          icon_size = 10,
          icon_color = P.text,
          bg = P.card,
          bg_hover = P.panel,
          bg_active = P.accent_d,
          tooltip = "Preset Options",
        }) then
          reaper.ImGui_OpenPopup(ctx, "al_preset_menu_popup")
        end
        if reaper.ImGui_BeginPopup(ctx, "al_preset_menu_popup") then
          if reaper.ImGui_Selectable(ctx, "Preset library...##alpm_lib") then
            show_preset_modal = true
          end
          reaper.ImGui_Separator(ctx)
          local can_del = (Presets.sel > 0 and Presets.sel <= #Presets.list)
          if not can_del then reaper.ImGui_BeginDisabled(ctx) end
          if reaper.ImGui_Selectable(ctx, "Delete preset##alpm_del") and can_del then
            table.remove(Presets.list, Presets.sel)
            if Presets.sel > #Presets.list then Presets.sel = #Presets.list end
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

        -- Save Preset popup
        if save_preset_popup then
          reaper.ImGui_OpenPopup(ctx, "Save as Preset##save_preset_popup")
          save_preset_popup = false
        end
        if reaper.ImGui_BeginPopup(ctx, "Save as Preset##save_preset_popup") then
          if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
          reaper.ImGui_Text(ctx, "Preset Name:")
          reaper.ImGui_SetNextItemWidth(ctx, 280)
          local chg, new_name = reaper.ImGui_InputTextWithHint(ctx, "##save_pn", "e.g. Inverse EQ \xe2\x80\x94 Pro-Q 4", save_preset_name, 256)
          if chg then save_preset_name = new_name end
          reaper.ImGui_Spacing(ctx)
          local can_save = (save_preset_name ~= "")
          local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())
          if not can_save then reaper.ImGui_BeginDisabled(ctx) end
          if (reaper.ImGui_Button(ctx, "Save##do_save_preset", 80, 0) or enter_pressed) and can_save then
            if save_preset_from_links(save_preset_name) then
              save_presets()
              Presets.sel = #Presets.list
              preset_status_msg = string.format("Preset '%s' saved \xe2\x9c\x93", save_preset_name)
              preset_status_time = reaper.time_precise()
              save_preset_name = ""
              link_sel = {}
            end
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
          if not can_save then reaper.ImGui_EndDisabled(ctx) end
          reaper.ImGui_SameLine(ctx, 0, L.md)
          if reaper.ImGui_Button(ctx, "Cancel##cancel_save_preset", 80, 0) then
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
          reaper.ImGui_EndPopup(ctx)
        end

        reaper.ImGui_Spacing(ctx)

        -- Active Links Table (grouped by parameter)
        local _, ah = reaper.ImGui_GetContentRegionAvail(ctx)
        local tbl_h = math.max(80, ah)
        local row_h = SETTINGS.row_height or L.row_h

        local link_groups = get_link_groups()

        if reaper.ImGui_BeginChild(ctx, "links_scroll", 0, tbl_h) then
          if #links == 0 then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
            reaper.ImGui_Text(ctx, "  No links yet.")
            reaper.ImGui_PopStyleColor(ctx, 1)
          end

          local to_del = nil
          for gi, grp in ipairs(link_groups) do
            -- Group header: Plugin / Parameter (N links)
            local grp_label = string.format("%s  /  %s  (%d)##grp%d", grp.plugin, grp.param, #grp.links, gi)
            local grp_open = Theme.collapsing_header(ctx, grp_label)

            if grp_open then
              local TFLG = reaper.ImGui_TableFlags_RowBg()
                         | reaper.ImGui_TableFlags_Borders()
                         | reaper.ImGui_TableFlags_Resizable()

              if reaper.ImGui_BeginTable(ctx, "ltbl_" .. gi, 7, TFLG) then
                reaper.ImGui_TableSetupColumn(ctx, "Track A",    reaper.ImGui_TableColumnFlags_WidthStretch(), 0.22)
                reaper.ImGui_TableSetupColumn(ctx, "Track B",    reaper.ImGui_TableColumnFlags_WidthStretch(), 0.22)
                reaper.ImGui_TableSetupColumn(ctx, "Live Values", reaper.ImGui_TableColumnFlags_WidthFixed(), UI.val_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "Mode",       reaper.ImGui_TableColumnFlags_WidthFixed(), UI.mode_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "Strength",   reaper.ImGui_TableColumnFlags_WidthFixed(), UI.str_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "##pause",    reaper.ImGui_TableColumnFlags_WidthFixed(), 28)
                reaper.ImGui_TableSetupColumn(ctx, "##del",      reaper.ImGui_TableColumnFlags_WidthFixed(), UI.del_col_w)
                reaper.ImGui_TableHeadersRow(ctx)

                for _, entry in ipairs(grp.links) do
                  local i = entry.idx
                  local lk = entry.lk
                  reaper.ImGui_PushID(ctx, i)
                  reaper.ImGui_TableNextRow(ctx, 0, row_h)
                  local tra = tr_by_guid(lk.a_guid)
                  local trb = tr_by_guid(lk.b_guid)
                  local ok  = (tra ~= nil and trb ~= nil)

                  -- Row selection (invisible selectable)
                  reaper.ImGui_TableSetColumnIndex(ctx, 0)
                  local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                                 | reaper.ImGui_SelectableFlags_AllowOverlap()
                  if reaper.ImGui_Selectable(ctx, "##sel_row", link_sel[i] == true, sel_flags, 0, row_h) then
                    local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftShift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightShift())
                    if shift and last_clicked_link > 0 and last_clicked_link ~= i then
                      local lo = math.min(last_clicked_link, i)
                      local hi = math.max(last_clicked_link, i)
                      for j = lo, hi do link_sel[j] = true end
                    else
                      link_sel[i] = (not link_sel[i]) or nil
                    end
                    last_clicked_link = i
                  end

                  local row_dimmed = lk.link_paused
                  if row_dimmed then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.45) end

                  -- Track A
                  reaper.ImGui_SameLine(ctx, 0, 0)
                  Theme.align(ctx, row_h)
                  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.green)
                  reaper.ImGui_Text(ctx, lk.a_name)
                  reaper.ImGui_PopStyleColor(ctx, 1)

                  -- Track B
                  reaper.ImGui_TableSetColumnIndex(ctx, 1)
                  Theme.align(ctx, row_h)
                  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.accent2)
                  reaper.ImGui_Text(ctx, lk.b_name)
                  reaper.ImGui_PopStyleColor(ctx, 1)

                  -- Live Values
                  reaper.ImGui_TableSetColumnIndex(ctx, 2)
                  if ok then
                    Theme.align(ctx, row_h, L.btn_sm.h)
                    local val_avail = reaper.ImGui_GetContentRegionAvail(ctx)
                    local bar_w = math.max(10, math.floor((val_avail - L.sm) * 0.5))
                    local av = reaper.TrackFX_GetParamNormalized(tra, lk.a_fxi, lk.a_pi)
                    local bv = reaper.TrackFX_GetParamNormalized(trb, lk.b_fxi, lk.b_pi)
                    Theme.badge(ctx, fmt_val(tra, lk.a_fxi, lk.a_pi, av), {
                      w = bar_w,
                      preset = L.btn_sm,
                      fonts = fonts,
                      color = P.green_l,
                      bg = P.green_d,
                      id = "va",
                    })
                    reaper.ImGui_SameLine(ctx, 0, L.sm)
                    Theme.badge(ctx, fmt_val(trb, lk.b_fxi, lk.b_pi, bv), {
                      w = bar_w,
                      preset = L.btn_sm,
                      fonts = fonts,
                      color = P.accent2_l,
                      bg = P.accent2_d,
                      id = "vb",
                    })
                  else
                    Theme.align(ctx, row_h, L.btn_sm.h)
                    Theme.badge(ctx, "OFFLINE", {
                      color = P.red_l,
                      bg = P.red_d,
                      w = -1,
                      preset = L.btn_sm,
                      fonts = fonts,
                      id = "off",
                    })
                  end

                  -- Mode
                  reaper.ImGui_TableSetColumnIndex(ctx, 3)
                  Theme.align(ctx, row_h, L.btn_sm.h)
                  local is_inv = (lk.mode ~= "follow")
                  local mode_lbl = is_inv and "Inverse" or "Follow"
                  if Theme.toggle_button(ctx, "tbl_m", mode_lbl, is_inv, {
                    w = -1,
                    preset = L.btn_sm,
                    fonts = fonts,
                    active_bg      = P.accent_d,
                    active_hover   = P.accent_h,
                    active_active  = P.accent,
                    active_text    = P.accent_l,
                    inactive_bg    = P.green_d,
                    inactive_hover = P.green_h,
                    inactive_active= P.green,
                    inactive_text  = P.green_l,
                  }) then
                    lk.mode = is_inv and "follow" or "inverse"
                    lk.last_a = nil
                    lk.last_b = nil
                    save_links()
                  end

                  -- Strength
                  reaper.ImGui_TableSetColumnIndex(ctx, 4)
                  Theme.align(ctx, row_h, L.btn_sm.h)
                  reaper.ImGui_SetNextItemWidth(ctx, -1)
                  local sp_vars, sp_font = Theme.push_button_preset(ctx, fonts, L.btn_sm)
                  local s_pct = (lk.strength or 1.0) * 100
                  local ch_s, np_s = reaper.ImGui_SliderDouble(ctx, "##tbl_s", s_pct, 0, 100, "%.0f%%")
                  Theme.pop_button_preset(ctx, sp_vars, sp_font)
                  if ch_s then
                    lk.strength = np_s / 100
                  end
                  if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                    save_links()
                  end

                  -- Pause
                  reaper.ImGui_TableSetColumnIndex(ctx, 5)
                  if row_dimmed then reaper.ImGui_PopStyleVar(ctx, 1) end
                  local pause_icon = lk.link_paused and Theme.icons.play or Theme.icons.pause
                  Theme.align(ctx, row_h, L.icon_sm.size + L.icon_sm.pad * 2)
                  if Theme.icon_btn(ctx, "lp", pause_icon, {
                    preset = L.icon_sm,
                    color = P.text_dim,
                  }) then
                    lk.link_paused = not lk.link_paused
                    lk.last_a = nil
                    lk.last_b = nil
                    save_links()
                  end
                  if row_dimmed then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.45) end

                  -- Remove
                  reaper.ImGui_TableSetColumnIndex(ctx, 6)
                  Theme.align(ctx, row_h, L.icon_sm.size + L.icon_sm.pad * 2)
                  if Theme.icon_btn(ctx, "ld", Theme.icons.close, {
                    preset = L.icon_sm,
                    color = P.red,
                  }) then
                    to_del = i
                  end
                  if row_dimmed then reaper.ImGui_PopStyleVar(ctx, 1) end

                  reaper.ImGui_PopID(ctx)
                end

                reaper.ImGui_EndTable(ctx)
              end
              reaper.ImGui_Spacing(ctx)
            end
          end

          if to_del then
            table.remove(links, to_del)
            link_sel = {}
            invalidate_link_groups()
            save_links()
          end

          reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_EndChild(ctx)
      end

      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 2)
  end

  -- Modals rendering
  draw_preset_modal()
  draw_info_modal()
  draw_settings_modal()

  reaper.ImGui_End(ctx)
  Theme.pop_font(ctx, pushed_default)
  Theme.pop(ctx, nc, nv)
  return op
end

-------------------------------------------------------------------------------
-- 12. DEFER LOOP
-------------------------------------------------------------------------------
local function loop()
  apply_links()
  local open = draw_main()
  if open then reaper.defer(loop) end
end

-------------------------------------------------------------------------------
-- 13. ENTRY POINT
-------------------------------------------------------------------------------
local function main()
  Utils.init_toolbar_toggle()
  load_links()
  load_presets()
  load_settings()

  local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
  ctx = reaper.ImGui_CreateContext("Fancy Parameter Link", dock_flag)
  fonts = Theme.create_fonts(ctx)
  Theme.attach_fonts(ctx, fonts)

  reaper.atexit(function()
    save_links()
    save_presets()
    save_settings()
  end)

  reaper.defer(loop)
end

main()

