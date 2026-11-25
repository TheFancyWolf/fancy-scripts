-- @description Fancy Pitch Correct
-- @author Fancy Scripts
-- @version 2.29.0
-- @changelog
--   Auto Vocal Range and Key: Vocal Range and Key have a new first choice, Auto (the default on a fresh install); Analyze first listens through the whole track once to find the singer's lowest and highest notes and the song's key, remembered per track in the project (Find Range and Key Again in the ... menu), a corrected key follows the track, Cancel works in both stages, and a hand-picked range and key skips the extra listening.
-- @about
--   Native Lua pitch correction and tracking.
--   Requirements: REAPER 7.0+, ReaImGui
-- @donation https://github.com/sponsors/TheFancyWolf
-- @link Website https://github.com/TheFancyWolf/fancy-scripts
-- @provides
--   [main] .
--   [nomain] ../_lib/*.lua
--   [nomain] ../_lib/fonts/*

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

-- "Auto" (auto = true) finds the range from the track before the analysis; its Hz are what an analysis with it uses
-- until then. Generic Vocal has the same Hz but is a range picked by hand (an entry matches by the flag first)
local VOCAL_RANGES = {
  { name = "Auto",          min = 65,  max = 1000, auto = true },
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
  -- ... both after its first choice, "Auto" (key index 0: the key is found from the track)
  table.insert(COMBO_LABELS.keys, 1, "Auto")
  table.insert(COMBO_LABELS.key_names, 1, "Auto")
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
-- control, every Settings "Reset" and "Reset section" restore its entry here; the initial `state` reads from it,
-- and every new or re-analysed item starts at these values (K.new_item_values).
local DEFAULTS = {
  -- Settings presets: the default pick of each list (an index into its table above; the algorithm into PITCHMODE_FLAT)
  preset_range_idx = 1,
  preset_mode_idx = 1,
  preset_quality_idx = 2,
  preset_pitchmode_idx = DEFAULT_PITCH_MODE_IDX,
  keep_pitch_mode = false,   -- Settings: leave each item's own pitch algorithm alone
  -- Item values (Item -> Note): every new or re-analysed item starts at these
  retune_speed = 1.0,        -- 0.0–1.0 (correction strength)
  tolerance = 8,             -- 0–50 cents a tightened note may stray from its centre untouched
  separation = 0.5,          -- 0–1 how readily the analysis splits notes (see K.separation_params)
  correct_mode = 0,          -- 0 Natural, 1 Classic, 2 Hard
  tighten = 0,               -- 0–1 how much of a note's wobble is taken out
  slide_in = 0,              -- 0–1 how much of the slide into a note is corrected
  note_bar_size = 2,         -- Settings > Appearance: the note action bar's size, an index into K.NOTE_BAR_SIZES (Medium)
}
-- Analysis engine (Settings > Advanced DSP): the values of the default presets, so a preset table and its default pick
-- can never drift apart
DEFAULTS.min_freq = VOCAL_RANGES[DEFAULTS.preset_range_idx].min
DEFAULTS.max_freq = VOCAL_RANGES[DEFAULTS.preset_range_idx].max
DEFAULTS.auto_range = VOCAL_RANGES[DEFAULTS.preset_range_idx].auto == true   -- Vocal Range "Auto"
DEFAULTS.threshold = DETECTION_MODES[DEFAULTS.preset_mode_idx].threshold
DEFAULTS.block_size = QUALITY_MODES[DEFAULTS.preset_quality_idx].block
DEFAULTS.hop_size = QUALITY_MODES[DEFAULTS.preset_quality_idx].hop   -- how many samples to advance per block

-- User-facing names for the value controls (used in undo labels; never show raw keys)
local PARAM_LABELS = {
  retune_speed = "Correction Strength",
  slide_in = "Slide In", -- per-note only (the top bar, Shift + drag on a note, note context menu)
  tighten = "Tighten",         -- per-note only (the top bar, the left side of a note, note context menu)
  tolerance = "Tolerance",
  correct_mode = "Mode",
  separation = "Separation",
}

-- Named constants, in one table so they take a single one of the chunk's 200 locals
local K = {
  -- Take extension key holding the analysis / note model (JSON)
  TAKE_DATA_KEY = "P_EXT:fancy_pitch_data",
  -- Track extension key holding the track's Track Default (JSON: only the value keys set); ExtState key prefix of
  -- the System Default of each value (pitch_def_<key>). See K.item_default
  TRACK_DEFAULT_KEY = "P_EXT:fancy_pitch_track_defaults",
  SYS_DEFAULT_EXT = "pitch_def_",
  -- Track extension key holding the track's range and key found by the coarse pre-analysis (JSON, K.track_record_valid)
  TRACK_SCAN_KEY = "P_EXT:fancy_pitch_track_scan",

  -- The note action bar's grip offset is kept within this many pixels of its place under the note
  NOTE_BAR_OFFSET_MAX = 2000,

  -- The most Slide In may move one slide frame, in semitones (see K.correction_build)
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
  CANCEL_BATCH_FMT = "Cancel Batch %d%%",   -- ... and into this while a batch runs
  CANCEL_BATCH_TIP = "Stops the batch.\n\nItems already finished are kept.",
  REASON_ANALYZING = "Wait for the analysis to finish",   -- why the Pitched Items rows and the batch entry are locked
  REASON_BATCH_FEW = "Select 2 or more audio items",
  REASON_NO_TARGET = "Select an audio item",   -- why "..." entries that need the open item are disabled
  CANCELLED_TEXT = "Analysis cancelled.",
  -- A new analysis puts the item's values back to the defaults (only its Key and Scale stay): the Re-Analyze and
  -- batch confirms say so, and with no confirm the status line says it once the analysis is written (HC4)
  REANALYZE_VALUES_LINE = "Its values go back to the defaults; Key and Scale stay.",
  REANALYZE_VALUES_LINE_N = "Their values go back to the defaults; Key and Scale stay.",
  REANALYZED_DEFAULTS_TEXT = "Re-analyzed: values back to the defaults (%s+Z undoes).",

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

  -- Value ranges { lowest, highest } of the Settings drags; a stored value is clamped to them (see K.PERSIST). The
  -- two Hz drags also stop 1 Hz short of each other (K.drag_bounds), so their outer ends are what counts: a vocal
  -- range's low end (Soprano: 250 Hz) lies well above 200 Hz
  LIMITS = {
    threshold = { 0.05, 0.5 },
    min_freq = { 20, 1999 },
    max_freq = { 21, 2000 },
    tolerance = { 0, 50 },   -- cents
    separation = { 0, 1 },
  },

  -- The detection values an analysis is run with, and the item stores (take data field `analysis`): five numbers
  -- and auto_range (Vocal Range "Auto", a boolean)
  ANALYSIS_KEYS = { "min_freq", "max_freq", "threshold", "block_size", "hop_size", "auto_range" },

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
  RULER_MIN_TICK_PX = 6,   -- beat ruler: ticks closer together than this are not drawn
  RULER_MAX_BARS = 1024,   -- beat ruler: the widest label step, in bars

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
  auto_range = DEFAULTS.auto_range, -- Vocal Range "Auto": the range is found from the track
  hop_size = DEFAULTS.hop_size, -- How many samples to advance per block
  separation = DEFAULTS.separation, -- how readily notes are split (K.segment)
  analysis_params = nil,        -- the detection values above (not separation), frozen by start_analysis

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
  context_edit = nil,   -- { note, key, raw }: a note menu slider changed and not yet written (raw = the value before)
  context_menu_time = nil, -- the pointer's time (item seconds) when the note menu was opened
  context_menu_live = false, -- the note's points could be added to (K.points_live_at) when the note menu was opened
  context_point = nil,  -- { note_idx, frame, start_st }: the point the point menu ("##point_context_menu") is on
  -- The setting that is hovered or dragged (K.setting_hint): the canvas shades where it acts. key = cascade key
  -- or "slide_in"; notes = nil (every note the top bar value reaches) or a set of note indices; frame = the
  -- ImGui frame that reported it; said = the "nothing in view" status was posted for this drag
  setting_hint = { frame = -1, menu_set = {}, zone_set = {} },
  view_t0 = nil,        -- visible time window of the canvas, seconds relative to the item start; nil = the whole item
  view_t1 = nil,        -- (both nil or both set; changed by the wheel in draw_graph, reset when the target changes or the model is analysed or cleared, kept through undo / redo of the same take)
  view_p0 = nil,        -- visible pitch range of the canvas, semitones (MIDI note numbers); nil = fitted to the notes
  view_p1 = nil,        -- (both nil or both set; same lifetime as view_t0 / view_t1, see K.reset_view)
  view_drag = nil,      -- a drag on the overview strip or the pitch strip: { kind ("t_pan" / "t0" / "t1" / "p_pan" / "p0" / "p1"), start (pointer x or y), a0, a1 (the window when it began) }
  note_bar_rect = nil,  -- { x1, y1, x2, y2 }: where the note action bar was drawn last frame (K.draw_note_bar); nil = not drawn

  -- Visualization toggles
  show_note_blocks = true,
  show_raw_pitch = true,
  show_smart_spots = true,
  show_split_points = false,
  show_preview = true,
  note_bar_size = DEFAULTS.note_bar_size,   -- Settings > Appearance: Small / Medium / Large (K.NOTE_BAR_SIZES)
  note_bar_dx = 0,      -- the note action bar's offset from its place under the note, pixels (its grip; saved)
  note_bar_dy = 0,
  note_bar_grip = nil,  -- { mx, my, dx, dy, above } while the grip is dragged

  -- Target item binding (persistent GUID lock)
  target_take_guid = nil,
  target_take_name = nil,
  analysis_form = nil,   -- { guid, values, edited, source, seed }: the values the next analysis of the target item would use (K.form_new)

  -- Undo / model sync with REAPER
  last_change_count = nil,  -- GetProjectStateChangeCount(0) after the last own write / resync (nil = resync next frame)
  raw_cache = {},           -- [guid] = raw P_EXT string last written or loaded by this script
  missing_takes = {},       -- [guid] = true when the take no longer resolves (row is kept in the sidebar)
  undone_takes = {},        -- [guid] = n: an undo took the take's analysis away (n: in which order); a redo may bring it back (sync_with_project)
  stale_takes = {},         -- [guid] = true: the take's pitch envelope is not what today's settings and its notes would write (K.envelope_check)
  stale_env = {},           -- [guid] = { points }: the envelope a stale take really holds, for the preview curve of the open item
  stale_queue = {},         -- guids whose envelope is still to be compared (one per frame, K.stale_check_step)
  last_seen_sel_guid = nil, -- GUID of the first selected audio item seen last frame (edge-triggered tracker)
  nudge_burst = nil,        -- pending arrow-key nudge { total_st, last_time, keys = { up, down }, guid }

  -- What the script asked REAPER about, valid for one value of GetProjectStateChangeCount(0) of one project (see
  -- K.refresh_project_cache, K.drop_project_cache): takes by GUID (take = pointer, or false when the item is not in
  -- the project; scanned = the full item scan ran), the item of a take, whether a take's pitch envelope is bypassed,
  -- the track of a take (false: none) and the Track Default of a track (K.track_defaults)
  cache = { count = nil, proj = nil, takes = {}, items = {}, bypass = {}, tracks = {}, trackdef = {}, trackscan = {} },
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
  -- Pitched Items row selection (in memory only): guid -> true, the Shift-click anchor row, and the active item the
  -- selection was last made for (when the active item changes from elsewhere the selection becomes just that row)
  row_sel = {},
  row_anchor = nil,
  row_sel_target = nil,
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

-- The value keys an item holds (data.overrides[key]; Separation is data.separation). A new item, and an item analysed
-- again, starts at the script's DEFAULTS for every one of them (K.new_item_values)
K.ITEM_KEYS = { "separation", "correct_mode", "tighten", "tolerance", "retune_speed", "slide_in" }

-- The Key and Scale last chosen in the bar (K.scale_changed): a new item starts in them. Stored under pitch_key_idx /
-- pitch_scale_idx (K.PERSIST); an item analysed again keeps its own. key_idx 0 is "Auto": the item's key is its
-- track's (K.key_resolve), else the key last chosen by hand (hand_key_idx / hand_scale_idx: pitch_key_hand_idx /
-- pitch_scale_hand_idx, updated whenever a real key or a scale is chosen in the bar). 0 is never an item's key
K.new_key = { key_idx = 0, scale_idx = 1, hand_key_idx = 1, hand_scale_idx = 1 }

--- The real key a key choice stands for: a real key (1..12) passes through; Auto (0) gives the key found on the
--- track of the take `guid` (its K.track_record), else the key last chosen by hand. Returns key_idx, scale_idx and
--- whether the key came from the track.
K.key_resolve = function(key_idx, scale_idx, guid)
  if key_idx ~= 0 then return key_idx, scale_idx, false end
  local rec = K.track_record(K.take_track(guid))
  if rec and rec.key_idx then return rec.key_idx, rec.scale_idx, true end
  return K.new_key.hand_key_idx, K.new_key.hand_scale_idx, false
end

--- A found key in words: "E Major", "C# Minor" (the found scales are Major and Natural Minor).
K.key_text = function(key_idx, scale_idx)
  local key, scale = SCALE_KEYS[key_idx], SCALE_DEFINITIONS[scale_idx]
  if not (key and scale) then return "" end
  return key.display .. " " .. (scale_idx == 2 and "Minor" or scale.name)
end

--- The name of `track` for the Key combo, the status line and undo labels ("this track" when REAPER gives none).
K.track_label = function(track)
  local _, name = reaper.GetTrackName(track)
  return (type(name) == "string" and name ~= "") and name or "this track"
end

--- The track of an analysed item `data` (its take `guid`) and the track's record, when the item's key was found on
--- the track (data.key_from_track) and the record still holds that key and scale; nil otherwise (no record, the item
--- moved to another track, the track's key changed since).
K.key_track_record = function(data, guid)
  if not (data and data.key_from_track) then return nil end
  local track = K.take_track(guid)
  local rec = track and K.track_record(track)
  if not (rec and rec.key_idx == data.key_idx and rec.scale_idx == data.scale_idx) then return nil end
  return track, rec
end

--- The Key combo's line for an analysed item `data` whose key was found on its track (and the track's record still
--- holds it): "Found from V _ Main. C# Minor also fits." (with the runner-up), or "Found from V _ Main."; nil for a
--- key chosen by hand.
K.key_found_text = function(data)
  local track, rec = K.key_track_record(data, data and data.guid)
  if not track then return nil end
  local name = K.track_label(track)
  if rec.alt_key_idx then
    return string.format("Found from %s. %s also fits.", name, K.key_text(rec.alt_key_idx, rec.alt_scale_idx))
  end
  return string.format("Found from %s.", name)
end

--- The item's own value of `key`, or nil (Separation is stored beside the notes, the others in data.overrides).
K.item_value = function(data, key)
  if not data then return nil end
  if key == "separation" then return data.separation end
  return data.overrides and data.overrides[key]
end

--- The values a new item `guid` starts with: its default of every value key (K.item_default: its track's, else the
--- System Default, else DEFAULTS), and the Key and Scale last chosen in the bar (K.new_key).
K.new_item_values = function(guid)
  local t = {}
  for _, key in ipairs(K.ITEM_KEYS) do t[key] = (K.item_default(key, guid)) end
  t.key_idx, t.scale_idx = K.new_key.key_idx, K.new_key.scale_idx
  return t
end

--- Fill every missing value of an item's model with a new item's (K.new_item_values: its defaults, by data.guid; a
--- model change only: it is written with the item's next save). A new analysis, and an item analysed before 2.22
--- that holds no values, get them here. Returns true when it filled one.
K.item_seed = function(data)
  local start, filled = K.new_item_values(data.guid), false
  for _, key in ipairs(K.ITEM_KEYS) do
    if K.item_value(data, key) == nil then
      if key == "separation" then
        data.separation = start.separation
      else
        data.overrides = data.overrides or {}
        data.overrides[key] = start[key]
      end
      filled = true
    end
  end
  -- No key, or Auto (a finished analysis copies the bar's Auto): the real key it stands for (K.key_resolve)
  if data.key_idx == nil or data.key_idx == 0 then
    local key = (data.key_idx == nil) and start.key_idx or 0
    if key == 0 then
      local k, sc, from_track = K.key_resolve(0, nil, data.guid)
      data.key_idx, data.scale_idx, data.key_from_track = k, sc, from_track or nil
    else
      data.key_idx = key
    end
    filled = true
  end
  if data.scale_idx == nil then data.scale_idx, filled = start.scale_idx, true end
  return filled
end

--- A new analysis of an item analysed before (`before`, its previous model) keeps only the item's Key and Scale
--- (they describe the song, not the analysis); its values start at the defaults (K.item_seed). A model change only.
K.item_carry_key = function(data, before)
  if not before then return end
  if before.key_idx ~= nil and before.key_idx ~= 0 then
    data.key_idx, data.key_from_track = before.key_idx, before.key_from_track
  end
  if before.scale_idx ~= nil then data.scale_idx = before.scale_idx end
end

--- How many of the item's values (K.ITEM_KEYS) differ from its defaults (K.item_default, by data.guid). A missing
--- value is the default. Key and Scale are not values with a default.
K.item_off_defaults = function(data)
  if not data then return 0 end
  local n = 0
  for _, key in ipairs(K.ITEM_KEYS) do
    local v, d = K.item_value(data, key), K.item_default(key, data.guid)
    if v ~= nil and d ~= nil and K.value_changed(v, d) then n = n + 1 end
  end
  return n
end

--- The model part of "Reset this item to defaults": every item value (K.ITEM_KEYS) becomes its default
--- (K.item_default, by data.guid); Key and Scale are not changed, and the notes keep their own values. A model change
--- only (K.reset_item_all writes it).
K.item_reset_values = function(data)
  if not data then return end
  for _, key in ipairs(K.ITEM_KEYS) do
    local d = K.item_default(key, data.guid)
    if d ~= nil then
      if key == "separation" then
        data.separation = d
      else
        data.overrides = data.overrides or {}
        data.overrides[key] = d
      end
    end
  end
end

--- Resolve an effective value: the note's own, else the target item's, else its default (K.item_default: an item
--- not analysed yet, or not seeded).
local function get_effective(note, key)
  if note and note.controls and note.controls[key] ~= nil then
    return note.controls[key]
  end
  if state.target_take_guid then
    local v = K.item_value(state.session_takes[state.target_take_guid], key)
    if v ~= nil then return v end
  end
  return (K.item_default(key, state.target_take_guid))
end

--- Returns the override level for display: "note" (the note has its own), "item" (the item differs from its
--- default, K.item_default: the "*" mark) or "default".
local function get_override_level(note, key)
  if note and note.controls and note.controls[key] ~= nil then return "note" end
  local guid = state.target_take_guid
  if guid then
    local v, d = K.item_value(state.session_takes[guid], key), K.item_default(key, guid)
    if v ~= nil and d ~= nil and K.value_changed(v, d) then return "item" end
  end
  return "default"
end

--- Show a short message on the canvas's status pill for STATUS_SECONDS (it replaces the hint there).
local function set_status(msg)
  state.status.text = msg or ""
  state.status.until_time = reaper.time_precise() + K.STATUS_SECONDS
  state.status.hold = nil
end

--- Show a message on the status pill until the user's next input in the window (K.status_release), not for
--- STATUS_SECONDS: the outcome of long work that may end while nobody is looking (a batch).
K.status_hold = function(msg)
  state.status.text = msg or ""
  state.status.until_time = math.huge
  state.status.hold = true
end

--- The user did something in the window: a message held by K.status_hold goes. Any other message keeps its time.
K.status_release = function()
  if not state.status.hold then return end
  state.status.text, state.status.until_time, state.status.hold = "", 0, nil
end

-- A held message is not released by input that came before it could be read (seconds)
K.STATUS_HOLD_MIN_S = 0.5
-- The keys that count as input for releasing a held message (letters and digits arrive as typed characters)
K.STATUS_KEYS = {
  reaper.ImGui_Key_Escape(), reaper.ImGui_Key_Enter(), reaper.ImGui_Key_KeypadEnter(), reaper.ImGui_Key_Space(),
  reaper.ImGui_Key_Delete(), reaper.ImGui_Key_Backspace(), reaper.ImGui_Key_Tab(), reaper.ImGui_Key_LeftArrow(),
  reaper.ImGui_Key_RightArrow(), reaper.ImGui_Key_UpArrow(), reaper.ImGui_Key_DownArrow(),
}

--- Once per frame, inside the window: release a held message on the user's next input in the window: a click or
--- wheel move over it, or a key while it has the focus. The keys are only looked at (IsKeyDown), never taken:
--- Esc, Space and the others keep doing what they do.
K.status_watch = function(wctx)
  local status = state.status
  if not status.hold then
    status.held_since = nil
    return
  end
  local now = reaper.time_precise()
  status.held_since = status.held_since or now
  if now - status.held_since < K.STATUS_HOLD_MIN_S then return end
  local input = false
  if reaper.ImGui_IsWindowHovered(wctx, reaper.ImGui_HoveredFlags_RootAndChildWindows()) then
    input = reaper.ImGui_IsMouseClicked(wctx, 0) or reaper.ImGui_IsMouseClicked(wctx, 1)
      or (reaper.ImGui_GetMouseWheel(wctx) or 0) ~= 0
  end
  if not input and reaper.ImGui_IsWindowFocused(wctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
    input = (reaper.ImGui_GetInputQueueCharacter(wctx, 0)) == true
    for _, key in ipairs(K.STATUS_KEYS) do
      if input then break end
      input = reaper.ImGui_IsKeyDown(wctx, key)
    end
  end
  if input then K.status_release() end
end

--- Ask the user to confirm a destructive action. draw_confirm_modal() shows the modal.
--- req = { id, title, body_lines = { string... }, confirm_label, on_confirm = function, on_cancel = function | nil,
---         list = { { name, where } ... } | nil, after_lines = { string... } | nil }
--- The modal names the consequence, Cancel comes first and Esc cancels; on_confirm runs once, or on_cancel once when
--- the modal closes without confirming. list: the things the action replaces, shown under body_lines in a region
--- that scrolls (K.confirm_list); after_lines follow it.
--- Optional targets (the Apply confirm):
---   checklist = { caption, all_label, none_label, rows = { { id, name, reason } ... }, ticked = { [id] = true } }:
---             a list of rows with a checkbox each (K.confirm_checklist), "All" / "None" beside the caption. A row with
---             a `reason` is drawn disabled with the reason beside it (EP2) and is never ticked.
---   check = { label, value }: a checkbox under the list.
---   consequence = function(checked, ticked) -> { lines = { string... }, confirm_label = string | nil,
---             reason = string | nil }: what the action does, drawn after the checkbox. It is called only when
---             the ticked rows or the check change (HI5) and its answer is kept in state.confirm.cons; its
---             confirm_label replaces the request's, and a `reason` disables the confirm button and is shown above it.
--- on_confirm(checked, ticked) receives the state of the check and the ticked rows.
--- size = a Theme.layout modal size (default L.modal_sm). fit = true: size.h is only where it opens; the modal then
--- takes its content's height (up to the most the window it opens from allows) with the footer right under it.
--- Optional analysis form (the analysis modal: Re-Analyze…, Analyze Selected Items (N)…, Change…):
---   form = an analysis form (K.form_new), the modal's own copy: drawn above body_lines (K.confirm_form_draw: the
---          header, the detection rows, the Advanced fold, Save as Default). Enter / KeypadEnter run the primary
---          (K.confirm_enter) and on_confirm(values) receives form.values.
---   safe = true: the primary is not danger-styled (nothing the user made is lost).
--- K.confirm_new builds the modal's state from a request; request_confirm makes it the one confirm (state.confirm).
K.confirm_new = function(req)
  local ticked = {}
  if req.checklist then
    for _, row in ipairs(req.checklist.rows) do
      if not row.reason and req.checklist.ticked and req.checklist.ticked[row.id] then ticked[row.id] = true end
    end
  end
  return {
    id = req.id or "action",
    title = req.title or "Are you sure?",
    body_lines = req.body_lines or {},
    list = req.list,
    after_lines = req.after_lines or {},
    confirm_label = req.confirm_label or "Confirm",
    on_confirm = req.on_confirm,
    on_cancel = req.on_cancel,
    checklist = req.checklist,
    ticked = ticked,
    ticks_rev = 0,    -- counts the changes to `ticked` (the consequence's cache key)
    check = req.check,
    checked = req.check and req.check.value == true or false,
    consequence = req.consequence,
    cons = nil,       -- the consequence's answer for cons_key (see K.confirm_consequence)
    cons_key = nil,
    size = req.size,
    fit = req.fit == true,  -- sized to its content (K.confirm_fit_h), else req.size throughout
    form = req.form,
    safe = req.safe == true,
    nested = nil,         -- the Save as Default confirm opened from the form, drawn over this one
    open_pending = true,  -- OpenPopup once, on the next draw_confirm_modal() call
    opened = false,
  }
end

local function request_confirm(req)
  if not req or not req.on_confirm then return end
  state.confirm = K.confirm_new(req)
end

--- True when Enter / KeypadEnter run the primary of the confirm `c`: only the analysis modal (it has a form); every
--- other confirm keeps Enter for ImGui's own keyboard use.
K.confirm_enter = function(c)
  return c ~= nil and c.form ~= nil
end

--- The consequence of the confirm `c` for its ticked rows and check: computed again only when one of them
--- (or the project state) changed since the last call (HI5), else the kept answer. nil when the request has no consequence.
K.confirm_consequence = function(c)
  if not c.consequence then return nil end
  -- The project state counts too: an undo in the arrange view can change what the consequence reads
  local key = tostring(c.checked) .. "|" .. tostring(c.ticks_rev) .. "|" .. tostring(state.cache.count)
  if c.cons_key ~= key then
    c.cons = c.consequence(c.checked, c.ticked) or { lines = {} }
    c.cons_key = key
  end
  return c.cons
end

--- Tick (on) or untick the row `id` of the confirm `c`'s checklist. A row with a reason cannot be ticked. The
--- consequence follows on the next frame (only when the ticked rows really changed).
K.confirm_tick = function(c, id, on)
  local row = nil
  for _, r in ipairs(c.checklist and c.checklist.rows or {}) do
    if r.id == id then row = r break end
  end
  if not row or (on and row.reason) then return end
  local was = c.ticked[id] == true
  if was == (on == true) then return end
  c.ticked[id] = on and true or nil
  c.ticks_rev = c.ticks_rev + 1
end

--- Tick every row of the confirm `c`'s checklist that can be ticked (on), or untick every row.
K.confirm_tick_all = function(c, on)
  for _, row in ipairs(c.checklist and c.checklist.rows or {}) do K.confirm_tick(c, row.id, on) end
end

local function update_scale_pitch_classes()
  local scale = SCALE_DEFINITIONS[state.scale_idx]
  local root_pc = (state.key_idx - 1) % 12
  state.scale_pc_set = {}
  if state.key_idx == 0 then   -- Auto (an item not analysed yet): every pitch class is in scale
    for pc = 0, 11 do state.scale_pc_set[pc] = true end
  elseif scale then
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

  -- The Key and Scale a new item starts in (K.new_key), saved when Key or Scale is changed in the bar
  -- (whole numbers only: they index SCALE_KEYS / SCALE_DEFINITIONS; Auto is 0, never a key chosen by hand)
  local function whole(group, ext, tbl, key, lo, hi)
    add(group, ext, function() return string.format("%.14g", tbl[key]) end, function(raw)
      local n = finite(raw)
      if n and n % 1 == 0 then tbl[key] = math.max(lo, math.min(hi, n)) end
    end)
  end
  whole("key", "pitch_key_idx", K.new_key, "key_idx", 0, #SCALE_KEYS)
  whole("key", "pitch_scale_idx", K.new_key, "scale_idx", 1, #SCALE_DEFINITIONS)
  whole("key", "pitch_key_hand_idx", K.new_key, "hand_key_idx", 1, #SCALE_KEYS)
  whole("key", "pitch_scale_hand_idx", K.new_key, "hand_scale_idx", 1, #SCALE_DEFINITIONS)

  -- Settings: the engine and the pitch algorithm, saved when a control changes or is committed or reset
  choice("engine", "pitch_block_size", state, "block_size", BLOCK_SIZES)
  choice("engine", "pitch_hop_size", state, "hop_size", HOP_SIZES)
  number("engine", "pitch_threshold", state, "threshold", K.LIMITS.threshold)
  number("engine", "pitch_min_freq", state, "min_freq", K.LIMITS.min_freq)
  number("engine", "pitch_max_freq", state, "max_freq", K.LIMITS.max_freq)
  flag("engine", "pitch_auto_range", state, "auto_range")
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

  -- Appearance: the note action bar's size, saved when the Settings combo changes
  choice("appearance", "pitch_note_bar_size", state, "note_bar_size", { 1, 2, 3 })
  -- ... and its offset from its place under the note, saved when a drag of its grip ends or it is double-clicked
  number("appearance", "pitch_note_bar_dx", state, "note_bar_dx", { -K.NOTE_BAR_OFFSET_MAX, K.NOTE_BAR_OFFSET_MAX }, "%.0f")
  number("appearance", "pitch_note_bar_dy", state, "note_bar_dy", { -K.NOTE_BAR_OFFSET_MAX, K.NOTE_BAR_OFFSET_MAX }, "%.0f")

  -- The note tone while a note is dragged, saved when the More menu item is toggled
  flag("tone", "pitch_note_tone", state, "note_tone")

  -- The Pitched Items width, saved when a drag of the divider ends
  number("sidebar", "pitch_sidebar_w", state, "sidebar_w", { K.SIDEBAR_MIN_W }, "%.0f")
  return list
end)()

--- Adopt every stored setting (validated by its entry) and remember what is stored.
K.load_settings = function()
  local found = {}
  for _, e in ipairs(K.PERSIST) do
    local raw = reaper.GetExtState("FancyScripts", e.ext)
    if raw and raw ~= "" then
      e.apply(raw)
      found[e.ext] = true
    end
  end
  -- A Vocal Range saved before Auto existed (no Auto flag stored) is kept: Auto only when the stored Hz are Auto's own
  if not found.pitch_auto_range then
    for _, r in ipairs(VOCAL_RANGES) do
      if r.auto and ((found.pitch_min_freq and math.abs(state.min_freq - r.min) > 1e-9)
          or (found.pitch_max_freq and math.abs(state.max_freq - r.max) > 1e-9)) then
        state.auto_range = false
      end
    end
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

  -- Restore the Key for new items, the engine settings, the layers and the panel width
  K.load_settings()
  -- Nothing is open yet: the window shows a new item's values
  state.key_idx, state.scale_idx, state.separation = K.new_key.key_idx, K.new_key.scale_idx, DEFAULTS.separation
  update_scale_pitch_classes()
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
  cache.takes, cache.items, cache.bypass, cache.tracks, cache.trackdef = {}, {}, {}, {}, {}
  cache.trackscan = {}
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

-------------------------------------------------------------------------------
-- Saved defaults (docs/design/pitch-correct-saved-defaults.md). An item's default of a value, the level its
-- "Reset to default", its "*" mark and a new analysis of it go by, is the first of: its track's Track Default
-- (track P_EXT, only the keys set, part of the project and its undo history), the System Default (ExtState
-- pitch_def_<key>, every project), the script's DEFAULTS. Key and Scale are never part of a default.
-------------------------------------------------------------------------------

--- A stored default of `key` checked: a finite number clamped to the value's range (Mode one of 0, 1, 2), or nil.
K.item_value_valid = function(key, v)
  v = tonumber(v)
  if not v or v ~= v or math.abs(v) == math.huge then return nil end
  if key == "correct_mode" then
    if v ~= 0 and v ~= 1 and v ~= 2 then return nil end
    return v
  end
  local lim = (key == "tolerance") and K.LIMITS.tolerance or { 0, 1 }
  if DEFAULTS[key] == nil then return nil end
  return math.max(lim[1], math.min(lim[2], v))
end

--- The System Default of each value key that has one ({ [key] = number }), read at start (K.sys_defaults_load).
K.sys_defaults = {}

K.sys_defaults_load = function()
  K.sys_defaults = {}
  for _, key in ipairs(K.ITEM_KEYS) do
    K.sys_defaults[key] = K.item_value_valid(key, reaper.GetExtState("FancyScripts", K.SYS_DEFAULT_EXT .. key))
  end
end
K.sys_defaults_load()   -- at start, with the other settings (K.load_settings)

--- Save `values` ({ [key] = number }) as the System Default of those keys (outside the undo history).
K.sys_default_set = function(values)
  for _, key in ipairs(K.ITEM_KEYS) do
    local v = values[key] ~= nil and K.item_value_valid(key, values[key]) or nil
    if v ~= nil then
      K.sys_defaults[key] = v
      reaper.SetExtState("FancyScripts", K.SYS_DEFAULT_EXT .. key, string.format("%.14g", v), true)
    end
  end
end

--- Forget every System Default: the factory DEFAULTS apply again.
K.sys_defaults_clear = function()
  for _, key in ipairs(K.ITEM_KEYS) do
    reaper.DeleteExtState("FancyScripts", K.SYS_DEFAULT_EXT .. key, true)
  end
  K.sys_defaults = {}
end

--- How many values have a System Default that differs from the factory one.
K.sys_defaults_changed = function()
  local n = 0
  for _, key in ipairs(K.ITEM_KEYS) do
    local v = K.sys_defaults[key]
    if v ~= nil and math.abs(v - DEFAULTS[key]) > 1e-9 then n = n + 1 end
  end
  return n
end

--- The track a take (by GUID) is on, cached per project state; nil when the take or its track is gone.
K.take_track = function(guid)
  if not guid then return nil end
  local tracks = state.cache.tracks
  local track = tracks[guid]
  if track == nil then
    local take = resolve_take_by_guid(guid, true)
    track = take and reaper.GetMediaItemTake_Track(take) or false
    tracks[guid] = track
  end
  return track or nil
end

--- The Track Default of `track` ({ [key] = number }, only the keys set and valid; empty when none), cached per
--- project state.
K.track_defaults = function(track)
  if not track then return {} end
  local cache = state.cache.trackdef
  local t = cache[track]
  if t then return t end
  t = {}
  local ok, raw = reaper.GetSetMediaTrackInfo_String(track, K.TRACK_DEFAULT_KEY, "", false)
  if ok and raw and raw ~= "" then
    local parsed_ok, parsed = pcall(JSON.decode, raw)
    if parsed_ok and type(parsed) == "table" then
      for _, key in ipairs(K.ITEM_KEYS) do t[key] = K.item_value_valid(key, parsed[key]) end
    end
  end
  cache[track] = t
  return t
end

--- True when `v` is an integer-valued number from `lo` to `hi`.
local function whole_in(v, lo, hi)
  return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi
end

--- `t` when it is a valid track record, else nil. Shape: { st = { ["52"] = frames }, takes = { [take_guid] = true },
--- lo_st, hi_st (both or neither: nil = nothing sung found), key_idx + scale_idx (both or neither: nil = key not
--- told; a found scale is Major or Natural Minor, a key corrected in the bar may be any scale), alt_key_idx +
--- alt_scale_idx (both or neither, only with a key; Major or Natural Minor), skipped (optional, a whole number >= 0) }.
--- Every number is finite: anything else is no record.
K.track_record_valid = function(t)
  if type(t) ~= "table" or type(t.st) ~= "table" or type(t.takes) ~= "table" then return nil end
  -- st: a whole MIDI note 0..127 written in digits (as K.track_record_build writes it) -> a finite count >= 0
  for k, v in pairs(t.st) do
    if type(k) ~= "string" or not k:match("^%d+$") or not whole_in(tonumber(k), 0, 127) then return nil end
    if type(v) ~= "number" or not (v >= 0 and v < math.huge) then return nil end
  end
  for k, v in pairs(t.takes) do
    if type(k) ~= "string" or v ~= true then return nil end
  end
  if (t.lo_st == nil) ~= (t.hi_st == nil) then return nil end
  if t.lo_st ~= nil and (not whole_in(t.lo_st, 0, 127) or not whole_in(t.hi_st, 0, 127) or t.lo_st > t.hi_st) then
    return nil
  end
  if (t.key_idx == nil) ~= (t.scale_idx == nil) then return nil end
  if t.key_idx ~= nil and (not whole_in(t.key_idx, 1, #SCALE_KEYS) or not whole_in(t.scale_idx, 1, #SCALE_DEFINITIONS))
  then
    return nil
  end
  if (t.alt_key_idx == nil) ~= (t.alt_scale_idx == nil) then return nil end
  if t.alt_key_idx ~= nil then
    if t.key_idx == nil or not whole_in(t.alt_key_idx, 1, 12) or not whole_in(t.alt_scale_idx, 1, 2) then return nil end
  end
  if t.skipped ~= nil and not (whole_in(t.skipped, 0, math.huge) and t.skipped < math.huge) then return nil end
  return t
end

--- The pre-analysis record of `track` (nil: none or not valid), cached per project state. A record found but not
--- written yet (K.track_records_pending: it waits for the analysis's undo block) is the track's record already.
K.track_record = function(track)
  if not track then return nil end
  local pending = K.track_records_pending and K.track_records_pending[track]
  if pending then return pending end
  local cache = state.cache.trackscan
  local rec = cache[track]
  if rec ~= nil then return rec or nil end
  rec = false
  local ok, raw = reaper.GetSetMediaTrackInfo_String(track, K.TRACK_SCAN_KEY, "", false)
  if ok and raw and raw ~= "" then
    local parsed_ok, parsed = pcall(JSON.decode, raw)
    if parsed_ok then rec = K.track_record_valid(parsed) or false end
  end
  cache[track] = rec
  return rec or nil
end

--- The tally (integer keys) of a record's `st` (string keys), for merging.
K.track_record_tally = function(record)
  local tally = K.pre_tally_new()
  for k, v in pairs(record.st) do
    local midi = tonumber(k)
    if midi and v > 0 then
      tally.st[math.floor(midi)] = v
      tally.n = tally.n + v
    end
  end
  return tally
end

--- A record from `tally` (this scan's frames) and `takes` ({ [take_guid] = true } it covered). With `prev` (the
--- record already on the track) its frames and takes are merged in, the range is recomputed from the merged tally
--- and its key fields are kept; without a key on `prev` the key is found from the merged tally.
K.track_record_build = function(tally, takes, prev)
  local merged = K.pre_tally_new()
  K.pre_tally_merge(merged, tally)
  local rec = { st = {}, takes = {}, skipped = 0 }
  for guid in pairs(takes or {}) do rec.takes[guid] = true end
  if prev then
    K.pre_tally_merge(merged, K.track_record_tally(prev))
    for guid in pairs(prev.takes) do rec.takes[guid] = true end
    rec.skipped = prev.skipped or 0
  end
  for midi, c in pairs(merged.st) do rec.st[tostring(midi)] = c end
  rec.lo_st, rec.hi_st = K.pre_range(merged)
  if prev and prev.key_idx ~= nil then
    rec.key_idx, rec.scale_idx = prev.key_idx, prev.scale_idx
    rec.alt_key_idx, rec.alt_scale_idx = prev.alt_key_idx, prev.alt_scale_idx
  else
    rec.key_idx, rec.scale_idx, rec.alt_key_idx, rec.alt_scale_idx = K.pre_key(merged)
  end
  return rec
end

--- Records waiting to be written: [track] = record. Only K.track_records_flush writes them.
K.track_records_pending = {}

--- Write every pending record to its track and forget them (and the cache, which may hold older ones). Opens NO
--- undo block: the caller's block is open, so the write is part of the user's one undo step. keep (optional): a set
--- { [track] = true }; only those tracks' records are written, the others are forgotten unwritten.
K.track_records_flush = function(keep)
  for track, rec in pairs(K.track_records_pending) do
    if not keep or keep[track] then
      reaper.GetSetMediaTrackInfo_String(track, K.TRACK_SCAN_KEY, JSON.encode(rec), true)
    end
  end
  K.track_records_pending = {}
  state.cache.trackscan = {}
end

--- Write the pending record of `track` alone and forget it (and the cache); the other tracks' records stay pending.
--- Opens NO undo block: the caller's is open (a key corrected on an item, Find Key, Find Range and Key Again).
K.track_record_flush_one = function(track)
  local rec = track and K.track_records_pending[track]
  if rec then
    K.track_records_pending[track] = nil
    reaper.GetSetMediaTrackInfo_String(track, K.TRACK_SCAN_KEY, JSON.encode(rec), true)
  end
  state.cache.trackscan = {}
end

--- The records an undo block holds (`flush`): true = every pending record (an Auto analysis), a track = that
--- track's only, nil = none.
K.records_flush = function(flush)
  if flush == true then
    K.track_records_flush()
  elseif flush then
    K.track_record_flush_one(flush)
  end
end

--- The default of value `key` for the item `guid`, and where it comes from: "track", "system" or "factory". A key
--- that is not an item value gives DEFAULTS[key], "factory".
K.item_default = function(key, guid)
  local tv = K.track_defaults(K.take_track(guid))[key]
  if tv ~= nil then return tv, "track" end
  local sv = K.sys_defaults[key]
  if sv ~= nil then return sv, "system" end
  return DEFAULTS[key], "factory"
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

--- The name and cents deviation of a note at centre pitch `cp` (MIDI, fractional): "A3", "+3\xC2\xA2". The label
--- pill and the note action bar's readout both show them.
K.note_name_cents = function(cp)
  local nearest = math.floor(cp + 0.5)
  local cents = math.floor((cp - nearest) * 100 + 0.5)
  return midi_to_name(nearest), string.format("%s%d\xC2\xA2", cents >= 0 and "+" or "", cents)
end

--- A tooltip's text from its paragraphs: the non-empty ones, a blank line between each (nil and "" are skipped).
K.tip = function(...)
  local out = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p and p ~= "" then out[#out + 1] = p end
  end
  return table.concat(out, "\n\n")
end

--- The note action bar's readout of a note at centre pitch `cp`: name and cents text, their colours (P.canvas
--- readout_*: the name as the note-name column colours it, by Key and Scale; the cents green on the semitone and
--- yellow off it) and the tooltip that says what they are.
K.note_readout = function(cp, C)
  local name, cents_txt = K.note_name_cents(cp)
  local nearest = math.floor(cp + 0.5)
  local cents = math.floor((cp - nearest) * 100 + 0.5)
  local pc = (nearest % 12 + 12) % 12
  local scale = SCALE_DEFINITIONS[state.scale_idx]
  local chromatic = (not scale) or scale.name == "Chromatic" or state.key_idx == 0   -- Auto: no scale yet
  local key_name = SCALE_KEYS[state.key_idx] and SCALE_KEYS[state.key_idx].display or ""
  local scale_name = chromatic and "" or (key_name .. " " .. scale.name)
  local name_col, scale_line = C.readout_name, nil
  if not chromatic then
    if pc == (state.key_idx - 1) % 12 then
      name_col = C.readout_name_tonic
      scale_line = string.format("%s is the root of the scale (%s), set by Key.", name, scale_name)
    elseif is_pitch_in_scale(pc) then
      scale_line = string.format("%s is in the scale (%s).", name, scale_name)
    else
      name_col = C.readout_name_dim
      scale_line = string.format("%s is out of the scale (%s). Quantize (Q) moves the note onto the scale.",
        name, scale_name)
    end
  end
  local cents_col = C.readout_cents_in
  local tune_line
  if cents == 0 then
    tune_line = string.format("In tune (green): right on %s.", name)
  else
    cents_col = C.readout_cents_off
    tune_line = string.format("%s (yellow): %d\xC2\xA2 %s %s. Snap (S) puts the note on %s at 0\xC2\xA2.",
      cents_txt, math.abs(cents), cents > 0 and "above" or "below", name, name)
  end
  local tip = K.tip(name .. " " .. cents_txt,
    "The note's pitch: the nearest note name, then how far from it in cents (100\xC2\xA2 = one semitone). "
      .. "Until you move the note, this is the pitch that was sung.",
    scale_line, tune_line)
  return name, cents_txt, name_col, cents_col, tip
end

--- What each value does to the sound: the first paragraph of its tooltip in the top bar and in the note menu.
K.VALUE_TIP = {
  tighten = "Steadies a wobbly note. Low values take out slow drift, higher values also take out wobble and then vibrato; 100% is a flat line.",
  retune_speed = "How far each note is pulled to its target pitch. 0% leaves the singing as recorded, 100% puts the note fully in tune.",
  tolerance = "How far a tightened note may wander from its centre before Tighten pulls it in. Higher values keep more natural movement.",
  slide_in = "How much of the slide into the note is corrected. 0% keeps the slide as sung, 100% removes it.",
  separation = "How readily the analysis splits the singing into notes. Raise it when separate notes are joined, lower it when one note is cut up.",
}
--- Mode: what it does, and the line a value's tooltip gains when the note's mode does not use it (K.mode_unused).
K.MODE_TIP = "How a note is corrected.\n\n"
  .. "Natural: Tighten, Tolerance, Slide In and Strength shape the note.\n\n"
  .. "Classic: the auto-tuned effect. The pitch jumps between the notes of the scale; Tighten sets how fast.\n\n"
  .. "Hard: one flat note of the scale."
K.MODE_UNUSED_TIP = {
  mode = "Not used in Classic or Hard mode.",
  hard = "Not used in Hard mode.",
  classic = "In Classic mode: how fast the pitch jumps between scale notes. 0% glides, 100% steps at once.",
}
K.TOLERANCE_IDLE_TIP = "Not used yet: raise Tighten first."
-- The note menu's value tooltips: what a change reaches, where the value comes from (the [level] tag), the gestures
K.CM_SCOPE_NOTE = "Changes this note."
K.CM_SCOPE_NOTES = "Changes the %d selected notes."
K.CM_LEVEL = {
  note = "[note]: this note has its own value.",
  item = "[item]: this note uses the item's value.",
  default = "[default]: this note uses the default value.",
}
K.CM_LEVEL_MODE_ITEM = "[item]: this note uses the item's mode."
K.CM_GESTURES = string.format("Drag to change (%s-drag: fine). Double-click: back to the item's value. "
  .. "%s-click: type a value.", K.MOD_LABEL, K.MOD_LABEL)

K.SCRUB_PX = 6     -- hold C + wheel: the edit cursor moves this many pixels of the current view per notch
K.SCRUB_FINE = 5   -- ... and this many times less with Ctrl/Cmd held (HC2)

K.LEVEL_WINDOW_S = 0.010   -- the shortest short-level window
K.LEVEL_PERIODS = 2        -- a voiced frame's window spans at least this many periods of its pitch
K.CENTRE_OUTLIER_ST = 6    -- a frame further than this from a note's middle pitch is left out of the note's centre

--- The short-level window (seconds) for a frame of pitch `freq` Hz (nil or 0: unvoiced): LEVEL_WINDOW_S, or
--- LEVEL_PERIODS periods if that is longer. A window shorter than a period swings with where it lands in the period.
K.level_window_s = function(freq)
  if freq and freq > 0 then return math.max(K.LEVEL_WINDOW_S, K.LEVEL_PERIODS / freq) end
  return K.LEVEL_WINDOW_S
end

--- RMS of the samples in a `window_s` window (default LEVEL_WINDOW_S) centred on the block (the whole block if it is
--- shorter). A whole-block RMS smears a quick dip in loudness; this follows it. `s` is a plain Lua array.
K.short_level = function(s, b_size, sample_rate, window_s)
  local n = math.min(b_size, math.max(1, math.floor((window_s or K.LEVEL_WINDOW_S) * sample_rate + 0.5)))
  local first = math.floor((b_size - n) / 2) + 1
  local sum = 0
  for i = first, first + n - 1 do
    sum = sum + s[i] * s[i]
  end
  return math.sqrt(sum / n)
end

--- The detector on one block of audio (YIN's difference function). `samples`: at least block_size samples, 1-based.
--- Returns rms (whole block), freq, lvl (K.short_level around the block's middle) and cands.
--- cands: the periods the block could be read at, for K.pitch_track to choose from across frames: the dips of the
--- normalised difference function inside the searched range, { tau = period in samples (fractional), d = its depth
--- (0 = the sound repeats perfectly) }, the K.TRACK.MAX_CANDS that cost least (K.cand_cost), in order of period. A value at the edge of the
--- range is not a dip. The block has a pitch when its deepest dip is at most twice params.threshold: the threshold
--- decides whether there is a pitch, not which one. freq is then the reading of the block on its own (K.cand_best);
--- without a pitch freq and cands are nil.
--- Every period is measured on a stretch of samples centred on the block's middle, so a frame's reading belongs to
--- the middle of its block (K.frame_centre_s).
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

  -- 1. Difference function: W samples against the W samples tau later, the pair centred on the block's middle
  for tau = 0, max_tau do
    local o = (b_size - W - tau) // 2
    local sum = 0
    for j = o + 1, o + W do
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

  -- 3. Candidates: the dips (a value below the one before and not above the one after), the deepest MAX_CANDS
  local T = K.TRACK
  local dips, d_min = {}, math.huge
  for tau = math.max(min_tau, 2), max_tau - 1 do
    local v = cmndf[tau]
    if v < T.CAND_MAX_D and v < cmndf[tau - 1] and v <= cmndf[tau + 1] then
      dips[#dips + 1] = tau
      if v < d_min then d_min = v end
    end
  end
  if #dips == 0 or d_min > params.threshold * 2 then   -- no dip deep enough: no pitch
    return rms, nil, K.short_level(s, b_size, sample_rate), nil
  end
  if #dips > T.MAX_CANDS then
    -- Keep the MAX_CANDS readings that cost least within the block (K.cand_cost), not the deepest: a steady note has a
    -- dip about as deep at every multiple of its period, and by depth alone the period itself could be dropped
    local cost, tau_min = {}, dips[1]
    for _, tau in ipairs(dips) do cost[tau] = K.cand_cost({ tau = tau, d = cmndf[tau] }, d_min, tau_min) end
    table.sort(dips, function(x, y) return cost[x] < cost[y] or (cost[x] == cost[y] and x < y) end)
    for q = #dips, T.MAX_CANDS + 1, -1 do dips[q] = nil end
    table.sort(dips)
  end

  -- 4. Parabolic interpolation for better precision
  local cands = {}
  for q, tau in ipairs(dips) do
    local better_tau = tau
    local s0, s1, s2 = cmndf[tau - 1], cmndf[tau], cmndf[tau + 1]
    local denom = (2 * (2 * s1 - s2 - s0))
    if denom ~= 0 then
      local adjustment = (s2 - s0) / denom
      if math.abs(adjustment) < 1 then
        better_tau = better_tau + adjustment
      end
    end
    cands[q] = { tau = better_tau, d = s1 }
  end

  local freq = sample_rate / K.cand_best(cands).tau
  -- The short level spans two periods of the pitch found (10 ms at least): it does not swing within a period
  return rms, freq, K.short_level(s, b_size, sample_rate, K.level_window_s(freq)), cands
end

--- Where in its block a frame's reading belongs, in seconds from the block's start: the middle.
K.frame_centre_s = function(block_size, sample_rate)
  return block_size / 2 / sample_rate
end

--- True when the block that starts at start_s lies whole inside an item of end_s seconds. Only such blocks are read:
--- a block that runs past the item's end gave a pitch of its own (the hop's period).
K.block_fits = function(start_s, params, sample_rate, end_s)
  return start_s + params.block_size / sample_rate <= end_s
end

--- The analysis frame of the block that starts at start_s, from what yin_process_block returned for it. Its time is
--- the middle of the block. freq / note are the block's reading on its own (note only inside the searched range),
--- shown while the analysis runs; cands ride on the frame until K.pitch_track makes the final choice.
K.analysis_frame = function(start_s, params, sample_rate, rms, freq, lvl, cands)
  local note = nil
  if freq and freq >= params.min_freq and freq <= params.max_freq then
    note = freq_to_note(freq)
  end
  return { time = start_s + K.frame_centre_s(params.block_size, sample_rate), freq = freq, note = note, rms = rms,
    lvl = lvl, cands = cands }
end

--- Auto range and key: a tally of the pitches heard (frames per MIDI note) gives a vocal range and a key.
--- STEP_S and BLOCK are provisional until the quick pre-pass is timed.
K.PRE = { RATE = 11025, BLOCK = 512, STEP_S = 0.1, MIN_HZ = 65, MAX_HZ = 1000, THRESHOLD = 0.15, MIN_FRAMES = 30,
  KEY_MIN_FRAMES = 100, TRIM = 0.02, MARGIN_LO_ST = 3, MARGIN_HI_ST = 4, KEY_CLOSE = 0.05, SHARE = 0.25 }
-- Krumhansl-Kessler key profiles (index 1 = the tonic)
K.PRE.MAJOR = { 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 }
K.PRE.MINOR = { 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 }

--- An empty tally: st[midi_int] = frames heard, n = their total.
K.pre_tally_new = function() return { st = {}, n = 0 } end

--- Count one frame at `freq_hz` (nil and non-positive are ignored) under its nearest MIDI note.
K.pre_tally_add = function(tally, freq_hz)
  if type(freq_hz) ~= "number" or freq_hz <= 0 then return end
  local midi = math.floor(69 + 12 * math.log(freq_hz / 440.0, 2) + 0.5)
  tally.st[midi] = (tally.st[midi] or 0) + 1
  tally.n = tally.n + 1
end

--- Add the frames of tally `from` into tally `into`.
K.pre_tally_merge = function(into, from)
  for midi, c in pairs(from.st) do into.st[midi] = (into.st[midi] or 0) + c end
  into.n = into.n + from.n
end

--- The range heard: the notes at the TRIM and 1 - TRIM quantiles by frame count, or nil under MIN_FRAMES.
K.pre_range = function(tally)
  if tally.n < K.PRE.MIN_FRAMES then return nil end
  local notes = {}
  for midi in pairs(tally.st) do notes[#notes + 1] = midi end
  table.sort(notes)
  local lo_at, hi_at = K.PRE.TRIM * tally.n, (1 - K.PRE.TRIM) * tally.n
  local lo, hi, cum = nil, nil, 0
  for _, midi in ipairs(notes) do
    cum = cum + tally.st[midi]
    if not lo and cum >= lo_at then lo = midi end
    if not hi and cum >= hi_at then hi = midi end
  end
  return lo, hi
end

--- The detector's min / max frequency (whole Hz) for a range in semitones, with a margin each side, within K.LIMITS.
K.pre_range_hz = function(lo_st, hi_st)
  local function hz(st) return 440 * 2 ^ ((st - 69) / 12) end
  local min_lim, max_lim = K.LIMITS.min_freq, K.LIMITS.max_freq
  local lo = math.floor(hz(lo_st - K.PRE.MARGIN_LO_ST) + 0.5)
  local hi = math.floor(hz(hi_st + K.PRE.MARGIN_HI_ST) + 0.5)
  lo = math.max(min_lim[1], math.min(lo, min_lim[2]))
  hi = math.max(max_lim[1], math.min(hi, max_lim[2]))
  if lo >= hi then lo = math.max(min_lim[1], hi - 1) end
  if lo >= hi then hi = lo + 1 end
  return lo, hi
end

--- The key heard: Pearson correlation of the 12 pitch classes with the Krumhansl-Kessler profiles at every root.
--- Returns key_idx, scale_idx (1 = Major, 2 = Natural Minor) and, when the runner-up is within KEY_CLOSE of the best,
--- its alt_key_idx, alt_scale_idx. nil under KEY_MIN_FRAMES.
K.pre_key = function(tally)
  if tally.n < K.PRE.KEY_MIN_FRAMES then return nil end
  local pc = {}
  for i = 1, 12 do pc[i] = 0 end
  for midi, c in pairs(tally.st) do pc[(midi % 12) + 1] = pc[(midi % 12) + 1] + c end
  local function pearson(profile, root)
    local mx, my = 0, 0
    for i = 1, 12 do mx = mx + pc[i]; my = my + profile[i] end
    mx, my = mx / 12, my / 12
    local sxy, sxx, syy = 0, 0, 0
    for i = 1, 12 do
      local x = pc[i] - mx
      local y = profile[((i - 1 - root) % 12) + 1] - my
      sxy = sxy + x * y; sxx = sxx + x * x; syy = syy + y * y
    end
    if sxx <= 0 or syy <= 0 then return -1 end
    return sxy / math.sqrt(sxx * syy)
  end
  local cands = {}
  for root = 0, 11 do
    cands[#cands + 1] = { key = root + 1, scale = 1, score = pearson(K.PRE.MAJOR, root) }
    cands[#cands + 1] = { key = root + 1, scale = 2, score = pearson(K.PRE.MINOR, root) }
  end
  table.sort(cands, function(a, b) return a.score > b.score end)
  local best, second = cands[1], cands[2]
  if best.score - second.score <= K.PRE.KEY_CLOSE then
    return best.key, best.scale, second.key, second.scale
  end
  return best.key, best.scale
end

--- A range as text: "E2\xE2\x80\x93A4" (the script's own note names, an en dash).
K.pre_range_text = function(lo_st, hi_st)
  return midi_to_name(lo_st) .. "\xE2\x80\x93" .. midi_to_name(hi_st)
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
  -- A running pre-analysis stops too. Records a finished one left pending stay for a running batch's undo block (it
  -- releases the analysis between its items); a single analysis that is released never writes, so its records go
  if state.pre then K.pre_cancel() end
  if not K.batch then K.auto_drop() end
end

--- Forget what an Auto analysis carries to its end (K.auto_run) and every record waiting for its undo block: the
--- analysis ended without writing (cancelled, could not begin, released, the item went).
K.auto_drop = function()
  local run = K.auto_run
  K.auto_run = nil
  K.track_records_pending = {}
  -- Its stage 1 saw an external change (K.pre_note_external): read the project again after this analysis's writes
  if run and run.external then state.last_change_count = nil end
end

--- Auto range and key, the pre-analysis: a coarse, time-sliced listen through every audio item on some tracks. Each
--- track's pitches heard go into a tally (K.pre_tally_add) and a finished track's record waits in
--- K.track_records_pending for the caller's undo block. It reads with its own accessor and buffer (state.pre), never
--- the analysis's, opens one accessor at a time, writes nothing to REAPER and opens no undo block.

--- The audio items of `track` still to be heard: a list of { take, item, guid, len } for every item whose active take
--- is audio and not in `record.takes`, and how many audio items were skipped (no GUID, so they cannot be recorded).
--- A take that gives no accessor is counted when K.pre_step opens it.
K.pre_takes = function(track, record)
  local list, skipped = {}, 0
  local n = reaper.CountTrackMediaItems(track) or 0
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = item and reaper.GetActiveTake(item) or nil
    if take and not reaper.TakeIsMIDI(take) then
      local guid = get_take_guid(take)
      if not guid then
        skipped = skipped + 1
      elseif not (record and record.takes[guid]) then
        local len = tonumber(reaper.GetMediaItemInfo_Value(item, "D_LENGTH")) or 0
        list[#list + 1] = { take = take, item = item, guid = guid, len = math.max(0, len) }
      end
    end
  end
  return list, skipped
end

-- What K.pre_progress gives while no pre-analysis runs: 1 after one finished, 0 otherwise
K.pre_last_progress = 0

--- Start the pre-analysis of `tracks` (a list of MediaTrack). opts (optional): fresh = true hears every take again and
--- ignores the records the tracks hold; on_done(results) runs once when every track is finished, results[track] =
--- its record. A track with nothing new to hear gives its record as it is (not pending); a track with no audio and
--- no record gets one from an empty tally (pending, so it is not heard every time); a track that is not (or no
--- longer) in the project gets nothing. Returns true when something is to be heard (state.pre is set and
--- state.is_analyzing is true); false, after calling on_done at once, otherwise.
K.pre_begin = function(tracks, opts)
  opts = opts or {}
  if state.pre then K.pre_cancel() end
  local queue, results, total = {}, {}, 0
  for _, track in ipairs(tracks or {}) do
    if not reaper.ValidatePtr2(0, track, "MediaTrack*") then goto next_track end
    local prev = nil
    if not opts.fresh then prev = K.track_record(track) end
    local list, skipped = K.pre_takes(track, prev)
    if #list > 0 then
      local secs = 0
      for _, entry in ipairs(list) do secs = secs + entry.len end
      queue[#queue + 1] = { track = track, prev = prev, list = list, skipped = skipped, tally = K.pre_tally_new(),
        takes = {} }
      total = total + secs
    elseif prev then
      results[track] = prev
    else
      local rec = K.track_record_build(K.pre_tally_new(), {}, nil)
      rec.skipped = skipped
      results[track] = rec
      K.track_records_pending[track] = rec
    end
    ::next_track::
  end
  K.pre_last_progress = 0
  if #queue == 0 then
    if opts.on_done then opts.on_done(results) end
    return false
  end
  state.pre = {
    queue = queue, qi = 1, ti = 1, t = 0, accessor = nil, buffer = reaper.new_array(K.PRE.BLOCK),
    results = results, on_done = opts.on_done, total_s = total, done_s = 0, n_tracks = #queue, track_idx = 1,
    track_name = "",
  }
  K.pre_name_track()
  state.is_analyzing = true
  return true
end

--- state.pre.track_name: the name of the track being heard.
K.pre_name_track = function()
  local pre = state.pre
  local tr = pre and pre.queue[pre.qi]
  if not tr then return end
  local _, name = reaper.GetTrackName(tr.track)
  pre.track_name = type(name) == "string" and name or ""
end

--- How far the pre-analysis is: seconds heard / seconds queued across all its tracks (0..1).
K.pre_progress = function()
  local pre = state.pre
  if not pre then return K.pre_last_progress end
  if pre.total_s <= 0 then return 0 end
  local entry = pre.queue[pre.qi] and pre.queue[pre.qi].list[pre.ti]
  local heard = pre.done_s + (entry and pre.accessor and math.min(pre.t, entry.len) or 0)
  return math.max(0, math.min(1, heard / pre.total_s))
end

--- Destroy the pre-analysis's open accessor, if any.
K.pre_close_accessor = function(pre)
  local accessor = pre.accessor
  pre.accessor = nil
  if accessor then pcall(reaper.DestroyAudioAccessor, accessor) end
end

--- The resync is paused while the pre-analysis runs, and K.open_accessor counts the project's change count as this
--- script's own after it bypasses a Pitch envelope: before each open (and when the run ends) pre.external remembers
--- whether the project changed meanwhile (an undo, an edit in REAPER). Whoever ends a run that saw one (on_done's
--- second argument; K.pre_cancel) sets state.last_change_count to nil after its own writes: the next frame reads the
--- project again.
K.pre_note_external = function(pre)
  if state.last_change_count ~= reaper.GetProjectStateChangeCount(0) then pre.external = true end
end

--- Go on to the next queued track. After the last one state.pre is cleared, then on_done(results, external) runs
--- (external: K.pre_note_external); when it started no analysis, state.is_analyzing goes back to false. Returns true
--- when the pre-analysis ended.
K.pre_next_track = function(pre)
  pre.qi, pre.ti, pre.t = pre.qi + 1, 1, 0
  if pre.qi > #pre.queue then
    state.pre = nil
    K.pre_last_progress = 1
    K.pre_note_external(pre)
    if pre.on_done then pre.on_done(pre.results, pre.external) end
    if not state.accessor and not state.pre then state.is_analyzing = false end
    return true
  end
  pre.track_idx = pre.qi
  if reaper.ValidatePtr2(0, pre.queue[pre.qi].track, "MediaTrack*") then K.pre_name_track() end
  return false
end

--- One slice (at most K.ANALYSIS_SLICE_S) of the running pre-analysis. A take is read in take time from 0, one block
--- of K.PRE.BLOCK samples at K.PRE.RATE every K.PRE.STEP_S while the block lies whole inside the item; a voiced
--- frame's pitch goes into its track's tally. The project can change between slices (REAPER's own edits go on), so
--- every pointer is checked before it is used: a take or item that went is counted as skipped, a track that went
--- gets no record. A record's skipped is this run's count only.
K.pre_step = function()
  local pre = state.pre
  if not pre then return end
  local params = { block_size = K.PRE.BLOCK, min_freq = K.PRE.MIN_HZ, max_freq = K.PRE.MAX_HZ,
    threshold = K.PRE.THRESHOLD }
  local block_s = K.PRE.BLOCK / K.PRE.RATE
  local slice_start = reaper.time_precise()
  while state.pre == pre do
    if reaper.time_precise() - slice_start > K.ANALYSIS_SLICE_S then break end
    local tr = pre.queue[pre.qi]
    local entry = tr.list[pre.ti]
    if not reaper.ValidatePtr2(0, tr.track, "MediaTrack*") then
      -- The track went: nothing is kept for it
      K.pre_close_accessor(pre)
      for i = pre.ti, #tr.list do pre.done_s = pre.done_s + tr.list[i].len end
      if K.pre_next_track(pre) then return end
    elseif not entry then
      -- The track is finished: its record waits for the caller's undo block
      local rec = K.track_record_build(tr.tally, tr.takes, tr.prev)
      rec.skipped = tr.skipped
      K.track_records_pending[tr.track] = rec
      pre.results[tr.track] = rec
      if K.pre_next_track(pre) then return end
    elseif not (reaper.ValidatePtr2(0, entry.item, "MediaItem*")
        and reaper.ValidatePtr2(0, entry.take, "MediaItem_Take*")) then
      -- The item or take went (deleted, glued, another take made active): skipped, like an unreadable take
      K.pre_close_accessor(pre)
      tr.skipped = tr.skipped + 1
      pre.done_s = pre.done_s + entry.len
      pre.ti, pre.t = pre.ti + 1, 0
    elseif not pre.accessor then
      -- No test of the source's sample rate here: it reads 0 for every source while REAPER is in the background
      -- ("Set media items offline when application is not active") although the accessor still reads the audio. The
      -- accessor's reads decide (a take that gives no accessor, or no audio at all, is skipped below)
      K.pre_note_external(pre)
      pre.accessor = K.open_accessor(entry.take)
      pre.t, pre.reads, pre.got = 0, 0, 0
      -- No audio to read: counted, and not listed as heard (tried again next time)
      if not pre.accessor then
        tr.skipped = tr.skipped + 1
        pre.done_s = pre.done_s + entry.len
        pre.ti = pre.ti + 1
      end
    elseif pre.t + block_s <= entry.len then
      local got = reaper.GetAudioAccessorSamples(pre.accessor, K.PRE.RATE, state.num_channels, pre.t, K.PRE.BLOCK,
        pre.buffer)
      pre.reads = pre.reads + 1
      if got and got > 0 then
        pre.got = pre.got + 1
        local _, freq = yin_process_block(pre.buffer, K.PRE.RATE, params)
        if freq then K.pre_tally_add(tr.tally, freq) end
      end
      pre.t = pre.t + K.PRE.STEP_S
    else
      -- The take is heard to its end. One whose every read gave no audio was not heard (its media went away): it is
      -- counted as skipped, not listed. A take shorter than one block (nothing to read) is heard
      K.pre_close_accessor(pre)
      if pre.reads > 0 and pre.got == 0 then
        tr.skipped = tr.skipped + 1
      else
        tr.takes[entry.guid] = true
      end
      pre.done_s = pre.done_s + entry.len
      pre.ti, pre.t = pre.ti + 1, 0
    end
  end
end

--- Stop the pre-analysis: destroy its accessor and forget it and every pending record. Safe when nothing runs. Leaves
--- state.is_analyzing to the caller (K.release_analysis clears it).
K.pre_cancel = function()
  local pre = state.pre
  state.pre = nil
  K.track_records_pending = {}
  K.pre_last_progress = 0
  if pre and pre.accessor then pcall(reaper.DestroyAudioAccessor, pre.accessor) end
  if pre and pre.external then state.last_change_count = nil end   -- K.pre_note_external
end

--- Developer switch (no interface): ExtState FancyScripts / pitch_dev_dump holds a folder, empty by default. While it
--- is set, every analysis also writes what the detector saw, one text file per item, so a change to the detector can
--- be judged again without reading the audio again (docs/superpowers/tests/pitch_correct_spec.lua reads the files).

--- The file name of an item's dump: the take's name (anything but letters, digits and "-" becomes "_") and its GUID.
K.dump_name = function(take_name, guid)
  local name = tostring(take_name or ""):gsub("[^%w%-]", "_")
  if name == "" then name = "item" end
  return "diag_" .. name .. "_" .. tostring(guid or ""):gsub("[{}]", "") .. ".tsv"
end

--- The dump of one analysis: a header line with the engine values, a line of column names, then one line per frame
--- (its time, the block's own reading or -1, rms, voiced / unvoiced, the short level, and every candidate period as
--- tau:d). `results` must still hold the candidates: K.pitch_track removes them.
K.dump_text = function(params, sample_rate, results)
  local lines = {
    string.format("# sr=%g block=%g hop=%g th=%g min=%g max=%g", sample_rate, params.block_size, params.hop_size,
      params.threshold, params.min_freq, params.max_freq),
    "time\tfreq\trms\thow\tlvl\tdips",
  }
  for _, f in ipairs(results) do
    local dips = {}
    for _, c in ipairs(f.cands or {}) do dips[#dips + 1] = string.format("%.3f:%.4f", c.tau, c.d) end
    lines[#lines + 1] = string.format("%.6f\t%.3f\t%.5f\t%s\t%.5f\t%s", f.time or 0, f.freq or -1, f.rms or 0,
      f.cands and "voiced" or "unvoiced", f.lvl or 0, table.concat(dips, " "))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Write an item's dump when the developer switch is set. Returns the file's path, or nil (the switch is empty, or
--- the folder could not be written: the status line says so).
K.dev_dump = function(take_name, guid, params, sample_rate, results)
  local folder = reaper.GetExtState("FancyScripts", "pitch_dev_dump")
  if not folder or folder == "" then return nil end
  local path = folder:gsub("[/\\]+$", "") .. "/" .. K.dump_name(take_name, guid)
  local file = io.open(path, "wb")
  if not file then
    set_status("Dev dump: couldn't write to " .. folder)
    return nil
  end
  file:write(K.dump_text(params, sample_rate, results))
  file:close()
  return path
end

--- The Monitoring FX chain's host: the master track (nil if REAPER gives none).
local function tone_master()
  return reaper.GetMasterTrack(0)
end

--- Delete the Monitoring FX at `fx` (an index with K.TONE.MON added). Never raises; returns true on success.
local function tone_delete(fx)
  local master = tone_master()
  if not master then return false end
  local ok, deleted = pcall(reaper.TrackFX_Delete, master, fx)
  return ok and deleted == true
end

--- Split a MIDI pitch into the Tone Generator's whole-step sliders: Note 0..11 (0 = A), Octave -4..4 and Fine Tune in
--- whole cents -50..50, over the fixed Base Frequency. It plays BASE_HZ * 2 ^ (octave + note / 12 + fine / 1200),
--- so 69 is 440 Hz. The pitch is clamped to MIN_PITCH..MAX_PITCH first.
K.tone_params = function(pitch)
  local T = K.TONE
  pitch = math.max(T.MIN_PITCH, math.min(T.MAX_PITCH, pitch))
  local cents = math.floor((pitch - 69) * 100 + 0.5)
  local semis = math.floor(cents / 100 + 0.5)
  local fine = cents - semis * 100
  return semis % 12, semis // 12, fine
end

--- The Monitoring FX index (K.TONE.MON added) of the tone effect: the one whose GUID is `guid` or, when `guid` is
--- nil, the first one renamed to K.TONE.TAG. nil when there is none.
K.tone_find = function(guid)
  local master = tone_master()
  if not master then return nil end
  for i = 0, reaper.TrackFX_GetRecCount(master) - 1 do
    local fx = K.TONE.MON + i
    if guid then
      if reaper.TrackFX_GetFXGUID(master, fx) == guid then return fx end
    else
      local ok, name = reaper.TrackFX_GetNamedConfigParm(master, fx, "renamed_name")
      if ok and name == K.TONE.TAG then return fx end
    end
  end
  return nil
end

--- Add the tone effect silently and remember it in state.tone. Returns false (and state.tone stays nil) on failure.
local function tone_add()
  local T = K.TONE
  local master = tone_master()
  if not master then return false end
  -- Whatever index comes back is the one used (the effect is first in the chain, so normally 0)
  local idx = reaper.TrackFX_AddByName(master, T.FX_NAME, true, T.INSERT_FIRST)
  if not idx or idx < 0 then return false end
  local fx = T.MON + idx
  -- The effect is born with Wet -12 dB and Dry -6 dB: silence it and pass the monitored audio untouched first
  reaper.TrackFX_SetParam(master, fx, T.P_WET, T.SILENT_DB)
  reaper.TrackFX_SetParam(master, fx, T.P_DRY, 0)
  if not reaper.TrackFX_SetNamedConfigParm(master, fx, "renamed_name", T.TAG) then
    tone_delete(fx)   -- an untagged effect could not be told apart from the user's own: count it as an add failure
    return false
  end
  reaper.TrackFX_SetParam(master, fx, T.P_FREQ, T.BASE_HZ)
  reaper.TrackFX_SetParam(master, fx, T.P_SHAPE, 0)
  local guid = reaper.TrackFX_GetFXGUID(master, fx)
  if not guid then
    tone_delete(fx)
    return false
  end
  state.tone = { guid = guid, gain = 0 }
  return true
end

--- Drive the note tone; call once per frame. With a pitch (MIDI note number) the tone fades in and follows it; with
--- nil it fades out and the effect is deleted. Does nothing while there is neither a tone nor a pitch. Adding or
--- deleting Monitoring FX makes no undo point, so this never opens an undo block.
K.tone_tick = function(pitch)
  local T = K.TONE
  if not state.tone then
    if not pitch or state.tone_failed then return end
    if not tone_add() then
      state.tone_failed = true
      set_status("Note tone unavailable: REAPER's Tone Generator effect was not found")
      return
    end
  end
  local tone = state.tone
  local master = tone_master()
  local fx = master and K.tone_find(tone.guid)
  if not fx then   -- the user deleted the effect mid-drag
    state.tone = nil
    return
  end
  if pitch then
    tone.gain = math.min(1, tone.gain + 1 / T.RAMP_FRAMES)
    local note, octave, fine = K.tone_params(pitch)
    -- Fine Tune first: when a semitone is crossed, Note / Octave and Fine Tune change together, and this order never
    -- lets the tone pass through a wrong in-between pitch
    if fine ~= tone.fine then
      reaper.TrackFX_SetParam(master, fx, T.P_FINE, fine)
      tone.fine = fine
    end
    if note ~= tone.note then
      reaper.TrackFX_SetParam(master, fx, T.P_NOTE, note)
      tone.note = note
    end
    if octave ~= tone.octave then
      reaper.TrackFX_SetParam(master, fx, T.P_OCTAVE, octave)
      tone.octave = octave
    end
  else
    tone.gain = math.max(0, tone.gain - 1 / T.RAMP_FRAMES)
    if tone.gain < 1e-6 then
      tone_delete(fx)
      state.tone = nil
      return
    end
  end
  local wet_db = T.LEVEL_DB + 20 * math.log(tone.gain, 10)
  wet_db = math.max(T.SILENT_DB, wet_db)
  if wet_db ~= tone.wet then   -- only when it changed since the last frame
    reaper.TrackFX_SetParam(master, fx, T.P_WET, wet_db)
    tone.wet = wet_db
  end
end

--- Remove the tone effect at once: the instance in state.tone, then every Monitoring FX tagged K.TONE.TAG (a leftover
--- of a crashed run). Idempotent, safe before any tone started and at exit; never raises.
K.tone_kill = function()
  pcall(function()
    local tone = state.tone
    if tone then
      local fx = K.tone_find(tone.guid)
      if fx then tone_delete(fx) end
    end
    for _ = 1, 64 do   -- bounded: a delete that keeps failing must not hang the exit
      local fx = K.tone_find(nil)
      if not fx or not tone_delete(fx) then break end
    end
  end)
  state.tone = nil
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
  state.point_drag = nil
  state.context_point = nil
  state.hovered_point = nil
  state.point_ghost = nil
  state.points_hover_note = nil
  state.points_zoom_hint = false
  state.nudge_burst = nil
  K.reset_view()   -- the canvas shows the whole item again
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

--- An audio accessor that reads the take without its pitch correction. REAPER's take accessor returns the audio with
--- the take's active Pitch envelope applied (seen 2026-11-23: a note quantized by -0.59 st was read 0.59 st low), and
--- it keeps the take state it was made with until AudioAccessorValidateState / AudioAccessorUpdate is called, which
--- this script never does. So the envelope is bypassed, the accessor made and the envelope's chunk put back byte for
--- byte, all in this one call: nothing is heard, no undo point is added, and the envelope is as it was whatever
--- happens to the analysis afterwards. An envelope that is bypassed already or holds no points is left alone.
--- Returns the accessor, or nil when REAPER gave none.
K.open_accessor = function(take)
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  local chunk = nil
  if env then
    local ok, text = reaper.GetEnvelopeStateChunk(env, "", false)
    if ok and text and text:match("ACT%s+1") and text:match("\nPT ") then chunk = text end
  end
  if chunk then reaper.SetEnvelopeStateChunk(env, (chunk:gsub("ACT%s+1", "ACT 0", 1)), false) end
  local ok, accessor = pcall(reaper.CreateTakeAudioAccessor, take)
  if chunk then
    reaper.SetEnvelopeStateChunk(env, chunk, false)
    note_own_write()   -- the two chunk writes moved the project's change count: they are this script's own
  end
  if ok and accessor then return accessor end
  return nil
end

--- The detection values the Settings hold now: a fresh table of the K.ANALYSIS_KEYS copied from state.
K.analysis_defaults = function()
  local values = {}
  for _, key in ipairs(K.ANALYSIS_KEYS) do values[key] = state[key] end
  return values
end

--- A validated copy of the K.ANALYSIS_KEYS of `t`, or nil when `t` is not a table or any of them is missing or
--- invalid: a finite number (not a string): Hz within the widest Settings span with min below max, threshold inside K.LIMITS, a block size and a hop size from the lists,
--- with the hop no longer than the block. auto_range is true only when it is true (absent or anything else: false);
--- an Auto analysis's found notes auto_lo_st / auto_hi_st are kept when both are whole numbers with lo <= hi, and
--- auto_none (nothing was found) is true only when it is true.
K.analysis_values = function(t)
  if type(t) ~= "table" then return nil end
  local function listed(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
  end
  local values = {}
  for _, key in ipairs(K.ANALYSIS_KEYS) do
    local v = t[key]
    if key == "auto_range" then
      v = v == true
    elseif type(v) ~= "number" or v ~= v then
      return nil
    end
    values[key] = v
  end
  local function whole(n) return type(n) == "number" and math.abs(n) < math.huge and n == math.floor(n) end
  local lo, hi = t.auto_lo_st, t.auto_hi_st
  if whole(lo) and whole(hi) and lo <= hi then values.auto_lo_st, values.auto_hi_st = lo, hi end
  values.auto_none = t.auto_none == true
  -- Both Hz values are held to the widest span the Settings allow (Min Freq's low end to Max Freq's high end), and
  -- the low end must be below the high end
  local hz_lo, hz_hi = K.LIMITS.min_freq[1], K.LIMITS.max_freq[2]
  for _, key in ipairs({ "min_freq", "max_freq" }) do
    if values[key] < hz_lo or values[key] > hz_hi then return nil end
  end
  if values.min_freq >= values.max_freq then return nil end
  local lim = K.LIMITS.threshold
  if values.threshold < lim[1] or values.threshold > lim[2] then return nil end
  if not listed(BLOCK_SIZES, values.block_size) or not listed(HOP_SIZES, values.hop_size) then return nil end
  if values.hop_size > values.block_size then return nil end
  return values
end

--- The index of the VOCAL_RANGES entry `values` show, 0 for none: the Auto entry when values.auto_range is true
--- (whatever Hz an Auto analysis ran with), else the hand-picked range with both Hz.
K.range_index = function(values)
  local auto = values.auto_range == true
  return K.match_preset(VOCAL_RANGES, function(e)
    if auto then return e.auto == true end
    return not e.auto and e.min == values.min_freq and e.max == values.max_freq
  end)
end

--- The Vocal Range `values` show by name: "Auto"; on an item analysed with it "Auto: E2–A4" (the notes found) or
--- "Auto: Generic Vocal (nothing found)"; else the range's name, K.CUSTOM_PRESET for Hz that match none.
K.range_name = function(values)
  if values.auto_range == true then
    if type(values.auto_lo_st) == "number" and type(values.auto_hi_st) == "number" then
      return "Auto: " .. K.pre_range_text(values.auto_lo_st, values.auto_hi_st)
    end
    if values.auto_none == true then return "Auto: Generic Vocal (nothing found)" end
  end
  local entry = VOCAL_RANGES[K.range_index(values)]
  return entry and entry.name or K.CUSTOM_PRESET
end

--- The Vocal Range row's tooltip for `values`: on an item whose range was found, that range in Hz; else the row's
--- own (K.ROW_TIPS.range).
K.range_tip = function(values)
  local lo, hi = values.auto_lo_st, values.auto_hi_st
  if values.auto_range ~= true or type(lo) ~= "number" or type(hi) ~= "number" then return K.ROW_TIPS.range end
  local function hz(st) return 440 * 2 ^ ((st - 69) / 12) end
  return K.range_name(values) .. "\n\n"
    .. string.format("%.0f\xE2\x80\x93%.0f Hz, with a little room either side", hz(lo), hz(hi))
end

--- Why Min Freq and Max Freq are disabled for `values`: nil, or "Found from the track" while Vocal Range is Auto.
K.auto_hz_reason = function(values)
  if values.auto_range == true then return "Found from the track" end
  return nil
end

--- Which of the three rows (Vocal Range, Detection Mode, Quality) of `values` match a preset: the names of the
--- presets (Vocal Range: K.range_name), K.CUSTOM_PRESET for a row that matches none.
K.form_part_names = function(values)
  local m = K.match_preset(DETECTION_MODES, function(e) return e.threshold == values.threshold end)
  local q = K.match_preset(QUALITY_MODES, function(e) return e.block == values.block_size and e.hop == values.hop_size end)
  return K.range_name(values),
    DETECTION_MODES[m] and DETECTION_MODES[m].name or K.CUSTOM_PRESET,
    QUALITY_MODES[q] and QUALITY_MODES[q].name or K.CUSTOM_PRESET
end

--- "Soprano · Clean / Strict · Standard (Realtime)": the three rows of `values` by preset name.
K.form_summary = function(values)
  local r, m, q = K.form_part_names(values)
  return r .. " · " .. m .. " · " .. q
end

--- "Analyzed with Soprano · ...": what an analysed item's tooltip says, nil when it has no stored analysis.
K.analyzed_with_tip = function(data)
  local values = data and K.analysis_values(data.analysis)
  if not values then return nil end
  return "Analyzed with " .. K.form_summary(values)
end

--- Where a form for `data` starts from: "item" (it has a stored analysis), "unrecorded" (notes, no stored
--- analysis) or "defaults" (not analysed, or a batch).
K.form_source = function(data)
  if data and K.analysis_values(data.analysis) then return "item" end
  if data and data.notes and #data.notes > 0 then return "unrecorded" end
  return "defaults"
end

--- A fresh form for `guid` (or "batch", with `data` nil): the item's stored analysis when it has one, else the
--- Settings' values. `seed` is the stored table it came from (identity compare in K.form_sync).
K.form_new = function(guid, data)
  local source = K.form_source(data)
  local form = { guid = guid, edited = {}, source = source }
  if source == "item" then
    form.values = K.analysis_values(data.analysis)
    form.seed = data.analysis
  else
    form.values = K.analysis_defaults()
  end
  return form
end

--- Keep state.analysis_form on `guid`: a new form when the item changed or its stored analysis is not the one the
--- form was seeded from (an undo or a re-analysis replaced it); otherwise the rows the user has not touched follow
--- the Settings' defaults (not for an item's own values).
K.form_sync = function(guid, data)
  local form = state.analysis_form
  if not form or form.guid ~= guid or form.seed ~= (data and data.analysis or nil) or form.source ~= K.form_source(data) then
    state.analysis_form = K.form_new(guid, data)
    return
  end
  if form.source ~= "item" then
    local defaults = K.analysis_defaults()
    for _, key in ipairs(K.ANALYSIS_KEYS) do
      if not form.edited[key] then form.values[key] = defaults[key] end
    end
  end
end

--- The values a row writes for `key`: "range" takes a VOCAL_RANGES entry (both Hz, and whether it is Auto: only this
--- row changes auto_range) and "quality" a QUALITY_MODES entry (block and hop); any other key is one value of its own.
K.value_pairs = function(key, value)
  if key == "range" then return { min_freq = value.min, max_freq = value.max, auto_range = value.auto == true } end
  if key == "quality" then return { block_size = value.block, hop_size = value.hop } end
  return { [key] = value }
end

--- Set one value of the form and mark it edited. key "range" takes a VOCAL_RANGES entry (both Hz) and "quality" a
--- QUALITY_MODES entry (block and hop).
K.form_set = function(form, key, value)
  for k, v in pairs(K.value_pairs(key, value)) do
    form.values[k] = v
    form.edited[k] = true
  end
end

--- Put a row back to the Settings' default: row_id "range", "mode", "quality", "block", "hop", "threshold",
--- "min_freq" or "max_freq" (K.hz_reset_follows: both Hz back at the default ones bring the default range back).
K.form_reset_row = function(form, row_id)
  local keys_of = {
    range = { "min_freq", "max_freq", "auto_range" }, mode = { "threshold" }, quality = { "block_size", "hop_size" },
    block = { "block_size" }, hop = { "hop_size" }, threshold = { "threshold" },
    min_freq = { "min_freq" }, max_freq = { "max_freq" },
  }
  local defaults = K.analysis_defaults()
  for _, key in ipairs(keys_of[row_id] or {}) do
    form.values[key] = defaults[key]
    form.edited[key] = nil
  end
  if (row_id == "min_freq" or row_id == "max_freq") and K.hz_reset_follows(form.values, defaults) then
    form.edited.auto_range = nil
  end
end

--- After a Min Freq or Max Freq reset of `v` to the defaults `base`: when both Hz now are the default range's, the
--- default range is back whole, its auto_range included (the Hz rows never set auto_range otherwise, so a section
--- reset of them ends at the defaults). Returns true when it restored auto_range.
K.hz_reset_follows = function(v, base)
  if v.min_freq ~= base.min_freq or v.max_freq ~= base.max_freq then return false end
  v.auto_range = base.auto_range == true
  return true
end

--- How many of the three rows (Vocal Range, Detection Mode, Quality) of `values` differ from the Settings' defaults.
K.form_changed_rows = function(values)
  local d = K.analysis_defaults()
  local n = 0
  if values.min_freq ~= d.min_freq or values.max_freq ~= d.max_freq or (values.auto_range == true) ~= (d.auto_range == true) then
    n = n + 1
  end
  if values.threshold ~= d.threshold then n = n + 1 end
  if values.block_size ~= d.block_size or values.hop_size ~= d.hop_size then n = n + 1 end
  return n
end

--- The form's header line.
K.form_header = function(form)
  if form.source == "item" then return "ANALYSIS SETTINGS · as analyzed before" end
  if form.source == "unrecorded" then return "ANALYSIS SETTINGS · not recorded, your defaults" end
  local n = K.form_changed_rows(form.values)
  if n == 0 then return "ANALYSIS SETTINGS · your defaults" end
  return string.format("ANALYSIS SETTINGS · %d changed from defaults", n)
end

--- The Save as Default confirm (a request_confirm request) for `values`.
K.form_defaults_request = function(values)
  local copy = {}
  for _, key in ipairs(K.ANALYSIS_KEYS) do copy[key] = values[key] end
  -- The default is Auto itself, never the Hz an Auto analysis of an item ran with
  if copy.auto_range then
    local auto = VOCAL_RANGES[K.range_index(copy)]
    copy.min_freq, copy.max_freq = auto.min, auto.max
  end
  local nr, nm, nq = K.form_part_names(copy)
  local or_, om, oq = K.form_part_names(K.analysis_defaults())
  local parts = {}
  if nr ~= or_ then parts[#parts + 1] = string.format("%s (was %s)", nr, or_) end
  if nm ~= om then parts[#parts + 1] = string.format("%s (was %s)", nm, om) end
  if nq ~= oq then parts[#parts + 1] = string.format("%s (was %s)", nq, oq) end
  local first = #parts > 0 and ("New analyses will start with: " .. table.concat(parts, ", ") .. ".")
    or "New analyses will start with these values."
  return {
    title = "Make these your defaults?",
    body_lines = { first, "Items already analyzed keep their own settings." },
    confirm_label = "Save as Default",
    fit = true,    -- as tall as its two lines: no empty block above the buttons
    safe = true,   -- nothing the user made is lost (items keep their own settings)
    on_confirm = function()
      for _, key in ipairs(K.ANALYSIS_KEYS) do state[key] = copy[key] end
      K.save_settings("engine")
      -- The canvas form's untouched rows follow the new defaults (Save as Default in the analysis modal never
      -- touches the canvas form itself), as after a Settings change
      local guid = state.target_take_guid
      if guid then K.form_sync(guid, state.session_takes[guid]) end
      set_status("Defaults saved.")
    end,
  }
end

--- Start analysing `take` (in `item`): it becomes the target and its audio is read slice by slice from the next
--- frame on (process_analysis_step). opts (optional):
---   sample_rate     the rate to read at, when the caller already knows it (a batch records it when it starts:
---                   REAPER can report 0 for every source while it is in the background, see K.batch_selection)
---   values          the detection values to analyse with (K.analysis_defaults() shape); omitted: the Settings' now
---   defer_envelope  do not create or show the take's Pitch envelope now (a batch does it in its one undo block)
--- Returns true, or false and why: "offline" (the source has no sample rate: its media is offline) or "accessor"
--- (REAPER gave no audio accessor). Nothing is changed when it returns false.
K.analysis_begin = function(take, item, opts)
  opts = opts or {}
  K.reanalyze_status_guid = nil   -- set again by K.request_analyze for the analysis it starts
  local sample_rate = opts.sample_rate
  if not sample_rate then
    local source = reaper.GetMediaItemTake_Source(take)
    sample_rate = source and reaper.GetMediaSourceSampleRate(source)
  end
  -- Without a rate nothing can be read; analysing anyway would store an analysis with no notes
  if not sample_rate or sample_rate <= 0 then return false, "offline" end

  local accessor = K.open_accessor(take)
  if not accessor then return false, "accessor" end

  local guid = get_take_guid(take)
  if guid then state.target_take_guid = guid end
  state.target_take_name = reaper.GetTakeName(take) or state.target_take_name
  -- An item analysed before starts again at its defaults (K.item_default): it is split at its default Separation, not its own (its
  -- Key and Scale stay). An item not analysed yet uses the Separation the bar shows for it (the default, unless it
  -- was set for this item before its first analysis)
  if guid and state.session_takes[guid] then state.separation = (K.item_default("separation", guid)) end

  state.start_time = 0 -- Relative to item start
  state.item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  state.end_time = state.item_len
  state.current_time = 0
  state.sample_rate = sample_rate

  -- A bad engine value must never crash (negative array size) or hang (a hop of 0 never advances the
  -- analysis time) an analysis: clamp to 64 <= block, 1 <= hop <= block before anything is allocated
  local values = opts.values or K.analysis_defaults()
  -- A zero-width or inverted Hz range finds nothing and is stored as "not recorded": analyse with the Settings'
  -- values instead (and the factory Hz when those are inverted too)
  local function hz_ok(t) return (tonumber(t.min_freq) or 0) < (tonumber(t.max_freq) or 0) end
  if not hz_ok(values) then
    values = K.analysis_defaults()
    if not hz_ok(values) then values.min_freq, values.max_freq = DEFAULTS.min_freq, DEFAULTS.max_freq end
  end
  local block = math.floor(tonumber(values.block_size) or DEFAULTS.block_size)
  block = math.max(K.BLOCK_SIZE_MIN, math.min(K.BLOCK_SIZE_MAX, block))
  local hop = math.floor(tonumber(values.hop_size) or DEFAULTS.hop_size)
  hop = math.max(1, math.min(block, hop))

  -- The running analysis reads this snapshot, never the live settings: the Settings controls are locked meanwhile,
  -- and a value changed some other way cannot overrun the sample buffer or mix two parameter sets
  state.analysis_params = {
    block_size = block, hop_size = hop, threshold = values.threshold,
    min_freq = values.min_freq, max_freq = values.max_freq, auto_range = values.auto_range == true,
  }
  -- An Auto range keeps what it was found from (K.auto_values), so the item shows "Auto: E2–A4" afterwards
  if values.auto_range == true then
    state.analysis_params.auto_lo_st, state.analysis_params.auto_hi_st = values.auto_lo_st, values.auto_hi_st
    state.analysis_params.auto_none = values.auto_none == true or nil
  end

  state.accessor = accessor
  state.buffer = reaper.new_array(state.analysis_params.block_size)

  state.results = {}
  state.is_analyzing = true
  state.analysis_empty = false
  state.progress = 0
  state.nudge_burst = nil
  K.reset_view()   -- the canvas shows the whole item again

  -- Ensure take pitch envelope is created and active on the take upfront (own named undo point,
  -- and only when it actually changes something)
  if not opts.defer_envelope and pitch_envelope_needs_setup(take) then
    reaper.Undo_BeginBlock()
    ensure_take_pitch_envelope(take, item, true)
    reaper.Undo_EndBlock("Show Pitch Envelope", -1)
    note_own_write()
  end
  return true
end

-- Auto range and key, wired into Analyze (docs/design/pitch-correct-auto-range-key.md): when Vocal Range or Key is
-- on Auto, the item's track is heard first (stage 1, K.pre_begin), then the item is analysed with the range found
-- (stage 2). The record found waits in K.track_records_pending and is written inside the analysis's own undo block;
-- every way an analysis ends without one drops it (K.auto_drop). K.auto_run carries a single analysis's stage-1
-- outcome to its end: { guid, track, rec, fresh, pre_ran, want_range, want_key, skipped, total }.
K.auto_run = nil
K.AUTO_UNREADABLE_TEXT = "Couldn't read this item's audio. Check that its media is online, then try again."
-- Shared by the Auto analysis, Find Key and Find Range and Key Again: the key kept, and items skipped of a track
K.NO_KEY_FMT = "Not enough singing to tell the key: kept %s."
K.SKIPPED_FMT = "Couldn't read %d of %d items on %s (media offline). Used the rest."

--- True when analysing the item `guid` with `values` needs its track's range or key: Vocal Range is Auto, or the
--- item is not analysed yet and the bar's Key is Auto (0).
K.auto_needed = function(values, guid)
  if values and values.auto_range == true then return true end
  return not (guid and state.session_takes[guid]) and state.key_idx == 0
end

--- A copy of `values` to analyse with. With Vocal Range Auto: the Hz of the range in `record` (K.pre_range_hz, its
--- notes kept as auto_lo_st / auto_hi_st), or, when the record (nil counts) has no range, Generic Vocal's Hz with
--- auto_none. A fixed range is left as it is. Returns the copy and whether nothing was found (none).
K.auto_values = function(values, record)
  local out = {}
  for k, v in pairs(values or K.analysis_defaults()) do out[k] = v end
  if out.auto_range ~= true then return out, false end
  out.auto_lo_st, out.auto_hi_st, out.auto_none = nil, nil, nil
  if record and record.lo_st and record.hi_st then
    out.min_freq, out.max_freq = K.pre_range_hz(record.lo_st, record.hi_st)
    out.auto_lo_st, out.auto_hi_st = record.lo_st, record.hi_st
    return out, false
  end
  for _, r in ipairs(VOCAL_RANGES) do
    if r.name == "Generic Vocal" and not r.auto then out.min_freq, out.max_freq = r.min, r.max end
  end
  out.auto_none = true
  return out, true
end

--- The status message after an Auto analysis, and its kind ("none", "no_key", "skipped", "found", "used"), or nil.
--- info = { fresh (stage 1 heard the track), range_text, key_text, alt_text, track (its name), none (no range found),
--- no_key (no key found), kept_key_text, skipped, total (items on the track this run), want_range, want_key }. One
--- message, by priority: no range > no key > unreadable media > found / used. Only what was on Auto is named.
K.auto_status = function(info)
  local track = info.track or ""
  if info.want_range and info.none then
    return string.format("Couldn't find a range on %s: used Generic Vocal.", track), "none"
  end
  if info.want_key and info.no_key then
    return string.format(K.NO_KEY_FMT, info.kept_key_text or ""), "no_key"
  end
  if info.fresh and (info.skipped or 0) > 0 then
    return string.format(K.SKIPPED_FMT, info.skipped,
      math.max(info.total or 0, info.skipped), track), "skipped"
  end
  local parts = {}
  if info.want_range and info.range_text then parts[#parts + 1] = info.range_text end
  if info.want_key and info.key_text then parts[#parts + 1] = info.key_text end
  if #parts == 0 then return nil end
  if info.fresh then
    local alt = (info.want_key and info.alt_text) and string.format(" (%s also fits)", info.alt_text) or ""
    return string.format("Found %s%s. %s+Z to undo.", table.concat(parts, ", "), alt, K.MOD_LABEL), "found"
  end
  local what = (info.want_range and info.want_key) and "range and key" or (info.want_range and "range" or "key")
  return string.format("Used %s's %s: %s.", track, what, table.concat(parts, ", ")), "used"
end

--- The status message for the Auto analysis K.auto_run of `data` (the item's new model), and its kind, or nil.
K.auto_run_status = function(run, data)
  local rec = run.rec
  local _, name = reaper.GetTrackName(run.track)
  local info = {
    fresh = run.fresh, track = type(name) == "string" and name or "", want_range = run.want_range,
    want_key = run.want_key, skipped = rec and rec.skipped or 0, total = run.total,
    none = not (rec and rec.lo_st), no_key = not (rec and rec.key_idx),
    kept_key_text = K.key_text(data.key_idx or 0, data.scale_idx or 0),
  }
  if rec and rec.lo_st then info.range_text = K.pre_range_text(rec.lo_st, rec.hi_st) end
  if rec and rec.key_idx then info.key_text = K.key_text(rec.key_idx, rec.scale_idx) end
  if rec and rec.alt_key_idx then info.alt_text = K.key_text(rec.alt_key_idx, rec.alt_scale_idx) end
  return K.auto_status(info)
end

--- Why the analysis controls are disabled while something runs: during stage 1 how far it is ("Finding range and
--- key… 42%", with the track's name when this run hears two or more), else K.LOCKED_REASON.
K.locked_reason = function()
  local pre = state.pre
  if not pre then return K.LOCKED_REASON end
  local pct = math.floor(K.analysis_progress() * 100)
  if (pre.n_tracks or 1) > 1 then
    return string.format("Finding range and key: %s… %d%%", pre.track_name or "", pct)
  end
  return string.format("Finding range and key… %d%%", pct)
end

--- Analyse `take` (in `item`) with Vocal Range or Key on Auto: its track is heard first, unless its record covers
--- every take already (then at once), and the analysis starts with the range found (K.auto_values).
K.auto_begin = function(take, item, values, guid)
  local track = reaper.GetMediaItemTake_Track(take)
  if track and not reaper.ValidatePtr2(0, track, "MediaTrack*") then track = nil end
  local run = { guid = guid, track = track, want_range = values.auto_range == true, want_key = K.auto_needed(nil, guid) }
  if track then
    local list, skipped = K.pre_takes(track, K.track_record(track))
    run.total = #list + skipped
  end
  local sync = true
  local function on_done(results, external)
    local pre_ran = not sync
    local rec = track and results[track] or nil
    run.rec, run.pre_ran, run.external = rec, pre_ran, external
    run.fresh = track ~= nil and K.track_records_pending[track] ~= nil
    -- The item can go while its track is heard: nothing is analysed then, and nothing is written
    if pre_ran and not (reaper.ValidatePtr2(0, take, "MediaItem_Take*") and reaper.ValidatePtr2(0, item, "MediaItem*")) then
      K.auto_drop()
      if external then state.last_change_count = nil end
      set_status("This item is no longer in the project")
      return
    end
    local reanalyze = K.reanalyze_status_guid   -- K.request_analyze set it while stage 1 ran
    if not K.analysis_begin(take, item, { values = (K.auto_values(values, rec)) }) then
      K.auto_drop()
      if external then state.last_change_count = nil end   -- after K.analysis_begin's own accessor
      set_status(K.AUTO_UNREADABLE_TEXT)
      return
    end
    if pre_ran then K.reanalyze_status_guid = reanalyze end
    K.auto_run = run
  end
  if track then
    K.pre_begin({ track }, { on_done = on_done })
  else
    on_done({})
  end
  sync = false
end

--- Analyse the open item (Analyze / Re-Analyze, and the canvas button with one item selected). Never while an
--- analysis, a batch or a pre-analysis runs.
local function start_analysis(values)
  if state.is_analyzing or K.batch or state.pre then return end
  -- Prefer the current target (a sidebar click sets it without touching REAPER's selection);
  -- get_target_take() falls back to the selected audio item only when there is no usable target.
  local take, item = get_target_take()

  if not item or not take then
    set_status("Select an audio item first")
    return
  end
  K.auto_drop()
  local guid = get_take_guid(take)
  if K.auto_needed(values or K.analysis_defaults(), guid) then
    K.auto_begin(take, item, values or K.analysis_defaults(), guid)
    return
  end
  if not K.analysis_begin(take, item, { values = values }) then
    set_status(K.AUTO_UNREADABLE_TEXT)
  end
end

-------------------------------------------------------------------------------
-- 4. SIGNAL PROCESSING & PITCH EXTRACTION HELPERS
-------------------------------------------------------------------------------

local function gaussian_filter(arr, sigma_frames)
  local n = #arr
  if n == 0 then return {} end
  if n == 1 then return { arr[1] } end
  local res = {}
  local radius = math.max(1, math.ceil(sigma_frames * 2.5))
  local weight = {}   -- [distance in frames + 1]
  for d = 0, math.min(radius, n - 1) do
    local dist = d / sigma_frames
    weight[d + 1] = math.exp(-0.5 * dist * dist)
  end
  for i = 1, n do
    local sum, w_sum = 0, 0
    for j = math.max(1, i - radius), math.min(n, i + radius) do
      local w = weight[(j < i and i - j or j - i) + 1]
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

-------------------------------------------------------------------------------
-- PER-NOTE VALUES: a note's own settings, each in note.controls[key] (nil = not set). Its pitch
-- (controls.center_pitch), its bypass (controls.bypassed) and its pitch points (controls.points) are handled apart.
--   merge    what a merged note gets: "weighted" = the merged notes' average by length, "first" = the first note's
--   edited   when the value makes its note count as edited: "positive" = above 0; "set" = stored at all (an
--            override that equals the item's value still counts)
-- nil means "follow the item" (get_effective); every value, 0 included, is a value of the note's own.
-------------------------------------------------------------------------------
K.NOTE_CONTROLS = {
  { key = "tighten",       merge = "weighted", edited = "set" },   -- 0 (as sung) .. 1 (a flat line)
  { key = "tolerance",     merge = "first",    edited = "set" },   -- cents
  { key = "retune_speed",  merge = "first",    edited = "set" },
  { key = "slide_in",      merge = "first",    edited = "set" },   -- 0 (natural) .. 1 (corrected)
  { key = "correct_mode",  merge = "first",    edited = "set" },   -- 0 Natural, 1 Classic, 2 Hard
}

--- The values a note cut from the note with `old_ctrl` keeps (Split, Trim): all of them, and its bypass.
K.controls_carry = function(old_ctrl)
  local out = { bypassed = old_ctrl and old_ctrl.bypassed or false }
  if old_ctrl then
    for _, d in ipairs(K.NOTE_CONTROLS) do out[d.key] = old_ctrl[d.key] end
  end
  return out
end

--- The values of the note merged from `notes` (in time order); it is not bypassed. A weighted value is the
--- average by length of each note's value in force (its own, else the item's); nil (follow the item) when no
--- merged note had one of its own.
K.controls_merge = function(notes)
  local out = { bypassed = false }
  local first = notes[1] and notes[1].controls
  local total = 0
  for _, n in ipairs(notes) do total = total + (n.end_time - n.start_time) end
  for _, d in ipairs(K.NOTE_CONTROLS) do
    if d.merge == "weighted" then
      local sum, own = 0, false
      for _, n in ipairs(notes) do
        if n.controls and n.controls[d.key] ~= nil then own = true end
        sum = sum + (tonumber(get_effective(n, d.key)) or 0) * (n.end_time - n.start_time)
      end
      out[d.key] = (own and total > 0) and (sum / total) or nil
    elseif first then
      out[d.key] = first[d.key]
    end
  end
  return out
end

--- True when one of the values makes its note count as edited.
K.controls_edited = function(ctrl)
  for _, d in ipairs(K.NOTE_CONTROLS) do
    local v = ctrl[d.key]
    if d.edited == "set" then
      if v ~= nil then return true end
    elseif (tonumber(v) or 0) > 0 then
      return true
    end
  end
  return false
end

--- Unset every value; true when one was stored.
K.controls_clear = function(ctrl)
  local changed = false
  for _, d in ipairs(K.NOTE_CONTROLS) do
    if ctrl[d.key] ~= nil then changed = true end
    ctrl[d.key] = nil
  end
  return changed
end

--- Take the saved controls of a note over into `ctrl` (a new note's defaults): its pitch, its bypass, its points
--- (checked afterwards by K.points_sanitize) and the values above, each a number; Tighten and Tolerance are held
--- in range. Anything else that was saved is dropped (Stability and Vibrato of builds before 2.12).
K.controls_load = function(ctrl, saved)
  if type(saved) ~= "table" then return end
  if type(saved.center_pitch) == "number" then ctrl.center_pitch = saved.center_pitch end
  ctrl.bypassed = saved.bypassed == true
  ctrl.points = saved.points
  for _, d in ipairs(K.NOTE_CONTROLS) do ctrl[d.key] = tonumber(saved[d.key]) end
  local lim = K.LIMITS.tolerance
  if ctrl.tighten then ctrl.tighten = math.max(0, math.min(1, ctrl.tighten)) end
  if ctrl.tolerance then ctrl.tolerance = math.max(lim[1], math.min(lim[2], ctrl.tolerance)) end
  if ctrl.correct_mode and (type(saved.correct_mode) ~= "number" or ctrl.correct_mode % 1 ~= 0
      or ctrl.correct_mode < 0 or ctrl.correct_mode > 2) then
    ctrl.correct_mode = nil
  end
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

  -- 2. Zero-phase Gaussian filtering: the smooth pitch (what Tighten works on) and the slow trend
  --    Smooth pitch (sigma ~1.5 frames) removes micro-jitters without phase distortion
  --    Trend (sigma ~7.0 frames, ~2 Hz cutoff) isolates slow drift without vibrato ripple
  local smooth_pitch = gaussian_filter(raw_pitch, 1.5)
  local trend = gaussian_filter(raw_pitch, 7.0)

  -- 3. Modulation: the fast movement around the trend (its peaks and valleys are the pitch points, step 5)
  local mod = {}
  for i = 1, #raw_pitch do
    mod[i] = smooth_pitch[i] - trend[i]
  end

  -- 4. Calculate robust pitch center (energy-weighted mean of the sustained core)
  --    Excludes initial onset scoop (first 12%) and release tail (last 12%), and any frame more than
  --    K.CENTRE_OUTLIER_ST from the core's middle pitch: a pitch reading in the wrong octave must not move the centre.
  --    The middle pitch is a frame's own (the lower of the two middle ones for an even count), so a frame always counts
  local total_w = 0
  local weighted_sum = 0
  local start_f = math.max(1, math.floor(#note.frames * 0.12))
  local end_f = math.min(#note.frames, math.ceil(#note.frames * 0.88))
  local core = {}
  for i = start_f, end_f do core[#core + 1] = note.frames[i].note end
  table.sort(core)
  local mid = core[(#core + 1) // 2]
  for i = start_f, end_f do
    local f = note.frames[i]
    if math.abs(f.note - mid) <= K.CENTRE_OUTLIER_ST then
      local w = math.max(0.0001, (f.rms or 0.05))
      weighted_sum = weighted_sum + f.note * w
      total_w = total_w + w
    end
  end
  if total_w > 0 then
    note.avg_note = weighted_sum / total_w
    note.display_note = math.floor(note.avg_note + 0.5)
  end

  -- 5. Find Smart Spots via Zero-Crossing (for visual rendering / anchor points)
  -- These peaks and valleys also define where saved pitch points (bends) are pinned: changing the 0.05 threshold
  -- or the filters below reshapes every stored bend and marks those items outdated.
  local smart_spots = {}

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
        table.insert(smart_spots, { index = extrema_idx, type = s_type })
      end
      current_sign = sign
      extrema_idx = i
      extrema_val = val
    end
  end

  if extrema_idx and math.abs(extrema_val) > 0.05 and extrema_idx ~= 1 and extrema_idx ~= #raw_pitch then
    local s_type = current_sign == 1 and "peak" or "valley"
    table.insert(smart_spots, { index = extrema_idx, type = s_type })
  end


  note.smooth = smooth_pitch   -- the lightly smoothed pitch Tighten works on (K.tighten_line)
  note.smart_spots = smart_spots

  -- Default controls: NO correction (green preview = raw pitch). Every value of K.NOTE_CONTROLS starts unset.
  note.controls = {
    center_pitch = note.avg_note,
    bypassed = false,          -- per-note bypass toggle
  }

  -- Restore user tuning offsets when splitting/merging notes
  if preserve_controls then
    for k, v in pairs(preserve_controls) do
      note.controls[k] = v
    end
  end
end

-------------------------------------------------------------------------------
-- PITCH POINTS: a per-note offset curve through the note's start and end, its detected peaks and valleys and the
-- points the user added. Stored in note.controls.points (sorted by t): { t = item seconds (a frame's time),
-- st = semitones, added = true | nil }, only for an added point or one off 0; nil when there is none.
-------------------------------------------------------------------------------

--- The index of the frame of `frames` (sorted by time, at least one) nearest to the time t.
K.points_frame_at = function(frames, t)
  local lo, hi = 1, #frames
  while lo < hi do
    local mid = (lo + hi) // 2
    if frames[mid].time < t then lo = mid + 1 else hi = mid end
  end
  if lo > 1 and math.abs(frames[lo - 1].time - t) <= math.abs(frames[lo].time - t) then return lo - 1 end
  return lo
end

--- An offset as stored: within ±K.POINT_MAX_ST, rounded to 1e-6 st (a value the take data's JSON, %.10g, keeps
--- exactly, so the envelope written now and the one rebuilt after a reload come from the same number), and 0
--- under K.POINT_EPS.
K.points_clamp = function(st)
  st = math.max(-K.POINT_MAX_ST, math.min(K.POINT_MAX_ST, st))
  st = math.floor(st * 1e6 + 0.5) / 1e6
  if math.abs(st) < K.POINT_EPS then return 0 end
  return st
end

--- Make the stored points of `note` usable (saved data may be old, edited or damaged): an entry whose t or st is
--- not a number or whose t lies outside the note is dropped, st is clamped, t snaps to the nearest frame, of two
--- entries on one frame the first is kept, an entry the rule does not allow (not added, at 0) is dropped; the list
--- is sorted, and nil when empty.
K.points_sanitize = function(note)
  local ctrl = note.controls
  if not ctrl then return end
  local list, frames = ctrl.points, note.frames
  local kept, used = {}, {}
  if type(list) == "table" and frames and #frames > 0 then
    for _, e in ipairs(list) do
      if type(e) == "table" and type(e.t) == "number" and type(e.st) == "number" and e.st == e.st
          and e.t >= note.start_time and e.t <= note.end_time then
        local f = K.points_frame_at(frames, e.t)
        local st = K.points_clamp(e.st)
        local added = (e.added == true) or nil
        if not used[f] and (added or st ~= 0) then
          used[f] = true
          kept[#kept + 1] = { t = frames[f].time, st = st, added = added }
        end
      end
    end
  end
  table.sort(kept, function(a, b) return a.t < b.t end)
  ctrl.points = (#kept > 0) and kept or nil
  note.points_rev = (note.points_rev or 0) + 1
end

--- The knots of the note's offset curve, ordered by frame: { frame, t, st, kind, entry }. kind = "start" (frame 1),
--- "end" (the last frame), "added", or "spot" (a detected peak / valley, or a stored entry that was not added).
--- A detected dot closer than K.POINT_MIN_GAP frames to a stored entry is not a knot. Cached on the note with the
--- per-frame offsets (K.points_offsets) until note.points_rev, its frames, its dots or its stored list change.
K.points_knots = function(note)
  local frames, spots = note.frames, note.smart_spots
  local list = note.controls and note.controls.points
  local rev = note.points_rev or 0
  local pc = note.points_cache
  if pc and pc.rev == rev and pc.frames == frames and pc.spots == spots and pc.list == list then return pc.knots end

  local knots, offsets = {}, nil
  local nf = frames and #frames or 0
  if nf > 0 then
    local by_frame = {}   -- [frame] = knot
    local function kind_of(f, added)
      if f == 1 then return "start" elseif f == nf then return "end" end
      return added and "added" or "spot"
    end
    local stored = {}     -- frames that hold a stored entry
    for _, e in ipairs(list or {}) do
      local f = K.points_frame_at(frames, e.t)
      if not by_frame[f] then
        by_frame[f] = { frame = f, t = frames[f].time, st = e.st, kind = kind_of(f, e.added), entry = e }
        stored[#stored + 1] = f
      end
    end
    local function near_stored(f)
      for _, s in ipairs(stored) do
        if math.abs(s - f) < K.POINT_MIN_GAP then return true end
      end
      return false
    end
    for _, f in ipairs({ 1, nf }) do
      if not by_frame[f] then by_frame[f] = { frame = f, t = frames[f].time, st = 0, kind = kind_of(f) } end
    end
    for _, spot in ipairs(spots or {}) do
      local f = spot.index
      if (spot.type == "peak" or spot.type == "valley") and f and frames[f] and not by_frame[f] and not near_stored(f) then
        by_frame[f] = { frame = f, t = frames[f].time, st = 0, kind = "spot" }
      end
    end
    for _, k in pairs(by_frame) do knots[#knots + 1] = k end
    table.sort(knots, function(a, b) return a.frame < b.frame end)

    -- Offsets: between two neighbouring knots a smoothstep from one value to the other (flat at both, no
    -- overshoot); nil when every knot is at 0
    for _, k in ipairs(knots) do
      if k.st ~= 0 then offsets = {} break end
    end
    if offsets then
      if #knots == 1 then offsets[1] = knots[1].st end
      for j = 1, #knots - 1 do
        local a, b = knots[j], knots[j + 1]
        local span = b.frame - a.frame
        for i = a.frame, b.frame do
          offsets[i] = a.st + (b.st - a.st) * smoothstep((i - a.frame) / span)
        end
      end
    end
  end
  note.points_cache = { rev = rev, frames = frames, spots = spots, list = list, knots = knots, offsets = offsets }
  return knots
end

--- The per-frame offset (semitones) of the note's points, or nil when every point is at 0. Pure, cached.
K.points_offsets = function(note)
  K.points_knots(note)
  return note.points_cache.offsets
end

--- The knot of `note` on frame `frame`, or nil.
K.point_knot_at = function(note, frame)
  for _, k in ipairs(K.points_knots(note)) do
    if k.frame == frame then return k end
  end
  return nil
end

--- Set the offset of `knot` (a knot of `note`, or { frame, t, st = 0 } for a frame that has none) to st semitones:
--- clamped, 0 under K.POINT_EPS; the stored entry is created, updated or removed by the entry rule. No REAPER calls:
--- the caller writes the change (apply_envelope_to_take).
K.point_set = function(note, knot, st)
  local ctrl = note.controls
  if not ctrl or not knot then return end
  st = K.points_clamp(st)
  local list = ctrl.points
  local entry = knot.entry
  if entry and list then
    if st == 0 and not entry.added then
      for i = #list, 1, -1 do
        if list[i] == entry then table.remove(list, i) end
      end
      if #list == 0 then ctrl.points = nil end
    else
      entry.st = st
    end
  elseif st ~= 0 then
    list = list or {}
    local pos = #list + 1
    for i, e in ipairs(list) do
      if e.t > knot.t then pos = i break end
    end
    table.insert(list, pos, { t = knot.t, st = st })
    ctrl.points = list
  end
  note.points_rev = (note.points_rev or 0) + 1
end

--- How many points the note stores (moved or added).
K.points_count = function(note)
  local list = note and note.controls and note.controls.points
  return list and #list or 0
end

--- Clear the note's stored points; returns how many there were.
K.points_reset = function(note)
  local n = K.points_count(note)
  if n > 0 then
    note.controls.points = nil
    note.points_rev = (note.points_rev or 0) + 1
  end
  return n
end

--- Remove the added point `knot` of `note` (a detected, start or end point stays: it has no stored entry to drop,
--- and a moved one is put back with K.point_set). Returns true when something was removed. No REAPER calls.
K.point_remove = function(note, knot)
  local list = note and note.controls and note.controls.points
  if not (list and knot and knot.kind == "added" and knot.entry) then return false end
  for i = #list, 1, -1 do
    if list[i] == knot.entry then table.remove(list, i) end
  end
  if #list == 0 then note.controls.points = nil end
  note.points_rev = (note.points_rev or 0) + 1
  return true
end

--- The offset (semitones) the points curve of whichever of `notes` holds the time t has at its frame nearest to t;
--- 0 outside all of them or where that note's points are all at 0. Pure.
K.points_curve_at = function(notes, t)
  for _, n in ipairs(notes) do
    if n.frames and #n.frames > 0 and t >= n.start_time and t <= n.end_time then
      local offsets = K.points_offsets(n)
      return offsets and (offsets[K.points_frame_at(n.frames, t)] or 0) or 0
    end
  end
  return 0
end

--- Carry the bend of `old_notes` (the notes as they were before a split, merge or trim, unchanged) over to
--- `new_note` (run after extract_note_features(new_note, ...)): (1) every stored entry of old_notes whose time lies
--- inside new_note is copied, on new_note's nearest frame (of two closer than K.POINT_MIN_GAP frames the first in
--- time is kept); (2) every other knot of new_note (its start, end and re-detected dots) takes the old curve's value
--- at its time; (3) at each knot time of old_notes and each of `pin_times` inside new_note where the new curve now
--- differs from the old one by K.POINT_EPS or more, an added entry holds the old curve's value (when no knot is within
--- K.POINT_MIN_GAP frames). Returns how many stored entries lay outside new_note (dropped). No REAPER calls: the
--- caller writes the change.
K.points_transfer = function(new_note, old_notes, pin_times)
  local frames, ctrl = new_note.frames, new_note.controls
  if not (frames and #frames > 0 and ctrl) then return 0 end
  local dropped = 0

  -- 1. Stored entries, each normalised by its place in new_note: on its first or last frame it is that start / end
  -- point (not added, and not stored at 0); an old start or end point that is now inside the note is added (a square)
  local entries = {}
  for _, old in ipairs(old_notes) do
    local of = old.frames
    local o_first = of and #of > 0 and of[1].time
    local o_last = of and #of > 0 and of[#of].time
    for _, e in ipairs((old.controls and old.controls.points) or {}) do
      if e.t >= new_note.start_time and e.t <= new_note.end_time then
        entries[#entries + 1] = { e = e, was_edge = (e.t == o_first or e.t == o_last) }
      else
        dropped = dropped + 1
      end
    end
  end
  table.sort(entries, function(a, b) return a.e.t < b.e.t end)
  local kept, last_f, nf = {}, nil, #frames
  for _, c in ipairs(entries) do
    local f = K.points_frame_at(frames, c.e.t)
    if not last_f or f - last_f >= K.POINT_MIN_GAP then
      local st = K.points_clamp(c.e.st)
      local added = (c.e.added == true) or nil
      if f == 1 or f == nf then
        added = nil
      elseif c.was_edge then
        added = true
      end
      if added or st ~= 0 then kept[#kept + 1] = { t = frames[f].time, st = st, added = added } end
      last_f = f
    end
  end
  ctrl.points = (#kept > 0) and kept or nil
  new_note.points_rev = (new_note.points_rev or 0) + 1

  -- 2. Knots without an entry follow the old curve
  local free = {}
  for _, k in ipairs(K.points_knots(new_note)) do
    if not k.entry then free[#free + 1] = k.frame end
  end
  for _, f in ipairs(free) do
    local k = K.point_knot_at(new_note, f)  -- an entry set just before can have taken a nearby dot
    if k and not k.entry then K.point_set(new_note, k, K.points_curve_at(old_notes, k.t)) end
  end

  -- 3. Squares where the old curve had a knot (or an old edge was) that the new curve no longer follows: each old
  -- knot time and pin time inside the note, in time order, where the new offset differs from the old curve by
  -- K.POINT_EPS or more and no knot is within K.POINT_MIN_GAP frames, gets an added entry holding the old value
  local times = {}
  for _, old in ipairs(old_notes) do
    for _, k in ipairs(K.points_knots(old)) do times[#times + 1] = k.t end
  end
  for _, pt in ipairs(pin_times or {}) do times[#times + 1] = pt end
  table.sort(times)
  for _, t in ipairs(times) do
    if t >= new_note.start_time and t <= new_note.end_time then
      local f = K.points_frame_at(frames, t)
      local want = K.points_curve_at(old_notes, t)
      local offs = K.points_offsets(new_note)
      if math.abs(((offs and offs[f]) or 0) - want) >= K.POINT_EPS then
        local clear = true
        for _, k in ipairs(K.points_knots(new_note)) do
          if math.abs(k.frame - f) < K.POINT_MIN_GAP then clear = false break end
        end
        if clear then
          local list = ctrl.points or {}
          local entry = { t = frames[f].time, st = K.points_clamp(want), added = true }
          local pos = #list + 1
          for n, e in ipairs(list) do
            if e.t > entry.t then pos = n break end
          end
          table.insert(list, pos, entry)
          ctrl.points = list
          new_note.points_rev = new_note.points_rev + 1
        end
      end
    end
  end
  return dropped
end

-------------------------------------------------------------------------------
-- TIGHTEN and TOLERANCE: the two values on the sides of a note.
-- Tighten (controls.tighten, 0..1, nil = 0) removes the note's movement around its centre that is slower than a
-- time window; the window shrinks as the value rises (K.TIGHTEN_WINDOW_S at 0 %, nothing left at 100 % = a flat
-- line), so slow drift goes first, then wobble, then vibrato. Tolerance (cents; the note's own controls.tolerance,
-- else the item's, else the global default) leaves that slow line alone where it is within Tolerance of the
-- centre: only the part beyond it is removed.
-------------------------------------------------------------------------------

K.TIGHTEN_BODY_ST = 0.5     -- the note's body: from its first to its last frame this close to its centre
K.TIGHTEN_WINDOW_S = 0.4    -- the time window at 0 %
K.TIGHTEN_FADE = 0.1        -- the first tenth of the dial fades the correction in

--- The body of `note`: the frame indices `a, b` from its first to its last frame whose smoothed pitch is within
--- K.TIGHTEN_BODY_ST of the note's centre, or nil when the note has fewer than 3 frames, no `smooth` line, or fewer
--- than 3 frames from `a` to `b`. No REAPER calls. Cached on the note, keyed on its frames, smooth line and centre
--- (not on Tighten), so Tighten, joins and Slide In share one body.
K.note_body = function(note)
  local sm, frames, centre = note.smooth, note.frames, note.avg_note
  if not sm or not frames or not centre or #frames < 3 or #sm ~= #frames then return nil end
  local bc = note.body_cache
  if not (bc and bc.frames == frames and bc.smooth == sm and bc.avg == centre) then
    local nf = #frames
    local a, b
    for i = 1, nf do
      if math.abs(sm[i] - centre) <= K.TIGHTEN_BODY_ST then a = i break end
    end
    for i = nf, 1, -1 do
      if math.abs(sm[i] - centre) <= K.TIGHTEN_BODY_ST then b = i break end
    end
    if not (a and b - a >= 2) then a, b = nil, nil end
    bc = { frames = frames, smooth = sm, avg = centre, a = a, b = b }
    note.body_cache = bc
  end
  return bc.a, bc.b
end

--- The per-frame pitch (semitones) Tighten takes away from `note`, or nil when it takes nothing (Tighten at 0, or
--- a note with no body to measure). Its Tighten is the one in force: its own, else the item's (get_effective).
--- No REAPER calls. Only the body of the note is measured, so a slide into or out of the note does not bend the
--- line; the frames before and after the body take the value at the body's edge
--- (the slide keeps its shape and lands on the tightened note). Cached on the note: the filtered line until the
--- note's analysis or its Tighten changes, the result until the Tolerance it uses changes too.
K.tighten_line = function(note)
  local sm, frames = note.smooth, note.frames
  local amount = note.controls and tonumber(get_effective(note, "tighten")) or 0
  if amount <= 0 or not sm or not frames or #frames < 3 or #sm ~= #frames then return nil end
  amount = math.min(1, amount)
  local nf, centre = #frames, note.avg_note

  local tc = note.tighten_cache
  if not (tc and tc.frames == frames and tc.smooth == sm and tc.avg == centre and tc.amount == amount) then
    tc = { frames = frames, smooth = sm, avg = centre, amount = amount, line = false }
    note.tighten_cache = tc
    local a, b = K.note_body(note)
    local hop = (frames[nf].time - frames[1].time) / (nf - 1)
    if a and hop > 0 then
      local dev = {}
      for i = a, b do dev[#dev + 1] = sm[i] - centre end
      local window = K.TIGHTEN_WINDOW_S * (1 - amount) ^ 2
      local line = (window > 0) and gaussian_filter(dev, window / hop) or dev
      local gain = smoothstep(amount / K.TIGHTEN_FADE)
      for k = 1, #line do line[k] = line[k] * gain end
      tc.line, tc.a, tc.b = line, a, b
    end
  end
  local line = tc.line
  if not line then return nil end

  local tol = math.max(0, tonumber(get_effective(note, "tolerance")) or 0) / 100
  if tc.tol ~= tol then
    local a, b = tc.a, tc.b
    local out = {}
    for k = 1, #line do
      local v = line[k]
      if tol > 0 then
        local mag = math.abs(v)
        v = (mag > tol) and v * (1 - tol / mag) or 0
      end
      out[a + k - 1] = v
    end
    for i = 1, a - 1 do out[i] = out[a] end
    for i = b + 1, nf do out[i] = out[b] end
    tc.tol, tc.out = tol, out
  end
  return tc.out
end

local function is_note_modified(note)
  if not note or not note.controls then return false end
  local ctrl = note.controls
  if ctrl.bypassed then return true end
  return math.abs(ctrl.center_pitch - note.avg_note) > 0.001 or K.controls_edited(ctrl)
    or K.points_offsets(note) ~= nil
end

--- True when the correction reaches `note`: it has controls and is not bypassed. Every note the item's values
--- reach, edited or not (is_note_modified stays for display, reset and re-split matching).
K.note_reached = function(note)
  return note ~= nil and note.controls ~= nil and not note.controls.bypassed
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

--- The text save_take_data stores on a take for the model `data`.
K.take_json = function(data)
  local save_data = {
    guid = data.guid,
    name = data.name,
    start_time = data.start_time,
    end_time = data.end_time,
    item_len = data.item_len,
    sample_rate = data.sample_rate,
    results = data.results,
    notes = {},
    -- (every model is seeded first, K.item_seed; the bar's Auto, 0, is never stored)
    key_idx = data.key_idx or (K.key_resolve(state.key_idx, state.scale_idx, data.guid)),
    scale_idx = data.scale_idx or state.scale_idx,
    key_from_track = data.key_from_track or nil,   -- the key was found on the item's track (the Key combo says so)
    separation = data.separation,   -- the Separation the notes were split at (see K.follow_resplit_undo)
    overrides = data.overrides or nil,
    analysis = data.analysis,   -- the values the analysis ran with (K.analysis_values)
  }
  if data.notes then
    for _, note in ipairs(data.notes) do
      table.insert(save_data.notes, {
        start_time = note.start_time,
        end_time = note.end_time,
        avg_note = note.avg_note,
        display_note = note.display_note,
        controls = note.controls,
        frames = note.frames
      })
    end
  end
  return JSON.encode(save_data)
end

--- Store the model `data` on `take`. json: its text when the caller prepared it already (K.take_json), so a write
--- of many items does not encode them all in one frame.
local function save_take_data(take, data, json)
  if not take or not data then return end
  reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, json or K.take_json(data), true)

  -- Remember what is now stored (read back) so the resync never treats our own write as external; what was stored
  -- before (readable or not) is replaced
  local guid = get_take_guid(take)
  if guid then
    state.raw_cache[guid] = read_take_raw(take)
    state.unreadable_takes[guid] = nil
  end
end

--- Save the active Key/Scale as the open item's own (one named undo point, so Cmd+Z reverts it together with the
--- Key/Scale selection). An item not analysed yet keeps it in state.key_idx / state.scale_idx, and its first
--- analysis stores it. `undo_label`: "Set Key", "Set Scale" or "Find Key: <item>" (K.scale_changed, K.find_key_finish).
--- flush (optional): the pending track record that goes into the same block (K.records_flush). Returns true when it
--- wrote (one undo point).
local function save_current_scale_settings(undo_label, flush)
  if state.target_take_guid and state.session_takes[state.target_take_guid] then
    local data = state.session_takes[state.target_take_guid]
    data.key_idx = state.key_idx
    data.scale_idx = state.scale_idx
    local take = resolve_take_by_guid(state.target_take_guid)
    if take then
      reaper.Undo_BeginBlock()
      state.undo_open = true
      save_take_data(take, data)
      K.records_flush(flush)
      reaper.Undo_EndBlock(undo_label or "Set Key", -1)
      state.undo_open = false
      note_own_write()
      return true
    end
  end
  return false
end

--- Parse the pitch model stored on a take. raw is the P_EXT string when the caller already read it.
--- Records the raw string in state.raw_cache so the resync can tell own loads from external changes.
--- Stored data that cannot be used (it does not decode, or holds no analysis) is not dropped silently: the take is
--- recorded in state.unreadable_takes (the Pitched Items banner reports it); nothing stored, or data that loads,
--- clears the record. Returns the model, or nil.
--- The take's name as REAPER has it now (the arrange window's item label). The name saved with an analysis is only
--- the fallback, for a take REAPER gives no name.
K.live_take_name = function(take, fallback)
  local name = take and reaper.GetTakeName(take) or nil
  if name and name ~= "" then return name end
  return fallback or "Item"
end

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
        -- The saved controls (including the per-note overrides) are kept across the re-extraction
        local saved_controls = note.controls
        extract_note_features(note)
        K.controls_load(note.controls, saved_controls)
        K.points_sanitize(note)
      end
    end)
  end
  if guid then state.unreadable_takes[guid] = (not readable) or nil end
  if readable then
    data.key_from_track = (data.key_from_track == true) or nil
    K.item_seed(data)
    data.analysis = K.analysis_values(data.analysis)   -- a malformed record counts as not recorded
    data.name = K.live_take_name(take, data.name)   -- the name is REAPER's, not the one saved with the analysis
    return data
  end
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

local function toggle_take_pitch_bypass(take)
  if not take then return end
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  local item = reaper.GetMediaItemTake_Item(take)
  if not env and item then
    env = ensure_take_pitch_envelope(take, item, true)
  end
  if env then
    reaper.Undo_BeginBlock()
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
    reaper.Undo_EndBlock("Toggle Pitch Envelope Bypass", -1)
  end
  note_own_write()
end

--- Drop every in-flight gesture and selection, and show the whole item again (used when the model under
--- them is replaced). keep_view: the canvas stays where it is (a re-split of the same item).
local function clear_interaction_state(keep_view)
  if not keep_view then K.reset_view() end
  state.selected_note = nil
  state.selected_notes = {}
  state.hovered_note = nil
  state.hovered_zone = nil
  state.hovered_edge = nil
  state.context_menu_note = nil
  state.context_edit = nil
  state.bar_edit = nil
  state.drag = nil
  state.edge_drag = nil
  state.marquee = nil
  state.point_drag = nil
  state.context_point = nil
  state.hovered_point = nil
  state.point_ghost = nil
  state.points_hover_note = nil
  state.points_zoom_hint = false
  state.shift_mode = false
  state.nudge_burst = nil
  K.tone_kill()   -- the drag that was sounding is gone
end

--- Make a session take's data the editing model (canvas, notes, key/scale). Does not touch
--- REAPER's item selection.
local function adopt_take_data(guid, data)
  local same_target = (state.target_take_guid == guid)
  local view_t0, view_t1, view_p0, view_p1 = state.view_t0, state.view_t1, state.view_p0, state.view_p1
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
  clear_interaction_state()   -- also shows the whole item and the fitted pitch range again (K.reset_view) ...
  if same_target then   -- ... unless the same take was reloaded (undo / redo): the zoom stays
    state.view_t0, state.view_t1, state.view_p0, state.view_p1 = view_t0, view_t1, view_p0, view_p1
  end

  if data.separation then state.separation = data.separation end
  if data.key_idx then state.key_idx = data.key_idx end
  if data.scale_idx then state.scale_idx = data.scale_idx end
  update_scale_pitch_classes()
end

--- Cancel the running analysis (header Cancel, closing the window, an error): stop reading audio, put the
--- previous model back and say so in the status line. Nothing was written for the new analysis (the model is saved
--- when it completes) and no undo block is open between frames, so there is nothing to close or undo.
--- Returns true when an analysis was running.
K.cancel_analysis = function()
  if K.batch then   -- a batch: the finished items are kept, written as its one undo step (K.batch_finish)
    K.batch_finish(true)
    return true
  end
  if state.pre then   -- the pre-analysis: nothing of the open item's model was touched yet
    K.release_analysis()
    state.progress = 0
    set_status(K.CANCELLED_TEXT)
    return true
  end
  if not state.is_analyzing and not state.accessor then
    -- Nothing runs, but an analysis that failed after it stopped reading may have left its records: never kept
    K.auto_drop()
    return false
  end
  K.release_analysis()
  K.reanalyze_status_guid = nil
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

-------------------------------------------------------------------------------
-- 3b. BATCH ANALYSIS (Analyze All Selected Items)
-------------------------------------------------------------------------------
-- Design: docs/design/pitch-correct-analyze-selected.md. A batch analyses the audio items selected in REAPER's
-- arrange view one after another. The models of finished items are held in memory and written together, in one
-- undo block, when the batch ends (an undo block cannot stay open between frames).

--- The items a batch would analyse now: every selected item whose active take is audio, in REAPER's order of the
--- selection. Returns { takes = { entry ... }, skipped = how many other selected items there are }, with
--- entry = { guid, take, item, name, len (seconds), pos (project seconds), track (its name), sample_rate,
--- has_notes (it holds notes that a new analysis would replace) }. REAPER's selection is only read.
--- sample_rate is asked here, when the user has just clicked in the window: REAPER can report 0 for every source
--- while it is in the background ("Set media items offline when application is not active"), and a batch runs on
--- while the user works elsewhere.
K.batch_selection = function()
  local out = { takes = {}, skipped = 0 }
  local count = reaper.CountSelectedMediaItems(0) or 0
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item) or nil
    local guid = nil
    if take and not reaper.TakeIsMIDI(take) then guid = get_take_guid(take) end
    if guid then
      local source = reaper.GetMediaItemTake_Source(take)
      local track = reaper.GetMediaItemTrack(item)
      local track_name = ""
      if track then
        local ok, name = reaper.GetTrackName(track)
        if ok and name then track_name = name end
      end
      local data = state.session_takes[guid]
      out.takes[#out.takes + 1] = {
        guid = guid, take = take, item = item,
        name = reaper.GetTakeName(take) or "Item",
        len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0,
        pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0,
        track = track_name,
        sample_rate = source and reaper.GetMediaSourceSampleRate(source) or 0,
        has_notes = (data ~= nil and data.notes ~= nil and #data.notes > 0),
      }
    elseif item then
      out.skipped = out.skipped + 1
    end
  end
  return out
end

-- How long K.batch_peek's answer is kept while the selection and the project state stay the same (seconds)
K.BATCH_PEEK_S = 0.25

--- What the window says about a possible batch: { n = audio items selected, skipped = other selected items,
--- with_notes = how many of the n hold notes, target_in = the open item is one of them, names = their take names }. The selection is not
--- walked every frame: the answer is kept until the number of selected items, the project state or the open item
--- changes, and for K.BATCH_PEEK_S at most (a selection change need not move the project's change count).
--- A batch never uses this: it reads the selection afresh when it starts (K.batch_request).
K.batch_peek = function(now)
  local sel_n = reaper.CountSelectedMediaItems(0) or 0
  local count = reaper.GetProjectStateChangeCount(0)
  local cache = K.batch_peek_cache
  if cache and cache.sel_n == sel_n and cache.count == count and cache.target == state.target_take_guid
     and now - cache.at < K.BATCH_PEEK_S then
    return cache.peek
  end
  local sel = K.batch_selection()
  local peek = { n = #sel.takes, skipped = sel.skipped, with_notes = 0, target_in = false, names = {} }
  for _, entry in ipairs(sel.takes) do
    peek.names[#peek.names + 1] = entry.name
    if entry.has_notes then peek.with_notes = peek.with_notes + 1 end
    if entry.guid == state.target_take_guid then peek.target_in = true end
  end
  K.batch_peek_cache = { sel_n = sel_n, count = count, target = state.target_take_guid, at = now, peek = peek }
  return peek
end

--- The canvas button's label for n selected audio items. narrow: the canvas has no room for the full batch label.
K.batch_label = function(n, narrow)
  if n < 2 then return "Analyze Item" end
  return narrow and "Analyze All" or "Analyze All Selected Items"
end

--- The canvas button's tooltip for a batch of n items.
K.batch_tip = function(n)
  return string.format("Detect the pitch of the %d selected audio items, one after another.\n\nOne undo step for all of them.", n)
end

--- The lines above the canvas form for what K.batch_peek returned: the first, and the second or nil. The first
--- names what Analyze will analyse: the open item (target_name, nil when there is none) unless two or more audio
--- items are selected, then "N items selected: a, b, …" (the full list here; the canvas fits it to its width, K.batch_names_fit). With nothing to
--- analyse it is the instruction. Both read "N item(s) selected: …".
K.batch_lines = function(peek, target_name)
  if peek.n < 2 then
    if target_name and target_name ~= "" then return "1 item selected: " .. target_name, nil end
    return "Select one or more items and click Analyze.", nil
  end
  local first = string.format("%d items selected: %s", peek.n, table.concat(peek.names or {}, ", "))
  local parts = {}
  if peek.skipped == 1 then
    parts[#parts + 1] = "1 other selected item is skipped."
  elseif peek.skipped > 1 then
    parts[#parts + 1] = string.format("%d other selected items are skipped.", peek.skipped)
  end
  if not peek.target_in then parts[#parts + 1] = "This item is not one of them." end
  if peek.with_notes == 1 then
    parts[#parts + 1] = "1 already has notes. You will be asked before it is replaced."
  elseif peek.with_notes > 1 then
    parts[#parts + 1] = string.format("%d already have notes. You will be asked before they are replaced.", peek.with_notes)
  end
  return first, (#parts > 0 and table.concat(parts, " ") or nil)
end

-- At most this many names are listed in the batch line's tooltip
K.BATCH_NAMES_MAX = 20
-- The batch line names this many items at most: with more selected it ends in "…" (the count leads the line)
K.BATCH_NAMES_SHOWN = 2

--- "N items selected: a, b, …": the first K.BATCH_NAMES_SHOWN of `names` (fewer when they do not fit max_w by
--- measure(text) -> width), "…" when some are left out. When not even the first name fits: "N items selected".
K.batch_names_fit = function(names, max_w, measure)
  local n = #names
  for k = math.min(n, K.BATCH_NAMES_SHOWN), 1, -1 do
    local text = string.format("%d items selected: %s", n, table.concat(names, ", ", 1, k))
    if k < n then text = text .. ", …" end
    if measure(text) <= max_w then return text end
  end
  return string.format("%d items selected", n)
end

--- The batch line's tooltip: every name, one per line (K.BATCH_NAMES_MAX at most, the rest counted).
K.batch_names_tip = function(names)
  local n = #names
  local lines = { string.format("%d selected items", n), "" }
  for i = 1, math.min(n, K.BATCH_NAMES_MAX) do lines[#lines + 1] = names[i] end
  if n > K.BATCH_NAMES_MAX then lines[#lines + 1] = string.format("+%d more", n - K.BATCH_NAMES_MAX) end
  return table.concat(lines, "\n")
end

--- What to ask before a batch over `entries` (K.batch_selection's takes) replaces existing notes: the fields of a
--- request_confirm request ({ title, body_lines, list, after_lines, confirm_label }; list = the items that hold
--- notes, in order, as { name, track, pos }), or nil when no item holds notes: then nothing is asked.
K.batch_confirm = function(entries)
  local total, list = #entries, {}
  for _, entry in ipairs(entries) do
    if entry.has_notes then list[#list + 1] = { name = entry.name, track = entry.track, pos = entry.pos } end
  end
  if #list == 0 then return nil end
  local body
  if total == 1 then
    body = "This item already has notes. Analyzing replaces its notes and any edits:"
  elseif #list == total then
    body = string.format("All %d already have notes. Analyzing replaces their notes and any edits:", total)
  elseif #list == 1 then
    body = "1 of them already has notes. Analyzing replaces its notes and any edits:"
  else
    body = string.format("%d of them already have notes. Analyzing replaces their notes and any edits:", #list)
  end
  local after = total == 1 and string.format("%s+Z restores it once the batch has finished.", K.MOD_LABEL)
    or string.format("%s+Z restores all %d items in one step once the batch has finished.", K.MOD_LABEL, total)
  return {
    title = total == 1 and "Analyze 1 item?" or string.format("Analyze %d items?", total),
    body_lines = { body }, list = list,
    after_lines = { #list == 1 and K.REANALYZE_VALUES_LINE or K.REANALYZE_VALUES_LINE_N, after },
    confirm_label = total == 1 and "Analyze 1 Item" or string.format("Analyze %d Items", total),
  }
end

--- A batch over `entries`, not started yet. queue = the entries, frozen (a later selection change does not reach
--- it); index = the entry being analysed (0 = none yet); done = { { guid, data, json, empty } ... } of the finished
--- ones; failed = entries that could not be analysed; total_len / done_len = seconds of audio in the queue / in the
--- entries that are behind; prev_guid = the item that was open when it started.
K.batch_new = function(entries, prev_guid)
  local total_len = 0
  for _, entry in ipairs(entries) do total_len = total_len + (entry.len or 0) end
  return { queue = entries, index = 0, done = {}, failed = 0, total_len = total_len, done_len = 0,
    prev_guid = prev_guid }
end

--- How far a batch is, 0 .. 1: the share of its audio that has been analysed. item_progress = how far the entry in
--- progress is (0 .. 1). The one number the "…" button and the status line both show.
K.batch_progress = function(batch, item_progress)
  if batch.total_len <= 0 then return 0 end
  local entry = batch.queue[batch.index]
  local part = entry and (entry.len or 0) * (item_progress or 0) or 0
  return math.max(0, math.min(1, (batch.done_len + part) / batch.total_len))
end

--- The undo label of a batch that wrote n items.
K.batch_undo_label = function(n)
  return string.format("Analyze Pitch (%d %s)", n, n == 1 and "item" or "items")
end

--- The closing message of a batch. r = { total = items in the batch, written = items analysed and stored,
--- empty = how many of the written hold no pitched notes, failed = items that could not be analysed,
--- cancelled = it was stopped before its end }.
K.batch_summary = function(r)
  local function items(n) return n == 1 and "1 item" or string.format("%d items", n) end
  local undo = string.format(" %s+Z to undo.", K.MOD_LABEL)
  if r.cancelled then
    if r.written == 0 then return "Batch cancelled. Nothing was changed." end
    return string.format("Batch cancelled. %d of %s %s analyzed and kept.", r.written, items(r.total),
      r.written == 1 and "was" or "were") .. undo
  end
  if r.written == 0 then
    if r.total == 1 then return "The item could not be analyzed. Nothing was changed." end
    return string.format("None of the %s could be analyzed. Nothing was changed.", items(r.total))
  end
  local text = r.written == r.total and ("Analyzed " .. items(r.total))
    or string.format("Analyzed %d of %s", r.written, items(r.total))
  if r.empty > 0 then
    text = text .. string.format(" (%d %s no pitched notes)", r.empty, r.empty == 1 and "has" or "have")
  end
  text = text .. "."
  if r.failed > 0 then text = text .. string.format(" %d could not be analyzed.", r.failed) end
  return text .. undo
end

--- Write the finished items of a batch: `done` = { { guid, data, json | nil, empty } ... }. Everything goes into
--- ONE undo block: per item, its Pitch envelope is created and shown where it was missing and written from its model
--- and its own values (K.write_take_envelope: item values reach every note; at the defaults nothing is corrected,
--- and the envelope is left with no points), and its model is
--- stored on the take; the take's pitch mode is left alone, as for a single analysis. An item that is no longer in
--- the project, whose Pitch envelope cannot be made or whose correction cannot be built, is left out and stays as
--- it was.
--- With no item left in the project no undo block is opened. Returns the entries of `done` that were written.
K.batch_write = function(done)
  local ready = {}
  for _, entry in ipairs(done) do
    local take = resolve_take_by_guid(entry.guid, true)
    local item = take and K.take_item(take) or nil
    if take and item then ready[#ready + 1] = { entry = entry, take = take, item = item } end
  end
  -- Each item's correction is built first, before anything is changed: an item whose correction cannot be built
  -- is left out untouched (its envelope is not created, shown or switched on). The build reads the item's values
  -- from its session model, so the new model stands in for its length
  local buildable = {}
  for _, r in ipairs(ready) do
    local guid = r.entry.guid
    local old = state.session_takes[guid]
    state.session_takes[guid] = r.entry.data
    local ok, build = pcall(K.take_correction, guid, r.entry.data, K.take_len(r.item))
    state.session_takes[guid] = old
    if ok then
      r.build = build
      buildable[#buildable + 1] = r
    else
      reaper.ShowConsoleMsg("Fancy Pitch Correct: an item could not be written: " .. tostring(build) .. "\n")
    end
  end
  if #buildable == 0 then return {} end

  local written = {}
  reaper.Undo_BeginBlock()
  state.undo_open = true
  for _, r in ipairs(buildable) do
    local guid, data = r.entry.guid, r.entry.data
    -- Without its Pitch envelope the item cannot be corrected: it is left out (not written). A write that raises
    -- leaves that item out too; the batch carries on and its block still closes once
    local old = state.session_takes[guid]
    local ok, wrote = pcall(function()
      if not ensure_take_pitch_envelope(r.take, r.item, true) then return false end
      -- The pitch mode is kept, as for a single analysis (process_analysis_step)
      state.session_takes[guid] = data
      return K.write_take_envelope(guid, data, true, r.take, r.item,
        { json = r.entry.json, built = true, build = r.build })
    end)
    if not ok then
      reaper.ShowConsoleMsg("Fancy Pitch Correct: an item could not be written: " .. tostring(wrote) .. "\n")
    end
    if not (ok and wrote) then state.session_takes[guid] = old end
    if ok and wrote then
      local listed = false
      for _, g in ipairs(state.session_order) do
        if g == guid then listed = true; break end
      end
      if not listed then table.insert(state.session_order, guid) end
      state.stale_takes[guid], state.stale_env[guid], state.missing_takes[guid] = nil, nil, nil
      state.undone_takes[guid] = nil
      written[#written + 1] = r.entry
    end
  end
  reaper.UpdateArrange()
  -- The track records an Auto batch found ride in the same step, each only with an item of its track that was
  -- written (K.batch_finish drops the others)
  if #written > 0 then
    local keep = {}
    for _, r in ipairs(buildable) do
      for _, e in ipairs(written) do
        if e == r.entry then
          local track = reaper.GetMediaItemTake_Track(r.take)
          if track then keep[track] = true end
        end
      end
    end
    K.track_records_flush(keep)
  end
  -- No item could get its envelope: no "Analyze Pitch (0 items)" step is named for it
  reaper.Undo_EndBlock(#written > 0 and K.batch_undo_label(#written) or "Analyze Pitch", -1)
  state.undo_open = false
  K.frame_view_memo.frame = nil   -- the canvas fetches the correction again
  note_own_write()
  return written
end

--- End the running batch, however it ends (its queue is done, Cancel, the window closes, a frame failed): the
--- finished items are written as one undo step, the item in progress and the items not started are left as they
--- were, the first written item is opened (or the item that was open before comes back) and one closing message
--- says what happened. cancelled: it was stopped before its end.
K.batch_finish = function(cancelled)
  local batch = K.batch
  if not batch then return end
  if batch.kind == "apply" then   -- an Apply to other items (K.apply_run) ends its own way
    K.apply_finish(cancelled)
    return
  end
  K.release_analysis()   -- while K.batch is still set: the records found for the batch stay for its write
  K.batch = nil
  state.progress = 0

  local written = K.batch_write(batch.done)
  K.auto_drop()   -- written inside the batch's block, or nothing was written: they never wait for another block
  local empty = 0
  for _, entry in ipairs(written) do
    if entry.empty then empty = empty + 1 end
  end

  local first = written[1]
  local open_guid = first and state.session_takes[first.guid] and first.guid or nil
  if not open_guid and batch.prev_guid and state.session_takes[batch.prev_guid] then open_guid = batch.prev_guid end
  if open_guid then
    adopt_take_data(open_guid, state.session_takes[open_guid])
  else
    -- Nothing written and the item that was open has no analysis: back to it, not analysed (a new item's values)
    reset_analysis_model()
    K.adopt_new_item_values()
    state.target_take_guid, state.target_take_name = batch.prev_guid, batch.prev_name
    local take = batch.prev_guid and resolve_take_by_guid(batch.prev_guid, true) or nil
    local item = take and K.take_item(take) or nil
    state.start_time = 0
    state.item_len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
    state.end_time = state.item_len
  end

  -- REAPER's selection was not followed while the batch ran: what is selected now is not a change to react to
  local sel_item = reaper.GetSelectedMediaItem(0, 0)
  local sel_take = sel_item and reaper.GetActiveTake(sel_item) or nil
  state.last_seen_sel_guid = (sel_take and not reaper.TakeIsMIDI(sel_take)) and get_take_guid(sel_take) or nil
  -- Nor was the project (undo, redo, deleted items): the next frame reads it again
  state.last_change_count = nil

  K.status_hold(K.batch_summary({
    total = #batch.queue, written = #written, empty = empty, failed = #batch.queue - #written,
    cancelled = cancelled and true or false,
  }))
end

--- Start the next entry of the running batch that can be analysed; entries that cannot (the item left the project,
--- its media has no sample rate, REAPER gave no accessor) are counted as failed. With no entry left the batch ends.
K.batch_next = function()
  local batch = K.batch
  if not batch then return end
  while true do
    batch.index = batch.index + 1
    local entry = batch.queue[batch.index]
    if not entry then
      K.batch_finish(false)
      return
    end
    local take = resolve_take_by_guid(entry.guid, true)
    local item = take and K.take_item(take) or nil
    if take and item and (entry.sample_rate or 0) > 0 then
      -- The canvas follows the item in progress: it becomes the open item, with nothing analysed yet
      reset_analysis_model()
      state.target_take_guid, state.target_take_name = entry.guid, entry.name
      -- It is split at the default Separation and keeps its own Key and Scale (an item analysed for the first time:
      -- the ones last chosen), never those of the item that was open. An analysis stored on the item that the window
      -- has not loaded (pasted later) counts too: it is read here and kept on the entry for K.batch_item_done
      local before, start = state.session_takes[entry.guid], K.new_item_values(entry.guid)
      if not before then before = load_take_data(take) end
      entry.before = before
      state.separation = start.separation
      state.key_idx = before and before.key_idx or start.key_idx
      state.scale_idx = before and before.scale_idx or start.scale_idx
      update_scale_pitch_classes()
      -- Vocal Range Auto: the range found on the item's own track (K.auto_values; a fixed range as it is)
      local track = reaper.GetMediaItemTake_Track(take)
      local values = K.auto_values(batch.values, track and K.track_record(track) or nil)
      if K.analysis_begin(take, item, { sample_rate = entry.sample_rate, defer_envelope = true,
          values = values }) then return end
    end
    batch.failed = batch.failed + 1
    batch.done_len = batch.done_len + (entry.len or 0)
  end
end

--- The entry in progress finished: its model (what process_analysis_step built) is held until the batch is written.
--- Its text is made now, one item at a time, so the write at the end does not encode every item in one frame.
K.batch_item_done = function(take_data)
  local batch = K.batch
  if not batch then return end
  local entry = batch.queue[batch.index]
  -- The model must be the entry's own. When the item in progress leaves the project, the window's target falls
  -- back to whatever is selected (get_target_take): frames read from one item must never be stored on another.
  if not entry or take_data.guid ~= entry.guid then
    K.batch_item_failed(nil)
    return
  end
  -- An item analysed before keeps its Key and Scale (K.batch_next set them before it was read); its values are the
  -- defaults, as for an item analysed for the first time
  K.item_carry_key(take_data, state.session_takes[entry.guid] or entry.before)
  batch.done[#batch.done + 1] = {
    guid = take_data.guid, data = take_data, json = K.take_json(take_data),
    empty = (take_data.notes == nil or #take_data.notes == 0),
  }
  batch.done_len = batch.done_len + (entry.len or 0)
  K.batch_next()
end

--- The entry in progress could not be analysed (err: what was raised, for the console): it is left as it was and
--- the batch carries on with the next one.
K.batch_item_failed = function(err)
  local batch = K.batch
  if not batch then return end
  K.release_analysis()
  if err then
    reaper.ShowConsoleMsg("Fancy Pitch Correct: an item could not be analyzed: " .. tostring(err) .. "\n")
  end
  local entry = batch.queue[batch.index]
  batch.failed = batch.failed + 1
  batch.done_len = batch.done_len + (entry and entry.len or 0)
  K.batch_next()
end

--- Start a batch over `entries` (K.batch_selection's takes, read when the user asked for it), every item analysed
--- with `values` (K.analysis_defaults() shape; omitted: the Settings' values now, kept for the whole batch).
K.batch_start = function(entries, values)
  if K.batch or state.is_analyzing or state.pre or #entries == 0 then return end
  if state.nudge_burst then flush_nudge_burst() end   -- a pending arrow-key nudge belongs to the item being left
  K.auto_drop()   -- only the records this batch finds are written with it
  K.batch = K.batch_new(entries, state.target_take_guid)
  -- A copy: the form the values came from may change (or be reseeded) while the batch runs. In values given by the
  -- caller a missing Auto flag is a fixed range (as for a single analysis), never the default's Auto
  local copy = K.analysis_defaults()
  for _, key in ipairs(K.ANALYSIS_KEYS) do
    if values and values[key] ~= nil then copy[key] = values[key] end
  end
  if values then copy.auto_range = values.auto_range == true end
  K.batch.values = copy
  K.batch.prev_name = state.target_take_name
  -- Auto: the distinct tracks of the items that need their range or key are heard first, in one stage 1
  local batch = K.batch
  local tracks = K.batch_auto_tracks(entries, copy)
  if #tracks == 0 then
    K.batch_next()
    return
  end
  batch.pre_ran = K.pre_begin(tracks, { on_done = function()
    if K.batch == batch then K.batch_next() end
  end })
end

--- The distinct tracks of `entries` (a batch's) whose items need the range or key found first: every item's when
--- Vocal Range is Auto in `values`, else an item not analysed yet while the Key for new items is Auto.
K.batch_auto_tracks = function(entries, values)
  local seen, out = {}, {}
  for _, entry in ipairs(entries) do
    local need = values.auto_range == true
      or (K.new_key.key_idx == 0 and not state.session_takes[entry.guid] and not entry.has_notes)
    if need and entry.take and reaper.ValidatePtr2(0, entry.take, "MediaItem_Take*") then
      local track = reaper.GetMediaItemTake_Track(entry.take)
      if track and not seen[track] then
        seen[track] = true
        out[#out + 1] = track
      end
    end
  end
  return out
end

--- How far the running analysis is, 0 .. 1: the whole batch when one runs, else the item.
K.analysis_progress = function()
  -- Stage 1 of an Auto analysis is the first K.PRE.SHARE of the whole; the analysis after it the rest
  -- (a pre-analysis on its own, Find Key / Find Range and Key Again, is the whole)
  if state.pre then return (state.pre.alone and 1 or K.PRE.SHARE) * K.pre_progress() end
  local p, pre_ran
  if K.batch then
    p, pre_ran = K.batch_progress(K.batch, state.progress), K.batch.pre_ran
  else
    p, pre_ran = state.progress or 0, K.auto_run and K.auto_run.pre_ran
  end
  if pre_ran then return K.PRE.SHARE + (1 - K.PRE.SHARE) * p end
  return p
end

--- The open item has no stored data: Separation is its default (K.item_default), Key and Scale the ones last chosen.
K.adopt_new_item_values = function()
  local start = K.new_item_values(state.target_take_guid)
  state.separation, state.key_idx, state.scale_idx = start.separation, start.key_idx, start.scale_idx
  update_scale_pitch_classes()
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
      state.stale_queue[#state.stale_queue + 1] = guid   -- a take that just joined the session: compare its envelope
    end
  end

  if data then
    adopt_take_data(guid, data)
    K.form_sync(guid, data)
    return true
  end
  K.adopt_new_item_values()   -- not analysed yet: it shows, and its first analysis uses, a new item's values
  K.form_sync(guid, nil)
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
  if state.is_analyzing or K.batch then return end
  local count = reaper.GetProjectStateChangeCount(0)
  if state.last_change_count == count then return end
  state.last_change_count = count
  K.queue_stale_checks()   -- an undo, a redo or an edit in REAPER may have changed an envelope

  -- Whether an item's stored analysis is not what this window last saw (undo, redo): a held closing message
  -- ("Analyzed 3 items") then no longer describes the items and goes. Any other change in REAPER leaves it.
  local analyses_changed = false
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
      -- A rename in REAPER (or its undo) shows in the list without a re-analysis
      local listed = state.session_takes[guid]
      if listed then listed.name = K.live_take_name(take, listed.name) end
      if guid == state.target_take_guid then state.target_take_name = K.live_take_name(take, state.target_take_name) end
      local raw = read_take_raw(take)
      if raw == (state.raw_cache[guid] or "") then
        i = i + 1
      else
        analyses_changed = true
        local data = load_take_data(take, raw)
        local is_active = (guid == state.target_take_guid)
        if data then
          state.session_takes[guid] = data
          if is_active then
            adopt_take_data(guid, data)
            K.follow_resplit_undo(data)
          end
          i = i + 1
        elseif raw == "" then
          -- The analysis was undone away: the take has no pitch data any more. It is remembered, so a redo
          -- brings it back into the list (below)
          state.session_takes[guid] = nil
          state.stale_takes[guid] = nil
          table.remove(state.session_order, i)
          K.undone_seq = (K.undone_seq or 0) + 1
          state.undone_takes[guid] = K.undone_seq   -- in the order of the list, so a redo lists them as before
          if is_active then
            clear_interaction_state()
            state.results = {}
            state.notes = nil
            state.split_points = nil
            state.progress = 0
            state.analysis_empty = false
            K.adopt_new_item_values()   -- not analysed any more: its next analysis is a first one
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
          analyses_changed = true
          state.session_takes[guid] = data
          table.insert(state.session_order, guid)
          if guid == state.target_take_guid then adopt_take_data(guid, data) end
        end
      end
    end
  end

  -- Items whose analysis an undo took away: a redo may have put it back. One undo can take away many (a batch), and
  -- only one of them is the open item, so each is looked at again whenever the project changes.
  local undone = {}
  for guid in pairs(state.undone_takes) do undone[#undone + 1] = guid end
  table.sort(undone, function(a, b) return state.undone_takes[a] < state.undone_takes[b] end)
  for _, guid in ipairs(undone) do
    if state.session_takes[guid] then
      state.undone_takes[guid] = nil   -- analysed again since
    else
      local take = resolve_take_by_guid(guid, true)
      local raw = take and read_take_raw(take) or ""
      if raw ~= "" then
        local data = load_take_data(take, raw)
        if data then
          analyses_changed = true
          state.undone_takes[guid] = nil
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
          analyses_changed = true
          state.session_takes[target_guid] = data
          table.insert(state.session_order, target_guid)
          adopt_take_data(target_guid, data)
        end
      end
    end
  end
  if analyses_changed then K.status_release() end
  if state.target_take_guid then K.form_sync(state.target_take_guid, state.session_takes[state.target_take_guid]) end
end

--- Persist the target's note model to its take (P_EXT) so it lands inside the caller's open undo block.
local function persist_take_model(take)
  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if not data or not take then return end
  if state.notes then data.notes = state.notes end
  save_take_data(take, data)
end

--- Close the undo block opened by apply_envelope_to_take: model (P_EXT) first, so Cmd+Z reverts
--- the envelope points and the note model together; then record the change count. flush_records: an Auto
--- analysis's track records go into the same block (K.records_flush: true = all, a track = its own).
local function end_apply(take, undo_desc, flush_records)
  persist_take_model(take)
  K.records_flush(flush_records)
  reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)
  state.undo_open = false
  note_own_write()
end

-- Joins and fades between notes (seconds). Two neighbours closer than 2 * FADE_S are joined: the blend runs from
-- the first note's body end to the second note's body start, at least MIN_S, at most MAX_S and MAX_PART of either
-- note. Every other edge of an edited note fades over FADE_S, or a quarter of the note when that is shorter.
K.JOIN = { FADE_S = 0.030, MIN_S = 0.010, MAX_S = 0.120, MAX_PART = 0.4 }

--- The pitch correction of `notes` as a trajectory: what the take pitch envelope holds and what the canvas
--- draws, from one calculation. Pure (no REAPER calls); it sets note.frame_shifts on every note.
--- Returns { points, spans, ranges }:
---   points  { time, val } in semitones, in generation order (the envelope writer simplifies and sorts them)
---   spans   { kind, t0, t1, a, b }: "onset" / "release" (the fade before / after note a), "glide" (the join of
---           notes a and b, across the slide between their bodies), "scoop" (the slide of note a that Slide In
---           flattens). a and b are note indices.
---   ranges  { t0, t1 }, sorted and merged: the time ranges an edited, non-bypassed note corrects (with its
---           fades and joins)
--- No timing setting: joins and fades follow K.JOIN.
--- This is the Natural build, called by K.correction_build (4b. MODES).
K.natural_build = function(notes, item_len)
  local all_points, spans, ranges = {}, {}, {}
  local num_notes = #notes

  -- 1. Precalculate continuous frame shifts for every note
  for idx = 1, num_notes do
    local n = notes[idx]
    n.frame_shifts = {}
    -- Per-note bypass: zero out all shifts
    if n.controls and n.controls.bypassed then
      if n.frames then
        for i = 1, #n.frames do
          n.frame_shifts[i] = 0.0
        end
      end
    else
      local is_mod = K.note_reached(n)
      local retune = get_effective(n, "retune_speed")
      -- Strength scales the note's pitch move; a note nobody moved (is_note_modified false) has none to scale
      local coarse = (is_mod and is_note_modified(n)) and (n.controls.center_pitch - n.avg_note) * retune or 0.0
      -- Tighten takes the note's slower movement away: literal, like a pitch point (Strength does not scale it)
      local tight = is_mod and K.tighten_line(n) or nil
      if n.frames then
        for i = 1, #n.frames do
          n.frame_shifts[i] = tight and (coarse - (tight[i] or 0)) or coarse
        end

        -- Slide In: flatten the slide into the note. The slide is the frames before the note's body (K.note_body).
        -- Each is pulled toward the pitch the corrected note has at its body start: fully at 100 %, not at all at
        -- 0 % (the slide as sung). No taper, so the slide meets the body without a step. The pull of one frame is
        -- limited to K.SCOOP_MAX_ST, so a mis-detected frame (an octave error) cannot write a jump of that size
        -- into the envelope. A note that starts on pitch has no slide.
        local slide_in = is_mod and tonumber(get_effective(n, "slide_in")) or 0
        if slide_in > 0 then
          local a = K.note_body(n)
          local settle = a and a > 1 and n.frames[a] and n.frames[a].note
          if settle then
            local settle_pitch = settle + n.frame_shifts[a]
            for i = 1, a - 1 do
              local sung = n.frames[i].note
              if sung then
                local natural = n.frame_shifts[i]
                local pull = (settle_pitch - sung) - natural   -- what would put this frame on the settled pitch
                pull = math.max(-K.SCOOP_MAX_ST, math.min(K.SCOOP_MAX_ST, pull))
                n.frame_shifts[i] = natural + pull * slide_in
              end
            end
            spans[#spans + 1] = { kind = "scoop", t0 = n.frames[1].time, t1 = n.frames[a - 1].time, a = idx }
          end
        end

        -- Pitch points: the note's own offset curve, last and literal (Strength does not scale it)
        local offsets = K.points_offsets(n)
        if offsets then
          for i = 1, #n.frames do
            n.frame_shifts[i] = n.frame_shifts[i] + (offsets[i] or 0)
          end
        end
      end
    end
    -- Does the note move the pitch at all? An unedited note the item's values leave as sung writes nothing
    n.frame_moves = false
    for i = 1, #n.frame_shifts do
      if n.frame_shifts[i] ~= 0 then n.frame_moves = true break end
    end
  end

  -- 2. The trajectory across notes. Two neighbours closer than two fades are joined (K.JOIN): the correction
  -- blends across the slide the singer sang between their bodies. Every other edge of an edited note fades.
  local J = K.JOIN
  local function emit(t, val)
    all_points[#all_points + 1] = { time = math.max(0.0, math.min(item_len, t)), val = val }
  end
  -- Corrected (reached, and edited or moved by the item's values): such a note writes its own points and takes
  -- part in its joins. A reached note left as sung writes none, as before: an unedited fresh item has no points.
  local function bypassed(n) return n.controls ~= nil and n.controls.bypassed == true end
  local function active(n)
    return K.note_reached(n) and (is_note_modified(n) or n.frame_moves == true)
  end
  -- The note's shift at time t: its frame shifts joined by straight lines, the first / last one before / after them
  local function shift_at(n, t)
    local fr, sh = n.frames, n.frame_shifts
    local nf = fr and #fr or 0
    if nf == 0 or not sh then return 0.0 end
    if t <= fr[1].time then return sh[1] or 0.0 end
    if t >= fr[nf].time then return sh[nf] or 0.0 end
    local lo, hi = 1, nf
    while hi - lo > 1 do
      local mid = math.floor((lo + hi) / 2)
      if fr[mid].time <= t then lo = mid else hi = mid end
    end
    local t0, t1 = fr[lo].time, fr[hi].time
    local v0, v1 = sh[lo] or 0.0, sh[hi] or 0.0
    return (t1 > t0) and v0 + (v1 - v0) * (t - t0) / (t1 - t0) or v1
  end
  -- The times of the first and last frame of the note's body; a note without a body is all body
  local function body_times(n)
    local fr = n.frames
    if not fr or #fr == 0 then return n.start_time, n.end_time end
    local a, b = K.note_body(n)
    return fr[a or 1].time, fr[b or #fr].time
  end

  -- joins[i]: the blend { t0, t1 } between notes i and i + 1, from the first note's body end to the second note's
  -- body start; at least MIN_S (grown evenly), at most MAX_S and MAX_PART of either note on its side (cut from the
  -- far ends, so the part nearest the boundary stays)
  local joins = {}
  for i = 1, num_notes - 1 do
    local na, nb = notes[i], notes[i + 1]
    if nb.start_time - na.end_time < 2 * J.FADE_S and (active(na) or active(nb)) then
      local _, a_end = body_times(na)
      local b_start = body_times(nb)
      local s0, s1 = a_end, math.max(a_end, b_start)
      if s1 - s0 < J.MIN_S then
        local c = (s0 + s1) * 0.5
        s0, s1 = c - J.MIN_S * 0.5, c + J.MIN_S * 0.5
      end
      local bnd = (na.end_time + nb.start_time) * 0.5
      local left, right = math.max(0, bnd - s0), math.max(0, s1 - bnd)
      if left + right > J.MAX_S then
        local half = J.MAX_S * 0.5
        if left < half then right = J.MAX_S - left
        elseif right < half then left = J.MAX_S - right
        else left, right = half, half end
      end
      s0 = math.max(0.0, bnd - left, na.end_time - J.MAX_PART * (na.end_time - na.start_time))
      s1 = math.min(item_len, bnd + right, nb.start_time + J.MAX_PART * (nb.end_time - nb.start_time))
      -- A bypassed note is not corrected: the blend stays on the edited side and ends (or starts) at the boundary,
      -- MIN_S long at least
      if bypassed(nb) then
        s1 = bnd
        s0 = math.max(0.0, na.start_time, math.min(s0, bnd - J.MIN_S))
      elseif bypassed(na) then
        s0 = bnd
        s1 = math.min(item_len, nb.end_time, math.max(s1, bnd + J.MIN_S))
      end
      joins[i] = { t0 = s0, t1 = math.max(s0, s1) }
    end
  end

  -- The blend of join j from note na into note nb (index b_idx): the first note's shift held at the span start,
  -- crossfaded (smoothstep) into the second note's own shift, one point per frame of either note
  local function emit_join(na, nb, b_idx, j)
    local hold = shift_at(na, j.t0)
    local len = j.t1 - j.t0
    local function put(t)
      local u = (len > 0) and (t - j.t0) / len or 1
      local own = shift_at(nb, t)
      emit(t, (u >= 1) and own or hold + (own - hold) * smoothstep(u))
    end
    put(j.t0)
    local fa, fb = na.frames or {}, nb.frames or {}
    local pa, pb = 1, 1
    while true do
      while fa[pa] and fa[pa].time <= j.t0 do pa = pa + 1 end
      while fb[pb] and fb[pb].time <= j.t0 do pb = pb + 1 end
      local ta = fa[pa] and fa[pa].time or math.huge
      local tb = fb[pb] and fb[pb].time or math.huge
      local t = math.min(ta, tb)
      if t >= j.t1 then break end
      put(t)
      if ta == t then pa = pa + 1 end
      if tb == t then pb = pb + 1 end
    end
    put(j.t1)
    spans[#spans + 1] = { kind = "glide", t0 = j.t0, t1 = j.t1, a = b_idx - 1, b = b_idx }
  end

  for idx = 1, num_notes do
    local n = notes[idx]
    local jp, jn = joins[idx - 1], joins[idx]

    -- A. The join from the previous note (written by whichever of the two is edited)
    if jp then emit_join(notes[idx - 1], n, idx, jp) end

    if active(n) then
      local fade = math.min(J.FADE_S, (n.end_time - n.start_time) * 0.25)
      local start_shift, end_shift = shift_at(n, n.start_time), shift_at(n, n.end_time)
      -- The time range this note corrects, with its joins and fades
      local range = { t0 = jp and jp.t0 or n.start_time, t1 = jn and jn.t1 or n.end_time }
      -- The body runs from the end of the join before (or the note start) to the start of the join after (or the
      -- note end); an edge a join or fade already wrote is not written again
      local body_t0 = jp and jp.t1 or n.start_time
      local body_t1 = jn and jn.t0 or n.end_time
      local t0_written = jp ~= nil

      -- B. Onset from silence: smooth ramp into the note's shift
      if not jp and math.abs(start_shift) > 0.001 then
        local t_pre = math.max(0.0, n.start_time - fade)
        local steps = 4
        for s = 0, steps do
          local u = s / steps
          emit(t_pre + u * (n.start_time - t_pre), start_shift * smoothstep(u))
        end
        spans[#spans + 1] = { kind = "onset", t0 = t_pre, t1 = n.start_time, a = idx }
        range.t0 = math.min(range.t0, t_pre)
        t0_written = true
      end

      -- C. The body: one point per frame when its shifts vary, its two ends when they are constant
      if not t0_written then emit(body_t0, shift_at(n, body_t0)) end
      local sh, fr = n.frame_shifts, n.frames
      local varies = false
      if fr and sh and sh[1] then
        for i = 2, #fr do
          if math.abs((sh[i] or 0) - sh[1]) > 1e-9 then varies = true break end
        end
      end
      if varies then
        for i = 1, #fr do
          local t = fr[i].time
          if t > body_t0 and t < body_t1 then emit(t, sh[i]) end
        end
      end

      -- D. Release into silence: smooth ramp out of the note's shift
      if not jn and math.abs(end_shift) > 0.001 then
        local steps = 4
        for s = 0, steps do
          local u = s / steps
          emit(n.end_time + u * fade, end_shift * (1.0 - smoothstep(u)))
        end
        local t_post = math.min(item_len, n.end_time + fade + 0.001)
        emit(t_post, 0.0)
        spans[#spans + 1] = { kind = "release", t0 = n.end_time, t1 = math.min(item_len, n.end_time + fade), a = idx }
        range.t1 = math.max(range.t1, t_post)
      elseif not jn then
        emit(body_t1, shift_at(n, body_t1))
      end

      ranges[#ranges + 1] = range
    end
  end

  -- Ranges are in note order; merge the ones that touch
  local merged = {}
  for _, r in ipairs(ranges) do
    local last = merged[#merged]
    if last and r.t0 <= last.t1 then
      last.t1 = math.max(last.t1, r.t1)
    else
      merged[#merged + 1] = r
    end
  end

  return { points = all_points, spans = spans, ranges = merged }
end

-------------------------------------------------------------------------------
-- 4b. MODES
-------------------------------------------------------------------------------
-- Mode picks how a note is corrected: 0 Natural (K.natural_build), 1 Classic, 2 Hard. A note stores its own mode
-- (controls.correct_mode) or inherits the item's (take overrides); anything but 1 or 2 is Natural. Classic and Hard
-- are built beside Natural, never inside it: K.natural_build is not edited for them (K.correction_build chooses).
-------------------------------------------------------------------------------
K.MODE = { GLIDE_S = 0.100, OUTLIER_ST = 3, STEP_S = 0.0005 }
K.MODES = { "Natural", "Classic", "Hard" }

--- The mode in force for `note` (nil = the item): its own, else the item's; 0 (Natural), 1 or 2.
K.mode_value = function(note)
  local v = get_effective(note, "correct_mode")
  if v == 1 or v == 2 then return v end
  return 0
end

--- "classic" or "hard" when `note` is corrected by that mode; nil when Natural handles it (no controls, bypassed,
--- or Natural). The item's mode reaches every note, edited or not.
K.note_mode = function(note)
  if not K.note_reached(note) then return nil end
  local v = K.mode_value(note)
  if v == 1 then return "classic" end
  if v == 2 then return "hard" end
  return nil
end

--- How many of `notes` are corrected by Classic or Hard (K.note_mode non-nil).
K.mode_note_count = function(notes)
  local n = 0
  for _, note in ipairs(notes or {}) do
    if K.note_mode(note) then n = n + 1 end
  end
  return n
end

--- How many of `notes` keep a mode of their own (not bypassed): the notes the item's mode does not reach.
K.mode_own_count = function(notes)
  local n = 0
  for _, note in ipairs(notes or {}) do
    if K.note_reached(note) and note.controls.correct_mode ~= nil then n = n + 1 end
  end
  return n
end

--- The status message of a change of the item's mode to `mode` (0, 1 or 2); `count` notes keep their own mode.
K.mode_item_status = function(mode, count)
  local name = K.MODES[(mode or 0) + 1] or K.MODES[1]
  if count == 0 then return string.format("Mode: %s for this item. Every note uses it", name) end
  return string.format("Mode: %s for this item (%d %s)", name, count,
    count == 1 and "note with its own mode" or "notes with their own mode")
end

--- Why the control `key` does nothing for the `n` notes in `notes`: "mode" (the mode does not use it), "hard" or
--- "classic" (Tighten only: that mode ignores it); nil when it works for at least one note. With no notes (n = 0)
--- it is the item's value, judged by the item's mode.
K.mode_unused = function(key, notes, n)
  local all1, all2, none0 = true, true, true
  for i = 1, math.max(1, n) do
    local v = K.mode_value(n > 0 and notes[i] or nil)
    if v ~= 1 then all1 = false end
    if v ~= 2 then all2 = false end
    if v == 0 then none0 = false end
  end
  if key == "retune_speed" or key == "tolerance" or key == "slide_in" then
    return none0 and "mode" or nil
  end
  if key == "tighten" then
    if all2 then return "hard" end
    if all1 then return "classic" end
  end
  return nil
end

K.scale_pcs_memo = {}

--- The pitch classes ({ [0..11] = true }) of scale `scale_idx` in key `key_idx` (1 = C); nil for an unknown scale.
--- Memoised: the same (key, scale) always returns the same table, so K.mode_line's cache can compare it by identity.
--- The returned set is shared: callers must not modify it.
K.scale_pcs = function(key_idx, scale_idx)
  local scale = SCALE_DEFINITIONS[scale_idx]
  if not scale or type(key_idx) ~= "number" then return nil end
  local root = (key_idx - 1) % 12
  local mk = (key_idx == 0) and "auto" or (root .. ":" .. scale_idx)
  local pcs = K.scale_pcs_memo[mk]
  if pcs then return pcs end
  pcs = {}
  -- Auto (an item not analysed yet): every pitch class is in scale
  for _, intv in ipairs(key_idx == 0 and SCALE_DEFINITIONS[#SCALE_DEFINITIONS].intervals or scale.intervals) do
    pcs[(root + intv) % 12] = true
  end
  K.scale_pcs_memo[mk] = pcs
  return pcs
end

--- Key and Scale of the take the build is for (its stored ones), each falling back to the combos' value.
K.item_scale = function()
  local td = state.target_take_guid and state.session_takes and state.session_takes[state.target_take_guid]
  local key_idx = td and td.key_idx or state.key_idx
  local scale_idx = td and td.scale_idx or state.scale_idx
  return key_idx, scale_idx
end

K.item_scale_pcs = function()
  return K.scale_pcs(K.item_scale())
end

--- The whole semitone nearest `pitch` whose pitch class is in `pcs` (nil or empty: every semitone). Searched 6 either
--- side of the rounded pitch; a tie goes to the lower.
K.nearest_scale_pitch = function(pitch, pcs)
  local base = math.floor(pitch + 0.5)
  local any = pcs == nil or next(pcs) == nil
  local best, best_d = base, math.huge
  for c = base - 6, base + 6 do
    if any or pcs[c % 12] then
      local d = math.abs(c - pitch)
      if d < best_d then best, best_d = c, d end
    end
  end
  return best
end

--- Classic or Hard correction of one note: shifts[i] (semitones, without pitch-point offsets) for each frame, and
--- steps[i] = true where the pitch steps just before frame i. Cached on note.mode_cache.
--- The returned shifts and steps tables are the cache itself: shared, read-only for callers.
K.mode_line = function(note, mode, pcs)
  local frames = note.frames or {}
  local ctrl = note.controls or {}
  local tighten = note.controls and tonumber(get_effective(note, "tighten")) or 0
  if tighten < 0 then tighten = 0 elseif tighten > 1 then tighten = 1 end
  local avg = note.avg_note
  local centre = type(ctrl.center_pitch) == "number" and ctrl.center_pitch or avg
  local c = note.mode_cache
  if c and c.frames == frames and c.tighten == tighten and c.mode == mode and c.centre == centre
     and c.avg == avg and c.pcs == pcs then
    return c.shifts, c.steps
  end
  local shifts, steps = {}, {}
  if #frames > 0 and type(avg) == "number" and type(centre) == "number" then
    local move = centre - avg
    local target = K.nearest_scale_pitch(centre, pcs)
    local last = target - avg
    local tau = K.MODE.GLIDE_S * (1 - tighten)
    local line, have_line = 0, false
    for i = 1, #frames do
      local sung = frames[i].note
      if type(sung) == "number" and math.abs(sung - avg) <= K.MODE.OUTLIER_ST then
        if mode == "hard" then
          last = target - sung
        else
          local goal = K.nearest_scale_pitch(sung + move, pcs)
          local dt = i > 1 and ((frames[i].time or 0) - (frames[i - 1].time or 0)) or 0
          if not have_line then
            line, have_line = goal, true
          elseif tau * 3 <= dt then
            if goal ~= line then steps[i] = true end
            line = goal
          else
            line = line + (1 - math.exp(-dt / tau)) * (goal - line)
          end
          last = line - sung
        end
      end
      shifts[i] = last
    end
  end
  note.mode_cache = { frames = frames, tighten = tighten, mode = mode, centre = centre, avg = avg, pcs = pcs,
                      shifts = shifts, steps = steps }
  return shifts, steps
end

--- A stand-in for a Classic or Hard note, for K.natural_build: it reads everything from `note` except its controls,
--- which read from the real controls except bypassed = true. Whatever the build writes (frame_shifts, the caches
--- of K.note_body and the like) lands on the stand-in, never on the real note.
K.mode_stand_in = function(note)
  local ctrl = setmetatable({ bypassed = true }, { __index = note.controls })
  return setmetatable({ controls = ctrl }, { __index = note })
end

--- The pitch correction of `notes`: K.natural_build's own result when no note is Classic or Hard. Otherwise
--- Natural builds every note with each Classic or Hard note seen as bypassed, and those notes write their own
--- points beside it (stepping in and out over K.MODE.STEP_S, held across to a touching Classic or Hard
--- neighbour). Pure (no REAPER calls); returns { points, spans, ranges } as K.natural_build does.
K.correction_build = function(notes, item_len)
  local num_notes = #notes
  local modes, any = {}, false
  for i = 1, num_notes do
    modes[i] = K.note_mode(notes[i])
    if modes[i] then any = true end
  end
  if not any then return K.natural_build(notes, item_len) end

  local stand = {}
  for i = 1, num_notes do
    stand[i] = modes[i] and K.mode_stand_in(notes[i]) or notes[i]
  end
  local A = K.natural_build(stand, item_len)

  local STEP, J = K.MODE.STEP_S, K.JOIN
  local pcs = K.item_scale_pcs()
  local function clamp(t) return math.max(0.0, math.min(item_len, t)) end
  local function has_frames(n) return n.frames ~= nil and #n.frames > 0 end
  -- Notes i and i + 1 are both Classic or Hard (with frames) and close enough to be held across
  local function held(i)
    local na, nb = notes[i], notes[i + 1]
    return nb ~= nil and modes[i] ~= nil and modes[i + 1] ~= nil and has_frames(na) and has_frames(nb)
      and nb.start_time - na.end_time < 2 * J.FADE_S
  end

  -- blocks[k]: the points of one Classic or Hard note, in time order; blocks are in note order. A point is
  -- never clamped onto another: a step in before the item start or a close after its end is not written.
  local blocks, mode_ranges = {}, {}
  local block
  local function put(t, val) block[#block + 1] = { time = clamp(t), val = val } end
  for idx = 1, num_notes do
    local n = notes[idx]
    if modes[idx] and not has_frames(n) then
      n.frame_shifts = {}
    elseif modes[idx] then
      block = {}
      local fr, nf = n.frames, #n.frames
      local shifts, steps = K.mode_line(n, modes[idx], pcs)
      local offsets = K.points_offsets(n)
      local fs = {}
      for i = 1, nf do fs[i] = (shifts[i] or 0) + (offsets and offsets[i] or 0) end
      n.frame_shifts = fs

      local t_first, t_last = fr[1].time, fr[nf].time
      if t_first - STEP >= 0 then
        if idx > 1 and held(idx - 1) then
          local p = notes[idx - 1]
          put(t_first - STEP, p.frame_shifts[#p.frames])
        else
          put(t_first - STEP, 0.0)
        end
      end
      for i = 1, nf do
        if i > 1 and steps[i] then put(fr[i].time - STEP, fs[i - 1]) end
        put(fr[i].time, fs[i])
      end
      local range = { t0 = clamp(t_first - STEP) }
      if held(idx) then
        range.t1 = clamp(notes[idx + 1].frames[1].time)
      else
        local t_close = math.max(n.end_time, t_last + STEP)
        if t_close - STEP > t_last and t_close - STEP <= item_len then put(t_close - STEP, fs[nf]) end
        if t_close <= item_len then put(t_close, 0.0) end
        range.t1 = clamp(t_close)
      end
      mode_ranges[#mode_ranges + 1] = range
      blocks[#blocks + 1] = block
    end
  end

  -- Natural's points outside every Classic or Hard range (closed at both ends), in Natural's own order; each
  -- note's block goes just before the first of them that is later than the block's first point (the envelope
  -- writer simplifies in list order, so the list must not go back in time)
  local points, next_block = {}, 1
  local function add_blocks_before(t)
    while blocks[next_block] and (t == nil or t > blocks[next_block][1].time) do
      for _, q in ipairs(blocks[next_block]) do points[#points + 1] = q end
      next_block = next_block + 1
    end
  end
  -- A time is inside a range when the latest end of the ranges starting at or before it is not before it: the
  -- ranges sorted by start (a copy: notes need not be in time order, ranges may touch or overlap) and a binary
  -- search for the last one starting at or before the time
  local by_t0, reach = {}, {}
  for i, r in ipairs(mode_ranges) do by_t0[i] = r end
  table.sort(by_t0, function(a, b) return a.t0 < b.t0 end)
  for i, r in ipairs(by_t0) do reach[i] = math.max(reach[i - 1] or r.t1, r.t1) end
  local function in_mode_range(t)
    local lo, hi = 0, #by_t0
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if by_t0[mid].t0 <= t then lo = mid else hi = mid - 1 end
    end
    return lo > 0 and t <= reach[lo]
  end
  for _, p in ipairs(A.points) do
    local inside = in_mode_range(p.time)
    if not inside then
      add_blocks_before(p.time)
      points[#points + 1] = p
    end
  end
  add_blocks_before(nil)

  local all = {}
  for _, r in ipairs(A.ranges) do all[#all + 1] = { t0 = r.t0, t1 = r.t1 } end
  for _, r in ipairs(mode_ranges) do all[#all + 1] = r end
  table.sort(all, function(a, b) return a.t0 < b.t0 end)
  local merged = {}
  for _, r in ipairs(all) do
    local last = merged[#merged]
    if last and r.t0 <= last.t1 then
      last.t1 = math.max(last.t1, r.t1)
    else
      merged[#merged + 1] = r
    end
  end

  return { points = points, spans = A.spans, ranges = merged }
end

--- The length the envelope of `item` is written over, in seconds (at least 0.1).
K.take_len = function(item)
  return math.max(0.1, reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0)
end

--- The correction K.write_take_envelope writes for the model `data` of the take `guid`, built with `guid` standing in
--- as the target (get_effective and K.item_scale read the target's item values from state.session_takes[guid]): nil
--- when it reaches no note (all bypassed, or none: the item's values reach unedited notes too). Raises when it cannot
--- be built; the target comes back either way.
K.take_correction = function(guid, data, item_len)
  local any_reached = false
  for _, n in ipairs(data.notes or {}) do
    if K.note_reached(n) then
      any_reached = true
      break
    end
  end
  if not any_reached then return nil end
  local saved = state.target_take_guid
  state.target_take_guid = guid
  local ok, res = pcall(K.correction_build, data.notes, item_len)
  state.target_take_guid = saved
  if not ok then error(res, 0) end
  return res
end

--- Write the take pitch envelope of the take `guid` from the notes of its model `data`, and store `data` on the take,
--- with no undo block of its own (the caller holds one open). The correction is built with `guid` standing in as
--- the target (get_effective and K.item_scale read the target's item values), as K.envelope_check does; the
--- target comes back even when the build raises. The model is stored only when it is the session's model of
--- `guid` (state.session_takes[guid] == data). The take's pitch mode is set as for an edit unless keep_pitch_mode
--- (or the Settings option state.keep_pitch_mode). take / item: the caller's, when it resolved them already. opts
--- (optional): json = the model's text when the caller prepared it already (K.take_json); built = true when the
--- caller built the correction already (K.take_correction), build = its result (nil: it reaches no note).
--- Returns false when the take or its Pitch envelope is not there (nothing written but the pitch mode).
K.write_take_envelope = function(guid, data, keep_pitch_mode, take, item, opts)
  if not data then return false end
  take = take or (guid and resolve_take_by_guid(guid, true)) or nil
  item = item or (take and K.take_item(take)) or nil
  if not take or not item then return false end

  opts = opts or {}
  local item_len = K.take_len(item)

  -- 1-2. The trajectory (frame shifts, scoop, ramps, glides): the same one the canvas draws. Built before anything
  -- is written, so a build that fails leaves the take's envelope and pitch mode as they were
  local build = opts.build
  if not opts.built then build = K.take_correction(guid, data, item_len) end

  -- Set pitch shift mode (Elastique Soloist Monophonic by default), unless the user keeps each item's own
  if not keep_pitch_mode and not state.keep_pitch_mode and state.pitchmode_value ~= -1 then
    reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", state.pitchmode_value)
  end

  local env = ensure_take_pitch_envelope(take, item)
  if not env then return false end

  -- Clear existing points across the entire item
  reaper.DeleteEnvelopePointRange(env, 0, item_len + 1.0)

  if build then
    local SHAPE = 5   -- Bezier
    local TENSION = 0 -- Neutral tension
    -- 3. Adaptive decimation with sub-cent tolerance (0.01 st / 1 cent)
    for _, pt in ipairs(rdp_simplify(build.points, 0.01)) do
      local t = math.max(0.0, math.min(item_len, pt.time))
      reaper.InsertEnvelopePointEx(env, -1, t, pt.val, SHAPE, TENSION, 0, true)
    end
  end
  reaper.Envelope_SortPointsEx(env, -1)

  -- Model (P_EXT) with the points, so Cmd+Z reverts the envelope and the note model together
  if guid and state.session_takes[guid] == data then save_take_data(take, data, opts.json) end
  -- The envelope is rewritten from the model with today's values: the take is current again
  if guid then state.stale_takes[guid], state.stale_env[guid] = nil, nil end
  return true
end

--- Rewrite the take pitch envelope from state.notes and persist the model, as one undo point.
--- keep_pitch_mode leaves the item's I_PITCHMODE untouched (used by re-analysis, which applies no correction); so does
--- the Settings option "Keep each item's own pitch algorithm" (state.keep_pitch_mode).
--- Returns true when the envelope and the model were written (one undo point); false when they were not, after
--- saying why in the status line (so a caller must not then claim an undo point). flush_records: true (an Auto
--- analysis) writes every track record it found inside the same block, a track (a key corrected on an item that
--- follows its track, Find Key) only that track's (K.records_flush).
local function apply_envelope_to_take(undo_desc, keep_pitch_mode, flush_records)
  -- A pending arrow-key nudge is committed as its own undo point first
  if state.nudge_burst then flush_nudge_burst() end

  local take, item = get_target_take()
  if not take or not item then
    set_status("This item is no longer in the project")
    return false
  end

  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if data and state.notes then data.notes = state.notes end

  reaper.Undo_BeginBlock()
  state.undo_open = true
  K.frame_view_memo.frame = nil   -- the canvas fetches the changed correction again (K.frame_view)

  -- An open item without a session model still gets its envelope (nothing is stored: see K.write_take_envelope)
  if not K.write_take_envelope(guid, data or { notes = state.notes }, keep_pitch_mode, take, item) then
    set_status("Couldn't show the pitch envelope on this item. Check that the item is an audio item on an unlocked track, then try again.")
    end_apply(take, "Apply Pitch Correction", flush_records)
    return false
  end

  reaper.UpdateArrange()
  K.records_flush(flush_records)
  reaper.Undo_EndBlock(undo_desc or "Apply Pitch Correction", -1)
  state.undo_open = false
  note_own_write()
  return true
end

--- The status line after a key change rewrote `count` Classic / Hard notes of the open item.
K.key_changed_status = function(count)
  local key_name = SCALE_KEYS[state.key_idx].display
  local scale_name = SCALE_DEFINITIONS[state.scale_idx].name
  if count == 1 then
    set_status(string.format("Key changed: 1 Classic / Hard note follows %s %s", key_name, scale_name))
  else
    set_status(string.format("Key changed: %d Classic / Hard notes follow %s %s", count, key_name, scale_name))
  end
end

--- The track an analysed item `data` follows for its key, and the track's record (K.key_track_record: its key, as it
--- was before the change, was found on the track and the record still holds it). nil otherwise.
K.key_follow_track = function(data)
  return K.key_track_record(data, data and (data.guid or state.target_take_guid))
end

--- Key or Scale was changed in the top bar (state.key_idx / state.scale_idx already hold the new values). With no
--- Classic or Hard note in the open item this is the plain save; otherwise the item's notes follow the new scale:
--- its take data takes the new Key and Scale and the envelope is rewritten, all in one undo point. `what` = "key" or
--- "scale": what changed, which names the undo point ("Set Key" / "Set Scale").
--- On an analysed item whose key came from its track (K.key_follow_track) the track's key changes with it, in the
--- same undo point, and the Key for new items stays as it is (Auto): later items on the track follow. Auto chosen on
--- an analysed item finds its key on its track (K.find_key_request).
K.scale_changed = function(what)
  local undo_label = (what == "scale") and "Set Scale" or "Set Key"
  local data = state.target_take_guid and state.session_takes[state.target_take_guid]
  if state.key_idx == 0 and data then
    -- An analysed item never shows Auto: the bar keeps the item's key until its track's is found
    state.key_idx = data.key_idx or K.new_key.hand_key_idx
    update_scale_pitch_classes()
    K.find_key_request()
    return
  end
  update_scale_pitch_classes()
  -- A real key or a scale chosen is the key last chosen by hand (what Auto falls back to). On the from-track path
  -- below it changes in memory only: it is saved with the next "key" settings save
  if state.key_idx ~= 0 then K.new_key.hand_key_idx, K.new_key.hand_scale_idx = state.key_idx, state.scale_idx end
  -- While an analysis, a batch or a pre-analysis runs its pending records are its own: the key changes as on any item
  local follow, rec = nil, nil
  if not (state.is_analyzing or K.batch or state.pre) then follow, rec = K.key_follow_track(data) end
  if follow then
    -- The track's record takes the key (its runner-up no longer applies); written inside the item's undo block
    local new = {}
    for k, v in pairs(rec) do new[k] = v end
    new.key_idx, new.scale_idx, new.alt_key_idx, new.alt_scale_idx = state.key_idx, state.scale_idx, nil, nil
    K.track_records_pending[follow] = new
  else
    -- The next new item starts in this Key and Scale (ExtState: a preference, not part of the item's undo point)
    K.new_key.key_idx, K.new_key.scale_idx = state.key_idx, state.scale_idx
    K.save_settings("key")
  end
  local count = data and K.mode_note_count(state.notes or {}) or 0
  local wrote
  if count == 0 then
    wrote = save_current_scale_settings(undo_label, follow)
  else
    data.key_idx = state.key_idx
    data.scale_idx = state.scale_idx
    wrote = apply_envelope_to_take(undo_label, nil, follow)
    if wrote and not follow then K.key_changed_status(count) end
  end
  if follow then
    K.track_records_pending[follow] = nil   -- written inside the block above, or never
    if wrote then
      set_status(string.format("Key for %s is now %s. New items on this track follow.", K.track_label(follow),
        K.key_text(state.key_idx, state.scale_idx)))
    end
  end
end

--- Key "Auto" chosen on the analysed open item: it takes its track's key (K.find_key_finish). A track with no record
--- is heard first (K.pre_begin; the record found is written with the item, or dropped). Never while an analysis, a
--- batch or a pre-analysis runs.
K.find_key_request = function()
  if state.is_analyzing or K.batch or state.pre then return end
  local guid = state.target_take_guid
  if not (guid and state.session_takes[guid]) then return end
  local track = K.take_track(guid)
  if not track then return end
  local rec = K.track_record(track)
  if rec then
    K.find_key_finish(guid, track, rec)
    return
  end
  if K.pre_begin({ track }, { on_done = function(results, external)
    K.find_key_finish(guid, track, results[track])
    if external then state.last_change_count = nil end   -- K.pre_note_external: after its own write
  end }) then
    state.pre.alone = true
  end
end

--- The track's record `rec` (nil: the track went) is known: the open item `guid` takes its key and scale (one undo
--- point "Find Key: <item>", the envelope rewritten when it has Classic / Hard notes, a record just found written in
--- the same block). No key in the record, or the item has it already: nothing is written. Nothing stays pending.
K.find_key_finish = function(guid, track, rec)
  local data = state.session_takes[guid]
  local take = resolve_take_by_guid(guid, true)
  if not (data and take and state.target_take_guid == guid) then
    K.track_records_pending[track] = nil
    return
  end
  if not (rec and rec.key_idx) then
    K.track_records_pending[track] = nil
    set_status(string.format(K.NO_KEY_FMT, K.key_text(data.key_idx, data.scale_idx)))
    return
  end
  if data.key_idx == rec.key_idx and data.scale_idx == rec.scale_idx and data.key_from_track then
    -- The item has its track's key already: nothing is written, the status says whose key it is
    K.track_records_pending[track] = nil
    set_status((K.auto_status({ fresh = false, want_key = true, track = K.track_label(track),
      key_text = K.key_text(rec.key_idx, rec.scale_idx) })))
    return
  end
  data.key_idx, data.scale_idx, data.key_from_track = rec.key_idx, rec.scale_idx, true
  state.key_idx, state.scale_idx = rec.key_idx, rec.scale_idx
  update_scale_pitch_classes()
  local label = "Find Key: " .. (data.name or state.target_take_name or "this item")
  local wrote
  if K.mode_note_count(state.notes or {}) == 0 then
    wrote = save_current_scale_settings(label, track)
  else
    wrote = apply_envelope_to_take(label, nil, track)
  end
  K.track_records_pending[track] = nil   -- written inside the block above, or never
  if wrote then
    -- What was found, as an Auto analysis says it with only the key on Auto: "Found E Major. Cmd+Z to undo."
    set_status((K.auto_status({ fresh = true, want_key = true, track = K.track_label(track),
      key_text = K.key_text(rec.key_idx, rec.scale_idx),
      alt_text = rec.alt_key_idx and K.key_text(rec.alt_key_idx, rec.alt_scale_idx) or nil })))
  end
end

--- Why "..." > Find Range and Key Again is disabled, or nil: no item to take the track from, or something runs.
K.find_again_reason = function(has_target)
  if state.is_analyzing or K.batch or state.pre then return K.REASON_ANALYZING end
  if not has_target then return K.REASON_NO_TARGET end
  return nil
end

--- "..." > Find Range and Key Again: hear the open item's whole track afresh (K.pre_begin, fresh) and replace its
--- record (K.find_again_finish). Analysed items are not changed.
K.find_again_request = function()
  if state.is_analyzing or K.batch or state.pre then return end
  local take = get_target_take()
  local track = take and reaper.GetMediaItemTake_Track(take)
  if not (track and reaper.ValidatePtr2(0, track, "MediaTrack*")) then return end
  local prev = K.track_record(track)
  local list, skipped = K.pre_takes(track, nil)
  local total = #list + skipped
  local guid = get_take_guid(take)
  if K.pre_begin({ track }, { fresh = true, on_done = function(results, external)
    K.find_again_finish(track, prev, results[track], total, guid)
    if external then state.last_change_count = nil end   -- K.pre_note_external: after its own write
  end }) then
    state.pre.alone = true
  end
end

--- The fresh record `rec` of `track` is heard (nil: the track went). Nothing found (no range, no key): the record
--- `prev` stays as it is. Otherwise `rec` replaces it, with prev's key when none was found, in one undo point
--- "Find Range and Key: <track>" that holds only the record. `total`: the audio items on the track; `guid`: the take
--- it was asked from. Status by the Auto analysis's priority: unreadable media > what was found. Nothing stays pending.
K.find_again_finish = function(track, prev, rec, total, guid)
  K.track_records_pending[track] = nil
  if not (rec and reaper.ValidatePtr2(0, track, "MediaTrack*")) then
    -- The track went while it was heard: said only when the item `guid` went with it (one moved off it: no status)
    if not (guid and resolve_take_by_guid(guid, true)) then set_status("This item is no longer in the project") end
    return
  end
  if not rec.lo_st and not rec.key_idx then
    -- Nothing heard at all, every take unreadable: say so; else the key kept (the track's, else the bar's)
    if (rec.skipped or 0) > 0 and next(rec.takes) == nil then
      set_status(K.AUTO_UNREADABLE_TEXT)
      return
    end
    local k, sc
    if prev and prev.key_idx then
      k, sc = prev.key_idx, prev.scale_idx
    else
      k, sc = K.key_resolve(state.key_idx, state.scale_idx, state.target_take_guid)
    end
    set_status(string.format(K.NO_KEY_FMT, K.key_text(k, sc)))
    return
  end
  local found_key = rec.key_idx ~= nil
  if not found_key and prev and prev.key_idx then
    rec.key_idx, rec.scale_idx = prev.key_idx, prev.scale_idx
    rec.alt_key_idx, rec.alt_scale_idx = prev.alt_key_idx, prev.alt_scale_idx
  end
  local name = K.track_label(track)
  K.track_records_pending[track] = rec
  reaper.Undo_BeginBlock()
  state.undo_open = true
  K.track_record_flush_one(track)
  reaper.Undo_EndBlock("Find Range and Key: " .. name, -1)
  state.undo_open = false
  note_own_write()
  if (rec.skipped or 0) > 0 then
    set_status(string.format(K.SKIPPED_FMT, rec.skipped,
      math.max(total or 0, rec.skipped), name))
    return
  end
  -- What this run found: a key carried over from prev is not news
  local parts = {}
  if rec.lo_st then parts[#parts + 1] = K.pre_range_text(rec.lo_st, rec.hi_st) end
  if found_key then parts[#parts + 1] = K.key_text(rec.key_idx, rec.scale_idx) end
  set_status(string.format("Found %s on %s. Items already analyzed keep theirs. %s+Z to undo.",
    table.concat(parts, ", "), name, K.MOD_LABEL))
end

--- Whether the pitch envelope of the session take `guid` differs from what its note model and today's settings
--- would write: a global default changed while another item was open, the script that wrote it computed the
--- correction differently, or the item was changed since. It is read from the project, so it is true after a
--- restart of the script too (a flag kept in memory was lost there, and the item then looked current).
--- Returns stale (boolean) and, when stale, the points { time, val } the envelope holds, sorted by time.
K.envelope_check = function(guid)
  local data = state.session_takes[guid]
  local take = data and resolve_take_by_guid(guid, true) or nil
  if not take then return false end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return false end
  local notes = (guid == state.target_take_guid) and state.notes or data.notes
  local item_len = math.max(0.1, reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0)

  local function by_time(p, q)
    if p.time ~= q.time then return p.time < q.time end
    return p.val < q.val
  end

  -- What apply_envelope_to_take would write. get_effective reads the item values of the target take, so the
  -- take stands in as the target for the length of the calculation.
  local expected = {}
  if notes and #notes > 0 then
    local saved = state.target_take_guid
    state.target_take_guid = guid
    local ok, build = pcall(K.correction_build, notes, item_len)
    state.target_take_guid = saved
    if not ok then return false end   -- a model this script cannot compute is not called stale
    for _, pt in ipairs(rdp_simplify(build.points, 0.01)) do
      expected[#expected + 1] = { time = math.max(0.0, math.min(item_len, pt.time)), val = pt.val }
    end
    table.sort(expected, by_time)
  end

  -- What the item holds. The script writes Bezier points (shape 5); a point of another shape is not its own
  -- (REAPER keeps a default point at the start of an envelope).
  local actual, written = {}, {}
  local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
  if env then
    for i = 0, (reaper.CountEnvelopePointsEx(env, -1) or 0) - 1 do
      local ok, t, v, shape = reaper.GetEnvelopePointEx(env, -1, i)
      if ok then
        local pt = { time = t, val = v }
        actual[#actual + 1] = pt
        if shape == 5 then written[#written + 1] = pt end
      end
    end
  end
  table.sort(actual, by_time)
  table.sort(written, by_time)
  -- That default point is Bezier when the user's default point shape is: one extra zero at the very start is not a difference
  if #written == #expected + 1 and math.abs(written[1].time) < 0.0001 and math.abs(written[1].val) < 0.0001 then
    table.remove(written, 1)
  end

  local same = (#written == #expected)
  if same then
    for i = 1, #expected do
      if math.abs(written[i].time - expected[i].time) > 0.0002 or math.abs(written[i].val - expected[i].val) > 0.0002 then
        same = false
        break
      end
    end
  end
  if same then return false end
  return true, actual
end

--- Ask for the envelope of every session take to be compared again (after the project changed, or a global
--- default did). The work is done one take per frame by K.stale_check_step.
K.queue_stale_checks = function()
  local q = state.stale_queue
  for i = #q, 1, -1 do q[i] = nil end
  for i, guid in ipairs(state.session_order) do q[i] = guid end
end

--- Compare the envelope of one queued take (once per frame at most; nothing when the queue is empty). It waits
--- while a gesture or an analysis is in progress: the model is then ahead of the envelope on purpose.
K.stale_check_step = function(sctx)
  local q = state.stale_queue
  if #q == 0 then return end
  if state.is_analyzing or state.drag or state.edge_drag or state.point_drag or state.nudge_burst or state.undo_open
      or reaper.ImGui_IsAnyItemActive(sctx) then
    return
  end
  local guid = table.remove(q)
  local stale, points = false, nil
  if state.session_takes[guid] and not state.missing_takes[guid] then
    stale, points = K.envelope_check(guid)
  end
  state.stale_takes[guid] = stale or nil
  state.stale_env[guid] = stale and { points = points } or nil
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

  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    if n and n.controls then
      n.controls.center_pitch = n.controls.center_pitch + delta
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

-- Snaps selected note(s) to the nearest valid in-scale pitch.
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
      if math.abs(ctrl.center_pitch - sel.avg_note) > 0.001 or ctrl.bypassed then any_changed = true end
      if K.controls_clear(ctrl) then any_changed = true end
      if K.points_reset(sel) > 0 then any_changed = true end
      ctrl.center_pitch = sel.avg_note
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

  -- Preserve the user's pitch offset (semitones from original avg). extract_note_features replaces avg_note with its
  -- own centre (energy-weighted, over the sustained core), so each half's target is set from that centre afterwards:
  -- a target built on the plain frame mean would shift the half by the difference between the two.
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
  extract_note_features(note_a, K.controls_carry(old_ctrl))
  note_a.controls.center_pitch = note_a.avg_note + pitch_offset
  K.points_transfer(note_a, { note }, {})

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
  extract_note_features(note_b, K.controls_carry(old_ctrl))
  note_b.controls.center_pitch = note_b.avg_note + pitch_offset
  K.points_transfer(note_b, { note }, {})

  -- Splice into notes array
  state.notes[note_idx] = note_a
  table.insert(state.notes, note_idx + 1, note_b)

  -- Update selection: select left half, adjust any indices above split
  state.selected_note = note_idx
  state.selected_notes = { [note_idx] = true }

  return true, apply_envelope_to_take("Split Note")
end

-- Merges all contiguous selected notes into a single note.
-- The merged note is shifted by the duration-weighted average of the shifts the old notes had (0 when none was moved).
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

  -- Duration-weighted pitch offset (target minus detected centre) from user tuning
  local total_dur = 0
  local weighted_offset = 0
  local merged_from = {}
  for _, idx in ipairs(indices) do
    local n = state.notes[idx]
    local dur = n.end_time - n.start_time
    total_dur = total_dur + dur
    merged_from[#merged_from + 1] = n
    if n.controls then
      weighted_offset = weighted_offset + (n.controls.center_pitch - n.avg_note) * dur
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

  extract_note_features(merged, K.controls_merge(merged_from))
  -- The target follows the centre extract_note_features found (see split_note_at)
  merged.controls.center_pitch = merged.avg_note + (total_dur > 0 and (weighted_offset / total_dur) or 0)
  -- The bend of every old note carries over; a square holds each old boundary (inner end and start)
  local old_notes, pin_times = {}, {}
  for i, idx in ipairs(indices) do
    local n = state.notes[idx]
    old_notes[i] = n
    if i > 1 then pin_times[#pin_times + 1] = n.start_time end
    if i < #indices then pin_times[#pin_times + 1] = n.end_time end
  end
  K.points_transfer(merged, old_notes, pin_times)

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
-- fewer than 3 frames is refused (the edge snaps back) and says so in the status line. The note's pitch points carry
-- over (K.points_transfer); returns how many stored points lay outside the trimmed note and were removed.
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

  -- The note as it was (rebuilt in place below), for its points; when it grew, a square holds the old edge
  local old_note = { start_time = note.start_time, end_time = note.end_time, frames = note.frames,
    smart_spots = note.smart_spots, controls = old_ctrl, points_rev = note.points_rev, points_cache = note.points_cache }
  local old_edge = (edge == "left") and note.start_time or note.end_time
  local grew = (edge == "left" and new_start < old_edge) or (edge == "right" and new_end > old_edge)

  note.start_time = new_start
  note.end_time = new_end
  note.frames = new_frames
  note.sum_note = sum_note
  note.count = #new_frames
  note.avg_note = avg_note
  note.display_note = math.floor(avg_note + 0.5)

  extract_note_features(note, K.controls_carry(old_ctrl))
  note.controls.center_pitch = note.avg_note + pitch_offset   -- from the centre extract_note_features found
  local dropped = K.points_transfer(note, { old_note }, grew and { old_edge } or {})

  -- `dropped` only when the write made an undo point (the caller's status names it)
  if not apply_envelope_to_take("Trim Note Edge") then return 0 end
  return dropped
end

-- Note splitting: the fixed constants of K.segment (the ones Separation scales come from K.separation_params)
K.SEG = {
  BRIDGE_S = 0.025,      -- a shorter unvoiced stretch with matching pitch on both sides does not end the note
  SILENCE_DB = 40,       -- a frame this far below the 95th-percentile level of the voiced frames is silent
  DIP_REACH_S = 0.150,   -- how far each way a level dip looks for the peaks it must lie below
  MEDIAN_S = 0.015,      -- pitch median filter window (at least 3 frames)
  CYCLE_S = 0.18,        -- about one vibrato cycle: the window of the cycle median the note's centre is taken from
  -- The Separation columns 0 / 0.5 / 1 (fewer notes -> more notes); K.separation_params is linear between them
  SEPARATION = {
    { pitch_st = 1.5, hold_s = 0.140, dip_db = 12, min_note_s = 0.100 },
    { pitch_st = 0.8, hold_s = 0.090, dip_db = 6, min_note_s = 0.070 },
    { pitch_st = 0.4, hold_s = 0.050, dip_db = 3, min_note_s = 0.040 },
  },
}

--- The splitting thresholds at Separation `sep` (0..1): pitch_st (a departure from the note's centre beyond this...),
--- hold_s (...that lasts this long starts a new note), dip_db (a level dip this deep splits) and min_note_s (a shorter
--- piece is merged into a neighbour).
K.separation_params = function(sep)
  sep = math.max(0, math.min(1, sep or DEFAULTS.separation))
  local cols = K.SEG.SEPARATION
  local a, b, u
  if sep <= 0.5 then a, b, u = cols[1], cols[2], sep / 0.5
  else a, b, u = cols[2], cols[3], (sep - 0.5) / 0.5 end
  local p = {}
  for key, v in pairs(a) do p[key] = v * (1 - u) + b[key] * u end   -- exact at the columns
  return p
end

--- The frame spacing of `results` (time-ordered frames, at least two): the median step between frames.
K.frame_step = function(results)
  local steps = {}
  for i = 2, #results do steps[i - 1] = results[i].time - results[i - 1].time end
  table.sort(steps)
  local m = #steps
  if m % 2 == 1 then return steps[(m + 1) / 2] end
  return (steps[m / 2] + steps[m / 2 + 1]) * 0.5
end

--- Choosing a frame's period (K.cand_cost, K.pitch_track). A frame's candidates are the dips of its difference function
--- { tau = period in samples, d = how badly the sound repeats at that period (0 = perfectly) }. FLOOR: added to the
--- deepest dip before another dip is compared with it (so two dips near 0 are not told apart by noise); OCTAVE_COST:
--- what one octave down costs (a sound that repeats at a period repeats at its multiples too, so of dips about as deep
--- the shortest period is the pitch); JUMP_COST: what each semitone of pitch change from one frame to the next costs,
--- up to JUMP_CAP_ST; REF_HOP_S: the frame spacing the costs of a frame are given for (they scale with the spacing);
--- MAX_CANDS / CAND_MAX_D: how many dips a frame keeps, and how shallow a dip may be.
K.TRACK = { FLOOR = 0.02, OCTAVE_COST = 0.7, JUMP_COST = 0.15, JUMP_CAP_ST = 12, REF_HOP_S = 512 / 48000,
  MAX_CANDS = 8, CAND_MAX_D = 0.8 }

--- What it costs to read a frame at candidate `c`, judged within the frame alone: how much shallower its dip is than
--- the frame's deepest (d_min), relative to that depth, plus OCTAVE_COST per octave its period is above the frame's
--- shortest candidate period (tau_min). The frame's best reading costs 0 only when it is both.
K.cand_cost = function(c, d_min, tau_min)
  local T = K.TRACK
  return (c.d - d_min) / (d_min + T.FLOOR) + T.OCTAVE_COST * math.log(c.tau / tau_min, 2)
end

--- The candidate of `cands` (not empty) that costs least within its frame (K.cand_cost): a frame's reading before
--- its neighbours are known.
K.cand_best = function(cands)
  local d_min, tau_min = math.huge, math.huge
  for _, c in ipairs(cands) do
    d_min, tau_min = math.min(d_min, c.d), math.min(tau_min, c.tau)
  end
  local best, best_cost
  for _, c in ipairs(cands) do
    local cost = K.cand_cost(c, d_min, tau_min)
    if not best or cost < best_cost then best, best_cost = c, cost end
  end
  return best
end

--- Gives every frame that has candidates (`results`: time-ordered frames, `cands` on the voiced ones) its pitch: the
--- candidate on the cheapest line through the frames, where a line pays each frame's K.cand_cost and JUMP_COST for
--- every semitone it moves between frames. A line runs through unvoiced stretches shorter than K.SEG.BRIDGE_S and
--- starts afresh after a longer one. Sets freq and note, removes cands (they are not stored), and returns how many
--- frames it gave a pitch.
K.pitch_track = function(results, sample_rate)
  local T, n = K.TRACK, #results
  local hop = n >= 2 and K.frame_step(results) or 0
  if not (hop > 0) then hop = 0 end   -- luacheck: ignore 581 (also catches NaN)
  local scale = hop > 0 and hop / T.REF_HOP_S or 1
  local done = 0
  local line = {}   -- the frames of the running line: { i = result index, cost = { per candidate }, from = { per candidate } }
  local function finish()   -- walk the cheapest line back and set its frames
    local m = #line
    if m == 0 then return end
    local pick, low = 1, math.huge
    for ci, cost in ipairs(line[m].cost) do
      if cost < low then pick, low = ci, cost end
    end
    for k = m, 1, -1 do
      local f = results[line[k].i]
      f.freq = sample_rate / f.cands[pick].tau
      f.note = freq_to_note(f.freq)
      f.cands = nil
      done = done + 1
      pick = line[k].from[pick]
    end
    line = {}
  end
  for i = 1, n do
    local f = results[i]
    local cands = f.cands
    if cands and #cands > 0 then
      local last = line[#line]
      if last and f.time - results[last.i].time - hop >= K.SEG.BRIDGE_S then
        finish()
        last = nil
      end
      local d_min, tau_min = math.huge, math.huge
      for _, c in ipairs(cands) do
        d_min, tau_min = math.min(d_min, c.d), math.min(tau_min, c.tau)
      end
      local cost, from = {}, {}
      for ci, c in ipairs(cands) do
        local best, best_from = 0, 0
        if last then
          best = math.huge
          for pi, pc in ipairs(results[last.i].cands) do
            local jump = math.min(T.JUMP_CAP_ST, math.abs(12 * math.log(pc.tau / c.tau, 2)))
            local total = last.cost[pi] + T.JUMP_COST * jump
            if total < best then best, best_from = total, pi end
          end
        end
        cost[ci], from[ci] = best + K.cand_cost(c, d_min, tau_min) * scale, best_from
      end
      line[#line + 1] = { i = i, cost = cost, from = from }
    elseif cands then
      f.cands = nil   -- an empty list: no pitch
    end
  end
  finish()
  return done
end

--- Octave errors of the pitch detection (K.octave_fix): JUMP_TOL_ST = how far from a whole number of octaves a
--- frame-to-frame jump may be and still count as an octave jump; RETURN_TOL_ST = the same for a jump that undoes the
--- last octave jump within MAX_RUN_S (the pitch may have glided meanwhile); MAX_RUN_S = the longest stretch that is
--- put back (a longer one may be a sung leap); WINDOW_S = how far each way a stretch looks for the octave most frames
--- are in; MIN_MAJORITY_S = how much of that window those frames must fill to be trusted (fewer are no majority).
K.OCTAVE = { JUMP_TOL_ST = 1.0, RETURN_TOL_ST = 2.0, MAX_RUN_S = 0.15, WINDOW_S = 0.25, MIN_MAJORITY_S = 0.03 }

--- Puts short octave-off stretches of analysed frames back (`results`: time-ordered { time, note | nil, freq | nil }).
--- Within each stretch of frames that all have a pitch, a frame-to-frame jump of a whole number of octaves (within
--- JUMP_TOL_ST, or RETURN_TOL_ST when it undoes the last such jump soon after) starts a new octave class. A run of one class no longer than MAX_RUN_S belongs to the class that
--- strictly most frames within WINDOW_S of it are in (with no such class, or one of fewer frames than MIN_MAJORITY_S,
--- it stays). Each frame of the run then moves
--- by the octaves between the two classes only when that brings it closer to the middle pitch of that majority's
--- frames: a run can hold right frames too, when it was entered or left by a jump that is not an octave. Changes note
--- and freq in place and returns how many frames changed.
K.octave_fix = function(results)
  local O, n = K.OCTAVE, #results
  if n < 2 then return 0 end
  local hop = K.frame_step(results)
  if not (hop > 0) then return 0 end   -- luacheck: ignore 581 (also catches NaN)
  local changed, i = 0, 1
  while i <= n do
    if not results[i].note then
      i = i + 1
    else
      local j = i   -- the stretch i..j
      while j + 1 <= n and results[j + 1].note do j = j + 1 end
      local class = { [i] = 0 }
      local entry_k, entry_t   -- the last octave jump: its octaves and the time of its frame
      for q = i + 1, j do
        local d = results[q].note - results[q - 1].note
        local k = math.floor(d / 12 + 0.5)
        local err = math.abs(d - 12 * k)
        -- a jump back that undoes the last octave jump soon after counts with RETURN_TOL_ST: the voice may have
        -- glided while the reading was off
        local back = entry_k and k == -entry_k and results[q].time - entry_t <= O.MAX_RUN_S
        if k ~= 0 and (err <= O.JUMP_TOL_ST or (back and err <= O.RETURN_TOL_ST)) then
          class[q] = class[q - 1] + k
          entry_k, entry_t = k, results[q].time
        else
          class[q] = class[q - 1]
        end
      end
      local moves, q = {}, i   -- decided on the classes as detected, applied afterwards
      while q <= j do
        local e = q
        while e + 1 <= j and class[e + 1] == class[q] do e = e + 1 end
        if results[e].time - results[q].time + hop <= O.MAX_RUN_S then
          -- lo..hi: the frames of the stretch within WINDOW_S of the run (the run included)
          local lo, hi = q, e
          while lo - 1 >= i and results[lo - 1].time >= results[q].time - O.WINDOW_S do lo = lo - 1 end
          while hi + 1 <= j and results[hi + 1].time <= results[e].time + O.WINDOW_S do hi = hi + 1 end
          local count, best, best_n, tied = {}, nil, 0, false
          for x = lo, hi do count[class[x]] = (count[class[x]] or 0) + 1 end
          for c, cn in pairs(count) do
            if cn > best_n then best, best_n, tied = c, cn, false
            elseif cn == best_n then tied = true end
          end
          if not tied and best ~= class[q] and best_n * hop >= O.MIN_MAJORITY_S then
            local ref = {}   -- the majority's pitches; their middle one is where the run's frames should end up near
            for x = lo, hi do
              if class[x] == best then ref[#ref + 1] = results[x].note end
            end
            table.sort(ref)
            moves[#moves + 1] = { q, e, class[q] - best, ref[(#ref + 1) // 2] }
          end
        end
        q = e + 1
      end
      for _, mv in ipairs(moves) do
        for x = mv[1], mv[2] do
          local f = results[x]
          local moved = f.note - 12 * mv[3]
          if math.abs(moved - mv[4]) < math.abs(f.note - mv[4]) then
            f.note = moved
            if f.freq then f.freq = f.freq / 2 ^ mv[3] end
            changed = changed + 1
          end
        end
      end
      i = j + 1
    end
  end
  return changed
end

--- Splits analysed frames (`results`: time-ordered { time, note | nil, rms, lvl }) into notes at Separation `sep`.
--- Returns notes { start_time, end_time, frames, sum_note, count } (frames: the original result frames, voiced only)
--- and split_points { time, reason } (one per note, reason "Onset" / "Pitch change" / "Level dip"). Every time constant
--- is converted with the frames' own spacing. `results` is not modified. floor_db (optional): the level below which a
--- frame counts as silent, as K.segment_floor gives it for the whole item (a stretch re-split passes the item's, so
--- the same Separation splits the same way); nil = worked out from `results`.
K.segment = function(results, sep, floor_db)
  local P, SEG = K.separation_params(sep), K.SEG
  local notes, split_points = {}, {}
  local n = #results
  if n < 2 then return notes, split_points end

  local function median(list)   -- sorts `list`
    table.sort(list)
    local m = #list
    if m % 2 == 1 then return list[(m + 1) / 2] end
    return (list[m / 2] + list[m / 2 + 1]) * 0.5
  end
  -- Binary heaps: h[1] is the entry for which less(h[1], x) holds against every other x
  local function hpush(h, e, less)
    local c = #h + 1
    h[c] = e
    while c > 1 do
      local up = c // 2
      if not less(e, h[up]) then break end
      h[c], h[up] = h[up], e
      c = up
    end
  end
  local function hpop(h, less)
    local top, c = h[1], #h
    h[1] = h[c]
    h[c] = nil
    c = c - 1
    local i = 1
    while true do
      local l, best = 2 * i, i
      if l <= c and less(h[l], h[best]) then best = l end
      if l + 1 <= c and less(h[l + 1], h[best]) then best = l + 1 end
      if best == i then break end
      h[i], h[best] = h[best], h[i]
      i = best
    end
    return top
  end
  local function lt(x, y) return x < y end
  local function gt(x, y) return x > y end

  local hop = K.frame_step(results)
  if not (hop > 0) then return notes, split_points end   -- luacheck: ignore 581 (also catches NaN)
  local half_w = math.max(1, math.floor(SEG.MEDIAN_S / hop / 2 + 0.5))   -- median window 2*half_w + 1 frames

  -- 1. Levels in dB; a frame is voiced when it has a pitch and is not silent relative to the item's loud level
  local db, loud = {}, {}
  for i, f in ipairs(results) do
    db[i] = 20 * math.log(math.max(f.lvl or f.rms or 0, 1e-10), 10)
    if f.note then loud[#loud + 1] = db[i] end
  end
  if #loud == 0 then return notes, split_points end
  if not floor_db then
    table.sort(loud)
    floor_db = loud[math.max(1, math.ceil(0.95 * #loud))] - SEG.SILENCE_DB
  end
  local voiced = {}
  for i, f in ipairs(results) do voiced[i] = f.note ~= nil and db[i] >= floor_db end

  -- 2. Runs of voiced frames; a short unvoiced stretch with matching pitch on both sides is bridged
  local function side_pitch(list, from, to)
    local vals = {}
    for k = from, to do vals[#vals + 1] = results[list[k]].note end
    return median(vals)
  end
  local runs, run = {}, nil   -- run: { idx = voiced result indices }
  for i = 1, n do
    if voiced[i] then
      if run then
        local last = run.idx[#run.idx]
        if i > last + 1 then
          local gap_s = results[i].time - results[last].time - hop
          local after = {}
          for j = i, n do
            if voiced[j] then after[#after + 1] = j end
            if #after > half_w then break end
          end
          local bridged = gap_s < SEG.BRIDGE_S and math.abs(
            side_pitch(run.idx, math.max(1, #run.idx - half_w), #run.idx) - side_pitch(after, 1, #after)) <= P.pitch_st
          if not bridged then run = nil end
        end
      end
      if not run then
        run = { idx = {} }
        runs[#runs + 1] = run
      end
      run.idx[#run.idx + 1] = i
    end
  end

  local segs = {}   -- { first, last (result indices), reason, run, voiced = result indices, pitch }
  for r, rn in ipairs(runs) do
    local idx, m = rn.idx, #rn.idx
    local first, last = idx[1], idx[m]

    -- 3. Median-filtered pitch of the run's voiced frames (working data; the frames keep their own pitch)
    local pf = {}
    for k = 1, m do
      local win = {}
      for q = math.max(1, k - half_w), math.min(m, k + half_w) do win[#win + 1] = results[idx[q]].note end
      pf[k] = median(win)
    end

    -- Cycle median: the median of pf over about one vibrato cycle (an unbiased centre for vibrato). The window is
    -- centred, shifted at the run's edges to stay full length; win_lo[k] is where it starts
    local cyc_w = math.min(m, 2 * math.max(1, math.floor(SEG.CYCLE_S / hop / 2 + 0.5)) + 1)
    local cyc_half = (cyc_w - 1) // 2
    local cyc, win_lo = {}, {}
    do
      local sorted, lo, hi = {}, 1, 0
      local function find(v)   -- the first position in `sorted` whose value is >= v
        local a, b = 1, #sorted
        while a <= b do
          local mid = (a + b) // 2
          if sorted[mid] < v then a = mid + 1 else b = mid - 1 end
        end
        return a
      end
      for k = 1, m do
        local want_lo = math.max(1, math.min(k - cyc_half, m - cyc_w + 1))
        local want_hi = want_lo + cyc_w - 1
        while hi < want_hi do hi = hi + 1; table.insert(sorted, find(pf[hi]), pf[hi]) end
        while lo < want_lo do table.remove(sorted, find(pf[lo])); lo = lo + 1 end
        local nc = #sorted
        cyc[k] = nc % 2 == 1 and sorted[(nc + 1) // 2] or (sorted[nc // 2] + sorted[nc // 2 + 1]) * 0.5
        win_lo[k] = want_lo
      end
    end

    -- 4. Pitch change: pf stays more than pitch_st from the note's centre, on one side, for hold_s, and has settled
    -- there (the cycle median in the middle of that stretch is more than pitch_st / 2 from the centre). The centre is
    -- the median of the note's cycle-median values so far (kept sorted), frozen while a departure lasts. A cycle-median
    -- window never reaches back before the note's start: near the start it is the note's first cycle
    local boundary = { [first] = "Onset" }
    local s, k = 1, 1
    -- The note's cycle-median values so far: the lower half in a max-heap (one more when odd), the upper half in a
    -- min-heap, so the median is at their tops
    local body_lo, body_hi, d, dir, head = {}, {}, nil, nil, nil
    local function note_cyc(q)
      if win_lo[q] >= s then return cyc[q] end
      if not head then
        local vals = {}
        for x = s, math.min(m, s + cyc_w - 1) do vals[#vals + 1] = pf[x] end
        head = median(vals)
      end
      return head
    end
    local function to_body(q)
      local v = note_cyc(q)
      if body_lo[1] and v > body_lo[1] then hpush(body_hi, v, lt) else hpush(body_lo, v, gt) end
      if #body_lo > #body_hi + 1 then hpush(body_hi, hpop(body_lo, gt), lt)
      elseif #body_hi > #body_lo then hpush(body_lo, hpop(body_hi, lt), gt) end
    end
    while k <= m do
      local split = false
      if #body_lo > 0 then
        local centre = #body_lo > #body_hi and body_lo[1] or (body_lo[1] + body_hi[1]) * 0.5
        local off = pf[k] - centre
        local away = math.abs(off) > P.pitch_st
        if d and not (away and (off > 0) == dir) then   -- came back (vibrato, a stray frame): part of the note
          for q = d, k - 1 do to_body(q) end
          d = nil
        end
        if away and not d then d, dir = k, off > 0 end
        if d and results[idx[k]].time - results[idx[d]].time >= P.hold_s
          and math.abs(note_cyc((d + k) // 2) - centre) > P.pitch_st / 2 then
          -- The new note starts where the pitch crossed halfway from the centre to the pitch it settled on
          local held = {}
          for q = d, k do held[#held + 1] = pf[q] end
          local settled = median(held)
          local half, sign = (centre + settled) * 0.5, settled - centre
          local function past(q) return (pf[q] - half) * sign >= 0 end
          local j = d
          if past(j) then
            while j - 1 > s and past(j - 1) do j = j - 1 end
          else
            while j < k and not past(j) do j = j + 1 end
          end
          boundary[idx[j]] = "Pitch change"
          s, k, body_lo, body_hi, d, head = j, j, {}, {}, nil, nil
          split = true
        end
      end
      if not split then
        if not d then to_body(k) end
        k = k + 1
      end
    end

    -- 5. Level dip: a frame dip_db below the highest level within DIP_REACH_S on each side (bridged frames count).
    -- Each stretch of such frames splits once, at its lowest frame (the middle one of equal lowest frames)
    local function side_max(step)   -- per frame, the highest level within reach before (step 1) or after (step -1) it
      local out, dq, h, tl = {}, {}, 1, 0
      local from, to = first, last
      if step < 0 then from, to = last, first end
      for i = from, to, step do
        if i ~= from then
          local q = i - step
          while tl >= h and db[dq[tl]] <= db[q] do tl = tl - 1 end
          tl = tl + 1
          dq[tl] = q
        end
        while tl >= h and math.abs(results[i].time - results[dq[h]].time) > SEG.DIP_REACH_S do h = h + 1 end
        if tl >= h then out[i] = db[dq[h]] end
      end
      return out
    end
    local left, right = side_max(1), side_max(-1)
    local i = first
    while i <= last do
      local function dip(q)
        return left[q] and right[q] and db[q] <= left[q] - P.dip_db and db[q] <= right[q] - P.dip_db
      end
      if dip(i) then
        local j = i
        while j + 1 <= last and dip(j + 1) do j = j + 1 end
        local low = math.huge
        for q = i, j do low = math.min(low, db[q]) end
        local ties = {}
        for q = i, j do if db[q] <= low + 1e-9 then ties[#ties + 1] = q end end
        local at = ties[(#ties + 1) // 2]
        if not boundary[at] then boundary[at] = "Level dip" end
        i = j + 1
      else
        i = i + 1
      end
    end

    -- Segments of this run, from its boundaries
    local starts = {}
    for at in pairs(boundary) do starts[#starts + 1] = at end
    table.sort(starts)
    local q = 1   -- idx and starts are both in order: one walk hands each voiced frame to its segment
    for b, at in ipairs(starts) do
      local seg = { first = at, last = (starts[b + 1] or last + 1) - 1, reason = boundary[at], run = r, voiced = {} }
      while q <= m and idx[q] < seg.first do q = q + 1 end
      while q <= m and idx[q] <= seg.last do
        seg.voiced[#seg.voiced + 1] = idx[q]
        q = q + 1
      end
      segs[#segs + 1] = seg
    end
    rn.pf = {}   -- filtered pitch by result index, for the merge below
    for x = 1, m do rn.pf[idx[x]] = pf[x] end
  end

  -- 6. A segment shorter than min_note_s joins the touching neighbour closer in pitch, or is dropped without one.
  -- The shortest goes first (the earliest of equally short ones). The segments are a linked list and the short ones
  -- sit in a heap keyed by (duration, order), so a merge only looks at its neighbours
  local function touching(a, b) return a and b and a.run == b.run end
  local function seg_dur(seg)
    local nxt = seg.nxt
    if #seg.voiced == 0 then return 0 end
    local stop = touching(seg, nxt) and #nxt.voiced > 0 and results[nxt.voiced[1]].time
      or results[seg.voiced[#seg.voiced]].time + hop
    return stop - results[seg.voiced[1]].time
  end
  local function pitch_of(seg)   -- the median of seg.sorted (its voiced frames' filtered pitch, in order)
    local v, c = seg.sorted, #seg.sorted
    if c == 0 then return nil end
    if c % 2 == 1 then return v[(c + 1) // 2] end
    return (v[c // 2] + v[c // 2 + 1]) * 0.5
  end
  local heap = {}
  local function before(x, y) return x.dur < y.dur or (x.dur == y.dur and x.seg.ord < y.seg.ord) end
  local function push(seg)   -- (re)queue seg when it is short; an older entry for it goes stale with seg.ver
    seg.ver = (seg.ver or 0) + 1
    local dur = seg_dur(seg)
    if dur < P.min_note_s then hpush(heap, { dur = dur, seg = seg, ver = seg.ver }, before) end
  end
  for x, seg in ipairs(segs) do
    seg.ord, seg.prv, seg.nxt = x, segs[x - 1], segs[x + 1]
    seg.sorted = {}
    for q, i in ipairs(seg.voiced) do seg.sorted[q] = runs[seg.run].pf[i] end
    table.sort(seg.sorted)
    seg.pitch = pitch_of(seg)
  end
  for _, seg in ipairs(segs) do push(seg) end
  local head = segs[1]
  while #heap > 0 do
    local e = hpop(heap, before)
    local seg = e.seg
    if not seg.gone and e.ver == seg.ver then
      local prev, nxt = seg.prv, seg.nxt
      if not touching(prev, seg) then prev = nil end
      if not touching(seg, nxt) then nxt = nil end
      local into = prev or nxt
      if prev and nxt and seg.pitch and nxt.pitch
        and (not prev.pitch or math.abs(nxt.pitch - seg.pitch) < math.abs(prev.pitch - seg.pitch)) then
        into = nxt
      end
      if into and into == prev then
        prev.last = seg.last
        for _, i in ipairs(seg.voiced) do prev.voiced[#prev.voiced + 1] = i end
      elseif into then   -- the next segment now starts where this one did, for the same reason
        nxt.first, nxt.reason = seg.first, seg.reason
        for _, i in ipairs(nxt.voiced) do seg.voiced[#seg.voiced + 1] = i end
        nxt.voiced = seg.voiced
      end
      if into then
        local sorted = into.sorted
        for _, v in ipairs(seg.sorted) do   -- insert after equal values: the same multiset as a fresh sort
          local lo, hi = 1, #sorted
          while lo <= hi do
            local mid = (lo + hi) // 2
            if sorted[mid] <= v then lo = mid + 1 else hi = mid - 1 end
          end
          table.insert(sorted, lo, v)
        end
        into.pitch = pitch_of(into)
      end
      -- Unlink seg; the durations that can change are those of the segments now on either side of the gap
      seg.gone = true
      if seg.prv then seg.prv.nxt = seg.nxt else head = seg.nxt end
      if seg.nxt then seg.nxt.prv = seg.prv end
      if seg.prv then push(seg.prv) end
      if seg.nxt then push(seg.nxt) end
    end
  end
  segs = {}
  local cur = head
  while cur do
    segs[#segs + 1] = cur
    cur = cur.nxt
  end

  -- Notes: start at the first voiced frame; end where the touching next note starts, else at the last voiced frame
  for x, seg in ipairs(segs) do
    local fr, sum = {}, 0
    for q, i in ipairs(seg.voiced) do
      fr[q] = results[i]
      sum = sum + results[i].note
    end
    local nxt = segs[x + 1]
    local note = {
      start_time = fr[1].time,
      end_time = touching(seg, nxt) and results[nxt.voiced[1]].time or fr[#fr].time,
      frames = fr, sum_note = sum, count = #fr,
    }
    notes[#notes + 1] = note
    split_points[#split_points + 1] = { time = note.start_time, reason = seg.reason }
  end
  return notes, split_points
end

--- The silence floor K.segment works out from `results` (dB; nil when no frame has a pitch): the item's loud level
--- (95th percentile of the pitched frames' levels) less K.SEG.SILENCE_DB. Pure.
K.segment_floor = function(results)
  local loud = {}
  for _, f in ipairs(results) do
    if f.note then loud[#loud + 1] = 20 * math.log(math.max(f.lvl or f.rms or 0, 1e-10), 10) end
  end
  if #loud == 0 then return nil end
  table.sort(loud)
  return loud[math.max(1, math.ceil(0.95 * #loud))] - K.SEG.SILENCE_DB
end

--- Re-split one stretch of the item: the frames of `results` with t0 <= time <= t1 are split at Separation `sep`
--- (K.segment); the notes of `old_notes` (time order) that start before t0 come first, unchanged (the same tables), then
--- the new notes, then the old notes that start at or after t1. old_split_points (optional) is merged the same way by
--- time. Returns notes, split_points, and the indices of the first and last new note (last < first: none); nil when
--- the stretch holds fewer than two frames. The silence floor is the whole item's (K.segment_floor), so the stretch
--- at the item's Separation splits as the item did. Pure: no REAPER calls, `results` and `old_notes` are not modified. The
--- caller carries edits over (K.resplit_match against the old notes inside the stretch).
K.segment_stretch = function(results, sep, old_notes, t0, t1, old_split_points)
  local sub = {}
  for _, f in ipairs(results) do
    if f.time >= t0 and f.time <= t1 then sub[#sub + 1] = f end
  end
  if #sub < 2 then return nil end
  local mid, mid_splits = K.segment(sub, sep, K.segment_floor(results))
  local notes, split_points = {}, {}
  for _, n in ipairs(old_notes) do
    if n.start_time < t0 then notes[#notes + 1] = n end
  end
  local first = #notes + 1
  for _, n in ipairs(mid) do notes[#notes + 1] = n end
  local last = #notes
  for _, n in ipairs(old_notes) do
    if n.start_time >= t1 then notes[#notes + 1] = n end
  end
  for _, sp in ipairs(old_split_points or {}) do
    if sp.time < t0 then split_points[#split_points + 1] = sp end
  end
  for _, sp in ipairs(mid_splits) do split_points[#split_points + 1] = sp end
  for _, sp in ipairs(old_split_points or {}) do
    if sp.time >= t1 then split_points[#split_points + 1] = sp end
  end
  return notes, split_points, first, last
end

--- Re-split: which new notes are old notes whose start and end did not move. pairs[new_index] = old_note when both
--- edges differ by at most tol_s (seconds; the caller passes one frame); each old note pairs at most once. lost =
--- how many old notes for which is_modified(old) is true are in no pair (their edits are dropped). Both lists are in
--- time order. Pure: no REAPER calls.
K.resplit_match = function(old_notes, new_notes, tol_s, is_modified)
  local tol = tol_s + 1e-9   -- frame times are sums of the hop: one frame apart may differ by a rounding error
  local pairs_, used, j = {}, {}, 1
  for i, nn in ipairs(new_notes) do
    -- Old notes that end before this note can start (within tol) cannot pair with it or with any later note
    while old_notes[j] and old_notes[j].end_time < nn.start_time - tol do j = j + 1 end
    local k = j
    while old_notes[k] and old_notes[k].start_time <= nn.start_time + tol do
      local o = old_notes[k]
      if not used[k] and math.abs(o.start_time - nn.start_time) <= tol and math.abs(o.end_time - nn.end_time) <= tol then
        pairs_[i], used[k] = o, true
        break
      end
      k = k + 1
    end
  end
  local lost = 0
  for k, o in ipairs(old_notes) do
    if not used[k] and is_modified(o) then lost = lost + 1 end
  end
  return pairs_, lost
end

local function run_hybrid_segmentation()
  -- Before the split, so the notes and their centres are made from the final frames: each voiced frame's period is
  -- chosen across the frames, then any short octave-off stretch that is left is put back
  K.pitch_track(state.results or {}, state.sample_rate)
  K.octave_fix(state.results or {})
  -- Both rewrite frames in place: the pitch range kept for drawing (K.results_range) starts over
  state.draw_cache.range.results = nil
  state.notes, state.split_points = K.segment(state.results or {}, state.separation)

  -- Anchor pitch
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
      min_freq = state.min_freq, max_freq = state.max_freq, auto_range = state.auto_range == true,
    }
    state.analysis_params = params
  end

  -- Work for one short slice, then yield to the window (the progress and Cancel stay responsive)
  local slice_start = reaper.time_precise()

  -- Only blocks that lie whole inside the item are read (K.block_fits)
  while K.block_fits(state.current_time, params, state.sample_rate, state.end_time) do
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
      local rms, freq, lvl, cands = yin_process_block(state.buffer, state.sample_rate, params)
      table.insert(state.results, K.analysis_frame(state.current_time, params, state.sample_rate, rms, freq, lvl, cands))
    end

    -- Advance time by hop size
    state.current_time = state.current_time + (params.hop_size / state.sample_rate)
  end

  if not K.block_fits(state.current_time, params, state.sample_rate, state.end_time) then
    -- The resync is paused while analysing: remember whether the project changed meanwhile so the
    -- next frame still picks up external changes (undo etc.) after this script's own writes.
    local external_change = (state.last_change_count ~= reaper.GetProjectStateChangeCount(0))

    reaper.DestroyAudioAccessor(state.accessor)
    state.accessor = nil
    state.is_analyzing = false
    state.analysis_params = nil
    state.progress = 1.0
    -- The developer switch: the frames as the detector left them, before the candidates are chosen from and dropped
    pcall(K.dev_dump, state.target_take_name, state.target_take_guid, params, state.sample_rate, state.results)
    run_hybrid_segmentation()
    state.analysis_empty = (not state.notes or #state.notes == 0)
    K.reset_view()   -- the new model is shown whole

    -- Store into multi-item session cache, then persist inside ONE named undo block
    if state.target_take_guid then
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
        scale_idx = state.scale_idx,
        separation = state.separation,
        analysis = params,   -- the frozen snapshot: the values this analysis ran with (K.ANALYSIS_KEYS)
      }
      -- Every new analysis starts at the defaults (K.item_seed); its Separation, Key and Scale are the state mirrors
      -- above (K.analysis_begin or, in a batch, K.batch_next put the default Separation; the Key and Scale are the
      -- item's own, or for a new item the ones last chosen: Auto (0) becomes a real key here)
      if not K.batch then K.item_carry_key(take_data, state.session_takes[state.target_take_guid]) end
      K.item_seed(take_data)
      if K.batch then
        -- A batch holds the model and writes every item in one undo block when it ends; this starts its next item.
        -- An item long enough to be read that gave no frame at all was not read (its media went away): it is not
        -- stored as "no pitched notes" over what the item had
        if #take_data.results == 0 and K.block_fits(0, params, state.sample_rate, state.end_time) then
          K.batch_item_failed(nil)
        else
          K.batch_item_done(take_data)
        end
        return
      end
      state.stale_takes[state.target_take_guid] = nil   -- a fresh analysis has no stale envelope
      state.session_takes[state.target_take_guid] = take_data
      -- The bar shows the analysed item's real key (Auto, 0, only while an item is not analysed)
      state.key_idx, state.scale_idx = take_data.key_idx, take_data.scale_idx
      update_scale_pitch_classes()
      -- The form follows: it now shows the values the item was analysed with ("as analyzed before"), so a later
      -- undo, which takes them away again, reseeds it from what the item holds then
      K.form_sync(state.target_take_guid, take_data)

      local found = false
      for _, g in ipairs(state.session_order) do
        if g == state.target_take_guid then found = true; break end
      end
      if not found then table.insert(state.session_order, state.target_take_guid) end

      -- Re-apply the envelope from the fresh (untouched) notes: this clears every stale point left by
      -- a previous analysis and writes the new model to the take inside the same "Analyze Pitch" block.
      -- The take's pitch mode is left alone, as for any analysis.
      -- An Auto analysis's track record is written inside the same block (K.track_records_flush); one that is not
      -- written with it is dropped below
      local run = K.auto_run
      if run and run.guid ~= state.target_take_guid then run = nil end
      if resolve_take_by_guid(state.target_take_guid, true) then
        if apply_envelope_to_take("Analyze Pitch", true, run ~= nil) then
          local reanalyzed = K.reanalyze_status_guid == state.target_take_guid
          local msg, kind = nil, nil
          if run and run.track then msg, kind = K.auto_run_status(run, take_data) end
          -- One message: the Auto one carries news, unless it only says the track's record was used again
          if msg and not (reanalyzed and kind == "used") then
            set_status(msg)
          elseif reanalyzed then
            set_status(string.format(K.REANALYZED_DEFAULTS_TEXT, K.MOD_LABEL))
          end
        end
      else
        state.missing_takes[state.target_take_guid] = true
      end
      K.reanalyze_status_guid = nil
    end
    if not K.batch then K.auto_drop() end   -- written above, or never: nothing waits for a later undo block
    if external_change then state.last_change_count = nil end
  elseif state.item_len > 0 then
    state.progress = state.current_time / state.item_len
  end
end

--- One frame of the running analysis (loop_body). In a batch, an error raised while an item is analysed does not
--- end the batch: that item is counted as failed (K.batch_item_failed) and the next one starts. An error raised
--- while the batch itself ended (its write) is not an item's: it is passed on to the window's error handling, which
--- also closes an undo block left open.
K.analysis_tick = function()
  if state.pre then   -- the pre-analysis runs before any analysis it leads to
    K.pre_step()
    return
  end
  if K.batch and K.batch.kind == "apply" then   -- an Apply to other items: no audio is read
    K.apply_tick()
    return
  end
  if not K.batch then
    process_analysis_step()
    return
  end
  -- A batch always has an item in progress. If something dropped the running analysis, that item counts as failed
  -- and the batch goes on: it must never sit there with nothing to do
  if not state.is_analyzing then
    -- Its stage 1 was dropped before any item started (the analysis was released): the batch ends, nothing written,
    -- rather than analysing its items without the ranges it was to find
    if K.batch.index == 0 then
      K.batch_finish(true)
      return
    end
    K.batch_item_failed(nil)
    return
  end
  local ok, err = xpcall(process_analysis_step, debug.traceback)
  if ok then return end
  if not K.batch then error(err, 0) end
  K.batch_item_failed(err)
end

-------------------------------------------------------------------------------
-- 5. GUI
-------------------------------------------------------------------------------

-- Press state of every param_drag control: [id] = { ctrl = Ctrl/Cmd held at press, dragged = mouse moved,
-- raw = the caller's value when the press began (K.drag_revert) }
local drag_state = {}

-- Whether the control param_drag drew last is under the pointer / being dragged or typed into, and whether its press
-- began this frame. esc_used: a drag was cancelled with Esc this frame, so that Esc is spent (HC5: the active edit is
-- innermost); the window's own Esc handling reads and clears it.
K.drag_hot = { hovered = false, active = false, activated = false, esc_used = false }

--- Report that the setting `key` is hovered (dragging = false) or being changed (true) this frame, so the canvas
--- shades where it acts. notes: nil for a top bar value (every note it reaches), or a set of note indices.
--- A drag is not replaced by a hover reported in the same frame.
K.setting_hint = function(hctx, key, dragging, notes)
  local frame = reaper.ImGui_GetFrameCount(hctx) or 0
  local h = state.setting_hint
  if h.frame == frame and h.dragging and not dragging then return end
  h.key, h.dragging, h.notes, h.frame = key, dragging, notes, frame
end

local function plural(n, one, many)
  return n == 1 and one or many
end

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
--- Returns changed, value, committed, reset, cancelled:
---   changed    the value moved (a drag frame, or a typed entry confirmed); value is clamped to [lo, hi]
---   committed  the edit is done: the drag was released after an edit, the typed entry was confirmed, or reset
---   reset      double-click: the caller restores its own default (the value returned is the input, untouched)
---   cancelled  HC5: the drag ended while the mouse button was still held (Esc): nothing is committed, and a caller
---              that wrote the value while it moved puts back the one from before the drag (K.drag_revert)
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
  local reset = reaper.ImGui_IsItemHovered(pctx) and reaper.ImGui_IsMouseDoubleClicked(pctx, 0) or false
  K.drag_hot.hovered = reaper.ImGui_IsItemHovered(pctx) == true
  K.drag_hot.active = reaper.ImGui_IsItemActive(pctx) == true
  K.drag_hot.held = K.drag_hot.active   -- the drag itself is held (active is also true while the typed entry is open)
  K.drag_hot.activated = reaper.ImGui_IsItemActivated(pctx) == true
  K.drag_hot.typed = false   -- true when the value returned was typed (not dragged)
  -- A mouse drag ends by itself only when the button comes up: ended with the button still held, it was cancelled
  -- (Esc clears ImGui's active item, which it also reports as an edit released)
  local cancelled = released and reaper.ImGui_IsMouseDown(pctx, 0) == true
  if cancelled then
    committed, reset = false, false
    K.drag_hot.esc_used = true
  end

  -- HC3: Ctrl/Cmd-click released without dragging opens the typed entry
  local popup = "###type_" .. id
  if released and st.ctrl and not st.dragged and not reset and not cancelled then
    reaper.ImGui_OpenPopup(pctx, popup)
  end
  if released or reset then st.ctrl = false end
  if reaper.ImGui_BeginPopup(pctx, popup) then
    -- HC5: Esc discards the entry; an active field handles it itself (below), this covers a lost focus
    if reaper.ImGui_Shortcut(pctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(pctx) end
    K.drag_hot.active = true   -- the typed entry is open: the value is being changed
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
      K.drag_hot.typed = true
      reaper.ImGui_CloseCurrentPopup(pctx)
    elseif ok or reaper.ImGui_IsItemDeactivated(pctx) then
      reaper.ImGui_CloseCurrentPopup(pctx)   -- Esc or a click elsewhere: the entry is discarded
    end
    reaper.ImGui_EndPopup(pctx)
  end

  if reset then return false, value, true, true, false end
  if cancelled then return false, value, false, false, true end
  return rv == true, v, committed, false, false
end

--- The range fill of a value control (the top bar and the note menu), drawn on the item just submitted: a track
--- along the bottom edge of the frame and, on it, the part from lo_frac to hi_frac (0..1 of the range) in `color`.
--- frame_w (optional): the width of the control's frame, for a control with its label drawn right of it (the item's
--- rectangle includes that label).
K.value_fill = function(vctx, lo_frac, hi_frac, color, frame_w)
  local x1, _ = reaper.ImGui_GetItemRectMin(vctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(vctx)
  if not (x1 and x2 and y2) then return end
  if frame_w then x2 = x1 + frame_w end
  K.value_track(reaper.ImGui_GetWindowDrawList(vctx), x1, x2, y2, lo_frac, hi_frac, color)
end

--- The track K.value_fill draws, on any draw list: along the bottom edge y2 of a box spanning x1 .. x2 (the value
--- controls, and the readout of a value drag on the canvas, so they all look the same).
K.value_track = function(dl, x1, x2, y2, lo_frac, hi_frac, color)
  local L = Theme.layout
  local w = x2 - x1
  local top = y2 - L.xs
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, top, x2, y2, Theme.get_palette().outline)
  lo_frac = math.max(0, math.min(1, lo_frac))
  hi_frac = math.max(lo_frac, math.min(1, hi_frac))
  local fx1, fx2 = x1 + w * lo_frac, x1 + w * hi_frac
  if lo_frac > 0 and fx2 - fx1 < L.xs then   -- a mixed range too narrow to see: keep a visible mark
    fx1 = math.max(x1, fx2 - L.xs)
  end
  if fx2 > fx1 then reaper.ImGui_DrawList_AddRectFilled(dl, fx1, top, fx2, y2, color) end
end

-- Parameter colours on the canvas (K.param_color): the wash of a highlighted span and of a hovered note zone
K.PARAM_WASH = { span = 0.26, zone = 0.27 }
--- The colour of the parameter `key`, the same wherever it shows: its value bar, its drag readout and its highlight
--- on the canvas.
K.PARAM_COLOR_KEYS = { tighten = "param_tighten", retune_speed = "param_strength", tolerance = "param_tolerance",
                       slide_in = "param_slide_in" }
K.param_color = function(key)
  local P = Theme.get_palette()
  return P.canvas[K.PARAM_COLOR_KEYS[key] or ""] or P.accent
end
--- The wash of the parameter `key` at `alpha` (a K.PARAM_WASH value): its palette hue itself, not the fitted edge
--- colour of K.param_color (fitted to contrast, that one can be far lighter or darker than the hue, and the note's
--- border and curves drawn over a wash of it would lose contrast).
K.PARAM_HUE_KEYS = { tighten = "green", retune_speed = "accent", tolerance = "yellow", slide_in = "orange" }
K.param_wash = function(key, alpha)
  local P = Theme.get_palette()
  return Theme.with_alpha(P[K.PARAM_HUE_KEYS[key] or ""] or P.accent, alpha)
end

--- For a param_drag caller that writes the value while it moves. Call right after param_drag with `raw`, the caller's
--- own value as it read it before drawing the control: it is remembered when the press begins, and returned when the
--- drag was cancelled (Esc) so the caller can put it back; nil otherwise. `raw` must not be nil.
K.drag_revert = function(id, raw, cancelled)
  local st = drag_state[id]
  if not st then return nil end
  if K.drag_hot.activated then st.raw = raw end
  if cancelled then return st.raw end
  return nil
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
--     plus, for the preview, everything the correction reads (K.correction_view compares it all each frame)
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
--- appended while an analysis runs, so each call looks only at the frames added since the last one (a different
--- table starts over, and so does the end of an analysis, which rewrites pitches: run_hybrid_segmentation).
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

--- The loudest frame (RMS) of `results`, for scaling the amplitude envelope drawn inside the notes; 0 when no
--- frame carries one (an analysis saved before the RMS was stored). Incremental, like K.results_range.
K.results_peak = function(results)
  local peak = state.draw_cache.peak
  local n = #results
  if peak.results ~= results or n < peak.n then
    peak.results, peak.n, peak.max = results, 0, 0
  end
  for i = peak.n + 1, n do
    local rms = results[i].rms
    if rms and rms > peak.max then peak.max = rms end
  end
  peak.n = n
  return peak.max
end

--- The waveform of the target item: its peaks from REAPER (the ones the arrange view draws), one maximum and one
--- minimum per 1 / rate seconds from the item's start, first channel. Returns the cache table (buf = reaper.array
--- holding `total` maxima then `total` minima, n = how many of each REAPER returned, rate = peaks per second,
--- peak = the largest absolute value, gen = counts the fetches), or nil while there is nothing to draw (no item,
--- peaks not built yet, a silent item): the caller then falls back to the loudness envelope of the analysis.
--- The peaks are fetched once per item and again only when something they depend on changed (another take, the
--- item's length, the take's start offset, play rate or source): that is looked at when the project state changed,
--- not on every frame.
K.take_wave = function(take, item)
  if not take or not item then return nil end
  local wv = state.draw_cache.wave
  if wv.take ~= take or wv.count ~= state.cache.count then
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0
    local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local src = reaper.GetMediaItemTake_Source(take)
    if wv.take ~= take or wv.len ~= len or wv.offs ~= offs or wv.playrate ~= playrate or wv.src ~= src then
      wv.take, wv.len, wv.offs, wv.playrate, wv.src = take, len, offs, playrate, src
      wv.n, wv.stale, wv.retry_at = 0, true, 0
    end
    wv.count = state.cache.count
  end

  if wv.stale and wv.len > 0 and reaper.time_precise() >= wv.retry_at then
    local total = math.max(1, math.min(K.WAVE_MAX_SAMPLES, math.ceil(wv.len * K.WAVE_RATE)))
    local rate = total / wv.len
    local buf = K.fit_array(wv.buf, total * 2)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
    -- One channel, no extra data. The return value's low 20 bits are the number of peaks written per block
    local ret = reaper.GetMediaItemTake_Peaks(take, rate, pos, 1, total, 0, buf)
    local got = math.min(total, (math.tointeger(ret) or 0) & 0xFFFFF)
    wv.buf = buf
    if got > 0 then
      local peak = 0
      for i = 1, got do
        local hi, lo = math.abs(buf[i]), math.abs(buf[total + i])
        if hi > peak then peak = hi end
        if lo > peak then peak = lo end
      end
      wv.n, wv.total, wv.rate, wv.peak = got, total, rate, peak
      wv.stale = false
      wv.gen = (wv.gen or 0) + 1
    else
      wv.n = 0
      wv.retry_at = reaper.time_precise() + K.WAVE_RETRY_S   -- the peaks are not built yet: ask again shortly
    end
  end

  if wv.n > 0 and wv.peak > 0 then return wv end
  return nil
end

--- The waveform of `note` between the screen positions x0 and x1 (the visible part of its block), as columns
--- WAVE_COL_PX wide: e.w_cols holds, per column, its x and the highest and lowest sample in it as fractions of the
--- item's peak (-1 .. 1), and e.w_n how many columns there are. Kept per note until the mapping, the block's
--- extent or the peaks change; the block's height is not part of it, so a pitch drag reuses it.
K.note_wave = function(note, wave, x0, x1, x_to_t)
  local dc = state.draw_cache
  local e = K.note_entry(note)
  if not (e.w_cols and e.w_gen == dc.gen and e.w_wave == wave.gen and e.w_x0 == x0 and e.w_x1 == x1) then
    local cols = e.w_cols or {}
    local buf, n, total, rate, peak = wave.buf, wave.n, wave.total, wave.rate, wave.peak
    local step = K.WAVE_COL_PX
    local count = 0
    local x = x0
    while x < x1 do
      -- The peaks this column covers (times are relative to the item's start, as the note times are)
      local i0 = math.floor(x_to_t(x) * rate) + 1
      local i1 = math.floor(x_to_t(math.min(x1, x + step)) * rate) + 1
      if i0 < 1 then i0 = 1 end
      if i1 > n then i1 = n end
      if i0 <= i1 then
        local hi, lo = buf[i0], buf[total + i0]
        for i = i0 + 1, i1 do
          local a, b = buf[i], buf[total + i]
          if a > hi then hi = a end
          if b < lo then lo = b end
        end
        local base = count * 3
        cols[base + 1], cols[base + 2], cols[base + 3] = x, hi / peak, lo / peak
        count = count + 1
      end
      x = x + step
    end
    e.w_cols, e.w_n, e.w_gen, e.w_wave, e.w_x0, e.w_x1 = cols, count, dc.gen, wave.gen, x0, x1
  end
  return e
end

--- The pitch range the notes need: the lowest and highest of every note's centre pitch (where it is now) and
--- original pitch (where its raw curve is), each +- half a semitone. has = false when there are no notes.
K.notes_pitch_fit = function(notes)
  local lo, hi = math.huge, -math.huge
  for _, note in ipairs(notes or {}) do
    local cp = note.controls and note.controls.center_pitch
    if cp then
      if cp - 0.5 < lo then lo = cp - 0.5 end
      if cp + 0.5 > hi then hi = cp + 0.5 end
    end
    local avg = note.avg_note
    if avg then
      if avg - 0.5 < lo then lo = avg - 0.5 end
      if avg + 0.5 > hi then hi = avg + 0.5 end
    end
  end
  if hi < lo then return false, 0, 0 end
  return true, lo, hi
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

--- The parts of the raw pitch trace that fall in a note's time span, as runs for DrawList_AddPolyline: arrs[1 .. count]
--- with owner[i] = the note of run i. A run starts one point before its note and ends one point after it, so that,
--- clipped to the note's block, the line reaches both edges. `notes` is in time order; notes_gen changes whenever a
--- note's extent does.
K.raw_trace_runs = function(results, r0, r1, t_to_x, notes, notes_gen)
  local dc = state.draw_cache
  local rr = dc.rruns
  if not rr then
    rr = { arrs = {}, owner = {}, count = 0, scratch = {} }
    dc.rruns = rr
  end
  if rr.gen == dc.gen and rr.ngen == notes_gen and rr.notes == notes and rr.results == results
      and rr.n == #results and rr.r0 == r0 and rr.r1 == r1 then
    return rr.arrs, rr.owner, rr.count
  end

  local m = dc.map
  local scratch = rr.scratch
  local count, len, cur, ni = 0, 0, nil, 1
  local last_x, last_y = nil, nil
  local function close_run()
    if cur and len >= 4 then
      count = count + 1
      local arr = K.fit_array(rr.arrs[count], len)
      for j = 1, len do arr[j] = scratch[j] end
      rr.arrs[count] = arr
      rr.owner[count] = cur
    end
    len = 0
  end
  for i = r0, r1 do
    local fr = results[i]
    if fr.note then
      local t = fr.time
      while notes[ni] and notes[ni].end_time < t do ni = ni + 1 end
      local nt = notes[ni]
      local owner = (nt ~= nil and t >= nt.start_time) and nt or nil
      local x, y = t_to_x(t), m.py + m.h - ((fr.note - m.min) / m.range) * m.h
      if owner ~= cur then
        if cur then
          scratch[len + 1], scratch[len + 2] = x, y   -- one point past the note
          len = len + 2
        end
        close_run()
        cur = owner
        if owner and last_x then
          scratch[1], scratch[2] = last_x, last_y   -- one point before the note
          len = 2
        end
      end
      if cur then
        scratch[len + 1], scratch[len + 2] = x, y
        len = len + 2
      end
      last_x, last_y = x, y
    end
  end
  close_run()
  for k = count + 1, #rr.owner do rr.owner[k] = nil end   -- no note is kept alive by a run that is gone

  rr.count, rr.gen, rr.ngen, rr.notes, rr.results, rr.n, rr.r0, rr.r1 = count, dc.gen, notes_gen, notes, results, #results, r0, r1
  return rr.arrs, rr.owner, count
end

--- Whether a note block overlaps the screen rectangle (x1, y1) .. (x2, y2). The other arguments are the canvas
--- mapping of this frame: time to x, and the note area's top, height, lowest pitch and pitch range.
K.note_under = function(notes, t_to_x, py, h, min_note, note_range, x1, y1, x2, y2)
  if not notes then return false end
  for _, note in ipairs(notes) do
    local cp = note.controls and note.controls.center_pitch
    if cp and t_to_x(note.end_time) > x1 and t_to_x(note.start_time) < x2 then
      local top = py + h - ((cp + 0.5 - min_note) / note_range) * h
      if top < y2 and top + h / note_range > y1 then return true end
    end
  end
  return false
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

--- Store v at sig[k]; true when that changed it.
K.sig_set = function(sig, k, v)
  if sig[k] ~= v then
    sig[k] = v
    return true
  end
  return false
end

--- The correction of `notes` for the canvas: K.correction_build's result with its points sorted by time, and a
--- gen that counts the rebuilds. It is rebuilt only when something the trajectory reads changed (every note's
--- extent, arrays and body, its Tighten, Tolerance, Slide In and effective Strength, its pitch points),
--- compared each frame without allocating; so a value dragged in the top bar shows on the next frame and a
--- frame that changed nothing rebuilds nothing. `item` gives the length the points are clamped to.
--- A note's mode and the item's Key and Scale also trigger a rebuild.
K.correction_view = function(notes, item)
  local dc = state.draw_cache
  local cv = dc.corr
  if not cv then
    cv = { sig = {}, n = 0, gen = 0 }
    dc.corr = cv
  end
  local sig, set = cv.sig, K.sig_set
  local k, changed = 1, set(cv.sig, 1, notes)
  for i = 1, #notes do
    local n = notes[i]
    local c = n.controls
    changed = set(sig, k + 1, n.start_time) or changed
    changed = set(sig, k + 2, n.end_time) or changed
    changed = set(sig, k + 3, n.frames) or changed
    changed = set(sig, k + 4, n.smooth) or changed
    changed = set(sig, k + 5, c and get_effective(n, "tighten") or 0) or changed
    changed = set(sig, k + 6, get_effective(n, "tolerance")) or changed
    changed = set(sig, k + 7, n.avg_note) or changed
    changed = set(sig, k + 8, (K.note_body(n))) or changed
    changed = set(sig, k + 9, c and c.bypassed or false) or changed
    changed = set(sig, k + 10, c and c.center_pitch) or changed
    changed = set(sig, k + 11, c and get_effective(n, "slide_in") or 0) or changed
    changed = set(sig, k + 12, get_effective(n, "retune_speed")) or changed
    -- An override that equals the inherited value still makes the note "edited"
    changed = set(sig, k + 13, is_note_modified(n)) or changed
    changed = set(sig, k + 14, n.points_rev or 0) or changed
    k = k + 14
    changed = set(sig, k + 1, K.mode_value(n)) or changed
    k = k + 1
  end
  local key_idx, scale_idx = K.item_scale()
  changed = set(sig, k + 1, key_idx) or changed
  changed = set(sig, k + 2, scale_idx) or changed
  k = k + 2
  if cv.n ~= k then
    cv.n = k
    changed = true
  end

  if changed or not cv.build then
    local item_len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or nil
    item_len = math.max(0.1, tonumber(item_len) or math.huge)
    local build = K.correction_build(notes, item_len)
    local pts = build.points
    for i = 1, #pts do pts[i].seq = i end
    table.sort(pts, function(p, q)
      if p.time ~= q.time then return p.time < q.time end
      return p.seq < q.seq
    end)
    cv.gen = cv.gen + 1
    build.gen = cv.gen
    cv.build = build
  end
  return cv.build
end

--- K.correction_view for the canvas, fetched at most once per frame (draw_graph's first caller fetches it, the
--- others reuse it); a write (apply_envelope_to_take) or other notes / item fetch it again.
K.frame_view_memo = { frame = nil, notes = nil, item = nil, build = nil }
K.frame_view = function(fctx, notes, item)
  local m = K.frame_view_memo
  local f = reaper.ImGui_GetFrameCount(fctx) or 0
  if m.frame ~= f or m.notes ~= notes or m.item ~= item or not m.build then
    m.frame, m.notes, m.item, m.build = f, notes, item, K.correction_view(notes, item)
  end
  return m.build
end

--- True when the pitch points of note n_idx are drawn: the layer is on and the note is the hovered one (`hovered`),
--- the one whose box holds the pointer (state.points_hover_note, see K.points_box_has), or a selected one.
K.points_shown = function(n_idx, hovered)
  return state.show_smart_spots and (hovered == n_idx or state.points_hover_note == n_idx
    or state.selected_note == n_idx or state.selected_notes[n_idx] == true)
end

--- True when the note's points can be hovered, grabbed and added to: a semitone row (row_h px) is at least
--- K.POINT_GRAB tall and its knots are on average at least K.POINT_GRAB apart across its block (block_w px).
--- Otherwise they are drawn at half size and the note behaves as if it had none.
K.points_live = function(note, row_h, block_w)
  local n = #K.points_knots(note)
  return row_h >= K.POINT_GRAB and (n < 2 or block_w / (n - 1) >= K.POINT_GRAB)
end

--- K.points_live for the note as the canvas maps it (t_to_x / pitch_to_y as in K.point_hit).
K.points_live_at = function(note, t_to_x, pitch_to_y)
  return K.points_live(note, pitch_to_y(0) - pitch_to_y(1), t_to_x(note.end_time) - t_to_x(note.start_time))
end

--- How far above and below a point at canvas y its grab area reaches: K.POINT_GRAB, but at most a quarter of the
--- note's block height where y lies inside the block (the block keeps half its height for its trim handles and zones).
K.point_reach_y = function(note, y, pitch_to_y)
  local cp = note.controls and note.controls.center_pitch
  if not cp then return K.POINT_GRAB end
  local top, bot = pitch_to_y(cp + 0.5), pitch_to_y(cp - 0.5)
  if y >= top and y <= bot then return math.min(K.POINT_GRAB, (bot - top) / 4) end
  return K.POINT_GRAB
end

--- True when (mx, my) lies inside the box around the note's block and the aim pitches of its points in view
--- (t0 .. t1), padded by K.POINT_GRAB: a dot above or below the block stays shown while the pointer goes to it.
K.points_box_has = function(note, mx, my, t0, t1, t_to_x, pitch_to_y, build)
  if not (note.controls and note.frames) then return false end
  local g = K.POINT_GRAB
  if mx < t_to_x(note.start_time) - g or mx > t_to_x(note.end_time) + g then return false end
  local cp = note.controls.center_pitch
  local y0, y1 = pitch_to_y(cp + 0.5), pitch_to_y(cp - 0.5)
  for _, k in ipairs(K.points_knots(note)) do
    local aim = (k.t >= t0 and k.t <= t1) and K.point_aim(note, k.frame, build) or nil
    if aim then
      local y = pitch_to_y(aim)
      y0, y1 = math.min(y0, y), math.max(y1, y)
    end
  end
  return my >= y0 - g and my <= y1 + g
end

--- The pitch a point aims for: the sung pitch at its frame plus the note's correction there. `build` is
--- K.correction_view's result; without one the note's frame_shifts are stale and count as 0. On a bypassed note
--- the sung pitch (its correction is not in effect). nil without a pitch.
K.point_aim = function(note, frame, build)
  local fr = note.frames and note.frames[frame]
  if not (fr and fr.note) then return nil end
  local bypassed = note.controls and note.controls.bypassed
  local shift = build and note.frame_shifts and not bypassed and note.frame_shifts[frame] or 0
  return fr.note + shift
end

--- The live pitch point (K.points_live) whose grab area holds (mx, my), nearest first: { note_idx, frame }, or nil.
--- A grab area reaches K.POINT_GRAB sideways but never past half the gap to a neighbouring knot, and up and down
--- as K.point_reach_y. Only the notes whose points are shown (K.points_shown, `hovered` = last frame's hovered note)
--- and the points inside the visible window t0 .. t1; bypassed notes only when `bypassed` is true, else none.
--- t_to_x / pitch_to_y map onto the canvas; build as in K.point_aim.
K.point_hit = function(notes, hovered, mx, my, t0, t1, t_to_x, pitch_to_y, build, bypassed)
  local best, best_d = nil, math.huge
  for n_idx, note in ipairs(notes) do
    local is_bypassed = (note.controls and note.controls.bypassed) and true or false
    if is_bypassed == (bypassed == true) and note.frames and K.points_shown(n_idx, hovered)
        and K.points_live_at(note, t_to_x, pitch_to_y) then
      local knots = K.points_knots(note)
      for j, k in ipairs(knots) do
        local aim = (k.t >= t0 and k.t <= t1) and K.point_aim(note, k.frame, build) or nil
        if aim then
          local x, y = t_to_x(k.t), pitch_to_y(aim)
          local reach_x = K.POINT_GRAB
          if knots[j - 1] then reach_x = math.min(reach_x, (x - t_to_x(knots[j - 1].t)) / 2) end
          if knots[j + 1] then reach_x = math.min(reach_x, (t_to_x(knots[j + 1].t) - x) / 2) end
          local dx, dy = math.abs(x - mx), math.abs(y - my)
          if dx <= reach_x and dy <= K.point_reach_y(note, y, pitch_to_y) and dx + dy < best_d then
            best, best_d = { note_idx = n_idx, frame = k.frame }, dx + dy
          end
        end
      end
    end
  end
  return best
end

--- Where a point may be added on `note` at time t (item seconds): the frame nearest to t, or nil and a reason:
--- "no_pitch" (that frame has no pitch) or "too_close" (fewer than K.POINT_MIN_GAP frames from a knot).
K.point_can_add = function(note, t)
  local frames = note.frames
  if not (note.controls and frames and #frames > 0) then return nil, "no_pitch" end
  local f = K.points_frame_at(frames, t)
  if not frames[f].note then return nil, "no_pitch" end
  for _, k in ipairs(K.points_knots(note)) do
    if math.abs(k.frame - f) < K.POINT_MIN_GAP then return nil, "too_close" end
  end
  return f
end

--- Add a point at 0 to `note` at the frame nearest to t (K.point_can_add): returns its knot, or nil and the reason.
--- No REAPER calls: the caller writes the change (apply_envelope_to_take).
K.point_add = function(note, t)
  local f, reason = K.point_can_add(note, t)
  if not f then return nil, reason end
  local ft = note.frames[f].time
  local list = note.controls.points or {}
  local pos = #list + 1
  for i, e in ipairs(list) do
    if e.t > ft then pos = i break end
  end
  table.insert(list, pos, { t = ft, st = 0, added = true })
  note.controls.points = list
  note.points_rev = (note.points_rev or 0) + 1
  return K.point_knot_at(note, f)
end

-- What a drag on a zone of a note block changes: K.ZONE_CONTROLS[zone][Shift held]. No entry = the pitch drag.
--   key      the note value (note.controls[key]); inherit = an unset value starts from the inherited one
--   lo, hi   its range; rows = a drag as tall as that many semitone rows sweeps it, or px = units per pixel
--   show     factor from the stored value to the shown one; read / hover = the drag readout and the hover tooltip
--   fine     Ctrl/Cmd-drag is fine adjust (HC2)
--   hint     the setting highlight the canvas shows while it is dragged (K.setting_hint)
-- Shift + drag anywhere on a note (every zone) adjusts Slide In.
K.ZONE_CONTROLS = {
  tighten = {
    [false] = { key = "tighten", lo = 0, hi = 1, rows = 2, show = 100, fine = true, inherit = true,
                read = "Tighten: %.0f%%", hover = "Tighten: %.0f%%", undo = "Adjust Tighten" },
  },
  pitch = {},
  tolerance = {
    [false] = { key = "tolerance", lo = 0, hi = 50, rows = 1, inherit = true, fine = true, hint = "tolerance",
                read = "Tolerance: %.0f\xC2\xA2", hover = "Tolerance: %.0f\xC2\xA2", undo = "Adjust Tolerance" },
  },
}
do
  local slide_in = { key = "slide_in", lo = 0, hi = 1, rows = 2, show = 100, fine = true, hint = "slide_in",
                     inherit = true,
                     read = "Slide In: %.0f%%", hover = "Slide In: %.0f%% (Shift+Drag)", undo = "Adjust Slide In" }
  for _, by_shift in pairs(K.ZONE_CONTROLS) do by_shift[true] = slide_in end
end
K.TOLERANCE_IDLE = " (not used yet: raise Tighten first)"   -- appended where a note's Tolerance is shown while its Tighten is 0
-- Appended where a value is shown on a note whose mode does not use it (K.zone_text): Tolerance and Slide In on a
-- Classic or Hard note, Tighten on a Hard one
K.MODE_IDLE = " (not used in Classic or Hard mode)"
K.HARD_IDLE = " (not used in Hard mode)"

--- The entry of K.ZONE_CONTROLS for a drag on `zone` with or without Shift, or nil (the pitch drag).
K.zone_control = function(zone, shift)
  local by_shift = K.ZONE_CONTROLS[zone]
  return by_shift and by_shift[shift and true or false] or nil
end

--- The value of `note` the zone control `zc` edits: its own, else the inherited one, else 0.
K.zone_value = function(zc, note)
  local v = note.controls[zc.key]
  if v == nil and zc.inherit then v = get_effective(note, zc.key) end
  return tonumber(v) or 0
end

--- The text for the value `zc` edits on `note`: the drag readout, or the hover tooltip (hover = true).
K.zone_text = function(zc, note, hover)
  local text = string.format(hover and zc.hover or zc.read, K.zone_value(zc, note) * (zc.show or 1))
  --- The note on why the value does nothing: in brackets on the drag readout's one line, its own paragraph (a
  --- sentence) in the hover tooltip
  local function idle(suffix)
    if not hover then return text .. suffix end
    local why = suffix:match("%((.*)%)") or suffix
    return K.tip(text, why:gsub("^%l", string.upper) .. ".")
  end
  local mode = K.mode_value(note)
  if mode ~= 0 then
    -- A Classic or Hard note: the mode says why a value does nothing (the Natural advice below does not apply)
    if zc.key == "tolerance" or zc.key == "slide_in" then return idle(K.MODE_IDLE) end
    if zc.key == "tighten" and mode == 2 then return idle(K.HARD_IDLE) end
    return text
  end
  if zc.key == "tolerance" and (tonumber(get_effective(note, "tighten")) or 0) <= 0 then
    return idle(K.TOLERANCE_IDLE)
  end
  return text
end

--- The drag zone of a note block spanning sx .. ex (px) at x: "tighten" (left quarter), "tolerance" (right quarter)
--- or "pitch", each side zone at least 12 px.
K.note_zone = function(x, sx, ex)
  local zone_w = math.max(12, (ex - sx) * 0.25)
  if x < sx + zone_w then return "tighten" elseif x > ex - zone_w then return "tolerance" end
  return "pitch"
end

--- Today's Ctrl/Cmd-click on note n_idx: toggle it in or out of the selection (an added note becomes the primary).
K.toggle_note_selection = function(n_idx)
  if state.selected_notes[n_idx] then
    state.selected_notes[n_idx] = nil
    if state.selected_note == n_idx then
      state.selected_note = next(state.selected_notes)
    end
  else
    state.selected_notes[n_idx] = true
    state.selected_note = n_idx
  end
end

--- Draw the pitch points of the notes whose points are shown (K.points_shown), each at its aim pitch (K.point_aim):
--- a circle for a detected point, a diamond for the start and end, a square for an added one (shape, not colour
--- alone); a moved point carries a 1 px stem from where it sits at 0, under the points. The hovered or dragged
--- point is drawn at the diamond size with a C.handle_hover outline. The points of a note that is not live
--- (K.points_live) are drawn at half size; a bypassed note's at the sung pitch without stems (its offsets are not in
--- effect). The add-square (state.point_ghost) is a C.spot outline the size of a dot. Arguments as for K.point_hit;
--- C = canvas palette.
K.draw_points = function(draw_list, C, notes, t0, t1, t_to_x, pitch_to_y, build)
  local pd, hp = state.point_drag, state.hovered_point
  local hot = pd or hp   -- the point with the hover look
  for n_idx, note in ipairs(notes) do
    if K.points_shown(n_idx, state.hovered_note) and note.frames then
      local knots = K.points_knots(note)
      local live = K.points_live_at(note, t_to_x, pitch_to_y)
      local bypassed = note.controls and note.controls.bypassed
      for pass = 1, 2 do   -- stems first, then the points over them
        for _, k in ipairs(knots) do
          local aim = (k.t >= t0 and k.t <= t1) and K.point_aim(note, k.frame, build) or nil
          if aim then
            local x, y = t_to_x(k.t), pitch_to_y(aim)
            local is_edge = (k.kind == "start" or k.kind == "end")
            local col = is_edge and C.anchor or C.spot
            if pass == 1 then
              if k.st ~= 0 and not bypassed then
                reaper.ImGui_DrawList_AddLine(draw_list, x, pitch_to_y(aim - k.st), x, y, col, 1.0)
              end
            else
              local is_hot = live and hot ~= nil and hot.note_idx == n_idx and hot.frame == k.frame
              local r = (is_hot or is_edge) and K.ANCHOR_R or K.SPOT_R
              if not live then r = r / 2 end
              if is_edge then
                reaper.ImGui_DrawList_AddQuadFilled(draw_list, x, y - r, x + r, y, x, y + r, x - r, y, col)
                if is_hot then reaper.ImGui_DrawList_AddQuad(draw_list, x, y - r, x + r, y, x, y + r, x - r, y, C.handle_hover, 1.5) end
              elseif k.kind == "added" then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, x - r, y - r, x + r, y + r, col)
                if is_hot then reaper.ImGui_DrawList_AddRect(draw_list, x - r, y - r, x + r, y + r, C.handle_hover, 0, 0, 1.5) end
              else
                reaper.ImGui_DrawList_AddCircleFilled(draw_list, x, y, r, col)
                if is_hot then reaper.ImGui_DrawList_AddCircle(draw_list, x, y, r, C.handle_hover, 0, 1.5) end
              end
            end
          end
        end
      end
    end
  end
  local pg = state.point_ghost   -- only while the pointer rests: never during a gesture
  local gesture = pd or state.drag or state.edge_drag or state.marquee or state.view_drag
  local pg_note = pg and not gesture and notes[pg.note_idx]
  local pg_fr = pg_note and pg_note.frames and pg_note.frames[pg.frame]
  local pg_aim = pg_fr and pg_fr.time >= t0 and pg_fr.time <= t1 and K.point_aim(pg_note, pg.frame, build)
  if pg_aim then
    local x, y, r = t_to_x(pg_fr.time), pitch_to_y(pg_aim), K.SPOT_R
    reaper.ImGui_DrawList_AddRect(draw_list, x - r, y - r, x + r, y + r, C.spot, 0, 0, 1.5)
  end
end

--- The corrected-pitch preview: the pitch trace plus the correction, over the frames r0 .. r1 of `results` that
--- lie in a corrected range of `build` (K.correction_view) and carry a pitch. Returns the lines (arrays for
--- DrawList_AddPolyline, one per corrected range in view) and how many there are. The correction at a frame
--- is read between the trajectory's points as a straight line, which is what the envelope holds there.
K.preview_lines = function(results, r0, r1, t_to_x, build)
  local dc = state.draw_cache
  local pl = dc.plines
  if not pl then
    pl = { arrs = {}, count = 0, scratch = {} }
    dc.plines = pl
  end
  if pl.gen == dc.gen and pl.bgen == build.gen and pl.results == results and pl.n == #results
      and pl.r0 == r0 and pl.r1 == r1 then
    return pl.arrs, pl.count
  end

  local pts, ranges = build.points, build.ranges
  local np = #pts
  local count = 0
  if np > 0 and #ranges > 0 then
    local m = dc.map
    local scratch = pl.scratch
    local len, run_range = 0, nil
    local ri, pi = 1, 1

    -- Close the run collected in scratch[1 .. len]: a line when it has two points or more
    local function close_run()
      if len >= 4 then
        count = count + 1
        local arr = K.fit_array(pl.arrs[count], len)
        for j = 1, len do arr[j] = scratch[j] end
        pl.arrs[count] = arr
      end
      len, run_range = 0, nil
    end

    for i = r0, r1 do
      local fr = results[i]
      local t = fr.time
      while ranges[ri] and ranges[ri].t1 < t do ri = ri + 1 end
      local rg = ranges[ri]
      -- A frame without a pitch adds no point and ends nothing: the line bridges it, as the pitch trace does
      if fr.note and rg and t >= rg.t0 then
        if run_range and run_range ~= rg then close_run() end
        run_range = rg
        while pi < np and pts[pi + 1].time <= t do pi = pi + 1 end
        local p0 = pts[pi]
        local shift = p0.val
        if t > p0.time and pi < np then
          local p1 = pts[pi + 1]
          local dt = p1.time - p0.time
          if dt > 0 then shift = p0.val + (p1.val - p0.val) * (t - p0.time) / dt end
        end
        scratch[len + 1] = t_to_x(t)
        scratch[len + 2] = m.py + m.h - ((fr.note + shift - m.min) / m.range) * m.h
        len = len + 2
      elseif fr.note and len > 0 then
        close_run()
      end
    end
    close_run()
  end

  pl.count, pl.gen, pl.bgen, pl.results, pl.n, pl.r0, pl.r1 = count, dc.gen, build.gen, results, #results, r0, r1
  return pl.arrs, count
end

-- Which spans of K.correction_build each setting shades (the joins and fades follow no setting)
K.HINT_KINDS = {
  slide_in = { scoop = true },
}

--- Shade where the hovered / dragged setting `hint` (state.setting_hint) acts, on the notes in view: an outline
--- on every note Strength reaches, the Tolerance band of each note, a span over each slide for Slide In.
--- A span is as tall as the block(s) of its note(s); one narrower than two pixels is a single edge line.
--- `build` is K.correction_view's result. Returns how many marks were drawn.
--- Also returns `skipped`: how many notes in view the value reaches that got no mark because they are Classic or
--- Hard (K.mode_value 1 or 2; for Tighten: Hard), 0 when a reached Natural note (Tighten: a non-Hard one) is in view.
K.draw_setting_hint = function(draw_list, hint, build)
  local m = state.draw_cache.map
  local notes, key, set = state.notes, hint.key, hint.notes
  if not (m.w and m.h and m.range and m.vt1 and m.vt1 > m.vt0 and m.range > 0) then return 0 end
  local x_min, x_max, y_min, y_max = m.px, m.px + m.w, m.py, m.py + m.h
  local pad = Theme.layout.xs
  local drawn = 0
  local skipped, natural = 0, 0
  -- The parameter's own colour: an opaque edge (K.param_color) and a wash of its hue (K.param_wash)
  local edge = K.param_color(key)
  local wash = K.param_wash(key, K.PARAM_WASH.span)

  -- The note takes the value that is being changed. edited_only: it must also be corrected (not bypassed)
  local function reached(idx, edited_only)
    local n = notes[idx]
    if not (n and n.controls) then return false end
    if set then return set[idx] ~= nil end
    if edited_only and not K.note_reached(n) then return false end
    return n.controls[key] == nil
  end
  -- A note in view the value reaches: is it one the mode leaves unmarked (counted in skipped) or a Natural one?
  local function tally(idx, skip)
    local n = notes[idx]
    if n.end_time >= m.vt0 and n.start_time <= m.vt1 and reached(idx, true) then
      if skip then skipped = skipped + 1 else natural = natural + 1 end
    end
  end
  local function t_x(t) return m.px + (t - m.vt0) / (m.vt1 - m.vt0) * m.w end
  local function block_y(idx)
    local cp = notes[idx].controls.center_pitch
    return m.py + m.h - ((cp + 0.5 - m.min) / m.range) * m.h, m.py + m.h - ((cp - 0.5 - m.min) / m.range) * m.h
  end

  if key == "retune_speed" then
    for idx = 1, #notes do
      local n = notes[idx]
      local skip = K.mode_value(n) ~= 0   -- a Classic or Hard note gets no outline
      tally(idx, skip)
      if not skip and n.end_time >= m.vt0 and n.start_time <= m.vt1 and reached(idx, true) then
        local top, bot = block_y(idx)
        if bot >= y_min and top <= y_max then
          reaper.ImGui_DrawList_AddRect(draw_list, math.max(x_min, t_x(n.start_time) - pad), math.max(y_min, top - pad),
            math.min(x_max, t_x(n.end_time) + pad), math.min(y_max, bot + pad), edge)
          drawn = drawn + 1
        end
      end
    end
    return drawn, natural == 0 and skipped or 0
  end

  if key == "tolerance" then
    -- The band a note may stray in untouched once tightened: centre - Tolerance .. centre + Tolerance across its block
    -- (shown at Tighten 0 too, so the band can be set before Tighten is raised)
    for idx = 1, #notes do
      local n = notes[idx]
      local skip = K.mode_value(n) ~= 0   -- a Classic or Hard note gets no band
      tally(idx, skip)
      if not skip and n.end_time >= m.vt0 and n.start_time <= m.vt1 and reached(idx, true) then
        local cp = n.controls.center_pitch
        local tol = (tonumber(get_effective(n, "tolerance")) or 0) / 100
        local top = m.py + m.h - ((cp + tol - m.min) / m.range) * m.h
        local bot = m.py + m.h - ((cp - tol - m.min) / m.range) * m.h
        local x0, x1 = math.max(x_min, t_x(n.start_time)), math.min(x_max, t_x(n.end_time))
        if bot >= y_min and top <= y_max and x1 > x0 then
          top, bot = math.max(y_min, top), math.min(y_max, bot)
          if bot - top >= 2 then reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, top, x1, bot, wash) end
          reaper.ImGui_DrawList_AddLine(draw_list, x0, top, x1, top, edge)
          reaper.ImGui_DrawList_AddLine(draw_list, x0, bot, x1, bot, edge)
          drawn = drawn + 1
        end
      end
    end
    return drawn, natural == 0 and skipped or 0
  end

  if key == "tighten" then
    -- No marks of its own (as for any key without K.HINT_KINDS); a Hard note does not use it at all
    for idx = 1, #notes do tally(idx, K.mode_value(notes[idx]) == 2) end
    return 0, natural == 0 and skipped or 0
  end

  if key == "slide_in" then
    -- A Classic or Hard note has no slide to shade
    for idx = 1, #notes do tally(idx, K.mode_value(notes[idx]) ~= 0) end
  end

  local kinds = K.HINT_KINDS[key]
  if not kinds then return 0 end
  for _, sp in ipairs(build.spans) do
    if kinds[sp.kind] and sp.t1 >= m.vt0 and sp.t0 <= m.vt1 then
      -- A slide belongs to the note it leads into
      local ok = reached(sp.a, true)
      if ok and K.mode_value(notes[sp.a]) ~= 0 then ok = false end
      if ok and notes[sp.a] and notes[sp.a].controls and (not sp.b or (notes[sp.b] and notes[sp.b].controls)) then
        local top, bot = block_y(sp.a)
        if sp.b then
          local top_b, bot_b = block_y(sp.b)
          top, bot = math.min(top, top_b), math.max(bot, bot_b)
        end
        top, bot = math.max(y_min, top), math.min(y_max, bot)
        local x0, x1 = t_x(math.min(sp.t0, sp.t1)), t_x(math.max(sp.t0, sp.t1))
        x0, x1 = math.max(x_min, x0), math.min(x_max, x1)
        if bot > top and x1 >= x0 then
          if x1 - x0 < 2 then
            local x = (x0 + x1) * 0.5
            reaper.ImGui_DrawList_AddLine(draw_list, x, top, x, bot, edge)
          else
            reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, top, x1, bot, wash)
            reaper.ImGui_DrawList_AddLine(draw_list, x0, top, x0, bot, edge)
            reaper.ImGui_DrawList_AddLine(draw_list, x1, top, x1, bot, edge)
          end
          drawn = drawn + 1
        end
      end
    end
  end
  return drawn, natural == 0 and skipped or 0
end

-------------------------------------------------------------------------------
-- NOTE ACTION BAR (Snap, Quantize, Cursor, Split, Merge, under the selected note)
-------------------------------------------------------------------------------

--- The beat ruler's steps at a zoom level. beat_px: the width of one beat; cml: beats in a bar; need: the room a
--- bar or beat label ("33.1") takes; need_sub: the room a part-beat label ("33.1.50") takes. Returns
---   bars: a label every this many bars (1 when beats or parts of a beat are labelled),
---   label_beats: the label spacing inside a bar in beats (1, 0.5, 0.25), or nil when only bar starts are labelled,
---   tick_beats: the tick spacing inside a bar in beats, or nil when no tick falls inside a bar,
---   bar_ticks: whether the bars between two labelled bars get a short tick.
K.ruler_beat_steps = function(beat_px, cml, need, need_sub)
  local min_px = K.RULER_MIN_TICK_PX
  -- The finest tick of `steps` (beats, finest first) that is still min_px wide, or `fallback`
  local function finest(steps, fallback)
    for _, step in ipairs(steps) do
      if beat_px * step >= min_px then return step end
    end
    return fallback
  end
  if beat_px * 0.25 >= need_sub then return 1, 0.25, finest({ 0.125 }, 0.25), false end
  if beat_px * 0.5 >= need_sub then return 1, 0.5, finest({ 0.125, 0.25 }, 0.5), false end
  if beat_px >= need then return 1, 1, finest({ 0.25, 0.5 }, 1), false end
  local bar_px = beat_px * math.max(cml, 1)
  local bars = 1
  while bars * bar_px < need and bars < K.RULER_MAX_BARS do bars = bars * 2 end
  if bars == 1 then return 1, nil, beat_px >= min_px and 1 or nil, false end
  return bars, nil, nil, bar_px >= min_px
end

--- The note action bar's anchor this frame (state.draw_cache.map is the mapping): the block of note `idx` as
--- { x = the middle of its visible part, top, bot } in pixels, or nil when the block is not in view (outside the
--- visible window, or not wholly between the ruler, ruler_h tall, and the bottom of the note area).
K.note_bar_anchor = function(idx, ruler_h)
  local m = state.draw_cache.map
  if not (m.w and m.h and m.range and m.vt1 and m.vt1 > m.vt0 and m.range > 0) then return nil end
  local note = state.notes and state.notes[idx]
  local cp = note and note.controls and note.controls.center_pitch
  if not cp or note.end_time <= m.vt0 or note.start_time >= m.vt1 then return nil end
  local function p_to_y(p) return m.py + m.h - ((p - m.min) / m.range) * m.h end
  local top, bot = p_to_y(cp + 0.5), p_to_y(cp - 0.5)
  if top < m.py + ruler_h or bot > m.py + m.h then return nil end
  local mid_t = (math.max(note.start_time, m.vt0) + math.min(note.end_time, m.vt1)) * 0.5
  local x = m.px + (mid_t - m.vt0) / (m.vt1 - m.vt0) * m.w
  return { x = x, top = top, bot = bot }
end

--- Top-left corner of the note action bar (bar_w x bar_h) for the anchor `a` (K.note_bar_anchor) and the user's
--- offset dx, dy: below the block with L.sm to spare, centred on it, moved by the offset. When that runs past
--- the bottom of the note area, above the block instead (the vertical offset mirrored); then kept inside the note
--- area, under the ruler (ruler_h) and L.xs from the sides. Also returns whether it went above.
K.note_bar_pos = function(a, bar_w, bar_h, ruler_h, dx, dy)
  local m = state.draw_cache.map
  local L = Theme.layout
  local y, above = a.bot + L.sm + dy, false
  if y + bar_h > m.py + m.h then y, above = a.top - L.sm - bar_h - dy, true end
  y = math.max(m.py + ruler_h, math.min(y, m.py + m.h - bar_h))
  local x = math.max(m.px + L.xs, math.min(a.x - bar_w * 0.5 + dx, m.px + m.w - L.xs - bar_w))
  return math.floor(x + 0.5), math.floor(y + 0.5), above
end

--- Draw the note action bar: a grip, the selection readout and K.NOTE_ACTIONS as icon buttons on a panel under the
--- primary selected note (placement: K.note_bar_anchor, K.note_bar_pos, moved by the grip's saved offset). Hidden
--- while notes, edges, Slide In or pitch points are dragged, during a box-select or a drag on a strip, while any popup
--- or modal is open, during an analysis, and when the anchor note is not in view; the caller leaves it out on a
--- bypassed take. has_target / target_item = the canvas's target. A disabled button shows its reason in the tooltip.
--- Returns true when it was drawn (it moved the layout cursor into the canvas).
-- The note action bar's sizes (Settings > Appearance): the icon drawn in each button, from the layout scale. Small is
-- the smallest that still reads (24 px buttons); Medium (the default) is 32 px and Large 40 px.
K.NOTE_BAR_SIZES = { "Small", "Medium", "Large" }
K.note_bar_icon_size = function()
  local L = Theme.layout
  local sizes = { L.xl, L.xxl, L.xxl + L.md }
  return sizes[state.note_bar_size] or sizes[DEFAULTS.note_bar_size]
end

--- True while the note action bar stays hidden whatever is selected (a drag, a box-select, a popup, an analysis).
K.note_bar_hidden = function(dctx)
  return state.is_analyzing or not state.notes or state.drag or state.edge_drag or state.point_drag
    or state.marquee or state.view_drag
    or reaper.ImGui_IsPopupOpen(dctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
end

--- Widths of the readout's two columns: the widest note name (every name, octaves -1 to 9) and the widest cents
--- value (-50 to +50), in the current font. A fixed slot, so the buttons never move as the value changes.
K.note_readout_widths = function(dctx)
  local key = reaper.ImGui_GetFontSize(dctx)
  local cache = K.readout_w_cache
  if cache and cache.key == key then return cache.name_w, cache.cents_w end
  local name_w, cents_w = 0, 0
  for midi = 0, 131 do
    name_w = math.max(name_w, (reaper.ImGui_CalcTextSize(dctx, midi_to_name(midi))))
  end
  for c = -50, 50 do
    local _, txt = K.note_name_cents(60 + c / 100)
    cents_w = math.max(cents_w, (reaper.ImGui_CalcTextSize(dctx, txt)))
  end
  K.readout_w_cache = { key = key, name_w = name_w, cents_w = cents_w }
  return name_w, cents_w
end

K.draw_note_bar = function(dctx, draw_list, ruler_h, has_target, target_item)
  if K.note_bar_hidden(dctx) then return false end
  local selected = {}
  for idx in pairs(state.selected_notes) do
    if state.notes[idx] then selected[#selected + 1] = idx end
  end
  if #selected == 0 and state.selected_note and state.notes[state.selected_note] then
    selected[1] = state.selected_note
  end
  if #selected == 0 then return false end
  -- Anchored on the primary note (the one clicked last); else on the first selected note in view
  local anchor = state.selected_notes[state.selected_note] and K.note_bar_anchor(state.selected_note, ruler_h)
  if not anchor then
    table.sort(selected)
    for _, idx in ipairs(selected) do
      anchor = K.note_bar_anchor(idx, ruler_h)
      if anchor then break end
    end
  end
  if not anchor then return false end

  local L = Theme.layout
  local P = Theme.get_palette()
  local preset = L.icon_md
  local icon_size = K.note_bar_icon_size()     -- Settings > Appearance; even Small is larger than the preset's icon
  local btn = icon_size + preset.pad * 2       -- Theme.icon_btn sizes the button from the icon (Small 24 px: MT1's target)
  local n = #K.NOTE_ACTIONS
  -- The readout: one note's name and cents, or the count of the selection (each note keeps its pill then)
  local name_txt, cents_txt, readout_tip
  local name_col, cents_col = P.canvas.readout_name, P.canvas.readout_name
  local one = #selected == 1 and state.notes[selected[1]].controls
  if one then
    name_txt, cents_txt, name_col, cents_col, readout_tip = K.note_readout(one.center_pitch, P.canvas)
  elseif #selected == 1 then
    name_txt, cents_txt = "", ""
  else
    name_txt, cents_txt = string.format("%d notes", #selected), ""
    readout_tip = K.tip(string.format("%d notes selected", #selected),
      "Select one note to see its pitch: its note name and how far from it in cents.")
  end
  local name_w, cents_w = K.note_readout_widths(dctx)
  local slot_w = math.max(name_w + L.sm + cents_w, (reaper.ImGui_CalcTextSize(dctx, name_txt)))
  local grip_w = math.floor(btn * 0.5)            -- the grip grows with the bar size: half a button wide
  local grip_seg = L.xs + grip_w + L.xs          -- the grip's own segment, closed by a full-height line
  local text_x0 = grip_seg + L.md                -- then the readout
  local lead_w = text_x0 + slot_w + L.md         -- ... then the divider before the buttons
  local bar_w = lead_w + L.sm + n * btn + (n - 1) * L.sm + L.xs
  local bar_h = btn + L.xs * 2
  local x, y, above = K.note_bar_pos(anchor, bar_w, bar_h, ruler_h, state.note_bar_dx, state.note_bar_dy)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + bar_w, y + bar_h, P.panel, L.rounding)
  reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + bar_w, y + bar_h, P.border, L.rounding, 0, L.border)
  local _, text_h = reaper.ImGui_CalcTextSize(dctx, name_txt)
  local text_y = math.floor(y + (bar_h - text_h) * 0.5 + 0.5)
  reaper.ImGui_DrawList_AddText(draw_list, x + text_x0, text_y, name_col, name_txt)
  if cents_txt ~= "" then
    local cw = reaper.ImGui_CalcTextSize(dctx, cents_txt)
    reaper.ImGui_DrawList_AddText(draw_list, x + text_x0 + slot_w - cw, text_y, cents_col, cents_txt)
  end
  -- The readout's hover area (from the grip's line to the divider before the buttons): its tooltip says what the
  -- name and cents are
  if readout_tip then
    reaper.ImGui_SetCursorScreenPos(dctx, x + grip_seg + L.border, y)
    reaper.ImGui_InvisibleButton(dctx, "##note_bar_readout", math.max(1, lead_w - grip_seg - L.border), bar_h)
    if reaper.ImGui_IsItemHovered(dctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(dctx, readout_tip)
    end
  end

  -- The grip: drag moves the bar (one offset for every note, saved on release); double-click puts it back
  -- (the whole segment, full height, is the handle)
  reaper.ImGui_SetCursorScreenPos(dctx, x, y)
  reaper.ImGui_InvisibleButton(dctx, "##note_bar_grip", grip_seg, bar_h)
  local grip_hot = reaper.ImGui_IsItemHovered(dctx) or reaper.ImGui_IsItemActive(dctx)
  if grip_hot then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x + L.border, y + L.border, x + grip_seg, y + bar_h - L.border,
      reaper.ImGui_IsItemActive(dctx) and P.btn_a or P.btn_h, L.rounding, reaper.ImGui_DrawFlags_RoundCornersLeft())
  end
  reaper.ImGui_DrawList_AddLine(draw_list, x + grip_seg, y, x + grip_seg, y + bar_h, P.border, L.border)
  if grip_hot then reaper.ImGui_SetMouseCursor(dctx, reaper.ImGui_MouseCursor_ResizeAll()) end
  local gmx, gmy = reaper.ImGui_GetMousePos(dctx)
  if reaper.ImGui_IsItemHovered(dctx) and reaper.ImGui_IsMouseDoubleClicked(dctx, 0) then
    state.note_bar_dx, state.note_bar_dy, state.note_bar_grip = 0, 0, nil
    K.save_settings("appearance")
  elseif reaper.ImGui_IsItemActivated(dctx) then
    state.note_bar_grip = { mx = gmx, my = gmy, dx = state.note_bar_dx, dy = state.note_bar_dy, above = above }
  elseif reaper.ImGui_IsItemActive(dctx) and state.note_bar_grip then
    local g, lim = state.note_bar_grip, K.NOTE_BAR_OFFSET_MAX
    state.note_bar_dx = math.max(-lim, math.min(lim, g.dx + gmx - g.mx))
    state.note_bar_dy = math.max(-lim, math.min(lim, g.dy + (g.above and -1 or 1) * (gmy - g.my)))
  end
  if reaper.ImGui_IsItemDeactivated(dctx) and state.note_bar_grip then
    state.note_bar_grip = nil
    K.save_settings("appearance")
  end
  if reaper.ImGui_IsItemHovered(dctx, reaper.ImGui_HoveredFlags_ForTooltip()) and not reaper.ImGui_IsItemActive(dctx) then
    Theme.tooltip(dctx, "Drag to move the bar.\n\nDouble-click: back under the note.")
  end
  local dot_col = grip_hot and P.text or P.text_dim
  local dot_r, dot_gap = btn / 22, btn / 5        -- 2 x 3 dots, in proportion to the button
  local dcx, dcy = x + grip_seg * 0.5, y + bar_h * 0.5
  for row = -1, 1 do
    for col = -1, 1, 2 do
      reaper.ImGui_DrawList_AddCircleFilled(draw_list, dcx + col * dot_gap * 0.5, dcy + row * dot_gap, dot_r, dot_col)
    end
  end
  local div_x = x + lead_w
  reaper.ImGui_DrawList_AddLine(draw_list, div_x, y + L.xs, div_x, y + bar_h - L.xs, P.border, L.border)

  local reason_of, sel_idx = K.note_actions_frame(has_target, target_item)
  local tip_flags = reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()
  reaper.ImGui_SetCursorScreenPos(dctx, div_x + L.sm, y + L.xs)
  for i, spec in ipairs(K.NOTE_ACTIONS) do
    if i > 1 then reaper.ImGui_SameLine(dctx, 0, L.sm) end
    local reason = reason_of(spec.id)
    reaper.ImGui_BeginDisabled(dctx, reason ~= nil)
    local clicked = Theme.icon_btn(dctx, "##note_bar_" .. spec.id, Theme.icons[spec.icon or spec.id],
      { preset = preset, icon_size = icon_size, color = reason and P.text_dim or nil })
    reaper.ImGui_EndDisabled(dctx)
    if reaper.ImGui_IsItemHovered(dctx, tip_flags) and not reaper.ImGui_IsItemActive(dctx) then
      Theme.tooltip(dctx, K.tip(spec.tip, reason))
    end
    if clicked and not reason then K.note_action(spec.id, sel_idx) end
  end
  state.note_bar_rect = { x, y, x + bar_w, y + bar_h }
  return true
end

-- The empty canvas's Analyze Item / Analyze All Selected Items button: the one thing to do there, so it is drawn
-- well above the large preset (header font, the 2x side and large top/bottom padding: about twice as tall)
-- accent: drawn as a solid accent face (Theme.toggle_button's "on" look: P.btn_on with P.on_text, fitted to 4.5:1 in
-- both theme modes, with its own hover and pressed shades) to draw the eye to it
K.ANALYZE_BTN = { pad_x = Theme.layout.xxl, pad_y = Theme.layout.lg, font = "header", accent = true }

--- The height of the Analyze button (its font's line plus its padding), measured in the context it is drawn in.
K.analyze_btn_h = function(draw_ctx)
  local var_count, pushed_font = Theme.push_button_preset(draw_ctx, fonts, K.ANALYZE_BTN)
  local frame_h = reaper.ImGui_GetFrameHeight(draw_ctx)
  Theme.pop_button_preset(draw_ctx, var_count, pushed_font)
  return frame_h
end

local function draw_graph(draw_ctx, w, h)
  local draw_list = reaper.ImGui_GetWindowDrawList(draw_ctx)
  local px, py = reaper.ImGui_GetCursorScreenPos(draw_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout
  local C = P.canvas   -- the canvas colours (Theme section 4A): rows, keys, notes, curves, pills; they follow the theme mode

  -- Claim canvas space and enable mouse interaction. A Button submitted later on top of it (the empty-state and
  -- BYPASSED actions, the note action bar) takes the hover where it sits, so the canvas allows itself to be overlapped.
  reaper.ImGui_SetNextItemAllowOverlap(draw_ctx)
  reaper.ImGui_InvisibleButton(draw_ctx, "##pitch_canvas", w, h)
  local is_canvas_hovered = reaper.ImGui_IsItemHovered(draw_ctx)
  local canvas_tip_ready = reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip())   -- the hover hint waits like every tooltip
  -- The note action bar owns the pointer where it was drawn: the overlap above hands the hover over only from the
  -- frame after the pointer reaches a button, so on that first frame a click would also reach the canvas (deselect,
  -- marquee, edit cursor). Every canvas gesture below is gated on is_canvas_hovered. The bar records itself again
  -- when it is drawn this frame.
  do
    local bar = state.note_bar_rect
    state.note_bar_rect = nil
    if bar and is_canvas_hovered then
      local bmx, bmy = reaper.ImGui_GetMousePos(draw_ctx)
      if bmx >= bar[1] and bmx < bar[3] and bmy >= bar[2] and bmy < bar[4] then
        is_canvas_hovered, canvas_tip_ready = false, false
      end
    end
  end

  -- Draw background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + h, P.bg)
  reaper.ImGui_DrawList_AddRect(draw_list, px, py, px + w, py + h, P.border)

  -- The canvas rectangle (full_px, py, full_w, full_h) is carved into the note-name column on the left, the note
  -- area (px, py, w, h: every time / pitch conversion below maps onto it), the pitch strip on the right and the
  -- overview strip along the bottom. The two strips come off w and h once there is something to show (see below).
  local line_h = reaper.ImGui_GetTextLineHeight(draw_ctx) or 0
  local piano_w = math.max(L.xxxl + L.md, (reaper.ImGui_CalcTextSize(draw_ctx, "G#-1") or 0) + L.sm * 2)
  local full_px = px
  local full_w = w
  local full_h = h
  px = px + piano_w
  w = w - piano_w

  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, full_px + full_w, py + h, true)

  local target_take, target_item = K.frame_target()
  local is_bypassed = is_take_pitch_bypassed(target_take)

  -- The one button the canvas draws (Analyze Item / Analyze All Selected Items, Open Settings, Enable): a real Button
  -- on the large preset, centred on cx with its top edge at y (its height is Theme.layout.btn_lg.h), hand cursor and tooltip.
  -- Returns true when it was clicked (never while it is disabled). It moves the layout cursor into the canvas:
  -- whoever used it calls restore_canvas_layout() before leaving draw_graph.
  -- preset: a Theme button preset table (default the large one); the Analyze button uses K.ANALYZE_BTN, the canvas's
  -- one call to action, and its height is K.analyze_btn_h(draw_ctx). min_w (optional): the width it takes at least
  local buttons_used = false
  local function canvas_button(label, id, cx, y, enabled, tip, narrow_label, preset, min_w)
    buttons_used = true
    preset = preset or L.btn_lg
    local var_count, pushed_font = Theme.push_button_preset(draw_ctx, fonts, preset)
    local btn_w = (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) + preset.pad_x * 2
    -- narrow_label: what the button reads when the canvas is narrower than its label (a narrow docker)
    if narrow_label and btn_w > full_w - L.sm * 2 then
      label = narrow_label
      btn_w = (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) + preset.pad_x * 2
    end
    if min_w and btn_w < min_w then btn_w = min_w end   -- as wide as what it sits under (the Analysis Settings form)
    reaper.ImGui_SetCursorScreenPos(draw_ctx, cx - btn_w * 0.5, y)
    if not enabled then reaper.ImGui_BeginDisabled(draw_ctx) end
    local clicked
    if preset.accent then
      -- The preset's padding and font are pushed above: only the colours come from the toggle's "on" look
      clicked = Theme.toggle_button(draw_ctx, id, label, true, { w = btn_w })
    else
      clicked = reaper.ImGui_Button(draw_ctx, label .. "###" .. id, btn_w, 0)
    end
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
      reaper.ImGui_Dummy(draw_ctx, full_w, full_h)
    end
  end

  -- Nothing to edit yet: not analysed (the instruction line, the "Analysis Settings" form, then Analyze Item as wide
  -- as the form), or analysed without finding a pitched note (title and hint, the form, Re-Analyze). The form takes
  -- one of three layouts by the room there is (K.form_layout): rows, stacked rows in a narrow canvas, or one summary
  -- line beside the button in a short one. The hint lines drop first when the height runs out, the last one first. While an
  -- analysis runs and has no frames yet the form stays in place, locked, showing the values it runs with
  -- (K.canvas_form), and the button is disabled; its first slice in state.results draws the pitch line instead.
  local form_canvas, no_notes = K.empty_canvas()
  if form_canvas then
    local cx = full_px + full_w * 0.5
    local cy = py + h * 0.5
    local gap = L.lg
    local avail_w = full_w - L.sm * 2
    local analyze_h = K.analyze_btn_h(draw_ctx)
    local _, text_h = reaper.ImGui_CalcTextSize(draw_ctx, "Ag")

    -- Above the form: the no-notes title and hint. Under the button: the hint lines (with two or more audio items
    -- selected in REAPER the button analyses them all, a batch, and the lines say what it will take)
    local peek, is_batch = nil, false
    local title, title_w, title_h, hint_rows, above_h = nil, 0, 0, {}, 0
    local shown = {}
    if no_notes then
      title = "No pitched notes found"
      local pushed_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)   -- measured in its font
      title_w, title_h = reaper.ImGui_CalcTextSize(draw_ctx, title)
      Theme.pop_font(draw_ctx, pushed_font)
      hint_rows = K.wrap_lines(draw_ctx, "Try another Vocal Range or Detection Mode.", avail_w)
      above_h = title_h + L.xs + #hint_rows * text_h + gap
    else
      peek = K.batch_peek(reaper.time_precise())
      is_batch = peek.n >= 2
      local first, second = K.batch_lines(peek, target_take ~= nil and state.target_take_name or nil)
      if is_batch then
        -- One line, fitted: the full list is its tooltip
        first = K.batch_names_fit(peek.names, avail_w,
          function(t) return (reaper.ImGui_CalcTextSize(draw_ctx, t)) or 0 end)
        shown[1] = { { text = first, w = (reaper.ImGui_CalcTextSize(draw_ctx, first)) or 0 } }
      else
        shown[1] = K.wrap_lines(draw_ctx, first, avail_w)
      end
      if second then shown[2] = K.wrap_lines(draw_ctx, second, avail_w) end
    end

    local form, reason = K.canvas_form(target_take ~= nil, is_batch)
    local layout, form_w, form_h, form_max_h = K.form_canvas_plan(avail_w, h - above_h, analyze_h + gap)
    if layout == "summary" and above_h + analyze_h > h then
      title, hint_rows, above_h = nil, {}, 0   -- a strip too short for the title: the button row only
    end
    local function block_h()
      local total = above_h + analyze_h + (layout == "summary" and 0 or form_h + gap)
      for i, rows in ipairs(shown) do
        total = total + (i == 1 and gap or L.xs) + #rows * text_h
      end
      return total
    end
    while #shown > 0 and block_h() > h do shown[#shown] = nil end
    local y = cy - block_h() * 0.5

    if title then
      local pushed_font = Theme.push_font(draw_ctx, fonts.large_bold or fonts.medium_bold)
      reaper.ImGui_DrawList_AddText(draw_list, cx - title_w * 0.5, y, P.text, title)
      Theme.pop_font(draw_ctx, pushed_font)
      local hy = y + title_h + L.xs
      for _, row in ipairs(hint_rows) do
        reaper.ImGui_DrawList_AddText(draw_list, cx - row.w * 0.5, hy, P.text_dim, row.text)
        hy = hy + text_h
      end
      y = y + above_h
    end

    local label, narrow_label, btn_id = "Re-Analyze", nil, "cv_reanalyze"
    if not no_notes then
      label, narrow_label, btn_id = K.batch_label(peek.n, false), K.batch_label(peek.n, true), "cv_analyze"
    end
    local can_analyze = (is_batch or target_take ~= nil) and not state.is_analyzing
    local tip = state.is_analyzing and "Analysis in progress"
      or (is_batch and K.batch_tip(peek.n))
      or (target_take ~= nil and "Detect the pitch of the selected audio item"
        or "Select an audio item in REAPER to analyze it.")

    -- The instruction (or what a batch will do) first, then the form, then the button as wide as the form: one
    -- column. The summary layout keeps its one row (summary, Change…, button) under the lines.
    for i, rows in ipairs(shown) do
      if i > 1 then y = y + L.xs end
      for _, row in ipairs(rows) do
        local x = cx - row.w * 0.5
        reaper.ImGui_DrawList_AddText(draw_list, x, y, P.text_dim, row.text)
        -- The batch line lists every selected item in its tooltip
        if i == 1 and is_batch and not K.window_modal_now and reaper.ImGui_IsWindowHovered(draw_ctx)
          and reaper.ImGui_IsMouseHoveringRect(draw_ctx, x, y, x + row.w, y + text_h) then
          Theme.tooltip(draw_ctx, K.batch_names_tip(peek.names))
        end
        y = y + text_h
      end
    end
    if #shown > 0 then y = y + gap end

    local btn_cx, btn_min_w = cx, nil
    if layout == "summary" then
      -- One row, centred: the summary line (shortened to the room left), Change…, the button
      local m = K.form_canvas_metrics()
      local btn_w = K.analyze_btn_w(draw_ctx, label)
      if narrow_label and btn_w > avail_w then
        label = narrow_label
        btn_w = K.analyze_btn_w(draw_ctx, label)
      end
      narrow_label = nil
      local sum_w = (reaper.ImGui_CalcTextSize(draw_ctx, K.FORM_COPY.summary .. K.form_summary(form.values))) or 0
      local text_w = math.min(sum_w, avail_w - btn_w - m.change_w - L.md * 2)
      if text_w < L.xxxl then text_w = 0 end   -- no room for a readable part of it: Change… still says where it is
      local row_w = (text_w > 0 and text_w + L.md or 0) + m.change_w + L.md + btn_w
      local x0 = cx - row_w * 0.5
      local used = K.form_summary_draw(form, x0, y, text_w, analyze_h, state.is_analyzing and K.locked_reason() or reason,
        is_batch)
      btn_cx = x0 + used + L.md + btn_w * 0.5
    else
      local drawn_h = K.form_canvas_draw(form, cx - form_w * 0.5, y, form_w, layout, reason, form_max_h)
      K.form_canvas_last = { layout = layout, adv = K.form_adv_open, h = drawn_h, scroll = form_max_h ~= nil }
      y = y + drawn_h + gap
      btn_min_w = form_w
    end

    if canvas_button(label, btn_id, btn_cx, y, can_analyze, tip, narrow_label, K.ANALYZE_BTN, btn_min_w) then
      if is_batch then K.batch_request(form.values) else start_analysis(form.values) end
    end

    -- The empty canvases carry their own centred message: the pill adds only a status message or the selection issue
    K.canvas_status(draw_list, full_px + L.sm, py + full_h - L.sm, full_w - L.sm * 2, false)
    restore_canvas_layout()
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end

  -- PITCH RANGE. The fit follows the notes (their centre and their original pitch), not every analysis frame: a
  -- stray octave error in the raw curve must not squeeze the melody into a third of the canvas. While there are no
  -- notes yet (an analysis in progress) the frames are all there is. ext_min .. ext_max is everything there is to
  -- see (the fit widened to the raw curve): the track of the pitch strip and the limit of a range the user chose.
  local has_frames, raw_min, raw_max = K.results_range(state.results)   -- cached, see K.results_range
  if not has_frames then
    K.canvas_status(draw_list, full_px + L.sm, py + full_h - L.sm, full_w - L.sm * 2, false)
    reaper.ImGui_DrawList_PopClipRect(draw_list)
    return
  end
  local has_fit, fit_min, fit_max = K.notes_pitch_fit(state.notes)
  if not has_fit then fit_min, fit_max = raw_min, raw_max end
  fit_min = math.floor(fit_min - K.PITCH_PAD_ST)
  fit_max = math.ceil(fit_max + K.PITCH_PAD_ST)
  if fit_max - fit_min < K.PITCH_MIN_FIT_ST then
    local grow = K.PITCH_MIN_FIT_ST - (fit_max - fit_min)
    fit_min = fit_min - grow // 2
    fit_max = fit_max + (grow - grow // 2)
  end
  local ext_min = math.min(fit_min, math.floor(raw_min - K.PITCH_PAD_ST))
  local ext_max = math.max(fit_max, math.ceil(raw_max + K.PITCH_PAD_ST))

  -- The range on screen: the fit, or the one the user chose (state.view_p0 / view_p1), kept inside the extent
  local min_note, max_note = fit_min, fit_max
  if state.view_p0 and state.view_p1 then
    local span = math.max(math.min(K.PITCH_MIN_VIEW_ST, ext_max - ext_min), math.min(ext_max - ext_min, state.view_p1 - state.view_p0))
    min_note = math.max(ext_min, math.min(ext_max - span, state.view_p0))
    max_note = min_note + span
  end
  local note_range = math.max(1, max_note - min_note)

  -- There is something to show: the strips take their room from the note area
  local ov_h = math.min(line_h * 2, h * 0.25)   -- overview strip (below the note area)
  local pv_w = L.xl                             -- pitch strip (right of the note area)
  h = h - ov_h
  w = w - pv_w

  local duration = state.end_time - state.start_time
  if duration <= 0 then duration = 1 end
  local px_per_st = h / note_range -- pixels per semitone

  -- A gesture keeps the pitch range it began with (view_min / view_max, stored when it starts): the range
  -- above follows every note, so a note dragged out of it would rescale the canvas under the cursor.
  -- After the release the range follows the notes again.
  local gesture = state.drag or state.edge_drag or state.marquee or state.point_drag
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

  -- The same for the pitch axis: show p0 .. p1 (semitones), never fewer than PITCH_MIN_VIEW_ST and never outside
  -- the extent. The range stays the user's until K.reset_view (F, a double-click on the pitch strip, a new model).
  local function set_pitch_view(p0, p1)
    local span = math.max(math.min(K.PITCH_MIN_VIEW_ST, ext_max - ext_min), math.min(ext_max - ext_min, p1 - p0))
    p0 = math.max(ext_min, math.min(ext_max - span, p0))
    state.view_p0, state.view_p1 = p0, p0 + span
    min_note, max_note = p0, p0 + span
    note_range = math.max(1, span)
    px_per_st = h / note_range
  end
  -- Back to the range fitted to the notes
  local function fit_pitch_view()
    state.view_p0, state.view_p1 = nil, nil
    min_note, max_note = fit_min, fit_max
    note_range = math.max(1, max_note - min_note)
    px_per_st = h / note_range
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

  -- The time ruler is an overlay along the top of the note area: it owns the pointer there. So do the overview
  -- strip (below the note area, the corner under the pitch strip included) and the pitch strip (right of it).
  local ruler_h = line_h + L.xs * 2
  local on_ruler = is_canvas_hovered and mx >= px and mx <= px + w and my >= py and my <= py + ruler_h
  local on_overview = is_canvas_hovered and my > py + h
  local on_pstrip = is_canvas_hovered and mx > px + w and my <= py + h

  if is_canvas_hovered and not gesture and not state.view_drag then
    -- Scrolling follows the axis the device sends: a vertical wheel scrolls the pitch axis, a horizontal one
    -- (trackpad, tilt wheel, a mouse's own horizontal-scroll button) scrolls the timeline (a no-op while the
    -- whole item is visible). Shift + wheel scrolls the timeline too: macOS already sends it as a horizontal
    -- wheel, elsewhere it is turned sideways here. Ctrl/Cmd + wheel zooms the timeline around the pointer and
    -- Alt + wheel zooms the pitch axis around it. Ignored during a gesture (the mapping must not change under
    -- it) and while the script window itself can scroll (the wheel belongs to it then).
    local wheel_y, wheel_x = reaper.ImGui_GetMouseWheel(draw_ctx)
    wheel_y, wheel_x = wheel_y or 0, wheel_x or 0
    if (reaper.ImGui_GetScrollMaxY(draw_ctx) or 0) > 0 then wheel_y, wheel_x = 0, 0 end
    local span = vt1 - vt0
    local wheel_mods = reaper.ImGui_GetKeyMods(draw_ctx) or 0
    if wheel_x == 0 and (wheel_mods & reaper.ImGui_Mod_Shift()) ~= 0 then wheel_y, wheel_x = 0, wheel_y end
    local notches = wheel_y ~= 0 and wheel_y or wheel_x   -- the zooms take either axis
    local _, scrub_item = K.frame_target()
    if notches ~= 0 and scrub_item and reaper.ImGui_IsKeyDown(draw_ctx, reaper.ImGui_Key_C())
       and not reaper.ImGui_IsAnyItemActive(draw_ctx) then
      -- Hold C + wheel: move the edit cursor (wheel up = later) by K.SCRUB_PX of the view per notch, Ctrl/Cmd =
      -- a fifth of that; kept inside the item, and playback follows as on the ruler
      local step = K.SCRUB_PX * span / math.max(w, 1)
      if (wheel_mods & reaper.ImGui_Mod_Ctrl()) ~= 0 then step = step / K.SCRUB_FINE end
      local item_pos = reaper.GetMediaItemInfo_Value(scrub_item, "D_POSITION")
      local t = reaper.GetCursorPosition() - item_pos + notches * step
      t = math.max(item_t0, math.min(t, item_t0 + duration))
      reaper.SetEditCurPos(item_pos + t, false, true)
    elseif notches ~= 0 and (wheel_mods & reaper.ImGui_Mod_Ctrl()) ~= 0 then
      local frac = math.max(0, math.min(1, (mx - px) / math.max(w, 1)))
      set_view(x_to_t(px + frac * w), frac, span / K.ZOOM_STEP ^ notches)
    elseif notches ~= 0 and (wheel_mods & reaper.ImGui_Mod_Alt()) ~= 0 then
      local frac = math.max(0, math.min(1, (py + h - my) / math.max(h, 1)))   -- 0 = bottom of the note area, 1 = top
      local anchor = min_note + frac * note_range
      local new_span = note_range / K.ZOOM_STEP ^ notches
      set_pitch_view(anchor - frac * new_span, anchor + (1 - frac) * new_span)
    else
      if wheel_y ~= 0 then
        local step = wheel_y * K.SCROLL_STEP * note_range   -- wheel up = higher notes
        set_pitch_view(min_note + step, max_note + step)
      end
      if wheel_x ~= 0 and span < duration - K.VIEW_EPS_S then
        set_view(vt0 - wheel_x * K.SCROLL_STEP * span, 0, span)   -- wheel left = earlier
      end
    end
    -- Double-click on the ruler shows the whole item again
    if on_ruler and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
      set_view(item_t0, 0, duration)
    elseif on_ruler and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
      -- Click on the ruler moves the edit cursor there, and playback follows it (as on REAPER's own ruler)
      local _, ruler_item = K.frame_target()
      if ruler_item then
        local item_pos = reaper.GetMediaItemInfo_Value(ruler_item, "D_POSITION")
        reaper.SetEditCurPos(item_pos + x_to_t(mx), false, true)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- OVERVIEW STRIP and PITCH STRIP: the one visible zoom / scroll control of each axis
  ---------------------------------------------------------------------------
  -- Each strip is a track (the whole item / the whole pitch extent) with a thumb marking what the note area shows.
  -- Dragging the thumb scrolls, dragging one of its ends zooms (the other end stays put), a double-click shows
  -- everything again (the whole item / the range fitted to the notes), and a press outside the thumb brings the
  -- window there. The thumbs are worked out again when they are drawn: a gesture below moves them.
  local pitch_ext = math.max(1, ext_max - ext_min)
  local function overview_thumb()   -- left x, right x
    return px + (vt0 - item_t0) / duration * w, px + (vt1 - item_t0) / duration * w
  end
  local function pitch_thumb()      -- top y, bottom y
    return py + (ext_max - max_note) / pitch_ext * h, py + (ext_max - min_note) / pitch_ext * h
  end

  if (on_overview or on_pstrip) and not is_bypassed and not gesture and not state.view_drag then
    local a0, a1, pos
    if on_overview then
      a0, a1 = overview_thumb()
      pos = math.max(px, math.min(px + w, mx))
    else
      a0, a1 = pitch_thumb()
      pos = my
    end
    local grab = math.min(K.VIEW_GRIP, (a1 - a0) * K.EDGE_GRAB_MAX_FRAC)
    local on_start = math.abs(pos - a0) <= grab   -- the thumb's left end / top end
    local on_end = math.abs(pos - a1) <= grab     -- its right end / bottom end
    if on_start or on_end then
      reaper.ImGui_SetMouseCursor(draw_ctx, on_overview and reaper.ImGui_MouseCursor_ResizeEW() or reaper.ImGui_MouseCursor_ResizeNS())
    else
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if canvas_tip_ready then
      Theme.tooltip(draw_ctx, on_overview and "Drag to scroll. Drag an end to zoom.\n\nDouble-click: whole item."
        or "Drag to scroll. Drag an end to zoom.\n\nDouble-click: fit the notes.")
    end

    if reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
      if on_overview then set_view(item_t0, 0, duration) else fit_pitch_view() end
    elseif reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
      flush_nudge_burst()   -- a new gesture starts: commit a pending arrow-key nudge first
      local kind = on_start and "0" or (on_end and "1" or "_pan")
      if kind == "_pan" and (pos < a0 or pos > a1) then
        -- Outside the thumb: the window is centred on the press, and the drag carries on from there
        if on_overview then
          local span = vt1 - vt0
          set_view(item_t0 + (pos - px) / math.max(w, 1) * duration - span * 0.5, 0, span)
        else
          local centre = ext_max - (pos - py) / math.max(h, 1) * pitch_ext
          set_pitch_view(centre - note_range * 0.5, centre + note_range * 0.5)
        end
      end
      if on_overview then
        state.view_drag = { kind = "t" .. kind, start = mx, a0 = vt0, a1 = vt1 }
      else
        -- p0 = the bottom end (the lowest pitch shown), p1 = the top end; the thumb's top is its "start"
        state.view_drag = { kind = "p" .. (kind == "0" and "1" or (kind == "1" and "0" or kind)), start = my, a0 = min_note, a1 = max_note }
      end
    end
  end

  if state.view_drag then
    local vd = state.view_drag
    if not reaper.ImGui_IsMouseDown(draw_ctx, 0) then
      state.view_drag = nil
    elseif vd.kind:sub(1, 1) == "t" then
      reaper.ImGui_SetMouseCursor(draw_ctx, vd.kind == "t_pan" and reaper.ImGui_MouseCursor_Hand() or reaper.ImGui_MouseCursor_ResizeEW())
      local dt = (mx - vd.start) / math.max(w, 1) * duration
      if vd.kind == "t_pan" then
        set_view(vd.a0 + dt, 0, vd.a1 - vd.a0)
      elseif vd.kind == "t0" then
        set_view(vd.a1, 1, vd.a1 - (vd.a0 + dt))   -- the right end stays where it is
      else
        set_view(vd.a0, 0, (vd.a1 + dt) - vd.a0)   -- the left end stays where it is
      end
    else
      reaper.ImGui_SetMouseCursor(draw_ctx, vd.kind == "p_pan" and reaper.ImGui_MouseCursor_Hand() or reaper.ImGui_MouseCursor_ResizeNS())
      local dp = -(my - vd.start) / math.max(h, 1) * pitch_ext   -- the strip runs downwards: down = lower notes
      local min_span = math.min(K.PITCH_MIN_VIEW_ST, pitch_ext)
      if vd.kind == "p_pan" then
        set_pitch_view(vd.a0 + dp, vd.a1 + dp)
      elseif vd.kind == "p1" then
        set_pitch_view(vd.a0, math.max(vd.a0 + min_span, math.min(ext_max, vd.a1 + dp)))   -- the bottom end stays
      else
        set_pitch_view(math.min(vd.a1 - min_span, math.max(ext_min, vd.a0 + dp)), vd.a1)   -- the top end stays
      end
    end
  end
  -- Nothing on a note is hovered, clicked or dragged from the ruler or a strip, nor while a strip is dragged
  local off_notes = on_ruler or on_overview or on_pstrip or state.view_drag ~= nil

  -- Text on a small panel-coloured pill (C.pill_bg), so it stays readable over any canvas surface (HC1): the text tokens
  -- (C.pill_text, C.marquee_text) are fitted to >= 4.5:1 on the pill over every row and every note fill. The pill
  -- is kept inside the note area (below the ruler); with flip_dx it moves to the left of x when it would run past the right edge.
  -- `big`: the drag readout's pill, in the large font with more padding, centred on y.
  local function pill_text(x, y, text, col, flip_dx, big, widest)
    local pushed = big and Theme.push_font(draw_ctx, fonts.large)
    local tw, th = reaper.ImGui_CalcTextSize(draw_ctx, text)
    -- widest (optional): the longest text this pill can show, so its width stays put while the value changes
    if widest then tw = math.max(tw, (reaper.ImGui_CalcTextSize(draw_ctx, widest))) end
    local pad_x, pad_y = L.sm, L.xs
    if big then pad_x, pad_y = L.md, L.sm end
    local pill_w, pill_h = tw + pad_x * 2, th + pad_y * 2
    if big then y = y - pill_h * 0.5 end
    if flip_dx and x + pill_w > px + w then x = x - pill_w - flip_dx end
    x = math.max(px, math.min(x, px + w - pill_w))
    y = math.max(py + ruler_h, math.min(y, py + h - pill_h))
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + pill_w, y + pill_h, C.pill_bg, L.rounding)
    reaper.ImGui_DrawList_AddText(draw_list, x + pad_x, y + pad_y, col, text)
    Theme.pop_font(draw_ctx, pushed)
    return x, y, pill_w, pill_h
  end

  --- True when `text` on a pill fits `room` pixels: the pill pill_text draws, plus the offset the zone labels start at.
  local function pill_fits(text, room)
    return (reaper.ImGui_CalcTextSize(draw_ctx, text)) + L.sm * 2 + L.xs <= room
  end

  -- Hit-test: find hovered note, zone, and edge handles
  local prev_edge = state.hovered_edge   -- the edge the pointer rested on last frame keeps a larger grab zone
  if is_canvas_hovered and not off_notes and not is_bypassed and not gesture and state.notes then
    local p_to_y = function(p) return py + h - ((p - min_note) / note_range) * h end
    local pt_build = state.show_smart_spots and K.frame_view(draw_ctx, state.notes, target_item) or nil
    -- The note whose points were shown by hover keeps them while the pointer stays in the box around its block
    -- and its points (so a dot above or below the block can be reached)
    local phn = state.points_hover_note
    if phn and not (state.notes[phn] and K.points_box_has(state.notes[phn], mx, my, vt0, vt1, t_to_x, p_to_y, pt_build)) then
      state.points_hover_note = nil
    end
    -- A live pitch point under the pointer (on last frame's hovered, box or selected notes) is found first. With
    -- Shift held no point is hovered and no add-square shown: a Shift press goes to the note beneath.
    local hover_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
    state.hovered_point = not hover_shift
      and K.point_hit(state.notes, state.hovered_note, mx, my, vt0, vt1, t_to_x, p_to_y, pt_build) or nil
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

        -- Check edge handles first (higher priority than zone hover); the note-name column is not part of the note
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
          state.hovered_zone = K.note_zone(mx, sx, ex)
          break
        end
      end
    end
    if state.hovered_point then
      state.points_hover_note = state.hovered_point.note_idx
    elseif state.hovered_note then
      state.points_hover_note = state.hovered_note
    end

    -- The hollow add-square: on a live note whose points are shown, no point and no edge under the pointer, the
    -- pointer within a point's reach of the pitch line at its nearest frame, and a point allowed there
    state.point_ghost = nil
    if not hover_shift and not state.hovered_point and not state.hovered_edge and state.show_smart_spots then
      local pt_t = x_to_t(mx)
      for n_idx, note in ipairs(state.notes) do
        if note.frames and pt_t >= note.start_time and pt_t <= note.end_time
            and not (note.controls and note.controls.bypassed) and K.points_shown(n_idx, state.hovered_note)
            and K.points_live_at(note, t_to_x, p_to_y) then
          local f = K.point_can_add(note, pt_t)
          local aim = f and K.point_aim(note, f, pt_build)
          if aim then
            local y = p_to_y(aim)
            if math.abs(y - my) <= K.point_reach_y(note, y, p_to_y) then
              state.point_ghost = { note_idx = n_idx, frame = f }
              break
            end
          end
        end
      end
    end

    -- The status says "zoom in" while the hovered note's points are too small to grab
    local zn = state.points_hover_note and state.notes[state.points_hover_note]
    state.points_zoom_hint = (state.show_smart_spots and zn and zn.frames and #zn.frames > 0
      and not (zn.controls and zn.controls.bypassed) and not K.points_live_at(zn, t_to_x, p_to_y)) and true or false

    -- Mouse cursor by what a drag here does: resize arrows on a pitch point, the edges and the pitch zone, a hand
    -- on the Tighten / Tolerance zones
    if state.hovered_point then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    elseif state.hovered_edge then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeEW())
    elseif state.hovered_zone == "pitch" then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    elseif state.hovered_zone == "tighten" or state.hovered_zone == "tolerance" then
      reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_Hand())
    end
    if state.hovered_zone == "tolerance" and state.hovered_note and not hover_shift and not state.hovered_point
        and not state.hovered_edge then
      local set = state.setting_hint.zone_set
      for k in pairs(set) do set[k] = nil end
      if state.selected_notes[state.hovered_note] then
        for idx in pairs(state.selected_notes) do set[idx] = true end
      else
        set[state.hovered_note] = true
      end
      K.setting_hint(draw_ctx, "tolerance", false, set)
    end
  elseif (not is_canvas_hovered or is_bypassed or off_notes) and not gesture then
    state.hovered_note = nil
    state.hovered_zone = nil
    state.hovered_edge = nil
    state.hovered_point = nil
    state.point_ghost = nil
    state.points_hover_note = nil
    state.points_zoom_hint = false
  end

  -- Click: select note (Shift/Cmd/Ctrl = multi-select), begin drag, edge drag, or marquee box select
  if is_canvas_hovered and not off_notes and not is_bypassed and reaper.ImGui_IsMouseClicked(draw_ctx, 0) then
    -- A new gesture starts: commit any pending arrow-key nudge as its own undo point first
    flush_nudge_burst()

    -- Resolve modifiers for selection modes (cross-platform macOS/Win/Linux)
    -- Cmd on macOS is Mod_Ctrl (MacOSXBehaviors); the Windows key / physical Ctrl are not treated as Ctrl
    local cur_mods = reaper.ImGui_GetKeyMods(draw_ctx) or 0
    local has_shift = (cur_mods & reaper.ImGui_Mod_Shift()) ~= 0
    local has_cmd_or_ctrl = (cur_mods & reaper.ImGui_Mod_Ctrl()) ~= 0

    local hp = state.hovered_point
    local hp_note = hp and state.notes and state.notes[hp.note_idx]
    local hp_knot = hp_note and K.point_knot_at(hp_note, hp.frame)
    local bp_select = nil   -- a bypassed note's point pressed with no note beneath: select that note, no drag
    if not hp_knot and not has_shift and state.notes then
      -- A press on a point of a bypassed note: say why it does not move, then handle the press as a press on the
      -- note block beneath, or, with none beneath, as a plain click on the point's note without a drag
      local bp = K.point_hit(state.notes, state.hovered_note, mx, my, vt0, vt1, t_to_x,
        function(p) return py + h - ((p - min_note) / note_range) * h end,
        state.show_smart_spots and K.frame_view(draw_ctx, state.notes, target_item) or nil, true)
      if bp then
        set_status("This note is bypassed, so its pitch points do nothing. Right-click the note to turn bypass off.")
        if not state.hovered_note and not state.hovered_edge then bp_select = bp.note_idx end
      end
    end
    -- A press on the add-square with no note block or edge beneath (the pitch line runs outside the block): no
    -- marquee, so neither press of the double-click that adds the point clears the selection or moves the edit
    -- cursor; the square's note is selected alone if it was not, so its points stay shown after the add
    local pg = state.point_ghost
    local pg_select = not bp_select and not hp_knot and not has_shift and pg and state.notes and state.notes[pg.note_idx]
      and not state.hovered_note and not state.hovered_edge and pg.note_idx or nil
    if bp_select then
      state.selected_note = bp_select
      state.selected_notes = { [bp_select] = true }
    elseif pg_select then
      if not state.selected_notes[pg_select] then
        state.selected_note = pg_select
        state.selected_notes = { [pg_select] = true }
      end
    elseif hp_knot and not has_shift then
      -- A press on a pitch point grabs the point (not the note beneath). A plain press selects its note alone unless
      -- it already was selected. Ctrl/Cmd = fine, and the selection is left as it is: a drag adds the note to it, a
      -- release without a drag is today's Ctrl/Cmd-click on the note under the pointer. A Shift press is left to the note.
      if not has_cmd_or_ctrl and not state.selected_notes[hp.note_idx] then
        state.selected_note = hp.note_idx
        state.selected_notes = { [hp.note_idx] = true }
      end
      state.point_drag = {
        note_idx = hp.note_idx,
        frame = hp.frame,
        start_st = hp_knot.st,
        st = hp_knot.st,
        last_y = my,      -- the press until the dead zone is passed, then the previous frame's pointer Y
        dirty = false,
        ctrl = has_cmd_or_ctrl or nil,                         -- pressed with Ctrl/Cmd
        under = has_cmd_or_ctrl and state.hovered_note or nil, -- the note under the pointer then
        view_min = min_note,   -- the pitch range stays as it is for the whole gesture
        view_max = max_note
      }
    elseif state.hovered_edge then
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
      -- Note click → update selection and prepare the drag of the zone under the pointer (K.ZONE_CONTROLS)
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
        K.toggle_note_selection(state.hovered_note)
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

      -- What each dragged note starts from: the value its zone changes (K.ZONE_CONTROLS), else its pitch.
      -- raw_values keeps what the note itself stored (false = nothing: it inherited), for Esc.
      local zone_ctl = K.zone_control(state.hovered_zone, state.shift_mode)
      local orig_values, raw_values = {}, {}
      for idx in pairs(state.selected_notes) do
        local n = state.notes[idx]
        if n and n.controls then
          orig_values[idx] = zone_ctl and K.zone_value(zone_ctl, n) or n.controls.center_pitch
          local raw = n.controls[zone_ctl and zone_ctl.key or "center_pitch"]
          raw_values[idx] = (raw ~= nil) and raw or false
        end
      end

      state.drag = {
        note_idx = state.hovered_note,
        zone = state.hovered_zone,
        shift_mode = state.shift_mode,
        start_mouse_y = my,
        last_y = my,      -- previous frame's pointer Y (pitch drag accumulates its movement per frame)
        pitch_st = 0,     -- semitones moved so far by a pitch drag (fine adjust scales each frame's share)
        acc = 0,          -- value units moved so far by a zone drag (K.ZONE_CONTROLS), accumulated the same way
        orig_values = orig_values,
        raw_values = raw_values,
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
      state.marquee = {
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
  if is_canvas_hovered and not off_notes and reaper.ImGui_IsMouseClicked(draw_ctx, 1) then
    local hp = state.hovered_point
    local hp_note = hp and state.notes[hp.note_idx]
    local hp_knot = hp_note and K.point_knot_at(hp_note, hp.frame)
    if hp_knot then
      -- A live point: its own menu, ahead of the note's
      if not state.selected_notes[hp.note_idx] then
        state.selected_note = hp.note_idx
        state.selected_notes = { [hp.note_idx] = true }
      end
      state.context_point = { note_idx = hp.note_idx, frame = hp.frame, start_st = hp_knot.st }
      reaper.ImGui_OpenPopup(draw_ctx, "##point_context_menu")
    elseif state.hovered_note and state.notes[state.hovered_note] then
      -- A right-click on a note that is already selected keeps the selection: Tighten and Tolerance in the menu
      -- write to every selected note
      if not state.selected_notes[state.hovered_note] then
        state.selected_note = state.hovered_note
        state.selected_notes = { [state.hovered_note] = true }
      end
      state.context_menu_note = state.hovered_note
      state.context_menu_time = x_to_t(mx)
      -- Whether the note's points can be added to at this zoom (the menu is drawn without the canvas mapping)
      state.context_menu_live = K.points_live_at(state.notes[state.hovered_note], t_to_x,
        function(p) return py + h - ((p - min_note) / note_range) * h end)
      reaper.ImGui_OpenPopup(draw_ctx, "##note_context_menu")
    end
  end

  -- HC5: Esc during a note drag puts every dragged note back to what it stored before and writes nothing
  if state.drag and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
    local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
    local key = zone_ctl and zone_ctl.key or "center_pitch"
    for idx, raw in pairs(state.drag.raw_values) do
      local n = state.notes[idx]
      if n and n.controls then
        if raw == false then n.controls[key] = nil else n.controls[key] = raw end
      end
    end
    state.drag = nil
    state.shift_mode = false
  end

  -- Process active drag (single-note or multi-note batch drag: pitch, or the zone's value)
  if state.drag then
    -- The cursor keeps the zone's meaning for the whole drag (pitch: vertical resize arrows, the others: a hand)
    reaper.ImGui_SetMouseCursor(draw_ctx, state.drag.zone == "pitch"
      and reaper.ImGui_MouseCursor_ResizeNS() or reaper.ImGui_MouseCursor_Hand())
    local delta_y = state.drag.start_mouse_y - my -- up = positive

    if math.abs(delta_y) > 2 then -- dead zone: click vs. drag
      state.drag.dirty = true
      state.drag.pending_single_select = nil -- drag occurred, cancel single-select collapse

      local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
      -- HC2: Cmd/Ctrl held (read every frame) = fine adjust. Each frame's pointer movement is scaled and
      -- accumulated, so pressing or releasing the modifier mid-drag never makes the value jump.
      local fine = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
      if zone_ctl then
        -- The canvas shades where the dragged value acts on the dragged notes
        if zone_ctl.hint then K.setting_hint(draw_ctx, zone_ctl.hint, true, state.drag.orig_values) end
        local per_px = zone_ctl.px or (zone_ctl.hi - zone_ctl.lo) / (px_per_st * zone_ctl.rows)
        state.drag.acc = state.drag.acc
          + (state.drag.last_y - my) * per_px * ((fine and zone_ctl.fine) and K.FINE_ADJUST_SCALE or 1)
        state.drag.last_y = my
        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            local v = math.max(zone_ctl.lo, math.min(zone_ctl.hi, orig_val + state.drag.acc))
            n.controls[zone_ctl.key] = v
          end
        end
      else
        -- The pitch drag. Snapping to a semitone stays on the S key and on double-click.
        state.drag.pitch_st = state.drag.pitch_st
          + (state.drag.last_y - my) / px_per_st * (fine and K.FINE_ADJUST_SCALE or 1)
        state.drag.last_y = my
        for idx, orig_val in pairs(state.drag.orig_values) do
          local n = state.notes[idx]
          if n and n.controls then
            n.controls.center_pitch = math.max(0, math.min(127, orig_val + state.drag.pitch_st))   -- MIDI range
          end
        end
      end
    end

    -- End drag → commit envelope to take or resolve single click
    if reaper.ImGui_IsMouseReleased(draw_ctx, 0) then
      if state.drag.dirty then
        local count = 0
        for _ in pairs(state.drag.orig_values) do count = count + 1 end
        -- Label follows the modifier x zone (K.ZONE_CONTROLS); the plain centre zone is the pitch drag
        local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
        local action_name = zone_ctl and zone_ctl.undo or "Pitch Shift"
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

  -- Process an active pitch point drag: vertical only, 1:1 with the pitch scale (Ctrl/Cmd = fine), written on release
  if state.point_drag then
    local pd = state.point_drag
    local pd_note = state.notes and state.notes[pd.note_idx]
    reaper.ImGui_SetMouseCursor(draw_ctx, reaper.ImGui_MouseCursor_ResizeNS())
    if not (pd_note and pd_note.frames and pd_note.frames[pd.frame]) then
      state.point_drag = nil   -- the model under it was replaced
    elseif reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      -- HC5: Esc during the drag puts the point back and writes nothing
      K.point_set(pd_note, K.point_knot_at(pd_note, pd.frame)
        or { frame = pd.frame, t = pd_note.frames[pd.frame].time, st = 0 }, pd.start_st)
      state.point_drag = nil
    else
      if not pd.dirty and math.abs(pd.last_y - my) > 2 then   -- dead zone: click vs. drag
        pd.dirty = true
        if pd.ctrl and not state.selected_notes[pd.note_idx] then   -- a Ctrl/Cmd drag adds the note to the selection
          state.selected_notes[pd.note_idx] = true
          state.selected_note = pd.note_idx
        end
      end
      if pd.dirty then
        local fine = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
        -- Accumulated unsnapped (held at the limit), so a slow fine drag is not snapped back to 0 frame by frame
        local st = math.max(-K.POINT_MAX_ST, math.min(K.POINT_MAX_ST,
          pd.st + (pd.last_y - my) / h * note_range * (fine and K.FINE_ADJUST_SCALE or 1)))
        pd.last_y = my
        if st ~= pd.st then
          pd.st = st
          -- A frame whose knot went away (a stored point moved back to 0) is set again from 0
          K.point_set(pd_note, K.point_knot_at(pd_note, pd.frame)
            or { frame = pd.frame, t = pd_note.frames[pd.frame].time, st = 0 }, st)
        end
      end
      if reaper.ImGui_IsMouseReleased(draw_ctx, 0) or not reaper.ImGui_IsMouseDown(draw_ctx, 0) then
        state.point_drag = nil
        if K.points_clamp(pd.st) ~= pd.start_st then apply_envelope_to_take("Move Pitch Point") end
        if pd.ctrl and not pd.dirty and pd.under and state.notes[pd.under] then K.toggle_note_selection(pd.under) end
      end
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
        local dropped = trim_note_edge(ed.note_idx, ed.edge, target_time)
        if dropped and dropped > 0 then
          set_status(string.format("Trimmed the note. %d pitch %s removed. %s+Z to undo",
            dropped, plural(dropped, "point outside it was", "points outside it were"), K.MOD_LABEL))
        end
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

  -- Process active marquee box select
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
  if not state.drag and not state.edge_drag and not state.point_drag and shortcuts_live and not is_bypassed and state.notes and #state.notes > 0 then
    local shift_mod = reaper.ImGui_Mod_Shift()
    local repeat_flag = reaper.ImGui_InputFlags_Repeat()

    -- Cmd/Ctrl + A: Select All notes
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

      -- S: Snap to nearest semitone (the status line reports it, as for the note action bar's Snap button)
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_S()) then
        K.note_action("snap")
      end

      -- Q: Quantize selected note(s) to active scale
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Q()) then
        K.note_action("quantize")
      end

      -- R / Backspace / Delete: Reset to [Untouched]
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_R())
        or reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Backspace())
        or reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Delete()) then
        reset_selected_note()
      end

      -- X: Split note at edit cursor position (outside the note it says so)
      if sel and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_X()) then
        K.note_action("split", state.selected_note)
      end
    end

    -- C: Edit cursor to the middle of the primary selected note (with none selected it says so). Held, the wheel
    -- moves the edit cursor (see the canvas's wheel handling).
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_C()) then
      K.note_action("cursor")
    end

    -- M: Merge selected notes (requires 2+ contiguous selected; with fewer it says so)
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_M()) then
      K.note_action("merge")
    end

    -- B: Toggle bypass on the selected notes (with none selected it says so)
    if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_B()) then
      K.note_action("bypass")
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

    -- F: the whole item again, with the pitch range fitted to the notes. Z: both axes zoom to the selected notes.
    -- Not during a marquee: the mapping must not change under a gesture. Both need exact modifiers, so
    -- Cmd/Ctrl+Z is left for forward_undo_to_reaper() in loop_body.
    if not gesture then
      if reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_F()) then
        set_view(item_t0, 0, duration)
        fit_pitch_view()
      elseif reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Z()) then
        local t_lo, t_hi, p_lo, p_hi = math.huge, -math.huge, math.huge, -math.huge
        local function include(idx)
          local n = state.notes[idx]
          if n and n.controls then
            t_lo, t_hi = math.min(t_lo, n.start_time), math.max(t_hi, n.end_time)
            p_lo, p_hi = math.min(p_lo, n.controls.center_pitch), math.max(p_hi, n.controls.center_pitch)
          end
        end
        for idx in pairs(state.selected_notes) do include(idx) end
        if state.selected_note then include(state.selected_note) end
        if t_hi > t_lo then
          local pad = math.max((t_hi - t_lo) * K.ZOOM_SEL_PAD, K.MIN_VIEW_SPAN_S * 0.5)
          set_view(t_lo - pad, 0, (t_hi - t_lo) + pad * 2)
          set_pitch_view(p_lo - K.ZOOM_SEL_PAD_ST, p_hi + K.ZOOM_SEL_PAD_ST)
        else
          set_status("Select a note to zoom to it")
        end
      end
    end

    -- Space is forwarded to the user's own REAPER binding by forward_space_to_reaper() in loop_body (HC6).
  end

  -- W: edit cursor to the start of the item (as REAPER's "Go to start of project"), playback follows, and a
  -- zoomed view scrolls back to the start. Navigation only, so it also works on a bypassed take.
  if not state.drag and not state.edge_drag and not state.point_drag and not gesture and shortcuts_live
    and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_W()) then
    local _, w_item = K.frame_target()
    if w_item then
      reaper.SetEditCurPos(reaper.GetMediaItemInfo_Value(w_item, "D_POSITION"), false, true)
      set_view(item_t0, 0, vt1 - vt0)
    end
  end

  -- Double-click: a pitch point back to 0, a point added on the add-square, else on the pitch zone: Snap to nearest
  -- semitone (single or batch). With Shift held the points are left alone, as for a press.
  if is_canvas_hovered and reaper.ImGui_IsMouseDoubleClicked(draw_ctx, 0) then
    local dc_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
    local hp = not dc_shift and state.hovered_point
    local hp_note = hp and state.notes and state.notes[hp.note_idx]
    local hp_knot = hp_note and K.point_knot_at(hp_note, hp.frame)
    local pg = not dc_shift and state.point_ghost
    local pg_note = pg and state.notes and state.notes[pg.note_idx]
    local pg_fr = pg_note and pg_note.frames and pg_note.frames[pg.frame]
    -- On a shown, live note: a double-click on the pitch line too close to a point does nothing (on the line the
    -- double-click belongs to the points), and one on a stretch without a pitch, off the pitch zone, says why
    -- nothing is added
    local no_pitch, line_busy = false, false
    if not dc_shift and not hp_knot and not pg_fr and state.notes and state.show_smart_spots then
      local p_to_y = function(p) return py + h - ((p - min_note) / note_range) * h end
      local pt_build = K.frame_view(draw_ctx, state.notes, target_item)
      local pt_t = x_to_t(mx)
      for n_idx, note in ipairs(state.notes) do
        if note.frames and #note.frames > 0 and pt_t >= note.start_time and pt_t <= note.end_time
            and not (note.controls and note.controls.bypassed) and K.points_shown(n_idx, state.hovered_note)
            and K.points_live_at(note, t_to_x, p_to_y) then
          local _, reason = K.point_can_add(note, pt_t)
          if reason == "too_close" then
            local aim = K.point_aim(note, K.points_frame_at(note.frames, pt_t), pt_build)
            local y = aim and p_to_y(aim)
            line_busy = y ~= nil and math.abs(y - my) <= K.point_reach_y(note, y, p_to_y)
          elseif reason == "no_pitch" then
            no_pitch = not (state.hovered_note == n_idx and state.hovered_zone == "pitch")
              and K.points_box_has(note, mx, my, vt0, vt1, t_to_x, p_to_y, pt_build)
          end
          break
        end
      end
    end
    if hp_knot then
      state.point_drag = nil   -- the press of this double-click grabbed the point: it is reset instead
      local was = hp_knot.st
      K.point_set(hp_note, hp_knot, 0)
      if was ~= 0 then apply_envelope_to_take("Reset Pitch Point") end
    elseif pg_fr then
      local knot, reason = K.point_add(pg_note, pg_fr.time)
      if knot then
        apply_envelope_to_take("Add Pitch Point")
      elseif reason == "no_pitch" then
        set_status("No pitch detected here: a point needs a pitch to sit on.")
      end
      state.point_ghost = nil
    elseif no_pitch then
      set_status("No pitch detected here: a point needs a pitch to sit on.")
    elseif not line_busy and state.hovered_note and state.hovered_zone == "pitch" then
      -- (line_busy: on the line too close to a point for another one, so nothing happens; the line is not the
      -- note's snap target)
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
  -- DRAW ROWS (two greys: in-key rows one grey, out-of-key rows a darker one, a hairline between rows)
  ---------------------------------------------------------------------------
  -- Everything from here to the playhead is clipped to the note area: the note-name column and the two strips
  -- are drawn after it, and a block that runs past the window's edge must not reach them.
  local root_pc = (state.key_idx - 1) % 12
  -- Key Auto (an item not analysed yet, e.g. while its analysis draws in): no scale yet, every row in key
  local is_chromatic = (SCALE_DEFINITIONS[state.scale_idx].name == "Chromatic") or state.key_idx == 0
  reaper.ImGui_DrawList_PushClipRect(draw_list, px, py, px + w, py + h, true)

  for n = math.floor(min_note), math.ceil(max_note) do
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local pc = (n % 12 + 12) % 12

    -- Two greys only: every in-key row (every row in Chromatic) is the same grey, an out-of-key row the dark one.
    -- Black and white keys are not told apart here, and no tint is laid over: a hairline separates the rows.
    local in_key = is_chromatic or is_pitch_in_scale(pc)
    local row_bg = in_key and C.row or C.row_dim

    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, key_top, px + w, key_bot, row_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, px, key_bot, px + w, key_bot, C.grid_plain)
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE BLOCKS (interactive, positioned by center_pitch)
  ---------------------------------------------------------------------------
  -- Labels are collected here and drawn after the curves (see NOTE LABELS): { x, top, bot, text }
  local labels = {}
  if state.show_note_blocks and state.notes then
    -- Inside the blocks: the item's real waveform (its peaks from REAPER), or, while those are not available, the
    -- loudness envelope of the analysis, scaled by its loudest frame
    local wave = K.take_wave(target_take, target_item)
    local peak_rms = (not wave) and K.results_peak(state.results) or 0
    local selected_n = 0
    for _ in pairs(state.selected_notes) do selected_n = selected_n + 1 end
    local label_all_selected = selected_n <= K.LABEL_MAX_SELECTED
    for n_idx, note in ipairs(state.notes) do
      -- Only blocks that reach the visible window are drawn
      if note.controls and note.end_time >= vt0 and note.start_time <= vt1 then
        local cp = note.controls.center_pitch
        local sx = t_to_x(note.start_time)
        local ex = t_to_x(note.end_time)
        local top_y = py + h - ((cp + 0.5 - min_note) / note_range) * h
        local bot_y = py + h - ((cp - 0.5 - min_note) / note_range) * h
        local block_w = ex - sx
        local zone_w = math.max(12, block_w * 0.25)

        local is_selected = state.selected_notes[n_idx] or false
        local is_hov = (state.hovered_note == n_idx)
        local is_mod = is_note_modified(note)

        local is_bypassed_note = note.controls.bypassed or false
        local fill
        local border
        if is_bypassed_note then
          fill = C.note_bypassed
          border = C.note_bypassed_border
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
        if is_hov and not state.drag and not state.point_drag and not state.hovered_point then
          local has_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0

          if has_shift then
            -- Shift + drag anywhere on the note adjusts Slide In: the whole block is its zone
            reaper.ImGui_DrawList_AddRectFilled(draw_list, sx, top_y, ex, bot_y,
              K.param_wash("slide_in", K.PARAM_WASH.zone))
          elseif state.hovered_zone == "tighten" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, sx + zone_w, bot_y, K.param_wash("tighten", K.PARAM_WASH.zone))
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx + zone_w, top_y, ex, bot_y, fill)
          elseif state.hovered_zone == "tolerance" then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex - zone_w, bot_y, fill)
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              ex - zone_w, top_y, ex, bot_y, K.param_wash("tolerance", K.PARAM_WASH.zone))
          else -- pitch zone
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              sx, top_y, ex, bot_y, fill)
          end

          if has_shift and block_w > 40 and pill_fits(PARAM_LABELS.slide_in, block_w) then
            -- The name sits on a pill: the text over the amber highlight alone is not enough (the hover hint names
            -- it at any width)
            local text_y = top_y + (bot_y - top_y) * 0.5 - 6
            pill_text(sx + 2, text_y, PARAM_LABELS.slide_in, C.pill_text)
          end
        else
          reaper.ImGui_DrawList_AddRectFilled(draw_list,
            sx, top_y, ex, bot_y, fill, L.xs)
        end

        -- The waveform inside the block (C.note_wave), around the block's centre line: the item's own audio between
        -- the note's start and end, scaled so the loudest sample of the item just fills a block. It is linear: a
        -- quiet note looks quiet.
        local wave_half = (bot_y - top_y) * 0.5 - L.xs
        local mid_y = (top_y + bot_y) * 0.5
        if wave and wave_half >= 1 and not is_bypassed_note then
          local wave_x0, wave_x1 = math.max(sx, px), math.min(ex, px + w)
          if wave_x1 > wave_x0 then
            local cols = K.note_wave(note, wave, wave_x0, wave_x1, x_to_t)   -- cached, see K.note_wave
            local col_w = K.WAVE_COL_PX
            local c = cols.w_cols
            for k = 0, cols.w_n - 1 do
              local col_x = c[k * 3 + 1]
              local y0 = mid_y - c[k * 3 + 2] * wave_half
              local y1 = mid_y - c[k * 3 + 3] * wave_half
              if y1 - y0 < 1 then   -- silence is a hairline, not a gap
                local centre = (y0 + y1) * 0.5
                y0, y1 = centre - 0.5, centre + 0.5
              end
              reaper.ImGui_DrawList_AddRectFilled(draw_list, col_x, y0, col_x + col_w, y1, C.note_wave)
            end
          end
        -- Fallback while REAPER has no peaks for the item: the loudness (RMS) of the analysis frames, as mirrored bars.
        -- One bar per frame, or per few frames when they are closer than WAVE_STEP_PX; an analysis saved without the
        -- RMS draws none. It shows where the note is loud, not the audio itself.
        elseif peak_rms > 0 and wave_half >= 1 and note.frames and not is_bypassed_note then
          local wf0, wf1 = visible_range(note.frames)
          if wf1 > wf0 then
            local wave_w = t_to_x(note.frames[wf1].time) - t_to_x(note.frames[wf0].time)
            local stride = math.max(1, math.ceil(K.WAVE_STEP_PX * (wf1 - wf0) / math.max(wave_w, 1)))
            local i = wf0
            while i < wf1 do
              local j = math.min(wf1, i + stride)
              local rms = 0
              for k = i, j - 1 do
                local frame_rms = note.frames[k].rms
                if frame_rms and frame_rms > rms then rms = frame_rms end
              end
              local amp = wave_half * math.sqrt(math.min(1, rms / peak_rms))
              local bar_x0 = math.max(sx, t_to_x(note.frames[i].time))
              local bar_x1 = math.min(ex, t_to_x(note.frames[j].time))
              if amp >= 0.5 and bar_x1 > bar_x0 then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, bar_x0, mid_y - amp, bar_x1, mid_y + amp, C.note_wave)
              end
              i = j
            end
          end
        end

        -- Border (thicker for selected notes)
        reaper.ImGui_DrawList_AddRect(draw_list,
          sx, top_y, ex, bot_y, border, L.xs, 0, is_selected and 2.0 or 1.0)

        if is_bypassed_note then
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
          local handle_w = 3
          local left_handle_col = C.handle
          local right_handle_col = C.handle

          -- Brighten the hovered edge
          if state.hovered_edge and state.hovered_edge.note_idx == n_idx and not state.hovered_point then
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

        -- An edited note also carries a small square (C.note_edit_mark) in its top-left corner (not green alone)
        if is_mod then
          local mark_x = math.max(sx, px) + L.sm   -- stays visible while the block runs past the left edge
          local mark = math.min(K.EDIT_MARK, bot_y - top_y - L.xs * 2, block_w - L.sm * 2)
          if mark >= L.xs then
            reaper.ImGui_DrawList_AddRectFilled(draw_list, mark_x, top_y + L.xs, mark_x + mark, top_y + L.xs + mark, C.note_edit_mark)
          end
        end

        -- Note label (name + cents deviation): only for the hovered note and the selected ones, on a pill beside the
        -- block (drawn after the curves). The row already names the pitch of every other note. A selection larger than
        -- LABEL_MAX_SELECTED labels its primary note alone; the note a pitch drag holds reads the same in the drag readout.
        local held = state.drag and state.drag.dirty and state.drag.zone == "pitch"
          and state.drag.note_idx == n_idx
        if not held and (is_hov or n_idx == state.selected_note or (is_selected and label_all_selected)) then
          local name, cents = K.note_name_cents(cp)
          labels[#labels + 1] = {
            x = math.max(sx, px), top = top_y, bot = bot_y,
            text = name .. " " .. cents,
            -- the one selected note: the note action bar's readout shows its name and cents instead of the pill
            fold = (selected_n == 1 and is_selected) or (selected_n == 0 and n_idx == state.selected_note),
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
        reaper.ImGui_DrawList_AddText(draw_list, x + 2, py + ruler_h + L.xs, C.marker_split_text, sp.reason)
      end
    end
  end

  ---------------------------------------------------------------------------
  -- SETTING HIGHLIGHTS: where the hovered / dragged setting acts (over the blocks, under the curves). They
  -- belong to the Preview Curve layer and show from the frame the setting reports itself to the next one.
  ---------------------------------------------------------------------------
  do
    local hint = state.setting_hint
    local live = hint.key ~= nil and hint.frame >= (reaper.ImGui_GetFrameCount(draw_ctx) or 0) - 1
    if live and state.show_preview and not is_bypassed and state.notes and #state.notes > 0 then
      local marks, skipped = K.draw_setting_hint(draw_list, hint, K.frame_view(draw_ctx, state.notes, target_item))
      if hint.dragging and marks == 0 and not hint.said and (skipped or 0) > 0 then
        -- Every note in view the value reaches is one whose mode does not use it
        hint.said = true
        set_status(hint.key == "tighten" and "Not used in Hard mode" or "Not used in Classic or Hard mode")
      end
      if hint.dragging and marks == 0 and not hint.said then
        hint.said = true
        set_status((hint.key == "tolerance" and "No note uses Tolerance yet: raise Tighten first")
          or (hint.key == "slide_in" and "Nothing to flatten: no note in view slides into its pitch")
          or "No note in view uses this value")
      end
    end
    if not (live and hint.dragging) then hint.said = false end
  end

  ---------------------------------------------------------------------------
  -- DRAW RAW PITCH CURVE (the text colour: the blocks own the accent)
  ---------------------------------------------------------------------------
  if state.show_raw_pitch then
    -- Only the part of the curve that reaches the visible window; unvoiced gaps at either end are skipped so
    -- the line still runs to the canvas edge
    local r0, r1 = visible_range(state.results)
    while r0 > 1 and not state.results[r0].note do r0 = r0 - 1 end
    while r1 < #state.results and not state.results[r1].note do r1 = r1 + 1 end
    local polyline = K.raw_trace(state.results, r0, r1, t_to_x)   -- cached, see K.raw_trace
    local has_notes = state.notes and #state.notes > 0
    if polyline then
      -- With notes the trace is a reference layer: barely visible everywhere, and dimmed only over a note's block
      reaper.ImGui_DrawList_AddPolyline(draw_list, polyline, has_notes and C.trace_far or C.trace, 0, 1.5)
    end
    if polyline and has_notes then
      local view = K.frame_view(draw_ctx, state.notes, target_item)
      local runs, owner, run_n = K.raw_trace_runs(state.results, r0, r1, t_to_x, state.notes, view.gen)   -- cached
      for i = 1, run_n do
        local note = owner[i]
        local cp = note.controls and note.controls.center_pitch
        if cp then
          reaper.ImGui_DrawList_PushClipRect(draw_list,
            t_to_x(note.start_time), py + h - ((cp + 0.5 - min_note) / note_range) * h,
            t_to_x(note.end_time), py + h - ((cp - 0.5 - min_note) / note_range) * h, true)
          reaper.ImGui_DrawList_AddPolyline(draw_list, runs[i], C.trace_note, 0, 1.5)
          reaper.ImGui_DrawList_PopClipRect(draw_list)
        end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW CORRECTED PITCH PREVIEW & PITCH POINTS
  ---------------------------------------------------------------------------

  -- Corrected pitch preview (green): the pitch trace plus the correction that is written to the item, over
  -- every edited note with its ramps and glides. It is the trajectory of the envelope itself
  -- (K.correction_build), so a scoop, a fade or a glide shows exactly as it will sound.
  if state.show_preview and state.notes and #state.notes > 0 and state.results and #state.results > 1 then
    local build = K.frame_view(draw_ctx, state.notes, target_item)
    -- An outdated item holds another envelope than today's settings would write: the curve shows what it really
    -- holds, except while a value or a note is being changed (then it previews what the release will write).
    local held = state.target_take_guid and state.stale_takes[state.target_take_guid]
      and state.stale_env[state.target_take_guid] or nil
    local hint = state.setting_hint
    local cpt = state.context_point   -- the point menu's Offset being dragged or typed
    local changing = state.drag or state.edge_drag or state.point_drag or state.nudge_burst
      or (cpt and (cpt.active or cpt.live))
      or (hint.dragging and hint.frame >= (reaper.ImGui_GetFrameCount(draw_ctx) or 0) - 1)
    if held and not changing then
      if held.base ~= build then
        K.held_gen = (K.held_gen or 0) - 1
        held.base, held.ranges, held.gen = build, build.ranges, K.held_gen
      end
      build = held
    end
    if #build.ranges > 0 then
      local r0, r1 = visible_range(state.results)
      local lines, line_n = K.preview_lines(state.results, r0, r1, t_to_x, build)
      for i = 1, line_n do
        reaper.ImGui_DrawList_AddPolyline(draw_list, lines[i], C.preview, 0, 2.0)
      end
    end
  end

  -- Pitch points over the Preview Curve, under the pills (same rule as the hit-test: K.points_shown)
  if state.notes and state.show_smart_spots then
    K.draw_points(draw_list, C, state.notes, vt0, vt1, t_to_x,
      function(p) return py + h - ((p - min_note) / note_range) * h end, K.frame_view(draw_ctx, state.notes, target_item))
  end

  ---------------------------------------------------------------------------
  -- DRAW NOTE LABELS (collected with the blocks): a pill above each block, or below it when the ruler is in the way
  ---------------------------------------------------------------------------
  do
    local pill_h = line_h + L.xs * 2
    local bar_shows = not is_bypassed and not K.note_bar_hidden(draw_ctx)
    for _, lb in ipairs(labels) do
      if lb.fold and bar_shows then goto next_label end
      local y = lb.top - pill_h - L.xs
      if y < py + ruler_h then y = lb.bot + L.xs end
      pill_text(lb.x, y, lb.text, C.pill_text)
      ::next_label::
    end
  end

  ---------------------------------------------------------------------------
  -- DRAW MARQUEE SELECTION BOX
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
  -- DRAW TIME RULER (overlay along the top of the note area, not the note-name column)
  ---------------------------------------------------------------------------
  do
    local span = vt1 - vt0
    -- REAPER's own timeline colours (C.ruler_*): the strip, grey ticks and labels match the arrange view's ruler.
    -- As there, no line closes the strip at the bottom: the ticks end on the rows.
    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, py, px + w, py + ruler_h, C.ruler_bg)

    local _, ruler_item = K.frame_target()
    local item_pos = ruler_item and reaper.GetMediaItemInfo_Value(ruler_item, "D_POSITION") or 0

    -- One tick: tall with a label at a major step, short at a minor one. A label that would touch the previous
    -- one (or leave the note area) is dropped, so labels never overlap.
    local label_y = py + L.xs
    local next_free_x = px
    local major_top = py + ruler_h // 3   -- a major tick is the lower two thirds of the strip
    local function draw_tick(x, label)
      if not label then
        reaper.ImGui_DrawList_AddLine(draw_list, x, py + ruler_h - L.sm, x, py + ruler_h, C.ruler_tick)
        return
      end
      reaper.ImGui_DrawList_AddLine(draw_list, x, major_top, x, py + ruler_h, C.ruler_text)
      local label_w = reaper.ImGui_CalcTextSize(draw_ctx, label) or 0
      local label_x = x + L.sm
      if label_x >= next_free_x and label_x + label_w <= px + w then
        reaper.ImGui_DrawList_AddText(draw_list, label_x, label_y, C.ruler_text, label)
        next_free_x = label_x + label_w + L.md
      end
    end

    -- The ruler follows REAPER's own ruler unit: bars and beats when the project's time format starts with
    -- measures.beats ("33.1.00", with or without a time after it), project time otherwise. REAPER's tempo map
    -- places every bar and beat, so tempo and time signature changes need nothing here.
    local t_first, t_last = item_pos + vt0, item_pos + vt1
    local unit = reaper.format_timestr_pos(t_first, "", -1)
    local beats_drawn = false
    if type(unit) == "string" and unit:match("^%-?%d+%.%d+%.%d+") then
      local _, bar_first = reaper.TimeMap2_timeToBeats(0, t_first)
      local _, bar_last = reaper.TimeMap2_timeToBeats(0, t_last)
      local bar_t0, _, _, cml = reaper.TimeMap_GetMeasureInfo(0, bar_first or 0)
      local bar_t1 = reaper.TimeMap_GetMeasureInfo(0, (bar_first or 0) + 1)
      if bar_first and bar_last and bar_t0 and bar_t1 and bar_t1 > bar_t0 and cml and cml > 0 then
        beats_drawn = true
        -- The bar number as REAPER shows it (a project's measure offset included)
        local function bar_name(bar, bar_t)
          local shown = reaper.format_timestr_pos(bar_t + K.VIEW_EPS_S, "", 2)
          return type(shown) == "string" and shown:match("^(%-?%d+)%.") or tostring(bar + 1)
        end
        local widest_bar = bar_name(bar_last, reaper.TimeMap_GetMeasureInfo(0, bar_last) or t_last)
        local need = (reaper.ImGui_CalcTextSize(draw_ctx, widest_bar .. ".1") or 0) * K.RULER_LABEL_ROOM
        local need_sub = (reaper.ImGui_CalcTextSize(draw_ctx, widest_bar .. ".1.50") or 0) * K.RULER_LABEL_ROOM
        local beat_px = (bar_t1 - bar_t0) / cml / span * w
        local bars, label_beats, tick_beats, bar_ticks = K.ruler_beat_steps(beat_px, cml, need, need_sub)

        local step = (bars > 1 and not bar_ticks) and bars or 1
        for bar = bar_first - bar_first % step, bar_last, step do
          local bar_t, _, _, bar_cml = reaper.TimeMap_GetMeasureInfo(0, bar)
          if not bar_t then break end
          local name = bar_name(bar, bar_t)
          if tick_beats then
            -- Ticks inside the bar: each time comes from the tempo map; a label at every label_beats (or the bar start)
            local per_label = label_beats and math.floor(label_beats / tick_beats + 0.5) or nil
            for i = 0, math.floor((bar_cml or cml) / tick_beats + 0.5) - 1 do
              local beat = i * tick_beats
              local t = i == 0 and bar_t or reaper.TimeMap2_beatsToTime(0, beat, bar)
              if t and t >= t_first - K.VIEW_EPS_S and t <= t_last + K.VIEW_EPS_S then
                local label = nil
                if (per_label and i % per_label == 0) or (not per_label and i == 0) then
                  local whole = math.floor(beat + K.VIEW_EPS_S)
                  local part = math.floor((beat - whole) * 100 + 0.5)
                  label = string.format("%s.%d", name, whole + 1) .. (part > 0 and string.format(".%02d", part) or "")
                end
                draw_tick(t_to_x(t - item_pos), label)
              end
            end
          elseif bar_t >= t_first - K.VIEW_EPS_S and bar_t <= t_last + K.VIEW_EPS_S then
            draw_tick(t_to_x(bar_t - item_pos), bar % bars == 0 and (name .. ".1") or nil)
          end
        end
      end
    end

    if not beats_drawn then
      -- Project time, as on REAPER's ruler (the project start time offset included): the item's position is added
      -- to the canvas time, and the ticks sit on round project times, not round item times
      local proj_t0 = item_pos + reaper.GetProjectTimeOffset(0, false)

      -- Smallest 1-2-5 x 10^n number of seconds that is at least t_min
      local function nice_step(t_min)
        local base = 10 ^ math.floor(math.log(t_min, 10))
        local ratio = t_min / base
        return base * (ratio <= 1 and 1 or (ratio <= 2 and 2 or (ratio <= 5 and 5 or 10)))
      end
      -- "1:02.5" (minutes:seconds, as REAPER's ruler), "1:00:02.5" from an hour on; "-" before the project start
      local function time_label(t, decimals)
        local scale = math.floor(10 ^ decimals + 0.5)
        local ticks = math.floor(math.abs(t) * scale + 0.5)
        local sign = (t < 0 and ticks > 0) and "-" or ""
        local whole = ticks // scale
        local fraction = decimals > 0 and string.format(".%0" .. decimals .. "d", ticks % scale) or ""
        if whole >= 3600 then
          return sign .. string.format("%d:%02d:%02d", whole // 3600, whole // 60 % 60, whole % 60) .. fraction
        end
        return sign .. string.format("%d:%02d", whole // 60, whole % 60) .. fraction
      end

      -- The major step: the smallest one whose labels fit with room between them (starting from one digit per step)
      local digit_w = reaper.ImGui_CalcTextSize(draw_ctx, "0") or 0
      local interval = nice_step(span * math.max(digit_w, 1) / math.max(w, 1))
      local decimals = 0
      for attempt = 1, K.RULER_MAX_TRIES do
        decimals = interval >= 1 and 0 or math.ceil(-math.log(interval, 10) - K.VIEW_EPS_S)
        local widest = math.max(
          reaper.ImGui_CalcTextSize(draw_ctx, time_label(proj_t0 + vt0, decimals)) or 0,
          reaper.ImGui_CalcTextSize(draw_ctx, time_label(proj_t0 + vt1, decimals)) or 0)
        if interval / span * w >= widest * K.RULER_LABEL_ROOM or attempt == K.RULER_MAX_TRIES then break end
        interval = nice_step(interval * K.RULER_WIDEN)
      end

      -- A label at every major step, a short tick at every minor one
      local minor = interval / K.RULER_MINOR_DIV
      for m = math.ceil((proj_t0 + vt0) / minor - K.VIEW_EPS_S), math.floor((proj_t0 + vt1) / minor + K.VIEW_EPS_S) do
        draw_tick(t_to_x(m * minor - proj_t0), m % K.RULER_MINOR_DIV == 0 and time_label(m * minor, decimals) or nil)
      end
    end

    if on_ruler and state.view_t0 and not gesture then
      Theme.tooltip(draw_ctx, "Click to move the edit cursor.\n\nDouble-click: whole item.")
    end
  end

  ---------------------------------------------------------------------------
  -- DRAG READOUT (a pill on the canvas, drawn after the playhead so it sits in front of it) and HOVER HINT (a tooltip)
  ---------------------------------------------------------------------------
  local drag_tip = nil
  local drag_gauge, drag_zone = nil, nil   -- the note and the K.ZONE_CONTROLS entry of a value drag: its readout carries the value's track
  if state.point_drag and state.point_drag.dirty then
    -- The point's own offset in whole cents, then the pitch the note aims for there (the note readout's format)
    local pd = state.point_drag
    local pd_note = state.notes[pd.note_idx]
    local knot = pd_note and K.point_knot_at(pd_note, pd.frame)
    local aim = pd_note and K.point_aim(pd_note, pd.frame, K.frame_view(draw_ctx, state.notes, target_item))
    if aim then
      local nearest = math.floor(aim + 0.5)
      local cents = math.floor((aim - nearest) * 100 + 0.5)
      local tip = string.format("%+d\xC2\xA2 \xC2\xB7 %s %s%d\xC2\xA2", math.floor((knot and knot.st or 0) * 100 + 0.5),
        midi_to_name(nearest), cents >= 0 and "+" or "", cents)
      drag_tip = tip
    end
  elseif state.drag and state.drag.dirty then
    local d_note = state.notes[state.drag.note_idx]
    if d_note and d_note.controls then
      local count = 0
      for _ in pairs(state.drag.orig_values or {}) do count = count + 1 end
      local count_suffix = count > 1 and string.format("  (%d notes)", count) or ""
      -- The readout names the value that is changing (K.ZONE_CONTROLS), as the hover hint does
      local zone_ctl = K.zone_control(state.drag.zone, state.drag.shift_mode)
      local tip
      if zone_ctl then
        tip = K.zone_text(zone_ctl, d_note, false) .. count_suffix
        drag_gauge, drag_zone = d_note, zone_ctl
      else
        local cp = d_note.controls.center_pitch
        local nearest = math.floor(cp + 0.5)
        local cents = math.floor((cp - nearest) * 100 + 0.5)
        local sign = cents >= 0 and "+" or ""
        tip = string.format("%s %s%d\xC2\xA2%s",
          midi_to_name(nearest), sign, cents, count_suffix)
      end
      drag_tip = tip
    end
  elseif canvas_tip_ready and state.hovered_point and not state.drag and not state.marquee and not state.point_drag then
    Theme.tooltip(draw_ctx, string.format(
      "Drag to bend the pitch here (%s-drag: fine).\n\nDouble-click: reset. Right-click: menu.", K.MOD_LABEL))
  elseif canvas_tip_ready and state.point_ghost and not state.drag and not state.marquee and not state.point_drag
      and not state.edge_drag and not state.view_drag then
    Theme.tooltip(draw_ctx, "Double-click to add a pitch point")
  elseif canvas_tip_ready and state.hovered_note and not state.drag and not state.marquee
      and not state.point_drag and not state.hovered_point then
    local h_note = state.notes[state.hovered_note]
    if h_note and h_note.controls then
      local has_shift = ((reaper.ImGui_GetKeyMods(draw_ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
      local zone_ctl = K.zone_control(state.hovered_zone, has_shift)
      local tip = zone_ctl and K.zone_text(zone_ctl, h_note, true)
        or string.format("Drag to change the pitch (%s-drag: fine).", K.MOD_LABEL)
      Theme.tooltip(draw_ctx, tip)   -- the Show Tooltips preference applies
    end
  end
  ---------------------------------------------------------------------------
  -- PLAYHEAD CURSOR LINE
  ---------------------------------------------------------------------------
  local playhead_t = nil   -- the cursor's time while it is inside the item (the overview strip marks it too)
  local _, item_for_cursor = K.frame_target()
  if item_for_cursor then
    local item_pos = reaper.GetMediaItemInfo_Value(item_for_cursor, "D_POSITION")
    -- Use play position when playing, edit cursor when stopped
    local play_state = reaper.GetPlayState()
    local project_pos = (play_state & 1) ~= 0
      and reaper.GetPlayPosition()
      or  reaper.GetCursorPosition()
    local item_rel = project_pos - item_pos
    if item_rel >= state.start_time and item_rel <= state.end_time then
      playhead_t = item_rel
      -- The line is drawn only inside the visible window. Its head sits in the ruler: the line is the same colour as
      -- the pitch trace, and the head is what tells it from a spike of the trace
      if item_rel >= vt0 and item_rel <= vt1 then
        local cursor_x = t_to_x(item_rel)
        reaper.ImGui_DrawList_AddLine(draw_list,
          cursor_x, py, cursor_x, py + h, C.playhead, 1.5)
        reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
          cursor_x - L.sm, py, cursor_x + L.sm, py, cursor_x, py + L.md, C.playhead)
      end
    end
  end

  -- The drag readout, beside the pointer, never outside the note area (nor over the note-name column or the ruler)
  if drag_tip then
    -- A value drag: the readout carries the track of that value in the top bar (K.value_track), in the parameter's
    -- colour; it keeps the width of its longest text so the track does not rescale (and is never narrower than the
    -- text shown, which may carry a suffix).
    local zc = drag_zone
    local widest = zc and string.format(zc.read, zc.hi * (zc.show or 1)) or nil
    local bx, by, bw, bh = pill_text(mx + L.xl, my, drag_tip, C.pill_text, L.xl * 2, true, widest)
    if zc then
      local v = math.max(zc.lo, math.min(zc.hi, K.zone_value(zc, drag_gauge)))
      local frac = (v - zc.lo) / (zc.hi - zc.lo)
      -- Inset by the pill's corner radius, so the square track stays inside its rounded bottom corners
      K.value_track(draw_list, bx + L.rounding, bx + bw - L.rounding, by + bh, 0, frac, K.param_color(zc.key))
    end
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)   -- the note area

  ---------------------------------------------------------------------------
  -- DRAW NOTE-NAME COLUMN (a flat strip left of the rows; the root row carries an accent strip and an accent name)
  ---------------------------------------------------------------------------
  reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, py, px, py + full_h, C.gutter_bg)
  reaper.ImGui_DrawList_PushClipRect(draw_list, full_px, py, px, py + h, true)
  for n = math.floor(min_note), math.ceil(max_note) do
    local key_top = py + h - ((n + 0.5 - min_note) / note_range) * h
    local key_bot = py + h - ((n - 0.5 - min_note) / note_range) * h
    local pc = (n % 12 + 12) % 12
    local is_root = (not is_chromatic) and pc == root_pc
    local in_scale = is_chromatic or is_pitch_in_scale(pc)
    -- An out-of-scale row's name sits on a darker cell, as its row does
    if not in_scale then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, key_top, px, key_bot, C.gutter_bg_dim)
    end
    reaper.ImGui_DrawList_AddLine(draw_list, full_px, key_bot, px, key_bot, C.grid)
    if is_root then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, px - L.xs - L.border, key_top, px, key_bot, C.gutter_strip)
    end
    -- Every row is named while a row is at least a text line tall; below that only the C rows are, so the names
    -- never overlap. Out-of-scale rows are named in the dimmer colour (3:1 on their darker cell, the rest >= 4.5:1).
    if px_per_st >= line_h or pc == 0 then
      local text_col = C.gutter_text_dim
      if is_root then
        text_col = C.gutter_text_tonic
      elseif in_scale then
        text_col = C.gutter_text
      end
      reaper.ImGui_DrawList_AddText(draw_list, full_px + L.sm, (key_top + key_bot) * 0.5 - line_h * 0.5, text_col, midi_to_name(n))
    end
  end
  reaper.ImGui_DrawList_PopClipRect(draw_list)
  reaper.ImGui_DrawList_AddLine(draw_list, px, py, px, py + h, P.border)

  ---------------------------------------------------------------------------
  -- DRAW PITCH STRIP (right of the note area) and OVERVIEW STRIP (below it): track, thumb, end grips
  ---------------------------------------------------------------------------
  do
    local x0, x1 = px + w, px + w + pv_w
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, py, x1, py + h, C.overview_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, x0, py, x0, py + h, P.border)
    local ty0, ty1 = pitch_thumb()
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x0 + L.xs, ty0, x1 - L.xs, ty1, C.view_fill, L.rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, x0 + L.xs, ty0, x1 - L.xs, ty1, C.view_border, L.rounding)
    if ty1 - ty0 >= L.xxl then   -- room for a grip inside each end
      local gx0, gx1 = x0 + L.sm + L.border, x1 - L.sm - L.border
      reaper.ImGui_DrawList_AddRectFilled(draw_list, gx0, ty0 + L.sm, gx1, ty0 + L.sm + L.xs, C.view_grip)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, gx0, ty1 - L.sm - L.xs, gx1, ty1 - L.sm, C.view_grip)
    end
  end
  do
    local y0, y1 = py + h, py + full_h
    reaper.ImGui_DrawList_AddRectFilled(draw_list, px, y0, full_px + full_w, y1, C.overview_bg)
    reaper.ImGui_DrawList_AddLine(draw_list, full_px, y0, full_px + full_w, y0, P.border)
    -- Every note, small: placed by time over the whole item and by pitch over the fitted range
    local lane_h = (y1 - y0) - L.sm * 2
    if state.notes and lane_h > 0 then
      local fit_span = math.max(1, fit_max - fit_min)
      local bar_h = math.max(L.xs, math.min(L.sm, lane_h / fit_span))
      for _, note in ipairs(state.notes) do
        if note.controls then
          local nx0 = px + (note.start_time - item_t0) / duration * w
          local nx1 = math.max(nx0 + 1, px + (note.end_time - item_t0) / duration * w)
          local frac = math.max(0, math.min(1, (note.controls.center_pitch - fit_min) / fit_span))
          local cy = y1 - L.sm - frac * lane_h
          reaper.ImGui_DrawList_AddRectFilled(draw_list, nx0, cy - bar_h * 0.5, nx1, cy + bar_h * 0.5, C.overview_note)
        end
      end
    end
    local tx0, tx1 = overview_thumb()
    reaper.ImGui_DrawList_AddRectFilled(draw_list, tx0, y0 + L.xs, tx1, y1 - L.xs, C.view_fill, L.rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, tx0, y0 + L.xs, tx1, y1 - L.xs, C.view_border, L.rounding)
    if tx1 - tx0 >= L.xxl then   -- room for a grip inside each end
      local gy0, gy1 = y0 + L.sm + L.border, y1 - L.sm - L.border
      reaper.ImGui_DrawList_AddRectFilled(draw_list, tx0 + L.sm, gy0, tx0 + L.sm + L.xs, gy1, C.view_grip)
      reaper.ImGui_DrawList_AddRectFilled(draw_list, tx1 - L.sm - L.xs, gy0, tx1 - L.sm, gy1, C.view_grip)
    end
    if playhead_t then
      local cursor_x = px + (playhead_t - item_t0) / duration * w
      reaper.ImGui_DrawList_AddLine(draw_list, cursor_x, y0, cursor_x, y1, C.playhead)
    end
  end

  -- Bypassed Overlay: yellow (a state to get out of, not an error), with the way out as a button
  if is_bypassed then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, full_px, py, full_px + full_w, py + full_h, C.scrim)

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

  -- Status pill, bottom-left of the note area (over the scrim too): a status message while it lasts, else the hint
  -- for the state the editor is in (K.status_line)
  K.canvas_status(draw_list, px + L.sm, py + h - L.sm, w - L.sm * 2, not is_bypassed, function(x1, y1, x2, y2)
    return K.note_under(state.notes, t_to_x, py, h, min_note, note_range, x1, y1, x2, y2)
  end)

  -- Note action bar (Snap, Quantize, Cursor, Split, Merge) under the selected note, over everything on the canvas but the
  -- menus; real Buttons, so they take the hover from the canvas (see the overlap above)
  if not is_bypassed and K.draw_note_bar(draw_ctx, draw_list, ruler_h, target_take ~= nil, target_item) then
    buttons_used = true
  end

  -- Note Context Menu
  local note_menu_open = reaper.ImGui_BeginPopup(draw_ctx, "##note_context_menu")
  if note_menu_open then
    -- HC5: Esc closes this menu, unless a popup opened from it (a typed-entry field) is open: that one is innermost.
    -- Esc also ends a slider drag in the same frame (ImGui reports it as an edit released): that is a cancel, not a
    -- commit
    local nm_esc = false
    if not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
      nm_esc = true
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
      if reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(draw_ctx, select(5, K.note_readout(cp, Theme.get_palette().canvas)))
      end

      reaper.ImGui_Separator(draw_ctx)

      -- A wider gap between each control and its label on the right (the menu's rows read as label pairs)
      local _, inner_y = reaper.ImGui_GetStyleVar(draw_ctx, reaper.ImGui_StyleVar_ItemInnerSpacing())
      reaper.ImGui_PushStyleVar(draw_ctx, reaper.ImGui_StyleVar_ItemInnerSpacing(), L.md, inner_y)

      local bp = ctrl.bypassed or false
      local changed, new_bp = reaper.ImGui_Checkbox(draw_ctx, "Bypass This Note", bp)
      if reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(draw_ctx, K.tip("Bypass This Note",
          "Turns the correction off for this note: it plays as sung. Its values and pitch points are kept.",
          "B bypasses the selected notes."))
      end
      if changed then
        ctrl.bypassed = new_bp
        apply_envelope_to_take("Toggle Note Bypass")
      end

      reaper.ImGui_Separator(draw_ctx)

      reaper.ImGui_PushItemWidth(draw_ctx, 120)

      -- How many notes a row with `spread` writes to: every selected note when the menu's note is one of several
      local spread_n = 0
      if state.selected_notes[note_idx] then
        for idx in pairs(state.selected_notes) do
          if state.notes[idx] and state.notes[idx].controls then spread_n = spread_n + 1 end
        end
      end

      --- One value row. `spread`: the value is written to every selected note (see spread_n), and the row says
      --- how many. A value outside the cascade (Tighten, Slide In) has nothing to inherit and shows no level.
      local function draw_cm_slider(label, key, min_v, max_v, fmt, scale, default, spread)
         local level = get_override_level(note, key)
         local cur_val = ctrl[key] or get_effective(note, key) or default or 0
         if scale then cur_val = cur_val * scale end
         spread = spread and spread_n > 1

         -- param_drag tests the gestures right after the control (not after SameLine / TextDisabled, which would test the text)
         local name = PARAM_LABELS[key] or label
         -- The note's mode may not use this value: its text is dim (as in the top bar)
         local unused = K.mode_unused(key, { note }, 1)
         local dim = (unused == "mode" or unused == "hard")
         if dim then reaper.ImGui_PushStyleColor(draw_ctx, reaper.ImGui_Col_Text(), Theme.get_palette().text_dim) end
         local s_changed, new_val, committed, reset = param_drag(draw_ctx, "cm_" .. key, label, cur_val, min_v, max_v, fmt)
         if dim then reaper.ImGui_PopStyleColor(draw_ctx) end
         -- The top bar's range fill (K.value_fill), in the parameter's colour
         K.value_fill(draw_ctx, 0, (cur_val - min_v) / (max_v - min_v), K.param_color(key),
            reaper.ImGui_CalcItemWidth(draw_ctx))
         -- Tooltip of the drag (no item was submitted since): name, what it does, why it does nothing now (if so),
         -- what it changes and where its value comes from, the gestures
         if reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip())
            and not reaper.ImGui_IsItemActive(draw_ctx) then
            local idle = K.tip(unused and K.MODE_UNUSED_TIP[unused],
               (key == "tolerance" and unused ~= "mode" and (tonumber(get_effective(note, "tighten")) or 0) <= 0)
                  and K.TOLERANCE_IDLE_TIP or nil)
            local scope = spread and string.format(K.CM_SCOPE_NOTES, spread_n) or K.CM_SCOPE_NOTE
            Theme.tooltip(draw_ctx, K.tip(name, K.VALUE_TIP[key], idle,
               scope .. "\n" .. (K.CM_LEVEL[level] or ""), K.CM_GESTURES))
         end
         if K.drag_hot.hovered or K.drag_hot.active then
            -- The canvas shades where this value acts on the menu's note
            local set = state.setting_hint.menu_set
            for k in pairs(set) do set[k] = nil end
            set[note_idx] = true
            if spread then
               for idx in pairs(state.selected_notes) do set[idx] = true end
            end
            K.setting_hint(draw_ctx, key, K.drag_hot.active, set)
         end
         local edit = state.context_edit
         if reset then
            -- Double-click: drop the per-note override so the note inherits again (one undo point)
            if edit and edit.key == key then state.context_edit = nil end
            local had = ctrl[key] ~= nil
            ctrl[key] = nil
            if spread then
               for idx in pairs(state.selected_notes) do
                  local o = state.notes[idx]
                  if o and o ~= note and o.controls and o.controls[key] ~= nil then
                     o.controls[key] = nil
                     had = true
                  end
               end
            end
            if had then
               apply_envelope_to_take("Reset " .. name)
            end
         else
            if s_changed then
               -- The model is ahead of the envelope until the commit: remember the value to go back to (nil = inherit)
               if not (edit and edit.note == note and edit.key == key) then
                  edit = { note = note, key = key, raw = ctrl[key] }
                  -- Each of the other selected notes remembers its own value for Esc
                  if spread then
                     edit.others = {}
                     for idx in pairs(state.selected_notes) do
                        local o = state.notes[idx]
                        if o and o ~= note and o.controls then
                           edit.others[#edit.others + 1] = { note = o, raw = o.controls[key] }
                        end
                     end
                  end
                  state.context_edit = edit
               end
               if scale then new_val = new_val / scale end
               ctrl[key] = new_val
               for _, o in ipairs(edit.others or {}) do o.note.controls[key] = new_val end
            end
            if committed and not nm_esc then
               apply_envelope_to_take("Adjust " .. name)
               state.context_edit = nil
            end
         end
         if key == "tolerance" or key == "retune_speed" then
            reaper.ImGui_SameLine(draw_ctx)
            reaper.ImGui_TextDisabled(draw_ctx, "[" .. level .. "]")
         end
         if spread then
            reaper.ImGui_SameLine(draw_ctx)
            reaper.ImGui_TextDisabled(draw_ctx, string.format("(%d notes)", spread_n))
         end
      end

      -- Mode: the note's mode in effect; a choice is written to the menu's note, or to every selected note when it
      -- is one of several (as the value rows do), as one undo point. Choosing what every one already has does nothing
      do
        local choice, m_changed = Theme.combo(draw_ctx, "##cm_mode", K.MODES, K.mode_value(note) + 1,
          { w = reaper.ImGui_CalcItemWidth(draw_ctx),
            tooltip = K.tip("Mode", K.MODE_TIP,
              (spread_n > 1 and string.format(K.CM_SCOPE_NOTES, spread_n) or K.CM_SCOPE_NOTE) .. "\n"
                .. (ctrl.correct_mode ~= nil and K.CM_LEVEL.note or K.CM_LEVEL_MODE_ITEM)) })
        -- The label sits where a value row's label does: the inner spacing right of the control
        local inner = reaper.ImGui_GetStyleVar(draw_ctx, reaper.ImGui_StyleVar_ItemInnerSpacing())
        reaper.ImGui_SameLine(draw_ctx, 0, inner)
        reaper.ImGui_Text(draw_ctx, "Mode")
        reaper.ImGui_SameLine(draw_ctx)
        reaper.ImGui_TextDisabled(draw_ctx, ctrl.correct_mode ~= nil and "[note]" or "[item]")
        if spread_n > 1 then
          reaper.ImGui_SameLine(draw_ctx)
          reaper.ImGui_TextDisabled(draw_ctx, string.format("(%d notes)", spread_n))
        end
        if m_changed then
          local targets = { note }
          if spread_n > 1 then
            for idx in pairs(state.selected_notes) do
              local o = state.notes[idx]
              if o and o ~= note and o.controls then targets[#targets + 1] = o end
            end
          end
          local differs = false
          for _, o in ipairs(targets) do
            if K.mode_value(o) ~= choice - 1 then differs = true break end
          end
          if differs then
            for _, o in ipairs(targets) do o.controls.correct_mode = choice - 1 end
            apply_envelope_to_take("Set Mode")
          end
        end
      end
      draw_cm_slider(PARAM_LABELS.tighten, "tighten", 0, 100, "%.0f%%", 100, nil, true)
      draw_cm_slider(PARAM_LABELS.tolerance, "tolerance", K.LIMITS.tolerance[1], K.LIMITS.tolerance[2], "%.0f \xC2\xA2", nil, nil, true)
      draw_cm_slider(PARAM_LABELS.slide_in, "slide_in", 0, 100, "%.0f%%", 100, nil, true)
      draw_cm_slider(PARAM_LABELS.retune_speed, "retune_speed", 0, 100, "%.0f%%", 100, nil, true)

      reaper.ImGui_PopItemWidth(draw_ctx)
      reaper.ImGui_PopStyleVar(draw_ctx)
      reaper.ImGui_Separator(draw_ctx)

      -- Snap, Quantize, Split and Reset are not repeated here: their keys are in the Shortcuts list and on the
      -- note action bar. A disabled entry still explains itself.
      local item_tip_flags = reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()
      -- Pitch points: add one where the menu was opened, or put the note's points back (disabled with the reason)
      local _, add_reason = K.point_can_add(note, state.context_menu_time or note.start_time)
      local add_why = (not state.show_smart_spots) and "layer is off"
        or ctrl.bypassed and "note is bypassed"
        or (not state.context_menu_live) and "zoom in first"
        or add_reason == "no_pitch" and "no pitch here"
        or add_reason == "too_close" and "a point is already here" or nil
      local add_clicked = reaper.ImGui_MenuItem(draw_ctx, "Add Pitch Point Here", add_why, false, add_why == nil)
      if reaper.ImGui_IsItemHovered(draw_ctx, item_tip_flags) then
        Theme.tooltip(draw_ctx, K.tip("Add Pitch Point Here",
          "Adds a point where you right-clicked. Drag it up or down to bend the pitch at that moment.",
          "You can also double-click the pitch line."))
      end
      if add_clicked then
        local knot, reason = K.point_add(note, state.context_menu_time or note.start_time)
        if knot then
          apply_envelope_to_take("Add Pitch Point")
        elseif reason == "no_pitch" then
          set_status("No pitch detected here: a point needs a pitch to sit on.")
        end
      end
      local n_points = K.points_count(note)
      local reset_points = reaper.ImGui_MenuItem(draw_ctx, string.format("Reset Pitch Points (%d)###reset_points", n_points),
          n_points == 0 and "none moved or added" or nil, false, n_points > 0)
      if reaper.ImGui_IsItemHovered(draw_ctx, item_tip_flags) then
        Theme.tooltip(draw_ctx, K.tip("Reset Pitch Points",
          "Puts this note's moved points back to 0 and removes the points you added.",
          "One undo step."))
      end
      if reset_points then
        local n_done = K.points_reset(note)
        if n_done > 0 and apply_envelope_to_take("Reset Pitch Points") then
          set_status(string.format("Reset %d pitch %s on %s. %s+Z to undo", n_done, plural(n_done, "point", "points"),
            note_name, K.MOD_LABEL))
        end
      end
    end
    reaper.ImGui_EndPopup(draw_ctx)
  end
  -- The note menu closed (Esc during a slider drag) with a slider value not written: the note gets back the value it
  -- had before the drag, with no write and no undo point (HC5: Esc reverts the active edit)
  local cm_edit = state.context_edit
  if not note_menu_open and cm_edit then
    if cm_edit.note.controls then cm_edit.note.controls[cm_edit.key] = cm_edit.raw end
    for _, o in ipairs(cm_edit.others or {}) do   -- the other selected notes the value was written to
      if o.note.controls then o.note.controls[cm_edit.key] = o.raw end
    end
    state.context_edit = nil
  end

  -- Point Context Menu: the offset of one pitch point, put it back, remove it (added points only)
  local point_menu_open = reaper.ImGui_BeginPopup(draw_ctx, "##point_context_menu")
  if point_menu_open then
    -- HC5: Esc closes this menu, unless its typed-entry popup is open (that one is innermost). Esc also ends an
    -- Offset drag in the same frame (ImGui reports it as an edit released): that is a cancel, not a commit
    local pt_esc = false
    if not reaper.ImGui_IsPopupOpen(draw_ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
       and reaper.ImGui_Shortcut(draw_ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
      pt_esc = true
    end
    local cpt = state.context_point
    local pt_note = cpt and state.notes and state.notes[cpt.note_idx]
    local pt_knot = pt_note and K.point_knot_at(pt_note, cpt.frame)
    if not pt_knot then
      -- The point is gone (an undo, a trim, a reload, or a live Offset of 0 dropped its entry): the menu closes,
      -- and an uncommitted Offset is put back below
      reaper.ImGui_CloseCurrentPopup(draw_ctx)
      point_menu_open = false
    else
      local pt_hint = string.format(" %s+Z to undo", K.MOD_LABEL)
      reaper.ImGui_PushItemWidth(draw_ctx, 120)
      local _, inner_y = reaper.ImGui_GetStyleVar(draw_ctx, reaper.ImGui_StyleVar_ItemInnerSpacing())
      reaper.ImGui_PushStyleVar(draw_ctx, reaper.ImGui_StyleVar_ItemInnerSpacing(), Theme.layout.md, inner_y)
      local ch, val, committed, reset = param_drag(draw_ctx, "pt_offset", "Offset", pt_knot.st * 100,
        -K.POINT_MAX_ST * 100, K.POINT_MAX_ST * 100, "%+.0f \xC2\xA2")
      if reaper.ImGui_IsItemHovered(draw_ctx, reaper.ImGui_HoveredFlags_ForTooltip())
          and not reaper.ImGui_IsItemActive(draw_ctx) then
        Theme.tooltip(draw_ctx, K.tip("Offset",
          "How far this point bends the pitch, in cents (100\xC2\xA2 = one semitone). + bends up, - bends down.",
          string.format("Drag to change (%s-drag: fine). Double-click: back to 0. %s-click: type a value.",
            K.MOD_LABEL, K.MOD_LABEL)))
      end
      reaper.ImGui_PopStyleVar(draw_ctx)
      reaper.ImGui_PopItemWidth(draw_ctx)
      cpt.active = K.drag_hot.active   -- the Offset is being dragged or typed (the Preview Curve follows it)
      if reset then
        if pt_knot.st ~= 0 then
          K.point_set(pt_note, pt_knot, 0)
          apply_envelope_to_take("Reset Pitch Point")
        end
        cpt.start_st, cpt.live = 0, nil
      else
        if ch then
          K.point_set(pt_note, pt_knot, val / 100)
          cpt.live, cpt.note = true, pt_note   -- the model is ahead of the envelope until the commit
        end
        if committed and not pt_esc then
          local now = K.point_knot_at(pt_note, cpt.frame)
          if not now or K.points_clamp(now.st) ~= K.points_clamp(cpt.start_st) then
            apply_envelope_to_take("Move Pitch Point")
          end
          cpt.start_st, cpt.live = now and now.st or 0, nil
        end
      end

      reaper.ImGui_Separator(draw_ctx)

      local cur = K.point_knot_at(pt_note, cpt.frame) or pt_knot
      local pt_tip_flags = reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()
      local reset_pt = reaper.ImGui_MenuItem(draw_ctx, "Reset Point", cur.st == 0 and "already at 0" or nil, false, cur.st ~= 0)
      if reaper.ImGui_IsItemHovered(draw_ctx, pt_tip_flags) then
        Theme.tooltip(draw_ctx, "Puts this point back to 0\xC2\xA2: the pitch there is as sung.")
      end
      if reset_pt then
        K.point_set(pt_note, cur, 0)
        cpt.start_st, cpt.live = 0, nil
        if apply_envelope_to_take("Reset Pitch Point") then set_status("Reset the pitch point." .. pt_hint) end
      end
      local can_remove = cur.kind == "added"
      local remove_pt = reaper.ImGui_MenuItem(draw_ctx, "Remove Point", not can_remove and "detected points stay" or nil, false, can_remove)
      if reaper.ImGui_IsItemHovered(draw_ctx, pt_tip_flags) then
        Theme.tooltip(draw_ctx, K.tip("Removes this point.",
          "Only points you added can be removed. Points found by the analysis stay: reset them to 0 instead."))
      end
      if remove_pt then
        if K.point_remove(pt_note, cur) then
          if apply_envelope_to_take("Remove Pitch Point") then set_status("Removed the pitch point." .. pt_hint) end
          state.context_point = nil
        end
      end
    end
    reaper.ImGui_EndPopup(draw_ctx)
  end
  -- The point menu closed (Esc, a click away, or by itself) with its Offset not committed: the point goes back to
  -- the value it had when the menu opened or was last committed, with no write and no undo point
  local cpt_closed = state.context_point
  if not point_menu_open and cpt_closed then
    if cpt_closed.live and state.notes and state.notes[cpt_closed.note_idx] == cpt_closed.note then
      local n = cpt_closed.note
      local f = n.frames and n.frames[cpt_closed.frame]
      local knot = K.point_knot_at(n, cpt_closed.frame) or (f and { frame = cpt_closed.frame, t = f.time, st = 0 })
      if knot then K.point_set(n, knot, cpt_closed.start_st) end
    end
    state.context_point = nil
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
      state.point_drag = nil
      state.context_point = nil
      state.hovered_point = nil
      state.point_ghost = nil
      state.points_hover_note = nil
      state.points_zoom_hint = false
      K.reset_view()
      state.start_time = nil
      state.end_time = nil
      state.item_len = nil
      state.sample_rate = nil
      K.adopt_new_item_values()   -- nothing open: the next item starts at a new item's values
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

--- Remove several items (Remove Selected, after the user confirmed) as ONE undo point.
--- Returns how many were removed and how many of them were found in the project.
K.remove_takes_from_session = function(guids)
  local n, found_n = 0, 0
  if not guids or #guids == 0 then return 0, 0 end
  reaper.Undo_BeginBlock()
  for _, guid in ipairs(guids) do
    if state.session_takes[guid] then
      local _, found = remove_take_core(guid)
      n = n + 1
      if found then found_n = found_n + 1 end
    end
  end
  reaper.Undo_EndBlock(string.format("Remove %d %s from Pitched Items", n, n == 1 and "Item" or "Items"), -1)
  note_own_write()
  return n, found_n
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
  K.adopt_new_item_values()   -- whatever is open next starts at a new item's values
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
    K.adopt_new_item_values()   -- not analysed any more: its next analysis is a first one, at a new item's values
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

--- The selected Pitched Items rows, in list order. Drops any selected guid that is no longer in the list, and makes the
--- selection just the active row when the active item changed from elsewhere (REAPER's selection, a removal, an undo).
K.row_sel_sync = function()
  if state.row_sel_target ~= state.target_take_guid then
    state.row_sel = {}
    if state.target_take_guid then state.row_sel[state.target_take_guid] = true end
    state.row_anchor = state.target_take_guid
    state.row_sel_target = state.target_take_guid
  end
  local list = {}
  for _, g in ipairs(state.session_order) do
    if state.row_sel[g] then list[#list + 1] = g end
  end
  if next(state.row_sel) ~= nil and #list ~= K.count_keys(state.row_sel) then
    local kept = {}
    for _, g in ipairs(list) do kept[g] = true end
    state.row_sel = kept
  end
  return list
end

K.count_keys = function(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- True when the row selection holds anything other than just the active row (what Esc puts back).
K.row_sel_extra = function()
  for g in pairs(state.row_sel) do
    if g ~= state.target_take_guid then return true end
  end
  return state.target_take_guid ~= nil and not state.row_sel[state.target_take_guid]
end

--- Make the row selection just the active row.
K.row_sel_reset = function()
  state.row_sel = {}
  if state.target_take_guid then state.row_sel[state.target_take_guid] = true end
  state.row_anchor = state.target_take_guid
  state.row_sel_target = state.target_take_guid
end

--- "Remove Selected" (on the On line) / row menu "Remove Selected Items (N)…": confirm before removing the selected rows (count, up to
--- five names, the pitch-algorithm resets). The guids are frozen here.
K.request_remove_selected_confirm = function()
  local guids = K.row_sel_sync()
  local n = #guids
  if n == 0 then return end
  if n == 1 then return request_remove_confirm(guids[1]) end
  local names = {}
  for i = 1, math.min(n, 5) do
    local data = state.session_takes[guids[i]]
    names[#names + 1] = (data and data.name) or "Item"
  end
  local name_text = table.concat(names, ", ")
  if n > 5 then name_text = string.format("%s and %d more", name_text, n - 5) end
  local lines = {
    string.format("This removes %d items from Pitched Items (%s), deletes their pitch envelope points and clears their saved analysis.",
      n, name_text),
  }
  local resets = count_pitch_mode_resets(guids)
  if resets > 0 then
    lines[#lines + 1] = string.format("The pitch algorithm of %d %s returns to the project default.",
      resets, plural(resets, "item", "items"))
  end
  request_confirm({
    id = "remove_selected",
    fit = true,   -- as tall as its text: a few lines, no empty block above the buttons
    title = string.format("Remove %d items?", n),
    body_lines = lines,
    confirm_label = string.format("Remove %d Items", n),
    on_confirm = function()
      local removed, found_n = K.remove_takes_from_session(guids)
      K.row_sel_reset()
      -- The list does not re-adopt items after Cmd/Ctrl+Z, so no undo promise
      if found_n > 0 then
        set_status(string.format("Removed %d %s. Their envelopes and saved analysis were cleared.",
          removed, plural(removed, "item", "items")))
      else
        set_status(string.format("Removed %d %s from Pitched Items.", removed, plural(removed, "item", "items")))
      end
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
      if guid == state.target_take_guid then
        reset_analysis_model()
        K.adopt_new_item_values()   -- not analysed any more: a new item's values
      end
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
  panel_tip_show = "Show the side panel: Pitched Items (%d) and Shortcuts",
  panel_tip_hide = "Hide the side panel",
  panel_tip_narrow = "The side panel does not fit this window.\n\nWiden the window to show it.",
  panel_narrow_status = "Widen the window to show the side panel",
  shortcuts_narrow_status = "Widen the window to show Shortcuts",
  -- Row states and the checkbox column label (a row is never told apart by colour alone)
  col_on = "On",
  tag_missing = "Item missing",
  tag_outdated = "outdated",
  tip_missing = "The item no longer exists in this project",
  tip_outdated = "This item's envelope is not what the current settings would write (a setting changed after it was written).\n\nEdit or re-analyze it to refresh.",
  -- The banner for items whose saved analysis cannot be read (see K.unreadable_guids) and its Clear button
  unreadable_fmt = "%d %s: saved analysis couldn't be read",
  unreadable_clear = "Clear",
  unreadable_tip = "Discard the saved analysis of these items that cannot be read, so they can be analyzed again (asks to confirm)",
  -- Why REAPER's selected item is not a target (state.selection_issue)
  issue_midi = "MIDI item selected: select an audio item",
  issue_no_audio = "Selected item has no audio: select an audio item",
  -- Row selection: the bar shown while two or more rows are selected, and the row's right-click menu
  sel_remove = "Remove Selected",
  sel_remove_tip_fmt = "Remove the %d selected items from Pitched Items and clear their envelopes and saved analysis (asks to confirm)",
  menu_remove_one = "Remove This Item…",
  menu_remove_sel_fmt = "Remove Selected Items (%d)…",
  menu_no_selection = "no rows selected",
  menu_wipe_fmt = "Wipe All Items (%d)…",
  menu_rename = "Rename…",
  menu_rename_missing = "item not in project",
  row_click_tip = string.format("Click to make this the active item · %s-click to add or remove · Shift-click for a range"
    .. "\nDouble-click to rename (the take in REAPER is renamed too)", K.MOD_LABEL),
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

-- Keyboard Shortcuts & Help content: one entry per section, one { key, description } row each (draw_info_modal measures
-- the columns from these strings). Keep a description near 52 characters so the table stays narrow; the terms follow
-- the UI labels (Pitched Items, item, Correction Strength, Tighten, Tolerance, Slide In, Separation).
-- A row that is also in the panel's Shortcuts list carries panel = { group, order in the group, short text [, short key] }:
-- the list is built from this table (K.panel_rows), so a key is never written in two places.
K.INFO_SECTIONS = {
  { title = "Selection & Navigation", rows = {
    { K.MOD_LABEL .. " + A", "Select all notes in phrase", panel = { "Select", 1, "Select all" } },
    { "Escape", "Close dialog, deselect notes then rows, close if floating", panel = { "Select", 6, "Deselect", "Esc" } },
    { "Marquee Drag", "Box select notes (Shift=Add)", panel = { "Select", 5, "Box select", "Drag empty" } },
    { "Shift + Click", "Range select notes", panel = { "Select", 3, "Select range" } },
    { K.MOD_LABEL .. " + Click", "Toggle note in/out of selection", panel = { "Select", 4, "Add / remove" } },
    { "← / →", "Select previous / next note (Shift=Extend)", panel = { "Select", 2, "Prev / next note" } },
    { "Click empty canvas", "Deselect, move the REAPER edit cursor" },
    { "Click a Pitched Items row", "Switch the active item, select only that row" },
    { K.MOD_LABEL .. " + Click a row", "Add / remove the row from the selection" },
    { "Shift + Click a row", "Select a range of rows" },
    { "Double-click a row's name", "Rename the item (Enter renames, Esc keeps the name)" },
    { "Right-click a row", "Rename, or remove this, the selected or all items" },
    { "Select an audio item in REAPER", "Becomes the active item" },
    { "Drag the divider", "Resize Pitched Items" },
    { "H", "Show / hide the Shortcuts list", panel = { "General", 5, "Hide this list" } },
  } },
  { title = "Pitch & Note Editing", rows = {
    { "Drag Center Zone", string.format("Move note pitch (%s = fine adjust)", K.MOD_LABEL) },
    { "Drag Left Zone", string.format("Tighten: steady the note, slow drift first; 100%% is a flat line (%s = fine)", K.MOD_LABEL),
      panel = { "Edit", 10, "Tighten · Tolerance", "Drag note side" } },
    { "Drag Right Zone", string.format("Tolerance: how far the note may stray from its centre untouched (%s = fine)", K.MOD_LABEL) },
    { "Mode (top bar, note menu)", "Natural, Classic (the pitch jumps between scale notes; Tighten sets how fast) or Hard (one flat scale note)" },
    { "Drag a value in the top bar", string.format("Changes the selected notes, or this item when nothing is selected (%s = fine)", K.MOD_LABEL) },
    { "Shift + Drag Note", "Adjust Slide In", panel = { "Edit", 11, "Slide In", "Shift + Drag" } },
    { "Drag Note Edge", "Trim note start / end boundary", panel = { "Edit", 12, "Trim note", "Drag edge" } },
    { "Drag a pitch point", string.format("Bend the pitch at that moment (%s = fine)", K.MOD_LABEL), panel = { "Edit", 13, "Pitch point", "Drag dot" } },
    { "Double-click a pitch point", "Put it back to 0" },
    { "Double-click the pitch line", "Add a pitch point" },
    { "Right-click a pitch point", "Point menu: type a value, Reset, Remove" },
    { "Click the time ruler", "Move the edit cursor (playback follows)" },
    { K.MOD_LABEL .. " + Wheel", "Zoom the timeline", panel = { "View", 3, "Zoom time" } },
    { "Wheel", "Scroll the pitch axis" },
    { "Alt + Wheel", "Zoom the pitch axis", panel = { "View", 5, "Zoom pitch" } },
    { "Shift + Wheel or horizontal scroll", "Scroll the timeline (when zoomed)", panel = { "View", 4, "Scroll time", "Shift + Wheel" } },
    { "Z", "Zoom to the selected notes", panel = { "View", 1, "Zoom to selection" } },
    { "F", "Show the whole item, fit the pitch range", panel = { "View", 2, "Fit whole item" } },
    { "Drag the overview strip", "Scroll; drag an end to zoom" },
    { "Drag the pitch strip", "Scroll; drag an end to zoom" },
    { "↑ / ↓", "Nudge pitch ±1 semitone", panel = { "Edit", 1, "±1 semitone" } },
    { "Shift + ↑ / ↓", "Fine-tune pitch ±10 cents", panel = { "Edit", 2, "±10 cents" } },
    { "S / Double-Click", "Snap note to nearest semitone", panel = { "Edit", 5, "Snap to semitone", "Double-click" } },
    { "Q", "Quantize selected note(s) to scale", panel = { "Edit", 6, "Quantize to scale" } },
    { "B", "Bypass the selected notes (again: turn bypass off)", panel = { "Edit", 4, "Bypass note" } },
    { "R / Backspace / Delete", "Reset note(s) to original detected pitch", panel = { "Edit", 3, "Reset pitch", "R" } },
    { "Right-click a note", "Note menu: bypass, mode, values, pitch points", panel = { "Edit", 9, "Note menu", "Right-click" } },
    { "Click the pill", "Apply values to other items, or reset this item to defaults" },
    { "Right-click a top bar value", "Reset, or apply it to other items" },
    { "Double-click a value", "Back to the item's value (notes) or the default (item)" },
    { K.MOD_LABEL .. "-click a value", "Type a number" },
    { "Hover or drag a setting", "Shows on the notes where it acts" },
    { "Note action bar (under the selected note)", "Snap · Quantize · Cursor · Split · Merge (S / Q / C / X / M)" },
    { "Drag the bar's grip (its left end)", "Move the bar; double-click it to put it back under the note" },
  } },
  { title = "Note Topology & REAPER Transport", rows = {
    { "X", "Split note at REAPER edit cursor", panel = { "Edit", 7, "Split at cursor" } },
    { "M", "Merge 2+ contiguous selected notes", panel = { "Edit", 8, "Merge notes" } },
    { "W", "Edit cursor to the start of the item", panel = { "General", 2, "Go to item start" } },
    { "C", "Edit cursor to the middle of the selected note", panel = { "General", 3, "Cursor to note" } },
    { "Hold C + Wheel", string.format("Move the edit cursor (wheel up = later, %s = fine)", K.MOD_LABEL),
      panel = { "General", 4, "Move cursor", "C + Wheel" } },
    { "Space", "Runs your REAPER action for Space (default Play/Stop)", panel = { "General", 1, "Play / stop" } },
    { "Shift / " .. K.MOD_LABEL .. " / Alt + Space", "Your REAPER actions for those chords" },
  } },
  { title = "Icons", rows = {
    { "… (top right)", "More: Analyze, Analyze Selected Items, Find Range and Key Again, Reset, Layers, Note Tone, Settings, Help" },
    { "Analysis modal", "Re-Analyze… opens the analysis settings; Enter analyzes, Esc cancels" },
    { "× (top right)", "Close the window (Esc when floating)" },
    { "> / <", "Hide / show the Pitched Items panel" },
    { "▾ / ▸ (section header)", "Collapse / expand the section" },
    { "Checkbox (item row)", "Pitch envelope active / bypassed" },
    { "× (item row)", "Remove the item from Pitched Items" },
    { "* after a value", "Differs from the default (a note: from its item)" },
  } },
}
K.INFO_TERMS = "Reset reverts note edits · Clear discards analysis · Remove drops an item · Wipe removes all"
-- How the analysis finds the range and key: { label, sentence }, drawn under the Terms line in its style
K.INFO_NOTES = {
  { "Auto", "Vocal Range and Key on Auto hear the whole track once, before its first analysis, for the singer's range and the song's key." },
  { "Find Range and Key Again", "In the … menu, it hears the track afresh; items already analyzed keep theirs." },
}

--- The body of the Pitched Items section: the unreadable-data banner, then the item rows (or the empty text).
K.draw_items_body = function(sidebar_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout

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
  local row_action = nil   -- the row menu's or Remove Selected's choice, run after the list is drawn
  -- While an analysis runs (one item or a batch) the list is read-only: the analysis owns the open item, and an
  -- item's envelope and stored analysis must not change under it. The reason is in each row's tooltip.
  local rows_locked = state.is_analyzing or K.batch ~= nil
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

  -- Header line: the "On" label over the bypass checkboxes (the checkbox has no text of its own) and, while two or
  -- more rows are selected, Remove Selected at the right end. The line is always a frame tall, so the rows do not
  -- move when the button appears.
  local sel_list = K.row_sel_sync()
  do
    local line_x = reaper.ImGui_GetCursorPosX(sidebar_ctx)
    local line_y = reaper.ImGui_GetCursorPosY(sidebar_ctx)
    local pushed = Theme.push_font(sidebar_ctx, fonts.small)
    local label_w, label_h = reaper.ImGui_CalcTextSize(sidebar_ctx, BODY.col_on)
    reaper.ImGui_SetCursorPos(sidebar_ctx, line_x + card_margin_x + card_pad_x + math.floor((frame_h - label_w) * 0.5), line_y)
    Theme.vcenter(sidebar_ctx, label_h, frame_h, line_y)
    reaper.ImGui_TextColored(sidebar_ctx, P.text_dim, BODY.col_on)
    Theme.pop_font(sidebar_ctx, pushed)

    if #sel_list >= 2 then
      local btn_w = (reaper.ImGui_CalcTextSize(sidebar_ctx, BODY.sel_remove)) + L.md * 2
      local btn_x = line_x + avail_w - card_margin_x - card_pad_x - btn_w
      reaper.ImGui_SetCursorPos(sidebar_ctx, math.max(line_x + card_margin_x + card_pad_x + frame_h + gap, btn_x), line_y)
      if rows_locked then reaper.ImGui_BeginDisabled(sidebar_ctx) end
      K.push_danger(P)
      local remove_clicked = reaper.ImGui_Button(sidebar_ctx, BODY.sel_remove .. "###sel_remove", btn_w, frame_h)
      K.pop_danger()
      if rows_locked then
        reaper.ImGui_EndDisabled(sidebar_ctx)
        if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
          Theme.tooltip(sidebar_ctx, K.REASON_ANALYZING)
        end
      elseif reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(sidebar_ctx, string.format(BODY.sel_remove_tip_fmt, #sel_list))
      end
      if remove_clicked and not rows_locked then row_action = { kind = "remove_selected" } end
    end

    reaper.ImGui_SetCursorPos(sidebar_ctx, line_x, line_y)
    reaper.ImGui_Dummy(sidebar_ctx, avail_w, frame_h)
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
        local is_selected = state.row_sel[guid] == true
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

        -- 1. Card: the active row is the selection tint (P.select) with a leading accent bar, a hovered row the
        -- hover fill (P.hover); no border, as the library's rows
        local card_x1 = rx + card_margin_x
        local card_y1 = ry + card_pad_y
        local card_x2 = rx + avail_w - card_margin_x
        local card_y2 = card_y1 + card_h

        local dl = reaper.ImGui_GetWindowDrawList(sidebar_ctx)
        local is_row_hovered = reaper.ImGui_IsMouseHoveringRect(sidebar_ctx, card_x1, card_y1, card_x2, card_y2)
        -- A selected row takes the selection tint; the active row keeps its accent bar (and bold name) either way
        if is_selected then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1, card_x2, card_y2, P.select, L.rounding)
        elseif is_row_hovered then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1, card_x2, card_y2, P.hover, L.rounding)
        end
        if is_active then
          reaper.ImGui_DrawList_AddRectFilled(dl, card_x1, card_y1 + L.xs, card_x1 + bar_w, card_y2 - L.xs, P.accent)
        end
        -- P.text_dim reads at 4.5:1 on the window, not on those fills (3.8:1 on the tint, 4.0:1 on the hover fill):
        -- on a filled card the dim name and the state tag take P.text (the tag's words still say the state)
        local dim_col = (is_selected or is_row_hovered) and P.text or P.text_dim

        -- 2. Elements on one line inside the card, each centred on it
        local x_left = start_x + card_margin_x + card_pad_x
        local x_right = start_x + avail_w - card_margin_x - card_pad_x
        local line_y = start_y + card_pad_y
        reaper.ImGui_SetCursorPos(sidebar_ctx, x_left, line_y)

        -- Bypass checkbox: default frame padding; disabled (and unchecked) when the item no longer exists
        local is_enabled = (not is_missing) and not is_take_pitch_bypassed(take_obj)
        Theme.vcenter(sidebar_ctx, frame_h, card_h, line_y)
        local cb_off = is_missing or rows_locked
        if cb_off then reaper.ImGui_BeginDisabled(sidebar_ctx) end
        -- The panel's surface is the recessed one, so the box takes the button face to keep its boundary visible
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_FrameBg(), P.btn)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_FrameBgHovered(), P.btn_h)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_FrameBgActive(), P.btn_a)
        local cb_changed, new_en = reaper.ImGui_Checkbox(sidebar_ctx, "##bp", is_enabled)
        reaper.ImGui_PopStyleColor(sidebar_ctx, 3)
        if cb_off then reaper.ImGui_EndDisabled(sidebar_ctx) end
        local cb_w = reaper.ImGui_GetItemRectSize(sidebar_ctx)
        if cb_changed and not cb_off then
          toggle_take_pitch_bypass(take_obj)
        end
        if cb_off then
          if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
            Theme.tooltip(sidebar_ctx, is_missing and BODY.tip_missing or K.REASON_ANALYZING)
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
        local name_col = (is_missing and dim_col) or P.text
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_Text(), name_col)
        -- The row card draws its own hover fill: the selectable adds none (an opaque P.hover would cover the
        -- active row's blue tint in the name area)
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_HeaderHovered(), Theme.with_alpha(P.hover, 0))
        reaper.ImGui_PushStyleColor(sidebar_ctx, reaper.ImGui_Col_HeaderActive(),  Theme.with_alpha(P.hover, 0))
        reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
        reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_SelectableTextAlign(), 0, 0.5)
        reaper.ImGui_SetCursorPosY(sidebar_ctx, line_y)
        if rows_locked then reaper.ImGui_BeginDisabled(sidebar_ctx) end
        local renaming = K.rename ~= nil and K.rename.guid == guid and not rows_locked and not is_missing
        if renaming then
          K.draw_rename_field(sidebar_ctx, guid, name_w, card_h, line_y)
        elseif reaper.ImGui_Selectable(sidebar_ctx, sel_text .. "###sel", false, reaper.ImGui_SelectableFlags_None(), name_w, card_h)
           and not rows_locked then
          -- Cmd/Ctrl-click toggles the row, Shift-click selects the range from the anchor (both leave the active item
          -- alone); a plain click makes the row active and the only one selected
          local mods = reaper.ImGui_GetKeyMods(sidebar_ctx) or 0
          if (mods & reaper.ImGui_Mod_Shift()) ~= 0 then
            row_action = { kind = "range", guid = guid, index = index }
          elseif (mods & reaper.ImGui_Mod_Ctrl()) ~= 0 then
            row_action = { kind = "toggle", guid = guid }
          else
            row_action = { kind = "click", guid = guid, take = take_obj }
          end
        end
        -- Double-click on the name renames the item in place (the first click of it made the row active)
        if not renaming and not rows_locked and not is_missing
           and reaper.ImGui_IsItemHovered(sidebar_ctx) and reaper.ImGui_IsMouseDoubleClicked(sidebar_ctx, 0) then
          row_action = { kind = "rename", guid = guid }
        end
        if not renaming and not rows_locked and reaper.ImGui_BeginPopupContextItem(sidebar_ctx, "##row_menu") then
          if reaper.ImGui_Shortcut(sidebar_ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(sidebar_ctx) end
          local rename_reason = is_missing and BODY.menu_rename_missing or nil
          if reaper.ImGui_MenuItem(sidebar_ctx, BODY.menu_rename, rename_reason, false, rename_reason == nil) then
            row_action = { kind = "rename", guid = guid }
          end
          if reaper.ImGui_MenuItem(sidebar_ctx, BODY.menu_remove_one) then
            row_action = { kind = "remove_one", guid = guid }
          end
          local sel_n = #sel_list
          local sel_reason = sel_n == 0 and BODY.menu_no_selection or nil
          if reaper.ImGui_MenuItem(sidebar_ctx, string.format(BODY.menu_remove_sel_fmt, sel_n) .. "###menu_remove_sel",
               sel_reason, false, sel_reason == nil) then
            row_action = { kind = "remove_selected" }
          end
          reaper.ImGui_Separator(sidebar_ctx)
          local all_n = #state.session_order
          if reaper.ImGui_MenuItem(sidebar_ctx, string.format(BODY.menu_wipe_fmt, all_n) .. "###menu_wipe") then
            row_action = { kind = "wipe" }
          end
          reaper.ImGui_EndPopup(sidebar_ctx)
        end
        if rows_locked then reaper.ImGui_EndDisabled(sidebar_ctx) end
        reaper.ImGui_PopStyleVar(sidebar_ctx, 2)
        reaper.ImGui_PopStyleColor(sidebar_ctx, 3)
        if name_font then Theme.pop_font(sidebar_ctx, name_font) end

        if rows_locked then
          if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
            Theme.tooltip(sidebar_ctx, K.tip("Item: " .. full_name, K.REASON_ANALYZING))
          end
        elseif not renaming and reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          -- Name and note count, then the state, then the clicks: one paragraph each
          local facts, state_para = "Item: " .. full_name, state_tip
          if not is_missing then
            facts = facts .. string.format("\nNotes: %d", data.notes and #data.notes or 0)
            if state_tip then state_para = "Outdated: " .. state_tip end
          end
          Theme.tooltip(sidebar_ctx, K.tip(facts, state_para, BODY.row_click_tip))
        end

        -- State tag (dim text, never colour alone), right before the X
        if tag_w > 0 then
          reaper.ImGui_SameLine(sidebar_ctx, 0, gap)
          local pushed_small = Theme.push_font(sidebar_ctx, fonts.small)
          Theme.vcenter(sidebar_ctx, tag_h, card_h, line_y)
          reaper.ImGui_TextColored(sidebar_ctx, dim_col, state_tag)
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
        if rows_locked then reaper.ImGui_BeginDisabled(sidebar_ctx) end
        if Theme.icon_btn(sidebar_ctx, "##del", Theme.icons.close, {
          preset = L.icon_target,
          icon_size = L.icon_md.size,   -- the glyph matches the other icons; only the click target is 24 px
          w = del_sz, h = del_sz,       -- icon_btn sizes the button from icon_size unless told otherwise
          color = P.text_dim,
          hover_color = P.red,
          tooltip = "Remove from Pitched Items and clear its envelope and saved analysis (asks to confirm)"
        }) and not rows_locked then
          to_remove = guid
        end
        if rows_locked then
          reaper.ImGui_EndDisabled(sidebar_ctx)
          -- A theme widget's own tooltip does not show on a disabled item: the reason is given here
          if reaper.ImGui_IsItemHovered(sidebar_ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
            Theme.tooltip(sidebar_ctx, K.REASON_ANALYZING)
          end
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
  K.run_row_action(row_action)
end

--- Select in the arrange view the items of the selected Pitched Items rows, and only those (like a click on an item
--- in REAPER: no undo point). The selection follower is then told what is selected now, so the first selected item
--- (which may not be the active row after a Shift- or Cmd-click) does not switch the active item.
K.mirror_row_sel_to_arrange = function()
  local items = {}
  for _, g in ipairs(state.session_order) do
    if state.row_sel[g] then
      local take = resolve_take_by_guid(g, true)
      local item = take and K.take_item(take) or nil
      if item then items[#items + 1] = item end
    end
  end
  if #items == 0 then return end   -- nothing to select (items gone): leave REAPER's selection alone

  reaper.PreventUIRefresh(1)
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(items) do reaper.SetMediaItemSelected(item, true) end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  local sel_item = reaper.GetSelectedMediaItem(0, 0)
  local sel_take = sel_item and reaper.GetActiveTake(sel_item) or nil
  state.last_seen_sel_guid = (sel_take and not reaper.TakeIsMIDI(sel_take)) and get_take_guid(sel_take) or nil
end

--- Carry out what a row click, the row menu or Remove Selected asked for (after the list was drawn).
K.run_row_action = function(a)
  if not a then return end
  if a.kind == "click" then
    switch_active_target(a.guid, a.take)
    state.row_sel = { [a.guid] = true }
    state.row_anchor = a.guid
    state.row_sel_target = state.target_take_guid
  elseif a.kind == "toggle" then
    state.row_sel[a.guid] = (not state.row_sel[a.guid]) or nil
    state.row_anchor = a.guid
  elseif a.kind == "range" then
    local anchor_i = nil
    for i, g in ipairs(state.session_order) do
      if g == state.row_anchor then anchor_i = i break end
    end
    anchor_i = anchor_i or a.index
    local lo, hi = math.min(anchor_i, a.index), math.max(anchor_i, a.index)
    state.row_sel = {}
    for i = lo, hi do
      local g = state.session_order[i]
      if g then state.row_sel[g] = true end
    end
  end
  if a.kind == "click" or a.kind == "toggle" or a.kind == "range" then
    K.mirror_row_sel_to_arrange()
  elseif a.kind == "remove_one" then
    request_remove_confirm(a.guid)
  elseif a.kind == "remove_selected" then
    K.request_remove_selected_confirm()
  elseif a.kind == "wipe" then
    request_wipe_confirm()
  elseif a.kind == "rename" then
    local data = state.session_takes[a.guid]
    if data then K.rename = { guid = a.guid, text = data.name or "", focus = true } end
  end
end

--- The in-place rename field of a Pitched Items row (K.rename = { guid, text, focus }), drawn where the name is.
--- Enter renames the take in REAPER; Esc or a click elsewhere leaves the name as it was (as the typed value entry).
K.draw_rename_field = function(rctx, guid, w, card_h, line_y)
  local r = K.rename
  local frame_h = reaper.ImGui_GetFrameHeight(rctx) or card_h
  reaper.ImGui_SetCursorPosY(rctx, line_y + math.max(0, (card_h - frame_h) * 0.5))
  reaper.ImGui_SetNextItemWidth(rctx, w)
  if r.focus then
    reaper.ImGui_SetKeyboardFocusHere(rctx)
    r.focus = false
    r.shown = false
  end
  local entered, text = reaper.ImGui_InputText(rctx, "##rename", r.text,
    reaper.ImGui_InputTextFlags_EnterReturnsTrue() | reaper.ImGui_InputTextFlags_AutoSelectAll())
  if type(text) == "string" then r.text = text end
  local active = reaper.ImGui_IsItemActive(rctx)
  if entered then
    K.rename = nil
    K.rename_take(guid, r.text)
  elseif r.shown and not active then
    K.rename = nil
    K.drag_hot.esc_used = true   -- an Esc that ended the entry is spent (HC5): it does not also clear a selection
  end
  if active then r.shown = true end
end

--- Rename the take of a Pitched Items row in REAPER (one undo point). The list reads the name back from the take.
K.rename_take = function(guid, text)
  local name = tostring(text or ""):match("^%s*(.-)%s*$")
  local data = state.session_takes[guid]
  local take = resolve_take_by_guid(guid)
  if not data or not take or name == "" or name == reaper.GetTakeName(take) then return end
  reaper.Undo_BeginBlock()
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  reaper.Undo_EndBlock("Rename Take", -1)
  reaper.UpdateArrange()
  data.name = name
  if guid == state.target_take_guid then state.target_take_name = name end
  set_status(string.format("Renamed to \"%s\". %s+Z to undo.", name, K.MOD_LABEL))
end

-- The panel's Shortcuts groups, in the order they are drawn
K.PANEL_GROUPS = { "Select", "Edit", "View", "General" }

--- The Shortcuts list of the panel: { { group = name, rows = { { key, text }, ... } }, ... } in K.PANEL_GROUPS order,
--- built once from the rows of K.INFO_SECTIONS that carry a `panel` field.
K.panel_rows = function()
  if K.panel_rows_cache then return K.panel_rows_cache end
  local by_group = {}
  for _, name in ipairs(K.PANEL_GROUPS) do by_group[name] = {} end
  for _, section in ipairs(K.INFO_SECTIONS) do
    for _, row in ipairs(section.rows) do
      local p = row.panel
      if p and by_group[p[1]] then
        local list = by_group[p[1]]
        list[#list + 1] = { key = p[4] or row[1], text = p[3], order = p[2] }
      end
    end
  end
  local out = {}
  for _, name in ipairs(K.PANEL_GROUPS) do
    table.sort(by_group[name], function(a, b) return a.order < b.order end)
    out[#out + 1] = { group = name, rows = by_group[name] }
  end
  K.panel_rows_cache = out
  return out
end

--- The colour of the key text in the Shortcuts list: the accent, as in the Help modal, when it reads at 4.5:1 on the
--- panel's surface (HC1), else the text colour (a Match Theme accent can be too close to the background).
K.panel_key_color = function(P)
  local c = K.panel_key_cache
  if c and c.accent == P.accent and c.inset == P.inset and c.text == P.text then return c.color end
  local function luminance(rgba)
    local function channel(v)
      v = v / 255
      return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * channel((rgba >> 24) & 0xFF) + 0.7152 * channel((rgba >> 16) & 0xFF) + 0.0722 * channel((rgba >> 8) & 0xFF)
  end
  local la, lb = luminance(P.accent), luminance(P.inset)
  local ratio = (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
  local color = ratio >= 4.5 and P.accent or P.text
  K.panel_key_cache = { accent = P.accent, inset = P.inset, text = P.text, color = color }
  return color
end

--- Fold or unfold a section of the panel ("items" or "shortcuts"); the preference is stored when it changes.
K.set_panel_open = function(which, open)
  local field = which == "items" and "items_open" or "shortcuts_open"
  open = open and true or false
  if state[field] == open then return end
  state[field] = open
  reaper.SetExtState("FancyScripts", which == "items" and "pitch_items_open" or "pitch_shortcuts_open", open and "1" or "0", true)
end

--- Heights of the two section bodies. avail_h = the room under the two headers. Both unfolded: Pitched Items is as tall as
--- its content, at most half of the room, and Shortcuts takes the rest. One unfolded: it takes everything. Never negative.
K.panel_heights = function(avail_h, items_content_h, items_open, shortcuts_open)
  avail_h = math.max(0, math.floor(avail_h))
  if items_open and shortcuts_open then
    local items_h = math.max(0, math.min(math.ceil(items_content_h), avail_h // 2))
    return items_h, avail_h - items_h
  elseif items_open then
    return avail_h, 0
  elseif shortcuts_open then
    return 0, avail_h
  end
  return 0, 0
end

--- The top bar's panel button: show or hide the side panel (the preference is stored). A window too narrow for the
--- panel records the wish to see it and says why nothing changed.
K.toggle_sidebar = function()
  local open = not (state.sidebar_open and state.sidebar_fits)
  if open ~= state.sidebar_open then
    state.sidebar_open = open
    reaper.SetExtState("FancyScripts", "pitch_sidebar_open", open and "1" or "0", true)
  end
  if open and not state.sidebar_fits then set_status(BODY.panel_narrow_status) end
end

--- H: show or hide the Shortcuts list. A hidden panel comes back with the list unfolded; a window too narrow for the
--- panel changes nothing and says why.
K.toggle_shortcuts = function()
  if not state.sidebar_fits then
    set_status(BODY.shortcuts_narrow_status)
  elseif not state.sidebar_open then
    state.sidebar_open = true
    reaper.SetExtState("FancyScripts", "pitch_sidebar_open", "1", true)
    K.set_panel_open("shortcuts", true)
  else
    K.set_panel_open("shortcuts", not state.shortcuts_open)
  end
end

--- Measure the widest key and the widest description of the Shortcuts list in the font pushed now (K.panel_key_w,
--- K.panel_text_w); measured again only when the font size changes.
K.panel_measure = function(measure_ctx)
  local font_h = reaper.ImGui_GetFontSize(measure_ctx)
  if K.panel_key_w_font == font_h then return end
  local key_w, text_w = 0, 0
  for _, g in ipairs(K.panel_rows()) do
    for _, row in ipairs(g.rows) do
      key_w = math.max(key_w, (reaper.ImGui_CalcTextSize(measure_ctx, row.key)) or 0)
      text_w = math.max(text_w, (reaper.ImGui_CalcTextSize(measure_ctx, row.text)) or 0)
    end
  end
  K.panel_key_w, K.panel_text_w, K.panel_key_w_font = key_w, text_w, font_h
end

--- The panel width at which every Shortcuts row fits on one line: the default width, taken from the text in the font in
--- use (never a pixel constant). The parts mirror draw_body_split (the panel's inset) and K.draw_shortcuts_body (the
--- list's indent, the key column, both columns' cell padding) plus the room of the body's scrollbar.
K.panel_fit_w = function(measure_ctx)
  local L = Theme.layout
  K.panel_measure(measure_ctx)
  local scrollbar_w = reaper.ImGui_GetStyleVar(measure_ctx, reaper.ImGui_StyleVar_ScrollbarSize()) or 0
  return math.ceil(L.sm * 2 + L.sm * 2 + (K.panel_key_w + L.sm) + K.panel_text_w + L.xs * 4 + scrollbar_w) + 1
end

--- The body of the Shortcuts section: one heading per group, the key in a fixed column as wide as the widest key, the
--- description wrapping in the rest. Reference text only (no hover, no click).
K.draw_shortcuts_body = function(sidebar_ctx)
  local P = Theme.get_palette()
  local L = Theme.layout
  local groups = K.panel_rows()
  local key_col = K.panel_key_color(P)

  -- The widest key in the font drawn now, measured again only when the font size changes
  K.panel_measure(sidebar_ctx)

  local avail_w = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)
  local table_w = math.max(1, avail_w - L.sm * 2)
  local table_flags = reaper.ImGui_TableFlags_SizingFixedFit() | reaper.ImGui_TableFlags_NoSavedSettings()
  reaper.ImGui_Indent(sidebar_ctx, L.sm)
  reaper.ImGui_PushStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_CellPadding(), L.xs, L.xs)
  for i, g in ipairs(groups) do
    -- Theme.section_divider brings its own air above and below: no extra gap between the groups
    Theme.section_divider(sidebar_ctx, g.group, { color = P.yellow })
    if reaper.ImGui_BeginTable(sidebar_ctx, "##panel_keys_" .. i, 2, table_flags, table_w, 0) then
      reaper.ImGui_TableSetupColumn(sidebar_ctx, "##key", reaper.ImGui_TableColumnFlags_WidthFixed(), K.panel_key_w + L.sm)
      reaper.ImGui_TableSetupColumn(sidebar_ctx, "##text", reaper.ImGui_TableColumnFlags_WidthStretch(), 1)
      for _, row in ipairs(g.rows) do
        reaper.ImGui_TableNextRow(sidebar_ctx)
        reaper.ImGui_TableSetColumnIndex(sidebar_ctx, 0)
        reaper.ImGui_TextColored(sidebar_ctx, key_col, row.key)
        reaper.ImGui_TableSetColumnIndex(sidebar_ctx, 1)
        reaper.ImGui_TextWrapped(sidebar_ctx, row.text)
      end
      reaper.ImGui_EndTable(sidebar_ctx)
    end
  end
  reaper.ImGui_PopStyleVar(sidebar_ctx, 1)
  reaper.ImGui_Unindent(sidebar_ctx, L.sm)
  reaper.ImGui_Dummy(sidebar_ctx, 0, L.sm)
end

--- The panel: two sections, Pitched Items and Shortcuts, each a header that folds its body. Each body scrolls on its own
--- inside the height K.panel_heights gives it; the panel itself never scrolls.
local function render_pitched_items_sidebar(sidebar_ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(sidebar_ctx)
  local _, spacing_y = reaper.ImGui_GetStyleVar(sidebar_ctx, reaper.ImGui_StyleVar_ItemSpacing())
  spacing_y = spacing_y or 0

  -- 1. Pitched Items header: the fold arrow and the count (the panel itself is shown and hidden from the top bar)
  reaper.ImGui_SetNextItemOpen(sidebar_ctx, state.items_open, reaper.ImGui_Cond_Always())
  local items_open = Theme.collapsing_header(sidebar_ctx,
    string.format("Pitched Items (%d)##pitch_items_hdr", #state.session_order))
  K.set_panel_open("items", items_open)

  -- The room under the two headers (the Shortcuts header and the gaps around the bodies come off what is left here)
  local _, left_h = reaper.ImGui_GetContentRegionAvail(sidebar_ctx)
  local gaps = (state.items_open and 1 or 0) + (state.shortcuts_open and 1 or 0)
  local avail_h = (left_h or 0) - frame_h - spacing_y * gaps
  local items_h, shortcuts_h = K.panel_heights(avail_h, state.items_content_h or math.huge, state.items_open, state.shortcuts_open)

  -- 2. Pitched Items body
  if state.items_open and items_h >= 1 then
    if reaper.ImGui_BeginChild(sidebar_ctx, "##pitch_items_body", 0, items_h, 0) then
      K.draw_items_body(sidebar_ctx)
      -- The cursor ends under the last row (the clipper counts the rows it skipped): the content's height
      state.items_content_h = reaper.ImGui_GetCursorPosY(sidebar_ctx)
      reaper.ImGui_EndChild(sidebar_ctx)
    end
  end

  -- 3. Shortcuts header and body
  reaper.ImGui_SetNextItemOpen(sidebar_ctx, state.shortcuts_open, reaper.ImGui_Cond_Always())
  local shortcuts_open = Theme.collapsing_header(sidebar_ctx, "Shortcuts##pitch_shortcuts_hdr")
  K.set_panel_open("shortcuts", shortcuts_open)
  if state.shortcuts_open and shortcuts_h >= 1 then
    if reaper.ImGui_BeginChild(sidebar_ctx, "##pitch_shortcuts_body", 0, shortcuts_h, 0) then
      K.draw_shortcuts_body(sidebar_ctx)
      reaper.ImGui_EndChild(sidebar_ctx)
    end
  end

  -- The body's top hairline (see the main window) continues over the panel: the first header sits on the panel's
  -- top edge and would cover a line drawn under this child
  local panel_x, panel_y = reaper.ImGui_GetWindowPos(sidebar_ctx)
  local panel_w = reaper.ImGui_GetWindowWidth(sidebar_ctx)
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(sidebar_ctx),
    panel_x, panel_y, panel_x + panel_w, panel_y, Theme.get_palette().canvas.ruler_edge)
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

  -- No stored width: the default is the width at which every Shortcuts row fits on one line. It is not saved (only a
  -- drag of the divider is), so it follows the font; the clamps below still keep the canvas its minimum.
  if state.sidebar_auto then
    state.sidebar_auto = false
    state.sidebar_w = K.panel_fit_w(ctx)
    state.stored["pitch_sidebar_w"] = string.format("%.0f", state.sidebar_w)
    state.sidebar_tabled = false
  end

  local max_sidebar_w = math.max(BODY.min_sidebar_w, avail_w - BODY.min_graph_w - BODY.splitter_w)
  local wanted_w = math.max(BODY.min_sidebar_w, math.min(max_sidebar_w, state.sidebar_w))
  -- A drag may run past the limits while the button is down; the width snaps back on release
  if not state.sidebar_tabled or (math.abs(wanted_w - state.sidebar_w) > BODY.width_eps and not mouse_down) then
    state.sidebar_w = wanted_w
    state.sidebar_gen = state.sidebar_gen + 1
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

    -- Right: Pitched Items panel, inset from the grip and, by as much, from the window's edge (the window has no padding)
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    local grip_x, grip_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local column_w = reaper.ImGui_GetContentRegionAvail(ctx)
    state.sidebar_w = column_w
    -- The panel has its own recessed surface, so it reads as a panel beside the canvas
    reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
      grip_x, grip_y, grip_x + column_w, grip_y + total_h, P.inset)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + L.sm)
    local panel_w = math.max(column_w, BODY.min_sidebar_w) - L.sm * 2
    -- The panel never scrolls itself: each of its two sections scrolls its own body
    local panel_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    if reaper.ImGui_BeginChild(ctx, "##pitched_items_sidebar", panel_w, total_h, 0, panel_flags) then
      render_pitched_items_sidebar(ctx)
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

--- The { lowest, highest } a detection row's drag allows for `key` of the values `v`: K.LIMITS[key], except that
--- Min Freq stays 1 Hz below v.max_freq and Max Freq 1 Hz above v.min_freq (K.analysis_values needs min < max).
K.drag_bounds = function(key, v)
  local lim = K.LIMITS[key]
  local lo, hi = lim[1], lim[2]
  if key == "min_freq" then
    hi = math.max(lo, math.min(hi, (tonumber(v.max_freq) or hi + 1) - 1))
  elseif key == "max_freq" then
    lo = math.min(hi, math.max(lo, (tonumber(v.min_freq) or lo - 1) + 1))
  end
  return lo, hi
end

--- Value control of the detection rows: a param_drag on b.v[key] within K.drag_bounds(key, b.v), `width` wide and without a
--- label (the form's label column names it); double-click restores the row's default (b.reset(key); the key is the
--- row id). `b` is the row binding (see K.settings_binding): the value is committed once the edit is done (the drag
--- released, a typed entry confirmed, a reset), not while it moves.
local function settings_drag(id, key, fmt, width, b)
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local raw = b.v[key]
  local lo, hi = K.drag_bounds(key, b.v)
  local changed, v, committed, reset, cancelled = param_drag(ctx, id, nil, raw, lo, hi, fmt)
  local back = K.drag_revert(id, raw, cancelled)
  if back ~= nil then
    b.set(key, back)   -- Esc during the drag: the value from before it, nothing committed
  elseif reset then
    b.reset(key)
  elseif changed then
    b.set(key, v)
  end
  if committed then b.commit() end
end

--- The control of the Min Freq / Max Freq row (`key`), `w` wide: a settings_drag, disabled while Vocal Range is
--- Auto with its reason (K.auto_hz_reason) as its tooltip and, when `inline`, as dim text after it (the drag then
--- takes what is left of `w`).
K.hz_row_draw = function(id, key, w, b, inline)
  local reason = K.auto_hz_reason(b.v)
  if not reason then
    settings_drag(id, key, "%.0f Hz", w, b)
    return
  end
  local L = Theme.layout
  local text_w = inline and ((reaper.ImGui_CalcTextSize(ctx, reason)) or 0) + L.sm or 0
  reaper.ImGui_BeginDisabled(ctx, true)
  settings_drag(id, key, "%.0f Hz", math.max(w - text_w, 1), b)
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    Theme.tooltip(ctx, reason)
  end
  if inline then
    reaper.ImGui_SameLine(ctx, 0, L.sm)
    Theme.align(ctx)
    reaper.ImGui_TextColored(ctx, Theme.get_palette().text_dim, reason)
  end
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

--- The row binding of the Settings: the rows edit `state`, a reset restores the factory DEFAULTS, and a commit saves
--- the engine group and lets an open analysis form follow the new defaults.
K.settings_binding = function()
  local function restore(keys)
    for _, key in ipairs(keys) do state[key] = DEFAULTS[key] end
  end
  return {
    v = state, base = DEFAULTS,
    set = function(key, value)
      for k, v in pairs(K.value_pairs(key, value)) do state[k] = v end
    end,
    reset = function(row_id)
      if row_id == "range" then restore({ "min_freq", "max_freq", "auto_range" })
      elseif row_id == "mode" then restore({ "threshold" })
      elseif row_id == "quality" then restore({ "block_size", "hop_size" })
      elseif row_id == "block" then
        state.block_size = DEFAULTS.block_size
        if state.hop_size > state.block_size then state.hop_size = state.block_size end
      elseif row_id == "hop" then state.hop_size = math.min(DEFAULTS.hop_size, state.block_size)
      else   -- threshold, min_freq, max_freq (both Hz back at the factory ones: the factory range, Auto included)
        restore({ row_id })
        if row_id == "min_freq" or row_id == "max_freq" then K.hz_reset_follows(state, DEFAULTS) end
      end
    end,
    commit = function()
      K.save_settings("engine")
      local guid = state.target_take_guid
      if guid then K.form_sync(guid, state.session_takes[guid]) end
    end,
  }
end

--- The row binding of an analysis form (K.form_new): the rows edit form.values and mark what the user changed, a
--- reset goes back to the Settings' values, and nothing is saved.
K.form_binding = function(form)
  return {
    v = form.values, base = K.analysis_defaults(),
    set = function(key, value) K.form_set(form, key, value) end,
    reset = function(row_id)
      K.form_reset_row(form, row_id)
      if form.values.hop_size > form.values.block_size then form.values.hop_size = form.values.block_size end
    end,
    commit = function() end,
  }
end

--- The line under the Analysis Defaults divider.
K.ANALYSIS_DEFAULTS_NOTE = "New analyses start with these. Each item keeps the settings it was analyzed with."

--- Tooltips of the three preset rows (shared by the Settings and the analysis form).
-- One paragraph per choice, its key difference first. The note names are the VOCAL_RANGES limits rounded to the
-- nearest note; the lowest notes of each Quality are its block's limit (half a block per period) at 48 kHz.
K.ROW_TIPS = {
  range = "Vocal Range\n\nThe pitches searched. Pick the singer's range to avoid octave errors."
    .. "\n\nAuto: Listens through the whole track first to find the singer's lowest and highest notes. Done once per track."
    .. "\n\nGeneric Vocal: C2 to B5 (65 to 1000 Hz), any voice."
    .. "\n\nSoprano: B3 to D6 (250 to 1200 Hz)."
    .. "\n\nAlto: F3 to G5 (170 to 800 Hz)."
    .. "\n\nTenor: C3 to B4 (130 to 500 Hz)."
    .. "\n\nBass: E2 to F4 (80 to 350 Hz).",
  mode = "Detection Mode\n\nHow clear a sound must be to count as a note."
    .. "\n\nClean / Strict: only clear, steady tone. Ignores breath and noise; may drop soft notes."
    .. "\n\nStandard: the balance for most takes."
    .. "\n\nBreathy / Lenient: catches airy, soft singing; may also catch breath and noise.",
  quality = "Quality / CPU\n\nHow finely the audio is measured, and how long it takes."
    .. "\n\nHigh Quality (Offline): finest pitch and timing, reaches the lowest voices. Slowest."
    .. "\n\nStandard (Realtime): quicker, coarser timing. Misses notes below about F#2 (94 Hz)."
    .. "\n\nLow Latency: fastest, fine timing. Misses notes below about F#3 (188 Hz).",
}

-- The Settings forms: Pitch Shift Engine, Analysis Defaults, Advanced DSP. A row knows its label, whether its
-- value is the factory one (DEFAULTS), how to restore it, and how to draw its control `w` pixels wide; the detection and dsp rows take the binding `b`
-- of the table they edit (K.settings_binding, K.form_binding): is_default(b), reset(b), draw(w, b); a preset combo
-- reads "Custom" when the values match none of its presets. K.form_rows_draw lays the rows out as label | control |
-- Reset, and a section's "Reset section" walks the same rows. `labels` = every text the control can show and `fit` =
-- the width it needs at least (they size the control column).
K.SETTINGS_SECTIONS = {
  { id = "engine", title = "Pitch Shift Engine", rows = {
    { id = "pitchmode", label = "Pitch Shift Algorithm", labels = COMBO_LABELS.pitchmodes,
      is_default = function() return state.preset_pitchmode_idx == DEFAULTS.preset_pitchmode_idx end,
      reset = function() K.set_pitch_algorithm(DEFAULTS.preset_pitchmode_idx) end,
      draw = function(w)
        local idx, changed = Theme.combo(ctx, "##settings_pitchmode", PITCHMODE_FLAT, state.preset_pitchmode_idx, {
          w = w,
          tooltip = "Pitch Shift Algorithm\n\nElastique Soloist (Monophonic) is recommended for vocals.\n\nApplied automatically to the item when writing envelopes.",
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
      reset = function() state.keep_pitch_mode = DEFAULTS.keep_pitch_mode end,
      draw = function()
        local changed, on = reaper.ImGui_Checkbox(ctx, K.KEEP_PITCH_LABEL .. "###keep_pitch_mode", state.keep_pitch_mode)
        if changed then
          state.keep_pitch_mode = on
          K.save_settings("engine")
        end
        if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, "Fancy Pitch Correct then never changes the pitch algorithm of an item: the one set in REAPER stays.\n\nThe Pitch Shift Algorithm above is not used.")
        end
      end },
  } },
  { id = "detection", title = "Analysis Defaults", rows = {
    { id = "range", label = "Vocal Range", labels = COMBO_LABELS.ranges,
      is_default = function(b)
        return b.v.min_freq == b.base.min_freq and b.v.max_freq == b.base.max_freq
          and (b.v.auto_range == true) == (b.base.auto_range == true)
      end,
      reset = function(b) b.reset("range") end,
      draw = function(w, b)
        -- Auto is matched by its flag first: an item analysed with it shows "Auto: E2–A4" whatever Hz it ran with
        local idx, changed = Theme.combo(ctx, "##settings_range", VOCAL_RANGES, K.range_index(b.v), {
          w = w, placeholder = K.CUSTOM_PRESET, tooltip = K.range_tip(b.v),
          get_label = function(r) return (r.auto and b.v.auto_range == true) and K.range_name(b.v) or r.name end,
        })
        if changed and VOCAL_RANGES[idx] then
          b.set("range", VOCAL_RANGES[idx])
          b.commit()
        end
      end },
    { id = "mode", label = "Detection Mode", labels = COMBO_LABELS.detection,
      is_default = function(b) return b.v.threshold == b.base.threshold end,
      reset = function(b) b.reset("mode") end,
      draw = function(w, b)
        local current = K.match_preset(DETECTION_MODES, function(m) return m.threshold == b.v.threshold end)
        local idx, changed = Theme.combo(ctx, "##settings_mode", DETECTION_MODES, current, {
          w = w, placeholder = K.CUSTOM_PRESET, tooltip = K.ROW_TIPS.mode,
        })
        if changed and DETECTION_MODES[idx] then
          b.set("threshold", DETECTION_MODES[idx].threshold)
          b.commit()
        end
      end },
    { id = "quality", label = "Quality / CPU", labels = COMBO_LABELS.quality,
      is_default = function(b) return b.v.block_size == b.base.block_size and b.v.hop_size == b.base.hop_size end,
      reset = function(b) b.reset("quality") end,
      draw = function(w, b)
        local current = K.match_preset(QUALITY_MODES, function(q) return q.block == b.v.block_size and q.hop == b.v.hop_size end)
        local idx, changed = Theme.combo(ctx, "##settings_quality", QUALITY_MODES, current, {
          w = w, placeholder = K.CUSTOM_PRESET, tooltip = K.ROW_TIPS.quality,
        })
        if changed and QUALITY_MODES[idx] then
          b.set("quality", QUALITY_MODES[idx])
          b.commit()
        end
      end },
  } },
  { id = "dsp", title = "Advanced DSP Parameters", rows = {
    -- Discrete choices; a value outside the lists (older state) shows the nearest item. The hop never exceeds the block.
    { id = "block", label = "Block size (samples)", name = "Block size",
      is_default = function(b) return b.v.block_size == b.base.block_size end,
      reset = function(b) b.reset("block") end,
      draw = function(w, b)
        local size, changed = K.size_combo("##dsp_block", BLOCK_SIZES, b.v.block_size, w,
          "Samples analyzed per window (e.g. 512, 1024, 2048).")
        if changed then
          b.set("block_size", size)
          -- The block shrank below the hop: clamp the hop down (every block up to 1024 is also a hop size)
          if b.v.hop_size > b.v.block_size then b.set("hop_size", b.v.block_size) end
          b.commit()
        end
      end },
    -- The default hop never exceeds the block either: a smaller block limits what Reset can restore
    { id = "hop", label = "Hop size (samples)", name = "Hop size",
      is_default = function(b) return b.v.hop_size == math.min(b.base.hop_size, b.v.block_size) end,
      reset = function(b) b.reset("hop") end,
      draw = function(w, b)
        local size, changed = K.size_combo("##dsp_hop", hop_choices(b.v.block_size), b.v.hop_size, w,
          "Samples to advance between analysis windows.")
        if changed then
          b.set("hop_size", size)
          b.commit()
        end
      end },
    { id = "threshold", label = "Detection Threshold",
      is_default = function(b) return b.v.threshold == b.base.threshold end,
      reset = function(b) b.reset("threshold") end,
      draw = function(w, b)
        settings_drag("dsp_threshold", "threshold", "%.2f", w, b)
        if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, "Detection Threshold\n\nThe confidence threshold for pitch detection. Lower is stricter.")
        end
      end },
    -- Disabled while Vocal Range is Auto (K.auto_hz_reason), Reset too: the reason inline after Min Freq and as the
    -- tooltips. Their Hz are then not the user's to set, so they count as at their default
    { id = "min_freq", label = "Min Freq (Hz)", reason = K.auto_hz_reason,
      is_default = function(b) return K.auto_hz_reason(b.v) ~= nil or b.v.min_freq == b.base.min_freq end,
      reset = function(b) b.reset("min_freq") end,
      draw = function(w, b) K.hz_row_draw("dsp_min_freq", "min_freq", w, b, true) end },
    { id = "max_freq", label = "Max Freq (Hz)", reason = K.auto_hz_reason,
      is_default = function(b) return K.auto_hz_reason(b.v) ~= nil or b.v.max_freq == b.base.max_freq end,
      reset = function(b) b.reset("max_freq") end,
      draw = function(w, b) K.hz_row_draw("dsp_max_freq", "max_freq", w, b, false) end },
  } },
}

--- One section as a form: a row per setting (label | control | Reset), bound to `b` (K.settings_binding or
--- K.form_binding). opts: locked (disable everything), stacked (label above the control, and the control takes the
--- width left after Reset), label_w, control_w, reset_w (control_w is the whole width when stacked), reset_hint (the
--- Reset tooltip), default_reason (the disabled Reset's tooltip), id (id suffix, default the section id), and, for a
--- "Reset section" button, section_reset_w, section_hint and section_default_reason. Returns true when
--- "Reset section" was clicked (the caller confirms and resets).
K.form_rows_draw = function(section, b, opts)
  local P = Theme.get_palette()
  local L = Theme.layout
  local locked = opts.locked
  local id = opts.id or section.id
  local section_clicked = false

  --- A text button that is disabled, dim and explained when `reason` is set (the tooltip waits like every tooltip and
  --- also shows on the disabled button). Returns true when it was clicked.
  local function reset_button(label, btn_id, w, reason, hint)
    reaper.ImGui_BeginDisabled(ctx, reason ~= nil)
    if reason then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim) end
    local clicked = reaper.ImGui_Button(ctx, label .. "###" .. btn_id, w, 0)
    if reason then reaper.ImGui_PopStyleColor(ctx, 1) end
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
      Theme.tooltip(ctx, locked and K.locked_reason() or reason or hint)
    end
    return clicked and not locked
  end

  local function row_reset(row)
    local at_default = row.is_default(b)
    -- row.reason (optional): why the whole row is disabled now, Reset included
    local why = row.reason and row.reason(b.v) or (at_default and opts.default_reason or nil)
    if reset_button("Reset", "reset_" .. row.id, opts.reset_w, why, opts.reset_hint) then
      row.reset(b)
      b.commit()
    end
    return at_default
  end

  local differing = 0
  if opts.stacked then
    reaper.ImGui_BeginDisabled(ctx, locked)
    for _, row in ipairs(section.rows) do
      if row.label ~= "" then reaper.ImGui_Text(ctx, row.label) end
      row.draw(math.max(opts.control_w - opts.reset_w - L.sm, 1), b)
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      if not row_reset(row) then differing = differing + 1 end
    end
    reaper.ImGui_EndDisabled(ctx)
    return false
  end

  local form_flags = reaper.ImGui_TableFlags_SizingFixedFit() | reaper.ImGui_TableFlags_NoHostExtendX()
  local fixed = reaper.ImGui_TableColumnFlags_WidthFixed()
  if not reaper.ImGui_BeginTable(ctx, "##settings_form_" .. id, 3, form_flags) then return false end
  reaper.ImGui_TableSetupColumn(ctx, "##label", fixed, opts.label_w + L.md)
  reaper.ImGui_TableSetupColumn(ctx, "##control", fixed, opts.control_w + L.md)
  reaper.ImGui_TableSetupColumn(ctx, "##reset", fixed, opts.reset_w + L.md)
  reaper.ImGui_BeginDisabled(ctx, locked)
  for _, row in ipairs(section.rows) do
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    if row.label ~= "" then
      Theme.align(ctx)
      reaper.ImGui_Text(ctx, row.label)
    end
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    row.draw(opts.control_w, b)
    reaper.ImGui_TableSetColumnIndex(ctx, 2)
    if not row_reset(row) then differing = differing + 1 end
  end
  if opts.section_reset_w then
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    if reset_button("Reset section", "reset_section_" .. section.id, opts.section_reset_w,
        differing == 0 and opts.section_default_reason or nil, opts.section_hint) then
      section_clicked = true
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_EndTable(ctx)
  return section_clicked
end

-- The "Analysis Settings" form on the empty canvas (spec: Analysis Settings at the Analyze Button). Its copy:
K.FORM_COPY = {
  reset_hint = "Back to your default (from Settings)",
  default_reason = "Already the default",
  save = "Save as Default",
  save_tip = "Use these values for every new analysis",
  change = "Change…",
  change_tip = "Change the values this item is analyzed with",
  summary = "Analysis Settings: ",
  no_target = "Select an audio item in REAPER to analyze it.",
}

--- Which layout of the canvas form fits avail_w x avail_h: "full" (label | control | Reset rows), "stacked" (each
--- label above its control) or "summary" (one line beside the button). need = { row_w, stacked_w, full_h, stacked_h,
--- button_h }: the width of a full row, the heights of the two forms and the button's height with its gap.
K.form_layout = function(avail_w, avail_h, need)
  if avail_w >= need.row_w and avail_h >= need.full_h + need.button_h then return "full" end
  if avail_h >= need.stacked_h + need.button_h then return "stacked" end
  return "summary"
end

--- What the canvas form is measured with in the font pushed now (kept per font size, not measured every frame):
--- the column widths, the Save as Default slot, and the estimated heights of the full and stacked forms with
--- Advanced closed (h_full, h_stacked) and what Advanced adds when open (adv_full, adv_stacked).
K.form_canvas_metrics = function()
  local key = reaper.ImGui_GetFontSize(ctx)
  local m = K.form_metrics_cache
  if m and m.key == key then return m end
  local L = Theme.layout
  local function text_w(text) return (reaper.ImGui_CalcTextSize(ctx, text)) or 0 end
  local detection, dsp = K.SETTINGS_SECTIONS[2], K.SETTINGS_SECTIONS[3]
  local label_w, control_w = 0, Theme.calc_combo_width(ctx, { K.CUSTOM_PRESET })
  for _, section in ipairs({ detection, dsp }) do
    for _, row in ipairs(section.rows) do
      label_w = math.max(label_w, text_w(row.label))
      if row.labels then control_w = math.max(control_w, Theme.calc_combo_width(ctx, row.labels)) end
    end
  end
  local pad_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())
  local _, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local cell_x, cell_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding())
  -- The form's border (ChildFlags_Borders) turns on the window padding inside it: counted on every side
  local win_x, win_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local fhs = reaper.ImGui_GetFrameHeightWithSpacing(ctx)
  local line_h = reaper.ImGui_GetTextLineHeight(ctx) + spacing_y
  local reset_w = text_w("Reset") + L.md * 2
  local save_w = text_w(K.FORM_COPY.save) + pad_x * 2
  local table_row_h = frame_h + cell_y * 2
  -- The header: the divider (spacing, label, separator, spacing), then the reason line
  local head_h = spacing_y * 4 + frame_h + 1 + line_h
  local n_det, n_dsp = #detection.rows, #dsp.rows
  m = {
    key = key, label_w = label_w, control_w = control_w, reset_w = reset_w, frame_h = frame_h,
    save_w = save_w, change_w = text_w(K.FORM_COPY.change) + pad_x * 2,
    slot_w = save_w,
    -- Three table columns, each with its L.md gap and the cells' padding on both sides
    row_w = label_w + control_w + reset_w + L.md * 3 + cell_x * 6 + win_x * 2,
    stacked_w = math.max(label_w, Theme.calc_combo_width(ctx, { K.CUSTOM_PRESET }) + L.sm + reset_w) + win_x * 2,
    h_full = head_h + n_det * table_row_h + spacing_y + fhs + win_y * 2,
    adv_full = n_dsp * table_row_h + spacing_y,
    h_stacked = head_h + n_det * (line_h + fhs) + fhs + fhs + win_y * 2,
    adv_stacked = n_dsp * (line_h + fhs),
  }
  K.form_metrics_cache = m
  return m
end

--- The layout of the canvas form for a canvas avail_w x avail_h whose button takes button_h (with its gap), the
--- width the form takes in it, its height and, when it scrolls, the height it is held to (else nil). When only the
--- open Advanced fold keeps the form from fitting, the form keeps the layout it has with the fold closed and
--- scrolls inside the room there is (the fold stays open: the user opened it).
K.form_canvas_plan = function(avail_w, avail_h, button_h)
  local m = K.form_canvas_metrics()
  local function need(open)
    return { row_w = m.row_w, stacked_w = m.stacked_w, button_h = button_h,
      full_h = m.h_full + (open and m.adv_full or 0), stacked_h = m.h_stacked + (open and m.adv_stacked or 0) }
  end
  local open = K.form_adv_open == true
  local layout = K.form_layout(avail_w, avail_h, need(open))
  local max_h = nil
  if layout == "summary" and open then
    local closed = K.form_layout(avail_w, avail_h, need(false))
    if closed ~= "summary" then
      layout = closed
      max_h = math.max(avail_h - button_h - Theme.layout.lg, 1)   -- and a margin under the button
    end
  end
  local form_w = layout == "full" and m.row_w or math.max(math.min(avail_w, m.row_w), 1)
  -- Its height: what it took when last drawn the same way, else the estimate
  local last = K.form_canvas_last
  local form_h
  if max_h then form_h = max_h
  elseif layout == "full" then form_h = m.h_full + (open and m.adv_full or 0)
  elseif layout == "stacked" then form_h = m.h_stacked + (open and m.adv_stacked or 0)
  else form_h = 0 end
  if not max_h and last and last.layout == layout and last.adv == open and not last.scroll and (last.h or 0) > 0
      and layout ~= "summary" then
    form_h = last.h
  end
  return layout, form_w, form_h, max_h
end

--- Whether a child window `key` is dimmed this frame for a modal over it (`open`: the modal is open now). Like
--- Theme.modal_scrim, the first frame it is seen open is skipped (no dim while the modal may still be hidden), and the
--- latch is released once it is closed. Pure but for its latch (K.child_dim_seen).
K.child_dim_seen = {}
K.child_dim_due = function(key, open)
  if not open then
    K.child_dim_seen[key] = nil
    return false
  end
  if not K.child_dim_seen[key] then
    K.child_dim_seen[key] = true
    return false
  end
  return true
end

--- Dim the child window being drawn now (call right before its EndChild) while a modal is over it. A modal's scrim
--- (Theme.modal_scrim) is drawn on its parent window's draw list, and ImGui renders a child window after its
--- parent's list: without this the child stays bright above the scrim. Fills the child's own rect with the same
--- palette key (dim_bg) on the child's own draw list.
K.child_dim = function(key, open)
  if not K.child_dim_due(key, open) then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetWindowPos(ctx)
  local w, h = reaper.ImGui_GetWindowSize(ctx)
  if not (dl and x and y and w and h) then return end
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + w, y + h, false)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, Theme.get_palette().dim_bg)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

--- The popup name of the confirm `c` (stable ID after ###: the visible title may carry the item name).
K.confirm_popup_name = function(c)
  return c.title .. "###confirm_" .. c.id
end

--- True while a modal of the main window is open (Settings, Info or a confirm). Call in the main window's own ID
--- scope: the popup names hash with the ID stack, and the canvas is drawn inside the body table's (its own) scope.
--- The window asks once per frame before the body (K.window_modal_now) and the canvas form reads that.
K.window_modal_open = function()
  local c = state.confirm
  return reaper.ImGui_IsPopupOpen(ctx, "Settings & Audio Engine##settings_modal")
    or reaper.ImGui_IsPopupOpen(ctx, "Keyboard Shortcuts & Help##info_modal")
    or (c ~= nil and reaper.ImGui_IsPopupOpen(ctx, K.confirm_popup_name(c)))
end

--- Save as Default, right-aligned in its slot (K.form_canvas_metrics' slot_w); nothing in its place while `form`
--- holds the defaults. why (optional): why it is disabled. Returns true when it was clicked (the caller asks
--- K.form_defaults_request's confirm).
K.form_save_draw = function(form, id, why)
  local m = K.form_canvas_metrics()
  local cur_x = reaper.ImGui_GetCursorPosX(ctx)
  if K.form_changed_rows(form.values) == 0 then
    reaper.ImGui_Dummy(ctx, m.slot_w, m.frame_h)   -- the slot stays, empty: the row keeps its height
    return false
  end
  reaper.ImGui_SetCursorPosX(ctx, cur_x + m.slot_w - m.save_w)
  reaper.ImGui_BeginDisabled(ctx, why ~= nil)
  local clicked = reaper.ImGui_Button(ctx, K.FORM_COPY.save .. "###" .. id, m.save_w, 0)
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    Theme.tooltip(ctx, why or K.FORM_COPY.save_tip)
  end
  return clicked and why == nil
end

--- The analysis modal's form (request_confirm's `form`), at the top of the confirm `c`'s body: the header, the
--- detection rows, the Advanced fold with Save as Default at its right (under the form when stacked), the DSP rows
--- when open, then a separator before the consequence lines. Stacked (label above control) when the modal is
--- narrower than the full rows. Save as Default opens its confirm over this modal (c.nested).
K.confirm_form_draw = function(c)
  local P = Theme.get_palette()
  local L = Theme.layout
  local form = c.form
  local m = K.form_canvas_metrics()
  local win_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
  local content_w = reaper.ImGui_GetContentRegionAvail(ctx) or 0
  local stacked = content_w < m.row_w - (win_x or 0) * 2
  local header = K.form_header(form)
  local head, tail = header:match("^(.-) · (.+)$")
  Theme.section_divider(ctx, head or header, { color = P.yellow })
  if tail then reaper.ImGui_TextColored(ctx, P.text_dim, tail) end

  local function save_draw()
    if K.form_save_draw(form, "modal_save", nil) then
      c.nested = K.confirm_new(K.form_defaults_request(form.values))
    end
  end
  local b = K.form_binding(form)
  local opts = {
    locked = false, stacked = stacked, label_w = m.label_w, control_w = stacked and content_w or m.control_w,
    reset_w = m.reset_w, reset_hint = K.FORM_COPY.reset_hint, default_reason = K.FORM_COPY.default_reason,
    id = "modal_detection",
  }
  K.form_rows_draw(K.SETTINGS_SECTIONS[2], b, opts)
  local adv_open
  if stacked then
    adv_open = Theme.collapsing_header(ctx, "Advanced##modal_adv")
  else
    adv_open = Theme.collapsing_header(ctx, "Advanced##modal_adv",
      { action_fn = save_draw, close_w = m.slot_w, close_h = m.frame_h, margin = L.sm })
  end
  c.form_adv_open = adv_open   -- the fit's key: opening the fold resizes the modal
  if adv_open then
    opts.id = "modal_dsp"
    K.form_rows_draw(K.SETTINGS_SECTIONS[3], b, opts)
  end
  if stacked then
    Theme.right_align(ctx, m.slot_w)
    save_draw()
  end
  -- The consequence lines under a separator, when there are any. Either way an item ends the form: the fold's
  -- right-hand action leaves the cursor moved with no item after it, and ImGui asks for one before the body ends
  if #c.body_lines > 0 or (c.list and #c.list > 0) or #c.after_lines > 0 then
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, L.sm)
  else
    reaper.ImGui_Dummy(ctx, 0, 0)
  end
end

--- The "Analysis Settings" form of the empty canvas: a child window at x, y (screen), w wide, over the canvas: the header
--- (ANALYSIS SETTINGS), the three rows, the Advanced fold, and Save as Default right-aligned.
--- layout "full" or "stacked" (K.form_layout). reason (optional): why the form is disabled (no item). While an
--- analysis runs everything is disabled with K.LOCKED_REASON under the header. max_h (optional): the height it is
--- held to, scrolling inside (K.form_canvas_plan); else it takes its content's height. Returns the height it took.
K.form_canvas_draw = function(form, x, y, w, layout, reason, max_h)
  local P = Theme.get_palette()
  local m = K.form_canvas_metrics()
  local locked = state.is_analyzing == true
  local why = locked and K.locked_reason() or reason
  local disabled = why ~= nil
  local stacked = layout == "stacked"
  local h = 0

  local function save_draw()
    if K.form_save_draw(form, "canvas_save", why) then request_confirm(K.form_defaults_request(form.values)) end
  end

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  -- The form's surface: the canvas bg inside a P.border outline (spec Theme mapping)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), P.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), P.border)
  local win_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  local child_flags = reaper.ImGui_ChildFlags_AutoResizeY() | reaper.ImGui_ChildFlags_Borders()
  if max_h then win_flags, child_flags = 0, reaper.ImGui_ChildFlags_Borders() end   -- held to max_h: it scrolls
  local under_modal = K.window_modal_now == true   -- asked in the main window's scope (K.window_modal_open)
  local child_open = reaper.ImGui_BeginChild(ctx, "##canvas_form", w, max_h or 0, child_flags, win_flags)
  -- The border is drawn by BeginChild: P.border is popped at once, so the combos and buttons inside keep the
  -- theme's own outline
  reaper.ImGui_PopStyleColor(ctx, 1)
  if child_open then
    local content_w = reaper.ImGui_GetContentRegionAvail(ctx)   -- less the scrollbar when it scrolls
    -- The heading alone (no "your defaults" / changed-count line under it, unlike the modal)
    local header = K.form_header(form)
    Theme.section_divider(ctx, header:match("^(.-) · ") or header, { color = P.yellow })
    -- No item: the line above the form already says to select one (the disabled controls keep it as their tooltip)
    if why and why ~= K.FORM_COPY.no_target then reaper.ImGui_TextColored(ctx, P.text_dim, why) end

    local b = K.form_binding(form)
    local opts = {
      locked = disabled, stacked = stacked, label_w = m.label_w, control_w = stacked and content_w or m.control_w,
      reset_w = m.reset_w, reset_hint = K.FORM_COPY.reset_hint, default_reason = K.FORM_COPY.default_reason,
      id = "canvas_detection",
    }
    K.form_rows_draw(K.SETTINGS_SECTIONS[2], b, opts)

    local adv_open
    if stacked then
      adv_open = Theme.collapsing_header(ctx, "Advanced##canvas_adv")
    else
      adv_open = Theme.collapsing_header(ctx, "Advanced##canvas_adv",
        { action_fn = save_draw, close_w = m.slot_w, close_h = m.frame_h, margin = Theme.layout.sm })
    end
    K.form_adv_open = adv_open
    if adv_open then
      opts.id = "canvas_dsp"   -- the same columns as the rows above, so the controls line up
      K.form_rows_draw(K.SETTINGS_SECTIONS[3], b, opts)
    end
    if stacked then
      Theme.right_align(ctx, m.slot_w)
      save_draw()
    end
    -- The fold's right-hand action leaves the cursor moved with no item after it: ImGui asks for an item before
    -- the child ends
    reaper.ImGui_Dummy(ctx, 0, 0)
    K.child_dim("canvas_form", under_modal)
    reaper.ImGui_EndChild(ctx)
    local _, child_h = reaper.ImGui_GetItemRectSize(ctx)
    h = child_h or 0
  end
  reaper.ImGui_PopStyleColor(ctx, 1)   -- ChildBg
  return h
end

--- The summary line of a short canvas: dim "Analysis Settings: Soprano · ..." (shortened to text_w with the whole line
--- in its tooltip) and Change… at x, centred on a row row_h tall at y. Returns the width it took. Change… opens the
--- analysis modal (K.analyze_change_request), or the batch modal seeded with the form when the canvas button is a
--- batch (is_batch). reason (optional): why Change… is disabled, its tooltip then.
K.form_summary_draw = function(form, x, y, text_w, row_h, reason, is_batch)
  local disabled = reason ~= nil
  local P = Theme.get_palette()
  local L = Theme.layout
  local m = K.form_canvas_metrics()
  local row_y = y + math.floor((row_h - m.frame_h) * 0.5)
  local used = 0
  if text_w > 0 then
    local full = K.FORM_COPY.summary .. K.form_summary(form.values)
    local shown = fit_text(ctx, full, text_w, "canvas_summary")
    reaper.ImGui_SetCursorScreenPos(ctx, x, row_y)
    Theme.align(ctx)
    reaper.ImGui_TextColored(ctx, P.text_dim, shown)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then Theme.tooltip(ctx, full) end
    used = ((reaper.ImGui_CalcTextSize(ctx, shown)) or 0) + L.md
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x + used, row_y)
  reaper.ImGui_BeginDisabled(ctx, disabled)
  local clicked = reaper.ImGui_Button(ctx, K.FORM_COPY.change .. "###change", m.change_w, 0)
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    Theme.tooltip(ctx, reason or K.FORM_COPY.change_tip)
  end
  if clicked and not disabled then
    if is_batch then K.batch_request(nil, form) else request_confirm(K.analyze_change_request(form)) end
  end
  return used + m.change_w
end

--- Whether the canvas shows the "Analysis Settings" form instead of notes (not analysed, no pitched note found, or an
--- analysis running that has no frames yet), and whether it is the no-notes canvas (title, hint and Re-Analyze;
--- never while analysing). Once the first slice of an analysis fills state.results the pitch line draws in.
K.empty_canvas = function()
  local running = state.is_analyzing == true
  local shows = #state.results == 0 or (state.analysis_empty == true and not running)
  return shows, shows and #state.results > 0 and not running
end

--- The form the empty canvas shows: the open item's (state.analysis_form), or, with no item to analyse, a form of
--- the defaults that is shown disabled with why. A batch without an open item gets a form of its own, kept here
--- (never in state.analysis_form) until there is an open item again. While an analysis runs: a form of the values it
--- runs with (state.analysis_params: a Re-Analyze from the modal or a batch may run with others than the open
--- form's), locked with K.LOCKED_REASON. Returns the form and the reason (nil when it can be edited).
K.canvas_form = function(has_target, is_batch)
  local params = state.is_analyzing and state.analysis_params
  if params then
    local running = K.canvas_running_form
    if not running or running.params ~= params then
      running = { guid = "running", edited = {}, source = "running", params = params, values = {} }
      for _, key in ipairs(K.ANALYSIS_KEYS) do running.values[key] = params[key] end
      K.canvas_running_form = running
    end
    return running, K.locked_reason()
  end
  K.canvas_running_form = nil
  local form = state.analysis_form
  if has_target and form and form.guid == state.target_take_guid then
    K.canvas_batch_form = nil
    return form, nil
  end
  if is_batch then
    K.canvas_batch_form = K.canvas_batch_form or K.form_new("batch", nil)
    return K.canvas_batch_form, nil
  end
  return K.form_new(nil, nil), K.FORM_COPY.no_target
end

--- The width of the Analyze button for `label`, measured in the context it is drawn in.
K.analyze_btn_w = function(draw_ctx, label)
  local var_count, pushed_font = Theme.push_button_preset(draw_ctx, fonts, K.ANALYZE_BTN)
  local btn_w = (reaper.ImGui_CalcTextSize(draw_ctx, label) or 0) + K.ANALYZE_BTN.pad_x * 2
  Theme.pop_button_preset(draw_ctx, var_count, pushed_font)
  return btn_w
end


--- Ask before restoring every setting of a Settings section to its DEFAULTS value. These settings are outside the
--- undo history (and are saved), so the confirm names how many change and which; the confirm is the only modal, so the
--- caller closes Settings first. Does nothing when every row already holds its default.
K.request_settings_reset = function(section)
  -- The rows are walked on a copy of the state: one row's reset can move another (the hop follows the block), so the
  -- names and the count come from exactly the sequence on_confirm runs
  local names = {}
  local saved = {}
  local b = K.settings_binding()
  for k, v in pairs(state) do saved[k] = v end
  for _, row in ipairs(section.rows) do
    if not row.is_default(b) then
      names[#names + 1] = row.name or row.label
      row.reset(b)
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
        if not row.is_default(b) then
          row.reset(b)
          done = done + 1
        end
      end
      b.commit()
      set_status(string.format("Reset %d %s to %s (not undoable)", done, plural(done, "setting", "settings"),
        plural(done, "its default", "their defaults")))
    end,
  })
end

--- The line under the Item Value Defaults divider, and the values it lists, one line each.
K.ITEM_DEFAULTS_NOTE = "New analyses start with these, unless the item's track has a Track Default."
K.ITEM_DEFAULTS_LINES = { { "separation", "correct_mode", "tighten" }, { "tolerance", "retune_speed", "slide_in" } }

--- Settings > Restore Factory Defaults…: ask, then forget every System Default (outside the undo history). Track
--- Defaults are not touched.
K.request_factory_defaults = function()
  local n = K.sys_defaults_changed()
  if n == 0 then return end
  local factory = {}
  for _, key in ipairs(K.ITEM_KEYS) do factory[key] = DEFAULTS[key] end
  request_confirm({
    id = "restore_factory_defaults",
    title = "Restore the factory defaults?",
    body_lines = {
      string.format("New analyses start with: %s.", K.apply_values_line(factory, K.ITEM_KEYS)),
      "Tracks with a Track Default keep it. Items already analyzed keep their values.",
      string.format("Not part of the undo history: %s+Z does not bring your System Default back.", K.MOD_LABEL),
    },
    confirm_label = "Restore Factory Defaults",
    fit = true,
    on_confirm = function()
      K.sys_defaults_clear()
      set_status("Factory defaults restored.")
    end,
  })
end

--- Danger styling of the Settings "Wipe" button and the confirm modal's confirm button: the label stays P.text and
--- every state is a translucent red over the popup surface (P.panel), so the label keeps >= 4.5:1 in all of them (HC1).
--- Fancy, composited: rest (P.red_d) 6.2:1, hover and pressed (P.red_h) 4.9:1 (an opaque P.red pressed would be
--- 2.4:1). Pair every K.push_danger(P) with K.pop_danger().
K.push_danger = function(P)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red_h)
end
K.pop_danger = function()
  reaper.ImGui_PopStyleColor(ctx, 3)
end

--- A checkbox for a canvas layer (state[key]: the Layers menu and Settings > Diagnostics). The change is saved at once:
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
--- host_w, host_h (optional): the size of that window, when it is not the one drawing now (a confirm over a confirm).
--- Returns the largest width and height the dialog may take.
function K.fit_modal(modal_ctx, host_w, host_h)
  local L = Theme.layout
  if not (host_w and host_h) then host_w, host_h = reaper.ImGui_GetWindowSize(modal_ctx) end
  local max_w, max_h = math.max((host_w or 0) - L.xl * 2, L.xxxl), math.max((host_h or 0) - L.xl * 2, L.xxxl)
  reaper.ImGui_SetNextWindowSizeConstraints(modal_ctx, 0, 0, max_w, max_h)
  return max_w, max_h
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
    local opts = {
      locked = locked, label_w = label_w, control_w = control_w, reset_w = text_w("Reset") + L.md * 2,
      section_reset_w = text_w("Reset section") + L.md * 2,
      reset_hint = "Restore the default value", default_reason = "Already at its default",
      section_hint = "Restore every setting of this section to its default",
      section_default_reason = "Already at its defaults",
    }
    local binding = K.settings_binding()
    local section_to_reset = nil
    local function draw_form(section)
      if K.form_rows_draw(section, binding, opts) then section_to_reset = section end
    end

    local engine, detection, dsp = K.SETTINGS_SECTIONS[1], K.SETTINGS_SECTIONS[2], K.SETTINGS_SECTIONS[3]

    Theme.section_divider(ctx, engine.title, { color = P.yellow })
    if locked then
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.text_dim, K.locked_reason())
    end
    draw_form(engine)

    Theme.section_divider(ctx, detection.title, { color = P.yellow })
    Theme.align(ctx)
    reaper.ImGui_TextColored(ctx, P.text_dim, K.ANALYSIS_DEFAULTS_NOTE)
    draw_form(detection)

    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if Theme.collapsing_header(ctx, dsp.title) then
      draw_form(dsp)
    end

    -- The System Default of the item values (saved from the "This item" menu), and its way back to the factory ones
    Theme.section_divider(ctx, "Item Value Defaults", { color = P.yellow })
    local sys = {}
    for _, key in ipairs(K.ITEM_KEYS) do sys[key] = K.sys_defaults[key] or DEFAULTS[key] end
    Theme.align(ctx)
    reaper.ImGui_TextColored(ctx, P.text_dim, K.ITEM_DEFAULTS_NOTE)
    for _, keys in ipairs(K.ITEM_DEFAULTS_LINES) do
      Theme.align(ctx)
      reaper.ImGui_Text(ctx, K.apply_values_line(sys, keys))
    end
    local factory_text = "Restore Factory Defaults\xE2\x80\xA6"
    local factory_reason = (K.sys_defaults_changed() == 0) and "Already at the factory defaults" or nil
    Theme.align(ctx)
    reaper.ImGui_BeginDisabled(ctx, factory_reason ~= nil)
    local factory_clicked = reaper.ImGui_Button(ctx, factory_text .. "###restore_factory", text_w(factory_text) + L.md * 2, 0)
    reaper.ImGui_EndDisabled(ctx)
    if factory_reason then
      reaper.ImGui_SameLine(ctx, 0, L.sm)
      Theme.align(ctx)
      reaper.ImGui_TextColored(ctx, P.text_dim, factory_reason)
    elseif reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "New analyses start at the factory values again (tracks with a Track Default keep it)")
    end
    if factory_clicked then
      -- The confirm is the only modal: close Settings first
      reaper.ImGui_CloseCurrentPopup(ctx)
      K.request_factory_defaults()
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

    Theme.align(ctx)
    local bar_idx, bar_changed = Theme.combo(ctx, "Note Action Bar Size##note_bar_size", K.NOTE_BAR_SIZES,
      state.note_bar_size, { w = Theme.calc_combo_width(ctx, K.NOTE_BAR_SIZES),
        tooltip = "Size of the Snap, Quantize, Split and Merge buttons under the selected note" })
    if bar_changed then
      state.note_bar_size = bar_idx
      K.save_settings("appearance")
    end

    -- Analysis internals: extra canvas layers for checking what the detection did (off unless enabled here)
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if Theme.collapsing_header(ctx, "Diagnostics") then
      reaper.ImGui_Indent(ctx, L.md)
      Theme.align(ctx)
      K.layer_checkbox("Split Markers", "show_split_points")
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
    if locked or K.batch then   -- an analysis owns the open item and, in a batch, holds models of others
      clear_reason, wipe_reason = K.REASON_ANALYZING, K.REASON_ANALYZING
    end

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
    for _, note in ipairs(K.INFO_NOTES) do
      terms_w = math.max(terms_w, ((reaper.ImGui_CalcTextSize(ctx, note[1])) or 0) + L.md
        + ((reaper.ImGui_CalcTextSize(ctx, note[2])) or 0) + L.md)
    end
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
      -- The analysis notes, one line each in the same style
      for _, note in ipairs(K.INFO_NOTES) do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_TextColored(ctx, P.accent, note[1])
        reaper.ImGui_SameLine(ctx, 0, L.md)
        reaper.ImGui_Text(ctx, note[2])
      end
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

--- The height of a confirm's body, the region above its footer. Pure: avail_h = the modal's content height,
--- btn_h = the button row's, gap = the space above the footer, reason_h = the line that says why the confirm is
--- off (0: none kept), spacing_y = ImGui's item spacing (after the body, the gap and the reason). At least 1, so
--- a modal too short for its body still shows its buttons.
K.confirm_body_h = function(avail_h, btn_h, gap, reason_h, spacing_y)
  local footer = spacing_y + gap + spacing_y + btn_h
  if reason_h > 0 then footer = footer + reason_h + spacing_y end
  return math.max(1, avail_h - footer)
end

--- The height a confirm sized to its content (request_confirm's `fit`) asks for: the modal now (win_h) less the body
--- it has (body_h) plus the body its content needs (content_h), so the footer sits right under the content. Never
--- taller than max_h (the most the window it opens from allows, K.fit_modal: longer content scrolls in the body,
--- and K.confirm_body_h keeps the buttons in view), and the body keeps at least one pixel. Pure.
K.confirm_fit_h = function(win_h, body_h, content_h, max_h)
  local frame = win_h - body_h   -- everything but the body: the title bar, the padding and the footer
  return math.max(frame + 1, math.min(max_h, frame + math.max(0, content_h)))
end

--- When the confirm `c` (sized to its content) is resized: once its content changed (key: what the body draws:
--- the consequence, the rows, the width it wraps to) and the body is not the content's height. At most twice for
--- one content (the second try mends a first frame measured short), so a body capped by max_h or a scrollbar that
--- re-wraps the text never makes it resize every frame, and ticking rows that keep the content's size never moves
--- it. Returns true when it should be resized now.
--- True while the confirm `c` (sized to its content) is drawn see-through: from its first frame until a frame has
--- measured its content and asked for no resize (c.fit_shown), so the size it opens at and a second try never
--- flash. At most K.CONFIRM_FIT_HIDDEN_MAX frames (c.fit_hidden_frames), so a body never measured still shows.
--- Only the opening: a later change of content resizes in view. Pure.
K.CONFIRM_FIT_HIDDEN_MAX = 3
K.confirm_fit_hidden = function(c)
  return c.fit == true and not c.fit_shown and (c.fit_hidden_frames or 0) < K.CONFIRM_FIT_HIDDEN_MAX
end

K.confirm_fit_due = function(c, key, body_h, content_h)
  if c.fit_key ~= key then c.fit_key, c.fit_tries = key, 0 end
  if (c.fit_tries or 0) >= 2 or math.abs(content_h - body_h) < 1 then return false end
  c.fit_tries = (c.fit_tries or 0) + 1
  return true
end

--- The one confirm modal (see request_confirm): consequence and count in the body, Cancel first,
--- Esc = Cancel, danger-styled confirm button. Called inside the main window's `if visible` block.
--- The list of a confirm dialog (request_confirm's `list`): one row per thing the action replaces, its name and,
--- dimmed at the right, where it is (`where`, e.g. track and position). The region takes the room the dialog's
--- body has left above its closing lines, three rows at least, and scrolls; only the rows in view are drawn. A
--- name that does not fit is shortened (its row's tooltip has it in full), and `where` gives way first.
K.confirm_list = function(c)
  local P = Theme.get_palette()
  local L = Theme.layout
  local row_h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  -- What comes below the list in the confirm's body, with the spacing ImGui puts after every item: the closing
  -- lines (a gap, then the line wrapped to the dialog's width). The gap drawn above the list and the spacing after
  -- it count too, or the body scrolls for nothing (the button row is outside the body, see K.confirm_body_h)
  local _, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  spacing_y = spacing_y or 0
  local below = (L.xs + spacing_y) + spacing_y
  for _, line in ipairs(c.after_lines) do
    local _, line_h = reaper.ImGui_CalcTextSize(ctx, line, nil, nil, false, avail_w)
    below = below + (L.sm + spacing_y) + (line_h or 0) + spacing_y
  end
  -- The region's own padding, above and below its rows: a list that fits must not get a scrollbar
  local _, pad_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
  local pad = (pad_y or L.sm) * 2
  local list_h = math.max(row_h * 3 + pad, math.min(#c.list * row_h + pad, avail_h - below))

  reaper.ImGui_Dummy(ctx, 0, L.xs)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), P.well)
  if reaper.ImGui_BeginChild(ctx, "##confirm_list", 0, list_h, reaper.ImGui_ChildFlags_Borders()) then
    -- A clipper of its own, attached to the context (see the Pitched Items list for why)
    if not K.confirm_clipper or not reaper.ImGui_ValidatePtr(K.confirm_clipper, "ImGui_ListClipper*") then
      K.confirm_clipper = reaper.ImGui_CreateListClipper(ctx)
      reaper.ImGui_Attach(ctx, K.confirm_clipper)
    end
    local clipper = K.confirm_clipper
    local inner_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local start_x = reaper.ImGui_GetCursorPosX(ctx)
    reaper.ImGui_ListClipper_Begin(clipper, #c.list, row_h)
    while reaper.ImGui_ListClipper_Step(clipper) do
      local first_row, end_row = reaper.ImGui_ListClipper_GetDisplayRange(clipper)   -- 0-based, end exclusive
      for index = first_row + 1, end_row do
        local row = c.list[index]
        local name = row.name or "Item"
        local where = row.where or ""
        local where_w = where ~= "" and (reaper.ImGui_CalcTextSize(ctx, where)) or 0
        local name_w = reaper.ImGui_CalcTextSize(ctx, name)
        -- `where` shows only while the name keeps half of the row (or fits whole beside it)
        local room = inner_w - where_w - L.md
        local show_where = where_w > 0 and room >= math.min(name_w, inner_w * 0.5)
        local shown = fit_text(ctx, name, show_where and room or inner_w, "regular")
        reaper.ImGui_Text(ctx, shown)
        if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, where ~= "" and (name .. "\n" .. where) or name)
        end
        if show_where then
          reaper.ImGui_SameLine(ctx)
          reaper.ImGui_SetCursorPosX(ctx, start_x + inner_w - where_w)
          reaper.ImGui_TextColored(ctx, P.text_dim, where)
        end
      end
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

-- The most rows a confirm's checklist shows before it scrolls
K.CHECKLIST_MAX_ROWS = 6

--- The targets of a confirm dialog (request_confirm's `checklist` and `check`): the caption with "All" and "None"
--- beside it, the rows in a region that scrolls past K.CHECKLIST_MAX_ROWS (only the rows in view are drawn), then the
--- checkbox. A row's name that does not fit is shortened (its tooltip has it in full); a row with a reason is
--- disabled, the reason beside it in dim text (shortened too when the row is narrow, its tooltip in full). A click
--- changes c.ticked / c.checked; the consequence follows on the next frame.
K.confirm_targets = function(c, P, L)
  local list = c.checklist
  if list then
    reaper.ImGui_Dummy(ctx, 0, L.sm)
    if list.caption then
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, list.caption)
      reaper.ImGui_SameLine(ctx, 0, L.md)
    end
    if reaper.ImGui_SmallButton(ctx, (list.all_label or "All") .. "###confirm_tick_all") then
      K.confirm_tick_all(c, true)
    end
    reaper.ImGui_SameLine(ctx, 0, L.sm)
    if reaper.ImGui_SmallButton(ctx, (list.none_label or "None") .. "###confirm_tick_none") then
      K.confirm_tick_all(c, false)
    end

    local rows = list.rows
    local row_h = reaper.ImGui_GetFrameHeightWithSpacing(ctx)
    local _, pad_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
    local list_h = math.max(1, math.min(#rows, K.CHECKLIST_MAX_ROWS)) * row_h + (pad_y or L.sm) * 2
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), P.well)
    if reaper.ImGui_BeginChild(ctx, "##confirm_checklist", 0, list_h, reaper.ImGui_ChildFlags_Borders()) then
      -- A clipper of its own, attached to the context (see K.confirm_list)
      if not K.checklist_clipper or not reaper.ImGui_ValidatePtr(K.checklist_clipper, "ImGui_ListClipper*") then
        K.checklist_clipper = reaper.ImGui_CreateListClipper(ctx)
        reaper.ImGui_Attach(ctx, K.checklist_clipper)
      end
      local clipper = K.checklist_clipper
      local inner_w = reaper.ImGui_GetContentRegionAvail(ctx)
      local inner_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemInnerSpacing())
      local box_w = reaper.ImGui_GetFrameHeight(ctx) + (inner_x or L.sm)
      reaper.ImGui_ListClipper_Begin(clipper, #rows, row_h)
      while reaper.ImGui_ListClipper_Step(clipper) do
        local first_row, end_row = reaper.ImGui_ListClipper_GetDisplayRange(clipper)   -- 0-based, end exclusive
        for index = first_row + 1, end_row do
          local row = rows[index]
          local name = row.name or "Item"
          -- A row with a reason: the name keeps half of the row (or what it needs), the reason is shortened to the
          -- rest, so a narrow docker never scrolls sideways
          local row_w = inner_w - box_w
          local name_room = row_w
          if row.reason then
            local reason_w = reaper.ImGui_CalcTextSize(ctx, row.reason)
            name_room = math.max(math.min(reaper.ImGui_CalcTextSize(ctx, name), row_w * 0.5), row_w - reason_w - L.md)
          end
          local shown = fit_text(ctx, name, name_room, "regular")
          -- The row's ID is its item's (RB17): a row keeps its state when the list above it changes
          reaper.ImGui_PushID(ctx, tostring(row.id))
          if row.reason then reaper.ImGui_BeginDisabled(ctx) end
          local changed, on = reaper.ImGui_Checkbox(ctx, shown .. "###confirm_row",
            c.ticked[row.id] == true and not row.reason)
          if changed and not row.reason then K.confirm_tick(c, row.id, on == true) end
          if shown ~= name and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()
              | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
            Theme.tooltip(ctx, name)
          end
          if row.reason then
            reaper.ImGui_EndDisabled(ctx)
            reaper.ImGui_SameLine(ctx, 0, L.md)
            local reason_room = row_w - reaper.ImGui_CalcTextSize(ctx, shown) - L.md
            local reason_shown = fit_text(ctx, row.reason, reason_room, "regular")
            reaper.ImGui_TextColored(ctx, P.text_dim, reason_shown)
            if reason_shown ~= row.reason
                and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
              Theme.tooltip(ctx, row.reason)
            end
          end
          reaper.ImGui_PopID(ctx)
        end
      end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  if c.check then
    reaper.ImGui_Dummy(ctx, 0, L.xs)
    local changed, on = reaper.ImGui_Checkbox(ctx, c.check.label .. "###confirm_check", c.checked)
    if changed then c.checked = on == true end
  end
end

--- Draw the confirm `c` (K.confirm_new). host = { x, y, w, h } of the window it is kept inside (K.fit_modal) and
--- centred on when it fits its content; nil: the window drawing now. gone() runs once the modal has closed (it
--- drops `c`). A nested confirm (c.nested: Save as Default from the analysis form) is drawn inside this modal's
--- scope, over it, kept inside the same host window.
K.confirm_draw = function(c, host, gone)
  local cons = K.confirm_consequence(c)
  local P = Theme.get_palette()
  local L = Theme.layout
  local size = c.size or L.modal_sm
  -- Stable ID after ###: the visible title may carry the item name
  local popup_name = K.confirm_popup_name(c)

  if c.open_pending then
    reaper.ImGui_OpenPopup(ctx, popup_name)
    c.open_pending = false
    c.opened = true
  end

  -- The window the confirm opens from: a confirm sized to its content is centred on it again at every resize (the
  -- place it first opens at is not reliable for a popup that is not on screen yet)
  local host_x, host_y, host_w, host_h
  if host then
    host_x, host_y, host_w, host_h = host.x, host.y, host.w, host.h
  else
    host_x, host_y = reaper.ImGui_GetWindowPos(ctx)
    host_w, host_h = reaper.ImGui_GetWindowSize(ctx)
  end
  -- The analysis modal is at least as wide as its form's full rows (K.form_canvas_metrics), the fit permitting
  local open_w = size.w
  if c.form then open_w = math.max(open_w, K.form_canvas_metrics().row_w) end
  Theme.center_next_window(ctx, open_w, size.h, reaper.ImGui_Cond_Appearing())
  local _, max_h = K.fit_modal(ctx, host_w, host_h)
  if c.fit_size then   -- sized to its content (asked last frame): same width, centred on the window it opens from
    reaper.ImGui_SetNextWindowPos(ctx, c.fit_size.x, c.fit_size.y)
    reaper.ImGui_SetNextWindowSize(ctx, c.fit_size.w, c.fit_size.h)
    c.fit_size = nil
  end
  Theme.modal_scrim(ctx, popup_name)
  -- Not measured yet: drawn see-through (the scrim as usual) until it has its content's height
  local hidden = K.confirm_fit_hidden(c)
  if hidden then
    c.fit_hidden_frames = (c.fit_hidden_frames or 0) + 1
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0)
  end
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, popup_name, true, reaper.ImGui_WindowFlags_NoResize())
  local confirmed = false
  local confirm_label = (cons and cons.confirm_label) or c.confirm_label
  local blocked = cons and cons.reason or nil
  if visible then
    -- HC5, innermost first: an open combo or the Save as Default confirm over this modal takes Esc (and Enter)
    -- before the modal does; a field being edited keeps Enter
    local over = reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
    if (not over and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape())) or not open then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if K.confirm_enter(c) and not over and not blocked and not reaper.ImGui_IsAnyItemActive(ctx)
       and (reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Enter()) or reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_KeypadEnter())) then
      confirmed = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    -- The footer (the line that says why the confirm is off, then the button row) is pinned to the bottom of the
    -- modal, outside the body: the body takes the room above it and scrolls, so the buttons are always in view. The
    -- reason's line is kept even while there is no reason (a confirm with a consequence can get one), so nothing
    -- moves when it comes and goes (EP5)
    local cancel_w = reaper.ImGui_CalcTextSize(ctx, "Cancel") + L.md * 2
    local confirm_w = reaper.ImGui_CalcTextSize(ctx, confirm_label) + L.md * 2
    local btn_h = reaper.ImGui_GetFrameHeight(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local _, spacing_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
    local reason_h = 0
    if blocked then
      local _, wrapped_h = reaper.ImGui_CalcTextSize(ctx, blocked, nil, nil, false, avail_w)
      reason_h = wrapped_h or 0
    elseif c.consequence then
      reason_h = reaper.ImGui_GetTextLineHeight(ctx)
    end
    local body_h = K.confirm_body_h(avail_h, btn_h, L.lg, reason_h, spacing_y or 0)

    local content_h = nil
    -- Save as Default's confirm open over this one: the body child (the form) is dimmed with it (K.child_dim)
    local nested_open = c.nested ~= nil and reaper.ImGui_IsPopupOpen(ctx, K.confirm_popup_name(c.nested))
    if reaper.ImGui_BeginChild(ctx, "##confirm_body", 0, body_h, 0) then
      local top_y = reaper.ImGui_GetCursorPosY(ctx) or 0
      if c.form then K.confirm_form_draw(c) end
      for i, line in ipairs(c.body_lines) do
        if i > 1 then reaper.ImGui_Dummy(ctx, 0, L.sm) end
        reaper.ImGui_TextWrapped(ctx, line)
      end
      if c.list and #c.list > 0 then K.confirm_list(c) end
      for _, line in ipairs(c.after_lines) do
        reaper.ImGui_Dummy(ctx, 0, L.sm)
        reaper.ImGui_TextWrapped(ctx, line)
      end
      if c.checklist or c.check then K.confirm_targets(c, P, L) end
      if cons then
        for _, line in ipairs(cons.lines or {}) do
          reaper.ImGui_Dummy(ctx, 0, L.sm)
          reaper.ImGui_TextWrapped(ctx, line)
        end
      end
      -- The content's height: the cursor is past the last item and its spacing (scrolling does not change it); the
      -- body's padding below is the same as above it
      local end_y = reaper.ImGui_GetCursorPosY(ctx)
      if end_y then content_h = end_y - (spacing_y or 0) + top_y end
      K.child_dim("confirm_body_" .. c.id, nested_open)
      reaper.ImGui_EndChild(ctx)
    end
    -- A confirm sized to its content: the body is as tall as what it draws (up to the most the window it opens from
    -- allows), the footer right under it; asked for next frame, before the modal begins
    if c.fit and content_h then
      local key = tostring(c.cons_key) .. "|" .. tostring(c.checklist and #c.checklist.rows or 0) .. "|"
        .. tostring(math.floor((avail_w or 0) + 0.5)) .. "|" .. tostring(c.form_adv_open)
      if K.confirm_fit_due(c, key, body_h, content_h) then
        local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)
        local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
        if win_w and win_h and win_x and win_y then
          local h = K.confirm_fit_h(win_h, body_h, content_h, max_h)
          if host_x and host_y and host_w and host_h then
            c.fit_size = { x = host_x + (host_w - win_w) * 0.5, y = host_y + (host_h - h) * 0.5, w = win_w, h = h }
          else
            c.fit_size = { x = win_x, y = win_y + (win_h - h) * 0.5, w = win_w, h = h }
          end
        end
      else
        c.fit_shown = true   -- measured and no resize asked: drawn in full from the next frame
      end
    end

    reaper.ImGui_Dummy(ctx, 0, L.lg)
    if blocked then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.text_dim)
      reaper.ImGui_TextWrapped(ctx, blocked)
      reaper.ImGui_PopStyleColor(ctx, 1)
    elseif reason_h > 0 then
      reaper.ImGui_Dummy(ctx, 0, reason_h)
    end
    Theme.hcenter(ctx, cancel_w + L.md + confirm_w)

    if reaper.ImGui_Button(ctx, "Cancel###confirm_cancel", cancel_w, 0) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SetItemDefaultFocus(ctx)
    reaper.ImGui_SameLine(ctx, 0, L.md)

    if blocked then reaper.ImGui_BeginDisabled(ctx) end
    if not c.safe then K.push_danger(P) end
    if reaper.ImGui_Button(ctx, confirm_label .. "###confirm_ok", confirm_w, 0) and not blocked then
      confirmed = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if not c.safe then K.pop_danger() end
    if blocked then
      reaper.ImGui_EndDisabled(ctx)
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()
          | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
        Theme.tooltip(ctx, blocked)
      end
    end

    -- Save as Default's confirm, over this modal: its scrim (Theme.modal_scrim, on this modal's draw list) dims this
    -- modal's frame and footer; the body child, drawn above that list, is dimmed by K.child_dim. It stays inside the
    -- window this modal is kept in
    if c.nested then
      K.confirm_draw(c.nested, { x = host_x, y = host_y, w = host_w, h = host_h }, function() c.nested = nil end)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  if hidden then reaper.ImGui_PopStyleVar(ctx, 1) end

  -- The action runs once, after the modal was closed and its style / popup stacks are balanced
  if confirmed then
    c.confirmed = true
    if c.form then c.on_confirm(c.form.values) else c.on_confirm(c.checked, c.ticked) end
  end

  if c.opened and not reaper.ImGui_IsPopupOpen(ctx, popup_name) then
    Theme.modal_scrim(ctx, popup_name) -- not open any more: releases the scrim's first-frame latch
    c.nested = nil
    gone()
    if not c.confirmed and c.on_cancel then c.on_cancel() end
  end
end

local function draw_confirm_modal()
  local c = state.confirm
  if not c then return end
  -- An on_confirm that asks for a new confirm replaces this one: only this one is dropped
  K.confirm_draw(c, nil, function() if state.confirm == c then state.confirm = nil end end)
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

--- Run a note command and say what happened in the status line. The note action bar's buttons, their keys (S, Q, X, M),
--- the note menu and the pitch-zone double-click all come through here, so they report alike. A refusal or a
--- no-op says why; a success names the count and promises an undo point only when one was written.
---   id        "snap", "quantize", "cursor" (edit cursor to the note's middle), "split" (at the edit cursor) or "merge"
---   note_idx  the note to split or move the cursor to (default: the primary selected note)
K.note_action = function(id, note_idx)
  local undo_hint = string.format(" %s+Z to undo", K.MOD_LABEL)
  if id == "cursor" then
    -- Navigation, like a click on the ruler: playback follows, no undo point
    local idx = note_idx or state.selected_note
    local note = idx and state.notes and state.notes[idx]
    if not note then
      set_status("Select a note first")
      return
    end
    local _, item = get_target_take()
    if not item then
      set_status("This item is no longer in the project")
      return
    end
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    reaper.SetEditCurPos(item_pos + (note.start_time + note.end_time) * 0.5, false, true)
    return
  end
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
  if id == "bypass" then
    -- Toggle: when every selected note is already bypassed, turn bypass off; otherwise bypass them all
    local notes = {}
    for idx in pairs(state.selected_notes) do
      local n = state.notes[idx]
      if n and n.controls then notes[#notes + 1] = n end
    end
    if #notes == 0 then
      local n = state.selected_note and state.notes[state.selected_note]
      if n and n.controls then notes[1] = n end
    end
    if #notes == 0 then
      set_status("Select a note first")
      return
    end
    local all_bypassed = true
    for _, n in ipairs(notes) do
      if not n.controls.bypassed then all_bypassed = false break end
    end
    local new_bp = not all_bypassed
    for _, n in ipairs(notes) do n.controls.bypassed = new_bp end
    if apply_envelope_to_take(new_bp and "Bypass Notes" or "Unbypass Notes") then
      set_status(string.format("%s %d %s.%s", new_bp and "Bypassed" or "Turned bypass off on",
        #notes, plural(#notes, "note", "notes"), undo_hint))
    end
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

--- A copy of the analysis form `form` (K.form_new) for a modal: its edits never reach `form`.
K.form_copy = function(form)
  local copy = { guid = form.guid, source = form.source, seed = form.seed, values = {}, edited = {} }
  for k, v in pairs(form.values) do copy.values[k] = v end
  for k, v in pairs(form.edited) do copy.edited[k] = v end
  return copy
end

--- The analysis form of the open item: state.analysis_form when it is the open item's, else nil.
K.target_form = function()
  local form = state.analysis_form
  if form and form.guid == state.target_take_guid then return form end
  return nil
end

--- The Re-Analyze… modal (a request_confirm request without on_confirm) for an item named `name` whose notes hold
--- `edited` edits, seeded with a copy of `form`.
K.reanalyze_request = function(edited, name, form)
  local body
  if edited > 0 then
    body = {
      string.format("This replaces the detected notes and discards your edits to %d %s.",
        edited, plural(edited, "note", "notes")),
      K.REANALYZE_VALUES_LINE,
      string.format("%s+Z restores them once the analysis has finished.", K.MOD_LABEL),
    }
  else
    body = { K.REANALYZE_VALUES_LINE }
  end
  return {
    id = "reanalyze",
    title = string.format("Re-analyze %s?", name),
    form = K.form_copy(form),
    body_lines = body,
    confirm_label = "Re-Analyze",
    fit = true,
    safe = edited == 0,
  }
end

--- "…" > Analyze / Re-Analyze…: an item without notes is analysed at once with the canvas form's values (they are
--- on screen); an analysed item opens the Re-Analyze… modal, seeded from its own stored values (else the defaults).
K.request_analyze = function()
  local form = K.target_form()
  if not (state.notes and #state.notes > 0) then
    start_analysis(form and form.values or nil)
    -- No modal: an item whose values differ from the defaults is told so once the new analysis is written
    if state.is_analyzing and K.item_off_defaults(state.session_takes[state.target_take_guid or ""]) > 0 then
      K.reanalyze_status_guid = state.target_take_guid
    end
    return
  end
  local edited = count_modified_notes()
  local guid = state.target_take_guid
  local name = state.target_take_name or "this item"
  local req = K.reanalyze_request(edited, name, form or K.form_new(guid, state.session_takes[guid or ""]))
  req.on_confirm = function(values)
    -- The modal names one item: never analyze another one if the target changed meanwhile
    if state.target_take_guid ~= guid then
      set_status("The active item changed. Nothing was re-analyzed.")
      return
    end
    start_analysis(values)
    if state.is_analyzing then
      if edited > 0 then
        set_status(string.format("Re-analyzing %s…", name))
      elseif K.item_off_defaults(state.session_takes[guid or ""]) > 0 then
        K.reanalyze_status_guid = guid   -- told once the new analysis is written
      end
    end
  end
  request_confirm(req)
end

--- Change… (the short canvas's summary line): the analysis modal for the open item, seeded with a copy of the
--- canvas form `form`. Its on_confirm puts the values back into the canvas form (the changed keys marked edited, so
--- they stay when the defaults change) and analyses the item with them. With several items selected the canvas
--- button is a batch: Change… opens the batch modal instead (K.batch_request with that seed).
K.analyze_change_request = function(form)
  local guid = state.target_take_guid
  local name = state.target_take_name or "this item"
  return {
    id = "analyze",
    title = string.format("Analyze %s", name),
    form = K.form_copy(form),
    confirm_label = "Analyze",
    fit = true,
    safe = true,
    on_confirm = function(values)
      if state.target_take_guid ~= guid then
        set_status("The active item changed. Nothing was analyzed.")
        return
      end
      local target = state.analysis_form
      if target and target.guid == guid then
        for _, key in ipairs(K.ANALYSIS_KEYS) do
          if values[key] ~= target.values[key] then
            target.values[key] = values[key]
            target.edited[key] = true
          end
        end
      end
      start_analysis(values)
    end,
  }
end

--- The batch modal ("…" > Analyze Selected Items (N)…) for `entries` (K.batch_selection's takes), a request_confirm
--- request: a form of its own (never state.analysis_form) seeded from the defaults, or a copy of `seed` (a form),
--- and, when any item holds notes, K.batch_confirm's lines and list. on_confirm(values) starts the batch with them.
K.batch_modal_request = function(entries, seed)
  local n = #entries
  local warn = K.batch_confirm(entries) or {}
  local req = {
    id = "batch",
    title = string.format("Analyze %d items", n),
    form = seed and K.form_copy(seed) or K.form_new("batch", nil),
    body_lines = warn.body_lines or {},
    list = warn.list,
    after_lines = warn.after_lines,
    confirm_label = string.format("Analyze %d Items", n),
    fit = true,
    safe = warn.list == nil,
  }
  req.on_confirm = function(values) K.batch_start(entries, values) end
  return req
end

--- Analyze All Selected Items (the canvas button with two or more audio items selected, "…" > Analyze Selected
--- Items (N)…): the selection is read now and frozen. values (the canvas button: the canvas form's values): when any
--- item holds notes the user is asked once, with those items listed, before anything starts. Without values ("…"):
--- the batch modal (K.batch_modal_request) picks them, seeded from the defaults or a copy of the form `seed`
--- (Change… on a short canvas), and names the items that hold notes.
K.batch_request = function(values, seed)
  if state.is_analyzing or K.batch then return end
  local sel = K.batch_selection()
  if #sel.takes == 0 then
    set_status("Select an audio item first")
    return
  end
  -- An item can hold an analysis this window has not loaded (pasted, duplicated or its project opened after the
  -- script started): it is asked about as well. Checked once, here, not while the window only counts
  for _, entry in ipairs(sel.takes) do
    if not entry.has_notes and not state.session_takes[entry.guid] and read_take_raw(entry.take) ~= "" then
      entry.has_notes = true
    end
  end
  local req
  if values then
    req = K.batch_confirm(sel.takes)
    if not req then
      K.batch_start(sel.takes, values)
      return
    end
    req.on_confirm = function() K.batch_start(sel.takes, values) end
  else
    req = K.batch_modal_request(sel.takes, seed)
  end
  for _, row in ipairs(req.list or {}) do
    -- Where the item is: its track and its start as REAPER's ruler shows it (items often share a name)
    local at = reaper.format_timestr_pos(row.pos or 0, "", -1) or ""
    row.where = (row.track ~= nil and row.track ~= "") and (row.track .. " · " .. at) or at
  end
  req.id = "batch"
  request_confirm(req)
end

--- `text` broken into rows at most max_w wide in the font pushed now, at spaces: { { text, w } ... }. A word wider
--- than max_w gets a row of its own. The last answer per text is kept (the empty canvas asks every frame).
K.wrap_lines = function(wctx, text, max_w)
  K.wrap_cache = K.wrap_cache or {}
  local hit = K.wrap_cache[text]
  if hit and hit.max_w == max_w then return hit.rows end
  local rows, current, current_w = {}, nil, 0
  for word in text:gmatch("%S+") do
    local candidate = current and (current .. " " .. word) or word
    local w = reaper.ImGui_CalcTextSize(wctx, candidate) or 0
    if current and w > max_w then
      rows[#rows + 1] = { text = current, w = current_w }
      current, current_w = word, reaper.ImGui_CalcTextSize(wctx, word) or 0
    else
      current, current_w = candidate, w
    end
  end
  if current then rows[#rows + 1] = { text = current, w = current_w } end
  if not hit then
    K.wrap_cache_n = (K.wrap_cache_n or 0) + 1
    if K.wrap_cache_n > 32 then K.wrap_cache, K.wrap_cache_n = {}, 1 end   -- the count lines change with the selection
  end
  K.wrap_cache[text] = { max_w = max_w, rows = rows }
  return rows
end

K.RESPLIT_UNDO = "Re-split item"   -- the undo label of K.resplit
K.RESPLIT_STRETCH_UNDO = "Re-split selected notes"   -- the undo label of K.resplit_stretch
K.STRETCH_NO_ANALYSIS = "This stretch has no analysis: Re-analyze the item"
K.STRETCH_UNCHANGED = "Nothing to re-split."

--- The target's notes were reloaded by an undo or redo (`data`: what is stored now). When the step undone or redone
--- is a re-split, Separation follows it: the value the stored notes were split at (data.separation, the item's own
--- value), or, for notes stored without one, the value from before / after this session's last re-split of the item.
--- Nothing is saved outside the item: the bar shows what the stored notes were split at. A stretch re-split
--- (K.RESPLIT_STRETCH_UNDO) never changed the item's value, so undoing or redoing it leaves the value alone.
K.follow_resplit_undo = function(data)
  if reaper.Undo_CanRedo2(0) == K.RESPLIT_STRETCH_UNDO or reaper.Undo_CanUndo2(0) == K.RESPLIT_STRETCH_UNDO then
    return
  end
  local undone = reaper.Undo_CanRedo2(0) == K.RESPLIT_UNDO
  local redone = reaper.Undo_CanUndo2(0) == K.RESPLIT_UNDO
  if not (undone or redone) then return end
  local sep = tonumber(data and data.separation)
  if not sep then
    local last = K.resplit_last
    if not (last and last.guid == state.target_take_guid) then return end
    sep = undone and last.before or last.after
  end
  sep = math.max(K.LIMITS.separation[1], math.min(K.LIMITS.separation[2], sep))
  state.separation = sep
  if data then data.separation = sep end
end

--- Give the new notes of a re-split their pitch and features; a note paired with an old one (matched[i], see
--- K.resplit_match) keeps that note's edits: its controls and bypass, its target as the same offset from its new
--- centre, its pitch points. True when any of them ends up edited.
K.resplit_features = function(new_notes, matched)
  local any_edited = false
  for i, n in ipairs(new_notes) do
    if n.count > 0 then
      n.avg_note = n.sum_note / n.count
      n.display_note = math.floor(n.avg_note + 0.5)
      local old = matched[i]
      if old and old.controls then
        -- As split_note_at: the target follows the centre extract_note_features finds, by the old offset
        local pitch_offset = old.controls.center_pitch - old.avg_note
        extract_note_features(n, K.controls_carry(old.controls))
        if n.controls then
          n.controls.center_pitch = n.avg_note + pitch_offset
          K.points_transfer(n, { old }, {})
        end
      else
        extract_note_features(n)
      end
      if is_note_modified(n) then any_edited = true end
    end
  end
  return any_edited
end

--- The item's Separation changed (data.separation, mirrored in state.separation; it was prev_separation): split the
--- active item's notes again from the analysed frames in memory. A new note whose start and end are an old note's
--- (within one frame) keeps that note's edits: its controls and bypass, its target as the same offset from its new
--- centre, its pitch points.
--- When other edited notes would lose their edits it asks first; Cancel puts Separation back. One undo point
--- (K.RESPLIT_UNDO) holds the envelope and the stored notes; the view stays, the selection is cleared.
--- Without analysed frames (or while analysing) only the value is stored: the next analysis uses it.
--- `opts` (optional), for a re-split that is part of a larger edit (K.reset_item_all): undo = the undo label in place
--- of K.RESPLIT_UNDO; status = the status message in place of "Split into …"; title / confirm_label = the question's
--- title and button in place of "Re-split <item>?" / "Re-Split"; on_cancel = called whenever nothing is split after
--- all (Cancel, the item changed or is gone), after Separation is put back.
K.resplit = function(prev_separation, opts)
  local results = state.results
  if state.is_analyzing or not state.target_take_guid or not results or #results < 2 then return end
  local data = state.session_takes[state.target_take_guid]
  local on_cancel = opts and opts.on_cancel
  if not target_take_exists() then
    -- Nothing was split: the item keeps the Separation its notes were split at (the caller stored the new one)
    if data then data.separation = prev_separation end
    state.separation = prev_separation
    set_status("This item is no longer in the project")
    if on_cancel then on_cancel() end
    return
  end
  -- A pending arrow-key nudge is its own undo point, and its note counts as edited below
  if state.nudge_burst then flush_nudge_burst() end

  local sep = tonumber(K.item_value(data, "separation")) or state.separation
  local new_notes, split_points = K.segment(results, sep)
  local tol_s = K.frame_step(results)   -- one frame, as K.segment measures it
  local old_notes = state.notes
  local matched, lost = K.resplit_match(old_notes or {}, new_notes, tol_s, is_note_modified)

  local function run()
    local any_edited = K.resplit_features(new_notes, matched)
    state.notes, state.split_points = new_notes, split_points
    state.analysis_empty = (#new_notes == 0)
    -- Stored with the notes, so an undo / redo of this step brings its Separation back (K.follow_resplit_undo)
    state.separation = sep
    if data then data.separation = sep end
    K.resplit_last = { guid = state.target_take_guid, before = prev_separation, after = sep }
    clear_interaction_state(true)   -- note indices changed; the view stays

    -- Written as an edit (the take's pitch mode is set) when an edit survived, else like a fresh analysis
    if apply_envelope_to_take(opts and opts.undo or K.RESPLIT_UNDO, not any_edited) then
      set_status(opts and opts.status or string.format("Split into %d %s. %s+Z to undo", #new_notes,
        plural(#new_notes, "note", "notes"), K.MOD_LABEL))
    end
  end

  if lost == 0 then
    run()
    return
  end
  local guid = state.target_take_guid
  --- Cancel, or the item changed meanwhile: the item keeps the Separation its notes were split at
  local function put_back()
    if data then data.separation = prev_separation end
    if state.target_take_guid == guid then state.separation = prev_separation end
    if on_cancel then on_cancel() end
  end
  request_confirm({
    id = "resplit",
    title = opts and opts.title or string.format("Re-split %s?", state.target_take_name or "this item"),
    body_lines = {
      string.format("This re-splits the notes and discards your edits to %d %s.", lost, plural(lost, "note", "notes")),
      string.format("%s+Z restores them.", K.MOD_LABEL),
    },
    confirm_label = opts and opts.confirm_label or "Re-Split",
    on_confirm = function()
      -- The modal names one item, and the match was made against its notes as they were (an undo reloads them)
      if state.target_take_guid ~= guid or state.results ~= results or state.notes ~= old_notes
        or not target_take_exists() then
        set_status("The item changed meanwhile. Nothing was re-split.")
        put_back()
        return
      end
      run()
    end,
    on_cancel = put_back,
  })
end

K.RESET_ITEM_UNDO = "Reset item to defaults"
K.RESET_ITEM_STATUS = "Item reset to the defaults."

--- The pill menu's "Reset this item to defaults": the open item takes the script's default of every value
--- (DEFAULTS, K.item_reset_values; Key and Scale are not changed); its notes keep their own values. One undo point
--- (K.RESET_ITEM_UNDO). When
--- Separation differs and the analysed frames are in memory, the item is split again as part of it (K.resplit, which
--- asks first when edits would be lost; Cancel puts every value back). Nothing differs: nothing is written (UC1).
--- Returns true when the reset ran (or waits on the re-split's question).
K.reset_item_all = function()
  local guid = state.target_take_guid
  local data = guid and state.session_takes[guid]
  if not data or K.item_off_defaults(data) == 0 then return false end
  local before = { separation = data.separation, key_idx = data.key_idx, scale_idx = data.scale_idx, overrides = {} }
  for k, v in pairs(data.overrides or {}) do before.overrides[k] = v end
  local had_overrides = data.overrides ~= nil

  --- The bar's mirror of the item's Separation, Key and Scale, while it is still the open item
  local function mirror()
    if state.target_take_guid ~= guid or state.session_takes[guid] ~= data then return end
    if data.separation ~= nil then state.separation = data.separation end
    if data.key_idx ~= nil then state.key_idx = data.key_idx end
    if data.scale_idx ~= nil then state.scale_idx = data.scale_idx end
    update_scale_pitch_classes()
  end

  K.item_reset_values(data)
  mirror()
  local results = state.results
  local resplit = K.value_changed(before.separation, data.separation) and before.separation ~= nil
    and not state.is_analyzing and results ~= nil and #results >= 2
  if resplit then
    K.resplit(before.separation, {
      undo = K.RESET_ITEM_UNDO,
      status = K.RESET_ITEM_STATUS,
      title = string.format("Reset %s to the defaults?", state.target_take_name or "this item"),
      confirm_label = "Reset",
      on_cancel = function()
        -- Nothing was split: every value goes back to what it was
        data.separation, data.key_idx, data.scale_idx = before.separation, before.key_idx, before.scale_idx
        data.overrides = had_overrides and before.overrides or nil
        mirror()
      end,
    })
    return true
  end
  if apply_envelope_to_take(K.RESET_ITEM_UNDO) then set_status(K.RESET_ITEM_STATUS) end
  return true
end

--- Separation `sep` with notes selected: split again only the stretch from the first selected note's start to the
--- last selected note's end (the unselected notes between them too), from the analysed frames in memory. The notes
--- outside it stay as they are; the new notes keep the edits of old notes with the same start and end (as K.resplit)
--- and end up selected. When other edited notes inside it would lose their edits it asks first (as K.resplit). One
--- undo point (K.RESPLIT_STRETCH_UNDO). The item's Separation (data.separation) is not changed: a stretch value is
--- not stored, and a whole-item re-split replaces it.
K.resplit_stretch = function(sep)
  local results = state.results
  if state.is_analyzing or not state.target_take_guid or not state.notes then return end
  if not target_take_exists() then
    set_status("This item is no longer in the project")
    return
  end
  -- A pending arrow-key nudge is its own undo point, and its note counts as edited below
  if state.nudge_burst then flush_nudge_burst() end

  local old_notes = state.notes
  local first, last
  for idx in pairs(state.selected_notes) do
    if old_notes[idx] then
      if not first or idx < first then first = idx end
      if not last or idx > last then last = idx end
    end
  end
  if not first and state.selected_note and old_notes[state.selected_note] then
    first, last = state.selected_note, state.selected_note
  end
  if not first then return end
  sep = math.max(K.LIMITS.separation[1], math.min(K.LIMITS.separation[2], tonumber(sep) or state.separation))
  local new_notes, split_points, i0, i1
  if results then
    new_notes, split_points, i0, i1 = K.segment_stretch(results, sep, old_notes,
      old_notes[first].start_time, old_notes[last].end_time, state.split_points)
  end
  if not new_notes then
    set_status(K.STRETCH_NO_ANALYSIS)
    return
  end
  local old_in, new_in = {}, {}
  for i = first, last do old_in[#old_in + 1] = old_notes[i] end
  for i = i0, i1 do new_in[#new_in + 1] = new_notes[i] end
  local tol_s = K.frame_step(results)   -- one frame, as K.segment measures it
  local matched, lost = K.resplit_match(old_in, new_in, tol_s, is_note_modified)
  if #new_in == #old_in then
    local all_paired = true
    for i = 1, #new_in do
      if not matched[i] then all_paired = false break end
    end
    if all_paired then
      -- The same notes again: nothing changes, so no undo point (UC1)
      set_status(K.STRETCH_UNCHANGED)
      return
    end
  end

  local function run()
    local any_edited = K.resplit_features(new_in, matched)
    for i, n in ipairs(new_notes) do
      if (i < i0 or i > i1) and is_note_modified(n) then any_edited = true break end
    end
    state.notes, state.split_points = new_notes, split_points
    state.analysis_empty = (#new_notes == 0)
    clear_interaction_state(true)   -- note indices changed; the view stays
    for i = i0, i1 do state.selected_notes[i] = true end
    state.selected_note = (i1 >= i0) and i0 or nil

    -- Written as an edit (the take's pitch mode is set) when an edit survived, else like a fresh analysis
    if apply_envelope_to_take(K.RESPLIT_STRETCH_UNDO, not any_edited) then
      set_status(string.format("Re-split %d %s into %d.", #old_in, plural(#old_in, "note", "notes"), #new_in))
    end
  end

  if lost == 0 then
    run()
    return
  end
  local guid = state.target_take_guid
  request_confirm({
    id = "resplit",
    title = string.format("Re-split %s?", state.target_take_name or "this item"),
    body_lines = {
      string.format("This re-splits the notes and discards your edits to %d %s.", lost, plural(lost, "note", "notes")),
      string.format("%s+Z restores them.", K.MOD_LABEL),
    },
    confirm_label = "Re-Split",
    on_confirm = function()
      -- The match was made against the item's notes as they were (an undo reloads them)
      if state.target_take_guid ~= guid or state.results ~= results or state.notes ~= old_notes
        or not target_take_exists() then
        set_status("The item changed meanwhile. Nothing was re-split.")
        return
      end
      run()
    end,
  })
end

-------------------------------------------------------------------------------
-- 3c. APPLY TO OTHER ITEMS
-------------------------------------------------------------------------------
-- Design: docs/design/pitch-correct-value-levels.md (Apply). The open item's values (all of them, or one) are given
-- to the other pitched items the user ticks; nothing else is changed (no ExtState). The confirm (K.apply_open, in the GUI
-- section) names the consequence from a pure plan (K.apply_plan); the run (K.apply_run) computes one item at a time
-- while the window keeps answering, then writes every finished item in ONE undo block. It runs as K.batch with
-- kind = "apply", so the window treats it as a batch: values and rows locked, progress on the "…" button, Cancel
-- through K.cancel_analysis.

-- Every value Apply can give: the item values, then Key and Scale
K.APPLY_ALL_KEYS = { "separation", "correct_mode", "tighten", "tolerance", "retune_speed", "slide_in", "key_idx",
  "scale_idx" }
-- The keys a note can hold a value of its own for (every item value but Separation)
K.APPLY_NOTE_KEYS = { correct_mode = true, tighten = true, tolerance = true, retune_speed = true, slide_in = true }

--- The value of `key` the model `data` holds (Key and Scale included), or nil.
K.apply_item_get = function(data, key)
  if key == "key_idx" or key == "scale_idx" then return data and data[key] end
  return K.item_value(data, key)
end

--- The open item's values for `keys` (what Apply gives): its own, else what the window shows for it.
K.apply_source = function(keys)
  local data = state.target_take_guid and state.session_takes[state.target_take_guid]
  local src = {}
  for _, key in ipairs(keys) do
    local v = K.apply_item_get(data, key)
    if v == nil then
      if key == "separation" or key == "key_idx" or key == "scale_idx" then v = state[key] else v = get_effective(nil, key) end
    end
    src[key] = v
  end
  -- Key Auto on an item not analysed yet: the real key it stands for (Auto is never given to an item)
  if src.key_idx == 0 then
    local k, sc = K.key_resolve(0, nil, state.target_take_guid)
    src.key_idx = k
    if src.scale_idx ~= nil then src.scale_idx = sc end
  end
  return src
end

--- How many items Apply can reach now: the analysed items of the Pitched Items list but the open one.
K.apply_other_count = function()
  local n = 0
  for _, guid in ipairs(state.session_order) do
    if guid ~= state.target_take_guid and state.session_takes[guid] then n = n + 1 end
  end
  return n
end

-- Why a row of the Apply checklist cannot be ticked (docs/design/pitch-correct-value-levels.md, Copy deck)
K.APPLY_ROW_MIDI = "Not an audio item"
K.APPLY_ROW_GONE = "No longer in the project"

--- The rows of the Apply checklist: every analysed item of the Pitched Items list (state.session_order) but the open
--- item, in the list's order, as { id = guid, guid, take (nil: not in the project), midi, name, data (the session
--- model), reason } — reason (K.APPLY_ROW_MIDI / K.APPLY_ROW_GONE) when the item cannot be written (it is skipped).
K.apply_rows = function()
  local rows = {}
  local open = state.target_take_guid
  for _, guid in ipairs(state.session_order) do
    local data = state.session_takes[guid]
    if guid ~= open and data then
      local take = resolve_take_by_guid(guid, true)
      local midi = take and reaper.TakeIsMIDI(take) or false
      rows[#rows + 1] = { id = guid, guid = guid, take = take or nil, midi = midi, name = data.name or guid, data = data,
        reason = (not take and K.APPLY_ROW_GONE) or (midi and K.APPLY_ROW_MIDI) or nil }
    end
  end
  return rows
end

--- The guids of REAPER's selected audio items, as a set (the selection is only read, UC4).
K.apply_selected_guids = function()
  local set = {}
  for _, e in ipairs(K.batch_selection().takes) do set[e.guid] = true end
  return set
end

--- The rows ticked when the Apply confirm opens. Pure: the rows (K.apply_rows's) that are selected in the arrange
--- view (`selected` = a set of guids); when none of them is, every row. A row with a reason is never ticked.
K.apply_initial_ticks = function(rows, selected)
  local ticked, any = {}, false
  for _, row in ipairs(rows) do
    if not row.reason and selected[row.guid] then ticked[row.id] = true any = true end
  end
  if not any then
    for _, row in ipairs(rows) do
      if not row.reason then ticked[row.id] = true end
    end
  end
  return ticked
end

--- The ticks of `ticked` (guid -> true) carried over to `rows` (K.apply_rows's, read again). Pure: a row that is
--- no longer in the list, or that cannot be written any more (a reason), drops out.
K.apply_carry_ticks = function(rows, ticked)
  local carried = {}
  for _, row in ipairs(rows) do
    if not row.reason and ticked[row.guid] then carried[row.id] = true end
  end
  return carried
end

--- The targets of the ticked rows, as K.apply_plan's entries. Pure: a row with a reason is never one.
K.apply_ticked_entries = function(rows, ticked)
  local entries = {}
  for _, row in ipairs(rows) do
    if ticked[row.id] and not row.reason then
      entries[#entries + 1] = { guid = row.guid, take = row.take, midi = row.midi, name = row.name, data = row.data }
    end
  end
  return entries
end

--- What Apply would do. Pure: reads its arguments only (and the note splitter for the edited notes a re-split
--- loses). src = the values given ({ key = v }); entries = K.apply_ticked_entries's; keys = the keys given; keep = "Keep
--- changes already made to items and notes".
--- Returns plan = { items = { { guid, name, set = { key = v }, clear_note_keys = { key ... }, resplit, key_change,
--- lost, changes } ... }, counts = { items_lose, notes_lose, key_change, resplit, lost, not_resplit, skipped },
--- changed = how many items change }.
---   set: the values that differ from the item's. With keep, a value the item holds that differs from the script's
---        default (DEFAULTS) is left out (the user's), and so is Separation on an item whose notes carry edits (it is
---        not split again: counted in not_resplit). Key and Scale have no default: Keep never holds them back.
---   items_lose: the items whose own values (ones that differ from the default) are replaced; key_change: the items
---        whose Key or Scale is set.
---   clear_note_keys: without keep, the given note keys that any note holds a value of its own for (notes_lose
---        counts those notes); with keep, none.
---   resplit: Separation is set and the item has analysed frames; lost = its edited notes the new split does not
---        match (K.resplit_match).
--- An entry whose take is not in the project, or is MIDI, or has no model, gets no row: it is counted in skipped.
K.apply_plan = function(src, entries, keys, keep)
  local plan = { items = {}, changed = 0,
    counts = { items_lose = 0, notes_lose = 0, key_change = 0, resplit = 0, lost = 0, not_resplit = 0, skipped = 0 } }
  local counts = plan.counts
  for _, entry in ipairs(entries) do
    local data = entry.data
    if not entry.take or entry.midi or not data then
      counts.skipped = counts.skipped + 1
    else
      local notes = data.notes or {}
      local edited = false
      for _, n in ipairs(notes) do
        if is_note_modified(n) then edited = true break end
      end
      local row = { guid = entry.guid, name = entry.name, set = {}, clear_note_keys = {}, resplit = false,
        key_change = false, lost = 0, changes = false }
      local item_lose = false
      for _, key in ipairs(keys) do
        local v, cur = src[key], K.apply_item_get(data, key)
        -- A value of the item's own: it differs from its default (K.item_default)
        local def = K.item_default(key, entry.guid)
        local differs = cur ~= nil and def ~= nil and K.value_changed(cur, def)
        local own = keep and differs
        if v ~= nil and not own and K.value_changed(cur, v) then
          if key == "separation" and keep and edited then
            counts.not_resplit = counts.not_resplit + 1
          else
            row.set[key] = v
            if key == "key_idx" or key == "scale_idx" then
              row.key_change = true
            elseif differs then
              item_lose = true   -- a value of its own (not the default) is replaced
            end
          end
        end
        if not keep and K.APPLY_NOTE_KEYS[key] then
          for _, n in ipairs(notes) do
            if n.controls and n.controls[key] ~= nil then row.clear_note_keys[#row.clear_note_keys + 1] = key break end
          end
        end
      end
      -- The notes that lose a value of their own (each note once)
      local cleared = 0
      if #row.clear_note_keys > 0 then
        for _, n in ipairs(notes) do
          for _, key in ipairs(row.clear_note_keys) do
            if n.controls and n.controls[key] ~= nil then cleared = cleared + 1 break end
          end
        end
      end
      local results = data.results
      if row.set.separation ~= nil and results and #results >= 2 then
        row.resplit = true
        if edited then
          local new_notes = K.segment(results, row.set.separation)
          local _, lost = K.resplit_match(notes, new_notes, K.frame_step(results), is_note_modified)
          row.lost = lost or 0
        end
      end
      row.changes = next(row.set) ~= nil or cleared > 0
      if item_lose then counts.items_lose = counts.items_lose + 1 end
      if row.key_change then counts.key_change = counts.key_change + 1 end
      if row.resplit then counts.resplit = counts.resplit + 1 end
      counts.notes_lose = counts.notes_lose + cleared
      counts.lost = counts.lost + row.lost
      if row.changes then plan.changed = plan.changed + 1 end
      plan.items[#plan.items + 1] = row
    end
  end
  return plan
end

--- The model a row of the plan gives its item: a copy of `data` (the notes and their controls copied too) with
--- the row's values set, its note keys cleared and, for a re-split, the notes split again from the analysed frames
--- (a new note with an old note's start and end keeps its edits, as K.resplit). The session model is not touched.
K.apply_item_model = function(data, row)
  local new = {}
  for k, v in pairs(data) do new[k] = v end
  new.overrides = {}
  for k, v in pairs(data.overrides or {}) do new.overrides[k] = v end
  for key, v in pairs(row.set) do
    if key == "separation" or key == "key_idx" or key == "scale_idx" then
      new[key] = v
      if key ~= "separation" then new.key_from_track = nil end   -- a key given, not found on the track
    else
      new.overrides[key] = v
    end
  end
  local notes = {}
  for i, n in ipairs(data.notes or {}) do
    local copy = {}
    for k, v in pairs(n) do copy[k] = v end
    if n.controls then
      copy.controls = {}
      for k, v in pairs(n.controls) do copy.controls[k] = v end
      for _, key in ipairs(row.clear_note_keys) do copy.controls[key] = nil end
    end
    notes[i] = copy
  end
  new.notes = notes
  if row.resplit then
    local results = data.results
    local new_notes = K.segment(results, new.separation)
    local matched = K.resplit_match(notes, new_notes, K.frame_step(results), is_note_modified)
    K.resplit_features(new_notes, matched)
    new.notes = new_notes
  end
  return new
end

--- The undo label of an Apply that wrote n items. label: the one value's name, or nil for every value.
K.apply_undo_label = function(n, label)
  if label then return string.format("Apply %s to %d items", label, n) end
  return string.format("Apply values to %d items", n)
end

--- The closing message of an Apply. r = { written, skipped, cancelled, total }.
K.apply_summary = function(r)
  if r.cancelled then
    if r.written == 0 then return "Apply cancelled. No item was changed." end
    return string.format("Apply cancelled. %d of %d items were changed and kept (%s+Z undoes them).",
      r.written, r.total, K.MOD_LABEL)
  end
  if r.skipped > 0 then return string.format("Applied to %d items. %d skipped: no audio.", r.written, r.skipped) end
  return string.format("Applied to %d items (%s+Z undoes them).", r.written, K.MOD_LABEL)
end
K.APPLY_NOTHING = "Nothing was changed: the ticked items already have these values."

--- Run an Apply: `plan` (K.apply_plan's), label (the one value's name, or nil). The items that change are computed one after another (K.apply_tick), and written in one undo
--- block when the run ends (K.apply_finish). Nothing outside the items is written: one Cmd+Z undoes all of it.
K.apply_run = function(plan, label)
  if K.batch or state.is_analyzing then return false end
  local queue = {}
  for _, row in ipairs(plan.items) do
    -- Never the open item: its canvas holds its model (K.apply_open's on_confirm already refuses a changed item)
    if row.changes and row.guid ~= state.target_take_guid then queue[#queue + 1] = { guid = row.guid, name = row.name, row = row, len = 1 } end
  end
  if #queue == 0 then
    set_status(K.APPLY_NOTHING)
    return true
  end
  if state.nudge_burst then flush_nudge_burst() end   -- a pending arrow-key nudge is its own undo point
  K.batch = K.batch_new(queue, state.target_take_guid)
  K.batch.kind, K.batch.label, K.batch.skipped = "apply", label, plan.counts.skipped
  -- The window treats the run as an analysis: the values, the canvas and the resync wait for it
  state.is_analyzing = true
  state.progress = 0
  return true
end

--- One frame of a running Apply (K.analysis_tick): compute the next items while the frame's analysis budget
--- (K.ANALYSIS_SLICE_S) lasts, one at least. An item that cannot be computed (its model went, or raised) is left as it
--- was and counted as skipped. With every item computed, the run ends.
K.apply_tick = function()
  local batch = K.batch
  local slice_start = reaper.time_precise()
  repeat
    batch.index = batch.index + 1
    local entry = batch.queue[batch.index]
    if not entry then
      K.apply_finish(false)
      return
    end
    local data = state.session_takes[entry.guid]
    local ok, new = false, nil
    if data then ok, new = pcall(K.apply_item_model, data, entry.row) end
    if ok and new then
      batch.done[#batch.done + 1] = { guid = entry.guid, data = new }
    else
      batch.failed = batch.failed + 1
    end
    batch.done_len = batch.done_len + 1
  until reaper.time_precise() - slice_start > K.ANALYSIS_SLICE_S
  if batch.index >= #batch.queue then K.apply_finish(false) end
end

--- End the running Apply (its queue is done, Cancel, the window closes): every finished item is written in ONE undo
--- block (its model becomes the session's, its envelope is rewritten); an item that is no longer in the project, or
--- whose envelope cannot be made, keeps its model and counts as skipped. One closing message.
K.apply_finish = function(cancelled)
  local batch = K.batch
  if not batch or batch.kind ~= "apply" then return end
  K.batch = nil
  state.is_analyzing = false
  state.progress = 0

  local ready = {}
  for _, d in ipairs(batch.done) do
    local take = resolve_take_by_guid(d.guid, true)
    local item = take and K.take_item(take) or nil
    if take and item then ready[#ready + 1] = { d = d, take = take, item = item } end
  end
  local written = 0
  if #ready > 0 then
    reaper.Undo_BeginBlock()
    state.undo_open = true
    for _, r in ipairs(ready) do
      local guid = r.d.guid
      local old = state.session_takes[guid]
      state.session_takes[guid] = r.d.data
      local ok, wrote = pcall(K.write_take_envelope, guid, r.d.data, false, r.take, r.item)
      if ok and wrote then
        written = written + 1
      else
        state.session_takes[guid] = old
      end
    end
    reaper.UpdateArrange()
    reaper.Undo_EndBlock(K.apply_undo_label(written, batch.label), -1)
    state.undo_open = false
    K.frame_view_memo.frame = nil
    note_own_write()
  end
  -- The project was not followed while the run went on: the next frame reads it again
  state.last_change_count = nil

  local skipped = (batch.skipped or 0) + #batch.queue - written
  if cancelled then skipped = (batch.skipped or 0) + #batch.done - written end
  K.status_hold(K.apply_summary({ written = written, skipped = skipped, cancelled = cancelled and true or false,
    total = #batch.queue }))
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

--- Forward Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z to REAPER's Undo / Redo: ReaImGui keeps the keys of a focused
--- window, so REAPER never sees them otherwise. Same gate as the Space forwarding, and not during a mouse
--- gesture on the canvas. A pending arrow-key nudge is committed first, so the undo takes that nudge back.
local function forward_undo_to_reaper()
  if state.drag or state.edge_drag or state.marquee or state.point_drag
     or not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
     or reaper.ImGui_IsAnyItemActive(ctx)
     or reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId()) then
    return
  end
  local undo_chord = reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_Z()
  local cmd
  if reaper.ImGui_Shortcut(ctx, undo_chord) then
    cmd = K.UNDO_CMD
  elseif reaper.ImGui_Shortcut(ctx, reaper.ImGui_Mod_Shift() | undo_chord) then
    cmd = K.REDO_CMD
  end
  if cmd then
    flush_nudge_burst()
    reaper.Main_OnCommand(cmd, 0)
  end
end

-------------------------------------------------------------------------------
-- TOP BAR
-------------------------------------------------------------------------------
-- The window's controls above the canvas, in three groups read from broad to specific (the note actions Snap,
-- Quantize, Split and Merge are on the canvas, in the note action bar under the selected note: K.draw_note_bar):
--   Clip          brand, target badge, Key, Scale
--   Values        the selection pill (what a drag changes: this item, or the selected notes; a click opens its
--                 menu), then three groups split by hairlines, all in the default font (no captions: each
--                 value's tooltip names its group): Notes (Separation), Correction (Mode, Tighten, Tolerance),
--                 Shaping (Strength, Slide In)
--   Right         "…" (Analyze / Cancel, Reset, Layers, Note Tone, Settings, Help) and Close, right-aligned on row 1
-- The Values units are drawn by K.bar_frame (see TOP BAR CONTROLS below); this
-- section places them. Every width is measured from the longest text its control can show. On how many rows the
-- units sit is a HDR_PLANS entry chosen from the content width alone (never from the selected item or the note
-- selection), so nothing jumps while working: as the width shrinks the groups wrap onto more rows, and at the
-- narrowest the Values group wraps inside itself. The item badge takes the width its row has left and truncates
-- its text with an ellipsis.

local hdr_static = nil        -- widths that depend only on fonts and style (measured once)
local hdr_was_docked = nil    -- IsWindowDocked of the previous frame (nil until known): size constraints are for floating windows only

-- Chunk-level names of this section (loop_body and the top bar controls use them): everything else stays
-- private to the block below, so it does not count against the chunk's 200-local limit.
local measure_header_static, hdr_min_content_w, hdr_fit_text, draw_header

do
  local HDR_NO_TARGET_TEXT = "No Audio Item"
  local HDR_ELLIPSIS = "…"
  local HDR_PROGRESS_LONGEST = "100%"
  -- Why Analyze / Reset are disabled (in the More popup, beside the item)
  local HDR_REASON_NO_TARGET = K.REASON_NO_TARGET
  local HDR_REASON_NO_NOTES = "Analyze an item first"
  local HDR_MORE_TIP = "Menu\n\nAnalyze, Analyze Selected Items, Find Range and Key Again, Reset, Layers, Note Tone,"
    .. " Settings and Help."
  -- The right-click menu of Key and Scale (hdr_key_menu)
  local HDR_APPLY_KEY = "Apply Key to other items\xE2\x80\xA6"

  -- The units of each group, and the group every unit belongs to (a separator is drawn where the group changes).
  -- The Values group is the pill, then three named groups (K.BAR_GROUP: Notes, Correction, Shaping), split by
  -- hairline separators.
  local HDR_CLIP = { "brand", "badge", "key", "scale" }
  local HDR_VALUES = { "pill", "sep", "mode", "tight", "tol", "strength", "slide" }
  K.BAR_GROUP = { pill = "values", sep = "notes", mode = "correction", tight = "correction", tol = "correction",
    strength = "shaping", slide = "shaping" }
  local HDR_GROUP = {}
  for _, id in ipairs(HDR_CLIP) do HDR_GROUP[id] = "clip" end
  for id, group in pairs(K.BAR_GROUP) do HDR_GROUP[id] = group end

  --- One row holding the units of every list given, in order.
  local function hdr_row(...)
    local row = {}
    for _, list in ipairs({ ... }) do
      for _, id in ipairs(list) do row[#row + 1] = id end
    end
    return row
  end

  -- From the widest to the narrowest (LG4). At the narrowest the Values group wraps by group, Shaping on its own
  -- row, so the main controls stay together.
  local HDR_PLANS = {
    { rows = { hdr_row(HDR_CLIP, HDR_VALUES) } },
    { rows = { HDR_CLIP, HDR_VALUES } },
    { rows = { { "brand", "badge" }, { "key", "scale" }, { "pill", "sep" }, { "mode", "tight" }, { "tol" },
      { "strength", "slide" } } },
  }
  K.HDR_PLANS = HDR_PLANS
  -- The plan a first-use window is sized for: two rows
  local HDR_FIRST_USE_PLAN = HDR_PLANS[2]
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

  --- Measure everything in the top bar that does not change from frame to frame. Call with the default
  --- font and the Theme style pushed (before Begin is fine).
  measure_header_static = function()
    local L = Theme.layout
    local s = {}
    s.frame_h = reaper.ImGui_GetFrameHeight(ctx)
    s.pad_x = L.md * 2                                    -- FramePadding.x on both sides of a label
    s.close_sz = L.icon_target.size + L.icon_target.pad * 2   -- Close is destructive: the 24 px minimum target (WCAG 2.5.8)
    s.brand_sz = L.row_h
    s.row_h = math.max(L.row_h, s.brand_sz, s.close_sz, s.frame_h)

    s.key_w = Theme.calc_combo_width(ctx, COMBO_LABELS.keys)
    -- Width of the Key list: Theme.selectable draws its text itself, so the popup only grows to fit if the
    -- rows are given the width of the longest name ("C# / Db") plus the text padding on both sides
    s.key_list_w = math.max(s.key_w, hdr_max_text_w(COMBO_LABELS.key_names) + L.sm * 2)
    s.scale_w = Theme.calc_combo_width(ctx, COMBO_LABELS.scales)
    s.more_w = math.max(hdr_text_w(HDR_ELLIPSIS), hdr_text_w(HDR_PROGRESS_LONGEST)) + s.pad_x
    s.no_target_w = hdr_text_w(HDR_NO_TARGET_TEXT) + s.pad_x  -- the badge never plans narrower than this
    s.badge_min_w = hdr_text_w(HDR_ELLIPSIS) + s.pad_x
    -- More, Panel, Close: the real gaps between them (see hdr_draw_right)
    s.right_w = s.more_w + L.sm + s.close_sz + L.lg + s.close_sz
    -- The Values units (see TOP BAR CONTROLS): s.bar.unit_w[id]
    s.bar = K.bar_measure(ctx)
    return s
  end

  --- `text` shortened with a trailing ellipsis to at most max_w wide (cached: the top bar runs every frame).
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

  --- Gap placed before the unit `id` when it follows `prev` on the same row: a group break (with a separator
  --- line in it) where the group changes, the standard gap inside the Clip group, tight everywhere else.
  local function hdr_gap_before(prev, id)
    local L = Theme.layout
    if HDR_GROUP[prev] ~= HDR_GROUP[id] then return L.xl end
    if HDR_GROUP[id] == "clip" then return L.md end
    return L.sm
  end

  local function hdr_element_w(id, s, badge_w)
    if id == "brand" then return s.brand_sz end
    if id == "badge" then return badge_w end
    if id == "key" then return s.key_w end
    if id == "scale" then return s.scale_w end
    return s.bar.unit_w[id] or 0
  end

  local function hdr_row_w(row, s, badge_w)
    local w = 0
    for i, id in ipairs(row) do
      if i > 1 then w = w + hdr_gap_before(row[i - 1], id) end
      w = w + hdr_element_w(id, s, badge_w)
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
        local reserved = (r == 1) and (L.xl + s.right_w) or 0
        local left = avail_w - hdr_row_w(row, s, 0) - reserved
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

  --- Content width a plan needs to be chosen: its widest row, the badge at its floor, row 1 with the right group.
  local function hdr_plan_w(plan, s)
    local L = Theme.layout
    local w = 0
    for r, row in ipairs(plan.rows) do
      w = math.max(w, hdr_row_w(row, s, s.no_target_w) + ((r == 1) and (L.xl + s.right_w) or 0))
    end
    return w
  end

  --- Content width the narrowest floating window keeps (the last plan). With `full`: the width a first-use
  --- window opens with (two rows). With `plan_i`: the width the plan HDR_PLANS[plan_i] needs. The second value is
  --- the number of rows the bar then has.
  hdr_min_content_w = function(s, full, plan_i)
    local plan = (plan_i and HDR_PLANS[plan_i]) or (full and HDR_FIRST_USE_PLAN) or HDR_PLANS[#HDR_PLANS]
    local w = hdr_plan_w(plan, s)
    -- Rows: what the bar drew last frame at the window's real width (s.rows_now), so a wide window may be as
    -- short as its bar allows; before the first frame, the plan's own count
    local rows = (not full) and s.rows_now or nil
    if not rows then rows = #plan.rows end
    return w, rows
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
      local badge_bg = track_col or (hs.has_notes and P.well or Theme.with_alpha(P.yellow, 0.25))   -- analysed: a quiet tag
      Theme.badge(ctx, hdr_fit_text(state.target_take_name, hs.badge_w - s.pad_x), {
        id = "target",
        bg = badge_bg,
        text_color = Theme.label_on(badge_bg),
        w = hs.badge_w,
      })
      -- The tooltip is built on hover only: it reads the item's pitch algorithm from REAPER
      if reaper.ImGui_IsItemHovered(ctx) then
        Theme.tooltip(ctx, K.tip("Active item: " .. state.target_take_name,
          "Status: " .. (hs.has_notes and "Analyzed & Active" or "Ready to Analyze") .. "\n"
            .. hdr_pitch_algorithm_line(hs.target_take),
          "Select any audio item in REAPER to switch to it."))
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

  --- The right-click menu of the Key and Scale combos (call right after the combo): Apply Key to other items…
  local function hdr_key_menu(id)
    if not reaper.ImGui_BeginPopupContextItem(ctx, id) then return end
    -- HC5: Esc closes this menu (innermost)
    if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
    K.apply_menu_item(ctx, HDR_APPLY_KEY, { "key_idx", "scale_idx" })
    reaper.ImGui_EndPopup(ctx)
  end

  local function hdr_draw_key(hs)
    local P, s = hs.P, hs.s
    -- Previews the short name ("C#") but lists the full one ("C# / Db"), so it stays a plain BeginCombo.
    -- Its preview takes the button face, like Scale's Theme.combo; popped before the list draws.
    reaper.ImGui_SetNextItemWidth(ctx, s.key_w)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        P.btn)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), P.btn_h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  P.btn_a)
    -- Key index 0 is "Auto" (only while the item is not analysed: an analysed item always shows its real key)
    local key_info = SCALE_KEYS[state.key_idx]
    local key_open = reaper.ImGui_BeginCombo(ctx, "##key_selector", key_info and key_info.display or "Auto")
    reaper.ImGui_PopStyleColor(ctx, 3)
    if key_open then
      local auto_sel = (state.key_idx == 0)
      if Theme.selectable(ctx, "Auto##key_0", auto_sel, nil, s.key_list_w) and not auto_sel then
        state.key_idx = 0
        K.scale_changed("key")   -- an analysed item takes its track's key (K.find_key_request)
      end
      if auto_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
      for i, k_info in ipairs(SCALE_KEYS) do
        local is_sel = (state.key_idx == i)
        if Theme.selectable(ctx, k_info.name .. "##key_" .. i, is_sel, nil, s.key_list_w) and not is_sel then
          state.key_idx = i
          K.scale_changed("key")
        end
        if is_sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    hdr_key_menu("##ctx_key")   -- right after the combo: it asks about the last item
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      -- An item whose key was found on its track says so, with the runner-up (K.key_found_text); built on hover only
      local found = K.key_found_text(state.target_take_guid and state.session_takes[state.target_take_guid])
      Theme.tooltip(ctx, "Key\n\nThe root note of the scale."
        .. (found and ("\n\n" .. found) or "")
        .. "\n\nAuto\n\nFinds the song's key from the whole track the first time one of its items is analyzed."
        .. "\n\nRight-click: apply Key and Scale to other items.")
    end
  end

  local function hdr_draw_scale(hs)
    local s = hs.s
    -- While Key is Auto (an item not analysed yet) the scale is found with the key: "Auto", disabled with its reason
    -- (Theme.combo's tooltip shows on a disabled combo too)
    local auto = (state.key_idx == 0)
    local new_idx, changed = Theme.combo(ctx, "##scale_selector", SCALE_DEFINITIONS, auto and 0 or state.scale_idx, {
      w = s.scale_w,
      disabled = auto,
      placeholder = "Auto",
      tooltip = auto and "Found with the key"
        or "Scale\n\nMarks the in-scale rows on the canvas and sets the scale Quantize (Q) snaps to.\n\nRight-click: apply Key and Scale to other items.",
    })
    if changed and new_idx ~= state.scale_idx then
      state.scale_idx = new_idx
      K.scale_changed("scale")
    end
    hdr_key_menu("##ctx_scale")
  end

  --- The Layers submenu of More: each layer shows how it looks on the canvas, a swatch from the same canvas
  --- tokens and shape, before its label (the labels carry no colour word).
  local function hdr_draw_layers(hs)
    local P, L = hs.P, Theme.layout
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
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "The pitch after correction.\n\nHover or drag a setting to see where it acts.")
    end
    layer_checkbox("Pitch Points", "show_smart_spots", function(dl, x, cy)
      reaper.ImGui_DrawList_AddCircleFilled(dl, x + sw_w * 0.5, cy, K.SPOT_R, LC.spot)
    end)
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      Theme.tooltip(ctx, "The points on a note that bend its pitch.\n\nPeaks and valleys, the note's start and end, and points you add.")
    end
  end

  --- "…" (More) and its popup: Analyze / Re-Analyze, Analyze Selected Items and Reset (with the reason beside a
  --- disabled one), then Layers, Settings and Help. While analysing the button reads the progress ("42%") and the
  --- popup offers Cancel (Cancel Batch for a batch) in place of Analyze (Esc is not bound to Cancel: on a floating window Esc closes the window, which
  --- cancels too).
  local function hdr_draw_more(hs)
    local s = hs.s
    local batch = K.batch
    local analyzing = state.is_analyzing or batch ~= nil
    -- One number for a batch, here and in the status line: the share of its audio that is analysed
    local pct = math.floor(K.analysis_progress() * 100)
    if reaper.ImGui_Button(ctx, (analyzing and string.format("%d%%", pct) or HDR_ELLIPSIS) .. "###hdr_more", s.more_w, 0) then
      reaper.ImGui_OpenPopup(ctx, "##hdr_more_popup")
    end
    if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
      local tip = HDR_MORE_TIP
      if batch then
        tip = string.format(batch.kind == "apply" and "Applying values to %d of %d items.\n\nOpen to cancel."
          or "Analyzing %d of %d.\n\nOpen to cancel.", math.min(batch.index, #batch.queue), #batch.queue)
      elseif analyzing then
        tip = "Analyzing.\n\nOpen to cancel."
      end
      Theme.tooltip(ctx, tip)
    end
    if reaper.ImGui_BeginPopup(ctx, "##hdr_more_popup") then
      -- HC5: Esc closes this popup (innermost); the window-level handler ignores Esc while a popup is open
      if reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
      if analyzing then
        if reaper.ImGui_MenuItem(ctx, string.format(batch and K.CANCEL_BATCH_FMT or K.CANCEL_FMT, pct) .. "###more_analyze") then
          K.cancel_analysis()
        end
        if batch and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, K.CANCEL_BATCH_TIP)
        end
      else
        if reaper.ImGui_MenuItem(ctx, hs.analyze_label .. "###more_analyze",
            (not hs.has_target) and HDR_REASON_NO_TARGET or nil, false, hs.has_target) then
          K.request_analyze()
        end
        -- Re-Analyze…: what the item was analysed with (ST1)
        local tip = hs.has_notes and K.analyzed_with_tip(state.session_takes[state.target_take_guid or ""]) or nil
        if tip and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
          Theme.tooltip(ctx, tip)
        end
      end
      -- Analyze Selected Items: always in the menu; with fewer than two audio items selected in REAPER, or while
      -- an analysis runs, it is disabled with the reason beside it
      local peek = K.batch_peek(reaper.time_precise())
      local batch_reason = analyzing and K.REASON_ANALYZING or (peek.n < 2 and K.REASON_BATCH_FEW or nil)
      local batch_label = batch_reason and "Analyze Selected Items" or string.format("Analyze Selected Items (%d)…", peek.n)
      if reaper.ImGui_MenuItem(ctx, batch_label .. "###more_batch", batch_reason, false, batch_reason == nil) then
        K.batch_request()
      end
      -- Find Range and Key Again: hears the open item's track afresh; disabled with the reason beside it (while it
      -- runs, Cancel above stops it)
      local again_reason = K.find_again_reason(hs.has_target)
      if reaper.ImGui_MenuItem(ctx, "Find Range and Key Again###more_find_again", again_reason, false,
          again_reason == nil) then
        K.find_again_request()
      end
      if reaper.ImGui_MenuItem(ctx, hs.reset_label .. "###more_reset",
          (not hs.has_notes) and HDR_REASON_NO_NOTES or nil, false, hs.has_notes) then
        request_reset(hs.reset_sel_n, hs.reset_note_n)
      end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_BeginMenu(ctx, "Layers") then
        hdr_draw_layers(hs)
        reaper.ImGui_EndMenu(ctx)
      end
      if reaper.ImGui_MenuItem(ctx, "Note Tone", nil, state.note_tone) then
        state.note_tone = not state.note_tone
        state.tone_failed = false
        K.save_settings("tone")
      end
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
        Theme.tooltip(ctx, "Play a tone at the note's pitch while you drag it")
      end
      if reaper.ImGui_MenuItem(ctx, "Settings") then
        show_settings_modal = true
      end
      if reaper.ImGui_MenuItem(ctx, "Keyboard Shortcuts & Help") then
        show_info_modal = true
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  --- More and Close, right-aligned on the current row. Returns true when Close was clicked.
  local function hdr_draw_right(hs)
    local L, s = Theme.layout, hs.s
    reaper.ImGui_SameLine(ctx, 0, 0)
    -- Never start left of the previous element plus a group gap, however narrow the row is
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx) - hs.margin
    Theme.right_align(ctx, math.min(s.right_w, math.max(0, avail_w - L.xl)), hs.margin)

    hdr_draw_more(hs)

    -- The side panel's switch: lit while the panel shows, dim while the window has no room for it
    reaper.ImGui_SameLine(ctx, 0, L.sm)
    Theme.align(ctx, nil, s.close_sz)
    local panel_shown = state.sidebar_open and state.sidebar_fits
    if Theme.icon_btn(ctx, "##hdr_panel", Theme.icons.panel_right, {
      preset = L.icon_target,
      icon_size = L.icon_md.size,
      w = s.close_sz, h = s.close_sz,
      color = panel_shown and hs.P.accent or (state.sidebar_fits and hs.P.text or hs.P.text_dim),
      tooltip = panel_shown and BODY.panel_tip_hide
        or (state.sidebar_fits and string.format(BODY.panel_tip_show, #state.session_order) or BODY.panel_tip_narrow),
    }) then
      K.toggle_sidebar()
    end

    -- The destructive Close sits a group gap away. An icon shorter than the frame is centred on the row's
    -- framed widgets.
    reaper.ImGui_SameLine(ctx, 0, L.lg)
    Theme.align(ctx, nil, s.close_sz)
    return Theme.icon_btn(ctx, "##hdr_close", Theme.icons.close, {
      preset = L.icon_target,
      icon_size = L.icon_md.size,   -- the glyph of the medium icons; only the click target is 24 px
      w = s.close_sz, h = s.close_sz,   -- icon_btn sizes the button from icon_size unless told otherwise
      tooltip = K.tip(hs.docked and "Close" or "Close (Esc)", "Your corrections stay on the items."),
    })
  end

  --- Draws the top bar. `right_margin` is the room kept free at the right end of every row (the window has no
  --- padding of its own). Returns true when Close was clicked.
  draw_header = function(P, docked, has_target, has_notes, target_take, target_item, right_margin)
    local L = Theme.layout
    local s = hdr_static
    right_margin = right_margin or 0
    -- Real booleans: a nil reaching MenuItem's `enabled` would mean "enabled"
    has_target = has_target and true or false
    has_notes = has_notes and true or false
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx) - right_margin

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

    local hs = {
      P = P, s = s, docked = docked, badge_w = badge_w, margin = right_margin,
      has_target = has_target, has_notes = has_notes, target_take = target_take, target_item = target_item,
      analyze_label = has_notes and "Re-Analyze…" or "Analyze",
      reset_label = reset_label, reset_sel_n = reset_sel_n, reset_note_n = reset_note_n,
    }
    -- The Values units draw themselves (see TOP BAR CONTROLS)
    local draw_unit = K.bar_frame(ctx, has_target, s.bar)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

    local close_clicked = false
    for r, row in ipairs(plan.rows) do
      for i, id in ipairs(row) do
        if i > 1 then
          local gap = hdr_gap_before(row[i - 1], id)
          reaper.ImGui_SameLine(ctx, 0, gap)
          if HDR_GROUP[row[i - 1]] ~= HDR_GROUP[id] then
            -- A hairline in the middle of the group break
            local sep_x, sep_y = reaper.ImGui_GetCursorScreenPos(ctx)
            sep_x = sep_x - math.floor(gap * 0.5)
            reaper.ImGui_DrawList_AddLine(draw_list, sep_x, sep_y + L.xs, sep_x, sep_y + s.frame_h - L.xs, P.border)
          end
        end
        if id == "brand" then
          Theme.brand_icon(ctx, s.brand_sz, s.row_h)
        elseif id == "badge" then
          hdr_draw_target_badge(hs)
        elseif id == "key" then
          hdr_draw_key(hs)
        elseif id == "scale" then
          hdr_draw_scale(hs)
        else
          draw_unit(id)
        end
      end
      if r == 1 then close_clicked = hdr_draw_right(hs) end
    end
    s.rows_now = #plan.rows
    return close_clicked
  end
end

-------------------------------------------------------------------------------
-- TOP BAR CONTROLS
-------------------------------------------------------------------------------
-- The units of the Values group, drawn in every state (disabled, with the reason, when there is nothing to act on):
-- the selection pill and one value control per entry of BAR_VALUES (a drag with its text inside and a range fill
-- under it). The note actions (Snap, Quantize, Split, Merge) share the bar's enable rules and reasons
-- (K.note_actions_frame) but are drawn on the canvas, under the selected note (K.draw_note_bar). A value control edits what the
-- pill names: the selected notes, else this item. The bar never changes other items: only "Apply to other items"
-- does. A new or re-analysed item starts at the script's DEFAULTS.
-- K.bar_measure gives their widths, each from its longest label, so a value, an override mark or a selection
-- never changes the layout; K.bar_frame returns the function that draws one unit this frame. The top bar
-- (above) decides where they go. The status line that used to sit beside them is a pill on the canvas
-- (K.canvas_status).

do
  -- Appended to a value that differs from the level above it: this item's from the script's default, a selected
  -- note's from the item's
  local BAR_OVERRIDE_MARK = "*"
  -- Shown in place of a value that does not exist for what is selected
  local BAR_NO_VALUE = "\xE2\x80\x93"
  local BAR_RANGE_SEP = "\xE2\x80\x93"   -- between the lowest and highest value of a mixed selection
  -- The selection pill: what a drag in the bar changes
  local BAR_PILL_NONE, BAR_PILL_ONE, BAR_PILL_MANY = "This item", "1 note", "%d notes"
  local BAR_PILL_TIP_NONE = "Your edits change this item only.\n\nSelect notes to change just those notes.\n\nClick or right-click: apply to other items, save as a default."
  local BAR_PILL_TIP_NOTES = "Your edits change the selected notes.\n\nEsc goes back to this item.\n\nClick or right-click: apply to other items, save as a default."
  -- Why the controls are disabled (the tooltips say it; the canvas pill carries the state)
  local BAR_REASON_ANALYZING = "Wait for the analysis to finish"
  local BAR_REASON_NO_TARGET = "Select an audio item"
  local BAR_REASON_NOT_ANALYZED = "Analyze an item first"
  local BAR_HINT_SELECT_NOTE = "Select a note to edit it"
  local BAR_HINT_OUTDATED = "Outdated: this item's envelope is from other settings. Edit a note to rewrite it."
  -- What a drag changes, by its target (a line of every value tooltip), the levels, and the gestures
  local BAR_SCOPE_ITEM = "Changes this item."
  local BAR_SCOPE_NOTE = "Changes the selected note."
  local BAR_SCOPE_NOTES = "Changes the %d selected notes; each keeps its difference from the others."
  local BAR_LEVELS = "Default: %s. This item: %s."
  -- After the default in BAR_LEVELS: where it comes from (K.item_default); the factory one has no tag
  local BAR_LEVEL_TAG = { track = " (track)", system = " (system)" }
  local BAR_GESTURES = string.format("Drag to change (%s-drag: fine). Double-click: reset. %s-click: type a value. Right-click: more.",
    K.MOD_LABEL, K.MOD_LABEL)
  local BAR_TOLERANCE_IDLE = K.TOLERANCE_IDLE_TIP
  -- The Mode dropdown (see draw_mode): its tooltip, its scope line by what it changes, the text of a mixed selection,
  -- and the line a value's tooltip gains when the selected notes' mode does not use it (key: K.mode_unused)
  local BAR_MODE = {
    title = "Mode",
    tip = K.MODE_TIP,
    scope_item = "Changes this item: every note without its own mode.",
    scope_note = "Changes the selected note.",
    scope_notes = "Changes the %d selected notes.",
    mixed = "Mixed",
    unused = K.MODE_UNUSED_TIP,
  }
  -- Separation (see draw_separation): what letting go does
  local BAR_SEP_RESPLIT = "Letting go splits this item's notes again."
  local BAR_SEP_NEXT = "This item's first analysis uses it."
  local BAR_SEP_NOTES = "Splits the selected stretch again: only the notes from the first to the last selected one change."
  -- The named groups of the Values group (K.BAR_GROUP): no caption shows them, so each value's tooltip starts with
  -- its group's name (the hairline separators show where a group ends)
  local BAR_GROUP_NAMES = { notes = "Notes", correction = "Correction", shaping = "Shaping" }
  local BAR_GROUP_TIP = "%s \xC2\xB7 %s"
  -- The pill's menu (see draw_pill)
  local BAR_PILL_MENU = {
    to_item = "Edits go to: this item",
    to_note = "Edits go to: the selected note",
    to_notes = "Edits go to: the %d selected notes",
    apply = "Apply to other items\xE2\x80\xA6",
    reset = "Reset this item to defaults",
    reset_none = "Already at the defaults",
  }
  -- The right-click menu of a value (K.value_menu)
  local BAR_MENU_RESET_ITEM, BAR_MENU_RESET_NOTES = "Reset to default", "Reset to item value"
  local BAR_MENU_APPLY = "Apply %s to other items\xE2\x80\xA6"
  local BAR_MENU_APPLY_NONE = "No other pitched items"

  -- The values of the bar, in the order they are shown. key = the model's key; label = the name on the control;
  -- lo / hi / num / unit = the range and the text in display units (scale x the stored value); levels = where the
  -- value exists: "all" (default, item, note; Separation has no note level of its own: see draw_separation);
  -- tip = what the value does to the sound.
  local BAR_VALUES = {
    { id = "tight", key = "tighten", label = "Tighten", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "all",
      title = "Tighten",
      tip = K.VALUE_TIP.tighten },
    { id = "strength", key = "retune_speed", label = "Strength", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "all",
      title = "Correction Strength",
      tip = K.VALUE_TIP.retune_speed },
    { id = "tol", key = "tolerance", label = "Tolerance", lo = K.LIMITS.tolerance[1], hi = K.LIMITS.tolerance[2], scale = 1,
      num = "%.0f", unit = "\xC2\xA2", levels = "all",
      title = "Tolerance",
      tip = K.VALUE_TIP.tolerance },
    { id = "slide", key = "slide_in", label = "Slide In", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "all",
      title = "Slide In",
      tip = K.VALUE_TIP.slide_in },
    { id = "sep", key = "separation", label = "Separation", lo = 0, hi = 100, scale = 100, num = "%.0f", unit = "%",
      levels = "all",
      title = "Separation",
      tip = K.VALUE_TIP.separation },
  }
  -- The note actions, in the order of the note action bar (K.draw_note_bar): the same commands as the keys and the
  -- note menu. id = K.note_action's id and the Theme.icons entry; tip = the tooltip
  K.NOTE_ACTIONS = {
    { id = "snap",     tip = "Snap to nearest semitone (S)" },
    { id = "quantize", tip = "Quantize to the active scale (Q)" },
    { id = "cursor",   tip = "Edit cursor to the middle of the note (C)\n\nHold C and turn the wheel to move it.", icon = "cursor_to_note" },
    { id = "split",    tip = "Split at the edit cursor (X)" },
    { id = "merge",    tip = "Merge the selected notes (M)" },
  }
  local BAR_VALUE_BY_ID = {}
  for _, spec in ipairs(BAR_VALUES) do BAR_VALUE_BY_ID[spec.id] = spec end

  local function bar_text_w(bctx, text)
    return (reaper.ImGui_CalcTextSize(bctx, text)) or 0
  end

  --- Widths that depend only on the font and the tokens: every label is measured at its longest, so a value,
  --- an override mark or a selection never changes the layout. unit_w[id] is the width of the unit `id`.
  K.bar_measure = function(bctx)
    local L = Theme.layout
    local s = { unit_w = {} }
    s.frame_h = reaper.ImGui_GetFrameHeight(bctx) or 0
    s.pad_x = L.md * 2                  -- FramePadding.x on both sides of a label (what Theme.badge and Button use)
    local function measure_value(spec)
      local mark_w = bar_text_w(bctx, " " .. BAR_OVERRIDE_MARK)
      local hi_t = string.format(spec.num, spec.hi)
      if spec.id == "sep" then
        -- One value (the item's), never a range or a blank
        return bar_text_w(bctx, spec.label .. " " .. hi_t .. spec.unit) + mark_w + s.pad_x
      end
      local widest = math.max(
        bar_text_w(bctx, spec.label .. " " .. hi_t .. spec.unit),
        bar_text_w(bctx, spec.label .. " " .. hi_t .. BAR_RANGE_SEP .. hi_t .. spec.unit),
        bar_text_w(bctx, spec.label .. " " .. BAR_NO_VALUE))
      return widest + mark_w + s.pad_x
    end
    -- Every value in the default font, the font it is drawn in (LG3)
    for _, spec in ipairs(BAR_VALUES) do s.unit_w[spec.id] = measure_value(spec) end
    s.unit_w.pill = math.max(bar_text_w(bctx, BAR_PILL_NONE), bar_text_w(bctx, BAR_PILL_ONE),
      bar_text_w(bctx, string.format(BAR_PILL_MANY, 999))) + s.pad_x
    -- The Mode dropdown: its longest text, the frame padding and the arrow (a square of the frame height)
    local mode_text_w = bar_text_w(bctx, BAR_MODE.mixed)
    for _, name in ipairs(K.MODES) do mode_text_w = math.max(mode_text_w, bar_text_w(bctx, name)) end
    s.unit_w.mode = mode_text_w + s.pad_x + s.frame_h
    return s
  end

  --- The selected notes that hold values, in one reused table (no table per frame), and how many.
  local bar_sel = {}
  -- The press now held on a value control: what it was aimed at when it began (see draw_value)
  local bar_gesture = { id = nil, target = nil, notes = nil, dead = false }
  -- This item's value of each control (by id) when its press began: a drag that ends there writes nothing (UC1)
  local bar_press = {}
  -- Separation while its control is held or typed into: the value from before the press (see draw_separation)
  local bar_sep_before = nil
  local function bar_sel_notes()
    local n = 0
    if state.notes then
      for idx in pairs(state.selected_notes) do
        local note = state.notes[idx]
        if note and note.controls then n = n + 1; bar_sel[n] = note end
      end
      if n == 0 and state.selected_note then
        local note = state.notes[state.selected_note]
        if note and note.controls then n = 1; bar_sel[1] = note end
      end
    end
    for i = #bar_sel, n + 1, -1 do bar_sel[i] = nil end
    return bar_sel, n
  end

  --- The value of `spec` in effect on `note`, in display units.
  local function bar_note_value(note, spec)
    return (tonumber(get_effective(note, spec.key)) or 0) * spec.scale
  end

  --- Give `note` its own value of `spec` (display units, clamped to the range).
  local function bar_note_write(note, spec, v)
    note.controls[spec.key] = math.max(spec.lo, math.min(spec.hi, v)) / spec.scale
  end

  --- Whether a committed value `after` differs from `before` (stored units; nil = no value): an edit that ends
  --- where it began makes no undo point.
  K.value_changed = function(before, after)
    if type(before) ~= "number" or type(after) ~= "number" then return before ~= after end
    return math.abs(after - before) > 1e-9
  end

  --- The bar's write path: give the `sel_n` notes of `sel_notes` their own value `v` of `key` (stored units; 0 is a
  --- value of its own), or, with none, this item (data.overrides, Separation data.separation and state.separation;
  --- an item not analysed yet keeps its Separation in state.separation, and its first analysis stores it). A model
  --- change only: the caller writes the envelope (one undo point). Never another item, never ExtState.
  K.bar_write = function(key, v, sel_notes, sel_n)
    if sel_n > 0 then
      for i = 1, sel_n do sel_notes[i].controls[key] = v end
      return
    end
    local data = state.target_take_guid and state.session_takes[state.target_take_guid]
    if key == "separation" then
      state.separation = v
      if data then data.separation = v end
    elseif data then
      data.overrides = data.overrides or {}
      data.overrides[key] = v
    end
  end

  --- Reset `key` (double-click, or the right-click menu): the `sel_n` selected notes lose their own value (they
  --- follow the item again), else this item takes its default (K.item_default, HC3). One undo point when
  --- something changed (none when the item is at the default already: UC1); true when it was written. Separation
  --- is reset by draw_separation (a re-split).
  K.reset_target = function(key, sel_notes, sel_n)
    state.bar_edit = nil
    local changed = false
    if sel_n > 0 then
      for i = 1, sel_n do
        local ctrl = sel_notes[i].controls
        if ctrl[key] ~= nil then ctrl[key], changed = nil, true end
      end
    else
      local data = state.target_take_guid and state.session_takes[state.target_take_guid]
      if not data then return false end
      local default, now = K.item_default(key, state.target_take_guid), K.item_value(data, key)
      if now == nil then now = default end
      if default ~= nil and K.value_changed(now, default) then
        K.bar_write(key, default, sel_notes, 0)
        changed = true
      end
    end
    if not changed then return false end
    return apply_envelope_to_take("Reset " .. (PARAM_LABELS[key] or key)) == true
  end

  --- The right-click menu of the value `key` named `label` (call right after its control): reset (to the item's
  --- value with notes selected, else to its default), apply it to other items (K.apply_open), and save it as the
  --- System or Track Default (K.default_menu_items).
  --- Returns true when Reset was chosen: the caller resets (K.reset_target, or Separation's re-split).
  K.value_menu = function(bctx, key, label, sel_n)
    if not reaper.ImGui_BeginPopupContextItem(bctx, "##ctx_" .. key) then return false end
    -- HC5: Esc closes this menu (innermost)
    if reaper.ImGui_Shortcut(bctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(bctx) end
    local reset = reaper.ImGui_MenuItem(bctx, (sel_n > 0) and BAR_MENU_RESET_NOTES or BAR_MENU_RESET_ITEM)
    K.apply_menu_item(bctx, string.format(BAR_MENU_APPLY, label), { key })
    reaper.ImGui_Separator(bctx)
    K.default_menu_items(bctx, { key }, label)
    reaper.ImGui_EndPopup(bctx)
    return reset == true
  end

  --- Why Apply to other items cannot be opened now (nil = it can): an analysis or a batch runs, or there is no other
  --- pitched item.
  K.apply_reason = function()
    if state.is_analyzing or K.batch then return BAR_REASON_ANALYZING end
    if K.apply_other_count() == 0 then return BAR_MENU_APPLY_NONE end
    return nil
  end

  --- A menu entry that opens the Apply confirm for `keys` (nil = every value), disabled with its reason beside it.
  K.apply_menu_item = function(mctx, text, keys)
    local reason = K.apply_reason()
    if reaper.ImGui_MenuItem(mctx, text, reason, false, reason == nil) and reason == nil then
      K.apply_open(keys)
    end
  end

  -- The Apply confirm's copy (docs/design/pitch-correct-value-levels.md, Copy deck)
  local APPLY_COPY = {
    title_all = "Apply this item's values to other items?",
    title_one = "Apply %s to other items?",
    caption = "Apply to:",
    tick_all = "All",
    tick_none = "None",
    tick_some = "Tick at least one item",
    none_tickable = "No item here can be changed",
    check = "Keep changes already made to items and notes",
    consequence = "%d items lose their own values, %d notes lose theirs, %d items change key, %d are split again (%d edited notes in them are lost).",
    keep = "%d items with edited notes are not split again.",
    keep_key = "Key and Scale are still applied.",
    confirm = "Apply (%d)",
    nothing = "Nothing would change",
    changed = "The item changed meanwhile. Nothing was applied.",
  }
  -- The name of each value in the confirm's title, its readout and its undo label
  local APPLY_LABEL = { correct_mode = "Mode", key_idx = "Key", scale_idx = "Key" }
  for _, spec in ipairs(BAR_VALUES) do APPLY_LABEL[spec.key] = spec.label end

  --- The values given, in one line: "Key E Major · Separation 50% · Mode Natural · Tighten 40% · …".
  K.apply_values_line = function(src, keys)
    local given = {}
    for _, key in ipairs(keys) do given[key] = true end
    local parts = {}
    if given.key_idx or given.scale_idx then
      local key_info, scale_info = SCALE_KEYS[src.key_idx], SCALE_DEFINITIONS[src.scale_idx]
      if key_info and scale_info then parts[#parts + 1] = "Key " .. key_info.display .. " " .. scale_info.name end
    end
    for _, id in ipairs({ "sep", "mode", "tight", "tol", "strength", "slide" }) do
      if id == "mode" then
        if given.correct_mode then
          parts[#parts + 1] = "Mode " .. (K.MODES[(tonumber(src.correct_mode) or 0) + 1] or K.MODES[1])
        end
      else
        local spec = BAR_VALUE_BY_ID[id]
        if given[spec.key] then
          parts[#parts + 1] = spec.label .. " " .. string.format(spec.num, (tonumber(src[spec.key]) or 0) * spec.scale)
            .. spec.unit
        end
      end
    end
    return table.concat(parts, " \xC2\xB7 ")
  end

  -- Saved defaults: the copy of the menu entries, their reasons, the System Default confirm and the status lines
  -- (docs/design/pitch-correct-saved-defaults.md)
  local DEFAULT_COPY = {
    sys_all = "Set as System Default\xE2\x80\xA6",
    sys_one = "Set %s as System Default\xE2\x80\xA6",
    track_all = "Set as Track Default",
    track_one = "Set %s as Track Default",
    track_clear = "Clear Track Default",
    sys_same = "Already the system default",
    track_same = "Already the track default",
    track_none = "No track default",
    no_track = "The item has no track",
    sys_title_all = "Make this item's values your System Default?",
    sys_title_one = "Make %s your System Default?",
    sys_body = "New analyses on tracks without a Track Default start with: %s.",
    sys_keep = "Items already analyzed keep their values. Restore Factory Defaults in Settings brings back the factory values.",
    sys_confirm = "Set as System Default",
    sys_done = "System default saved: %s.",
    track_done = "Track default of %s: %s (%s+Z undoes it).",
    track_cleared = "Track default of %s cleared (%s+Z undoes it).",
    undo_set_all = "Set track default",
    undo_set_one = "Set %s as track default",
    undo_clear = "Clear track default",
    was = "%s (was %s)",
  }
  -- The value keys a default holds (Key and Scale never)
  local DEFAULT_ALL_KEYS = K.ITEM_KEYS

  --- This item's value of each of `keys` (K.apply_source), nil when no analysed item is open.
  local function default_source(keys)
    local guid = state.target_take_guid
    if not (guid and state.session_takes[guid]) then return nil end
    return K.apply_source(keys)
  end

  --- The track of the open item and its name ("this track" when it has none).
  local function default_track()
    local track = K.take_track(state.target_take_guid)
    if not track then return nil, nil end
    local _, name = reaper.GetTrackName(track)
    return track, (name and name ~= "") and name or "this track"
  end

  --- Why "Set as System Default" / "Set as Track Default" for `keys` cannot run now (nil = it can). `level` is
  --- "system" or "track".
  K.default_reason = function(keys, level)
    if state.is_analyzing or K.batch then return BAR_REASON_ANALYZING end
    local src = default_source(keys)
    if not src then return BAR_REASON_NOT_ANALYZED end
    local have
    if level == "track" then
      local track = default_track()
      if not track then return DEFAULT_COPY.no_track end
      have = K.track_defaults(track)
    end
    for _, key in ipairs(keys) do
      local d
      if level == "track" then d = have[key] else d = K.sys_defaults[key] or DEFAULTS[key] end
      if d == nil or K.value_changed(src[key], d) then return nil end
    end
    return (level == "track") and DEFAULT_COPY.track_same or DEFAULT_COPY.sys_same
  end

  --- The System Default confirm for `keys` (nil: every value): names what new analyses start with, and what it was.
  K.sys_default_request = function(keys)
    keys = keys or DEFAULT_ALL_KEYS
    local src = default_source(keys)
    if not src then return nil end
    local parts = {}
    for _, key in ipairs(keys) do
      local old = { [key] = K.sys_defaults[key] or DEFAULTS[key] }
      local now_t, old_t = K.apply_values_line(src, { key }), K.apply_values_line(old, { key })
      parts[#parts + 1] = (now_t ~= old_t) and string.format(DEFAULT_COPY.was, now_t, old_t) or now_t
    end
    local line = table.concat(parts, ", ")
    local title = (#keys == 1) and string.format(DEFAULT_COPY.sys_title_one, K.apply_values_line(src, keys))
      or DEFAULT_COPY.sys_title_all
    return {
      title = title,
      body_lines = { string.format(DEFAULT_COPY.sys_body, line), DEFAULT_COPY.sys_keep },
      confirm_label = DEFAULT_COPY.sys_confirm,
      fit = true,
      safe = true,   -- nothing the user made is lost (items keep their values)
      on_confirm = function()
        K.sys_default_set(src)
        set_status(string.format(DEFAULT_COPY.sys_done, K.apply_values_line(src, keys)))
      end,
    }
  end

  --- Write `t` ({ [key] = number }, empty: none) as the Track Default of `track`, as one undo point `undo`.
  local function track_default_write(track, t, undo)
    local any = next(t) ~= nil
    reaper.Undo_BeginBlock()
    reaper.GetSetMediaTrackInfo_String(track, K.TRACK_DEFAULT_KEY, any and JSON.encode(t) or "", true)
    reaper.Undo_EndBlock(undo, -1)
    note_own_write()
  end

  --- "Set as Track Default" (keys nil: every value): this item's values of `keys` become its track's default; the
  --- track's other keys stay. One undo point; nothing else changes. Returns true when it was written.
  K.set_track_default = function(keys)
    keys = keys or DEFAULT_ALL_KEYS
    if K.default_reason(keys, "track") then return false end
    local src = default_source(keys)
    local track, name = default_track()
    local t = {}
    for k, v in pairs(K.track_defaults(track)) do t[k] = v end
    for _, key in ipairs(keys) do t[key] = K.item_value_valid(key, src[key]) end
    local undo = (#keys == 1) and string.format(DEFAULT_COPY.undo_set_one, APPLY_LABEL[keys[1]] or keys[1])
      or DEFAULT_COPY.undo_set_all
    track_default_write(track, t, undo)
    set_status(string.format(DEFAULT_COPY.track_done, name, K.apply_values_line(src, keys), K.MOD_LABEL))
    return true
  end

  --- Why "Clear Track Default" cannot run now (nil = it can).
  K.clear_track_reason = function()
    if state.is_analyzing or K.batch then return BAR_REASON_ANALYZING end
    local track = default_track()
    if not track then return DEFAULT_COPY.no_track end
    if next(K.track_defaults(track)) == nil then return DEFAULT_COPY.track_none end
    return nil
  end

  --- "Clear Track Default": the open item's track has no default any more (one undo point).
  K.clear_track_default = function()
    if K.clear_track_reason() then return false end
    local track, name = default_track()
    track_default_write(track, {}, DEFAULT_COPY.undo_clear)
    set_status(string.format(DEFAULT_COPY.track_cleared, name, K.MOD_LABEL))
    return true
  end

  --- The default entries of a menu for `keys` (nil: every value; label: the value's name, for one): Set as System
  --- Default…, Set as Track Default and, for every value (the pill menu), Clear Track Default. Each disabled entry
  --- says why beside it (EP2).
  K.default_menu_items = function(mctx, keys, label)
    local one = keys ~= nil
    keys = keys or DEFAULT_ALL_KEYS
    local sys_reason = K.default_reason(keys, "system")
    local sys_text = one and string.format(DEFAULT_COPY.sys_one, label) or DEFAULT_COPY.sys_all
    if reaper.ImGui_MenuItem(mctx, sys_text, sys_reason, false, sys_reason == nil) and sys_reason == nil then
      local req = K.sys_default_request(keys)
      if req then request_confirm(req) end
    end
    local track_reason = K.default_reason(keys, "track")
    local track_text = one and string.format(DEFAULT_COPY.track_one, label) or DEFAULT_COPY.track_all
    if reaper.ImGui_MenuItem(mctx, track_text, track_reason, false, track_reason == nil) and track_reason == nil then
      K.set_track_default(keys)
    end
    if not one then
      local clear_reason = K.clear_track_reason()
      if reaper.ImGui_MenuItem(mctx, DEFAULT_COPY.track_clear, clear_reason, false, clear_reason == nil)
          and clear_reason == nil then
        K.clear_track_default()
      end
    end
  end

  --- "Apply to other items…" (keys nil: every value, Key and Scale included) or "Apply <Value> to other items…"
  --- (keys = { key }, or Key and Scale): the confirm with its checklist of the other pitched items (ticked at first:
  --- the ones selected in the arrange view, or every one when none is) and "Keep changes…". The consequence is
  --- planned when the confirm opens and again when the ticked rows or the check change (HI5). Apply writes only the
  --- ticked items, in one undo block (HC4: one Cmd+Z restores it); the confirm stays, as the place to pick them.
  K.apply_open = function(keys)
    keys = keys or K.APPLY_ALL_KEYS
    if state.confirm or K.apply_reason() == BAR_REASON_ANALYZING then return end
    local label = nil
    if #keys == 1 or (#keys == 2 and keys[1] == "key_idx") then label = APPLY_LABEL[keys[1]] end
    local src = K.apply_source(keys)
    local rows = K.apply_rows()
    local ticked = K.apply_initial_ticks(rows, K.apply_selected_guids())
    -- Only a Separation given splits items again: the keep line is about that alone
    -- ... and Keep never holds back a Key and Scale given (they have no default): the confirm says so
    local gives_sep, gives_key = false, false
    for _, key in ipairs(keys) do
      if key == "separation" then gives_sep = true end
      if key == "key_idx" or key == "scale_idx" then gives_key = true end
    end
    -- The item the values come from: it must still be the open item when the user confirms
    local open_guid = state.target_take_guid
    -- Planned from the rows of now: an undo in the arrange view while the confirm is up reloads the pitched items
    -- (state.session_takes) and may take one out of the project. The ticks carry over by guid. Also says whether
    -- any row can be ticked at all
    local function plan_for(checked, ticks)
      local now_rows = K.apply_rows()
      local tickable = false
      for _, row in ipairs(now_rows) do if not row.reason then tickable = true end end
      local entries = K.apply_ticked_entries(now_rows, K.apply_carry_ticks(now_rows, ticks or {}))
      return K.apply_plan(src, entries, keys, checked), #entries, tickable
    end
    request_confirm({
      id = "apply",
      title = label and string.format(APPLY_COPY.title_one, label) or APPLY_COPY.title_all,
      body_lines = { K.apply_values_line(src, keys) },
      checklist = { caption = APPLY_COPY.caption, all_label = APPLY_COPY.tick_all, none_label = APPLY_COPY.tick_none,
        rows = rows, ticked = ticked },
      check = { label = APPLY_COPY.check, value = false },
      size = Theme.layout.modal_md,
      fit = true,   -- its content changes with the ticks: no empty band above the buttons
      confirm_label = string.format(APPLY_COPY.confirm, 0),
      consequence = function(checked, ticks)
        local plan, n_ticked, tickable = plan_for(checked, ticks)
        local c = plan.counts
        local lines = {}
        if n_ticked > 0 then
          lines[1] = string.format(APPLY_COPY.consequence, c.items_lose, c.notes_lose, c.key_change, c.resplit, c.lost)
          if checked and gives_sep then lines[#lines + 1] = string.format(APPLY_COPY.keep, c.not_resplit) end
          if checked and gives_key then lines[#lines + 1] = APPLY_COPY.keep_key end
        end
        local out = { lines = lines, confirm_label = string.format(APPLY_COPY.confirm, plan.changed) }
        if n_ticked == 0 then
          out.reason = tickable and APPLY_COPY.tick_some or APPLY_COPY.none_tickable
        elseif plan.changed == 0 then
          out.reason = APPLY_COPY.nothing
        end
        return out
      end,
      on_confirm = function(checked, ticks)
        -- The open item changed while the confirm was up (the selection follower): the values and the targets were
        -- read for another item, and the new open item may be one of the targets
        if state.target_take_guid ~= open_guid then
          set_status(APPLY_COPY.changed)
          return
        end
        local plan, n_ticked = plan_for(checked, ticks)
        if n_ticked == 0 then return end
        K.apply_run(plan, label)
      end,
    })
  end

  --- Give every note of a bar drag back what it held when the drag began (false = no own value).
  local function bar_edit_restore(edit, key)
    for note, raw in pairs(edit.raws) do
      if raw == false then note.controls[key] = nil else note.controls[key] = raw end
    end
  end

  --- How many notes are selected, and the index of one of them (the note itself when exactly one is).
  local function bar_selection()
    local sel_count, sel_idx = 0, nil
    if state.notes then
      for idx in pairs(state.selected_notes) do
        if state.notes[idx] then sel_count = sel_count + 1; sel_idx = idx end
      end
      if sel_count == 0 and state.selected_note and state.notes[state.selected_note] then
        sel_count, sel_idx = 1, state.selected_note
      end
    end
    return sel_count, sel_idx
  end

  --- Why the bar's values and the note actions cannot be used at all (nil = they can): an analysis is running,
  --- there is no target, or it has no notes yet. has_data = the target is analysed and has notes.
  local function bar_inspector_reason(has_target, has_data)
    if state.is_analyzing then return BAR_REASON_ANALYZING end
    if not has_target then return BAR_REASON_NO_TARGET end
    if not has_data then return BAR_REASON_NOT_ANALYZED end
    return nil
  end

  --- The note actions this frame (K.NOTE_ACTIONS, drawn by K.draw_note_bar). `has_target`: there is a target take
  --- (nil = state.target_take_guid decides); `target_item`: its item (nil = K.frame_target's). Returns reason(id),
  --- why the action `id` cannot run now (nil = it can; the same rules as the S / Q / X / M keys), and the note a
  --- single-note action acts on (sel_idx, for K.note_action).
  K.note_actions_frame = function(has_target, target_item)
    if has_target == nil then has_target = (state.target_take_guid ~= nil) end
    local has_data = (#state.results > 0 and state.notes ~= nil and #state.notes > 0)
    local inspector_reason = bar_inspector_reason(has_target, has_data)
    local sel_count, sel_idx = bar_selection()
    local single_note = (sel_count == 1) and state.notes[sel_idx] or nil

    -- Split needs the edit cursor strictly inside the selected note, as the X key does (asked once per frame).
    -- Note times are relative to the item's start.
    local cursor_in_note = nil
    local function edit_cursor_in_note()
      if cursor_in_note == nil then
        cursor_in_note = false
        local item = target_item
        if not item then
          local _, target = K.frame_target()
          item = target
        end
        local item_pos = item and reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local cursor = item_pos and reaper.GetCursorPosition()
        if single_note and item_pos and cursor then
          local t = cursor - item_pos
          cursor_in_note = (t > single_note.start_time and t < single_note.end_time)
        end
      end
      return cursor_in_note
    end

    local function reason(id)
      if inspector_reason then return inspector_reason end
      if id == "merge" then
        if sel_count < 2 then return "Select 2 or more notes" end
        return nil
      end
      if sel_count == 0 then return "Select a note" end
      if id == "split" then
        if sel_count > 1 then return "Select one note to split" end
        if not edit_cursor_in_note() then return "Move the edit cursor into the selected note" end
      end
      return nil
    end
    return reason, sel_idx
  end

  --- The status line: a status message (set_status) while it lasts, else what the window is doing or waiting
  --- for; "" when there is nothing to say. `editing` = notes are on the canvas and can be edited (an empty
  --- canvas carries its own centred message, and a bypassed one its badge, so neither adds a hint).
  K.status_line = function(editing)
    if state.status.text ~= "" and reaper.time_precise() < state.status.until_time then
      return state.status.text
    end
    if state.pre then return K.locked_reason() end   -- stage 1 of an Auto analysis
    local batch = K.batch
    if batch and batch.kind == "apply" then
      return string.format("Applying values to %d of %d items\xE2\x80\xA6 %d%%", math.min(batch.index, #batch.queue),
        #batch.queue, math.floor(K.analysis_progress() * 100))
    end
    if batch then
      local entry = batch.queue[batch.index]
      return string.format("Analyzing %d of %d: %s… %d%%", math.min(batch.index, #batch.queue), #batch.queue,
        entry and entry.name or "item", math.floor(K.analysis_progress() * 100))
    end
    if state.is_analyzing then
      return string.format("Analyzing %s… %d%%", state.target_take_name or "this item", math.floor(K.analysis_progress() * 100))
    end
    if not (state.frame.take and state.target_take_name) then
      return state.selection_issue or ""
    end
    if editing then
      if state.hovered_point then return "Drag a point to bend the pitch there" end
      -- The zoom hint is for a pointer that rests (the hit-test that sets it does not run during a gesture), and
      -- the Outdated hint wins over it
      local in_gesture = state.drag or state.edge_drag or state.marquee or state.point_drag or state.view_drag
      if state.points_zoom_hint and not in_gesture then
        local guid = state.target_take_guid
        if guid and state.stale_takes[guid] then return BAR_HINT_OUTDATED end
        return "Zoom in to move pitch points"
      end
      local sel_count = bar_selection()
      if sel_count == 0 then
        local guid = state.target_take_guid
        if guid and state.stale_takes[guid] then return BAR_HINT_OUTDATED end
        return BAR_HINT_SELECT_NOTE, true
      end
      if sel_count > 1 then return string.format("%d notes selected", sel_count), true end
    end
    return ""
  end

  --- Draw the status line on a pill whose bottom-left corner is (x, bottom_y), at most max_w wide (the text is
  --- shortened with an ellipsis). The canvas calls it on every path it leaves by, so a status message shows in
  --- every state. C.pill_text is >= 4.5:1 on the pill over every canvas surface.
  --- An idle hint (the second value of K.status_line) gives way to the notes: it is not drawn while covered(x1, y1,
  --- x2, y2) says a note block lies under the pill. A message always shows.
  K.canvas_status = function(draw_list, x, bottom_y, max_w, editing, covered)
    local text, idle = K.status_line(editing)
    if text == "" then return end
    local L = Theme.layout
    local C = Theme.get_palette().canvas
    local room = max_w - L.sm * 2
    if room <= 0 then return end
    text = hdr_fit_text(text, room)
    local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, text)
    if (text_w or 0) > room then return end   -- not even the ellipsis fits
    local top_y = bottom_y - text_h - L.xs * 2
    if idle and covered and covered(x, top_y, x + text_w + L.sm * 2, bottom_y) then return end
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, top_y, x + text_w + L.sm * 2, bottom_y, C.pill_bg, L.rounding)
    reaper.ImGui_DrawList_AddText(draw_list, x + L.sm, top_y + L.xs, C.pill_text, text)
  end

  --- The units of this frame. `has_target` comes from loop_body (the top bar's view of the target); `s` from
  --- K.bar_measure. Returns draw_unit(id) for "pill" and the ids of BAR_VALUES.
  K.bar_frame = function(bctx, has_target, s)
    local P = Theme.get_palette()
    --- The first paragraph of the tooltip of the value `id`: its group's name (no caption shows it) and `title`
    local function group_tip(id, title)
      local name = BAR_GROUP_NAMES[K.BAR_GROUP[id]]
      return name and string.format(BAR_GROUP_TIP, name, title) or title
    end
    if has_target == nil then has_target = (state.target_take_guid ~= nil) end

    local has_data = (#state.results > 0 and state.notes ~= nil and #state.notes > 0)
    local take_data = state.target_take_guid and state.session_takes[state.target_take_guid] or nil

    -- Why the values are disabled (nil = usable)
    local inspector_reason = bar_inspector_reason(has_target, has_data)

    -- What the value controls act on: the selected notes that hold values (none = this item)
    local sel_notes, sel_n = bar_sel_notes()

    --- What the control of `spec` shows and what a drag on it writes to (worked out once per frame):
    ---   lo_v, hi_v  the value in display units; with several notes, their lowest and highest
    ---   mixed       the selected notes do not all show the same value
    ---   marked      the value differs from the level above: a selected note's from the item's, else this item's
    ---               from the script's default (the "*" mark)
    ---   target      "item" or "notes": what a drag changes
    ---   blank       there is no value to show; disabled / reason: the control cannot be used, and why
    local views = {}
    local function bar_view(spec)
      local view = views[spec.id]
      if view then return view end
      local key = spec.key
      view = { lo_v = spec.lo, hi_v = spec.lo, mixed = false, marked = false, target = "item" }
      views[spec.id] = view
      local item_v = (tonumber(get_effective(nil, key)) or 0) * spec.scale
      local function differs(a, b) return string.format(spec.num, a) ~= string.format(spec.num, b) end
      if sel_n > 0 then
        view.target = "notes"
        local lo_v, hi_v = math.huge, -math.huge
        for i = 1, sel_n do
          local note = sel_notes[i]
          local v = bar_note_value(note, spec)
          if v < lo_v then lo_v = v end
          if v > hi_v then hi_v = v end
          if note.controls[key] ~= nil and differs(v, item_v) then view.marked = true end
        end
        view.lo_v, view.hi_v = lo_v, hi_v
        view.mixed = differs(lo_v, hi_v)
      else
        view.lo_v, view.hi_v = item_v, item_v
        view.marked = get_override_level(nil, key) == "item"
          and differs(item_v, (tonumber((K.item_default(key, state.target_take_guid))) or 0) * spec.scale)
      end
      if inspector_reason then
        view.disabled, view.reason = true, inspector_reason
        view.blank = not (has_target and has_data)
      end
      return view
    end

    --- The control's text as a DragDouble format: a real number format when it shows one value (the drag and
    --- the typed entry format with it), literal text otherwise.
    local function value_format(spec, view)
      local unit = spec.unit:gsub("%%", "%%%%")
      if view.blank then return spec.label .. " " .. BAR_NO_VALUE end
      local mark = view.marked and (" " .. BAR_OVERRIDE_MARK) or ""
      if view.mixed then
        return spec.label .. " " .. string.format(spec.num, view.lo_v) .. BAR_RANGE_SEP
          .. string.format(spec.num, view.hi_v) .. unit .. mark
      end
      return spec.label .. " " .. spec.num .. unit .. mark
    end

    --- The last line of a value's tooltip: its default (with where it comes from) and this item's (stored units).
    local function levels_line(spec, item_raw)
      local function text(raw) return string.format(spec.num, (tonumber(raw) or 0) * spec.scale) .. spec.unit end
      local d, level = K.item_default(spec.key, state.target_take_guid)
      return string.format(BAR_LEVELS, text(d) .. (BAR_LEVEL_TAG[level] or ""), text(item_raw))
    end

    --- Tooltip for the item just drawn, gated on the hover delay. A disabled item passes
    --- HoveredFlags_AllowWhenDisabled as `extra_flags` so its reason still shows.
    local function bar_tooltip(text, extra_flags)
      local flags = reaper.ImGui_HoveredFlags_ForTooltip() | (extra_flags or 0)
      if reaper.ImGui_IsItemHovered(bctx, flags) and not reaper.ImGui_IsItemActive(bctx) then
        Theme.tooltip(bctx, text)
      end
    end

    --- Tolerance does nothing yet: no note it reaches has a Tighten above 0 (the selected notes, else every note
    --- of this item).
    local function tolerance_idle()
      if sel_n > 0 then
        for i = 1, sel_n do
          if (tonumber(get_effective(sel_notes[i], "tighten")) or 0) > 0 then return false end
        end
        return true
      end
      if (tonumber(get_effective(nil, "tighten")) or 0) > 0 then return false end
      for _, note in ipairs(state.notes or {}) do
        if note.controls and (tonumber(note.controls.tighten) or 0) > 0 then return false end
      end
      return true
    end

    --- One value of the bar: a drag with its text inside and the range fill under it. It edits what the pill
    --- names: the selected notes (each moves by the same amount from its own value, as a drag on the canvas
    --- does; a typed value sets them all), else this item (K.bar_write).
    local function draw_value(spec)
      local view = bar_view(spec)
      local key, id = spec.key, "bv_" .. spec.id
      local name = PARAM_LABELS[key] or spec.label

      -- The mode of what the pill names may not use this value: its text is dim and its tooltip says why
      local unused = K.mode_unused(key, sel_notes, sel_n)
      local dim = (unused == "mode" or unused == "hard")

      reaper.ImGui_BeginDisabled(bctx, view.disabled == true)
      reaper.ImGui_PushItemWidth(bctx, s.unit_w[spec.id])
      if dim then reaper.ImGui_PushStyleColor(bctx, reaper.ImGui_Col_Text(), P.text_dim) end
      local changed, v, committed, reset, cancelled = param_drag(bctx, id, nil, view.lo_v, spec.lo, spec.hi, value_format(spec, view))
      if dim then reaper.ImGui_PopStyleColor(bctx) end
      local back = K.drag_revert(id, view.lo_v / spec.scale, cancelled)
      local hovered, active, typed = K.drag_hot.hovered, K.drag_hot.active, K.drag_hot.typed
      local held, pressed = K.drag_hot.held, K.drag_hot.activated
      reaper.ImGui_PopItemWidth(bctx)
      reaper.ImGui_EndDisabled(bctx)

      -- A press belongs to what it was aimed at. When that changes under it (the notes were reloaded by an undo,
      -- the selection went away, another item became the target), the rest of the gesture does nothing: it must
      -- never turn a drag on notes into a change of the item.
      local gest = bar_gesture
      if pressed then
        gest.id, gest.target, gest.notes, gest.dead = spec.id, view.target, state.notes, false
        bar_press[spec.id] = K.item_value(take_data, key)
      end
      local dead = false
      if gest.id == spec.id then
        if view.disabled or gest.target ~= view.target or gest.notes ~= state.notes then gest.dead = true end
        dead = gest.dead
        if not held then gest.id = nil end   -- the press is over (this frame still counts as part of it)
      end
      if dead or view.disabled then
        local stale = state.bar_edit
        if stale and stale.id == spec.id then
          if stale.notes == state.notes then bar_edit_restore(stale, key) end
          state.bar_edit = nil
        end
      end

      if view.disabled then
        bar_tooltip(K.tip(group_tip(spec.id, spec.title), spec.tip, view.reason), reaper.ImGui_HoveredFlags_AllowWhenDisabled())
        return
      end

      -- The fill is in the value's own colour; where the value comes from is said by the mark and the tooltip
      local span = spec.hi - spec.lo
      K.value_fill(bctx, view.mixed and (view.lo_v - spec.lo) / span or 0, (view.hi_v - spec.lo) / span,
        K.param_color(key))   -- one colour per parameter, the same on the canvas

      -- Paragraphs: name, what it does, why it does nothing now (if so), what a drag changes and the levels, gestures
      local scope = BAR_SCOPE_ITEM
      if view.target == "notes" then
        scope = (sel_n == 1) and BAR_SCOPE_NOTE or string.format(BAR_SCOPE_NOTES, sel_n)
      end
      local idle = K.tip(unused and BAR_MODE.unused[unused],
        (key == "tolerance" and unused ~= "mode" and tolerance_idle()) and BAR_TOLERANCE_IDLE or nil)
      bar_tooltip(K.tip(group_tip(spec.id, spec.title), spec.tip, idle,
        scope .. "\n" .. levels_line(spec, get_effective(nil, key)), BAR_GESTURES))
      if dead then return end

      if hovered or active then
        -- The canvas shades where the value acts: on the selected notes, or wherever this item's value reaches
        local set = nil
        if view.target == "notes" then
          set = state.setting_hint.menu_set
          for k in pairs(set) do set[k] = nil end
          for idx in pairs(state.selected_notes) do set[idx] = true end
          if state.selected_note then set[state.selected_note] = true end
        end
        K.setting_hint(bctx, key, active, set)
      end

      if K.value_menu(bctx, key, spec.label, sel_n) then K.reset_target(key, sel_notes, sel_n) end

      if view.target ~= "notes" then
        if back ~= nil then
          K.bar_write(key, back, sel_notes, 0)   -- Esc during the drag: the value from before it, nothing written
        elseif reset then
          K.reset_target(key, sel_notes, 0)
        else
          local before = K.item_value(take_data, key)
          if changed then K.bar_write(key, v / spec.scale, sel_notes, 0) end
          if committed and take_data then
            -- A typed value is compared with the value it replaced, a drag with the value at its press
            local from = typed and before or bar_press[spec.id]
            bar_press[spec.id] = nil
            if K.value_changed(from, K.item_value(take_data, key)) then apply_envelope_to_take("Adjust " .. name) end
          end
        end
        return
      end

      -- The drag in progress: what each note held (raws; false = no own value) and showed (starts) when it began,
      -- and how far the pointer has moved since, in value units (acc). The pointer is followed here, not through
      -- the value the widget returns: a drag past the end of the range and back then lands where it started. It
      -- is dropped when it belongs to another control or to a note model that has been replaced since.
      local edit = state.bar_edit
      if edit and (edit.id ~= spec.id or edit.notes ~= state.notes) then
        if edit.id == spec.id then state.bar_edit = nil end
        edit = nil
      end
      if cancelled then
        -- Esc during the drag: every note gets back what it held, nothing is written
        if edit then
          bar_edit_restore(edit, key)
          state.bar_edit = nil
        end
      elseif reset then
        K.reset_target(key, sel_notes, sel_n)
      elseif changed and typed then
        -- A typed value sets every selected note to it; nothing is written when every note shows it already
        state.bar_edit = nil
        local target, moved = math.max(spec.lo, math.min(spec.hi, v)), false
        for i = 1, sel_n do
          if K.value_changed(bar_note_value(sel_notes[i], spec), target) then moved = true break end
        end
        if moved then
          for i = 1, sel_n do bar_note_write(sel_notes[i], spec, v) end
          apply_envelope_to_take("Adjust " .. name)
        end
      elseif held and reaper.ImGui_IsMouseDragging(bctx, 0) then
        if not edit then
          edit = { id = spec.id, notes = state.notes, acc = 0, raws = {}, starts = {} }
          for i = 1, sel_n do
            local note = sel_notes[i]
            local raw = note.controls[key]
            edit.raws[note] = (raw == nil) and false or raw
            edit.starts[note] = bar_note_value(note, spec)
          end
          state.bar_edit = edit
        end
        local dx = reaper.ImGui_GetMouseDelta(bctx) or 0
        if dx ~= 0 then
          -- HC2: Cmd/Ctrl held (read every frame) = fine adjust; the control's width sweeps the whole range.
          -- acc is not clamped (each note is): however far the pointer goes, coming back undoes it.
          local fine = ((reaper.ImGui_GetKeyMods(bctx) or 0) & reaper.ImGui_Mod_Ctrl()) ~= 0
          edit.acc = edit.acc + dx * span / math.max(s.unit_w[spec.id], 1) * (fine and K.FINE_ADJUST_SCALE or 1)
          for note, start in pairs(edit.starts) do bar_note_write(note, spec, start + edit.acc) end
        end
      elseif edit and not held then
        -- Released: one write and one undo point, and only when a note now shows another value than it did
        -- (a drag against the end of the range, or back to where it began, leaves every note what it held)
        state.bar_edit = nil
        local moved = false
        for note, start in pairs(edit.starts) do
          if math.abs(bar_note_value(note, spec) - start) > 1e-9 then moved = true break end
        end
        if moved then
          apply_envelope_to_take("Adjust " .. name)
        else
          bar_edit_restore(edit, key)
        end
      end
    end

    --- The pill's menu: where edits go, Apply to other items…, the System / Track Default entries
    --- (K.default_menu_items) and Reset this item to defaults. A disabled entry says
    --- why beside it (EP2: readable with tooltips off).
    local function draw_pill_menu(open_x, open_y)
      -- Under the pill: set right before BeginPopup (a tooltip in between would take the position)
      if open_x then reaper.ImGui_SetNextWindowPos(bctx, open_x, open_y) end
      if not reaper.ImGui_BeginPopup(bctx, "##bar_pill_menu") then return end
      -- HC5: Esc closes this menu (innermost)
      if reaper.ImGui_Shortcut(bctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(bctx) end
      local to = (sel_n == 0) and BAR_PILL_MENU.to_item or (sel_n == 1) and BAR_PILL_MENU.to_note
        or string.format(BAR_PILL_MENU.to_notes, sel_n)
      reaper.ImGui_TextColored(bctx, P.text_dim, to)
      reaper.ImGui_Separator(bctx)

      K.apply_menu_item(bctx, BAR_PILL_MENU.apply, nil)
      reaper.ImGui_Separator(bctx)
      K.default_menu_items(bctx, nil)
      reaper.ImGui_Separator(bctx)
      local reset_reason = inspector_reason or (not take_data and BAR_REASON_NOT_ANALYZED)
        or ((K.item_off_defaults(take_data) == 0) and BAR_PILL_MENU.reset_none) or nil
      if reaper.ImGui_MenuItem(bctx, BAR_PILL_MENU.reset, reset_reason, false, reset_reason == nil)
          and reset_reason == nil then
        K.reset_item_all()
      end
      reaper.ImGui_EndPopup(bctx)
    end

    --- The selection pill: what a drag on a value changes. A click or a right-click opens its menu (draw_pill_menu),
    --- under it.
    local function draw_pill()
      local text = (sel_n == 0) and BAR_PILL_NONE or (sel_n == 1) and BAR_PILL_ONE or string.format(BAR_PILL_MANY, sel_n)
      local fg, bg = P.text, P.well
      if sel_n > 0 then fg, bg = Theme.label_on(P.accent2), P.accent2 end
      Theme.align(bctx)
      local open_x, open_y
      local clicked = Theme.badge(bctx, text, { color = fg, bg = bg, text_color = fg, id = "bar_pill", w = s.unit_w.pill,
        interactive = true })
      if clicked or reaper.ImGui_IsItemClicked(bctx, reaper.ImGui_MouseButton_Right()) then
        open_x = reaper.ImGui_GetItemRectMin(bctx)
        open_y = select(2, reaper.ImGui_GetItemRectMax(bctx))
        reaper.ImGui_OpenPopup(bctx, "##bar_pill_menu")
      end
      bar_tooltip((sel_n == 0) and BAR_PILL_TIP_NONE or BAR_PILL_TIP_NOTES)
      draw_pill_menu(open_x, open_y)
    end

    --- Separation: this item's value (state.separation mirrors data.separation), shown whatever is selected (it has
    --- no note level of its own). A drag only moves the value; letting go (or a typed value, or the reset to the
    --- default, DEFAULTS) stores it as the item's (K.bar_write) and splits the item's notes again, given the value from
    --- before (K.resplit: it may ask first, and Cancel puts the value back). With notes selected, letting go (or a
    --- typed value) splits again only their stretch at that value (K.resplit_stretch) and the bar goes back to the
    --- item's value, which is not changed; the reset splits the stretch again at the item's value. Usable whenever
    --- there is a target, no analysis runs and no confirmation is open: on an item not analysed yet, its first
    --- analysis uses it. With notes selected it needs the analysed frames in memory.
    local function draw_separation(spec)
      local key, id = spec.key, "bv_" .. spec.id
      local reason = (state.is_analyzing and BAR_REASON_ANALYZING) or ((not has_target) and BAR_REASON_NO_TARGET)
        or ((sel_n > 0 and not (state.results and #state.results >= 2)) and K.STRETCH_NO_ANALYSIS) or nil
      local disabled = reason ~= nil or state.confirm ~= nil
      if disabled and bar_sep_before ~= nil then
        state[key] = bar_sep_before   -- a drag cut short: nothing was stored or split, so the value goes back
        bar_sep_before = nil
      end

      local default = K.item_default(key, state.target_take_guid)
      local marked = has_target
        and string.format(spec.num, state[key] * spec.scale) ~= string.format(spec.num, default * spec.scale)
      reaper.ImGui_BeginDisabled(bctx, disabled)
      reaper.ImGui_PushItemWidth(bctx, s.unit_w[spec.id])
      local fmt = spec.label .. " " .. spec.num .. (spec.unit:gsub("%%", "%%%%")) .. (marked and (" " .. BAR_OVERRIDE_MARK) or "")
      local changed, v, committed, reset, cancelled = param_drag(bctx, id, nil, state[key] * spec.scale, spec.lo, spec.hi, fmt)
      local back = K.drag_revert(id, state[key], cancelled)
      local pressed, active, typed = K.drag_hot.activated, K.drag_hot.active, K.drag_hot.typed
      reaper.ImGui_PopItemWidth(bctx)
      reaper.ImGui_EndDisabled(bctx)

      if disabled then
        bar_tooltip(K.tip(group_tip(spec.id, spec.title), spec.tip, reason), reaper.ImGui_HoveredFlags_AllowWhenDisabled())
        return
      end
      local span = spec.hi - spec.lo
      K.value_fill(bctx, 0, (state[key] * spec.scale - spec.lo) / span, P.accent)
      local what = (sel_n > 0 and BAR_SEP_NOTES) or (has_data and BAR_SEP_RESPLIT) or BAR_SEP_NEXT
      bar_tooltip(K.tip(group_tip(spec.id, spec.title), spec.tip, what .. "\n" .. levels_line(spec, state[key]), BAR_GESTURES))
      local menu_reset = K.value_menu(bctx, key, spec.label, sel_n)

      --- The edit is done: store the item's value and split again, once, only when it changed. With notes
      --- selected: the bar goes back to the item's value (prev) and only their stretch is split again
      local function commit(prev)
        bar_sep_before = nil
        if prev == nil or state[key] == prev then return end
        if sel_n > 0 then
          local stretch_sep = state[key]
          state[key] = prev
          K.resplit_stretch(stretch_sep)
          return
        end
        K.bar_write(key, state[key], sel_notes, 0)
        K.resplit(prev)
      end

      if pressed then bar_sep_before = state[key] end
      if back ~= nil then
        -- Esc during the drag: the value from before it (or from the reset the same press already committed),
        -- nothing stored or split
        if bar_sep_before ~= nil then state[key] = bar_sep_before else state[key] = back end
        bar_sep_before = nil
      elseif (reset or menu_reset) and sel_n > 0 then
        -- The level above the notes is the item: their stretch is split again at the item's value
        if bar_sep_before ~= nil then state[key] = bar_sep_before end
        bar_sep_before = nil
        K.resplit_stretch(state[key])
        if active then bar_sep_before = state[key] end
      elseif reset or menu_reset or (changed and typed) then
        local prev = state[key]
        state[key] = (reset or menu_reset) and default or v / spec.scale
        commit(prev)
        -- Still held (a double-click whose second press goes on into a drag): that drag starts from the value just
        -- committed, and letting go commits it as its own edit
        if active then bar_sep_before = state[key] end
      else
        if changed then state[key] = v / spec.scale end
        if committed then commit(bar_sep_before) end
      end
      if not active then bar_sep_before = nil end   -- the press is over (a click that changed nothing)
    end

    --- Mode: the selected notes' mode (Mixed when they differ), else this item's. A choice is stored on every
    --- selected note, else as this item's mode (Natural too: it is a value of its own), as one undo point; the same
    --- choice does nothing.
    local function draw_mode()
      local idx
      if sel_n == 0 then
        idx = K.mode_value(nil) + 1
      else
        idx = K.mode_value(sel_notes[1]) + 1
        for i = 2, sel_n do
          if K.mode_value(sel_notes[i]) + 1 ~= idx then idx = 0 break end
        end
      end
      local scope = (sel_n == 0) and BAR_MODE.scope_item or (sel_n == 1) and BAR_MODE.scope_note
        or string.format(BAR_MODE.scope_notes, sel_n)
      local function mode_name(raw) return K.MODES[(tonumber(raw) or 0) + 1] or K.MODES[1] end
      local mode_d, mode_level = K.item_default("correct_mode", state.target_take_guid)
      local levels = string.format(BAR_LEVELS, mode_name(mode_d) .. (BAR_LEVEL_TAG[mode_level] or ""),
        mode_name(get_effective(nil, "correct_mode")))
      local choice, changed = Theme.combo(bctx, "##bar_mode", K.MODES, idx, {
        w = s.unit_w.mode, placeholder = BAR_MODE.mixed, disabled = inspector_reason ~= nil,
        tooltip = K.tip(group_tip("mode", BAR_MODE.title), BAR_MODE.tip, inspector_reason or (scope .. "\n" .. levels)),
      })
      if inspector_reason then return end
      if K.value_menu(bctx, "correct_mode", "Mode", sel_n) then
        if K.reset_target("correct_mode", sel_notes, sel_n) and sel_n == 0 then
          set_status(K.mode_item_status(K.mode_value(nil), K.mode_own_count(state.notes)))
        end
      end
      if not changed or choice == idx or not take_data then return end
      K.bar_write("correct_mode", choice - 1, sel_notes, sel_n)
      if apply_envelope_to_take("Set Mode") and sel_n == 0 then
        set_status(K.mode_item_status(choice - 1, K.mode_own_count(state.notes)))
      end
    end

    return function(id)
      if id == "pill" then
        draw_pill()
      elseif id == "mode" then
        draw_mode()
      elseif BAR_VALUE_BY_ID[id] then
        local spec = BAR_VALUE_BY_ID[id]
        if spec.id == "sep" then draw_separation(spec) else draw_value(spec) end
      end
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
  local form_guid = state.target_take_guid
  if form_guid and (not state.analysis_form or state.analysis_form.guid ~= form_guid) then   -- HI5: only on a target change
    K.form_sync(form_guid, state.session_takes[form_guid])
  end
  K.analysis_tick()
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
  hdr_static = hdr_static or measure_header_static()
  Theme.center_next_window(ctx, math.max(920, math.ceil(hdr_min_content_w(hdr_static, true) + pad_x * 2)), 620,
    reaper.ImGui_Cond_FirstUseEver())
  -- A floating window never gets narrower, nor shorter, than the narrowest top bar needs (its last plan: every
  -- group on a row of its own); a docked one takes its dock's size, and the bar is clipped (see TOP BAR)
  if hdr_was_docked == false then
    local min_content_w, min_rows = hdr_min_content_w(hdr_static)
    reaper.ImGui_SetNextWindowSizeConstraints(ctx,
      min_content_w + pad_x * 2,
      hdr_static.frame_h + pad_v * (min_rows + 1) + hdr_static.row_h * min_rows,
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
    -- selected audio item CHANGES (or the current target no longer exists). A sidebar click selects its
    -- row's items in REAPER and records that selection as seen, so it is not taken for a change here.
    -- A batch owns the target while it runs.
    if not state.is_analyzing and not K.batch then
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
          K.status_release()   -- a held closing message belongs to the item being left
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

    K.status_watch(ctx)   -- a held closing message (a batch's) goes on the user's next input

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
    local body_x, body_y = reaper.ImGui_GetCursorScreenPos(ctx)

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

    -- Asked here, in the window's own ID scope, for the canvas form (drawn inside the body table, see K.child_dim)
    K.window_modal_now = K.window_modal_open()
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
    -- A light hairline along the top of the body, across the note column, the ruler and the side panel: the
    -- faint edge REAPER draws above its own ruler (C.ruler_edge)
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      body_x, body_y, body_x + avail_w, body_y, P.canvas.ruler_edge)
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
    -- Pitched Items row selection (back to just the active row), then the window, which closes on Esc only
    -- when it is floating.
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
      elseif K.row_sel_extra() then
        K.row_sel_reset()
        K.mirror_row_sel_to_arrange()
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

--- After a frame failed: close an undo block it left open, cancel the running analysis (a batch writes its finished
--- items here, in an undo block of its own), and keep no track record an analysis or batch found (K.auto_drop):
--- after any failed analysis or batch nothing is pending.
K.recover_after_error = function()
  if state.undo_open then   -- the frame failed inside an undo block (a note edit, a batch's write): close it
    state.undo_open = false
    pcall(reaper.Undo_EndBlock, "Apply Pitch Correction (interrupted)", -1)
  end
  K.drop_project_cache()    -- what the failed frame asked REAPER is not trusted any more
  pcall(K.cancel_analysis)
  pcall(K.tone_kill)
  if state.undo_open then   -- that write failed as well
    state.undo_open = false
    pcall(reaper.Undo_EndBlock, "Analyze Pitch (interrupted)", -1)
  end
  K.auto_drop()
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
      K.recover_after_error()
      state.clipper = nil       -- nor is a list clipper it may have left begun (a new one is made when needed)
      K.confirm_clipper = nil
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
    if K.batch then
      -- Ended mid-batch: the finished items are kept. What the last frame asked REAPER is not trusted here (the
      -- project may be closing), and a write that fails must not leave its undo block open
      K.drop_project_cache()
      pcall(K.batch_finish, true)
      if state.undo_open then
        state.undo_open = false
        pcall(reaper.Undo_EndBlock, "Analyze Pitch (interrupted)", -1)
      end
    end
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

if FANCY_PITCH_TEST then   -- luacheck: ignore 113 (set by docs/superpowers/tests/pitch_correct_spec.lua)
  return { K = K, state = state, DEFAULTS = DEFAULTS, VOCAL_RANGES = VOCAL_RANGES, extract_note_features = extract_note_features,
           SCALE_DEFINITIONS = SCALE_DEFINITIONS, rdp_simplify = rdp_simplify,
           run_hybrid_segmentation = run_hybrid_segmentation, yin_process_block = yin_process_block,
           request_confirm = request_confirm, draw_confirm_modal = draw_confirm_modal, sync_with_project = sync_with_project,
           get_effective = get_effective, get_override_level = get_override_level,
           measure_header_static = measure_header_static, hdr_min_content_w = hdr_min_content_w,
           clear_take_analysis = clear_take_analysis, wipe_entire_session = wipe_entire_session,
           start_analysis = start_analysis }
end
main()
