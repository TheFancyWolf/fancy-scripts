-- Stubbed `reaper` table for the theme tests. See the plan, "The test stub".
-- return function new_stub(opts) -> stub
--   stub.reaper         the table to install as the global `reaper`
--   stub.calls          recorded calls, each { name, arg1, arg2, ... }
--   stub.enum_name(n)   enum integer -> function name
-- Draw-list rect/text calls also carry named fields (color, x1, y1, x2, y2).
-- opts: theme (REAPER theme key -> 0xRRGGBB), mode, missing, fail.

local M = {}

M.REAPERTIPS = {
  col_main_bg2 = 0x3E3E3E, col_tr1_bg = 0x424242, col_tr2_bg = 0x454545,
  col_main_text = 0xA0A0A0, col_tcp_text = 0xD9D9D9, col_cursor = 0x46B9FE,
  col_main_3dhl = 0x323232, col_buttonbg = 0x464646, col_main_editbk = 0x2A2A2A,
  docker_bg = 0x2D2D2D,
}

M.LIGHT = {
  col_main_bg2 = 0xE6E6E6, col_tr1_bg = 0xDADADA, col_tr2_bg = 0xD0D0D0,
  col_main_text = 0x202020, col_tcp_text = 0x303030, col_cursor = 0x1565C0,
  col_main_3dhl = 0xFFFFFF, col_buttonbg = 0xC8C8C8, col_main_editbk = 0xFFFFFF,
  docker_bg = 0xD0D0D0,
}

-- Return values for ImGui functions that widgets call. Extend as needed.
local RETURNS = {
  ImGui_Button = { false },
  ImGui_SmallButton = { false },
  ImGui_InvisibleButton = { false },
  ImGui_Checkbox = { false, false },
  ImGui_Selectable = { false },
  ImGui_CalcTextSize = { 40, 13 },
  ImGui_GetCursorScreenPos = { 0, 0 },
  ImGui_GetCursorPos = { 0, 0 },
  ImGui_GetCursorPosX = { 0 },
  ImGui_GetCursorPosY = { 0 },
  ImGui_GetContentRegionAvail = { 200, 100 },
  ImGui_GetWindowDrawList = { "drawlist" },
  ImGui_GetWindowSize = { 400, 300 },
  ImGui_GetWindowPos = { 0, 0 },
  ImGui_GetWindowWidth = { 400 },
  ImGui_GetItemRectMin = { 0, 0 },
  ImGui_GetItemRectMax = { 40, 20 },
  ImGui_GetItemRectSize = { 40, 20 },
  ImGui_GetMousePos = { 0, 0 },
  ImGui_IsItemHovered = { false },
  ImGui_IsItemActive = { false },
  ImGui_IsItemClicked = { false },
  ImGui_IsMouseHoveringRect = { false },
  ImGui_IsMouseClicked = { false },
  ImGui_IsMouseDown = { false },
  ImGui_GetFontSize = { 13 },
  ImGui_GetTextLineHeight = { 13 },
  ImGui_GetTextLineHeightWithSpacing = { 17 },
  ImGui_GetFrameHeight = { 21 },
  ImGui_GetTime = { 0 },
  ImGui_SetCursorPos = {},
  ImGui_SetCursorPosX = {},
  ImGui_SetCursorPosY = {},
  ImGui_SetCursorScreenPos = {},
  ImGui_SameLine = {},
  ImGui_Dummy = {},
  ImGui_Spacing = {},
  ImGui_Separator = {},
  ImGui_Text = {},
  ImGui_TextWrapped = {},
  ImGui_TextColored = {},
  ImGui_PushItemWidth = {},
  ImGui_PopItemWidth = {},
  ImGui_SetNextItemWidth = {},
  ImGui_PushID = {},
  ImGui_PopID = {},
  ImGui_Indent = {},
  ImGui_Unindent = {},
  ImGui_Attach = {},
  ImGui_SetTooltip = {},
  ImGui_BeginTooltip = { false },
  ImGui_EndTooltip = {},
  ImGui_BeginCombo = { false },
  ImGui_EndCombo = {},
  ImGui_SetItemDefaultFocus = {},
  ImGui_BeginDisabled = {},
  ImGui_EndDisabled = {},
  ImGui_CollapsingHeader = { false },
  ImGui_AlignTextToFramePadding = {},
  ImGui_PushTextWrapPos = {},
  ImGui_PopTextWrapPos = {},
  ImGui_SetMouseCursor = {},
  ImGui_MouseCursor_Hand = { 7 },
  ImGui_IsPopupOpen = { false },
  ImGui_DrawList_AddLine = {},
  ImGui_DrawList_AddCircle = {},
  ImGui_DrawList_AddCircleFilled = {},
  ImGui_DrawList_AddTriangleFilled = {},
  ImGui_DrawList_AddBezierCubic = {},
  ImGui_DrawList_PushClipRect = {},
  ImGui_DrawList_PopClipRect = {},
}

local ENUM_PATTERNS = { "^ImGui_Col_", "^ImGui_StyleVar_", "^ImGui_%w*Flags_", "^ImGui_Cond_" }

local function is_enum(name)
  for _, pat in ipairs(ENUM_PATTERNS) do
    if name:match(pat) then return true end
  end
  return false
end

local function list_has(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

function M.new(opts)
  opts = opts or {}
  local stub = { calls = {} }
  local ext = {}
  if opts.mode then ext["FancyScripts\0theme_mode"] = opts.mode end
  local enum_ids, enum_names, next_enum = {}, {}, 1000
  local theme_keys = opts.theme or {}
  local raw = {}
  local r

  local function record(name, ...)
    local call = { name, ... }
    stub.calls[#stub.calls + 1] = call
    return call
  end

  local function check_fail(name, first)
    if list_has(opts.fail, name) or (first ~= nil and list_has(opts.fail, name .. ":" .. tostring(first))) then
      error("stub: " .. name .. " failed", 0)
    end
  end

  function stub.enum_name(n) return enum_names[n] end

  local function enum_fn(name)
    return function()
      check_fail(name)
      if not enum_ids[name] then
        next_enum = next_enum + 1
        enum_ids[name] = next_enum
        enum_names[next_enum] = name
      end
      return enum_ids[name]
    end
  end

  -- extstate (the key is section and key joined)
  raw.GetExtState = function(section, key) return ext[section .. "\0" .. key] or "" end
  raw.SetExtState = function(section, key, value) ext[section .. "\0" .. key] = value end
  raw.HasExtState = function(section, key) return ext[section .. "\0" .. key] ~= nil end
  raw.DeleteExtState = function(section, key) ext[section .. "\0" .. key] = nil end
  -- theme
  raw.GetThemeColor = function(key)
    local v = theme_keys[key]
    if v == nil then return -1 end
    local rr, gg, bb = (v >> 16) & 255, (v >> 8) & 255, v & 255
    return rr | (gg << 8) | (bb << 16)  -- native colour, red in the low byte
  end
  raw.ColorFromNative = function(n)
    return n & 255, (n >> 8) & 255, (n >> 16) & 255
  end
  raw.ColorToNative = function(rr, gg, bb) return rr | (gg << 8) | (bb << 16) end

  -- recorded calls
  for _, name in ipairs({ "ImGui_PushStyleColor", "ImGui_PopStyleColor", "ImGui_PushStyleVar",
                          "ImGui_PopStyleVar", "ImGui_PushFont", "ImGui_PopFont" }) do
    raw[name] = function(...)
      record(name, select(2, ...))  -- drop ctx
      check_fail(name, (select(2, ...)))
    end
  end
  -- Draw-list calls keep the draw list as arg 1; named fields for convenience.
  raw.ImGui_DrawList_AddRectFilled = function(dl, x1, y1, x2, y2, color, ...)
    local c = record("ImGui_DrawList_AddRectFilled", dl, x1, y1, x2, y2, color, ...)
    c.x1, c.y1, c.x2, c.y2, c.color = x1, y1, x2, y2, color
    check_fail("ImGui_DrawList_AddRectFilled")
  end
  raw.ImGui_DrawList_AddRect = function(dl, x1, y1, x2, y2, color, ...)
    local c = record("ImGui_DrawList_AddRect", dl, x1, y1, x2, y2, color, ...)
    c.x1, c.y1, c.x2, c.y2, c.color = x1, y1, x2, y2, color
    check_fail("ImGui_DrawList_AddRect")
  end
  raw.ImGui_DrawList_AddText = function(dl, x, y, color, text, ...)
    local c = record("ImGui_DrawList_AddText", dl, x, y, color, text, ...)
    c.color = color
    check_fail("ImGui_DrawList_AddText")
  end
  -- fonts: each call returns a fresh object
  raw.ImGui_CreateFont = function(...)
    record("ImGui_CreateFont", ...)
    check_fail("ImGui_CreateFont", (...))
    return { font = (...) }
  end
  raw.ImGui_CreateFontFromFile = function(...)
    record("ImGui_CreateFontFromFile", ...)
    check_fail("ImGui_CreateFontFromFile", (...))
    return { file = (...) }
  end

  for name, rets in pairs(RETURNS) do
    raw[name] = function(...)
      check_fail(name, (select(2, ...)))
      return table.unpack(rets)
    end
  end

  for _, name in ipairs(opts.missing or {}) do raw[name] = false end

  r = setmetatable({}, {
    __index = function(t, name)
      local v = raw[name]
      if v == false then return nil end
      if v == nil then
        if type(name) == "string" and is_enum(name) then
          v = enum_fn(name)
        elseif type(name) == "string" and name:match("^ImGui_") then
          v = function() error("unstubbed: " .. name, 0) end
        else
          return nil
        end
      end
      rawset(t, name, v)
      return v
    end,
  })
  stub.reaper = r
  return stub
end

return M
