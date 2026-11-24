-- Run from the repo root: lua docs/superpowers/tests/pitch_correct_spec.lua
local SCRIPT = "Pitch/Fancy_Pitch Correct.lua"

local function load_script()
  reaper = setmetatable({
    ImGui_CreateContext = function() end,
    GetExtState = function() return "" end,   -- top-level code tonumber()s this
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
  local a, b = K.batch_lines({ n = 1, skipped = 0, with_notes = 0, target_in = true })
  eq(a, "No data. Select an item and click Analyze."); eq(b, "Select several items in REAPER to analyze them all at once.")
  a, b = K.batch_lines({ n = 12, skipped = 0, with_notes = 0, target_in = true })
  eq(a, "12 audio items selected."); eq(b, nil)
  a, b = K.batch_lines({ n = 12, skipped = 2, with_notes = 3, target_in = false })
  eq(a, "12 audio items selected (2 other items are skipped). This item is not one of them.")
  eq(b, "3 already have notes. You will be asked before they are replaced.")
  a, b = K.batch_lines({ n = 2, skipped = 1, with_notes = 1, target_in = true })
  eq(a, "2 audio items selected (1 other item is skipped)."); eq(b, "1 already has notes. You will be asked before it is replaced.")
  eq(K.batch_tip(12), "Detect the pitch of the 12 selected audio items, one after another. One undo step for all of them.")
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
  eq(c.after_lines[1], MOD .. "+Z restores all 12 items in one step once the batch has finished.")
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
    rec.begun[#rec.begun + 1] = { take = take, sr = opts and opts.sample_rate, defer = opts and opts.defer_envelope }
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
  K.batch, st.is_analyzing = nil, false
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
  eq(S.state.status.text, "Analyzed 3 items. " .. MOD .. "+Z to undo.")
end) end)

test("batch_skips_missing_and_offline", function() with_batch(function(rec)
  local K = S.K
  rec.gone = { ["{a}"] = true }
  local e = entries3(); e[2].sample_rate = 0
  K.batch_start(e)
  eq(#rec.begun, 1); eq(rec.begun[1].take, "c", "the deleted and the offline item never start")
  K.batch_item_done(model("{c}"))
  eq(S.state.status.text, "Analyzed 1 of 3 items. 2 could not be analyzed. " .. MOD .. "+Z to undo.")
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
  eq(S.state.status.text, "Analyzed 1 of 3 items. 2 could not be analyzed. " .. MOD .. "+Z to undo.")
end) end)

test("batch_counts_items_without_notes", function() with_batch(function()
  local K = S.K
  K.batch_start(entries3())
  K.batch_item_done(model("{a}", {})); K.batch_item_done(model("{b}")); K.batch_item_done(model("{c}"))
  eq(S.state.status.text, "Analyzed 3 items (1 has no pitched notes). " .. MOD .. "+Z to undo.")
end) end)

test("batch_cancel_keeps_finished", function() with_batch(function(rec)
  local K = S.K
  K.batch_start(entries3()); K.batch_item_done(model("{a}"))
  eq(K.cancel_analysis(), true)
  eq(#rec.writes, 1); eq(#rec.writes[1], 1); eq(K.batch, nil); eq(S.state.is_analyzing, false)
  eq(S.state.status.text, "Batch cancelled. 1 of 3 items was analyzed and kept. " .. MOD .. "+Z to undo.")
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
  S.K.batch_write({ { guid = "{a}", data = data } })   -- no text prepared: made at the write
  eq(rec.stored.a, json)
end) end)

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
    eq(st.status.text, "Analyzed 2 items (2 have no pitched notes). " .. MOD .. "+Z to undo.")
  end)
  K.analysis_begin, st.target_take_guid, st.target_take_name, st.results, st.notes = table.unpack(saved, 1, 5)
  K.batch, st.is_analyzing, st.status.text, st.status.hold = nil, false, "", nil
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
  eq(K.status_line(false), "Analyzing 2 of 2: V Main Verse 3… 62%")
  K.batch, st.is_analyzing, st.progress = nil, false, 0
  reaper.time_precise = nil
end)

test("confirm_carries_the_list", function()
  local st = S.state
  local req = S.K.batch_confirm({ { guid = "{a}", name = "A", track = "Vox", pos = 1, has_notes = true }, { guid = "{b}", name = "B", has_notes = false } })
  req.id, req.on_confirm = "batch", function() end
  S.request_confirm(req)
  eq(st.confirm.id, "batch"); eq(#st.confirm.list, 1); eq(st.confirm.list[1].name, "A")
  eq(st.confirm.after_lines[1], MOD .. "+Z restores all 2 items in one step once the batch has finished.")
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

-- Starting values and per-item values (copy once) -------------------------------------------------------
test("item_seed_fills_all", function()
  local K = S.K
  local data = {}
  eq(K.item_seed(data), true, "first seed fills")
  local start = K.start_values()
  for _, key in ipairs(K.ITEM_KEYS) do
    local v = (key == "separation") and data.separation or (data.overrides and data.overrides[key])
    if v == nil then error("missing " .. key) end
    eq(v, start[key], key)
  end
  eq(data.key_idx, start.key_idx, "key_idx")
  eq(data.scale_idx, start.scale_idx, "scale_idx")
  eq(K.item_seed(data), false, "second seed fills nothing")
end)

test("item_copy_once", function()
  local st, K = S.state, S.K
  local saved = { st.target_take_guid, st.session_takes["{seed}"] }
  local data = { notes = {}, results = {} }
  K.item_seed(data)
  st.session_takes["{seed}"], st.target_take_guid = data, "{seed}"
  local before = S.get_effective(nil, "tolerance")
  S.global_defaults.tolerance = before + 7
  local ok, err = pcall(function() eq(S.get_effective(nil, "tolerance"), before, "item value kept") end)
  S.global_defaults.tolerance = before
  st.target_take_guid, st.session_takes["{seed}"] = saved[1], saved[2]
  if not ok then error(err, 0) end
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

test("start_values_key_from_global", function()
  local st, g = S.state, S.global_defaults
  local saved = { g.key_idx, st.key_idx, g.scale_idx, st.scale_idx }
  g.key_idx, st.key_idx, g.scale_idx, st.scale_idx = 3, 7, 2, 5
  local sv = S.K.start_values()
  g.key_idx, st.key_idx, g.scale_idx, st.scale_idx = saved[1], saved[2], saved[3], saved[4]
  eq(sv.key_idx, 3, "key_idx")
  eq(sv.scale_idx, 2, "scale_idx")
end)

test("unanalysed_take_takes_start_values", function()
  local st, g = S.state, S.global_defaults
  local saved = { g.separation, g.key_idx, g.scale_idx, st.separation, st.key_idx, st.scale_idx }
  g.separation, g.key_idx, g.scale_idx = 0.8, 4, 2
  st.separation, st.key_idx, st.scale_idx = 0.1, 9, 1
  S.K.adopt_start_values()
  local got = { st.separation, st.key_idx, st.scale_idx }
  g.separation, g.key_idx, g.scale_idx, st.separation, st.key_idx, st.scale_idx = table.unpack(saved)
  eq(got[1], 0.8, "separation")
  eq(got[2], 4, "key_idx")
  eq(got[3], 2, "scale_idx")
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

-- The bar edits this item or the notes, never the starting values (value levels, Task 3) ---------------------------
local function with_no_project(fn)   -- runs fn where an envelope write finds no take (it says so and writes nothing)
  local saved = { reaper.time_precise, reaper.CountMediaItems }
  reaper.time_precise = function() return 0 end
  reaper.CountMediaItems = function() return 0 end
  local ok, err = pcall(fn)
  reaper.time_precise, reaper.CountMediaItems = saved[1], saved[2]
  if not ok then error(err, 0) end
end

test("reset_item_to_start", function()
  with_no_project(function() with_item({ tolerance = 30 }, function()
    eq(type(S.K.reset_target("tolerance", {}, 0)), "boolean", "returns a boolean")
    eq(S.state.session_takes["{IV}"].overrides.tolerance, S.global_defaults.tolerance, "the item's value")
  end) end)
end)

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

test("bar_never_saves_cascade", function()
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

test("scale_change_keeps_start_key", function()
  local st, K = S.state, S.K
  local ext = 0
  local set_ext = reaper.SetExtState
  reaper.SetExtState = function() ext = ext + 1 end
  local saved = { st.target_take_guid, st.key_idx, S.global_defaults.key_idx }
  st.target_take_guid = nil
  st.key_idx = (S.global_defaults.key_idx or 1) % 12 + 1
  local ok, err = pcall(K.scale_changed, "key")
  reaper.SetExtState = set_ext
  st.target_take_guid, st.key_idx = saved[1], saved[2]
  if not ok then error(err, 0) end
  eq(ext, 0, "SetExtState calls")
  eq(S.global_defaults.key_idx, saved[3], "the starting key")
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
  st.target_take_guid, st.session_takes["{KL}"] = "{KL}", { notes = {}, results = {} }
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
  eq(status, "Re-split 1 notes into 2.", "status")
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
      if a <= b then error(string.format("plan %d (%g) is not wider than plan %d (%g)", i, a, i + 1, b), 0) end
    end
    eq(plans[1].captions and plans[3].captions and not plans[2].captions and not plans[4].captions
      and not plans[5].captions, true, "captions in plans 1 and 3 only")
  end)
  reaper.ImGui_CalcTextSize, reaper.ImGui_GetFrameHeight = saved[1], saved[2]
  if not ok then error(err, 0) end
end)

test("reset_item_all_counts", function()
  local K = S.K
  local data = {}
  K.item_seed(data)
  eq(K.item_differs(data), 0, "seeded")
  data.overrides.tolerance = data.overrides.tolerance + 5
  eq(K.item_differs(data), 1, "tolerance changed")
  K.item_reset_values(data)
  eq(K.item_differs(data), 0, "reset")
  eq(data.overrides.tolerance, K.start_values().tolerance, "starting value back")
end)

test("reset_item_all_one_undo", function() with_write_stubs({}, function(rec)
  local st, K = S.state, S.K
  local fr = stretch_frames(slide_segs(62))
  local start = K.start_values()
  local other_sep = (start.separation > 0.5) and 0.2 or 0.9
  local old, old_splits = K.segment(fr, other_sep)
  local data = { guid = "{a}", name = "{a}", notes = old, results = fr, item_len = 2, sample_rate = 44100 }
  K.item_seed(data)
  data.separation = other_sep
  data.overrides.tolerance = start.tolerance + 5
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
    eq(rec.labels[1], "Reset item to starting values", "undo label")
    eq(st.status.text, "Item reset to the starting values.", "status")
    eq(K.item_differs(data), 0, "every value back")
    eq(st.separation, start.separation, "bar Separation follows")
    eq(st.key_idx, start.key_idx, "bar Key follows")
    eq(st.notes ~= old, true, "re-split")
    K.reset_item_all()
    eq(#rec.labels, 1, "nothing differs: no undo point")
  end)
  st.target_take_guid, st.results, st.notes, st.split_points, st.separation, st.key_idx,
    st.scale_idx, reaper.time_precise, st.status.text = table.unpack(saved, 1, 9)
  if not ok then error(err, 0) end
end) end)

-- Apply to other items (K.apply_plan, the confirm's choices)
-- A target of K.apply_plan: a model with notes split from `fr` at `sep`, each note with its controls
local function apply_target(id, fr, sep, tol)
  local notes = S.K.segment(fr, sep)
  S.K.resplit_features(notes, {})
  local data = { guid = "{" .. id .. "}", name = id, notes = notes, results = fr, item_len = 2, sample_rate = 44100,
    separation = sep, overrides = { tolerance = tol } }
  return { guid = data.guid, take = id, name = id, data = data }
end
local function apply_start(sep, tol)
  return { separation = sep, tolerance = tol, correct_mode = 0, tighten = 0, retune_speed = 1, slide_in = 0,
    key_idx = 1, scale_idx = 1 }
end

test("apply_plan_overwrites", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
  for _, e in ipairs({ a, b }) do e.data.notes[1].controls.tolerance = 30 end
  local plan = S.K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, false, apply_start(0.5, 8))
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
  local plan = S.K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, true, apply_start(0.5, 8))
  eq(plan.items[1].set.tolerance, 40, "a was at the starting value: set")
  eq(plan.items[2].set.tolerance, nil, "b has its own value: kept")
  eq(#plan.items[1].clear_note_keys, 0, "notes keep their own"); eq(plan.counts.notes_lose, 0)
  eq(plan.counts.items_lose, 0, "a held the starting value: nothing of its own is lost"); eq(plan.changed, 1)
end)

test("apply_plan_keep_no_resplit", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local function target()
    local t = apply_target("a", fr, 0.5, 8)
    eq(#t.data.notes, 2, "split at 0.5")
    t.data.notes[1].controls.center_pitch = t.data.notes[1].controls.center_pitch + 1   -- an edit
    return t
  end
  local keep = S.K.apply_plan({ separation = 0 }, { target() }, { "separation" }, true, apply_start(0.5, 8))
  eq(keep.items[1].resplit, false, "keep: not split again"); eq(keep.counts.not_resplit, 1)
  local over = S.K.apply_plan({ separation = 0 }, { target() }, { "separation" }, false, apply_start(0.5, 8))
  eq(over.items[1].resplit, true, "overwrite: split again"); eq(over.counts.resplit, 1)
  eq(over.counts.lost > 0, true, "the edited note is lost")
end)

test("apply_plan_skips_missing", function()
  local fr = frames(REARTIC_SEGS, HOP)
  local gone = apply_target("a", fr, 0.5, 8); gone.take = nil
  local midi = apply_target("m", fr, 0.5, 8); midi.midi = true
  local plan = S.K.apply_plan({ tolerance = 40 }, { gone, midi }, { "tolerance" }, false, apply_start(0.5, 8))
  eq(#plan.items, 0, "no rows"); eq(plan.counts.skipped, 2, "counted")
end)

test("apply_plan_new_only", function()
  local plan = S.K.apply_plan({ tolerance = 40 }, {}, { "tolerance" }, false, apply_start(0.5, 8))
  eq(#plan.items, 0); eq(plan.counts.items_lose, 0); eq(plan.counts.skipped, 0)
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
      choices = { { label = "One", value = "one" }, { label = "Two", value = "two" } },
      check = { label = "Keep", value = false },
      consequence = function(choice, checked) calls = calls + 1; return { lines = { choice .. tostring(checked) } } end })
    S.draw_confirm_modal(); S.draw_confirm_modal()
    eq(calls, 1, "same choice: computed once")
    eq(st.confirm.cons.lines[1], "onefalse", "cached in state.confirm")
    st.confirm.choice = "two"; S.draw_confirm_modal()
    eq(calls, 2, "a new choice: computed again")
    st.confirm.checked = true; S.draw_confirm_modal(); S.draw_confirm_modal()
    eq(calls, 3, "the check changed: computed again, once")
  end)
  for k in pairs(stubs) do reaper[k] = nil end
  st.confirm = nil
  if not ok then error(err, 0) end
end)

test("apply_run_one_undo_and_cancel", function() with_write_stubs({}, function(rec)
  local st, K, G = S.state, S.K, S.global_defaults
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, G.tolerance, reaper.time_precise, st.is_analyzing }
  reaper.time_precise = function() return 0 end
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    st.target_take_guid = "{open}"
    local plan = K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, false, apply_start(0.5, 8))
    K.apply_run(plan, { "tolerance" }, { tolerance = 40 }, "Tolerance")
    eq(G.tolerance, 40, "starting value saved first"); eq(K.batch ~= nil, true, "runs as a batch")
    for _ = 1, 10 do if K.batch then K.analysis_tick() end end
    eq(K.batch, nil, "done"); eq(st.is_analyzing, false)
    eq(#rec.labels, 1, "one undo point"); eq(rec.labels[1], "Apply Tolerance to 2 items")
    eq(st.session_takes["{a}"].overrides.tolerance, 40, "a written"); eq(a.data.overrides.tolerance, 12, "old model untouched")
    eq(st.status.text, "Applied to 2 items (" .. MOD .. "+Z undoes the items).")
    -- Cancel before the first item: nothing written, the starting values stay
    G.tolerance = 8
    plan = K.apply_plan({ tolerance = 50 }, { a, b }, { "tolerance" }, false, apply_start(0.5, 8))
    K.apply_run(plan, { "tolerance" }, { tolerance = 50 }, "Tolerance")
    eq(K.cancel_analysis(), true)
    eq(#rec.labels, 1, "no new undo point"); eq(G.tolerance, 50, "starting value kept")
    eq(st.status.text, "Apply cancelled. No item was changed. The starting values were saved.")
  end)
  st.target_take_guid, G.tolerance, reaper.time_precise, st.is_analyzing = table.unpack(saved, 1, 4)
  K.batch = nil
  st.status.text, st.status.hold = "", nil
  if not ok then error(err, 0) end
end) end)

test("apply_refuses_when_the_open_item_changed", function() with_write_stubs({}, function(rec)
  local st, K, G = S.state, S.K, S.global_defaults
  local fr = frames(REARTIC_SEGS, HOP)
  local saved = { st.target_take_guid, G.tolerance, reaper.time_precise, st.is_analyzing, st.confirm }
  reaper.time_precise = function() return 0 end
  local ok, err = pcall(function()
    local a, b = apply_target("a", fr, 0.5, 12), apply_target("b", fr, 0.5, 20)
    st.session_takes["{a}"], st.session_takes["{b}"] = a.data, b.data
    st.session_order[#st.session_order + 1] = "{a}"; st.session_order[#st.session_order + 1] = "{b}"
    st.target_take_guid, st.confirm = "{open}", nil
    local start_tol = G.tolerance
    K.apply_open({ "tolerance" })
    local c = st.confirm
    eq(c ~= nil and c.id, "apply", "the confirm is open")
    eq(c.choice, "all", "nothing selected: all pitched items")
    st.target_take_guid = "{a}"   -- the user clicked a target in the arrange view
    c.on_confirm(c.choice, c.checked)
    eq(#rec.labels, 0, "no undo point"); eq(K.batch, nil, "no run")
    eq(st.session_takes["{a}"], a.data, "a untouched"); eq(G.tolerance, start_tol, "starting values untouched")
    eq(st.status.text, "The item changed meanwhile. Nothing was applied.")
    -- Defence in depth: a row for the open item is never run
    local plan = K.apply_plan({ tolerance = 40 }, { a, b }, { "tolerance" }, false, apply_start(0.5, 8))
    K.apply_run(plan, { "tolerance" }, { tolerance = 40 }, "Tolerance")
    for _ = 1, 10 do if K.batch then K.analysis_tick() end end
    eq(rec.labels[1], "Apply Tolerance to 1 items", "only b")
    eq(st.session_takes["{a}"], a.data, "the open item is not written")
    eq(st.session_takes["{b}"].overrides.tolerance, 40, "b written")
  end)
  st.target_take_guid, G.tolerance, reaper.time_precise, st.is_analyzing, st.confirm = table.unpack(saved, 1, 5)
  K.batch = nil
  st.status.text, st.status.hold = "", nil
  if not ok then error(err, 0) end
end) end)

-- Tests appended by later tasks go above this line.
local failed = false
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then count = count + 1
  else failed = true; io.stderr:write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n") end
end
if failed then os.exit(1) end
print("ok " .. count .. " tests")
