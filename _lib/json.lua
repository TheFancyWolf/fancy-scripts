-- Fancy Scripts — Shared JSON Library
-- Lightweight JSON encoder/decoder for REAPER Lua scripts.
-- Loaded via: local JSON = require("json")

local JSON = {}

-------------------------------------------------------------------------------
-- 1. ENCODER
-------------------------------------------------------------------------------
function JSON.encode(v)
  local t = type(v)
  if t == "nil"     then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number"  then
    if v ~= v then return "null" end
    return string.format("%.10g", v)
  end
  if t == "string"  then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"')
                   :gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
  end
  if t == "table" then
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == #v then
      local p = {}
      for i, x in ipairs(v) do p[i] = JSON.encode(x) end
      return "[" .. table.concat(p, ",") .. "]"
    else
      local p = {}
      for k, x in pairs(v) do
        p[#p + 1] = JSON.encode(tostring(k)) .. ":" .. JSON.encode(x)
      end
      table.sort(p)
      return "{" .. table.concat(p, ",") .. "}"
    end
  end
  return "null"
end

-------------------------------------------------------------------------------
-- 2. DECODER
-------------------------------------------------------------------------------
function JSON.decode(s)
  if not s or s == "" then return nil end
  local i = 1
  local function ws()
    while i <= #s and s:sub(i, i):match('%s') do i = i + 1 end
  end
  local parse
  local function pstr()
    i = i + 1
    local b = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1
        break
      elseif c == '\\' then
        i = i + 1
        c = s:sub(i, i)
        local e = { n = '\n', r = '\r', t = '\t', ['\\'] = '\\', ['"'] = '"', ['/'] = '/' }
        b[#b + 1] = e[c] or c
      else
        b[#b + 1] = c
      end
      i = i + 1
    end
    return table.concat(b)
  end

  local function parr()
    i = i + 1
    local a = {}
    ws()
    if s:sub(i, i) == ']' then i = i + 1; return a end
    repeat
      ws()
      a[#a + 1] = parse()
      ws()
      local c = s:sub(i, i)
      i = i + 1
    until c ~= ','
    return a
  end

  local function pobj()
    i = i + 1
    local o = {}
    ws()
    if s:sub(i, i) == '}' then i = i + 1; return o end
    repeat
      ws()
      local k = pstr()
      ws()
      i = i + 1
      ws()
      o[k] = parse()
      ws()
      local c = s:sub(i, i)
      i = i + 1
    until c ~= ','
    return o
  end

  parse = function()
    ws()
    local c = s:sub(i, i)
    if c == '"' then
      return pstr()
    elseif c == '[' then
      return parr()
    elseif c == '{' then
      return pobj()
    elseif c == 't' then
      i = i + 4
      return true
    elseif c == 'f' then
      i = i + 5
      return false
    elseif c == 'n' then
      i = i + 4
      return nil
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
      if num then
        i = i + #num
        return tonumber(num)
      end
    end
  end

  return parse()
end

return JSON
