-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Cover driver tests: registration, capability sync from supported_features,
-- HA state -> blind proxy notifications, proxy commands -> HA services,
-- positionless (garage) and tilt-only variants.
package.path = 'lib/?.lua;tests/?.lua;' .. package.path
local stub = require('c4stub')

local check, check_eq = stub.check, stub.check_eq

local BLIND, HUB = 5001, 999

Properties = {
	['Entity ID'] = 'cover.patio',
	['Entity Selector'] = '',
	['Travel Time (seconds)'] = '20',
	['Debug Mode'] = 'Off',
	['Cover State'] = '',
	['Device Class'] = '',
	['Current Position'] = '',
	['Supported Features'] = '',
	['Driver Version'] = '',
}

dofile('drivers/ha-cover/driver.lua')

-- Flat HA_STATE params, values stringified as they would be over the binding.
local function ha_state_for(entity, state, attributes)
	attributes = attributes or {}
	local params = { entity_id = entity, state = state }
	for _, field in ipairs({
		'position',
		'tilt_position',
		'device_class',
		'supported_features',
	}) do
		if attributes[field] ~= nil then
			params[field] = tostring(attributes[field])
		end
	end
	ExecuteCommand('HA_STATE', params)
end

local function ha_state(state, attributes)
	ha_state_for('cover.patio', state, attributes)
end

local function last_service()
	local entry = stub.last_proxy('HA_CALL_SERVICE', HUB)
	if not entry then
		return nil
	end
	return entry.params
end

---------------------------------------------------------------- registration

OnDriverLateInit()
local reg = stub.last_proxy('HA_REGISTER', HUB)
check(reg ~= nil, 'registers on late init')
check_eq(reg.params.entity_id, 'cover.patio', 'registers configured entity')
check_eq(reg.params.device_id, 42, 'registers own device id')
check(stub.last_proxy('HA_LIST_ENTITIES', HUB) ~= nil, 'requests entity list')

---------------------------------------------------------------- positional cover

-- full-featured blind: OPEN|CLOSE|SET_POSITION|STOP = 15
stub.clear_captures()
ha_state('open', { supported_features = 15, position = 100, device_class = 'blind' })

local has_level = stub.last_proxy('SET_HAS_LEVEL', BLIND)
check(has_level ~= nil, 'capabilities sent on first state')
check_eq(has_level.params.LEVEL_OPEN, 100, 'positional open level 100')
check_eq(has_level.params.LEVEL_DISCRETE_CONTROL, true, 'discrete control on')
check_eq(
	stub.last_proxy('SET_CAN_STOP', BLIND).params.SET_CAN_STOP,
	true,
	'stop capability from feature bit'
)
-- SET_TYPE is deliberately never sent (crashes Composer's blind panel);
-- device_class only surfaces as a read-only property
check(stub.last_proxy('SET_TYPE', BLIND) == nil, 'no SET_TYPE notification')
check_eq(Properties['Device Class'], 'blind', 'device_class surfaced as property')
local stopped = stub.last_proxy('STOPPED', BLIND)
check_eq(stopped.params.LEVEL, 100, 'open state -> STOPPED at 100')
check_eq(Properties['Cover State'], 'open', 'state property updated')
check_eq(Properties['Current Position'], '100', 'position property updated')

-- closing from HA (external control): MOVING toward closed
stub.clear_captures()
ha_state('closing', { supported_features = 15, position = 100, device_class = 'blind' })
local moving = stub.last_proxy('MOVING', BLIND)
check(moving ~= nil, 'closing -> MOVING')
check_eq(moving.params.LEVEL_TARGET, 0, 'closing targets closed level')
check_eq(moving.params.LEVEL, 100, 'MOVING reports start level')
check_eq(moving.params.RAMP_RATE, 20000, 'ramp = travel time * full distance')

stub.clear_captures()
ha_state('closed', { supported_features = 15, position = 0, device_class = 'blind' })
check_eq(stub.last_proxy('STOPPED', BLIND).params.LEVEL, 0, 'closed -> STOPPED 0')

-- no duplicate capability spam when features unchanged
check(stub.last_proxy('SET_HAS_LEVEL', BLIND) == nil, 'capabilities not re-sent for same features')

---------------------------------------------------------------- proxy commands

stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '100' })
check_eq(last_service().service, 'open_cover', 'target 100 -> open_cover')
check(stub.last_proxy('MOVING', BLIND) ~= nil, 'optimistic MOVING on command')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '0' })
check_eq(last_service().service, 'close_cover', 'target 0 -> close_cover')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '40' })
local call = last_service()
check_eq(call.service, 'set_cover_position', 'mid target -> set position')
check_eq(call.position, 40, 'position value passed flat')
check_eq(call.entity_id, 'cover.patio', 'service targets entity')
moving = stub.last_proxy('MOVING', BLIND)
check_eq(moving.params.LEVEL_TARGET, 40, 'optimistic MOVING to target')
check_eq(moving.params.RAMP_RATE, 8000, 'ramp proportional to distance (40/100)')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'STOP', {})
check_eq(last_service().service, 'stop_cover', 'STOP -> stop_cover')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'UP', {})
check_eq(last_service().service, 'open_cover', 'UP -> open_cover')
ReceivedFromProxy(BLIND, 'DOWN', {})
check_eq(last_service().service, 'close_cover', 'DOWN -> close_cover')

-- settle timer forces STOPPED if HA never confirms
stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '100' })
stub.run_timers()
check(stub.last_proxy('STOPPED', BLIND) ~= nil, 'settle timer forces STOPPED')

---------------------------------------------------------------- unavailable

stub.clear_captures()
ha_state('unavailable', { supported_features = 15 })
check_eq(stub.last_proxy('STOPPED', BLIND).params.LEVEL, -1, 'unavailable -> level unknown')

---------------------------------------------------------------- entity list

ExecuteCommand('HA_ENTITY_LIST', {
	domain = 'cover',
	entities = 'cover.garage,cover.patio',
})
check_eq(
	stub.property_lists['Entity Selector'],
	',cover.garage,cover.patio',
	'selector list populated with blank first entry'
)

---------------------------------------------------------------- reconnect

stub.clear_captures()
ExecuteCommand('HA_CONNECTION', { connected = 'true' }) -- transition: disconnected -> connected
check(stub.last_proxy('HA_REGISTER', HUB) ~= nil, 'first connected=true registers')

stub.clear_captures()
ExecuteCommand('HA_CONNECTION', { connected = 'false' })
check_eq(stub.last_proxy('STOPPED', BLIND).params.LEVEL, -1, 'gateway loss -> level unknown')
ExecuteCommand('HA_CONNECTION', { connected = 'true' })
check(stub.last_proxy('HA_REGISTER', HUB) ~= nil, 're-registers on reconnect')

-- LOOP GUARD: repeated connection messages with the same state must be
-- ignored -- reacting to every one (not just transitions) closed a
-- register->ack->register loop with the gateway that crashed Director.
stub.clear_captures()
ExecuteCommand('HA_CONNECTION', { connected = 'true' })
ExecuteCommand('HA_CONNECTION', { connected = 'true' })
check(stub.last_proxy('HA_REGISTER', HUB) == nil, 'repeated connected=true ignored')

---------------------------------------------------------------- garage door

-- switch entity: open/close/stop only (11), no position
ha_state('closed', { supported_features = 11, device_class = 'garage' })

stub.clear_captures()
Properties['Entity ID'] = 'cover.garage'
OnPropertyChanged('Entity ID')
-- property reactions are deferred out of the Composer callback
check(stub.last_proxy('HA_REGISTER', HUB) == nil, 'entity change deferred past the callback')
stub.run_timers()
check(stub.last_proxy('HA_UNREGISTER', HUB) ~= nil, 'entity change unregisters old')
reg = stub.last_proxy('HA_REGISTER', HUB)
check_eq(reg.params.entity_id, 'cover.garage', 'entity change registers new')

stub.clear_captures()
ha_state_for('cover.garage', 'closed', { supported_features = 11, device_class = 'garage' })
has_level = stub.last_proxy('SET_HAS_LEVEL', BLIND)
check_eq(has_level.params.LEVEL_OPEN, 2, 'positionless+stop -> open level 2')
check_eq(has_level.params.LEVEL_DISCRETE_CONTROL, false, 'no discrete control')
check_eq(Properties['Device Class'], 'garage', 'garage device_class surfaced')
check_eq(stub.last_proxy('STOPPED', BLIND).params.LEVEL, 0, 'closed at level 0')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '2' })
check_eq(last_service().service, 'open_cover', 'garage target 2 -> open_cover')
check(last_service().position == nil, 'no position for garage')

---------------------------------------------------------------- tilt-only

stub.clear_captures()
Properties['Entity ID'] = 'cover.louver'
OnPropertyChanged('Entity ID')
stub.run_timers()
ha_state_for('cover.louver', 'open', { supported_features = 240, tilt_position = 75 })
has_level = stub.last_proxy('SET_HAS_LEVEL', BLIND)
check_eq(has_level.params.LEVEL_OPEN, 100, 'tilt-only with set position -> 0-100')
check_eq(stub.last_proxy('STOPPED', BLIND).params.LEVEL, 75, 'tilt position drives level')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '30' })
call = last_service()
check_eq(call.service, 'set_cover_tilt_position', 'tilt-only mid target')
check_eq(call.tilt_position, 30, 'tilt_position key used flat')

stub.clear_captures()
ReceivedFromProxy(BLIND, 'SET_LEVEL_TARGET', { LEVEL_TARGET = '100' })
check_eq(last_service().service, 'open_cover_tilt', 'tilt-only open')
ReceivedFromProxy(BLIND, 'STOP', {})
check_eq(last_service().service, 'stop_cover_tilt', 'tilt-only stop')

---------------------------------------------------------------- selector

-- Picking from the dropdown must do nothing inside the callback (Composer is
-- still processing the selection there) and everything on the deferred timer.
stub.clear_captures()
Properties['Entity Selector'] = 'cover.patio'
OnPropertyChanged('Entity Selector')
check(stub.last_proxy('HA_REGISTER', HUB) == nil, 'selector reaction deferred')
check_eq(#stub.properties_updated, 0, 'no property writes inside the callback')
stub.run_timers()
check_eq(Properties['Entity ID'], 'cover.patio', 'selector pick lands in Entity ID')
reg = stub.last_proxy('HA_REGISTER', HUB)
check_eq(reg.params.entity_id, 'cover.patio', 'selector pick registers')
check_eq(Properties['Entity Selector'], '', 'selector reset after apply')

stub.finish('test_cover')
