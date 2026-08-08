-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.json: minimal JSON encoder/decoder for Lua 5.1 / LuaJIT.
-- No external dependencies; safe to vendor into a .c4z.

local json = {}

-- Sentinel for JSON null so it survives a decode/encode round trip
-- (plain nil would delete the key from a Lua table).
json.null = setmetatable({}, {
	__tostring = function()
		return 'null'
	end,
})

---------------------------------------------------------------- encode

local ESCAPES = {
	['"'] = '\\"',
	['\\'] = '\\\\',
	['\b'] = '\\b',
	['\f'] = '\\f',
	['\n'] = '\\n',
	['\r'] = '\\r',
	['\t'] = '\\t',
}

local function escape_char(c)
	return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
end

local function encode_string(s)
	return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode_number(n)
	if n ~= n or n == math.huge or n == -math.huge then
		error('cannot encode non-finite number')
	end
	if math.floor(n) == n and math.abs(n) < 2 ^ 53 then
		return string.format('%d', n)
	end
	return string.format('%.14g', n)
end

-- A table encodes as an array when its keys are exactly 1..n.
local function is_array(t)
	local count = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
			return false
		end
		count = count + 1
	end
	return count == #t, count
end

local encode_value

local function encode_table(t, seen)
	if seen[t] then
		error('cannot encode circular reference')
	end
	seen[t] = true

	local out = {}
	local array, count = is_array(t)
	if array and count > 0 then
		for _, v in ipairs(t) do
			out[#out + 1] = encode_value(v, seen)
		end
		seen[t] = nil
		return '[' .. table.concat(out, ',') .. ']'
	elseif count == 0 then
		-- Ambiguous empty table: encode as object, which is what every
		-- gateway<->HA message shape expects.
		seen[t] = nil
		return '{}'
	end

	for k, v in pairs(t) do
		local key = type(k) == 'string' and k or tostring(k)
		out[#out + 1] = encode_string(key) .. ':' .. encode_value(v, seen)
	end
	seen[t] = nil
	return '{' .. table.concat(out, ',') .. '}'
end

encode_value = function(v, seen)
	if v == json.null then
		return 'null'
	end
	local t = type(v)
	if t == 'nil' then
		return 'null'
	elseif t == 'boolean' then
		return v and 'true' or 'false'
	elseif t == 'number' then
		return encode_number(v)
	elseif t == 'string' then
		return encode_string(v)
	elseif t == 'table' then
		return encode_table(v, seen)
	end
	error('cannot encode value of type ' .. t)
end

-- Returns the JSON text, or nil + error message.
function json.encode(value)
	local ok, result = pcall(encode_value, value, {})
	if ok then
		return result
	end
	return nil, result
end

---------------------------------------------------------------- decode

local function decode_error(str, pos, message)
	error(string.format('%s at position %d (near %q)', message, pos, str:sub(pos, pos + 12)), 0)
end

local function skip_whitespace(str, pos)
	local _, last = str:find('^[ \t\r\n]*', pos)
	return last + 1
end

local function utf8_char(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	elseif code < 0x10000 then
		return string.char(
			0xE0 + math.floor(code / 0x1000),
			0x80 + math.floor(code / 0x40) % 0x40,
			0x80 + code % 0x40
		)
	end
	return string.char(
		0xF0 + math.floor(code / 0x40000),
		0x80 + math.floor(code / 0x1000) % 0x40,
		0x80 + math.floor(code / 0x40) % 0x40,
		0x80 + code % 0x40
	)
end

local STRING_ESCAPES = {
	['"'] = '"',
	['\\'] = '\\',
	['/'] = '/',
	b = '\b',
	f = '\f',
	n = '\n',
	r = '\r',
	t = '\t',
}

local function decode_string(str, pos)
	local out = {}
	local i = pos + 1 -- skip opening quote
	while true do
		local c = str:sub(i, i)
		if c == '' then
			decode_error(str, pos, 'unterminated string')
		elseif c == '"' then
			return table.concat(out), i + 1
		elseif c == '\\' then
			local esc = str:sub(i + 1, i + 1)
			if STRING_ESCAPES[esc] then
				out[#out + 1] = STRING_ESCAPES[esc]
				i = i + 2
			elseif esc == 'u' then
				local hex = str:sub(i + 2, i + 5)
				local code = tonumber(hex, 16)
				if not code or #hex < 4 then
					decode_error(str, i, 'invalid unicode escape')
				end
				i = i + 6
				if code >= 0xD800 and code <= 0xDBFF then
					-- surrogate pair
					local lo = tonumber(str:sub(i + 2, i + 5), 16)
					if str:sub(i, i + 1) == '\\u' and lo and lo >= 0xDC00 and lo <= 0xDFFF then
						code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
						i = i + 6
					else
						code = 0xFFFD -- unpaired surrogate
					end
				end
				out[#out + 1] = utf8_char(code)
			else
				decode_error(str, i, 'invalid escape sequence')
			end
		else
			-- consume a run of plain characters at once
			local last = str:find('["\\]', i)
			if not last then
				decode_error(str, pos, 'unterminated string')
			end
			out[#out + 1] = str:sub(i, last - 1)
			i = last
		end
	end
end

local function decode_number(str, pos)
	local numstr = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
	local n = tonumber(numstr)
	if not n then
		decode_error(str, pos, 'invalid number')
	end
	return n, pos + #numstr
end

local decode_value

local function decode_array(str, pos)
	local out = {}
	pos = skip_whitespace(str, pos + 1)
	if str:sub(pos, pos) == ']' then
		return out, pos + 1
	end
	while true do
		local value
		value, pos = decode_value(str, pos)
		out[#out + 1] = value
		pos = skip_whitespace(str, pos)
		local c = str:sub(pos, pos)
		if c == ']' then
			return out, pos + 1
		elseif c == ',' then
			pos = skip_whitespace(str, pos + 1)
		else
			decode_error(str, pos, "expected ',' or ']' in array")
		end
	end
end

local function decode_object(str, pos)
	local out = {}
	pos = skip_whitespace(str, pos + 1)
	if str:sub(pos, pos) == '}' then
		return out, pos + 1
	end
	while true do
		if str:sub(pos, pos) ~= '"' then
			decode_error(str, pos, 'expected string key in object')
		end
		local key, value
		key, pos = decode_string(str, pos)
		pos = skip_whitespace(str, pos)
		if str:sub(pos, pos) ~= ':' then
			decode_error(str, pos, "expected ':' in object")
		end
		pos = skip_whitespace(str, pos + 1)
		value, pos = decode_value(str, pos)
		out[key] = value
		pos = skip_whitespace(str, pos)
		local c = str:sub(pos, pos)
		if c == '}' then
			return out, pos + 1
		elseif c == ',' then
			pos = skip_whitespace(str, pos + 1)
		else
			decode_error(str, pos, "expected ',' or '}' in object")
		end
	end
end

decode_value = function(str, pos)
	local c = str:sub(pos, pos)
	if c == '"' then
		return decode_string(str, pos)
	elseif c == '{' then
		return decode_object(str, pos)
	elseif c == '[' then
		return decode_array(str, pos)
	elseif c == 't' and str:sub(pos, pos + 3) == 'true' then
		return true, pos + 4
	elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then
		return false, pos + 5
	elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then
		return json.null, pos + 4
	elseif c == '-' or c:match('%d') then
		return decode_number(str, pos)
	end
	decode_error(str, pos, 'unexpected character')
end

-- Returns the decoded value, or nil + error message.
function json.decode(str)
	if type(str) ~= 'string' then
		return nil, 'expected string, got ' .. type(str)
	end
	local ok, value, pos = pcall(function()
		local v, p = decode_value(str, skip_whitespace(str, 1))
		p = skip_whitespace(str, p)
		if p <= #str then
			decode_error(str, p, 'trailing garbage')
		end
		return v, p
	end)
	if ok then
		return value, pos
	end
	return nil, value
end

return json
