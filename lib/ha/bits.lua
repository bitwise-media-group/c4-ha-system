-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.bits: band/bor/bxor with a pure-Lua fallback.
--
-- On the controller (LuaJIT, jit="1") the native bit library is used. The
-- fallback exists so the modules also run under plain Lua 5.1 -- which is what
-- CI pins as the test interpreter, deliberately exercising this path.

local ok, native = pcall(require, 'bit')
if ok and type(native) == 'table' and native.band then
	return { band = native.band, bor = native.bor, bxor = native.bxor }
end

-- Bit-by-bit on non-negative 32-bit integers: plenty for websocket framing.
local function bitop(a, b, op)
	local result, power = 0, 1
	while a > 0 or b > 0 do
		result = result + op(a % 2, b % 2) * power
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		power = power * 2
	end
	return result
end

return {
	band = function(a, b)
		return bitop(a, b, function(x, y)
			return (x == 1 and y == 1) and 1 or 0
		end)
	end,
	bor = function(a, b)
		return bitop(a, b, function(x, y)
			return (x == 1 or y == 1) and 1 or 0
		end)
	end,
	bxor = function(a, b)
		return bitop(a, b, function(x, y)
			return x ~= y and 1 or 0
		end)
	end,
}
