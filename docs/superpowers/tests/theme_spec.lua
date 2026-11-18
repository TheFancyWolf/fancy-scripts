-- Theme tests. Run from the repo root: lua docs/superpowers/tests/theme_spec.lua
package.path = "_lib/?.lua;docs/superpowers/tests/?.lua;" .. package.path

local stub_lib = require("reaper_stub")

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Fresh stub installed as the global `reaper`, fresh library.
local function load_theme(opts)
  local stub = stub_lib.new(opts)
  reaper = stub.reaper
  package.loaded.theme = nil
  local Theme = require("theme")
  return Theme, stub
end

local function all(calls, name)
  local out = {}
  for _, c in ipairs(calls) do
    if c[1] == name then out[#out + 1] = c end
  end
  return out
end

local function count(calls, name) return #all(calls, name) end
local function first(calls, name) return all(calls, name)[1] end
local function last(calls, name)
  local list = all(calls, name)
  return list[#list]
end

local function contains(list, value) -- luacheck: ignore 211 (used by later tasks)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

-------------------------------------------------------------------------------
-- Runner
-------------------------------------------------------------------------------

local failures, total = 0, 0

local function test(name, fn)
  total = total + 1
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    print("ok    " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. "\n" .. tostring(err))
  end
end

-------------------------------------------------------------------------------
-- Task 1: fonts
-------------------------------------------------------------------------------

test("fonts: new API loads the bundled files", function()
  local T, stub = load_theme({})                      -- CreateFontFromFile present
  local fonts = T.create_fonts(nil)
  local n = count(stub.calls, "ImGui_CreateFontFromFile")
  assert(n == 8, "8 fonts from file, got " .. n)
  assert(first(stub.calls, "ImGui_CreateFontFromFile")[2]:match("_lib[/\\]fonts[/\\]FiraSans%-Regular%.otf$"))
  assert(T.font_source == "file")
  for _, k in ipairs({ "default", "small", "medium", "large", "header", "default_bold", "medium_bold", "large_bold", "tooltip" }) do
    assert(fonts[k] ~= nil, k)
  end
  assert(T._font_sizes[fonts.default] == 13 and T._font_sizes[fonts.small] == 11 and T._font_sizes[fonts.header] == 18)
end)

test("fonts: missing file falls back to the family, no error", function()
  local T, stub = load_theme({})
  T.font_dir = "/nonexistent/"
  T.create_fonts(nil)
  assert(count(stub.calls, "ImGui_CreateFontFromFile") == 0)
  assert(first(stub.calls, "ImGui_CreateFont")[2] == "Fira Sans")
  assert(T.font_source == "family")
end)

test("fonts: file load failing falls back, no error", function()
  local T = load_theme({ fail = { "ImGui_CreateFontFromFile" } })
  local fonts = T.create_fonts(nil)
  assert(fonts.default ~= nil and T.font_source == "family")
end)

test("fonts: family failing falls back to sans-serif", function()
  local T, stub = load_theme({ fail = { "ImGui_CreateFontFromFile", "ImGui_CreateFont:Fira Sans" } })
  T.create_fonts(nil)
  assert(T.font_source == "system")
  assert(last(stub.calls, "ImGui_CreateFont")[2]:match("^sans%-serif"))
end)

test("fonts: old ReaImGui without CreateFontFromFile still works", function()
  local T, stub = load_theme({ missing = { "ImGui_CreateFontFromFile" } })
  local fonts = T.create_fonts(nil)
  assert(fonts.default ~= nil and fonts.default_bold ~= nil)
  local c = first(stub.calls, "ImGui_CreateFont")
  assert(c[3] == 13, "old API passes the size as the second argument")
end)

-------------------------------------------------------------------------------

print(string.format("\n%d tests, %d failed", total, failures))
os.exit(failures == 0 and 0 or 1)
