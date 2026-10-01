-- @description Fancy Pitch Correct
-- @author Fancy Scripts
-- @version 2.6.0
-- @changelog
--   + Diagnostics spots off by default; note labels drawn above the curves and fitted to their block; clearer bypassed notes
--   + Esc cancels a canvas drag; wheel adjusts values (Cmd/Ctrl + wheel: fine); right-click Reset on Settings values
--   + Status messages for note resets, Settings resets and global defaults (not undoable); Split / Merge reasons inline
-- @about
--   Native Lua pitch correction and tracking.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n"
    .. "Install via Extensions > ReaPack > Browse Packages > 'ReaImGui'.",
    "Fancy Pitch Correct -- Missing ReaImGui", 0)
  return
end

local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_dir .. "../_lib/?.lua;" .. package.path

local Theme = require("theme")
local JSON  = require("json")

local dock_flag = (reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable()) or 0
local ctx = reaper.ImGui_CreateContext('Fancy Pitch Correct', dock_flag)
local fonts = Theme.create_fonts(ctx)
Theme.attach_fonts(ctx, fonts)

local show_settings_modal = false
local show_info_modal = false

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
  COMBO_LABELS.keys = labels_of(SCALE_KEYS, "display")  -- the header Key combo previews the short name ...
  COMBO_LABELS.key_names = labels_of(SCALE_KEYS, "name") -- ... and lists the long one
  COMBO_LABELS.scales = labels_of(SCALE_DEFINITIONS, "name")
  COMBO_LABELS.pitchmodes = labels_of(PITCHMODE_FLAT, "name")
  COMBO_LABELS.ranges = labels_of(VOCAL_RANGES, "name")
  COMBO_LABELS.detection = labels_of(DETECTION_MODES, "name")
  COMBO_LABELS.quality = labels_of(QUALITY_MODES, "name")
end

-------------------------------------------------------------------------------
-- 1. STATE & SETTINGS
-------------------------------------------------------------------------------

-- Factory values of every value control: the single place these numbers live. Double-click on a
-- control, every Settings "Reset" and "Reset section" restore its entry here; the initial `state`
-- and `global_defaults` read from it.
local DEFAULTS = {
  -- Settings presets: the default pick of each list (an index into its table above; the algorithm into PITCHMODE_FLAT)
  preset_range_idx = 1,
  preset_mode_idx = 1,
  preset_quality_idx = 2,
  preset_pitchmode_idx = DEFAULT_PITCH_MODE_IDX,
  keep_pitch_mode = false,   -- Settings: leave each item's own pitch algorithm alone
  -- Cascade parameters (Global -> Item -> Note)
  retune_speed = 1.0,        -- 0.0–1.0 (correction strength)
  transition_ms = 35,        -- 5–60ms (smoothstep crossfade)
  onset_ramp_ms = 35,        -- 5–60ms (silence → correction fade-in)
  legato_threshold_ms = 120, -- 50–300ms (gap below = legato blend)
}
-- Analysis engine (Settings > Advanced DSP): the values of the default presets, so a preset table and its default pick
-- can never drift apart
DEFAULTS.min_freq = VOCAL_RANGES[DEFAULTS.preset_range_idx].min
DEFAULTS.max_freq = VOCAL_RANGES[DEFAULTS.preset_range_idx].max
DEFAULTS.threshold = DETECTION_MODES[DEFAULTS.preset_mode_idx].threshold
DEFAULTS.block_size = QUALITY_MODES[DEFAULTS.preset_quality_idx].block
DEFAULTS.hop_size = QUALITY_MODES[DEFAULTS.preset_quality_idx].hop   -- how many samples to advance per block

-- Global cascade defaults (project-wide, persisted in ExtState)
local global_defaults = {
  retune_speed = DEFAULTS.retune_speed,
  transition_ms = DEFAULTS.transition_ms,
  onset_ramp_ms = DEFAULTS.onset_ramp_ms,
  legato_threshold_ms = DEFAULTS.legato_threshold_ms,
}

-- User-facing names for the value controls (used in undo labels; never show raw keys)
local PARAM_LABELS = {
  retune_speed = "Correction Strength",
  transition_ms = "Transition",
  onset_ramp_ms = "Onset Ramp",
  legato_threshold_ms = "Legato Gap",
  scoop_shape = "Scoop", -- per-note only (note context menu); the same name as the Shift + vibrato-zone drag
}

-- Named constants, in one table so they take a single one of the chunk's 200 locals
local K = {
  -- Take extension key holding the analysis / note model (JSON)
  TAKE_DATA_KEY = "P_EXT:fancy_pitch_data",

  -- How long a status message replaces the dock's hint line
  STATUS_SECONDS = 4.0,

  -- Platform label of REAPER's command modifier, for "Cmd+Z to undo" style messages
  -- GetOS() is "OSX32"/"OSX64" on Intel Macs and "macOS-arm64" on Apple Silicon
  MOD_LABEL = (function()
    local os_name = reaper.GetOS() or ""
    return (os_name:match("OSX") or os_name:match("macOS")) and "Cmd" or "Ctrl"
  end)(),

  -- Ctrl/Cmd held during a note pitch drag scales the pixel-to-semitone movement by this factor (fine adjust)
  FINE_ADJUST_SCALE = 0.1,

  -- Wheel over a value control (param_drag): one notch moves it by 1 / WHEEL_NOTCHES of its range (Ctrl/Cmd + wheel:
  -- FINE_ADJUST_SCALE of that); a run of notches is one edit, committed this long (seconds) after the last notch
  WHEEL_NOTCHES = 50,
  WHEEL_IDLE_S = 0.25,

  -- Where a value comes from, in words (a badge colour is only a second cue): the dock's strength slider and the note
  -- menu's values show it after themselves
  SCOPE_TAGS = { note = "· note", item = "· item", global = "· global" },

  -- Window size on first use (a saved size wins); wider when the full header needs it (see loop_body)
  FIRST_USE_W = 920,
  FIRST_USE_H = 620,

  -- Hard limits start_analysis enforces on the engine sizes, whatever the UI or older state holds
  BLOCK_SIZE_MIN = 64,
  BLOCK_SIZE_MAX = 16384,

  -- The time one frame may spend reading and analysing audio before it yields to the window (seconds, measured with
  -- reaper.time_precise). Small on purpose: the window keeps answering (Cancel, Esc, scrolling) and the analysis
  -- simply takes more frames
  ANALYSIS_SLICE_S = 0.008,

  -- Analysis Cancel: the header's Analyze slot turns into this button while an analysis runs (see hdr_draw_analyze)
  CANCEL_FMT = "Cancel %d%%",
  CANCELLED_TEXT = "Analysis cancelled.",

  -- Error recovery (see loop): the window shows this, with Retry and Close, instead of disappearing
  FATAL_TEXT = "Something went wrong. Your corrections on the items are unchanged.",
  FATAL_AGAIN_TEXT = "It happened again. If Retry keeps failing, close this window and open the script again.",

  -- An arrow-key nudge burst is committed this long (seconds) after its last event (see service_nudge_burst)
  NUDGE_IDLE_S = 0.25,

  -- Plain Space's fallback when the user bound none: Transport: Play/stop (see Space forwarding, HC6)
  SPACE_FALLBACK_CMD = 40044,

  -- SetNextWindowSizeConstraints: "no maximum"
  SIZE_UNBOUNDED = 1e6,

  -- Settings copy and values shared by the form rows (see K.SETTINGS_SECTIONS)
  LOCKED_REASON = "Locked while analyzing",          -- why the engine controls are disabled (shown once, at the top of the form)
  CUSTOM_PRESET = "Custom",                          -- what a preset combo reads when the values match none of its presets
  KEEP_PITCH_LABEL = "Keep each item's own pitch algorithm",
  DEFAULT_SAMPLE_RATE = 44100,                       -- the block / hop readouts assume this until an item has been analysed

  -- Value ranges { lowest, highest } of the Settings drags; a stored value is clamped to them (see K.PERSIST)
  LIMITS = {
    threshold = { 0.05, 0.5 },
    min_freq = { 20, 200 },
    max_freq = { 200, 2000 },
  },

  -- The Pitched Items panel never gets narrower than this (BODY.min_sidebar_w); a stored width is checked against it
  SIDEBAR_MIN_W = 160,

  -- Timeline view of the canvas: zoom, scroll and ruler (see draw_graph)
  ZOOM_STEP = 1.25,        -- one Ctrl/Cmd + wheel notch divides (up) or multiplies (down) the visible span by this
  MIN_VIEW_SPAN_S = 0.25,  -- never zoom in beyond this many seconds (an item shorter than this cannot be zoomed)
  SCROLL_STEP = 0.1,       -- one plain wheel notch scrolls the window by this fraction of its span
  VIEW_EPS_S = 1e-6,       -- a window this close to the whole item counts as "not zoomed"
  RULER_MINOR_DIV = 5,     -- minor ticks per major tick
  RULER_WIDEN = 1.5,       -- a label interval that does not fit grows to the next 1-2-5 step above interval * this
  RULER_MAX_TRIES = 8,     -- widenings tried before the ruler gives up on making every label fit

  -- Canvas colours are not defined here: draw_graph and the Layers popup swatches read the same Theme palette tokens
  -- (Theme.get_palette().canvas, see section 4A of _lib/theme.lua), which follow the theme mode.
  SPOT_R = Theme.layout.sm,                          -- smart-spot circle radius
  ANCHOR_R = Theme.layout.sm + Theme.layout.xs,      -- trend-anchor diamond half-diagonal
  EDIT_MARK = Theme.layout.sm + Theme.layout.xs,     -- side of the square that marks an edited note
  EDGE_GRAB = Theme.layout.sm * 2,                   -- note edge grab zone, per side
  EDGE_GRAB_HOVER = Theme.layout.sm * 3,             -- ... while the pointer rests on that edge
  EDGE_GRAB_MAX_FRAC = 0.25,                         -- a zone never takes more than this fraction of the block width (both edges stay usable)
  PIANO_W = Theme.layout.xxxl + Theme.layout.md,     -- the piano-key column left of the note area (40)
  ZONE_MIN_W = Theme.layout.lg,                      -- a note's stability / vibrato zone is at least this wide (12)
  HANDLE_W = 3,                                      -- visible width of a note's edge trim handle
  TONIC_STRIP_W = 3,                                 -- the accent strip on the tonic key
  ZONE_PILLS_MIN_W = 40,                             -- a block narrower than this shows no Shift zone names on pills
}

local state = {
  is_analyzing = false,
  progress = 0,
  results = {}, -- array of { time, freq, note }
  analysis_empty = false, -- the last analysis of the target found no pitched notes (drives the dock hint; the canvas message reads it too)

  -- Settings > Pitch Shift Engine: the algorithm written to the item (an entry of PITCHMODE_FLAT) and whether to write it at all
  preset_pitchmode_idx = DEFAULTS.preset_pitchmode_idx,
  pitchmode_value = PITCHMODE_FLAT[DEFAULTS.preset_pitchmode_idx].value,
  pitchmode_name = PITCHMODE_FLAT[DEFAULTS.preset_pitchmode_idx].name,
  keep_pitch_mode = DEFAULTS.keep_pitch_mode,

  -- Pitch detection parameters (Settings > Analysis & Detection, Advanced DSP)
  block_size = DEFAULTS.block_size,
  threshold = DEFAULTS.threshold,
  min_freq = DEFAULTS.min_freq,
  max_freq = DEFAULTS.max_freq,
  hop_size = DEFAULTS.hop_size, -- How many samples to advance per block
  analysis_params = nil,        -- the five values above, frozen by start_analysis for the running analysis

  -- Analysis state
  accessor = nil,
  sample_rate = 44100,
  num_channels = 1,
  start_time = 0,
  end_time = 0,
  current_time = 0,
  item_len = 0,
  buffer = nil,

  -- Interaction state
  hovered_note = nil,   -- index of note block under cursor
  hovered_zone = nil,   -- "drift" / "pitch" / "vibrato"
  hovered_edge = nil,   -- { note_idx, edge ("left"/"right") } for edge trimming
  selected_note = nil,  -- index of primary selected note (for single-note ops)
  selected_notes = {},  -- set { [note_idx] = true } for multi-select (merge, batch drag, quantize)
  -- Every gesture table also holds view_min / view_max: the pitch range frozen when it began (the vertical scale
  -- must not change under the cursor mid-gesture)
  drag = nil,           -- { note_idx, anchor_idx, zone, shift_mode, start_mouse_y, last_y, pitch_st, original_value, orig_values, dirty, view_min, view_max }
  edge_drag = nil,      -- { note_idx, edge, start_mouse_x, original_time, dirty, view_min, view_max }
  marquee = nil,        -- { start_x, start_y, cur_x, cur_y, active, has_shift, init_sel, view_min, view_max }
  shift_mode = false,   -- true when Shift held before click (zone remap)
  context_menu_note = nil, -- index of note for right-click context menu
  view_t0 = nil,        -- visible time window of the canvas, seconds relative to the item start; nil = the whole item
  view_t1 = nil,        -- (both nil or both set; changed by the wheel in draw_graph, reset when the target changes or the model is analysed or cleared, kept through undo / redo of the same take)

  -- Visualization toggles
  show_note_blocks = true,
  show_raw_pitch = true,
  show_trend = false,
  show_smart_spots = false,  -- Diagnostics layer: off unless enabled in Settings > Diagnostics (a stored choice still wins)
  show_split_points = false,
  show_preview = true,
  show_vibrato_regions = false,

  -- Target item binding (persistent GUID lock)
  target_take_guid = nil,
  target_take_name = nil,

  -- Undo / model sync with REAPER
  last_change_count = nil,  -- GetProjectStateChangeCount(0) after the last own write / resync (nil = resync next frame)
  raw_cache = {},           -- [guid] = raw P_EXT string last written or loaded by this script
  missing_takes = {},       -- [guid] = true when the take no longer resolves (row is kept in the sidebar)
  stale_takes = {},         -- [guid] = true: a global default changed after the take's envelope was written and the take was not re-applied since
  last_seen_sel_guid = nil, -- GUID of the first selected audio item seen last frame (edge-triggered tracker)
  nudge_burst = nil,        -- pending arrow-key nudge { total_st, last_time, keys = { up, down }, guid }

  -- What the script asked REAPER about, valid for one value of GetProjectStateChangeCount(0) of one project (see
  -- K.refresh_project_cache, K.drop_project_cache): takes by GUID (take = pointer, or false when the item is not in
  -- the project; scanned = the full item scan ran), the item of a take, and whether a take's pitch envelope is bypassed
  cache = { count = nil, proj = nil, takes = {}, items = {}, bypass = {} },
  -- The target as loop_body resolved it this frame (see K.frame_target)
  frame = { guid = nil, take = nil, item = nil },
  -- The canvas's drawing cache (see K.canvas_cache_begin): the mapping the cached coordinates belong to (map, gen counts
  -- its changes), the raw min / max of the analysis frames, the raw pitch trace, and one entry per note (weak keys)
  draw_cache = { gen = 0, map = {}, range = { n = 0 }, raw = {}, notes = setmetatable({}, { __mode = "k" }) },
  clipper = nil,            -- the Pitched Items list clipper (kept here so it is not garbage-collected)
  clipper_ctx = nil,        -- the ImGui context it was created for

  -- Status channel (drawn in the bottom dock) and the pending confirmation request (see request_confirm)
  status = { text = "", until_time = 0 },
  confirm = nil,

  -- Persisted settings (see K.PERSIST): [ExtState key] = the string last loaded or saved, so a save writes only what changed
  stored = {},
  -- Items whose saved analysis could not be decoded: [take guid] = true (see load_take_data, K.clear_unreadable)
  unreadable_takes = {},

  -- Error recovery: a failed frame sets fatal = { message, count } and the window shows only that message
  -- (Retry / Close) until the user picks one; error_streak counts the frames in a row that failed; undo_open is
  -- true while apply_envelope_to_take holds an open undo block (a failed frame must not leave it open)
  fatal = nil,
  error_streak = 0,
  undo_open = false,

  -- Multi-item Pitched Items state
  session_takes = {},  -- [guid] = take_data table
  session_order = {},  -- array of guids
  sidebar_w = 200,     -- Pitched Items width: the body table's fixed column, mirrored from ImGui's live width each frame
  sidebar_open = true, -- Pitched Items drawer preference (defaults open); a window too narrow for it shows the tag instead
  sidebar_gen = 0,     -- body table id generation: a new id makes ImGui take TableSetupColumn's width again (see draw_body_split)
  sidebar_scroll_y = 0, -- the Pitched Items list's scroll position, carried over when the body table gets a new id
  sidebar_tabled = false, -- the resizable body table was drawn last frame
  grip_hover_since = nil, -- time the mouse began resting on the divider between canvas and panel (its tooltip waits)
  grip_pressed = false,   -- a press began on that divider: the width is saved when the button is released
  selection_issue = nil,  -- why REAPER's first selected item cannot be a target (MIDI / no audio take); nil when it can or nothing is selected

  -- Key & Scale state
  key_idx = 1,       -- 1..12 (1 = C)
  scale_idx = 1,     -- 1..6 (1 = Major)
  scale_pc_set = {}  -- pitch class lookup set [0..11] = true/false
}

--- Settings: choose the pitch algorithm written to the items (an index into PITCHMODE_FLAT).
K.set_pitch_algorithm = function(idx)
  local entry = PITCHMODE_FLAT[idx]
  if not entry then return end
  state.preset_pitchmode_idx = idx
  state.pitchmode_value = entry.value
  state.pitchmode_name = entry.name
end

--- Resolve an effective value through the Global → Item → Note cascade.
--- For per-note cascadable keys: retune_speed, transition_ms, onset_ramp_ms.
--- For per-item only keys: legato_threshold_ms.
local function get_effective(note, key)
  -- 1. Per-note override (not applicable for legato_threshold_ms)
  if key ~= "legato_threshold_ms" then
    if note and note.controls and note.controls[key] ~= nil then
      return note.controls[key]
    end
  end
  -- 2. Per-item override
  if state.target_take_guid then
    local take_data = state.session_takes[state.target_take_guid]
    if take_data and take_data.overrides and take_data.overrides[key] ~= nil then
      return take_data.overrides[key]
    end
  end
  -- 3. Global default
  return global_defaults[key]
end

--- Returns the override level for display: "note", "item", or "global"
local function get_override_level(note, key)
  if key ~= "legato_threshold_ms" then
    if note and note.controls and note.controls[key] ~= nil then return "note" end
  end
  if state.target_take_guid then
    local take_data = state.session_takes[state.target_take_guid]
    if take_data and take_data.overrides and take_data.overrides[key] ~= nil then return "item" end
  end
  return "global"
end

--- Show a short message in the bottom dock for STATUS_SECONDS (replaces the dock's hint line).
local function set_status(msg)
  state.status.text = msg or ""
  state.status.until_time = reaper.time_precise() + K.STATUS_SECONDS
end

--- Ask the user to confirm a destructive action. draw_confirm_modal() shows the modal.
--- req = { id, title, body_lines = { string... }, confirm_label, on_confirm = function }
--- The modal names the consequence, Cancel comes first and Esc cancels; on_confirm runs once.
local function request_confirm(req)
  if not req or not req.on_confirm then return end
  state.confirm = {
    id = req.id or "action",
    title = req.title or "Are you sure?",
    body_lines = req.body_lines or {},
    confirm_label = req.confirm_label or "Confirm",
    on_confirm = req.on_confirm,
    open_pending = true,  -- OpenPopup once, on the next draw_confirm_modal() call
    opened = false,
  }
end

local function update_scale_pitch_classes()
  local scale = SCALE_DEFINITIONS[state.scale_idx]
  local root_pc = (state.key_idx - 1) % 12
  state.scale_pc_set = {}
  if scale then
    for _, intv in ipairs(scale.intervals) do
      local pc = (root_pc + intv) % 12
      state.scale_pc_set[pc] = true
    end
  end
end

local function is_pitch_in_scale(pitch_class)
  if not state.scale_pc_set or not pitch_class then return true end
  local pc = (math.floor(pitch_class + 0.5) % 12 + 12) % 12
  return state.scale_pc_set[pc] == true
end

-- Settings kept between launches (ExtState section "FancyScripts", keys "pitch_..."): one entry per value.
--   ext    the ExtState key            group  what K.save_settings(group) saves together
--   read   the live value as the string to store
--   apply  adopts a stored string after checking it: a number is finite and clamped to the control's range, a size is a
--          member of its list, a flag is "1" / "0", the algorithm is a mode REAPER still lists. A missing or unusable
--          string changes nothing, so the factory value (DEFAULTS) stays
-- state.stored holds the string last loaded or saved per key, so a save writes only the entries that changed.
K.PERSIST = (function()
  local list = {}
  local function add(group, ext, read, apply)
    list[#list + 1] = { group = group, ext = ext, read = read, apply = apply }
  end
  local function finite(raw)
    local n = tonumber(raw)
    if n and math.abs(n) < math.huge then return n end
    return nil
  end
  -- tbl[key] is a number within { lowest, highest } (no highest: no upper limit); fmt formats it for storing
  local function number(group, ext, tbl, key, limits, fmt)
    add(group, ext, function() return string.format(fmt or "%.14g", tbl[key]) end, function(raw)
      local n = finite(raw)
      if n then
        if limits[2] then n = math.min(limits[2], n) end
        tbl[key] = math.max(limits[1], n)
      end
    end)
  end
  -- tbl[key] is one of the numbers in `choices`
  local function choice(group, ext, tbl, key, choices)
    add(group, ext, function() return string.format("%.14g", tbl[key]) end, function(raw)
      local n = finite(raw)
      for _, c in ipairs(choices) do
        if n == c then
          tbl[key] = c
          return
        end
      end
    end)
  end
  -- tbl[key] is a boolean, stored as "1" / "0"
  local function flag(group, ext, tbl, key)
    add(group, ext, function() return tbl[key] and "1" or "0" end, function(raw)
      if raw == "1" then tbl[key] = true elseif raw == "0" then tbl[key] = false end
    end)
  end

  -- Global cascade defaults (project-wide), saved when a drag or a typed entry is committed or reset
  number("cascade", "pitch_retune_speed", global_defaults, "retune_speed", { 0, 1 })
  number("cascade", "pitch_transition_ms", global_defaults, "transition_ms", { 5, 60 })
  number("cascade", "pitch_onset_ramp_ms", global_defaults, "onset_ramp_ms", { 5, 60 })
  number("cascade", "pitch_legato_thresh_ms", global_defaults, "legato_threshold_ms", { 50, 300 })

  -- Settings: the engine and the pitch algorithm, saved when a control changes or is committed or reset
  choice("engine", "pitch_block_size", state, "block_size", BLOCK_SIZES)
  choice("engine", "pitch_hop_size", state, "hop_size", HOP_SIZES)
  number("engine", "pitch_threshold", state, "threshold", K.LIMITS.threshold)
  number("engine", "pitch_min_freq", state, "min_freq", K.LIMITS.min_freq)
  number("engine", "pitch_max_freq", state, "max_freq", K.LIMITS.max_freq)
  flag("engine", "pitch_keep_pitch_mode", state, "keep_pitch_mode")
  add("engine", "pitch_algorithm", function() return string.format("%.14g", state.pitchmode_value) end, function(raw)
    local value = finite(raw)
    for idx, entry in ipairs(PITCHMODE_FLAT) do
      if entry.value == value then
        K.set_pitch_algorithm(idx)
        return
      end
    end
  end)

  -- Canvas layers, saved when a checkbox changes
  flag("layers", "pitch_show_note_blocks", state, "show_note_blocks")
  flag("layers", "pitch_show_raw_pitch", state, "show_raw_pitch")
  flag("layers", "pitch_show_preview", state, "show_preview")
  flag("layers", "pitch_show_smart_spots", state, "show_smart_spots")
  flag("layers", "pitch_show_vibrato_regions", state, "show_vibrato_regions")
  flag("layers", "pitch_show_trend", state, "show_trend")
  flag("layers", "pitch_show_split_points", state, "show_split_points")

  -- The Pitched Items width, saved when a drag of the divider ends
  number("sidebar", "pitch_sidebar_w", state, "sidebar_w", { K.SIDEBAR_MIN_W }, "%.0f")
  return list
end)()

--- Adopt every stored setting (validated by its entry) and remember what is stored.
K.load_settings = function()
  for _, e in ipairs(K.PERSIST) do
    local raw = reaper.GetExtState("FancyScripts", e.ext)
    if raw and raw ~= "" then e.apply(raw) end
  end
  -- The hop never exceeds the block (either may come from a stored value)
  if state.hop_size > state.block_size then state.hop_size = state.block_size end
  for _, e in ipairs(K.PERSIST) do state.stored[e.ext] = e.read() end
end

--- Write the entries of `group` whose value differs from what was last loaded or saved (nothing when none does).
--- Call it when an edit is done (a change of a discrete control, the release of a drag, a typed entry, a reset),
--- never while a drag is moving.
K.save_settings = function(group)
  for _, e in ipairs(K.PERSIST) do
    if e.group == group then
      local now = e.read()
      if now ~= state.stored[e.ext] then
        state.stored[e.ext] = now
        reaper.SetExtState("FancyScripts", e.ext, now, true)
      end
    end
  end
end

-- Initialize key, scale, sidebar, and the persisted settings from ExtState
do
  local saved_key = tonumber(reaper.GetExtState("FancyScripts", "pitch_key_idx"))
  local saved_scale = tonumber(reaper.GetExtState("FancyScripts", "pitch_scale_idx"))
  if saved_key and saved_key >= 1 and saved_key <= #SCALE_KEYS then
    state.key_idx = saved_key
  end
  if saved_scale and saved_scale >= 1 and saved_scale <= #SCALE_DEFINITIONS then
    state.scale_idx = saved_scale
  end
  update_scale_pitch_classes()

  local saved_sidebar = reaper.GetExtState("FancyScripts", "pitch_sidebar_open")
  if saved_sidebar == "0" or saved_sidebar == "false" then
    state.sidebar_open = false
  else
    state.sidebar_open = true
  end

  -- Restore the global cascade defaults, the engine settings, the layers and the panel width
  K.load_settings()
end

-------------------------------------------------------------------------------
-- Project-state cache. Everything the window asks REAPER about every frame (which take a GUID is, its item, whether
-- its pitch envelope is bypassed) is remembered in state.cache and stays valid while REAPER's project state is the
-- same. Three rules invalidate it, and they are the only ones:
--   1. loop_body calls K.refresh_project_cache first thing every frame: a different GetProjectStateChangeCount(0)
--      (undo, redo, an item deleted or edited, the user's own edits) or a different current project (tab switch)
--      drops every entry.
--   2. note_own_write (called after every write of this script, each one closes its undo block first) drops them
--      right away, so nothing read after the write is older than the write.
--   3. A frame that failed drops them too (loop).
-- A dropped cache is refilled lazily, one REAPER call per entry, at most once per state.
-------------------------------------------------------------------------------

--- Forget everything the cache holds (and the count it belonged to, so the next frame starts from scratch).
K.drop_project_cache = function()
  local cache = state.cache
  cache.count, cache.proj = nil, nil
  cache.takes, cache.items, cache.bypass = {}, {}, {}
end

--- Once per frame, before anything reads the cache: one GetProjectStateChangeCount call and one EnumProjects call;
--- the cache is dropped when either differs from the one it was filled for.
K.refresh_project_cache = function()
  local cache = state.cache
  local count = reaper.GetProjectStateChangeCount(0)
  local proj = reaper.EnumProjects(-1)
  if count == nil or cache.count ~= count or cache.proj ~= proj then
    K.drop_project_cache()
    cache.count, cache.proj = count, proj
  end
end

-- Robustly resolve a media item take by GUID with SWS and item-scan fallbacks. The answer (a take, or "not in the
-- project") is cached per project state, so the full item scan runs at most once per state and GUID.
-- no_scan skips the full item scan (used by the per-frame trackers and the resync).
local function resolve_take_by_guid(guid, no_scan)
  if not guid then return nil end
  local takes = state.cache.takes
  local entry = takes[guid]
  if entry then
    if entry.take then return entry.take end
    if no_scan or entry.scanned then return nil end   -- known to be missing (the scan, when wanted, already ran)
  else
    entry = { take = false, scanned = false }
    takes[guid] = entry
  end

  local take = reaper.GetMediaItemTakeByGUID(0, guid)
  if not take and reaper.SNM_GetMediaItemTakeByGUID then
    take = reaper.SNM_GetMediaItemTakeByGUID(0, guid)
  end
  if not take and not no_scan then
    entry.scanned = true
    local num_items = reaper.CountMediaItems(0)
    for i = 0, num_items - 1 do
      local it = reaper.GetMediaItem(0, i)
      if it then
        local num_takes = reaper.CountTakes(it)
        for t = 0, num_takes - 1 do
          local tk = reaper.GetTake(it, t)
          if tk then
            local _, g = reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false)
            if g == guid then take = tk; break end
          end
        end
        if take then break end
      end
    end
  end
  entry.take = take or false
  return take
end

--- The item a take lives in (cached per project state), or nil.
K.take_item = function(take)
  local items = state.cache.items
  local item = items[take]
  if item == nil then
    item = reaper.GetMediaItemTake_Item(take) or false
    items[take] = item
  end
  return item or nil
end

--- GUID string of a take, or nil.
local function get_take_guid(take)
  if not take then return nil end
  local ok, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  if ok and guid and guid ~= "" then return guid end
  return nil
end

--- Raw P_EXT string of the pitch model on a take ("" when the take has none).
local function read_take_raw(take)
  if not take then return "" end
  local ok, raw = reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, "", false)
  if not ok or not raw then return "" end
  return raw
end

--- Record the project change count after this script's own write (undo block ended), so the
--- per-frame resync does not mistake the script's own edit for an undo / redo.
local function note_own_write()
  state.last_change_count = reaper.GetProjectStateChangeCount(0)
  K.drop_project_cache()   -- the write may have changed what the cache holds (a bypass flag, an envelope)
end

-- Resolve the target take reliably, even if the item becomes deselected in REAPER.
-- Never touches the user's item selection. The answer by GUID comes from the project-state cache; the fallback to
-- REAPER's selected item is asked every time (a selection change does not have to move the change count).
local function get_target_take()
  local take = nil
  if state.target_take_guid then
    take = resolve_take_by_guid(state.target_take_guid)
  end

  if not take then
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if sel_item then
      local sel_take = reaper.GetActiveTake(sel_item)
      if sel_take and not reaper.TakeIsMIDI(sel_take) then
        take = sel_take
        local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
        state.target_take_guid = guid
        state.target_take_name = reaper.GetTakeName(take)
      end
    end
  end

  if not take then return nil, nil end

  return take, K.take_item(take)
end

--- The target of this frame: what loop_body resolved once at the start of the frame (state.frame), so the header,
--- canvas, dock and sidebar do not each ask again. Only valid while the target is still the one that was resolved
--- (a click may switch it mid-frame): then it is resolved again (from the cache).
K.frame_target = function()
  local frame = state.frame
  if frame.guid ~= nil and frame.guid == state.target_take_guid then return frame.take, frame.item end
  return get_target_take()
end

--- Get effective track color for active take/item, converting native REAPER color to ImGui RGBA
local function get_target_track_color(take, item)
  if not take then return nil end
  if not item then
    item = reaper.GetMediaItemTake_Item(take)
  end
  if not item then return nil end

  -- 1. Check track color explicitly first
  local track = reaper.GetMediaItem_Track(item)
  if track then
    local tr_col = reaper.GetTrackColor(track)
    if tr_col and tr_col ~= 0 then
      return Theme.bgr_to_rgba(tr_col)
    end
  end

  -- 2. Fall back to displayed item color if track has default 0
  if reaper.GetDisplayedMediaItemColor then
    local disp_col = reaper.GetDisplayedMediaItemColor(item)
    if disp_col and disp_col ~= 0 then
      return Theme.bgr_to_rgba(disp_col)
    end
  end

  return nil
end

-- get_contrasting_text_color is the only chunk-level name of the colour maths below: its helpers stay
-- private to the block, so they do not count against the chunk's 200-local limit.
local get_contrasting_text_color
do
  --- sRGB channel (0-255) to linear light, the curve WCAG 2.x uses for relative luminance.
  local function srgb_channel_to_linear(c8)
    local c = c8 / 255
    if c <= 0.03928 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
  end

  --- WCAG relative luminance (0 = black, 1 = white) of an 0xRRGGBBAA colour (alpha ignored).
  local function relative_luminance(rgba)
    local r = srgb_channel_to_linear((rgba >> 24) & 0xFF)
    local g = srgb_channel_to_linear((rgba >> 16) & 0xFF)
    local b = srgb_channel_to_linear((rgba >> 8) & 0xFF)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  --- WCAG contrast ratio (1 to 21) between two relative luminances.
  local function contrast_ratio(lum_a, lum_b)
    if lum_a < lum_b then lum_a, lum_b = lum_b, lum_a end
    return (lum_a + 0.05) / (lum_b + 0.05)
  end

  --- Alpha-composites `fg` (0xRRGGBBAA) over the opaque colour `under`; the result is opaque.
  local function composite_over(fg, under)
    local a = (fg & 0xFF) / 255
    local out = 0
    for shift = 24, 8, -8 do
      local f = (fg >> shift) & 0xFF
      local u = (under >> shift) & 0xFF
      out = out | (math.floor(f * a + u * (1 - a) + 0.5) << shift)
    end
    return out | 0xFF
  end

  --- Text colour for a badge filled with `badge_bg`: P.text or P.bg, whichever has the higher WCAG
  --- contrast against the fill as it really shows (composited over the window background).
  get_contrasting_text_color = function(badge_bg)
    local P = Theme.get_palette()
    if not badge_bg then return P.text end
    local lum = relative_luminance(composite_over(badge_bg, P.bg))
    if contrast_ratio(relative_luminance(P.text), lum) >= contrast_ratio(relative_luminance(P.bg), lum) then
      return P.text
    end
    return P.bg
  end
end

-- Ensure the Take Pitch Envelope is active on the take, creating it if needed.
-- If force_unbypass is true (e.g. during analysis), guarantees it is active (ACT 1).
local function ensure_take_pitch_envelope(take, item, force_unbypass)
  if not take or not item then return nil end
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  local is_new = false

  if not env then
    is_new = true
    -- The action targets the selected items' active takes: temporarily select only the target
    -- item and make the take active, then restore the user's full selection and active take.
    local saved_sel = {}
    local sel_count = reaper.CountSelectedMediaItems(0)
    for i = 0, sel_count - 1 do
      local sel_it = reaper.GetSelectedMediaItem(0, i)
      if sel_it then saved_sel[#saved_sel + 1] = sel_it end
    end
    local prev_take = reaper.GetActiveTake(item)

    for _, sel_it in ipairs(saved_sel) do
      reaper.SetMediaItemSelected(sel_it, false)
    end
    reaper.SetMediaItemSelected(item, true)
    reaper.SetActiveTake(take)

    -- SWS command is "Show take pitch envelope" (explicit, non-toggling)
    local sws_cmd = reaper.NamedCommandLookup("_S&M_TAKEENV10")
    if sws_cmd > 0 then
      reaper.Main_OnCommand(sws_cmd, 0)
    else
      -- Native REAPER command 41612: "Take: Toggle take pitch envelope"
      reaper.Main_OnCommand(41612, 0)
    end

    reaper.UpdateArrange()
    env = reaper.GetTakeEnvelopeByName(take, "Pitch")

    -- Restore the previous selection (the target item is deselected unless it was selected before)
    reaper.SetMediaItemSelected(item, false)
    for _, sel_it in ipairs(saved_sel) do
      if reaper.ValidatePtr2(0, sel_it, "MediaItem*") then
        reaper.SetMediaItemSelected(sel_it, true)
      end
    end
    if prev_take and prev_take ~= take and reaper.ValidatePtr2(0, prev_take, "MediaItem_Take*") then
      reaper.SetActiveTake(prev_take)
    end
    reaper.UpdateArrange()
  end

  -- Guarantee envelope is ACTIVE (unbypassed, ACT 1) and VISIBLE (VIS 1)
  -- when newly created or when explicitly requested (e.g. upon analysis)
  if env and (is_new or force_unbypass) then
    local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if ok and chunk then
      local modified = false
      if chunk:match("ACT%s+0") then
        chunk = chunk:gsub("ACT%s+0", "ACT 1")
        modified = true
      end
      if chunk:match("VIS%s+0") then
        chunk = chunk:gsub("VIS%s+0", "VIS 1")
        modified = true
      end
      if modified then
        reaper.SetEnvelopeStateChunk(env, chunk, false)
        reaper.UpdateItemInProject(item)
        reaper.UpdateArrange()
      end
    end
  end

  return env
end

-------------------------------------------------------------------------------
-- 2. DSP LOGIC (YIN ALGORITHM)
-------------------------------------------------------------------------------

-- Convert frequency to MIDI note (fractional)
local function freq_to_note(freq)
  if freq <= 0 then return 0 end
  return 69 + 12 * (math.log(freq / 440.0) / math.log(2))
end

local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local function midi_to_name(midi)
  if not midi then return "" end
  local note_idx = (midi % 12) + 1
  local octave = math.floor(midi / 12) - 1
  return NOTE_NAMES[note_idx] .. octave
end

-- Process a single block of audio using the YIN algorithm
local function yin_process_block(samples, sample_rate, params)
  local b_size = params.calc_block_size or params.block_size

  -- Cache to native Lua table. reaper.array metamethods are extremely slow inside nested loops!
  local s = {}
  for i = 1, b_size do
    s[i] = samples[i]
  end

  local rms_sum = 0
  for i = 1, b_size do
    rms_sum = rms_sum + s[i] * s[i]
  end
  local rms = math.sqrt(rms_sum / b_size)

  local W = math.floor(b_size / 2)
  local max_tau = math.floor(sample_rate / params.min_freq)
  local min_tau = math.floor(sample_rate / params.max_freq)

  if max_tau > W then max_tau = W end
  if min_tau < 1 then min_tau = 1 end

  local diff = {}
  local cmndf = {}

  -- 1. Difference function
  for tau = 0, max_tau do
    local sum = 0
    for j = 1, W do
      local d = s[j] - s[j + tau]
      sum = sum + d * d
    end
    diff[tau] = sum
  end

  -- 2. Cumulative Mean Normalized Difference Function (CMNDF)
  cmndf[0] = 1.0
  local running_sum = 0
  for tau = 1, max_tau do
    running_sum = running_sum + diff[tau]
    if running_sum == 0 then
      cmndf[tau] = 1.0
    else
      cmndf[tau] = diff[tau] / (running_sum / tau)
    end
  end

  -- 3. Absolute threshold
  local tau_estimate = -1
  for tau = min_tau, max_tau do
    if cmndf[tau] < params.threshold then
      -- Find local minimum
      local cur_tau = tau
      while cur_tau + 1 <= max_tau and cmndf[cur_tau + 1] < cmndf[cur_tau] do
        cur_tau = cur_tau + 1
      end
      tau_estimate = cur_tau
      break
    end
  end

  if tau_estimate == -1 then
    -- Fallback to global minimum if nothing is below threshold
    local min_val = 1
    for tau = min_tau, max_tau do
      if cmndf[tau] < min_val then
        min_val = cmndf[tau]
        tau_estimate = tau
      end
    end
    -- If even the global minimum is high, it's likely unvoiced
    if min_val > params.threshold * 2 then
      return rms, nil
    end
  end

  -- 4. Parabolic interpolation for better precision
  local better_tau = tau_estimate
  if tau_estimate > 0 and tau_estimate < max_tau then
    local s0 = cmndf[tau_estimate - 1]
    local s1 = cmndf[tau_estimate]
    local s2 = cmndf[tau_estimate + 1]
    local denom = (2 * (2 * s1 - s2 - s0))
    if denom ~= 0 then
      local adjustment = (s2 - s0) / denom
      if math.abs(adjustment) < 1 then
         better_tau = better_tau + adjustment
      end
    end
  end

  return rms, sample_rate / better_tau
end

-------------------------------------------------------------------------------
-- 3. ANALYSIS ROUTINE (DEFERRED)
-------------------------------------------------------------------------------

--- Stop reading audio: destroy a live audio accessor and forget the running analysis's engine state. Safe at any
--- time and any number of times (Cancel, closing the window, an error recovery, atexit): it touches nothing else
--- and writes nothing to REAPER.
K.release_analysis = function()
  local accessor = state.accessor
  state.accessor = nil
  state.buffer = nil
  state.is_analyzing = false
  state.analysis_params = nil
  if accessor then pcall(reaper.DestroyAudioAccessor, accessor) end
end

--- Drop the in-memory analysis (results, notes, selection, a running analysis). Writes nothing to
--- REAPER: callers that also clear take data own the undo block (clear_take_analysis, wipe_entire_session).
local function reset_analysis_model()
  K.release_analysis()
  state.results = {}
  state.notes = nil
  state.split_points = nil
  state.progress = 0
  state.analysis_empty = false
  state.hovered_note = nil
  state.hovered_zone = nil
  state.selected_note = nil
  state.selected_notes = {}
  state.drag = nil
  state.marquee = nil
  state.nudge_burst = nil
  state.view_t0, state.view_t1 = nil, nil   -- the canvas shows the whole item again
end

--- True when the take has no Pitch envelope yet, or it is bypassed / hidden, i.e. when
--- ensure_take_pitch_envelope(take, item, true) would change project state.
local function pitch_envelope_needs_setup(take)
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if not env then return true end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not ok or not chunk then return false end
  return chunk:match("ACT%s+0") ~= nil or chunk:match("VIS%s+0") ~= nil
end

local function start_analysis()
  -- Prefer the current target (a sidebar click sets it without touching REAPER's selection);
  -- get_target_take() falls back to the selected audio item only when there is no usable target.
  local take, item = get_target_take()

  if not item or not take then
    set_status("Select an audio item first")
    return
  end

  local guid = get_take_guid(take)
  if guid then state.target_take_guid = guid end
  state.target_take_name = reaper.GetTakeName(take) or state.target_take_name

  state.start_time = 0 -- Relative to item start
  state.item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  state.end_time = state.item_len
  state.current_time = 0

  local source = reaper.GetMediaItemTake_Source(take)
  state.sample_rate = reaper.GetMediaSourceSampleRate(source)

  -- A bad engine value must never crash (negative array size) or hang (a hop of 0 never advances the
  -- analysis time) an analysis: clamp to 64 <= block, 1 <= hop <= block before anything is allocated
  local block = math.floor(tonumber(state.block_size) or DEFAULTS.block_size)
  state.block_size = math.max(K.BLOCK_SIZE_MIN, math.min(K.BLOCK_SIZE_MAX, block))
  local hop = math.floor(tonumber(state.hop_size) or DEFAULTS.hop_size)
  state.hop_size = math.max(1, math.min(state.block_size, hop))

  -- The running analysis reads this snapshot, never the live settings: the Settings controls are locked meanwhile,
  -- and a value changed some other way cannot overrun the sample buffer or mix two parameter sets
  state.analysis_params = {
    block_size = state.block_size, hop_size = state.hop_size, threshold = state.threshold,
    min_freq = state.min_freq, max_freq = state.max_freq,
  }

  state.accessor = reaper.CreateTakeAudioAccessor(take)
  state.buffer = reaper.new_array(state.analysis_params.block_size)

  state.results = {}
  state.is_analyzing = true
  state.analysis_empty = false
  state.progress = 0
  state.nudge_burst = nil
  state.view_t0, state.view_t1 = nil, nil   -- the canvas shows the whole item again

  -- Ensure take pitch envelope is created and active on the take upfront (own named undo point,
  -- and only when it actually changes something)
  if pitch_envelope_needs_setup(take) then
    reaper.Undo_BeginBlock()
    ensure_take_pitch_envelope(take, item, true)
    reaper.Undo_EndBlock("Show Pitch Envelope", -1)
    note_own_write()
  end
end

-------------------------------------------------------------------------------
-- 3. SIGNAL PROCESSING & PITCH EXTRACTION HELPERS
-------------------------------------------------------------------------------

local function gaussian_filter(arr, sigma_frames)
  local n = #arr
  if n == 0 then return {} end
  if n == 1 then return { arr[1] } end
  local res = {}
  local radius = math.max(1, math.ceil(sigma_frames * 2.5))
  for i = 1, n do
    local sum, w_sum = 0, 0
    for j = math.max(1, i - radius), math.min(n, i + radius) do
      local dist = (i - j) / sigma_frames
      local w = math.exp(-0.5 * dist * dist)
      sum = sum + arr[j] * w
      w_sum = w_sum + w
    end
    res[i] = sum / w_sum
  end
  return res
end

local function smoothstep(u)
  local c = math.max(0, math.min(1, u))
  return c * c * (3 - 2 * c)
end

local function rdp_simplify(points, epsilon)
  if #points <= 2 then return points end

  local function perpendicular_dist(pt, l1, l2)
    local dx = l2.time - l1.time
    if dx <= 0.00001 then
      return math.abs(pt.val - l1.val)
    end
    local u = (pt.time - l1.time) / dx
    local py = l1.val + u * (l2.val - l1.val)
    return math.abs(pt.val - py)
  end

  local function rdp_recursive(pts, first, last, eps, out)
    local dmax = 0
    local index = 0
    for i = first + 1, last - 1 do
      local d = perpendicular_dist(pts[i], pts[first], pts[last])
      if d > dmax then
        index = i
        dmax = d
      end
    end
    if dmax > eps then
      rdp_recursive(pts, first, index, eps, out)
      table.insert(out, pts[index])
      rdp_recursive(pts, index, last, eps, out)
    end
  end

  local out = { points[1] }
  rdp_recursive(points, 1, #points, epsilon, out)
  table.insert(out, points[#points])
  table.sort(out, function(a, b) return a.time < b.time end)

  local dedup = { out[1] }
  for i = 2, #out do
    if out[i].time > dedup[#dedup].time + 0.0001 then
      table.insert(dedup, out[i])
    end
  end
  return dedup
end

local function compute_vibrato_weights(mod, frame_dur, total_dur)
  local n = #mod
  local weights = {}
  for i = 1, n do weights[i] = 0.0 end
  if n < 8 then return weights end

  local half_win = math.max(2, math.floor(0.12 / frame_dur)) -- ~240ms window
  local raw_gate = {}
  local is_active = false

  for i = 1, n do
    local t = (i - 1) * frame_dur
    -- Onset & offset exclusion (pitch settling and release tail are not vibrato)
    if t < 0.10 or t > (total_dur - 0.06) then
      raw_gate[i] = false
      is_active = false
    else
      local w_start = math.max(1, i - half_win)
      local w_end = math.min(n, i + half_win)
      local count = w_end - w_start + 1
      local sum_sq = 0
      local zc = 0
      for j = w_start, w_end do
        sum_sq = sum_sq + mod[j] * mod[j]
        if j > w_start and (mod[j] >= 0) ~= (mod[j-1] >= 0) then
          zc = zc + 1
        end
      end
      local rms = math.sqrt(sum_sq / count)
      local win_time = count * frame_dur
      local freq = win_time > 0 and (zc / (2 * win_time)) or 0
      local is_periodic = (freq >= 3.5 and freq <= 8.5 and zc >= 2)

      -- Schmitt trigger (turn on at 0.045 st / 4.5 cents, hold down to 0.028 st / 2.8 cents)
      if not is_active then
        if is_periodic and rms >= 0.045 then
          is_active = true
        end
      else
        if not is_periodic or rms < 0.028 then
          is_active = false
        end
      end
      raw_gate[i] = is_active
    end
  end

  -- Asymmetric envelope follower (Attack: ~100ms, Release: ~60ms)
  local attack_coef = math.exp(-frame_dur / 0.10)
  local release_coef = math.exp(-frame_dur / 0.06)
  local current_env = 0.0

  for i = 1, n do
    local target = raw_gate[i] and 1.0 or 0.0
    if target > current_env then
      current_env = target + (current_env - target) * attack_coef
    else
      current_env = target + (current_env - target) * release_coef
    end
    weights[i] = current_env > 0.05 and current_env or 0.0
  end

  return weights
end

local function extract_note_features(note, preserve_controls)
  if note.count == 0 or not note.frames or #note.frames == 0 then return end

  -- 1. Extract raw pitch array
  local raw_pitch = {}
  for i, frame in ipairs(note.frames) do
    raw_pitch[i] = frame.note
  end

  -- Median filter (3-point) to remove YIN tracking outliers
  local function median3(a, b, c)
    if a > b then a, b = b, a end
    if b > c then b = c end
    if a > b then b = a end
    return b
  end

  local filtered = {}
  filtered[1] = raw_pitch[1]
  for i = 2, #raw_pitch - 1 do
    filtered[i] = median3(raw_pitch[i-1], raw_pitch[i], raw_pitch[i+1])
  end
  filtered[#raw_pitch] = raw_pitch[#raw_pitch]
  raw_pitch = filtered

  -- 2. Zero-phase Gaussian filtering for smooth pitch and low-frequency drift trend
  --    Smooth pitch (sigma ~1.5 frames) removes micro-jitters without phase distortion
  --    Trend (sigma ~7.0 frames, ~2 Hz cutoff) isolates slow drift without vibrato ripple
  local smooth_pitch = gaussian_filter(raw_pitch, 1.5)
  local trend = gaussian_filter(raw_pitch, 7.0)

  -- 3. Calculate Modulation: clean, zero-phase vibrato waveform
  local mod = {}
  for i = 1, #raw_pitch do
    mod[i] = smooth_pitch[i] - trend[i]
  end

  -- 4. Calculate robust pitch center (energy-weighted median/mean of sustained core)
  --    Excludes initial onset scoop (first 12%) and release tail (last 12%)
  local total_w = 0
  local weighted_sum = 0
  local start_f = math.max(1, math.floor(#note.frames * 0.12))
  local end_f = math.min(#note.frames, math.ceil(#note.frames * 0.88))
  for i = start_f, end_f do
    local f = note.frames[i]
    local w = math.max(0.0001, (f.rms or 0.05))
    weighted_sum = weighted_sum + f.note * w
    total_w = total_w + w
  end
  if total_w > 0 then
    note.avg_note = weighted_sum / total_w
    note.display_note = math.floor(note.avg_note + 0.5)
  end

  -- 5. Find Smart Spots via Zero-Crossing (for visual rendering / anchor points)
  local smart_spots = {}
  table.insert(smart_spots, { index = 1, time = note.frames[1].time, type = "anchor_start" })

  local current_sign = nil
  local extrema_idx = nil
  local extrema_val = 0

  for i = 1, #mod do
    local val = mod[i]
    local sign = val >= 0 and 1 or -1

    if current_sign == nil then
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    elseif sign == current_sign then
      if sign == 1 and val > extrema_val then
        extrema_idx = i
        extrema_val = val
      elseif sign == -1 and val < extrema_val then
        extrema_idx = i
        extrema_val = val
      end
    else
      -- Zero crossing! Save the previous extrema if it's prominent enough
      if math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
        local s_type = current_sign == 1 and "peak" or "valley"
        table.insert(smart_spots, { index = extrema_idx, time = note.frames[extrema_idx].time, type = s_type, mod_val = extrema_val })
      end
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    end
  end

  if extrema_idx and math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
    local s_type = current_sign == 1 and "peak" or "valley"
    table.insert(smart_spots, { index = extrema_idx, time = note.frames[extrema_idx].time, type = s_type, mod_val = extrema_val })
  end

  table.insert(smart_spots, { index = #raw_pitch, time = note.frames[#raw_pitch].time, type = "anchor_end" })

  note.trend = trend
  note.modulation = mod
  note.smart_spots = smart_spots

  -- 6. Vibrato detection with Schmitt trigger hysteresis & asymmetric envelope follower
  local total_dur = note.end_time - note.start_time
  local frame_dur = #note.frames > 1
    and (note.frames[#note.frames].time - note.frames[1].time) / (#note.frames - 1)
    or 0.012

  note.vibrato_weight = compute_vibrato_weights(mod, frame_dur, total_dur)

  -- Default controls: NO correction (green preview = raw pitch)
  -- Cascade fields default to nil (inherit from item → global)
  note.controls = {
    center_pitch = note.avg_note,
    drift_scale = 1.0,
    vibrato_scale = 1.0,
    transition_ms = nil,       -- per-note override (nil = inherit)
    onset_ramp_ms = nil,       -- per-note override (nil = inherit)
    retune_speed = nil,        -- per-note override (nil = inherit)
    scoop_shape = nil,         -- 0.0 (natural) to 1.0 (corrected), nil = 0
    bypassed = false,          -- per-note bypass toggle
  }

  -- Restore user tuning offsets when splitting/merging notes
  if preserve_controls then
    for k, v in pairs(preserve_controls) do
      note.controls[k] = v
    end
  end

  -- 7. ONSET ANALYSIS — scoop magnitude and voiced start detection
  local scoop_frames = math.min(10, math.floor(#raw_pitch * 0.3))
  local scoop_sum = 0
  for i = 1, scoop_frames do
    scoop_sum = scoop_sum + math.abs(raw_pitch[i] - note.avg_note)
  end
  note.scoop_magnitude = scoop_frames > 0 and (scoop_sum / scoop_frames) or 0

  -- Find first frame with stable voicing (3+ consecutive voiced frames)
  note.voiced_start_idx = 1
  for i = 1, math.min(#note.frames, 15) do
    if i + 2 <= #note.frames
      and note.frames[i].note and note.frames[i+1].note and note.frames[i+2].note then
      note.voiced_start_idx = i
      break
    end
  end
  note.voiced_start_time = note.frames[note.voiced_start_idx].time
end

local function is_note_modified(note)
  if not note or not note.controls then return false end
  local ctrl = note.controls
  if ctrl.bypassed then return true end
  local pitch_changed = math.abs(ctrl.center_pitch - note.avg_note) > 0.001
  local fine_changed = (ctrl.drift_scale ~= 1.0) or (ctrl.vibrato_scale ~= 1.0)
  local has_overrides = (ctrl.retune_speed ~= nil) or (ctrl.onset_ramp_ms ~= nil)
    or (ctrl.scoop_shape ~= nil and ctrl.scoop_shape > 0)
    or (ctrl.transition_ms ~= nil)
  return pitch_changed or fine_changed or has_overrides
end

--- True when the envelope of a take (its model `data`) depends on the global default of `key`: the take has no item
--- value for it and an edited note inherits it (an untouched take has no envelope to go stale).
K.inherits_global = function(data, key)
  if not data or (data.overrides and data.overrides[key] ~= nil) then return false end
  for _, note in ipairs(data.notes or {}) do
    local own = key ~= "legato_threshold_ms" and note.controls and note.controls[key] ~= nil
    if is_note_modified(note) and not own then return true end
  end
  return false
end

--- After a take's model was reloaded (undo / redo): its envelope is stale when it was written with a global default
--- that differs from the current one, for a key the take inherits. data.globals is the snapshot persist_take_model
--- stores with every envelope write; a model saved before that snapshot existed leaves the flag as it is.
K.refresh_stale_flag = function(guid, data)
  if not guid or not data or type(data.globals) ~= "table" then return end
  local stale = false
  for key, value in pairs(global_defaults) do
    local was = tonumber(data.globals[key])
    if was and math.abs(was - value) > 1e-6 and K.inherits_global(data, key) then
      stale = true
      break
    end
  end
  state.stale_takes[guid] = stale or nil
end

-- Forward declaration; will be set after apply_envelope_to_take is defined
local reset_selected_note
local snap_selected_note
local quantize_selected_notes_to_scale
local split_note_at
local merge_selected_notes
local trim_note_edge
local flush_nudge_burst -- commits a pending arrow-key nudge as one undo point (defined after apply_envelope_to_take)

-------------------------------------------------------------------------------
-- MULTI-ITEM SESSION & PROJECT PERSISTENCE
-------------------------------------------------------------------------------

local function save_take_data(take, data)
  if not take or not data then return end
  local save_data = {
    guid = data.guid,
    name = data.name,
    start_time = data.start_time,
    end_time = data.end_time,
    item_len = data.item_len,
    sample_rate = data.sample_rate,
    results = data.results,
    notes = {},
    key_idx = data.key_idx or state.key_idx,
    scale_idx = data.scale_idx or state.scale_idx,
    overrides = data.overrides or nil,
    globals = data.globals or nil,   -- the global defaults the stored envelope was written with (see persist_take_model)
  }
  if data.notes then
    for _, note in ipairs(data.notes) do
      table.insert(save_data.notes, {
        start_time = note.start_time,
        end_time = note.end_time,
        avg_note = note.avg_note,
        display_note = note.display_note,
        controls = note.controls,
        scoop_magnitude = note.scoop_magnitude,
        voiced_start_idx = note.voiced_start_idx,
        voiced_start_time = note.voiced_start_time,
        frames = note.frames
      })
    end
  end
  local json_str = JSON.encode(save_data)
  reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, json_str, true)

  -- Remember what is now stored (read back) so the resync never treats our own write as external; what was stored
  -- before (readable or not) is replaced
  local guid = get_take_guid(take)
  if guid then
    state.raw_cache[guid] = read_take_raw(take)
    state.unreadable_takes[guid] = nil
  end
end

--- Save the active Key/Scale. The global ExtState write stays outside undo; the per-take model
--- write is one named undo point so Cmd+Z reverts it together with the Key/Scale selection.
local function save_current_scale_settings()
  reaper.SetExtState("FancyScripts", "pitch_key_idx", tostring(state.key_idx), true)
  reaper.SetExtState("FancyScripts", "pitch_scale_idx", tostring(state.scale_idx), true)
  if state.target_take_guid and state.session_takes[state.target_take_guid] then
    local data = state.session_takes[state.target_take_guid]
    data.key_idx = state.key_idx
    data.scale_idx = state.scale_idx
    local take = resolve_take_by_guid(state.target_take_guid)
    if take then
      reaper.Undo_BeginBlock()
      save_take_data(take, data)
      reaper.Undo_EndBlock("Change Key/Scale", -1)
      note_own_write()
    end
  end
end

--- Parse the pitch model stored on a take. raw is the P_EXT string when the caller already read it.
--- Records the raw string in state.raw_cache so the resync can tell own loads from external changes.
--- Stored data that cannot be used (it does not decode, or holds no analysis) is not dropped silently: the take is
--- recorded in state.unreadable_takes (the Pitched Items banner reports it); nothing stored, or data that loads,
--- clears the record. Returns the model, or nil.
local function load_take_data(take, raw)
  if not take then return nil end
  local guid = get_take_guid(take)
  local json_str = raw
  if json_str == nil then json_str = read_take_raw(take) end
  if guid then
    state.raw_cache[guid] = (json_str ~= "") and json_str or nil
  end
  if json_str == "" then
    if guid then state.unreadable_takes[guid] = nil end
    return nil
  end
  local success, data = pcall(JSON.decode, json_str)
  local readable = success and type(data) == "table" and data.results and data.notes
  if readable then
    -- A note that does not hold what the model needs makes the whole take unreadable, not the window fail
    readable = pcall(function()
      for _, note in ipairs(data.notes) do
        note.count = #note.frames
        -- Preserve all saved controls (including cascade override fields) across re-extraction
        local saved_controls = note.controls
        extract_note_features(note)
        if saved_controls then
          for k, v in pairs(saved_controls) do
            note.controls[k] = v
          end
        end
      end
    end)
  end
  if guid then state.unreadable_takes[guid] = (not readable) or nil end
  if readable then return data end
  return nil
end

--- True when the take's pitch envelope is bypassed. The envelope chunk is read once per take and project state
--- (state.cache.bypass), not on every frame and sidebar row.
local function is_take_pitch_bypassed(take)
  if not take then return false end
  local bypass = state.cache.bypass
  local known = bypass[take]
  if known ~= nil then return known end
  local bypassed = false
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if env then
    local retval, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if retval and chunk then
      bypassed = chunk:match("ACT%s+0") ~= nil
    end
  end
  bypass[take] = bypassed
  return bypassed
end

--- One undo point (UC1): a missing envelope is created inside the same block as the toggle, and nothing opens a block
--- when there is neither an envelope nor an item to make one on.
local function toggle_take_pitch_bypass(take)
  if not take then return end
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  local item = reaper.GetMediaItemTake_Item(take)
  if not env and not item then return end
  reaper.Undo_BeginBlock()
  if not env then
    env = ensure_take_pitch_envelope(take, item, true)
  end
  if env then
    local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    if ok and chunk then
      if chunk:match("ACT%s+0") then
        chunk = chunk:gsub("ACT%s+0", "ACT 1")
        if chunk:match("VIS%s+0") then
          chunk = chunk:gsub("VIS%s+0", "VIS 1")
        end
      else
        chunk = chunk:gsub("ACT%s+1", "ACT 0")
      end
      reaper.SetEnvelopeStateChunk(env, chunk, false)
      if item then reaper.UpdateItemInProject(item) end
      reaper.UpdateArrange()
    end
  end
  reaper.Undo_EndBlock("Toggle Pitch Envelope Bypass", -1)
  note_own_write()
end

--- Drop every in-flight gesture and selection, and show the whole item again (used when the model under
--- them is replaced).
local function clear_interaction_state()
  state.view_t0, state.view_t1 = nil, nil
  state.selected_note = nil
  state.selected_notes = {}
  state.hovered_note = nil
  state.hovered_zone = nil
  state.hovered_edge = nil
  state.context_menu_note = nil
  state.drag = nil
  state.edge_drag = nil
  state.marquee = nil
  state.shift_mode = false
  state.nudge_burst = nil
end

--- Make a session take's data the editing model (canvas, notes, key/scale). Does not touch
--- REAPER's item selection.
local function adopt_take_data(guid, data)
  local same_target = (state.target_take_guid == guid)
  local view_t0, view_t1 = state.view_t0, state.view_t1
  state.target_take_guid = guid
  state.target_take_name = data.name
  state.results = data.results
  state.notes = data.notes
  state.start_time = data.start_time
  state.end_time = data.end_time
  state.item_len = data.item_len
  state.sample_rate = data.sample_rate
  -- An analysed item that has no notes is "analysed, nothing found" (not "ready to analyze")
  state.analysis_empty = (data.notes ~= nil and #data.notes == 0 and data.results ~= nil and #data.results > 0)
  clear_interaction_state()   -- also shows the whole item again (state.view_t0 / view_t1) ...
  if same_target then state.view_t0, state.view_t1 = view_t0, view_t1 end   -- ... unless the same take was reloaded (undo / redo): the zoom stays

  if data.key_idx then state.key_idx = data.key_idx end
  if data.scale_idx then state.scale_idx = data.scale_idx end
  update_scale_pitch_classes()
end

--- Cancel the running analysis (header Cancel, closing the window, an error): stop reading audio, put the
--- previous model back and say so in the status line. Nothing was written for the new analysis (the model is saved
--- when it completes) and no undo block is open between frames, so there is nothing to close or undo.
--- Returns true when an analysis was running.
K.cancel_analysis = function()
  if not state.is_analyzing and not state.accessor then return false end
  K.release_analysis()
  state.progress = 0
  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if data then
    adopt_take_data(guid, data)   -- the item was analysed before: its saved model comes back
  else
    reset_analysis_model()        -- a first analysis: back to "not analysed"
  end
  -- The resync paused while analysing: a project change made meanwhile (undo etc.) is picked up next frame
  if state.last_change_count ~= reaper.GetProjectStateChangeCount(0) then state.last_change_count = nil end
  set_status(K.CANCELLED_TEXT)
  return true
end

local function switch_active_target(guid, take_obj)
  -- A pending arrow-key nudge belongs to the take being left: commit it first
  flush_nudge_burst()

  local data = state.session_takes[guid]
  if not data and take_obj then
    data = load_take_data(take_obj)
    if data then
      state.session_takes[guid] = data
      local found = false
      for _, g in ipairs(state.session_order) do if g == guid then found = true; break end end
      if not found then table.insert(state.session_order, guid) end
    end
  end

  if data then
    adopt_take_data(guid, data)
    return true
  end
  return false
end

local function scan_project_for_saved_takes()
  local num_items = reaper.CountMediaItems(0)
  for i = 0, num_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
      local num_takes = reaper.CountTakes(item)
      for t = 0, num_takes - 1 do
        local take = reaper.GetTake(item, t)
        if take and not reaper.TakeIsMIDI(take) then
          local _, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
          if guid and not state.session_takes[guid] then
            local data = load_take_data(take)
            if data then
              state.session_takes[guid] = data
              local found = false
              for _, g in ipairs(state.session_order) do if g == guid then found = true; break end end
              if not found then table.insert(state.session_order, guid) end
            end
          end
        end
      end
    end
  end
end

--- Re-read the pitch model of every session take when REAPER's project state changed
--- (undo, redo, project-tab switch, item delete...). One GetProjectStateChangeCount call per
--- frame; the per-take work only runs when the count moved, and a take is only reloaded when its
--- stored P_EXT differs from what this script last wrote or loaded (state.raw_cache), so the
--- script's own edits never trigger a reload.
local function sync_with_project()
  if state.is_analyzing then return end
  local count = reaper.GetProjectStateChangeCount(0)
  if state.last_change_count == count then return end
  state.last_change_count = count

  local i = 1
  while i <= #state.session_order do
    local guid = state.session_order[i]
    local take = resolve_take_by_guid(guid, true)
    if not take then
      -- Item deleted (or project switched): keep the row, flag it
      state.missing_takes[guid] = true
      i = i + 1
    else
      state.missing_takes[guid] = nil
      local raw = read_take_raw(take)
      if raw == (state.raw_cache[guid] or "") then
        i = i + 1
      else
        local data = load_take_data(take, raw)
        local is_active = (guid == state.target_take_guid)
        if data then
          state.session_takes[guid] = data
          if is_active then adopt_take_data(guid, data) end
          -- Undo of a global-default edit brings back an envelope written with the old default: flag it
          K.refresh_stale_flag(guid, data)
          i = i + 1
        elseif raw == "" then
          -- The analysis was undone away: the take has no pitch data any more
          state.session_takes[guid] = nil
          state.stale_takes[guid] = nil
          table.remove(state.session_order, i)
          if is_active then
            clear_interaction_state()
            state.results = {}
            state.notes = nil
            state.split_points = nil
            state.progress = 0
            state.analysis_empty = false
          end
        else
          -- Stored data is unreadable: keep the in-memory model (raw_cache now holds the bad string)
          i = i + 1
        end
      end
    end
  end

  -- Items whose saved analysis could not be read, and that are not listed: the data may have been fixed, cleared or
  -- restored (undo / redo) since. Such an item is re-read only when what is stored differs from what was last seen.
  for guid in pairs(state.unreadable_takes) do
    local take = (not state.session_takes[guid]) and resolve_take_by_guid(guid, true) or nil
    if take then
      local raw = read_take_raw(take)
      if raw ~= (state.raw_cache[guid] or "") then
        local data = load_take_data(take, raw)
        if data then
          state.session_takes[guid] = data
          table.insert(state.session_order, guid)
          if guid == state.target_take_guid then adopt_take_data(guid, data) end
        end
      end
    end
  end

  -- The active target has no session entry: an undone analysis may have been redone
  local target_guid = state.target_take_guid
  if target_guid and not state.session_takes[target_guid] then
    local take = resolve_take_by_guid(target_guid, true)
    if take then
      local raw = read_take_raw(take)
      if raw ~= "" and raw ~= (state.raw_cache[target_guid] or "") then
        local data = load_take_data(take, raw)
        if data then
          state.session_takes[target_guid] = data
          table.insert(state.session_order, target_guid)
          adopt_take_data(target_guid, data)
        end
      end
    end
  end
end

--- Persist the target's note model to its take (P_EXT) so it lands inside the caller's open undo block.
local function persist_take_model(take)
  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if not data or not take then return end
  if state.notes then data.notes = state.notes end
  -- The envelope written in this block uses the current global defaults: remember them, so an undo / redo that brings
  -- back an older model can tell whether its envelope is stale (K.refresh_stale_flag)
  local globals = {}
  for key, value in pairs(global_defaults) do globals[key] = value end
  data.globals = globals
  save_take_data(take, data)
end

--- Close the undo block opened by apply_envelope_to_take: model (P_EXT) first, so Cmd+Z reverts
--- the envelope points and the note model together; then record the change count.
local function end_apply(take, undo_desc)
  persist_take_model(take)
  reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)
  state.undo_open = false
  note_own_write()
end

--- Rewrite the take pitch envelope from state.notes and persist the model, as one undo point.
--- keep_pitch_mode leaves the item's I_PITCHMODE untouched (used by re-analysis, which applies no correction); so does
--- the Settings option "Keep each item's own pitch algorithm" (state.keep_pitch_mode).
--- Returns true when the envelope and the model were written (one undo point); false when they were not, after
--- saying why in the status line (so a caller must not then claim an undo point).
local function apply_envelope_to_take(undo_desc, keep_pitch_mode)
  -- A pending arrow-key nudge is committed as its own undo point first
  if state.nudge_burst then flush_nudge_burst() end

  local take, item = get_target_take()
  if not take or not item then
    set_status("This item is no longer in the project")
    return false
  end

  -- The envelope is rewritten from the model with today's defaults and overrides: the take is current again
  if state.target_take_guid then state.stale_takes[state.target_take_guid] = nil end

  reaper.Undo_BeginBlock()
  state.undo_open = true

  -- Set pitch shift mode (Elastique Soloist Monophonic by default), unless the user keeps each item's own
  if not keep_pitch_mode and not state.keep_pitch_mode and state.pitchmode_value ~= -1 then
    reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", state.pitchmode_value)
  end

  -- Ensure pitch envelope exists
  local env = ensure_take_pitch_envelope(take, item)
  if not env then
    set_status("Couldn't show the pitch envelope on this item. Check that the item is an audio item on an unlocked track, then try again.")
    end_apply(take, "Apply Pitch Correction")
    return false
  end

  local item_len = math.max(0.1, reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))

  -- Clear existing points across the entire item
  reaper.DeleteEnvelopePointRange(env, 0, item_len + 1.0)

  local SHAPE = 5   -- Bezier
  local TENSION = 0 -- Neutral tension

  if not state.notes or #state.notes == 0 then
    reaper.Envelope_SortPointsEx(env, -1)
    reaper.UpdateArrange()
    end_apply(take, undo_desc)
    return true
  end

  -- Check if any note in the phrase is modified
  local any_modified = false
  for _, n in ipairs(state.notes) do
    if is_note_modified(n) then
      any_modified = true
      break
    end
  end

  if not any_modified then
    -- Clean envelope: untouched takes have no points
    reaper.Envelope_SortPointsEx(env, -1)
    reaper.UpdateArrange()
    end_apply(take, undo_desc)
    return true
  end

  -- 1. Precalculate continuous frame shifts for every note
  for _, n in ipairs(state.notes) do
    n.frame_shifts = {}
    -- Per-note bypass: zero out all shifts
    if n.controls and n.controls.bypassed then
      if n.frames then
        for i = 1, #n.frames do
          n.frame_shifts[i] = 0.0
        end
      end
    else
      local is_mod = is_note_modified(n)
      local retune = get_effective(n, "retune_speed")
      local coarse = is_mod and (n.controls.center_pitch - n.avg_note) * retune or 0.0
      local d_scale = (n.controls and n.controls.drift_scale) or 1.0
      local v_scale = (n.controls and n.controls.vibrato_scale) or 1.0
      if n.frames then
        for i = 1, #n.frames do
          if not is_mod then
            n.frame_shifts[i] = 0.0
          else
            local vw = (n.vibrato_weight and n.vibrato_weight[i]) or 0.0
            local drift_corr = (n.trend and n.trend[i]) and ((n.trend[i] - n.avg_note) * (d_scale - 1.0)) or 0.0
            local vib_corr = (n.modulation and n.modulation[i]) and (n.modulation[i] * (v_scale - 1.0) * vw) or 0.0
            n.frame_shifts[i] = coarse + drift_corr + vib_corr
          end
        end

        -- Scoop/glide shaping: blend onset frames toward body target
        local scoop = (n.controls and n.controls.scoop_shape) or 0
        if scoop > 0 and is_mod and n.voiced_start_idx then
          local onset_end = math.min(n.voiced_start_idx + 8, #n.frames)
          if onset_end > 1 and onset_end < #n.frames then
            local body_shift = n.frame_shifts[math.min(onset_end + 1, #n.frames)]
            for i = 1, onset_end do
              local onset_u = i / onset_end  -- 0→1 across onset
              local natural = n.frame_shifts[i]
              n.frame_shifts[i] = natural + (body_shift - natural) * scoop * (1 - onset_u)
            end
          end
        end
      end
    end
  end

  -- 2. Build continuous trajectory across notes and boundaries
  local all_points = {}
  local num_notes = #state.notes
  local legato_thresh = get_effective(nil, "legato_threshold_ms") * 0.001

  for idx = 1, num_notes do
    local n = state.notes[idx]
    local prev_n = state.notes[idx - 1]
    local next_n = state.notes[idx + 1]

    -- Bypassed notes produce zero shifts — skip trajectory generation
    if n.controls and n.controls.bypassed then
      goto continue_note
    end

    local is_mod = is_note_modified(n)
    local prev_mod = is_note_modified(prev_n)
    local next_mod = is_note_modified(next_n)

    -- If this note and both its neighbors are untouched, skip entirely
    if not is_mod and not prev_mod and not next_mod then
      goto continue_note
    end

    local start_shift = (n.frame_shifts and n.frame_shifts[1]) or 0.0
    local end_shift = (n.frame_shifts and n.frame_shifts[#n.frame_shifts]) or 0.0

    local trans_dur = math.min(get_effective(n, "transition_ms") * 0.001, 0.060)
    trans_dur = math.min(trans_dur, (n.end_time - n.start_time) * 0.4)

    -- A. START TRANSITION
    local prev_gap = prev_n and (n.start_time - prev_n.end_time) or 999
    if prev_gap < legato_thresh and prev_n then
      -- Legato transition with previous note: smoothstep blend centered at boundary
      local prev_end_shift = (prev_n.frame_shifts and prev_n.frame_shifts[#prev_n.frame_shifts]) or 0.0
      local t_bnd = (prev_n.end_time + n.start_time) * 0.5
      local t_start = math.max(0.0, t_bnd - trans_dur * 0.5)
      local t_end = math.min(item_len, t_bnd + trans_dur * 0.5)

      local steps = 5
      for s = 0, steps do
        local u = s / steps
        local t = t_start + u * (t_end - t_start)
        local val = prev_end_shift + (start_shift - prev_end_shift) * smoothstep(u)
        table.insert(all_points, { time = t, val = val })
      end
    else
      -- Onset from silence / start of take: smooth ramp into pitch shift
      if is_mod and math.abs(start_shift) > 0.001 then
        local onset_ramp = get_effective(n, "onset_ramp_ms") * 0.001
        local ramp_t = math.min(onset_ramp, (n.end_time - n.start_time) * 0.25)
        local t_pre = math.max(0.0, n.start_time - ramp_t)
        table.insert(all_points, { time = t_pre, val = 0.0 })
        local steps = 4
        for s = 1, steps do
          local u = s / steps
          local t = t_pre + u * (n.start_time - t_pre)
          local val = start_shift * smoothstep(u)
          table.insert(all_points, { time = t, val = val })
        end
      end
    end

    -- B. NOTE BODY
    local fine_changed = is_mod and (((n.controls.drift_scale or 1.0) ~= 1.0) or ((n.controls.vibrato_scale or 1.0) ~= 1.0))
    local body_t_start = n.start_time + trans_dur * 0.5
    local body_t_end = n.end_time - trans_dur * 0.5

    if not fine_changed then
      -- Coarse shift or untouched: hold shift across body
      if is_mod then
        table.insert(all_points, { time = math.min(item_len, body_t_start), val = start_shift })
        table.insert(all_points, { time = math.min(item_len, body_t_end), val = end_shift })
      end
    else
      -- Fine contour: sample frames across body to counteract drift / scale vibrato
      if n.frames then
        for i = 1, #n.frames do
          local t = n.frames[i].time
          if t >= body_t_start and t <= body_t_end then
            table.insert(all_points, { time = math.min(item_len, t), val = n.frame_shifts[i] })
          end
        end
      end
    end

    -- C. END TRANSITION TO SILENCE (if next note is far or this is last note)
    local next_gap = next_n and (next_n.start_time - n.end_time) or 999
    if next_gap >= legato_thresh then
      if is_mod and math.abs(end_shift) > 0.001 then
        local onset_ramp = get_effective(n, "onset_ramp_ms") * 0.001
        local ramp_t = math.min(onset_ramp, (n.end_time - n.start_time) * 0.25)
        local steps = 4
        for s = 1, steps do
          local u = s / steps
          local t = math.min(item_len, n.end_time + u * ramp_t)
          local val = end_shift * (1.0 - smoothstep(u))
          table.insert(all_points, { time = t, val = val })
        end
        local t_post = math.min(item_len, n.end_time + ramp_t + 0.001)
        table.insert(all_points, { time = t_post, val = 0.0 })
      end
    end

    ::continue_note::
  end

  -- 3. Adaptive decimation with sub-cent tolerance (0.01 st / 1 cent)
  local simplified = rdp_simplify(all_points, 0.01)
  for _, pt in ipairs(simplified) do
    local t = math.max(0.0, math.min(item_len, pt.time))
    reaper.InsertEnvelopePointEx(env, -1, t, pt.val, SHAPE, TENSION, 0, true)
  end

  reaper.Envelope_SortPointsEx(env, -1)
  reaper.UpdateArrange()
  end_apply(take, undo_desc)
  return true
end

--- Commit the pending arrow-key nudge (if any) as ONE named undo point.
flush_nudge_burst = function()
  local burst = state.nudge_burst
  if not burst then return end
  state.nudge_burst = nil
  -- Drop bursts whose model is gone (target switched, analysis cleared, project reloaded)
  if not state.notes or burst.guid ~= state.target_take_guid then return end
  if math.abs(burst.total_st) < 0.001 then return end
  apply_envelope_to_take(string.format("Nudge Pitch %+.1f st", burst.total_st))
end

--- Nudge the selected notes by delta semitones. Only the preview (center_pitch) changes here;
--- the envelope and the undo point are committed once per burst by service_nudge_burst().
local function nudge_selected_notes(delta, key_name)
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then table.insert(indices, idx) end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then return end

  -- EP3: a nudge never leaves the MIDI range (0..127), like a pitch drag
  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    if n and n.controls then
      n.controls.center_pitch = math.max(0, math.min(127, n.controls.center_pitch + delta))
    end
  end

  local burst = state.nudge_burst
  if burst and burst.guid ~= state.target_take_guid then
    flush_nudge_burst()
    burst = nil
  end
  if not burst then
    burst = { total_st = 0, last_time = 0, keys = {}, guid = state.target_take_guid }
    state.nudge_burst = burst
  end
  burst.total_st = burst.total_st + delta
  burst.last_time = reaper.time_precise()
  burst.keys[key_name] = true
end

--- Once per frame: commit the pending nudge burst when no nudge arrow is down any more, or 0.25 s
--- after the last event, or immediately when force is set (window closing / popup open).
--- A frame with a nudge arrow held counts as an event, so holding a key (whose first repeat arrives
--- after ~0.275 s) stays ONE burst instead of splitting into two undo points.
local function service_nudge_burst(force)
  local burst = state.nudge_burst
  if not burst then return end
  if force then
    flush_nudge_burst()
    return
  end
  local now = reaper.time_precise()
  local held = (burst.keys.up and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_UpArrow()))
    or (burst.keys.down and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_DownArrow()))
  if held then burst.last_time = now end
  if not held or now - burst.last_time > K.NUDGE_IDLE_S then
    flush_nudge_burst()
  end
end

local function find_nearest_in_scale_pitch(pitch)
  local clamped_pitch = math.max(0, math.min(127, pitch))
  local nearest_st = math.floor(clamped_pitch + 0.5)
  local best_cand = nearest_st
  local min_diff = 999999

  for dist = 0, 12 do
    local cands = (dist == 0) and { nearest_st } or { nearest_st + dist, nearest_st - dist }
    for _, cand in ipairs(cands) do
      if cand >= 0 and cand <= 127 then
        local pc = (cand % 12 + 12) % 12
        if is_pitch_in_scale(pc) then
          local diff = math.abs(cand - clamped_pitch)
          if diff < min_diff then
            min_diff = diff
            best_cand = cand
          end
        end
      end
    end
    if min_diff <= dist + 0.5 then
      break
    end
  end

  return best_cand
end

-- Snaps selected note(s) to the nearest valid in-scale pitch (Milestone 3: Quantize Key).
-- Returns how many notes moved (0 = nothing to change) and whether the change was written to the take (an undo point).
quantize_selected_notes_to_scale = function()
  if not state.notes then return 0 end
  local changed_count = 0
  local any_changed = false
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then return 0 end

  for _, idx in ipairs(indices) do
    local note = state.notes[idx]
    if note and note.controls then
      local target_pitch = find_nearest_in_scale_pitch(note.controls.center_pitch)
      if math.abs(note.controls.center_pitch - target_pitch) > 0.001 then
        note.controls.center_pitch = target_pitch
        any_changed = true
        changed_count = changed_count + 1
      end
    end
  end

  local written = false
  if any_changed then
    written = apply_envelope_to_take("Quantize Pitch to Scale")
  end
  return changed_count, written
end

-- Resets the selected note(s) back to [Untouched], clearing envelope contribution.
-- Returns true when at least one note actually changed (and the envelope was rewritten).
reset_selected_note = function()
  if not state.notes then return false end
  local any_changed = false
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then
    for i = 1, #state.notes do
      table.insert(indices, i)
    end
  end
  if #indices == 0 then return false end

  for _, idx in ipairs(indices) do
    local sel = state.notes[idx]
    if sel and sel.controls then
      local ctrl = sel.controls
      -- Only a control that actually differs from its reset value counts as a change
      if math.abs(ctrl.center_pitch - sel.avg_note) > 0.001
          or ctrl.drift_scale ~= 1.0
          or ctrl.vibrato_scale ~= 1.0
          or ctrl.transition_ms ~= nil
          or ctrl.onset_ramp_ms ~= nil
          or ctrl.retune_speed ~= nil
          or ctrl.scoop_shape ~= nil
          or ctrl.bypassed then
        any_changed = true
      end
      ctrl.center_pitch = sel.avg_note
      ctrl.drift_scale = 1.0
      ctrl.vibrato_scale = 1.0
      ctrl.transition_ms = nil
      ctrl.onset_ramp_ms = nil
      ctrl.retune_speed = nil
      ctrl.scoop_shape = nil
      ctrl.bypassed = false
    end
  end

  -- Nothing differed: no envelope rewrite and no undo point
  if any_changed then
    apply_envelope_to_take("Reset Pitch Correction")
  end
  return any_changed
end

-- Snaps selected note(s) to the nearest exact semitone (0¢ deviation).
-- Returns how many notes moved (0 = nothing to change) and whether the change was written to the take (an undo point).
snap_selected_note = function()
  if not state.notes then return 0 end
  local changed_count = 0
  local any_changed = false
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  if #indices == 0 and state.selected_note and state.notes[state.selected_note] then
    table.insert(indices, state.selected_note)
  end
  if #indices == 0 then return 0 end

  for _, idx in ipairs(indices) do
    local sel = state.notes[idx]
    if sel and sel.controls then
      local target_pitch = math.floor(sel.controls.center_pitch + 0.5)
      if math.abs(sel.controls.center_pitch - target_pitch) > 0.001 then
        sel.controls.center_pitch = target_pitch
        any_changed = true
        changed_count = changed_count + 1
      end
    end
  end

  local written = false
  if any_changed then
    written = apply_envelope_to_take("Snap Note to Semitone")
  end
  return changed_count, written
end

-------------------------------------------------------------------------------
-- NOTE TOPOLOGY: SPLIT, MERGE & EDGE TRIMMING
-------------------------------------------------------------------------------

-- Splits the note at note_idx into two independent notes at split_time.
-- Preserves user tuning offsets on both halves and re-extracts features.
-- Returns true and whether the change was written to the take (an undo point) when the note was split, else false and
-- the reason in the user's words (the caller puts it in the status line).
split_note_at = function(note_idx, split_time)
  local too_short = "Can't split: the note needs at least 3 analysis frames on each side"
  if not state.notes or not state.notes[note_idx] then return false, "Select a note to split" end
  local note = state.notes[note_idx]
  if not note.frames or #note.frames < 6 then return false, too_short end -- need at least 3 per half
  if split_time <= note.start_time or split_time >= note.end_time then
    return false, "Move the edit cursor into the note to split it"
  end

  -- Partition frames
  local frames_a = {}
  local frames_b = {}
  for _, frame in ipairs(note.frames) do
    if frame.time < split_time then
      table.insert(frames_a, frame)
    else
      table.insert(frames_b, frame)
    end
  end

  -- Validate minimum size (3 frames, ~35ms)
  if #frames_a < 3 or #frames_b < 3 then return false, too_short end

  -- Preserve the user's pitch offset (semitones from original avg)
  local old_ctrl = note.controls
  local pitch_offset = old_ctrl and (old_ctrl.center_pitch - note.avg_note) or 0

  -- Build note A (left half)
  local sum_a = 0
  for _, f in ipairs(frames_a) do sum_a = sum_a + f.note end
  local avg_a = sum_a / #frames_a
  local note_a = {
    start_time = frames_a[1].time,
    end_time = frames_a[#frames_a].time,
    sum_note = sum_a,
    count = #frames_a,
    avg_note = avg_a,
    display_note = math.floor(avg_a + 0.5),
    frames = frames_a,
  }
  extract_note_features(note_a, {
    center_pitch = avg_a + pitch_offset,
    drift_scale = old_ctrl and old_ctrl.drift_scale or 1.0,
    vibrato_scale = old_ctrl and old_ctrl.vibrato_scale or 1.0,
    transition_ms = old_ctrl and old_ctrl.transition_ms or nil,
    onset_ramp_ms = old_ctrl and old_ctrl.onset_ramp_ms or nil,
    retune_speed = old_ctrl and old_ctrl.retune_speed or nil,
    scoop_shape = old_ctrl and old_ctrl.scoop_shape or nil,
    bypassed = old_ctrl and old_ctrl.bypassed or false,
  })

  -- Build note B (right half)
  local sum_b = 0
  for _, f in ipairs(frames_b) do sum_b = sum_b + f.note end
  local avg_b = sum_b / #frames_b
  local note_b = {
    start_time = frames_b[1].time,
    end_time = frames_b[#frames_b].time,
    sum_note = sum_b,
    count = #frames_b,
    avg_note = avg_b,
    display_note = math.floor(avg_b + 0.5),
    frames = frames_b,
  }
  extract_note_features(note_b, {
    center_pitch = avg_b + pitch_offset,
    drift_scale = old_ctrl and old_ctrl.drift_scale or 1.0,
    vibrato_scale = old_ctrl and old_ctrl.vibrato_scale or 1.0,
    transition_ms = old_ctrl and old_ctrl.transition_ms or nil,
    onset_ramp_ms = old_ctrl and old_ctrl.onset_ramp_ms or nil,
    retune_speed = old_ctrl and old_ctrl.retune_speed or nil,
    scoop_shape = old_ctrl and old_ctrl.scoop_shape or nil,
    bypassed = old_ctrl and old_ctrl.bypassed or false,
  })

  -- Splice into notes array
  state.notes[note_idx] = note_a
  table.insert(state.notes, note_idx + 1, note_b)

  -- Update selection: select left half, adjust any indices above split
  state.selected_note = note_idx
  state.selected_notes = { [note_idx] = true }

  return true, apply_envelope_to_take("Split Note")
end

-- Merges all contiguous selected notes into a single note.
-- Uses duration-weighted pitch averaging to preserve user tuning intent.
-- Returns true and whether the change was written to the take (an undo point) when the notes were merged, else false
-- and the reason in the user's words (the caller puts it in the status line).
merge_selected_notes = function()
  if not state.notes or not state.selected_notes then return false, "Select 2 or more notes" end

  -- Collect and sort selected indices
  local indices = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then
      table.insert(indices, idx)
    end
  end
  table.sort(indices)

  if #indices < 2 then return false, "Select 2 or more notes" end -- need at least 2 notes to merge

  -- Validate contiguity: indices must be consecutive
  for i = 2, #indices do
    if indices[i] ~= indices[i - 1] + 1 then
      return false, "Can't merge: notes must be next to each other"
    end
  end

  -- Validate gap size: no gap > 300ms between any pair
  for i = 2, #indices do
    local prev_note = state.notes[indices[i - 1]]
    local curr_note = state.notes[indices[i]]
    local gap = curr_note.start_time - prev_note.end_time
    if gap > 0.3 then
      return false, "Can't merge: the gap is longer than 300 ms"
    end
  end

  local first_note = state.notes[indices[1]]
  local last_note = state.notes[indices[#indices]]

  -- Concatenate frames from all selected notes + recover gap frames
  local merged_frames = {}
  for i, idx in ipairs(indices) do
    local n = state.notes[idx]

    -- Before this note (except the first), try to recover gap frames
    if i > 1 then
      local prev_n = state.notes[indices[i - 1]]
      local gap_start = prev_n.end_time
      local gap_end = n.start_time
      if gap_end > gap_start then
        for _, frame in ipairs(state.results) do
          if frame.time > gap_start and frame.time < gap_end
              and frame.note and frame.rms and frame.rms > 0.005 then
            table.insert(merged_frames, frame)
          end
        end
      end
    end

    -- Add this note's frames
    for _, frame in ipairs(n.frames) do
      table.insert(merged_frames, frame)
    end
  end

  if #merged_frames < 3 then return false, "Can't merge: the merged note would have too few analysis frames" end

  -- Duration-weighted pitch target from user tuning
  local total_dur = 0
  local weighted_pitch = 0
  local weighted_drift = 0
  local weighted_vibrato = 0
  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    local dur = n.end_time - n.start_time
    total_dur = total_dur + dur
    if n.controls then
      weighted_pitch = weighted_pitch + n.controls.center_pitch * dur
      weighted_drift = weighted_drift + n.controls.drift_scale * dur
      weighted_vibrato = weighted_vibrato + n.controls.vibrato_scale * dur
    else
      weighted_pitch = weighted_pitch + n.avg_note * dur
      weighted_drift = weighted_drift + 1.0 * dur
      weighted_vibrato = weighted_vibrato + 1.0 * dur
    end
  end

  local sum_note = 0
  for _, f in ipairs(merged_frames) do sum_note = sum_note + f.note end
  local avg_note = sum_note / #merged_frames

  local merged = {
    start_time = first_note.start_time,
    end_time = last_note.end_time,
    sum_note = sum_note,
    count = #merged_frames,
    avg_note = avg_note,
    display_note = math.floor(avg_note + 0.5),
    frames = merged_frames,
  }

  extract_note_features(merged, {
    center_pitch = total_dur > 0 and (weighted_pitch / total_dur) or avg_note,
    drift_scale = total_dur > 0 and (weighted_drift / total_dur) or 1.0,
    vibrato_scale = total_dur > 0 and (weighted_vibrato / total_dur) or 1.0,
    transition_ms = first_note.controls and first_note.controls.transition_ms or nil,
    onset_ramp_ms = first_note.controls and first_note.controls.onset_ramp_ms or nil,
    retune_speed = first_note.controls and first_note.controls.retune_speed or nil,
    scoop_shape = first_note.controls and first_note.controls.scoop_shape or nil,
    bypassed = false,
  })

  -- Replace in array: put merged note at first index, remove the rest
  local first_idx = indices[1]
  state.notes[first_idx] = merged
  for i = #indices, 2, -1 do
    table.remove(state.notes, indices[i])
  end

  -- Update selection
  state.selected_note = first_idx
  state.selected_notes = { [first_idx] = true }

  return true, apply_envelope_to_take("Merge Notes")
end

-- Trims the left or right edge of a note to a new time boundary.
-- Filters or extends frames, preserves pitch offset, re-extracts features. A trim that would leave the note with
-- fewer than 3 frames is refused (the edge snaps back) and says so in the status line.
trim_note_edge = function(note_idx, edge, new_time)
  if not state.notes or not state.notes[note_idx] then return end
  local note = state.notes[note_idx]
  if not note.frames or #note.frames < 3 then return end

  local min_dur = 0.05 -- 50ms minimum note duration
  local gap_margin = 0.005 -- 5ms gap to prevent overlap

  -- Clamp to prevent overlap with neighbors
  if edge == "left" then
    local prev_note = state.notes[note_idx - 1]
    local min_t = prev_note and (prev_note.end_time + gap_margin) or 0
    local max_t = note.end_time - min_dur
    new_time = math.max(min_t, math.min(max_t, new_time))
  elseif edge == "right" then
    local next_note = state.notes[note_idx + 1]
    local min_t = note.start_time + min_dur
    local max_t = next_note and (next_note.start_time - gap_margin) or state.end_time
    new_time = math.max(min_t, math.min(max_t, new_time))
  else
    return
  end

  -- Preserve pitch offset
  local old_ctrl = note.controls
  local pitch_offset = old_ctrl and (old_ctrl.center_pitch - note.avg_note) or 0

  -- Rebuild frames within the new boundary
  local new_start = (edge == "left") and new_time or note.start_time
  local new_end = (edge == "right") and new_time or note.end_time

  -- Collect frames: from existing note + from state.results for any extensions
  local frame_set = {} -- time → frame (deduplicate)
  for _, frame in ipairs(note.frames) do
    if frame.time >= new_start and frame.time <= new_end then
      frame_set[frame.time] = frame
    end
  end

  -- If extending, pull in unassigned frames from the raw results pool
  if (edge == "left" and new_time < note.start_time)
      or (edge == "right" and new_time > note.end_time) then
    for _, frame in ipairs(state.results) do
      if frame.time >= new_start and frame.time <= new_end
          and frame.note and frame.rms and frame.rms > 0.005
          and not frame_set[frame.time] then
        frame_set[frame.time] = frame
      end
    end
  end

  -- Sort frames by time
  local new_frames = {}
  for _, frame in pairs(frame_set) do
    table.insert(new_frames, frame)
  end
  table.sort(new_frames, function(a, b) return a.time < b.time end)

  if #new_frames < 3 then -- too few frames remaining: the edge snaps back
    set_status("That edge can't move any further")
    return
  end

  -- Rebuild note
  local sum_note = 0
  for _, f in ipairs(new_frames) do sum_note = sum_note + f.note end
  local avg_note = sum_note / #new_frames

  note.start_time = new_start
  note.end_time = new_end
  note.frames = new_frames
  note.sum_note = sum_note
  note.count = #new_frames
  note.avg_note = avg_note
  note.display_note = math.floor(avg_note + 0.5)

  extract_note_features(note, {
    center_pitch = avg_note + pitch_offset,
    drift_scale = old_ctrl and old_ctrl.drift_scale or 1.0,
    vibrato_scale = old_ctrl and old_ctrl.vibrato_scale or 1.0,
    transition_ms = old_ctrl and old_ctrl.transition_ms or nil,
    onset_ramp_ms = old_ctrl and old_ctrl.onset_ramp_ms or nil,
    retune_speed = old_ctrl and old_ctrl.retune_speed or nil,
    scoop_shape = old_ctrl and old_ctrl.scoop_shape or nil,
    bypassed = old_ctrl and old_ctrl.bypassed or false,
  })

  apply_envelope_to_take("Trim Note Edge")
end

local function run_hybrid_segmentation()
  state.notes = {}
  state.split_points = {} -- For debugging display

  if #state.results == 0 then return end

  -- Configuration
  local min_note_dur = 0.08 -- 80ms
  local debounce_dur = 0.08 -- 80ms
  local pitch_jump_threshold = 0.75 -- Semitones
  local rms_noise_floor = 0.005 -- Absolute RMS threshold for silence

  -- Calculate derivatives (applying a simple median filter logic by looking at 3 frames would be better, but we keep it simple for now)
  for i, frame in ipairs(state.results) do
    if i > 1 then
      local prev = state.results[i-1]
      if frame.note and prev.note then
        frame.delta_note = frame.note - prev.note
      else
        frame.delta_note = 0
      end
      frame.delta_rms = frame.rms - prev.rms
    else
      frame.delta_note = 0
      frame.delta_rms = 0
    end
  end

  local current_note = nil
  local last_split_time = -1

  for _, frame in ipairs(state.results) do
    local is_voiced = (frame.note ~= nil and frame.rms > rms_noise_floor)

    local should_split = false
    local split_reason = ""

    if is_voiced then
      if not current_note then
        should_split = true
        split_reason = "Onset (from silence)"
      else
        -- Check for pitch jump (legato)
        if math.abs(frame.delta_note) > pitch_jump_threshold then
          should_split = true
          split_reason = "Pitch Jump"
        end

        -- Check for amplitude spike (articulation)
        if frame.delta_rms > frame.rms * 0.5 and frame.delta_rms > 0.02 then
          should_split = true
          split_reason = "Amplitude Spike"
        end
      end
    else
      -- Unvoiced gap
      if current_note then
        -- End current note
        if (frame.time - current_note.start_time) >= min_note_dur then
          table.insert(state.notes, current_note)
        end
        current_note = nil
      end
    end

    if should_split and (frame.time - last_split_time) >= debounce_dur then
      if current_note then
        current_note.end_time = frame.time
        if (current_note.end_time - current_note.start_time) >= min_note_dur then
          table.insert(state.notes, current_note)
        end
      end

      current_note = {
        start_time = frame.time,
        end_time = frame.time,
        sum_note = 0,
        count = 0,
        frames = {}
      }

      table.insert(state.split_points, { time = frame.time, reason = split_reason })
      last_split_time = frame.time
    end

    if current_note and is_voiced then
      current_note.sum_note = current_note.sum_note + frame.note
      current_note.count = current_note.count + 1
      current_note.end_time = frame.time
      table.insert(current_note.frames, frame)
    end
  end

  -- Push last note
  if current_note and (current_note.end_time - current_note.start_time) >= min_note_dur then
    table.insert(state.notes, current_note)
  end

  -- Calculate anchor pitch
  for _, n in ipairs(state.notes) do
    if n.count > 0 then
      n.avg_note = n.sum_note / n.count
      n.display_note = math.floor(n.avg_note + 0.5)
      extract_note_features(n)
    end
  end
end

local function process_analysis_step()
  if not state.is_analyzing then return end

  -- The parameters frozen by start_analysis (an analysis always has them; the copy only guards a state set up by hand)
  local params = state.analysis_params
  if not params then
    params = {
      block_size = state.block_size, hop_size = state.hop_size, threshold = state.threshold,
      min_freq = state.min_freq, max_freq = state.max_freq,
    }
    state.analysis_params = params
  end

  -- Work for one short slice, then yield to the window (the progress and Cancel stay responsive)
  local slice_start = reaper.time_precise()

  while state.current_time < state.end_time do
    if reaper.time_precise() - slice_start > K.ANALYSIS_SLICE_S then
      break
    end

    -- Read samples
    local num_read = reaper.GetAudioAccessorSamples(
      state.accessor,
      state.sample_rate,
      state.num_channels,
      state.current_time,
      params.block_size,
      state.buffer
    )

    if num_read > 0 then
      local rms, freq = yin_process_block(state.buffer, state.sample_rate, params)
      local note = nil
      if freq and freq >= params.min_freq and freq <= params.max_freq then
        note = freq_to_note(freq)
      end
      table.insert(state.results, {
        time = state.current_time,
        freq = freq,
        note = note,
        rms = rms
      })
    end

    -- Advance time by hop size
    state.current_time = state.current_time + (params.hop_size / state.sample_rate)
  end

  if state.current_time >= state.end_time then
    -- The resync is paused while analysing: remember whether the project changed meanwhile so the
    -- next frame still picks up external changes (undo etc.) after this script's own writes.
    local external_change = (state.last_change_count ~= reaper.GetProjectStateChangeCount(0))

    reaper.DestroyAudioAccessor(state.accessor)
    state.accessor = nil
    state.is_analyzing = false
    state.analysis_params = nil
    state.progress = 1.0
    run_hybrid_segmentation()
    state.analysis_empty = (not state.notes or #state.notes == 0)
    state.view_t0, state.view_t1 = nil, nil   -- the new model is shown whole

    -- Store into multi-item session cache, then persist inside ONE named undo block
    if state.target_take_guid then
      state.stale_takes[state.target_take_guid] = nil   -- a fresh analysis has no stale envelope
      local take_data = {
        guid = state.target_take_guid,
        name = state.target_take_name or "Item",
        start_time = state.start_time,
        end_time = state.end_time,
        item_len = state.item_len,
        sample_rate = state.sample_rate,
        results = state.results,
        notes = state.notes,
        key_idx = state.key_idx,
        scale_idx = state.scale_idx
      }
      state.session_takes[state.target_take_guid] = take_data

      local found = false
      for _, g in ipairs(state.session_order) do
        if g == state.target_take_guid then found = true; break end
      end
      if not found then table.insert(state.session_order, state.target_take_guid) end

      -- Re-apply the envelope from the fresh (untouched) notes: this clears every stale point left by
      -- a previous analysis and writes the new model to the take inside the same "Analyze Pitch" block.
      -- The take's pitch mode is left alone (no correction is applied yet).
      if resolve_take_by_guid(state.target_take_guid, true) then
        apply_envelope_to_take("Analyze Pitch", true)
      else
        state.missing_takes[state.target_take_guid] = true
      end
    end
    if external_change then state.last_change_count = nil end
  elseif state.item_len > 0 then
    state.progress = state.current_time / state.item_len
  end
end

-------------------------------------------------------------------------------
-- 4. GUI
-------------------------------------------------------------------------------

-- Press state of every param_drag control: [id] = { ctrl = Ctrl/Cmd held at press, dragged = mouse moved }
local drag_state = {}

--- Numeric part of a display format for the typed-entry field: "%.0f%%" -> "%.0f", "%.0f ms" -> "%.0f".
local function typed_format(fmt)
  return (fmt or ""):match("%%[%d%.%-+ #]*[fFgGeE]") or "%.3f"
end

--- Value control shared by every slider of the script (HC2 / HC3, EP3): a DragDouble that cannot leave
--- [lo, hi], fine-adjusts with Ctrl/Cmd-drag (speed x FINE_ADJUST_SCALE; Shift and Alt stay REAPER's),
--- resets on double-click and opens a typed-entry popup on a Ctrl/Cmd-click released without dragging.
--- Works in display units: a percent control passes value * 100 with lo = 0, hi = 100 and converts back.
---   id     stable widget id ("###id"): the visible label may change without losing the drag
---   label  visible text right of the control (nil / "" = none)
---   speed  value units per pixel (default: (hi - lo) / the item width in pixels, so a drag across the whole
---          control sweeps the whole range whatever its width; Ctrl/Cmd fine adjust is FINE_ADJUST_SCALE x that)
--- The wheel adjusts the hovered value too (Ctrl/Cmd + wheel: fine, FINE_ADJUST_SCALE x a notch), but only where the
--- window cannot scroll (there the wheel belongs to the window): a run of notches is ONE edit, committed WHEEL_IDLE_S
--- after the last notch or as soon as the pointer leaves the control, so the caller makes one undo point per burst.
--- Returns changed, value, committed, reset:
---   changed    the value moved (a drag frame, a wheel notch, or a typed entry confirmed); value is clamped to [lo, hi]
---   committed  the edit is done: the drag was released after an edit, a wheel burst ended, the typed entry was
---              confirmed, or reset
---   reset      double-click: the caller restores its own default (the value returned is the input, untouched)
--- Test the gestures right here: no other item may be submitted between this call and the caller's
--- BeginPopupContextItem / IsItemHovered.
local function param_drag(pctx, id, label, value, lo, hi, fmt, speed)
  local ctrl_down = ((reaper.ImGui_GetKeyMods(pctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0   -- Cmd on macOS
  local step = speed or (hi - lo) / math.max(reaper.ImGui_CalcItemWidth(pctx) or 0, 1)
  local rv, v = reaper.ImGui_DragDouble(pctx, (label or "") .. "###" .. id, value,
    ctrl_down and step * K.FINE_ADJUST_SCALE or step, lo, hi, fmt,
    reaper.ImGui_SliderFlags_AlwaysClamp() | reaper.ImGui_SliderFlags_NoInput() | reaper.ImGui_SliderFlags_NoSpeedTweaks())
  if type(v) ~= "number" then v = value end
  v = math.max(lo, math.min(hi, v))

  -- Item state first (it describes the drag item until another item is submitted)
  local st = drag_state[id]
  if not st then st = { ctrl = false, dragged = false }; drag_state[id] = st end
  if reaper.ImGui_IsItemActivated(pctx) then st.ctrl, st.dragged = ctrl_down, false end
  if reaper.ImGui_IsItemActive(pctx) and reaper.ImGui_IsMouseDragging(pctx, 0) then st.dragged = true end
  local released = reaper.ImGui_IsItemDeactivated(pctx)
  local committed = reaper.ImGui_IsItemDeactivatedAfterEdit(pctx) == true
  local hovered = reaper.ImGui_IsItemHovered(pctx)
  local reset = hovered and reaper.ImGui_IsMouseDoubleClicked(pctx, 0) or false

  -- HC2 / EF1: wheel adjust where the window cannot scroll; the burst commits once (see above)
  local now = reaper.time_precise()
  if hovered and not reset and not reaper.ImGui_IsItemActive(pctx) and (reaper.ImGui_GetScrollMaxY(pctx) or 0) <= 0 then
    local wheel = reaper.ImGui_GetMouseWheel(pctx) or 0
    if wheel ~= 0 then
      local notch = (hi - lo) / K.WHEEL_NOTCHES * (ctrl_down and K.FINE_ADJUST_SCALE or 1)
      local wheeled = math.max(lo, math.min(hi, value + wheel * notch))
      if wheeled ~= value then rv, v = true, wheeled end
      st.wheel_pending, st.wheel_last = true, now
    end
  end
  if st.wheel_pending and (not hovered or now - st.wheel_last > K.WHEEL_IDLE_S) then
    st.wheel_pending = false
    committed = true
  end

  -- HC3: Ctrl/Cmd-click released without dragging opens the typed entry
  local popup = "###type_" .. id
  if released and st.ctrl and not st.dragged and not reset then
    reaper.ImGui_OpenPopup(pctx, popup)
  end
  if released or reset then st.ctrl = false end
  if reaper.ImGui_BeginPopup(pctx, popup) then
    -- HC5: Esc discards the entry; an active field handles it itself (below), this covers a lost focus
    if reaper.ImGui_Shortcut(pctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(pctx) end
    if reaper.ImGui_IsWindowAppearing(pctx) then
      reaper.ImGui_SetKeyboardFocusHere(pctx)
      st.text = string.format(typed_format(fmt), value)
    end
    -- InputText, not InputDouble: InputScalar asserts on EnterReturnsTrue, and without it a number field
    -- reports every keystroke as a change. The text is kept between frames and parsed on Enter.
    local ok, text = reaper.ImGui_InputText(pctx, "##typed", st.text or "",
      reaper.ImGui_InputTextFlags_EnterReturnsTrue() | reaper.ImGui_InputTextFlags_CharsDecimal()
      | reaper.ImGui_InputTextFlags_AutoSelectAll())
    if type(text) == "string" then st.text = text end
    local typed = ok and tonumber(st.text) or nil
    if typed then
      rv, v, committed = true, math.max(lo, math.min(hi, typed)), true
      reaper.ImGui_CloseCurrentPopup(pctx)
    elseif ok or reaper.ImGui_IsItemDeactivated(pctx) then
      reaper.ImGui_CloseCurrentPopup(pctx)   -- Esc or a click elsewhere: the entry is discarded
    end
    reaper.ImGui_EndPopup(pctx)
  end

  if reset then return false, value, true, true end
  return rv == true, v, committed, false
end

-------------------------------------------------------------------------------
-- Canvas drawing cache. The coordinates of the raw pitch trace and of each note's trend and preview lines are
-- reaper.arrays with thousands of points, and the raw min / max of the analysis frames is a scan over all of
-- them: none of it changes while the user only looks. They are kept in state.draw_cache and rebuilt only when
-- something they are made of changed. The key of each cached value is EVERY input of its computation, compared
-- each frame (a few numbers and table identities, no allocation), so the cache needs no revision counter that
-- every edit would have to remember to bump:
--   * the mapping from time and pitch to screen: the note area's origin and size, the visible time window and the
--     pitch range (state.draw_cache.map; gen counts its changes, and it covers zoom, scroll, resize, a window that
--     moved and the pitch range that follows the notes while they are dragged)
--   * the data: the analysis frames (state.results only ever grows by appending, a new analysis or a reload makes a
--     new table, and no frame is changed after it is made) and, per note, the identity of its frames / trend /
--     modulation / vibrato arrays (a split, merge, trim or re-extraction makes new ones; none is written in place)
--     plus the numbers the preview line reads (average pitch, pitch / stability / vibrato controls, retune speed)
-- Edits therefore show on the very next frame, and a frame that changed nothing rebuilds nothing.
-------------------------------------------------------------------------------

--- An array of n numbers: `arr` resized when its allocation has room (reaper.array.resize stays within the
--- allocation), otherwise a new one with room to spare, so a curve that grows by a point or two per frame
--- (an analysis in progress) does not allocate on every frame.
K.fit_array = function(arr, n)
  local alloc = arr and arr.get_alloc() or 0
  if alloc < n then arr = reaper.new_array(math.max(n, alloc * 2)) end
  arr.resize(n)
  return arr
end

--- Raw min / max pitch over the analysis frames of `results` (has: some frame carries a pitch). Frames are only
--- appended, so each call looks only at the frames added since the last one (a different table starts over).
K.results_range = function(results)
  local range = state.draw_cache.range
  local n = #results
  if range.results ~= results or n < range.n then
    range.results, range.n, range.min, range.max, range.has = results, 0, 127, 0, false
  end
  for i = range.n + 1, n do
    local note = results[i].note
    if note then
      range.has = true
      if note < range.min then range.min = note end
      if note > range.max then range.max = note end
    end
  end
  range.n = n
  return range.has, range.min, range.max
end

--- Once per frame, after the canvas mapping is final: records it (px, py = the note area's top-left corner, w, h =
--- its size, vt0 .. vt1 = the visible time window, min_note, note_range = the pitch range) and counts a change in
--- state.draw_cache.gen, which every cached array carries and compares.
K.canvas_cache_begin = function(px, py, w, h, vt0, vt1, min_note, note_range)
  local dc = state.draw_cache
  local m = dc.map
  if m.px ~= px or m.py ~= py or m.w ~= w or m.h ~= h or m.vt0 ~= vt0 or m.vt1 ~= vt1
      or m.min ~= min_note or m.range ~= note_range then
    m.px, m.py, m.w, m.h, m.vt0, m.vt1, m.min, m.range = px, py, w, h, vt0, vt1, min_note, note_range
    dc.gen = dc.gen + 1
  end
end

--- The coordinates of the raw pitch trace (frames r0 .. r1 of `results` that carry a pitch) as an array for
--- DrawList_AddPolyline, or nil when fewer than two points. t_to_x is the canvas's time-to-x mapping.
K.raw_trace = function(results, r0, r1, t_to_x)
  local dc = state.draw_cache
  local raw = dc.raw
  if not (raw.results == results and raw.n == #results and raw.r0 == r0 and raw.r1 == r1 and raw.gen == dc.gen) then
    local valid_pts = 0
    for i = r0, r1 do
      if results[i].note then valid_pts = valid_pts + 1 end
    end
    if valid_pts > 1 then
      local m = dc.map
      local arr = K.fit_array(raw.arr, valid_pts * 2)
      local idx = 1
      for i = r0, r1 do
        local pt = results[i]
        if pt.note then
          arr[idx] = t_to_x(pt.time)
          arr[idx + 1] = m.py + m.h - ((pt.note - m.min) / m.range) * m.h
          idx = idx + 2
        end
      end
      raw.arr = arr
    end
    raw.results, raw.n, raw.r0, raw.r1, raw.gen, raw.valid = results, #results, r0, r1, dc.gen, valid_pts
  end
  if raw.valid > 1 then return raw.arr end
  return nil
end

--- The per-note cache entry (created on first use; entries go when their note does).
K.note_entry = function(note)
  local notes = state.draw_cache.notes
  local entry = notes[note]
  if not entry then
    entry = {}
    notes[note] = entry
  end
  return entry
end

--- The coordinates of the trend line of `note` over its frames f0 .. f1 (the ones in the visible window), as an array
--- for DrawList_AddPolyline.
K.note_trend = function(note, f0, f1, t_to_x)
  local dc = state.draw_cache
  local e = K.note_entry(note)
  if not (e.t_arr and e.t_gen == dc.gen and e.t_frames == note.frames and e.t_trend == note.trend
      and e.t_f0 == f0 and e.t_f1 == f1) then
    local m = dc.map
    local arr = K.fit_array(e.t_arr, (f1 - f0 + 1) * 2)
    local idx = 1
    for i = f0, f1 do
      arr[idx] = t_to_x(note.frames[i].time)
      arr[idx + 1] = m.py + m.h - ((note.trend[i] - m.min) / m.range) * m.h
      idx = idx + 2
    end
    e.t_arr, e.t_gen, e.t_frames, e.t_trend, e.t_f0, e.t_f1 = arr, dc.gen, note.frames, note.trend, f0, f1
  end
  return e.t_arr
end

--- The coordinates of the corrected-pitch preview line of `note` over its frames f0 .. f1, as an array for
--- DrawList_AddPolyline. The note must have controls, a trend and a modulation.
K.note_preview = function(note, f0, f1, t_to_x)
  local dc = state.draw_cache
  local e = K.note_entry(note)
  local ctrl = note.controls
  local retune = get_effective(note, "retune_speed")
  if not (e.p_arr and e.p_gen == dc.gen and e.p_frames == note.frames and e.p_trend == note.trend
      and e.p_mod == note.modulation and e.p_vw == note.vibrato_weight and e.p_avg == note.avg_note
      and e.p_cp == ctrl.center_pitch and e.p_ds == ctrl.drift_scale and e.p_vs == ctrl.vibrato_scale
      and e.p_ret == retune and e.p_f0 == f0 and e.p_f1 == f1) then
    local m = dc.map
    local coarse_shift = (ctrl.center_pitch - note.avg_note) * retune
    local arr = K.fit_array(e.p_arr, (f1 - f0 + 1) * 2)
    local idx = 1
    for i = f0, f1 do
      local frame = note.frames[i]
      local vw = (note.vibrato_weight and note.vibrato_weight[i]) or 0.0
      local drift_corr = (note.trend[i] - note.avg_note) * (ctrl.drift_scale - 1.0)
      local vib_corr = note.modulation[i] * (ctrl.vibrato_scale - 1.0) * vw
      local target = frame.note + coarse_shift + drift_corr + vib_corr
      arr[idx] = t_to_x(frame.time)
      arr[idx + 1] = m.py + m.h - ((target - m.min) / m.range) * m.h
      idx = idx + 2
    end
    e.p_arr, e.p_gen, e.p_frames, e.p_trend, e.p_mod, e.p_vw = arr, dc.gen, note.frames, note.trend, note.modulation, note.vibrato_weight
    e.p_avg, e.p_cp, e.p_ds, e.p_vs, e.p_ret, e.p_f0, e.p_f1 =
      note.avg_note, ctrl.center_pitch, ctrl.drift_scale, ctrl.vibrato_scale, retune, f0, f1
  end
  return e.p_arr
end

--- The note control a canvas drag writes: by zone, and Shift remaps the zones (Transition / Onset Ramp / Scoop).
K.drag_field = function(zone, shift)
  if shift then
    return (zone == "pitch" and "transition_ms") or (zone == "drift" and "onset_ramp_ms") or "scoop_shape"
  end
  return (zone == "pitch" and "center_pitch") or (zone == "drift" and "drift_scale") or "vibrato_scale"
end

--- Esc during a canvas gesture (HC5): put back what the drag, edge drag or box selection changed and end it. Nothing
--- was written while it moved (the envelope and the undo point come on release), so nothing is written now either.
K.cancel_gesture = function()
  local d, e, m = state.drag, state.edge_drag, state.marquee
  if d and d.field and d.orig_raw and state.notes then
    for idx in pairs(d.orig_values or {}) do
      local n = state.notes[idx]
      if n and n.controls then n.controls[d.field] = d.orig_raw[idx] end
    end
  end
  if e and state.notes then
    local n = state.notes[e.note_idx]
    if n then
      if e.edge == "left" then n.start_time = e.original_time else n.end_time = e.original_time end
    end
  end
  if m and m.prev_sel then
    state.selected_notes = m.prev_sel
    state.selected_note = m.prev_primary
  end
  state.drag, state.edge_drag, state.marquee, state.shift_mode = nil, nil, nil, false
  if (d and d.dirty) or (e and e.dirty) then set_status("Drag cancelled. Nothing was changed.") end
end

local function draw_graph(draw_ctx, w, h)
  local draw_list = reaper.ImGui_GetWindowDrawList(draw_ctx)
  local px, py = reaper.ImGui_GetCursorScreenPos(draw_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout
  local C = P.canvas   -- the canvas colours (Theme section 4A): rows, keys, notes, curves, pills; they follow the theme mode

  -- Claim canvas space and enable mouse interaction. A Button submitted later on top of it (the empty-state and
  -- BYPASSED actions) takes the hover where it sits, so the canvas allows itself to be overlapped.
  reaper.ImGui_SetNextItemAllowOverlap(draw_ctx)
  reaper.ImGui_InvisibleButton(draw_ctx, "##pitch_canvas", w, h)
  local is_canvas_hovered = reaper.ImGui_IsItemHovered(draw_ctx)
  local canvas_tip_ready = reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip())   -- the hover hint waits like every tooltip

  -- Draw background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + h, P.bg)
  reaper.ImGui_DrawList_AddRect(draw_list, px, py, px + w, py + h, P.border)

  local piano_w = K.PIANO_W
  local full_px = px
  local full_w = w
  px = px + piano_w
  w = w - piano_w

  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, full_px + full_w, py + h, true)

  local target_take = K.frame_target()
  local is_bypassed = is_take_pitch_bypassed(target_take)

  -- The one button the canvas draws (Analyze Item, Open Settings, Enable): a real Button on the large preset,
  -- centred on cx with its top edge at y (its height is Theme.layout.btn_lg.h), hand cursor and tooltip.
  -- Returns true when it was clicked (never while it is disabled). It moves the layout cursor into the canvas:
  -- whoever used it calls restore_canvas_layout() before leaving draw_graph.
  local buttons_used = false
  local function canvas_button(label, id, cx, y, enabled, tip)
    buttons_used = true
    local var_count, pushed_font = Theme.push_button_preset(draw_ctx, fonts, "lg")
    local btn_w = (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) + L.btn_lg.pad_x * 2
    reaper.ImGui_SetCursorScreenPos(draw_ctx, cx - btn_w * 0.5, y)
    if not enabled then reaper.ImGui_BeginDisabled(draw_ctx) end
    local clicked = reaper.ImGui_Button(draw_ctx, label .. "###" .. id, btn_w, 0)
    if not enabled then reaper.ImGui_EndDisabled(draw_ctx) end
    local hovered = reaper.ImGui_IsItemHovered(draw_ctx)
    local tip_ready = reaper.ImGui_IsItemHovered(draw_ctx,   -- a disabled button explains itself too
      reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled())
    Theme.pop_button_preset(draw_ctx, var_count, pushed_font)   -- before the tooltip: it is drawn in the default font
    if enabled and hovered then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if tip_ready then Theme.tooltip(draw_ctx, tip) end
    return clicked and enabled
  end

  -- After canvas_button the last item is a button inside the canvas and the cursor sits in it: a canvas-sized
  -- Dummy at the canvas origin puts both back, so the caller's SameLine / next item lands as it does without buttons
  local function restore_canvas_layout()
    if buttons_used then
      reaper.ImGui_SetCursorScreenPos(draw_ctx, full_px, py)
      reaper.ImGui_Dummy(draw_ctx, full_w, h)
    end
  end

  -- Nothing to edit yet: not analysed (Analyze Item above a hint), or analysed without finding a pitched note
  if #state.results == 0 or state.analysis_empty then
    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5
    local gap = L.lg

    if #state.results == 0 then
      -- While the analysis runs (and has no frame yet) the canvas says so, as the dock does
      local msg = state.is_analyzing
        and string.format("Analyzing %s… %d%%", state.target_take_name or "this item", math.floor((state.progress or 0) * 100))
        or "No data. Select an item and click Analyze."
      local text_w, text_h = reaper.ImGui_CalcTextSize(draw_ctx, msg)
      local start_y = cy - (L.btn_lg.h + gap + text_h) * 0.5

      local can_analyze = (target_take ~= nil and not state.is_analyzing)
      local tip = can_analyze and "Detect the pitch of the selected audio item"
        or (state.is_analyzing and "Analysis in progress" or "Select an audio item in REAPER to analyze it.")
      if canvas_button("Analyze Item", "cv_analyze", cx, start_y, can_analyze, tip) then
        start_analysis()
      end

      -- Centered text below the button
      reaper.ImGui_DrawList_AddText(draw_list, cx - text_w * 0.5, start_y + L.btn_lg.h + gap, P.text_dim, msg)
    else
      local title = "No pitched notes found"
      local hint = "Try another Vocal Range or Detection Mode in Settings."
      -- The title is measured and drawn in the same (bold) font
      local pushed_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
      local title_w, title_h = reaper.ImGui_CalcTextSize(draw_ctx, title)
      Theme.pop_font(draw_ctx, pushed_font)
      local hint_w, hint_h = reaper.ImGui_CalcTextSize(draw_ctx, hint)
      local start_y = cy - (title_h + L.xs + hint_h + gap + L.btn_lg.h) * 0.5

      pushed_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
      reaper.ImGui_DrawList_AddText(draw_list, cx - title_w * 0.5, start_y, P.text, title)
      Theme.pop_font(draw_ctx, pushed_font)
      reaper.ImGui_DrawList_AddText(draw_list, cx - hint_w * 0.5, start_y + title_h + L.xs, P.text_dim, hint)

      if canvas_button("Open Settings", "cv_open_settings", cx, start_y + title_h + L.xs + hint_h + gap, true,
          "Open Settings to change the Vocal Range or Detection Mode") then
        show_settings_modal = true
      end
    end

    restore_canvas_layout()
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end

  -- Find min/max notes for vertical scaling (the analysis frames' part is cached, see K.results_range)
  local has_notes, min_note, max_note = K.results_range(state.results)
  -- Include moved blocks in range calculation
  if state.notes then
    for _, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        if cp + 0.5 > max_note then max_note = cp + 0.5 end
        if cp - 0.5 < min_note then min_note = cp - 0.5 end
      end
    end
  end

  if not has_notes then
    -- Frames exist but none is voiced yet: a silent lead-in while analysing, or an item without pitched audio
    local msg = state.is_analyzing
      and string.format("Analyzing %s… %d%%", state.target_take_name or "this item", math.floor((state.progress or 0) * 100))
      or "No pitched audio found in this item."
    local msg_w, msg_h = reaper.ImGui_CalcTextSize(draw_ctx, msg)
    reaper.ImGui_DrawList_AddText(draw_list, full_px + (full_w - (msg_w or 0)) * 0.5, py + (h - (msg_h or 0)) * 0.5,
      P.text_dim, msg)
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end

  -- Add padding
  min_note = math.floor(min_note - 2)
  max_note = math.ceil(max_note + 2)
  local note_range = max_note - min_note
  if note_range < 1 then note_range = 1 end

  local duration = state.end_time - state.start_time
  if duration <= 0 then duration = 1 end
  local px_per_st = h / note_range -- pixels per semitone

  -- A gesture keeps the pitch range it began with (view_min / view_max, stored when it starts): the range
  -- above follows every note, so a note dragged out of it would rescale the canvas under the cursor.
  -- After the release the range follows the notes again.
  local gesture = state.drag or state.edge_drag or state.marquee
  if gesture and gesture.view_min and gesture.view_max then
    min_note, max_note = gesture.view_min, gesture.view_max
    note_range = math.max(1, max_note - min_note)
    px_per_st = h / note_range
  end

  ---------------------------------------------------------------------------
  -- TIMELINE VIEW (horizontal zoom and scroll)
  ---------------------------------------------------------------------------
  -- Every time <-> x conversion below goes through t_to_x / x_to_t, which map the visible window [vt0, vt1]
  -- (seconds relative to the item start: the whole item unless the user zoomed, state.view_t0 / view_t1) onto
  -- the note area. The vertical pitch range is not affected by the window.
  local item_t0 = state.start_time
  local item_t1 = state.start_time + duration
  local vt0, vt1 = item_t0, item_t1
  local function t_to_x(t) return px + (t - vt0) / (vt1 - vt0) * w end
  local function x_to_t(x) return vt0 + (x - px) / math.max(w, 1) * (vt1 - vt0) end

  -- Show `span` seconds with the time `anchor_t` at fraction `frac` (0..1) of the note area's width. The span
  -- stays within [MIN_VIEW_SPAN_S, the item], the window inside the item, and a window covering the whole
  -- item is stored as nil.
  local function set_view(anchor_t, frac, span)
    span = math.max(math.min(K.MIN_VIEW_SPAN_S, duration), math.min(duration, span))
    local t0 = math.max(item_t0, math.min(item_t1 - span, anchor_t - frac * span))
    if span >= duration - K.VIEW_EPS_S then
      vt0, vt1 = item_t0, item_t1
      state.view_t0, state.view_t1 = nil, nil
    else
      vt0, vt1 = t0, t0 + span
      state.view_t0, state.view_t1 = vt0, vt1
    end
  end
  if state.view_t0 and state.view_t1 then   -- an item that changed length keeps the window inside it
    set_view(state.view_t0, 0, state.view_t1 - state.view_t0)
  end

  -- Index range [i0, i1] of `list` (entries sorted by .time) that reaches the visible window, with one entry of
  -- margin on each side so a curve still runs off the canvas edge. Empty list -> 1, 0.
  local function visible_range(list)
    local n = #list
    if n == 0 then return 1, 0 end
    local lo, hi = 1, n + 1                         -- first entry at or after the window start
    while lo < hi do
      local mid = (lo + hi) // 2
      if list[mid].time < vt0 then lo = mid + 1 else hi = mid end
    end
    local i0 = math.max(1, lo - 1)
    lo, hi = i0, n + 1                              -- first entry after the window end
    while lo < hi do
      local mid = (lo + hi) // 2
      if list[mid].time <= vt1 then lo = mid + 1 else hi = mid end
    end
    return i0, math.min(n, lo)
  end

  ---------------------------------------------------------------------------
  -- MOUSE INTERACTION
  ---------------------------------------------------------------------------
  local mx, my = reaper.ImGui_GetMousePos(draw_ctx)

  -- The time ruler is an overlay along the top of the note area: it owns the pointer there
  local line_h = reaper.ImGui_GetTextLineHeight(draw_ctx) or 0
  local ruler_h = line_h + L.xs * 2
  local on_ruler = is_canvas_hovered and mx >= px and mx <= px + w and my >= py and my <= py + ruler_h

  if is_canvas_hovered and not gesture then
    -- Ctrl/Cmd + wheel zooms around the pointer; the plain wheel scrolls the window (a no-op while the whole
    -- item is visible). Ignored during a gesture (the mapping must not change under it) and while the script
    -- window itself can scroll (the wheel belongs to it then).
    local wheel_y, wheel_x = reaper.ImGui_GetMouseWheel(draw_ctx)
    wheel_y, wheel_x = wheel_y or 0, wheel_x or 0
    if (reaper.ImGui_GetScrollMaxY(draw_ctx) or 0) > 0 then wheel_y, wheel_x = 0, 0 end
    local span = vt1 - vt0
    local wheel_mods = reaper.ImGui_GetKeyMods(draw_ctx) or 0
    if wheel_y ~= 0 and (wheel_mods & reaper.ImGui_Mod_Ctrl()) ~= 0 then
      local frac = math.max(0, math.min(1, (mx - px) / math.max(w, 1)))
      set_view(x_to_t(px + frac * w), frac, span / K.ZOOM_STEP ^ wheel_y)
    elseif span < duration - K.VIEW_EPS_S and (wheel_y ~= 0 or wheel_x ~= 0) then
      local notches = wheel_y ~= 0 and wheel_y or wheel_x   -- wheel up / left = earlier
      set_view(vt0 - notches * K.SCROLL_STEP * span, 0, span)
    end
    -- Double-click on the ruler shows the whole item again
    if on_ruler and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
      set_view(item_t0, 0, duration)
    end
  end

  -- Text on a small panel-coloured pill (C.pill_bg), so it stays readable over any canvas surface (HC1): the text tokens
  -- (C.pill_text, C.marquee_text) are fitted to >= 4.5:1 on the pill over every row and the brightest piano key. The pill
  -- is kept inside the note area (below the ruler); with flip_dx it moves to the left of x when it would run past the right edge.
  local function pill_text(x, y, text, col, flip_dx)
    local tw, th = reaper.ImGui_CalcTextSize(draw_ctx, text)
    local pill_w, pill_h = tw + L.sm * 2, th + L.xs * 2
    if flip_dx and x + pill_w > px + w then x = x - pill_w - flip_dx end
    x = math.max(px, math.min(x, px + w - pill_w))
    y = math.max(py + ruler_h, math.min(y, py + h - pill_h))
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + pill_w, y + pill_h, C.pill_bg, L.rounding)
    reaper.ImGui_DrawList_AddText(draw_list, x + L.sm, y + L.xs, col, text)
  end

  --- True when `text` on a pill fits `room` pixels: the pill pill_text draws, plus the offset the zone labels start at.
  local function pill_fits(text, room)
    return (reaper.ImGui_CalcTextSize(draw_ctx, text)) + L.sm * 2 + L.xs <= room
  end

  -- Hit-test: find hovered note, zone, and edge handles
  local prev_edge = state.hovered_edge   -- the edge the pointer rested on last frame keeps a larger grab zone
  if is_canvas_hovered and not on_ruler and not is_bypassed and not gesture and state.notes then
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
    for n_idx, note in ipairs(state.notes) do
      if note.controls then
        local cp = note.controls.center_pitch
        local sx = t_to_x(note.start_time)
        local ex = t_to_x(note.end_time)
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h

        -- Edge grab zones, per side: EDGE_GRAB wide (EDGE_GRAB_HOVER on the edge the pointer rests on), never more than
        -- a quarter of the block, so both edges stay usable at any zoom and the body stays reachable
        local cap = (ex - sx) * K.EDGE_GRAB_MAX_FRAC
        local grab_l = math.min(cap, (prev_edge and prev_edge.note_idx == n_idx and prev_edge.edge == "left") and K.EDGE_GRAB_HOVER or K.EDGE_GRAB)
        local grab_r = math.min(cap, (prev_edge and prev_edge.note_idx == n_idx and prev_edge.edge == "right") and K.EDGE_GRAB_HOVER or K.EDGE_GRAB)

        -- Check edge handles first (higher priority than zone hover); the piano column is not part of the note
        -- area, so a note running past the window's left edge is not grabbed from the keys
        if mx >= px - grab_l and my >= top_y and my <= bot_y then
          if math.abs(mx - sx) <= grab_l then
            state.hovered_edge = { note_idx = n_idx, edge = "left" }
            state.hovered_note = n_idx
            state.hovered_zone = nil
            break
          elseif math.abs(mx - ex) <= grab_r then
            state.hovered_edge = { note_idx = n_idx, edge = "right" }
            state.hovered_note = n_idx
            state.hovered_zone = nil
            break
          end
        end

        -- Standard zone hit-test (only if no edge match)
        if mx >= px and mx >= sx and mx <= ex and my >= top_y and my <= bot_y then
          state.hovered_note = n_idx
          local block_w = ex - sx
          local zone_w = math.max(K.ZONE_MIN_W, block_w * 0.25)
          if mx < sx + zone_w then
            state.hovered_zone = "drift"
          elseif mx > ex - zone_w then
            state.hovered_zone = "vibrato"
          else
            state.hovered_zone = "pitch"
          end
          break
        end
      end
    end

    -- Mouse cursor by what a drag here does: resize arrows on the edges and the pitch zone, a hand on the
    -- drift / vibrato zones
    if state.hovered_edge then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    elseif state.hovered_zone == "pitch" then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    elseif state.hovered_zone == "drift" or state.hovered_zone == "vibrato" then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
  elseif (not is_canvas_hovered or is_bypassed or on_ruler) and not state.drag and not state.edge_drag and not state.marquee then
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
  end

  -- Click: select note (Shift/Cmd/Ctrl = multi-select), begin drag, edge drag, or marquee box select
  if is_canvas_hovered and not on_ruler and not is_bypassed and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
    -- A new gesture starts: commit any pending arrow-key nudge as its own undo point first
    flush_nudge_burst()

    -- Resolve modifiers for selection modes (cross-platform macOS/Win/Linux)
    -- Cmd on macOS is Mod_Ctrl (MacOSXBehaviors); the Windows key / physical Ctrl are not treated as Ctrl
    local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
    local ctrl_mod = reaper.ImGui_Mod_Ctrl and reaper.ImGui_Mod_Ctrl() or 0
    local ok_mods, cur_mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
    local has_shift = ok_mods and cur_mods and (cur_mods & shift_mod) ~= 0
    local has_cmd_or_ctrl = ok_mods and cur_mods and (cur_mods & ctrl_mod) ~= 0

    if state.hovered_edge then
      -- Edge click → start edge drag (trimming)
      local he = state.hovered_edge
      local note = state.notes[he.note_idx]
      state.selected_note = he.note_idx
      state.selected_notes = { [he.note_idx] = true }
      state.edge_drag = {
        note_idx = he.note_idx,
        edge = he.edge,
        start_mouse_x = mx,
        original_time = (he.edge == "left") and note.start_time or note.end_time,
        dirty = false,
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    elseif state.hovered_note then
      -- Note click → update selection and prepare pitch / drift (stability) / vibrato drag
      local pending_single_select = nil
      if has_shift and state.selected_note then
        -- Shift+Click: range select from primary anchor to clicked note
        local lo = math.min(state.selected_note, state.hovered_note)
        local hi = math.max(state.selected_note, state.hovered_note)
        state.selected_notes = {}
        for i = lo, hi do
          state.selected_notes[i] = true
        end
        -- Primary anchor remains unchanged for range expansion
      elseif has_cmd_or_ctrl then
        -- Cmd/Ctrl+Click: toggle individual note in/out of selection
        if state.selected_notes[state.hovered_note] then
          state.selected_notes[state.hovered_note] = nil
          if state.selected_note == state.hovered_note then
            state.selected_note = next(state.selected_notes)
          end
        else
          state.selected_notes[state.hovered_note] = true
          state.selected_note = state.hovered_note
        end
      else
        -- Normal click
        if state.selected_notes[state.hovered_note] then
          local cur_count = 0
          for _ in pairs(state.selected_notes) do cur_count = cur_count + 1 end
          if cur_count > 1 then
            -- Clicked an already-selected note in a group: preserve selection for multi-drag.
            -- If mouse is released without dragging beyond deadzone, collapse to this note.
            pending_single_select = state.hovered_note
            state.selected_note = state.hovered_note
          end
        else
          -- Clicked an unselected note: select only this note
          state.selected_note = state.hovered_note
          state.selected_notes = { [state.hovered_note] = true }
        end
      end

      state.shift_mode = has_shift and (state.hovered_note ~= nil)

      local orig_values = {}
      -- What the drag writes and each note's own value of it before (nil = inherited), so Esc can put it back (HC5)
      local field = K.drag_field(state.hovered_zone, state.shift_mode)
      local orig_raw = {}
      for idx in pairs(state.selected_notes) do
        local n = state.notes[idx]
        if n and n.controls then
          orig_raw[idx] = n.controls[field]
          if state.shift_mode then
            if state.hovered_zone == "drift" then
              orig_values[idx] = n.controls.onset_ramp_ms or get_effective(n, "onset_ramp_ms")
            elseif state.hovered_zone == "pitch" then
              orig_values[idx] = n.controls.transition_ms or get_effective(n, "transition_ms")
            else
              orig_values[idx] = n.controls.scoop_shape or 0
            end
          else
            if state.hovered_zone == "pitch" then
              orig_values[idx] = n.controls.center_pitch
            elseif state.hovered_zone == "drift" then
              orig_values[idx] = n.controls.drift_scale
            else
              orig_values[idx] = n.controls.vibrato_scale
            end
          end
        end
      end

      state.drag = {
        note_idx = state.hovered_note,
        anchor_idx = state.hovered_note,
        zone = state.hovered_zone,
        shift_mode = state.shift_mode,
        start_mouse_y = my,
        last_y = my,      -- previous frame's pointer Y (pitch drag accumulates its movement per frame)
        pitch_st = 0,     -- semitones moved so far by a pitch drag (fine adjust scales each frame's share)
        original_value = orig_values[state.hovered_note] or 0,
        orig_values = orig_values,
        field = field,
        orig_raw = orig_raw,
        pending_single_select = pending_single_select,
        dirty = false,
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    else
      -- Click on empty canvas: initiate marquee drag tracking
      local init_sel = {}
      if has_shift and state.selected_notes then
        for k, v in pairs(state.selected_notes) do init_sel[k] = v end
      end
      local prev_sel = {}
      for k, v in pairs(state.selected_notes) do prev_sel[k] = v end
      state.marquee = {
        prev_sel = prev_sel,                    -- the selection before the box, restored by Esc (HC5)
        prev_primary = state.selected_note,
        start_x = mx,
        start_y = my,
        cur_x = mx,
        cur_y = my,
        active = false,
        has_shift = has_shift,
        init_sel = init_sel,
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    end
  end

  -- Right-click on note: open context menu
  if is_canvas_hovered and not on_ruler and reaper.ImGui_IsMouseClicked(draw_ctx, 1) then
    if state.hovered_note and state.notes[state.hovered_note] then
      state.selected_note = state.hovered_note
      state.selected_notes = { [state.hovered_note] = true }
      state.context_menu_note = state.hovered_note
      reaper.ImGui_OpenPopup(draw_ctx, "##note_context_menu")
    end
  end

  -- Process active drag (Single-note or Multi-note batch drag: Pitch, Stability, Vibrato)
  if state.drag then
    -- The cursor keeps the zone's meaning for the whole drag (pitch: vertical resize arrows, the others: a hand)
    reaper.ImGui_SetMouseCursor(draw_ctx, state.drag.zone == "pitch"
      and reaper.ImGui_MouseCursor_ResizeNS() or reaper.ImGui_MouseCursor_Hand())
    local delta_y = state.drag.start_mouse_y - my -- up = positive

    if math.abs(delta_y) > 2 then -- dead zone: click vs. drag
      state.drag.dirty = true
      state.drag.pending_single_select = nil -- drag occurred, cancel single-select collapse

      if state.shift_mode then
        if state.drag.zone == "pitch" then
          local delta = delta_y * 0.5
          for idx, orig_val in pairs(state.drag.orig_values) do
            local n = state.notes[idx]
            if n and n.controls then
              n.controls.transition_ms = math.max(5, math.min(60, orig_val + delta))
            end
          end
        elseif state.drag.zone == "drift" then
          local delta = delta_y * 0.5
          for idx, orig_val in pairs(state.drag.orig_values) do
            local n = state.notes[idx]
            if n and n.controls then
              n.controls.onset_ramp_ms = math.max(5, math.min(60, orig_val + delta))
            end
          end
        elseif state.drag.zone == "vibrato" then
          local delta = delta_y / (px_per_st * 2)
          for idx, orig_val in pairs(state.drag.orig_values) do
            local n = state.notes[idx]
            if n and n.controls then
              n.controls.scoop_shape = math.max(0, math.min(1, orig_val + delta))
            end
          end
        end
      else
        if state.drag.zone == "pitch" then
          -- HC2: Cmd/Ctrl held (read every frame) = fine adjust. Each frame's pointer movement is scaled
          -- and accumulated, so pressing or releasing the modifier mid-drag never makes the note jump.
          -- Snapping to a semitone stays on the S key and on double-click.
          local ok_mods, mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
          local fine = ok_mods and mods and (mods & reaper.ImGui_Mod_Ctrl()) ~= 0
          state.drag.pitch_st = state.drag.pitch_st
            + (state.drag.last_y - my) / px_per_st * (fine and K.FINE_ADJUST_SCALE or 1)
          state.drag.last_y = my
          local effective_delta = state.drag.pitch_st

          for idx, orig_val in pairs(state.drag.orig_values) do
            local n = state.notes[idx]
            if n and n.controls then
              n.controls.center_pitch = math.max(0, math.min(127, orig_val + effective_delta))   -- MIDI range
            end
          end
        elseif state.drag.zone == "drift" then
          -- Stability drag: up = more stable = less drift = lower drift_scale
          local delta = delta_y / (px_per_st * 2)
          for idx, orig_val in pairs(state.drag.orig_values) do
            local n = state.notes[idx]
            if n and n.controls then
              n.controls.drift_scale = math.max(0, math.min(1, orig_val - delta))
            end
          end
        elseif state.drag.zone == "vibrato" then
          -- Vibrato scale drag
          local delta = delta_y / px_per_st
          for idx, orig_val in pairs(state.drag.orig_values) do
            local n = state.notes[idx]
            if n and n.controls then
              n.controls.vibrato_scale = math.max(0, math.min(2, orig_val + delta))
            end
          end
        end
      end
    end

    -- End drag → commit envelope to take or resolve single click
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.drag.dirty then
        local count = 0
        for _ in pairs(state.drag.orig_values) do count = count + 1 end
        -- Label follows the modifier x zone: Shift remaps the zones to Transition / Onset Ramp / Scoop
        local action_name
        if state.drag.shift_mode then
          action_name = (state.drag.zone == "pitch" and "Adjust Transition" or
                        (state.drag.zone == "drift" and "Adjust Onset Ramp" or "Adjust Scoop"))
        else
          action_name = (state.drag.zone == "pitch" and "Adjust Pitch" or
                        (state.drag.zone == "drift" and "Adjust Stability" or "Adjust Vibrato"))
        end
        local undo_title = count > 1 and string.format("%s (%d notes)", action_name, count) or action_name
        apply_envelope_to_take(undo_title)
      elseif state.drag.pending_single_select then
        -- Released without dragging: collapse multi-selection to clicked note
        state.selected_note = state.drag.pending_single_select
        state.selected_notes = { [state.drag.pending_single_select] = true }
      end
      state.drag = nil
      state.shift_mode = false
    end
  end

  -- Process active edge drag (trimming)
  if state.edge_drag then
    reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    local delta_x = mx - state.edge_drag.start_mouse_x
    if math.abs(delta_x) > 3 then -- horizontal dead zone
      state.edge_drag.dirty = true
      -- Convert the pixel delta to a time delta through the visible window
      local delta_time = x_to_t(mx) - x_to_t(state.edge_drag.start_mouse_x)
      local new_time = state.edge_drag.original_time + delta_time
      -- Live preview: update note boundary directly (no feature re-extraction during drag)
      local ed_note = state.notes[state.edge_drag.note_idx]
      if ed_note then
        if state.edge_drag.edge == "left" then
          -- Clamp: don't go past end_time - 50ms, don't overlap previous note
          local prev_note = state.notes[state.edge_drag.note_idx - 1]
          local min_t = prev_note and (prev_note.end_time + 0.005) or 0
          new_time = math.max(min_t, math.min(ed_note.end_time - 0.05, new_time))
          ed_note.start_time = new_time
        else
          -- Clamp: don't go before start_time + 50ms, don't overlap next note
          local next_note = state.notes[state.edge_drag.note_idx + 1]
          local max_t = next_note and (next_note.start_time - 0.005) or state.end_time
          new_time = math.max(ed_note.start_time + 0.05, math.min(max_t, new_time))
          ed_note.end_time = new_time
        end
      end
    end

    -- End edge drag → commit trim
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.edge_drag.dirty then
        local ed = state.edge_drag
        local ed_note = state.notes[ed.note_idx]
        -- Capture the dragged-to position before restoring original boundary
        local target_time = (ed.edge == "left") and ed_note.start_time or ed_note.end_time
        -- Restore original boundary so trim_note_edge can detect extend vs shrink
        if ed.edge == "left" then
          ed_note.start_time = ed.original_time
        else
          ed_note.end_time = ed.original_time
        end
        trim_note_edge(ed.note_idx, ed.edge, target_time)
      else
        -- No movement beyond dead zone — restore boundary in case of micro-drift
        local ed = state.edge_drag
        local ed_note = state.notes[ed.note_idx]
        if ed_note then
          if ed.edge == "left" then
            ed_note.start_time = ed.original_time
          else
            ed_note.end_time = ed.original_time
          end
        end
      end
      state.edge_drag = nil
    end
  end

  -- Process active marquee box select (Milestone 4)
  if state.marquee then
    local delta_x = mx - state.marquee.start_x
    local delta_y = my - state.marquee.start_y

    if not state.marquee.active then
      if math.abs(delta_x) > 3 or math.abs(delta_y) > 3 then
        state.marquee.active = true
      end
    end

    if state.marquee.active then
      state.marquee.cur_x = mx
      state.marquee.cur_y = my

      local bx1 = math.min(state.marquee.start_x, state.marquee.cur_x)
      local bx2 = math.max(state.marquee.start_x, state.marquee.cur_x)
      local by1 = math.min(state.marquee.start_y, state.marquee.cur_y)
      local by2 = math.max(state.marquee.start_y, state.marquee.cur_y)

      local new_sel = {}
      if state.marquee.has_shift and state.marquee.init_sel then
        for k, v in pairs(state.marquee.init_sel) do
          new_sel[k] = v
        end
      end

      if state.notes then
        for n_idx, note in ipairs(state.notes) do
          if note.controls then
            local cp = note.controls.center_pitch
            local sx = t_to_x(note.start_time)
            local ex = t_to_x(note.end_time)
            local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
            local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h

            -- AABB intersection check
            if sx <= bx2 and ex >= bx1 and top_y <= by2 and bot_y >= by1 then
              new_sel[n_idx] = true
            end
          end
        end
      end

      state.selected_notes = new_sel

      -- Maintain valid primary selected note
      if not (state.selected_note and state.selected_notes[state.selected_note]) then
        local first_idx = nil
        if state.notes then
          for idx = 1, #state.notes do
            if state.selected_notes[idx] then
              first_idx = idx
              break
            end
          end
        end
        state.selected_note = first_idx
      end
    end

    -- End marquee
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if not state.marquee.active then
        -- Clicked on empty canvas without dragging: deselect and move edit cursor
        if not state.marquee.has_shift then
          state.selected_note = nil
          state.selected_notes = {}
        end
        local item_time = x_to_t(math.max(px, math.min(px + w, state.marquee.start_x)))
        local _, item = K.frame_target()
        if item then
          local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          reaper.SetEditCurPos(item_pos + item_time, false, false)
        end
      end
      state.marquee = nil
    end
  end

  -- HC5: Esc during a drag, edge drag or box selection cancels it: every value goes back to what it was when the
  -- gesture began and nothing is written (no envelope, no undo point). The canvas button stays active until the
  -- mouse is released, so the window-level Esc handler in loop_body (which skips active items) never sees this press.
  if (state.drag or state.edge_drag or state.marquee) and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
    K.cancel_gesture()
    gesture = nil
  end

  ---------------------------------------------------------------------------
  -- KEYBOARD CONTROLS (Scalpel Workflow)
  ---------------------------------------------------------------------------
  -- Guard: skip keyboard shortcuts if any widget (combo, input, slider)
  -- is active — prevents arrow keys from leaking into toolbar combos.
  local ok_aia, any_active = pcall(reaper.ImGui_IsAnyItemActive, draw_ctx)
  local widget_capturing = ok_aia and any_active

  -- Shortcuts do nothing while a modal / combo / context menu is open or the window is not focused (EP6).
  -- Every key goes through Shortcut(): exact modifiers, no repeat unless InputFlags_Repeat is passed, so
  -- Cmd/Ctrl+S never snaps and a held command key fires once.
  local shortcuts_live = not widget_capturing
    and not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
    and reaper.ImGui_IsWindowFocused(draw_ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())

  -- A bypassed take is not edited at all: neither by the mouse (gated above) nor by the keys
  if not state.drag and not state.edge_drag and shortcuts_live and not is_bypassed and state.notes and #state.notes > 0 then
    local shift_mod = reaper.ImGui_Mod_Shift()
    local repeat_flag = reaper.ImGui_InputFlags_Repeat()

    -- Cmd/Ctrl + A: Select All notes (Milestone 4)
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_A()) then
      state.selected_notes = {}
      for i = 1, #state.notes do
        state.selected_notes[i] = true
      end
      if not state.selected_note or not state.selected_notes[state.selected_note] then
        state.selected_note = 1
      end
    end

    -- Esc is routed once, innermost first, by the window-level handler in loop_body (HC5).

    -- Up / Down: Nudge pitch (±1 semitone, or ±10 cents with Shift)
    local has_selection = (state.selected_note and state.notes[state.selected_note])
      or (next(state.selected_notes) ~= nil)
    if has_selection then
      local sel = state.selected_note and state.notes[state.selected_note]

      -- Only the preview moves on each (repeating) press; the envelope write and the undo point
      -- are committed once per burst by service_nudge_burst() when the key is released.
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_UpArrow(), repeat_flag) then
        nudge_selected_notes(1.0, "up")
      elseif reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_UpArrow(), repeat_flag) then
        nudge_selected_notes(0.10, "up")
      end

      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_DownArrow(), repeat_flag) then
        nudge_selected_notes(-1.0, "down")
      elseif reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_DownArrow(), repeat_flag) then
        nudge_selected_notes(-0.10, "down")
      end

      -- S: Snap to nearest semitone (the status line reports it, as for the dock's Snap button)
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_S()) then
        K.note_action("snap")
      end

      -- Q: Quantize selected note(s) to active scale (Milestone 3)
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Q()) then
        K.note_action("quantize")
      end

      -- R / Backspace / Delete: Reset to [Untouched]
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_R())
        or reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Backspace())
        or reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Delete()) then
        K.request_reset(K.count_selected_notes(), #state.notes)   -- same status (and confirm) as the header Reset
      end

      -- X: Split note at edit cursor position (outside the note it says so)
      if sel and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_X()) then
        K.note_action("split", state.selected_note)
      end
    end

    -- M: Merge selected notes (requires 2+ contiguous selected; with fewer it says so)
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_M()) then
      K.note_action("merge")
    end

    -- Left / Right: Jump or range-extend (Shift) selection to previous / next note
    local left_plain = reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_LeftArrow(), repeat_flag)
    local left_extend = reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_LeftArrow(), repeat_flag)
    if left_plain or left_extend then
      if left_extend and state.selected_note and state.selected_note > 1 then
        state.selected_note = state.selected_note - 1
        state.selected_notes[state.selected_note] = true
      elseif state.selected_note and state.selected_note > 1 then
        state.selected_note = state.selected_note - 1
        state.selected_notes = { [state.selected_note] = true }
      elseif not state.selected_note then
        state.selected_note = 1
        state.selected_notes = { [1] = true }
      end
    end

    local right_plain = reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_RightArrow(), repeat_flag)
    local right_extend = reaper.ImGui_Shortcut(draw_ctx, shift_mod | reaper.ImGui_Key_RightArrow(), repeat_flag)
    if right_plain or right_extend then
      if right_extend and state.selected_note and state.selected_note < #state.notes then
        state.selected_note = state.selected_note + 1
        state.selected_notes[state.selected_note] = true
      elseif state.selected_note and state.selected_note < #state.notes then
        state.selected_note = state.selected_note + 1
        state.selected_notes = { [state.selected_note] = true }
      elseif not state.selected_note then
        state.selected_note = 1
        state.selected_notes = { [1] = true }
      end
    end

    -- Space is forwarded to the user's own REAPER binding by forward_space_to_reaper() in loop_body (HC6).
  end

  -- Double-click pitch zone: Snap to nearest semitone (single or batch)
  if is_canvas_hovered and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
    if state.hovered_note and state.hovered_zone == "pitch" then
      if not state.selected_notes[state.hovered_note] then
        state.selected_note = state.hovered_note
        state.selected_notes = { [state.hovered_note] = true }
      end
      K.note_action("snap")
    end
  end

  -- The mapping is final (zoom, scroll and the gesture's frozen pitch range are applied): the cached coordinate arrays
  -- below are valid only for this one
  K.canvas_cache_begin(px, py, w, h, vt0, vt1, min_note, note_range)

  ---------------------------------------------------------------------------
  -- DRAW NOTE GRID & PIANO ROLL (IN-SCALE TINTING & OUT-OF-SCALE DIMMING)
  ---------------------------------------------------------------------------
  local root_pc = (state.key_idx - 1) % 12
  local is_chromatic = (SCALE_DEFINITIONS[state.scale_idx].name == "Chromatic")

  for n = math.floor(min_note), math.ceil(max_note) do
    local y = py + h - ((n - min_note) / note_range) * h
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local is_black_key = (n % 12 == 1 or n % 12 == 3 or n % 12 == 6
                          or n % 12 == 8 or n % 12 == 10)
    local pc = (n % 12 + 12) % 12
    local in_scale = is_pitch_in_scale(pc)
    local is_root = (pc == root_pc)

    -- 1. Canvas row background & grid line
    local row_bg
    local row_tint = nil
    local grid_color

    if is_chromatic then
      row_bg = is_black_key and C.row_plain_black or C.row_plain
      grid_color = is_black_key and C.grid_plain_black or C.grid_plain
    elseif in_scale then
      if is_root then
        -- Tonic/Root note row: subtle theme accent tint
        row_bg = C.row_tonic
        row_tint = C.row_tonic_tint
        grid_color = C.grid_tonic
      else
        -- In-scale note row: subtle theme tinting
        row_bg = is_black_key and C.row_black or C.row
        row_tint = C.row_tint
        grid_color = C.grid
      end
    else
      -- Out-of-scale note row: dimmed
      row_bg = is_black_key and C.row_dim_black or C.row_dim
      grid_color = C.grid_dim
    end

    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_bg)
    if row_tint then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_tint)
    end
    reaper.ImGui_DrawList_AddLine(draw_list, px, y, px + w, y, grid_color)

    -- 2. Piano roll keys
    local key_color
    local text_col

    -- Label colours (WCAG 2.x on the key): every label that is drawn is >= 4.5:1 (each key_text_* token is fitted on its key)
    if is_chromatic then
      key_color = is_black_key and C.key_plain_black or C.key_white
      text_col = is_black_key and C.key_text_plain_black or C.key_text_plain_white
    elseif in_scale then
      if is_root then
        key_color = is_black_key and C.key_tonic_black or C.key_tonic_white
        text_col = is_black_key and C.key_text_tonic_black or C.key_text_tonic_white
      else
        key_color = is_black_key and C.key_black or C.key_white
        text_col = is_black_key and C.key_text_black or C.key_text_white
      end
    else
      -- Out-of-scale keys dimmed; only their C is labelled (below)
      key_color = is_black_key and C.key_dim_black or C.key_dim_white
      text_col = is_black_key and C.key_text_dim_black or C.key_text_dim_white
    end

    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, key_top, full_px + piano_w, key_bot, key_color)
    reaper.ImGui_DrawList_AddRect(draw_list, full_px, key_top, full_px + piano_w, key_bot, C.key_outline)

    -- Accent indicator strip for root key
    if not is_chromatic and is_root then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px + piano_w - K.TONIC_STRIP_W, key_top, full_px + piano_w, key_bot, C.key_tonic_strip)
    end

    -- Every in-scale key is labelled while a row is at least a text line tall; below that only the C keys are, so
    -- labels never overlap. Out-of-scale keys are dimmed: they carry a label on C only (orientation)
    if (px_per_st >= line_h or n % 12 == 0) and (in_scale or pc == 0) then
      local label = midi_to_name(n)
      local text_y = (key_top + key_bot) * 0.5 - line_h * 0.5
      reaper.ImGui_DrawList_AddText(draw_list, full_px + L.xs, text_y, text_col, label)
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE BLOCKS (interactive, positioned by center_pitch)
  ---------------------------------------------------------------------------
  -- Note labels are collected here and drawn after the curves (HC1: a curve never crosses the text)
  local note_labels = {}
  if state.show_note_blocks and state.notes then
    for n_idx, note in ipairs(state.notes) do
      -- Only blocks that reach the visible window are drawn
      if note.controls and note.end_time >= vt0 and note.start_time <= vt1 then
        local cp = note.controls.center_pitch
        local sx = t_to_x(note.start_time)
        local ex = t_to_x(note.end_time)
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h
        local block_w = ex - sx
        local zone_w = math.max(K.ZONE_MIN_W, block_w * 0.25)

        local is_selected = state.selected_notes[n_idx] or false
        local is_hov = (state.hovered_note == n_idx)
        local is_mod = is_note_modified(note)

        local is_bypassed_note = note.controls.bypassed or false
        local fill
        local border
        if is_bypassed_note then
          fill = C.note_bypassed
          border = C.note_bypassed_mark   -- outline and strike: >= 3:1 on the rows while the fill stays dim
        elseif is_selected then
          fill = is_mod and C.note_selected_edited or C.note_selected
          border = C.note_selected_border
        elseif is_mod then
          fill = C.note_edited   -- Green for edited notes (and the corner square below)
          border = C.note_edited_border
        else
          fill = C.note_fill     -- Muted blue for untouched notes, its border >= 3:1 on every row
          border = C.note_border
        end

        -- Zone-colored hover highlights
        if is_hov and not state.drag then
          local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
          local ok_mods, cur_mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
          local has_shift = ok_mods and cur_mods and (cur_mods & shift_mod) ~= 0

          if state.hovered_zone == "drift" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, sx + zone_w, bot_y, has_shift and C.zone_shift or C.zone_drift)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx + zone_w, top_y, ex, bot_y, fill)
          elseif state.hovered_zone == "vibrato" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex - zone_w, bot_y, fill)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              ex - zone_w, top_y, ex, bot_y, C.zone_shift)
          else -- pitch zone
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex, bot_y, fill)
            if has_shift then
              reaper.ImGui_DrawList_AddRectFilled(draw_list,
                sx + zone_w, top_y, ex - zone_w, bot_y, C.zone_shift)
            end
          end

          if has_shift and block_w > K.ZONE_PILLS_MIN_W then
            -- The zone names sit on a pill: the text over the amber zone highlight alone is not enough. All three are
            -- drawn when each fits its zone (the pills never overlap); on a narrower block only the name of the zone
            -- under the pointer is (the hover hint names it at any width)
            -- The pill (a text line + L.xs above and below) centred on the block
            local text_y = (top_y + bot_y) * 0.5 - line_h * 0.5 - L.xs
            local onset, transition, scoop = PARAM_LABELS.onset_ramp_ms, PARAM_LABELS.transition_ms, PARAM_LABELS.scoop_shape
            if pill_fits(onset, zone_w) and pill_fits(transition, block_w - zone_w * 2)
                and pill_fits(scoop, zone_w) then
              pill_text(sx + L.xs, text_y, onset, C.pill_text)
              pill_text(sx + zone_w + L.xs, text_y, transition, C.pill_text)
              pill_text(ex - zone_w + L.xs, text_y, scoop, C.pill_text)
            elseif state.hovered_zone == "drift" then
              pill_text(sx + L.xs, text_y, onset, C.pill_text)
            elseif state.hovered_zone == "vibrato" then
              pill_text(ex - zone_w + L.xs, text_y, scoop, C.pill_text)
            else
              pill_text(sx + zone_w + L.xs, text_y, transition, C.pill_text)
            end
          end
        else
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx, top_y, ex, bot_y, fill)
        end

        -- Border (thicker for selected notes)
        reaper.ImGui_DrawList_AddRect(draw_list,
          sx, top_y, ex, bot_y, border, 0, 0, is_selected and 2.0 or 1.0)

        if is_bypassed_note then
          local mid_y = top_y + (bot_y - top_y) * 0.5
          reaper.ImGui_DrawList_AddLine(draw_list, sx, mid_y, ex, mid_y, border, 1.5)
        end

        -- Zone divider lines on hover/select
        if is_hov or is_selected then
          reaper.ImGui_DrawList_AddLine(draw_list,
            sx + zone_w, top_y, sx + zone_w, bot_y, C.zone_divider)
          reaper.ImGui_DrawList_AddLine(draw_list,
            ex - zone_w, top_y, ex - zone_w, bot_y, C.zone_divider)

          -- Edge trim handles (visible grab zones). C.handle is >= 3:1 against every note fill, row and zone highlight at
          -- rest; the hovered edge goes opaque (C.handle_hover)
          local handle_w = K.HANDLE_W
          local left_handle_col = C.handle
          local right_handle_col = C.handle

          -- Brighten the hovered edge
          if state.hovered_edge and state.hovered_edge.note_idx == n_idx then
            if state.hovered_edge.edge == "left" then
              left_handle_col = C.handle_hover
            else
              right_handle_col = C.handle_hover
            end
          end

          -- During edge drag, brighten the active edge
          if state.edge_drag and state.edge_drag.note_idx == n_idx then
            if state.edge_drag.edge == "left" then
              left_handle_col = C.handle_drag
            else
              right_handle_col = C.handle_drag
            end
          end

          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx - 1, top_y, sx + handle_w, bot_y, left_handle_col)
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            ex - handle_w, top_y, ex + 1, bot_y, right_handle_col)
        end

        -- An edited note also carries a small square (C.note_edit_mark) in its top-left corner (not green alone); the label moves over
        local label_x = math.max(sx, px) + L.sm   -- stays readable while the block runs past the left edge
        if is_mod then
          local mark = math.min(K.EDIT_MARK, bot_y - top_y - L.xs * 2, block_w - L.sm * 2)
          if mark >= L.xs then
            reaper.ImGui_DrawList_AddRectFilled(draw_list, label_x, top_y + L.xs, label_x + mark, top_y + L.xs + mark, C.note_edit_mark)
            label_x = label_x + mark + L.xs
          end
        end

        -- Note label: name + cents deviation. Each label token is fitted to >= 4.5:1 over its note fill. It must fit
        -- the block (LG4): the cents go first, then the name; a block too short for the name shows no label
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        local name = midi_to_name(nearest)
        local room = math.min(ex, px + w) - L.xs - label_x
        local label = string.format("%s %s%d\xC2\xA2", name, sign, cents)
        if (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) > room then label = name end
        if (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) <= room then
          note_labels[#note_labels + 1] = {
            x = label_x,
            y = (top_y + bot_y) * 0.5 - line_h * 0.5,
            color = is_mod and C.note_label_edited or (is_selected and C.note_label_selected or C.note_label),
            text = label,
          }
        end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW SPLIT POINTS
  ---------------------------------------------------------------------------
  if state.show_split_points and state.split_points then
    for _, sp in ipairs(state.split_points) do
      if sp.time >= vt0 and sp.time <= vt1 then
        local x = t_to_x(sp.time)
        reaper.ImGui_DrawList_AddLine(draw_list, x, py, x, py + h, C.marker_split, 1.0)   -- blue: red is for clip / destructive only
        -- The label sits below the time ruler, which covers the top of the note area
        reaper.ImGui_DrawList_AddText(draw_list, x + L.xs, py + ruler_h + L.xs, C.marker_split_text, sp.reason)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW RAW PITCH CURVE (purple)
  ---------------------------------------------------------------------------
  if state.show_raw_pitch then
    -- Only the part of the curve that reaches the visible window; unvoiced gaps at either end are skipped so
    -- the line still runs to the canvas edge
    local r0, r1 = visible_range(state.results)
    while r0 > 1 and not state.results[r0].note do r0 = r0 - 1 end
    while r1 < #state.results and not state.results[r1].note do r1 = r1 + 1 end
    local polyline = K.raw_trace(state.results, r0, r1, t_to_x)   -- cached, see K.raw_trace
    if polyline then
      reaper.ImGui_DrawList_AddPolyline(draw_list, polyline, C.trace, 0, 2.0)
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW TREND, SMART SPOTS, VIBRATO REGIONS & CORRECTED PITCH PREVIEW
  ---------------------------------------------------------------------------
  if state.notes then
    for _, note in ipairs(state.notes) do
      -- The frames of this note that reach the visible window (f0 > f1: none)
      local f0, f1 = 1, 0
      if note.frames then f0, f1 = visible_range(note.frames) end

      -- Vibrato regions (amber bands where vibrato was detected)
      if state.show_vibrato_regions and note.vibrato_weight and note.frames then
        local in_region = false
        local region_start_x = 0
        for i = f0, f1 do
          local frame = note.frames[i]
          local is_vib = note.vibrato_weight[i] > 0.3
          local x = t_to_x(frame.time)
          if is_vib and not in_region then
            region_start_x = x
            in_region = true
          elseif not is_vib and in_region then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              region_start_x, py, x, py + h, C.vibrato)
            in_region = false
          end
        end
        -- Close trailing region
        if in_region then
          local last_x = t_to_x(note.frames[f1].time)
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            region_start_x, py, last_x, py + h, C.vibrato)
        end
      end

      -- Trend line (cyan)
      if state.show_trend and note.trend and f1 > f0 then
        reaper.ImGui_DrawList_AddPolyline(draw_list, K.note_trend(note, f0, f1, t_to_x), C.trend, 0, 1.0)
      end

      -- Smart spots: yellow circles (peaks / valleys) and cyan diamonds (the trend's anchors): shape, not colour alone
      if state.show_smart_spots and note.smart_spots then
        for _, spot in ipairs(note.smart_spots) do
          if spot.time >= vt0 and spot.time <= vt1 then
            local x = t_to_x(spot.time)
            local raw_pitch = note.frames[spot.index].note
            local y = py + h - ((raw_pitch - min_note) / note_range) * h

            if spot.type == "anchor_start" or spot.type == "anchor_end" then
              local r = K.ANCHOR_R
              reaper.ImGui_DrawList_AddQuadFilled(draw_list, x, y - r, x + r, y, x, y + r, x - r, y, C.anchor)
            else
              reaper.ImGui_DrawList_AddCircleFilled(draw_list, x, y, K.SPOT_R, C.spot)
            end
          end
        end
      end

      -- Corrected pitch preview line (green) — rendered for modified notes (not bypassed)
      if state.show_preview and f1 > f0 and is_note_modified(note) and not (note.controls.bypassed)
          and note.controls and note.trend and note.modulation then
        reaper.ImGui_DrawList_AddPolyline(draw_list, K.note_preview(note, f0, f1, t_to_x), C.preview, 0, 2.0)
      end
    end
  end

  -- The note labels, above every curve and marker (HC1)
  for _, lb in ipairs(note_labels) do
    reaper.ImGui_DrawList_AddText(draw_list, lb.x, lb.y, lb.color, lb.text)
  end

  ---------------------------------------------------------------------------
  -- DRAW MARQUEE SELECTION BOX (Milestone 4)
  ---------------------------------------------------------------------------
  if state.marquee and state.marquee.active then
    local bx1 = math.max(px, math.min(state.marquee.start_x, state.marquee.cur_x))
    local by1 = math.max(py, math.min(state.marquee.start_y, state.marquee.cur_y))
    local bx2 = math.min(px + w, math.max(state.marquee.start_x, state.marquee.cur_x))
    local by2 = math.min(py + h, math.max(state.marquee.start_y, state.marquee.cur_y))

    if bx2 > bx1 and by2 > by1 then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, bx1, by1, bx2, by2, C.marquee_fill)
      reaper.ImGui_DrawList_AddRect(draw_list, bx1, by1, bx2, by2, C.marquee_border, 0, 0, 1.5)

      local m_count = 0
      for _ in pairs(state.selected_notes) do m_count = m_count + 1 end
      if m_count > 0 then
        -- On a pill (kept inside the note area, below the time ruler): C.marquee_text is fitted to >= 4.5:1 there
        pill_text(bx2 + L.sm, by2 - line_h - L.xs * 2, string.format("%d selected", m_count), C.marquee_text)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW TIME RULER (overlay along the top of the note area, not the piano column)
  ---------------------------------------------------------------------------
  do
    local span = vt1 - vt0
    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + ruler_h, C.ruler_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, px, py + ruler_h, px + w, py + ruler_h, P.border)

    -- Smallest 1-2-5 x 10^n number of seconds that is at least t_min
    local function nice_step(t_min)
      local base = 10 ^ math.floor(math.log(t_min, 10))
      local ratio = t_min / base
      return base * (ratio <= 1 and 1 or (ratio <= 2 and 2 or (ratio <= 5 and 5 or 10)))
    end
    -- "12.5s" while the window ends before a minute, "1:05.5" from then on
    local show_minutes = (vt1 - item_t0) >= 60
    local function time_label(t, decimals)
      local scale = math.floor(10 ^ decimals + 0.5)
      local ticks = math.floor(math.max(t, 0) * scale + 0.5)
      local whole = ticks // scale
      local fraction = decimals > 0 and string.format(".%0" .. decimals .. "d", ticks % scale) or ""
      if show_minutes then
        return string.format("%d:%02d", whole // 60, whole % 60) .. fraction
      end
      return string.format("%d", whole) .. fraction .. "s"
    end

    -- The major step: the smallest one whose labels fit side by side (starting from one digit per step)
    local digit_w = reaper.ImGui_CalcTextSize(draw_ctx, "0") or 0
    local interval = nice_step(span * math.max(digit_w, 1) / math.max(w, 1))
    local decimals = 0
    for attempt = 1, K.RULER_MAX_TRIES do
      decimals = interval >= 1 and 0 or math.ceil(-math.log(interval, 10) - K.VIEW_EPS_S)
      local widest = reaper.ImGui_CalcTextSize(draw_ctx, time_label(vt1 - item_t0, decimals)) or 0
      if interval / span * w >= widest + L.md or attempt == K.RULER_MAX_TRIES then break end
      interval = nice_step(interval * K.RULER_WIDEN)
    end

    -- Ticks: a label and a full-height tick at every major step, a short tick at every minor one. A label
    -- that would touch the previous one (or leave the note area) is dropped, so labels never overlap.
    local minor = interval / K.RULER_MINOR_DIV
    local label_y = py + L.xs
    local next_free_x = px
    for m = math.ceil((vt0 - item_t0) / minor - K.VIEW_EPS_S), math.floor((vt1 - item_t0) / minor + K.VIEW_EPS_S) do
      local t = item_t0 + m * minor
      local x = t_to_x(t)
      if m % K.RULER_MINOR_DIV == 0 then
        reaper.ImGui_DrawList_AddLine(draw_list, x, py, x, py + ruler_h, P.text_dim)
        local label = time_label(t - item_t0, decimals)
        local label_w = reaper.ImGui_CalcTextSize(draw_ctx, label) or 0
        local label_x = x + L.sm
        if label_x >= next_free_x and label_x + label_w <= px + w then
          reaper.ImGui_DrawList_AddText(draw_list, label_x, label_y, P.text_dim, label)
          next_free_x = label_x + label_w + L.md
        end
      else
        reaper.ImGui_DrawList_AddLine(draw_list, x, py + ruler_h - L.sm, x, py + ruler_h, P.border)
      end
    end

    if on_ruler and canvas_tip_ready and state.view_t0 and not gesture then   -- waits for the hover delay (RB15)
      Theme.tooltip(draw_ctx, "Double-click to show the whole item")
    end
  end

  ---------------------------------------------------------------------------
  -- DRAG READOUT (a pill on the canvas) and HOVER HINT (a tooltip)
  ---------------------------------------------------------------------------
  if state.drag and state.drag.dirty then
    local d_note = state.notes[state.drag.anchor_idx or state.drag.note_idx]
    if d_note and d_note.controls then
      local count = 0
      for _ in pairs(state.drag.orig_values or {}) do count = count + 1 end
      local count_suffix = count > 1 and string.format("  (%d notes)", count) or ""
      local tip
      if state.drag.zone == "pitch" then
        local cp = d_note.controls.center_pitch
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        tip = string.format("%s %s%d\xC2\xA2%s",
          midi_to_name(nearest), sign, cents, count_suffix)
      elseif state.drag.zone == "drift" then
        tip = string.format("Stability: %.0f%%%s",
          (1 - d_note.controls.drift_scale) * 100, count_suffix)
      else
        tip = string.format("Vibrato: %.0f%%%s",
          d_note.controls.vibrato_scale * 100, count_suffix)
      end
      -- Beside the pointer, never outside the note area (nor over the piano keys or the ruler)
      pill_text(mx + L.xl, my - line_h * 0.5, tip, C.pill_text, L.xl * 2)
    end
  elseif canvas_tip_ready and state.hovered_note and not state.drag and not state.marquee then
    local h_note = state.notes[state.hovered_note]
    if h_note and h_note.controls then
      local tip
      local shift_mod = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
      local ok_mods, cur_mods = pcall(reaper.ImGui_GetKeyMods, draw_ctx)
      local has_shift = ok_mods and cur_mods and (cur_mods & shift_mod) ~= 0

      if has_shift then
        if state.hovered_zone == "drift" then
          local v = h_note.controls.onset_ramp_ms or get_effective(h_note, "onset_ramp_ms")
          tip = string.format("%s: %.0f ms (Shift + drag)", PARAM_LABELS.onset_ramp_ms, v)
        elseif state.hovered_zone == "vibrato" then
          local v = h_note.controls.scoop_shape or 0
          tip = string.format("%s: %.0f%% corrected (Shift + drag)", PARAM_LABELS.scoop_shape, v * 100)
        else
          local v = h_note.controls.transition_ms or get_effective(h_note, "transition_ms")
          tip = string.format("%s: %.0f ms (Shift + drag)", PARAM_LABELS.transition_ms, v)
        end
      else
        if state.hovered_zone == "drift" then
          tip = string.format("Stability: %.0f%%", (1 - h_note.controls.drift_scale) * 100)
        elseif state.hovered_zone == "vibrato" then
          tip = string.format("Vibrato: %.0f%%", h_note.controls.vibrato_scale * 100)
        else
          tip = string.format("Pitch: drag to move the note (%s-drag: fine adjust)", K.MOD_LABEL)
        end
      end
      Theme.tooltip(draw_ctx, tip)   -- the Show Tooltips preference applies
    end
  end
  ---------------------------------------------------------------------------
  -- PLAYHEAD CURSOR LINE
  ---------------------------------------------------------------------------
  local _, item_for_cursor = K.frame_target()
  if item_for_cursor then
    local item_pos = reaper.GetMediaItemInfo_Value(item_for_cursor, "D_POSITION")
    -- Use play position when playing, edit cursor when stopped
    local play_state = reaper.GetPlayState()
    local project_pos = (play_state & 1) ~= 0
      and reaper.GetPlayPosition()
      or  reaper.GetCursorPosition()
    local item_rel = project_pos - item_pos
    -- Only draw if cursor is within the item's time range and the visible window
    if item_rel >= state.start_time and item_rel <= state.end_time and item_rel >= vt0 and item_rel <= vt1 then
      local cursor_x = t_to_x(item_rel)
      reaper.ImGui_DrawList_AddLine(draw_list,
        cursor_x, py, cursor_x, py + h, C.playhead, 1.5)
    end
  end

  -- Bypassed Overlay: yellow (a state to get out of, not an error), with the way out as a button
  if is_bypassed then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, py, full_px + full_w, py + h, C.scrim)

    local txt_main = "BYPASSED"
    local sub_txt = "Pitch envelope is bypassed"
    local hint_txt = "Re-enable the envelope to edit"
    -- Every line is measured and drawn in the same font
    local pushed_bp_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
    local tw, th = reaper.ImGui_CalcTextSize(draw_ctx, txt_main)
    Theme.pop_font(draw_ctx, pushed_bp_font)
    local stw, sth = reaper.ImGui_CalcTextSize(draw_ctx, sub_txt)
    local htw, hth = reaper.ImGui_CalcTextSize(draw_ctx, hint_txt)

    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5
    local badge_w = math.max(tw, stw, htw) + L.xl * 2
    local badge_h = L.lg + th + L.xs + sth + hth + L.md + L.btn_lg.h + L.lg
    local bx1 = cx - badge_w * 0.5
    local by1 = cy - badge_h * 0.5
    local bx2 = cx + badge_w * 0.5
    local by2 = cy + badge_h * 0.5

    reaper.ImGui_DrawList_AddRectFilled(draw_list, bx1, by1, bx2, by2, P.card, L.rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, bx1, by1, bx2, by2, C.bypass_border, L.rounding, 0, 1.5)   -- yellow, >= 3:1 on the card and the dimmed canvas

    local line_y = by1 + L.lg
    pushed_bp_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
    reaper.ImGui_DrawList_AddText(draw_list, cx - tw * 0.5, line_y, C.bypass_title, txt_main)   -- yellow, >= 4.5:1 on the card
    Theme.pop_font(draw_ctx, pushed_bp_font)
    line_y = line_y + th + L.xs
    reaper.ImGui_DrawList_AddText(draw_list, cx - stw * 0.5, line_y, P.text, sub_txt)   -- P.text on the card 15.5:1 (P.text_dim was 3.8:1)
    line_y = line_y + sth
    reaper.ImGui_DrawList_AddText(draw_list, cx - htw * 0.5, line_y, P.text, hint_txt)
    line_y = line_y + hth + L.md

    if canvas_button("Enable", "cv_enable", cx, line_y, true, "Turn the item's pitch envelope back on") then
      toggle_take_pitch_bypass(target_take)
    end
  end

  -- Note Context Menu (Phase 4)
  if reaper.ImGui_BeginPopup(draw_ctx, "##note_context_menu") then
    -- HC5: Esc closes this menu, unless a popup opened from it (a typed-entry field) is open: that one is innermost
    if not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
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

      -- As wide as the longest value name, so the drags follow the font size
      reaper.ImGui_PushItemWidth(draw_ctx, (reaper.ImGui_CalcTextSize(draw_ctx, PARAM_LABELS.retune_speed)) or L.xxxl)

      local function draw_cm_slider(label, key, min_v, max_v, fmt, scale, default)
         local level = get_override_level(note, key)
         local cur_val = ctrl[key] or get_effective(note, key) or default or 0
         if scale then cur_val = cur_val * scale end

         -- param_drag tests the gestures right after the control (not after SameLine / TextDisabled, which would test the text)
         local name = PARAM_LABELS[key] or label
         local s_changed, new_val, committed, reset = param_drag(draw_ctx, "cm_" .. key, label, cur_val, min_v, max_v, fmt)
         if reset then
            -- Double-click: drop the per-note override so the note inherits again (one undo point)
            if ctrl[key] ~= nil then
               ctrl[key] = nil
               apply_envelope_to_take("Reset " .. name)
            end
         else
            if s_changed then
               if scale then new_val = new_val / scale end
               ctrl[key] = new_val
            end
            if committed then
               apply_envelope_to_take("Adjust " .. name)
            end
         end
         reaper.ImGui_SameLine(draw_ctx, 0, L.sm)
         reaper.ImGui_TextDisabled(draw_ctx, K.SCOPE_TAGS[level] or K.SCOPE_TAGS.global)   -- one scope style, as in the dock (CN4)
      end

      draw_cm_slider(PARAM_LABELS.onset_ramp_ms, "onset_ramp_ms", 5, 60, "%.0f ms", nil)
      draw_cm_slider(PARAM_LABELS.scoop_shape, "scoop_shape", 0, 100, "%.0f%%", 100)
      draw_cm_slider(PARAM_LABELS.transition_ms, "transition_ms", 5, 60, "%.0f ms", nil)
      draw_cm_slider(PARAM_LABELS.retune_speed, "retune_speed", 0, 100, "%.0f%%", 100)

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
      if reaper.ImGui_MenuItem(draw_ctx, "Reset to Original", "R") then
        K.request_reset(K.count_selected_notes(), #state.notes)   -- same status as the header Reset and the R key
      end
    end
    reaper.ImGui_EndPopup(draw_ctx)
  end

  restore_canvas_layout()
  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

local function strip_pitchenv_from_str(str)
  local s_start = str:find("<PITCHENV")
  if not s_start then return str end
  local depth = 0
  local pos = s_start
  local s_end = nil
  while pos <= #str do
    local b_start, b_end, tag = str:find("([<>])", pos)
    if not b_start then break end
    if tag == "<" then
      depth = depth + 1
    elseif tag == ">" then
      depth = depth - 1
      if depth == 0 then
        if str:sub(b_end + 1, b_end + 2) == "\r\n" then
          s_end = b_end + 2
        elseif str:sub(b_end + 1, b_end + 1) == "\n" then
          s_end = b_end + 1
        else
          s_end = b_end
        end
        break
      end
    end
    pos = b_end + 1
  end

  if s_end then
    return str:sub(1, s_start - 1) .. str:sub(s_end + 1)
  end
  return str
end

local function remove_take_pitch_envelope_chunk(item, take_guid)
  if not item then return end
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or not chunk or not chunk:find("<PITCHENV") then return end

  local num_takes = reaper.CountTakes(item)
  if num_takes <= 1 or not take_guid then
    local new_chunk = strip_pitchenv_from_str(chunk)
    reaper.SetItemStateChunk(item, new_chunk, false)
    return
  end

  -- Multi-take item: split chunk at "\nTAKE" boundaries
  local sections = {}
  local last_pos = 1
  while true do
    local t_start = chunk:find("\nTAKE", last_pos)
    if not t_start then
      table.insert(sections, chunk:sub(last_pos))
      break
    end
    table.insert(sections, chunk:sub(last_pos, t_start))
    last_pos = t_start + 1
  end

  local modified = false
  for i, sec in ipairs(sections) do
    if sec:find(take_guid, 1, true) then
      local new_sec = strip_pitchenv_from_str(sec)
      if new_sec ~= sec then
        sections[i] = new_sec
        modified = true
      end
      break
    end
  end

  if modified then
    local new_chunk = table.concat(sections, "")
    reaper.SetItemStateChunk(item, new_chunk, false)
  end
end

--- True when the take's pitch algorithm is the one this script writes (state.pitchmode_value), i.e. a
--- reset to the project default only undoes the script's own change and never a value the user chose.
local function script_set_pitch_mode(take)
  if not take or state.pitchmode_value == -1 then return false end
  local current = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
  return current ~= nil and current == state.pitchmode_value
end

--- Remove one item from Pitched Items and clear the script's data on it. Writes to REAPER but opens no
--- undo block: the caller owns it (remove_take_from_session for one item, wipe_entire_session for all).
--- Returns the item name and whether the item was found in the project.
local function remove_take_core(guid)
  local data = state.session_takes[guid]
  local take_name = (data and data.name) or "Item"
  local take_obj = resolve_take_by_guid(guid)

  -- A pending arrow-key nudge on the removed take is discarded with it
  if state.nudge_burst and state.nudge_burst.guid == guid then state.nudge_burst = nil end

  if take_obj then
    local item = reaper.GetMediaItemTake_Item(take_obj)

    -- 1. Wipe all pitch envelope points and automation items first
    local env = reaper.GetTakeEnvelopeByName(take_obj, "Pitch")
    if env then
      local ai_count = reaper.CountAutomationItems(env)
      for a = ai_count - 1, 0, -1 do
        reaper.DestroyAutomationItem(env, a)
      end
      reaper.DeleteEnvelopePointRange(env, -1000000, 1000000)
      reaper.Envelope_SortPoints(env)
    end

    -- 2. Completely remove the <PITCHENV> block from the media item chunk
    if item then
      remove_take_pitch_envelope_chunk(item, guid)
    end

    -- 3. Return the pitch shift mode to the project default (-1), but only when it is the value this
    --    script wrote. The take's own pitch offset (D_PITCH) is the user's and is never touched.
    if script_set_pitch_mode(take_obj) then
      reaper.SetMediaItemTakeInfo_Value(take_obj, "I_PITCHMODE", -1)
    end

    -- 4. Purge persistent project metadata on this take
    reaper.GetSetMediaItemTakeInfo_String(take_obj, K.TAKE_DATA_KEY, "", true)

    if item then
      reaper.UpdateItemInProject(item)
    end
    reaper.UpdateArrange()
  end

  -- 5. Remove from session cache and order
  state.session_takes[guid] = nil
  state.raw_cache[guid] = nil
  state.missing_takes[guid] = nil
  state.stale_takes[guid] = nil
  state.unreadable_takes[guid] = nil
  for idx, g in ipairs(state.session_order) do
    if g == guid then
      table.remove(state.session_order, idx)
      break
    end
  end

  -- 6. If active target was this take, switch to next take or reset to empty
  if state.target_take_guid == guid then
    if #state.session_order > 0 then
      local next_guid = state.session_order[1]
      local next_take = resolve_take_by_guid(next_guid)
      switch_active_target(next_guid, next_take)
    else
      state.target_take_guid = nil
      state.target_take_name = nil
      state.results = {}
      state.notes = nil
      state.analysis_empty = false
      state.selected_note = nil
      state.selected_notes = {}
      state.hovered_note = nil
      state.drag = nil
      state.marquee = nil
      state.view_t0, state.view_t1 = nil, nil
      state.start_time = nil
      state.end_time = nil
      state.item_len = nil
      state.sample_rate = nil
    end
  end

  return take_name, take_obj ~= nil
end

--- Remove one take (sidebar X, after the user confirmed): one undo block.
--- Returns the take name and whether the take was found in the project.
local function remove_take_from_session(guid)
  if not guid then return nil, false end

  reaper.Undo_BeginBlock()
  local take_name, found = remove_take_core(guid)
  reaper.Undo_EndBlock(string.format("Remove %s from Pitched Items", take_name), -1)
  note_own_write()
  return take_name, found
end

--- Wipe every item of the session (after the user confirmed) as ONE undo point.
--- Returns the number of items removed.
local function wipe_entire_session()
  local order_copy = {}
  for _, guid in ipairs(state.session_order) do
    table.insert(order_copy, guid)
  end
  local n = #order_copy
  if n == 0 then return 0 end

  reaper.Undo_BeginBlock()
  for _, guid in ipairs(order_copy) do
    remove_take_core(guid)
  end
  -- Every item's envelope was cleared above; only the in-memory analysis is left to drop
  reset_analysis_model()
  state.session_takes = {}
  state.session_order = {}
  state.raw_cache = {}
  state.missing_takes = {}
  state.stale_takes = {}
  reaper.Undo_EndBlock(string.format("Wipe Pitched Items (%d)", n), -1)
  note_own_write()
  return n
end

--- True when the take has a pitch envelope or a stored model to clear (so clearing writes to the project).
local function take_has_clearable_data(take)
  if not take then return false end
  return reaper.GetTakeEnvelopeByName(take, "Pitch") ~= nil or read_take_raw(take) ~= ""
end

--- Clear one take's analysis and pitch envelope points as ONE undo point: the envelope points, the P_EXT
--- model and the session entry go together, so Cmd/Ctrl+Z restores them together (the resync in
--- sync_with_project re-adopts the model when the P_EXT returns).
--- Returns the number of notes cleared and whether an undo point was written.
local function clear_take_analysis(guid)
  if not guid then return 0, false end
  local data = state.session_takes[guid]
  local note_count = (guid == state.target_take_guid and state.notes and #state.notes)
    or (data and data.notes and #data.notes) or 0
  local take = resolve_take_by_guid(guid, true)
  local item = take and reaper.GetMediaItemTake_Item(take)
  local wrote = false

  if take then
    local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
    if take_has_clearable_data(take) then
      wrote = true
      reaper.Undo_BeginBlock()
      if env and item then
        reaper.DeleteEnvelopePointRange(env, 0, reaper.GetMediaItemInfo_Value(item, "D_LENGTH") + 1.0)
        reaper.Envelope_SortPointsEx(env, -1)
      end
      reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, "", true)
      if item then reaper.UpdateItemInProject(item) end
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Clear Pitch Analysis and Envelope", -1)
      note_own_write()
    end
  end

  -- The model goes with the take data (the row leaves Pitched Items until it is analysed again)
  state.session_takes[guid] = nil
  state.raw_cache[guid] = nil
  state.missing_takes[guid] = nil
  state.stale_takes[guid] = nil
  state.unreadable_takes[guid] = nil
  for idx, g in ipairs(state.session_order) do
    if g == guid then
      table.remove(state.session_order, idx)
      break
    end
  end
  if guid == state.target_take_guid then
    reset_analysis_model()
  end
  return note_count, wrote
end

--- Number of session items whose pitch algorithm a removal would return to the project default.
local function count_pitch_mode_resets(guids)
  local n = 0
  for _, g in ipairs(guids) do
    if script_set_pitch_mode(resolve_take_by_guid(g)) then n = n + 1 end
  end
  return n
end

local function plural(n, one, many)
  return n == 1 and one or many
end

--- Sidebar X: confirm before removing one item (names the item and every consequence).
local function request_remove_confirm(guid)
  local data = state.session_takes[guid]
  local name = (data and data.name) or "Item"
  local resets_mode = count_pitch_mode_resets({ guid }) > 0
  local lines = {
    string.format("This removes \"%s\" from Pitched Items, deletes its pitch envelope points and clears its saved analysis.", name),
  }
  if resets_mode then
    lines[#lines + 1] = "Its pitch algorithm returns to the project default."
  end
  request_confirm({
    id = "remove_take",
    title = string.format("Remove %s?", name),
    body_lines = lines,
    confirm_label = "Remove",
    on_confirm = function()
      local _, found = remove_take_from_session(guid)
      -- Cmd/Ctrl+Z restores the take's data in REAPER but this list only re-adopts it after the item is
      -- selected again, so the message makes no undo promise
      if found then
        set_status(string.format("Removed %s. Its envelope and saved analysis were cleared.", name))
      else
        set_status(string.format("Removed %s from Pitched Items.", name))
      end
    end,
  })
end

--- Settings > Wipe: confirm before removing every item of the session.
local function request_wipe_confirm()
  local n = #state.session_order
  if n == 0 then return end
  local resets = count_pitch_mode_resets(state.session_order)
  local lines = {
    string.format("This removes all %d pitched %s from Pitched Items, deletes their pitch envelope points and clears their saved analysis.",
      n, plural(n, "item", "items")),
  }
  if resets > 0 then
    lines[#lines + 1] = string.format("The pitch algorithm of %d %s returns to the project default.",
      resets, plural(resets, "item", "items"))
  end
  request_confirm({
    id = "wipe_session",
    title = string.format("Wipe %d %s?", n, plural(n, "item", "items")),
    body_lines = lines,
    confirm_label = string.format("Wipe %d %s", n, plural(n, "Item", "Items")),
    on_confirm = function()
      local wiped = wipe_entire_session()
      -- The list does not re-adopt items after Cmd/Ctrl+Z, so no undo promise
      set_status(string.format("Wiped %d %s.", wiped, plural(wiped, "item", "items")))
    end,
  })
end

--- Settings > Clear: confirm before discarding the active take's analysis and envelope points.
local function request_clear_confirm()
  local guid = state.target_take_guid
  if not guid or not state.notes or #state.notes == 0 then return end
  local name = state.target_take_name or "this item"
  local k = #state.notes
  local lines = {
    string.format("Discards %d %s and the pitch envelope points of this item.", k, plural(k, "note", "notes")),
    "The item leaves Pitched Items until it is analyzed again.",
  }
  if take_has_clearable_data(resolve_take_by_guid(guid, true)) then
    lines[#lines + 1] = string.format("%s+Z brings them back.", K.MOD_LABEL)
  end
  request_confirm({
    id = "clear_take",
    title = string.format("Clear %s?", name),
    body_lines = lines,
    confirm_label = "Clear",
    on_confirm = function()
      local cleared, wrote = clear_take_analysis(guid)
      local msg = string.format("Cleared %d %s.", cleared, plural(cleared, "note", "notes"))
      if wrote then msg = msg .. string.format(" %s+Z to undo", K.MOD_LABEL) end
      set_status(msg)
    end,
  })
end

--- The items (take GUIDs, sorted) whose saved analysis could not be read and which exist in the project now.
K.unreadable_guids = function()
  local list = {}
  for guid in pairs(state.unreadable_takes) do
    if resolve_take_by_guid(guid, true) then list[#list + 1] = guid end
  end
  table.sort(list)
  return list
end

--- Purge the saved data of every unreadable item as ONE undo point ("Clear Unreadable Pitched Items Data"). An item that
--- was listed leaves Pitched Items like any cleared analysis. Returns how many items were purged.
K.clear_unreadable = function()
  local guids = K.unreadable_guids()
  if #guids == 0 then return 0 end
  reaper.Undo_BeginBlock()
  for _, guid in ipairs(guids) do
    local take = resolve_take_by_guid(guid, true)
    if take then reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, "", true) end
    state.unreadable_takes[guid] = nil
    state.raw_cache[guid] = nil
    if state.session_takes[guid] then
      state.session_takes[guid] = nil
      state.missing_takes[guid] = nil
      state.stale_takes[guid] = nil
      for idx, g in ipairs(state.session_order) do
        if g == guid then
          table.remove(state.session_order, idx)
          break
        end
      end
      if guid == state.target_take_guid then reset_analysis_model() end
    end
  end
  reaper.Undo_EndBlock("Clear Unreadable Pitched Items Data", -1)
  note_own_write()
  return #guids
end

--- Pitched Items banner "Clear": confirm before purging the unreadable saved data (names the count).
K.request_clear_unreadable = function()
  local n = #K.unreadable_guids()
  if n == 0 then return end
  request_confirm({
    id = "clear_unreadable",
    title = "Clear unreadable saved data?",
    body_lines = {
      string.format("Clear the unreadable saved data of %d %s? Their Pitched Items entry can be analyzed again.",
        n, plural(n, "item", "items")),
    },
    confirm_label = "Clear",
    on_confirm = function()
      local cleared = K.clear_unreadable()
      set_status(string.format("Cleared the unreadable saved data of %d %s.", cleared, plural(cleared, "item", "items")))
    end,
  })
end

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
  tag_tip = "Show Pitched Items (%d)",
  tag_tip_narrow = "Pitched Items (%d) does not fit this window. Widen the window to show it.",
  tag_narrow_status = "Widen the window to show Pitched Items",
  -- Row states and the checkbox column label (a row is never told apart by colour alone)
  col_on = "On",
  tag_missing = "Item missing",
  tag_outdated = "outdated",
  tip_missing = "The item no longer exists in this project",
  tip_outdated = "A global default changed after this item's envelope was written. Edit or re-analyze it to refresh.",
  -- Row card tints, as alpha of P.accent: the active row's fill and border, the hover fill and border
  active_fill_a = 0.22,
  active_border_a = 0.9,
  hover_fill_a = 0.10,
  hover_border_a = 0.35,
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

local function render_pitched_items_sidebar(sidebar_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout

  Theme.align(sidebar_ctx)
  reaper.ImGui_Text(sidebar_ctx, string.format("Pitched Items (%d)", #state.session_order))

  reaper.ImGui_SameLine(sidebar_ctx)
  local close_sz = L.icon_md.size + L.icon_md.pad * 2
  Theme.right_align(sidebar_ctx, close_sz)
  Theme.align(sidebar_ctx, nil, close_sz)
  if Theme.icon_btn(sidebar_ctx, "##close_items_panel", Theme.icons.tri_right, {
    preset = L.icon_md,
    tooltip = "Hide Pitched Items panel"
  }) then
    state.sidebar_open = false
    reaper.SetExtState("FancyScripts", "pitch_sidebar_open", "0", true)
  end

  reaper.ImGui_Separator(sidebar_ctx)

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

        -- 1. Card (inset so the border is never cut off): tint, border and, for the active row, a leading bar
        local card_x1 = rx + card_margin_x
        local card_y1 = ry + card_pad_y
        local card_x2 = rx + avail_w - card_margin_x
        local card_y2 = card_y1 + card_h

        local dl = reaper.ImGui_GetWindowDrawList(sidebar_ctx)
        local is_row_hovered = reaper.ImGui_IsMouseHoveringRect(sidebar_ctx, card_x1, card_y1, card_x2, card_y2)
        if is_active then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1, card_x2, card_y2, Theme.with_alpha(P.accent, BODY.active_fill_a), L.rounding)
          reaper.ImGui_DrawList_AddRect(dl, card_x1, card_y1, card_x2, card_y2, Theme.with_alpha(P.accent, BODY.active_border_a), L.rounding, 0, 1.0)
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1 + L.xs, card_x1 + bar_w, card_y2 - L.xs, P.accent)
        elseif is_row_hovered then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1, card_x2, card_y2, Theme.with_alpha(P.accent, BODY.hover_fill_a), L.rounding)
          reaper.ImGui_DrawList_AddRect(dl, card_x1, card_y1, card_x2, card_y2, Theme.with_alpha(P.accent, BODY.hover_border_a), L.rounding, 0, 1.0)
        end

        -- 2. Elements on one line inside the card, each centred on it
        local x_left = start_x + card_margin_x + card_pad_x
        local x_right = start_x + avail_w - card_margin_x - card_pad_x
        local line_y = start_y + card_pad_y
        reaper.ImGui_SetCursorPos(sidebar_ctx, x_left, line_y)

        -- Bypass checkbox: default frame padding; disabled (and unchecked) when the item no longer exists
        local is_enabled = (not is_missing) and not is_take_pitch_bypassed(take_obj)
        Theme.vcenter(sidebar_ctx, frame_h, card_h, line_y)
        if is_missing then reaper.ImGui_BeginDisabled(sidebar_ctx) end
        local cb_changed, new_en = reaper.ImGui_Checkbox(sidebar_ctx, "##bp", is_enabled)
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
        local name_col = (is_missing and P.text_dim) or P.text
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), name_col)
        reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
        reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_SelectableTextAlign(), 0, 0.5)
        reaper.ImGui_SetCursorPosY(sidebar_ctx, line_y)
        if reaper.ImGui_Selectable(sidebar_ctx, sel_text .. "###sel", false, reaper.ImGui_SelectableFlags_None(), name_w, card_h) then
          switch_active_target(guid, take_obj)
        end
        reaper.ImGui_PopStyleVar(sidebar_ctx, 2)
        reaper.ImGui_PopStyleColor(sidebar_ctx, 1)
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
          reaper.ImGui_TextColored(sidebar_ctx, P.text_dim, state_tag)
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

--- Body, panel open: canvas | grip | Pitched Items in a resizable two-column table (canvas stretches,
--- the panel is a fixed column). ImGui keeps a fixed column's width between frames and offers no way to
--- set it again, so a width that has to change without a drag (the window got narrower, the panel was
--- closed and reopened) is applied by starting a new table id, which takes the init width once. The live
--- width is read back each frame into state.sidebar_w. Returns whether the table was drawn.
local function draw_body_split(P, avail_w, total_h)
  local L = Theme.layout
  local left = reaper.ImGui_MouseButton_Left()
  local mouse_down = reaper.ImGui_IsMouseDown(ctx, left)

  local max_sidebar_w = math.max(BODY.min_sidebar_w, avail_w - BODY.min_graph_w - BODY.splitter_w)
  local wanted_w = math.max(BODY.min_sidebar_w, math.min(max_sidebar_w, state.sidebar_w))
  -- A drag may run past the limits while the button is down; the width snaps back on release
  -- ReaImGui 0.10 has no TableSetColumnWidth: the table takes TableSetupColumn's width again only under a new id. The id
  -- changes only when the width must be clamped (window resized, panel reopened), never while the user works, and the
  -- list's scroll position is carried over to the new id (RB17)
  local new_id = false
  if not state.sidebar_tabled or (math.abs(wanted_w - state.sidebar_w) > BODY.width_eps and not mouse_down) then
    state.sidebar_w = wanted_w
    state.sidebar_gen = state.sidebar_gen + 1
    new_id = true
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

    -- Right: Pitched Items panel, inset from the grip
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    local grip_x, grip_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local column_w = reaper.ImGui_GetContentRegionAvail(ctx)
    state.sidebar_w = column_w
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + L.sm)
    local panel_w = math.max(column_w, BODY.min_sidebar_w) - L.sm
    if new_id then reaper.ImGui_SetNextWindowScroll(ctx, 0, state.sidebar_scroll_y or 0) end
    if reaper.ImGui_BeginChild(ctx, "##pitched_items_sidebar", panel_w, total_h, 0) then
      render_pitched_items_sidebar(ctx)
      state.sidebar_scroll_y = reaper.ImGui_GetScrollY(ctx) or 0
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

--- Body, panel closed (by preference or because the window is too narrow): the canvas and a strip on the
--- right whose button, centred in the strip, opens the panel again when it fits.
local function draw_body_tag(P, avail_w, total_h, fits)
  local L = Theme.layout
  local tag_w = L.icon_md.size + L.icon_md.pad * 2
  draw_graph(ctx, avail_w - tag_w, total_h)

  reaper.ImGui_SameLine(ctx, 0, 0)

  local tag_dl = reaper.ImGui_GetWindowDrawList(ctx)
  local tx, ty = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddRectFilled(tag_dl, tx, ty, tx + tag_w, ty + total_h, P.card)

  -- The button is the whole strip: its icon is centred in it and the click target is as tall as the body
  if Theme.icon_btn(ctx, "##open_items_tag", Theme.icons.tri_left, {
    icon_size = L.icon_md.size,
    w = tag_w,
    h = total_h,
    tooltip = string.format(fits and BODY.tag_tip or BODY.tag_tip_narrow, #state.session_order)
  }) then
    -- Record the wish to see the panel; a window too narrow for it keeps showing this tag
    if not state.sidebar_open then
      state.sidebar_open = true
      reaper.SetExtState("FancyScripts", "pitch_sidebar_open", "1", true)
    end
    if not fits then set_status(BODY.tag_narrow_status) end
  end
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

--- Status line of a Settings reset: engine settings are saved outside the undo history, so it says so (EP1 / HC4).
K.settings_reset_status = function(name, shown)
  set_status(string.format("%s reset to %s (not undoable)", name, shown))
end

--- Settings value control: a param_drag on state[key] within K.LIMITS[key], `width` wide and without a label (the form's
--- label column names it, `name` is the setting's name in the status line); double-click or the right-click menu's
--- "Reset to default" restores DEFAULTS[key] (engine settings are not project state: no undo point, the status line
--- says so). The value is saved once the edit is done (the drag released, a wheel burst over, a typed entry confirmed,
--- a reset), not while it moves.
local function settings_drag(id, key, fmt, width, name)
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local changed, v, committed, reset = param_drag(ctx, id, nil, state[key], K.LIMITS[key][1], K.LIMITS[key][2], fmt)
  -- HC3: right-click menu. A Ctrl/Cmd-click opens the typed entry instead (on macOS ReaImGui may report it as a
  -- right-click too), so the menu never opens while Ctrl/Cmd is held
  local menu_id = "##reset_menu_" .. id
  local ctrl_held = ((reaper.ImGui_GetKeyMods(ctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
  if (not ctrl_held or reaper.ImGui_IsPopupOpen(ctx, menu_id))
     and reaper.ImGui_BeginPopupContextItem(ctx, menu_id, reaper.ImGui_PopupFlags_MouseButtonRight()) then
    if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end   -- HC5
    if reaper.ImGui_MenuItem(ctx, "Reset to default", nil, nil, state[key] ~= DEFAULTS[key]) then reset = true end
    reaper.ImGui_EndPopup(ctx)
  end
  if reset then
    if state[key] ~= DEFAULTS[key] then
      state[key] = DEFAULTS[key]
      K.save_settings("engine")
      K.settings_reset_status(name or key, string.format(fmt, DEFAULTS[key]))
    end
    return
  end
  if changed then state[key] = v end
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
      shown = function() return state.pitchmode_name end,
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
      shown = function() return state.keep_pitch_mode and "on" or "off" end,
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
      shown = function()
        local i = K.match_preset(VOCAL_RANGES, function(r) return r.min == state.min_freq and r.max == state.max_freq end)
        return VOCAL_RANGES[i] and VOCAL_RANGES[i].name or string.format("%.0f-%.0f Hz", state.min_freq, state.max_freq)
      end,
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
      shown = function()
        local i = K.match_preset(DETECTION_MODES, function(m) return m.threshold == state.threshold end)
        return DETECTION_MODES[i] and DETECTION_MODES[i].name or string.format("%.2f", state.threshold)
      end,
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
      shown = function()
        local i = K.match_preset(QUALITY_MODES, function(q) return q.block == state.block_size and q.hop == state.hop_size end)
        return QUALITY_MODES[i] and QUALITY_MODES[i].name or string.format("%d / %d samples", state.block_size, state.hop_size)
      end,
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
      shown = function() return string.format("%d samples", state.block_size) end,
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
      shown = function() return string.format("%d samples", state.hop_size) end,
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
      shown = function() return string.format("%.2f", state.threshold) end,
      reset = function() state.threshold = DEFAULTS.threshold end,
      draw = function(w)
        settings_drag("dsp_threshold", "threshold", "%.2f", w, "Detection Threshold")
        if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, "Confidence threshold for pitch detection (lower = stricter).")
        end
      end },
    { id = "min_freq", label = "Min Freq (Hz)", name = "Min Freq",
      is_default = function() return state.min_freq == DEFAULTS.min_freq end,
      shown = function() return string.format("%.0f Hz", state.min_freq) end,
      reset = function() state.min_freq = DEFAULTS.min_freq end,
      draw = function(w) settings_drag("dsp_min_freq", "min_freq", "%.0f Hz", w, "Min Freq") end },
    { id = "max_freq", label = "Max Freq (Hz)", name = "Max Freq",
      is_default = function() return state.max_freq == DEFAULTS.max_freq end,
      shown = function() return string.format("%.0f Hz", state.max_freq) end,
      reset = function() state.max_freq = DEFAULTS.max_freq end,
      draw = function(w) settings_drag("dsp_max_freq", "max_freq", "%.0f Hz", w, "Max Freq") end },
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
--- Fancy Dark, composited: rest (P.red_d) 12.7:1, hover and pressed (P.red_h) 9.1:1 (an opaque P.red pressed would be
--- 3.21:1). Pair every K.push_danger(P) with K.pop_danger().
K.push_danger = function(P)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red_h)
end
K.pop_danger = function()
  reaper.ImGui_PopStyleColor(ctx, 3)
end

--- A checkbox for a canvas layer (state[key]: the Layers popup and Settings > Diagnostics). The change is saved at once:
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

  if show_settings_modal then
    reaper.ImGui_OpenPopup(ctx, "Settings & Audio Engine##settings_modal")
    show_settings_modal = false
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
          K.settings_reset_status(row.name or row.label, row.shown())   -- EP1: outside the undo history, so say so
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
      Theme.align(ctx)
      K.layer_checkbox("Trend Line", "show_trend")
      Theme.align(ctx)
      K.layer_checkbox("Pitch Center Spots", "show_smart_spots")
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

-- Keyboard Shortcuts & Help content: one entry per section, one { key, description } row each (draw_info_modal measures
-- the columns from these strings). Keep a description near 52 characters so the table stays narrow; the terms follow
-- the UI labels (Pitched Items, item, Correction Strength, Transition, Onset Ramp, Legato Gap, Scoop shape).
K.INFO_SECTIONS = {
  { title = "Selection & Navigation", rows = {
    { K.MOD_LABEL .. " + A", "Select all notes in phrase" },
    { "Escape", "Cancel a drag, close a dialog, deselect, close if floating" },
    { "Marquee Drag", "Box select notes (Shift=Add)" },
    { "Shift + Click", "Range select notes" },
    { K.MOD_LABEL .. " + Click", "Toggle note in/out of selection" },
    { "← / →", "Select previous / next note (Shift=Extend)" },
    { "Click empty canvas", "Deselect, move the REAPER edit cursor" },
    { "Click a Pitched Items row", "Switch the active item" },
    { "Select an audio item in REAPER", "Becomes the active item" },
    { "Drag the divider", "Resize Pitched Items" },
  } },
  { title = "Pitch & Note Editing", rows = {
    { "Drag the Pitch zone (middle)", string.format("Move the note's pitch (%s-drag: fine adjust)", K.MOD_LABEL) },
    { "Drag the Stability zone (left)", "Stability: hold the pitch steadier (less drift)" },
    { "Drag the Vibrato zone (right)", "Vibrato: scale its depth" },
    { "Shift + drag a zone", string.format("%s (left) / %s (middle) / %s (right)", PARAM_LABELS.onset_ramp_ms,
      PARAM_LABELS.transition_ms, PARAM_LABELS.scoop_shape) },
    { "Shift on the canvas", "Remaps the three zones (as above); the zones turn amber and are named" },
    { "Drag a note edge", "Trim the note's start / end" },
    { K.MOD_LABEL .. " + wheel", "Zoom the timeline" },
    { "Wheel / horizontal wheel", "Scroll the timeline (when zoomed)" },
    { "Double-click the ruler", "Show the whole item again" },
    { "↑ / ↓", "Nudge pitch ±1 semitone" },
    { "Shift + ↑ / ↓", "Nudge pitch ±10 cents (fine)" },
    { "S / Double-Click", "Snap note to nearest semitone" },
    { "Q", "Quantize selected note(s) to scale" },
    { "R / Backspace / Delete", "Reset note(s) to original detected pitch" },
    { "Right-click a note", "Note menu: bypass, overrides, Snap, Quantize, Split, Reset" },
    { "Right-click a dock value", "Item override and reset" },
    { "Double-click a value", "Reset to its default" },
    { K.MOD_LABEL .. "-click a value", "Type a number" },
    { "Wheel over a value", string.format("Adjust it (%s + wheel: fine), where the window does not scroll", K.MOD_LABEL) },
    { "Right-click a Settings value", "Reset to default" },
    { "Snap / Quantize / Split / Merge buttons", "Same as S / Q / X / M" },
  } },
  { title = "Note Topology & REAPER Transport", rows = {
    { "X", "Split note at REAPER edit cursor" },
    { "M", "Merge 2+ contiguous selected notes" },
    { "Space", "Runs your REAPER action for Space (default Play/Stop)" },
    { "Shift / " .. K.MOD_LABEL .. " / Alt + Space", "Your REAPER actions for those chords" },
  } },
  { title = "Icons", rows = {
    { "Gear icon", "Settings & audio engine" },
    { "Info icon", "This help window" },
    { "× (top right)", "Close the window (Esc when floating)" },
    { "▸ / ◀", "Hide / show the Pitched Items panel" },
    { "Checkbox (item row)", "Pitch envelope active / bypassed" },
    { "× (item row)", "Remove the item from Pitched Items" },
    { "* after a value", "Set for this item only" },
  } },
}
K.INFO_TERMS = "Reset reverts note edits · Clear discards analysis · Remove drops an item · Wipe removes all"

local function draw_info_modal()
  local P = Theme.get_palette()
  local L = Theme.layout

  if show_info_modal then
    reaper.ImGui_OpenPopup(ctx, "Keyboard Shortcuts & Help##info_modal")
    show_info_modal = false
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

K.count_selected_notes = count_selected_notes   -- for draw_graph (defined above this function)

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

--- Run a note command and say what happened in the status line. The dock's action buttons, their keys (S, Q, X, M),
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

K.request_reset = request_reset   -- for draw_graph: R / Backspace / Delete and the note menu's Reset (ST2 / HC4)

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

-------------------------------------------------------------------------------
-- HEADER BAR
-------------------------------------------------------------------------------
-- One row at normal widths:  brand, title | target badge | Key, Scale | Analyze, Reset ... Layers,
-- Settings, Info, Close (right-aligned). Every width is measured from the longest label its control can
-- show. Which elements appear, and on how many rows, is a HDR_PLANS entry chosen from the content width
-- alone (never from the selected item or the note selection), so nothing jumps while working. As the
-- width shrinks the plans drop, in order: the "Key:" / "Scale:" labels, the title, Analyze / Reset
-- (into a "…" popup), and finally wrap the controls onto a second and third row. The item badge takes
-- the width its row has left and truncates its text with an ellipsis.

local hdr_static = nil        -- widths that depend only on fonts and style (measured once)
local hdr_was_docked = nil    -- IsWindowDocked of the previous frame (nil until known): size constraints are for floating windows only

-- Chunk-level names of this section (loop_body and the bottom dock use them): everything else stays
-- private to the block below, so it does not count against the chunk's 200-local limit.
local measure_header_static, hdr_min_content_w, hdr_fit_text, draw_header

do
  local HDR_NO_TARGET_TEXT = "No Audio Item"
  local HDR_LAYERS_LABEL = "Layers ▾"
  local HDR_ELLIPSIS = "…"
  local HDR_PROGRESS_LONGEST = "100%"
  -- Every label of the Analyze slot: while analysing it reads "Cancel <N>%", so the slot is planned for "Cancel 100%"
  local HDR_ANALYZE_LABELS = { "Analyze", "Re-Analyze", string.format(K.CANCEL_FMT, 100) }
  -- Longest label of the Reset button: the layout plan reserves this so it does not change with the selection
  local HDR_RESET_LONGEST = "Reset selected (999)"
  -- Why Analyze / Reset are disabled (shown beside them when there is room, and in their tooltips)
  local HDR_REASON_NO_TARGET = "Select an audio item"
  local HDR_REASON_NO_NOTES = "Analyze an item first"

  local HDR_FULL_ROW = { "brand", "fancy", "title", "badge", "key", "scale", "analyze", "reset" }
  local HDR_PLANS = {
    { labels = true,  rows = { HDR_FULL_ROW } },
    { labels = false, rows = { HDR_FULL_ROW } },
    { labels = false, rows = { { "brand", "badge", "key", "scale", "analyze", "reset" } } },
    { labels = false, rows = { { "brand", "badge", "key", "scale", "more" } } },
    { labels = false, rows = { { "brand", "fancy", "title" }, { "badge", "key", "scale", "more" } } },
    { labels = false, rows = { { "brand" }, { "badge", "more" }, { "key", "scale" } } },
  }
  -- The narrowest header a floating window keeps (two rows, no title): row 1 is the brand + the right group
  local HDR_FLOATING_MIN_ROW = { "badge", "key", "scale", "more" }
  for _, plan in ipairs(HDR_PLANS) do
    for r, row in ipairs(plan.rows) do
      for _, id in ipairs(row) do
        if id == "badge" then plan.badge_row = r end
      end
    end
  end

  local hdr_fit_cache = {}      -- fit_text results, keyed by text and width
  local hdr_fit_cache_n = 0

  local function hdr_text_w(text)
    return (reaper.ImGui_CalcTextSize(ctx, text))
  end

  local function hdr_max_text_w(list)
    local w = 0
    for _, text in ipairs(list) do w = math.max(w, hdr_text_w(text)) end
    return w
  end

  --- Measure everything in the header that does not change from frame to frame. Call with the default
  --- font and the Theme style pushed (before Begin is fine).
  measure_header_static = function()
    local L = Theme.layout
    local s = {}
    s.frame_h = reaper.ImGui_GetFrameHeight(ctx)
    s.pad_x = L.md * 2                                    -- FramePadding.x on both sides of a label
    s.icon_sz = L.icon_md.size + L.icon_md.pad * 2
    s.close_sz = L.icon_target.size + L.icon_target.pad * 2   -- Close is destructive: the 24 px minimum target (WCAG 2.5.8)
    s.brand_sz = L.row_h
    s.row_h = math.max(L.row_h, s.brand_sz, s.icon_sz, s.close_sz, s.frame_h)

    local pushed = Theme.push_font(ctx, fonts.large_bold)
    s.fancy_w, s.fancy_h = reaper.ImGui_CalcTextSize(ctx, "FANCY")
    Theme.pop_font(ctx, pushed)
    pushed = Theme.push_font(ctx, fonts.large)
    s.title_w, s.title_h = reaper.ImGui_CalcTextSize(ctx, "PITCH CORRECT")
    Theme.pop_font(ctx, pushed)

    s.key_lbl_w = hdr_text_w("Key:")
    s.scale_lbl_w = hdr_text_w("Scale:")
    s.key_w = Theme.calc_combo_width(ctx, COMBO_LABELS.keys)
    -- Width of the Key list: Theme.selectable draws its text itself, so the popup only grows to fit if the
    -- rows are given the width of the longest name ("C# / Db") plus the text padding on both sides
    s.key_list_w = math.max(s.key_w, hdr_max_text_w(COMBO_LABELS.key_names) + L.sm * 2)
    s.scale_w = Theme.calc_combo_width(ctx, COMBO_LABELS.scales)
    s.analyze_w = hdr_max_text_w(HDR_ANALYZE_LABELS) + s.pad_x
    s.reset_longest_w = hdr_text_w(HDR_RESET_LONGEST) + s.pad_x
    s.layers_w = hdr_text_w(HDR_LAYERS_LABEL) + s.pad_x
    s.more_w = math.max(hdr_text_w(HDR_ELLIPSIS), hdr_text_w(HDR_PROGRESS_LONGEST)) + s.pad_x
    s.no_target_w = hdr_text_w(HDR_NO_TARGET_TEXT) + s.pad_x  -- the badge never plans narrower than this
    s.badge_min_w = hdr_text_w(HDR_ELLIPSIS) + s.pad_x
    -- Layers, gear, info, close: the real gaps between them (see hdr_draw_right)
    s.right_w = s.layers_w + L.md + s.icon_sz + L.sm + s.icon_sz + L.lg + s.close_sz
    return s
  end

  --- `text` shortened with a trailing ellipsis to at most max_w wide (cached: the header runs every frame).
  hdr_fit_text = function(text, max_w)
    if hdr_text_w(text) <= max_w then return text end
    local key = text .. "\0" .. tostring(math.floor(max_w))
    local hit = hdr_fit_cache[key]
    if hit then return hit end
    local n = utf8.len(text)
    local by_char = (n ~= nil)
    if not by_char then n = #text end
    local result = HDR_ELLIPSIS
    for k = n - 1, 1, -1 do
      local head = by_char and text:sub(1, utf8.offset(text, k + 1) - 1) or text:sub(1, k)
      local candidate = (head:gsub("%s+$", "")) .. HDR_ELLIPSIS
      if hdr_text_w(candidate) <= max_w then
        result = candidate
        break
      end
    end
    if hdr_fit_cache_n >= 64 then
      hdr_fit_cache = {}
      hdr_fit_cache_n = 0
    end
    hdr_fit_cache[key] = result
    hdr_fit_cache_n = hdr_fit_cache_n + 1
    return result
  end

  --- Gap placed before an element when it follows another one on the same row: tight inside a group
  --- (brand / FANCY / title, Key / Scale), a group break everywhere else.
  local function hdr_gap_before(id)
    local L = Theme.layout
    if id == "fancy" then return L.sm end
    if id == "title" then return L.xs end
    if id == "badge" or id == "scale" then return L.md end
    return L.lg
  end

  local function hdr_element_w(id, s, labels, badge_w, reset_w)
    local L = Theme.layout
    if id == "brand" then return s.brand_sz end
    if id == "fancy" then return s.fancy_w end
    if id == "title" then return s.title_w end
    if id == "badge" then return badge_w end
    if id == "key" then return labels and (s.key_lbl_w + L.xs + s.key_w) or s.key_w end
    if id == "scale" then return labels and (s.scale_lbl_w + L.xs + s.scale_w) or s.scale_w end
    if id == "analyze" then return s.analyze_w end
    if id == "reset" then return reset_w end
    return s.more_w -- "more"
  end

  local function hdr_row_w(row, s, labels, badge_w, reset_w)
    local w = 0
    for i, id in ipairs(row) do
      if i > 1 then w = w + hdr_gap_before(id) end
      w = w + hdr_element_w(id, s, labels, badge_w, reset_w)
    end
    return w
  end

  --- First plan whose rows all fit in avail_w (row 1 also holds the right group). The badge is planned at
  --- its floor and then takes whatever its row has left. Returns the plan and the badge width.
  local function hdr_choose_plan(s, avail_w, badge_natural_w)
    local L = Theme.layout
    local chosen, badge_room = HDR_PLANS[#HDR_PLANS], 0
    for pi, plan in ipairs(HDR_PLANS) do
      local fits, room = true, 0
      for r, row in ipairs(plan.rows) do
        local reserved = (r == 1) and (L.lg + s.right_w) or 0
        local left = avail_w - hdr_row_w(row, s, plan.labels, 0, s.reset_longest_w) - reserved
        if r == plan.badge_row then
          room = left
          if left < s.no_target_w then fits = false end
        elseif left < 0 then
          fits = false
        end
      end
      if fits or pi == #HDR_PLANS then
        chosen, badge_room = plan, room
        if fits then break end
      end
    end
    return chosen, math.min(badge_natural_w, math.max(badge_room, s.badge_min_w))
  end

  --- Content width the narrowest floating header needs (two rows, no title). With `full`: the width the
  --- first plan needs to be chosen (title, "Key:" / "Scale:" labels, one row), its badge at its floor.
  hdr_min_content_w = function(s, full)
    local L = Theme.layout
    if full then
      local plan = HDR_PLANS[1]
      return hdr_row_w(plan.rows[1], s, plan.labels, s.no_target_w, s.reset_longest_w) + L.lg + s.right_w
    end
    local row1 = s.brand_sz + L.lg + s.right_w
    local row2 = hdr_row_w(HDR_FLOATING_MIN_ROW, s, false, s.no_target_w, 0)
    return math.max(row1, row2)
  end

  --- The pitch algorithm line of the item badge tooltip: the algorithm the item uses now, and who chose it
  --- (this script writes it with every apply unless "Keep each item's own pitch algorithm" is on).
  local function hdr_pitch_algorithm_line(take)
    local mode = take and reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    local name = "Unknown"
    for _, entry in ipairs(PITCHMODE_FLAT) do
      if entry.value == mode then name = entry.name; break end
    end
    local by_script = not state.keep_pitch_mode and script_set_pitch_mode(take)
    return string.format("Pitch algorithm: %s %s", name, by_script and "(set by Fancy Pitch Correct)" or "(your own setting)")
  end

  local function hdr_draw_target_badge(hs)
    local P, s = hs.P, hs.s
    if hs.has_target then
      local track_col = get_target_track_color(hs.target_take, hs.target_item)
      local badge_bg = track_col or (hs.has_notes and P.accent_d or Theme.with_alpha(P.yellow, 0.25))
      Theme.badge(ctx, hdr_fit_text(state.target_take_name, hs.badge_w - s.pad_x), {
        id = "target",
        bg = badge_bg,
        text_color = get_contrasting_text_color(badge_bg),
        w = hs.badge_w,
      })
      -- The tooltip is built on hover only (after the hover delay, RB15): it reads the item's pitch algorithm from REAPER
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(ctx, string.format("Active item: %s\nStatus: %s\n%s\nSelect any audio item in REAPER to switch to it.",
          state.target_take_name, hs.has_notes and "Analyzed & Active" or "Ready to Analyze",
          hdr_pitch_algorithm_line(hs.target_take)))
      end
    else
      Theme.badge(ctx, hdr_fit_text(HDR_NO_TARGET_TEXT, hs.badge_w - s.pad_x), {
        id = "target",
        bg = P.card,
        text_color = P.text,
        w = hs.badge_w,
        tooltip = state.selection_issue or "Select an audio item in REAPER to pitch-correct.",
      })
    end
  end

  local function hdr_draw_key(hs)
    local P, L, s = hs.P, Theme.layout, hs.s
    if hs.labels then
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.accent_l, "Key:")
      reaper.ImGui_SameLine(ctx, 0, L.xs)
    end
    -- Previews the short name ("C#") but lists the full one ("C# / Db"), so it stays a plain BeginCombo
    reaper.ImGui_SetNextItemWidth(ctx, s.key_w)
    if reaper.ImGui_BeginCombo(ctx, "##key_selector", SCALE_KEYS[state.key_idx].display) then
      for i, k_info in ipairs(SCALE_KEYS) do
        local is_sel = (state.key_idx == i)
        if Theme.selectable(ctx, k_info.name .. "##key_" .. i, is_sel, nil, s.key_list_w) and not is_sel then
          state.key_idx = i
          update_scale_pitch_classes()
          save_current_scale_settings()
        end
        if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "Musical Key (Root Pitch Class)")
    end
  end

  local function hdr_draw_scale(hs)
    local P, L, s = hs.P, Theme.layout, hs.s
    if hs.labels then
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.accent_l, "Scale:")
      reaper.ImGui_SameLine(ctx, 0, L.xs)
    end
    local new_idx, changed = Theme.combo(ctx, "##scale_selector", SCALE_DEFINITIONS, state.scale_idx, {
      w = s.scale_w,
      tooltip = "Musical Scale — highlights in-scale piano roll rows and sets the scale Quantize (Q) snaps to",
    })
    if changed and new_idx ~= state.scale_idx then
      state.scale_idx = new_idx
      update_scale_pitch_classes()
      save_current_scale_settings()
    end
  end

  --- Analyze / Re-Analyze. While analysing the same slot is the Cancel button, with the progress in its label, so
  --- nothing moves (Esc is not bound to it: on a floating window Esc closes the window, which cancels too).
  local function hdr_draw_analyze(hs)
    local s = hs.s
    if state.is_analyzing then
      local clicked = reaper.ImGui_Button(ctx,
        string.format(K.CANCEL_FMT, math.floor(state.progress * 100)) .. "###top_analyze", s.analyze_w, 0)
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(ctx, hs.has_notes and "Stop analyzing. The item keeps its previous analysis"
          or "Stop analyzing this item")
      end
      if clicked then K.cancel_analysis() end
      return
    end
    reaper.ImGui_BeginDisabled(ctx, not hs.has_target)
    local clicked = reaper.ImGui_Button(ctx, hs.analyze_label .. "###top_analyze", s.analyze_w, 0)
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
      if not hs.has_target then
        Theme.tooltip(ctx, HDR_REASON_NO_TARGET .. " in REAPER to analyze it.")
      else
        Theme.tooltip(ctx, hs.has_notes and "Detect the pitch of this item again" or "Detect the pitch of the selected audio item")
      end
    end
    if clicked then request_analyze() end
  end

  --- Reset: the label names the scope (the selection, or every note) and its count.
  local function hdr_draw_reset(hs)
    reaper.ImGui_BeginDisabled(ctx, not hs.has_notes)
    local clicked = reaper.ImGui_Button(ctx, hs.reset_label .. "###top_reset", hs.reset_w, 0)
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
      if hs.has_notes then
        Theme.tooltip(ctx, "Reset selected note(s) to original pitch, or reset all notes if none selected")
      else
        Theme.tooltip(ctx, HDR_REASON_NO_NOTES .. ". There are no notes to reset.")
      end
    end
    if clicked then request_reset(hs.reset_sel_n, hs.reset_note_n) end
  end

  --- "…" button and popup holding Analyze and Reset, for widths where they no longer fit in the row. The
  --- items carry the same disabled reasons as the buttons (in the shortcut column). While analysing the same
  --- button shows the progress ("42%") and its popup offers Cancel in place of Analyze.
  local function hdr_draw_more(hs)
    local s = hs.s
    local analyzing = state.is_analyzing
    local pct = math.floor(state.progress * 100)
    if reaper.ImGui_Button(ctx, (analyzing and string.format("%d%%", pct) or HDR_ELLIPSIS) .. "###hdr_more", s.more_w, 0) then
      reaper.ImGui_OpenPopup(ctx, "##hdr_more_popup")
    end
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, analyzing and "Analyzing. Open to cancel" or "More: Analyze and Reset")
    end
    if reaper.ImGui_BeginPopup(ctx, "##hdr_more_popup") then
      -- HC5: Esc closes this popup (innermost)
      if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
      if analyzing then
        if reaper.ImGui_MenuItem(ctx, string.format(K.CANCEL_FMT, pct) .. "###more_analyze") then
          K.cancel_analysis()
        end
      elseif reaper.ImGui_MenuItem(ctx, hs.analyze_label .. "###more_analyze",
          (not hs.has_target) and HDR_REASON_NO_TARGET or nil, false, hs.has_target) then
        request_analyze()
      end
      if reaper.ImGui_MenuItem(ctx, hs.reset_label .. "###more_reset",
          (not hs.has_notes) and HDR_REASON_NO_NOTES or nil, false, hs.has_notes) then
        request_reset(hs.reset_sel_n, hs.reset_note_n)
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  --- Layers, Settings, Info and Close, right-aligned on the current row. Returns true when Close was clicked.
  local function hdr_draw_right(hs)
    local P, L, s = hs.P, Theme.layout, hs.s
    reaper.ImGui_SameLine(ctx, 0, 0)
    -- Never start left of the previous element plus a group gap, however narrow the row is
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    Theme.right_align(ctx, math.min(s.right_w, math.max(0, avail_w - L.lg)))

    -- Layers ▾
    if reaper.ImGui_Button(ctx, HDR_LAYERS_LABEL .. "###top_layers", s.layers_w, 0) then
      reaper.ImGui_OpenPopup(ctx, "##layers_popup")
    end
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "Toggle visual display layers on the piano roll canvas")
    end

    if reaper.ImGui_BeginPopup(ctx, "##layers_popup") then
      -- HC5: Esc closes this popup (innermost); the window-level handler ignores Esc while a popup is open
      if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.accent, "Display Layers")
      reaper.ImGui_Separator(ctx)
      -- Each layer shows how it looks on the canvas: a swatch from the same canvas tokens and shape, before its label
      -- (the labels carry no colour word)
      local LC = P.canvas
      local sw_w, sw_h = L.xl, reaper.ImGui_GetFrameHeight(ctx)
      local function layer_checkbox(label, key, draw_swatch)
        reaper.ImGui_Dummy(ctx, sw_w, sw_h)
        local sx, sy = reaper.ImGui_GetItemRectMin(ctx)
        draw_swatch(reaper.ImGui_GetWindowDrawList(ctx), sx, sy + sw_h * 0.5)
        reaper.ImGui_SameLine(ctx, 0, L.sm)
        K.layer_checkbox(label, key)
      end
      layer_checkbox("Note Blocks", "show_note_blocks", function(dl, x, cy)
        reaper.ImGui_DrawList_AddRectFilled(dl, x, cy - L.sm, x + sw_w, cy + L.sm, LC.note_fill)
        reaper.ImGui_DrawList_AddRect(dl, x, cy - L.sm, x + sw_w, cy + L.sm, LC.note_border)
      end)
      layer_checkbox("Pitch Trace", "show_raw_pitch", function(dl, x, cy)
        reaper.ImGui_DrawList_AddLine(dl, x, cy, x + sw_w, cy, LC.trace, 2.0)
      end)
      layer_checkbox("Preview Curve", "show_preview", function(dl, x, cy)
        reaper.ImGui_DrawList_AddLine(dl, x, cy, x + sw_w, cy, LC.preview, 2.0)
      end)
      layer_checkbox("Vibrato Shading", "show_vibrato_regions", function(dl, x, cy)
        reaper.ImGui_DrawList_AddRectFilled(dl, x, cy - L.sm, x + sw_w, cy + L.sm, Theme.with_alpha(LC.vibrato, 1.0))   -- the band is translucent on the canvas; the swatch is its opaque hue
      end)
      reaper.ImGui_EndPopup(ctx)
    end

    -- Settings, Info: 24 px apart (centre to centre); the destructive Close sits a group gap away.
    -- An icon shorter than the frame is centred on the row's framed widgets.
    reaper.ImGui_SameLine(ctx, 0, L.md)
    Theme.align(ctx, nil, s.icon_sz)
    if Theme.icon_btn(ctx, "##hdr_settings", Theme.icons.gear, { preset = L.icon_md, tooltip = "Settings & Audio Engine" }) then
      show_settings_modal = true
    end

    reaper.ImGui_SameLine(ctx, 0, L.sm)
    Theme.align(ctx, nil, s.icon_sz)
    if Theme.icon_btn(ctx, "##hdr_info", Theme.icons.info, { preset = L.icon_md, tooltip = "Keyboard Shortcuts & Help" }) then
      show_info_modal = true
    end

    reaper.ImGui_SameLine(ctx, 0, L.lg)
    Theme.align(ctx, nil, s.close_sz)
    return Theme.icon_btn(ctx, "##hdr_close", Theme.icons.close, {
      preset = L.icon_target,
      icon_size = L.icon_md.size,   -- same glyph as gear and info; only the click target is 24 px
      w = s.close_sz, h = s.close_sz,   -- icon_btn sizes the button from icon_size unless told otherwise
      tooltip = hs.docked and "Close. Your corrections stay on the items" or "Close (Esc). Your corrections stay on the items",
    })
  end

  local function hdr_draw_element(id, hs)
    local P, s = hs.P, hs.s
    if id == "brand" then
      Theme.brand_icon(ctx, s.brand_sz, s.row_h)
    elseif id == "fancy" then
      Theme.align(ctx, nil, s.fancy_h)  -- the larger text is centred on the framed widgets, not top-aligned
      local pushed = Theme.push_font(ctx, fonts.large_bold)
      reaper.ImGui_TextColored(ctx, P.yellow, "FANCY")
      Theme.pop_font(ctx, pushed)
    elseif id == "title" then
      Theme.align(ctx, nil, s.title_h)
      local pushed = Theme.push_font(ctx, fonts.large)
      reaper.ImGui_Text(ctx, "PITCH CORRECT")
      Theme.pop_font(ctx, pushed)
    elseif id == "badge" then
      hdr_draw_target_badge(hs)
    elseif id == "key" then
      hdr_draw_key(hs)
    elseif id == "scale" then
      hdr_draw_scale(hs)
    elseif id == "analyze" then
      hdr_draw_analyze(hs)
    elseif id == "reset" then
      hdr_draw_reset(hs)
    else
      hdr_draw_more(hs)
    end
  end

  --- Draws the header. Returns true when Close was clicked.
  draw_header = function(P, docked, has_target, has_notes, target_take, target_item)
    local L = Theme.layout
    local s = hdr_static
    -- Real booleans: a nil reaching MenuItem's `enabled` would mean "enabled"
    has_target = has_target and true or false
    has_notes = has_notes and true or false
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)

    local badge_text = has_target and state.target_take_name or HDR_NO_TARGET_TEXT
    local plan, badge_w = hdr_choose_plan(s, avail_w, hdr_text_w(badge_text) + s.pad_x)

    local reset_sel_n = has_notes and count_selected_notes() or 0
    local reset_note_n = has_notes and #state.notes or 0
    local reset_label = "Reset"
    if reset_sel_n > 0 then
      reset_label = string.format("Reset selected (%d)", reset_sel_n)
    elseif reset_note_n > 0 then
      reset_label = string.format("Reset %d %s", reset_note_n, plural(reset_note_n, "note", "notes"))
    end

    local reason = nil  -- one short line beside the disabled control, none while analysing (the bar shows it)
    if not state.is_analyzing then
      if not has_target then
        reason = HDR_REASON_NO_TARGET
      elseif not has_notes then
        reason = HDR_REASON_NO_NOTES
      end
    end

    local hs = {
      P = P, s = s, docked = docked, labels = plan.labels, badge_w = badge_w,
      has_target = has_target, has_notes = has_notes, target_take = target_take, target_item = target_item,
      analyze_label = has_notes and "Re-Analyze" or "Analyze",
      reset_label = reset_label, reset_w = hdr_text_w(reset_label) + s.pad_x,
      reset_sel_n = reset_sel_n, reset_note_n = reset_note_n,
    }

    local close_clicked = false
    for r, row in ipairs(plan.rows) do
      for i, id in ipairs(row) do
        if i > 1 then reaper.ImGui_SameLine(ctx, 0, hdr_gap_before(id)) end
        hdr_draw_element(id, hs)
        if id == "reset" and reason then
          -- The reason goes after Reset, in space the right group does not need: nothing moves for it
          reaper.ImGui_SameLine(ctx, 0, L.md)
          local left = reaper.ImGui_GetContentRegionAvail(ctx) - ((r == 1) and (L.lg + s.right_w) or 0)
          if left >= hdr_text_w(reason) then
            Theme.align(ctx)
            reaper.ImGui_TextColored(ctx, P.text_dim, reason)
          end
        end
      end
      if r == 1 then close_clicked = hdr_draw_right(hs) end
    end
    return close_clicked
  end
end

-------------------------------------------------------------------------------
-- BOTTOM DOCK
-------------------------------------------------------------------------------
-- Two groups, drawn in every state (disabled, with the reason, when there is nothing to act on):
-- the Inspector (Correction Strength slider + Transition / Onset Ramp / Legato Gap badges) and the Actions strip (Snap, Quantize,
-- Split, Merge). plan_dock() flows the groups onto as many rows as the width needs, from the width alone
-- (never from the selection or the status text), so nothing under the cursor moves while working; loop_body
-- asks it for the row count BEFORE it lays out the canvas. The status / hint text takes the room left after
-- the last control row when there is enough, else a row of its own. The selection count and the key / scale
-- sit in a right-aligned slot of that row.

-- Chunk-level names of this section: everything else stays private to the block below, so it does not
-- count against the chunk's 200-local limit.
local plan_dock, layout_dock_texts, mark_stale_takes, render_bottom_dock

do
  -- The Correction Strength slider's label: the full name, or the short one when the full name would cost the dock a row
  -- (plan_dock decides from the width alone; the tooltip always carries the full name)
  local DOCK_STRENGTH_LABEL = PARAM_LABELS.retune_speed
  local DOCK_STRENGTH_SHORT = "Correction"
  -- Where a value comes from, in words (the badge colour is only a second cue): the strength slider shows it after itself
  local DOCK_SCOPE_TAGS = K.SCOPE_TAGS
  -- Appended to a badge label when its value is overridden for the item (or the selected note)
  local DOCK_OVERRIDE_MARK = "*"
  -- Why the controls are disabled (the state hint below is the inline reason; the tooltips repeat these)
  local DOCK_REASON_ANALYZING = "Wait for the analysis to finish"
  local DOCK_REASON_NO_TARGET = "Select an audio item"
  local DOCK_REASON_NOT_ANALYZED = "Analyze an item first"
  local DOCK_REASON_NOTE_OVERRIDE = "Overridden on this note. Right-click the note to change it."
  local DOCK_HINT_NO_TARGET = "Select an audio item in REAPER"
  local DOCK_HINT_NO_NOTES = "No pitched notes found. Try Vocal Range or Detection Mode in Settings"
  local DOCK_HINT_SELECT_NOTE = "Select a note to edit it"

  -- Value badges: label format, edit range. The item override menu and the edit popup use the key.
  local DOCK_BADGES = {
    { id = "trans",  key = "transition_ms",       fmt = "Transition: %.0fms", min = 5,  max = 60 },
    { id = "ramp",   key = "onset_ramp_ms",       fmt = "Onset Ramp: %.0fms", min = 5,  max = 60 },
    { id = "legato", key = "legato_threshold_ms", fmt = "Legato Gap: %.0fms", min = 50, max = 300 },
  }
  -- Actions strip: same commands as the keys
  local DOCK_ACTIONS = {
    { id = "snap",     label = "Snap",     tip = "Snap to nearest semitone (S)" },
    { id = "quantize", label = "Quantize", tip = "Quantize to the active scale (Q)" },
    { id = "split",    label = "Split",    tip = "Split at the edit cursor (X)" },
    { id = "merge",    label = "Merge",    tip = "Merge the selected notes (M)" },
  }
  local DOCK_BADGE_BY_ID, DOCK_ACTION_BY_ID = {}, {}
  for _, spec in ipairs(DOCK_BADGES) do DOCK_BADGE_BY_ID[spec.id] = spec end
  for _, spec in ipairs(DOCK_ACTIONS) do DOCK_ACTION_BY_ID[spec.id] = spec end
  -- The status text follows the controls on their last row only when at least this much text fits there
  local DOCK_STATUS_MIN_SAMPLE = DOCK_HINT_NO_TARGET

  local function dock_text_w(dock_ctx, text)
    return (reaper.ImGui_CalcTextSize(dock_ctx, text)) or 0
  end

  --- Widths that depend only on the font and the tokens: every label is measured at its longest, so a value,
  --- an override mark or a selection never changes the layout.
  local function measure_dock(dock_ctx)
    local L = Theme.layout
    local s = {}
    s.frame_h = reaper.ImGui_GetFrameHeight(dock_ctx) or 0
    s.pad_x = L.md * 2                  -- FramePadding.x on both sides of a label (what Theme.badge and Button use)
    s.slider_w = L.xxxl * 2 + L.md
    s.edit_w = L.xxxl * 4               -- the drag inside a badge's edit popup
    s.scope_w = 0
    for _, tag in pairs(DOCK_SCOPE_TAGS) do s.scope_w = math.max(s.scope_w, dock_text_w(dock_ctx, tag)) end
    s.strength_w = {}   -- width of the slider unit, by the label it shows
    for _, label in ipairs({ DOCK_STRENGTH_LABEL, DOCK_STRENGTH_SHORT }) do
      s.strength_w[label] = dock_text_w(dock_ctx, label) + L.sm + s.slider_w + L.sm + s.scope_w
    end
    s.badge_w, s.action_w = {}, {}
    local mark_w = dock_text_w(dock_ctx, DOCK_OVERRIDE_MARK)
    for _, spec in ipairs(DOCK_BADGES) do
      local widest = math.max(dock_text_w(dock_ctx, string.format(spec.fmt, spec.min)),
        dock_text_w(dock_ctx, string.format(spec.fmt, spec.max)))
      s.badge_w[spec.id] = widest + mark_w + s.pad_x
    end
    for _, spec in ipairs(DOCK_ACTIONS) do
      s.action_w[spec.id] = dock_text_w(dock_ctx, spec.label) + s.pad_x
    end
    s.status_min_w = dock_text_w(dock_ctx, DOCK_STATUS_MIN_SAMPLE)
    return s
  end

  --- Lay the dock out for a content width: `rows` is a list of rows of { id, x, w } (x from the row start), and
  --- `row_count` includes the status row when the status text needs a row of its own. Inspector and Actions
  --- share a row when both fit (a group gap apart), else Actions starts a new row; a group wider than a row
  --- wraps unit by unit. Gaps grow with the distance (LG1): L.sm inside a unit (the strength label, slider and
  --- scope tag) and between the action buttons, L.md between the Inspector's units, L.lg between the groups.
  plan_dock = function(dock_ctx, avail_w)
    local L = Theme.layout
    local s = measure_dock(dock_ctx)
    avail_w = math.max(0, avail_w or 0)

    local actions = {}
    for _, spec in ipairs(DOCK_ACTIONS) do actions[#actions + 1] = { id = spec.id, w = s.action_w[spec.id] } end

    --- The plan for one label of the strength slider.
    local function flow(strength_label)
      local inspector = { { id = "retune", w = s.strength_w[strength_label] } }
      for _, spec in ipairs(DOCK_BADGES) do inspector[#inspector + 1] = { id = spec.id, w = s.badge_w[spec.id] } end

      local rows, row, row_w = {}, {}, 0
      rows[1] = row
      for _, group in ipairs({ inspector, actions }) do
        local unit_gap = (group == inspector) and L.md or L.sm
        local group_w = 0
        for i, unit in ipairs(group) do group_w = group_w + unit.w + ((i > 1) and unit_gap or 0) end
        local lead_gap = 0
        if #row > 0 then
          if row_w + L.lg + group_w <= avail_w then
            lead_gap = L.lg
          else
            row, row_w = {}, 0
            rows[#rows + 1] = row
          end
        end
        for i, unit in ipairs(group) do
          local gap = (i == 1) and lead_gap or unit_gap
          if #row > 0 and row_w + gap + unit.w > avail_w then
            row, row_w, gap = {}, 0, 0
            rows[#rows + 1] = row
          end
          local x = (#row > 0) and (row_w + gap) or 0
          row[#row + 1] = { id = unit.id, x = x, w = unit.w }
          row_w = x + unit.w
        end
      end

      local status_x = row_w + L.lg
      local inline = (avail_w - status_x) >= s.status_min_w
      if not inline then status_x = 0 end
      return {
        s = s, rows = rows, avail_w = avail_w, status_inline = inline, status_x = status_x,
        row_count = #rows + (inline and 0 or 1), strength_label = strength_label,
      }
    end

    -- The full name, unless the short one saves a row
    local plan = flow(DOCK_STRENGTH_LABEL)
    local short = flow(DOCK_STRENGTH_SHORT)
    if short.row_count < plan.row_count then plan = short end
    return plan
  end

  --- Place the status / hint text (left) and the selection / key text (right-aligned) in the room from x0 to
  --- the row end. The message wins: when both do not fit, only the message is drawn (truncated to the room).
  --- Never returns an offset left of x0. Returns left text, right text, offset of the right text.
  layout_dock_texts = function(dock_ctx, x0, avail_w, left_text, right_text)
    local L = Theme.layout
    local room = math.max(0, avail_w - x0)
    if room <= 0 then return "", "", x0 end
    local left_w = (left_text ~= "") and dock_text_w(dock_ctx, left_text) or 0
    local right_w = dock_text_w(dock_ctx, right_text)
    if left_w + ((left_w > 0) and L.lg or 0) + right_w <= room then
      return left_text, right_text, x0 + room - right_w
    end
    if left_w > 0 then
      local fitted = hdr_fit_text(left_text, room)
      if dock_text_w(dock_ctx, fitted) > room then return "", "", x0 end
      return fitted, "", x0
    end
    local fitted = hdr_fit_text(right_text, room)
    local fitted_w = dock_text_w(dock_ctx, fitted)
    if fitted_w > room then return "", "", x0 end
    return "", fitted, x0 + room - fitted_w
  end

  --- Flag the other session items whose stored envelope was written with the old global default of `key`:
  --- those without an item value for it and with an edited note that inherits it (an untouched item has no
  --- envelope to go stale). Returns how many were flagged.
  mark_stale_takes = function(key)
    local n = 0
    for _, guid in ipairs(state.session_order) do
      if guid ~= state.target_take_guid and K.inherits_global(state.session_takes[guid], key) then
        state.stale_takes[guid] = true
        n = n + 1
      end
    end
    return n
  end

  --- Status text of a global default change / reset: it is saved outside the undo history, and the other
  --- items keep the envelope they have until they are edited.
  local function global_change_status(prefix, stale_n)
    if stale_n <= 0 then return prefix end
    if stale_n == 1 then
      return prefix .. ". 1 other item keeps its old envelope until edited."
    end
    return string.format("%s. %d other items keep their old envelope until edited.", prefix, stale_n)
  end

  --- Where a value comes from, for tooltips. `marked` = the badge form, which explains its trailing mark.
  local function dock_scope_tip(level, marked)
    if level == "note" then return DOCK_REASON_NOTE_OVERRIDE end
    if level == "item" then
      return marked and (DOCK_OVERRIDE_MARK .. " = overridden for this item") or "Overridden for this item."
    end
    if marked then return "Global default, used by every item without its own value. A " .. DOCK_OVERRIDE_MARK .. " marks an item override." end
    return "Global default, used by every item without its own value."
  end

  --- `has_target` / `target_item` come from loop_body (the header's view of the target); `plan` from plan_dock.
  render_bottom_dock = function(dock_ctx, has_target, target_item, plan)
    local P = Theme.get_palette()
    local L = Theme.layout
    if has_target == nil then has_target = (state.target_take_guid ~= nil) end
    plan = plan or plan_dock(dock_ctx, reaper.ImGui_GetContentRegionAvail(dock_ctx))
    local s = plan.s

    -- A status message (set_status) replaces the hint text until it expires
    local status_text = nil
    if state.status.text ~= "" and reaper.time_precise() < state.status.until_time then
      status_text = state.status.text
    end

    local has_data = (#state.results > 0 and state.notes ~= nil and #state.notes > 0)
    local take_data = state.target_take_guid and state.session_takes[state.target_take_guid] or nil

    -- Selection: how many notes, and the note itself when there is exactly one
    local sel_count, sel_idx = 0, nil
    if state.notes then
      for idx in pairs(state.selected_notes) do
        if state.notes[idx] then sel_count = sel_count + 1; sel_idx = idx end
      end
      if sel_count == 0 and state.selected_note and state.notes[state.selected_note] then
        sel_count, sel_idx = 1, state.selected_note
      end
    end
    local single_note = (sel_count == 1) and state.notes[sel_idx] or nil

    -- Why the Inspector and Actions are disabled (nil = usable)
    local inspector_reason = nil
    if state.is_analyzing then
      inspector_reason = DOCK_REASON_ANALYZING
    elseif not has_target then
      inspector_reason = DOCK_REASON_NO_TARGET
    elseif not has_data then
      inspector_reason = DOCK_REASON_NOT_ANALYZED
    end

    -- The state line: what the window is doing / waiting for (a status message replaces it)
    local hint = ""
    local target_name = state.target_take_name or "this item"
    if state.is_analyzing then
      hint = string.format("Analyzing %s… %d%%", target_name, math.floor((state.progress or 0) * 100))
    elseif not has_target then
      hint = state.selection_issue or DOCK_HINT_NO_TARGET
    elseif has_data then
      if sel_count == 0 then hint = DOCK_HINT_SELECT_NOTE end
    elseif state.analysis_empty then
      hint = DOCK_HINT_NO_NOTES
    else
      hint = string.format("Ready to analyze %s", target_name)
    end

    --- Value and where it comes from for a cascade key: the selected note's own value when it has one
    local function cascade_view(key)
      local value = get_effective(single_note, key)
      if value == nil then value = DEFAULTS[key] end
      return value, get_override_level(single_note, key)
    end

    --- Write an edited value: to the item override when there is one, else to the global default. The global default is
    --- saved (K.save_settings) when the edit is committed, not on every frame of a drag.
    local function write_cascade_value(key, v)
      if take_data and take_data.overrides and take_data.overrides[key] ~= nil then
        take_data.overrides[key] = v
      else
        global_defaults[key] = v
      end
    end

    --- Undo point of re-writing the target's envelope after a global default changed: Cmd+Z reverts that envelope
    --- (and the stored model), never the global default itself, so the name says what it reverts.
    local function global_undo_label(key)
      return string.format("Apply Global %s to Item Envelope", PARAM_LABELS[key] or key)
    end

    --- A drag / typed / wheel edit of a cascade value was committed (the value is already written by
    --- write_cascade_value). An item override is project state: one undo point. A global default is saved
    --- outside the undo history: it is saved, the target's envelope is re-written with it (an undo point that
    --- reverts only that envelope; after such an undo the item is flagged stale, see K.refresh_stale_flag), and
    --- the status line always says it is not undoable (and how many other items keep their old envelope).
    local function commit_cascade_edit(key)
      local name = PARAM_LABELS[key] or key
      if take_data and take_data.overrides and take_data.overrides[key] ~= nil then
        apply_envelope_to_take("Adjust Item " .. name)
        return
      end
      K.save_settings("cascade")
      if take_data then apply_envelope_to_take(global_undo_label(key)) end
      set_status(global_change_status("Global default changed (not undoable)", mark_stale_takes(key)))
    end

    --- Item override on / off (right-click menu): a new override starts at the current global default.
    local function toggle_item_override(key)
      if not take_data then return end
      take_data.overrides = take_data.overrides or {}
      if take_data.overrides[key] ~= nil then
        take_data.overrides[key] = nil
      else
        take_data.overrides[key] = global_defaults[key]
      end
      apply_envelope_to_take("Toggle Item Override: " .. (PARAM_LABELS[key] or key))
    end

    --- Double-click / "Reset to default": an item override goes back to inheriting (one undo point);
    --- otherwise the global default returns to its DEFAULTS value, which is saved and applied to the take
    --- but not part of the undo history.
    local function reset_cascade_param(key)
      local name = PARAM_LABELS[key] or key
      if take_data and take_data.overrides and take_data.overrides[key] ~= nil then
        take_data.overrides[key] = nil
        apply_envelope_to_take("Reset Item Override: " .. name)
      elseif DEFAULTS[key] ~= nil and global_defaults[key] ~= DEFAULTS[key] then
        global_defaults[key] = DEFAULTS[key]
        K.save_settings("cascade")
        if take_data then apply_envelope_to_take(global_undo_label(key)) end
        set_status(global_change_status("Global default changed (not undoable)", mark_stale_takes(key)))
      end
    end

    --- Right-click menu of a cascade control (call right after the control).
    local function item_override_menu(key)
      if not reaper.ImGui_BeginPopupContextItem(dock_ctx, "##ctx_" .. key) then return end
      -- HC5: Esc closes this menu (innermost)
      if reaper.ImGui_Shortcut(dock_ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(dock_ctx) end
      local has_override = take_data ~= nil and take_data.overrides ~= nil and take_data.overrides[key] ~= nil
      if reaper.ImGui_MenuItem(dock_ctx, "Override for this item", nil, has_override, take_data ~= nil) then
        toggle_item_override(key)
      end
      if reaper.ImGui_MenuItem(dock_ctx, "Reset to default") then
        reset_cascade_param(key)
      end
      reaper.ImGui_EndPopup(dock_ctx)
    end

    --- Tooltip for the item just drawn, gated on the hover delay. A disabled item passes
    --- HoveredFlags_AllowWhenDisabled as `extra_flags` so its reason still shows.
    local function dock_tooltip(text, extra_flags)
      local flags = reaper.ImGui_HoveredFlags_ForTooltip() | (extra_flags or 0)
      if reaper.ImGui_IsItemHovered(dock_ctx, flags) and not reaper.ImGui_IsItemActive(dock_ctx) then
        Theme.tooltip(dock_ctx, text)
      end
    end

    local function draw_retune()
      local value, level = cascade_view("retune_speed")
      local disabled = (inspector_reason ~= nil) or (level == "note")
      Theme.align(dock_ctx)
      reaper.ImGui_TextDisabled(dock_ctx, plan.strength_label or DOCK_STRENGTH_LABEL)
      reaper.ImGui_SameLine(dock_ctx, 0, L.sm)

      reaper.ImGui_BeginDisabled(dock_ctx, disabled)
      reaper.ImGui_PushItemWidth(dock_ctx, s.slider_w)
      local rs_c, rs_v, rs_committed, rs_reset = param_drag(dock_ctx, "rt_speed", nil, value * 100, 0, 100, "%.0f%%")
      reaper.ImGui_PopItemWidth(dock_ctx)
      reaper.ImGui_EndDisabled(dock_ctx)

      if inspector_reason then
        dock_tooltip(inspector_reason, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
      elseif level == "note" then
        dock_tooltip(DOCK_REASON_NOTE_OVERRIDE, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
      else
        dock_tooltip(string.format("%s: how much of the pitch correction is applied.\n%s\nDrag to change (%s-drag: fine adjust). Double-click: reset. Right-click: item override.",
          DOCK_STRENGTH_LABEL, dock_scope_tip(level, false), K.MOD_LABEL))
      end
      if not disabled then
        item_override_menu("retune_speed")
        if rs_reset then
          reset_cascade_param("retune_speed")
        else
          if rs_c then write_cascade_value("retune_speed", rs_v / 100) end
          if rs_committed then commit_cascade_edit("retune_speed") end   -- the edit is over: one write, one undo point
        end
      end

      reaper.ImGui_SameLine(dock_ctx, 0, L.sm)
      Theme.align(dock_ctx)
      reaper.ImGui_TextColored(dock_ctx, P.text_dim, DOCK_SCOPE_TAGS[level] or DOCK_SCOPE_TAGS.global)
    end

    local function draw_badge(spec)
      local key = spec.key
      local value, level = cascade_view(key)
      local disabled = (inspector_reason ~= nil) or (level == "note")
      local fg, bg = P.text_dim, P.card
      if level == "note" then
        fg, bg = P.accent2_l, P.accent2_d
      elseif level == "item" then
        fg, bg = P.accent_l, P.accent_d
      end
      local txt = string.format(spec.fmt, value) .. ((level ~= "global") and DOCK_OVERRIDE_MARK or "")

      Theme.align(dock_ctx)
      reaper.ImGui_BeginDisabled(dock_ctx, disabled)
      local pressed = Theme.badge(dock_ctx, txt, {
        color = fg, bg = bg, interactive = true, id = "dock_" .. spec.id, w = s.badge_w[spec.id],
      })
      reaper.ImGui_EndDisabled(dock_ctx)

      if inspector_reason then
        dock_tooltip(inspector_reason, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
      elseif level == "note" then
        dock_tooltip(DOCK_REASON_NOTE_OVERRIDE, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
      else
        dock_tooltip(string.format("%s: %.0f ms\n%s\nLeft-click to edit. Right-click for item override and reset.",
          PARAM_LABELS[key] or key, value, dock_scope_tip(level, true)))
      end

      if not disabled then item_override_menu(key) end
      if pressed then
        reaper.ImGui_OpenPopup(dock_ctx, "##edit_" .. key)
      end

      if reaper.ImGui_BeginPopup(dock_ctx, "##edit_" .. key) then
        -- HC5: Esc closes this editor, unless its typed-entry popup is open: that one is innermost
        if not reaper.ImGui_IsPopupOpen(dock_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
           and reaper.ImGui_Shortcut(dock_ctx, reaper.ImGui_Key_Escape()) then
          reaper.ImGui_CloseCurrentPopup(dock_ctx)
        end
        reaper.ImGui_PushItemWidth(dock_ctx, s.edit_w)
        local c, v, committed, reset = param_drag(dock_ctx, "s_" .. key, nil, value, spec.min, spec.max, "%.0f ms")
        if reset then
          reset_cascade_param(key)
        else
          if c then write_cascade_value(key, v) end
          if committed then commit_cascade_edit(key) end
        end
        reaper.ImGui_PopItemWidth(dock_ctx)
        reaper.ImGui_EndPopup(dock_ctx)
      end
    end

    --- The edit cursor relative to the target item's start (note times are item-relative); nil when unknown
    local function edit_cursor_offset()
      local item = target_item
      if not item then
        local _, target = K.frame_target()
        item = target
      end
      if not item then return nil end
      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local cursor = reaper.GetCursorPosition()
      if not item_pos or not cursor then return nil end
      return cursor - item_pos
    end

    -- Split needs the edit cursor strictly inside the selected note, as the X key does (asked once per frame)
    local cursor_in_note_cache = nil
    local function edit_cursor_in_note(note)
      if cursor_in_note_cache == nil then
        local t = edit_cursor_offset()
        cursor_in_note_cache = (note ~= nil and t ~= nil and t > note.start_time and t < note.end_time)
      end
      return cursor_in_note_cache
    end

    --- Why an action is unavailable (nil = available)
    local function action_reason(id)
      if inspector_reason then return inspector_reason end
      if id == "merge" then
        if sel_count < 2 then return "Select 2 or more notes" end
        return nil
      end
      if sel_count == 0 then return "Select a note" end
      if id == "split" then
        if sel_count > 1 then return "Select one note to split" end
        if not edit_cursor_in_note(single_note) then return "Move the edit cursor into the selected note" end
      end
      return nil
    end

    local function draw_action(spec)
      local reason = action_reason(spec.id)
      reaper.ImGui_BeginDisabled(dock_ctx, reason ~= nil)
      local clicked = reaper.ImGui_Button(dock_ctx, spec.label .. "###dock_" .. spec.id, s.action_w[spec.id], 0)
      reaper.ImGui_EndDisabled(dock_ctx)
      dock_tooltip(reason and (spec.tip .. "\n" .. reason) or spec.tip,
        reason and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
      if clicked and not reason then K.note_action(spec.id, sel_idx) end
    end

    -- Controls: the rows planned from the width; every unit sits at its planned x, whatever its neighbours drew
    local left_x = reaper.ImGui_GetCursorPosX(dock_ctx) or 0
    for _, row in ipairs(plan.rows) do
      for i, unit in ipairs(row) do
        if i > 1 then reaper.ImGui_SameLine(dock_ctx, left_x + unit.x, 0) end
        if unit.id == "retune" then
          draw_retune()
        elseif DOCK_BADGE_BY_ID[unit.id] then
          draw_badge(DOCK_BADGE_BY_ID[unit.id])
        else
          draw_action(DOCK_ACTION_BY_ID[unit.id])
        end
      end
    end

    -- Status / hint text (left) and selection count + key / scale (right-aligned): the message replaces the hint
    local scale_str = string.format("%s %s", SCALE_KEYS[state.key_idx].display, SCALE_DEFINITIONS[state.scale_idx].name)
    local right_text = (sel_count > 0) and string.format("%d Selected  •  %s", sel_count, scale_str) or scale_str
    -- EP2: with notes selected, why Split / Merge are disabled stays readable inline (not in a tooltip only): it fills
    -- the hint line while no status message is showing
    if hint == "" and has_data and sel_count > 0 and not inspector_reason then
      local reasons = {}
      for _, id in ipairs({ "split", "merge" }) do
        local why = action_reason(id)
        if why then
          reasons[#reasons + 1] = string.format("%s: %s%s", DOCK_ACTION_BY_ID[id].label, why:sub(1, 1):lower(), why:sub(2))
        end
      end
      hint = table.concat(reasons, "  ·  ")
    end
    local wanted = status_text or hint
    local left_text, right_shown, right_x = layout_dock_texts(dock_ctx, plan.status_x, plan.avail_w, wanted, right_text)
    -- Inline, the text continues the last control row; otherwise it opens the row the plan reserved
    if left_text ~= "" then
      if plan.status_inline then reaper.ImGui_SameLine(dock_ctx, left_x + plan.status_x, 0) end
      Theme.align(dock_ctx)
      reaper.ImGui_TextColored(dock_ctx, P.text_dim, left_text)
      if left_text ~= wanted then dock_tooltip(wanted) end
    elseif not plan.status_inline then
      reaper.ImGui_Dummy(dock_ctx, 0, s.frame_h)   -- the row exists even when there is nothing to say
    end
    if right_shown ~= "" then
      reaper.ImGui_SameLine(dock_ctx, left_x + right_x, 0)
      Theme.align(dock_ctx)
      reaper.ImGui_TextColored(dock_ctx, P.text_dim, right_shown)
    end
  end
end

local function loop_body()
  -- What REAPER answered earlier stays valid only while the project state is the same: check that first, before
  -- anything reads it (the target of the previous frame is not trusted either)
  K.refresh_project_cache()
  state.frame.guid, state.frame.take, state.frame.item = nil, nil, nil

  -- Follow REAPER's undo / redo / project changes (one cheap count check per frame)
  sync_with_project()
  process_analysis_step()

  local P = Theme.get_palette()
  local L = Theme.layout
  local nc, nv = Theme.push(ctx, P)
  local pushed_font = Theme.push_font(ctx, fonts.default)

  local pad_x = L.md + L.xs
  local pad_v = L.sm + L.xs
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), pad_x, pad_v)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), L.md, pad_v)
  nv = nv + 2

  -- First use: K.FIRST_USE_W x K.FIRST_USE_H, wider when the full header (title, Key: / Scale: labels, one row) needs
  -- it, so it opens unabbreviated. A saved size wins over this (Cond_FirstUseEver)
  hdr_static = hdr_static or measure_header_static()
  Theme.center_next_window(ctx, math.max(K.FIRST_USE_W, math.ceil(hdr_min_content_w(hdr_static, true) + pad_x * 2)),
    K.FIRST_USE_H, reaper.ImGui_Cond_FirstUseEver())
  -- A floating window never gets narrower than the header needs (two rows); a docked one takes its
  -- dock's size, and the header wraps further to fit (see HEADER BAR)
  if hdr_was_docked == false then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx,
      hdr_min_content_w(hdr_static) + pad_x * 2,
      hdr_static.frame_h + pad_v * 3 + hdr_static.row_h * 2,
      K.SIZE_UNBOUNDED, K.SIZE_UNBOUNDED)
  end
  local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoNavInputs()

  local visible, open = reaper.ImGui_Begin(ctx, 'Fancy Pitch Correct', true, win_flags)
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
      -- Why the selected item cannot be a target (the dock hint and the badge tooltip say it); nil for an
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
            state.view_t0, state.view_t1 = nil, nil
            state.start_time = 0
            state.item_len = reaper.GetMediaItemInfo_Value(cur_sel_item, "D_LENGTH")
            state.end_time = state.item_len
          end
        end
      end
    end

    -- The target, asked once per frame: the header, canvas, dock and sidebar read it from state.frame
    local target_take, target_item = get_target_take()
    state.frame.guid, state.frame.take, state.frame.item = state.target_take_guid, target_take, target_item
    local has_target = (target_take ~= nil and state.target_take_name ~= nil)
    local has_notes = (state.notes and #state.notes > 0)

    -- 1. Header bar (widths and wrapping: see HEADER BAR above)
    if draw_header(P, docked, has_target, has_notes, target_take, target_item) then
      open = false
    end

    -- 2. Main Body: Canvas + (optional) Pitched Items Sidebar
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    -- The dock's real height: its rows for this width (see BOTTOM DOCK), each a frame tall with the item
    -- spacing between them, plus the spacing between the body and the first row
    local dock_plan = plan_dock(ctx, avail_w)
    local footer_h = dock_plan.row_count * (dock_plan.s.frame_h + pad_v)
    local body_h = avail_h - footer_h
    local total_h = math.max(60, body_h)

    -- The panel is drawn only when the window has room for it beside a usable canvas; otherwise the
    -- tag layout takes over without touching the saved open / closed preference
    local sidebar_fits = avail_w >= BODY.min_graph_w + BODY.splitter_w + BODY.min_sidebar_w
    local split_drawn = false
    if total_h > 80 then
      if state.sidebar_open and sidebar_fits then
        split_drawn = draw_body_split(P, avail_w, total_h)
      else
        draw_body_tag(P, avail_w, total_h, sidebar_fits)
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

    -- 4. Bottom Row: Inspector & Action Bar
    render_bottom_dock(ctx, has_target, target_item, dock_plan)
  end

  -- Pop custom window padding & item spacing before rendering modals
  reaper.ImGui_PopStyleVar(ctx, 2)
  nv = nv - 2

  -- 5. Render Modals (ReaImGui's Begin calls End itself when it returns false)
  if visible then
    draw_settings_modal()
    draw_info_modal()
    draw_confirm_modal()

    -- HC5: Esc, innermost first, only through Shortcut(). Modals own Esc while open (handled inside each
    -- BeginPopupModal); an active edit consumes it itself. What is left: the note selection, then the
    -- window, which closes on Esc only when it is floating.
    if not popup_open_at_start
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

    reaper.ImGui_End(ctx)
  end

  -- Arrow-key nudge burst: commit when the key is released; always before the window closes or hides,
  -- or a popup / modal opens
  local popup_open = visible and reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
  service_nudge_burst(not visible or not open or popup_open)

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
      return
    end
  else
    ok, open = xpcall(loop_body, debug.traceback)
    if ok then
      state.error_streak = 0
    else
      reaper.ShowConsoleMsg("Fancy Pitch Correct Error: " .. tostring(open) .. "\n")
      pcall(K.cancel_analysis)
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
  end
end

-------------------------------------------------------------------------------
-- 5. MAIN
-------------------------------------------------------------------------------
local function main()
  -- The toolbar button shows the script as running and resets when it ends; closing the window or ending the script
  -- mid-analysis also destroys the audio accessor
  local Utils = require("utils")
  local release_toolbar = Utils.init_toolbar_toggle()
  reaper.atexit(function()
    K.release_analysis()
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

  loop()
end

main()
