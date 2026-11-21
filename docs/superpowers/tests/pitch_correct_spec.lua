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

-- Tests appended by later tasks go above this line.
local failed = false
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then count = count + 1
  else failed = true; io.stderr:write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n") end
end
if failed then os.exit(1) end
print("ok " .. count .. " tests")
