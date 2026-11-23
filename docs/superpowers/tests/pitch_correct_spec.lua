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

local function untouched_note(t0, dur, centre, slide)
  local n = join_note(t0, dur, centre, 0, slide)
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

local function natural_record()
  local ok = os.execute('git diff --quiet ' .. NATURAL_REF .. ' -- "' .. SCRIPT .. '"')
  if ok ~= true then
    io.stderr:write("refusing to record: " .. SCRIPT .. " differs from " .. NATURAL_REF
      .. " (the fixture is the v2.18.0 behaviour)\n")
    os.exit(1)
  end
  local function write(path, name_of, items)
    local out = { "-- Recorded by: lua docs/superpowers/tests/pitch_correct_spec.lua --record-natural",
      "-- Natural correction of Pitch Correct v2.18.0 (commit " .. NATURAL_REF .. "). Do not edit by hand.",
      "return {", '  commit = "' .. NATURAL_REF .. '",', "  cases = {" }
    for _, item in ipairs(items) do record_case(out, name_of(item), item.got, item.notes) end
    out[#out + 1] = "  },"
    out[#out + 1] = "}"
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(out, "\n"), "\n")
    f:close()
    print("recorded " .. #items .. " cases to " .. path)
  end
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
  for _, prefix in ipairs({ "K.tighten_line = function(", "K.note_body = function(", "K.points_offsets = function(",
      "local function is_note_modified(", "K.controls_edited = function(", "K.ZONE_CONTROLS = {",
      "local function param_drag(", "  local BAR_VALUES = {" }) do
    text_same(ref, now, prefix, prefix, false, prefix)
  end
  -- The build may be renamed (natural_build) but not changed; its first line carries the name
  local build = "K.correction_build = function(notes, item_len)"
  local renamed = "K.natural_build = function(notes, item_len)"
  local has_renamed = false
  for _, l in ipairs(now) do if l:sub(1, #renamed) == renamed then has_renamed = true break end end
  text_same(ref, now, build, has_renamed and renamed or build, true, "the build")
  text_single(ref, now, "K.JOIN = {", "K.JOIN")
  local loaded = text_block(now, "K.controls_load = function(")
  local ref_loaded = text_block(ref, "K.controls_load = function(")
  if not (loaded and ref_loaded) then error("K.controls_load not found") end
  for _, prefix in ipairs({ "  if ctrl.tighten then", "  if ctrl.tolerance then" }) do
    text_single(ref_loaded, loaded, prefix, "K.controls_load " .. prefix)
  end
end)

if arg and arg[1] == "--record-natural" then natural_record() os.exit(0) end

-- Tests appended by later tasks go above this line.
local failed = false
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then count = count + 1
  else failed = true; io.stderr:write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n") end
end
if failed then os.exit(1) end
print("ok " .. count .. " tests")
