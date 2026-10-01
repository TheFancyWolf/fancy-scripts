-- @description Fancy Parameter Link
-- @author Fancy Scripts
-- @version 5.5.0
-- @changelog
--   + Clear All, Delete (N), the row delete button and preset deletion ask for confirmation first (Cancel and Esc keep everything)
--   + Choosing a preset no longer applies it at once: pick it, then click Apply (N links)
--   + Strength is a drag control: Cmd/Ctrl-drag fine adjust, double-click resets to 100%, Cmd/Ctrl-click types a value
--   + Paused links show a Paused badge and stay readable; a missing plugin shows FX missing
--   + Right-click a link row for Pause/Resume, Mode and Delete; Esc clears the link selection, then closes a floating window
--   + Space runs your REAPER Space binding while the window is focused
--   + Messages appear in the header status line instead of message boxes
--   + Preset Options menu is readable at the right edge; disabled buttons say why
--   + Selected tracks are kept by track, so inserting or reordering tracks no longer changes the selection
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

-- Version shown in the About tab (keep equal to the @version tag above)
local VERSION = "5.5.0"

-- Status message (single status line in the header subtitle)
local STATUS_SECS = 4.0
local status_msg  = ""
local status_kind = "info"   -- "info" | "ok" | "warn"
local status_time = 0

local function set_status(msg, kind)
  status_msg  = msg or ""
  status_kind = kind or "info"
  status_time = reaper.time_precise()
end

-- Cmd on macOS, Ctrl elsewhere (labels only; ImGui reports both as Mod_Ctrl)
local MOD_LABEL = (reaper.GetOS():match("OSX") or reaper.GetOS():match("macOS")) and "Cmd" or "Ctrl"

-- UI Layout Constants built from Theme.layout tokens
local L = Theme.layout

-- Defaults (AR1): used for resets and as fallbacks when loading saved data
local DEFAULTS = {
  default_mode     = "smart",       -- "smart" (auto Inverse for gain-like params), "inverse", "follow"
  default_strength = 1.0,           -- 0.0 to 1.0
  auto_touch_sync  = false,         -- auto-populate pickers on touch
  row_height       = L.row_h,       -- row height in active links table (24)
  link_mode        = "inverse",     -- mode of a link whose saved data has none
  link_strength    = 1.0,           -- strength of a link whose saved data has none; double-click reset
}

-- Settings & Preferences
local SETTINGS = {
  default_mode     = DEFAULTS.default_mode,
  default_strength = DEFAULTS.default_strength,
  auto_touch_sync  = DEFAULTS.auto_touch_sync,
  row_height       = DEFAULTS.row_height,
}

-- Row height choices (values stay 20 / 24 / 28 for compatibility with saved settings)
local ROW_HEIGHTS = {
  { h = L.row_h - L.sm, label = "Compact" },
  { h = L.row_h,        label = "Standard" },
  { h = L.row_h + L.sm, label = "Comfortable" },
}

-- First-use main window size (no layout token covers a full window; used once with Cond_FirstUseEver)
local FIRST_USE_W, FIRST_USE_H = 1200, 820

local UI = {
  btn_info_w  = L.xxxl + L.xl,             -- 48
  btn_sett_w  = L.xxxl * 2 + L.md,         -- 72
  indent_w    = L.indent,                  -- 32 (from Theme.layout)
  chk_col_w   = L.chk_col_w,               -- 24 (from Theme.layout)
  icon_col_w  = L.icon_md.size + L.icon_md.pad * 2 + L.md, -- 28
}

-- HC6: Space chords -> REAPER Main-section command ids (filled from reaper-kb.ini at startup)
local space_cmds = { [0] = 40044 }

-- HC4: one pending confirmation at a time
-- { owner = "main"|"library", title, message, action, on_confirm }
local confirm_req     = nil
local confirm_open    = false
local CONFIRM_ID_TAIL = "###pl_confirm"

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
  tracks = {},     -- list of track GUIDs for selected tracks (stable across inserts / reorders)
  tracks_expanded = false, -- whether track list is expanded
  fi     = 0,      -- selected FX index (into fxs list)
  fxs    = {},     -- FX list (intersection across all selected tracks)
  params = {},     -- param list for the selected plugin
}

-- Selected-track helpers (S.tracks holds GUIDs; tlist indices change when tracks move)
local _by_guid_src, _by_guid = nil, {}
local function tlist_by_guid()
  local tlist = get_tlist()
  if _by_guid_src ~= tlist then
    _by_guid_src, _by_guid = tlist, {}
    for _, t in ipairs(tlist) do _by_guid[t.guid] = t end
  end
  return _by_guid
end

--- Returns the tlist entries of the selected tracks in selection order, dropping deleted tracks.
--- @return table entries, boolean pruned
local function sel_entries()
  local by_guid = tlist_by_guid()
  local out, kept = {}, {}
  for _, g in ipairs(S.tracks) do
    local t = by_guid[g]
    if t then
      out[#out + 1] = t
      kept[#kept + 1] = g
    end
  end
  local pruned = (#kept ~= #S.tracks)
  if pruned then S.tracks = kept end
  return out, pruned
end

local function add_sel_track(guid)
  for _, g in ipairs(S.tracks) do
    if g == guid then return end
  end
  S.tracks[#S.tracks + 1] = guid
end

local function remove_sel_track(guid)
  for i, g in ipairs(S.tracks) do
    if g == guid then
      table.remove(S.tracks, i)
      return
    end
  end
end

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
    mode        = d.mode or DEFAULTS.link_mode,
    strength    = tonumber(d.strength) or DEFAULTS.link_strength,
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
  local entries = sel_entries()
  if #entries == 0 then
    S.fxs = {}
    return
  end
  -- Start with FX list from first track
  local first_entry = entries[1]
  if not first_entry or not first_entry.track then
    S.fxs = {}
    return
  end
  local first_fxs = fx_list(first_entry.track)
  if #entries == 1 then
    S.fxs = first_fxs
    return
  end
  -- Intersect: keep only plugins present on ALL tracks
  local shared = {}
  for _, fx in ipairs(first_fxs) do
    local found_all = true
    for ti = 2, #entries do
      local entry = entries[ti]
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
  local entries = sel_entries()
  if #entries < 2 or S.fi == 0 or not S.fxs[S.fi] then return end
  local plugin_name = S.fxs[S.fi].name
  -- Use first track's instance to enumerate parameters
  local first_entry = entries[1]
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
      strength = (SETTINGS.default_strength or DEFAULTS.default_strength),
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
  local entries = sel_entries()
  if #entries < 2 or S.fi == 0 or not S.fxs[S.fi] then return 0 end
  local plugin_name = S.fxs[S.fi].name

  -- Resolve FX index and GUID per track
  local track_info = {}
  for _, t in ipairs(entries) do
    if t and t.track then
      local fxi = find_fx_idx(t.track, plugin_name)
      if fxi >= 0 then
        local fxguid = reaper.TrackFX_GetFXGUID(t.track, fxi) or ""
        track_info[#track_info + 1] = { guid = t.guid, name = t.name, fxi = fxi, fxguid = fxguid, track = t.track }
      end
    end
  end
  if #track_info < 2 then return 0 end

  -- Build existing link set to avoid duplicates
  local existing = {}
  for _, lk in ipairs(links) do
    local k1 = lk.a_guid .. "|" .. lk.a_fxi .. "|" .. lk.a_pi .. "|" .. lk.b_guid .. "|" .. lk.b_fxi .. "|" .. lk.b_pi
    local k2 = lk.b_guid .. "|" .. lk.b_fxi .. "|" .. lk.b_pi .. "|" .. lk.a_guid .. "|" .. lk.a_fxi .. "|" .. lk.a_pi
    existing[k1] = true
    existing[k2] = true
  end

  local created = 0
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
              created = created + 1
            end
          end
        end
      end
    end
  end

  if created > 0 then
    invalidate_link_groups()
  end
  return created
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
      set_status("Not saved: select links from one plugin only (found '" .. plugin_name_val
        .. "' and '" .. links[idx].a_fxname .. "')", "warn")
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
  -- Resolve tracks from S.tracks or REAPER selection
  local track_entries = {}
  local entries = sel_entries()
  if #entries >= 2 then
    for _, t in ipairs(entries) do
      if t.track then track_entries[#track_entries + 1] = t end
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
    set_status("Select at least 2 tracks (in Tracks or in REAPER), then apply the preset.", "warn")
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
    set_status("Plugin '" .. preset.plugin_name .. "' is not on enough tracks. Missing on: "
      .. table.concat(missing_tracks, ", "), "warn")
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
  if total > 0 and skipped == total then
    set_status(string.format("Preset '%s': all links already exist", preset.name), "info")
  elseif created > 0 and created == total then
    set_status(string.format("Preset '%s': %d links created", preset.name, created), "ok")
  elseif created > 0 then
    set_status(string.format("Preset '%s': %d created, %d already existed", preset.name, created, skipped), "ok")
  else
    set_status(string.format("Preset '%s': no matching parameters found", preset.name), "warn")
  end
  return created > 0
end

-- Fill builder state from Last Touched
use_last_touched_builder = function(silent)
  local ok, trnum, fxnum, paramnum = reaper.GetLastTouchedFX()
  if not ok then
    if not silent then
      set_status("No parameter touched yet. Move a plugin knob or fader first.", "warn")
    end
    return
  end
  local real_fxi = fxnum & 0xFFFFFF
  local tr = (trnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, trnum - 1)
  if not tr then return end
  local tguid = reaper.GetTrackGUID(tr)
  if not tlist_by_guid()[tguid] then return end

  -- Add to selected tracks if not already there
  add_sel_track(tguid)

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
      mode        = lk.mode or DEFAULTS.link_mode,
      strength    = lk.strength or DEFAULTS.link_strength,
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
    if data.default_strength ~= nil then
      SETTINGS.default_strength = tonumber(data.default_strength) or DEFAULTS.default_strength
    end
    if data.auto_touch_sync ~= nil  then SETTINGS.auto_touch_sync  = data.auto_touch_sync end
    if data.row_height ~= nil       then SETTINGS.row_height       = tonumber(data.row_height) or DEFAULTS.row_height end
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
    set_status("Config folder: " .. dir .. " (install SWS to open it from here)", "info")
  end
end

local function export_links_dialog()
  local default_path = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/fancy_ipl_links_backup.json"
  local ok, filename = reaper.GetUserFileNameForWrite(default_path, "Export Links JSON", "json")
  if ok and filename ~= "" then
    if write_file(filename, serialize_links(links)) then
      set_status(string.format("Exported %d links to %s", #links, filename), "ok")
    else
      set_status("Export failed: could not write " .. filename, "warn")
    end
  end
end

local function import_links_dialog()
  local default_dir = reaper.GetResourcePath() .. "/Scripts/Fancy Scripts/"
  local ok, filename = reaper.GetUserFileNameForRead(default_dir, "Import Links JSON", "json")
  if ok and filename ~= "" then
    local raw = read_file(filename)
    if not raw then
      set_status("Import failed: could not read " .. filename, "warn")
      return
    end
    local sok, data = pcall(JSON.decode, raw)
    if not sok or type(data) ~= "table" then
      set_status("Import failed: the file is not a Parameter Link JSON export", "warn")
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
    set_status(string.format("Imported %d links", added), "ok")
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
-- 7. UI HELPERS
-------------------------------------------------------------------------------
--- HC6: reads the user's Space bindings in REAPER's Main section from reaper-kb.ini.
--- Fills space_cmds keyed by ImGui modifier chord; plain Space falls back to 40044 (Transport: Play/stop).
local function load_space_bindings()
  local mod_map = {
    ["1"]  = 0,
    ["5"]  = reaper.ImGui_Mod_Shift(),
    ["9"]  = reaper.ImGui_Mod_Ctrl(),
    ["17"] = reaper.ImGui_Mod_Alt(),
  }
  local ok, f = pcall(io.open, reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  if not ok or not f then return end
  for line in f:lines() do
    local mods, cmd, section = line:match("^KEY%s+(%d+)%s+32%s+(%S+)%s+(%d+)")
    if mods and section == "0" and mod_map[mods] then
      local id = tonumber(cmd)
      if not id then id = reaper.NamedCommandLookup(cmd) end
      if id and id > 0 then space_cmds[mod_map[mods]] = id end
    end
  end
  f:close()
end

--- Danger styling for destructive buttons (red family by palette key).
local function push_danger(P)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  P.red)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          P.red_l)
end
local function pop_danger()
  reaper.ImGui_PopStyleColor(ctx, 4)
end

--- Width of a button that fits `label` with the current frame padding (content-measured).
local function button_width(label)
  local pad_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())
  return (reaper.ImGui_CalcTextSize(ctx, label)) + pad_x * 2
end

--- Tooltip for the last item: waits for the hover delay and also shows on disabled items (reasons).
local function item_tooltip(text)
  if text and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()
                                             | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    Theme.tooltip(ctx, text)
  end
end

--- Minimum popup width that fits the widest label (Theme.selectable items do not size their popup).
local function menu_min_width(labels)
  local w = 0
  for _, s in ipairs(labels) do
    w = math.max(w, (reaper.ImGui_CalcTextSize(ctx, s)))
  end
  return w + L.sm * 2 + L.lg * 2 + L.md   -- selectable text pad + window padding + breathing room
end

--- Shortens `text` from the left with "..." so its tail (the file name) stays visible within max_w.
--- @return string fitted, boolean clipped
local function fit_left(text, max_w)
  if (reaper.ImGui_CalcTextSize(ctx, text)) <= max_w then return text, false end
  local ell = "..."
  local lo, hi = 1, #text
  while lo < hi do
    local mid = (lo + hi) // 2
    if (reaper.ImGui_CalcTextSize(ctx, ell .. text:sub(mid))) <= max_w then hi = mid else lo = mid + 1 end
  end
  while lo <= #text and (text:byte(lo) & 0xC0) == 0x80 do lo = lo + 1 end   -- UTF-8 boundary
  return ell .. text:sub(lo), true
end

--- HC2/HC3 parameter drag: AlwaysClamp | NoInput | NoSpeedTweaks, Ctrl/Cmd-drag fine adjust,
--- double-click resets to `opts.default`, Ctrl/Cmd-click released without dragging opens text entry.
--- (No context menu here: on macOS ReaImGui treats Cmd-click as a right-click, which would open both.)
--- @param key string  Lua state key (unique per control)
--- @param id string   ImGui id (unique within the current ID stack)
--- @param value number
--- @param opts table  { speed, lo, hi, fmt, type_fmt, default, tooltip, type_label }
--- @return boolean changed, number value, boolean commit  (commit = save now: release, reset or typed)
local drag_state = {}
local function param_drag(key, id, value, opts)
  local ctrl = (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  local flags = reaper.ImGui_SliderFlags_AlwaysClamp() | reaper.ImGui_SliderFlags_NoInput()
              | reaper.ImGui_SliderFlags_NoSpeedTweaks()
  local speed = ctrl and opts.speed * 0.1 or opts.speed
  local rv, v = reaper.ImGui_DragDouble(ctx, "##" .. id, value, speed, opts.lo, opts.hi, opts.fmt, flags)
  local commit = reaper.ImGui_IsItemDeactivatedAfterEdit(ctx)

  local st = drag_state[key] or {}
  drag_state[key] = st
  if reaper.ImGui_IsItemActivated(ctx) then st.ctrl, st.dragged = ctrl, false end
  if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then st.dragged = true end
  local open_typing = reaper.ImGui_IsItemDeactivated(ctx) and st.ctrl and not st.dragged

  -- HC3: double-click resets to the default value
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    rv, v, commit = true, opts.default, true
  end

  if opts.tooltip and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
    Theme.tooltip(ctx, opts.tooltip)
  end

  -- HC3: Ctrl/Cmd-click (no drag) opens text entry
  local popup_id = "type###" .. id
  if open_typing then reaper.ImGui_OpenPopup(ctx, popup_id) end
  if reaper.ImGui_BeginPopup(ctx, popup_id) then
    reaper.ImGui_Text(ctx, opts.type_label)
    if reaper.ImGui_IsWindowAppearing(ctx) then
      st.typed = v
      reaper.ImGui_SetKeyboardFocusHere(ctx)
    end
    reaper.ImGui_SetNextItemWidth(ctx, L.xxxl * 3)
    -- InputDouble rejects InputTextFlags_EnterReturnsTrue: keep the typed value and apply it on Enter
    local _, typed = reaper.ImGui_InputDouble(ctx, "##typed", st.typed or v, 0, 0, opts.type_fmt)
    st.typed = typed
    local entered = reaper.ImGui_IsItemDeactivated(ctx)
      and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
           or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false))
    if entered and typed then
      rv, v, commit = true, math.max(opts.lo, math.min(opts.hi, typed)), true
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif not reaper.ImGui_IsAnyItemActive(ctx) and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  return rv, v, commit
end

--- HC4: asks for confirmation before a destructive action (drawn by draw_confirm_modal of `owner`).
--- @param owner string  "main" (main window) or "library" (inside the Preset Library modal)
local function request_confirm(owner, title, message, action, on_confirm)
  confirm_req = { owner = owner, title = title, message = message, action = action,
                  on_confirm = on_confirm, pending = true }
end

--- HC4 confirm modal: names the consequence and count, Cancel first, Esc = Cancel.
--- Call inside the owning window or modal (a nested modal must be opened from its parent).
local function draw_confirm_modal(P, owner)
  local req = confirm_req
  if not req or req.owner ~= owner then return end
  local popup_id = req.title .. CONFIRM_ID_TAIL
  if req.pending then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    req.pending  = false
    confirm_open = true
  end

  Theme.center_next_window(ctx, L.modal_sm.w, 0, reaper.ImGui_Cond_Appearing())
  Theme.modal_scrim(ctx, popup_id)
  local flags = reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  if reaper.ImGui_BeginPopupModal(ctx, popup_id, true, flags) then
    reaper.ImGui_TextWrapped(ctx, req.message)
    reaper.ImGui_Dummy(ctx, 0, L.md)
    local close = false
    if reaper.ImGui_Button(ctx, "Cancel###pl_confirm_cancel")
       or reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      close = true
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    push_danger(P)
    local confirmed = reaper.ImGui_Button(ctx, req.action .. "###pl_confirm_ok")
    pop_danger()
    if confirmed then
      req.on_confirm()
      close = true
    end
    if close then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  else
    -- Closed (Cancel, Esc, confirm or the title-bar close button)
    confirm_req  = nil
    confirm_open = false
  end
end

--- Removes every link for which pred(lk, i) is true; returns how many were removed.
local function remove_links(pred)
  local kept, removed = {}, 0
  for i, lk in ipairs(links) do
    if pred(lk, i) then removed = removed + 1 else kept[#kept + 1] = lk end
  end
  if removed > 0 then
    links = kept
    link_sel = {}
    last_clicked_link = 0
    invalidate_link_groups()
    save_links()
  end
  return removed
end

local function plural(n, word)
  return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

--- Number of tracks a preset Apply would use: the Tracks selection, else REAPER's selected tracks.
local function preset_track_count()
  if #S.tracks >= 2 then return #S.tracks end
  return reaper.CountSelectedTracks(0)
end

-- One ListClipper reused for every clipped list (recreated if ReaImGui collected it)
local _clipper = nil
local function get_clipper()
  if not _clipper or not reaper.ImGui_ValidatePtr(_clipper, "ImGui_ListClipper*") then
    _clipper = reaper.ImGui_CreateListClipper(ctx)
  end
  return _clipper
end

-------------------------------------------------------------------------------
-- 8. TRACK SELECTOR (Multi-track)
-------------------------------------------------------------------------------
--- Recomputes shared plugins after the track selection changed, keeping the plugin when still shared.
local function on_tracks_changed()
  local cur_name = (S.fi > 0 and S.fxs[S.fi]) and S.fxs[S.fi].name or nil
  compute_shared_fxs()
  S.fi = 0
  if cur_name then
    for fi, f in ipairs(S.fxs) do
      if f.name == cur_name then S.fi = fi; break end
    end
  end
  M.scanned = false
  M.groups = {}
end

local function draw_track_selector(tlist)
  local P = Theme.get_palette()
  local entries, pruned = sel_entries()
  if pruned then
    on_tracks_changed()
    entries = sel_entries()
  end

  -- Action row: Add Tracks multi-combo + Use Selected on same line
  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local use_sel_text = "Use Selected"
  local use_sel_w = math.ceil(button_width(use_sel_text))
  local combo_w = avail_w - use_sel_w - L.md

  local toggled_idx, is_now_selected = Theme.multi_combo(ctx, "##add_track", tlist, S.tracks, {
    w = combo_w,
    placeholder = "+ Add Tracks...",
    preview = "+ Add Tracks...",
  })

  if toggled_idx and tlist[toggled_idx] then
    local guid = tlist[toggled_idx].guid
    if is_now_selected then add_sel_track(guid) else remove_sel_track(guid) end
    on_tracks_changed()
  end

  reaper.ImGui_SameLine(ctx, 0, L.md)
  if reaper.ImGui_Button(ctx, use_sel_text, use_sel_w, 0) then
    S.tracks = {}
    local by_guid = tlist_by_guid()
    for i = 0, reaper.CountSelectedTracks(0) - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      if tr then
        local tguid = reaper.GetTrackGUID(tr)
        if by_guid[tguid] then add_sel_track(tguid) end
      end
    end
    on_tracks_changed()
  end
  item_tooltip("Replace the list with the tracks selected in REAPER")

  reaper.ImGui_Dummy(ctx, 0, L.sm)

  -- Collapsible track list (below action buttons)
  if #entries == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(ctx, "No tracks selected. Add tracks above or select them in REAPER and click Use Selected.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    return
  end

  local hdr_label = string.format("Tracks Selected  (%d)##trk_hdr", #entries)
  local is_open, clear_clicked = Theme.collapsing_header(ctx, hdr_label, {
    default_open = S.tracks_expanded,
    close_id = "trk_clear",
    close_tooltip = "Clear all tracks",
  })
  S.tracks_expanded = is_open

  if clear_clicked then
    S.tracks = {}
    on_tracks_changed()
    S.tracks_expanded = false
    return
  end

  -- Expanded: track list matching Link Builder table style with right-aligned close buttons
  if S.tracks_expanded then
    local to_remove = nil
    local btn_preset = L.icon_sm
    local btn_w = btn_preset.size + btn_preset.pad * 2
    local btn_col_w = btn_w + L.sm * 2
    local tree_indent = L.md + 10 + L.md   -- matches Theme.collapsing_header's text offset
    local text_h = reaper.ImGui_GetTextLineHeight(ctx)

    if reaper.ImGui_BeginTable(ctx, "trk_list_tbl", 2, reaper.ImGui_TableFlags_None()) then
      reaper.ImGui_TableSetupColumn(ctx, "##tname", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "##tdel",  reaper.ImGui_TableColumnFlags_WidthFixed(), btn_col_w)

      for _, t in ipairs(entries) do
        reaper.ImGui_PushID(ctx, t.guid)
        reaper.ImGui_TableNextRow(ctx, 0, L.row_h)

        -- Column 0: Track Name (aligned with "Tracks" in header)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        local col_start_x = reaper.ImGui_GetCursorPosX(ctx)
        local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                        | reaper.ImGui_SelectableFlags_AllowOverlap()
        Theme.selectable(ctx, "##tsel", false, sel_flags, 0, L.row_h - L.xs * 2)

        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_SetCursorPosX(ctx, col_start_x + tree_indent)
        Theme.align(ctx, L.row_h, text_h)
        reaper.ImGui_Text(ctx, t.name)

        -- Column 1: Close button (aligned with header close button)
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        Theme.align(ctx, L.row_h, btn_w)
        Theme.right_align(ctx, btn_w, L.sm)
        if Theme.icon_btn(ctx, "trk_rm", Theme.icons.close, {
          preset = btn_preset,
          color = P.text_dim,
          tooltip = "Remove track",
        }) then
          to_remove = t.guid
        end
        reaper.ImGui_PopID(ctx)
      end
      reaper.ImGui_EndTable(ctx)
    end

    if to_remove then
      remove_sel_track(to_remove)
      on_tracks_changed()
      if #S.tracks == 0 then S.tracks_expanded = false end
    end
  end
end

-------------------------------------------------------------------------------
-- 9. PLUGIN SELECTOR
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
-- 10. LINK BUILDER
-------------------------------------------------------------------------------
--- Display name of a parameter inside its group (group prefix removed).
local function param_display_name(grp, item)
  local disp = item.param.name
  if grp.name ~= "(General)" then
    local w = disp:sub(#grp.name + 2)
    if w ~= "" then disp = w end
  end
  return disp
end

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
    return
  end

  -- Auto-scan whenever plugins are selected and result is stale
  if not M.scanned then do_scan() end

  -- Search filter + Expand/Collapse All + Last Touched + All (widths measured, not hardcoded)
  local lt_label  = "Last Touched"
  local all_label = "All"
  local lt_w  = button_width(lt_label)
  local all_w = math.max(L.xxxl, button_width(all_label))
  local right_w = L.sm + L.xxl + L.xs + L.xxl + L.sm + lt_w + L.xs + all_w
  reaper.ImGui_SetNextItemWidth(ctx, -right_w)
  local fr, nf = reaper.ImGui_InputTextWithHint(ctx, "##mf", "Search parameters...", M.filter, 256)
  if fr then M.filter = nf end

  local small_icon = L.md + L.xs   -- 10
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  if Theme.icon_btn_colored(ctx, "exp_all", Theme.icons.tri_down, {
    w = L.xxl,
    h = 0,
    icon_size = small_icon,
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
    icon_size = small_icon,
    icon_color = P.text,
    bg = P.card,
    bg_hover = P.panel,
    bg_active = P.accent_d,
    tooltip = "Collapse All Groups",
  }) then
    for _, g in ipairs(M.groups) do g.force_open = false end
  end

  reaper.ImGui_SameLine(ctx, 0, L.sm)
  if reaper.ImGui_Button(ctx, "Last Touched##lb_lt", lt_w, 0) then
    use_last_touched_builder()
  end
  -- LT is polled once per frame in draw_main
  if LT.track ~= "" then
    local lt_val = LT.tr and fmt_val(LT.tr, LT.fxi, LT.pi, LT.norm) or "?"
    item_tooltip("Last touched: " .. LT.track .. " / " .. LT.fx .. " / " .. LT.param .. " = " .. lt_val
      .. "\nClick to add this track and check the parameter.")
  else
    item_tooltip("Move a plugin parameter in REAPER, then click to add its track and check it here.")
  end

  reaper.ImGui_SameLine(ctx, 0, L.xs)
  local no_groups = (#M.groups == 0)
  reaper.ImGui_BeginDisabled(ctx, no_groups)
  if reaper.ImGui_Button(ctx, "All##lb_all", all_w, 0) then
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
  reaper.ImGui_EndDisabled(ctx)
  item_tooltip(no_groups and "No parameters to select for this plugin" or "Check / uncheck all parameters")

  reaper.ImGui_Dummy(ctx, 0, L.sm)

  -- Scrollable param list (leaves room for the Add Links row below)
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local footer_h = L.sm + reaper.ImGui_GetFrameHeightWithSpacing(ctx)
  local list_h = math.max(L.row_h * 3, avail_h - footer_h)

  if reaper.ImGui_BeginChild(ctx, "lb_list", 0, list_h) then
    if no_groups then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
      reaper.ImGui_TextWrapped(ctx, "No parameters found for this plugin.")
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local flo = M.filter:lower()
      for gi, grp in ipairs(M.groups) do
        -- Items of this group that match the filter
        local vis = {}
        local scroll_k = nil
        for pi, item in ipairs(grp.params) do
          local disp = param_display_name(grp, item)
          if flo == "" or grp.name:lower():find(flo, 1, true) or disp:lower():find(flo, 1, true) then
            vis[#vis + 1] = { pi = pi, item = item, disp = disp }
            if _scroll_to_param_idx ~= nil and item.param.idx == _scroll_to_param_idx then scroll_k = #vis end
          end
        end

        if #vis > 0 then
          -- Group select-all checkbox
          local all_chk = true
          for _, item in ipairs(grp.params) do
            if not item.checked then all_chk = false; break end
          end
          local crv, nc = reaper.ImGui_Checkbox(ctx, "##gc" .. gi, all_chk)
          if crv then
            for _, item in ipairs(grp.params) do item.checked = nc end
          end
          item_tooltip("Check / uncheck every parameter in " .. grp.name)
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

              -- Long parameter lists: draw only the visible rows
              local clipper = get_clipper()
              reaper.ImGui_ListClipper_Begin(clipper, #vis)
              if scroll_k then reaper.ImGui_ListClipper_IncludeItemByIndex(clipper, scroll_k - 1) end
              while reaper.ImGui_ListClipper_Step(clipper) do
                local d0, d1 = reaper.ImGui_ListClipper_GetDisplayRange(clipper)
                for k = d0 + 1, d1 do
                  local row = vis[k]
                  local item, pi = row.item, row.pi
                  reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
                  reaper.ImGui_TableSetColumnIndex(ctx, 0)
                  local ck, nc2 = reaper.ImGui_Checkbox(ctx, "##ck" .. gi .. "_" .. pi, item.checked)
                  if ck then item.checked = nc2 end
                  reaper.ImGui_TableSetColumnIndex(ctx, 1)
                  Theme.align(ctx, L.row_h)
                  if Theme.selectable(ctx, row.disp .. "##psel" .. gi .. "_" .. pi, item.checked, reaper.ImGui_SelectableFlags_None()) then
                    item.checked = not item.checked
                  end
                  -- Scroll to this param if it was the Last Touched target
                  if k == scroll_k then
                    reaper.ImGui_SetScrollHereY(ctx, 0.5)
                    _scroll_to_param_idx = nil
                  end
                end
              end
              reaper.ImGui_EndTable(ctx)
            end
            reaper.ImGui_Unindent(ctx, UI.indent_w)
            reaper.ImGui_Dummy(ctx, 0, L.sm)
          end
        end
      end
    end

    reaper.ImGui_EndChild(ctx)
  end

  -- Action row
  local total_params = count_checked_params()
  local n_tracks = #S.tracks
  local n_pairs = (n_tracks * (n_tracks - 1)) // 2
  local total_links = total_params * n_pairs
  reaper.ImGui_Dummy(ctx, 0, L.sm)

  reaper.ImGui_BeginDisabled(ctx, total_links == 0)
  local lbl = string.format("Add %s across %d Tracks###lb_add_links", plural(total_links, "Link"), n_tracks)
  if reaper.ImGui_Button(ctx, lbl, -1, 0) and total_links > 0 then
    local created = create_links_from_match()
    save_links()
    for _, grp in ipairs(M.groups) do
      for _, item in ipairs(grp.params) do item.checked = false end
    end
    if created > 0 then
      set_status("Added " .. plural(created, "link"), "ok")
    else
      set_status("Those links already exist", "info")
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  if total_links == 0 then
    item_tooltip("Check at least one parameter in the list first")
  end
end

-------------------------------------------------------------------------------
-- 11. MODAL DIALOGS (Preset Library, Info & Guide, Settings)
-------------------------------------------------------------------------------
--- Asks to delete a preset (HC4: presets file is not undoable).
local function confirm_delete_preset(owner, preset)
  if not preset then return end
  local n = #(preset.params or {})
  request_confirm(owner, "Delete preset?",
    string.format("Delete the preset '%s' (%s, %s)?\n\nIt is removed from the preset library in every project. "
      .. "Links already created from it stay.\n\nThis cannot be undone with %s+Z.",
      preset.name or "?", preset.plugin_name or "?", plural(n, "parameter"), MOD_LABEL),
    "Delete Preset",
    function()
      for i, p in ipairs(Presets.list) do
        if p == preset then
          table.remove(Presets.list, i)
          if Presets.sel == i then
            Presets.sel = 0
          elseif Presets.sel > i then
            Presets.sel = Presets.sel - 1
          end
          save_presets()
          set_status(string.format("Deleted preset '%s'", preset.name or "?"), "info")
          break
        end
      end
    end)
end

local function draw_preset_modal()
  local P = Theme.get_palette()
  local popup_id = "Preset Library##preset_mgr_modal"
  if show_preset_modal then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    show_preset_modal = false
  end

  Theme.center_next_window(ctx, L.modal_lg.w, L.modal_md.h)
  Theme.modal_scrim(ctx, popup_id)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, popup_id, true, reaper.ImGui_WindowFlags_None())
  if visible then
    -- HC5: the nested confirm owns Esc while it is open
    local esc = not confirm_open and not reaper.ImGui_IsAnyItemActive(ctx)
                and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape())

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
    reaper.ImGui_Text(ctx, string.format("Saved Presets (%d)", #Presets.list))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_Text(ctx, "Select tracks, then Apply to create links.")
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, L.sm)

    local close_label = "Close##close_preset_modal"
    -- footer: Dummy + Separator + Dummy (each followed by ItemSpacing.y) + Close button
    local footer_h = L.sm * 2 + L.sm * 3 + L.border + reaper.ImGui_GetFrameHeightWithSpacing(ctx)
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local tbl_h = math.max(L.row_h * 3, avail_h - footer_h)

    if #Presets.list == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
      reaper.ImGui_TextWrapped(ctx, "No presets yet. In Active Links, click the rows you want (Shift-click for a range), "
        .. "then click Save as Preset.")
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Dummy(ctx, 0, math.max(0, tbl_h - reaper.ImGui_GetTextLineHeightWithSpacing(ctx) * 2))
    else
      local apply_lbl, del_lbl = "Apply", "Delete"
      local sm_pad = L.md   -- SmallButton uses FramePadding.x
      local actions_w = (reaper.ImGui_CalcTextSize(ctx, apply_lbl)) + (reaper.ImGui_CalcTextSize(ctx, del_lbl))
                        + sm_pad * 4 + L.sm + L.sm * 2
      local params_w = (reaper.ImGui_CalcTextSize(ctx, "Params")) + L.lg
      local PFLG = reaper.ImGui_TableFlags_RowBg()
                 | reaper.ImGui_TableFlags_Borders()
                 | reaper.ImGui_TableFlags_ScrollY()
      if reaper.ImGui_BeginTable(ctx, "preset_modal_tbl", 4, PFLG, 0, tbl_h) then
        reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
        reaper.ImGui_TableSetupColumn(ctx, "Preset Name", reaper.ImGui_TableColumnFlags_WidthStretch(), 0.40)
        reaper.ImGui_TableSetupColumn(ctx, "Plugin",      reaper.ImGui_TableColumnFlags_WidthStretch(), 0.30)
        reaper.ImGui_TableSetupColumn(ctx, "Params",      reaper.ImGui_TableColumnFlags_WidthFixed(), params_w)
        reaper.ImGui_TableSetupColumn(ctx, "Actions",     reaper.ImGui_TableColumnFlags_WidthFixed(), actions_w)
        reaper.ImGui_TableHeadersRow(ctx)

        for pi, preset in ipairs(Presets.list) do
          reaper.ImGui_PushID(ctx, pi)
          reaper.ImGui_TableNextRow(ctx, 0, L.row_h)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          Theme.align(ctx, L.row_h, reaper.ImGui_GetTextLineHeight(ctx))
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (Presets.sel == pi) and P.accent or P.text)
          reaper.ImGui_Text(ctx, preset.name or "?")
          reaper.ImGui_PopStyleColor(ctx, 1)

          reaper.ImGui_TableSetColumnIndex(ctx, 1)
          Theme.align(ctx, L.row_h, reaper.ImGui_GetTextLineHeight(ctx))
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
          local pname_display = preset.plugin_name or ""
          reaper.ImGui_Text(ctx, (pname_display ~= "") and pname_display or "--")
          reaper.ImGui_PopStyleColor(ctx, 1)

          reaper.ImGui_TableSetColumnIndex(ctx, 2)
          Theme.align(ctx, L.row_h, reaper.ImGui_GetTextLineHeight(ctx))
          reaper.ImGui_Text(ctx, tostring(#(preset.params or {})))

          reaper.ImGui_TableSetColumnIndex(ctx, 3)
          Theme.align(ctx, L.row_h, L.btn_sm.h)
          if reaper.ImGui_SmallButton(ctx, apply_lbl .. "##papply") then
            Presets.sel = pi
            apply_preset_direct(preset)
          end
          item_tooltip("Create this preset's links across the selected tracks")
          reaper.ImGui_SameLine(ctx, 0, L.sm)
          push_danger(P)
          if reaper.ImGui_SmallButton(ctx, del_lbl .. "##pdel") then
            confirm_delete_preset("library", preset)
          end
          pop_danger()
          item_tooltip("Delete this preset (asks first)")
          reaper.ImGui_PopID(ctx)
        end
        reaper.ImGui_EndTable(ctx)
      end
    end

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if reaper.ImGui_Button(ctx, close_label) or not open or esc then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    -- Nested confirm (preset delete) is opened from inside this modal
    draw_confirm_modal(P, "library")
    reaper.ImGui_EndPopup(ctx)
  end
end

--- Bold coloured heading for the Info modal.
local function info_heading(P, text, col)
  local pf = Theme.push_font(ctx, fonts.default_bold)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col or P.yellow)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
  Theme.pop_font(ctx, pf)
end

--- One gesture row in the Info modal: bold gesture, then what it does.
local function info_gesture(gesture, what)
  reaper.ImGui_Bullet(ctx)
  reaper.ImGui_SameLine(ctx, 0, L.md)
  local pf = Theme.push_font(ctx, fonts.default_bold)
  reaper.ImGui_Text(ctx, gesture)
  Theme.pop_font(ctx, pf)
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  reaper.ImGui_TextWrapped(ctx, what)
end

local function draw_info_modal()
  local P = Theme.get_palette()
  local popup_id = "Fancy Parameter Link -- Info & Guide##info_modal"
  if show_info_modal then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    show_info_modal = false
  end

  Theme.center_next_window(ctx, L.modal_lg.w, L.modal_lg.h)
  Theme.modal_scrim(ctx, popup_id)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, popup_id, true, reaper.ImGui_WindowFlags_None())
  if visible then
    if not reaper.ImGui_IsAnyItemActive(ctx) and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      open = false
    end

    if reaper.ImGui_BeginTabBar(ctx, "info_tab_bar") then
      if reaper.ImGui_BeginTabItem(ctx, "Quick Start Guide") then
        reaper.ImGui_Dummy(ctx, 0, L.sm)
        info_heading(P, "1. Select Tracks")
        reaper.ImGui_TextWrapped(ctx, "Add 2 or more tracks using the track selector, or select them in REAPER and click 'Use Selected'.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "2. Select Plugin")
        reaper.ImGui_TextWrapped(ctx, "Choose the plugin that's on all selected tracks. The script shows only plugins common to every track.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "3. Select Parameters")
        reaper.ImGui_TextWrapped(ctx, "Check individual parameters or entire groups. Use the search bar to filter by name.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "4. Add Links")
        reaper.ImGui_TextWrapped(ctx, "Click 'Add Links' to create bidirectional links across all track pairs. Move any linked knob and all others follow (or inverse).")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Links run only while this window is open")
        reaper.ImGui_TextWrapped(ctx, "Closing the Parameter Link window stops all links (they are saved with the project and "
          .. "start again when you reopen it). Use Pause All to stop them without closing.")

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Controls") then
        reaper.ImGui_Dummy(ctx, 0, L.sm)
        info_heading(P, "Active Links")
        info_gesture("Click a row", "Select or deselect that link.")
        info_gesture("Shift-click a row", "Select every link between the last clicked row and this one.")
        info_gesture("Right-click a row", "Pause / Resume, switch Mode, or Delete that link.")
        info_gesture("Mode button", "Switch the link between Follow and Inverse.")
        info_gesture("Strength", "Drag to change. " .. MOD_LABEL .. "-drag for fine steps, double-click resets to 100%, "
          .. MOD_LABEL .. "-click to type a value.")
        info_gesture("Pause / play icon", "Pause or resume one link.")
        info_gesture("x icon", "Delete one link (asks first).")
        info_gesture("Pause All", "Stop every link without deleting it; Resume All restarts them.")
        info_gesture("Clear All / Delete (N)", "Delete all links, or the selected ones (asks first).")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Presets")
        info_gesture("Save as Preset", "Select rows, click Save as Preset, type a name, Enter saves, Esc cancels.")
        info_gesture("Preset list + Apply", "Choose a preset in the list, then click Apply (N links) to create its links "
          .. "on the selected tracks.")
        info_gesture("Presets menu", "Open the Preset Library, delete the chosen preset, export or import links.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Link Builder")
        info_gesture("Last Touched", "Move a plugin parameter in REAPER, then click to add its track and check that parameter. "
          .. "Settings can do this automatically.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Keys")
        info_gesture("Esc", "Closes a dialog, then cancels an edit, then clears the link selection, then closes the "
          .. "window when it is floating (never when docked).")
        info_gesture("Enter", "Saves in the Save as Preset box and confirms a typed value.")
        info_gesture("Space", "Runs your REAPER Space shortcut (Play/Stop by default) while this window is focused.")
        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Modes & Tips") then
        reaper.ImGui_Dummy(ctx, 0, L.sm)
        info_heading(P, "Follow Mode", P.green)
        reaper.ImGui_TextWrapped(ctx, "Linked parameters move in the same direction (1:1 tracking). Move any linked knob and all others follow.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Inverse Mode", P.accent)
        reaper.ImGui_TextWrapped(ctx, "Parameters move inversely around center (0.5). Ideal for complementary EQ, wet/dry crossfades, and dynamic frequency balancing.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Bidirectional Links")
        reaper.ImGui_TextWrapped(ctx, "All links are bidirectional. Move the parameter on any linked track and the others update automatically. No need to designate a 'source' or 'target'.")
        reaper.ImGui_Dummy(ctx, 0, L.md)

        info_heading(P, "Multi-Track Linking")
        reaper.ImGui_TextWrapped(ctx, "Select any number of tracks. Links are created for every pair (full mesh). 3 tracks = 3 links, 4 tracks = 6 links per parameter.")

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "About") then
        local icon_sz = L.xxxl + L.sm -- 36
        local line_h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
        local content_h = icon_sz + Theme.font_sizes.large + line_h * 2 + L.md * 2
                          + reaper.ImGui_GetFrameHeight(ctx)
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
        local top_pad = math.max(L.md, math.floor((avail_h - content_h) * 0.5))
        reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + top_pad)
        Theme.hcenter(ctx, icon_sz)
        Theme.brand_icon(ctx, icon_sz)
        reaper.ImGui_Dummy(ctx, 0, L.sm)

        local pf1 = Theme.push_font(ctx, fonts.large_bold)
        local t1 = "FANCY "
        local t2 = "PARAMETER LINK"
        local w1 = reaper.ImGui_CalcTextSize(ctx, t1)
        local w2 = reaper.ImGui_CalcTextSize(ctx, t2)
        Theme.hcenter(ctx, w1 + w2)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.yellow)
        reaper.ImGui_Text(ctx, t1)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text)
        reaper.ImGui_Text(ctx, t2)
        reaper.ImGui_PopStyleColor(ctx, 1)
        Theme.pop_font(ctx, pf1)

        local sub = "v" .. VERSION .. " crafted by Fancy Wolf Audio & Antigravity for REAPER"
        local sw = reaper.ImGui_CalcTextSize(ctx, sub)
        Theme.hcenter(ctx, sw)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
        reaper.ImGui_Text(ctx, sub)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Dummy(ctx, 0, L.md)

        local prompt = "Find this useful?"
        local pw = reaper.ImGui_CalcTextSize(ctx, prompt)
        Theme.hcenter(ctx, pw)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), Theme.with_alpha(P.text, 0.8))
        reaper.ImGui_Text(ctx, prompt)
        reaper.ImGui_PopStyleColor(ctx, 1)

        reaper.ImGui_Dummy(ctx, 0, L.sm)
        local coffee = "Buy me a Cup of Coffee as Thanks"
        local btn_w = button_width(coffee) + L.xxxl
        Theme.hcenter(ctx, btn_w)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        P.card)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.panel)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  P.accent_d)
        if reaper.ImGui_Button(ctx, coffee, btn_w, 0) then
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

--- One storage path row: label, then the path shortened from the left with the full path in a tooltip.
local function draw_path_row(label, path)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local shown, clipped = fit_left(path, avail)
  reaper.ImGui_Text(ctx, shown)
  if clipped then item_tooltip(path) end
end

local function draw_settings_modal()
  local P = Theme.get_palette()
  local popup_id = "Settings & Preferences##settings_modal"
  if show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    show_settings_modal = false
  end

  Theme.center_next_window(ctx, L.modal_lg.w, L.modal_lg.h)
  Theme.modal_scrim(ctx, popup_id)
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, popup_id, true, reaper.ImGui_WindowFlags_None())
  if visible then
    if not reaper.ImGui_IsAnyItemActive(ctx) and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      open = false
    end

    Theme.section_divider(ctx, "Default Link Rules", { color = P.yellow })

    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Start gain-like parameters in Inverse:")
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
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    reaper.ImGui_TextWrapped(ctx, "Yes: parameters named gain, level, volume, vol, output, wet, dry, boost or cut start in "
      .. "Inverse, all others in Follow. No: every new link starts in Follow.")
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Default Strength:")
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    reaper.ImGui_SetNextItemWidth(ctx, L.xxxl * 5)
    local s_pct = (SETTINGS.default_strength or DEFAULTS.default_strength) * 100
    local sc, np, s_commit = param_drag("def_st", "def_st", s_pct, {
      speed = 0.5, lo = 0, hi = 100, fmt = "%.0f%%", type_fmt = "%.1f",
      default = DEFAULTS.default_strength * 100,
      type_label = "Default strength (%)",
      tooltip = "Strength of new links. Drag; " .. MOD_LABEL .. "-drag fine; double-click resets to 100%; "
        .. MOD_LABEL .. "-click to type.",
    })
    if sc then SETTINGS.default_strength = np / 100 end
    if s_commit then save_settings() end

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

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    Theme.tooltip_setting_widget(ctx, { label = "Show Tooltips##pl_tooltips" })

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    Theme.align(ctx)
    reaper.ImGui_Text(ctx, "Table Row Height:")
    for ri, rh in ipairs(ROW_HEIGHTS) do
      reaper.ImGui_SameLine(ctx, 0, ri == 1 and L.lg or L.md)
      if reaper.ImGui_RadioButton(ctx, rh.label .. "##rh" .. ri, SETTINGS.row_height == rh.h) then
        SETTINGS.row_height = rh.h
        save_settings()
      end
    end

    reaper.ImGui_Dummy(ctx, 0, L.lg)

    Theme.section_divider(ctx, "File Storage & Backups", { color = P.yellow })

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
    draw_path_row("Project links:", sav_path())
    draw_path_row("Presets file:", PRESET_PATH)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Dummy(ctx, 0, L.sm)

    if reaper.ImGui_Button(ctx, "Open Config Folder") then
      open_config_folder()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_Button(ctx, "Export Links JSON...") then
      export_links_dialog()
    end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_Button(ctx, "Import Links JSON...") then
      import_links_dialog()
    end

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if reaper.ImGui_Button(ctx, "Close##close_settings_modal") or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-------------------------------------------------------------------------------
-- 12. MAIN WINDOW
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

local function toggle_link_pause(lk)
  lk.link_paused = not lk.link_paused
  lk.last_a = nil
  lk.last_b = nil
  save_links()
end

local function toggle_link_mode(lk)
  lk.mode = (lk.mode ~= "follow") and "follow" or "inverse"
  lk.last_a = nil
  lk.last_b = nil
  save_links()
end

local function confirm_delete_link(lk)
  request_confirm("main", "Delete link?",
    string.format("Delete the link between %s and %s (%s / %s)?\n\nThe two parameters stop following each other; "
      .. "their current values stay.\n\nThis cannot be undone with %s+Z.",
      lk.a_name, lk.b_name, lk.a_fxname, lk.a_pname, MOD_LABEL),
    "Delete Link",
    function()
      if remove_links(function(l) return l == lk end) > 0 then
        set_status("Deleted 1 link", "info")
      end
    end)
end

--- Toolbar above the Active Links table.
local function draw_links_toolbar(P, sel_count)
  local tb_x0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local tb_avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local no_links = (#links == 0)

  -- Pause All / Resume All (paused = neutral yellow, never red)
  if Theme.toggle_button(ctx, "tb_pause_all", paused and "Resume All" or "Pause All", paused, {
    active_bg      = Theme.with_alpha(P.yellow, 0.20),
    active_hover   = Theme.with_alpha(P.yellow, 0.40),
    active_active  = Theme.with_alpha(P.yellow, 0.60),
    active_text    = P.yellow_l,
    inactive_bg    = P.green_d,
    inactive_hover = P.green_h,
    inactive_active= P.green,
    inactive_text  = P.green_l,
    tooltip = paused and "All links are paused. Click to resume them."
      or "Pause every link without deleting it. Closing this window also stops all links.",
  }) then
    paused = not paused
    set_status(paused and "All links paused" or "All links resumed", "info")
  end

  -- Clear All (HC4: confirm first)
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  reaper.ImGui_BeginDisabled(ctx, no_links)
  if Theme.toggle_button(ctx, "tb_clear_all", "Clear All", true, {
    active_bg      = P.red_d,
    active_hover   = P.red_h,
    active_active  = P.red,
    active_text    = P.red_l,
    tooltip = no_links and "No links to clear" or "Delete every link in this project (asks first)",
  }) and not no_links then
    request_confirm("main", "Delete all links?",
      string.format("Delete all %s in this project?\n\nLinked parameters stop following each other; their current "
        .. "values stay. Saved presets are not affected.\n\nThis cannot be undone with %s+Z.",
        plural(#links, "link"), MOD_LABEL),
      "Delete All Links",
      function()
        local n = remove_links(function() return true end)
        set_status("Deleted all " .. plural(n, "link"), "info")
      end)
  end
  reaper.ImGui_EndDisabled(ctx)

  -- Select All / None toggle (stable ID while the label changes)
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  local all_selected = (#links > 0 and sel_count == #links)
  reaper.ImGui_BeginDisabled(ctx, no_links)
  if reaper.ImGui_Button(ctx, (all_selected and "Select None" or "Select All") .. "###tb_sel_all") then
    link_sel = {}
    if not all_selected then
      for i = 1, #links do link_sel[i] = true end
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  item_tooltip(no_links and "No links yet" or "Click rows to select; Shift-click selects a range")

  -- Delete Selected (always drawn so the toolbar does not shift; HC4: confirm first)
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  reaper.ImGui_BeginDisabled(ctx, sel_count == 0)
  if Theme.toggle_button(ctx, "tb_del_sel", string.format("Delete (%d)", sel_count), true, {
    active_bg      = P.red_d,
    active_hover   = P.red_h,
    active_active  = P.red,
    active_text    = P.red_l,
    tooltip = (sel_count == 0) and "Select links first: click rows (Shift-click for a range)"
      or "Delete the selected links (asks first)",
  }) and sel_count > 0 then
    request_confirm("main", "Delete selected links?",
      string.format("Delete the %d selected %s?\n\nThe linked parameters stop following each other; their current "
        .. "values stay.\n\nThis cannot be undone with %s+Z.",
        sel_count, sel_count == 1 and "link" or "links", MOD_LABEL),
      "Delete Links",
      function()
        local n = remove_links(function(_, i) return link_sel[i] == true end)
        set_status("Deleted " .. plural(n, "link"), "info")
      end)
  end
  reaper.ImGui_EndDisabled(ctx)

  -- Save as Preset
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  local save_reason = no_links and "No links yet: add links first"
    or (sel_count == 0 and "Select the links to save first: click rows (Shift-click for a range)") or nil
  reaper.ImGui_BeginDisabled(ctx, save_reason ~= nil)
  if reaper.ImGui_Button(ctx, "Save as Preset") and not save_reason then
    local first_sel = nil
    for i = 1, #links do
      if link_sel[i] then first_sel = i; break end
    end
    save_preset_name = first_sel and (links[first_sel].a_fxname .. " Link") or ""
    save_preset_popup = true
  end
  reaper.ImGui_EndDisabled(ctx)
  item_tooltip(save_reason or "Save the selected links' parameters, modes and strengths as a preset")

  -- Preset group (right-aligned; wraps to its own line when the pane is narrow)
  local left_used = (reaper.ImGui_GetItemRectMax(ctx)) - tb_x0
  local sel_preset = (Presets.sel > 0 and Presets.sel <= #Presets.list) and Presets.list[Presets.sel] or nil
  local n_tr = preset_track_count()
  local n_new = 0
  if sel_preset and n_tr >= 2 then
    n_new = #(sel_preset.params or {}) * ((n_tr * (n_tr - 1)) // 2)
  end
  local apply_text = string.format("Apply (%s)", plural(n_new, "link"))
  local menu_text  = "Presets"
  local combo_w = L.xxxl * 5
  local label_w = reaper.ImGui_CalcTextSize(ctx, "Preset:")
  local total_group_w = label_w + L.sm + combo_w + L.xs + button_width(apply_text) + L.xs + button_width(menu_text)
  if tb_avail - left_used >= total_group_w + L.md then
    reaper.ImGui_SameLine(ctx, 0, 0)
  end
  Theme.right_align(ctx, total_group_w)
  Theme.align(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
  reaper.ImGui_Text(ctx, "Preset:")
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Preset combo: choosing only selects (AR5); Apply creates the links
  reaper.ImGui_SameLine(ctx, 0, L.sm)
  reaper.ImGui_SetNextItemWidth(ctx, combo_w)
  local preview = sel_preset and sel_preset.name or ((#Presets.list == 0) and "No presets yet" or "Choose preset...")
  if reaper.ImGui_BeginCombo(ctx, "##al_preset_combo", preview) then
    for i, preset in ipairs(Presets.list) do
      local pn = preset.plugin_name or ""
      local hint = (pn ~= "") and ("  [" .. pn .. "]") or ""
      if Theme.selectable(ctx, (preset.name or "?") .. hint .. "##alp" .. i, Presets.sel == i) then
        Presets.sel = i
      end
      if Presets.sel == i then reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  item_tooltip((#Presets.list == 0) and "No presets yet: select links and click Save as Preset"
    or "Choose a preset, then click Apply")

  reaper.ImGui_SameLine(ctx, 0, L.xs)
  local apply_reason = (not sel_preset) and "Choose a preset in the list first"
    or (n_tr < 2 and "Select 2+ tracks (in Tracks or in REAPER) first") or nil
  reaper.ImGui_BeginDisabled(ctx, apply_reason ~= nil)
  if reaper.ImGui_Button(ctx, apply_text .. "###al_apply") and not apply_reason then
    apply_preset_direct(sel_preset)
  end
  reaper.ImGui_EndDisabled(ctx)
  item_tooltip(apply_reason or string.format("Create up to %s for '%s' across %d tracks (existing links are skipped)",
    plural(n_new, "link"), sel_preset.name or "?", n_tr))

  -- Preset Options menu
  reaper.ImGui_SameLine(ctx, 0, L.xs)
  if reaper.ImGui_Button(ctx, menu_text .. "###al_preset_menu") then
    reaper.ImGui_OpenPopup(ctx, "al_preset_menu_popup")
  end
  item_tooltip("Preset options: library, delete, export, import")

  local menu_labels = { "Preset library...", "Delete preset...", "Export links...", "Import links..." }
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, menu_min_width(menu_labels), 0, 1e6, 1e6)
  if reaper.ImGui_BeginPopup(ctx, "al_preset_menu_popup") then
    if Theme.selectable(ctx, menu_labels[1] .. "##alpm_lib") then
      show_preset_modal = true
    end
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_BeginDisabled(ctx, sel_preset == nil)
    -- Theme.selectable draws its text on the draw list, which BeginDisabled does not dim: dim it by colour
    if Theme.selectable(ctx, menu_labels[2] .. "##alpm_del", false, nil, nil, nil,
                        { text_col = sel_preset and P.text or P.text_dim }) and sel_preset then
      confirm_delete_preset("main", sel_preset)
    end
    reaper.ImGui_EndDisabled(ctx)
    item_tooltip(sel_preset and ("Delete '" .. (sel_preset.name or "?") .. "' (asks first)")
      or "Choose a preset in the list first")
    reaper.ImGui_Separator(ctx)
    if Theme.selectable(ctx, menu_labels[3] .. "##alpm_exp") then
      export_links_dialog()
    end
    if Theme.selectable(ctx, menu_labels[4] .. "##alpm_imp") then
      import_links_dialog()
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

--- Save as Preset popup (opened from the toolbar).
local function draw_save_preset_popup()
  if save_preset_popup then
    reaper.ImGui_OpenPopup(ctx, "Save as Preset##save_preset_popup")
    save_preset_popup = false
  end
  if reaper.ImGui_BeginPopup(ctx, "Save as Preset##save_preset_popup") then
    -- HC5: Esc first reverts the active name field, a second Esc closes the popup
    if not reaper.ImGui_IsAnyItemActive(ctx) and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_Text(ctx, "Preset Name:")
    local hint = "e.g. Inverse EQ \xe2\x80\x94 Pro-Q 4"
    reaper.ImGui_SetNextItemWidth(ctx, (reaper.ImGui_CalcTextSize(ctx, hint)) + L.xxxl * 2)
    if reaper.ImGui_IsWindowAppearing(ctx) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    local chg, new_name = reaper.ImGui_InputTextWithHint(ctx, "##save_pn", hint, save_preset_name, 256)
    if chg then save_preset_name = new_name end
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    local can_save = (save_preset_name ~= "")
    local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
                       or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false)
    reaper.ImGui_BeginDisabled(ctx, not can_save)
    if (reaper.ImGui_Button(ctx, "Save##do_save_preset") or enter_pressed) and can_save then
      local name = save_preset_name
      if save_preset_from_links(name) then
        save_presets()
        Presets.sel = #Presets.list
        set_status(string.format("Saved preset '%s'", name), "ok")
        save_preset_name = ""
        link_sel = {}
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndDisabled(ctx)
    if not can_save then item_tooltip("Type a name first") end
    reaper.ImGui_SameLine(ctx, 0, L.md)
    if reaper.ImGui_Button(ctx, "Cancel##cancel_save_preset") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

--- One row of the Active Links table.
local function draw_link_row(P, i, lk, row_h)
  reaper.ImGui_PushID(ctx, i)
  reaper.ImGui_TableNextRow(ctx, 0, row_h)
  local tra = tr_by_guid(lk.a_guid)
  local trb = tr_by_guid(lk.b_guid)
  local tracks_ok = (tra ~= nil and trb ~= nil)
  local fxi_a = tracks_ok and resolve_fx(tra, lk.a_fxi, lk.a_fxguid) or -1
  local fxi_b = tracks_ok and resolve_fx(trb, lk.b_fxi, lk.b_fxguid) or -1
  local content_h = row_h - L.xs * 2
  local text_h = reaper.ImGui_GetTextLineHeight(ctx)

  -- Row selection (invisible selectable spanning the row, exactly the cell content height)
  reaper.ImGui_TableSetColumnIndex(ctx, 0)
  local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                  | reaper.ImGui_SelectableFlags_AllowOverlap()
  if Theme.selectable(ctx, "##sel_row", link_sel[i] == true, sel_flags, 0, content_h) then
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

  -- Right-click context menu on the row
  local is_inv = (lk.mode ~= "follow")
  local ctx_labels = { lk.link_paused and "Resume link" or "Pause link",
                       is_inv and "Switch to Follow" or "Switch to Inverse", "Delete link..." }
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, menu_min_width(ctx_labels), 0, 1e6, 1e6)
  if reaper.ImGui_BeginPopupContextItem(ctx, "row_ctx") then
    if Theme.selectable(ctx, ctx_labels[1] .. "##rc_pause") then toggle_link_pause(lk) end
    if Theme.selectable(ctx, ctx_labels[2] .. "##rc_mode") then toggle_link_mode(lk) end
    reaper.ImGui_Separator(ctx)
    if Theme.selectable(ctx, ctx_labels[3] .. "##rc_del") then confirm_delete_link(lk) end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Paused rows: names in text_dim (>= 4.5:1), no alpha fade; the Paused badge carries the state
  local col_a = lk.link_paused and P.text_dim or P.green
  local col_b = lk.link_paused and P.text_dim or P.accent2

  -- Track A
  reaper.ImGui_SameLine(ctx, 0, 0)
  Theme.align(ctx, row_h, text_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col_a)
  reaper.ImGui_Text(ctx, lk.a_name)
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Track B
  reaper.ImGui_TableSetColumnIndex(ctx, 1)
  Theme.align(ctx, row_h, text_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col_b)
  reaper.ImGui_Text(ctx, lk.b_name)
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Live Values / state badge
  reaper.ImGui_TableSetColumnIndex(ctx, 2)
  Theme.align(ctx, row_h, L.btn_sm.h)
  if not tracks_ok then
    Theme.badge(ctx, "OFFLINE", {
      color = P.red_l, bg = P.red_d, w = -1, preset = L.btn_sm, fonts = fonts, id = "off",
      tooltip = "Track missing: " .. ((not tra) and lk.a_name or lk.b_name),
    })
  elseif fxi_a < 0 or fxi_b < 0 then
    Theme.badge(ctx, "FX missing", {
      color = P.red_l, bg = P.red_d, w = -1, preset = L.btn_sm, fonts = fonts, id = "fxm",
      tooltip = string.format("'%s' is no longer on %s", (fxi_a < 0) and lk.a_fxname or lk.b_fxname,
        (fxi_a < 0) and lk.a_name or lk.b_name),
    })
  elseif lk.link_paused then
    Theme.badge(ctx, "Paused", {
      color = P.yellow, w = -1, preset = L.btn_sm, fonts = fonts, id = "pz",
      tooltip = "This link is paused: the values do not follow. Click the play icon to resume.",
    })
  else
    local val_avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local bar_w = math.max(L.md, math.floor((val_avail - L.sm) * 0.5))
    local av = reaper.TrackFX_GetParamNormalized(tra, fxi_a, lk.a_pi)
    local bv = reaper.TrackFX_GetParamNormalized(trb, fxi_b, lk.b_pi)
    Theme.badge(ctx, fmt_val(tra, fxi_a, lk.a_pi, av), {
      w = bar_w, preset = L.btn_sm, fonts = fonts, color = P.green_l, bg = P.green_d, id = "va",
    })
    reaper.ImGui_SameLine(ctx, 0, L.sm)
    Theme.badge(ctx, fmt_val(trb, fxi_b, lk.b_pi, bv), {
      w = bar_w, preset = L.btn_sm, fonts = fonts, color = P.accent2_l, bg = P.accent2_d, id = "vb",
    })
  end

  -- Mode
  reaper.ImGui_TableSetColumnIndex(ctx, 3)
  Theme.align(ctx, row_h, L.btn_sm.h)
  if Theme.toggle_button(ctx, "tbl_m", is_inv and "Inverse" or "Follow", is_inv, {
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
    tooltip = is_inv and "Inverse: when one goes up, the other goes down. Click to switch to Follow."
      or "Follow: both move the same way. Click to switch to Inverse.",
  }) then
    toggle_link_mode(lk)
  end

  -- Strength (HC2/HC3 drag; saved once on release)
  reaper.ImGui_TableSetColumnIndex(ctx, 4)
  Theme.align(ctx, row_h, L.btn_sm.h)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local sp_vars, sp_font = Theme.push_button_preset(ctx, fonts, L.btn_sm)
  local ch_s, np_s, s_commit = param_drag(tostring(lk), "tbl_s", (lk.strength or DEFAULTS.link_strength) * 100, {
    speed = 0.5, lo = 0, hi = 100, fmt = "%.0f%%", type_fmt = "%.1f",
    default = DEFAULTS.link_strength * 100,
    type_label = "Strength (%)",
    tooltip = "Strength. Drag; " .. MOD_LABEL .. "-drag fine; double-click resets to 100%; "
      .. MOD_LABEL .. "-click to type.",
  })
  Theme.pop_button_preset(ctx, sp_vars, sp_font)
  if ch_s then lk.strength = np_s / 100 end
  if s_commit then save_links() end

  -- Pause
  reaper.ImGui_TableSetColumnIndex(ctx, 5)
  local pause_w = L.icon_sm.size + L.icon_sm.pad * 2
  Theme.align(ctx, row_h, pause_w)
  if Theme.icon_btn(ctx, "lp", lk.link_paused and Theme.icons.play or Theme.icons.pause, {
    preset = L.icon_sm,
    color = P.text_dim,
    tooltip = lk.link_paused and "Resume link" or "Pause link",
  }) then
    toggle_link_pause(lk)
  end

  -- Remove (destructive: icon_md target, confirm first)
  reaper.ImGui_TableSetColumnIndex(ctx, 6)
  local del_w = L.icon_md.size + L.icon_md.pad * 2
  local del_h = math.min(del_w, content_h)
  Theme.align(ctx, row_h, del_h)
  if Theme.icon_btn(ctx, "ld", Theme.icons.close, {
    preset = L.icon_md,
    h = del_h,
    color = P.red,
    tooltip = "Delete link",
  }) then
    confirm_delete_link(lk)
  end

  reaper.ImGui_PopID(ctx)
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
    link_sel = {}
  else
    _current_proj = cur_proj
  end

  Theme.center_next_window(ctx, FIRST_USE_W, FIRST_USE_H, reaper.ImGui_Cond_FirstUseEver())

  -- NoNavInputs: Space is forwarded to REAPER (HC6) instead of activating the nav-focused widget
  local win_flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNavInputs()
  local vis, op = reaper.ImGui_Begin(ctx, "Fancy Parameter Link", true, win_flags)
  if vis then
    local docked = reaper.ImGui_IsWindowDocked(ctx)
    poll_last_touched()

    -- Header status line: latest message for a few seconds, otherwise the selection count
    local subtitle_text = nil
    local subtitle_col = nil
    local sel_count = 0
    for i = 1, #links do if link_sel[i] then sel_count = sel_count + 1 end end

    if status_msg ~= "" then
      local elapsed = reaper.time_precise() - status_time
      if elapsed < STATUS_SECS then
        subtitle_text = status_msg
        subtitle_col = (status_kind == "warn") and P.yellow or P.text
      else
        status_msg = ""
      end
    end
    if not subtitle_text and sel_count > 0 then
      subtitle_text = string.format("%d selected", sel_count)
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
        reaper.ImGui_Dummy(ctx, 0, L.xs)

        draw_links_toolbar(P, sel_count)
        draw_save_preset_popup()

        reaper.ImGui_Dummy(ctx, 0, L.sm)

        -- Active Links Table (grouped by parameter)
        local _, ah = reaper.ImGui_GetContentRegionAvail(ctx)
        local tbl_h = math.max(L.row_h * 3, ah)
        local row_h = SETTINGS.row_height or DEFAULTS.row_height

        local link_groups = get_link_groups()

        if reaper.ImGui_BeginChild(ctx, "links_scroll", 0, tbl_h) then
          if #links == 0 then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
            reaper.ImGui_TextWrapped(ctx, "No links yet. Select 2+ tracks and a plugin, then Add Links.")
            reaper.ImGui_PopStyleColor(ctx, 1)
          end

          -- Column widths measured from their content (small badge font is narrower than this)
          local val_col_w  = ((reaper.ImGui_CalcTextSize(ctx, "-000.0 dB")) + L.btn_sm.pad_x * 2) * 2 + L.sm
          local mode_col_w = math.max((reaper.ImGui_CalcTextSize(ctx, "Inverse")), (reaper.ImGui_CalcTextSize(ctx, "Follow")))
                             + L.btn_sm.pad_x * 2 + L.md
          local str_col_w  = (reaper.ImGui_CalcTextSize(ctx, "100%")) + L.xxxl

          for gi, grp in ipairs(link_groups) do
            -- Group header: Plugin / Parameter (N links)
            local grp_label = string.format("%s  /  %s  (%d)##grp%d", grp.plugin, grp.param, #grp.links, gi)
            local grp_open = Theme.collapsing_header(ctx, grp_label)

            if grp_open then
              local TFLG = reaper.ImGui_TableFlags_RowBg()
                         | reaper.ImGui_TableFlags_Borders()
                         | reaper.ImGui_TableFlags_Resizable()

              if reaper.ImGui_BeginTable(ctx, "ltbl_" .. gi, 7, TFLG) then
                reaper.ImGui_TableSetupColumn(ctx, "Track A",     reaper.ImGui_TableColumnFlags_WidthStretch(), 0.22)
                reaper.ImGui_TableSetupColumn(ctx, "Track B",     reaper.ImGui_TableColumnFlags_WidthStretch(), 0.22)
                reaper.ImGui_TableSetupColumn(ctx, "Live Values", reaper.ImGui_TableColumnFlags_WidthFixed(), val_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "Mode",        reaper.ImGui_TableColumnFlags_WidthFixed(), mode_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "Strength",    reaper.ImGui_TableColumnFlags_WidthFixed(), str_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "##pause",     reaper.ImGui_TableColumnFlags_WidthFixed(), UI.icon_col_w)
                reaper.ImGui_TableSetupColumn(ctx, "##del",       reaper.ImGui_TableColumnFlags_WidthFixed(), UI.icon_col_w)
                reaper.ImGui_TableHeadersRow(ctx)

                -- Long link lists: draw only the visible rows
                local clipper = get_clipper()
                reaper.ImGui_ListClipper_Begin(clipper, #grp.links)
                while reaper.ImGui_ListClipper_Step(clipper) do
                  local d0, d1 = reaper.ImGui_ListClipper_GetDisplayRange(clipper)
                  for k = d0 + 1, d1 do
                    local entry = grp.links[k]
                    draw_link_row(P, entry.idx, entry.lk, row_h)
                  end
                end

                reaper.ImGui_EndTable(ctx)
              end
              reaper.ImGui_Dummy(ctx, 0, L.sm)
            end
          end

          reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_EndChild(ctx)
      end

      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 2)

    -- Modals rendering
    draw_preset_modal()
    draw_info_modal()
    draw_settings_modal()
    draw_confirm_modal(P, "main")

    local any_popup = reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())

    -- HC5: modal -> active edit -> link selection -> window (only when floating)
    if not any_popup
       and not reaper.ImGui_IsAnyItemActive(ctx)
       and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
      if next(link_sel) ~= nil then
        link_sel = {}
      elseif not docked then
        op = false
      end
    end

    -- HC6: forward Space chords to the user's Main-section binding while the window is focused
    if not any_popup
       and not reaper.ImGui_IsAnyItemActive(ctx)
       and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
      for mod, cmd in pairs(space_cmds) do
        if reaper.ImGui_Shortcut(ctx, mod | reaper.ImGui_Key_Space()) then
          reaper.Main_OnCommand(cmd, 0)
        end
      end
    end

    -- ReaImGui's Begin calls End itself when it returns false
    reaper.ImGui_End(ctx)
  end

  Theme.pop_font(ctx, pushed_default)
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
local function main()
  Utils.init_toolbar_toggle()
  load_links()
  load_presets()
  load_settings()

  local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
  ctx = reaper.ImGui_CreateContext("Fancy Parameter Link", dock_flag)
  fonts = Theme.create_fonts(ctx)
  Theme.attach_fonts(ctx, fonts)
  load_space_bindings()

  reaper.atexit(function()
    save_links()
    save_presets()
    save_settings()
  end)

  reaper.defer(loop)
end

main()
