-- Run from the repo root: lua docs/superpowers/tests/pitch_correct_spec.lua
local SCRIPT = "Pitch/Fancy_Pitch Correct.lua"

local function load_script()
  reaper = setmetatable({
    ImGui_CreateContext = function() end,
    GetExtState = function() return "" end,   -- top-level code tonumber()s this
  },
    { __index = function() return function() end end })
  FANCY_PITCH_TEST = true
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

test("segment_short_note", function()
  eq(#segment({ { dur = 0.12, note = 60 }, { dur = 0.4, note = 62 } }, HOP, 0.5), 2, "notes")
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
  for i = 1, 6 do
    if math.abs(s1[i] - s0[i]) > S.K.SCOOP_MAX_ST + 1e-9 then error("moved too far at " .. i) end
  end
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

-- Tests appended by later tasks go above this line.
local failed = false
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then count = count + 1
  else failed = true; io.stderr:write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n") end
end
if failed then os.exit(1) end
print("ok " .. count .. " tests")
