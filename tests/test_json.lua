-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- JSON codec round-trip and edge-case tests.
package.path = 'lib/?.lua;tests/?.lua;' .. package.path
local stub = require('c4stub')
local json = require('ha.json')

local check, check_eq = stub.check, stub.check_eq

-- primitives
check_eq(json.encode(true), 'true', 'encode true')
check_eq(json.encode(json.null), 'null', 'encode null')
check_eq(json.encode(42), '42', 'encode int')
check_eq(json.encode(2.5), '2.5', 'encode float')
check_eq(json.encode('hi'), '"hi"', 'encode string')
check_eq(json.encode('a"b\\c\n'), '"a\\"b\\\\c\\n"', 'encode escapes')

-- containers
check_eq(json.encode({ 1, 2, 3 }), '[1,2,3]', 'encode array')
check_eq(json.encode({}), '{}', 'empty table is object')
check_eq(json.encode({ a = 1 }), '{"a":1}', 'encode object')

-- decode primitives
check_eq(json.decode('true'), true, 'decode true')
check_eq(json.decode('null'), json.null, 'decode null')
check_eq(json.decode('-12.5e2'), -1250, 'decode scientific')
check_eq(json.decode('"a\\u0041b"'), 'aAb', 'decode unicode escape')
check_eq(json.decode('"\\ud83d\\ude00"'), '\240\159\152\128', 'surrogate pair -> emoji')

-- structures
local obj = json.decode(
	'{"entity_id":"cover.x","attributes":{"current_position":57,"supported_features":15},"state":"open"}'
)
check_eq(obj.entity_id, 'cover.x', 'decode nested string')
check_eq(obj.attributes.current_position, 57, 'decode nested number')
check_eq(obj.state, 'open', 'decode sibling key')

local arr = json.decode('[{"a":1},{"a":2}]')
check_eq(#arr, 2, 'decode array of objects')
check_eq(arr[2].a, 2, 'decode array element')

-- whitespace tolerance
check_eq(json.decode('  { "a" : [ 1 , 2 ] } ').a[2], 2, 'whitespace tolerated')

-- round trip
local original = {
	id = 5,
	type = 'call_service',
	domain = 'cover',
	service = 'set_cover_position',
	service_data = { position = 40 },
	target = { entity_id = 'cover.living_room' },
}
local decoded = json.decode(json.encode(original))
check_eq(decoded.service_data.position, 40, 'round trip nested number')
check_eq(decoded.target.entity_id, 'cover.living_room', 'round trip nested string')

-- null round trip keeps the key
local with_null = json.decode('{"new_state":null}')
check(with_null.new_state == json.null, 'null survives decode as sentinel')
check_eq(json.encode(with_null), '{"new_state":null}', 'null survives encode')

-- errors return nil, message
check(json.decode('{"a":') == nil, 'truncated input fails')
check(json.decode('{"a":1}garbage') == nil, 'trailing garbage fails')
check(json.decode('{a:1}') == nil, 'unquoted key fails')
check(select(2, json.decode('')) ~= nil, 'error message provided')
check(json.encode(function() end) == nil, 'unencodable type fails')
local circular = {}
circular.self = circular
check(json.encode(circular) == nil, 'circular reference fails')

stub.finish('test_json')
