-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Gateway driver integration test: full session lifecycle against a
-- scripted Home Assistant, plus registration/routing and error paths.
package.path = 'lib/?.lua;tests/?.lua;' .. package.path
local stub = require('c4stub')
local json = require('ha.json')

local check, check_eq = stub.check, stub.check_eq
local bit = require('ha.bits')

local WS_BINDING, PORT = 6001, 8123

Properties = {
	['Host'] = 'ha.example.com',
	['Port'] = '8123',
	['Use SSL'] = 'Yes',
	['Verify Certificate'] = 'Yes',
	['Access Token'] = '',
	['Debug Mode'] = 'Off',
	['Status'] = '',
	['HA Version'] = '',
	['Driver Version'] = '',
}
stub.persist['access_token'] = 'test-token-xyz'

dofile('drivers/ha-gateway/driver.lua')

---------------------------------------------------------------- ws plumbing

local function server_frame(payload)
	local len = #payload
	if len < 126 then
		return string.char(0x81, len) .. payload
	elseif len < 65536 then
		return string.char(0x81, 126, math.floor(len / 256), len % 256) .. payload
	end
	local bytes = {}
	local rest = len
	for i = 8, 1, -1 do
		bytes[i] = rest % 256
		rest = math.floor(rest / 256)
	end
	return string.char(0x81, 127, unpack(bytes)) .. payload
end

-- Decodes every client frame captured since the last call; returns the
-- decoded JSON payloads.
local function drain_client_messages()
	local data = stub.network_data()
	stub.network_sent = {}
	local out = {}
	while #data >= 2 do
		local b2 = data:byte(2)
		local len = bit.band(b2, 0x7F)
		local pos = 3
		if len == 126 then
			len = data:byte(3) * 256 + data:byte(4)
			pos = 5
		elseif len == 127 then
			len = 0
			for i = 3, 10 do
				len = len * 256 + data:byte(i)
			end
			pos = 11
		end
		local mask = { data:byte(pos, pos + 3) }
		pos = pos + 4
		local chars = {}
		for i = 1, len do
			chars[i] = string.char(bit.bxor(data:byte(pos + i - 1), mask[(i - 1) % 4 + 1]))
		end
		out[#out + 1] = json.decode(table.concat(chars))
		data = data:sub(pos + len)
	end
	return out
end

local function ha_sends(message)
	ReceivedFromNetwork(WS_BINDING, PORT, server_frame(json.encode(message)))
end

---------------------------------------------------------------- lifecycle

OnDriverInit()
OnDriverLateInit()
check_eq(Properties['Access Token'], '**********', 'stored token masked on load')

stub.run_timers() -- reconfigure debounce -> Connect
check(stub.net_connection ~= nil, 'network connection created')
check_eq(stub.net_connection.kind, 'SSL', 'SSL used')
check_eq(stub.net_options.options.VERIFY_MODE, 'peer', 'peer verification')

OnConnectionStatusChanged(WS_BINDING, PORT, 'ONLINE')
local request = stub.network_data()
local ws_key = request:match('Sec%-WebSocket%-Key: ([^\r\n]+)')
stub.network_sent = {}
ReceivedFromNetwork(
	WS_BINDING,
	PORT,
	'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
		.. 'Connection: Upgrade\r\nSec-WebSocket-Accept: '
		.. C4:Hash('sha1', ws_key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11', {})
		.. '\r\n\r\n'
)
check_eq(Properties['Status'], 'Authenticating...', 'status while authenticating')

-- HA opens the conversation
ha_sends({ type = 'auth_required', ha_version = '2026.7.0' })
local sent = drain_client_messages()
check_eq(sent[1].type, 'auth', 'auth sent on auth_required')
check_eq(sent[1].access_token, 'test-token-xyz', 'token from encrypted persist')
check(sent[1].id == nil, 'auth carries no id')

ha_sends({ type = 'auth_ok', ha_version = '2026.7.0' })
sent = drain_client_messages()
check_eq(Properties['Status'], 'Connected', 'status connected')
check_eq(Properties['HA Version'], '2026.7.0', 'ha version surfaced')
check_eq(sent[1].type, 'get_config', 'get_config first after auth')
check_eq(#sent, 1, 'state sync waits for the config result')

-- the unit must be known before any state is pushed
ha_sends({
	id = sent[1].id,
	type = 'result',
	success = true,
	result = { unit_system = { temperature = '°C' } },
})
sent = drain_client_messages()
check_eq(sent[1].type, 'get_states', 'get_states after config')
check_eq(sent[2].type, 'subscribe_events', 'subscribe after config')
check_eq(sent[2].event_type, 'state_changed', 'subscribed to state_changed')
local get_states_id = sent[1].id
local subscribe_id = sent[2].id
check(get_states_id < subscribe_id, 'ids monotonic')

-- register a device before states arrive
ReceivedFromProxy(1, 'HA_REGISTER', { entity_id = 'cover.patio', device_id = '77' })
-- LOOP GUARD: a registration must never be answered with HA_CONNECTION --
-- devices re-register on connection messages, so an ack would close a
-- register->ack->register loop that floods Director until it crashes.
check(stub.last_device('HA_CONNECTION') == nil, 'registration NOT acked with HA_CONNECTION')

-- re-registering is idempotent and quiet (no state cached yet -> no reply)
local sends_before = #stub.device_sent
ReceivedFromProxy(1, 'HA_REGISTER', { entity_id = 'cover.patio', device_id = '77' })
check_eq(#stub.device_sent, sends_before, 'duplicate registration sends nothing')

-- a climate device registers too (seeded from get_states below)
ReceivedFromProxy(1, 'HA_REGISTER', { entity_id = 'climate.living', device_id = '88' })

-- states arrive: registered device gets its state, connection broadcast fires
stub.clear_captures()
ha_sends({
	id = get_states_id,
	type = 'result',
	success = true,
	result = {
		{
			entity_id = 'cover.patio',
			state = 'open',
			attributes = {
				supported_features = 15,
				current_position = 100,
				friendly_name = 'Patio Blind',
			},
		},
		{
			entity_id = 'cover.garage',
			state = 'closed',
			attributes = {
				supported_features = 11,
				device_class = 'garage',
				friendly_name = 'Garage Door',
			},
		},
		{
			entity_id = 'climate.living',
			state = 'heat_cool',
			attributes = {
				hvac_modes = { 'off', 'heat', 'cool', 'heat_cool' },
				fan_modes = { 'auto', 'low', 'high' },
				min_temp = 7,
				max_temp = 30,
				target_temp_step = 0.5,
				target_temp_low = 20,
				target_temp_high = 24,
				current_temperature = 21.5,
				temperature = json.null,
				hvac_action = 'idle',
				supported_features = 386,
				friendly_name = 'Living Room',
			},
		},
		{ entity_id = 'light.kitchen', state = 'on', attributes = {} },
	},
})
ha_sends({ id = subscribe_id, type = 'result', success = true })
local pushed
for _, entry in ipairs(stub.device_sent) do
	if entry.command == 'HA_STATE' and entry.device_id == 77 then
		pushed = entry
	end
end
check(pushed ~= nil, 'seed state pushed to device 77')
check_eq(pushed.params.entity_id, 'cover.patio', 'seed state entity')
check_eq(pushed.params.state, 'open', 'seed state flattened: state')
check_eq(pushed.params.position, 100, 'seed state flattened: position')
check_eq(pushed.params.supported_features, 15, 'seed state flattened: features')
check(pushed.params.json == nil, 'no JSON blob on the wire')
-- cover payload regression: exactly the historical key set, no climate keys
do
	local keys = {}
	for key in pairs(pushed.params) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	check_eq(
		table.concat(keys, ','),
		'entity_id,position,state,supported_features',
		'cover push carries exactly the historical keys'
	)
end

-- climate seed: whitelisted attrs flattened, lists as CSV, null omitted
local climate_pushed
for _, entry in ipairs(stub.device_sent) do
	if entry.command == 'HA_STATE' and entry.device_id == 88 then
		climate_pushed = entry
	end
end
check(climate_pushed ~= nil, 'seed state pushed to climate device 88')
local cp = climate_pushed.params
check_eq(cp.state, 'heat_cool', 'climate state pushed')
check_eq(cp.hvac_modes, 'off,heat,cool,heat_cool', 'hvac_modes flattened to CSV')
check_eq(cp.fan_modes, 'auto,low,high', 'fan_modes flattened to CSV')
check_eq(cp.target_temp_low, 20, 'target_temp_low as number')
check_eq(cp.target_temp_high, 24, 'target_temp_high as number')
check_eq(cp.min_temp, 7, 'min_temp as number')
check_eq(cp.max_temp, 30, 'max_temp as number')
check_eq(cp.target_temp_step, 0.5, 'target_temp_step as number')
check_eq(cp.current_temperature, 21.5, 'current_temperature as number')
check_eq(cp.hvac_action, 'idle', 'hvac_action string kept')
check(cp.temperature == nil, 'JSON null temperature omitted')
check_eq(cp.temperature_unit, 'C', 'server unit injected from get_config')
check(cp.friendly_name == nil, 'non-whitelisted attribute dropped')
for key, value in pairs(cp) do
	check(type(value) ~= 'table', 'climate param ' .. key .. ' is a flat scalar')
end
local broadcast = stub.last_proxy('HA_CONNECTION', 1)
check(
	broadcast ~= nil and broadcast.params.connected == 'true',
	'connection broadcast over binding'
)
check_eq(stub.variables['CONNECTED'], 'true', 'CONNECTED variable set')
check_eq(stub.events_fired[#stub.events_fired], 'Home Assistant Connected', 'connected event fired')

---------------------------------------------------------------- routing

-- state_changed for a registered entity routes only to its device
stub.clear_captures()
ha_sends({
	id = subscribe_id,
	type = 'event',
	event = {
		event_type = 'state_changed',
		data = {
			entity_id = 'cover.patio',
			new_state = {
				entity_id = 'cover.patio',
				state = 'closing',
				attributes = {
					supported_features = 15,
					current_position = 60,
					friendly_name = 'Patio Blind',
				},
			},
		},
	},
})
pushed = stub.last_device('HA_STATE')
check(pushed ~= nil and pushed.device_id == 77, 'event routed to registered device')
check_eq(pushed.params.state, 'closing', 'event payload flattened')
check_eq(pushed.params.position, 60, 'event position flattened')

-- unregistered entity events route nowhere
stub.clear_captures()
ha_sends({
	id = subscribe_id,
	type = 'event',
	event = {
		event_type = 'state_changed',
		data = {
			entity_id = 'light.kitchen',
			new_state = { entity_id = 'light.kitchen', state = 'off', attributes = {} },
		},
	},
})
check(stub.last_device('HA_STATE') == nil, 'unregistered entity not routed')

---------------------------------------------------------------- entity list

stub.clear_captures()
ReceivedFromProxy(1, 'HA_LIST_ENTITIES', { domain = 'cover', device_id = '77' })
local listed = stub.last_device('HA_ENTITY_LIST')
check(listed ~= nil, 'entity list answered')
check_eq(listed.params.entities, 'cover.garage,cover.patio', 'sorted csv, cover domain only')

---------------------------------------------------------------- service call

-- flat params in (as they arrive over the binding: everything stringly)
stub.clear_captures()
ReceivedFromProxy(1, 'HA_CALL_SERVICE', {
	domain = 'cover',
	service = 'set_cover_position',
	position = '25',
	entity_id = 'cover.patio',
})
sent = drain_client_messages()
check_eq(sent[1].type, 'call_service', 'service call forwarded')
check_eq(sent[1].service, 'set_cover_position', 'service name kept')
check_eq(sent[1].service_data.position, 25, 'position coerced to number')
check_eq(sent[1].target.entity_id, 'cover.patio', 'target entity set')
check(sent[1].id ~= nil, 'service call has an id')

-- open_cover carries no service_data at all
stub.clear_captures()
ReceivedFromProxy(1, 'HA_CALL_SERVICE', {
	domain = 'cover',
	service = 'open_cover',
	entity_id = 'cover.patio',
})
sent = drain_client_messages()
check(sent[1].service_data == nil, 'no empty service_data object')

-- climate range setpoints: both bounds coerced to numbers in the JSON
stub.clear_captures()
ReceivedFromProxy(1, 'HA_CALL_SERVICE', {
	domain = 'climate',
	service = 'set_temperature',
	entity_id = 'climate.living',
	target_temp_low = '21',
	target_temp_high = '24',
})
sent = drain_client_messages()
check_eq(sent[1].service_data.target_temp_low, 21, 'target_temp_low coerced to number')
check_eq(sent[1].service_data.target_temp_high, 24, 'target_temp_high coerced to number')
check_eq(sent[1].target.entity_id, 'climate.living', 'climate target entity set')
check(sent[1].service_data.domain == nil, 'domain never leaks into service_data')
check(sent[1].service_data.service == nil, 'service never leaks into service_data')
check(sent[1].service_data.entity_id == nil, 'entity_id never leaks into service_data')

-- string service fields survive (previously silently dropped)
stub.clear_captures()
ReceivedFromProxy(1, 'HA_CALL_SERVICE', {
	domain = 'climate',
	service = 'set_hvac_mode',
	entity_id = 'climate.living',
	hvac_mode = 'heat_cool',
})
sent = drain_client_messages()
check_eq(sent[1].service_data.hvac_mode, 'heat_cool', 'hvac_mode string survives')

stub.clear_captures()
ReceivedFromProxy(1, 'HA_CALL_SERVICE', {
	domain = 'climate',
	service = 'set_fan_mode',
	entity_id = 'climate.living',
	fan_mode = 'low',
})
sent = drain_client_messages()
check_eq(sent[1].service_data.fan_mode, 'low', 'fan_mode string survives')

stub.clear_captures()
ReceivedFromProxy(1, 'HA_CALL_SERVICE', {
	domain = 'climate',
	service = 'set_preset_mode',
	entity_id = 'climate.living',
	preset_mode = 'eco',
})
sent = drain_client_messages()
check_eq(sent[1].service_data.preset_mode, 'eco', 'preset_mode string survives')

-- a failed result is tolerated (logged, no crash)
ha_sends({
	id = sent[1].id,
	type = 'result',
	success = false,
	error = { code = 'not_found', message = 'Entity not found' },
})

---------------------------------------------------------------- programming

stub.clear_captures()
ExecuteCommand('Call Service', {
	['Service'] = 'cover.open_cover',
	['Entity ID'] = 'cover.patio',
	['Data'] = '',
})
sent = drain_client_messages()
check_eq(sent[1].domain, 'cover', 'programming command domain')
check_eq(sent[1].service, 'open_cover', 'programming command service')
check_eq(sent[1].target.entity_id, 'cover.patio', 'programming command target')

---------------------------------------------------------------- unregister

ReceivedFromProxy(1, 'HA_UNREGISTER', { entity_id = 'cover.patio', device_id = '77' })
stub.clear_captures()
ha_sends({
	id = subscribe_id,
	type = 'event',
	event = {
		event_type = 'state_changed',
		data = {
			entity_id = 'cover.patio',
			new_state = { entity_id = 'cover.patio', state = 'open', attributes = {} },
		},
	},
})
check(stub.last_device('HA_STATE') == nil, 'unregistered device no longer routed')

---------------------------------------------------------------- auth failure

-- reconnect and fail auth: no retry until the token changes
stub.clear_captures()
ExecuteCommand('Disconnect', {})
check(Properties['Status']:find('by user', 1, true) ~= nil, 'user disconnect status')
ExecuteCommand('Connect', {})
OnConnectionStatusChanged(WS_BINDING, PORT, 'ONLINE')
request = stub.network_data()
ws_key = request:match('Sec%-WebSocket%-Key: ([^\r\n]+)')
stub.network_sent = {}
ReceivedFromNetwork(
	WS_BINDING,
	PORT,
	'HTTP/1.1 101 x\r\nSec-WebSocket-Accept: '
		.. C4:Hash('sha1', ws_key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11', {})
		.. '\r\n\r\n'
)
ha_sends({ type = 'auth_required' })
drain_client_messages()
ha_sends({ type = 'auth_invalid', message = 'Invalid access token' })
check(
	Properties['Status']:find('token rejected', 1, true) ~= nil,
	'auth failure surfaced in status'
)
stub.run_timers()
check(stub.net_connected == nil, 'no reconnect after auth failure')

---------------------------------------------------------------- connect watchdog

-- WEDGE GUARD: Director does not reliably fire OnConnectionStatusChanged for
-- an SSL NetConnect that never establishes (e.g. HA mid-restart).  Without a
-- watchdog the driver sat in 'Connecting...' forever with no timer pending,
-- needing a manual Disconnect/Connect.  The connect timeout must tear the
-- attempt down and schedule a fresh one.
ExecuteCommand('Connect', {})
check(stub.net_connected ~= nil, 'connect attempt started')
check_eq(Properties['Status'], 'Connecting...', 'status while connecting')

-- No OCS callback ever arrives; the connect watchdog fires.
stub.run_timers()
check(Properties['Status']:find('timed out', 1, true) ~= nil, 'stalled connect surfaced as timeout')
check(stub.net_connected == nil, 'stalled attempt torn down')

-- The backoff reconnect timer was armed by the watchdog; it retries.
stub.run_timers()
check(stub.net_connected ~= nil, 'reconnect attempted after stalled connect')

-- This attempt succeeds: the watchdog must be disarmed once the socket opens,
-- so firing remaining timers must not tear the session down.
OnConnectionStatusChanged(WS_BINDING, PORT, 'ONLINE')
request = stub.network_data()
ws_key = request:match('Sec%-WebSocket%-Key: ([^\r\n]+)')
stub.network_sent = {}
ReceivedFromNetwork(
	WS_BINDING,
	PORT,
	'HTTP/1.1 101 x\r\nSec-WebSocket-Accept: '
		.. C4:Hash('sha1', ws_key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11', {})
		.. '\r\n\r\n'
)
ha_sends({ type = 'auth_required' })
drain_client_messages()
ha_sends({ type = 'auth_ok', ha_version = '2026.8.1' })
check_eq(Properties['Status'], 'Connected', 'reconnected after stalled attempt')

stub.finish('test_gateway')
