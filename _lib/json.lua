-- @noindex
-- Fancy Scripts — Shared JSON Library
-- Lightweight JSON encoder/decoder for REAPER Lua scripts.
-- Loaded via: local JSON = require("json")
--
-- Contract:
--   JSON.encode(v) returns a JSON string. NaN encodes as null; +/-inf are
--   clamped to +/-1.7976931348623157e308 (so e.g. -inf dB survives as a very
--   large negative number). Tables whose keys are exactly 1..n encode as
--   arrays; any other table encodes as an object with tostring()'d keys.
--   JSON.decode(s) returns the decoded value (nil for nil/empty input) and
--   raises error() on malformed input. Call it through pcall.
--   Object keys that are canonical integers ("1", "-3", not "01" or "1.0")
--   decode back to integer keys, so sparse/mixed Lua tables round-trip.
--   null decodes to nil (array positions are kept, so [1,null,3] gives
--   {1, nil, 3}).

local JSON = {}

-------------------------------------------------------------------------------
-- 1. ENCODER
-------------------------------------------------------------------------------
local MAX_DOUBLE = 1.7976931348623157e308

local ESC = {
  ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_char(c)
  return ESC[c] or string.format("\\u%04x", c:byte())
end

local function encode_number(v)
  if v ~= v then return "null" end
  if v == math.huge then v = MAX_DOUBLE elseif v == -math.huge then v = -MAX_DOUBLE end
  if math.type(v) == "integer" then return string.format("%d", v) end
  local s = string.format("%.14g", v)
  if tonumber(s) ~= v then s = string.format("%.17g", v) end
  return s
end

local function is_array(v)
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  for k in pairs(v) do
    if math.type(k) ~= "integer" or k < 1 or k > n then return false end
  end
  return true, n
end

function JSON.encode(v)
  local t = type(v)
  if t == "nil"     then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number"  then return encode_number(v) end
  if t == "string"  then
    return '"' .. v:gsub('[%c"\\]', function(c)
      if c == '\127' then return c end
      return escape_char(c)
    end) .. '"'
  end
  if t == "table" then
    local arr, n = is_array(v)
    if arr then
      local p = {}
      for i = 1, n do p[i] = JSON.encode(v[i]) end
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
local UNESC = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
                ['\\'] = '\\', ['"'] = '"', ['/'] = '/' }

function JSON.decode(s)
  if not s or s == "" then return nil end
  if type(s) ~= "string" then error("JSON.decode: expected string, got " .. type(s), 2) end
  local i = 1
  local len = #s

  local function fail(msg)
    error(string.format("JSON.decode: %s at position %d", msg, i), 0)
  end

  local function ws()
    i = s:find("[^ \t\r\n]", i) or (len + 1)
  end

  local function hex4()
    local h = s:match("^%x%x%x%x", i)
    if not h then fail("invalid \\u escape") end
    i = i + 4
    return tonumber(h, 16)
  end

  local function pstr()
    i = i + 1 -- opening quote
    local b = {}
    while true do
      local j = s:find('["\\\0-\31]', i)
      if not j then fail("unterminated string") end
      if j > i then b[#b + 1] = s:sub(i, j - 1) end
      i = j
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(b)
      elseif c == '\\' then
        local e = s:sub(i + 1, i + 1)
        i = i + 2
        if e == 'u' then
          local cp = hex4()
          if cp >= 0xD800 and cp <= 0xDBFF then
            if s:sub(i, i + 1) ~= "\\u" then fail("unpaired surrogate") end
            i = i + 2
            local lo = hex4()
            if lo < 0xDC00 or lo > 0xDFFF then fail("invalid surrogate pair") end
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          elseif cp >= 0xDC00 and cp <= 0xDFFF then
            fail("unpaired surrogate")
          end
          b[#b + 1] = utf8.char(cp)
        elseif UNESC[e] then
          b[#b + 1] = UNESC[e]
        else
          i = i - 1
          fail("invalid escape")
        end
      else
        fail("control character in string")
      end
    end
  end

  local parse

  local function parr()
    i = i + 1
    local a, n = {}, 0
    ws()
    if s:sub(i, i) == ']' then i = i + 1; return a end
    while true do
      n = n + 1
      a[n] = parse()
      ws()
      local c = s:sub(i, i)
      i = i + 1
      if c == ']' then return a end
      if c ~= ',' then i = i - 1; fail("expected ',' or ']'") end
    end
  end

  local function pobj()
    i = i + 1
    local o = {}
    ws()
    if s:sub(i, i) == '}' then i = i + 1; return o end
    while true do
      ws()
      if s:sub(i, i) ~= '"' then fail("expected string key") end
      local k = pstr()
      if k:match("^-?[1-9]%d*$") or k == "0" then
        local nk = math.tointeger(tonumber(k))
        if nk and tostring(nk) == k then k = nk end
      end
      ws()
      if s:sub(i, i) ~= ':' then fail("expected ':'") end
      i = i + 1
      o[k] = parse()
      ws()
      local c = s:sub(i, i)
      i = i + 1
      if c == '}' then return o end
      if c ~= ',' then i = i - 1; fail("expected ',' or '}'") end
    end
  end

  local function literal(word, value)
    if s:sub(i, i + #word - 1) ~= word then fail("invalid literal") end
    i = i + #word
    return value
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
      return literal("true", true)
    elseif c == 'f' then
      return literal("false", false)
    elseif c == 'n' then
      return literal("null", nil)
    elseif c == '' then
      fail("unexpected end of input")
    else
      local num = s:match('^-?%d+%.?%d*[eE][+-]?%d+', i) or s:match('^-?%d+%.?%d*', i)
      if not num then fail("unexpected character '" .. c .. "'") end
      local v = tonumber(num)
      if not v then fail("invalid number") end
      i = i + #num
      return v
    end
  end

  local result = parse()
  ws()
  if i <= len then fail("trailing garbage") end
  return result
end

return JSON
