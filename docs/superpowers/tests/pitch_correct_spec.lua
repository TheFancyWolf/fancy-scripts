-- Run from the repo root: lua docs/superpowers/tests/pitch_correct_spec.lua
local SCRIPT = "Pitch/Fancy_Pitch Correct.lua"

-- ext (optional): what REAPER's ExtState holds for the load, { [key] = string }; asked keys are recorded in ext_asked
local ext_asked = {}
local function load_script(ext)
  reaper = setmetatable({
    ImGui_CreateContext = function() end,
    GetExtState = function(_, key)   -- top-level code tonumber()s this
      ext_asked[key] = true
      return ext and ext[key] or ""
    end,
  },
    { __index = function() return function() end end })
  FANCY_PITCH_TEST = true   -- luacheck: ignore 111 (the script returns its internals instead of running)
  return dofile(SCRIPT)
end

local tests, count = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(a, b, msg)
  if a ~= b then
    error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

local function near(a, b, tol, msg)
  if type(a) ~= "number" or math.abs(a - b) > tol then
    error((msg or "near") .. ": expected " .. tostring(b) .. " +/- " .. tostring(tol)
      .. ", got " .. tostring(a), 2)
  end
end

-- segs: list of { dur = s, note = st | nil | fn(t), lvl = linear | fn(t) }
-- returns an array of frames { time, note, rms, lvl }, time starting at 0
local function frames(segs, hop_s)
  local out, t0 = {}, 0
  for _, seg in ipairs(segs) do
    local n = math.floor(seg.dur / hop_s + 0.5)
    for i = 0, n - 1 do
      local lt = i * hop_s
      local note, lvl = seg.note, seg.lvl
      if type(note) == "function" then note = note(lt) end
      if lvl == nil then lvl = 0.1 elseif type(lvl) == "function" then lvl = lvl(lt) end
      out[#out + 1] = { time = t0 + lt, note = note, rms = lvl, lvl = lvl }
    end
    t0 = t0 + n * hop_s
  end
  return out
end

local S = load_script()   -- once: it re-runs the whole script

test("loads", function()
  eq(type(S), "table")
  eq(type(S.K.correction_build), "function")
end)

test("short_level_constant", function()
  local s = {}
  for i = 1, 2048 do s[i] = 0.5 end
  near(S.K.short_level(s, 2048, 44100), 0.5, 1e-9)
end)

test("short_level_centre_burst", function()
  local s = {}
  for i = 1, 2048 do s[i] = (i >= 804 and i <= 1244) and 1.0 or 0 end
  near(S.K.short_level(s, 2048, 44100), 1.0, 1e-9)
end)

test("short_level_short_block", function()
  local s = {}
  for i = 1, 100 do s[i] = 0.25 end
  near(S.K.short_level(s, 100, 44100), 0.25, 1e-9)
end)

-- Note splitting (K.segment) -------------------------------------------------------------------

local HOP = 256 / 44100
local DIP_9DB = 0.1 * 10 ^ (-9 / 20)

local function slide_segs(to)
  return {
    { dur = 0.4, note = 60 },
    { dur = 0.04, note = function(t) return 60 + (to - 60) * t / 0.04 end },
    { dur = 0.4, note = to },
  }
end
local REARTIC_SEGS = { { dur = 0.4, note = 60 }, { dur = 0.03, note = 60, lvl = DIP_9DB }, { dur = 0.4, note = 60 } }
local VIBRATO_SEGS = { { dur = 1, note = function(t) return 60 + 0.5 * math.sin(2 * math.pi * 5.5 * t) end } }

local function segment(segs, hop_s, sep)
  return S.K.segment(frames(segs, hop_s or HOP), sep or 0.5)
end

test("separation_params_columns", function()
  local cols = {
    [0] = { 1.5, 0.140, 12, 0.100 },
    [0.5] = { 0.8, 0.090, 6, 0.070 },
    [1] = { 0.4, 0.050, 3, 0.040 },
  }
  for sep, want in pairs(cols) do
    local p = S.K.separation_params(sep)
    near(p.pitch_st, want[1], 1e-12, "pitch_st " .. sep)
    near(p.hold_s, want[2], 1e-12, "hold_s " .. sep)
    near(p.dip_db, want[3], 1e-12, "dip_db " .. sep)
    near(p.min_note_s, want[4], 1e-12, "min_note_s " .. sep)
  end
end)

test("segment_slide", function()
  local notes, splits = segment(slide_segs(62))
  eq(#notes, 2, "notes")
  near(notes[2].start_time, 0.42, 0.02, "boundary")
  eq(splits[2].reason, "Pitch change")
  near(splits[2].time, notes[2].start_time, 1e-12, "split time")
end)

test("segment_rearticulation", function()
  local notes, splits = segment(REARTIC_SEGS)
  eq(#notes, 2, "notes")
  near(notes[2].start_time, 0.415, 0.02, "boundary")
  eq(splits[2].reason, "Level dip")
end)

test("segment_vibrato", function()
  eq(#segment(VIBRATO_SEGS), 1, "notes")
end)

test("segment_dropout", function()
  eq(#segment({ { dur = 0.4, note = 60 }, { dur = 0.015 }, { dur = 0.4, note = 60 } }), 1, "notes")
end)

test("segment_octave_frame", function()
  local fr = frames({ { dur = 0.8, note = 60 } }, HOP)
  fr[70].note = 72
  eq(#S.K.segment(fr, 0.5), 1, "notes")
end)

test("segment_short_octave_error", function()
  local fr = frames({ { dur = 0.8, note = 60 } }, HOP)
  for i = 70, 72 do fr[i].note = 72 end
  eq(#S.K.segment(fr, 0.5), 1, "notes")
end)

test("segment_gap", function()
  local notes, splits = segment({ { dur = 0.3, note = 60 }, { dur = 0.1 }, { dur = 0.3, note = 60 } })
  eq(#notes, 2, "notes")
  eq(#splits, 2, "splits")
  eq(splits[1].reason, "Onset")
  eq(splits[2].reason, "Onset")
end)

test("segment_separation_range", function()
  eq(#segment(slide_segs(60.6), HOP, 0), 1, "sep 0")
  eq(#segment(slide_segs(60.6), HOP, 1), 2, "sep 1")
end)

test("segment_hop_extremes", function()
  for _, hop in ipairs({ 64 / 44100, 1024 / 44100 }) do
    eq(#segment(slide_segs(62), hop), 2, "slide at hop " .. hop)
    eq(#segment(VIBRATO_SEGS, hop), 1, "vibrato at hop " .. hop)
  end
end)

test("segment_degenerate", function()
  eq(#S.K.segment({}, 0.5), 0, "empty")
  eq(#segment({ { dur = 1 } }), 0, "all unvoiced")
  eq(#S.K.segment(frames({ { dur = 2 * HOP, note = 60 } }, HOP), 0.5), 0, "two frames")
  local notes = segment({ { dur = 1, note = 60 } })
  eq(#notes, 1, "one note")
  near(notes[1].start_time, 0, HOP, "start")
  near(notes[1].end_time, 1, 1.5 * HOP, "end")
end)

test("segment_missing_lvl", function()
  local fr = frames(REARTIC_SEGS, HOP)
  for _, f in ipairs(fr) do f.lvl = nil end
  eq(#S.K.segment(fr, 0.5), 2, "notes")
end)

test("segment_frames_intact", function()
  local fr = frames(slide_segs(62), HOP)
  local before = {}
  for i, f in ipairs(fr) do before[i] = f.note end
  local notes = S.K.segment(fr, 0.5)
  local owner, last_time = {}, -1
  for ni, n in ipairs(notes) do
    for _, f in ipairs(n.frames) do
      eq(owner[f], nil, "frame in two notes")
      owner[f] = ni
      if f.time <= last_time then error("frames out of time order") end
      last_time = f.time
    end
  end
  for i, f in ipairs(fr) do
    if f.note then eq(owner[f] ~= nil, true, "voiced frame " .. i .. " in no note") end
    eq(f.note, before[i], "frame " .. i .. " note mutated")
  end
end)

local function vibrato(centre, amp, rate, phase)
  return function(t) return centre + amp * math.sin(2 * math.pi * rate * t + (phase or 0)) end
end

test("segment_vibrato_all_separations", function()
  for _, hop in ipairs({ 64 / 44100, 256 / 44100, 1024 / 44100 }) do
    for _, sep in ipairs({ 0, 0.5, 0.75, 1 }) do
      eq(#segment({ { dur = 1.5, note = vibrato(60, 0.5, 5.5) } }, hop, sep), 1,
        "hop " .. math.floor(hop * 44100 + 0.5) .. " sep " .. sep)
    end
  end
end)

test("segment_wide_vibrato_default", function()
  for _, f in ipairs({ 5, 6.5 }) do
    eq(#segment({ { dur = 1.5, note = vibrato(60, 1.0, f) } }, HOP, 0.5), 1, "rate " .. f)
  end
end)

test("segment_vibrato_phase", function()
  eq(#segment({ { dur = 1.5, note = vibrato(60, 0.5, 5.5, math.pi / 2) } }, HOP, 1), 1, "notes")
end)

test("segment_vibrato_then_step", function()
  for _, sep in ipairs({ 0.5, 1 }) do
    local notes = segment({ { dur = 0.6, note = vibrato(60, 0.5, 5.5) }, { dur = 0.6, note = vibrato(62, 0.5, 5.5) } },
      HOP, sep)
    eq(#notes, 2, "notes at sep " .. sep)
    near(notes[2].start_time, 0.6, 0.05, "boundary at sep " .. sep)
  end
end)

-- Real sample blocks: a band-limited pulse train at f0 (harmonics up to 5 kHz, all equal: very peaky), amplitude
-- amp(t), cut into 2048-sample blocks at `hop` samples. Each frame's level is K.short_level over the window
-- K.level_window_s gives for f0, as yin_process_block does; `note` is the MIDI pitch of f0.
local SR, BLOCK = 44100, 2048
local function pulse_frames(f0, dur, hop, amp)
  local h = math.floor(5000 / f0)
  local total = math.floor(dur * SR) + BLOCK
  local s = {}
  for i = 1, total do
    local t, v = (i - 1) / SR, 0
    for k = 1, h do v = v + math.cos(2 * math.pi * k * f0 * t) end
    s[i] = (amp and amp(t) or 1) * v / h
  end
  local note, win, out = 69 + 12 * math.log(f0 / 440, 2), S.K.level_window_s(f0), {}
  for st = 0, math.floor(dur * SR) - 1, hop do
    local blk = {}
    for i = 1, BLOCK do blk[i] = s[st + i] end
    local lvl = S.K.short_level(blk, BLOCK, SR, win)
    out[#out + 1] = { time = st / SR, note = note, rms = lvl, lvl = lvl }
  end
  return out
end

test("short_level_window", function()
  near(S.K.level_window_s(nil), S.K.LEVEL_WINDOW_S, 1e-12, "unvoiced")
  near(S.K.level_window_s(440), S.K.LEVEL_WINDOW_S, 1e-12, "high pitch")
  near(S.K.level_window_s(82), 2 / 82, 1e-12, "low pitch")
  local s = {}
  for i = 1, 2048 do s[i] = 0.5 end
  near(S.K.short_level(s, 2048, 44100, 1), 0.5, 1e-9, "capped at the block")
end)

test("segment_low_steady_note", function()
  for _, f0 in ipairs({ 82, 70 }) do
    for _, hop in ipairs({ 256, 512 }) do
      local fr = pulse_frames(f0, 1.5, hop)
      local lo, hi = math.huge, -math.huge
      for _, f in ipairs(fr) do
        local d = 20 * math.log(f.lvl, 10)
        lo, hi = math.min(lo, d), math.max(hi, d)
      end
      local tag = f0 .. " Hz hop " .. hop
      if hi - lo >= 3 then error("level swing " .. (hi - lo) .. " dB at " .. tag) end
      for _, sep in ipairs({ 0.5, 1 }) do eq(#S.K.segment(fr, sep), 1, tag .. " sep " .. sep) end
    end
  end
end)

test("segment_low_dip_still_found", function()
  local quiet = 10 ^ (-9 / 20)
  local fr = pulse_frames(110, 0.83, 256, function(t) return (t >= 0.4 and t < 0.43) and quiet or 1 end)
  eq(#S.K.segment(fr, 0.5), 2, "notes")
end)

test("segment_short_note", function()
  eq(#segment({ { dur = 0.12, note = 60 }, { dur = 0.4, note = 62 } }, HOP, 0.5), 2, "notes")
end)

test("segment_pitch_only_floor", function()
  local function run(mid) return { { dur = 0.4, note = 60 }, { dur = mid, note = 62 }, { dur = 0.4, note = 60 } } end
  eq(#segment(run(0.15), HOP, 0.5), 3, "0.15 s middle note at sep 0.5")
  -- This pins a known limit, not a goal: a note set apart only by pitch needs about 100 ms (the cycle-median centre
  -- needs that long to settle), so a 60 ms one is not found even at Separation 100 %
  if #segment(run(0.06), HOP, 1) >= 3 then error("a 60 ms pitch-only note was found: update the spec and changelog") end
end)

-- Noisy frames (a fixed generator, so the same on every run): pitch noise, steps of 0.7 st, 1 % dropouts and a level
-- that jumps up to 12 dB from frame to frame
local function noisy_frames(dur, hop)
  local seed, out = 777, {}
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
  for i = 0, math.floor(dur / hop) - 1 do
    local note = 60 + (rnd() - 0.5) * 1.5 + ((i // 200) % 3) * 0.7
    if rnd() < 0.01 then note = nil end
    local lvl = 0.1 * 10 ^ (-(rnd() * 12) / 20)
    out[#out + 1] = { time = i * hop, note = note, rms = lvl, lvl = lvl }
  end
  return out
end

test("segment_noisy_matches_recorded", function()
  -- Literals recorded from K.segment before the short-segment merge and the note centre used heaps
  local want = { [0] = { 1, 1703, 9.9903854875283447 }, [0.5] = { 73, 63775, 35506.265396825402 },
                 [1] = { 155, 132815, 160996.89650793653 } }
  local fr = noisy_frames(10, HOP)
  for sep, w in pairs(want) do
    local notes = S.K.segment(fr, sep)
    local c, t = 0, 0
    for i, n in ipairs(notes) do c, t = c + i * n.count, t + i * (n.start_time + n.end_time) end
    eq(#notes, w[1], "notes at sep " .. sep)
    eq(c, w[2], "frames at sep " .. sep)
    near(t, w[3], 1e-9, "times at sep " .. sep)
  end
end)

test("segment_frame_step", function()
  local fr = frames({ { dur = 0.1, note = 60 } }, HOP)
  fr[3].time = fr[3].time + 0.5 * HOP   -- one uneven frame does not move the median step
  near(S.K.frame_step(fr), HOP, 1e-12, "step")
end)

local function body_note(n, low_first, tighten)
  local fr, sm = {}, {}
  for i = 1, n do
    fr[i] = { time = (i - 1) * 0.01 }
    sm[i] = 60 + ((i <= low_first) and -2 or 0)
  end
  return { frames = fr, smooth = sm, avg_note = 60, controls = { tighten = tighten } }
end

test("note_body_flat", function()
  local a, b = S.K.note_body(body_note(20, 0, 0.5))
  eq(a, 1, "a"); eq(b, 20, "b")
end)

test("note_body_skips_low_start", function()
  local a, b = S.K.note_body(body_note(20, 5, 0.5))
  eq(a, 6, "a"); eq(b, 20, "b")
end)

test("note_body_too_short", function()
  eq(S.K.note_body(body_note(2, 0, 0.5)), nil, "2 frames")
end)

test("note_body_without_tighten", function()
  local a, b = S.K.note_body(body_note(20, 0, nil))
  eq(a, 1, "a"); eq(b, 20, "b")
end)

test("tighten_unchanged", function()
  local n = body_note(100, 5, 0.5)
  for i = 6, 100 do n.smooth[i] = 60 + 0.3 * math.sin(i * 0.7) + 0.002 * i end
  n.controls.tolerance = 1
  local out = S.K.tighten_line(n)
  -- literals recorded from K.tighten_line before the note_body refactor
  near(out[1], 0, 1e-9, "first"); near(out[50], 0.090541679572182426, 1e-9, "middle")
  near(out[100], 0.16270590047208416, 1e-9, "last")
end)

local function slide_note(onset_low, slide_in)
  local fr, sm = {}, {}
  for i = 1, 30 do
    local v = 60
    if i <= 6 then v = 60 - onset_low * (7 - i) / 6 end
    fr[i] = { time = (i - 1) * 0.01, note = v }
    sm[i] = (i <= 6) and (v - 1) or v   -- the slide lies outside the 0.5 st body, whatever its size
  end
  return { start_time = 0, end_time = 0.3, frames = fr, smooth = sm, avg_note = 60,
           controls = { center_pitch = 60.3, retune_speed = 1, slide_in = slide_in, bypassed = false } }
end

local function slide_shifts(onset_low, slide_in)
  local n = slide_note(onset_low, slide_in)
  S.K.correction_build({ n }, 1)
  return n.frame_shifts, n
end

test("slide_in_zero", function()
  local sh = slide_shifts(1, 0)
  for i = 1, 6 do near(sh[i], 0.3, 1e-9, "coarse " .. i) end
end)

test("slide_in_full", function()
  local sh, n = slide_shifts(1, 1)
  local target = n.frames[7].note + sh[7]
  for i = 1, 6 do near(n.frames[i].note + sh[i], target, 1e-9, "frame " .. i) end
end)

test("slide_in_half", function()
  local s0, s1, sh = slide_shifts(1, 0), slide_shifts(1, 1), slide_shifts(1, 0.5)
  for i = 1, 6 do near(sh[i], (s0[i] + s1[i]) / 2, 1e-9, "frame " .. i) end
end)

test("slide_in_no_slide", function()
  local s0, s1 = slide_shifts(0, 0), slide_shifts(0, 1)
  for i = 1, 30 do near(s0[i], s1[i], 1e-9, "frame " .. i) end
end)

test("slide_in_cap", function()
  local s0, s1 = slide_shifts(12, 0), slide_shifts(12, 1)
  local most = 0
  for i = 1, 6 do
    if math.abs(s1[i] - s0[i]) > S.K.SCOOP_MAX_ST + 1e-9 then error("moved too far at " .. i) end
    most = math.max(most, math.abs(s1[i] - s0[i]))
  end
  near(most, S.K.SCOOP_MAX_ST, 1e-9, "the far slide frames are pulled by the cap")
end)

-- Automatic joins (K.correction_build part 2) ----------------------------------------------------

local JHOP = 0.005

-- A note from t0 lasting dur, centred on `centre`, shifted by `shift` (Strength 100 %). slide = { from, dur }: it
-- starts with a linear slide from `from`, whose smoothed pitch lies outside the 0.5 st body.
local function join_note(t0, dur, centre, shift, slide)
  local fr, sm = {}, {}
  local nf = math.floor(dur / JHOP + 0.5)
  for i = 1, nf do
    local lt = (i - 1) * JHOP
    local v, s = centre, centre
    if slide and lt < slide.dur then
      v = slide.from + (centre - slide.from) * lt / slide.dur
      s = centre - 1
    end
    fr[i] = { time = t0 + lt, note = v }
    sm[i] = s
  end
  return { start_time = t0, end_time = t0 + nf * JHOP, frames = fr, smooth = sm, avg_note = centre,
           controls = { center_pitch = centre + shift, retune_speed = 1, bypassed = false } }
end

local function max_step(points)
  local p = {}
  for i, q in ipairs(points) do p[i] = q end
  table.sort(p, function(a, b) return a.time < b.time end)
  local m = 0
  for i = 2, #p do m = math.max(m, math.abs(p[i].val - p[i - 1].val)) end
  return m
end

local function value_at(points, t)
  local p = {}
  for i, q in ipairs(points) do p[i] = q end
  table.sort(p, function(a, b) return a.time < b.time end)
  if #p == 0 or t <= p[1].time then return p[1] and p[1].val or 0 end
  for i = 2, #p do
    if p[i].time >= t then
      local dt = p[i].time - p[i - 1].time
      return dt > 0 and p[i - 1].val + (p[i].val - p[i - 1].val) * (t - p[i - 1].time) / dt or p[i].val
    end
  end
  return p[#p].val
end

local function spans_of(build, kind)
  local out = {}
  for _, sp in ipairs(build.spans) do if sp.kind == kind then out[#out + 1] = sp end end
  return out
end

local function point_at(points, t)
  for _, p in ipairs(points) do if math.abs(p.time - t) < 1e-9 then return p end end
end

local function slid_pair(slide_dur, b_dur)
  local a = join_note(0.1, 0.3, 60, 0.3)
  local b = join_note(a.end_time, b_dur or 0.3, 62, -0.2, { from = 60, dur = slide_dur })
  return a, b
end

test("join_continuous", function()
  local a, b = slid_pair(0.04)
  local build = S.K.correction_build({ a, b }, 10)
  eq(#spans_of(build, "glide"), 1, "glides")
  if max_step(build.points) >= 0.12 then error("step " .. max_step(build.points)) end
end)

test("join_span_follows_slide", function()
  local a, b = slid_pair(0.04)
  local g = spans_of(S.K.correction_build({ a, b }, 10), "glide")[1]
  local _, a_end = S.K.note_body(a)
  local b_start = S.K.note_body(b)
  near(g.t0, a.frames[a_end].time, JHOP, "t0")
  near(g.t1, b.frames[b_start].time, JHOP, "t1")
end)

test("join_limits", function()
  local a, b = slid_pair(0.3, 1.0)
  local g = spans_of(S.K.correction_build({ a, b }, 10), "glide")[1]
  if g.t1 - g.t0 > S.K.JOIN.MAX_S + JHOP then error("glide " .. (g.t1 - g.t0)) end
  a, b = slid_pair(0.03, 0.05)
  g = spans_of(S.K.correction_build({ a, b }, 10), "glide")[1]
  if g.t1 > b.start_time + 0.4 * (b.end_time - b.start_time) + 1e-9 then error("t1 " .. g.t1) end
end)

test("join_min", function()
  local a = join_note(0.1, 0.3, 60, 0.3)
  local b = join_note(a.end_time, 0.3, 62, -0.2)
  local g = spans_of(S.K.correction_build({ a, b }, 10), "glide")[1]
  near(g.t1 - g.t0, 0.010, JHOP, "length")
  near((g.t0 + g.t1) / 2, a.end_time, JHOP, "centre")
end)

test("join_meets_tightened_body", function()
  local a, b = slid_pair(0.04)
  local first = S.K.note_body(b)
  for i = first, #b.frames do
    local w = 62 + 0.2 * math.sin(2 * math.pi * 5 * b.frames[i].time)
    b.frames[i].note, b.smooth[i] = w, w
  end
  b.controls.tighten = 0.6
  local build = S.K.correction_build({ a, b }, 10)
  local g = spans_of(build, "glide")[1]
  local bs = S.K.note_body(b)
  local p = point_at(build.points, g.t1)
  if not p then error("no point at t1") end
  near(g.t1, b.frames[bs].time, 1e-9, "t1 on the body start")
  near(p.val, b.frame_shifts[bs], 1e-9, "meets the body")
  if max_step(build.points) >= 0.12 then error("step " .. max_step(build.points)) end
end)

test("join_slide_in", function()
  local a, b = slid_pair(0.04)
  b.controls.slide_in = 1
  local build = S.K.correction_build({ a, b }, 10)
  local g = spans_of(build, "glide")[1]
  -- Continuous: no step beyond the frame-to-frame change Slide In itself writes into the slide
  local own = 0
  for i = 2, #b.frame_shifts do own = math.max(own, math.abs(b.frame_shifts[i] - b.frame_shifts[i - 1])) end
  if max_step(build.points) >= own + 0.12 then error("step " .. max_step(build.points)) end
  local bs = S.K.note_body(b)
  local p = point_at(build.points, g.t1)
  if not p then error("no point at t1") end
  near(p.val, b.frame_shifts[bs], 1e-9, "end value")
end)

test("join_edited_to_untouched", function()
  -- A: a tightened, shifted note with vibrato in its body; U: an untouched note (no edits at all)
  local function edited(t0, slide)
    local n = join_note(t0, 0.3, 60, 0.3, slide)
    local first = S.K.note_body(n)
    for i = first, #n.frames do
      local w = 60 + 0.2 * math.sin(2 * math.pi * 5 * n.frames[i].time)
      n.frames[i].note, n.smooth[i] = w, w
    end
    n.controls.tighten = 0.6
    return n
  end
  local function untouched(t0, slide)
    local n = join_note(t0, 0.3, 62, 0, slide)
    n.controls.retune_speed = nil
    return n
  end
  local function check(build, tag)
    local g = spans_of(build, "glide")
    eq(#g, 1, tag .. " glides")
    g = g[1]
    if max_step(build.points) >= 0.12 then error(tag .. " step " .. max_step(build.points)) end
    local covered = false
    for _, r in ipairs(build.ranges) do
      if r.t0 <= g.t0 + 1e-9 and r.t1 >= g.t1 - 1e-9 then covered = true end
    end
    eq(covered, true, tag .. " ranges cover the glide")
    return g
  end
  -- Edited first: the blend runs to 0 where it meets the untouched note
  local a = edited(0.1)
  local u = untouched(a.end_time, { from = 60, dur = 0.04 })
  local g = check(S.K.correction_build({ a, u }, 10), "edited first")
  local build = S.K.correction_build({ a, u }, 10)
  local p = point_at(build.points, g.t1)
  if not p then error("no point at t1") end
  near(p.val, 0, 1e-9, "edited first: 0 on the untouched side")
  -- Untouched first: the blend starts from 0
  u = untouched(0.1)
  local b = edited(u.end_time, { from = 62, dur = 0.04 })
  build = S.K.correction_build({ u, b }, 10)
  g = check(build, "untouched first")
  p = point_at(build.points, g.t0)
  if not p then error("no point at t0") end
  near(p.val, 0, 1e-9, "untouched first: 0 on the untouched side")
  near(point_at(build.points, g.t1).val, b.frame_shifts[S.K.note_body(b)], 1e-9, "meets the edited body")
end)

test("unjoined_fades", function()
  local a = join_note(0.1, 0.3, 60, 0.3)
  local b = join_note(a.end_time + 0.2, 0.3, 62, -0.2)
  local build = S.K.correction_build({ a, b }, 10)
  eq(#spans_of(build, "glide"), 0, "glides")
  local rel, ons
  for _, sp in ipairs(spans_of(build, "release")) do if sp.a == 1 then rel = sp end end
  for _, sp in ipairs(spans_of(build, "onset")) do if sp.a == 2 then ons = sp end end
  if not (rel and ons) then error("missing fade") end
  near(rel.t1 - rel.t0, 0.030, 1e-6, "release")
  near(ons.t1 - ons.t0, 0.030, 1e-6, "onset")
  near(value_at(build.points, (a.end_time + b.start_time) / 2), 0, 1e-9, "between")
end)

test("joined_by_short_gap", function()
  local a = join_note(0.1, 0.3, 60, 0.3)
  local b = join_note(a.end_time + 0.04, 0.3, 62, -0.2)
  local build = S.K.correction_build({ a, b }, 10)
  eq(#spans_of(build, "glide"), 1, "glides")
  for _, sp in ipairs(spans_of(build, "release")) do if sp.a == 1 then error("release between") end end
  for _, sp in ipairs(spans_of(build, "onset")) do if sp.a == 2 then error("onset between") end end
end)

test("join_bodiless_note", function()
  local a = join_note(0.1, 0.3, 60, 0.3)
  local b = join_note(a.end_time, 3 * JHOP, 62, -0.2)
  for i = 1, 3 do b.frames[i].note, b.smooth[i] = 65, 65 end
  eq(S.K.note_body(b), nil, "bodiless")
  local build = S.K.correction_build({ a, b }, 10)
  eq(#spans_of(build, "glide"), 1, "glides")
  if max_step(build.points) > 0.5 + 1e-9 then error("step " .. max_step(build.points)) end
end)

test("untouched_pair_writes_nothing", function()
  local a = join_note(0.1, 0.3, 60, 0)
  local b = join_note(a.end_time, 0.3, 62, 0)
  a.controls.retune_speed, b.controls.retune_speed = nil, nil
  eq(#S.K.correction_build({ a, b }, 10).points, 0, "points")
end)

test("segment_to_correction", function()
  -- K.segment -> extract_note_features -> K.correction_build, as an analysis and a target edit run them
  -- 0.1 s of silence each side: the fades into and out of the notes lie inside the item
  local segs = slide_segs(62)
  table.insert(segs, 1, { dur = 0.1 })
  segs[#segs + 1] = { dur = 0.1 }
  local fr = frames(segs, HOP)
  local item_len = fr[#fr].time + HOP
  local notes = S.K.segment(fr, 0.5)
  eq(#notes, 2, "notes")
  for i, n in ipairs(notes) do
    n.avg_note = n.sum_note / n.count
    n.display_note = math.floor(n.avg_note + 0.5)
    S.extract_note_features(n)
    -- 0.2 st apart: this slide leaves a blend of about three frames at this hop, so a step stays under the bound
    n.controls.center_pitch = n.avg_note + (i == 1 and 0.15 or -0.05)
    n.controls.retune_speed = 1
  end
  local build = S.K.correction_build(notes, item_len)
  eq(#spans_of(build, "glide"), 1, "glides")
  if max_step(build.points) >= 0.12 then error("step " .. max_step(build.points)) end
  for _, q in ipairs(build.points) do
    if q.time < 0 or q.time > item_len then error("point outside the item at " .. q.time) end
  end
end)

-- Re-split: notes { start_time, end_time, edited } and a predicate on `edited`
local RTOL = 256 / 44100
local function rnote(t0, t1, edited) return { start_time = t0, end_time = t1, edited = edited } end
local function r_edited(n) return n.edited == true end

test("resplit_match_identical", function()
  local old = { rnote(0.1, 0.5, true), rnote(0.6, 0.9, false), rnote(1.0, 1.4, true) }
  local new = { rnote(0.1, 0.5), rnote(0.6, 0.9), rnote(1.0, 1.4) }
  local pairs_, lost = S.K.resplit_match(old, new, RTOL, r_edited)
  for i = 1, 3 do eq(pairs_[i], old[i], "pair " .. i) end
  eq(lost, 0, "lost")
end)

test("resplit_match_edited_cut", function()
  local old = { rnote(0.1, 0.5, false), rnote(0.6, 1.4, true) }
  local new = { rnote(0.1, 0.5), rnote(0.6, 1.0), rnote(1.0 + RTOL, 1.4) }
  local pairs_, lost = S.K.resplit_match(old, new, RTOL, r_edited)
  eq(pairs_[1], old[1], "kept")
  eq(pairs_[2], nil, "first half")
  eq(pairs_[3], nil, "second half")
  eq(lost, 1, "lost")
end)

test("resplit_match_unedited_cut", function()
  local old = { rnote(0.1, 0.5, true), rnote(0.6, 1.4, false) }
  local new = { rnote(0.1, 0.5), rnote(0.6, 1.0), rnote(1.0 + RTOL, 1.4) }
  local pairs_, lost = S.K.resplit_match(old, new, RTOL, r_edited)
  eq(pairs_[1], old[1], "kept")
  eq(pairs_[2], nil, "first half")
  eq(lost, 0, "lost")
end)

test("resplit_match_tolerance", function()
  local old = { rnote(0.1, 0.5, true), rnote(0.6, 0.9, true) }
  local new = { rnote(0.1 + RTOL / 2, 0.5), rnote(0.6, 0.9 - 2 * RTOL) }
  local pairs_, lost = S.K.resplit_match(old, new, RTOL, r_edited)
  eq(pairs_[1], old[1], "half a tolerance pairs")
  eq(pairs_[2], nil, "twice the tolerance does not")
  eq(lost, 1, "lost")
end)

test("no_removed_names", function()
  local f = assert(io.open(SCRIPT, "rb"))
  local src = f:read("a")
  f:close()
  for _, name in ipairs({ "transition_ms", "onset_ramp_ms", "legato_threshold_ms", "scoop_shape",
      '"Legato Gap"', '"Onset Ramp"', '"Scoop Shape"', "timing_open" }) do
    eq(src:find(name, 1, true), nil, name)
  end
  for _, name in ipairs({ '"Slide In"', '"Separation"' }) do
    eq(src:find(name, 1, true) ~= nil, true, name)
  end
end)

test("join_bypassed_neighbour", function()
  -- An edited note touching a bypassed one: the blend stays on the edited side, the bypassed note gets nothing
  local function bypassed(t0, slide)
    local n = join_note(t0, 0.3, 62, 0.5, slide)
    n.controls.bypassed = true
    return n
  end
  local a = join_note(0.1, 0.3, 60, 0.3)
  local b = bypassed(a.end_time, { from = 60, dur = 0.04 })
  local bnd = a.end_time
  local build = S.K.correction_build({ a, b }, 10)
  local g = spans_of(build, "glide")
  eq(#g, 1, "edited first: glides")
  if g[1].t1 > bnd + 1e-9 then error("edited first: glide ends at " .. g[1].t1) end
  if g[1].t1 - g[1].t0 < S.K.JOIN.MIN_S - 1e-9 then error("edited first: glide " .. (g[1].t1 - g[1].t0)) end
  for _, p in ipairs(build.points) do
    if p.time >= bnd - 1e-9 and math.abs(p.val) > 1e-9 then error("edited first: " .. p.val .. " at " .. p.time) end
  end
  -- Bypassed first: nothing before the boundary
  b = bypassed(0.1)
  local c = join_note(b.end_time, 0.3, 62, -0.2, { from = 60, dur = 0.04 })
  bnd = b.end_time
  build = S.K.correction_build({ b, c }, 10)
  g = spans_of(build, "glide")
  eq(#g, 1, "bypassed first: glides")
  if g[1].t0 < bnd - 1e-9 then error("bypassed first: glide starts at " .. g[1].t0) end
  for _, p in ipairs(build.points) do
    if p.time <= bnd + 1e-9 and math.abs(p.val) > 1e-9 then error("bypassed first: " .. p.val .. " at " .. p.time) end
  end
end)

test("follow_resplit_undo", function()
  local st, K = S.state, S.K
  local can_undo, can_redo
  reaper.Undo_CanUndo2 = function() return can_undo end
  reaper.Undo_CanRedo2 = function() return can_redo end
  st.target_take_guid = "{T}"
  -- Undone: the stored notes' own value
  st.separation, can_undo, can_redo = 0.8, "Move edit cursor", K.RESPLIT_UNDO
  K.follow_resplit_undo({ separation = 0.5 })
  near(st.separation, 0.5, 1e-12, "undone, stored value")
  -- Redone
  can_undo, can_redo = K.RESPLIT_UNDO, nil
  K.follow_resplit_undo({ separation = 0.8 })
  near(st.separation, 0.8, 1e-12, "redone, stored value")
  -- Notes stored without a value: this session's last re-split of the item
  K.resplit_last = { guid = "{T}", before = 0.3, after = 0.8 }
  can_undo, can_redo = "Move edit cursor", K.RESPLIT_UNDO
  K.follow_resplit_undo({})
  near(st.separation, 0.3, 1e-12, "undone, no stored value")
  -- Any other undo leaves it alone
  can_undo, can_redo = "Adjust Tighten", "Adjust Slide In"
  K.follow_resplit_undo({ separation = 0.9 })
  near(st.separation, 0.3, 1e-12, "other undo")
  reaper.Undo_CanUndo2, reaper.Undo_CanRedo2, K.resplit_last, st.target_take_guid = nil, nil, nil, nil
end)

test("note_bar_place", function()
  local st, K = S.state, S.K
  local L = require("theme").layout
  local saved_map, saved_notes = st.draw_cache.map, st.notes
  -- Note area 400 x 300 at (100, 50), seconds 0..4, pitch 60..72 (25 px a semitone), ruler 20 px
  st.draw_cache.map = { px = 100, py = 50, w = 400, h = 300, vt0 = 0, vt1 = 4, min = 60, range = 12 }
  local function note(t0, t1, cp) return { start_time = t0, end_time = t1, controls = { center_pitch = cp } } end
  st.notes = { note(1, 2, 66), note(-1, 0.5, 64), note(-1, -0.5, 66), note(1, 2, 80), note(3, 3.5, 60.5) }
  local bw, bh, ruler = 96, 24, 20
  -- Note 1: block 65.5 .. 66.5, 1 .. 2 s (middle at 250 px)
  local a = K.note_bar_anchor(1, ruler)
  near(a.x, 250, 1e-9, "middle"); near(a.top, 350 - 6.5 * 25, 1e-9, "top"); near(a.bot, 350 - 5.5 * 25, 1e-9, "bot")
  local x, y, above = K.note_bar_pos(a, bw, bh, ruler, 0, 0)
  eq(x, 250 - bw / 2, "centred"); eq(y, math.floor(a.bot + L.sm + 0.5), "below"); eq(above, false, "not above")
  -- The offset moves it
  x, y = K.note_bar_pos(a, bw, bh, ruler, 30, -10)
  eq(x, 250 - bw / 2 + 30, "dx"); eq(y, math.floor(a.bot + L.sm - 10 + 0.5), "dy")
  -- A note that starts before the window: centred on its visible part (0 .. 0.5 s), then kept L.xs inside
  a = K.note_bar_anchor(2, ruler)
  near(a.x, 125, 1e-9, "visible middle")
  x = K.note_bar_pos(a, bw, bh, ruler, 0, 0)
  eq(x, 100 + L.xs, "inside the area")
  -- Out of view (time / pitch): nothing
  eq(K.note_bar_anchor(3, ruler), nil, "before the window")
  eq(K.note_bar_anchor(4, ruler), nil, "above the view")
  -- At the bottom of the view: above the block, the vertical offset mirrored
  a = K.note_bar_anchor(5, ruler)
  local _, y2, above2 = K.note_bar_pos(a, bw, bh, ruler, 0, 5)
  eq(above2, true, "flipped"); eq(y2, math.floor(a.top - L.sm - bh - 5 + 0.5), "above, mirrored")
  -- Right edge clamp
  x = K.note_bar_pos(a, bw, bh, ruler, 1000, 0)
  eq(x, 100 + 400 - L.xs - bw, "clamped right")
  st.draw_cache.map, st.notes = saved_map, saved_notes
end)

test("beat ruler: the label step follows the zoom, from parts of a beat out to many bars", function()
  local K = load_script().K
  local function steps(beat_px) return table.pack(K.ruler_beat_steps(beat_px, 4, 60, 90)) end
  local function is(got, bars, label_beats, tick_beats, bar_ticks)
    eq(got[1], bars, "bars"); eq(got[2], label_beats, "label_beats")
    eq(got[3], tick_beats, "tick_beats"); eq(got[4], bar_ticks, "bar_ticks")
  end
  is(steps(400), 1, 0.25, 0.125, false)   -- quarter beats labelled, eighths ticked
  is(steps(200), 1, 0.5, 0.125, false)    -- half beats labelled
  is(steps(100), 1, 1, 0.25, false)       -- every beat labelled, quarters ticked
  is(steps(20), 1, nil, 1, false)         -- every bar labelled (80 px), beats ticked
  is(steps(10), 2, nil, nil, true)        -- every 2nd bar labelled, the bars between ticked
  is(steps(1), 16, nil, nil, false)       -- every 16th bar labelled, bars too tight (4 px) to tick
  is(table.pack(K.ruler_beat_steps(20, 3, 60, 90)), 1, nil, 1, false)     -- 3/4: a 60 px bar still fits its label
  is(table.pack(K.ruler_beat_steps(0.0001, 4, 60, 90)), 1024, nil, nil, false)   -- the step is capped
end)

test("note_actions_frame", function()
  local st, K = S.state, S.K
  local saved = { st.results, st.notes, st.selected_notes, st.selected_note, st.is_analyzing }
  st.results = { { time = 0, note = 60 } }
  st.notes = { { start_time = 1, end_time = 2, controls = {} }, { start_time = 2, end_time = 3, controls = {} } }
  st.is_analyzing = false
  st.selected_notes, st.selected_note = {}, nil
  local reason = K.note_actions_frame(true, nil)
  eq(reason("snap"), "Select a note"); eq(reason("merge"), "Select 2 or more notes")
  st.selected_notes = { [1] = true, [2] = true }
  reason = K.note_actions_frame(true, nil)
  eq(reason("snap"), nil); eq(reason("quantize"), nil); eq(reason("merge"), nil)
  eq(reason("split"), "Select one note to split")
  st.selected_notes, st.selected_note = { [1] = true }, 1
  local item = {}
  reaper.GetMediaItemInfo_Value = function() return 10 end
  reaper.GetCursorPosition = function() return 11.5 end
  local idx
  reason, idx = K.note_actions_frame(true, item)
  eq(reason("split"), nil, "cursor inside"); eq(idx, 1)
  reaper.GetCursorPosition = function() return 13 end
  reason = K.note_actions_frame(true, item)
  eq(reason("split"), "Move the edit cursor into the selected note")
  reason = K.note_actions_frame(false, item)
  eq(reason("snap"), "Select an audio item")
  reaper.GetMediaItemInfo_Value, reaper.GetCursorPosition = nil, nil
  st.results, st.notes, st.selected_notes, st.selected_note, st.is_analyzing = table.unpack(saved)
end)

-- Proof of Natural: the correction of v2.18.0 pinned to the number ---------------------------------------------
-- natural_corpus() builds fresh notes on every call (a build mutates the notes and caches on them). The recorder
-- (--record-natural) writes what K.correction_build gives on the unchanged v2.18.0 script; the tests compare to it.

local NATURAL_REF = "810bc35"
local NATURAL_FIXTURE = "docs/superpowers/tests/fixtures/natural_v2_18_0.lua"

-- The sung pitch of the note's body wobbles +/-0.3 st at 5 Hz over a slow drift (so Tighten has something to take)
local function wobbly(n, tighten, tolerance)
  local first = S.K.note_body(n)
  for i = first or 1, #n.frames do
    local t = n.frames[i].time
    local w = n.avg_note + 0.3 * math.sin(2 * math.pi * 5 * t) + 0.1 * math.sin(2 * math.pi * 0.7 * t)
    n.frames[i].note, n.smooth[i] = w, w
  end
  n.controls.tighten, n.controls.tolerance = tighten, tolerance
  return n
end

local function untouched_note(t0, dur, centre, slide)   -- a note nobody edited (a Strength of its own counts as one)
  local n = join_note(t0, dur or 0.3, centre or 60, 0, slide)
  n.controls.retune_speed = nil
  return n
end

local function bypassed_note(t0, dur, centre, slide)
  local n = join_note(t0, dur, centre, 0.5, slide)
  n.controls.bypassed = true
  return n
end

local function with_points(n, list)
  n.controls.points = {}
  for i, p in ipairs(list) do
    n.controls.points[i] = { t = n.frames[p[1]].time, st = p[2], added = true }
  end
  return n
end

local function natural_corpus()
  local cases = {}
  local function add(name, notes, item_len, setup, teardown)
    cases[#cases + 1] = { name = name, notes = notes, item_len = item_len, setup = setup, teardown = teardown }
  end
  local function solo(name, n, item_len) add(name, { n }, item_len or 10) end

  solo("moved", join_note(0.1, 0.3, 60, 0.3))
  solo("tighten_50_tol_8", wobbly(join_note(0.1, 0.4, 60, 0.3), 0.5, 8))
  solo("tighten_100", wobbly(join_note(0.1, 0.4, 60, -0.2), 1, nil))
  solo("tighten_50_tol_30", wobbly(join_note(0.1, 0.4, 60, 0.3), 0.5, 30))
  for _, v in ipairs({ { 0, "slide_in_0" }, { 0.5, "slide_in_50" }, { 1, "slide_in_100" } }) do
    solo(v[2], slide_note(2, v[1]), 1)
  end
  local half = join_note(0.1, 0.4, 60, 0.3)
  half.controls.retune_speed = 0.5
  solo("strength_50_note", wobbly(half, 0.5, 8))
  local saved
  add("strength_50_item", { wobbly(join_note(0.1, 0.4, 60, 0.3), 0.5, 8) }, 10,
    function()
      saved = { S.state.target_take_guid, S.state.session_takes["{T}"] }
      S.state.target_take_guid = "{T}"
      S.state.session_takes["{T}"] = { overrides = { retune_speed = 0.5 } }
    end,
    function()
      S.state.target_take_guid, S.state.session_takes["{T}"] = saved[1], saved[2]
    end)
  cases[#cases].notes[1].controls.retune_speed = nil

  local a, b = slid_pair(0.04)
  add("joined_pair", { a, wobbly(b, 0.6, 8) }, 10)
  a = join_note(0.1, 0.3, 60, 0.3)
  add("short_gap", { a, join_note(a.end_time + 0.04, 0.3, 62, -0.2) }, 10)
  a = join_note(0.1, 0.3, 60, 0.3)
  add("unjoined_fades", { a, join_note(a.end_time + 0.2, 0.3, 62, -0.2) }, 10)

  a = wobbly(join_note(0.1, 0.3, 60, 0.3), 0.6, 8)
  add("edited_then_untouched", { a, untouched_note(a.end_time, 0.3, 62, { from = 60, dur = 0.04 }) }, 10)
  a = join_note(0.1, 0.3, 60, 0.3)
  add("edited_then_bypassed", { a, bypassed_note(a.end_time, 0.3, 62, { from = 60, dur = 0.04 }) }, 10)
  a = bypassed_note(0.1, 0.3, 62)
  add("bypassed_then_edited", { a, join_note(a.end_time, 0.3, 62, -0.2, { from = 60, dur = 0.04 }) }, 10)

  solo("pitch_points", with_points(join_note(0.1, 0.4, 60, 0.2), { { 12, 0.5 }, { 40, -0.4 }, { 60, 0.25 } }))
  a = join_note(0.1, 0.3, 60, 0.3)
  b = join_note(a.end_time, 3 * JHOP, 62, -0.2)
  for i = 1, 3 do b.frames[i].note, b.smooth[i] = 65, 65 end
  add("bodiless_note", { a, b }, 10)
  solo("note_at_item_start", join_note(0, 0.3, 60, 0.3))
  solo("note_at_item_end", join_note(0.7, 0.3, 60, 0.3), 1)

  -- A phrase of six: tightened, joined with Slide In, bypassed, untouched, with points (after a gap), joined at half Strength
  local p1 = wobbly(join_note(0.1, 0.3, 60, 0.3), 0.5, 8)
  local p2 = join_note(p1.end_time, 0.3, 62, -0.2, { from = 60, dur = 0.04 })
  p2.controls.slide_in = 0.5
  local p3 = bypassed_note(p2.end_time, 0.3, 64)
  local p4 = untouched_note(p3.end_time + 0.02, 0.3, 65)
  local p5 = with_points(join_note(p4.end_time + 0.2, 0.3, 67, 0.1), { { 10, 0.4 }, { 30, -0.3 } })
  local p6 = join_note(p5.end_time, 0.3, 69, -0.15, { from = 67, dur = 0.04 })
  p6.controls.retune_speed = 0.5
  add("phrase_of_six", { p1, p2, p3, p4, p5, p6 }, 10)
  return cases
end

local function natural_run(case)
  if case.setup then case.setup() end
  local got = S.K.correction_build(case.notes, case.item_len)
  if case.teardown then case.teardown() end
  return got
end

local function num(x) return string.format("%.17g", x) end

-- The lines of one recorded case: what the build gave, and every note's frame shifts
local function record_case(out, name, got, notes)
  local function row(list)
    local parts = {}
    for i, x in ipairs(list) do parts[i] = num(x) end
    return table.concat(parts, ", ")
  end
  out[#out + 1] = '    ["' .. name .. '"] = {'
  out[#out + 1] = "      points = {"
  for _, p in ipairs(got.points) do out[#out + 1] = "        { " .. num(p.time) .. ", " .. num(p.val) .. " }," end
  out[#out + 1] = "      },"
  out[#out + 1] = "      spans = {"
  for _, s in ipairs(got.spans) do
    out[#out + 1] = string.format('        { "%s", %s, %s, %s, %s },', s.kind, num(s.t0), num(s.t1),
      s.a and tostring(s.a) or "nil", s.b and tostring(s.b) or "nil")
  end
  out[#out + 1] = "      },"
  out[#out + 1] = "      ranges = {"
  for _, r in ipairs(got.ranges) do out[#out + 1] = "        { " .. num(r.t0) .. ", " .. num(r.t1) .. " }," end
  out[#out + 1] = "      },"
  out[#out + 1] = "      shifts = {"
  for _, n in ipairs(notes) do out[#out + 1] = "        { " .. row(n.frame_shifts) .. " }," end
  out[#out + 1] = "      },"
  out[#out + 1] = "    },"
end

-- The real vocal (this machine only): a take's saved model read the way the script reads it from a take
local FIXTURE_DIR = (os.getenv("HOME") or "") .. "/.fancy-scripts-fixtures/"
local function real_model()
  local f = io.open(FIXTURE_DIR .. "pitch_real_model.json", "rb")
  if not f then return nil end
  local raw = f:read("a")
  f:close()
  local json = loadfile("_lib/json.lua")()
  local data = json.decode(raw)
  for _, note in ipairs(data.notes) do
    note.count = #note.frames
    local saved = note.controls
    S.extract_note_features(note)
    S.K.controls_load(note.controls, saved)
    S.K.points_sanitize(note)
  end
  return data
end

-- Writes recorded cases to `path` under the comment lines `head` (items: { got, notes }; name_of(item) names a case;
-- commit: the commit whose behaviour was recorded, or nil)
local function record_write(path, head, commit, name_of, items)
  local out = {}
  for i, line in ipairs(head) do out[i] = line end
  out[#out + 1] = "return {"
  if commit then out[#out + 1] = '  commit = "' .. commit .. '",' end
  out[#out + 1] = "  cases = {"
  for _, item in ipairs(items) do record_case(out, name_of(item), item.got, item.notes) end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(out, "\n"), "\n")
  f:close()
  print("recorded " .. #items .. " cases to " .. path)
end

local function natural_record()
  local ok = os.execute('git diff --quiet ' .. NATURAL_REF .. ' -- "' .. SCRIPT .. '"')
  if ok ~= true then
    io.stderr:write("refusing to record: " .. SCRIPT .. " differs from " .. NATURAL_REF
      .. " (the fixture is the v2.18.0 behaviour)\n")
    os.exit(1)
  end
  local head = { "-- Recorded by: lua docs/superpowers/tests/pitch_correct_spec.lua --record-natural",
    "-- Natural correction of Pitch Correct v2.18.0 (commit " .. NATURAL_REF .. "). Do not edit by hand." }
  local function write(path, name_of, items) record_write(path, head, NATURAL_REF, name_of, items) end
  local items = {}
  for _, case in ipairs(natural_corpus()) do
    items[#items + 1] = { name = case.name, got = natural_run(case), notes = case.notes }
  end
  write(NATURAL_FIXTURE, function(it) return it.name end, items)
  local data = real_model()
  if data then
    local got = S.K.correction_build(data.notes, data.item_len)
    write(FIXTURE_DIR .. "pitch_real_expected.lua", function() return "real" end,
      { { got = got, notes = data.notes } })
  end
end

-- The real vocal's expected numbers again, from the script as it is now (no commit check): for a fix that changes
-- them on purpose. The committed fixture is not touched.
local function real_record()
  local data = real_model()
  if not data then
    io.stderr:write("no local fixture\n")
    os.exit(1)
  end
  local got = S.K.correction_build(data.notes, data.item_len)
  record_write(FIXTURE_DIR .. "pitch_real_expected.lua",
    { "-- Recorded by: lua docs/superpowers/tests/pitch_correct_spec.lua --record-real",
      "-- Natural correction of the real vocal, recorded after the note-centre fix (v2.19.1). Do not edit by hand." },
    nil, function() return "real" end, { { got = got, notes = data.notes } })
end

test("natural_same_numbers", function()
  local fx = dofile(NATURAL_FIXTURE)
  local seen = 0
  for _, case in ipairs(natural_corpus()) do
    local want = fx.cases[case.name]
    if not want then error("no recorded case " .. case.name) end
    seen = seen + 1
    local got = natural_run(case)
    -- exact: ==, never near()
    eq(#got.points, #want.points, case.name .. " points")
    for i, p in ipairs(got.points) do
      eq(p.time, want.points[i][1], case.name .. " point time " .. i)
      eq(p.val, want.points[i][2], case.name .. " point val " .. i)
    end
    eq(#got.spans, #want.spans, case.name .. " spans")
    for i, s in ipairs(got.spans) do
      local w = want.spans[i]
      eq(s.kind, w[1], case.name .. " span kind " .. i)
      eq(s.t0, w[2], case.name .. " span t0 " .. i)
      eq(s.t1, w[3], case.name .. " span t1 " .. i)
      eq(s.a, w[4], case.name .. " span a " .. i)
      eq(s.b, w[5], case.name .. " span b " .. i)
    end
    eq(#got.ranges, #want.ranges, case.name .. " ranges")
    for i, r in ipairs(got.ranges) do
      eq(r.t0, want.ranges[i][1], case.name .. " range t0 " .. i)
      eq(r.t1, want.ranges[i][2], case.name .. " range t1 " .. i)
    end
    eq(#case.notes, #want.shifts, case.name .. " notes")
    for ni, n in ipairs(case.notes) do
      eq(#n.frame_shifts, #want.shifts[ni], case.name .. " frames of note " .. ni)
      for i, v in ipairs(n.frame_shifts) do
        eq(v, want.shifts[ni][i], case.name .. " shift " .. ni .. "/" .. i)
      end
    end
  end
  local n_want = 0
  for _ in pairs(fx.cases) do n_want = n_want + 1 end
  eq(seen, n_want, "every recorded case is in the corpus")
  if seen < 20 then error("only " .. seen .. " cases") end
end)

test("natural_same_numbers_real", function()
  local data = real_model()
  local f = io.open(FIXTURE_DIR .. "pitch_real_expected.lua", "rb")
  if not data or not f then
    if f then f:close() end
    print("SKIP natural_same_numbers_real (no local fixture)")
    return
  end
  f:close()
  local want = dofile(FIXTURE_DIR .. "pitch_real_expected.lua").cases.real
  local got = S.K.correction_build(data.notes, data.item_len)
  eq(#got.points, #want.points, "points")
  for i, p in ipairs(got.points) do
    eq(p.time, want.points[i][1], "point time " .. i)
    eq(p.val, want.points[i][2], "point val " .. i)
  end
  eq(#got.spans, #want.spans, "spans")
  for i, sp in ipairs(got.spans) do
    local w = want.spans[i]
    eq(sp.kind, w[1], "span kind " .. i); eq(sp.t0, w[2], "span t0 " .. i); eq(sp.t1, w[3], "span t1 " .. i)
    eq(sp.a, w[4], "span a " .. i); eq(sp.b, w[5], "span b " .. i)
  end
  eq(#got.ranges, #want.ranges, "ranges")
  for i, r in ipairs(got.ranges) do
    eq(r.t0, want.ranges[i][1], "range t0 " .. i); eq(r.t1, want.ranges[i][2], "range t1 " .. i)
  end
  eq(#data.notes, #want.shifts, "notes")
  for ni, n in ipairs(data.notes) do
    eq(#n.frame_shifts, #want.shifts[ni], "frames of note " .. ni)
    for i, v in ipairs(n.frame_shifts) do eq(v, want.shifts[ni][i], "shift " .. ni .. "/" .. i) end
  end
end)

-- Lines of the block that starts at the first line beginning with `prefix`: up to the first later line that is the
-- prefix's own indentation followed by "end" or "}" (or "end," / "},"). Returns the lines, or nil.
local function text_block(lines, prefix)
  for i, l in ipairs(lines) do
    if l:sub(1, #prefix) == prefix then
      local indent = l:match("^(%s*)")
      local out = { l }
      for j = i + 1, #lines do
        out[#out + 1] = lines[j]
        local rest = lines[j]:match("^" .. indent .. "(.*)$")
        if rest and (rest:match("^end%f[^%w_]") or rest:match("^}")) then return out end
      end
      return nil
    end
  end
  return nil
end

local function text_lines(s)
  local lines = {}
  for l in (s .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
  return lines
end

local function text_same(ref, now, ref_prefix, now_prefix, skip_first, what)
  local a, b = text_block(ref, ref_prefix), text_block(now, now_prefix)
  if not a then error(what .. ": not found in " .. NATURAL_REF) end
  if not b then error(what .. ": not found in the script") end
  eq(#b, #a, what .. " length")
  for i = skip_first and 2 or 1, #a do eq(b[i], a[i], what .. " line " .. i) end
end

local function text_single(ref, now, prefix, what)
  local want
  for _, l in ipairs(ref) do if l:sub(1, #prefix) == prefix then want = l break end end
  if not want then error(what .. ": not found in " .. NATURAL_REF) end
  for _, l in ipairs(now) do if l == want then return end end
  error(what .. ": line changed: " .. want)
end

test("natural_same_text", function()
  local p = io.popen('git show ' .. NATURAL_REF .. ':"' .. SCRIPT .. '" 2>/dev/null')
  local ref_src = p and p:read("a") or ""
  if p then p:close() end
  if ref_src == "" then print("SKIP natural_same_text (" .. NATURAL_REF .. " not readable)") return end
  local f = assert(io.open(SCRIPT, "rb"))
  local now_src = f:read("a")
  f:close()
  local ref, now = text_lines(ref_src), text_lines(now_src)
  -- Value levels (2026-11-24) changed the build, K.tighten_line, K.ZONE_CONTROLS and the Tighten line of
  -- K.controls_load on purpose (item values reach every note; 0 is a note value of its own). Their numbers stay
  -- pinned by natural_same_numbers. The bar's BAR_VALUES changed on purpose too (Task 3: every value has an item
  -- level, and 0 is stored as a value).
  for _, prefix in ipairs({ "K.note_body = function(", "K.points_offsets = function(",
      "local function is_note_modified(", "K.controls_edited = function(",
      "local function param_drag(" }) do
    text_same(ref, now, prefix, prefix, false, prefix)
  end
  text_single(ref, now, "K.JOIN = {", "K.JOIN")
  local loaded = text_block(now, "K.controls_load = function(")
  local ref_loaded = text_block(ref, "K.controls_load = function(")
  if not (loaded and ref_loaded) then error("K.controls_load not found") end
  text_single(ref_loaded, loaded, "  if ctrl.tolerance then", "K.controls_load   if ctrl.tolerance then")
end)

if arg and arg[1] == "--record-natural" then natural_record() os.exit(0) end
if arg and arg[1] == "--record-real" then real_record() os.exit(0) end

local function with_item_mode(mode, fn)   -- runs fn with an open item whose mode is `mode` (nil = none)
  local st = S.state
  local saved_guid, saved_take = st.target_take_guid, st.session_takes["{M}"]
  st.target_take_guid = "{M}"
  st.session_takes["{M}"] = { overrides = { correct_mode = mode } }
  local ok, err = pcall(fn)
  st.target_take_guid, st.session_takes["{M}"] = saved_guid, saved_take
  if not ok then error(err, 0) end
end

test("mode_load_holds_range", function()
  for _, bad in ipairs({ 3, 1.5, -1, "x", "1", "2" }) do
    local ctrl = {}
    S.K.controls_load(ctrl, { correct_mode = bad })
    eq(ctrl.correct_mode, nil, "bad " .. tostring(bad))
  end
  for _, good in ipairs({ 0, 1, 2 }) do
    local ctrl = {}
    S.K.controls_load(ctrl, { correct_mode = good })
    eq(ctrl.correct_mode, good)
  end
end)

test("mode_first_attempt_data_is_natural", function()
  local ctrl = {}
  S.K.controls_load(ctrl, { tighten = 1.4, tune_mode = 2 })
  eq(ctrl.tighten, 1, "Tighten above 100% reads as 100%")
  eq(ctrl.tune_mode, nil); eq(ctrl.correct_mode, nil)
end)

test("mode_value_and_note_mode", function()
  local moved = join_note(0.1, 0.3, 60, 0.5)
  local untouched = untouched_note(0.5)
  eq(S.K.mode_value(moved), 0); eq(S.K.note_mode(moved), nil)
  with_item_mode(1, function()
    eq(S.K.mode_value(nil), 1, "the item's")
    eq(S.K.note_mode(moved), "classic", "edited note takes the item's mode")
    eq(S.K.note_mode(untouched), "classic", "the item's mode reaches an untouched note too")
    moved.controls.correct_mode = 0
    eq(S.K.note_mode(moved), nil, "its own Natural wins")
    moved.controls.correct_mode = 2
    eq(S.K.note_mode(moved), "hard")
    moved.controls.bypassed = true
    eq(S.K.note_mode(moved), nil, "bypassed")
  end)
  with_item_mode(7, function() eq(S.K.mode_value(nil), 0, "a bad item mode is Natural") end)
  with_item_mode("2", function() eq(S.K.mode_value(nil), 0, "an item mode stored as a string is Natural") end)
  untouched.controls.correct_mode = 1
  eq(S.K.note_mode(untouched), "classic", "choosing a mode is an edit")
end)

test("mode_carry_merge_clear", function()
  local a, b = join_note(0.1, 0.3, 60, 0), join_note(0.4, 0.3, 62, 0)
  a.controls.correct_mode, b.controls.correct_mode = 2, 1
  eq(S.K.controls_carry(a.controls).correct_mode, 2)
  eq(S.K.controls_merge({ a, b }).correct_mode, 2, "the first note's")
  eq(S.K.controls_clear(a.controls), true); eq(a.controls.correct_mode, nil)
end)

test("mode_unused", function()
  local c, h, n = { controls = { correct_mode = 1 } }, { controls = { correct_mode = 2 } }, { controls = {} }
  eq(S.K.mode_unused("tolerance", { c, h }, 2), "mode")
  eq(S.K.mode_unused("retune_speed", { c, n }, 2), nil)
  eq(S.K.mode_unused("slide_in", {}, 0), nil)
  eq(S.K.mode_unused("tighten", { h, h }, 2), "hard")
  eq(S.K.mode_unused("tighten", { c }, 1), "classic")
  eq(S.K.mode_unused("tighten", { c, h }, 2), nil)
  eq(S.K.mode_unused("separation", { h }, 1), nil)
end)

-- A note from t0 lasting dur. sung: a number, or fn(local_time) -> number | nil. avg: its sung average.
local function mode_note(t0, dur, sung, avg, ctrl)
  local fr = {}
  local nf = math.floor(dur / JHOP + 0.5)
  for i = 1, nf do
    local lt = (i - 1) * JHOP
    local v = sung
    if type(sung) == "function" then v = sung(lt) end
    fr[i] = { time = t0 + lt, note = v }
  end
  local c = { center_pitch = avg, bypassed = false }
  for k, v in pairs(ctrl or {}) do c[k] = v end
  return { start_time = t0, end_time = t0 + nf * JHOP, frames = fr, avg_note = avg, controls = c }
end
local C_MAJOR = { [0] = true, [2] = true, [4] = true, [5] = true, [7] = true, [9] = true, [11] = true }

test("mode_nearest_scale_pitch", function()
  local f = S.K.nearest_scale_pitch
  eq(f(60.4, nil), 60); eq(f(60.6, nil), 61)
  eq(f(60.5, nil), 60, "a tie goes to the lower")
  eq(f(61.4, C_MAJOR), 62); eq(f(61.0, C_MAJOR), 60, "tie in the scale"); eq(f(59.2, C_MAJOR), 59)
  eq(f(61.4, {}), 61, "an empty scale is every semitone")
end)

test("mode_scale_pcs", function()
  local major
  for i, d in ipairs(S.SCALE_DEFINITIONS) do if d.name == "Major" then major = i end end
  local pcs = S.K.scale_pcs(1, major)
  for pc = 0, 11 do eq(pcs[pc] == true, C_MAJOR[pc] == true, "pc " .. pc) end
  eq(S.K.scale_pcs(3, major)[2], true, "the root moves with the key")
  eq(S.K.scale_pcs(1, 999), nil, "unknown scale")
end)

test("mode_line_hard", function()
  local n = mode_note(0.5, 0.3, 60.3, 60.3)
  local shifts, steps = S.K.mode_line(n, "hard", nil)
  eq(#shifts, #n.frames)
  for i = 1, #shifts do near(shifts[i], -0.3, 1e-9, "frame " .. i) end
  eq(next(steps), nil)
  n = mode_note(0.5, 0.3, 60.3, 60.3, { center_pitch = 62.4 })
  near(S.K.mode_line(n, "hard", nil)[1], 62 - 60.3, 1e-9, "follows where the note was moved")
  near(S.K.mode_line(n, "hard", C_MAJOR)[1], 62 - 60.3, 1e-9)
end)

test("mode_line_classic_step", function()
  local n = mode_note(0, 0.2, function(lt) return lt < 0.0975 and 60.2 or 61.2 end, 60.7, { tighten = 1 })
  local shifts, steps = S.K.mode_line(n, "classic", nil)
  near(shifts[20], -0.2, 1e-9); near(shifts[21], -0.2, 1e-9)
  eq(steps[21], true, "a step where the scale note changes")
  eq(steps[20], nil); eq(steps[22], nil)
end)

test("mode_line_classic_glide", function()
  local n = mode_note(0, 0.2, function(lt) return lt < 0.0975 and 60 or 61 end, 60.5)   -- Tighten 0: 100 ms
  local shifts, steps = S.K.mode_line(n, "classic", nil)
  local a = 1 - math.exp(-JHOP / 0.100)
  near(shifts[20], 0, 1e-9)
  near(shifts[21], (60 + a) - 61, 1e-9)
  near(shifts[22], (60 + 1 - (1 - a) ^ 2) - 61, 1e-9)
  eq(next(steps), nil, "a glide writes no step")
end)

test("mode_line_untrusted_frames", function()
  local n = mode_note(0.5, 0.1, 60.3, 60.3)
  n.frames[5].note = 72.3   -- a wrong-octave frame
  n.frames[6].note = nil    -- no pitch
  local shifts = S.K.mode_line(n, "hard", nil)
  near(shifts[5], shifts[4], 1e-12); near(shifts[6], shifts[4], 1e-12)
  local silent = mode_note(0.5, 0.1, nil, 60.3)
  shifts = S.K.mode_line(silent, "classic", nil)
  for i = 1, #shifts do near(shifts[i], 60 - 60.3, 1e-9, "no pitch at all: flat at the scale note") end
  local empty = { start_time = 1, end_time = 1.2, frames = {}, avg_note = 60, controls = { center_pitch = 60 } }
  eq(#(S.K.mode_line(empty, "hard", nil)), 0)
end)

test("mode_scale_pcs_memo_and_cache", function()
  local major
  for i, d in ipairs(S.SCALE_DEFINITIONS) do if d.name == "Major" then major = i end end
  eq(S.K.scale_pcs(1, major), S.K.scale_pcs(1, major), "same table twice")
  eq(S.K.scale_pcs(1, major) ~= S.K.scale_pcs(3, major), true, "a different key is a different table")
  local st = S.state
  local saved = { st.target_take_guid, st.key_idx, st.scale_idx }
  st.target_take_guid, st.key_idx, st.scale_idx = nil, 1, major
  local n = mode_note(0.5, 0.1, 60.3, 60.3)
  local a = S.K.mode_line(n, "hard", S.K.item_scale_pcs())
  local b = S.K.mode_line(n, "hard", S.K.item_scale_pcs())
  st.target_take_guid, st.key_idx, st.scale_idx = saved[1], saved[2], saved[3]
  eq(a, b, "the cache hits for the item's scale")
  n.controls.center_pitch = 62.4
  eq(a ~= S.K.mode_line(n, "hard", S.K.scale_pcs(1, major)), true, "a moved note rebuilds")
end)

local function hard_note(t0, sung, ctrl)
  local c = { correct_mode = 2 }
  for k, v in pairs(ctrl or {}) do c[k] = v end
  return mode_note(t0, 0.3, sung, sung, c)
end
local function chromatic(fn)   -- runs fn with every item on the chromatic scale
  local saved = S.K.item_scale_pcs
  S.K.item_scale_pcs = function() return nil end
  local ok, err = pcall(fn)
  S.K.item_scale_pcs = saved
  if not ok then error(err, 0) end
end
local STEP = 0.0005

test("build_natural_only_is_handed_through", function()
  local saved, seen = S.K.natural_build, nil
  local sentinel = { points = {}, spans = {}, ranges = {} }
  S.K.natural_build = function(notes, item_len) seen = { notes, item_len } return sentinel end
  local notes = { join_note(0.1, 0.3, 60, 0.3) }
  local got = S.K.correction_build(notes, 10)
  S.K.natural_build = saved
  eq(got, sentinel, "Natural's own result"); eq(seen[1], notes, "the same list"); eq(seen[2], 10)
end)

test("build_hard_note", function() chromatic(function()
  local h = hard_note(0.5, 60.3)
  local build = S.K.correction_build({ h }, 10)
  eq(#h.frame_shifts, #h.frames)
  for i = 1, #h.frames do near(h.frame_shifts[i], -0.3, 1e-9) end
  local t1 = h.frames[1].time
  near(point_at(build.points, t1 - STEP).val, 0, 1e-12, "steps in from no correction")
  near(point_at(build.points, t1).val, -0.3, 1e-9)
  near(point_at(build.points, h.end_time - STEP).val, -0.3, 1e-9, "held to the end")
  near(point_at(build.points, h.end_time).val, 0, 1e-12, "steps out")
  eq(#build.ranges, 1); near(build.ranges[1].t0, t1 - STEP, 1e-12); near(build.ranges[1].t1, h.end_time, 1e-12)
  eq(#build.spans, 0)
  eq(h.controls.bypassed, false, "the real note is not changed")
end) end)

test("build_classic_step_point", function() chromatic(function()
  local n = mode_note(0.5, 0.2, function(lt) return lt < 0.0975 and 60.2 or 61.2 end, 60.7,
    { correct_mode = 1, tighten = 1 })
  local build = S.K.correction_build({ n }, 10)
  local t = n.frames[21].time
  near(point_at(build.points, t - STEP).val, n.frame_shifts[20], 1e-12, "holds the old value before the step")
  near(point_at(build.points, t).val, n.frame_shifts[21], 1e-12)
end) end)

test("build_natural_neighbour_keeps_its_side", function() chromatic(function()
  local a = join_note(0.1, 0.3, 60, 0.3)
  local h = hard_note(a.end_time, 62.3)
  local build = S.K.correction_build({ a, h }, 10)
  -- What Natural writes next to a note that is not corrected, built by Natural alone
  local a2, b = join_note(0.1, 0.3, 60, 0.3), hard_note(a.end_time, 62.3)
  b.controls.correct_mode, b.controls.bypassed = nil, true
  local ref = S.K.natural_build({ a2, b }, 10)
  local edge = h.frames[1].time - STEP
  local n_ref = 0
  for _, p in ipairs(ref.points) do
    if p.time < edge then
      n_ref = n_ref + 1
      local q = build.points[n_ref]
      eq(q.time, p.time, "same time " .. n_ref); eq(q.val, p.val, "same value " .. n_ref)
    end
  end
  if n_ref < 3 then error("the reference has no blend to compare") end
  local g = spans_of(build, "glide")
  eq(#g, 1); if g[1].t1 > a.end_time + 1e-9 then error("the blend crosses into the Hard note") end
  eq(a.frame_shifts[1], a2.frame_shifts[1], "Natural's own shifts")
end) end)

test("build_adjacent_mode_notes_hold", function() chromatic(function()
  local h1 = hard_note(0.5, 60.3)
  local h2 = hard_note(h1.end_time, 62.4)
  local build = S.K.correction_build({ h1, h2 }, 10)
  local t2 = h2.frames[1].time
  near(point_at(build.points, t2 - STEP).val, -0.3, 1e-9, "held across")
  near(point_at(build.points, t2).val, 62 - 62.4, 1e-9, "one step")
  for _, p in ipairs(build.points) do
    if p.time > h1.frames[1].time and p.time < h2.end_time - STEP and math.abs(p.val) < 1e-9 then
      error("returns to no correction between the notes at " .. p.time)
    end
  end
  eq(#build.ranges, 1, "one merged range")
end) end)

test("build_mode_note_at_item_edges", function() chromatic(function()
  local h = mode_note(0, 0.2, 60.3, 60.3, { correct_mode = 2 })
  local build = S.K.correction_build({ h }, 0.2)
  for _, p in ipairs(build.points) do
    if p.time < 0 or p.time > 0.2 then error("point outside the item at " .. p.time) end
  end
  local empty = { start_time = 1, end_time = 1.2, frames = {}, avg_note = 60,
                  controls = { center_pitch = 60, correct_mode = 2, bypassed = false } }
  build = S.K.correction_build({ empty }, 10)
  eq(#build.points, 0, "a note without frames writes nothing")
end) end)

test("build_item_mode_reaches_every_note", function() chromatic(function()
  with_item_mode(2, function()
    local moved, untouched = mode_note(0.1, 0.3, 60.3, 60.3, { center_pitch = 61.3 }), mode_note(1, 0.3, 60.3, 60.3)
    S.K.correction_build({ moved, untouched }, 10)
    near(moved.frame_shifts[1], 61 - 60.3, 1e-9, "Hard, around where it was moved")
    near(untouched.frame_shifts[1], 60 - 60.3, 1e-9, "the untouched note is Hard too")
  end)
end) end)

local function sorted_by_time(points)
  local p = {}
  for i, q in ipairs(points) do p[i] = q end
  table.sort(p, function(a, b) return a.time < b.time end)
  return p
end
local function no_close_points(points, msg)
  local p = sorted_by_time(points)
  for i = 2, #p do
    if p[i].time - p[i - 1].time < 0.0001 then error((msg or "") .. ": two points closer than 0.1 ms at " .. p[i].time) end
  end
end

test("build_mode_then_later_natural_is_written_as_built", function() chromatic(function()
  local build = S.K.correction_build({ hard_note(0.5, 60.3), join_note(2.0, 0.3, 60, 1) }, 10)
  local simplified = sorted_by_time(S.rdp_simplify(build.points, 0.01))
  near(simplified[1].val, 0, 1e-12, "starts with no correction")
  near(simplified[1].time, 0.5 - STEP, 1e-9, "at the step in")
  near(value_at(simplified, 0.25), 0, 1e-12, "nothing before the Hard note")
  near(value_at(simplified, 0.6), -0.3, 1e-9, "the Hard note")
end) end)

test("build_points_keep_time_order", function() chromatic(function()
  local function notes_of(bypass)
    local list = { hard_note(0.5, 60.3), join_note(1.5, 0.3, 60, 1), hard_note(2.5, 62.4), join_note(3.5, 0.3, 64, -1) }
    if bypass then
      for _, i in ipairs({ 1, 3 }) do list[i].controls.correct_mode, list[i].controls.bypassed = nil, true end
    end
    return list
  end
  local notes = notes_of(false)
  local build = S.K.correction_build(notes, 10)
  for i = 2, #build.points do
    if build.points[i].time < build.points[i - 1].time then error("time goes back at point " .. i) end
  end
  local ref = S.K.natural_build(notes_of(true), 10)
  local function in_mode_note(t)
    for _, i in ipairs({ 1, 3 }) do
      if t >= notes[i].start_time - 0.01 and t <= notes[i].end_time + 0.01 then return true end
    end
    return false
  end
  local q, n_ref = 1, 0
  for _, p in ipairs(ref.points) do
    if not in_mode_note(p.time) then
      n_ref = n_ref + 1
      while build.points[q] and not (build.points[q].time == p.time and build.points[q].val == p.val) do q = q + 1 end
      if not build.points[q] then error("Natural's point " .. n_ref .. " is missing or out of order") end
      q = q + 1
    end
  end
  if n_ref < 4 then error("the reference has no Natural points to compare") end
end) end)

test("build_mode_note_at_item_start_is_flat", function() chromatic(function()
  local h = mode_note(0, 0.2, 60.3, 60.3, { correct_mode = 2 })
  local build = S.K.correction_build({ h }, 0.2)
  local simplified = sorted_by_time(S.rdp_simplify(build.points, 0.01))
  for _, t in ipairs({ 0, 0.05, 0.1, 0.15 }) do near(value_at(simplified, t), -0.3, 1e-9, "flat at " .. t) end
  no_close_points(build.points, "raw build")
end) end)

test("build_mode_note_at_item_end_has_no_shared_time", function() chromatic(function()
  local h = hard_note(0.5, 60.3)
  local build = S.K.correction_build({ h }, h.end_time)
  no_close_points(build.points, "raw build")
  build = S.K.correction_build({ h }, h.end_time - STEP - 0.0002)   -- the note runs just past the item end
  no_close_points(build.points, "note past the item end")
end) end)

test("mode_note_count", function()
  local a, b, c = join_note(0.1, 0.3, 60, 0.3), join_note(0.5, 0.3, 60, 0.3), untouched_note(0.9)
  a.controls.correct_mode = 1
  eq(S.K.mode_note_count({ a, b, c }), 1)
  with_item_mode(2, function() eq(S.K.mode_note_count({ a, b, c }), 3, "the item's mode reaches every note") end)
  eq(S.K.mode_note_count({}), 0)
end)

test("zone_text_mode_suffix", function()
  local zc = S.K.ZONE_CONTROLS
  local tol, tight, slide = zc.tolerance[false], zc.tighten[false], zc.tolerance[true]
  local n = join_note(0.1, 0.3, 60, 0.3)
  n.controls.tighten, n.controls.tolerance = 0.5, 8
  local natural_tol, natural_tight = S.K.zone_text(tol, n, false), S.K.zone_text(tight, n, false)
  n.controls.correct_mode = 1
  eq(S.K.zone_text(tol, n, false), natural_tol .. " (not used in Classic or Hard mode)")
  eq(S.K.zone_text(slide, n, false):sub(-#S.K.MODE_IDLE), " (not used in Classic or Hard mode)")
  eq(S.K.zone_text(tight, n, false), natural_tight, "Tighten acts in Classic")
  n.controls.correct_mode = 2
  eq(S.K.zone_text(tight, n, false), natural_tight .. " (not used in Hard mode)")
  n.controls.correct_mode, n.controls.tighten = 1, nil
  eq(S.K.zone_text(tol, n, false):find("used once Tighten", 1, true), nil, "the Natural advice is not given")
end)

test("build_uses_the_takes_own_key_and_scale", function()
  local st = S.state
  local major
  for i, sc in ipairs(S.SCALE_DEFINITIONS) do if sc.name == "Major" then major = i end end
  local chrom = #S.SCALE_DEFINITIONS
  eq(S.SCALE_DEFINITIONS[chrom].name, "Chromatic")
  local saved = { st.target_take_guid, st.session_takes["{KS}"], st.key_idx, st.scale_idx }
  local function shift_with(take_scale, combo_key, combo_scale)
    st.target_take_guid = "{KS}"
    st.session_takes["{KS}"] = { key_idx = 1, scale_idx = take_scale }
    st.key_idx, st.scale_idx = combo_key, combo_scale
    local h = hard_note(0.5, 61.4)
    S.K.correction_build({ h }, 10)
    return h.frame_shifts[1]
  end
  local ok, err = pcall(function()
    near(shift_with(major, 3, chrom), 62 - 61.4, 1e-9, "the take's C Major, not the combos' Chromatic")
    near(shift_with(chrom, 1, major), 61 - 61.4, 1e-9, "the take's Chromatic, not the combos' C Major")
  end)
  st.target_take_guid, st.session_takes["{KS}"], st.key_idx, st.scale_idx = saved[1], saved[2], saved[3], saved[4]
  if not ok then error(err, 0) end
end)

test("build_written_equals_built", function() chromatic(function()
  local seed = 20261123   -- a small LCG of its own: no math.random state is used or left behind
  local function rand() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
  local function pick(list) return list[1 + math.floor(rand() * #list)] end
  for case = 1, 200 do
    local notes, t = {}, pick({ 0, 0.1, 0.3 })
    for i = 1, 1 + math.floor(rand() * 6) do
      local centre, kind = 55 + math.floor(rand() * 12) + 0.8 * rand() - 0.4, pick({ "natural", "classic", "classic", "hard" })
      local n
      if kind == "natural" then
        n = join_note(t, pick({ 0.1, 0.3 }), centre, rand() - 0.5)
      else
        local wob, slide = 0.6 * rand(), pick({ 0, 0, 1.5, -2 })
        local function sung(lt)
          local v = centre + wob * math.sin(2 * math.pi * 5.5 * lt)
          if slide ~= 0 and lt < 0.06 then v = v - slide * (1 - lt / 0.06) end
          return v
        end
        local tighten = pick({ 0, 0.3, 0.8, 1 })
        n = mode_note(t, pick({ 0.1, 0.25, 0.4 }), sung, centre, { correct_mode = kind == "classic" and 1 or 2,
          tighten = tighten > 0 and tighten or nil, center_pitch = centre + pick({ 0, 0, 2 * rand() - 1 }) })
      end
      notes[i] = n
      t = n.end_time + pick({ 0, 0, 0.02, 0.059, 0.2 })
    end
    local build = S.K.correction_build(notes, t + 1)
    local written = sorted_by_time(S.rdp_simplify(build.points, 0.01))
    local at = {}   -- raw values by time: Natural stacks its fade-in at 0 for a note at the item start (as on main)
    for _, p in ipairs(build.points) do at[p.time] = at[p.time] or {}; table.insert(at[p.time], p.val) end
    for i, p in ipairs(build.points) do
      if i > 1 and p.time < build.points[i - 1].time then error("case " .. case .. ": time goes back at point " .. i) end
      local got, hit = value_at(written, p.time), false
      for _, v in ipairs(at[p.time]) do hit = hit or math.abs(got - v) <= 0.0101 end
      if #at[p.time] == 1 then near(got, p.val, 0.0101, "case " .. case .. " at " .. p.time)
      elseif not hit then error("case " .. case .. ": no built value of the stack at " .. p.time .. " is written") end
    end
  end
end) end)

-- Amendment 1: one colour per value (the script's Theme is the module its require() loaded)
test("param_color_keys", function()
  local P = package.loaded["theme"].get_palette()
  local want = { tighten = "param_tighten", retune_speed = "param_strength", tolerance = "param_tolerance",
                 slide_in = "param_slide_in" }
  local seen = {}
  for key, ckey in pairs(want) do
    eq(S.K.PARAM_COLOR_KEYS[key], ckey, "colour key of " .. key)
    local c = S.K.param_color(key)
    eq(type(c), "number", "colour of " .. key)
    eq(c, P.canvas[ckey], "colour of " .. key)
    for other, oc in pairs(seen) do
      if oc == c then error(key .. " and " .. other .. " share a colour") end
    end
    seen[key] = c
  end
  eq(S.K.param_color("separation"), P.accent, "an unknown key takes the accent")
  -- The washes come from the palette hue itself, not the fitted edge colour
  local Theme = package.loaded["theme"]
  local hue = { tighten = P.green, retune_speed = P.accent, tolerance = P.yellow, slide_in = P.orange }
  for key, c in pairs(hue) do eq(S.K.param_wash(key, 0.27), Theme.with_alpha(c, 0.27), "wash of " .. key) end
  eq(S.K.param_wash("separation", 0.27), Theme.with_alpha(P.accent, 0.27), "an unknown key washes in the accent")
end)

test("value_track_draws_track_then_fill", function()
  local orig = reaper.ImGui_DrawList_AddRectFilled
  local rects = {}
  reaper.ImGui_DrawList_AddRectFilled = function(_, x1, y1, x2, y2, col)
    rects[#rects + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, col = col }
  end
  local ok, err = pcall(function()
    S.K.value_track("dl", 100, 200, 50, 0, 0.25, 0xFF)
    eq(#rects, 2, "track and fill")
    eq(rects[1].x1, 100, "track x1"); eq(rects[1].x2, 200, "track x2"); eq(rects[1].y2, 50, "track y2")
    eq(rects[2].x1, 100, "fill x1"); eq(rects[2].x2, 125, "fill x2"); eq(rects[2].y2, 50, "fill y2")
    eq(rects[2].col, 0xFF, "fill colour")
    rects = {}
    S.K.value_track("dl", 100, 200, 50, 0, 0, 0xFF)
    eq(#rects, 1, "an empty value: the track only")
    rects = {}
    S.K.value_track("dl", 100, 200, 50, -0.5, 1.5, 0xFF)
    eq(#rects, 2, "held: track and fill")
    eq(rects[2].x1, 100, "held fill x1"); eq(rects[2].x2, 200, "held fill x2")
  end)
  reaper.ImGui_DrawList_AddRectFilled = orig
  if not ok then error(err, 0) end
end)

-- Octave errors (K.octave_fix) ------------------------------------------------------------------

local OHOP = 512 / 48000
-- list: runs of { frame count, pitch | nil }; returns result frames (freq follows the pitch)
local function oct_frames(list, hop)
  local out = {}
  for _, r in ipairs(list) do
    for _ = 1, r[1] do
      local note = r[2]
      out[#out + 1] = { time = #out * (hop or OHOP), note = note, rms = 0.1, lvl = 0.1,
        freq = note and 440 * 2 ^ ((note - 69) / 12) or nil }
    end
  end
  return out
end
local function all_near(fr, want, tol, msg)
  for i, f in ipairs(fr) do if f.note then near(f.note, want, tol, msg .. " frame " .. i) end end
end

test("octave_fix_drop_in_note", function()   -- the verse: 2 of 27 frames one octave down
  local fr = oct_frames({ { 5, 58.8 }, { 2, 47.0 }, { 20, 58.8 } })
  eq(S.K.octave_fix(fr), 2, "frames changed")
  all_near(fr, 58.8, 0.21, "pitch")
  near(fr[6].note, 59.0, 1e-9, "moved by exactly 12")
  near(fr[6].freq, 440 * 2 ^ ((59.0 - 69) / 12), 1e-6, "freq follows")
end)

test("octave_fix_spikes_in_held_note", function()   -- the chorus: many short runs one octave up
  local fr = oct_frames({ { 7, 66.3 }, { 4, 78.3 }, { 9, 66.3 }, { 8, 78.4 }, { 19, 66.3 }, { 5, 78.4 }, { 26, 66.3 },
    { 4, 78.4 }, { 2, 66.3 }, { 1, 78.4 }, { 5, 66.3 }, { 2, 78.4 }, { 30, 66.3 } })
  eq(S.K.octave_fix(fr), 24, "frames changed")
  all_near(fr, 66.3, 0.11, "pitch")
end)

test("octave_fix_spike_on_a_slide", function()
  local fr = oct_frames({ { 30, 60 } })
  for i, f in ipairs(fr) do f.note = 64.5 + 1.8 * (i - 1) / 29 end
  for i = 12, 15 do fr[i].note = fr[i].note + 12 end
  eq(S.K.octave_fix(fr), 4, "frames changed")
  for i, f in ipairs(fr) do near(f.note, 64.5 + 1.8 * (i - 1) / 29, 1e-9, "on the slide, frame " .. i) end
end)

test("octave_fix_at_phrase_start_and_end", function()
  local fr = oct_frames({ { 3, nil }, { 2, 48 }, { 30, 60 }, { 3, 72 }, { 3, nil } })
  eq(S.K.octave_fix(fr), 5, "frames changed")
  all_near(fr, 60, 1e-9, "pitch")
end)

test("octave_fix_spike_left_by_a_glide", function()   -- 01_Vox1 at 193.84: down 12.4 st, back up only 10.7 st
  local fr = oct_frames({ { 30, 60 } })
  for i, f in ipairs(fr) do f.note = 62 + (i <= 12 and 0 or 1.7) end
  fr[11].note, fr[12].note = 62 - 12.4, 62 - 12.4 + 0.2
  eq(S.K.octave_fix(fr), 2, "frames changed")
  near(fr[11].note, 61.6, 1e-9, "put back by an octave")
  near(fr[12].note, 61.8, 1e-9, "put back by an octave")
  -- the same return long after the jump down is a sung leap, not a return: the jump down does not count either way
  local held = oct_frames({ { 40, 60 } })
  for x = 21, 40 do held[x].note = x <= 36 and 48 or 58.7 end
  eq(S.K.octave_fix(held), 0, "a return after 171 ms is judged with JUMP_TOL_ST")
  -- a jump into the wrong octave still needs JUMP_TOL_ST
  local enter = oct_frames({ { 20, 60 }, { 3, 70.5 }, { 20, 60 } })
  eq(S.K.octave_fix(enter), 0, "a 10.5 st jump up is not an octave")
end)

test("octave_fix_two_octaves", function()
  local fr = oct_frames({ { 20, 60 }, { 3, 84 }, { 20, 60 } })
  eq(S.K.octave_fix(fr), 3, "frames changed")
  all_near(fr, 60, 1e-9, "pitch")
end)

test("octave_fix_keeps_real_leaps", function()
  local held = oct_frames({ { 40, 60 }, { 40, 72 } })
  eq(S.K.octave_fix(held), 0, "a held octave leap")
  local visit = oct_frames({ { 40, 60 }, { 16, 72 }, { 40, 60 } })   -- 16 frames = 171 ms, longer than MAX_RUN_S
  eq(S.K.octave_fix(visit), 0, "an octave held for 171 ms")
  eq(visit[45].note, 72, "untouched")
  local fifth = oct_frames({ { 20, 60 }, { 3, 67 }, { 20, 60 } })
  eq(S.K.octave_fix(fifth), 0, "a jump that is not an octave")
  local gap = oct_frames({ { 20, 60 }, { 2, nil }, { 3, 72 }, { 2, nil }, { 20, 60 } })
  eq(S.K.octave_fix(gap), 0, "a stretch between two unvoiced gaps is judged alone")
  local tie = oct_frames({ { 5, 60 }, { 5, 72 } })
  eq(S.K.octave_fix(tie), 0, "equal halves: no way to tell, nothing changes")
end)

test("octave_fix_any_hop_and_idempotent", function()
  for _, hop in ipairs({ 256 / 48000, 512 / 48000, 256 / 44100 }) do
    local wrong = math.floor(0.06 / hop)   -- 60 ms one octave up inside a 0.5 s note
    local side = math.floor(0.22 / hop)
    local fr = oct_frames({ { side, 60 }, { wrong, 72 }, { side, 60 } }, hop)
    eq(S.K.octave_fix(fr), wrong, "frames changed at hop " .. hop)
    all_near(fr, 60, 1e-9, "pitch at hop " .. hop)
    eq(S.K.octave_fix(fr), 0, "a second run changes nothing at hop " .. hop)
  end
end)

test("octave_fix_degenerate", function()
  eq(S.K.octave_fix({}), 0, "no frames")
  eq(S.K.octave_fix(oct_frames({ { 1, 60 } })), 0, "one frame")
  eq(S.K.octave_fix(oct_frames({ { 20, nil } })), 0, "no pitch at all")
  local same = oct_frames({ { 10, 60 }, { 2, 72 }, { 10, 60 } })
  for _, f in ipairs(same) do f.time = 0 end
  eq(S.K.octave_fix(same), 0, "equal times")
end)

test("octave_fix_only_moves_frames_that_get_closer", function()
  -- A note onset: only 52.2 is an octave off. It is reached by a jump that is not an octave, so the two frames before
  -- it share its octave class; they must stay where they are
  local onset = oct_frames({ { 3, nil }, { 1, 69.2 }, { 1, 68.2 }, { 1, 52.2 }, { 17, 64.0 }, { 2, nil } })
  eq(S.K.octave_fix(onset), 1, "onset: frames changed")
  eq(onset[4].note, 69.2, "onset: first frame untouched")
  eq(onset[5].note, 68.2, "onset: second frame untouched")
  near(onset[6].note, 64.2, 1e-9, "onset: the octave-off frame is put back")
  -- A right pickup before a wrong stretch that is left by a jump that is not an octave: the pickup stays
  local pickup = oct_frames({ { 1, nil }, { 10, 60 }, { 4, 72 }, { 60, 62.5 } })
  eq(S.K.octave_fix(pickup), 0, "pickup: frames changed")
  eq(pickup[2].note, 60, "pickup: untouched")
  -- A wrong stretch followed by a right tail in the same class: the stretch moves, the tail stays
  local tail = oct_frames({ { 40, 60 }, { 4, 72 }, { 8, 62.5 }, { 1, nil } })
  eq(S.K.octave_fix(tail), 4, "tail: frames changed")
  near(tail[41].note, 60, 1e-9, "tail: the wrong stretch is put back")
  eq(tail[45].note, 62.5, "tail: untouched")
end)

test("octave_fix_needs_enough_frames_to_trust", function()
  -- A three-frame scrap (the verse at 17.6 s): two frames are no majority to move the third by
  local scrap = oct_frames({ { 2, nil }, { 1, 58.4 }, { 1, 45.0 }, { 1, 56.6 }, { 2, nil } })
  eq(S.K.octave_fix(scrap), 0, "scrap: frames changed")
  -- Three frames (32 ms at this hop) are enough
  local enough = oct_frames({ { 2, nil }, { 3, 60 }, { 1, 72 }, { 2, nil } })
  eq(S.K.octave_fix(enough), 1, "enough: frames changed")
  near(enough[6].note, 60, 1e-9, "enough: put back")
end)

test("octave_fix_real_items", function()   -- this machine only: the two takes of the 2026-11-23 report
  local json = loadfile("_lib/json.lua")()
  local function model(name)
    local f = io.open(FIXTURE_DIR .. name, "rb")
    if not f then return nil end
    local data = json.decode(f:read("a"))
    f:close()
    return data
  end
  local verse, chorus = model("octave_verse_model.json"), model("octave_chorus_model.json")
  if not verse or not chorus then print("SKIP octave_fix_real_items (no local fixture)") return end
  -- No changed frame may end further from the frames around it (the middle pitch of up to 5 voiced frames each side,
  -- after the fix) than it started
  local function fix_checked(results, what)
    local before = {}
    for i, f in ipairs(results) do before[i] = f.note end
    local changed = S.K.octave_fix(results)
    for i, f in ipairs(results) do
      if f.note ~= before[i] then
        local around = {}
        for d = 1, 5 do
          for _, x in ipairs({ i - d, i + d }) do
            if results[x] and results[x].note then around[#around + 1] = results[x].note end
          end
        end
        table.sort(around)
        local mid = around[(#around + 1) // 2]
        if mid and math.abs(f.note - mid) > math.abs(before[i] - mid) then
          error(string.format("%s frame at %.3f moved away from its neighbours: %.1f -> %.1f (around %.1f)",
            what, f.time, before[i], f.note, mid), 0)
        end
      end
    end
    return changed
  end
  fix_checked(verse.results, "verse")
  for _, f in ipairs(verse.results) do
    if f.time > 0.90 and f.time < 0.92 then near(f.note, 59.0, 0.5, "verse frame at " .. f.time) end
    -- the onset at 11.79 s: 69.2 and 68.2 are right and stay; 52.2 is an octave off
    if f.time > 11.78 and f.time < 11.80 then near(f.note, 68.7, 0.6, "verse onset frame at " .. f.time) end
    if f.time > 11.80 and f.time < 11.81 then near(f.note, 64.2, 0.1, "verse onset frame at " .. f.time) end
  end
  eq(fix_checked(chorus.results, "chorus"), 40, "chorus frames changed")
  for _, f in ipairs(chorus.results) do
    if f.time > 0.30 and f.time < 3.19 then near(f.note, 66.3, 1.5, "chorus frame at " .. f.time) end
  end
end)

-- Note centre (extract_note_features step 4) ------------------------------------------------------

local function centre_note(pitches, rms)
  local fr = {}
  for i, p in ipairs(pitches) do fr[i] = { time = (i - 1) * OHOP, note = p, rms = rms and rms[i] or 0.1 } end
  return { start_time = 0, end_time = #fr * OHOP, frames = fr, count = #fr }
end
-- The centre as v2.19.0 computed it: the energy-weighted mean of the raw frames of the core
local function old_centre(note)
  local nf = #note.frames
  local sum, w_sum = 0, 0
  for i = math.max(1, math.floor(nf * 0.12)), math.min(nf, math.ceil(nf * 0.88)) do
    local f = note.frames[i]
    local w = math.max(0.0001, (f.rms or 0.05))
    sum, w_sum = sum + f.note * w, w_sum + w
  end
  return sum / w_sum
end

test("centre_ignores_octave_frames", function()
  local p = {}
  for i = 1, 27 do p[i] = (i == 6 or i == 7) and 47.0 or 58.8 end
  local note = centre_note(p)
  S.extract_note_features(note)
  near(note.avg_note, 58.8, 1e-9, "centre")
  eq(note.display_note, 59, "display note")
end)

test("centre_clean_note_unchanged", function()
  local p, rms = {}, {}
  for i = 1, 40 do p[i], rms[i] = 60 + 0.3 * math.sin(i), 0.05 + 0.01 * i end
  local note = centre_note(p, rms)
  local want = old_centre(note)
  S.extract_note_features(note)
  eq(note.avg_note, want, "bit for bit the old centre")
end)

test("centre_split_core_stays_finite", function()
  local note = centre_note({ 47, 47, 59.2, 59.2 })
  S.extract_note_features(note)
  near(note.avg_note, 47, 1e-9, "the lower of the two middle pitches decides")
end)

test("centre_real_only_outlier_notes_move", function()   -- this machine only
  local f = io.open(FIXTURE_DIR .. "pitch_real_model.json", "rb")
  if not f then print("SKIP centre_real_only_outlier_notes_move (no local fixture)") return end
  local data = loadfile("_lib/json.lua")().decode(f:read("a"))
  f:close()
  local moved = 0
  for _, note in ipairs(data.notes) do
    note.count = #note.frames
    local want = old_centre(note)
    S.extract_note_features(note)
    if note.avg_note ~= want then moved = moved + 1 end
  end
  eq(moved, 4, "notes whose centre moved (2, 4, 17 and 32 hold octave-wrong frames)")
end)

test("analysis_fixes_octaves_before_splitting", function()   -- what an analysis runs when its last frame is read
  local st = S.state
  local saved = { st.results, st.notes, st.split_points, st.separation }
  st.results = oct_frames({ { 3, nil }, { 5, 58.8 }, { 2, 47.0 }, { 40, 58.8 }, { 3, nil } })
  st.separation = 0.5
  local ok, err = pcall(function()
    S.run_hybrid_segmentation()
    near(st.results[9].note, 59.0, 1e-9, "the stored frames are fixed")
    eq(#st.notes, 1, "notes")
    near(st.notes[1].avg_note, 58.8, 0.05, "the note's centre")
  end)
  st.results, st.notes, st.split_points, st.separation = table.unpack(saved, 1, 4)
  if not ok then error(err, 0) end
end)

-- Choosing the period across frames (K.pitch_track) ------------------------------------------------

local TSR = 48000
-- list: runs of { frame count, candidates | nil }; candidates: { { tau, d }, ... } (d: how badly the sound repeats
-- at that period, 0 = perfectly). Returns result frames with `cands`
local function track_frames(list, hop)
  local out = {}
  for _, r in ipairs(list) do
    for _ = 1, r[1] do
      local cands
      if r[2] then
        cands = {}
        for i, c in ipairs(r[2]) do cands[i] = { tau = c[1], d = c[2] } end
      end
      out[#out + 1] = { time = #out * (hop or OHOP), cands = cands, rms = 0.1, lvl = 0.1 }
    end
  end
  return out
end
local function tau_of(f) return f.freq and TSR / f.freq or nil end

test("track_prefers_the_far_deeper_dip", function()   -- the chorus: half the period passes the threshold, barely
  local fr = track_frames({ { 30, { { 64, 0.07 }, { 128, 0.001 }, { 192, 0.075 }, { 256, 0.002 }, { 384, 0.003 } } } })
  S.K.pitch_track(fr, TSR)
  for i, f in ipairs(fr) do near(tau_of(f), 128, 1e-9, "frame " .. i) end
  near(fr[1].note, 69 + 12 * math.log(375 / 440, 2), 1e-9, "note follows freq")
end)

test("track_keeps_the_period_at_a_shaky_onset", function()   -- the verse: the double period is deeper by a hair
  local fr = track_frames({ { 5, { { 190, 0.02 }, { 380, 0.025 } } },
    { 2, { { 94, 0.332 }, { 190, 0.117 }, { 286, 0.336 }, { 384, 0.109 }, { 478, 0.36 } } },
    { 20, { { 190, 0.01 }, { 380, 0.012 } } } })
  S.K.pitch_track(fr, TSR)
  for i, f in ipairs(fr) do near(tau_of(f), 190, 1e-9, "frame " .. i) end
  -- the first frame of a phrase, the double period clearly deeper (the verse at 5.58 s)
  local first = track_frames({ { 3, nil }, { 1, { { 232, 0.177 }, { 463, 0.073 } } }, { 20, { { 232, 0.02 }, { 464, 0.03 } } } })
  S.K.pitch_track(first, TSR)
  near(tau_of(first[4]), 232, 1e-9, "phrase start")
end)

test("track_follows_a_real_octave_leap", function()
  local fr = track_frames({ { 20, { { 256, 0.005 }, { 512, 0.006 } } },
    { 20, { { 128, 0.004 }, { 256, 0.006 }, { 384, 0.006 } } } })
  S.K.pitch_track(fr, TSR)
  for i = 1, 20 do near(tau_of(fr[i]), 256, 1e-9, "low frame " .. i) end
  for i = 21, 40 do near(tau_of(fr[i]), 128, 1e-9, "high frame " .. i) end
end)

test("track_follows_a_glide", function()
  local fr = track_frames({ { 21, { { 200, 0.01 } } } })
  for i, f in ipairs(fr) do f.cands = { { tau = 200 - (i - 1), d = 0.01 }, { tau = 2 * (200 - (i - 1)), d = 0.012 } } end
  S.K.pitch_track(fr, TSR)
  for i, f in ipairs(fr) do near(tau_of(f), 200 - (i - 1), 1e-9, "frame " .. i) end
end)

test("track_neighbours_decide_a_doubtful_frame", function()
  local doubtful = { { 128, 0.30 }, { 256, 0.10 } }   -- alone, the double period is the better reading
  local alone = track_frames({ { 3, nil }, { 1, doubtful }, { 3, nil } })
  S.K.pitch_track(alone, TSR)
  near(tau_of(alone[4]), 256, 1e-9, "alone")
  local among = track_frames({ { 10, { { 128, 0.01 }, { 256, 0.01 } } }, { 1, doubtful }, { 10, { { 128, 0.01 }, { 256, 0.01 } } } })
  S.K.pitch_track(among, TSR)
  for i, f in ipairs(among) do near(tau_of(f), 128, 1e-9, "among, frame " .. i) end
end)

test("track_gaps_and_leftovers", function()
  local fr = track_frames({ { 2, nil }, { 6, { { 128, 0.01 }, { 256, 0.012 } } }, { 8, nil }, { 6, { { 300, 0.01 } } }, { 2, nil } })
  eq(S.K.pitch_track(fr, TSR), 12, "frames given a pitch")
  eq(fr[1].note, nil, "an unvoiced frame has no pitch"); eq(fr[1].freq, nil, "nor a freq")
  near(tau_of(fr[3]), 128, 1e-9, "first stretch"); near(tau_of(fr[17]), 300, 1e-9, "after the gap")
  for i, f in ipairs(fr) do eq(f.cands, nil, "candidates are not kept, frame " .. i) end
  eq(S.K.pitch_track(fr, TSR), 0, "a second run has nothing to do")
  near(tau_of(fr[3]), 128, 1e-9, "and leaves the pitch alone")
end)

test("track_degenerate", function()
  eq(S.K.pitch_track({}, TSR), 0, "no frames")
  local one = track_frames({ { 1, { { 128, 0.01 } } } })
  eq(S.K.pitch_track(one, TSR), 1, "one frame"); near(tau_of(one[1]), 128, 1e-9, "its only candidate")
  local same = track_frames({ { 5, { { 128, 0.01 }, { 256, 0.012 } } } })
  for _, f in ipairs(same) do f.time = 0 end
  eq(S.K.pitch_track(same, TSR), 5, "equal times"); near(tau_of(same[3]), 128, 1e-9, "still the period")
  local empty = track_frames({ { 3, {} } })
  eq(S.K.pitch_track(empty, TSR), 0, "empty candidate lists"); eq(empty[1].note, nil, "no pitch")
end)

test("track_any_hop", function()
  for _, hop in ipairs({ 256 / 48000, 512 / 48000, 1024 / 48000 }) do
    local n = math.floor(0.2 / hop)
    local fr = track_frames({ { n, { { 128, 0.01 }, { 256, 0.01 } } }, { math.max(1, math.floor(0.012 / hop)), { { 128, 0.30 }, { 256, 0.10 } } },
      { n, { { 128, 0.01 }, { 256, 0.01 } } } }, hop)
    S.K.pitch_track(fr, TSR)
    for i, f in ipairs(fr) do near(tau_of(f), 128, 1e-9, "hop " .. hop .. " frame " .. i) end
  end
end)

-- Reads what the detector had to choose from, per frame: the recordings of 2026-11-23 and the files the developer
-- switch writes (K.dump_text). Columns are found by the names in the header line; a file without a "lvl" column has
-- the frame's rms as its level. Returns the frames { time, rms, lvl, cands = { { tau, d } ... } | nil }
local function diag_parse(text)
  local out, col = {}, nil
  for line in text:gmatch("[^\n]+") do
    if not line:match("^#") then
      local cols = {}
      for cell in (line .. "\t"):gmatch("(.-)\t") do cols[#cols + 1] = cell end
      if not col then
        col = {}
        for i, name in ipairs(cols) do col[name] = i end
      else
        local fr = { time = tonumber(cols[col.time]), rms = tonumber(cols[col.rms]) }
        fr.lvl = col.lvl and tonumber(cols[col.lvl]) or fr.rms
        if cols[col.how] ~= "unvoiced" then
          fr.cands = {}
          for tau, d in (cols[col.dips] or ""):gmatch("([%d%.]+):([%d%.]+)") do
            fr.cands[#fr.cands + 1] = { tau = tonumber(tau), d = tonumber(d) }
          end
        end
        out[#out + 1] = fr
      end
    end
  end
  return out
end
-- This machine only: what the detector had to choose from on the two reported items, recorded in real REAPER on
-- 2026-11-23 (per frame: every dip of the difference function). Returns the frames, or nil
local function diag_frames(name)
  local f = io.open(FIXTURE_DIR .. "detector-diag-2026-11-23/" .. name, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return diag_parse(text)
end
-- How many frames read more than 6 st from the middle pitch of the 12 frames each side (octave errors, mostly)
local function frames_off(fr)
  local off = 0
  for i, f in ipairs(fr) do
    if f.note then
      local around = {}
      for x = math.max(1, i - 12), math.min(#fr, i + 12) do
        if x ~= i and fr[x].note then around[#around + 1] = fr[x].note end
      end
      if #around >= 6 then
        table.sort(around)
        if math.abs(f.note - around[(#around + 1) // 2]) > 6 then off = off + 1 end
      end
    end
  end
  return off
end

test("track_real_items", function()
  local chorus, verse = diag_frames("diag_Chorus_Error_b1024_th0.08.tsv"), diag_frames("diag_V_Main_Verse_1_b1024_th0.08.tsv")
  if not chorus or not verse then print("SKIP track_real_items (no local fixture)") return end
  S.K.pitch_track(chorus, TSR)
  S.K.pitch_track(verse, TSR)
  local c, v = frames_off(chorus), frames_off(verse)
  -- With the old choice: chorus 41, verse 32. What is left (chorus 1, verse 21 when this was written) is unchanged
  -- readings: quiet falling tails at phrase ends, one real high blip at 11.75 s and the junk at the items' ends
  if c > 2 then error("chorus: " .. c .. " frames off", 0) end
  if v > 23 then error("verse: " .. v .. " frames off", 0) end
end)

-- The detector on one block (yin_process_block) --------------------------------------------------------

local YP = { block_size = 1024, threshold = 0.08, min_freq = 65, max_freq = 1000 }
-- A block of `fn(t)` (t in seconds from the block's start) at 48 kHz
local function block_of(fn)
  local s = {}
  for i = 1, YP.block_size do s[i] = fn((i - 1) / TSR) end
  return s
end
local function tone(freq, a1, a2, a3)
  return function(t)
    local ph = 2 * math.pi * freq * t
    return (a1 or 1) * math.sin(ph) + (a2 or 0) * math.sin(2 * ph) + (a3 or 0) * math.sin(3 * ph)
  end
end

test("yin_reads_a_plain_tone", function()
  local rms, freq, lvl, cands = S.yin_process_block(block_of(tone(220, 1, 0.5, 0.3)), TSR, YP)
  near(freq, 220, 0.5, "freq")
  if not (rms > 0 and lvl > 0) then error("levels") end
  if not (#cands >= 2 and #cands <= S.K.TRACK.MAX_CANDS) then error("candidates: " .. #cands) end
  for i, c in ipairs(cands) do
    if c.d >= S.K.TRACK.CAND_MAX_D then error("candidate " .. i .. " too shallow: " .. c.d) end
    if i > 1 and c.tau <= cands[i - 1].tau then error("candidates are in order of period") end
  end
  near(cands[1].tau, TSR / 220, 0.3, "the period"); near(cands[2].tau, 2 * TSR / 220, 0.6, "its double")
end)

test("yin_strong_second_harmonic", function()   -- the chorus: the note is 375 Hz, most of the sound is at 750
  local _, freq = S.yin_process_block(block_of(tone(375, 0.12, 1)), TSR, YP)
  near(freq, 375, 1, "freq")
end)

test("yin_noise_has_no_pitch", function()
  local seed = 12345
  local _, freq, _, cands = S.yin_process_block(block_of(function()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 1073741824 - 1
  end), TSR, YP)
  eq(freq, nil, "freq"); eq(cands, nil, "candidates")
end)

test("yin_nothing_at_the_longest_period", function()   -- 93.75 Hz repeats exactly at the last period looked at
  local _, freq = S.yin_process_block(block_of(tone(93.75, 1, 0.5)), TSR, YP)
  eq(freq, nil, "a reading at the edge of the search is no dip")
end)

test("yin_reads_the_middle_of_the_block", function()   -- a rising pitch: 200 Hz at the block's start, 216 at its end
  local dur = YP.block_size / TSR
  local _, freq = S.yin_process_block(block_of(function(t)
    local ph = 2 * math.pi * (200 * t + 0.5 * (16 / dur) * t * t)
    return math.sin(ph) + 0.5 * math.sin(2 * ph) + 0.3 * math.sin(3 * ph)
  end), TSR, YP)
  near(freq, 208, 0.8, "the pitch at the middle of the block")
end)


test("analysis_chooses_periods_before_splitting", function()   -- what an analysis runs when its last frame is read
  local st = S.state
  local saved = { st.results, st.notes, st.split_points, st.separation, st.sample_rate }
  st.results = track_frames({ { 3, nil }, { 40, { { 64, 0.07 }, { 128, 0.001 }, { 256, 0.002 } } }, { 3, nil } })
  st.separation, st.sample_rate = 0.5, TSR
  local ok, err = pcall(function()
    S.run_hybrid_segmentation()
    near(st.results[10].freq, 375, 1e-9, "the frames are read at the period, not half of it")
    eq(st.results[10].cands, nil, "candidates are not kept")
    eq(#st.notes, 1, "notes")
    near(st.notes[1].avg_note, 69 + 12 * math.log(375 / 440, 2), 1e-6, "the note's centre")
  end)
  st.results, st.notes, st.split_points, st.separation, st.sample_rate = table.unpack(saved, 1, 5)
  if not ok then error(err, 0) end
end)

test("frame_centre", function()
  near(S.K.frame_centre_s(1024, 48000), 512 / 48000, 1e-12, "the middle of the block")
end)

-- After the whole-branch review of the detector change -----------------------------------------------

test("yin_steady_high_note", function()   -- more dips than a frame keeps: the note's own period must be among them
  for _, hz in ipairs({ 880, 932, 988 }) do
    local _, freq, _, cands = S.yin_process_block(block_of(tone(hz, 1, 0.3, 0.1)), TSR, YP)
    near(freq, hz, 2, hz .. " Hz")
    eq(#cands, S.K.TRACK.MAX_CANDS, hz .. " Hz: the frame is trimmed")
    near(cands[1].tau, TSR / hz, 0.3, hz .. " Hz: the shortest deep dip is kept")
  end
end)

test("yin_threshold_decides_whether_there_is_a_pitch", function()   -- a noisy tone: its deepest dip is about 0.2
  local seed = 99
  local function noisy(t)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return math.sin(2 * math.pi * 220 * t) + 0.62 * (seed / 1073741824 - 1)
  end
  local blk = block_of(noisy)
  local function at(th) return S.yin_process_block(blk, TSR, { block_size = 1024, threshold = th, min_freq = 65, max_freq = 1000 }) end
  local _, strict = at(0.08)
  local _, standard, _, cands = at(0.15)
  eq(strict, nil, "no pitch at 0.08: the deepest dip is over 0.16")
  near(standard, 220, 3, "a pitch at 0.15: the deepest dip is under 0.30")
  local deepest = math.huge
  for _, c in ipairs(cands) do deepest = math.min(deepest, c.d) end
  if deepest <= 0.16 or deepest > 0.30 then error("the block's deepest dip is " .. deepest .. ", the test needs 0.16..0.30") end
end)

-- The same note with noise 20 dB under it. (With the noise 15 dB under, the note's own tone, 18 dB under its
-- overtone, is below the noise: the block then really is a 750 Hz sound in noise, and is read as one.)
test("yin_strong_second_harmonic_in_noise", function()
  local seed = 4242
  local amp = math.sqrt((0.12 * 0.12 + 1) / 2) / 10 ^ (20 / 20) * math.sqrt(3)
  local n = 20 * 512 + 1024
  local x = {}
  for i = 1, n do
    local t = (i - 1) / TSR
    seed = (seed * 1103515245 + 12345) % 2147483648
    x[i] = 0.12 * math.sin(2 * math.pi * 375 * t) + math.sin(2 * math.pi * 750 * t) + amp * (seed / 1073741824 - 1)
  end
  local fr = {}
  for k = 0, 19 do
    local blk = {}
    for i = 1, 1024 do blk[i] = x[k * 512 + i] end
    local rms, freq, lvl, cands = S.yin_process_block(blk, TSR, YP)
    fr[#fr + 1] = { time = k * OHOP, freq = freq, rms = rms, lvl = lvl, cands = cands }
  end
  S.K.pitch_track(fr, TSR)
  for i, f in ipairs(fr) do near(f.freq, 375, 3, "frame " .. i) end
end)

test("track_a_line_runs_through_a_short_gap_only", function()
  local good, doubtful = { { 128, 0.01 }, { 256, 0.01 } }, { { 128, 0.30 }, { 256, 0.10 } }
  -- 2 unvoiced frames (21 ms, under K.SEG.BRIDGE_S): the doubtful frame is read with the line before the gap
  local short = track_frames({ { 10, good }, { 2, nil }, { 1, doubtful } })
  S.K.pitch_track(short, TSR)
  near(tau_of(short[13]), 128, 1e-9, "after a short gap")
  -- 3 unvoiced frames (32 ms): a new line, the frame is read on its own
  local long = track_frames({ { 10, good }, { 3, nil }, { 1, doubtful } })
  S.K.pitch_track(long, TSR)
  near(tau_of(long[14]), 256, 1e-9, "after a long gap")
end)

test("track_same_answer_at_any_hop", function()
  local good, doubtful = { { 128, 0.01 }, { 256, 0.01 } }, { { 128, 0.30 }, { 256, 0.10 } }
  for _, hop in ipairs({ 256 / 48000, 512 / 48000, 1024 / 48000 }) do
    local side = math.floor(0.3 / hop + 0.5)
    -- 21 ms of doubtful frames among good ones stay on the line; 64 ms are followed
    for _, case in ipairs({ { 0.0213, 128 }, { 0.064, 256 } }) do
      local n = math.floor(case[1] / hop + 0.5)
      local fr = track_frames({ { side, good }, { n, doubtful }, { side, good } }, hop)
      S.K.pitch_track(fr, TSR)
      near(tau_of(fr[side + 1]), case[2], 1e-9, string.format("%.0f ms at hop %.4f", case[1] * 1000, hop))
      near(tau_of(fr[1]), 128, 1e-9, "the frames around")
    end
  end
end)

test("track_empty_candidate_list_is_removed", function()
  local fr = track_frames({ { 2, {} } })
  S.K.pitch_track(fr, TSR)
  eq(fr[1].cands, nil, "removed")
end)

test("analysis_frame_and_block_times", function()
  local P = { block_size = 1024, min_freq = 65, max_freq = 1000 }
  local cands = { { tau = 128, d = 0.01 } }
  local f = S.K.analysis_frame(1.0, P, TSR, 0.1, 375, 0.09, cands)
  near(f.time, 1.0 + 512 / TSR, 1e-12, "the middle of the block")
  eq(f.freq, 375); near(f.note, 69 + 12 * math.log(375 / 440, 2), 1e-9, "note"); eq(f.rms, 0.1); eq(f.lvl, 0.09)
  eq(f.cands, cands, "the candidates ride on the frame until the choice is made")
  eq(S.K.analysis_frame(0, P, TSR, 0.1, 1200, 0.1, nil).note, nil, "a reading outside the range has no note")
  eq(S.K.analysis_frame(0, P, TSR, 0.1, nil, 0.1, nil).note, nil, "no pitch, no note")
  -- which blocks are read: only those that lie whole inside the item
  local block_s = 1024 / TSR
  eq(S.K.block_fits(0, P, TSR, 1.0), true, "the first block")
  eq(S.K.block_fits(1.0 - block_s, P, TSR, 1.0), true, "a block that ends with the item")
  eq(S.K.block_fits(1.0 - block_s + 1e-6, P, TSR, 1.0), false, "a block that runs past the end")
  eq(S.K.block_fits(0, P, TSR, block_s / 2), false, "an item shorter than a block")
end)

test("analysis_pitch_range_follows_the_final_choice", function()
  local st = S.state
  local saved = { st.results, st.notes, st.split_points, st.separation, st.sample_rate }
  st.results = track_frames({ { 40, { { 64, 0.07 }, { 128, 0.001 }, { 256, 0.002 } } } })
  for _, f in ipairs(st.results) do f.note = 99 end   -- what the frames showed while the analysis ran
  st.separation, st.sample_rate = 0.5, TSR
  local ok, err = pcall(function()
    local _, _, before = S.K.results_range(st.results)
    eq(before, 99, "the range while the analysis runs")
    S.run_hybrid_segmentation()
    local _, low, high = S.K.results_range(st.results)
    local want = 69 + 12 * math.log(375 / 440, 2)
    near(low, want, 1e-6, "lowest pitch after the choice"); near(high, want, 1e-6, "highest pitch after the choice")
  end)
  st.results, st.notes, st.split_points, st.separation, st.sample_rate = table.unpack(saved, 1, 5)
  if not ok then error(err, 0) end
end)

-- Analyze All Selected Items (docs/design/pitch-correct-analyze-selected.md) ----------------------------------------

-- Every analysis reads the uncorrected audio: the accessor is made while the take's Pitch envelope is bypassed
local ENV_CHUNK = "<PITCHENV\nEGUID {E}\nACT 1 -1\nVIS 1 1 1\nPT 0 0 0\nPT 0.5 0.244 5 0\n>"
local function with_envelope(chunk, create, fn)   -- runs fn(log) with the envelope and accessor calls recorded
  local log = {}
  reaper.GetTakeEnvelopeByName = function() return chunk and "ENV" or nil end
  reaper.GetEnvelopeStateChunk = function() return true, chunk end
  reaper.SetEnvelopeStateChunk = function(_, c) log[#log + 1] = "set:" .. c; return true end
  reaper.CreateTakeAudioAccessor = function() log[#log + 1] = "create"; return create() end
  local ok, err = pcall(fn, log)
  reaper.GetTakeEnvelopeByName, reaper.GetEnvelopeStateChunk, reaper.SetEnvelopeStateChunk,
    reaper.CreateTakeAudioAccessor = nil, nil, nil, nil
  if not ok then error(err, 0) end
end

test("open_accessor_reads_around_the_envelope", function()
  with_envelope(ENV_CHUNK, function() return "ACC" end, function(log)
    eq(S.K.open_accessor("TAKE"), "ACC")
    eq(#log, 3, "calls")
    eq(log[1], "set:" .. (ENV_CHUNK:gsub("ACT 1", "ACT 0", 1)), "bypassed first")
    eq(log[2], "create")
    eq(log[3], "set:" .. ENV_CHUNK, "put back byte for byte")
  end)
end)

test("open_accessor_restores_when_creation_fails", function()
  with_envelope(ENV_CHUNK, function() error("boom") end, function(log)
    eq(S.K.open_accessor("TAKE"), nil)
    eq(log[#log], "set:" .. ENV_CHUNK, "envelope put back")
  end)
end)

test("open_accessor_leaves_other_envelopes_alone", function()
  for _, chunk in ipairs({ false, (ENV_CHUNK:gsub("ACT 1", "ACT 0", 1)), "<PITCHENV\nACT 1 -1\nVIS 1 1 1\n>" }) do
    with_envelope(chunk, function() return "ACC" end, function(log)
      eq(S.K.open_accessor("TAKE"), "ACC")
      eq(#log, 1, "only the accessor is created"); eq(log[1], "create")
    end)
  end
end)

test("analysis_begin_refuses_offline_media", function()
  local st = S.state
  local asked = false
  reaper.GetMediaItemTake_Source = function() return "SRC" end
  reaper.GetMediaSourceSampleRate = function(src) asked = (src == "SRC"); return 0 end
  local created = false
  reaper.CreateTakeAudioAccessor = function() created = true; return "ACC" end
  local ok, reason = S.K.analysis_begin("TAKE", "ITEM")
  reaper.GetMediaItemTake_Source, reaper.GetMediaSourceSampleRate, reaper.CreateTakeAudioAccessor = nil, nil, nil
  eq(asked, true, "the source was asked for its rate")
  eq(ok, false); eq(reason, "offline"); eq(st.is_analyzing == true, false, "not analysing")
  eq(created, false, "nothing was opened")
end)

test("analysis_begin_uses_the_rate_it_is_given", function()
  local st = S.state
  local saved = { st.target_take_guid, st.target_take_name, st.results, st.sample_rate, st.item_len, st.end_time }
  reaper.GetMediaItemTake_Source = function() return "SRC" end
  reaper.GetMediaSourceSampleRate = function() return 0 end   -- REAPER in the background: no rate to be had
  reaper.CreateTakeAudioAccessor = function() return "ACC" end
  reaper.GetMediaItemInfo_Value = function() return 3 end
  local undo_blocks = 0
  reaper.Undo_BeginBlock = function() undo_blocks = undo_blocks + 1 end
  local ok = S.K.analysis_begin("TAKE", "ITEM", { sample_rate = 44100, defer_envelope = true })
  local got = { ok, st.sample_rate, st.is_analyzing, st.accessor, st.item_len }
  S.K.release_analysis()
  reaper.GetMediaItemTake_Source, reaper.GetMediaSourceSampleRate, reaper.CreateTakeAudioAccessor,
    reaper.GetMediaItemInfo_Value, reaper.Undo_BeginBlock = nil, nil, nil, nil, nil
  st.target_take_guid, st.target_take_name, st.results, st.sample_rate, st.item_len, st.end_time = table.unpack(saved, 1, 6)
  eq(got[1], true); eq(got[2], 44100); eq(got[3], true); eq(got[4], "ACC"); eq(got[5], 3)
  eq(undo_blocks, 0, "defer_envelope: no undo point of its own")
end)

-- The developer switch (ExtState FancyScripts / pitch_dev_dump): what the detector saw, one file per item
local DUMP_PARAMS = { block_size = 1024, hop_size = 512, threshold = 0.08, min_freq = 65, max_freq = 1000 }
local function dump_results()
  return {
    { time = 0.010667, rms = 0.0007, lvl = 0.0006 },
    { time = 0.064, freq = 337.22, rms = 0.02487, lvl = 0.0231,
      cands = { { tau = 142.337, d = 0.0182 }, { tau = 284.5, d = 0.0507 } } },
  }
end

test("dump_name", function()
  eq(S.K.dump_name("V Main: Verse/1", "{AB12-CD}"), "diag_V_Main__Verse_1_AB12-CD.tsv")
  eq(S.K.dump_name("", "{X}"), "diag_item_X.tsv")
end)

test("dump_text_format", function()
  local lines = {}
  for line in S.K.dump_text(DUMP_PARAMS, 48000, dump_results()):gmatch("[^\n]+") do lines[#lines + 1] = line end
  eq(lines[1], "# sr=48000 block=1024 hop=512 th=0.08 min=65 max=1000")
  eq(lines[2], "time\tfreq\trms\thow\tlvl\tdips")
  eq(lines[3], "0.010667\t-1.000\t0.00070\tunvoiced\t0.00060\t")
  eq(lines[4], "0.064000\t337.220\t0.02487\tvoiced\t0.02310\t142.337:0.0182 284.500:0.0507")
  eq(#lines, 4)
end)

test("dump_round_trip", function()
  local fr = diag_parse(S.K.dump_text(DUMP_PARAMS, 48000, dump_results()))
  eq(#fr, 2)
  eq(fr[1].cands, nil, "an unvoiced frame has no candidates")
  near(fr[2].time, 0.064, 1e-6); near(fr[2].rms, 0.02487, 1e-5); near(fr[2].lvl, 0.0231, 1e-5)
  eq(#fr[2].cands, 2); near(fr[2].cands[1].tau, 142.337, 1e-3); near(fr[2].cands[2].d, 0.0507, 1e-4)
end)

test("dump_reader_still_reads_the_recordings_of_2026_11_23", function()
  local fr = diag_parse("# sr=48000 block=1024 hop=512 th=0.08 min=65 max=1000\n"
    .. "time\tfreq\trms\thow\ttau\tW\tmin_tau\tmax_tau\tedge\tdips\n"
    .. "0.000000\t-1.000\t0.00027\tunvoiced\t487\t512\t48\t512\t1.0127\t487:0.7824\n"
    .. "0.053333\t333.208\t0.01981\tglobal\t144\t512\t48\t512\t1.1187\t116:0.5025 144:0.0912\n")
  eq(#fr, 2); eq(fr[1].cands, nil); near(fr[2].rms, 0.01981, 1e-9); near(fr[2].lvl, 0.01981, 1e-9, "no lvl column: rms")
  eq(#fr[2].cands, 2); eq(fr[2].cands[2].tau, 144); near(fr[2].cands[2].d, 0.0912, 1e-9)
end)

test("dev_dump_off_by_default_and_on", function()
  eq(S.K.dev_dump("Take", "{G}", DUMP_PARAMS, 48000, dump_results()), nil, "off: the switch is empty")
  local dir = os.tmpname(); os.remove(dir); os.execute('mkdir "' .. dir .. '"')
  reaper.GetExtState = function(_, key) return key == "pitch_dev_dump" and dir or "" end
  local path = S.K.dev_dump("Take", "{G}", DUMP_PARAMS, 48000, dump_results())
  reaper.GetExtState = function() return "" end   -- the harness's own stub
  eq(path, dir .. "/diag_Take_G.tsv")
  local f = io.open(path, "rb"); local body = f:read("a"); f:close(); os.remove(path); os.remove(dir)
  eq(body, S.K.dump_text(DUMP_PARAMS, 48000, dump_results()))
end)

-- What a batch is made of: the selection, the counts, the copy
local MOD = S.K.MOD_LABEL

local function with_selection(items, fn)   -- items: { { take = id | nil, midi = bool, name, len, sr, track, pos } }
  reaper.CountSelectedMediaItems = function() return #items end
  reaper.GetSelectedMediaItem = function(_, i) return items[i + 1] end
  reaper.GetActiveTake = function(it) return it.take end
  reaper.TakeIsMIDI = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.midi == true end end end
  reaper.GetSetMediaItemTakeInfo_String = function(tk, key) if key == "GUID" then return true, "{" .. tk .. "}" end return false, "" end
  reaper.GetTakeName = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.name end end end
  reaper.GetMediaItemInfo_Value = function(it, key) return key == "D_LENGTH" and (it.len or 1) or (it.pos or 0) end
  reaper.GetMediaItemTake_Source = function(tk) return tk end
  reaper.GetMediaSourceSampleRate = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.sr or 48000 end end end
  reaper.GetMediaItemTrack = function(it) return it end
  reaper.GetTrackName = function(it) return true, it.track or "Vox" end
  local ok, err = pcall(fn)
  for _, name in ipairs({ "CountSelectedMediaItems", "GetSelectedMediaItem", "GetActiveTake", "TakeIsMIDI",
    "GetSetMediaItemTakeInfo_String", "GetTakeName", "GetMediaItemInfo_Value", "GetMediaItemTake_Source",
    "GetMediaSourceSampleRate", "GetMediaItemTrack", "GetTrackName", "GetProjectStateChangeCount" }) do reaper[name] = nil end
  S.K.batch_peek_cache = nil
  if not ok then error(err, 0) end
end

test("batch_selection_audio_only", function()
  local st = S.state
  st.session_takes["{b}"] = { notes = { {} }, results = { {} } }
  st.session_takes["{d}"] = { notes = {}, results = { {} } }
  with_selection({ { take = "a", name = "A", len = 10, pos = 4 }, { take = "m", midi = true }, { name = "empty" },
      { take = "b", name = "B", len = 20, sr = 44100, track = "Dbl" }, { take = "d", name = "D" } }, function()
    local sel = S.K.batch_selection()
    eq(#sel.takes, 3); eq(sel.skipped, 2)
    eq(sel.takes[1].guid, "{a}"); eq(sel.takes[1].name, "A"); eq(sel.takes[1].len, 10); eq(sel.takes[1].pos, 4)
    eq(sel.takes[1].has_notes, false)
    eq(sel.takes[2].guid, "{b}"); eq(sel.takes[2].sample_rate, 44100); eq(sel.takes[2].track, "Dbl"); eq(sel.takes[2].has_notes, true)
    eq(sel.takes[3].has_notes, false, "analysed without notes: nothing to lose")
  end)
  st.session_takes["{b}"], st.session_takes["{d}"] = nil, nil
end)

test("batch_peek_is_cached", function()
  local calls = 0
  with_selection({ { take = "a" }, { take = "b" } }, function()
    local get = reaper.GetSelectedMediaItem
    reaper.GetSelectedMediaItem = function(...) calls = calls + 1; return get(...) end
    reaper.GetProjectStateChangeCount = function() return 7 end
    eq(S.K.batch_peek(10).n, 2); local first = calls
    S.K.batch_peek(10.1); eq(calls, first, "same selection, same project state, under 0.25 s: no walk")
    S.K.batch_peek(10.3); eq(calls > first, true, "walked again after 0.25 s")
  end)
end)

test("batch_copy", function()
  local K = S.K
  eq(K.batch_label(1), "Analyze Item"); eq(K.batch_label(0), "Analyze Item")
  eq(K.batch_label(2), "Analyze All Selected Items"); eq(K.batch_label(12, true), "Analyze All")
  local a, b = K.batch_lines({ n = 1, skipped = 0, with_notes = 0, target_in = true, names = { "Verse" } }, "Verse")
  eq(a, "1 item selected: Verse", "one item: its name"); eq(b, nil)
  a, b = K.batch_lines({ n = 0, skipped = 0, with_notes = 0, target_in = false, names = {} }, nil)
  eq(a, "Select one or more items and click Analyze."); eq(b, nil)
  a, b = K.batch_lines({ n = 2, skipped = 0, with_notes = 0, target_in = true, names = { "A", "B" } }, "A")
  eq(a, "2 items selected: A, B"); eq(b, nil)
  a, b = K.batch_lines({ n = 3, skipped = 2, with_notes = 3, target_in = false, names = { "A", "B", "C" } }, "X")
  eq(a, "3 items selected: A, B, C")
  eq(b, "2 other selected items are skipped. This item is not one of them. 3 already have notes. You will be asked before they are replaced.")
  a, b = K.batch_lines({ n = 2, skipped = 1, with_notes = 1, target_in = true, names = { "A", "B" } }, "A")
  eq(a, "2 items selected: A, B"); eq(b, "1 other selected item is skipped. 1 already has notes. You will be asked before it is replaced.")
  -- Fitted to the width (one unit per character here)
  local len = function(text) return #text end
  local names = { "Verse 1", "Verse 2", "Chorus", "Bridge" }
  eq(K.batch_names_fit({ "Verse 1", "Verse 2" }, 100, len), "2 items selected: Verse 1, Verse 2")
  eq(K.batch_names_fit({ "Verse 1", "Verse 2", "Chorus" }, 100, len), "3 items selected: Verse 1, Verse 2, …",
    "3 or more: two names and an ellipsis")
  eq(K.batch_names_fit(names, 100, len), "4 items selected: Verse 1, Verse 2, …")
  eq(K.batch_names_fit(names, 30, len), "4 items selected: Verse 1, …", "narrow: fewer names")
  eq(K.batch_names_fit(names, 20, len), "4 items selected")
  eq(K.batch_names_tip({ "A", "B" }), "2 selected items\n\nA\nB")
  eq(K.batch_tip(12), "Detect the pitch of the 12 selected audio items, one after another.\n\nOne undo step for all of them.")
  eq(K.batch_undo_label(12), "Analyze Pitch (12 items)"); eq(K.batch_undo_label(1), "Analyze Pitch (1 item)")
end)

test("batch_confirm_copy", function()
  local K = S.K
  local function entries(n, with)
    local out = {}
    for i = 1, n do out[i] = { guid = "{" .. i .. "}", name = "N" .. i, track = "T", pos = i, has_notes = i <= with } end
    return out
  end
  eq(K.batch_confirm(entries(3, 0)), nil, "nothing to replace: no confirm")
  local c = K.batch_confirm(entries(12, 3))
  eq(c.title, "Analyze 12 items?"); eq(c.confirm_label, "Analyze 12 Items")
  eq(c.body_lines[1], "3 of them already have notes. Analyzing replaces their notes and any edits:")
  eq(#c.list, 3); eq(c.list[2].name, "N2"); eq(c.list[2].track, "T"); eq(c.list[2].pos, 2)
  eq(c.after_lines[1], "Their values go back to the defaults; Key and Scale stay.")
  eq(c.after_lines[2], MOD .. "+Z restores all 12 items in one step once the batch has finished.")
  eq(K.batch_confirm(entries(12, 1)).after_lines[1], "Its values go back to the defaults; Key and Scale stay.")
  eq(K.batch_confirm(entries(12, 1)).body_lines[1], "1 of them already has notes. Analyzing replaces its notes and any edits:")
  eq(K.batch_confirm(entries(12, 12)).body_lines[1], "All 12 already have notes. Analyzing replaces their notes and any edits:")
end)

test("batch_progress_by_audio_length", function()
  local K = S.K
  local b = K.batch_new({ { len = 10 }, { len = 30 }, { len = 0 } }, "{p}")
  eq(b.total_len, 40); eq(b.prev_guid, "{p}"); eq(K.batch_progress(b, 0), 0)
  b.index = 1; near(K.batch_progress(b, 0.5), 0.125, 1e-12)
  b.index, b.done_len = 2, 10; near(K.batch_progress(b, 0.5), 0.625, 1e-12)
  eq(K.batch_progress(K.batch_new({ { len = 0 } }), 0.5), 0, "no audio at all")
end)

test("batch_summary_copy", function()
  local sum = S.K.batch_summary
  eq(sum({ total = 12, written = 12, empty = 0, failed = 0 }), "Analyzed 12 items. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 1, written = 1, empty = 0, failed = 0 }), "Analyzed 1 item. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 11, empty = 1, failed = 1 }),
    "Analyzed 11 of 12 items (1 has no pitched notes). 1 could not be analyzed. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 12, empty = 2, failed = 0 }), "Analyzed 12 items (2 have no pitched notes). " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 2, empty = 0, failed = 0, cancelled = true }),
    "Batch cancelled. 2 of 12 items were analyzed and kept. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 1, empty = 0, failed = 0, cancelled = true }),
    "Batch cancelled. 1 of 12 items was analyzed and kept. " .. MOD .. "+Z to undo.")
  eq(sum({ total = 12, written = 0, empty = 0, failed = 0, cancelled = true }), "Batch cancelled. Nothing was changed.")
  eq(sum({ total = 12, written = 0, empty = 0, failed = 12 }), "None of the 12 items could be analyzed. Nothing was changed.")
end)

-- The queue of a batch and its single write
-- A batch with the analysis itself and the write replaced by recorders. fn(rec) runs with takes "a".."c" selected.
local function with_batch(fn)
  local K, st = S.K, S.state
  local saved = { K.analysis_begin, K.batch_write, st.target_take_guid, st.target_take_name }
  local saved_model = { st.results, st.notes, st.split_points, st.analysis_empty, st.progress }
  local rec = { begun = {}, writes = {} }
  K.analysis_begin = function(take, _, opts)
    rec.begun[#rec.begun + 1] = { take = take, sr = opts and opts.sample_rate, defer = opts and opts.defer_envelope,
      sep = st.separation, key_idx = st.key_idx, scale_idx = st.scale_idx }
    if rec.refuse and rec.refuse[take] then return false, "accessor" end
    st.is_analyzing = true
    return true
  end
  K.batch_write = function(done) rec.writes[#rec.writes + 1] = done; return done end
  K.drop_project_cache()
  st.status.text, st.status.hold = "", nil
  reaper.GetMediaItemTakeByGUID = function(_, guid) if rec.gone and rec.gone[guid] then return nil end return (guid:gsub("[{}]", "")) end
  reaper.GetMediaItemTake_Item = function(take) return "item_" .. take end
  local ok, err = pcall(fn, rec)
  K.analysis_begin, K.batch_write, st.target_take_guid, st.target_take_name = table.unpack(saved, 1, 4)
  st.results, st.notes, st.split_points, st.analysis_empty, st.progress = table.unpack(saved_model, 1, 5)
  K.batch, st.is_analyzing, K.card = nil, false, nil
  st.status.text, st.status.hold = "", nil
  reaper.GetMediaItemTakeByGUID, reaper.GetMediaItemTake_Item = nil, nil
  K.drop_project_cache()
  if not ok then error(err, 0) end
end
local function entries3()
  local out = {}
  for i, id in ipairs({ "a", "b", "c" }) do
    out[i] = { guid = "{" .. id .. "}", take = id, item = "item_" .. id, name = id:upper(), len = 10, sample_rate = 48000, has_notes = false }
  end
  return out
end
local function model(guid, notes) return { guid = guid, name = guid, results = { {} }, notes = notes or { { frames = {} } } } end

test("batch_runs_queue_in_order", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3())
  eq(#rec.begun, 1); eq(rec.begun[1].take, "a"); eq(rec.begun[1].sr, 48000); eq(rec.begun[1].defer, true)
  eq(S.state.target_take_guid, "{a}", "the canvas follows the item in progress")
  K.batch_item_done(model("{a}")); K.batch_item_done(model("{b}")); eq(#rec.writes, 0, "nothing is written while it runs")
  near(K.analysis_progress(), 20 / 30, 1e-12)
  K.batch_item_done(model("{c}"))
  eq(#rec.writes, 1, "one write"); eq(#rec.writes[1], 3)
  eq(rec.writes[1][1].guid, "{a}"); eq(rec.writes[1][3].guid, "{c}"); eq(type(rec.writes[1][1].json), "string")
  eq(K.batch, nil); eq(S.state.is_analyzing, false)
  eq(K.card.phase, "done", "the Analysis card waits for OK")
  eq(K.card.lines[1], "Analyzed 3 items. " .. MOD .. "+Z to undo.", "the summary is in the card")
  eq(S.state.status.text, "", "not in the status line")
end) end)

test("batch_skips_missing_and_offline", function() with_batch(function(rec)
  local K = S.K
  rec.gone = { ["{a}"] = true }
  local e = entries3(); e[2].sample_rate = 0
  K.batch_start(e)
  eq(#rec.begun, 1); eq(rec.begun[1].take, "c", "the deleted and the offline item never start")
  K.batch_item_done(model("{c}"))
  eq(S.K.card.lines[1], "Analyzed 1 of 3 items. 2 could not be analyzed. " .. MOD .. "+Z to undo.")
end) end)

test("batch_uses_rates_from_the_click", function() with_batch(function(rec)
  reaper.GetMediaSourceSampleRate = function() return 0 end   -- REAPER went to the background
  S.K.batch_start(entries3()); S.K.batch_item_done(model("{a}"))
  reaper.GetMediaSourceSampleRate = nil
  eq(rec.begun[2].take, "b"); eq(rec.begun[2].sr, 48000)
end) end)

test("batch_item_failure_carries_on", function() with_batch(function(rec)
  local K = S.K
  rec.refuse = { b = true }
  K.batch_start(entries3()); K.batch_item_done(model("{a}"))
  eq(rec.begun[#rec.begun].take, "c", "b was refused, c is running")
  K.batch_item_failed(nil)
  eq(#rec.writes, 1); eq(#rec.writes[1], 1)
  eq(K.card.lines[1], "Analyzed 1 of 3 items. 2 could not be analyzed. " .. MOD .. "+Z to undo.")
end) end)

test("batch_counts_items_without_notes", function() with_batch(function()
  local K = S.K
  K.batch_start(entries3())
  K.batch_item_done(model("{a}", {})); K.batch_item_done(model("{b}")); K.batch_item_done(model("{c}"))
  eq(K.card.lines[1], "Analyzed 3 items (1 has no pitched notes). " .. MOD .. "+Z to undo.")
end) end)

test("batch_cancel_keeps_finished", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3()); K.batch_item_done(model("{a}"))
  eq(K.cancel_analysis(), true)
  eq(#rec.writes, 1); eq(#rec.writes[1], 1); eq(K.batch, nil); eq(S.state.is_analyzing, false)
  eq(S.state.status.text, "Batch cancelled. 1 of 3 items was analyzed and kept. " .. MOD .. "+Z to undo.")
  eq(K.card, nil, "cancelled: the card closes, the status line says what was kept")
end) end)

test("batch_cancel_before_any_item", function() with_batch(function(rec)
  local K, st = S.K, S.state
  st.target_take_guid, st.target_take_name = "{prev}", "Prev"
  K.batch_start(entries3())
  K.cancel_analysis()
  eq(#rec.writes == 0 or #rec.writes[1] == 0, true, "nothing to write")
  eq(st.target_take_guid, "{prev}", "the item that was open comes back")
  eq(st.status.text, "Batch cancelled. Nothing was changed.")
end) end)

test("batch_queue_is_frozen", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3())
  reaper.CountSelectedMediaItems = function() return 0 end   -- the user deselects everything
  K.batch_item_done(model("{a}")); K.batch_item_done(model("{b}"))
  reaper.CountSelectedMediaItems = nil
  eq(rec.begun[3].take, "c")
end) end)

test("batch_tick_turns_an_error_into_a_failed_item", function() with_batch(function(rec)
  local K, st = S.K, S.state
  local said = nil
  reaper.ShowConsoleMsg = function(msg) said = msg end
  K.batch_start(entries3())
  st.is_analyzing, st.analysis_params = true, setmetatable({}, { __index = function() error("bad frame") end })
  local ok, err = pcall(K.analysis_tick)
  reaper.ShowConsoleMsg, st.analysis_params = nil, nil
  if not ok then error(err, 0) end
  eq(tostring(said):find("bad frame", 1, true) ~= nil, true, "the console has what was raised")
  eq(rec.begun[#rec.begun].take, "b", "the batch moved on"); eq(K.batch.failed, 1)
end) end)

test("batch_tick_does_not_swallow_a_failed_write", function() with_batch(function()
  local K, st = S.K, S.state
  local saved = { st.results, st.notes, st.sample_rate, st.end_time, st.current_time }
  K.batch_write = function() error("disk full") end
  local e = entries3()
  K.batch_start({ e[1] })
  -- the item's last frame: nothing left to read, so this tick completes it and the batch ends by writing
  st.results, st.sample_rate, st.end_time, st.current_time = {}, 48000, 0, 0
  st.analysis_params = { block_size = 1024, hop_size = 512, threshold = 0.1, min_freq = 65, max_freq = 1000 }
  local ok, err = pcall(K.analysis_tick)
  st.results, st.notes, st.sample_rate, st.end_time, st.current_time = table.unpack(saved, 1, 5)
  st.analysis_params = nil
  eq(ok, false, "the window's own error handling must see it (it closes the undo block)")
  eq(tostring(err):find("disk full", 1, true) ~= nil, true); eq(K.batch, nil)
end) end)

local function with_write_stubs(gone, fn, no_env)
  local st = S.state
  local rec = { begin = 0, labels = {}, stored = {}, cleared = {} }
  reaper.Undo_BeginBlock = function() rec.begin = rec.begin + 1 end
  reaper.Undo_EndBlock = function(label) rec.labels[#rec.labels + 1] = label end
  reaper.GetMediaItemTakeByGUID = function(_, guid) if gone[guid] then return nil end return (guid:gsub("[{}]", "")) end
  reaper.GetMediaItemTake_Item = function(take) return "item_" .. take end
  reaper.GetTakeEnvelopeByName = function(take) if no_env and no_env[take] then return nil end return "env_" .. take end
  reaper.DeleteEnvelopePointRange = function(env) rec.cleared[#rec.cleared + 1] = env end
  reaper.NamedCommandLookup = function() return 0 end
  reaper.CountSelectedMediaItems = function() return 0 end
  reaper.GetSetMediaItemTakeInfo_String = function(take, key, value, set)
    if key == "GUID" then return true, "{" .. take .. "}" end
    if set then rec.stored[take] = value end
    return true, rec.stored[take] or ""
  end
  local order = #st.session_order
  S.K.drop_project_cache()   -- nothing an earlier test resolved (without these stubs) is reused
  local ok, err = pcall(fn, rec)
  for _, name in ipairs({ "Undo_BeginBlock", "Undo_EndBlock", "GetMediaItemTakeByGUID", "GetMediaItemTake_Item",
    "GetTakeEnvelopeByName", "DeleteEnvelopePointRange", "NamedCommandLookup", "CountSelectedMediaItems",
    "GetSetMediaItemTakeInfo_String" }) do reaper[name] = nil end
  for _, g in ipairs({ "{a}", "{b}" }) do st.session_takes[g], st.raw_cache[g] = nil, nil end
  while #st.session_order > order do table.remove(st.session_order) end
  S.K.drop_project_cache()
  if not ok then error(err, 0) end
end
local function done2()
  local out = {}
  for i, g in ipairs({ "{a}", "{b}" }) do
    local data = { guid = g, name = g, results = {}, notes = {}, item_len = 1, sample_rate = 48000 }
    out[i] = { guid = g, data = data, json = S.K.take_json(data), empty = true }
  end
  return out
end

test("batch_write_is_one_undo_block", function() with_write_stubs({}, function(rec)
  local done = done2()
  local written = S.K.batch_write(done)
  eq(#written, 2); eq(rec.begin, 1, "one undo block"); eq(#rec.labels, 1); eq(rec.labels[1], "Analyze Pitch (2 items)")
  eq(rec.stored.a, done[1].json); eq(rec.stored.b, done[2].json)
  eq(#rec.cleared, 2, "each item's envelope is cleared of points"); eq(rec.cleared[1], "env_a")
  eq(S.state.session_takes["{a}"], done[1].data); eq(S.state.undo_open, false)
end) end)

test("batch_write_skips_gone_takes", function()
  with_write_stubs({ ["{a}"] = true }, function(rec)
    local written = S.K.batch_write(done2())
    eq(#written, 1); eq(written[1].guid, "{b}"); eq(rec.labels[1], "Analyze Pitch (1 item)")
  end)
  with_write_stubs({ ["{a}"] = true, ["{b}"] = true }, function(rec)
    eq(#S.K.batch_write(done2()), 0); eq(rec.begin, 0, "nothing to write: no undo point")
  end)
end)

test("take_json_is_what_save_writes", function() with_write_stubs({}, function(rec)
  local data = { guid = "{a}", name = "A", results = { { time = 0, note = 60 } }, item_len = 2, sample_rate = 48000,
    notes = { { start_time = 0, end_time = 1, avg_note = 60, display_note = 61, controls = { center_pitch = 62 }, frames = { 1 },
      count = 99 } } }
  local json = S.K.take_json(data)
  for _, part in ipairs({ '"guid":"{a}"', '"name":"A"', '"sample_rate":48000', '"display_note":61', '"center_pitch":62' }) do
    eq(json:find(part, 1, true) ~= nil, true, "stored text holds " .. part)
  end
  eq(json:find('"count"', 1, true), nil, "only what a note needs to be loaded again is stored")
  -- no text prepared: made at the write (the note above is not one a correction can be built from)
  local build = S.K.correction_build
  S.K.correction_build = function() return { points = {} } end
  local ok, err = pcall(S.K.batch_write, { { guid = "{a}", data = data } })
  S.K.correction_build = build
  if not ok then error(err, 0) end
  eq(rec.stored.a, json)
end) end)

test("analysis_defaults_copies_state", function()
  local d = S.K.analysis_defaults()
  eq(d.min_freq, S.state.min_freq); eq(d.hop_size, S.state.hop_size)
  d.min_freq = 1; eq(S.state.min_freq ~= 1, true, "a copy, not state")
end)
test("analysis_values_accepts_good", function()
  local v = S.K.analysis_values({ min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 })
  eq(v.max_freq, 1200); eq(v.block_size, 2048)
end)
test("analysis_values_rejects_bad", function()
  local K = S.K
  eq(K.analysis_values(nil), nil)
  eq(K.analysis_values({ min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 512, hop_size = 1024 }), nil, "hop > block")
  eq(K.analysis_values({ min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 1000, hop_size = 256 }), nil, "block not listed")
  eq(K.analysis_values({ min_freq = "250", max_freq = 1200, threshold = 0.25, block_size = 1024, hop_size = 256 }), nil, "string")
  eq(K.analysis_values({ min_freq = 5, max_freq = 1200, threshold = 0.25, block_size = 1024, hop_size = 256 }), nil, "Hz below limit")
  eq(K.analysis_values({ min_freq = 1200, max_freq = 1200, threshold = 0.25, block_size = 1024, hop_size = 256 }), nil, "min >= max")
end)
test("take_json_round_trips_analysis", function()
  local v = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 }
  local json = S.K.take_json({ guid = "{a}", results = {}, notes = {}, analysis = v })
  eq(json:find('"analysis"') ~= nil, true)
  for _, part in ipairs({ '"min_freq":250', '"max_freq":1200', '"threshold":0.25', '"block_size":2048', '"hop_size":256' }) do
    eq(json:find(part, 1, true) ~= nil, true, "stored text holds " .. part)
  end
end)
test("analysis_begin_snapshots_opts_values", function()
  local K, st = S.K, S.state
  local saved = { K.open_accessor, st.block_size, st.hop_size, st.min_freq, st.target_take_guid, st.target_take_name,
    st.session_takes, st.separation }
  local names = { "GetTakeName", "GetMediaItemInfo_Value", "new_array", "GetSetMediaItemTakeInfo_String" }
  local old = {}
  for _, n in ipairs(names) do old[n] = reaper[n] end
  K.open_accessor = function() return "acc" end
  reaper.GetTakeName = function() return "t" end
  reaper.GetMediaItemInfo_Value = function() return 2 end
  reaper.new_array = function() return {} end
  reaper.GetSetMediaItemTakeInfo_String = function(_, key) if key == "GUID" then return true, "{z}" end return true, "" end
  local before = { st.block_size, st.hop_size, st.min_freq }
  local ok, err = pcall(function()
    local began = K.analysis_begin("take", "item", { sample_rate = 48000, defer_envelope = true,
      values = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 } })
    eq(began, true)
    eq(st.analysis_params.min_freq, 250); eq(st.analysis_params.block_size, 2048)
    eq(st.analysis_params.hop_size, 256); eq(st.analysis_params.max_freq, 1200); eq(st.analysis_params.threshold, 0.25)
    eq(st.min_freq, before[3], "state.min_freq unchanged"); eq(st.block_size, before[1]); eq(st.hop_size, before[2])
    -- no values: the defaults, copied from state
    K.analysis_begin("take", "item", { sample_rate = 48000, defer_envelope = true })
    eq(st.analysis_params.min_freq, st.min_freq)
  end)
  K.open_accessor = saved[1]
  for _, n in ipairs(names) do reaper[n] = old[n] end
  st.is_analyzing, st.analysis_params, st.accessor, st.buffer = false, nil, nil, nil
  st.target_take_guid, st.target_take_name, st.separation = saved[5], saved[6], saved[8]
  if not ok then error(err, 0) end
end)
test("load_take_data_drops_bad_analysis", function()
  local K, st = S.K, S.state
  local good = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 }
  local bad = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 512, hop_size = 1024 }
  local raw, changes = "", 1
  reaper.GetProjectStateChangeCount = function() return changes end
  reaper.GetMediaItemTakeByGUID = function(_, guid) return guid == "{a}" and "a" or nil end
  reaper.GetSetMediaItemTakeInfo_String = function(_, key)
    if key == "GUID" then return true, "{a}" end
    return true, raw
  end
  local saved = { st.target_take_guid, st.last_change_count, #st.session_order }
  st.target_take_guid = "{other}"
  local function load(a)
    st.session_takes["{a}"], st.raw_cache["{a}"], st.unreadable_takes["{a}"] = nil, nil, nil
    while #st.session_order > saved[3] do table.remove(st.session_order) end
    raw = K.take_json({ guid = "{a}", name = "A", results = {}, notes = {}, item_len = 1, sample_rate = 48000, analysis = a })
    st.undone_takes["{a}"] = 1
    changes = changes + 1
    st.last_change_count = changes - 1
    K.drop_project_cache()
    S.sync_with_project()
    return st.session_takes["{a}"]
  end
  local ok, err = pcall(function()
    local d = load(good)
    eq(type(d), "table", "loaded"); eq(d.analysis.block_size, 2048); eq(d.analysis.min_freq, 250)
    eq(d.analysis.hop_size, 256); eq(d.analysis.threshold, 0.25); eq(d.analysis.max_freq, 1200)
    d = load(bad)
    eq(type(d), "table", "loaded"); eq(d.analysis, nil, "hop > block is not recorded")
    d = load(nil)
    eq(type(d), "table", "loaded"); eq(d.analysis, nil)
  end)
  reaper.GetProjectStateChangeCount, reaper.GetMediaItemTakeByGUID, reaper.GetSetMediaItemTakeInfo_String = nil, nil, nil
  st.session_takes["{a}"], st.raw_cache["{a}"], st.unreadable_takes["{a}"], st.undone_takes["{a}"] = nil, nil, nil, nil
  while #st.session_order > saved[3] do table.remove(st.session_order) end
  st.target_take_guid, st.last_change_count = saved[1], saved[2]
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

test("batch_write_leaves_an_item_whose_envelope_cannot_be_made", function() with_write_stubs({}, function(rec)
  local written = S.K.batch_write(done2())
  eq(#written, 1); eq(written[1].guid, "{b}"); eq(rec.stored.a, nil, "left as it was")
  eq(S.state.session_takes["{a}"], nil); eq(rec.labels[1], "Analyze Pitch (1 item)")
end, { a = true }) end)

test("batch_opens_the_first_written_item", function() with_write_stubs({}, function()
  local K, st = S.K, S.state
  local saved = { K.analysis_begin, st.target_take_guid, st.target_take_name, st.results, st.notes }
  K.analysis_begin = function() st.is_analyzing = true; return true end
  local e = entries3()
  local a, b = model("{a}", {}), model("{b}", {})
  local ok, err = pcall(function()
    K.batch_start({ e[1], e[2] })
    K.batch_item_done(a); K.batch_item_done(b)
    eq(K.batch, nil); eq(st.target_take_guid, "{a}", "the first item of the batch is open"); eq(st.results, a.results)
    eq(K.card.lines[1], "Analyzed 2 items (2 have no pitched notes). " .. MOD .. "+Z to undo.")
  end)
  K.analysis_begin, st.target_take_guid, st.target_take_name, st.results, st.notes = table.unpack(saved, 1, 5)
  K.batch, st.is_analyzing, st.status.text, st.status.hold, K.card = nil, false, "", nil, nil
  if not ok then error(err, 0) end
end) end)

test("batch_refuses_a_model_of_another_item", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3())
  -- the item in progress left the project and the open item was re-pointed at whatever is selected: its frames
  -- must never be stored under that other item
  K.batch_item_done(model("{x}"))
  eq(#K.batch.done, 0); eq(K.batch.failed, 1); eq(rec.begun[#rec.begun].take, "b", "the batch moved on")
end) end)

test("batch_moves_on_when_its_analysis_was_dropped", function() with_batch(function(rec)
  local K, st = S.K, S.state
  K.batch_start(entries3())
  K.release_analysis()   -- something else in the window dropped the running analysis
  K.analysis_tick()
  eq(K.batch.failed, 1); eq(rec.begun[#rec.begun].take, "b"); eq(st.is_analyzing, true)
end) end)

test("batch_keeps_each_items_key_and_scale", function() with_batch(function()
  local K, st = S.K, S.state
  st.session_takes["{a}"] = { key_idx = 5, scale_idx = 3, notes = {}, results = {} }
  local ok, err = pcall(function()
    K.batch_start(entries3())
    local m = model("{a}"); m.key_idx, m.scale_idx = 1, 1   -- what the open item had when the batch started
    K.batch_item_done(m)
    eq(K.batch.done[1].data.key_idx, 5, "the item's own key"); eq(K.batch.done[1].data.scale_idx, 3)
    local n = model("{b}"); n.key_idx, n.scale_idx = 1, 1
    K.batch_item_done(n)
    eq(K.batch.done[2].data.key_idx, 1, "an item analysed for the first time takes the current key")
  end)
  st.session_takes["{a}"] = nil
  if not ok then error(err, 0) end
end) end)

test("batch_fails_a_long_item_that_gave_no_audio", function() with_batch(function(rec)
  local K, st = S.K, S.state
  K.batch_start(entries3())
  st.results, st.sample_rate, st.end_time, st.current_time = {}, 48000, 5, 6   -- five seconds, read to the end, no frame
  st.analysis_params = { block_size = 1024, hop_size = 512, threshold = 0.1, min_freq = 65, max_freq = 1000 }
  K.analysis_tick()
  st.analysis_params = nil
  eq(#K.batch.done, 0, "never stored as an analysis without notes"); eq(K.batch.failed, 1)
  eq(rec.begun[#rec.begun].take, "b")
end) end)

-- A new analysis starts the item at the defaults (spec: "Always defaults", 2026-11-24): its values go back to
-- DEFAULTS, Separation included (it splits at 50%), and only its Key and Scale are kept
local ITEM_VALS = { correct_mode = 2, tighten = 0.3, tolerance = 33, retune_speed = 77, slide_in = 0.4 }
-- The running analysis reaches its end on the next tick (nothing left to read)
local function at_analysis_end(st)
  st.is_analyzing, st.results, st.sample_rate, st.end_time, st.current_time = true, {}, 48000, 0, 0
  st.analysis_params = { block_size = 1024, hop_size = 512, threshold = 0.1, min_freq = 65, max_freq = 1000 }
end
local function analysed_before(guid)
  local ov = {}
  for k, v in pairs(ITEM_VALS) do ov[k] = v end
  return { guid = guid, name = guid, overrides = ov, separation = 0.8, key_idx = 5, scale_idx = 3, notes = {}, results = {} }
end
local function check_defaults(data, what)
  for _, k in ipairs(S.K.ITEM_KEYS) do eq(S.K.item_value(data, k), S.DEFAULTS[k], what .. ": " .. k .. " at its default") end
end

test("reanalyse_resets_the_values_and_keeps_key_and_scale", function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.separation, st.key_idx, st.scale_idx, st.results, st.notes, st.sample_rate,
    st.end_time, st.current_time, #st.session_order, K.open_accessor }
  local ok, err = pcall(function()
    st.session_takes["{z}"] = analysed_before("{z}")
    st.target_take_guid, st.separation, st.key_idx, st.scale_idx = "{z}", 0.8, 5, 3   -- adopt_take_data's mirrors
    reaper.GetMediaItemTake_Source = function() return "src" end
    reaper.GetMediaSourceSampleRate = function() return 48000 end
    reaper.GetSetMediaItemTakeInfo_String = function(_, key) if key == "GUID" then return true, "{z}" end return true, "" end
    K.open_accessor = function() return "acc" end
    eq(K.analysis_begin("z", "item_z", { defer_envelope = true }), true, "the re-analysis starts")
    eq(st.separation, S.DEFAULTS.separation, "it splits at the default Separation, not the item's 80%")
    eq(st.key_idx, 5, "the bar keeps the item's Key"); eq(st.scale_idx, 3)
    at_analysis_end(st)
    K.analysis_tick()
    local data = st.session_takes["{z}"]
    eq(st.is_analyzing, false, "the analysis ended")
    check_defaults(data, "a re-analysed item")
    eq(data.separation, S.DEFAULTS.separation, "Separation 50%")
    eq(data.key_idx, 5, "its own Key"); eq(data.scale_idx, 3, "its own Scale")
  end)
  reaper.GetMediaItemTake_Source, reaper.GetMediaSourceSampleRate, reaper.GetSetMediaItemTakeInfo_String = nil, nil, nil
  st.session_takes["{z}"], st.missing_takes["{z}"], st.stale_takes["{z}"] = nil, nil, nil
  st.raw_cache["{z}"], st.unreadable_takes["{z}"] = nil, nil
  while #st.session_order > saved[10] do table.remove(st.session_order) end
  st.target_take_guid, st.separation, st.key_idx, st.scale_idx, st.results, st.notes, st.sample_rate, st.end_time,
    st.current_time = table.unpack(saved, 1, 9)
  K.open_accessor = saved[11]
  st.is_analyzing, st.analysis_params, st.accessor = false, nil, nil
  if not ok then error(err, 0) end
end)

test("first_analysis_of_a_new_item_uses_the_defaults", function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.separation, st.key_idx, st.scale_idx, st.results, st.notes, st.sample_rate,
    st.end_time, st.current_time, #st.session_order }
  local ok, err = pcall(function()
    st.target_take_guid, st.separation, st.key_idx, st.scale_idx = "{n}", S.DEFAULTS.separation, 4, 2
    K.pending_key["{n}"] = { key_idx = 4, scale_idx = 2 }   -- picked in the bar before the first analysis
    at_analysis_end(st)
    K.analysis_tick()
    local data = st.session_takes["{n}"]
    check_defaults(data, "a new item")
    eq(data.key_idx, 4, "the Key picked"); eq(data.scale_idx, 2); eq(data.key_source, "picked")
    eq(K.pending_key["{n}"], nil, "dropped once analysed")
  end)
  K.pending_key["{n}"] = nil
  st.session_takes["{n}"], st.missing_takes["{n}"], st.stale_takes["{n}"] = nil, nil, nil
  while #st.session_order > saved[10] do table.remove(st.session_order) end
  st.target_take_guid, st.separation, st.key_idx, st.scale_idx, st.results, st.notes, st.sample_rate, st.end_time,
    st.current_time = table.unpack(saved, 1, 9)
  st.is_analyzing, st.analysis_params = false, nil
  if not ok then error(err, 0) end
end)

test("batch_reanalyse_resets_the_values_and_keeps_key_and_scale", function() with_batch(function(rec)
  local K, st = S.K, S.state
  local saved = { st.separation, st.key_idx, st.scale_idx }
  local ok, err = pcall(function()
    st.session_takes["{a}"] = analysed_before("{a}")
    st.separation, st.key_idx, st.scale_idx = 0.2, 1, 1   -- the open item (not a) when the batch starts
    K.batch_start(entries3())
    eq(rec.begun[1].sep, S.DEFAULTS.separation, "a is split at the default Separation, not its own 80%")
    eq(rec.begun[1].key_idx, 5, "its own Key"); eq(rec.begun[1].scale_idx, 3)
    at_analysis_end(st)
    K.analysis_tick()   -- a is finished through the real path (process_analysis_step, batch_item_done)
    local data = K.batch.done[1].data
    check_defaults(data, "an item of a batch")
    eq(data.key_idx, 5); eq(data.scale_idx, 3)
    -- the model handed over lacks Key and Scale (it was built some other way): they still come from the item
    st.session_takes["{b}"] = analysed_before("{b}")
    K.batch_item_done(model("{b}"))
    local b = K.batch.done[2].data
    eq(b.key_idx, 5, "b's Key"); eq(b.scale_idx, 3, "b's Scale")
    eq(K.item_value(b, "tighten"), nil, "no value of the old model is carried")
  end)
  st.session_takes["{a}"], st.session_takes["{b}"] = nil, nil
  st.separation, st.key_idx, st.scale_idx = table.unpack(saved, 1, 3)
  st.analysis_params = nil
  if not ok then error(err, 0) end
end) end)

test("batch_stored_analysis_not_loaded_yet_keeps_only_its_key", function() with_batch(function(rec)
  local K, st = S.K, S.state
  local saved = { st.separation, st.key_idx, st.scale_idx }
  local stored = K.take_json(analysed_before("{a}"))   -- a holds an analysis the window has not loaded (pasted later)
  reaper.GetSetMediaItemTakeInfo_String = function(take, key)
    if key == "GUID" then return true, "{" .. take .. "}" end
    return true, take == "a" and stored or ""
  end
  local ok, err = pcall(function()
    eq(st.session_takes["{a}"], nil, "not loaded")
    K.batch_start(entries3())
    eq(rec.begun[1].sep, S.DEFAULTS.separation, "split at the default"); eq(rec.begun[1].key_idx, 5, "its stored Key")
    at_analysis_end(st)
    K.analysis_tick()
    local data = K.batch.done[1].data
    check_defaults(data, "a stored item"); eq(data.key_idx, 5); eq(data.scale_idx, 3)
  end)
  reaper.GetSetMediaItemTakeInfo_String = nil
  st.raw_cache["{a}"], st.unreadable_takes["{a}"] = nil, nil
  st.separation, st.key_idx, st.scale_idx = table.unpack(saved, 1, 3)
  st.analysis_params = nil
  if not ok then error(err, 0) end
end) end)

test("batch_first_analysis_takes_the_defaults_and_the_picked_key", function() with_batch(function(rec)
  local K, st = S.K, S.state
  local saved = { st.separation, st.key_idx, st.scale_idx }
  local ok, err = pcall(function()
    K.pending_key["{a}"] = { key_idx = 2, scale_idx = 4 }   -- picked in the bar before its first analysis
    st.session_takes["{o}"] = analysed_before("{o}")   -- the open item, with values of its own
    st.target_take_guid, st.separation, st.key_idx, st.scale_idx = "{o}", 0.8, 5, 3
    K.batch_start(entries3())
    eq(rec.begun[1].sep, S.DEFAULTS.separation, "a new item is split at the default Separation")
    eq(rec.begun[1].key_idx, 2); eq(rec.begun[1].scale_idx, 4)
    at_analysis_end(st)
    K.analysis_tick()
    local data = K.batch.done[1].data
    check_defaults(data, "a new item of a batch")
    eq(data.key_idx, 2, "the picked Key"); eq(data.scale_idx, 4); eq(data.key_source, "picked")
    eq(rec.begun[2].key_idx, 0, "an item with no key picked shows none while it is read")
  end)
  K.pending_key["{a}"] = nil
  st.session_takes["{o}"] = nil
  st.separation, st.key_idx, st.scale_idx = table.unpack(saved, 1, 3)
  st.analysis_params = nil
  if not ok then error(err, 0) end
end) end)

test("batch_request_asks_about_notes_the_list_does_not_know", function()
  local st = S.state
  with_selection({ { take = "a", name = "A" }, { take = "b", name = "B", track = "Dbl" } }, function()
    -- b holds a stored analysis the script has not loaded (pasted after the script started)
    reaper.GetSetMediaItemTakeInfo_String = function(tk, key)
      if key == "GUID" then return true, "{" .. tk .. "}" end
      return true, tk == "b" and "{stored}" or ""
    end
    S.K.batch_request()
    local c = st.confirm
    st.confirm = nil
    eq(type(c), "table", "asked first"); eq(c.id, "batch"); eq(#c.list, 1); eq(c.list[1].name, "B")
  end)
end)

-- The window: the held closing message, the batch's status line, the confirm's list
test("status_hold_stays_until_released", function()
  local K, st = S.K, S.state
  local now = 100
  reaper.time_precise = function() return now end
  st.frame.take, st.target_take_name = nil, nil
  K.status_hold("Analyzed 12 items.")
  now = 10000
  eq(K.status_line(false), "Analyzed 12 items.", "still there long after the usual four seconds")
  K.status_release()
  eq(K.status_line(false) ~= "Analyzed 12 items.", true, "gone after the next input")
  st.status.text, st.status.until_time, st.status.hold = "plain", now + 4, nil
  K.status_release()
  eq(st.status.text, "plain", "releasing does not touch an ordinary message")
  reaper.time_precise = nil
  st.status.text = ""
end)

test("batch_status_line", function()
  local K, st = S.K, S.state
  reaper.time_precise = function() return 0 end
  st.status.text, st.status.hold = "", nil
  K.batch = K.batch_new({ { len = 10, name = "A" }, { len = 30, name = "V Main Verse 3" } })
  K.batch.index, K.batch.done_len, st.is_analyzing, st.progress = 2, 10, true, 0.5
  local ok, err = pcall(function()
    eq(K.status_line(false), "", "a batch's progress is in the Analysis card, not the status line")
  end)
  K.batch, st.is_analyzing, st.progress = nil, false, 0
  reaper.time_precise = nil
  if not ok then error(err, 0) end
end)

test("confirm_carries_the_list", function()
  local st = S.state
  local req = S.K.batch_confirm({ { guid = "{a}", name = "A", track = "Vox", pos = 1, has_notes = true }, { guid = "{b}", name = "B", has_notes = false } })
  req.id, req.on_confirm = "batch", function() end
  S.request_confirm(req)
  eq(st.confirm.id, "batch"); eq(#st.confirm.list, 1); eq(st.confirm.list[1].name, "A")
  eq(st.confirm.after_lines[1], "Its values go back to the defaults; Key and Scale stay.")
  eq(st.confirm.after_lines[2], MOD .. "+Z restores all 2 items in one step once the batch has finished.")
  st.confirm = nil
end)

-- Undo takes a batch's items out of the list; redo must bring every one of them back, not only the open item
test("sync_brings_back_a_redone_analysis", function()
  local K, st = S.K, S.state
  local data = { guid = "{a}", name = "A", results = { { time = 0, note = 60 } }, notes = {}, item_len = 1, sample_rate = 48000 }
  local json = K.take_json(data)
  local raw, changes = json, 1
  reaper.GetProjectStateChangeCount = function() return changes end
  reaper.GetMediaItemTakeByGUID = function(_, guid) return guid == "{a}" and "a" or nil end
  reaper.GetSetMediaItemTakeInfo_String = function(_, key)
    if key == "GUID" then return true, "{a}" end
    return true, raw
  end
  local saved = { st.target_take_guid, st.last_change_count, #st.session_order }
  st.target_take_guid = "{other}"
  st.session_takes["{a}"], st.raw_cache["{a}"] = data, json
  st.session_order[#st.session_order + 1] = "{a}"
  local ok, err = pcall(function()
    K.drop_project_cache()
    raw, changes = "", 2           -- the batch was undone: the take holds no analysis
    st.last_change_count = 1
    S.sync_with_project()
    eq(st.session_takes["{a}"], nil, "undone: out of the list")
    K.drop_project_cache()
    raw, changes = json, 3         -- and redone
    S.sync_with_project()
    eq(type(st.session_takes["{a}"]), "table", "redone: back in the list")
    eq(st.session_order[#st.session_order], "{a}")
    K.drop_project_cache()
    changes = 4                    -- a later change does not list it twice
    S.sync_with_project()
    local listed = 0
    for _, g in ipairs(st.session_order) do if g == "{a}" then listed = listed + 1 end end
    eq(listed, 1)
  end)
  reaper.GetProjectStateChangeCount, reaper.GetMediaItemTakeByGUID, reaper.GetSetMediaItemTakeInfo_String = nil, nil, nil
  st.session_takes["{a}"], st.raw_cache["{a}"], st.unreadable_takes["{a}"] = nil, nil, nil
  while #st.session_order > saved[3] do table.remove(st.session_order) end
  st.target_take_guid, st.last_change_count = saved[1], saved[2]
  if st.undone_takes then st.undone_takes["{a}"] = nil end
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

-- A held closing message describes the analyses as the batch left them: it ends when an undo or a redo changes one,
-- not on any other change in REAPER
test("held_message_goes_when_an_analysis_changes", function()
  local K, st = S.K, S.state
  local data = { guid = "{a}", name = "A", results = { { time = 0, note = 60 } }, notes = {}, item_len = 1, sample_rate = 48000 }
  local json = K.take_json(data)
  local raw, changes = json, 5
  reaper.GetProjectStateChangeCount = function() return changes end
  reaper.GetMediaItemTakeByGUID = function(_, guid) return guid == "{a}" and "a" or nil end
  reaper.GetSetMediaItemTakeInfo_String = function(_, key)
    if key == "GUID" then return true, "{a}" end
    return true, raw
  end
  local saved = { st.target_take_guid, st.last_change_count, #st.session_order }
  st.target_take_guid = "{other}"
  st.session_takes["{a}"], st.raw_cache["{a}"] = data, json
  st.session_order[#st.session_order + 1] = "{a}"
  local ok, err = pcall(function()
    K.drop_project_cache()
    K.status_hold("Analyzed 3 items.")
    st.last_change_count = nil     -- as a batch leaves it: the next frame reads the project again
    S.sync_with_project()
    eq(st.status.text, "Analyzed 3 items.", "the batch's own resync keeps it")
    K.drop_project_cache()
    changes = 6                    -- the edit cursor moved, a fader was touched: no analysis changed
    S.sync_with_project()
    eq(st.status.text, "Analyzed 3 items.", "another change in REAPER keeps it")
    K.drop_project_cache()
    raw, changes = "", 7           -- Cmd+Z: the item is not analysed any more
    S.sync_with_project()
    eq(st.status.text, "", "gone once an analysis changed")
  end)
  reaper.GetProjectStateChangeCount, reaper.GetMediaItemTakeByGUID, reaper.GetSetMediaItemTakeInfo_String = nil, nil, nil
  st.session_takes["{a}"], st.raw_cache["{a}"], st.unreadable_takes["{a}"], st.undone_takes["{a}"] = nil, nil, nil, nil
  while #st.session_order > saved[3] do table.remove(st.session_order) end
  st.target_take_guid, st.last_change_count, st.status.text, st.status.hold = saved[1], saved[2], "", nil
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

-- New items start at the defaults; per-item values ("Always defaults", 2026-11-24) ---------------------------------
test("item_seed_fills_all_with_the_defaults", function()
  local K = S.K
  local data = {}
  eq(K.item_seed(data), true, "first seed fills")
  for _, key in ipairs(K.ITEM_KEYS) do
    local v = (key == "separation") and data.separation or (data.overrides and data.overrides[key])
    if v == nil then error("missing " .. key) end
    eq(v, S.DEFAULTS[key], key)
  end
  -- no key: the real key not set (0) stands for, the hand key here (no track): never 0
  local want_key, want_scale = K.key_resolve(0, nil, nil)
  eq(data.key_idx, want_key, "key_idx: the hand key")
  eq(data.scale_idx, want_scale, "scale_idx: the hand scale")
  eq(K.item_seed(data), false, "second seed fills nothing")
end)

test("new_item_ignores_old_starting_values_in_extstate", function()
  -- ExtState written by 2.22 builds before "Always defaults": the user's old starting values
  local old = { pitch_tighten = "0.85", pitch_slide_in = "0.5", pitch_tolerance = "12", pitch_start_separation = "1",
    pitch_correct_mode = "1", pitch_retune_speed = "0.4", pitch_key_idx = "5", pitch_scale_idx = "3",
    pitch_key_hand_idx = "5", pitch_scale_hand_idx = "3" }
  for k in pairs(ext_asked) do ext_asked[k] = nil end
  local T = load_script(old)
  reaper.GetExtState = function() return "" end   -- the harness's own stub again
  local K, st, D = T.K, T.state, T.DEFAULTS
  for _, key in ipairs({ "pitch_tighten", "pitch_slide_in", "pitch_tolerance", "pitch_start_separation",
      "pitch_correct_mode", "pitch_retune_speed" }) do
    eq(ext_asked[key], nil, key .. " is not read any more")
  end
  eq(T.global_defaults, nil, "no starting values")
  eq(st.separation, D.separation, "the window shows the default Separation")
  eq(ext_asked.pitch_key_idx, nil, "the Key for new items is not read any more")
  eq(ext_asked.pitch_scale_idx, nil)
  eq(st.key_idx, 0, "nothing open: no key set"); eq(st.scale_idx, 1)
  local data = { notes = {}, results = {} }
  K.item_seed(data)
  for _, key in ipairs(K.ITEM_KEYS) do eq(K.item_value(data, key), D[key], "a new item's " .. key) end
  eq(data.key_idx, 5, "no key found: the one last chosen by hand"); eq(data.scale_idx, 3)
  eq(T.get_effective(nil, "tighten"), D.tighten, "nothing open: the default")
end)

test("seed_old_take_same_build", function()
  local st, K = S.state, S.K
  local saved = { st.target_take_guid, st.session_takes["{old}"] }
  local n1, n2 = slide_note(1, 0), slide_note(1, 0)
  n1.controls.retune_speed, n2.controls.retune_speed = nil, nil
  local data = { notes = { n1 }, results = {} }
  st.session_takes["{old}"], st.target_take_guid = data, "{old}"
  local ok, err = pcall(function()
    local before = K.correction_build({ n1 }, 1)
    K.item_seed(data)
    local after = K.correction_build({ n2 }, 1)
    eq(#after.points, #before.points, "point count")
    for i, p in ipairs(before.points) do
      near(after.points[i].time, p.time, 1e-12, "time " .. i)
      near(after.points[i].val, p.val, 1e-12, "val " .. i)
    end
  end)
  st.target_take_guid, st.session_takes["{old}"] = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("item_seed_keeps_existing", function()
  local data = { separation = 0.2, overrides = { tighten = 0.3 } }
  S.K.item_seed(data)
  eq(data.separation, 0.2, "separation")
  eq(data.overrides.tighten, 0.3, "tighten")
end)

-- Saved defaults: track -> system -> factory (2026-11-25) ------------------------------------------------------------
-- track_json: what the track of take {t} holds under its Track Default key (nil: the take has no track)
local function with_track(track_json, sys, fn)
  local K = S.K
  local saved_sys = K.sys_defaults
  local ext = {}
  K.sys_defaults = sys or {}
  reaper.GetMediaItemTakeByGUID = function(_, guid) return guid == "{t}" and "take_t" or nil end
  reaper.GetMediaItemTake_Track = function(take) return (take == "take_t" and track_json) and "track_t" or nil end
  reaper.GetSetMediaTrackInfo_String = function(track, key, value, set)
    if track ~= "track_t" or key ~= K.TRACK_DEFAULT_KEY then return false, "" end
    if set then track_json = value end
    return true, track_json or ""
  end
  reaper.SetExtState = function(_, key, value) ext[key] = value end
  reaper.DeleteExtState = function(_, key) ext[key] = "deleted" end
  K.drop_project_cache()
  local ok, err = pcall(fn, ext, function() return track_json end)
  for _, name in ipairs({ "GetMediaItemTakeByGUID", "GetMediaItemTake_Track", "GetSetMediaTrackInfo_String",
    "SetExtState", "DeleteExtState" }) do reaper[name] = nil end
  K.sys_defaults = saved_sys
  K.drop_project_cache()
  if not ok then error(err, 0) end
end

test("saved_defaults_levels", function()
  local K, D = S.K, S.DEFAULTS
  with_track(nil, nil, function()
    local v, lvl = K.item_default("tolerance", "{t}")
    eq(v, D.tolerance); eq(lvl, "factory")
  end)
  with_track(nil, { tolerance = 20, tighten = 0.4 }, function()
    local v, lvl = K.item_default("tolerance", "{t}")
    eq(v, 20); eq(lvl, "system")
  end)
  with_track('{"tolerance":12}', { tolerance = 20, tighten = 0.4 }, function()
    local v, lvl = K.item_default("tolerance", "{t}")
    eq(v, 12, "the track's"); eq(lvl, "track")
    v, lvl = K.item_default("tighten", "{t}")
    eq(v, 0.4, "a key the track does not set: the system's"); eq(lvl, "system")
    v, lvl = K.item_default("slide_in", "{t}")
    eq(v, D.slide_in); eq(lvl, "factory")
    v, lvl = K.item_default("tolerance", "{gone}")
    eq(v, 20, "a take with no track: the system's"); eq(lvl, "system")
  end)
end)

test("saved_defaults_invalid_ignored", function()
  local K, D = S.K, S.DEFAULTS
  eq(K.item_value_valid("tolerance", "abc"), nil); eq(K.item_value_valid("tolerance", "nan"), nil)
  eq(K.item_value_valid("tolerance", 999), 50, "clamped"); eq(K.item_value_valid("tighten", -1), 0, "clamped")
  eq(K.item_value_valid("correct_mode", 1.5), nil); eq(K.item_value_valid("correct_mode", 2), 2)
  eq(K.item_value_valid("key_idx", 3), nil, "Key is never a default")
  with_track('{"tolerance":"x","correct_mode":7,"tighten":0.25}', nil, function()
    eq(K.item_default("tolerance", "{t}"), D.tolerance); eq(K.item_default("correct_mode", "{t}"), D.correct_mode)
    eq(K.item_default("tighten", "{t}"), 0.25)
  end)
  with_track("not json", nil, function() eq(K.item_default("tighten", "{t}"), D.tighten) end)
end)

test("item_seed_uses_track_default", function()
  local K, D = S.K, S.DEFAULTS
  with_track('{"tolerance":12,"separation":0.7}', { correct_mode = 2 }, function()
    local data = { guid = "{t}" }
    K.item_seed(data)
    eq(data.overrides.tolerance, 12); eq(data.separation, 0.7); eq(data.overrides.correct_mode, 2)
    eq(data.overrides.tighten, D.tighten)
    eq(K.item_off_defaults(data), 0, "at its own defaults")
    data.overrides.tolerance = D.tolerance
    eq(K.item_off_defaults(data), 1, "the factory value differs from the track's")
    K.item_reset_values(data)
    eq(data.overrides.tolerance, 12, "reset goes to the track default")
  end)
end)

test("unanalysed_take_shows_its_track_default", function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.separation }
  with_track('{"tighten":0.3,"separation":0.8}', nil, function()
    st.target_take_guid = "{t}"
    eq(S.get_effective(nil, "tighten"), 0.3, "not analysed: its track's default")
    eq(S.get_override_level(nil, "tighten"), "default")
    K.adopt_new_item_values()
    eq(st.separation, 0.8, "the Separation its first analysis uses")
  end)
  st.target_take_guid, st.separation = saved[1], saved[2]
end)

-- The open item {t}, analysed, with `overrides` and Separation `sep`, while fn runs
local function with_open_t(overrides, sep, fn)
  local st = S.state
  local saved = { st.target_take_guid, st.session_takes["{t}"], st.status.text, st.confirm }
  st.target_take_guid = "{t}"
  st.session_takes["{t}"] = { guid = "{t}", notes = {}, results = {}, separation = sep, overrides = overrides }
  reaper.time_precise = function() return 0 end
  local ok, err = pcall(fn)
  reaper.time_precise = nil
  st.target_take_guid, st.session_takes["{t}"], st.status.text, st.confirm = saved[1], saved[2], saved[3], saved[4]
  if not ok then error(err, 0) end
end

test("set_track_default_one_undo", function()
  local K = S.K
  with_track('{"tighten":0.2}', nil, function(_, track_json)
    local labels = {}
    reaper.Undo_BeginBlock = function() end
    reaper.Undo_EndBlock = function(label) labels[#labels + 1] = label end
    with_open_t({ tolerance = 15, tighten = 0.5, correct_mode = 1, retune_speed = 1, slide_in = 0 }, 0.6, function()
      eq(K.set_track_default({ "tolerance" }), true)
      eq(labels[1], "Set Tolerance as track default", "one undo point")
      local t = S.K.track_defaults("track_t")
      eq(t.tolerance, 15); eq(t.tighten, 0.2, "the track's other keys stay")
      eq(K.default_reason({ "tolerance" }, "track"), "Already the track default")
      eq(K.set_track_default(nil), true)
      eq(labels[2], "Set track default")
      eq(K.track_defaults("track_t").separation, 0.6)
      eq(K.clear_track_default(), true); eq(labels[3], "Clear track default")
      eq(track_json(), "", "cleared"); eq(K.clear_track_reason(), "No track default")
    end)
    reaper.Undo_BeginBlock, reaper.Undo_EndBlock = nil, nil
  end)
end)

test("sys_default_request_saves_on_confirm", function()
  local K = S.K
  with_track(nil, nil, function(ext)
    with_open_t({ tolerance = 15, tighten = 0, correct_mode = 0, retune_speed = 1, slide_in = 0 }, 0.5, function()
      eq(K.default_reason({ "tighten" }, "system"), "Already the system default", "equals the factory value")
      eq(K.default_reason({ "tolerance" }, "system"), nil)
      local req = K.sys_default_request({ "tolerance" })
      eq(req.title, "Make Tolerance 15\xC2\xA2 your System Default?")
      eq(req.body_lines[1], "New analyses on tracks without a Track Default start with: Tolerance 15\xC2\xA2 (was Tolerance 8\xC2\xA2).")
      eq(next(ext), nil, "nothing saved before the confirm")
      req.on_confirm()
      eq(ext.pitch_def_tolerance, "15"); eq(K.sys_defaults.tolerance, 15)
      eq(K.item_default("tolerance", "{t}"), 15, "the item on a track without a default follows it")
      eq(K.sys_defaults_changed(), 1)
      K.sys_defaults_clear()
      eq(ext.pitch_def_tolerance, "deleted"); eq(K.sys_defaults_changed(), 0)
    end)
  end)
end)

test("unanalysed_take_takes_the_defaults", function()
  local st = S.state
  local saved = { st.separation, st.key_idx, st.scale_idx }
  st.separation, st.key_idx, st.scale_idx = 0.1, 9, 3
  S.K.adopt_new_item_values()
  local got = { st.separation, st.key_idx, st.scale_idx }
  st.separation, st.key_idx, st.scale_idx = table.unpack(saved)
  eq(got[1], S.DEFAULTS.separation, "separation")
  eq(got[2], 0, "key_idx: not set")
  eq(got[3], 1, "scale_idx")
end)

-- Item values reach every note (value levels, Task 2) --------------------------------------------------------------
local function with_item(overrides, fn)   -- runs fn with an open item whose own values are `overrides`
  local st = S.state
  local saved = { st.target_take_guid, st.session_takes["{IV}"] }
  st.target_take_guid = "{IV}"
  st.session_takes["{IV}"] = { overrides = overrides }
  local ok, err = pcall(fn)
  st.target_take_guid, st.session_takes["{IV}"] = saved[1], saved[2]
  if not ok then error(err, 0) end
end

local function wobbly_untouched(t0)   -- an unedited note whose body wobbles (so Tighten has something to take)
  return wobbly(untouched_note(t0 or 0.1, 0.4, 60), nil, nil)
end

test("item_tighten_reaches_unedited", function()
  with_item({ tighten = 1, tolerance = 0 }, function()
    local n = wobbly_untouched()
    local build = S.K.correction_build({ n }, 10)
    if #build.points == 0 then error("the unedited note is not corrected") end
    local a, b = S.K.note_body(n)
    for i = a, b do near(n.frames[i].note + n.frame_shifts[i], 60, 1e-9, "flat at frame " .. i) end
  end)
end)

test("note_zero_survives_load", function()
  local ctrl = {}
  S.K.controls_load(ctrl, { tighten = 0 })
  eq(ctrl.tighten, 0, "0 is a value of its own")
  with_item({ tighten = 0.4, tolerance = 0 }, function()
    local n = wobbly_untouched()
    n.controls.tighten = ctrl.tighten
    S.K.correction_build({ n }, 10)
    for i = 1, #n.frames do near(n.frame_shifts[i], 0, 1e-12, "as sung at frame " .. i) end
    local follows = wobbly_untouched()
    S.K.correction_build({ follows }, 10)
    local moved = false
    for i = 1, #follows.frames do if math.abs(follows.frame_shifts[i]) > 1e-6 then moved = true end end
    eq(moved, true, "a note without its own Tighten takes the item's")
  end)
end)

test("bypassed_untouched", function()
  with_item({ tighten = 1, tolerance = 0, slide_in = 1 }, function()
    local n = wobbly_untouched()
    n.controls.bypassed = true
    local build = S.K.correction_build({ n }, 10)
    for i = 1, #n.frames do eq(n.frame_shifts[i], 0, "frame " .. i) end
    eq(#build.points, 0, "points")
  end)
end)

test("item_mode_reaches_unedited", function()
  with_item_mode(2, function()
    eq(S.K.note_mode(untouched_note(0.5)), "hard")
    local b = untouched_note(0.9)
    b.controls.bypassed = true
    eq(S.K.note_mode(b), nil, "bypassed")
  end)
end)

test("fresh_item_as_sung", function()
  local st = S.state
  local notes = { wobbly_untouched(0.1) }
  notes[2] = untouched_note(notes[1].end_time, 0.3, 62, { from = 60, dur = 0.04 })
  notes[3] = wobbly(untouched_note(notes[2].end_time + 0.3, 0.4, 64), nil, nil)
  local data = { notes = notes, results = {} }
  S.K.item_seed(data)
  local saved = { st.target_take_guid, st.session_takes["{fresh}"] }
  st.target_take_guid, st.session_takes["{fresh}"] = "{fresh}", data
  local ok, err = pcall(function()
    local build = S.K.correction_build(notes, 10)
    for i, p in ipairs(build.points) do near(p.val, 0, 1e-12, "point " .. i) end
    for k, n in ipairs(notes) do
      for i = 1, #n.frames do near(n.frame_shifts[i], 0, 1e-12, "note " .. k .. " frame " .. i) end
    end
  end)
  st.target_take_guid, st.session_takes["{fresh}"] = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("item_slide_in_reaches_unedited", function()
  with_item({ slide_in = 1 }, function()
    local n = slide_note(1, nil)
    n.controls.center_pitch, n.controls.retune_speed = 60, nil
    S.K.correction_build({ n }, 1)
    local target = n.frames[7].note + n.frame_shifts[7]
    for i = 1, 6 do near(n.frames[i].note + n.frame_shifts[i], target, 1e-9, "frame " .. i) end
  end)
end)

test("merge_tighten_effective", function()
  with_item({ tighten = 1 }, function()
    local a, b = join_note(0.1, 0.3, 60, 0), join_note(0.4, 0.3, 60, 0)
    a.controls.tighten = 0.5
    near(S.K.controls_merge({ a, b }).tighten, 0.75, 1e-9, "the other note's is the item's")
    a.controls.tighten = nil
    eq(S.K.controls_merge({ a, b }).tighten, nil, "no own value: the merged note follows the item")
    a.controls.tighten = 0
    near(S.K.controls_merge({ a, b }).tighten, 0.5, 1e-9, "an own 0 counts")
  end)
end)

test("mode_unused_item_level", function()
  with_item_mode(2, function() eq(S.K.mode_unused("tighten", {}, 0), "hard", "the item's mode, nothing selected") end)
  with_item_mode(1, function() eq(S.K.mode_unused("tolerance", {}, 0), "mode") end)
  eq(S.K.mode_unused("tighten", {}, 0), nil, "Natural uses it")
end)

test("mode_own_and_status", function()
  local own, moved, untouched = join_note(0.1, 0.3, 60, 0.3), join_note(0.5, 0.3, 60, 0.3), untouched_note(0.9)
  own.controls.correct_mode = 0
  local byp = untouched_note(1.3)
  byp.controls.correct_mode, byp.controls.bypassed = 1, true
  eq(S.K.mode_own_count({ own, moved, untouched, byp }), 1, "notes with a mode of their own, not bypassed")
  eq(S.K.mode_item_status(0, 0), "Mode: Natural for this item. Every note uses it")
  eq(S.K.mode_item_status(1, 12), "Mode: Classic for this item (12 notes with their own mode)")
  eq(S.K.mode_item_status(2, 1), "Mode: Hard for this item (1 note with its own mode)")
end)

-- The bar edits this item or the notes; its values never reach ExtState (value levels, Task 3) ---------------------
local function with_no_project(fn)   -- runs fn where an envelope write finds no take (it says so and writes nothing)
  local saved = { reaper.time_precise, reaper.CountMediaItems }
  reaper.time_precise = function() return 0 end
  reaper.CountMediaItems = function() return 0 end
  local ok, err = pcall(fn)
  reaper.time_precise, reaper.CountMediaItems = saved[1], saved[2]
  if not ok then error(err, 0) end
end

test("reset_item_to_default", function()
  with_no_project(function() with_item({ tolerance = 30 }, function()
    eq(type(S.K.reset_target("tolerance", {}, 0)), "boolean", "returns a boolean")
    eq(S.state.session_takes["{IV}"].overrides.tolerance, S.DEFAULTS.tolerance, "the item's value")
  end) end)
end)

test("value_defaults_are_the_users", function()
  local D = S.DEFAULTS
  eq(D.separation, 0.5); eq(D.tighten, 0); eq(D.tolerance, 8); eq(D.retune_speed, 1.0); eq(D.slide_in, 0)
  eq(D.correct_mode, 0, "Natural")
end)

test("reset_item_at_default_no_undo", function() with_write_stubs({}, function(rec)
  local st = S.state
  local saved = { st.target_take_guid, st.notes, reaper.time_precise }
  reaper.time_precise = function() return 0 end
  local data = { guid = "{a}", name = "{a}", notes = {}, results = {}, item_len = 1, sample_rate = 48000,
    overrides = { tolerance = S.DEFAULTS.tolerance, tighten = 0.3 } }
  st.target_take_guid, st.session_takes["{a}"], st.notes = "{a}", data, {}
  local ok, err = pcall(function()
    eq(S.K.reset_target("tolerance", {}, 0), false, "already at the default")
    eq(#rec.labels, 0, "no undo point")
    eq(S.K.reset_target("tighten", {}, 0), true, "written")
    eq(data.overrides.tighten, S.DEFAULTS.tighten, "Tighten to its default")
    eq(#rec.labels, 1, "a reset that changes the value: one undo point"); eq(rec.labels[1], "Reset Tighten")
  end)
  st.target_take_guid, st.notes, reaper.time_precise = saved[1], saved[2], saved[3]
  if not ok then error(err, 0) end
end) end)

test("reset_notes_to_item", function()
  with_no_project(function() with_item({ tolerance = 30 }, function()
    local a, b = { controls = { tolerance = 5 } }, { controls = { tolerance = 9, tighten = 0 } }
    S.K.reset_target("tolerance", { a, b }, 2)
    eq(a.controls.tolerance, nil, "first note follows the item")
    eq(b.controls.tolerance, nil, "second note follows the item")
    eq(b.controls.tighten, 0, "other values kept")
    eq(S.state.session_takes["{IV}"].overrides.tolerance, 30, "the item's value is untouched")
  end) end)
end)

test("bar_values_write_no_extstate", function()
  local K = S.K
  local saves, ext = 0, 0
  local save, set_ext, sep = K.save_settings, reaper.SetExtState, S.state.separation
  K.save_settings = function() saves = saves + 1 end
  reaper.SetExtState = function() ext = ext + 1 end
  local ok, err = pcall(with_no_project, function() with_item({ tolerance = 8 }, function()
    local data = S.state.session_takes["{IV}"]
    K.bar_write("tolerance", 20, {}, 0)
    eq(data.overrides.tolerance, 20, "the item's value")
    K.bar_write("correct_mode", 0, {}, 0)
    eq(data.overrides.correct_mode, 0, "Natural is stored as the item's mode")
    K.bar_write("separation", 0.7, {}, 0)
    eq(data.separation, 0.7, "the item's Separation")
    K.reset_target("tolerance", {}, 0)
  end) end)
  K.save_settings, reaper.SetExtState, S.state.separation = save, set_ext, sep
  if not ok then error(err, 0) end
  eq(saves, 0, "K.save_settings calls")
  eq(ext, 0, "SetExtState calls")
end)

test("bar_write_note_zero", function()
  with_item({ tighten = 0.4 }, function()
    local n = { controls = {} }
    S.K.bar_write("tighten", 0, { n }, 1)
    eq(n.controls.tighten, 0, "0 is the note's own value")
    S.K.bar_write("slide_in", 0, { n }, 1)
    eq(n.controls.slide_in, 0, "Slide In 0 too")
    eq(S.state.session_takes["{IV}"].overrides.tighten, 0.4, "the item is untouched")
  end)
end)

test("star_mark_means_differs_from_the_default", function()
  with_item({ tolerance = S.DEFAULTS.tolerance, tighten = 0.4 }, function()
    eq(S.get_override_level(nil, "tolerance"), "default", "at the default: no mark")
    eq(S.get_override_level(nil, "tighten"), "item", "differs from the default: the mark")
    eq(S.get_override_level({ controls = { tighten = 0.1 } }, "tighten"), "note", "a note's own value")
  end)
end)

test("value_changed_no_op", function()
  local vc = S.K.value_changed
  eq(vc(8, 8), false, "same value")
  eq(vc(8, 8 + 1e-12), false, "float noise")
  eq(vc(8, 20), true, "moved")
  eq(vc(0, 0), false, "zero to zero")
  eq(vc(nil, 0), true, "no value to 0")
  eq(vc(nil, nil), false, "nothing to nothing")
end)

test("key_scale_undo_labels", function()
  local st, K = S.state, S.K
  local labels = {}
  local saved = { st.target_take_guid, st.session_takes["{KL}"], st.key_idx, st.scale_idx,
    reaper.GetMediaItemTakeByGUID, reaper.Undo_EndBlock }
  reaper.GetMediaItemTakeByGUID = function() return "TAKE" end
  reaper.Undo_EndBlock = function(label) labels[#labels + 1] = label end
  st.target_take_guid, st.session_takes["{KL}"] = "{KL}", { notes = {}, results = {}, key_idx = 3, scale_idx = 1 }
  st.key_idx, st.scale_idx = 3, 1   -- an analysed item shows its real key
  local ok, err = pcall(function()
    K.scale_changed("key")
    K.scale_changed("scale")
  end)
  st.target_take_guid, st.session_takes["{KL}"], st.key_idx, st.scale_idx,
    reaper.GetMediaItemTakeByGUID, reaper.Undo_EndBlock = table.unpack(saved, 1, 6)
  if not ok then error(err, 0) end
  eq(labels[1], "Set Key", "key")
  eq(labels[2], "Set Scale", "scale")
end)

-- Stretch re-split (K.segment_stretch): three phrases apart; the middle one is a slide
local STRETCH_GAP = { dur = 0.1 }
local function stretch_frames(mid)
  local segs = { { dur = 0.4, note = 55 }, STRETCH_GAP }
  for _, s in ipairs(mid) do segs[#segs + 1] = s end
  segs[#segs + 1] = STRETCH_GAP
  segs[#segs + 1] = { dur = 0.4, note = 67 }
  return frames(segs, HOP)
end

test("segment_stretch_outside_untouched", function()
  local fr = stretch_frames({ { dur = 0.4, note = 64 } })
  local old, old_splits = S.K.segment(fr, 0.5)
  eq(#old, 3, "old notes")
  local new, splits, i0, i1 = S.K.segment_stretch(fr, 0.5, old, old[2].start_time, old[2].end_time, old_splits)
  eq(#new, 3, "new notes")
  eq(rawequal(new[1], old[1]), true, "before is the same table")
  eq(rawequal(new[3], old[3]), true, "after is the same table")
  eq(rawequal(new[2], old[2]), false, "the stretch is split again")
  near(new[2].start_time, old[2].start_time, 1e-9, "stretch start")
  near(new[2].end_time, old[2].end_time, 1e-9, "stretch end")
  eq(i0, 2, "first new")
  eq(i1, 2, "last new")
  eq(#splits, 3, "split points")
  eq(rawequal(splits[1], old_splits[1]), true, "split before kept")
  eq(rawequal(splits[3], old_splits[3]), true, "split after kept")
end)

test("segment_stretch_higher_sep_more_notes", function()
  local fr = stretch_frames(slide_segs(60.6))
  local old, old_splits = S.K.segment(fr, 0.2)
  eq(#old, 3, "joined at 0.2")
  local new, splits, i0, i1 = S.K.segment_stretch(fr, 0.9, old, old[2].start_time, old[2].end_time, old_splits)
  eq(#new, 4, "two notes in the stretch at 0.9")
  eq(rawequal(new[1], old[1]), true, "before")
  eq(rawequal(new[4], old[3]), true, "after")
  eq(i0, 2, "first new")
  eq(i1, 3, "last new")
  eq(#splits, 4, "split points")
  for i = 2, 4 do
    if splits[i].time <= splits[i - 1].time then error("split points out of order at " .. i) end
  end
end)

test("segment_stretch_too_few_frames", function()
  local fr = stretch_frames({ { dur = 0.4, note = 64 } })
  local old = S.K.segment(fr, 0.5)
  local new = S.K.segment_stretch(fr, 0.5, old, 0.45, 0.45 + HOP / 2)
  eq(new, nil, "nothing to split")
end)

test("resplit_stretch_keeps_item_value", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = stretch_frames(slide_segs(60.6))
  local old, old_splits = K.segment(fr, 0.2)
  local data = { guid = "{a}", name = "{a}", notes = old, results = fr, separation = 0.2, item_len = 2,
    sample_rate = 44100 }
  local saved = { st.target_take_guid, st.results, st.notes, st.split_points, st.selected_notes, st.selected_note,
    st.separation, reaper.time_precise, st.status.text }
  reaper.time_precise = function() return 0 end
  st.target_take_guid, st.session_takes["{a}"] = "{a}", data
  st.results, st.notes, st.split_points, st.separation = fr, old, old_splits, 0.2
  st.selected_notes, st.selected_note = { [2] = true }, 2
  local ok, err = pcall(function() K.resplit_stretch(0.9) end)
  local notes, sel, sep, status = st.notes, st.selected_notes, st.separation, st.status.text
  st.target_take_guid, st.results, st.notes, st.split_points, st.selected_notes, st.selected_note,
    st.separation, reaper.time_precise, st.status.text = table.unpack(saved, 1, 9)
  if not ok then error(err, 0) end
  eq(#notes, 4, "notes")
  eq(rawequal(notes[1], old[1]) and rawequal(notes[4], old[3]), true, "outside untouched")
  eq(sel[2] and sel[3] and not sel[1] and not sel[4], true, "the new notes are selected")
  eq(data.separation, 0.2, "item value unchanged")
  eq(sep, 0.2, "bar value unchanged")
  eq(rec.labels[#rec.labels], "Re-split selected notes", "undo label")
  eq(status, "Re-split 1 note into 2.", "status (singular)")
end) end)

-- A stretch at the item's own Separation splits as the item did, also where the stretch is quiet: the silence
-- floor is the whole item's
local function quiet_frames()
  local q, hush = 10 ^ (-45 / 20), 10 ^ (-70 / 20)
  return frames({ { dur = 0.4, note = 55 }, STRETCH_GAP,
    { dur = 0.3, note = 60, lvl = q }, { dur = 0.1, note = 60, lvl = hush }, { dur = 0.3, note = 62, lvl = q },
    STRETCH_GAP, { dur = 0.4, note = 67 } }, HOP)
end

test("segment_stretch_same_sep_same_notes", function()
  for _, case in ipairs({ { stretch_frames(slide_segs(62)), "loud" }, { quiet_frames(), "quiet" } }) do
    local fr, name = case[1], case[2]
    for _, sep in ipairs({ 0.2, 0.5, 0.9 }) do
      local old, old_splits = S.K.segment(fr, sep)
      local first, last = 2, #old - 1
      local new, _, i0, i1 = S.K.segment_stretch(fr, sep, old, old[first].start_time, old[last].end_time, old_splits)
      local tag = name .. " sep " .. sep
      eq(#new, #old, tag .. ": notes")
      eq(i1 - i0, last - first, tag .. ": notes in the stretch")
      for i = i0, i1 do
        eq(new[i].start_time, old[i].start_time, tag .. ": start " .. i)
        eq(new[i].end_time, old[i].end_time, tag .. ": end " .. i)
      end
    end
  end
end)

test("segment_floor_matches_segment", function()
  local fr = quiet_frames()
  local a = S.K.segment(fr, 0.5)
  local b = S.K.segment(fr, 0.5, S.K.segment_floor(fr))
  eq(#b, #a, "notes")
  for i = 1, #a do
    eq(b[i].start_time, a[i].start_time, "start " .. i)
    eq(b[i].end_time, a[i].end_time, "end " .. i)
  end
  eq(S.K.segment_floor({ { time = 0, rms = 0.1, lvl = 0.1 } }), nil, "no pitched frame")
end)

test("resplit_stretch_unchanged_no_undo", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = stretch_frames(slide_segs(60.6))
  local old, old_splits = K.segment(fr, 0.2)
  local data = { guid = "{a}", name = "{a}", notes = old, results = fr, separation = 0.2, item_len = 2,
    sample_rate = 44100 }
  local saved = { st.target_take_guid, st.results, st.notes, st.split_points, st.selected_notes, st.selected_note,
    st.separation, reaper.time_precise, st.status.text }
  reaper.time_precise = function() return 0 end
  st.target_take_guid, st.session_takes["{a}"] = "{a}", data
  st.results, st.notes, st.split_points, st.separation = fr, old, old_splits, 0.2
  st.selected_notes, st.selected_note = { [2] = true }, 2
  -- the item's own value (Reset with notes selected), and another value that gives the same notes
  local ok, err = pcall(function() K.resplit_stretch(0.2); K.resplit_stretch(0.25) end)
  local notes, sel, status = st.notes, st.selected_notes, st.status.text
  st.target_take_guid, st.results, st.notes, st.split_points, st.selected_notes, st.selected_note,
    st.separation, reaper.time_precise, st.status.text = table.unpack(saved, 1, 9)
  if not ok then error(err, 0) end
  eq(#rec.labels, 0, "no undo point")
  eq(rawequal(notes, old), true, "the notes stay")
  eq(sel[2], true, "the selection stays")
  eq(status, "Nothing to re-split.", "status")
end) end)

-- The Values group in three named groups, and the pill menu's reset (task 5) ------------------------------------
test("hdr_plan_widths_ordered", function()
  local saved = { reaper.ImGui_CalcTextSize, reaper.ImGui_GetFrameHeight }
  reaper.ImGui_CalcTextSize = function(_, text) return #text * 7, 13 end
  reaper.ImGui_GetFrameHeight = function() return 20 end
  local ok, err = pcall(function()
    local s = S.measure_header_static()
    local plans = S.K.HDR_PLANS
    eq(#plans, 5, "plans")
    for i = 1, #plans - 1 do
      local a, b = S.hdr_min_content_w(s, false, i), S.hdr_min_content_w(s, false, i + 1)
      if a < b then error(string.format("plan %d (%g) is narrower than plan %d (%g)", i, a, i + 1, b), 0) end
    end
    if S.hdr_min_content_w(s, false, 1) <= S.hdr_min_content_w(s, false, 3) then error("one row is not wider", 0) end
    if S.hdr_min_content_w(s, false, 3) <= S.hdr_min_content_w(s, false, 5) then error("two rows are not wider", 0) end
    local function has_range(plan)
      for _, row in ipairs(plan.rows) do
        for _, id in ipairs(row) do if id == "range" then return true end end
      end
      return false
    end
    -- The Range box is the first unit to go: each plan with it is followed by the same plan without it
    eq(has_range(plans[1]), true); eq(has_range(plans[2]), false); eq(has_range(plans[3]), true)
    eq(has_range(plans[4]), false); eq(has_range(plans[5]), false, "not at the narrowest")
    if S.hdr_min_content_w(s, false, 1) <= S.hdr_min_content_w(s, false, 2) then error("the box takes width", 0) end
    eq(#plans[1].rows, 1, "one row"); eq(#plans[2].rows, 1, "one row")
    eq(#plans[3].rows, 2, "Clip row + Values row"); eq(#plans[4].rows, 2); eq(#plans[5].rows, 6, "narrow")
    for pi, plan in ipairs(plans) do
      eq(plan.captions, nil, "plan " .. pi .. " has no captions")
      for _, row in ipairs(plan.rows) do
        for _, id in ipairs(row) do
          if id:sub(1, 4) == "cap_" then error("plan " .. pi .. " has a caption unit " .. id, 0) end
        end
      end
    end
    -- The first-use window is sized for the two-row plan
    local w2, rows = S.hdr_min_content_w(s, true)
    eq(w2, S.hdr_min_content_w(s, false, 3), "first use: two rows with the Range box"); eq(rows, 2, "first use: two rows")
    -- Strength and Slide In are measured in the default font, as the other values: nothing pushes a font
    local Theme, pushes = package.loaded["theme"], 0
    local push = Theme.push_font
    Theme.push_font = function(...) pushes = pushes + 1; return push(...) end
    local ok2, err2 = pcall(S.K.bar_measure, nil)
    Theme.push_font = push
    if not ok2 then error(err2, 0) end
    eq(pushes, 0, "fonts pushed while measuring the values")
  end)
  reaper.ImGui_CalcTextSize, reaper.ImGui_GetFrameHeight = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("reset_item_all_counts", function()
  local K, D = S.K, S.DEFAULTS
  local data = { separation = D.separation, key_idx = 3, scale_idx = 2, overrides = {} }
  for _, key in ipairs(K.ITEM_KEYS) do
    if key ~= "separation" then data.overrides[key] = D[key] end
  end
  eq(K.item_off_defaults(data), 0, "at the defaults")
  data.overrides.tolerance = D.tolerance + 5
  data.overrides.retune_speed = 0.4
  data.key_idx, data.scale_idx = 5, 1
  eq(K.item_off_defaults(data), 2, "Tolerance and Strength differ; Key and Scale do not count")
  K.item_reset_values(data)
  eq(K.item_off_defaults(data), 0, "reset")
  eq(data.overrides.tolerance, D.tolerance, "the default back"); eq(data.overrides.retune_speed, D.retune_speed)
  eq(data.key_idx, 5, "Key untouched"); eq(data.scale_idx, 1, "Scale untouched")
end)

test("reset_item_all_one_undo", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = stretch_frames(slide_segs(62))
  local start, D = K.new_item_values(), S.DEFAULTS
  local other_sep = 0.9
  local old, old_splits = K.segment(fr, other_sep)
  local data = { guid = "{a}", name = "{a}", notes = old, results = fr, item_len = 2, sample_rate = 44100 }
  K.item_seed(data)
  data.separation = other_sep
  data.overrides.tolerance = D.tolerance + 5
  data.key_idx = (start.key_idx % 12) + 1
  local saved = { st.target_take_guid, st.results, st.notes, st.split_points, st.separation, st.key_idx,
    st.scale_idx, reaper.time_precise, st.status.text }
  reaper.time_precise = function() return 0 end
  st.target_take_guid, st.session_takes["{a}"] = "{a}", data
  st.results, st.notes, st.split_points, st.separation = fr, old, old_splits, other_sep
  st.key_idx = data.key_idx
  local ok, err = pcall(function()
    K.reset_item_all()
    eq(#rec.labels, 1, "one undo point")
    eq(rec.labels[1], "Reset item to defaults", "undo label")
    eq(st.status.text, "Item reset to the defaults.", "status")
    eq(K.item_off_defaults(data), 0, "every value back")
    eq(data.overrides.tolerance, D.tolerance, "Tolerance at its default")
    eq(st.separation, D.separation, "bar Separation follows")
    eq(data.key_idx, (start.key_idx % 12) + 1, "Key untouched")
    eq(st.key_idx, data.key_idx, "bar Key untouched")
    eq(st.notes ~= old, true, "re-split")
    K.reset_item_all()
    eq(#rec.labels, 1, "nothing differs: no undo point")
  end)
  st.target_take_guid, st.results, st.notes, st.split_points, st.separation, st.key_idx,
    st.scale_idx, reaper.time_precise, st.status.text = table.unpack(saved, 1, 9)
  if not ok then error(err, 0) end
end) end)

test("reset_item_all_asks_in_reset_words", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = stretch_frames(slide_segs(62))
  local start = K.new_item_values()
  local other_sep = (start.separation > 0.5) and 0.2 or 0.9
  local old, old_splits = K.segment(fr, other_sep)
  -- an edited note no new note matches: a re-split asks first
  old[#old + 1] = { start_time = 5, end_time = 6, avg_note = 60, controls = { bypassed = true, center_pitch = 60 } }
  local data = { guid = "{a}", name = "{a}", notes = old, results = fr, item_len = 2, sample_rate = 44100 }
  K.item_seed(data)
  data.separation = other_sep
  local saved = { st.target_take_guid, st.target_take_name, st.results, st.notes, st.split_points, st.separation,
    st.confirm }
  st.target_take_guid, st.target_take_name, st.session_takes["{a}"] = "{a}", "Lead Vox", data
  st.results, st.notes, st.split_points, st.separation, st.confirm = fr, old, old_splits, other_sep, nil
  local ok, err = pcall(function()
    K.reset_item_all()
    local c = st.confirm
    eq(c ~= nil and c.id, "resplit", "asks first")
    eq(c.title, "Reset Lead Vox to the defaults?")
    eq(c.confirm_label, "Reset")
    eq(#rec.labels, 0, "nothing written yet")
    -- a plain Separation re-split keeps its own words
    st.confirm = nil
    K.resplit(start.separation)
    eq(st.confirm.title, "Re-split Lead Vox?"); eq(st.confirm.confirm_label, "Re-Split")
  end)
  st.target_take_guid, st.target_take_name, st.results, st.notes, st.split_points, st.separation,
    st.confirm = table.unpack(saved, 1, 7)
  if not ok then error(err, 0) end
end) end)

test("write_take_envelope_keeps_the_old_envelope_when_the_build_fails", function() with_write_stubs({}, function(rec)
  local K = S.K
  local saved_build = K.correction_build
  local pitchmode_set = false
  reaper.SetMediaItemTakeInfo_Value = function() pitchmode_set = true end
  K.correction_build = function() error("bad note") end
  local data = { notes = { { start_time = 0, end_time = 1, avg_note = 60, controls = { center_pitch = 60 } } } }
  local ok, err = pcall(K.write_take_envelope, "{a}", data, false)
  K.correction_build, reaper.SetMediaItemTakeInfo_Value = saved_build, nil
  eq(ok, false, "the error is passed on"); eq(tostring(err):find("bad note", 1, true) ~= nil, true)
  eq(#rec.cleared, 0, "the old points are still there")
  eq(pitchmode_set, false, "the pitch mode is not changed either")
end) end)

-- Apply to other items (K.apply_plan, the confirm's checklist)
-- A target of K.apply_plan: a model with notes split from `fr` at `sep`, each note with its controls
local function apply_target(id, fr, sep, tol)
  local notes = S.K.segment(fr, sep)
  S.K.resplit_features(notes, {})
  local data = { guid = "{" .. id .. "}", name = id, notes = notes, results = fr, item_len = 2, sample_rate = 44100,
    separation = sep, overrides = { tolerance = tol } }
  return { guid = data.guid, take = id, name = id, data = data }
end

test("apply_plan_overwrites", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
  for _, e in ipairs({ a, b }) do e.data.notes[1].controls.tolerance = 30 end
  local plan = S.K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, false)
  eq(#plan.items, 2, "both items")
  eq(plan.items[1].set.tolerance, 40, "a set"); eq(plan.items[2].set.tolerance, 40, "b set")
  eq(plan.items[1].clear_note_keys[1], "tolerance", "note keys cleared")
  eq(plan.counts.items_lose, 2, "items_lose"); eq(plan.counts.notes_lose, 2, "notes_lose")
  eq(plan.items[1].resplit, false, "no Separation: no re-split")
end)

test("apply_plan_keep", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local a, b = apply_target("a", fr, 0.5, 8), apply_target("b", fr, 0.5, 20)
  for _, e in ipairs({ a, b }) do e.data.notes[1].controls.tolerance = 30 end
  local plan = S.K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, true)
  eq(plan.items[1].set.tolerance, 40, "a was at the default (8): set")
  eq(plan.items[2].set.tolerance, nil, "b differs from the default: the user's, kept")
  eq(#plan.items[1].clear_note_keys, 0, "notes keep their own"); eq(plan.counts.notes_lose, 0)
  eq(plan.counts.items_lose, 0, "a held the default: nothing of its own is lost"); eq(plan.changed, 1)
end)

test("apply_plan_keep_no_resplit", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local function target()
    local t = apply_target("a", fr, 0.5, 8)
    eq(#t.data.notes, 2, "split at 0.5")
    t.data.notes[1].controls.center_pitch = t.data.notes[1].controls.center_pitch + 1   -- an edit
    return t
  end
  local keep = S.K.apply_plan({ separation = 0 }, { target() }, { "separation" }, true)
  eq(keep.items[1].resplit, false, "keep: not split again"); eq(keep.counts.not_resplit, 1)
  local over = S.K.apply_plan({ separation = 0 }, { target() }, { "separation" }, false)
  eq(over.items[1].resplit, true, "overwrite: split again"); eq(over.counts.resplit, 1)
  eq(over.counts.lost > 0, true, "the edited note is lost")
end)

test("apply_plan_skips_missing", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local gone = apply_target("a", fr, 0.5, 8); gone.take = nil
  local midi = apply_target("m", fr, 0.5, 8); midi.midi = true
  local plan = S.K.apply_plan({ tolerance = 40 }, { gone, midi }, { "tolerance" }, false)
  eq(#plan.items, 0, "no rows"); eq(plan.counts.skipped, 2, "counted")
end)

test("apply_plan_keep_is_against_the_default", function()
  -- Keep: an item value that differs from the script's default is the user's; at the default it is taken
  local fr = frames(REARTIC_SEGS, HOP)
  local D = S.DEFAULTS
  local at, own = apply_target("a", fr, 0.5, D.tolerance), apply_target("b", fr, 0.5, D.tolerance + 4)
  at.data.overrides.tighten, own.data.overrides.tighten = D.tighten, 0.85
  local plan = S.K.apply_plan({ tolerance = 40, tighten = 0.2 }, { at, own }, { "tolerance", "tighten" }, true)
  eq(plan.items[1].set.tolerance, 40, "a at the default Tolerance: set"); eq(plan.items[1].set.tighten, 0.2)
  eq(plan.items[2].set.tolerance, nil, "b's 12 cents: kept"); eq(plan.items[2].set.tighten, nil, "b's 85%: kept")
  local over = S.K.apply_plan({ tolerance = 40 }, { own }, { "tolerance" }, false)
  eq(over.items[1].set.tolerance, 40, "without Keep: set"); eq(over.counts.items_lose, 1, "b loses a value of its own")
end)

test("confirm_consequence_cached", function()
  local st = S.state
  local stubs = {
    ImGui_IsPopupOpen = function() return true end,
    ImGui_GetWindowSize = function() return 800, 600 end,
    ImGui_GetWindowPos = function() return 0, 0 end,
    ImGui_Viewport_GetPos = function() return 0, 0 end,
    ImGui_Viewport_GetSize = function() return 800, 600 end,
  }
  for k, v in pairs(stubs) do reaper[k] = v end
  local calls = 0
  local ok, err = pcall(function()
    S.request_confirm({ id = "t", title = "T", on_confirm = function() end,
      checklist = { caption = "To:", rows = { { id = "a", name = "A" }, { id = "b", name = "B" } },
        ticked = { a = true } },
      check = { label = "Keep", value = false },
      consequence = function(checked, ticked)
        calls = calls + 1
        local n = 0
        for _ in pairs(ticked) do n = n + 1 end
        return { lines = { tostring(checked) .. n } }
      end })
    S.draw_confirm_modal(); S.draw_confirm_modal()
    eq(calls, 1, "same ticks: computed once")
    eq(st.confirm.cons.lines[1], "false1", "cached in state.confirm")
    S.K.confirm_tick(st.confirm, "b", true); S.draw_confirm_modal(); S.draw_confirm_modal()
    eq(calls, 2, "a row ticked: computed again, once")
    eq(st.confirm.cons.lines[1], "false2")
    S.K.confirm_tick(st.confirm, "b", true); S.draw_confirm_modal()
    eq(calls, 2, "ticking a ticked row changes nothing")
    st.confirm.checked = true; S.draw_confirm_modal()
    eq(calls, 3, "the check changed: computed again")
    S.draw_confirm_modal()
    eq(calls, 3, "nothing changed: not computed again")
    S.K.confirm_tick_all(st.confirm, false); S.draw_confirm_modal()
    eq(calls, 4, "None: computed again"); eq(next(st.confirm.ticked), nil, "nothing ticked")
  end)
  for k in pairs(stubs) do reaper[k] = nil end
  st.confirm = nil
  if not ok then error(err, 0) end
end)

test("confirm_skipped_rows_are_not_tickable", function()
  local c = { checklist = { rows = { { id = "a", name = "A" }, { id = "m", name = "M", reason = "Not an audio item" } } },
    ticked = {}, ticks_rev = 0 }
  S.K.confirm_tick(c, "m", true)
  eq(c.ticked.m, nil, "a skipped row stays unticked"); eq(c.ticks_rev, 0, "and nothing is recomputed")
  S.K.confirm_tick_all(c, true)
  eq(c.ticked.a, true, "All ticks the audio row"); eq(c.ticked.m, nil, "All skips the skipped row")
end)

-- The Apply checklist: its rows, the rows ticked at first, the targets of the ticked rows
local function apply_row(id, reason) return { id = "{" .. id .. "}", guid = "{" .. id .. "}", name = id, reason = reason } end

test("apply_initial_ticks_follow_the_selection", function()
  local rows = { apply_row("a"), apply_row("b"), apply_row("c") }
  local ticked = S.K.apply_initial_ticks(rows, { ["{b}"] = true, ["{x}"] = true })
  eq(ticked["{b}"], true, "the selected row"); eq(ticked["{a}"], nil); eq(ticked["{c}"], nil)
  eq(ticked["{x}"], nil, "a selected item that is not in the list is not a row")
end)

test("apply_initial_ticks_all_when_none_selected", function()
  local rows = { apply_row("a"), apply_row("m", "Not an audio item"), apply_row("b") }
  local ticked = S.K.apply_initial_ticks(rows, {})
  eq(ticked["{a}"], true); eq(ticked["{b}"], true, "none of the rows is selected: every row")
  eq(ticked["{m}"], nil, "a skipped row is never ticked")
  ticked = S.K.apply_initial_ticks(rows, { ["{m}"] = true })
  eq(ticked["{m}"], nil, "selected but skipped: not ticked")
  eq(ticked["{a}"], true, "the only selected row is skipped: every audio row")
end)

test("apply_rows_and_ticked_entries", function() with_write_stubs({ ["{g}"] = true }, function()
  local st, K = S.state, S.K
  local saved = { st.target_take_guid, reaper.TakeIsMIDI }
  local ok, err = pcall(function()
    for _, g in ipairs({ "{open}", "{a}", "{m}", "{g}", "{b}" }) do
      st.session_takes[g] = { guid = g, name = g:gsub("[{}]", ""), notes = {} }
      st.session_order[#st.session_order + 1] = g
    end
    st.target_take_guid = "{open}"
    reaper.TakeIsMIDI = function(take) return take == "m" end
    local rows = K.apply_rows()
    eq(#rows, 4, "every pitched item but the open one")
    eq(rows[1].guid, "{a}"); eq(rows[1].reason, nil)
    eq(rows[2].guid, "{m}"); eq(rows[2].reason, "Not an audio item")
    eq(rows[3].guid, "{g}"); eq(rows[3].reason, "No longer in the project")
    eq(rows[4].guid, "{b}"); eq(rows[4].name, "b")
    local entries = K.apply_ticked_entries(rows, { ["{b}"] = true, ["{m}"] = true })
    eq(#entries, 1, "only ticked rows that can be written"); eq(entries[1].guid, "{b}")
    eq(entries[1].data, st.session_takes["{b}"])
  end)
  for _, g in ipairs({ "{open}", "{m}", "{g}" }) do st.session_takes[g] = nil end
  st.target_take_guid, reaper.TakeIsMIDI = table.unpack(saved, 1, 2)
  if not ok then error(err, 0) end
end) end)

test("apply_consequence_follows_the_ticked_rows", function() with_write_stubs({}, function()
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, st.confirm }
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    st.target_take_guid, st.confirm = "{open}", nil
    K.apply_open({ "tolerance" })
    local c = st.confirm
    st.confirm = nil
    eq(#c.checklist.rows, 2, "one row per other pitched item")
    eq(c.ticked["{a}"] and c.ticked["{b}"], true, "nothing selected: every row ticked")
    eq(c.only, nil, "no \"New items only\"")
    local all = c.consequence(false, { ["{a}"] = true, ["{b}"] = true })
    eq(all.confirm_label, "Apply (2)")
    for _, line in ipairs(all.lines) do
      eq(line:find("starting", 1, true), nil, "no line about starting values: " .. line)
      eq(line:find("can't be undone", 1, true), nil, "no line about what can't be undone: " .. line)
    end
    local one = c.consequence(false, { ["{b}"] = true })
    eq(one.confirm_label, "Apply (1)", "the count follows the ticked rows"); eq(one.reason, nil)
    local none = c.consequence(false, {})
    eq(none.reason, "Tick at least one item", "nothing ticked: Apply disabled")
    eq(none.confirm_label, "Apply (0)")

  end)
  st.target_take_guid, st.confirm = table.unpack(saved, 1, 2)
  if not ok then error(err, 0) end
end) end)

test("apply_open_ticks_the_selected_rows", function() with_write_stubs({}, function()
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, st.confirm }
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    reaper.CountSelectedMediaItems = function() return 1 end
    reaper.GetSelectedMediaItem = function() return "item_b" end
    reaper.GetActiveTake = function() return "b" end
    st.target_take_guid, st.confirm = "{open}", nil
    K.apply_open({ "tolerance" })
    local c = st.confirm
    st.confirm = nil
    eq(c.ticked["{b}"], true, "the selected item is ticked"); eq(c.ticked["{a}"], nil, "the other is not")
  end)
  reaper.GetSelectedMediaItem, reaper.GetActiveTake = nil, nil
  st.target_take_guid, st.confirm = table.unpack(saved, 1, 2)
  if not ok then error(err, 0) end
end) end)

test("apply_run_one_undo_and_cancel", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, reaper.time_precise, st.is_analyzing, reaper.SetExtState, K.save_settings }
  local ext, saves = 0, 0
  reaper.time_precise = function() return 0 end
  reaper.SetExtState = function() ext = ext + 1 end
  K.save_settings = function() saves = saves + 1 end
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    st.target_take_guid = "{open}"
    local plan = K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, false)
    K.apply_run(plan, "Tolerance")
    eq(K.batch ~= nil, true, "runs as a batch")
    for _ = 1, 10 do if K.batch then K.analysis_tick() end end
    eq(K.batch, nil, "done"); eq(st.is_analyzing, false)
    eq(rec.begin, 1, "one undo block"); eq(#rec.labels, 1, "one undo point")
    eq(rec.labels[1], "Apply Tolerance to 2 items")
    eq(st.session_takes["{a}"].overrides.tolerance, 40, "a written"); eq(a.data.overrides.tolerance, 12, "old model untouched")
    eq(st.status.text, "Applied to 2 items (" .. MOD .. "+Z undoes them).")
    eq(ext, 0, "Apply writes no ExtState: one undo restores everything"); eq(saves, 0, "no setting saved")
    -- Cancel before the first item: nothing written
    plan = K.apply_plan({ tolerance = 50 }, { a, b }, { "tolerance" }, false)
    K.apply_run(plan, "Tolerance")
    eq(K.cancel_analysis(), true)
    eq(#rec.labels, 1, "no new undo point"); eq(ext, 0, "still no ExtState")
    eq(st.status.text, "Apply cancelled. No item was changed.")
  end)
  st.target_take_guid, reaper.time_precise, st.is_analyzing, reaper.SetExtState, K.save_settings = table.unpack(saved, 1, 5)
  K.batch = nil
  st.status.text, st.status.hold = "", nil
  if not ok then error(err, 0) end
end) end)

test("apply_keep_line_only_when_separation_is_given", function() with_write_stubs({}, function()
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, st.confirm }
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    local function keep_shown(keys)
      st.target_take_guid, st.confirm = "{open}", nil
      K.apply_open(keys)
      local c = st.confirm
      st.confirm = nil
      for _, line in ipairs(c.consequence(true, c.ticked).lines) do
        if line:find("not split again", 1, true) then return true end
      end
      return false
    end
    eq(keep_shown({ "tolerance" }), false, "Tolerance never splits again: no keep line")
    eq(keep_shown({ "separation" }), true, "Separation: the keep line")
    eq(keep_shown(nil), true, "every value: the keep line")
  end)
  st.target_take_guid, st.confirm = table.unpack(saved, 1, 2)
  if not ok then error(err, 0) end
end) end)

test("apply_refuses_when_the_open_item_changed", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, reaper.time_precise, st.is_analyzing, st.confirm }
  reaper.time_precise = function() return 0 end
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    st.target_take_guid, st.confirm = "{open}", nil
    K.apply_open({ "tolerance" })
    local c = st.confirm
    eq(c ~= nil and c.id, "apply", "the confirm is open")
    eq(c.ticked["{a}"] and c.ticked["{b}"], true, "nothing selected: every row ticked")
    st.target_take_guid = "{a}"   -- the user clicked a target in the arrange view
    c.on_confirm(c.checked, c.ticked)
    eq(#rec.labels, 0, "no undo point"); eq(K.batch, nil, "no run")
    eq(st.session_takes["{a}"], a.data, "a untouched")
    eq(st.status.text, "The item changed meanwhile. Nothing was applied.")
    -- Defence in depth: a row for the open item is never run
    local plan = K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, false)
    K.apply_run(plan, "Tolerance")
    for _ = 1, 10 do if K.batch then K.analysis_tick() end end
    eq(rec.labels[1], "Apply Tolerance to 1 items", "only b")
    eq(st.session_takes["{a}"], a.data, "the open item is not written")
    eq(st.session_takes["{b}"].overrides.tolerance, 40, "b written")
  end)
  st.target_take_guid, reaper.time_precise, st.is_analyzing, st.confirm = table.unpack(saved, 1, 4)
  K.batch = nil
  st.status.text, st.status.hold = "", nil
  if not ok then error(err, 0) end
end) end)

-- A batch writes each item's envelope from its model and its own values (what K.envelope_check expects)
-- fn(rec, pts) runs K.batch_write with envelope points recorded per envelope: pts[env] = { { time, val, shape } ... }
local function with_point_stubs(fn)
  with_write_stubs({}, function(rec)
    local st = S.state
    local pts, modes = {}, {}
    local clear = reaper.DeleteEnvelopePointRange
    reaper.DeleteEnvelopePointRange = function(env, ...) clear(env, ...); pts[env] = {} end
    reaper.InsertEnvelopePointEx = function(env, _, t, v, shape)
      pts[env] = pts[env] or {}
      table.insert(pts[env], { time = t, val = v, shape = shape })
    end
    reaper.CountEnvelopePointsEx = function(env) return #(pts[env] or {}) end
    reaper.GetEnvelopePointEx = function(env, _, i)
      local p = (pts[env] or {})[i + 1]
      if not p then return false end
      return true, p.time, p.val, p.shape
    end
    reaper.GetMediaItemInfo_Value = function(_, key) if key == "D_LENGTH" then return 10 end return 0 end
    reaper.SetMediaItemTakeInfo_Value = function(take, key) modes[#modes + 1] = { take = take, key = key } end
    local saved_target = st.target_take_guid
    st.target_take_guid = "{other}"   -- the window has another item open
    local ok, err = pcall(fn, rec, pts, modes)
    st.target_take_guid = saved_target
    for _, name in ipairs({ "InsertEnvelopePointEx", "CountEnvelopePointsEx", "GetEnvelopePointEx",
      "GetMediaItemInfo_Value", "SetMediaItemTakeInfo_Value" }) do reaper[name] = nil end
    if not ok then error(err, 0) end
  end)
end

test("batch_writes_the_correction_of_kept_item_values", function() with_point_stubs(function(rec, pts, modes)
  local K, st = S.K, S.state
  local data = { guid = "{a}", name = "A", results = {}, item_len = 10, sample_rate = 44100,
    notes = { wobbly_untouched(0.1) } }
  K.item_seed(data)
  data.overrides.tighten, data.overrides.tolerance = 0.3, 0   -- the item kept its own Tighten 30%
  local written = K.batch_write({ { guid = "{a}", data = data, json = K.take_json(data), empty = false } })
  eq(#written, 1); eq(rec.begin, 1, "one undo block"); eq(rec.labels[1], "Analyze Pitch (1 item)")
  eq(st.undo_open, false)
  local moved = false
  for _, p in ipairs(pts.env_a or {}) do if math.abs(p.val) > 1e-6 then moved = true end end
  eq(moved, true, "the item's Tighten corrects its note: the envelope holds the correction")
  eq(K.envelope_check("{a}"), false, "the envelope is what the model and the item's values produce: not Outdated")
  eq(rec.stored.a, written[1].json, "the model is stored with the text the batch prepared")
  eq(#modes, 0, "the take's pitch mode is left alone, as for a single analysis")
  eq(st.target_take_guid, "{other}", "the open item is still the target")
end) end)

test("batch_leaves_a_fresh_item_uncorrected", function() with_point_stubs(function(rec, pts, modes)
  local K = S.K
  local data = { guid = "{a}", name = "A", results = {}, item_len = 10, sample_rate = 44100,
    notes = { wobbly_untouched(0.1) } }
  K.item_seed(data)   -- the starting values: they correct nothing
  local written = K.batch_write({ { guid = "{a}", data = data, json = K.take_json(data), empty = false } })
  eq(#written, 1); eq(rec.begin, 1)
  eq(#(pts.env_a or {}), 0, "no points: a cleared envelope, as before")
  eq(K.envelope_check("{a}"), false, "not Outdated")
  eq(#modes, 0, "pitch mode left alone")
end) end)

-- Runs K.batch_write(d) with the correction of every model that has notes failing; returns what it wrote, what the
-- console said and the takes whose Pitch envelope was looked up (ensure_take_pitch_envelope)
local function batch_write_failing(d)
  local K = S.K
  local build, said, looked = K.correction_build, nil, {}
  local lookup = reaper.GetTakeEnvelopeByName
  K.correction_build = function() error("bad note") end
  reaper.ShowConsoleMsg = function(msg) said = msg end
  reaper.GetTakeEnvelopeByName = function(take, ...) looked[take] = true; return lookup(take, ...) end
  local ok, res = pcall(K.batch_write, d)
  K.correction_build, reaper.ShowConsoleMsg, reaper.GetTakeEnvelopeByName = build, nil, lookup
  if not ok then error(res, 0) end
  return res, said, looked
end

test("batch_leaves_out_an_item_whose_correction_cannot_be_built", function() with_point_stubs(function(rec, pts)
  local K, st = S.K, S.state
  local d = done2()
  d[1].data.notes = { wobbly_untouched(0.1) }; K.item_seed(d[1].data)
  local written, said, looked = batch_write_failing(d)
  eq(#written, 1, "only b is written"); eq(written[1].guid, "{b}"); eq(rec.stored.a, nil, "a left as it was")
  eq(looked.a, nil, "a's envelope is not created, shown or switched on"); eq(pts.env_a, nil, "nor cleared")
  eq(st.session_takes["{a}"], nil); eq(rec.labels[1], "Analyze Pitch (1 item)"); eq(st.undo_open, false)
  eq(tostring(said):find("bad note", 1, true) ~= nil, true, "the console says why")
end) end)

test("batch_with_no_buildable_item_makes_no_undo_point", function() with_point_stubs(function(rec)
  local K, st = S.K, S.state
  local d = done2()
  for _, e in ipairs(d) do e.data.notes = { wobbly_untouched(0.1) }; K.item_seed(e.data) end
  local written, _, looked = batch_write_failing(d)
  eq(#written, 0); eq(rec.begin, 0, "no undo block"); eq(#rec.labels, 0, "no undo point")
  eq(looked.a, nil); eq(looked.b, nil); eq(st.undo_open, false)
  eq(st.session_takes["{a}"], nil); eq(st.session_takes["{b}"], nil)
end) end)

test("batch_carries_on_when_a_write_raises", function() with_point_stubs(function(rec)
  local K, st = S.K, S.state
  local insert, said = reaper.InsertEnvelopePointEx, nil
  reaper.InsertEnvelopePointEx = function(env, ...) if env == "env_a" then error("disk full") end return insert(env, ...) end
  reaper.ShowConsoleMsg = function(msg) said = msg end
  local d = done2()
  for _, e in ipairs(d) do
    e.data.notes = { wobbly_untouched(0.1) }; K.item_seed(e.data); e.data.overrides.tighten = 0.3
    e.data.overrides.tolerance = 0; e.json = K.take_json(e.data)
  end
  local ok, written = pcall(K.batch_write, d)
  reaper.ShowConsoleMsg = nil
  if not ok then error(written, 0) end
  eq(#written, 1, "b is written"); eq(written[1].guid, "{b}"); eq(rec.stored.b, d[2].json)
  eq(rec.begin, 1, "one undo block"); eq(#rec.labels, 1, "closed once"); eq(rec.labels[1], "Analyze Pitch (1 item)")
  eq(st.undo_open, false); eq(st.session_takes["{a}"], nil, "a's session entry comes back")
  eq(rec.stored.a, nil, "a's model is not stored")
  eq(tostring(said):find("disk full", 1, true) ~= nil, true, "the console says why")
end) end)

-- The confirm's layout: the button row (and the line that says why Apply is off) is outside the scrolling body
test("confirm_body_h_leaves_room_for_the_reason_and_the_buttons", function()
  local K = S.K
  -- avail 400, buttons 20, gap 12, a reason line 14, item spacing 4
  local body = K.confirm_body_h(400, 20, 12, 14, 4)
  eq(body, 400 - (4 + 12 + 4 + 14 + 4 + 20), "the body leaves the gap, the reason line and the button row")
  eq(K.confirm_body_h(400, 20, 12, 0, 4), 400 - (4 + 12 + 4 + 20), "no reason slot: only the gap and the buttons")
  eq(K.confirm_body_h(30, 20, 12, 14, 4), 1, "too little room: the body is one pixel, the buttons stay in view")
end)

test("apply_carry_ticks_by_guid", function()
  local rows = { apply_row("a"), apply_row("m", "Not an audio item"), apply_row("b") }
  local carried = S.K.apply_carry_ticks(rows, { ["{a}"] = true, ["{m}"] = true, ["{x}"] = true })
  eq(carried["{a}"], true, "a ticked row carried over")
  eq(carried["{m}"], nil, "a row that cannot be written any more drops out")
  eq(carried["{x}"], nil, "a row that is no longer in the list drops out")
  eq(carried["{b}"], nil, "an unticked row stays unticked")
end)

test("apply_confirm_plans_with_the_rows_of_now", function() with_write_stubs({}, function()
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, st.confirm, K.apply_run }
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    st.target_take_guid, st.confirm = "{open}", nil
    K.apply_open({ "tolerance" })
    local c = st.confirm
    st.confirm = nil
    eq(c.ticked["{a}"] and c.ticked["{b}"], true, "every row ticked")
    -- Cmd+Z in the arrange view while the confirm is up: a is gone, b's model is reloaded with another value
    reaper.GetMediaItemTakeByGUID = function(_, guid) if guid == "{a}" then return nil end return (guid:gsub("[{}]", "")) end
    K.drop_project_cache()
    local b2 = apply_target("b", fr, 0.5, K.apply_source({ "tolerance" }).tolerance)
    st.session_takes["{b}"] = b2.data
    local ran = nil
    K.apply_run = function(plan) ran = plan end
    c.on_confirm(c.checked, c.ticked)
    eq(ran ~= nil, true, "Apply runs")
    eq(#ran.items, 1, "only b"); eq(ran.items[1].guid, "{b}")
    eq(ran.items[1].set.tolerance, nil, "planned from b's reloaded model (it already holds the value given)")
  end)
  st.target_take_guid, st.confirm, K.apply_run = table.unpack(saved, 1, 3)
  if not ok then error(err, 0) end
end) end)

test("apply_confirm_says_when_no_row_can_be_ticked", function() with_write_stubs({}, function()
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, st.confirm, reaper.TakeIsMIDI }
  local ok, err = pcall(function()
    local a = apply_target("a", fr, 0.5, 12)
    st.session_takes["{a}"] = a.data
    st.session_order[#st.session_order + 1] = "{a}"
    reaper.TakeIsMIDI = function() return true end
    st.target_take_guid, st.confirm = "{open}", nil
    K.apply_open({ "tolerance" })
    local c = st.confirm
    st.confirm = nil
    eq(next(c.ticked), nil, "nothing can be ticked")
    eq(c.consequence(false, {}).reason, "No item here can be changed", "nothing tickable: Apply disabled")
  end)
  st.target_take_guid, st.confirm, reaper.TakeIsMIDI = table.unpack(saved, 1, 3)
  if not ok then error(err, 0) end
end) end)

-- An open item that loses its analysis (Clear, Remove, Wipe, unreadable data cleared, the analysis undone away) is
-- not analysed any more: it shows a new item's values, so its next analysis is a first one and splits at 50%
local function open_analysed_at_70(st)
  st.session_takes["{a}"] = { guid = "{a}", name = "A", separation = 0.7, key_idx = 5, scale_idx = 3,
    notes = {}, results = { { time = 0, note = 60 } }, item_len = 1, sample_rate = 48000 }
  st.session_order[#st.session_order + 1] = "{a}"
  st.target_take_guid, st.separation, st.key_idx, st.scale_idx = "{a}", 0.7, 5, 3   -- adopt_take_data's mirrors
end

test("clearing_the_open_item_starts_it_at_a_new_items_values", function() with_write_stubs({}, function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.separation, st.key_idx, st.scale_idx,
    K.open_accessor, st.results, st.notes, st.sample_rate, st.end_time, st.current_time }
  local ok, err = pcall(function()
    open_analysed_at_70(st)
    reaper.GetMediaItemInfo_Value = function() return 1 end
    S.clear_take_analysis("{a}")
    eq(st.separation, S.DEFAULTS.separation, "Separation back to the default, not the cleared 70%")
    eq(st.key_idx, 0, "no key set: a new item's"); eq(st.scale_idx, 1)
    reaper.GetMediaItemTake_Source = function() return "src" end
    reaper.GetMediaSourceSampleRate = function() return 48000 end
    K.open_accessor = function() return "acc" end
    eq(K.analysis_begin("a", "item_a", { defer_envelope = true }), true, "the next analysis starts")
    eq(st.separation, S.DEFAULTS.separation, "it splits at 50%")
  end)
  reaper.GetMediaItemInfo_Value, reaper.GetMediaItemTake_Source, reaper.GetMediaSourceSampleRate = nil, nil, nil
  st.target_take_guid, st.separation, st.key_idx, st.scale_idx, K.open_accessor,
    st.results, st.notes, st.sample_rate, st.end_time, st.current_time = table.unpack(saved, 1, 10)
  st.is_analyzing, st.analysis_params, st.accessor = false, nil, nil
  if not ok then error(err, 0) end
end) end)

test("wiping_the_session_starts_the_open_item_at_a_new_items_values", function() with_write_stubs({}, function()
  local st = S.state
  local saved = { st.target_take_guid, st.separation, st.key_idx, st.scale_idx,
    st.session_order, st.session_takes, st.raw_cache, st.missing_takes, st.stale_takes }
  local ok, err = pcall(function()
    st.session_order, st.session_takes = {}, {}
    open_analysed_at_70(st)
    reaper.GetMediaItemInfo_Value = function() return 1 end
    reaper.CountAutomationItems = function() return 0 end
    eq(S.wipe_entire_session(), 1)
    eq(st.separation, S.DEFAULTS.separation, "Separation back to the default")
    eq(st.key_idx, 0, "no key set: a new item's")
  end)
  reaper.GetMediaItemInfo_Value, reaper.CountAutomationItems = nil, nil
  st.target_take_guid, st.separation, st.key_idx, st.scale_idx, st.session_order,
    st.session_takes, st.raw_cache, st.missing_takes, st.stale_takes = table.unpack(saved, 1, 9)
  if not ok then error(err, 0) end
end) end)

test("an_analysis_undone_away_starts_the_open_item_at_a_new_items_values", function()
  local K, st = S.K, S.state
  local raw, changes = "", 2
  reaper.GetProjectStateChangeCount = function() return changes end
  reaper.GetMediaItemTakeByGUID = function(_, guid) return guid == "{a}" and "a" or nil end
  reaper.GetSetMediaItemTakeInfo_String = function(_, key)
    if key == "GUID" then return true, "{a}" end
    return true, raw
  end
  local saved = { st.target_take_guid, st.separation, st.key_idx, st.scale_idx,
    st.last_change_count, #st.session_order, st.results, st.notes }
  local ok, err = pcall(function()
    open_analysed_at_70(st)
    st.raw_cache["{a}"] = K.take_json(st.session_takes["{a}"])
    K.drop_project_cache()
    st.last_change_count = 1
    S.sync_with_project()   -- Cmd+Z took the item's first analysis away
    eq(st.session_takes["{a}"], nil, "undone: not analysed")
    eq(st.separation, S.DEFAULTS.separation, "Separation back to the default")
    eq(st.key_idx, 0, "no key set: a new item's")
  end)
  reaper.GetProjectStateChangeCount, reaper.GetMediaItemTakeByGUID, reaper.GetSetMediaItemTakeInfo_String = nil, nil, nil
  st.session_takes["{a}"], st.raw_cache["{a}"], st.unreadable_takes["{a}"], st.undone_takes["{a}"] = nil, nil, nil, nil
  while #st.session_order > saved[6] do table.remove(st.session_order) end
  st.target_take_guid, st.separation, st.key_idx, st.scale_idx, st.last_change_count,
    st.results, st.notes = saved[1], saved[2], saved[3], saved[4], saved[5], saved[7], saved[8]
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

-- Re-analysing puts an item's values back to the defaults: the confirm says so, and with no confirm (no edited
-- note) the status line says it once the new analysis is written (HC4)
local function reanalyse_stubs(K)
  reaper.GetMediaItemTake_Source = function() return "src" end
  reaper.GetMediaSourceSampleRate = function() return 48000 end
  reaper.GetMediaItemInfo_Value = function() return 0 end
  reaper.GetTakeName = function(take) return take end
  reaper.time_precise = function() return 0 end
  local saved = { K.open_accessor, K.write_take_envelope }
  K.open_accessor = function() return "acc" end
  K.write_take_envelope = function() return true end
  return function()
    reaper.GetMediaItemTake_Source, reaper.GetMediaSourceSampleRate, reaper.GetMediaItemInfo_Value = nil, nil, nil
    reaper.GetTakeName, reaper.time_precise = nil, nil
    K.open_accessor, K.write_take_envelope = saved[1], saved[2]
  end
end

test("reanalyze_confirm_says_the_values_go_back", function() with_write_stubs({}, function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.target_take_name, st.notes, st.confirm }
  local ok, err = pcall(function()
    st.session_takes["{a}"] = analysed_before("{a}")
    st.target_take_guid, st.target_take_name = "{a}", "A"
    st.notes = { { avg_note = 60, controls = { bypassed = true } } }   -- one edited note: the confirm
    st.confirm = nil
    K.request_analyze()
    local c = st.confirm
    st.confirm = nil
    eq(c.id, "reanalyze")
    eq(c.body_lines[2], "Its values go back to the defaults; Key and Scale stay.")
    eq(c.body_lines[3], MOD .. "+Z restores them once the analysis has finished.")
  end)
  st.target_take_guid, st.target_take_name, st.notes, st.confirm = table.unpack(saved, 1, 4)
  if not ok then error(err, 0) end
end) end)

test("reanalyze_without_confirm_says_the_values_went_back", function() with_write_stubs({}, function()
  local K, st = S.K, S.state
  local undo = reanalyse_stubs(K)
  local saved = { st.target_take_guid, st.target_take_name, st.separation, st.key_idx, st.scale_idx, st.results,
    st.notes, st.sample_rate, st.end_time, st.current_time, st.confirm }
  local ok, err = pcall(function()
    local function reanalyse(data)
      st.session_takes["{a}"] = data
      st.target_take_guid, st.notes, st.confirm = "{a}", {}, nil   -- no edited note: no confirm
      st.status.text = ""
      K.request_analyze()
      eq(st.confirm, nil, "no confirm")
      eq(st.is_analyzing, true, "the analysis starts")
      eq(st.status.text, "", "nothing said before the write")
      at_analysis_end(st)
      K.analysis_tick()
      eq(st.is_analyzing, false, "the analysis ended")
      eq(st.status.text, "", "nothing in the status line: it is in the Analysis card")
      local lines = table.concat(K.card and K.card.lines or {}, "|")
      K.card = nil
      return lines
    end
    eq(reanalyse(analysed_before("{a}")), "Re-analyzed: values back to the defaults (" .. MOD .. "+Z undoes).",
      "values that differed from the defaults: said")
    local at_defaults = analysed_before("{a}")
    at_defaults.overrides, at_defaults.separation = {}, S.DEFAULTS.separation
    eq(reanalyse(at_defaults), "", "already at the defaults: nothing to say")
  end)
  undo()
  st.target_take_guid, st.target_take_name, st.separation, st.key_idx, st.scale_idx, st.results, st.notes,
    st.sample_rate, st.end_time, st.current_time, st.confirm = table.unpack(saved, 1, 11)
  st.is_analyzing, st.analysis_params, st.accessor = false, nil, nil
  st.stale_takes["{a}"], st.missing_takes["{a}"] = nil, nil
  st.status.text, st.status.hold = "", nil
  if not ok then error(err, 0) end
end) end)

test("apply_keep_says_key_and_scale_are_still_applied", function() with_write_stubs({}, function()
  local st, K = S.state, S.K
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, st.confirm }
  local ok, err = pcall(function()
    local a = apply_target("a", fr, 0.5, 12)
    st.session_takes["{a}"] = a.data
    st.session_order[#st.session_order + 1] = "{a}"
    local function key_line(keys, keep)
      st.target_take_guid, st.confirm = "{open}", nil
      K.apply_open(keys)
      local c = st.confirm
      st.confirm = nil
      eq(c.fit, true, "the Apply confirm takes its content's height")
      for _, line in ipairs(c.consequence(keep, c.ticked).lines) do
        if line == "Key and Scale are still applied." then return true end
      end
      return false
    end
    eq(key_line({ "key_idx", "scale_idx" }, true), true, "Key given, Keep on: said")
    eq(key_line(nil, true), true, "every value (Key included), Keep on: said")
    eq(key_line({ "key_idx", "scale_idx" }, false), false, "Keep off: not said")
    eq(key_line({ "tolerance" }, true), false, "no Key given: not said")
  end)
  st.target_take_guid, st.confirm = table.unpack(saved, 1, 2)
  if not ok then error(err, 0) end
end) end)

-- The Apply confirm takes its content's height: no empty band above the footer, the buttons never clipped
test("confirm_fit_h_puts_the_footer_under_the_content", function()
  local K = S.K
  -- a modal 480 tall whose body is 380: 100 of title bar, padding and footer
  eq(K.confirm_fit_h(480, 380, 150, 1000), 250, "short content: the modal shrinks to it")
  eq(K.confirm_fit_h(480, 380, 600, 1000), 700, "long content: the modal grows to it")
  eq(K.confirm_fit_h(480, 380, 2000, 900), 900, "never taller than the window it opens from allows")
  eq(K.confirm_fit_h(480, 380, 0, 1000), 101, "no content: the body keeps one pixel, the footer stays")
  eq(K.confirm_fit_h(480, 380, 150, 50), 101, "a tiny host: the footer is never cut (the constraint caps the rest)")
end)

test("confirm_fit_due_only_when_the_content_changes", function()
  local K, c = S.K, {}
  eq(K.confirm_fit_due(c, "k1", 380, 150), true, "first sight: fit")
  eq(K.confirm_fit_due(c, "k1", 150, 150), false, "fitted: nothing to do")
  eq(K.confirm_fit_due(c, "k2", 150, 150), false, "a row ticked, same content size: no move")
  eq(K.confirm_fit_due(c, "k3", 150, 170), true, "a line more: fit again")
  eq(K.confirm_fit_due(c, "k3", 160, 170), true, "still off (capped, re-wrapped): once more")
  eq(K.confirm_fit_due(c, "k3", 160, 170), false, "never a third time for one content: no resize every frame")
  eq(K.confirm_fit_due(c, "k4", 160, 300), true, "new content: fit again")
end)

test("confirm_sized_to_its_content_resizes_once_before_it_begins", function()
  local K, st, L = S.K, S.state, package.loaded["theme"].layout
  local sizes, cursor, alphas, pops = {}, 0, {}, 0
  local stubs = {
    ImGui_IsPopupOpen = function() return true end,
    ImGui_BeginPopupModal = function() return true, true end,
    ImGui_BeginChild = function() return true end,
    ImGui_GetWindowSize = function() return 560, 480 end,
    ImGui_GetWindowPos = function() return 100, 50 end,
    ImGui_Viewport_GetPos = function() return 0, 0 end,
    ImGui_Viewport_GetSize = function() return 800, 600 end,
    ImGui_GetContentRegionAvail = function() return 520, 400 end,
    ImGui_GetStyleVar = function() return 4, 4 end,
    ImGui_GetFrameHeight = function() return 20 end,
    ImGui_GetTextLineHeight = function() return 14 end,
    ImGui_CalcTextSize = function() return 40, 14 end,
    ImGui_GetCursorPosX = function() return 0 end,
    ImGui_GetCursorPosY = function() cursor = cursor + 1; return (cursor % 2 == 1) and 0 or 104 end,
    -- the fit's own (no condition): Theme.center_next_window's, at Cond_Appearing, are not counted
    ImGui_Cond_Appearing = function() return 4 end,
    ImGui_SetNextWindowSize = function(_, w, h, cond) if cond == nil then sizes[#sizes + 1] = { w = w, h = h } end end,
    ImGui_StyleVar_Alpha = function() return 99 end,
    ImGui_PushStyleVar = function(_, var, v) if var == 99 then alphas[#alphas + 1] = v end end,
    ImGui_PopStyleVar = function() pops = pops + 1 end,
  }
  for k, v in pairs(stubs) do reaper[k] = v end
  local ok, err = pcall(function()
    S.request_confirm({ id = "fit", title = "T", body_lines = { "One line" }, on_confirm = function() end,
      fit = true, size = { w = 560, h = 480 },
      consequence = function() return { lines = {} } end })
    S.draw_confirm_modal()   -- opens at size.h (Theme.center_next_window) and measures its content: 100
    local opened = #sizes
    eq(opened, 0, "nothing resized before it was measured")
    S.draw_confirm_modal()   -- resized before it begins
    eq(#sizes, opened + 1, "one resize asked")
    local body_h = 400 - (4 + L.lg + 4 + 20) - (14 + 4)   -- K.confirm_body_h with the reason's line kept
    eq(sizes[#sizes].w, 560, "the same width (a narrow docker's fit is kept)")
    eq(sizes[#sizes].h, K.confirm_fit_h(480, body_h, 100, 480 - L.xl * 2), "the footer right under the content")
    S.draw_confirm_modal(); S.draw_confirm_modal(); S.draw_confirm_modal()
    eq(#sizes, opened + 2, "the stubbed body never matches: tried twice for one content, then left alone")
    eq(#alphas, S.K.CONFIRM_FIT_HIDDEN_MAX, "see-through while it resizes, at most the cap")
    eq(alphas[1], 0, "alpha 0"); eq(pops >= #alphas, true, "every push popped")
  end)
  for k in pairs(stubs) do reaper[k] = nil end
  st.confirm = nil
  if not ok then error(err, 0) end
end)

test("confirm_fit_hidden_until_measured", function()
  local K = S.K
  eq(K.confirm_fit_hidden({}), false, "a confirm of a fixed size is always drawn")
  eq(K.confirm_fit_hidden({ fit = true }), true, "not measured yet: see-through")
  eq(K.confirm_fit_hidden({ fit = true, fit_key = "k", fit_hidden_frames = 1 }), true, "a resize asked: still")
  eq(K.confirm_fit_hidden({ fit = true, fit_shown = true }), false, "measured with no resize asked: drawn")
  eq(K.confirm_fit_hidden({ fit = true, fit_hidden_frames = K.CONFIRM_FIT_HIDDEN_MAX }), false,
    "never measured: shown anyway after a few frames")
end)

local SOPRANO_ANALYSIS = { min_freq = 250, max_freq = 1200, threshold = 0.08, block_size = 1024, hop_size = 512 }
test("form_seeds_from_item_not_defaults", function()
  local f = S.K.form_new("{a}", { notes = { {} }, analysis = SOPRANO_ANALYSIS })
  eq(f.source, "item"); eq(f.values.min_freq, 250); eq(f.values.max_freq, 1200)
  eq(f.seed, SOPRANO_ANALYSIS, "the seed is the stored table")
  eq(S.K.form_header(f), "ANALYSIS SETTINGS · as analyzed before")
end)
test("form_unrecorded_item_uses_defaults", function()
  local f = S.K.form_new("{a}", { notes = { {} } })
  eq(f.source, "unrecorded"); eq(f.values.min_freq, S.state.min_freq)
  eq(S.K.form_header(f), "ANALYSIS SETTINGS · not recorded, your defaults")
  local u = S.K.form_new("{b}", nil)
  eq(u.source, "defaults"); eq(S.K.form_header(u), "ANALYSIS SETTINGS · your defaults")
  eq(S.K.form_new("batch", nil).guid, "batch")
end)
test("form_reseeds_when_stored_analysis_changes", function()
  local st = S.state
  local saved = st.analysis_form
  local a1 = { min_freq = 250, max_freq = 1200, threshold = 0.08, block_size = 1024, hop_size = 512 }
  local a2 = { min_freq = 80, max_freq = 350, threshold = 0.15, block_size = 2048, hop_size = 256 }
  local d1 = { notes = { {} }, analysis = a1 }
  local d2 = { notes = { {} }, analysis = a2 }
  st.analysis_form = nil
  S.K.form_sync("{a}", d1)
  local form = st.analysis_form
  S.K.form_set(form, "threshold", 0.25)
  S.K.form_sync("{a}", d1)
  eq(st.analysis_form, form, "same guid and same stored analysis: kept")
  eq(st.analysis_form.values.threshold, 0.25)
  S.K.form_sync("{a}", d2)
  eq(st.analysis_form.values.min_freq, 80, "an undo replaced the stored analysis: reseeded from it")
  eq(st.analysis_form.values.threshold, 0.15)
  eq(next(st.analysis_form.edited), nil, "edited is empty")
  st.analysis_form = saved
end)
test("form_follows_defaults_for_untouched_rows", function()
  local st = S.state
  local saved, saved_min, saved_max = st.analysis_form, st.min_freq, st.max_freq
  st.analysis_form = nil
  S.K.form_sync("{b}", nil)
  local form = st.analysis_form
  S.K.form_set(form, "threshold", 0.25)
  st.min_freq, st.max_freq = 80, 350   -- Bass
  S.K.form_sync("{b}", nil)
  eq(form.values.min_freq, 80); eq(form.values.max_freq, 350)
  eq(form.values.threshold, 0.25, "the edited row keeps its value")
  st.min_freq, st.max_freq, st.analysis_form = saved_min, saved_max, saved
end)
test("form_set_and_reset_row", function()
  local f = S.K.form_new("{c}", nil)
  S.K.form_set(f, "range", { min = 250, max = 1200 })
  eq(f.values.min_freq, 250); eq(f.values.max_freq, 1200)
  eq(f.edited.min_freq, true); eq(f.edited.max_freq, true)
  S.K.form_reset_row(f, "range")
  eq(f.values.min_freq, S.state.min_freq); eq(f.values.max_freq, S.state.max_freq)
  eq(next(f.edited), nil)
  S.K.form_set(f, "block_size", 2048); S.K.form_reset_row(f, "block")
  eq(f.values.block_size, S.state.block_size); eq(f.edited.block_size, nil)
end)
test("form_changed_rows_counts_rows_not_keys", function()
  local v = S.K.analysis_defaults(); v.auto_range, v.min_freq, v.max_freq = false, 250, 1200
  eq(S.K.form_changed_rows(v), 1)
  v.threshold = 0.25; eq(S.K.form_changed_rows(v), 2)
  local f = { source = "defaults", values = v }
  eq(S.K.form_header(f), "ANALYSIS SETTINGS · 2 changed from defaults")
  v.threshold = S.state.threshold
  eq(S.K.form_header(f), "ANALYSIS SETTINGS · 1 changed from defaults")
end)
test("form_summary_names_presets_and_custom", function()
  local v = S.K.analysis_defaults()
  eq(S.K.form_summary(v), "Auto · Clean / Strict · Standard (Realtime)", "the factory range is Auto")
  v.auto_range = false   -- the same Hz picked by hand
  eq(S.K.form_summary(v), "Generic Vocal · Clean / Strict · Standard (Realtime)")
  v.max_freq = 999; eq(S.K.form_summary(v):match("^Custom") ~= nil, true)
  eq(S.K.analyzed_with_tip({ analysis = SOPRANO_ANALYSIS }), "Analyzed with Soprano · Clean / Strict · Standard (Realtime)")
  eq(S.K.analyzed_with_tip({}), nil)
end)
test("form_defaults_request_names_changes", function()
  local K, st = S.K, S.state
  local v = K.analysis_defaults(); v.min_freq, v.max_freq, v.auto_range = 250, 1200, false   -- Soprano by hand
  local req = K.form_defaults_request(v)
  eq(req.title, "Make these your defaults?")
  eq(req.body_lines[1], "New analyses will start with: Soprano (was Auto).")
  eq(req.body_lines[2], "Items already analyzed keep their own settings.")
  eq(req.confirm_label, "Save as Default")
  local saved = { K.save_settings, st.min_freq, st.max_freq, reaper.time_precise, st.status.text, st.status.until_time,
    st.auto_range }
  local group
  K.save_settings = function(g) group = g end
  reaper.time_precise = function() return 0 end
  req.on_confirm()
  eq(st.min_freq, 250); eq(st.max_freq, 1200); eq(group, "engine"); eq(st.status.text, "Defaults saved.")
  eq(st.auto_range, false)
  K.save_settings, st.min_freq, st.max_freq, reaper.time_precise = saved[1], saved[2], saved[3], saved[4]
  st.status.text, st.status.until_time, st.auto_range = saved[5], saved[6], saved[7]
end)

test("form_defaults_saved_from_the_modal_reach_the_canvas_form", function()
  local K, st = S.K, S.state
  local saved = { K.save_settings, st.min_freq, st.max_freq, reaper.time_precise, st.status.text, st.status.until_time,
    st.target_take_guid, st.analysis_form, st.auto_range }
  local ok, err = pcall(function()
    K.save_settings = function() end
    reaper.time_precise = function() return 0 end
    st.target_take_guid = "{c}"
    st.analysis_form = K.form_new("{c}", nil)          -- the canvas form, untouched
    local modal = K.form_copy(st.analysis_form)        -- the modal's own copy
    K.form_set(modal, "range", { name = "Tenor", min = 130, max = 500 })
    K.form_defaults_request(modal.values).on_confirm()
    eq(st.analysis_form.values.min_freq, 130, "the untouched canvas form follows the new defaults")
    eq(st.analysis_form.values.max_freq, 500)
    eq(st.analysis_form.values.auto_range, false, "and is no longer Auto")
  end)
  K.save_settings, st.min_freq, st.max_freq, reaper.time_precise = saved[1], saved[2], saved[3], saved[4]
  st.status.text, st.status.until_time, st.target_take_guid, st.analysis_form = saved[5], saved[6], saved[7], saved[8]
  st.auto_range = saved[9]
  if not ok then error(err, 0) end
end)

local function settings_row(section_id, row_id)
  for _, section in ipairs(S.K.SETTINGS_SECTIONS) do
    if section.id == section_id then
      for _, row in ipairs(section.rows) do if row.id == row_id then return row end end
    end
  end
end

test("rows_edit_the_bound_table", function()
  local st = S.state
  local form = S.K.form_new("batch", nil)
  local b = S.K.form_binding(form)
  local range = settings_row("detection", "range")
  local before = { st.min_freq, st.max_freq }
  form.values.auto_range = false -- the Hz are only the user's to set when not Auto
  b.set("min_freq", 250); b.set("max_freq", 1200)
  eq(range.is_default(b), false)
  eq(st.min_freq, before[1], "state untouched"); eq(st.max_freq, before[2], "state untouched")
  range.reset(b)
  eq(range.is_default(b), true)
  eq(form.edited.min_freq, nil)
  eq(form.values.min_freq, st.min_freq)
end)

test("settings_binding_resets_to_factory", function()
  local K, st = S.K, S.state
  local saved = { st.threshold, K.save_settings }
  local b = K.settings_binding()
  st.threshold = 0.25
  local row = settings_row("dsp", "threshold")
  eq(row.is_default(b), false)
  row.reset(b)
  eq(st.threshold, S.DEFAULTS.threshold)
  eq(row.is_default(b), true)
  local group
  K.save_settings = function(g) group = g end
  b.commit()
  eq(group, "engine")
  st.threshold, K.save_settings = saved[1], saved[2]
end)

test("settings_binding_commit_syncs_the_form", function()
  local K, st = S.K, S.state
  local saved = { K.save_settings, st.target_take_guid, st.session_takes["{c3}"], st.analysis_form, st.min_freq, st.max_freq }
  K.save_settings = function() end
  st.target_take_guid = "{c3}"
  st.session_takes["{c3}"] = {}
  st.analysis_form = nil
  K.form_sync("{c3}", st.session_takes["{c3}"])
  st.min_freq, st.max_freq = 250, 1200
  K.settings_binding().commit()
  eq(st.analysis_form.values.min_freq, 250, "untouched rows follow the new defaults")
  st.target_take_guid = nil
  K.settings_binding().commit()   -- no target: no error
  K.save_settings, st.target_take_guid, st.session_takes["{c3}"], st.analysis_form, st.min_freq, st.max_freq = table.unpack(saved, 1, 6)
end)

test("settings_section_renamed", function()
  eq(S.K.SETTINGS_SECTIONS[2].title, "Analysis Defaults")
  eq(S.K.ANALYSIS_DEFAULTS_NOTE, "New analyses start with these. Each item keeps the settings it was analyzed with.")
end)

test("form_binding_shape", function()
  local K = S.K
  local form = K.form_new("batch", nil)
  local b = K.form_binding(form)
  eq(b.v, form.values)
  eq(b.base.min_freq, S.state.min_freq)
  b.commit()   -- a no-op
  b.set("threshold", 0.3)
  eq(form.values.threshold, 0.3)
  b.reset("mode")
  eq(form.values.threshold, S.state.threshold)
end)

test("form_layout_picks_by_space", function()
  local K = S.K
  local need = { row_w = 400, stacked_w = 200, full_h = 120, stacked_h = 200, button_h = 40 }
  eq(K.form_layout(600, 300, need), "full")
  eq(K.form_layout(250, 300, need), "stacked")
  eq(K.form_layout(1200, 110, need), "summary")
end)

test("batch_start_snapshots_given_values", function()
  local real_begin = S.K.analysis_begin
  with_batch(function()
    local K, st = S.K, S.state
    local names = { "GetTakeName", "GetMediaItemInfo_Value", "new_array", "GetSetMediaItemTakeInfo_String" }
    local old, saved_acc, saved_min = {}, K.open_accessor, st.min_freq
    for _, n in ipairs(names) do old[n] = reaper[n] end
    K.analysis_begin = real_begin
    K.open_accessor = function() return "acc" end
    reaper.GetTakeName = function() return "t" end
    reaper.GetMediaItemInfo_Value = function() return 2 end
    reaper.new_array = function() return {} end
    reaper.GetSetMediaItemTakeInfo_String = function(_, key) if key == "GUID" then return true, "{a}" end return true, "" end
    local ok, err = pcall(function()
      local values = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 256 }
      K.batch_start(entries3(), values)
      eq(K.batch.values.auto_range, false, "given values without the Auto flag are a fixed range")
      eq(K.batch.values.min_freq, 250, "the given Hz are kept"); eq(K.batch.values.max_freq, 1200)
      values.min_freq = 80   -- the form changes after the click: the batch keeps what it was started with
      eq(K.batch.values.min_freq, 250, "the batch keeps the values it was started with")
      eq(st.analysis_params.min_freq, 250); eq(st.analysis_params.block_size, 2048); eq(st.analysis_params.hop_size, 256)
      eq(st.min_freq, saved_min, "state.min_freq unchanged")
      K.batch = nil; st.is_analyzing = false
      K.batch_start(entries3())
      eq(K.batch.values.min_freq, st.min_freq, "no values: the defaults")
      eq(st.analysis_params.min_freq, st.min_freq)
    end)
    K.open_accessor = saved_acc
    for _, n in ipairs(names) do reaper[n] = old[n] end
    st.analysis_params, st.accessor, st.buffer = nil, nil, nil
    if not ok then error(err, 0) end
  end)
end)

local TENOR = { name = "Tenor", min = 130, max = 500 }

test("reanalyze_request_carries_form_copy", function()
  local f = S.K.form_new("{a}", { notes = { {} }, analysis = SOPRANO_ANALYSIS })
  local req = S.K.reanalyze_request(4, "Lead Vox", f)
  eq(req.title, "Re-analyze Lead Vox?"); eq(req.confirm_label, "Re-Analyze")
  eq(req.fit, true)
  eq(req.form ~= f, true, "a copy"); eq(req.form.values ~= f.values, true, "its own values")
  eq(req.form.values.min_freq, 250); eq(req.form.source, "item")
  eq(S.K.form_header(req.form), "ANALYSIS SETTINGS · as analyzed before")
  eq(#req.body_lines, 3)
  eq(req.body_lines[1], "This replaces the detected notes and discards your edits to 4 notes.")
  eq(req.body_lines[2], S.K.REANALYZE_VALUES_LINE)
  S.K.form_set(req.form, "range", TENOR)
  eq(f.values.min_freq, 250, "edits in the modal never touch the canvas form")
  eq(f.edited.min_freq, nil)
  local r0 = S.K.reanalyze_request(0, "Lead Vox", f)
  eq(#r0.body_lines, 1); eq(r0.body_lines[1], S.K.REANALYZE_VALUES_LINE)
end)

test("batch_modal_request_titles_and_seeds_defaults", function()
  local K, st = S.K, S.state
  local entries = { { guid = "{a}", name = "A", has_notes = false }, { guid = "{b}", name = "B", has_notes = false } }
  local saved_min = st.min_freq
  st.min_freq = 130   -- the Settings say Tenor's low end
  local ok, err = pcall(function()
    local req = K.batch_modal_request(entries)
    eq(req.title, "Analyze 2 items"); eq(req.confirm_label, "Analyze 2 Items")
    eq(req.form.source, "defaults"); eq(req.form.guid, "batch"); eq(req.form.values.min_freq, 130)
    eq(#req.body_lines, 0, "no item holds notes: nothing to warn about"); eq(req.list, nil)
    eq(req.fit, true)
    eq(st.analysis_form == req.form, false, "never the canvas form")
    entries[2].has_notes = true
    local warn = K.batch_modal_request(entries)
    eq(warn.title, "Analyze 2 items", "the modal's title, not the old confirm's question")
    eq(warn.body_lines[1], "1 of them already has notes. Analyzing replaces its notes and any edits:")
    eq(#warn.list, 1); eq(warn.list[1].name, "B")
    eq(#warn.after_lines, 2)
    local started
    local real = K.batch_start
    K.batch_start = function(e, v) started = { e = e, v = v } end
    local ok2, err2 = pcall(function() warn.on_confirm(warn.form.values) end)
    K.batch_start = real
    if not ok2 then error(err2, 0) end
    eq(started.e, entries); eq(started.v, warn.form.values)
  end)
  st.min_freq = saved_min
  if not ok then error(err, 0) end
end)

test("batch_uses_and_stores_modal_values", function()
  local real_begin = S.K.analysis_begin
  with_batch(function()
    local K, st = S.K, S.state
    local names = { "GetTakeName", "GetMediaItemInfo_Value", "new_array", "GetSetMediaItemTakeInfo_String" }
    local old, saved_acc, saved_min, saved_form = {}, K.open_accessor, st.min_freq, st.analysis_form
    for _, n in ipairs(names) do old[n] = reaper[n] end
    K.analysis_begin = real_begin
    K.open_accessor = function() return "acc" end
    reaper.GetTakeName = function() return "t" end
    reaper.GetMediaItemInfo_Value = function() return 2 end
    reaper.new_array = function() return {} end
    reaper.GetSetMediaItemTakeInfo_String = function(_, key) if key == "GUID" then return true, "{a}" end return true, "" end
    local ok, err = pcall(function()
      st.min_freq = 80   -- the Settings hold Bass; the modal picks Soprano
      local req = K.batch_modal_request(entries3())
      K.form_set(req.form, "range", { name = "Soprano", min = 250, max = 1200 })
      req.on_confirm(req.form.values)
      eq(K.batch ~= nil, true, "the batch runs")
      eq(K.batch.values.min_freq, 250, "the batch keeps the modal's values")
      eq(st.analysis_params.min_freq, 250, "the first item is analysed with them")
      eq(st.analysis_params.max_freq, 1200)
      eq(st.min_freq, 80, "state.min_freq unchanged")
      eq(st.analysis_form, saved_form, "the canvas form is not replaced")
      K.cancel_analysis()
      eq(K.batch, nil, "cancelled")
    end)
    K.open_accessor = saved_acc
    for _, n in ipairs(names) do reaper[n] = old[n] end
    st.analysis_params, st.accessor, st.buffer = nil, nil, nil
    st.min_freq = saved_min
    if not ok then error(err, 0) end
  end)
end)

test("confirm_enter_runs_primary_only_with_form", function()
  local K, st = S.K, S.state
  eq(K.confirm_enter({}), false, "existing confirms: Enter is not theirs")
  eq(K.confirm_enter({ form = { values = {} } }), true)
  local saved = st.confirm
  S.request_confirm({ title = "T", on_confirm = function() end })
  eq(K.confirm_enter(st.confirm), false)
  local f = K.form_new("batch", nil)
  S.request_confirm({ title = "T", form = f, on_confirm = function() end })
  eq(st.confirm.form, f); eq(K.confirm_enter(st.confirm), true)
  st.confirm = saved
end)

-- Draws the confirm modal with Enter pressed (Shortcut true for Enter only) and returns what on_confirm received.
local function confirm_with_enter(req, active)
  local K, st = S.K, S.state
  local got = { called = false }
  req.on_confirm = function(...) got.called = true; got.args = { ... } end
  local enter, kp_enter = 1001, 1002
  local stubs = {
    ImGui_Key_Enter = function() return enter end,
    ImGui_Key_KeypadEnter = function() return kp_enter end,
    ImGui_Shortcut = function(_, key) return key == enter end,
    ImGui_IsAnyItemActive = function() return active == true end,
    ImGui_IsPopupOpen = function(_, name) return name ~= "" end,   -- the modal is open, nothing over it
    ImGui_BeginPopupModal = function() return true, true end,
    ImGui_BeginChild = function() return true end,
    ImGui_BeginTable = function() return false end,
    ImGui_GetWindowSize = function() return 560, 480 end,
    ImGui_GetWindowPos = function() return 100, 50 end,
    ImGui_Viewport_GetPos = function() return 0, 0 end,
    ImGui_Viewport_GetSize = function() return 800, 600 end,
    ImGui_GetContentRegionAvail = function() return 520, 400 end,
    ImGui_GetStyleVar = function() return 4, 4 end,
    ImGui_GetFrameHeight = function() return 20 end,
    ImGui_GetFrameHeightWithSpacing = function() return 24 end,
    ImGui_GetTextLineHeight = function() return 14 end,
    ImGui_GetFontSize = function() return 13 end,
    ImGui_CalcTextSize = function() return 40, 14 end,
    ImGui_GetCursorPosX = function() return 0 end,
    ImGui_GetCursorPosY = function() return 0 end,
  }
  for k, v in pairs(stubs) do reaper[k] = v end
  local saved, real_form_draw = st.confirm, K.confirm_form_draw
  -- The form's widgets are checked in real REAPER; here only what Enter does
  K.confirm_form_draw = function() end
  local ok, err = pcall(function()
    S.request_confirm(req)
    S.draw_confirm_modal()
  end)
  K.confirm_form_draw = real_form_draw
  for k in pairs(stubs) do reaper[k] = nil end
  st.confirm = saved
  K.form_metrics_cache = nil
  if not ok then error(err, 0) end
  return got
end

test("confirm_enter_confirms_the_form_with_its_values", function()
  local f = S.K.form_new("batch", nil)
  local got = confirm_with_enter({ title = "Analyze 2 items", form = f, confirm_label = "Analyze 2 Items", fit = true })
  eq(got.called, true, "Enter runs the primary")
  eq(got.args[1], f.values, "on_confirm receives form.values")
  eq(confirm_with_enter({ title = "Delete?", body_lines = { "x" } }).called, false, "no form: Enter does nothing")
  eq(confirm_with_enter({ title = "T", form = S.K.form_new("batch", nil) }, true).called, false,
    "not while an item (a field) is active")
end)

test("request_analyze_modal_only_on_analysed_items", function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.target_take_name, st.notes, st.confirm, st.analysis_form }
  local ok, err = pcall(function()
    st.session_takes["{a}"] = { notes = { {} }, analysis = SOPRANO_ANALYSIS }
    st.target_take_guid, st.target_take_name = "{a}", "Lead Vox"
    st.notes = { { avg_note = 60 } }   -- analysed, nothing edited (no controls: not modified)
    st.analysis_form = K.form_new("{a}", st.session_takes["{a}"])
    st.confirm = nil
    K.request_analyze()
    local c = st.confirm
    eq(c ~= nil, true, "an analysed item always gets the modal")
    eq(c.title, "Re-analyze Lead Vox?"); eq(c.id, "reanalyze")
    eq(#c.body_lines, 1); eq(c.body_lines[1], K.REANALYZE_VALUES_LINE)
    eq(c.form.values.min_freq, 250, "seeded from the item")
    eq(c.form ~= st.analysis_form, true)
  end)
  st.target_take_guid, st.target_take_name, st.notes, st.confirm, st.analysis_form = table.unpack(saved, 1, 5)
  st.session_takes["{a}"] = nil
  if not ok then error(err, 0) end
end)

test("analyze_change_request_copies_values_back", function()
  local K, st = S.K, S.state
  local saved = { st.target_take_guid, st.target_take_name, st.analysis_form, st.status.text }
  local ok, err = pcall(function()
    st.target_take_guid, st.target_take_name = "{z}", "Lead Vox"
    st.analysis_form = K.form_new("{z}", nil)
    local req = K.analyze_change_request(st.analysis_form)
    eq(req.title, "Analyze Lead Vox"); eq(req.confirm_label, "Analyze"); eq(req.fit, true)
    eq(req.form ~= st.analysis_form, true, "a copy")
    K.form_set(req.form, "range", TENOR)
    eq(st.analysis_form.values.min_freq, st.min_freq, "the canvas form is untouched")
    reaper.CountMediaItems = function() return 0 end
    reaper.CountSelectedMediaItems = function() return 0 end
    reaper.time_precise = function() return 0 end
    req.on_confirm(req.form.values)   -- no take in the stub: start_analysis says so
    reaper.CountMediaItems, reaper.CountSelectedMediaItems, reaper.time_precise = nil, nil, nil
    eq(st.status.text, "Select an audio item first", "start_analysis ran")
    eq(st.analysis_form.values.min_freq, 130, "the values come back to the canvas form")
    eq(st.analysis_form.values.max_freq, 500)
    eq(st.analysis_form.edited.min_freq, true, "marked edited")
    eq(st.analysis_form.edited.threshold, nil, "unchanged keys are not")
  end)
  st.target_take_guid, st.target_take_name, st.analysis_form, st.status.text = table.unpack(saved, 1, 4)
  if not ok then error(err, 0) end
end)

test("info_lists_the_analysis_modal", function()
  local found = false
  for _, section in ipairs(S.K.INFO_SECTIONS) do
    for _, row in ipairs(section.rows) do
      if row[2] == "Re-Analyze… opens the analysis settings; Enter analyzes, Esc cancels" then found = true end
    end
  end
  eq(found, true)
end)

test("child_dim_skips_the_first_open_frame_and_releases_on_close", function()
  local K = S.K
  K.child_dim_seen = {}
  eq(K.child_dim_due("t", false), false, "no modal: never dimmed")
  eq(K.child_dim_due("t", true), false, "first frame open: skipped, as Theme.modal_scrim does")
  eq(K.child_dim_due("t", true), true, "from the next frame on: dimmed")
  eq(K.child_dim_due("t", true), true)
  eq(K.child_dim_due("u", true), false, "each child has its own latch")
  eq(K.child_dim_due("t", false), false, "closed: not dimmed")
  eq(K.child_dim_due("t", true), false, "opened again: the first frame is skipped again")
  K.child_dim_seen = {}
end)

test("child_dim_fills_the_child_rect_with_dim_bg", function()
  local K = S.K
  local fills, clips = {}, 0
  local stubs = {
    ImGui_GetWindowDrawList = function() return "dl" end,
    ImGui_GetWindowPos = function() return 10, 20 end,
    ImGui_GetWindowSize = function() return 300, 100 end,
    ImGui_DrawList_PushClipRect = function() clips = clips + 1 end,
    ImGui_DrawList_PopClipRect = function() clips = clips - 1 end,
    ImGui_DrawList_AddRectFilled = function(dl, x1, y1, x2, y2, col)
      fills[#fills + 1] = { dl = dl, x1 = x1, y1 = y1, x2 = x2, y2 = y2, col = col }
    end,
  }
  for k, v in pairs(stubs) do reaper[k] = v end
  local ok, err = pcall(function()
    K.child_dim_seen = {}
    K.child_dim("c", true)
    eq(#fills, 0, "first open frame: nothing drawn")
    K.child_dim("c", true)
    eq(#fills, 1, "then one fill")
    local f = fills[1]
    eq(f.dl, "dl"); eq(f.x1, 10); eq(f.y1, 20); eq(f.x2, 310); eq(f.y2, 120)
    eq(f.col, package.loaded["theme"].get_palette().dim_bg, "the scrim's own colour")
    eq(clips, 0, "clip push / pop balanced")
    K.child_dim("c", false)
    eq(#fills, 1, "closed: nothing drawn")
  end)
  for k in pairs(stubs) do reaper[k] = nil end
  K.child_dim_seen = {}
  if not ok then error(err, 0) end
end)

test("canvas_form_while_analyzing_shows_the_running_values_locked", function()
  local K, st = S.K, S.state
  local saved = { st.is_analyzing, st.analysis_params, st.analysis_form, st.target_take_guid, st.results,
    st.analysis_empty, K.canvas_batch_form, K.canvas_running_form }
  local ok, err = pcall(function()
    st.target_take_guid = "{run}"
    st.analysis_form = K.form_new("{run}", nil)        -- the open item's form: the Settings' values
    st.results, st.analysis_empty, st.is_analyzing = {}, false, false
    local shows, no_notes = K.empty_canvas()
    eq(shows, true, "not analysed: the form"); eq(no_notes, false)
    local form, reason = K.canvas_form(true, false)
    eq(form, st.analysis_form, "idle: the open item's form"); eq(reason, nil)

    -- A Re-Analyze from the modal with Soprano, before its first slice: the form, locked
    st.is_analyzing = true
    st.analysis_params = { min_freq = 250, max_freq = 1200, threshold = 0.25, block_size = 2048, hop_size = 512 }
    st.results = {}
    shows, no_notes = K.empty_canvas()
    eq(shows, true, "analysing, no frames yet: the form")
    eq(no_notes, false, "no 'No pitched notes found' / Re-Analyze while running")
    form, reason = K.canvas_form(true, false)
    eq(reason, K.LOCKED_REASON, "locked with the inline reason")
    eq(form ~= st.analysis_form, true, "not the open item's form")
    for _, key in ipairs(K.ANALYSIS_KEYS) do eq(form.values[key], st.analysis_params[key], key .. ": the running value") end
    eq(K.form_summary(form.values), "Soprano · Breathy / Lenient · " .. select(3, K.form_part_names(form.values)))
    eq(K.canvas_form(true, false), form, "the same run: the same form")
    eq(K.canvas_form(false, true), form, "a batch run: the values it runs with too")
    eq(st.analysis_form.values.min_freq, st.min_freq, "the open item's form is untouched")

    -- The first slice fills state.results: the pitch line draws in (the notes canvas), never the no-notes canvas,
    -- even when the last analysis of this item found no pitched note
    st.results = { { time = 0 } }
    eq((K.empty_canvas()), false, "analysing with frames in: the pitch line, not the form")
    st.analysis_empty = true
    shows, no_notes = K.empty_canvas()
    eq(shows, false, "a stale 'no notes' flag does not hide the pitch line while running"); eq(no_notes, false)

    -- Done with no pitched note: the no-notes canvas, and the open item's form again
    st.is_analyzing, st.analysis_params, st.analysis_empty = false, nil, true
    shows, no_notes = K.empty_canvas()
    eq(shows, true); eq(no_notes, true, "finished without notes: the no-notes canvas")
    form, reason = K.canvas_form(true, false)
    eq(form, st.analysis_form); eq(reason, nil)
    st.analysis_empty = false
    eq((K.empty_canvas()), false, "notes found: the notes canvas")
  end)
  st.is_analyzing, st.analysis_params, st.analysis_form, st.target_take_guid, st.results = saved[1], saved[2], saved[3],
    saved[4], saved[5]
  st.analysis_empty, K.canvas_batch_form, K.canvas_running_form = saved[6], saved[7], saved[8]
  if not ok then error(err, 0) end
end)

test("freq_drags_cannot_meet_or_cross", function()
  local K = S.K
  local lo, hi = K.drag_bounds("min_freq", { min_freq = 65, max_freq = 1000 })
  eq(lo, K.LIMITS.min_freq[1]); eq(hi, 999, "Min Freq stops 1 Hz under Max Freq")
  lo, hi = K.drag_bounds("max_freq", { min_freq = 65, max_freq = 1000 })
  eq(lo, 66, "Max Freq stops 1 Hz over Min Freq"); eq(hi, K.LIMITS.max_freq[2])
  lo, hi = K.drag_bounds("min_freq", { min_freq = 250, max_freq = 1200 })
  eq(250 >= lo and 250 <= hi, true, "Soprano's 250 Hz is inside Min Freq's range (not snapped to 200)")
  lo, hi = K.drag_bounds("min_freq", { min_freq = 100, max_freq = 200 })
  eq(lo, K.LIMITS.min_freq[1]); eq(hi, 199)
  local v = K.analysis_defaults(); v.min_freq, v.max_freq = hi, 200
  eq(K.analysis_values(v) ~= nil, true, "the closest the drags allow is a valid analysis")
  lo, hi = K.drag_bounds("threshold", { threshold = 0.1 })
  eq(lo, K.LIMITS.threshold[1]); eq(hi, K.LIMITS.threshold[2])
  for _, r in ipairs({ { 65, 1000 }, { 250, 1200 }, { 170, 800 }, { 130, 500 }, { 80, 350 } }) do   -- VOCAL_RANGES
    local a, b = K.drag_bounds("min_freq", { min_freq = r[1], max_freq = r[2] })
    eq(r[1] >= a and r[1] <= b, true, r[1] .. " Hz inside Min Freq's range")
    a, b = K.drag_bounds("max_freq", { min_freq = r[1], max_freq = r[2] })
    eq(r[2] >= a and r[2] <= b, true, r[2] .. " Hz inside Max Freq's range")
  end
end)

test("stored_soprano_min_freq_loads_unclamped", function()
  local T = load_script({ pitch_min_freq = "250", pitch_max_freq = "1200" })
  reaper.GetExtState = function() return "" end   -- the harness's own stub again
  eq(T.state.min_freq, 250, "not snapped to 200")
  eq(T.state.max_freq, 1200)
end)

test("analysis_begin_falls_back_when_min_is_not_below_max", function()
  local K, st = S.K, S.state
  local saved_params = st.analysis_params
  local stubs = {
    GetMediaItemTake_Source = function() return "src" end, GetMediaSourceSampleRate = function() return 44100 end,
    GetMediaItemInfo_Value = function() return 1 end, new_array = function() return {} end,
  }
  local saved_open, saved_state = K.open_accessor, {}
  for _, key in ipairs({ "is_analyzing", "results", "target_take_guid", "accessor", "buffer", "sample_rate",
      "item_len", "end_time", "current_time", "start_time", "progress", "separation", "analysis_empty" }) do
    saved_state[key] = st[key]
  end
  for k, f in pairs(stubs) do reaper[k] = f end
  local ok, err = pcall(function()
    K.open_accessor = function() return "acc" end
    local bad = { min_freq = 200, max_freq = 200, threshold = 0.25, block_size = 2048, hop_size = 512 }
    eq(K.analysis_begin("take", "item", { values = bad, defer_envelope = true }), true)
    local d = K.analysis_defaults()
    eq(st.analysis_params.min_freq, d.min_freq, "zero-width range: the Settings' values")
    eq(st.analysis_params.max_freq, d.max_freq)
    eq(st.analysis_params.threshold, d.threshold, "the whole set, not a mix")
    eq(K.analysis_values(st.analysis_params) ~= nil, true, "what it stores is a valid record")
  end)
  for k in pairs(stubs) do reaper[k] = nil end
  K.open_accessor = saved_open
  for key, v in pairs(saved_state) do st[key] = v end
  st.is_analyzing = saved_state.is_analyzing
  st.analysis_params = saved_params
  if not ok then error(err, 0) end
end)

test("analyzed_with_tip_ignores_a_malformed_record", function()
  eq(S.K.analyzed_with_tip({ analysis = { min_freq = 200, max_freq = 200, threshold = 0.15, block_size = 2048,
    hop_size = 512 } }), nil, "min not below max: not recorded")
  eq(S.K.analyzed_with_tip({ analysis = "x" }), nil)
end)

test("form_defaults_request_is_safe_and_fit", function()
  local req = S.K.form_defaults_request(S.K.analysis_defaults())
  eq(req.safe, true, "CL3: no red added")
  eq(req.fit, true, "sized to its two lines")
end)

local function tally_of(notes)   -- { [midi] = frames }
  local t = S.K.pre_tally_new()
  for midi, n in pairs(notes) do
    for _ = 1, n do S.K.pre_tally_add(t, 440 * 2 ^ ((midi - 69) / 12)) end
  end
  return t
end

test("pre_range_trims_outliers", function()
  local t = tally_of({ [40] = 200, [52] = 400, [69] = 200, [88] = 2, [28] = 2 })
  local lo, hi = S.K.pre_range(t)
  eq(lo, 40); eq(hi, 69)
end)

test("pre_range_needs_frames", function()
  eq(S.K.pre_range(tally_of({ [60] = 29 })), nil)
end)

test("pre_range_hz_margin_and_limits", function()
  local lo, hi = S.K.pre_range_hz(40, 69)          -- E2 .. A4
  near(lo, 440 * 2 ^ ((37 - 69) / 12), 1)           -- 3 st below
  near(hi, 440 * 2 ^ ((73 - 69) / 12), 1)           -- 4 st above
  local lo2, hi2 = S.K.pre_range_hz(0, 127)
  eq(lo2, S.K.LIMITS.min_freq[1]); eq(hi2, S.K.LIMITS.max_freq[2])
end)

test("pre_key_major", function()   -- E major scale, tonic and fifth weighted
  local k, s = S.K.pre_key(tally_of({ [52]=300, [54]=100, [56]=180, [57]=120, [59]=250, [61]=100, [63]=60 }))
  eq(k, 5); eq(s, 1)               -- SCALE_KEYS[5] = E, SCALE_DEFINITIONS[1] = Major
end)

test("pre_key_minor", function()   -- A natural minor
  local k, s = S.K.pre_key(tally_of({ [57]=300, [59]=100, [60]=180, [62]=120, [64]=250, [65]=100, [67]=100 }))
  eq(k, 10); eq(s, 2)
end)

test("pre_key_close_call_names_runner_up", function()   -- flat use of the seven notes of C major / A minor
  local k, s, ak, as = S.K.pre_key(tally_of({ [60]=100, [62]=100, [64]=100, [65]=100, [67]=100, [69]=100, [71]=100 }))
  eq(type(ak), "number"); eq(type(as), "number")
  eq((k == 1 and s == 1 and ak == 10 and as == 2) or (k == 10 and s == 2 and ak == 1 and as == 1), true)
end)

test("pre_key_needs_frames", function()
  eq(S.K.pre_key(tally_of({ [60] = 99 })), nil)
end)

test("pre_range_text", function() eq(S.K.pre_range_text(40, 69), "E2\xE2\x80\x93A4") end)

local JSON = require("json")   -- on package.path since the script loaded

-- Track record (2026-11-25) ------------------------------------------------------------------------------------------
local function full_record()
  return { st = { ["52"] = 300, ["59"] = 250 }, takes = { ["{a}"] = true }, lo_st = 52, hi_st = 59,
    key_idx = 5, scale_idx = 1, alt_key_idx = 2, alt_scale_idx = 2, skipped = 1 }
end

test("track_record_valid_accepts", function()
  local K = S.K
  local back = K.track_record_valid(JSON.decode(JSON.encode(full_record())))
  eq(type(back), "table")
  eq(back.lo_st, 52); eq(back.hi_st, 59); eq(back.key_idx, 5); eq(back.alt_scale_idx, 2)
  eq(back.st["52"], 300); eq(back.takes["{a}"], true)
  local one = full_record(); one.lo_st, one.hi_st = 60, 60
  eq(type(K.track_record_valid(one)), "table", "one note is a range")
  local none = { st = {}, takes = {} }
  eq(type(K.track_record_valid(none)), "table", "nothing sung, no key")
end)

test("track_record_valid_rejects", function()
  local K = S.K
  local function bad(mut, msg)
    local r = full_record(); mut(r)
    eq(K.track_record_valid(r), nil, msg)
  end
  eq(K.track_record_valid("text"), nil, "string")
  bad(function(r) r.key_idx = 13 end, "key 13")
  bad(function(r) r.scale_idx = 7 end, "scale 7")
  bad(function(r) r.lo_st, r.hi_st = 61, 60 end, "lo > hi")
  bad(function(r) r.hi_st = nil end, "lo without hi")
  bad(function(r) r.st["52"] = "x" end, "st non-number")
  bad(function(r) r.alt_scale_idx = nil end, "alt key without alt scale")
  bad(function(r) r.skipped = -1 end, "negative skipped")
  bad(function(r) r.takes = "x" end, "takes not a table")
end)

test("track_record_build_keeps_key", function()
  local K = S.K
  local prev = { st = { ["52"] = 200, ["54"] = 200 }, takes = { ["{a}"] = true }, lo_st = 52, hi_st = 54,
    key_idx = 5, scale_idx = 1, skipped = 2 }
  local tally = K.pre_tally_new()
  for _ = 1, 200 do K.pre_tally_add(tally, 440 * 2 ^ ((69 - 69) / 12)) end   -- A4 = 69
  for _ = 1, 200 do K.pre_tally_add(tally, 440 * 2 ^ ((71 - 69) / 12)) end
  local r = K.track_record_build(tally, { ["{b}"] = true }, prev)
  eq(r.key_idx, 5); eq(r.scale_idx, 1); eq(r.alt_key_idx, nil)
  eq(r.lo_st, 52); eq(r.hi_st, 71)
  eq(r.takes["{a}"], true); eq(r.takes["{b}"], true)
  eq(r.st["52"], 200); eq(r.st["69"], 200)
  eq(r.skipped, 2)
  eq(type(K.track_record_valid(r)), "table")
  local t2 = K.track_record_tally(r)
  eq(t2.st[52], 200); eq(t2.n, 800)
end)

test("track_records_flush_writes_once", function()
  local K = S.K
  local writes, undo = {}, 0
  reaper.GetSetMediaTrackInfo_String = function(track, key, value, set)
    if set then writes[#writes + 1] = { track = track, key = key, value = value } end
    return true, ""
  end
  reaper.Undo_BeginBlock = function() undo = undo + 1 end
  local ok, err = pcall(function()
    K.track_records_pending["tr1"] = full_record()
    K.track_records_pending["tr2"] = full_record()
    K.track_records_flush()
    eq(#writes, 2)
    eq(writes[1].key, K.TRACK_SCAN_KEY)
    eq(K.track_record_valid(JSON.decode(writes[1].value)) ~= nil, true)
    eq(next(K.track_records_pending), nil)
    eq(undo, 0, "no undo block")
    K.track_records_flush()
    eq(#writes, 2, "second flush writes nothing")
  end)
  reaper.GetSetMediaTrackInfo_String, reaper.Undo_BeginBlock = nil, nil
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

-- The pre-analysis runner (K.pre_*) ---------------------------------------------------------------

-- One track "tr" with two 20 s audio items (takes "tk_a" / "tk_b", GUIDs "{a}" / "{b}") whose audio is a 220 Hz sine
-- read at the asked rate. opts: prev (the record the track holds), unreadable (a take K.open_accessor gives nil
-- for), step (seconds reaper.time_precise advances per call, 0 by default), silent (a take whose every read
-- gives 0), len ({ [item] = s }:
-- an item's length, 20 s otherwise), stubs (more reaper stubs, put in over these). w.opened lists the takes
-- K.open_accessor was asked for. fn(w) runs with the stubs in place;
-- they are all put back afterwards, and the pre-analysis is cancelled. w records the reads, destroys, track writes
-- and undo blocks; a pointer put in w.dead is no longer valid (reaper.ValidatePtr2).
local function pre_world(opts, fn)
  local K, st = S.K, S.state
  local w = { reads = {}, destroyed = 0, writes = 0, undo = 0, now = 0, dead = {}, opened = {} }
  local takes = { it_a = "tk_a", it_b = "tk_b" }
  local guids = { tk_a = "{a}", tk_b = "{b}" }
  local stubs = {
    ValidatePtr2 = function(_, ptr) return ptr ~= nil and not w.dead[ptr] end,
    CountTrackMediaItems = function(track) return track == "tr" and 2 or 0 end,
    GetTrackMediaItem = function(_, i) return ({ [0] = "it_a", [1] = "it_b" })[i] end,
    GetActiveTake = function(item) return takes[item] end,
    TakeIsMIDI = function() return false end,
    GetMediaItemInfo_Value = function(item, key)
      if key == "D_LENGTH" then return opts.len and opts.len[item] or 20 end
      return 0
    end,
    GetSetMediaItemTakeInfo_String = function(take, key)
      if key == "GUID" and guids[take] then return true, guids[take] end
      return false, ""
    end,
    GetSetMediaTrackInfo_String = function(_, _, _, set)
      if set then w.writes = w.writes + 1 end
      return false, ""
    end,
    Undo_BeginBlock = function() w.undo = w.undo + 1 end,
    new_array = function() return {} end,
    GetAudioAccessorSamples = function(acc, rate, _, t, n, buf)
      w.reads[#w.reads + 1] = { acc = acc, rate = rate, t = t, n = n }
      if opts.silent and acc == "acc_" .. opts.silent then return 0 end
      for i = 1, n do buf[i] = 0.5 * math.sin(2 * math.pi * 220 * (t + (i - 1) / rate)) end
      return 1
    end,
    DestroyAudioAccessor = function() w.destroyed = w.destroyed + 1 end,
    time_precise = function()
      w.now = w.now + (opts.step or 0)
      return w.now
    end,
  }
  for name, f in pairs(opts.stubs or {}) do stubs[name] = f end
  local old = {}
  for name, f in pairs(stubs) do
    old[name] = rawget(reaper, name)
    rawset(reaper, name, f)
  end
  local old_open, old_record = K.open_accessor, K.track_record
  -- no analysis is running (an earlier test may leave its stub accessor behind)
  local old_analyzing, old_accessor = st.is_analyzing, st.accessor
  st.is_analyzing, st.accessor = false, nil
  K.open_accessor = function(take)
    w.opened[#w.opened + 1] = take
    if take == opts.unreadable then return nil end
    return "acc_" .. take
  end
  K.track_record = function(track) if track == "tr" then return opts.prev end return nil end
  local ok, err = pcall(fn, w)
  K.pre_cancel()
  K.open_accessor, K.track_record = old_open, old_record
  st.is_analyzing, st.accessor = old_analyzing, old_accessor
  for name in pairs(stubs) do rawset(reaper, name, old[name]) end
  if not ok then error(err, 0) end
end

-- Steps the pre-analysis until it ends (bounded)
local function pre_run_out()
  for _ = 1, 100000 do
    if S.state.pre == nil then return end
    S.K.pre_step()
  end
  error("the pre-analysis never ended")
end

test("pre_runs_to_a_record", function()
  pre_world({}, function(w)
    local K, st = S.K, S.state
    local calls, got = 0, nil
    eq(K.pre_begin({ "tr" }, { on_done = function(results) calls = calls + 1; got = results end }), true)
    eq(st.is_analyzing, true, "the pre-analysis counts as analysing")
    eq(#st.pre.queue, 1); eq(st.pre.n_tracks, nil, "no count of its own"); eq(st.pre.track_idx, nil)
    eq(type(st.pre.track_name), "string")
    pre_run_out()
    eq(calls, 1, "on_done once")
    local rec = got["tr"]
    eq(type(rec), "table", "a record for the track")
    eq((rec.st["57"] or 0) > 0, true, "220 Hz heard as MIDI 57")
    eq(rec.lo_st, 57); eq(rec.hi_st, 57)
    eq(rec.takes["{a}"], true); eq(rec.takes["{b}"], true)
    eq(K.track_records_pending["tr"], rec, "pending for the caller's undo block")
    eq(st.pre, nil)
    eq(st.is_analyzing, false, "on_done started nothing: no longer analysing")
    eq(w.reads[1].rate, K.PRE.RATE); eq(w.reads[1].n, K.PRE.BLOCK)
    eq(w.destroyed, 2, "each accessor destroyed")
    eq(w.writes, 0, "nothing written to the track"); eq(w.undo, 0, "no undo block")
    eq(K.pre_progress(), 1, "done")
  end)
end)

test("pre_skips_heard_takes", function()
  local K = S.K
  local prev = K.track_record_build(K.pre_tally_new(), { ["{a}"] = true }, nil)
  pre_world({ prev = prev }, function(w)
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    eq(#w.reads > 0, true)
    for _, r in ipairs(w.reads) do eq(r.acc, "acc_tk_b", "only the take not heard yet is read") end
    local rec = K.track_records_pending["tr"]
    eq(rec.takes["{a}"], true, "the heard take stays listed"); eq(rec.takes["{b}"], true)
  end)
end)

test("pre_fresh_rehears_all", function()
  local K = S.K
  local old_tally = K.pre_tally_new()
  for _ = 1, 500 do K.pre_tally_add(old_tally, 440) end   -- MIDI 69, never in this audio
  local prev = K.track_record_build(old_tally, { ["{a}"] = true, ["{b}"] = true }, nil)
  pre_world({ prev = prev }, function(w)
    eq(K.pre_begin({ "tr" }, { fresh = true }), true)
    pre_run_out()
    local seen = {}
    for _, r in ipairs(w.reads) do seen[r.acc] = true end
    eq(seen["acc_tk_a"], true); eq(seen["acc_tk_b"], true)
    local rec = K.track_records_pending["tr"]
    eq(rec.st["69"], nil, "the old tally is not merged")
    eq(rec.lo_st, 57); eq(rec.hi_st, 57)
  end)
end)

test("pre_slice_budget", function()
  pre_world({ step = 0.003 }, function(w)
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    K.pre_step()
    eq(#w.reads <= 3, true, "at most three blocks in one slice, got " .. #w.reads)
    eq(#w.reads > 0, true, "the slice read something")
    local p = K.pre_progress()
    eq(p > 0 and p < 1, true, "part way")
    local before = #w.reads
    K.analysis_tick()
    eq(#w.reads > before, true, "the window's analysis tick steps the pre-analysis")
  end)
end)

test("pre_cancel_leaves_nothing", function()
  pre_world({ step = 0.003 }, function(w)
    local K, st = S.K, S.state
    local done = 0
    eq(K.pre_begin({ "tr" }, { on_done = function() done = done + 1 end }), true)
    -- a record from an earlier run that is not flushed yet goes with the cancel too
    K.track_records_pending["other"] = { st = {}, takes = {} }
    K.pre_step(); K.pre_step()
    eq(K.cancel_analysis(), true)
    eq(st.pre, nil)
    eq(next(K.track_records_pending), nil)
    eq(w.destroyed, 1, "the open accessor destroyed once")
    eq(w.writes, 0); eq(w.undo, 0)
    eq(done, 0, "on_done not called")
    eq(st.is_analyzing, false)
    K.pre_cancel()   -- nothing runs: safe
    eq(w.destroyed, 1)
  end)
end)

test("pre_unreadable_take_is_counted", function()
  pre_world({ unreadable = "tk_a" }, function(w)
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    local rec = K.track_records_pending["tr"]
    eq(rec.skipped, 1)
    eq(rec.takes["{a}"], nil, "not heard: tried again next time")
    eq(rec.takes["{b}"], true)
    eq(rec.lo_st, 57)
    for _, r in ipairs(w.reads) do eq(r.acc, "acc_tk_b") end
  end)
end)

test("pre_nothing_to_hear", function()
  local K = S.K
  local prev = K.track_record_build(K.pre_tally_new(), { ["{a}"] = true, ["{b}"] = true }, nil)
  pre_world({ prev = prev }, function(w)
    local st = S.state
    local got, calls = nil, 0
    eq(K.pre_begin({ "tr", "empty" }, { on_done = function(r) got = r; calls = calls + 1 end }), false)
    eq(calls, 1, "on_done at once")
    eq(got["tr"], prev, "a track heard whole gives its record")
    eq(K.track_records_pending["tr"], nil, "and is not written again")
    local empty = got["empty"]
    eq(type(empty), "table", "a track with no audio gets a record")
    eq(empty.lo_st, nil); eq(empty.key_idx, nil)
    eq(K.track_records_pending["empty"], empty, "kept, so it is not heard every time")
    eq(st.pre, nil); eq(#w.reads, 0)
    eq(K.pre_progress(), 0, "nothing queued")
  end)
end)

test("pre_take_gone_mid_run_is_skipped", function()
  pre_world({ step = 0.003 }, function(w)
    local K, st = S.K, S.state
    eq(K.pre_begin({ "tr" }, {}), true)
    K.pre_step()
    eq(#w.reads > 0, true, "take a is being read")
    w.dead["tk_a"] = true   -- the user deleted or glued it between two frames
    local reads_a = #w.reads
    pre_run_out()
    for i = reads_a + 1, #w.reads do eq(w.reads[i].acc, "acc_tk_b", "the gone take is not read again") end
    eq(w.destroyed, 2, "its accessor destroyed, and take b's")
    local rec = K.track_records_pending["tr"]
    eq(rec.skipped, 1); eq(rec.takes["{a}"], nil); eq(rec.takes["{b}"], true)
    eq(st.pre, nil)
  end)
end)

test("pre_item_gone_before_open_is_skipped", function()
  pre_world({}, function(w)
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    w.dead["it_b"] = true
    pre_run_out()
    for _, r in ipairs(w.reads) do eq(r.acc, "acc_tk_a") end
    eq(K.track_records_pending["tr"].skipped, 1)
  end)
end)

test("pre_track_gone_mid_run_leaves_nothing", function()
  pre_world({ step = 0.003 }, function(w)
    local K, st = S.K, S.state
    local calls, got = 0, nil
    eq(K.pre_begin({ "tr", "empty" }, { on_done = function(r) calls = calls + 1; got = r end }), true)
    eq(K.track_records_pending["empty"] ~= nil, true, "the empty track's record is pending from the start")
    K.pre_step()
    w.dead["tr"] = true
    pre_run_out()
    eq(calls, 1, "on_done once")
    eq(got["tr"], nil, "no record for the gone track")
    eq(K.track_records_pending["tr"], nil, "nothing pending for it")
    eq(got["empty"] ~= nil, true, "the other track still has its record")
    eq(w.destroyed, 1, "the open accessor destroyed")
    eq(st.pre, nil); eq(st.is_analyzing, false)
  end)
end)

test("pre_gone_track_is_not_queued", function()
  pre_world({}, function(w)
    local K = S.K
    w.dead["tr"] = true
    local got
    eq(K.pre_begin({ "tr" }, { on_done = function(r) got = r end }), false)
    eq(next(got), nil); eq(next(K.track_records_pending), nil); eq(#w.reads, 0)
  end)
end)

test("pre_skipped_counts_this_run_only", function()
  local K = S.K
  local prev = K.track_record_build(K.pre_tally_new(), { ["{a}"] = true }, nil)
  prev.skipped = 2
  pre_world({ prev = prev }, function()
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    eq(K.track_records_pending["tr"].skipped, 0, "take b heard cleanly: nothing skipped this run")
  end)
end)

-- Vocal Range "Auto" (Task 4) --------------------------------------------------------------------

local function vocal_range(name, list)
  for i, r in ipairs(list or S.VOCAL_RANGES) do
    if r.name == name then return r, i end
  end
  error("no vocal range named " .. name, 2)
end

test("auto_is_factory_range", function()
  eq(S.DEFAULTS.auto_range, true)
  local auto, idx = vocal_range("Auto")
  eq(auto.auto, true); eq(auto.min, 65); eq(auto.max, 1000)
  eq(idx, S.DEFAULTS.preset_range_idx, "the default pick is Auto")
  eq(vocal_range("Generic Vocal").auto, nil, "Generic Vocal is a range of its own")
  local T = load_script({})
  reaper.GetExtState = function() return "" end   -- the harness's own stub again
  local d = T.K.analysis_defaults()
  eq(d.auto_range, true, "nothing stored: Auto")
  eq(d.min_freq, 65); eq(d.max_freq, 1000)
end)

test("auto_range_persists", function()
  local T = load_script({ pitch_auto_range = "0" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, false); eq(T.K.analysis_defaults().auto_range, false)
  T = load_script({ pitch_auto_range = "yes" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, true, "unknown text: the factory value")
  local entry
  for _, e in ipairs(T.K.PERSIST) do if e.ext == "pitch_auto_range" then entry = e end end
  eq(entry ~= nil, true, "persisted"); eq(entry.group, "engine")
  eq(entry.read(), "1")
  T.state.auto_range = false; eq(entry.read(), "0")
end)

test("range_name_variants", function()
  local K = S.K
  local v = { auto_range = true, min_freq = 65, max_freq = 1000 }
  eq(K.range_name(v), "Auto")
  v.auto_lo_st, v.auto_hi_st = 40, 69
  eq(K.range_name(v), "Auto: E2\xE2\x80\x93A4")
  v.auto_lo_st, v.auto_hi_st, v.auto_none = nil, nil, true
  eq(K.range_name(v), "Auto: Generic Vocal (nothing found)")
  eq(K.range_name({ auto_range = false, min_freq = 65, max_freq = 1000 }), "Generic Vocal", "65 / 1000 Hz by hand")
  eq(K.range_name({ min_freq = 65, max_freq = 1000 }), "Generic Vocal", "no flag: not Auto")
  eq(K.range_name({ auto_range = false, min_freq = 66, max_freq = 1000 }), K.CUSTOM_PRESET)
  eq(K.range_name({ auto_range = true, min_freq = 82, max_freq = 440, auto_lo_st = 40, auto_hi_st = 69 }),
    "Auto: E2\xE2\x80\x93A4", "an Auto analysis keeps its name whatever Hz it ran with")
  eq((K.form_part_names({ auto_range = true, min_freq = 82, max_freq = 440, threshold = 0.08, block_size = 1024,
    hop_size = 512 })), "Auto")
end)

test("range_index_matches_flag_first", function()
  local K = S.K
  local _, auto_i = vocal_range("Auto")
  local _, generic_i = vocal_range("Generic Vocal")
  eq(K.range_index({ auto_range = true, min_freq = 250, max_freq = 1200 }), auto_i, "Auto whatever the Hz")
  eq(K.range_index({ auto_range = false, min_freq = 65, max_freq = 1000 }), generic_i, "by Hz: never Auto")
  eq(K.range_index({ min_freq = 65, max_freq = 1000 }), generic_i)
  eq(K.range_index({ auto_range = false, min_freq = 66, max_freq = 1000 }), 0)
end)

test("analysis_values_keeps_auto", function()
  local K = S.K
  local function with(extra)
    local t = { min_freq = 65, max_freq = 1000, threshold = 0.08, block_size = 1024, hop_size = 512 }
    for k, v in pairs(extra) do t[k] = v end
    return K.analysis_values(t)
  end
  eq(with({ auto_range = true }).auto_range, true)
  eq(with({ auto_range = "yes" }).auto_range, false, "not a boolean: false")
  eq(with({}).auto_range, false, "absent: false")
  local v = with({ auto_range = true, auto_lo_st = 40, auto_hi_st = 69 })
  eq(v.auto_lo_st, 40); eq(v.auto_hi_st, 69)
  v = with({ auto_range = true, auto_lo_st = 69, auto_hi_st = 40 })
  eq(v.auto_lo_st, nil, "lo above hi: dropped"); eq(v.auto_hi_st, nil)
  v = with({ auto_range = true, auto_lo_st = 40.5, auto_hi_st = 69 })
  eq(v.auto_lo_st, nil, "not a whole note: dropped"); eq(v.auto_hi_st, nil)
  v = with({ auto_range = true, auto_lo_st = 40, auto_hi_st = 40 })
  eq(v.auto_lo_st, 40, "one note: kept"); eq(v.auto_hi_st, 40)
  eq(with({ auto_range = true, auto_none = true }).auto_none, true)
  eq(with({ auto_range = true, auto_none = 1 }).auto_none, false, "not a boolean: false")
end)

test("form_pick_range_clears_auto", function()
  local K = S.K
  local f = K.form_new("{auto}", nil)
  eq(f.values.auto_range, true, "a new form starts at Auto")
  K.form_set(f, "range", vocal_range("Tenor"))
  eq(f.values.auto_range, false); eq(f.values.min_freq, 130); eq(f.values.max_freq, 500)
  eq(f.edited.auto_range, true, "picking a range is an edit of Auto too")
  K.form_set(f, "range", vocal_range("Auto"))
  eq(f.values.auto_range, true); eq(f.values.min_freq, 65); eq(f.values.max_freq, 1000)
  K.form_set(f, "range", vocal_range("Bass"))
  K.form_reset_row(f, "range")
  eq(f.values.auto_range, S.state.auto_range, "Reset: back to the default, Auto included")
  eq(f.edited.auto_range, nil)
  K.form_set(f, "range", vocal_range("Tenor"))
  K.form_set(f, "min_freq", 80)
  eq(f.values.auto_range, false, "a Min Freq edit never changes auto_range")
  eq(f.values.min_freq, 80)
  K.form_reset_row(f, "min_freq")
  eq(f.values.min_freq, S.state.min_freq); eq(f.values.auto_range, false, "one Hz back alone: still not Auto")
  K.form_reset_row(f, "max_freq")
  eq(f.values.max_freq, S.state.max_freq)
  eq(f.values.auto_range, S.state.auto_range, "both Hz back at the defaults: the default range whole")
  eq(f.edited.auto_range, nil)
end)

test("existing_presets_shift", function()
  local K = S.K
  eq(K.range_name({ auto_range = false, min_freq = 250, max_freq = 1200 }), "Soprano")
  eq((K.form_part_names(SOPRANO_ANALYSIS)), "Soprano", "a record from before Auto")
  eq(K.ROW_TIPS.range:find("\n\nAuto: Listens through the whole track first to find the singer's lowest and "
    .. "highest notes. Done once per track.", 1, true) ~= nil, true, "the Auto paragraph in the row's tooltip")
end)

test("range_row_default_compares_auto", function()
  local K = S.K
  local row = K.SETTINGS_SECTIONS[2].rows[1]
  eq(row.id, "range")
  local base = K.analysis_defaults()
  local v = K.analysis_defaults()
  eq(row.is_default({ v = v, base = base }), true, "Auto from the factory: already the default")
  v.auto_range = false   -- Generic Vocal: the same Hz, not Auto
  eq(row.is_default({ v = v, base = base }), false)
  eq(K.form_changed_rows(v), 1, "Generic Vocal differs from Auto")
end)

test("range_tip_names_found_hz", function()
  local K = S.K
  eq(K.range_tip({ auto_range = true, auto_lo_st = 40, auto_hi_st = 69 }),
    "Auto: E2\xE2\x80\x93A4\n\n82\xE2\x80\x93440 Hz, with a little room either side")
  eq(K.range_tip({ auto_range = true }), K.ROW_TIPS.range, "nothing found yet: the row's own tooltip")
  eq(K.range_tip({ auto_range = false, auto_lo_st = 40, auto_hi_st = 69 }), K.ROW_TIPS.range)
end)

test("dsp_section_reset_ends_at_auto", function()
  local K, st = S.K, S.state
  local saved = { st.auto_range, st.min_freq, st.max_freq, st.confirm, K.save_settings, reaper.time_precise,
    st.status.text, st.status.until_time, st.target_take_guid }
  local ok, err = pcall(function()
    K.save_settings = function() end
    reaper.time_precise = function() return 0 end
    st.target_take_guid = nil
    K.settings_binding().set("range", vocal_range("Tenor"))
    eq(st.auto_range, false)
    local dsp
    for _, section in ipairs(K.SETTINGS_SECTIONS) do if section.id == "dsp" then dsp = section end end
    K.request_settings_reset(dsp)
    eq(st.auto_range, false, "the confirm alone changes nothing")
    st.confirm.on_confirm()
    local d = K.analysis_defaults()
    eq(d.auto_range, true); eq(d.min_freq, S.DEFAULTS.min_freq); eq(d.max_freq, S.DEFAULTS.max_freq)
    eq(K.range_name(d), "Auto")
  end)
  st.auto_range, st.min_freq, st.max_freq, st.confirm, K.save_settings, reaper.time_precise = table.unpack(saved, 1, 6)
  st.status.text, st.status.until_time, st.target_take_guid = saved[7], saved[8], saved[9]
  if not ok then error(err, 0) end
end)

test("hz_rows_at_default_while_auto", function()
  local K = S.K
  local dsp
  for _, section in ipairs(K.SETTINGS_SECTIONS) do if section.id == "dsp" then dsp = section end end
  local rows = {}
  for _, row in ipairs(dsp.rows) do rows[row.id] = row end
  local f = K.form_new("{hz}", { notes = { {} }, analysis = { auto_range = true, min_freq = 82, max_freq = 440,
    threshold = 0.08, block_size = 1024, hop_size = 512 } })
  local b = K.form_binding(f)
  for _, id in ipairs({ "min_freq", "max_freq" }) do
    eq(rows[id].is_default(b), true, id .. ": not the user's to set while Auto")
    eq(rows[id].reason(b.v), "Found from the track", id .. ": Reset disabled with the reason")
  end
  -- Reset is disabled; were it called anyway, it would not switch Auto off
  K.form_reset_row(f, "min_freq")
  eq(f.values.auto_range, true, "auto_range untouched")
  eq(f.values.max_freq, 440, "the other Hz untouched")
  f.values.auto_range = false
  eq(rows.max_freq.is_default(b), false, "not Auto: the Hz count again")
  eq(rows.max_freq.reason(b.v), nil)
end)

test("form_changed_rows_auto_nil_is_false", function()
  local K, st = S.K, S.state
  local saved = st.auto_range
  st.auto_range = false
  local v = K.analysis_defaults(); v.auto_range = nil
  local n = K.form_changed_rows(v)
  st.auto_range = saved
  eq(n, 0, "nil and false are the same")
end)

test("range_row_auto_found_from_track_is_default", function()
  local K, st = S.K, S.state
  local row
  for _, section in ipairs(K.SETTINGS_SECTIONS) do
    for _, r in ipairs(section.rows) do if r.id == "range" then row = r end end
  end
  local auto_base = { auto_range = true, min_freq = 65, max_freq = 1000 }
  local fixed_base = { auto_range = false, min_freq = 130, max_freq = 500 }
  local function is_def(v, base) return row.is_default({ v = v, base = base }) end
  eq(is_def({ auto_range = true, min_freq = 104, max_freq = 554 }, auto_base), true, "Auto found from the track is the default")
  eq(is_def({ auto_range = true, min_freq = 104, max_freq = 554 }, fixed_base), false, "Auto against a fixed default")
  eq(is_def({ auto_range = false, min_freq = 130, max_freq = 500 }, auto_base), false, "fixed against Auto")
  eq(is_def({ auto_range = false, min_freq = 65, max_freq = 1000 }, auto_base), false, "Generic Vocal is not Auto")
  eq(is_def({ auto_range = false, min_freq = 130, max_freq = 500 }, fixed_base), true, "fixed equal to fixed")
  local saved = { st.auto_range, st.min_freq, st.max_freq }
  local ok, err = pcall(function()
    local function changed(v, d)
      st.auto_range, st.min_freq, st.max_freq = d.auto_range, d.min_freq, d.max_freq
      local x = K.analysis_defaults()
      v.threshold, v.block_size, v.hop_size = x.threshold, x.block_size, x.hop_size
      return K.form_changed_rows(v)
    end
    eq(changed({ auto_range = true, min_freq = 104, max_freq = 554 }, auto_base), 0, "Auto found from the track: no changed row")
    eq(changed({ auto_range = true, min_freq = 104, max_freq = 554 }, fixed_base), 1)
    eq(changed({ auto_range = false, min_freq = 130, max_freq = 500 }, auto_base), 1)
    eq(changed({ auto_range = false, min_freq = 65, max_freq = 1000 }, auto_base), 1)
    eq(changed({ auto_range = false, min_freq = 130, max_freq = 500 }, fixed_base), 0)
  end)
  st.auto_range, st.min_freq, st.max_freq = table.unpack(saved, 1, 3)
  if not ok then error(err, 0) end
end)

test("auto_hz_rows_disabled_with_reason", function()
  local K = S.K
  eq(K.auto_hz_reason({ auto_range = true }), "Found from the track")
  eq(K.auto_hz_reason({ auto_range = false }), nil)
  eq(K.auto_hz_reason({}), nil)
end)

test("settings_binding_auto_range", function()
  local K, st = S.K, S.state
  local saved = { st.auto_range, st.min_freq, st.max_freq }
  local ok, err = pcall(function()
    local b = K.settings_binding()
    b.set("range", vocal_range("Tenor"))
    eq(st.auto_range, false); eq(st.min_freq, 130)
    b.reset("range")
    eq(st.auto_range, S.DEFAULTS.auto_range); eq(st.min_freq, S.DEFAULTS.min_freq)
    b.reset("min_freq")
    eq(st.auto_range, S.DEFAULTS.auto_range, "a Min Freq reset never switches Auto off")
    b.set("range", vocal_range("Tenor")); b.set("min_freq", 80)
    eq(st.auto_range, false, "a Min Freq edit never switches Auto on or off")
    b.reset("min_freq")
    eq(st.auto_range, false, "Max Freq still Tenor's: not the factory range")
    b.reset("max_freq")
    eq(st.auto_range, S.DEFAULTS.auto_range, "both Hz at the factory ones: the factory range, Auto included")
  end)
  st.auto_range, st.min_freq, st.max_freq = saved[1], saved[2], saved[3]
  if not ok then error(err, 0) end
end)

test("save_as_default_carries_auto", function()
  local K, st = S.K, S.state
  local saved = { K.save_settings, st.min_freq, st.max_freq, st.auto_range, reaper.time_precise, st.status.text,
    st.status.until_time }
  local ok, err = pcall(function()
    K.save_settings = function() end
    reaper.time_precise = function() return 0 end
    local f = K.form_new("{sad}", nil)
    K.form_set(f, "range", vocal_range("Tenor"))
    local req = K.form_defaults_request(f.values)
    eq(req.body_lines[1], "New analyses will start with: Tenor (was Auto).")
    req.on_confirm()
    eq(st.auto_range, false); eq(st.min_freq, 130)
    -- An item analysed with Auto: its form holds the Hz it ran with; the default saved is Auto itself
    local seeded = K.analysis_values({ auto_range = true, min_freq = 82, max_freq = 440, threshold = st.threshold,
      block_size = st.block_size, hop_size = st.hop_size, auto_lo_st = 40, auto_hi_st = 69 })
    req = K.form_defaults_request(seeded)
    req.on_confirm()
    eq(st.auto_range, true); eq(st.min_freq, 65); eq(st.max_freq, 1000)
  end)
  K.save_settings, st.min_freq, st.max_freq, st.auto_range, reaper.time_precise = saved[1], saved[2], saved[3],
    saved[4], saved[5]
  st.status.text, st.status.until_time = saved[6], saved[7]
  if not ok then error(err, 0) end
end)

test("form_reseeded_from_auto_analysis", function()
  local K = S.K
  local stored = { auto_range = true, min_freq = 82, max_freq = 440, threshold = 0.08, block_size = 1024,
    hop_size = 512, auto_lo_st = 40, auto_hi_st = 69 }
  local f = K.form_new("{seed}", { notes = { {} }, analysis = stored })
  eq(f.source, "item")
  eq(f.values.auto_range, true); eq(f.values.min_freq, 82)
  eq(K.range_name(f.values), "Auto: E2\xE2\x80\x93A4")
  eq(K.range_index(f.values), select(2, vocal_range("Auto")), "the row shows Auto selected")
end)

test("analysis_begin_freezes_auto_range", function()
  local K, st = S.K, S.state
  local saved_params = st.analysis_params
  local stubs = {
    GetMediaItemTake_Source = function() return "src" end, GetMediaSourceSampleRate = function() return 44100 end,
    GetMediaItemInfo_Value = function() return 1 end, new_array = function() return {} end,
  }
  local saved_open, saved_state, saved_reanalyze = K.open_accessor, {}, K.reanalyze_status_guid
  for _, key in ipairs({ "is_analyzing", "results", "target_take_guid", "target_take_name", "accessor", "buffer",
      "sample_rate", "item_len", "end_time", "current_time", "start_time", "progress", "separation",
      "analysis_empty", "nudge_burst" }) do
    saved_state[key] = st[key]
  end
  for k, f in pairs(stubs) do reaper[k] = f end
  local ok, err = pcall(function()
    K.open_accessor = function() return "acc" end
    local v = K.analysis_defaults(); v.auto_range = true
    eq(K.analysis_begin("take", "item", { values = v, defer_envelope = true }), true)
    eq(st.analysis_params.auto_range, true, "frozen with the run")
    eq(K.analysis_values(st.analysis_params).auto_range, true, "what it stores keeps it")
    v.auto_range = false
    eq(K.analysis_begin("take", "item", { values = v, defer_envelope = true }), true)
    eq(st.analysis_params.auto_range, false)
  end)
  for k in pairs(stubs) do reaper[k] = nil end
  K.open_accessor, K.reanalyze_status_guid = saved_open, saved_reanalyze
  for _, key in ipairs({ "is_analyzing", "results", "target_take_guid", "target_take_name", "accessor", "buffer",
      "sample_rate", "item_len", "end_time", "current_time", "start_time", "progress", "separation",
      "analysis_empty", "nudge_burst" }) do
    st[key] = saved_state[key]   -- nil values too (pairs skips them)
  end
  st.is_analyzing = saved_state.is_analyzing
  st.analysis_params = saved_params
  if not ok then error(err, 0) end
end)

-- A key not set (0) and the key last chosen by hand ----------------------------------------------------------------
-- Runs fn with K.take_track / K.track_record stubbed: every guid is on track "TR", whose record is `rec` (nil = none)
local function with_track_record(rec, fn)
  local K = S.K
  local old_track, old_record = K.take_track, K.track_record
  K.take_track = function(guid) if guid then return "TR" end return nil end
  K.track_record = function(track) if track == "TR" then return rec end return nil end
  local ok, err = pcall(fn)
  K.take_track, K.track_record = old_track, old_record
  if not ok then error(err, 0) end
end

test("key_unset_is_fresh_default", function()
  local T = load_script({})
  reaper.GetExtState = function() return "" end   -- the harness's own stub again
  local NK = T.K.new_key
  eq(NK.hand_key_idx, 1, "the hand key: C"); eq(NK.hand_scale_idx, 1, "the hand scale: Major")
  eq(T.state.key_idx, 0, "no key set before anything is open"); eq(T.state.scale_idx, 1)
  local T2 = load_script({ pitch_key_idx = "5", pitch_key_hand_idx = "7", pitch_scale_hand_idx = "2" })
  reaper.GetExtState = function() return "" end
  eq(T2.state.key_idx, 0, "a stored Key for new items is not used")
  eq(T2.K.new_key.hand_key_idx, 7); eq(T2.K.new_key.hand_scale_idx, 2)
  local T3 = load_script({ pitch_key_hand_idx = "0", pitch_scale_hand_idx = "99" })
  reaper.GetExtState = function() return "" end
  eq(T3.K.new_key.hand_key_idx, 1, "the hand key is never 0")
  eq(T3.K.new_key.hand_scale_idx, #T3.SCALE_DEFINITIONS, "clamped to the last scale")
end)

test("key_resolve_from_track", function() with_track_record({ st = {}, takes = {}, key_idx = 5, scale_idx = 1 },
  function()
    local k, sc, from = S.K.key_resolve(0, 2, "{r}")
    eq(k, 5); eq(sc, 1); eq(from, true)
    k, sc, from = S.K.key_resolve(9, 3, "{r}")
    eq(k, 9, "a real key passes through"); eq(sc, 3); eq(from, false)
  end) end)

test("key_resolve_falls_to_hand", function() with_track_record(nil, function()
  local NK = S.K.new_key
  local saved = { NK.hand_key_idx, NK.hand_scale_idx }
  NK.hand_key_idx, NK.hand_scale_idx = 3, 2
  local k, sc, from, k2, sc2, from2
  local ok, err = pcall(function()
    k, sc, from = S.K.key_resolve(0, 1, "{r}")
    k2, sc2, from2 = S.K.key_resolve(0, 1, nil)   -- no item at all
  end)
  NK.hand_key_idx, NK.hand_scale_idx = saved[1], saved[2]
  if not ok then error(err, 0) end
  eq(k, 3); eq(sc, 2); eq(from, false)
  eq(k2, 3); eq(sc2, 2); eq(from2, false)
end) end)

test("item_seed_never_stores_unset", function()
  local K, NK = S.K, S.K.new_key
  local saved = { NK.hand_key_idx, NK.hand_scale_idx }
  local ok, err = pcall(function()
    NK.hand_key_idx, NK.hand_scale_idx = 3, 2
    with_track_record({ st = {}, takes = {}, key_idx = 5, scale_idx = 1 }, function()
      local data = { guid = "{s}" }
      K.item_seed(data)
      eq(data.key_idx, 5, "the track's key"); eq(data.scale_idx, 1); eq(data.key_from_track, true)
      -- a model holding no key set (0) and a scale
      data = { guid = "{s}", key_idx = 0, scale_idx = 4 }
      eq(K.item_seed(data), true, "0 resolved counts as filled")
      eq(data.key_idx, 5); eq(data.scale_idx, 1, "the found scale, not the hidden one"); eq(data.key_from_track, true)
    end)
    with_track_record(nil, function()
      local data = { guid = "{s}", key_idx = 0, scale_idx = 4 }
      K.item_seed(data)
      eq(data.key_idx, 3, "no record: the hand key"); eq(data.scale_idx, 2); eq(data.key_from_track, nil)
      -- a real key on the item is its own
      data = { guid = "{s}", key_idx = 8, scale_idx = 3 }
      K.item_seed(data)
      eq(data.key_idx, 8); eq(data.scale_idx, 3); eq(data.key_from_track, nil)
    end)
  end)
  NK.hand_key_idx, NK.hand_scale_idx = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("scale_classes_with_no_key", function()
  local st = S.state
  local saved = { st.separation, st.key_idx, st.scale_idx, st.target_take_guid }
  local ok, err = pcall(function()
    st.target_take_guid = nil
    S.K.adopt_new_item_values()   -- the bar shows no key and the scale classes follow
    eq(st.key_idx, 0)
    for pc = 0, 11 do eq(st.scale_pc_set[pc], true, "pitch class " .. pc) end
    local pcs = S.K.scale_pcs(0, 1)
    for pc = 0, 11 do eq(pcs[pc], true, "scale_pcs " .. pc) end
  end)
  st.separation, st.key_idx, st.scale_idx, st.target_take_guid = table.unpack(saved, 1, 4)
  S.K.adopt_new_item_values()
  if not ok then error(err, 0) end
end)

test("hand_key_tracks_bar_choice", function()
  local st, K, NK = S.state, S.K, S.K.new_key
  local writes = {}
  local set_ext, count_items = reaper.SetExtState, rawget(reaper, "CountMediaItems")
  reaper.SetExtState = function(_, key, value) writes[key] = value end
  rawset(reaper, "CountMediaItems", function() return 0 end)   -- the take is not found: nothing is saved on it
  local saved = { st.target_take_guid, st.key_idx, st.scale_idx, NK.hand_key_idx, NK.hand_scale_idx,
    st.session_takes["{H}"], st.stored.pitch_key_hand_idx, st.stored.pitch_scale_hand_idx }
  local ok, err = pcall(function()
    st.stored.pitch_key_hand_idx, st.stored.pitch_scale_hand_idx = nil, nil
    st.target_take_guid = nil   -- nothing open
    st.key_idx, st.scale_idx = 7, 2
    K.scale_changed("key")
    eq(NK.hand_key_idx, 7, "a real key: the hand key follows"); eq(NK.hand_scale_idx, 1, "a first pick: Major")
    eq(writes.pitch_key_hand_idx, "7"); eq(writes.pitch_scale_hand_idx, "1")
    -- not set (0) is no choice: nothing changes
    st.key_idx = 0
    K.scale_changed("key")
    eq(NK.hand_key_idx, 7, "0 leaves the hand key"); eq(NK.hand_scale_idx, 1)
    -- an analysed item: an ordinary key change, and the hand key follows
    st.session_takes["{H}"] = { guid = "{H}", notes = {}, results = {}, key_idx = 4, scale_idx = 1 }
    st.target_take_guid, st.key_idx, st.scale_idx = "{H}", 9, 2
    K.scale_changed("key")
    eq(NK.hand_key_idx, 9); eq(NK.hand_scale_idx, 2); eq(writes.pitch_key_hand_idx, "9")
    eq(writes.pitch_key_idx, nil, "the Key for new items is not written"); eq(writes.pitch_scale_idx, nil)
  end)
  reaper.SetExtState = set_ext
  rawset(reaper, "CountMediaItems", count_items)
  K.drop_project_cache()
  st.target_take_guid, st.key_idx, st.scale_idx, NK.hand_key_idx, NK.hand_scale_idx,
    st.session_takes["{H}"], st.stored.pitch_key_hand_idx, st.stored.pitch_scale_hand_idx = table.unpack(saved, 1, 8)
  K.save_settings("key")   -- the stored mirror follows the put-back values
  if not ok then error(err, 0) end
end)

test("apply_source_never_gives_unset", function() with_track_record(nil, function()
  local st, NK = S.state, S.K.new_key
  local saved = { st.target_take_guid, st.key_idx, st.scale_idx, NK.hand_key_idx, NK.hand_scale_idx }
  st.target_take_guid, st.key_idx, st.scale_idx = "{none}", 0, 1   -- not analysed, no key set
  NK.hand_key_idx, NK.hand_scale_idx = 6, 2
  local ok, src = pcall(S.K.apply_source, { "key_idx", "scale_idx" })
  st.target_take_guid, st.key_idx, st.scale_idx, NK.hand_key_idx, NK.hand_scale_idx = table.unpack(saved, 1, 5)
  if not ok then error(src, 0) end
  eq(src.key_idx, 6, "the key not set stands for"); eq(src.scale_idx, 2)
end) end)

test("key_tooltip_names_the_track_and_runner_up", function()
  local K = S.K
  local get_name = reaper.GetTrackName
  reaper.GetTrackName = function() return true, "V _ Main" end
  local ok, err = pcall(function()
    with_track_record({ st = {}, takes = {}, key_idx = 5, scale_idx = 1, alt_key_idx = 2, alt_scale_idx = 2 },
      function()
        eq(K.key_found_text({ guid = "{f}", key_idx = 5, scale_idx = 1, key_from_track = true }),
          "Found from V _ Main. C# Minor also fits.")
        eq(K.key_found_text({ guid = "{f}", key_idx = 5, scale_idx = 1 }), nil, "a key chosen by hand")
        eq(K.key_found_text({ guid = "{f}", key_idx = 7, scale_idx = 1, key_from_track = true }), nil,
          "the track's key is another now")
      end)
    with_track_record({ st = {}, takes = {}, key_idx = 5, scale_idx = 1 }, function()
      eq(K.key_found_text({ guid = "{f}", key_idx = 5, scale_idx = 1, key_from_track = true }), "Found from V _ Main.")
    end)
  end)
  reaper.GetTrackName = get_name
  if not ok then error(err, 0) end
end)

-- Analyze runs the pre-analysis first (auto range and key, Task 6) --------------------------------------------------

-- A small project: opts.tracks = { [track] = { items = { "it_x", ... }, freq = Hz, name = "V _ Main" } }; item "it_x"
-- holds take "tk_x" (GUID "{x}"), opts.len seconds of a sine at its track's freq, read at opts.rate (8000) by the
-- analysis and at K.PRE.RATE by the pre-analysis. opts.step: seconds reaper.time_precise advances per call (0).
-- opts.offline: { [take] = true } has no sample rate; opts.ext: { [track] = text } what the track's record holds.
-- opts.real_open: the script's own K.open_accessor runs (REAPER's accessor stubbed), on a Pitch envelope with points
-- (it bypasses and restores the envelope, then counts that as the script's own write).
-- w.log records, in order, "begin", "end:<label>", "track:<track>" (a track write) and "take:<guid>" (a take
-- write); w.reads every accessor read { acc, rate }. Every stub, state value and K value it changes is put back.
local function auto_world(opts, fn)
  local K, st = S.K, S.state
  local w = { log = {}, reads = {}, destroyed = 0, now = 0, count = 1, dead = {}, ext = {} }
  local rate, len = opts.rate or 8000, opts.len or 6
  local take_of, item_of, track_of, freq_of, guid_of, by_guid = {}, {}, {}, {}, {}, {}
  for track, t in pairs(opts.tracks) do
    w.ext[track] = { [K.TRACK_SCAN_KEY] = opts.ext and opts.ext[track] or "" }
    for _, item in ipairs(t.items) do
      local id = item:sub(4)
      local take = "tk_" .. id
      take_of[item], item_of[take], track_of[take], track_of[item] = take, item, track, track
      freq_of["acc_" .. take], guid_of[take], by_guid["{" .. id .. "}"] = t.freq, "{" .. id .. "}", take
    end
  end
  local function log(s) w.log[#w.log + 1] = s end
  local stubs = {
    ValidatePtr2 = function(_, ptr) return ptr ~= nil and not w.dead[ptr] end,
    CountTrackMediaItems = function(track) return opts.tracks[track] and #opts.tracks[track].items or 0 end,
    GetTrackMediaItem = function(track, i) return opts.tracks[track] and opts.tracks[track].items[i + 1] end,
    GetActiveTake = function(item) return take_of[item] end,
    TakeIsMIDI = function() return false end,
    GetMediaItemInfo_Value = function(_, key) if key == "D_LENGTH" then return len end return 0 end,
    GetSetMediaItemTakeInfo_String = function(take, key, _, set)
      if key == "GUID" then return guid_of[take] ~= nil, guid_of[take] or "" end
      if set then log("take:" .. tostring(guid_of[take])) end
      return true, ""
    end,
    GetSetMediaTrackInfo_String = function(track, key, value, set)
      w.ext[track] = w.ext[track] or {}
      if set then
        w.ext[track][key] = value
        log("track:" .. tostring(track))
        return true, value
      end
      return true, w.ext[track][key] or ""
    end,
    GetMediaItemTakeByGUID = function(_, guid) local t = by_guid[guid]; if t and not w.dead[t] then return t end end,
    GetMediaItemTake_Item = function(take) return item_of[take] end,
    GetMediaItemTake_Track = function(take) return track_of[take] end,
    GetMediaItemTrack = function(item) return track_of[item] end,
    GetMediaItemTake_Source = function(take) return "src_" .. take end,
    GetMediaSourceSampleRate = function(src)
      if opts.offline and opts.offline[src:sub(5)] then return 0 end
      return rate
    end,
    GetTakeName = function(take) return take end,
    GetTrackName = function(track) return true, opts.tracks[track] and opts.tracks[track].name or "V _ Main" end,
    GetTrackGUID = function(track) return "{track:" .. tostring(track) .. "}" end,
    GetTakeEnvelopeByName = function(take) return "env_" .. take end,
    GetEnvelopeStateChunk = function()
      if opts.real_open then return true, "<PITCHENV\nACT 1 -1\nVIS 1 1 1\nPT 0 0 0\n>" end
      return true, "<PITCHENV\nACT 1 -1\nVIS 1 1 1\n>"
    end,
    SetEnvelopeStateChunk = function() return true end,
    CreateTakeAudioAccessor = function(take) return "acc_" .. take end,
    Undo_BeginBlock = function() log("begin") end,
    Undo_EndBlock = function(label) log("end:" .. tostring(label)) end,
    new_array = function() return {} end,
    GetAudioAccessorSamples = function(acc, r, _, t, n, buf)
      w.reads[#w.reads + 1] = { acc = acc, rate = r }
      local f = freq_of[acc] or 220
      for i = 1, n do buf[i] = 0.5 * math.sin(2 * math.pi * f * (t + (i - 1) / r)) end
      return 1
    end,
    DestroyAudioAccessor = function() w.destroyed = w.destroyed + 1 end,
    time_precise = function() w.now = w.now + (opts.step or 0); return w.now end,
    GetProjectStateChangeCount = function() return w.count end,
    CountSelectedMediaItems = function() return 0 end,
    NamedCommandLookup = function() return 0 end,
  }
  local old = {}
  for name, f in pairs(stubs) do old[name] = rawget(reaper, name); rawset(reaper, name, f) end
  local old_k = { open_accessor = K.open_accessor, write_take_envelope = K.write_take_envelope,
    take_correction = K.take_correction, pre_begin = K.pre_begin, batch_write = K.batch_write }
  local saved_last_progress = K.pre_last_progress
  if not opts.real_open then
    K.open_accessor = function(take)
      if opts.unreadable and opts.unreadable[take] then return nil end
      return "acc_" .. take
    end
  end
  K.write_take_envelope = function(guid) log("take:" .. tostring(guid)); return true end
  K.take_correction = function() return {} end
  w.pre_calls = 0
  K.pre_begin = function(...) w.pre_calls = w.pre_calls + 1; return old_k.pre_begin(...) end
  local keys = { "target_take_guid", "target_take_name", "key_idx", "scale_idx", "separation", "results", "notes",
    "split_points", "analysis_empty", "progress", "is_analyzing", "accessor", "buffer", "analysis_params",
    "sample_rate", "item_len", "start_time", "end_time", "current_time", "analysis_form", "last_change_count",
    "last_seen_sel_guid", "scale_pc_set", "pre" }
  local saved = {}
  for _, k in ipairs(keys) do saved[k] = st[k] end
  local saved_status = { st.status.text, st.status.until_time, st.status.hold }
  local NK = K.new_key
  local saved_nk = { NK.hand_key_idx, NK.hand_scale_idx }
  local saved_pending = K.pending_key
  K.pending_key = {}
  local saved_order = #st.session_order
  local saved_reanalyze = K.reanalyze_status_guid
  st.is_analyzing, st.accessor, st.pre, st.analysis_params = false, nil, nil, nil
  st.status.text, st.status.until_time, st.status.hold = "", 0, nil
  K.track_records_pending = {}
  K.drop_project_cache()
  local ok, err = pcall(fn, w)
  pcall(K.pre_cancel)
  for name in pairs(stubs) do rawset(reaper, name, old[name]) end
  for name, f in pairs(old_k) do K[name] = f end
  K.pre_last_progress = saved_last_progress
  for _, k in ipairs(keys) do st[k] = saved[k] end
  st.status.text, st.status.until_time, st.status.hold = table.unpack(saved_status, 1, 3)
  NK.hand_key_idx, NK.hand_scale_idx = saved_nk[1], saved_nk[2]
  K.pending_key = saved_pending
  for g in pairs(by_guid) do
    st.session_takes[g], st.raw_cache[g], st.stale_takes[g], st.missing_takes[g] = nil, nil, nil, nil
    st.undone_takes[g], st.stale_env[g], st.unreadable_takes[g] = nil, nil, nil
  end
  while #st.session_order > saved_order do table.remove(st.session_order) end
  K.batch, K.auto_run, K.reanalyze_status_guid, K.card = nil, nil, saved_reanalyze, nil
  K.track_records_pending = {}
  K.drop_project_cache()
  if not ok then error(err, 0) end
end

-- Ticks the window's analysis until nothing runs (bounded)
local function auto_run_out()
  for _ = 1, 100000 do
    if not S.state.is_analyzing and not S.state.pre and not S.K.batch then return end
    S.K.analysis_tick()
  end
  error("the analysis never ended")
end

local function auto_values(auto)
  local v = S.K.analysis_defaults()
  v.auto_range = auto
  if not auto then v.min_freq, v.max_freq = 130, 500 end
  return v
end

local function index_of(list, value)
  for i, v in ipairs(list) do if v == value then return i end end
  return nil
end

local ONE_TRACK = { tr = { items = { "it_a", "it_b" }, freq = 220 } }

test("auto_needed_cases", function()
  local K, st = S.K, S.state
  local saved = { st.session_takes["{an}"], K.pending_key }
  local ok, err = pcall(function()
    K.pending_key = {}
    with_track_record(nil, function()
      eq(K.auto_needed(auto_values(true), "{new}"), true, "Vocal Range Auto")
      eq(K.auto_needed(auto_values(false), "{new}"), true, "fixed range, not analysed, no key")
      K.pending_key["{new}"] = { key_idx = 5, scale_idx = 1 }
      eq(K.auto_needed(auto_values(false), "{new}"), false, "fixed range, key 5 picked")
      eq(K.auto_needed(auto_values(true), "{new}"), true, "Auto range, key picked")
      st.session_takes["{an}"] = { guid = "{an}", notes = {}, results = {}, key_idx = 4, scale_idx = 1 }
      eq(K.auto_needed(auto_values(false), "{an}"), false, "fixed range, analysed item")
      eq(K.auto_needed(auto_values(true), "{an}"), true, "Auto range, analysed item")
    end)
    with_track_record({ st = {}, takes = {}, key_idx = 2, scale_idx = 1 }, function()
      eq(K.auto_needed(auto_values(false), "{other}"), false, "fixed range, the track has a key")
    end)
  end)
  st.session_takes["{an}"], K.pending_key = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("auto_values_from_record", function()
  local K = S.K
  local v, none = K.auto_values(auto_values(true), { st = {}, takes = {}, lo_st = 40, hi_st = 69 })
  local lo, hi = K.pre_range_hz(40, 69)
  eq(v.min_freq, lo); eq(v.max_freq, hi); eq(v.auto_lo_st, 40); eq(v.auto_hi_st, 69); eq(v.auto_range, true)
  eq(none, false); eq(v.auto_none == true, false)
  v, none = K.auto_values(auto_values(true), { st = {}, takes = {} })
  eq(v.min_freq, 65); eq(v.max_freq, 1000); eq(v.auto_none, true); eq(none, true); eq(v.auto_lo_st, nil)
  v, none = K.auto_values(auto_values(true), nil)
  eq(v.min_freq, 65); eq(v.auto_none, true, "no record: like a record without a range"); eq(none, true)
  local fixed = auto_values(false)
  v = K.auto_values(fixed, { st = {}, takes = {}, lo_st = 40, hi_st = 69 })
  eq(v.min_freq, 130, "a fixed range is left as it is"); eq(v.max_freq, 500); eq(v.auto_lo_st, nil)
  eq(K.analysis_values(K.auto_values(auto_values(true), { st = {}, takes = {}, lo_st = 40, hi_st = 69 })).auto_lo_st,
    40, "the found notes are kept by what is stored")
end)

test("track_record_sees_pending", function()
  local K = S.K
  local reads = 0
  local old = rawget(reaper, "GetSetMediaTrackInfo_String")
  rawset(reaper, "GetSetMediaTrackInfo_String", function() reads = reads + 1; return true, "" end)
  local ok, err = pcall(function()
    K.drop_project_cache()
    eq(K.track_record("trP"), nil, "nothing stored")
    local rec = K.track_record_build(K.pre_tally_new(), { ["{p}"] = true }, nil)
    K.track_records_pending["trP"] = rec
    eq(K.track_record("trP"), rec, "a record found but not written yet is the track's record")
    K.track_records_pending = {}
    eq(K.track_record("trP"), nil, "dropped: the stored one (none) again")
  end)
  rawset(reaper, "GetSetMediaTrackInfo_String", old)
  K.track_records_pending = {}
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

test("analyze_auto_then_stores", function()
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0   -- not analysed, no key set
    S.start_analysis(auto_values(true))
    eq(st.pre ~= nil, true, "stage 1 runs first")
    eq(st.is_analyzing, true)
    eq(K.card.phase, "listen", "the Analysis card shows stage 1")
    eq(K.analysis_progress(), 0)
    auto_run_out()
    local data = st.session_takes["{a}"]
    eq(type(data), "table", "analysed")
    local rec = K.track_record_valid(JSON.decode(w.ext.tr[K.TRACK_SCAN_KEY]))
    eq(type(rec), "table", "the track holds its record")
    eq(rec.lo_st, 57); eq(rec.hi_st, 57); eq(rec.takes["{a}"], true); eq(rec.takes["{b}"], true)
    local lo, hi = K.pre_range_hz(57, 57)
    eq(data.analysis.auto_range, true); eq(data.analysis.min_freq, lo); eq(data.analysis.max_freq, hi)
    eq(data.analysis.auto_lo_st, 57); eq(data.analysis.auto_hi_st, 57)
    eq(K.range_name(K.analysis_values(data.analysis)), "Auto: " .. K.pre_range_text(57, 57))
    -- written once, inside the analysis's own undo block
    local writes = 0
    for _, s in ipairs(w.log) do if s == "track:tr" then writes = writes + 1 end end
    eq(writes, 1, "one track write")
    local at, b, e = index_of(w.log, "track:tr"), index_of(w.log, "begin"), index_of(w.log, "end:Analyze Pitch")
    eq(b ~= nil and e ~= nil, true, "the analysis's undo block")
    eq(at > b and at < e, true, "between its Undo_BeginBlock and Undo_EndBlock")
    eq(#w.log, 4, "begin, the take, the track, end: " .. table.concat(w.log, ","))
    eq(next(K.track_records_pending), nil)
    -- the key came from the track, the bar shows it, the Analysis card says what was found
    eq(type(rec.key_idx), "number", "a key was found")
    eq(data.key_idx, rec.key_idx); eq(data.scale_idx, rec.scale_idx); eq(data.key_from_track, true)
    eq(st.key_idx, rec.key_idx, "the bar shows the found key")
    eq(K.card.rows[1].value, "A3 \xE2\x80\x93 A3"); eq(K.card.rows[2].value, K.key_text(rec.key_idx, rec.scale_idx))
    eq(st.status.text, "", "nothing in the status line")
    eq(st.is_analyzing, false); eq(st.pre, nil); eq(K.auto_run, nil)
  end)
end)

test("undo_drops_record_cache", function()
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 3
    S.start_analysis(auto_values(true))
    auto_run_out()
    K.refresh_project_cache()
    eq(K.track_record("tr") ~= nil, true, "the stored record")
    w.ext.tr[K.TRACK_SCAN_KEY] = ""   -- Cmd+Z took the record away
    w.count = w.count + 1
    K.refresh_project_cache()
    eq(K.track_record("tr"), nil, "read again after the undo")
  end)
end)

test("analyze_auto_reuses_record", function()
  local K = S.K
  local tally = K.pre_tally_new()
  for _ = 1, 300 do K.pre_tally_add(tally, 329.63) end   -- E4
  for _ = 1, 300 do K.pre_tally_add(tally, 164.81) end   -- E3
  for _ = 1, 200 do K.pre_tally_add(tally, 246.94) end   -- B3
  for _ = 1, 100 do K.pre_tally_add(tally, 207.65) end   -- G#3
  local rec = K.track_record_build(tally, { ["{a}"] = true, ["{b}"] = true }, nil)
  rec.alt_key_idx, rec.alt_scale_idx = nil, nil
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(rec) } }, function(w)
    local st = S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    eq(st.pre, nil, "no stage 1: the record covers every take")
    eq(K.analysis_progress(), 0, "plain analysis progress")
    auto_run_out()
    for _, r in ipairs(w.reads) do eq(r.rate ~= K.PRE.RATE, true, "nothing read at the pre-analysis rate") end
    eq(index_of(w.log, "track:tr"), nil, "no track write")
    local data = st.session_takes["{a}"]
    local lo, hi = K.pre_range_hz(rec.lo_st, rec.hi_st)
    eq(data.analysis.min_freq, lo); eq(data.analysis.max_freq, hi)
    eq(data.key_idx, rec.key_idx); eq(data.key_source, "track"); eq(data.key_from_track, true)
    -- the range and the key were the track's already: the Analysis card says where they came from
    eq(K.card.rows[1].value, K.card_range_text(rec.lo_st, rec.hi_st) .. " (from track \"V _ Main\")")
    eq(st.status.text, "")
  end)
end)

test("analyze_fixed_range_fixed_key_no_pre", function()
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx, st.scale_idx = "{a}", 5, 1
    K.pending_key["{a}"] = { key_idx = 5, scale_idx = 1 }   -- picked before analysing
    local seen_pre = false
    S.start_analysis(auto_values(false))
    for _ = 1, 100000 do
      if st.pre then seen_pre = true end
      if not st.is_analyzing then break end
      K.analysis_tick()
    end
    eq(seen_pre, false, "state.pre never set"); eq(w.pre_calls, 0)
    eq(st.session_takes["{a}"].analysis.min_freq, 130); eq(st.session_takes["{a}"].analysis.auto_range, false)
    eq(index_of(w.log, "track:tr"), nil)
    eq(st.status.text, "", "no Auto message")
  end)
end)

test("cancel_in_stage_one_writes_nothing", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    K.analysis_tick(); K.analysis_tick()
    eq(st.pre ~= nil, true, "still in stage 1")
    local p = K.analysis_progress()
    eq(p > 0 and p <= K.PRE.SHARE, true, "stage 1 is the first share of the whole, got " .. p)
    K.card_update()
    near(K.card.progress, p, 1e-12, "the Analysis card shows it")
    eq(K.cancel_analysis(), true)
    eq(index_of(w.log, "begin"), nil, "no undo block"); eq(#w.log, 0, "no take or track write")
    eq(st.is_analyzing, false); eq(st.pre, nil); eq(next(K.track_records_pending), nil)
    eq(st.status.text, K.CANCELLED_TEXT)
    eq(st.session_takes["{a}"], nil)
  end)
end)

test("auto_progress_spans_both_stages", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    while st.pre do K.analysis_tick() end
    eq(st.is_analyzing, true, "stage 2 started by itself")
    eq(select(2, K.canvas_form(true, false)), K.LOCKED_REASON, "stage 2: the usual locked line")
    st.progress = 0.5
    near(K.analysis_progress(), K.PRE.SHARE + (1 - K.PRE.SHARE) * 0.5, 1e-12)
    K.card_update()
    near(K.card.progress, K.analysis_progress(), 1e-12, "the Analysis card's one number")
    eq(K.status_line(false), "", "not in the status line")
  end)
end)

test("auto_stage_two_cancel_drops_pending", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    while st.pre do K.analysis_tick() end
    eq(K.track_records_pending.tr ~= nil, true, "the found record waits for the analysis's block")
    K.analysis_tick()
    eq(st.is_analyzing, true, "the analysis is part way")
    -- the window's error handling and Cancel both end here
    eq(K.cancel_analysis(), true)
    eq(next(K.track_records_pending), nil, "the record is dropped with the analysis")
    eq(K.auto_run, nil)
    eq(#w.log, 0, "nothing written")
    eq(st.is_analyzing, false)
    -- a later, unrelated undo block writes no stale record
    K.track_records_flush()
    eq(index_of(w.log, "track:tr"), nil)
  end)
end)

test("auto_begin_failure_drops_pending", function()
  auto_world({ tracks = ONE_TRACK, offline = { tk_a = true } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    eq(st.pre ~= nil, true, "stage 1 runs: the pre-analysis needs no sample rate")
    auto_run_out()
    eq(#w.reads > 0 and w.reads[1].rate == K.PRE.RATE, true, "the track was heard")
    eq(st.status.text, "Couldn't read this item's audio. Check that its media is online, then try again.")
    eq(next(K.track_records_pending), nil, "the record of the stage 1 run is dropped")
    eq(K.auto_run, nil)
    eq(#w.log, 0, "nothing written"); eq(st.is_analyzing, false); eq(st.pre, nil)
  end)
end)

test("auto_release_during_stage_one_ends_cleanly", function()
  -- reset_analysis_model (the open item removed, the session wiped) releases the analysis: on_done never comes
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    K.analysis_tick()
    K.release_analysis()
    eq(st.pre, nil); eq(st.is_analyzing, false); eq(next(K.track_records_pending), nil); eq(K.auto_run, nil)
    for _ = 1, 5 do K.analysis_tick() end
    eq(st.is_analyzing, false, "nothing waits on it"); eq(#w.log, 0)
    -- and Analyze works again
    S.start_analysis(auto_values(true))
    eq(st.pre ~= nil, true, "a new run starts")
  end)
end)

test("auto_never_starts_twice", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    local pre = st.pre
    S.start_analysis(auto_values(true))
    eq(w.pre_calls, 1, "refused while stage 1 runs"); eq(st.pre, pre)
    K.batch_start({ { guid = "{b}", take = "tk_b", item = "it_b", name = "B", len = 6, sample_rate = 8000 } },
      auto_values(true))
    eq(K.batch, nil, "no batch while it runs"); eq(w.pre_calls, 1)
  end)
end)

local TWO_TRACKS = { tr1 = { items = { "it_a" }, freq = 110, name = "Low" },
  tr2 = { items = { "it_b" }, freq = 440, name = "High" } }
local function two_entries()
  return { { guid = "{a}", take = "tk_a", item = "it_a", name = "A", len = 6, sample_rate = 8000, has_notes = false },
    { guid = "{b}", take = "tk_b", item = "it_b", name = "B", len = 6, sample_rate = 8000, has_notes = false } }
end

test("batch_two_tracks_each_own_range", function()
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    -- a key picked for each item: only the range is found, and each track takes its item's key
    for _, g in ipairs({ "{a}", "{b}", "{c}" }) do K.pending_key[g] = { key_idx = 3, scale_idx = 1 } end
    K.batch_start(two_entries(), auto_values(true))
    eq(st.pre ~= nil, true, "stage 1 before the first item"); eq(#st.pre.queue, 2)
    K.analysis_tick()
    K.card_update()
    eq(K.card.step, "Listening to track \"Low\"\xE2\x80\xA6", "two tracks: the one being heard is named")
    eq(K.status_line(false), "")
    eq(K.analysis_progress() <= K.PRE.SHARE, true)
    auto_run_out()
    local recs = {}
    for _, tr in ipairs({ "tr1", "tr2" }) do
      recs[tr] = K.track_record_valid(JSON.decode(w.ext[tr][K.TRACK_SCAN_KEY]))
      eq(type(recs[tr]), "table", tr .. " holds its record")
    end
    eq(recs.tr1.lo_st, 45); eq(recs.tr2.lo_st, 69)
    local a, b = st.session_takes["{a}"], st.session_takes["{b}"]
    eq(a.analysis.min_freq, (K.pre_range_hz(recs.tr1.lo_st, recs.tr1.hi_st)), "a: its own track's range")
    eq(b.analysis.min_freq, (K.pre_range_hz(recs.tr2.lo_st, recs.tr2.hi_st)), "b: its own track's range")
    eq(a.analysis.min_freq ~= b.analysis.min_freq, true)
    eq(a.key_idx, 3, "the picked key"); eq(a.key_source, "picked"); eq(a.key_from_track, true, "a leads tr1")
    eq(recs.tr1.key_idx, 3, "tr1 takes a's key"); eq(recs.tr2.key_idx, 3, "tr2 takes b's key")
    eq(recs.tr1.alt_key_idx, nil); eq(recs.tr2.alt_key_idx, nil)
    local begins, starts, ends, at1, at2 = 0, nil, nil, index_of(w.log, "track:tr1"), index_of(w.log, "track:tr2")
    for i, s in ipairs(w.log) do
      if s == "begin" then begins = begins + 1; starts = i end
      if s:find("^end:") then ends = i end
    end
    eq(begins, 1, "one undo block: " .. table.concat(w.log, ","))
    eq(w.log[ends], "end:Analyze Pitch (2 items)")
    eq(at1 ~= nil and at1 > starts and at1 < ends, true, "tr1 written inside it")
    eq(at2 ~= nil and at2 > starts and at2 < ends, true, "tr2 too")
    eq(K.card.lines[1], "Analyzed 2 items. " .. MOD .. "+Z to undo.", "the batch's own summary, nothing added")
    eq(#K.card.lines, 1); eq(st.status.text, "")
    eq(next(K.track_records_pending), nil)
  end)
end)

test("batch_cancel_after_stage_one_writes_no_record", function()
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    for _, g in ipairs({ "{a}", "{b}", "{c}" }) do K.pending_key[g] = { key_idx = 3, scale_idx = 1 } end
    K.batch_start(two_entries(), auto_values(true))
    while st.pre do K.analysis_tick() end
    eq(K.track_records_pending.tr1 ~= nil, true, "found, waiting for the batch's block")
    eq(K.batch.pre_ran, true)
    near(K.analysis_progress(), K.PRE.SHARE + (1 - K.PRE.SHARE) * K.batch_progress(K.batch, st.progress), 1e-12)
    K.cancel_analysis()
    eq(K.batch, nil); eq(st.is_analyzing, false)
    eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(next(K.track_records_pending), nil, "the batch wrote nothing: its records are dropped")
    eq(st.status.text, "Batch cancelled. Nothing was changed.")
  end)
end)

test("batch_cancel_in_stage_one", function()
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    K.batch_start(two_entries(), auto_values(true))
    K.analysis_tick()
    K.cancel_analysis()
    eq(K.batch, nil); eq(st.pre, nil); eq(st.is_analyzing, false); eq(#w.log, 0)
    eq(next(K.track_records_pending), nil)
    eq(st.status.text, "Batch cancelled. Nothing was changed.")
  end)
end)

test("batch_stage_one_released_ends_the_batch", function()
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    K.batch_start(two_entries(), auto_values(true))
    K.analysis_tick()
    K.release_analysis()   -- reset_analysis_model while stage 1 runs: on_done never comes
    eq(st.pre, nil); eq(st.is_analyzing, false); eq(next(K.track_records_pending), nil)
    K.analysis_tick()
    eq(K.batch, nil, "the batch does not wait forever"); eq(st.is_analyzing, false); eq(#w.log, 0)
    eq(st.status.text, "Batch cancelled. Nothing was changed.")
  end)
end)

-- Fix round 1: after any failed or cancelled analysis or batch, nothing is pending and K.auto_run is nil
local THREE = { tr = { items = { "it_a", "it_b" }, freq = 220 }, tr2 = { items = { "it_c" }, freq = 440, name = "Other" } }
local function entry_c()
  return { guid = "{c}", take = "tk_c", item = "it_c", name = "C", len = 6, sample_rate = 8000, has_notes = false }
end

-- What the window's error handler does after a failed frame (loop): close an open block, then cancel
local function after_frame_error()
  local st = S.state
  if st.undo_open then st.undo_open = false; reaper.Undo_EndBlock("Apply Pitch Correction (interrupted)", -1) end
  S.K.drop_project_cache()
  pcall(S.K.cancel_analysis)
  if st.undo_open then st.undo_open = false; reaper.Undo_EndBlock("Analyze Pitch (interrupted)", -1) end
end

local function tick_until_error()
  for _ = 1, 100000 do
    local ok, err = pcall(S.K.analysis_tick)
    if not ok then return err end
    if not S.state.is_analyzing and not S.state.pre and not S.K.batch then return nil end
  end
  error("never ended")
end

test("frame_error_in_finishing_frame_drops_pending", function()
  auto_world({ tracks = THREE }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 3
    local write = K.write_take_envelope
    K.write_take_envelope = function() error("write failed") end
    S.start_analysis(auto_values(true))
    local err = tick_until_error()
    eq(tostring(err):find("write failed", 1, true) ~= nil, true, "the finishing frame failed")
    after_frame_error()
    eq(next(K.track_records_pending), nil, "nothing pending after the error"); eq(K.auto_run, nil)
    K.write_take_envelope = write
    -- a later batch on another track never writes the first track's record
    K.batch_start({ entry_c() }, auto_values(true))
    auto_run_out()
    eq(index_of(w.log, "track:tr"), nil, "no write for the first track: " .. table.concat(w.log, ","))
    eq(index_of(w.log, "track:tr2") ~= nil, true, "the batch's own track is written")
  end)
end)

test("failed_batch_write_drops_pending", function()
  auto_world({ tracks = THREE }, function(w)
    local K, st = S.K, S.state
    for _, g in ipairs({ "{a}", "{b}", "{c}" }) do K.pending_key[g] = { key_idx = 3, scale_idx = 1 } end
    local real_write = K.batch_write
    K.batch_write = function() error("disk full") end
    K.batch_start({ entry_c() }, auto_values(true))
    local err = tick_until_error()
    eq(tostring(err):find("disk full", 1, true) ~= nil, true, "the batch's write failed")
    after_frame_error()
    eq(next(K.track_records_pending), nil, "nothing pending after the error"); eq(K.auto_run, nil)
    K.batch_write = real_write
    st.target_take_guid, st.key_idx = "{a}", 3
    S.start_analysis(auto_values(true))
    auto_run_out()
    eq(index_of(w.log, "track:tr2"), nil, "the failed batch's record is never written: " .. table.concat(w.log, ","))
  end)
end)

test("error_recovery_drops_pending", function()
  local K = S.K
  K.track_records_pending["trE"], K.auto_run = { st = {}, takes = {} }, { guid = "{e}" }
  local ok, err = pcall(K.recover_after_error)
  local left_pending, left_run = next(K.track_records_pending), K.auto_run
  K.track_records_pending, K.auto_run = {}, nil
  if not ok then error(err, 0) end
  eq(left_pending, nil); eq(left_run, nil)
end)

test("batch_start_drops_stale_pending", function()
  auto_world({ tracks = THREE }, function(w)
    local K = S.K
    for _, g in ipairs({ "{a}", "{b}", "{c}" }) do K.pending_key[g] = { key_idx = 3, scale_idx = 1 } end
    K.track_records_pending["tr"] = K.track_record_build(K.pre_tally_new(), {}, nil)   -- left by something else
    K.batch_start({ entry_c() }, auto_values(true))
    auto_run_out()
    eq(index_of(w.log, "track:tr"), nil, "a record the batch did not find is not written")
  end)
end)

test("batch_writes_only_records_of_written_tracks", function()
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    for _, g in ipairs({ "{a}", "{b}", "{c}" }) do K.pending_key[g] = { key_idx = 3, scale_idx = 1 } end
    K.batch_start(two_entries(), auto_values(true))
    for _ = 1, 100000 do
      if K.batch and K.batch.index == 2 and st.is_analyzing then break end
      K.analysis_tick()
    end
    eq(#K.batch.done, 1, "the first item is finished"); eq(K.batch.index, 2, "the second is part way")
    K.cancel_analysis()
    local n = 0
    for _, s in ipairs(w.log) do if s:find("^track:") then n = n + 1 end end
    eq(n, 1, "one track write: " .. table.concat(w.log, ","))
    eq(index_of(w.log, "track:tr1") ~= nil, true, "the first track's record, with its item")
    eq(index_of(w.log, "track:tr2"), nil, "no item of the second track was written: neither is its record")
    eq(next(K.track_records_pending), nil, "and it is not left pending")
  end)
end)

test("item_gone_in_stage_one_says_so", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.key_idx = "{a}", 0
    S.start_analysis(auto_values(true))
    K.analysis_tick()
    w.dead["tk_a"], w.dead["it_a"] = true, true   -- the user deleted the item while its track was heard
    auto_run_out()
    eq(st.status.text, "This item is no longer in the project")
    eq(#w.log, 0); eq(next(K.track_records_pending), nil); eq(st.is_analyzing, false)
  end)
end)

-- A corrected key follows the track; Find Range and Key Again --------------------------------------------------------

-- A stored record of track "tr" (ONE_TRACK) that covers both its takes: A3 heard, key `key_idx` / `scale_idx` (nil:
-- no key), with a runner-up when alt is given
local function t7_record(key_idx, scale_idx, alt)
  local r = { st = { ["57"] = 500 }, takes = { ["{a}"] = true, ["{b}"] = true }, lo_st = 57, hi_st = 57, skipped = 0,
    key_idx = key_idx, scale_idx = scale_idx }
  if alt then r.alt_key_idx, r.alt_scale_idx = alt[1], alt[2] end
  return r
end

-- The analysed item "{a}" as the open item: its model (key, scale, key_from_track), no notes in a mode
local function t7_open(key_idx, scale_idx, from_track)
  local st = S.state
  local data = { guid = "{a}", name = "Lead Vox", notes = {}, results = {}, key_idx = key_idx, scale_idx = scale_idx,
    key_from_track = from_track or nil }
  st.session_takes["{a}"] = data
  st.target_take_guid, st.target_take_name, st.notes = "{a}", "Lead Vox", {}
  st.key_idx, st.scale_idx = key_idx, scale_idx
  return data
end

-- Runs fn(ext_writes, sync) with reaper.SetExtState recorded ({ [key] = value }); sync() brings the stored mirror to
-- K.new_key as the test set it and forgets that write. Puts SetExtState back, and the stored mirror, after
local function t7_ext(fn)
  local writes = {}
  local set_ext = rawget(reaper, "SetExtState")
  rawset(reaper, "SetExtState", function(_, key, value) writes[key] = value end)
  -- the stored mirror follows K.new_key as the test sets it: only the test's own writes are recorded
  local function sync()
    S.K.save_settings("key")
    for k in pairs(writes) do writes[k] = nil end
  end
  local ok, err = pcall(fn, writes, sync)
  rawset(reaper, "SetExtState", set_ext)
  S.K.save_settings("key")
  if not ok then error(err, 0) end
end

local function t7_stored(w)
  local raw = w.ext.tr[S.K.TRACK_SCAN_KEY]
  return raw ~= "" and S.K.track_record_valid(JSON.decode(raw)) or nil
end

test("key_fix_follows_track", function() t7_ext(function(ext, ext_sync)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st, NK = S.K, S.state, S.K.new_key
    NK.hand_key_idx, NK.hand_scale_idx = 9, 1
    ext_sync()
    local data = t7_open(5, 1, true)
    st.key_idx = 3   -- D, chosen in the bar
    K.scale_changed("key")
    eq(table.concat(w.log, ","), "begin,take:{a},track:tr,end:Set Key", "the item and the track in one block")
    local rec = t7_stored(w)
    eq(rec.key_idx, 3); eq(rec.scale_idx, 1); eq(rec.alt_key_idx, nil); eq(rec.alt_scale_idx, nil)
    eq(rec.lo_st, 57, "the rest of the record is kept"); eq(rec.takes["{a}"], true)
    eq(data.key_idx, 3); eq(data.key_from_track, true, "the item still follows its track")
    eq(NK.hand_key_idx, 3, "the hand key follows")
    eq(NK.hand_scale_idx, 1)
    eq(next(ext), nil, "no ExtState written")
    eq(next(K.track_records_pending), nil)
    eq(st.status.text, "Key for V _ Main is now D Major. New items on this track follow.")
  end)
end) end)

test("key_fix_follows_track_envelope_path", function() t7_ext(function(ext, ext_sync)
  local mode_count = S.K.mode_note_count
  S.K.mode_note_count = function() return 2 end   -- the item has Classic / Hard notes: the envelope is rewritten
  local ok, err = pcall(auto_world, { tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st, NK = S.K, S.state, S.K.new_key
    ext_sync()
    local data = t7_open(5, 1, true)
    st.scale_idx = 2
    K.scale_changed("scale")
    eq(table.concat(w.log, ","), "begin,take:{a},track:tr,end:Set Scale")
    local rec = t7_stored(w)
    eq(rec.key_idx, 5); eq(rec.scale_idx, 2)
    eq(data.scale_idx, 2); eq(data.key_from_track, true); eq(NK.hand_scale_idx, 2)
    eq(next(ext), nil); eq(next(K.track_records_pending), nil)
    eq(st.status.text, "Key for V _ Main is now E Minor. New items on this track follow.",
      "this message replaces the Key changed one")
  end)
  S.K.mode_note_count = mode_count
  if not ok then error(err, 0) end
end) end)

test("key_fix_follows_track_failed_write_leaves_nothing_pending", function() t7_ext(function()
  local mode_count, count_items = S.K.mode_note_count, rawget(reaper, "CountMediaItems")
  S.K.mode_note_count = function() return 2 end
  local ok, err = pcall(auto_world, { tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st = S.K, S.state
    -- the envelope cannot be written: the block closes with the model and the record, nothing stays pending
    K.write_take_envelope = function() return false end
    t7_open(5, 1, true)
    st.key_idx = 8
    K.scale_changed("key")
    local b, t, e = index_of(w.log, "begin"), index_of(w.log, "track:tr"), index_of(w.log, "end:Apply Pitch Correction")
    eq(b ~= nil and t ~= nil and e ~= nil and b < t and t < e, true, "inside the block: " .. table.concat(w.log, ","))
    eq(next(K.track_records_pending), nil)
    -- the item is gone: no block is opened, nothing written, nothing pending
    w.log = {}
    K.write_take_envelope = function() return true end
    rawset(reaper, "CountMediaItems", function() return 0 end)
    w.dead["tk_a"] = true
    K.drop_project_cache()
    st.key_idx = 10
    K.scale_changed("key")
    eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(next(K.track_records_pending), nil)
  end)
  rawset(reaper, "CountMediaItems", count_items)
  S.K.mode_note_count = mode_count
  if not ok then error(err, 0) end
end) end)

test("key_fix_follows_track_plain_save_no_take", function() t7_ext(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st = S.K, S.state
    t7_open(5, 1, true)
    K.take_track("{a}")   -- the track is known; then the take goes
    local count_items = rawget(reaper, "CountMediaItems")
    rawset(reaper, "CountMediaItems", function() return 0 end)
    w.dead["tk_a"] = true
    st.cache.takes = {}
    st.key_idx = 10
    local ok, err = pcall(K.scale_changed, "key")
    rawset(reaper, "CountMediaItems", count_items)
    if not ok then error(err, 0) end
    eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(next(K.track_records_pending), nil, "nothing pending")
  end)
end) end)

test("key_fix_other_item_as_before", function() t7_ext(function(ext, ext_sync)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st, NK = S.K, S.state, S.K.new_key
    NK.hand_key_idx = 9
    ext_sync()
    local data = t7_open(5, 1, false)   -- the key was chosen by hand
    st.key_idx = 3
    K.scale_changed("key")
    eq(table.concat(w.log, ","), "begin,take:{a},end:Set Key", "no track write")
    eq(t7_stored(w).key_idx, 5, "the track keeps its key")
    eq(data.key_idx, 3); eq(data.key_from_track, nil)
    eq(NK.hand_key_idx, 3, "the hand key follows"); eq(ext.pitch_key_hand_idx, "3")
    eq(ext.pitch_key_idx, nil, "no Key for new items")
  end)
  -- from its track, but the track has no record (undone): as today too
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st, NK = S.K, S.state, S.K.new_key
    t7_open(5, 1, true)
    st.key_idx = 4
    K.scale_changed("key")
    eq(table.concat(w.log, ","), "begin,take:{a},end:Set Key")
    eq(NK.hand_key_idx, 4); eq(next(K.track_records_pending), nil)
  end)
end) end)

test("find_again_replaces_record", function() t7_ext(function(ext)
  local old = t7_record(7, 1)
  old.takes = { ["{old}"] = true }
  old.st = { ["40"] = 900 }
  old.lo_st, old.hi_st = 40, 40
  auto_world({ tracks = ONE_TRACK, step = 0.003, ext = { tr = JSON.encode(old) } }, function(w)
    local K, st = S.K, S.state
    local data = t7_open(7, 1, true)
    eq(K.find_again_reason(true), nil, "enabled with a target")
    K.find_again_request()
    eq(st.pre ~= nil, true, "the track is heard"); eq(st.is_analyzing, true)
    eq(K.find_again_reason(true), K.REASON_ANALYZING, "disabled while it runs")
    K.analysis_tick(); K.analysis_tick()
    local p = K.analysis_progress()
    eq(p > 0 and p < 1, true, "progress: " .. p)
    auto_run_out()
    eq(table.concat(w.log, ","), "begin,track:tr,end:Find Range and Key: V _ Main", "only the record, one block")
    local rec = t7_stored(w)
    eq(rec.takes["{a}"], true); eq(rec.takes["{b}"], true); eq(rec.takes["{old}"], nil, "heard afresh")
    eq(rec.st["40"], nil, "the old tally is gone"); eq(rec.lo_st, 57); eq(rec.hi_st, 57)
    eq(data.key_idx, 7, "the item keeps its key"); eq(data.key_from_track, true); eq(st.key_idx, 7)
    eq(K.card.rows[1].value, "A3 \xE2\x80\x93 A3"); eq(K.card.rows[2].value, K.key_text(rec.key_idx, rec.scale_idx))
    eq(K.card.lines[1], "Items already analyzed keep theirs."); eq(st.status.text, "")
    eq(next(K.track_records_pending), nil); eq(K.auto_run, nil); eq(st.is_analyzing, false)
    eq(next(ext), nil, "no ExtState")
  end)
end) end)

test("find_again_disabled_reasons", function()
  local K, st = S.K, S.state
  local saved = { st.is_analyzing, K.batch }
  local ok, err = pcall(function()
    st.is_analyzing, K.batch = false, nil
    eq(K.find_again_reason(false), "Select an audio item")
    eq(K.find_again_reason(true), nil)
    st.is_analyzing = true
    eq(K.find_again_reason(true), K.REASON_ANALYZING)
    st.is_analyzing, K.batch = false, {}
    eq(K.find_again_reason(true), K.REASON_ANALYZING)
  end)
  st.is_analyzing, K.batch = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("find_again_refused_while_analysing", function()
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    local was = st.is_analyzing
    st.is_analyzing = true
    local ok, err = pcall(function()
      K.find_again_request()
      eq(w.pre_calls, 0); eq(#w.log, 0)
    end)
    st.is_analyzing = was
    if not ok then error(err, 0) end
  end)
end)

-- A track whose items are heard but hold no singing (silence)
local SILENT_TRACK = { tr = { items = { "it_a", "it_b" }, freq = 0 } }

test("find_again_nothing_found_keeps_the_record", function()
  local old = JSON.encode(t7_record(7, 1))
  auto_world({ tracks = SILENT_TRACK, ext = { tr = old } }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    auto_run_out()
    eq(#w.log, 0, "no undo point: " .. table.concat(w.log, ","))
    eq(w.ext.tr[K.TRACK_SCAN_KEY], old, "the record is kept untouched")
    eq(next(K.track_records_pending), nil)
    eq(st.status.text, "Not enough singing to tell the key: kept F# Major.", "the track's kept key, not the bar's")
  end)
end)

test("find_again_nothing_found_without_a_key_names_the_bar_key", function()
  auto_world({ tracks = SILENT_TRACK }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    auto_run_out()
    eq(#w.log, 0); eq(w.ext.tr[K.TRACK_SCAN_KEY], ""); eq(next(K.track_records_pending), nil)
    eq(st.status.text, "Not enough singing to tell the key: kept D Major.", "no key kept on the track: the bar's")
  end)
end)

test("find_again_all_media_unreadable_says_so", function()
  local old = JSON.encode(t7_record(7, 1))
  auto_world({ tracks = ONE_TRACK, unreadable = { tk_a = true, tk_b = true }, ext = { tr = old } }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    auto_run_out()
    eq(#w.log, 0); eq(w.ext.tr[K.TRACK_SCAN_KEY], old); eq(next(K.track_records_pending), nil)
    eq(st.status.text, K.AUTO_UNREADABLE_TEXT)
  end)
end)

test("find_again_track_deleted_mid_run_says_so", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    K.analysis_tick()
    w.dead["tr"], w.dead["tk_a"], w.dead["it_a"] = true, true, true   -- the user deleted the track (and its items)
    K.drop_project_cache()
    auto_run_out()
    eq(#w.log, 0); eq(next(K.track_records_pending), nil); eq(st.is_analyzing, false)
    eq(st.status.text, "This item is no longer in the project")
  end)
end)

test("key_fix_leaves_a_running_analysis_alone", function() t7_ext(function(_, ext_sync)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st, NK = S.K, S.state, S.K.new_key
    ext_sync()
    t7_open(5, 1, true)
    -- an Auto analysis (or a batch) runs and its record waits for its own undo block
    local pending = t7_record(5, 1, { 2, 2 })
    K.track_records_pending.tr = pending
    local was = st.is_analyzing
    st.is_analyzing = true
    local ok, err = pcall(function()
      st.key_idx = 3
      K.scale_changed("key")
      eq(table.concat(w.log, ","), "begin,take:{a},end:Set Key", "no track write in the Set Key block")
      eq(rawequal(K.track_records_pending.tr, pending), true, "the run's record is still pending, the same object")
      eq(pending.key_idx, 5); eq(pending.alt_key_idx, 2, "and unchanged")
      eq(NK.hand_key_idx, 3, "an ordinary key change meanwhile")
    end)
    st.is_analyzing = was
    K.track_records_pending = {}
    if not ok then error(err, 0) end
  end)
end) end)

test("find_again_range_only_keeps_the_key", function()
  local min_frames = S.K.PRE.KEY_MIN_FRAMES
  S.K.PRE.KEY_MIN_FRAMES = math.huge   -- a range is heard, too little for a key
  local ok, err = pcall(auto_world, { tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(7, 2, { 10, 1 })) } },
    function(w)
      local K, st = S.K, S.state
      t7_open(3, 1, false)
      K.find_again_request()
      auto_run_out()
      eq(table.concat(w.log, ","), "begin,track:tr,end:Find Range and Key: V _ Main")
      local rec = t7_stored(w)
      eq(rec.lo_st, 57); eq(rec.key_idx, 7, "the previous key is carried"); eq(rec.scale_idx, 2)
      eq(rec.alt_key_idx, 10); eq(rec.alt_scale_idx, 1)
      eq(K.card.rows[1].value, "A3 \xE2\x80\x93 A3")
      eq(K.card.rows[2].value, "Not enough singing to tell: kept F# Minor", "the previous key, carried")
      eq(st.status.text, "")
    end)
  S.K.PRE.KEY_MIN_FRAMES = min_frames
  if not ok then error(err, 0) end
end)

test("find_again_unreadable_media_says_so", function()
  auto_world({ tracks = ONE_TRACK, unreadable = { tk_b = true } }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    auto_run_out()
    eq(table.concat(w.log, ","), "begin,track:tr,end:Find Range and Key: V _ Main")
    eq(t7_stored(w).skipped, 1)
    eq(K.card.lines[1], "Couldn't read 1 of 2 items on \"V _ Main\" (media offline). Used the rest.")
    eq(K.card.lines[2], "Items already analyzed keep theirs."); eq(st.status.text, "")
  end)
end)

test("find_again_cancel_writes_nothing", function()
  local old = JSON.encode(t7_record(7, 1))
  auto_world({ tracks = ONE_TRACK, step = 0.003, ext = { tr = old } }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    K.analysis_tick()
    eq(st.pre ~= nil, true)
    eq(K.cancel_analysis(), true)
    auto_run_out()
    eq(#w.log, 0, "no undo point"); eq(w.ext.tr[K.TRACK_SCAN_KEY], old)
    eq(next(K.track_records_pending), nil); eq(K.auto_run, nil); eq(st.is_analyzing, false)
    eq(st.status.text, K.CANCELLED_TEXT)
  end)
end)

test("track_record_holds_a_corrected_scale", function()
  local K = S.K
  local r = t7_record(5, 3)   -- E Dorian, chosen by hand on an item that follows its track
  eq(type(K.track_record_valid(r)), "table", "any scale of the bar")
  eq(K.track_record_valid(t7_record(5, 7)), nil, "no scale 7")
  eq(K.track_record_valid(t7_record(5, 3, { 2, 3 })), nil, "a runner-up is only ever Major or Minor")
end)

test("info_explains_auto_and_find_again", function()
  local K = S.K
  -- prose beside the Terms line, not rows of the shortcut tables
  eq(#K.INFO_NOTES, 3, "three sentences")
  local text = {}
  for _, note in ipairs(K.INFO_NOTES) do text[#text + 1] = note[1] .. " " .. note[2] end
  eq(text[1]:find("Auto", 1, true) ~= nil and text[1]:find("whole track", 1, true) ~= nil, true, "Auto")
  eq(text[2]:find("Key", 1, true) ~= nil and text[2]:find("found from the whole track", 1, true) ~= nil, true, "Key")
  eq(text[3]:find("Find Range and Key Again", 1, true) ~= nil and text[3]:find("keep theirs", 1, true) ~= nil, true,
    "Find Range and Key Again")
  for _, section in ipairs(K.INFO_SECTIONS) do
    for _, row in ipairs(section.rows) do
      eq(row[1]:find("Auto", 1, true), nil, "no row for Auto: " .. row[1])
      if row[1]:find("Find Range and Key Again", 1, true) then error("a row for Find Range and Key Again") end
      if row[1] == "… (top right)" then
        eq(row[2], "More: Analyze, Analyze Selected Items, Find Range and Key Again, Reset, Layers, Note Tone, "
          .. "Settings, Help", "the menu in order")
      end
    end
  end
end)

-- Final review fixes (Auto Vocal Range and Key) -------------------------------------------------------------------

-- F1: a Vocal Range saved before Auto existed is kept (load rule, no migration)
test("auto_range_load_keeps_a_saved_range", function()
  local T = load_script({ pitch_min_freq = "130", pitch_max_freq = "500" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, false, "a saved Tenor, no Auto flag: kept")
  eq(T.state.min_freq, 130); eq(T.state.max_freq, 500)
  T = load_script({ pitch_max_freq = "500" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, false, "only a Max stored, not Auto's: kept")
  T = load_script({})
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, true, "fresh install: factory Auto")
  T = load_script({ pitch_min_freq = "65", pitch_max_freq = "1000" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, true, "stored Hz are Auto's own: Auto")
  T = load_script({ pitch_auto_range = "1", pitch_min_freq = "130", pitch_max_freq = "500" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, true, "an explicit flag wins")
  T = load_script({ pitch_auto_range = "0", pitch_min_freq = "65", pitch_max_freq = "1000" })
  reaper.GetExtState = function() return "" end
  eq(T.state.auto_range, false, "an explicit flag wins (off)")
end)

-- F2: an external change while stage 1 runs is not taken for the script's own write (the real K.open_accessor)
local REAL_OPEN = { tracks = ONE_TRACK, step = 0.003, real_open = true }

-- Ticks until stage 1 has opened take b (the second take), bounded
local function until_second_take()
  for _ = 1, 100000 do
    local pre = S.state.pre
    if not pre or (pre.ti == 2 and pre.accessor) then return end
    S.K.analysis_tick()
  end
  error("stage 1 never reached the second take")
end

test("pre_external_change_survives_the_analysis", function()
  for _, bump in ipairs({ true, false }) do
    auto_world(REAL_OPEN, function(w)
      local st = S.state
      st.target_take_guid, st.key_idx = "{a}", 0
      st.last_change_count = w.count
      S.start_analysis(auto_values(true))
      S.K.analysis_tick()
      eq(st.pre ~= nil and st.pre.ti == 1, true, "stage 1 is on the first take")
      if bump then w.count = w.count + 1 end   -- an undo made in REAPER while stage 1 runs
      until_second_take()
      auto_run_out()
      eq(type(st.session_takes["{a}"]), "table", "analysed")
      if bump then
        eq(st.last_change_count, nil, "the next frame reads the project again")
      else
        eq(st.last_change_count, w.count, "no external change: nothing to read again")
      end
    end)
  end
end)

test("pre_external_change_survives_find_again", function()
  for _, bump in ipairs({ true, false }) do
    auto_world(REAL_OPEN, function(w)
      local st = S.state
      t7_open(3, 1, false)
      st.last_change_count = w.count
      S.K.find_again_request()
      S.K.analysis_tick()
      if bump then w.count = w.count + 1 end
      until_second_take()
      auto_run_out()
      eq(table.concat(w.log, ","), "begin,track:tr,end:Find Range and Key: V _ Main")
      if bump then eq(st.last_change_count, nil) else eq(st.last_change_count, w.count) end
    end)
  end
end)

test("pre_external_change_survives_cancel", function()
  for _, bump in ipairs({ true, false }) do
    auto_world(REAL_OPEN, function(w)
      local K, st = S.K, S.state
      t7_open(3, 1, false)
      st.last_change_count = w.count
      K.find_again_request()
      K.analysis_tick()
      if bump then w.count = w.count + 1 end
      until_second_take()
      eq(st.pre ~= nil, true)
      eq(K.cancel_analysis(), true)
      auto_run_out()
      eq(#w.log, 0)
      if bump then eq(st.last_change_count, nil) else eq(st.last_change_count, w.count) end
    end)
  end
end)

-- F3: offline media and takes that give no audio are skipped, not heard
test("pre_trusts_the_accessor_not_the_source_rate", function()
  -- REAPER in the background: every source reports a sample rate of 0, the accessor still reads the audio
  pre_world({ stubs = {
    GetMediaItemTake_Source = function(take) return "src_" .. take end,
    GetMediaSourceSampleRate = function() return 0 end,
  } }, function()
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    local rec = K.track_records_pending["tr"]
    eq(rec.takes["{a}"], true); eq(rec.takes["{b}"], true, "every take heard")
    eq(rec.skipped, 0, "nothing called offline")
    eq(rec.lo_st, 57); eq(rec.hi_st, 57)
  end)
end)

test("pre_take_with_no_audio_is_skipped", function()
  pre_world({ silent = "tk_b" }, function(w)
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    local rec = K.track_records_pending["tr"]
    eq(rec.takes["{a}"], true); eq(rec.takes["{b}"], nil, "every read gave nothing: not heard")
    eq(rec.skipped, 1)
    eq(w.destroyed, 2, "its accessor is destroyed")
  end)
end)

test("pre_short_take_stays_heard", function()
  pre_world({ len = { it_b = 0.01 } }, function(w)
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    for _, r in ipairs(w.reads) do eq(r.acc, "acc_tk_a", "shorter than one block: nothing read") end
    local rec = K.track_records_pending["tr"]
    eq(rec.takes["{b}"], true, "no read attempted: heard as before"); eq(rec.skipped, 0)
  end)
end)

-- F4: malformed track records are no record
test("track_record_rejects_malformed", function()
  local K = S.K
  local function rec(t)
    local r = { st = { ["57"] = 500 }, takes = {} }
    for k, v in pairs(t) do r[k] = v end
    return r
  end
  for _, key in ipairs({ "-5", "128", "1e3", "5.5" }) do
    eq(K.track_record_valid(rec({ st = { [key] = 500 } })), nil, "st key " .. key)
  end
  local inf = JSON.decode('{"st":{"57":1e999},"takes":{}}')
  eq(inf.st["57"], math.huge, "the decoder gives inf")
  eq(K.track_record_valid(inf), nil, "st value inf")
  eq(K.track_record_valid(rec({ st = { ["57"] = -1 } })), nil, "st value negative")
  eq(K.track_record_valid(rec({ st = { ["57"] = 0 / 0 } })), nil, "st value NaN")
  eq(K.track_record_valid(rec({ skipped = 1.5 })), nil, "skipped fractional")
  eq(K.track_record_valid(rec({ skipped = math.huge })), nil, "skipped inf")
  eq(K.track_record_valid(rec({ lo_st = -1, hi_st = 60 })), nil, "lo_st -1")
  eq(K.track_record_valid(rec({ lo_st = 60, hi_st = 128 })), nil, "hi_st 128")
  eq(type(K.track_record_valid(rec({ st = { ["0"] = 1, ["127"] = 2.5 }, skipped = 3 }))), "table", "edges valid")
end)

test("track_record_round_trips_what_it_builds", function()
  local K = S.K
  local tally = K.pre_tally_new()
  for i = 1, 400 do K.pre_tally_add(tally, 110 * 2 ^ ((i % 24) / 12)) end
  local built = K.track_record_build(tally, { ["{a}"] = true }, nil)
  built.skipped = 2
  local back = K.track_record_valid(JSON.decode(JSON.encode(built)))
  eq(type(back), "table", "a record from a real tally")
  eq(back.lo_st, built.lo_st); eq(back.key_idx, built.key_idx); eq(back.skipped, 2)
  local empty = K.track_record_build(K.pre_tally_new(), {}, nil)
  eq(type(K.track_record_valid(JSON.decode(JSON.encode(empty)))), "table", "an empty record")
  local merged = K.track_record_build(tally, { ["{b}"] = true }, back)
  eq(type(K.track_record_valid(JSON.decode(JSON.encode(merged)))), "table", "a merged record")
end)

-- F6: an item whose track's record holds another key changes alone
test("key_fix_track_holds_another_key_changes_the_item_only", function() t7_ext(function(ext, ext_sync)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st, NK = S.K, S.state, S.K.new_key
    NK.hand_key_idx = 9
    ext_sync()
    local data = t7_open(7, 1, true)   -- found on its track once; the track's record holds E now
    eq(K.key_found_text(data), nil, "no 'Found from' line")
    st.key_idx = 3
    K.scale_changed("key")
    eq(table.concat(w.log, ","), "begin,take:{a},end:Set Key", "no track write")
    eq(t7_stored(w).key_idx, 5, "the track keeps its key")
    eq(data.key_idx, 3)
    eq(NK.hand_key_idx, 3, "the hand key follows"); eq(ext.pitch_key_hand_idx, "3")
    eq(ext.pitch_key_idx, nil, "no Key for new items")
    eq(next(K.track_records_pending), nil)
  end)
end) end)

-- F7: the track goes during Find Again; the item says so only when it went too
test("find_again_track_deleted_item_moved_says_nothing", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    K.analysis_tick()
    w.dead["tr"] = true   -- the track is deleted; the item was moved to another track first
    auto_run_out()
    eq(#w.log, 0); eq(next(K.track_records_pending), nil); eq(st.is_analyzing, false)
    eq(st.status.text, "", "no status")
  end)
end)

-- F8: MIDI items and items with no active take are neither opened nor counted
test("pre_ignores_midi_and_empty_items", function()
  local items = { [0] = "it_a", [1] = "it_m", [2] = "it_e" }
  pre_world({ stubs = {
    CountTrackMediaItems = function(track) return track == "tr" and 3 or 0 end,
    GetTrackMediaItem = function(_, i) return items[i] end,
    GetActiveTake = function(item) return ({ it_a = "tk_a", it_m = "tk_m" })[item] end,
    TakeIsMIDI = function(take) return take == "tk_m" end,
  } }, function(w)
    local K = S.K
    eq(K.pre_begin({ "tr" }, {}), true)
    pre_run_out()
    eq(table.concat(w.opened, ","), "tk_a", "only the audio take is opened")
    local rec = K.track_records_pending["tr"]
    eq(rec.takes["{a}"], true)
    local n = 0
    for _ in pairs(rec.takes) do n = n + 1 end
    eq(n, 1, "only the audio take is listed")
    eq(rec.skipped, 0, "MIDI and empty items are not media offline")
  end)
end)

-- A key is found unless picked; no Auto in the Key list -------------------------------------------------------------

-- Runs fn with K.pending_key empty and the hand key put back after
local function with_pending(fn)
  local K = S.K
  local saved_pending, NK = K.pending_key, K.new_key
  local saved_hand = { NK.hand_key_idx, NK.hand_scale_idx }
  K.pending_key = {}
  local ok, err = pcall(fn)
  K.pending_key = saved_pending
  NK.hand_key_idx, NK.hand_scale_idx = saved_hand[1], saved_hand[2]
  if not ok then error(err, 0) end
end

test("key_list_has_twelve_keys", function()
  local L = S.COMBO_LABELS
  eq(#L.keys, 12, "twelve short names"); eq(#L.key_names, 12, "twelve long names")
  for i = 1, 12 do
    eq(L.keys[i] ~= "Auto" and L.key_names[i] ~= "Auto", true, "no Auto entry")
  end
  eq(L.keys[1], "C"); eq(L.key_names[2], "C# / Db")
  eq(S.K.key_preview(0), "\xE2\x80\x93", "not set: an en dash")
  eq(S.K.key_preview(2), "C#")
end)

test("new_item_key_sources", function() with_pending(function()
  local K = S.K
  with_track_record(nil, function()
    local k, sc, src = K.new_item_key("{n}")
    eq(k, 0); eq(sc, 1); eq(src, "unset")
    k, sc, src = K.new_item_key(nil)
    eq(k, 0); eq(sc, 1); eq(src, "unset", "no item")
    K.pending_key["{n}"] = { key_idx = 4, scale_idx = 3 }
    k, sc, src = K.new_item_key("{n}")
    eq(k, 4); eq(sc, 3); eq(src, "picked")
  end)
  with_track_record({ st = {}, takes = {}, key_idx = 9, scale_idx = 2 }, function()
    local k, sc, src = K.new_item_key("{n}")
    eq(k, 4); eq(sc, 3); eq(src, "picked", "a picked key wins over the track's")
    k, sc, src = K.new_item_key("{m}")
    eq(k, 9); eq(sc, 2); eq(src, "track")
  end)
  with_track_record({ st = {}, takes = {} }, function()
    local k, _, src = K.new_item_key("{m}")
    eq(k, 0); eq(src, "unset", "a record without a key")
  end)
end) end)

-- What REAPER's selection moving to the item `guid` (take `take`) does, in the order loop_body and the script's
-- start do it: the switch first, then the caller makes the item the target when it was not analysed
local function select_item(guid, take)
  local switched = S.switch_active_target(guid, take)
  if not switched then S.state.target_take_guid = guid end
  return switched
end

test("picked_key_does_not_leak", function() with_pending(function()
  local K, st = S.K, S.state
  local set_ext, by_guid = rawget(reaper, "SetExtState"), rawget(reaper, "GetMediaItemTakeByGUID")
  rawset(reaper, "SetExtState", function() end)
  rawset(reaper, "GetMediaItemTakeByGUID", function(_, guid) return "take" .. guid end)   -- both items exist
  K.drop_project_cache()
  local saved = { st.target_take_guid, st.key_idx, st.scale_idx, st.separation, st.analysis_form }
  local ok, err = pcall(with_track_record, nil, function()
    st.target_take_guid = nil
    select_item("{A}")
    eq(st.key_idx, 0, "A starts unset")
    st.key_idx = 4   -- D# picked in the bar
    K.scale_changed("key")
    eq(K.pending_key["{A}"].key_idx, 4); eq(K.pending_key["{A}"].scale_idx, 1, "Major with a first pick")
    eq(st.scale_idx, 1, "the bar shows Major")
    select_item("{B}")
    eq(st.key_idx, 0, "B is unset"); eq(st.scale_idx, 1)
    eq(K.pending_key["{B}"], nil)
    select_item("{A}")
    eq(st.key_idx, 4, "A shows its picked key again")
    -- A leaves the project: its key is forgotten the next time the open item changes
    rawset(reaper, "GetMediaItemTakeByGUID", function(_, guid) if guid ~= "{A}" then return "take" .. guid end end)
    K.drop_project_cache()
    select_item("{B}")
    eq(K.pending_key["{A}"], nil, "gone with its item")
  end)
  rawset(reaper, "SetExtState", set_ext)
  rawset(reaper, "GetMediaItemTakeByGUID", by_guid)
  K.drop_project_cache()
  st.target_take_guid, st.key_idx, st.scale_idx, st.separation, st.analysis_form = table.unpack(saved, 1, 5)
  K.save_settings("key")
  if not ok then error(err, 0) end
end) end)

-- A on a track whose record has key 5 (tr), B on a track without a record (tr2)
local KEY_AND_NONE = { tr = { items = { "it_a" }, freq = 220 }, tr2 = { items = { "it_b" }, freq = 440, name = "Other" } }

test("switch_pick_does_not_follow_to_the_next_item", function() t7_ext(function()
  auto_world({ tracks = { tr2 = { items = { "it_a", "it_b" }, freq = 440 } } }, function()
    local K, st = S.K, S.state
    st.target_take_guid = nil
    select_item("{a}", "tk_a")
    eq(st.target_take_guid, "{a}"); eq(st.key_idx, 0, "A starts unset")
    st.key_idx = 4
    K.scale_changed("key")
    eq(K.pending_key["{a}"].key_idx, 4)
    eq(select_item("{b}", "tk_b"), false, "B is not analysed")
    eq(st.target_take_guid, "{b}")
    eq(st.key_idx, 0, "B shows no key, not A's pick"); eq(st.scale_idx, 1)
    eq(K.scale_combo_state(st.key_idx, st.scale_idx), true, "Scale is locked on B")
    eq(K.pending_key["{b}"], nil, "nothing picked for B")
    select_item("{a}", "tk_a")
    eq(st.key_idx, 4, "A keeps its pick")
  end)
end) end)

test("switch_shows_the_new_items_track_key", function() t7_ext(function()
  auto_world({ tracks = KEY_AND_NONE, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local st = S.state
    st.target_take_guid = nil
    select_item("{a}", "tk_a")
    eq(st.key_idx, 5, "A shows its track's key")
    select_item("{b}", "tk_b")
    eq(st.key_idx, 0, "B's track has no key: B shows none, not A's track's")
    eq(S.K.scale_combo_state(st.key_idx, st.scale_idx), true, "Scale is locked on B")
    select_item("{a}", "tk_a")
    eq(st.key_idx, 5, "back on A: its track's key"); eq(st.scale_idx, 1)
    eq(S.K.scale_combo_state(st.key_idx, st.scale_idx), false, "Scale is open on A")
  end)
end) end)

test("switch_at_script_start_shows_the_track_key", function() t7_ext(function()
  auto_world({ tracks = KEY_AND_NONE, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local st = S.state
    st.target_take_guid = nil   -- nothing open yet: the script's start
    st.key_idx = 0
    select_item("{a}", "tk_a")
    eq(st.key_idx, 5, "the first item opened shows its track's key"); eq(st.scale_idx, 1)
  end)
end) end)

test("switch_shows_the_new_items_track_separation", function() t7_ext(function()
  auto_world({ tracks = KEY_AND_NONE }, function(w)
    local K, st = S.K, S.state
    w.ext.tr[K.TRACK_DEFAULT_KEY] = JSON.encode({ separation = 0.8 })
    K.drop_project_cache()
    local other = K.item_default("separation", "{b}")
    eq(other ~= 0.8, true, "B's track has no Separation default of its own")
    st.target_take_guid = nil
    select_item("{a}", "tk_a")
    eq(st.separation, 0.8, "A: its track's default")
    select_item("{b}", "tk_b")
    eq(st.separation, other, "B: not A's track's default")
    select_item("{a}", "tk_a")
    eq(st.separation, 0.8)
  end)
end) end)

test("batch_cancel_back_to_an_unanalysed_item_shows_its_key", function() t7_ext(function()
  auto_world({ tracks = KEY_AND_NONE, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid = nil
    select_item("{a}", "tk_a")
    eq(st.key_idx, 5)
    K.pending_key["{b}"] = { key_idx = 3, scale_idx = 2 }
    K.batch_start({ { guid = "{b}", take = "tk_b", item = "it_b", name = "B", len = 6, sample_rate = 8000 } },
      auto_values(false))
    eq(st.target_take_guid, "{b}", "the batch opens its item")
    K.batch_finish(true)
    eq(st.target_take_guid, "{a}", "back to A")
    eq(st.key_idx, 5, "A's track's key, not B's pick"); eq(st.scale_idx, 1)
    -- nothing was open before the batch: nothing is shown after it, not the batch's item's key
    st.target_take_guid, st.target_take_name = nil, nil
    K.batch_start({ { guid = "{b}", take = "tk_b", item = "it_b", name = "B", len = 6, sample_rate = 8000 } },
      auto_values(false))
    eq(st.target_take_guid, "{b}")
    K.batch_finish(true)
    eq(st.target_take_guid, nil); eq(st.key_idx, 0, "no item: no key")
  end)
end) end)

test("picked_key_survives_analysis", function() with_pending(function()
  local pre_key = S.K.pre_key
  S.K.pre_key = function() return 5, 1, 10, 2 end   -- the listening pass would find E Major (A Minor also fits)
  local ok, err = pcall(auto_world, { tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid = "{a}"
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 2 }
    K.adopt_new_item_values()
    eq(st.key_idx, 3, "the bar shows the picked key"); eq(st.scale_idx, 2)
    S.start_analysis(auto_values(true))
    eq(st.pre ~= nil, true, "Vocal Range Auto: the track is heard")
    auto_run_out()
    local data = st.session_takes["{a}"]
    eq(data.key_idx, 3, "the user's key"); eq(data.scale_idx, 2)
    eq(data.key_source, "picked"); eq(data.key_from_track, true)
    local rec = t7_stored(w)
    eq(rec.key_idx, 3, "the track takes the user's key"); eq(rec.scale_idx, 2)
    eq(rec.alt_key_idx, nil); eq(rec.alt_scale_idx, nil)
    local at, b, e = index_of(w.log, "track:tr"), index_of(w.log, "begin"), index_of(w.log, "end:Analyze Pitch")
    eq(at ~= nil and b ~= nil and e ~= nil and b < at and at < e, true, "inside the block: " .. table.concat(w.log, ","))
    eq(K.pending_key["{a}"], nil, "dropped once analysed")
    eq(next(K.track_records_pending), nil); eq(K.auto_run, nil)
    eq(st.key_idx, 3)
  end)
  S.K.pre_key = pre_key
  if not ok then error(err, 0) end
end) end)

test("picked_key_fixed_range_no_pass", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid = "{a}"
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 2 }
    K.adopt_new_item_values()
    eq(K.auto_needed(auto_values(false), "{a}"), false, "nothing to find")
    S.start_analysis(auto_values(false))
    auto_run_out()
    eq(w.pre_calls, 0, "no listening pass")
    eq(index_of(w.log, "track:tr"), nil, "no track write: " .. table.concat(w.log, ","))
    local data = st.session_takes["{a}"]
    eq(data.key_idx, 3); eq(data.scale_idx, 2); eq(data.key_from_track, nil); eq(data.key_source, "picked")
    eq(K.pending_key["{a}"], nil)
  end)
end) end)

test("unset_key_is_found", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid = "{a}"
    K.adopt_new_item_values()
    eq(st.key_idx, 0, "unset")
    eq(K.auto_needed(auto_values(false), "{a}"), true, "the key is to be found")
    S.start_analysis(auto_values(false))
    auto_run_out()
    local rec = t7_stored(w)
    eq(type(rec) == "table" and type(rec.key_idx) == "number", true, "a key was found")
    local data = st.session_takes["{a}"]
    eq(data.key_idx, rec.key_idx); eq(data.scale_idx, rec.scale_idx); eq(data.key_from_track, true)
    eq(data.key_source, "found")
    eq(st.key_idx, rec.key_idx, "the bar shows it")
    eq(JSON.decode(K.take_json(data)).key_source, "found", "stored with the item")
  end)
end) end)

test("reused_record_key_source_track", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid = "{a}"
    K.adopt_new_item_values()
    eq(st.key_idx, 5, "the track's key on the bar"); eq(st.scale_idx, 1)
    eq(K.auto_needed(auto_values(false), "{a}"), false)
    S.start_analysis(auto_values(false))
    auto_run_out()
    local data = st.session_takes["{a}"]
    eq(data.key_idx, 5); eq(data.key_from_track, true); eq(data.key_source, "track")
    eq(index_of(w.log, "track:tr"), nil, "the record is not written again")
  end)
end) end)

test("picked_key_with_record_no_pass_updates_track", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid = "{a}"
    K.pending_key["{a}"] = { key_idx = 8, scale_idx = 2 }
    K.adopt_new_item_values()
    S.start_analysis(auto_values(false))
    auto_run_out()
    eq(w.pre_calls, 0, "no listening pass")
    local rec = t7_stored(w)
    eq(rec.key_idx, 8, "the track's record takes the picked key"); eq(rec.scale_idx, 2); eq(rec.alt_key_idx, nil)
    eq(rec.lo_st, 57, "the rest of the record is kept")
    local at, b, e = index_of(w.log, "track:tr"), index_of(w.log, "begin"), index_of(w.log, "end:Analyze Pitch")
    eq(at ~= nil and b < at and at < e, true, "inside the analysis's block: " .. table.concat(w.log, ","))
    local data = st.session_takes["{a}"]
    eq(data.key_idx, 8); eq(data.key_from_track, true); eq(data.key_source, "picked")
    eq(K.key_found_text(data), nil, "a picked key is not 'Found from'")
    eq(next(K.track_records_pending), nil)
  end)
end) end)

test("pending_key_dropped_on_project_switch_only", function() with_pending(function()
  local K, st = S.K, S.state
  local enum, change_count = rawget(reaper, "EnumProjects"), rawget(reaper, "GetProjectStateChangeCount")
  local proj, n = "p1", 1
  rawset(reaper, "EnumProjects", function() return proj end)
  rawset(reaper, "GetProjectStateChangeCount", function() return n end)
  local ok, err = pcall(function()
    K.drop_project_cache()
    K.refresh_project_cache()
    K.pending_key["{q}"] = { key_idx = 2, scale_idx = 1 }
    n = 2   -- an undo, an edit
    K.refresh_project_cache()
    eq(K.pending_key["{q}"] ~= nil, true, "kept through a project change")
    proj = "p2"   -- another project tab
    K.refresh_project_cache()
    eq(K.pending_key["{q}"], nil, "dropped with the project left")
  end)
  rawset(reaper, "EnumProjects", enum)
  rawset(reaper, "GetProjectStateChangeCount", change_count)
  st.cache.count, st.cache.proj = nil, nil
  K.drop_project_cache()
  if not ok then error(err, 0) end
end) end)

test("key_source_loads_validated", function()
  local K = S.K
  for _, v in ipairs({ "picked", "track", "found" }) do eq(K.key_source_valid(v), v) end
  eq(K.key_source_valid("auto"), nil); eq(K.key_source_valid(3), nil); eq(K.key_source_valid(nil), nil)
end)

test("scale_locked_while_unset", function()
  local K = S.K
  eq(K.SCALE_UNSET_REASON, "Pick a key first, or it is found when you analyze")
  eq(K.KEY_UNSET_TOOLTIP, "Pick the key if you know it. Otherwise it is found from the whole track when you analyze.")
  eq(K.key_tooltip(nil, 0):find(K.KEY_UNSET_TOOLTIP, 1, true) ~= nil, true, "Key while unset says it")
  eq(K.key_tooltip(nil, 5):find(K.KEY_UNSET_TOOLTIP, 1, true), nil, "not once a key is set")
  eq(K.key_tooltip(nil, 5):find("Auto", 1, true), nil, "no Auto in the Key tooltip")
  eq(K.key_tooltip(nil, 0):find("Auto", 1, true), nil)
  -- what the Scale combo is drawn with (hdr_draw_scale uses it)
  local disabled, idx, placeholder, tip = K.scale_combo_state(0, 4)
  eq(disabled, true, "locked while no key is set"); eq(idx, 0, "no row selected"); eq(placeholder, "\xE2\x80\x93")
  eq(tip, "Pick a key first, or it is found when you analyze")
  disabled, idx, placeholder, tip = K.scale_combo_state(5, 2)
  eq(disabled, false); eq(idx, 2, "the scale"); eq(placeholder, "\xE2\x80\x93")
  eq(tip:find("^Scale\n\n") ~= nil, true, "the Scale tooltip")
end)

test("new_key_extstate_not_written", function() with_pending(function()
  local K, st = S.K, S.state
  local writes, blocks, project_writes = {}, 0, 0
  local set_ext, begin = rawget(reaper, "SetExtState"), rawget(reaper, "Undo_BeginBlock")
  local take_str, track_str = rawget(reaper, "GetSetMediaItemTakeInfo_String"),
    rawget(reaper, "GetSetMediaTrackInfo_String")
  rawset(reaper, "SetExtState", function(_, key, value) writes[key] = value end)
  rawset(reaper, "Undo_BeginBlock", function() blocks = blocks + 1 end)
  rawset(reaper, "GetSetMediaItemTakeInfo_String", function(_, _, _, set)
    if set then project_writes = project_writes + 1 end
    return false, ""
  end)
  rawset(reaper, "GetSetMediaTrackInfo_String", function(_, _, _, set)
    if set then project_writes = project_writes + 1 end
    return false, ""
  end)
  local saved = { st.target_take_guid, st.key_idx, st.scale_idx, st.stored.pitch_key_hand_idx,
    st.stored.pitch_scale_hand_idx }
  st.stored.pitch_key_hand_idx, st.stored.pitch_scale_hand_idx = nil, nil   -- every save is seen
  local ok, err = pcall(with_track_record, nil, function()
    st.target_take_guid = "{n}"
    st.key_idx, st.scale_idx = 4, 1
    K.scale_changed("key")
    eq(writes.pitch_key_idx, nil); eq(writes.pitch_scale_idx, nil)
    eq(writes.pitch_key_hand_idx, "4", "the hand key follows"); eq(writes.pitch_scale_hand_idx, "1")
    st.scale_idx = 3
    K.scale_changed("scale")
    eq(K.pending_key["{n}"].key_idx, 4); eq(K.pending_key["{n}"].scale_idx, 3, "the scale picked is kept")
    eq(writes.pitch_scale_hand_idx, "3")
    st.key_idx = 6
    K.scale_changed("key")
    eq(K.pending_key["{n}"].scale_idx, 3, "a scale picked already stays")
    eq(writes.pitch_key_idx, nil); eq(writes.pitch_scale_idx, nil)
    eq(blocks, 0, "no undo block"); eq(project_writes, 0, "no take or track write")
  end)
  rawset(reaper, "SetExtState", set_ext)
  rawset(reaper, "Undo_BeginBlock", begin)
  rawset(reaper, "GetSetMediaItemTakeInfo_String", take_str)
  rawset(reaper, "GetSetMediaTrackInfo_String", track_str)
  st.target_take_guid, st.key_idx, st.scale_idx, st.stored.pitch_key_hand_idx, st.stored.pitch_scale_hand_idx =
    table.unpack(saved, 1, 5)
  if not ok then error(err, 0) end
end) end)

-- Fix round 1: a picked key leads its track in a batch too; Scale on a pick; a hand key on an analysed item ---------

local function one_track_entries()
  return { { guid = "{a}", take = "tk_a", item = "it_a", name = "A", len = 6, sample_rate = 8000, has_notes = false },
    { guid = "{b}", take = "tk_b", item = "it_b", name = "B", len = 6, sample_rate = 8000, has_notes = false } }
end

local function track_writes(w, track)
  local n, at = 0, nil
  for i, s in ipairs(w.log) do if s == "track:" .. track then n, at = n + 1, i end end
  return n, at
end

test("batch_picked_key_leads_track", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 2 }   -- A picked D Minor; B has no key
    K.batch_start(one_track_entries(), auto_values(true))
    auto_run_out()
    local rec = t7_stored(w)
    eq(rec.key_idx, 3, "the track takes A's key"); eq(rec.scale_idx, 2); eq(rec.alt_key_idx, nil)
    local a, b = st.session_takes["{a}"], st.session_takes["{b}"]
    eq(a.key_idx, 3); eq(a.scale_idx, 2); eq(a.key_source, "picked"); eq(a.key_from_track, true)
    eq(b.key_idx, 3, "B takes the track's key"); eq(b.scale_idx, 2); eq(b.key_source, "track")
    eq(b.key_from_track, true)
    local n, at = track_writes(w, "tr")
    local bi, ei = index_of(w.log, "begin"), index_of(w.log, "end:Analyze Pitch (2 items)")
    eq(n, 1, "one track write: " .. table.concat(w.log, ","))
    eq(bi ~= nil and ei ~= nil and bi < at and at < ei, true, "inside the batch's block")
    eq(next(K.track_records_pending), nil); eq(K.pending_key["{a}"], nil)
  end)
end) end)

test("batch_two_picks_first_leads", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 2 }
    K.pending_key["{b}"] = { key_idx = 8, scale_idx = 1 }
    K.batch_start(one_track_entries(), auto_values(true))
    auto_run_out()
    local rec = t7_stored(w)
    eq(rec.key_idx, 3, "the first pick in batch order"); eq(rec.scale_idx, 2)
    local a, b = st.session_takes["{a}"], st.session_takes["{b}"]
    eq(a.key_idx, 3); eq(a.key_from_track, true)
    eq(b.key_idx, 8, "B keeps its own pick"); eq(b.scale_idx, 1); eq(b.key_source, "picked")
    eq(b.key_from_track, nil, "B does not follow the track")
  end)
end) end)

test("batch_fixed_range_record_takes_pick", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    K.pending_key["{a}"] = { key_idx = 8, scale_idx = 2 }
    K.batch_start(one_track_entries(), auto_values(false))
    auto_run_out()
    eq(w.pre_calls, 0, "no listening pass")
    local rec = t7_stored(w)
    eq(rec.key_idx, 8); eq(rec.scale_idx, 2); eq(rec.alt_key_idx, nil); eq(rec.lo_st, 57, "the rest is kept")
    local n, at = track_writes(w, "tr")
    local bi, ei = index_of(w.log, "begin"), index_of(w.log, "end:Analyze Pitch (2 items)")
    eq(n, 1); eq(bi < at and at < ei, true, "inside the batch's block: " .. table.concat(w.log, ","))
    eq(st.session_takes["{b}"].key_idx, 8, "B follows"); eq(st.session_takes["{b}"].key_source, "track")
  end)
end) end)

test("batch_picked_cancelled_writes_nothing", function() with_pending(function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 2 }
    K.batch_start(one_track_entries(), auto_values(true))
    while st.pre do K.analysis_tick() end
    eq(K.track_records_pending.tr ~= nil and K.track_records_pending.tr.key_idx, 3, "the pick leads, pending")
    K.cancel_analysis()
    eq(track_writes(w, "tr"), 0); eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(next(K.track_records_pending), nil); eq(K.auto_run, nil)
    eq(K.pending_key["{a}"].key_idx, 3, "the pick stays for the next analysis")
  end)
end) end)

test("key_pick_scale_rule", function() with_pending(function()
  local K, st = S.K, S.state
  local set_ext = rawget(reaper, "SetExtState")
  rawset(reaper, "SetExtState", function() end)
  local saved = { st.target_take_guid, st.key_idx, st.scale_idx }
  local ok, err = pcall(function()
    with_track_record(nil, function()
      st.target_take_guid, st.key_idx, st.scale_idx = "{u}", 0, 1
      st.key_idx, st.scale_idx = 4, 3   -- picked while "–" (the hidden scale is not a choice)
      K.scale_changed("key")
      eq(st.scale_idx, 1, "Major"); eq(K.pending_key["{u}"].scale_idx, 1)
    end)
    with_track_record({ st = {}, takes = {}, key_idx = 5, scale_idx = 2 }, function()
      st.target_take_guid = "{t}"
      K.adopt_new_item_values()
      eq(st.key_idx, 5); eq(st.scale_idx, 2, "the track's E Minor")
      st.key_idx = 3
      K.scale_changed("key")
      eq(st.scale_idx, 2, "the scale shown stays"); eq(K.pending_key["{t}"].scale_idx, 2)
    end)
  end)
  rawset(reaper, "SetExtState", set_ext)
  st.target_take_guid, st.key_idx, st.scale_idx = table.unpack(saved, 1, 3)
  K.save_settings("key")
  if not ok then error(err, 0) end
end) end)

test("hand_key_on_analysed_item_is_picked", function() t7_ext(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function(w)
    local K, st = S.K, S.state
    local data = t7_open(5, 1, false)
    data.key_source = "found"
    st.key_idx = 3
    K.scale_changed("key")
    eq(data.key_source, "picked", "a key set by hand")
    eq(table.concat(w.log, ","), "begin,take:{a},end:Set Key", "written with the item in one block")
    -- the item follows its track: the track takes the key, and the item's key is still the user's
    w.log = {}
    data = t7_open(5, 1, true)
    data.key_source = "found"
    eq(K.key_found_text(data), "Found from V _ Main.", "found before the change")
    st.key_idx = 7
    K.scale_changed("key")
    eq(data.key_source, "picked", "follows the track: picked by hand all the same")
    eq(table.concat(w.log, ","), "begin,take:{a},track:tr,end:Set Key")
    eq(K.key_found_text(data), nil, "no 'Found from' for a key the user set")
    eq(K.key_tooltip(data, st.key_idx):find("Found from", 1, true), nil, "nor in the Key tooltip")
  end)
end) end)

test("track_record_stored_ignores_pending", function()
  local K = S.K
  local old = rawget(reaper, "GetSetMediaTrackInfo_String")
  rawset(reaper, "GetSetMediaTrackInfo_String", function() return true, "" end)
  local ok, err = pcall(function()
    K.drop_project_cache()
    local rec = K.track_record_build(K.pre_tally_new(), {}, nil)
    K.track_records_pending.trS = rec
    eq(K.track_record("trS"), rec); eq(K.track_record_stored("trS"), nil, "nothing stored")
    local copy = K.track_record_with_key({ st = {}, takes = {}, key_idx = 1, scale_idx = 1, alt_key_idx = 2,
      alt_scale_idx = 2, lo_st = 40, hi_st = 50 }, 6, 2)
    eq(copy.key_idx, 6); eq(copy.scale_idx, 2); eq(copy.alt_key_idx, nil); eq(copy.alt_scale_idx, nil)
    eq(copy.lo_st, 40)
  end)
  rawset(reaper, "GetSetMediaTrackInfo_String", old)
  K.track_records_pending = {}
  K.drop_project_cache()
  if not ok then error(err, 0) end
end)

test("pending_key_pruned_on_project_change", function() with_pending(function()
  local K, st = S.K, S.state
  local by_guid, change_count = rawget(reaper, "GetMediaItemTakeByGUID"),
    rawget(reaper, "GetProjectStateChangeCount")
  local n = 50
  rawset(reaper, "GetMediaItemTakeByGUID", function(_, guid) if guid == "{keep}" then return "tk" end end)
  rawset(reaper, "GetProjectStateChangeCount", function() return n end)
  local saved = { st.last_change_count, st.target_take_guid, st.key_idx, st.scale_idx }
  local ok, err = pcall(function()
    K.drop_project_cache()
    K.pending_key["{keep}"] = { key_idx = 2, scale_idx = 1 }
    K.pending_key["{gone}"] = { key_idx = 4, scale_idx = 1 }
    st.target_take_guid, st.last_change_count = nil, 49
    S.sync_with_project()
    eq(K.pending_key["{gone}"], nil, "its item was deleted"); eq(K.pending_key["{keep}"].key_idx, 2)
  end)
  rawset(reaper, "GetMediaItemTakeByGUID", by_guid)
  rawset(reaper, "GetProjectStateChangeCount", change_count)
  st.last_change_count, st.target_take_guid, st.key_idx, st.scale_idx = table.unpack(saved, 1, 4)
  K.drop_project_cache()
  if not ok then error(err, 0) end
end) end)

test("find_key_is_gone", function()
  eq(S.K.find_key_request, nil); eq(S.K.find_key_finish, nil)
  eq(S.K.new_key.key_idx, nil); eq(S.K.new_key.scale_idx, nil)
end)

-- The Analysis card: progress and results in one modal; the range box in the top bar --------------------------------

-- Ticks the window's analysis, and the card as the window does each frame, until nothing runs (bounded)
local function card_run_out()
  for _ = 1, 100000 do
    if not S.state.is_analyzing and not S.state.pre and not S.K.batch then return end
    S.K.analysis_tick()
    S.K.card_update()
  end
  error("the analysis never ended")
end

local function card_row(label)
  for _, row in ipairs(S.K.card and S.K.card.rows or {}) do
    if row.label == label then return row end
  end
  return nil
end

test("card_text_builders", function()
  local K = S.K
  eq(K.card_title("single", "listen", "07_LeadVox copy.wav"), "Analyzing 07_LeadVox copy.wav")
  eq(K.card_title("single", "notes", "07_LeadVox copy.wav"), "Analyzing 07_LeadVox copy.wav")
  eq(K.card_title("batch", "notes", "Lead take 3.wav", 3, 12), "Analyzing 3 of 12: Lead take 3.wav")
  eq(K.card_title("batch", "listen", nil, 0, 12), "Analyzing 12 items", "the batch's listening pass, before item 1")
  eq(K.card_title("batch", "listen", nil, 0, 2), "Analyzing 2 items")
  eq(K.card_title("again", "listen"), "Finding range and key")
  eq(K.card_title("single", "done", "x"), "Analysis done")
  eq(K.card_title("batch", "done", "x", 12, 12), "Analysis done")
  eq(K.card_step("listen", "Test"), "Listening to track \"Test\"\xE2\x80\xA6")
  eq(K.card_step("notes", "Test"), "Finding notes\xE2\x80\xA6")
  eq(K.card_range_value({ pending = true }), "listening\xE2\x80\xA6")
  eq(K.card_range_value({ source = "found", lo_st = 57, hi_st = 65 }), "A3 \xE2\x80\x93 F4")
  eq(K.card_range_value({ source = "track", lo_st = 57, hi_st = 65, track = "Test" }),
    "A3 \xE2\x80\x93 F4 (from track \"Test\")")
  eq(K.card_range_value({ source = "picked", name = "Tenor" }), "Tenor (your choice)")
  eq(K.card_range_value({ source = "picked", name = "Custom" }), "Custom (your choice)")
  eq(K.card_range_value({ source = "none" }), "No singing found: used Generic Vocal")
  eq(K.card_key_value({ pending = true }), "listening\xE2\x80\xA6")
  eq(K.card_key_value({ source = "found", text = "C Minor" }), "C Minor")
  eq(K.card_key_value({ source = "track", text = "C Minor", track = "Test" }), "C Minor (from track \"Test\")")
  eq(K.card_key_value({ source = "picked", text = "D Major" }), "D Major (your choice)")
  eq(K.card_key_value({ source = "none", text = "E Major" }), "Not enough singing to tell: kept E Major")
  eq(K.card_key_value({ source = "own", text = "E Major" }), "E Major", "a re-analysed item keeps its own key")
  eq(K.card_notes_value({ phase = "listen" }), "waiting")
  eq(K.card_notes_value({ phase = "notes" }), "finding\xE2\x80\xA6")
  eq(K.card_notes_value({ phase = "done", count = 31 }), "31")
  eq(K.card_notes_value({ phase = "done", count = 0 }), "none found. Try another Vocal Range or Detection Mode.")
  local lines = K.card_lines({ skipped = 2, total = 12, track = "Test" })
  eq(#lines, 1); eq(lines[1], "Couldn't read 2 of 12 items on \"Test\" (media offline). Used the rest.")
  lines = K.card_lines({ again = true })
  eq(#lines, 1); eq(lines[1], "Items already analyzed keep theirs.")
  lines = K.card_lines({ summary = { "Analyzed 3 items." }, skipped = 1, total = 3, track = "T", again = true })
  eq(table.concat(lines, "|"), "Analyzed 3 items.|Couldn't read 1 of 3 items on \"T\" (media offline). Used the rest."
    .. "|Items already analyzed keep theirs.", "the summary first, the problem, then the note")
  eq(#K.card_lines({ skipped = 0, total = 3, track = "T" }), 0, "nothing skipped: no line")
  local row = K.card_batch_row("Lead Vox", { lo_st = 47, hi_st = 69, key_idx = 5, scale_idx = 1 },
    { auto_range = true, want_key = true })
  eq(row.label .. "   " .. row.value, "Lead Vox   B2 \xE2\x80\x93 A4 \xC2\xB7 E Major")
  eq(row.choices, nil, "a batch offers no key candidates")
  row = K.card_batch_row("Lead Vox", nil, { auto_range = true, want_key = true })
  eq(row.value, "\xE2\x80\x93 \xC2\xB7 \xE2\x80\x93", "not heard yet"); eq(row.dim, true)
  row = K.card_batch_row("Quiet", { st = {}, takes = {} }, { auto_range = true, want_key = true, kept = "D Major" })
  eq(row.value, "No singing found: used Generic Vocal \xC2\xB7 Not enough singing to tell: kept D Major")
  row = K.card_batch_row("Lead Vox", { lo_st = 47, hi_st = 69 }, { auto_range = false, range = "Tenor" })
  eq(row.value, "Tenor (your choice) \xC2\xB7 \xE2\x80\x93", "a fixed range; no key wanted and none found")
end)

test("card_follows_a_single_analysis", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    local c = K.card
    eq(type(c), "table", "the card opens"); eq(c.kind, "single"); eq(c.phase, "listen")
    eq(c.title, "Analyzing tk_a"); eq(c.step, "Listening to track \"V _ Main\"\xE2\x80\xA6")
    eq(card_row("Vocal Range").value, "listening\xE2\x80\xA6"); eq(card_row("Key").value, "listening\xE2\x80\xA6")
    eq(card_row("Notes").value, "waiting"); eq(card_row("Vocal Range").dim, true)
    eq(c.guid, "{a}")
    while st.pre do K.analysis_tick(); K.card_update() end
    eq(c.phase, "notes"); eq(c.step, "Finding notes\xE2\x80\xA6")
    eq(card_row("Vocal Range").value, "A3 \xE2\x80\x93 A3", "found by this run's own listening pass")
    local rec = K.track_record("tr")
    eq(card_row("Key").value, K.key_text(rec.key_idx, rec.scale_idx))
    eq(card_row("Notes").value, "finding\xE2\x80\xA6")
    near(c.progress, K.analysis_progress(), 1e-12)
    card_run_out()
    eq(K.card, c, "still open at the end"); eq(c.phase, "done"); eq(c.title, "Analysis done"); eq(c.step, "tk_a")
    eq(st.is_analyzing, false)
    local data = st.session_takes["{a}"]
    eq(card_row("Notes").value, K.card_notes_value({ phase = "done", count = #data.notes }))
    eq(card_row("Vocal Range").value, "A3 \xE2\x80\x93 A3")
    eq(card_row("Key").value ~= nil, true)
    eq(st.status.text, "", "no Found / Used message in the status line")
    eq(c.tracks, nil, "the done card holds no pointers")
  end)
end)

test("card_close_call_offers_both", function() t7_ext(function(_, ext_sync)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    ext_sync()
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    local c = K.card
    eq(c.phase, "done")
    local key = card_row("Key")
    eq(#key.choices, 2, "two candidates"); eq(key.choices[1].text, "E Major", "the best first")
    eq(key.choices[1].key_idx, 5); eq(key.choices[2].text, "C# Minor")
    eq(key.choices[2].key_idx, 2); eq(key.choices[2].scale_idx, 2)
    eq(key.note, "These two fit equally well."); eq(c.picked, 1)
    w.log = {}
    c.picked = 2
    K.card_close(true)
    eq(K.card, nil)
    eq(table.concat(w.log, ","), "begin,take:{a},track:tr,end:Set Key", "one block, item and track")
    local data = st.session_takes["{a}"]
    eq(data.key_idx, 2); eq(data.scale_idx, 2)
    local rec = t7_stored(w)
    eq(rec.key_idx, 2); eq(rec.scale_idx, 2); eq(rec.alt_key_idx, nil); eq(rec.alt_scale_idx, nil)
  end)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    w.log = {}
    K.card_close(true)   -- OK with the key in use
    eq(K.card, nil); eq(#w.log, 0, "nothing written, no undo block"); eq(st.session_takes["{a}"].key_idx, 5)
  end)
end) end)

test("card_no_candidates_for_a_picked_key", function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx, st.scale_idx = "{a}", "tk_a", 3, 1
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 1 }
    S.start_analysis(auto_values(true))
    card_run_out()
    eq(card_row("Key").value, "D Major (your choice)"); eq(card_row("Key").choices, nil)
  end)
end)

test("card_esc_on_done_applies_nothing", function() t7_ext(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    w.log = {}
    K.card.picked = 2
    K.card_close(false)   -- Esc
    eq(K.card, nil); eq(#w.log, 0, "nothing written"); eq(st.session_takes["{a}"].key_idx, 5)
    eq(t7_stored(w).alt_key_idx, 2, "the record keeps its runner-up")
  end)
end) end)

test("card_cancel_in_each_phase", function()
  local function after_cancel(w, st, K)
    eq(K.card, nil, "the card closes"); eq(next(K.track_records_pending), nil); eq(K.auto_run, nil)
    eq(index_of(w.log, "begin"), nil, "no undo block: " .. table.concat(w.log, ","))
    eq(st.is_analyzing, false); eq(st.pre, nil)
  end
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    K.analysis_tick(); K.card_update()
    eq(K.card.phase, "listen")
    K.card_cancel()
    after_cancel(w, st, K)
    eq(st.status.text, K.CANCELLED_TEXT)
    S.start_analysis(auto_values(true))
    while st.pre do K.analysis_tick() end
    K.analysis_tick(); K.card_update()
    eq(K.card.phase, "notes")
    K.card_cancel()
    after_cancel(w, st, K)
    eq(st.status.text, K.CANCELLED_TEXT)
  end)
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    K.batch_start(two_entries(), auto_values(true))
    K.analysis_tick(); K.card_update()
    eq(K.card.kind, "batch"); eq(K.card.phase, "listen")
    K.card_cancel()
    after_cancel(w, st, K)
    eq(K.batch, nil); eq(st.status.text, "Batch cancelled. Nothing was changed.")
  end)
  auto_world({ tracks = ONE_TRACK, step = 0.003, ext = { tr = JSON.encode(t7_record(7, 1)) } }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    K.analysis_tick(); K.card_update()
    eq(K.card.kind, "again"); eq(K.card.phase, "listen")
    K.card_cancel()
    after_cancel(w, st, K)
    eq(st.status.text, K.CANCELLED_TEXT)
  end)
end)

test("card_closes_when_its_run_is_dropped", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    K.analysis_tick()
    K.release_analysis()   -- something dropped the run without an outcome
    K.card_update()
    eq(K.card, nil, "a card with nothing running and no result closes")
  end)
end)

test("card_reused_track_and_hand_range", function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    eq(K.card.phase, "notes", "the record covers every take: no listening")
    eq(card_row("Vocal Range").value, "A3 \xE2\x80\x93 A3 (from track \"V _ Main\")")
    eq(card_row("Key").value, "E Major (from track \"V _ Main\")")
    card_run_out()
    eq(card_row("Vocal Range").value, "A3 \xE2\x80\x93 A3 (from track \"V _ Main\")")
    eq(card_row("Key").value, "E Major (from track \"V _ Main\")"); eq(card_row("Key").choices, nil)
    eq(st.status.text, "")
  end)
  auto_world({ tracks = ONE_TRACK }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx, st.scale_idx = "{a}", "tk_a", 3, 1
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 1 }
    S.start_analysis(auto_values(false))   -- Tenor and a picked key: nothing to listen for
    eq(K.card.phase, "notes")
    eq(card_row("Vocal Range").value, "Tenor (your choice)"); eq(card_row("Key").value, "D Major (your choice)")
    card_run_out()
    eq(card_row("Vocal Range").value, "Tenor (your choice)"); eq(card_row("Key").value, "D Major (your choice)")
  end)
  auto_world({ tracks = ONE_TRACK }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx, st.scale_idx = "{a}", "tk_a", 3, 1
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 1 }
    local v = auto_values(false)
    v.min_freq, v.max_freq = 100, 400
    S.start_analysis(v)
    card_run_out()
    eq(card_row("Vocal Range").value, "Custom (your choice)")
  end)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local st = S.state
    t7_open(7, 2, false)   -- analysed before, with its own key
    st.target_take_name = "tk_a"
    S.start_analysis(auto_values(true))
    card_run_out()
    eq(card_row("Key").value, "F# Minor", "a re-analysed item keeps its own key"); eq(card_row("Key").choices, nil)
  end)
end)

test("card_batch_lists_tracks", function()
  local tracks = { tr1 = { items = { "it_a" }, freq = 110, name = "Low" },
    tr2 = { items = { "it_b" }, freq = 0, name = "Quiet" } }
  auto_world({ tracks = tracks, step = 0.003 }, function()
    local K, st = S.K, S.state
    K.batch_start(two_entries(), auto_values(true))
    local c = K.card
    eq(c.kind, "batch"); eq(c.phase, "listen"); eq(c.title, "Analyzing 2 items")
    eq(#c.rows, 2, "one row per track"); eq(c.rows[1].label, "Low"); eq(c.rows[2].label, "Quiet")
    eq(c.rows[1].value, "\xE2\x80\x93 \xC2\xB7 \xE2\x80\x93", "not heard yet")
    while st.pre do K.analysis_tick(); K.card_update() end
    eq(c.phase, "notes"); eq(c.title, "Analyzing 1 of 2: A")
    card_run_out()
    eq(K.card, c); eq(c.phase, "done"); eq(c.title, "Analysis done")
    eq(c.rows[1].value:sub(1, #"A2 \xE2\x80\x93 A2 \xC2\xB7 "), "A2 \xE2\x80\x93 A2 \xC2\xB7 ", "the range heard on Low")
    local NK = K.new_key
    eq(c.rows[2].value, "No singing found: used Generic Vocal \xC2\xB7 Not enough singing to tell: kept "
      .. K.key_text(NK.hand_key_idx, NK.hand_scale_idx))
    eq(c.lines[1], "Analyzed 2 items (1 has no pitched notes). " .. MOD .. "+Z to undo.", "the batch's summary")
    for _, row in ipairs(c.rows) do eq(row.choices, nil, "no key candidates in a batch") end
    eq(st.status.text, "", "the summary is not posted"); eq(c.tracks, nil)
  end)
end)

test("card_find_again", function()
  local old = t7_record(7, 1)
  old.takes = { ["{old}"] = true }
  auto_world({ tracks = ONE_TRACK, step = 0.003, ext = { tr = JSON.encode(old) } }, function()
    local K, st = S.K, S.state
    t7_open(7, 1, true)
    K.find_again_request()
    local c = K.card
    eq(c.kind, "again"); eq(c.title, "Finding range and key"); eq(c.step, "Listening to track \"V _ Main\"\xE2\x80\xA6")
    eq(#c.rows, 2); eq(card_row("Vocal Range").value, "listening\xE2\x80\xA6")
    eq(card_row("Key").value, "listening\xE2\x80\xA6"); eq(card_row("Notes"), nil)
    card_run_out()
    eq(c.phase, "done"); eq(c.title, "Analysis done")
    local rec = K.track_record("tr")
    eq(card_row("Vocal Range").value, "A3 \xE2\x80\x93 A3")
    eq(card_row("Key").value, K.key_text(rec.key_idx, rec.scale_idx))
    eq(c.lines[#c.lines], "Items already analyzed keep theirs.")
    eq(st.status.text, "")
  end)
  auto_world({ tracks = SILENT_TRACK, ext = { tr = JSON.encode(t7_record(7, 1)) } }, function()
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    card_run_out()
    eq(K.card, nil, "nothing found: the card closes")
    eq(st.status.text, "Not enough singing to tell the key: kept F# Major.")
  end)
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function(w)
    local K, st = S.K, S.state
    t7_open(3, 1, false)
    K.find_again_request()
    K.analysis_tick()
    w.dead["tr"], w.dead["tk_a"], w.dead["it_a"] = true, true, true
    K.drop_project_cache()
    card_run_out()
    eq(K.card, nil, "the track went: the card closes"); eq(st.status.text, "This item is no longer in the project")
  end)
end)

test("card_survives_a_vanished_item", function() t7_ext(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    w.dead["tk_a"], w.dead["it_a"] = true, true   -- the item is deleted while the done card is open
    K.drop_project_cache()
    w.log = {}
    K.card.picked = 2
    K.card_close(true)
    eq(K.card, nil); eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(st.session_takes["{a}"].key_idx, 5)
  end)
end) end)

test("card_short_analysis_still_waits", function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    eq(st.pre, nil); eq(K.card.phase, "notes", "straight to finding notes")
    K.analysis_tick()   -- the whole item in one frame
    eq(st.is_analyzing, false)
    K.card_update()
    eq(K.card ~= nil and K.card.phase, "done", "open at done, waiting for OK")
  end)
end)

test("card_not_opened_when_nothing_starts", function()
  auto_world({ tracks = ONE_TRACK, offline = { tk_a = true }, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx, st.scale_idx = "{a}", "tk_a", 3, 1
    K.pending_key["{a}"] = { key_idx = 3, scale_idx = 1 }
    S.start_analysis(auto_values(false))
    eq(K.card, nil); eq(st.status.text, K.AUTO_UNREADABLE_TEXT)
  end)
  auto_world({ tracks = ONE_TRACK, offline = { tk_a = true } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    eq(K.card ~= nil, true, "the track is heard first")
    card_run_out()
    eq(K.card, nil, "the item could not be read: the card closes"); eq(st.status.text, K.AUTO_UNREADABLE_TEXT)
  end)
end)

test("frame_error_closes_the_card", function()
  auto_world({ tracks = ONE_TRACK }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    while st.pre do K.analysis_tick() end   -- the track is heard: its record waits for the analysis's block
    K.card_update()
    eq(K.card ~= nil, true, "the card is open"); eq(st.is_analyzing, true, "the notes are being found")
    eq(next(K.track_records_pending) ~= nil, true, "a record is pending"); eq(K.auto_run ~= nil, true)
    K.recover_after_error()
    eq(K.card, nil, "the card closes")
    eq(next(K.track_records_pending), nil, "nothing pending"); eq(K.auto_run, nil)
    eq(st.is_analyzing, false)
  end)
end)

test("card_counts_as_a_window_modal", function()
  local K = S.K
  local is_open = rawget(reaper, "ImGui_IsPopupOpen")
  rawset(reaper, "ImGui_IsPopupOpen", function(_, name) return name == K.CARD_POPUP end)
  local saved = S.state.confirm
  S.state.confirm = nil
  K.card = { kind = "single", phase = "notes", rows = {}, lines = {}, picked = 1 }
  local ok, err = pcall(function() eq(K.window_modal_open() == true, true) end)
  K.card = nil
  local ok2, err2 = pcall(function() eq(K.window_modal_open() == true, false, "closed: not a modal") end)
  rawset(reaper, "ImGui_IsPopupOpen", is_open)
  S.state.confirm = saved
  if not ok then error(err, 0) end
  if not ok2 then error(err2, 0) end
end)

test("locked_reason_has_no_progress", function()
  auto_world({ tracks = TWO_TRACKS, step = 0.003 }, function()
    local K, st = S.K, S.state
    K.batch_start(two_entries(), auto_values(true))
    K.analysis_tick()
    eq(st.pre ~= nil, true)
    eq(K.locked_reason, nil, "the constant is used as it is")
    eq(K.LOCKED_REASON, "Locked while analyzing", "no progress in the form")
    eq(K.status_line(false), "", "no progress in the status line")
    while st.pre do K.analysis_tick() end
    K.analysis_tick()
    eq(select(2, K.canvas_form(true, false)), K.LOCKED_REASON); eq(K.status_line(false), "")
  end)
end)

test("more_menu_cancel_has_no_percent", function()
  local K = S.K
  eq(K.CANCEL_TEXT, "Cancel"); eq(K.CANCEL_BATCH_TEXT, "Cancel Batch")
  eq(K.CANCEL_FMT, nil); eq(K.CANCEL_BATCH_FMT, nil)
  eq(K.CANCEL_TEXT:find("%", 1, true), nil); eq(K.CANCEL_BATCH_TEXT:find("%", 1, true), nil)
  eq(K.auto_status, nil, "no Found / Used messages any more"); eq(K.auto_run_status, nil)
end)

test("range_box_texts", function()
  local K = S.K
  local function both(t) return K.range_box_text(t), K.range_box_tip(t) end
  local text, tip = both({ has_target = false })
  eq(text, "\xE2\x80\x93"); eq(tip, nil)
  text, tip = both({ has_target = true, values = auto_values(true), track_name = "Test" })
  eq(text, "Auto"); eq(tip, "The range is found from the whole track when you analyze")
  text, tip = both({ has_target = true, values = auto_values(false), track_name = "Test" })
  eq(text, "Tenor"); eq(tip, "Vocal Range: Tenor (130\xE2\x80\x93500 Hz)")
  local found = K.auto_values(auto_values(true), { st = {}, takes = {}, lo_st = 57, hi_st = 65 })
  text, tip = both({ has_target = true, data = { analysis = found }, values = auto_values(false),
    track_name = "Test" })
  eq(text, "A3\xE2\x80\x93F4", "analysed: the range found, not the form's")
  eq(tip, "Vocal range found on Test: 220\xE2\x80\x93349 Hz, with a little room either side")
  text, tip = both({ has_target = true, data = { analysis = auto_values(false) },
    values = auto_values(true), track_name = "Test" })
  eq(text, "Tenor"); eq(tip, "Vocal Range: Tenor (130\xE2\x80\x93500 Hz)")
  local none = auto_values(true)
  none.auto_none = true
  text, tip = both({ has_target = true, data = { analysis = none } })
  eq(text, "Generic Vocal"); eq(tip:find("^Vocal Range: Generic Vocal %(") ~= nil, true)
  eq(both({ has_target = true, data = { analysis = { bad = true } } }), "\xE2\x80\x93", "unreadable: none")
  eq(K.range_box_tip({ has_target = true, data = { analysis = { bad = true } } }), nil)
end)

test("range_box_text_is_cheap_per_frame", function()
  local K = S.K
  local real_values, calls = K.analysis_values, 0
  K.analysis_values = function(...) calls = calls + 1; return real_values(...) end
  local ok, err = pcall(function()
    local found = K.auto_values(auto_values(true), { st = {}, takes = {}, lo_st = 57, hi_st = 65 })
    local t = { has_target = true, data = { analysis = found }, track_name = "Test" }
    eq(K.range_box_text(t), "A3\xE2\x80\x93F4")
    local first = calls
    for _ = 1, 5 do eq(K.range_box_text(t), "A3\xE2\x80\x93F4") end
    eq(calls, first, "the same analysis is not read again every frame")
    -- a new analysis (a re-analysis, an undo) is a new table: read again
    t.data = { analysis = K.auto_values(auto_values(true), { st = {}, takes = {}, lo_st = 60, hi_st = 64 }) }
    eq(K.range_box_text(t), "C4\xE2\x80\x93E4")
    -- the form of an item not analysed yet, changed in place: the text follows it
    local values = auto_values(true)
    t = { has_target = true, values = values }
    eq(K.range_box_text(t), "Auto")
    values.auto_range, values.min_freq, values.max_freq = false, 130, 500
    eq(K.range_box_text(t), "Tenor")
    eq(K.range_box_text({ has_target = false }), "\xE2\x80\x93")
  end)
  K.analysis_values = real_values
  if not ok then error(err, 0) end
end)

-- Final review fixes: the Analysis card -----------------------------------------------------------------------------

test("card_reanalysis_keeps_the_picked_source", function()
  local K = S.K
  local c = { guid = "{zz}", before = true, values = auto_values(false), track_name = "Test" }
  local function key_value(source)
    local data = { guid = "{zz}", key_idx = 3, scale_idx = 1, key_source = source, notes = {},
      analysis = auto_values(false) }
    return K.card_single_rows(c, "done", { data = data })[2].value
  end
  eq(key_value("picked"), "D Major (your choice)", "a key the user chose says so on a re-analysis")
  eq(key_value("track"), "D Major", "the track's: bare on a re-analysis")
  eq(key_value("found"), "D Major")
  eq(key_value(nil), "D Major", "no source: bare")
end)

test("card_real_reanalysis_shows_your_choice", function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local K, st = S.K, S.state
    local data = t7_open(3, 1, false)
    data.key_source = "picked"
    data.analysis = auto_values(false)
    S.start_analysis(auto_values(false))
    eq(K.card ~= nil and K.card.before, true, "a re-analysis")
    card_run_out()
    eq(K.card.phase, "done")
    eq(card_row("Key").value, "D Major (your choice)")
    eq(st.session_takes["{a}"].key_source, "picked", "carried")
  end)
end)

test("card_other_key_with_another_item_open_writes_nothing", function() t7_ext(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    eq(#card_row("Key").choices, 2)
    st.target_take_guid, st.target_take_name = "{b}", "tk_b"   -- another item is open now
    w.log = {}
    K.card.picked = 2
    K.card_close(true)
    eq(K.card, nil, "the card closes"); eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(st.session_takes["{a}"].key_idx, 5, "A keeps its key"); eq(t7_stored(w).key_idx, 5, "so does the track")
  end)
end) end)

test("card_other_key_after_the_analysis_was_undone_writes_nothing", function() t7_ext(function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function(w)
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    eq(#card_row("Key").choices, 2)
    st.session_takes["{a}"] = nil   -- Cmd+Z took the analysis away (sync_with_project drops the model)
    w.log = {}
    K.card.picked = 2
    K.card_close(true)
    eq(K.card, nil); eq(#w.log, 0, "nothing written: " .. table.concat(w.log, ","))
    eq(t7_stored(w).key_idx, 5, "the track keeps its key")
  end)
end) end)

-- Fix round 1 of the Analysis card ----------------------------------------------------------------------------------

test("card_closes_when_the_write_fails", function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    K.write_take_envelope = function() return false end   -- the item's envelope cannot be written
    S.start_analysis(auto_values(true))
    card_run_out()
    eq(K.card, nil, "no 'Analysis done' for an item whose analysis was not saved")
  end)
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1, { 2, 2 })) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    card_run_out()
    eq(K.card ~= nil and K.card.phase, "done", "written: the done card")
  end)
end)

test("card_line_after_a_first_analysis_has_no_reanalyzed_note", function()
  auto_world({ tracks = ONE_TRACK, ext = { tr = JSON.encode(t7_record(5, 1)) } }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    K.reanalyze_status_guid = nil
    S.start_analysis(auto_values(true))
    card_run_out()
    local text = string.format(K.REANALYZED_DEFAULTS_TEXT, K.MOD_LABEL)
    for _, line in ipairs(K.card.lines) do eq(line ~= text, true, "a first analysis has nothing to go back") end
    eq(K.card_lines({ reanalyzed = true })[1], text, "the existing sentence, as a card line")
  end)
end)

test("card_batch_row_shows_a_picked_key", function()
  local K = S.K
  local row = K.card_batch_row("Lead Vox", nil, { auto_range = false, range = "Tenor",
    item_key = { source = "picked", text = "D Major" } })
  eq(row.value, "Tenor (your choice) \xC2\xB7 D Major (your choice)")
  auto_world({ tracks = ONE_TRACK }, function()
    local st = S.state
    for _, g in ipairs({ "{a}", "{b}" }) do K.pending_key[g] = { key_idx = 3, scale_idx = 1 } end
    K.batch_start(one_track_entries(), auto_values(false))
    card_run_out()
    eq(K.card.phase, "done")
    eq(K.card.rows[1].value, "Tenor (your choice) \xC2\xB7 D Major (your choice)", "the first written item's key")
    eq(st.status.text, "")
  end)
end)

test("card_closes_when_reset_drops_its_run", function()
  auto_world({ tracks = ONE_TRACK, step = 0.003 }, function()
    local K, st = S.K, S.state
    st.target_take_guid, st.target_take_name, st.key_idx = "{a}", "tk_a", 0
    S.start_analysis(auto_values(true))
    K.analysis_tick()
    eq(K.card ~= nil, true)
    S.reset_analysis_model()   -- the open item removed, the session wiped
    eq(K.card, nil, "closed at once"); eq(st.is_analyzing, false); eq(st.pre, nil)
  end)
end)

test("card_center_on_the_canvas", function()
  local K = S.K
  local host = { x = 0, y = 0, w = 1000, h = 600 }
  local cx, cy = K.card_center({ x = 0, y = 100, w = 800, h = 500 }, host, nil)
  eq(cx, 400); eq(cy, 350)
  cx, cy = K.card_center(nil, host, nil)
  eq(cx, 500, "no canvas: the window's centre"); eq(cy, 300)
  cx, cy = K.card_center({ x = 0, y = 100, w = 800, h = 500 }, host, { w = 420, h = 560 })
  eq(cx, 400); eq(cy, 320, "held inside the window: a tall card moves up")
  cx = K.card_center({ x = 0, y = 0, w = 300, h = 600 }, host, { w = 420, h = 200 })
  eq(cx, 210, "held inside the window on the left")
end)

-- Tests appended by later tasks go above this line.
local failed = false
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then count = count + 1
  else failed = true; io.stderr:write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n") end
end
if failed then os.exit(1) end
print("ok " .. count .. " tests")
