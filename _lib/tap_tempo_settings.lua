-------------------------------------------------------------------------------
-- Fancy Scripts -- Tap Tempo settings (shared by the tap action and its
-- settings window). DEFAULTS is the single source of truth.
-------------------------------------------------------------------------------

local S = {}

S.EXT = "FancyTapTempoSlew"

S.DEFAULTS = {
  mode            = "instant", -- "instant" | "glide"
  glide_rate      = 10,        -- BPM per second (glide mode)
  taps_per_change = 4,
  update          = "group",   -- "group" | "rolling"
  restart_gap     = 2.0,       -- seconds
  min_bpm         = 30,
  max_bpm         = 300,
}

S.RANGES = {
  glide_rate      = { 0.5, 100 },
  taps_per_change = { 2, 16 },
  restart_gap     = { 0.5, 10 },
  min_bpm         = { 20, 959 },
  max_bpm         = { 21, 960 },
}

local CHOICES = {
  mode   = { instant = true, glide = true },
  update = { group = true, rolling = true },
}

S.KEYS = { "mode", "glide_rate", "taps_per_change", "update",
           "restart_gap", "min_bpm", "max_bpm" }

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

--- Reads every setting; invalid or missing values fall back to DEFAULTS.
--- @return table settings, boolean had_invalid
function S.load()
  local s, bad = {}, false
  for _, key in ipairs(S.KEYS) do
    local raw = reaper.GetExtState(S.EXT, key)
    local def = S.DEFAULTS[key]
    if raw == "" then
      s[key] = def
    elseif CHOICES[key] then
      if CHOICES[key][raw] then s[key] = raw else s[key], bad = def, true end
    else
      local n = tonumber(raw)
      if n then
        local r = S.RANGES[key]
        s[key] = clamp(n, r[1], r[2])
        if key == "taps_per_change" then s[key] = math.floor(s[key] + 0.5) end
      else
        s[key], bad = def, true
      end
    end
  end
  if s.min_bpm > s.max_bpm - 1 then
    s.min_bpm, s.max_bpm, bad = S.DEFAULTS.min_bpm, S.DEFAULTS.max_bpm, true
  end
  return s, bad
end

--- Persists one setting.
function S.save(key, value)
  reaper.SetExtState(S.EXT, key, tostring(value), true)
end

--- Clears every saved setting so DEFAULTS apply.
function S.reset_all()
  for _, key in ipairs(S.KEYS) do
    reaper.DeleteExtState(S.EXT, key, true)
  end
end

return S
