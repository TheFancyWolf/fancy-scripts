-- @noindex
-- Fancy Pitch Correct: defaults, settings, the shared state and the project-state cache.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local Theme = App.Theme
local BLOCK_SIZES = App.BLOCK_SIZES
local DEFAULT_PITCH_MODE_IDX = App.DEFAULT_PITCH_MODE_IDX
local DETECTION_MODES = App.DETECTION_MODES
local HOP_SIZES = App.HOP_SIZES
local PITCHMODE_FLAT = App.PITCHMODE_FLAT
local QUALITY_MODES = App.QUALITY_MODES
local SCALE_DEFINITIONS = App.SCALE_DEFINITIONS
local SCALE_KEYS = App.SCALE_KEYS
local VOCAL_RANGES = App.VOCAL_RANGES

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
  tolerance = 8,             -- 0–50 cents a tightened note may stray from its centre untouched
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
  tolerance = DEFAULTS.tolerance,
}

-- User-facing names for the value controls (used in undo labels; never show raw keys)
local PARAM_LABELS = {
  retune_speed = "Correction Strength",
  transition_ms = "Transition",
  onset_ramp_ms = "Onset Ramp",
  legato_threshold_ms = "Legato Gap",
  scoop_shape = "Scoop Shape", -- per-note only (the top bar's Timing row, note context menu)
  tighten = "Tighten",         -- per-note only (the top bar, the left side of a note, note context menu)
  tolerance = "Tolerance",
}

-- Named constants, in one table so they take a single one of the chunk's 200 locals
local K = {
  -- Take extension key holding the analysis / note model (JSON)
  TAKE_DATA_KEY = "P_EXT:fancy_pitch_data",

  -- The most a Scoop may move one onset frame, in semitones (see K.correction_build)
  SCOOP_MAX_ST = 3.0,

  -- How long a status message replaces the hint on the canvas's status pill
  STATUS_SECONDS = 4.0,

  -- Platform label of REAPER's command modifier, for "Cmd+Z to undo" style messages
  -- GetOS() is "OSX32"/"OSX64" on Intel Macs and "macOS-arm64" on Apple Silicon
  MOD_LABEL = (function()
    local os_name = reaper.GetOS() or ""
    return (os_name:match("OSX") or os_name:match("macOS")) and "Cmd" or "Ctrl"
  end)(),

  -- Ctrl/Cmd held during a note pitch drag scales the pixel-to-semitone movement by this factor (fine adjust)
  FINE_ADJUST_SCALE = 0.1,

  -- Hard limits start_analysis enforces on the engine sizes, whatever the UI or older state holds
  BLOCK_SIZE_MIN = 64,
  BLOCK_SIZE_MAX = 16384,

  -- The time one frame may spend reading and analysing audio before it yields to the window (seconds, measured with
  -- reaper.time_precise). Small on purpose: the window keeps answering (Cancel, Esc, scrolling) and the analysis
  -- simply takes more frames
  ANALYSIS_SLICE_S = 0.008,

  -- Analysis Cancel: More's Analyze item turns into this while an analysis runs (see hdr_draw_more)
  CANCEL_FMT = "Cancel %d%%",
  CANCELLED_TEXT = "Analysis cancelled.",

  -- Error recovery (see loop): the window shows this, with Retry and Close, instead of disappearing
  FATAL_TEXT = "Something went wrong. Your corrections on the items are unchanged.",
  FATAL_AGAIN_TEXT = "It happened again. If Retry keeps failing, close this window and open the script again.",

  -- An arrow-key nudge burst is committed this long (seconds) after its last event (see service_nudge_burst)
  NUDGE_IDLE_S = 0.25,

  -- Plain Space's fallback when the user bound none: Transport: Play/stop (see Space forwarding, HC6)
  SPACE_FALLBACK_CMD = 40044,

  -- Edit: Undo / Edit: Redo, run for Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z (see forward_undo_to_reaper)
  UNDO_CMD = 40029,
  REDO_CMD = 40030,

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
    tolerance = { 0, 50 },   -- cents
  },

  -- Note tone: a sine on the Monitoring FX chain (REAPER's JS: Tone Generator) that sounds while a note is dragged
  -- (see K.tone_tick). The P_* entries are its 0-based parameter indices; MON is added to an FX index to address the
  -- Monitoring FX chain, which lives on the master track
  TONE = {
    FX_NAME = "JS:synthesis/tonegenerator",   -- the path form: a third-party JSFX named "Tone Generator" never matches
    -- TrackFX_AddByName's instantiate value: <= -1000 is an insertion position, -1000 = first in the chain. First, so
    -- the tone passes through the user's own Monitoring FX (monitor trim, dim, correction) instead of bypassing them
    INSERT_FIRST = -1000,
    TAG = "Fancy Pitch Correct Tone",   -- the renamed_name that marks the effect as ours
    LEVEL_DB = -18,                     -- Wet Mix at full gain
    SILENT_DB = -120,                   -- Wet Mix when silent (the lowest the generator allows)
    RAMP_FRAMES = 3,                    -- frames a fade in or out takes (avoids clicks)
    BASE_HZ = 440,                      -- fixed Base Frequency; the pitch is set through Note / Octave / Fine Tune
    MIN_PITCH = 21,                     -- lowest MIDI pitch the tone follows (A0)
    MAX_PITCH = 127,
    P_WET = 0, P_DRY = 1, P_FREQ = 2, P_NOTE = 3, P_OCTAVE = 4, P_FINE = 5, P_SHAPE = 6,
    MON = 0x1000000,
  },

  -- The Pitched Items panel never gets narrower than this (BODY.min_sidebar_w); a stored width is checked against it
  SIDEBAR_MIN_W = 160,

  -- Timeline view of the canvas: zoom, scroll and ruler (see draw_graph)
  ZOOM_STEP = 1.25,        -- one Ctrl/Cmd + wheel notch divides (up) or multiplies (down) the visible span by this
  MIN_VIEW_SPAN_S = 0.25,  -- never zoom in beyond this many seconds (an item shorter than this cannot be zoomed)
  SCROLL_STEP = 0.1,       -- one wheel notch scrolls the window by this fraction of its span
  VIEW_EPS_S = 1e-6,       -- a window this close to the whole item counts as "not zoomed"
  RULER_MINOR_DIV = 5,     -- minor ticks per major tick
  RULER_WIDEN = 1.5,       -- a label interval that does not fit grows to the next 1-2-5 step above interval * this
  RULER_LABEL_ROOM = 2,    -- a label interval is at least this many times as wide as its widest label
  RULER_MAX_TRIES = 8,     -- widenings tried before the ruler gives up on making every label fit

  -- Pitch view of the canvas (see draw_graph): the range is fitted to the notes unless the user chose one
  PITCH_PAD_ST = 2,        -- semitones shown above the highest and below the lowest note
  PITCH_MIN_FIT_ST = 12,   -- the fitted range never shows fewer semitones than this (a one-note item is not one giant row)
  PITCH_MIN_VIEW_ST = 3,   -- never zoom the pitch axis in beyond this many semitones
  ZOOM_SEL_PAD = 0.1,      -- Z (zoom to selection): this fraction of the selection's length is added on each side ...
  ZOOM_SEL_PAD_ST = 3,     -- ... and this many semitones above and below
  WAVE_STEP_PX = 2,        -- the loudness envelope inside a note (the fallback, see below) is drawn in bars at least this wide
  -- The waveform inside the notes is the item's own peaks, as REAPER draws them in the arrange view (K.take_wave)
  WAVE_RATE = 400,         -- peaks asked per second of item: about the finest REAPER keeps in its peak files, so no audio is read
  WAVE_MAX_SAMPLES = 200000, -- ... but never more than this many for the whole item (a longer item gets a lower rate)
  WAVE_RETRY_S = 0.5,      -- peaks that are not built yet are asked for again after this long
  WAVE_COL_PX = 1,         -- the waveform is drawn in columns this wide
  LABEL_MAX_SELECTED = 8,  -- with more notes selected than this, only the hovered and the primary note carry a label

  -- Canvas colours are not defined here: draw_graph and the Layers menu swatches read the same Theme palette tokens
  -- (Theme.get_palette().canvas, see section 4A of _lib/theme.lua), which follow the theme mode.
  SPOT_R = Theme.layout.sm,                          -- smart-spot circle radius
  ANCHOR_R = Theme.layout.sm + Theme.layout.xs,      -- start / end point diamond half-diagonal
  EDIT_MARK = Theme.layout.sm + Theme.layout.xs,     -- side of the square that marks an edited note
  EDGE_GRAB = Theme.layout.sm * 2,                   -- note edge grab zone, per side
  EDGE_GRAB_HOVER = Theme.layout.sm * 3,             -- ... while the pointer rests on that edge
  EDGE_GRAB_MAX_FRAC = 0.25,                         -- a zone never takes more than this fraction of the block width (both edges stay usable)
  VIEW_GRIP = Theme.layout.md,                       -- grab width of each end of the overview / pitch strip thumb

  -- Pitch points (see K.points_knots): handles that bend a note's pitch at one moment
  POINT_MAX_ST = 3.0,                                -- the most one point may move the pitch, in semitones (±300 ¢)
  POINT_MIN_GAP = 3,                                 -- a detected dot this many frames or closer to a stored point is not a point
  POINT_GRAB = Theme.layout.sm * 2,                  -- grab distance around a drawn point, per side
  POINT_EPS = 0.005,                                 -- an offset under half a cent counts as 0
}

local state = {
  is_analyzing = false,
  progress = 0,
  results = {}, -- array of { time, freq, note }
  analysis_empty = false, -- the last analysis of the target found no pitched notes (the canvas message reads it)

  -- Note tone (see K.tone_tick)
  note_tone = true,      -- play the tone while a note is dragged
  tone = nil,            -- the running tone effect: { guid, gain (0..1 fade), note, octave, fine (last values sent) }
  tone_failed = false,   -- the effect could not be added; K.tone_tick does not retry until this is cleared

  -- Settings > Pitch Shift Engine: the algorithm written to the item (an entry of PITCHMODE_FLAT) and whether to write it at all
  preset_pitchmode_idx = DEFAULTS.preset_pitchmode_idx,
  pitchmode_value = PITCHMODE_FLAT[DEFAULTS.preset_pitchmode_idx].value,
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
  hovered_zone = nil,   -- "tighten" (left side) / "pitch" / "tolerance" (right side)
  hovered_edge = nil,   -- { note_idx, edge ("left"/"right") } for edge trimming
  selected_note = nil,  -- index of primary selected note (for single-note ops)
  selected_notes = {},  -- set { [note_idx] = true } for multi-select (merge, batch drag, quantize)
  -- Every gesture table also holds view_min / view_max: the pitch range frozen when it began (the vertical scale
  -- must not change under the cursor mid-gesture)
  drag = nil,           -- { note_idx, zone, shift_mode, start_mouse_y, last_y, pitch_st, acc, orig_values, raw_values, pending_single_select, dirty, view_min, view_max }
  edge_drag = nil,      -- { note_idx, edge, start_mouse_x, original_time, dirty, view_min, view_max }
  marquee = nil,        -- { start_x, start_y, cur_x, cur_y, active, has_shift, init_sel, view_min, view_max }
  -- A pitch point is named by { note_idx, frame } (its knot is looked up by frame: the knot tables are rebuilt)
  point_drag = nil,     -- { note_idx, frame, start_st, st, last_y, dirty, view_min, view_max }
  hovered_point = nil,  -- { note_idx, frame }
  point_ghost = nil,    -- { note_idx, frame }: where a double-click on the pitch line would add a point
  points_hover_note = nil, -- note index whose points stay shown: the pointer is in the box around its block and points
  points_zoom_hint = false, -- the hovered note's points are too small to grab (K.points_live): the status says zoom in
  shift_mode = false,   -- true when Shift held before click (zone remap)
  context_menu_note = nil, -- index of note for right-click context menu
  bar_edit = nil,       -- { id, notes, acc, raws, starts }: a top bar value is being dragged on the selected notes (see draw_value)
  timing_open = false,  -- the top bar's Timing row is shown (persisted)
  context_edit = nil,   -- { note, key, raw }: a note menu slider changed and not yet written (raw = the value before)
  context_menu_time = nil, -- the pointer's time (item seconds) when the note menu was opened
  context_menu_live = false, -- the note's points could be added to (K.points_live_at) when the note menu was opened
  context_point = nil,  -- { note_idx, frame, start_st }: the point the point menu ("##point_context_menu") is on
  -- The setting that is hovered or dragged (K.setting_hint): the canvas shades where it acts. key = cascade key
  -- or "scoop_shape"; notes = nil (every note the top bar value reaches) or a set of note indices; frame = the
  -- ImGui frame that reported it; said = the "nothing in view" status was posted for this drag
  setting_hint = { frame = -1, menu_set = {}, zone_set = {} },
  view_t0 = nil,        -- visible time window of the canvas, seconds relative to the item start; nil = the whole item
  view_t1 = nil,        -- (both nil or both set; changed by the wheel in draw_graph, reset when the target changes or the model is analysed or cleared, kept through undo / redo of the same take)
  view_p0 = nil,        -- visible pitch range of the canvas, semitones (MIDI note numbers); nil = fitted to the notes
  view_p1 = nil,        -- (both nil or both set; same lifetime as view_t0 / view_t1, see K.reset_view)
  view_drag = nil,      -- a drag on the overview strip or the pitch strip: { kind ("t_pan" / "t0" / "t1" / "p_pan" / "p0" / "p1"), start (pointer x or y), a0, a1 (the window when it began) }

  -- Visualization toggles
  show_note_blocks = true,
  show_raw_pitch = true,
  show_smart_spots = true,
  show_split_points = false,
  show_preview = true,

  -- Target item binding (persistent GUID lock)
  target_take_guid = nil,
  target_take_name = nil,

  -- Undo / model sync with REAPER
  last_change_count = nil,  -- GetProjectStateChangeCount(0) after the last own write / resync (nil = resync next frame)
  raw_cache = {},           -- [guid] = raw P_EXT string last written or loaded by this script
  missing_takes = {},       -- [guid] = true when the take no longer resolves (row is kept in the sidebar)
  stale_takes = {},         -- [guid] = true: the take's pitch envelope is not what today's settings and its notes would write (K.envelope_check)
  stale_env = {},           -- [guid] = { points }: the envelope a stale take really holds, for the preview curve of the open item
  stale_queue = {},         -- guids whose envelope is still to be compared (one per frame, K.stale_check_step)
  last_seen_sel_guid = nil, -- GUID of the first selected audio item seen last frame (edge-triggered tracker)
  nudge_burst = nil,        -- pending arrow-key nudge { total_st, last_time, keys = { up, down }, guid }

  -- What the script asked REAPER about, valid for one value of GetProjectStateChangeCount(0) of one project (see
  -- K.refresh_project_cache, K.drop_project_cache): takes by GUID (take = pointer, or false when the item is not in
  -- the project; scanned = the full item scan ran), the item of a take, and whether a take's pitch envelope is bypassed
  cache = { count = nil, proj = nil, takes = {}, items = {}, bypass = {} },
  -- The target as loop_body resolved it this frame (see K.frame_target)
  frame = { guid = nil, take = nil, item = nil },
  -- The canvas's drawing cache (see K.canvas_cache_begin): the mapping the cached coordinates belong to (map, gen counts
  -- its changes), the raw min / max and the loudest frame of the analysis, the item's waveform peaks, the raw pitch trace, and one entry per note (weak keys)
  draw_cache = { gen = 0, map = {}, range = { n = 0 }, peak = { n = 0, max = 0 }, wave = { n = 0 }, raw = {}, notes = setmetatable({}, { __mode = "k" }) },
  clipper = nil,            -- the Pitched Items list clipper (kept here so it is not garbage-collected)
  clipper_ctx = nil,        -- the ImGui context it was created for

  -- Status channel (drawn on the canvas's status pill, see K.canvas_status) and the pending confirmation request (see request_confirm)
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
  sidebar_open = true, -- side panel preference (defaults open); a window too narrow for it shows the canvas alone
  items_open = true,     -- the Pitched Items section of the panel is unfolded (header click)
  shortcuts_open = true, -- the Shortcuts section of the panel is unfolded (header click or H)
  sidebar_auto = false,  -- no panel width is stored: the first frame takes the width that fits the Shortcuts list
  sidebar_fits = true,   -- the window had room for the panel beside the canvas last frame (H reads it)
  items_content_h = nil, -- height of the Pitched Items section's content as drawn last frame (nil before the first)
  sidebar_gen = 0,     -- body table id generation: a new id makes ImGui take TableSetupColumn's width again (see draw_body_split)
  sidebar_tabled = false, -- the resizable body table was drawn last frame
  grip_hover_since = nil, -- time the mouse began resting on the divider between canvas and panel (its tooltip waits)
  grip_pressed = false,   -- a press began on that divider: the width is saved when the button is released
  selection_issue = nil,  -- why REAPER's first selected item cannot be a target (MIDI / no audio take); nil when it can or nothing is selected

  -- Key & Scale state
  key_idx = 1,       -- 1..12 (1 = C)
  scale_idx = 1,     -- 1..6 (1 = Major)
  scale_pc_set = {}  -- pitch class lookup set [0..11] = true/false
}

--- The canvas shows the whole item and the pitch range fitted to its notes again; a drag on a strip is dropped.
K.reset_view = function()
  state.view_t0, state.view_t1 = nil, nil
  state.view_p0, state.view_p1 = nil, nil
  state.view_drag = nil
end

--- Settings: choose the pitch algorithm written to the items (an index into PITCHMODE_FLAT).
K.set_pitch_algorithm = function(idx)
  local entry = PITCHMODE_FLAT[idx]
  if not entry then return end
  state.preset_pitchmode_idx = idx
  state.pitchmode_value = entry.value
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

--- Show a short message on the canvas's status pill for STATUS_SECONDS (it replaces the hint there).
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
  number("cascade", "pitch_tolerance", global_defaults, "tolerance", K.LIMITS.tolerance)

  -- Top bar: whether the Timing row is open, saved when it is toggled
  flag("bar", "pitch_timing_open", state, "timing_open")

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
  flag("layers", "pitch_show_split_points", state, "show_split_points")

  -- The note tone while a note is dragged, saved when the More menu item is toggled
  flag("tone", "pitch_note_tone", state, "note_tone")

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
  -- The two sections of the panel: anything but a stored "0" / "false" means unfolded
  local saved_items = reaper.GetExtState("FancyScripts", "pitch_items_open")
  state.items_open = not (saved_items == "0" or saved_items == "false")
  local saved_shortcuts = reaper.GetExtState("FancyScripts", "pitch_shortcuts_open")
  state.shortcuts_open = not (saved_shortcuts == "0" or saved_shortcuts == "false")

  -- Restore the global cascade defaults, the engine settings, the layers and the panel width
  K.load_settings()
  -- A panel the user never resized takes its width from the Shortcuts list (see K.panel_fit_w), on the first frame
  state.sidebar_auto = not reaper.HasExtState("FancyScripts", "pitch_sidebar_w")
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

--- The target of this frame: what loop_body resolved once at the start of the frame (state.frame), so the top bar,
--- canvas and sidebar do not each ask again. Only valid while the target is still the one that was resolved
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

-- What the files loaded after this one use
App.DEFAULTS = DEFAULTS
App.ensure_take_pitch_envelope = ensure_take_pitch_envelope
App.get_effective = get_effective
App.get_override_level = get_override_level
App.get_take_guid = get_take_guid
App.get_target_take = get_target_take
App.get_target_track_color = get_target_track_color
App.global_defaults = global_defaults
App.is_pitch_in_scale = is_pitch_in_scale
App.K = K
App.note_own_write = note_own_write
App.PARAM_LABELS = PARAM_LABELS
App.read_take_raw = read_take_raw
App.request_confirm = request_confirm
App.resolve_take_by_guid = resolve_take_by_guid
App.set_status = set_status
App.state = state
App.update_scale_pitch_classes = update_scale_pitch_classes
