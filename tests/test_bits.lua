-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.bits tests: the pure-Lua fallback must match native semantics for the
-- byte/word ranges websocket framing uses. The fallback is forced even under
-- luajit by poisoning the bit loader before ha.bits is required.
package.path = 'lib/?.lua;tests/?.lua;' .. package.path
local stub = require('c4stub')

local native_ok, native = pcall(require, 'bit')
package.loaded['bit'] = nil
package.preload['bit'] = function()
	error('forced fallback for test')
end
local bits = require('ha.bits')

local check, check_eq = stub.check, stub.check_eq

if native_ok then
	check(bits.band ~= native.band, 'fallback engaged, not native')
end

-- fixed vectors covering websocket framing patterns
check_eq(bits.band(0x81, 0x80), 0x80, 'FIN bit extraction')
check_eq(bits.band(0x81, 0x0F), 0x01, 'opcode extraction')
check_eq(bits.band(0xFE, 0x7F), 0x7E, 'length extraction')
check_eq(bits.bor(0x80, 0x09), 0x89, 'FIN|opcode composition')
check_eq(bits.bor(0x80, 126), 0xFE, 'masked length composition')
check_eq(bits.bxor(0xAA, 0xFF), 0x55, 'mask xor')
check_eq(bits.bxor(0x00, 0x00), 0x00, 'zero xor')
check_eq(bits.bxor(0xFF, 0xFF), 0x00, 'self xor')
check_eq(bits.band(0, 0xFF), 0, 'zero band')
check_eq(bits.band(0xFFFFFFFF, 0x80000000), 0x80000000, '32-bit high band')

-- parity with native where available (luajit); native is signed 32-bit,
-- the fallback unsigned -- normalize both mod 2^32
if native_ok then
	math.randomseed(20260804)
	for _ = 1, 500 do
		local a = math.random(0, 2 ^ 31)
		local b = math.random(0, 2 ^ 31)
		check_eq(bits.band(a, b), native.band(a, b) % 2 ^ 32, 'band parity ' .. a .. '/' .. b)
		check_eq(bits.bor(a, b), native.bor(a, b) % 2 ^ 32, 'bor parity ' .. a .. '/' .. b)
		check_eq(bits.bxor(a, b), native.bxor(a, b) % 2 ^ 32, 'bxor parity ' .. a .. '/' .. b)
	end
end

stub.finish('test_bits')
