-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Climate driver tests: registration, HA state -> thermostatV2 notifications
-- with change detection, heat_cool range commands, mode/action mapping, fan,
-- humidity, presets via Extras, unit handling, and the Director-crash
-- invariants shared with the cover driver.
package.path = 'lib/?.lua;tests/?.lua;' .. package.path
local stub = require('c4stub')

local check, check_eq = stub.check, stub.check_eq

local THERMO, HUB = 5001, 999

Properties = {
	['Entity ID'] = 'climate.living',
	['Entity Selector'] = '',
	['Debug Mode'] = 'Off',
	['Climate State'] = '',
	['HVAC Action'] = '',
	['Current Temperature'] = '',
	['Setpoints'] = '',
	['HVAC Modes'] = '',
	['Driver Version'] = '',
}

dofile('drivers/ha-climate/driver.lua')

-- Flat HA_STATE params, values stringified as they would be over the binding.
local function ha_state_for(entity, state, attributes)
	local params = { entity_id = entity, state = state }
	for field, value in pairs(attributes or {}) do
		params[field] = tostring(value)
	end
	ExecuteCommand('HA_STATE', params)
end

local function ha_state(state, attributes)
	ha_state_for('climate.living', state, attributes)
end

local function with(base, overrides)
	local attrs = {}
	for field, value in pairs(base) do
		attrs[field] = value
	end
	for field, value in pairs(overrides or {}) do
		attrs[field] = value
	end
	return attrs
end

-- nil values vanish in pairs(), so removal needs its own helper
local function without(base, field)
	local attrs = with(base)
	attrs[field] = nil
	return attrs
end

local function last_service()
	local entry = stub.last_proxy('HA_CALL_SERVICE', HUB)
	if not entry then
		return nil
	end
	return entry.params
end

-- Most recent DYNAMIC_CAPABILITIES_CHANGED payload carrying param_key.
local function find_caps(param_key)
	for i = #stub.proxy_sent, 1, -1 do
		local entry = stub.proxy_sent[i]
		if entry.command == 'DYNAMIC_CAPABILITIES_CHANGED' and entry.params[param_key] ~= nil then
			return entry.params
		end
	end
	return nil
end

local function count_thermo_sends()
	local total = 0
	for _, entry in ipairs(stub.proxy_sent) do
		if entry.binding == THERMO then
			total = total + 1
		end
	end
	return total
end

---------------------------------------------------------------- registration

OnDriverLateInit()
local reg = stub.last_proxy('HA_REGISTER', HUB)
check(reg ~= nil, 'registers on late init')
check_eq(reg.params.entity_id, 'climate.living', 'registers configured entity')
check_eq(reg.params.device_id, 42, 'registers own device id')
local list = stub.last_proxy('HA_LIST_ENTITIES', HUB)
check(list ~= nil, 'requests entity list')
check_eq(list.params.domain, 'climate', 'requests climate entities')

---------------------------------------------------------------- first heat_cool push

local base = {
	hvac_modes = 'off,heat,cool,heat_cool',
	supported_features = 386, -- TURN_ON|TURN_OFF|TARGET_TEMPERATURE_RANGE
	min_temp = 7,
	max_temp = 30,
	target_temp_step = 0.5,
	current_temperature = 21.5,
	target_temp_low = 20,
	target_temp_high = 24,
	hvac_action = 'idle',
	temperature_unit = 'C',
}

stub.clear_captures()
ha_state('heat_cool', base)

-- has_connection_status makes IS_CONNECTED start false with a dead UI, so
-- CONNECTION must open the initial sync sweep
local first_thermo
for _, entry in ipairs(stub.proxy_sent) do
	if entry.binding == THERMO then
		first_thermo = entry
		break
	end
end
check(first_thermo ~= nil, 'proxy notified on first state')
check_eq(first_thermo.command, 'CONNECTION', 'CONNECTION opens the initial sweep')
check_eq(first_thermo.params.CONNECTED, 'true', 'connected on first good state')

local allowed = stub.last_proxy('ALLOWED_HVAC_MODES_CHANGED', THERMO)
check(allowed ~= nil, 'allowed HVAC modes sent')
check_eq(allowed.params.MODES, 'Off,Heat,Cool,Auto', 'heat_cool mapped to Auto')
check_eq(allowed.params.CAN_HEAT, true, 'CAN_HEAT derived from mode list')
check_eq(allowed.params.CAN_COOL, true, 'CAN_COOL derived from mode list')
check_eq(allowed.params.CAN_AUTO, true, 'CAN_AUTO derived from mode list')

local caps = find_caps('HEAT_SETPOINT_MIN_C')
check(caps ~= nil, 'setpoint range capabilities sent')
check_eq(caps.HEAT_SETPOINT_MIN_C, 7, 'min in celsius')
check_eq(caps.HEAT_SETPOINT_MIN_F, 45, 'min converted to fahrenheit')
check_eq(caps.COOL_SETPOINT_MAX_C, 30, 'max in celsius')
check_eq(caps.COOL_SETPOINT_MAX_F, 86, 'max converted to fahrenheit')
check_eq(caps.SINGLE_SETPOINT_MIN_F, 45, 'single min tracks the same range')
check_eq(caps.SINGLE_SETPOINT_MAX_C, 30, 'single max tracks the same range')

local res = find_caps('TEMPERATURE_RESOLUTION_C')
check(res ~= nil, 'resolutions sent')
check_eq(res.TEMPERATURE_RESOLUTION_C, 0.5, 'celsius resolution from step')
check_eq(res.TEMPERATURE_RESOLUTION_F, 1, 'fahrenheit resolution paired')
check_eq(res.HEAT_SETPOINT_RESOLUTION_C, 0.5, 'heat setpoint resolution')
check_eq(res.COOL_SETPOINT_RESOLUTION_F, 1, 'cool setpoint resolution')

check_eq(find_caps('HAS_SINGLE_SETPOINT').HAS_SINGLE_SETPOINT, false, 'heat_cool is dual setpoint')
check_eq(find_caps('HAS_HUMIDITY').HAS_HUMIDITY, false, 'no humidity reported')

check_eq(stub.last_proxy('HVAC_MODE_CHANGED', THERMO).params.MODE, 'Auto', 'heat_cool -> Auto')
check_eq(stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE, 'Off', 'idle -> Off')

local temp = stub.last_proxy('TEMPERATURE_CHANGED', THERMO)
check_eq(temp.params.TEMPERATURE, 21.5, 'current temperature raw HA value')
check_eq(temp.params.SCALE, 'CELSIUS', 'tagged with the HA unit')

check_eq(stub.last_proxy('HEAT_SETPOINT_CHANGED', THERMO).params.SETPOINT, 20, 'low -> heat')
check_eq(stub.last_proxy('COOL_SETPOINT_CHANGED', THERMO).params.SETPOINT, 24, 'high -> cool')
check(stub.last_proxy('FAN_STATE_CHANGED', THERMO) == nil, 'no fan state without fan modes')
check(stub.last_proxy('ALLOWED_FAN_MODES_CHANGED', THERMO) == nil, 'no fan modes advertised')

check_eq(Properties['Climate State'], 'heat_cool', 'state property updated')
check_eq(Properties['HVAC Modes'], 'Off,Heat,Cool,Auto', 'modes property updated')
check_eq(Properties['Current Temperature'], '21.5', 'temperature property updated')
check_eq(Properties['Setpoints'], '20 – 24', 'setpoints rendered as range')

---------------------------------------------------------------- change detection

stub.clear_captures()
ha_state('heat_cool', base)
check_eq(#stub.proxy_sent, 0, 'identical re-push sends nothing')

stub.clear_captures()
ha_state('heat_cool', with(base, { current_temperature = 21.9 }))
check_eq(#stub.proxy_sent, 1, 'single attribute change -> exactly one notify')
check_eq(stub.proxy_sent[1].command, 'TEMPERATURE_CHANGED', 'and it is the temperature')

---------------------------------------------------------------- range commands

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '21', FAHRENHEIT = '69.8' })
local call = last_service()
check_eq(call.service, 'set_temperature', 'heat setpoint -> set_temperature')
check_eq(call.domain, 'climate', 'climate domain')
check_eq(call.entity_id, 'climate.living', 'service targets entity')
check_eq(call.target_temp_low, 21, 'low bound from command')
check_eq(call.target_temp_high, 24, 'high bound always paired (HA rejects lone bounds)')
check(call.temperature == nil, 'no single temperature in range mode')
check(call.hvac_mode == nil, 'setpoint drag never mutates the mode')

ReceivedFromProxy(THERMO, 'SET_SETPOINT_COOL', { CELSIUS = '25', FAHRENHEIT = '77' })
call = last_service()
check_eq(call.target_temp_low, 21, 'low from the optimistic cache')
check_eq(call.target_temp_high, 25, 'high from command')

-- clamps: heat against the cached cool bound, cool against the entity max,
-- and quantization to the entity step
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '27' })
call = last_service()
check_eq(call.target_temp_low, 25, 'heat clamped to the cool bound')
check_eq(call.target_temp_high, 25, 'pair stays ordered')

ReceivedFromProxy(THERMO, 'SET_SETPOINT_COOL', { CELSIUS = '35' })
call = last_service()
check_eq(call.target_temp_high, 30, 'cool clamped to max_temp')

ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '20.3' })
call = last_service()
check_eq(call.target_temp_low, 20.5, 'value quantized to target_temp_step')

---------------------------------------------------------------- HA is authoritative

-- HA adjusted the pair (e.g. minimum range gap): the push overwrites the
-- optimistic caches and notifies the changed setpoint
stub.clear_captures()
ha_state('heat_cool', with(base, { target_temp_low = 21.5, current_temperature = 21.9 }))
check_eq(stub.last_proxy('HEAT_SETPOINT_CHANGED', THERMO).params.SETPOINT, 21.5, 'HA value wins')
check(stub.last_proxy('COOL_SETPOINT_CHANGED', THERMO) == nil, 'unchanged cool not re-notified')

ReceivedFromProxy(THERMO, 'SET_SETPOINT_COOL', { CELSIUS = '23' })
call = last_service()
check_eq(call.target_temp_low, 21.5, 'HA-confirmed low pairs the next cool command')
check_eq(call.target_temp_high, 23, 'new high')

---------------------------------------------------------------- single-setpoint modes

local heat_attrs = {
	hvac_modes = 'off,heat,cool,heat_cool',
	supported_features = 385, -- range bit dropped outside heat_cool
	min_temp = 7,
	max_temp = 30,
	target_temp_step = 0.5,
	current_temperature = 21.9,
	temperature = 22,
	hvac_action = 'heating',
	temperature_unit = 'C',
}

stub.clear_captures()
ha_state('heat', heat_attrs)
check_eq(stub.last_proxy('HVAC_MODE_CHANGED', THERMO).params.MODE, 'Heat', 'heat mode')
check_eq(stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE, 'Heat', 'heating -> Heat')
check_eq(
	stub.last_proxy('HEAT_SETPOINT_CHANGED', THERMO).params.SETPOINT,
	22,
	'temperature -> heat'
)

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '23', FAHRENHEIT = '73.4' })
call = last_service()
check_eq(call.temperature, 23, 'single-setpoint service shape in heat mode')
check(call.target_temp_low == nil, 'no range bounds outside range mode')

-- doc-driven edge: only FAHRENHEIT present on a Celsius entity -> converted
stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { FAHRENHEIT = '69.8' })
call = last_service()
check_eq(call.temperature, 21, 'lone FAHRENHEIT field converted to the HA unit')

stub.clear_captures()
ha_state('off', { hvac_action = 'off' })
check_eq(stub.last_proxy('HVAC_MODE_CHANGED', THERMO).params.MODE, 'Off', 'off mode')
stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '23' })
check(last_service() == nil, 'setpoint while off dropped')

---------------------------------------------------------------- mode switch keeps the pair

-- Back to heat_cool with no bounds in the push: the cached pair (low 22 from
-- the heat push, high 23 from the last confirmed range) drives the first
-- outbound range command
stub.clear_captures()
ha_state('heat_cool', {
	supported_features = 386,
	hvac_action = 'idle',
	current_temperature = 21.9,
})
check_eq(stub.last_proxy('HVAC_MODE_CHANGED', THERMO).params.MODE, 'Auto', 'back to Auto')
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '21' })
call = last_service()
check_eq(call.target_temp_low, 21, 'commanded low')
check_eq(call.target_temp_high, 23, 'high survives the mode round-trip')

---------------------------------------------------------------- mode commands

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_MODE_HVAC', { MODE = 'Auto' })
call = last_service()
check_eq(call.service, 'set_hvac_mode', 'mode command -> set_hvac_mode')
check_eq(call.hvac_mode, 'heat_cool', 'Auto -> heat_cool when the entity has it')

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_MODE_HVAC', { MODE = 'Heat' })
check_eq(last_service().hvac_mode, 'heat', 'Heat -> heat')
check_eq(
	stub.last_proxy('HVAC_MODE_CHANGED', THERMO).params.MODE,
	'Heat',
	'optimistic echo so Navigator does not snap back'
)
-- HA never confirms: the watchdog reverts to the last confirmed mode
stub.run_timers()
check_eq(stub.last_proxy('HVAC_MODE_CHANGED', THERMO).params.MODE, 'Auto', 'watchdog revert')

-- entity with plain auto (no heat_cool): Auto maps to auto, single setpoint
stub.clear_captures()
ha_state('auto', {
	hvac_modes = 'off,heat,auto',
	supported_features = 385,
	temperature = 22,
	current_temperature = 21.9,
})
check_eq(
	stub.last_proxy('ALLOWED_HVAC_MODES_CHANGED', THERMO).params.MODES,
	'Off,Heat,Auto',
	'plain auto also maps to Auto'
)
check_eq(find_caps('HAS_SINGLE_SETPOINT').HAS_SINGLE_SETPOINT, true, 'single setpoint flip')
check_eq(
	stub.last_proxy('SINGLE_SETPOINT_CHANGED', THERMO).params.SETPOINT,
	22,
	'single setpoint value'
)
ReceivedFromProxy(THERMO, 'SET_MODE_HVAC', { MODE = 'Auto' })
check_eq(last_service().hvac_mode, 'auto', 'Auto -> auto without heat_cool')

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SETPOINT_SINGLE', { CELSIUS = '21', FAHRENHEIT = '69.8' })
call = last_service()
check_eq(call.temperature, 21, 'single setpoint -> temperature')
check(call.target_temp_low == nil, 'no bounds for single setpoint')

-- holds are not supported: logged no-op, no service call
stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_MODE_HOLD', { MODE = 'Permanent' })
check(last_service() == nil, 'SET_MODE_HOLD is a no-op')

---------------------------------------------------------------- action mapping

stub.clear_captures()
ha_state('heat', { hvac_action = 'heating', temperature = 22 })
check_eq(stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE, 'Heat', 'heating -> Heat')
ha_state('heat', { hvac_action = 'fan', temperature = 22 })
check_eq(stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE, 'Fan', 'fan -> Fan')
ha_state('heat', { hvac_action = 'drying', temperature = 22 })
check_eq(stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE, 'Heat', 'drying -> Heat')
ha_state('heat', { hvac_action = 'idle', temperature = 22 })
check_eq(stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE, 'Off', 'idle -> Off')
ha_state('cool', { temperature = 24 })
check_eq(
	stub.last_proxy('HVAC_STATE_CHANGED', THERMO).params.STATE,
	'Cool',
	'absent action falls back to the mode'
)

---------------------------------------------------------------- fan modes

local fan_attrs = {
	fan_modes = 'auto,low,high',
	fan_mode = 'low',
	hvac_action = 'cooling',
	temperature = 24,
	current_temperature = 24.5,
}
stub.clear_captures()
ha_state('cool', fan_attrs)
local fan_allowed = stub.last_proxy('ALLOWED_FAN_MODES_CHANGED', THERMO)
check(fan_allowed ~= nil, 'fan modes advertised')
check_eq(fan_allowed.params.MODES, 'auto,low,high', 'HA fan mode names verbatim')
check_eq(type(fan_allowed.params.MODES), 'string', 'MODES is a CSV string, never a table')
check_eq(stub.last_proxy('FAN_MODE_CHANGED', THERMO).params.MODE, 'low', 'fan mode verbatim')
-- docs say FAN_STATE_CHANGE, the field-proven reference sends FAN_STATE_CHANGED:
-- both spellings go out
check_eq(stub.last_proxy('FAN_STATE_CHANGE', THERMO).params.STATE, 'Off', 'fan state (docs name)')
check_eq(
	stub.last_proxy('FAN_STATE_CHANGED', THERMO).params.STATE,
	'Off',
	'fan state (reference name)'
)

stub.clear_captures()
ha_state('cool', fan_attrs)
check_eq(#stub.proxy_sent, 0, 'identical fan push sends nothing')

stub.clear_captures()
ha_state('cool', with(fan_attrs, { fan_mode = 'on' }))
check_eq(stub.last_proxy('FAN_STATE_CHANGE', THERMO).params.STATE, 'On', 'fan_mode on -> On')
check_eq(stub.last_proxy('FAN_STATE_CHANGED', THERMO).params.STATE, 'On', 'both spellings track')

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_MODE_FAN', { MODE = 'low' })
call = last_service()
check_eq(call.service, 'set_fan_mode', 'fan command -> set_fan_mode')
check_eq(call.fan_mode, 'low', 'fan mode string passed flat')

---------------------------------------------------------------- unavailable

stub.clear_captures()
ha_state('unavailable', {})
local conn = stub.last_proxy('CONNECTION', THERMO)
check(conn ~= nil, 'unavailable -> CONNECTION')
check_eq(conn.params.CONNECTED, 'false', 'disconnected')
check_eq(count_thermo_sends(), 1, 'no value notifies while unavailable')
check_eq(Properties['Climate State'], 'unavailable', 'state property shows outage')

stub.clear_captures()
ha_state('cool', with(fan_attrs, { fan_mode = 'on' }))
conn = stub.last_proxy('CONNECTION', THERMO)
check(conn ~= nil and conn.params.CONNECTED == 'true', 'recovery -> CONNECTION true')
check(
	stub.last_proxy('TEMPERATURE_CHANGED', THERMO) ~= nil,
	'recovery re-emits values even if unchanged'
)
check(stub.last_proxy('HVAC_MODE_CHANGED', THERMO) ~= nil, 'recovery re-emits the mode')

---------------------------------------------------------------- fahrenheit server

stub.clear_captures()
ha_state('heat', {
	temperature_unit = 'F',
	min_temp = 40,
	max_temp = 90,
	target_temp_step = 1,
	current_temperature = 70,
	temperature = 68,
	hvac_action = 'heating',
})
temp = stub.last_proxy('TEMPERATURE_CHANGED', THERMO)
check_eq(temp.params.TEMPERATURE, 70, 'fahrenheit value raw')
check_eq(temp.params.SCALE, 'FAHRENHEIT', 'tagged FAHRENHEIT')
check_eq(
	stub.last_proxy('HEAT_SETPOINT_CHANGED', THERMO).params.SCALE,
	'FAHRENHEIT',
	'setpoints tagged too'
)
caps = find_caps('HEAT_SETPOINT_MIN_C')
check_eq(caps.HEAT_SETPOINT_MIN_F, 40, 'fahrenheit min raw')
check_eq(caps.HEAT_SETPOINT_MIN_C, 4.5, 'celsius min converted, half-degree steps')
check_eq(caps.COOL_SETPOINT_MAX_C, 32, 'celsius max converted')

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SETPOINT_HEAT', { CELSIUS = '20', FAHRENHEIT = '68' })
check_eq(last_service().temperature, 68, 'FAHRENHEIT field preferred on an F server')

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SET_SCALE', { SCALE = 'FAHRENHEIT' })
check_eq(
	stub.last_proxy('SCALE_CHANGED', THERMO).params.SCALE,
	'FAHRENHEIT',
	'scale change acknowledged'
)
check_eq(stub.persist['SELECTED_SCALE'], 'FAHRENHEIT', 'scale persisted')

---------------------------------------------------------------- reconnect loop guard

stub.clear_captures()
ExecuteCommand('HA_CONNECTION', { connected = 'true' }) -- transition: down -> up
check(stub.last_proxy('HA_REGISTER', HUB) ~= nil, 'first connected=true registers')

-- LOOP GUARD: repeated connection messages with the same state must be
-- ignored -- reacting to every one (not just transitions) closed a
-- register->ack->register loop with the gateway that crashed Director.
stub.clear_captures()
ExecuteCommand('HA_CONNECTION', { connected = 'true' })
ExecuteCommand('HA_CONNECTION', { connected = 'true' })
check(stub.last_proxy('HA_REGISTER', HUB) == nil, 'repeated connected=true ignored')

stub.clear_captures()
ExecuteCommand('HA_CONNECTION', { connected = 'false' })
conn = stub.last_proxy('CONNECTION', THERMO)
check(conn ~= nil and conn.params.CONNECTED == 'false', 'gateway loss -> proxy disconnected')
ExecuteCommand('HA_CONNECTION', { connected = 'true' })
check(stub.last_proxy('HA_REGISTER', HUB) ~= nil, 're-registers on reconnect')
check(stub.last_proxy('HA_LIST_ENTITIES', HUB) ~= nil, 'refreshes the entity list')

---------------------------------------------------------------- entity list + selector

ExecuteCommand('HA_ENTITY_LIST', {
	domain = 'climate',
	entities = 'climate.bedroom,climate.living',
})
check_eq(
	stub.property_lists['Entity Selector'],
	',climate.bedroom,climate.living',
	'selector list populated with blank first entry'
)

-- Picking from the dropdown must do nothing inside the callback (Composer is
-- still processing the selection there) and everything on the deferred timer.
stub.clear_captures()
Properties['Entity Selector'] = 'climate.bedroom'
OnPropertyChanged('Entity Selector')
check(stub.last_proxy('HA_REGISTER', HUB) == nil, 'selector reaction deferred')
check_eq(#stub.properties_updated, 0, 'no property writes inside the callback')
stub.run_timers()
check_eq(Properties['Entity ID'], 'climate.bedroom', 'selector pick lands in Entity ID')
check(stub.last_proxy('HA_UNREGISTER', HUB) ~= nil, 'entity change unregisters old')
reg = stub.last_proxy('HA_REGISTER', HUB)
check_eq(reg.params.entity_id, 'climate.bedroom', 'entity change registers new')
check_eq(Properties['Entity Selector'], '', 'selector reset after apply')
check_eq(Properties['Climate State'], '', 'stale state cleared on entity change')

---------------------------------------------------------------- humidity

local bedroom = {
	hvac_modes = 'off,cool',
	supported_features = 1,
	min_temp = 16,
	max_temp = 30,
	target_temp_step = 0.5,
	current_temperature = 24,
	temperature = 22,
	current_humidity = 55,
	hvac_action = 'cooling',
	temperature_unit = 'C',
}

stub.clear_captures()
ha_state_for('climate.bedroom', 'cool', bedroom)
check_eq(find_caps('HAS_HUMIDITY').HAS_HUMIDITY, true, 'humidity capability flips on')
check_eq(stub.last_proxy('HUMIDITY_CHANGED', THERMO).params.HUMIDITY, 55, 'humidity value')

stub.clear_captures()
ha_state_for('climate.bedroom', 'cool', bedroom)
check_eq(#stub.proxy_sent, 0, 'no humidity re-flip on identical push')

stub.clear_captures()
ha_state_for('climate.bedroom', 'cool', with(bedroom, { current_humidity = 60 }))
check_eq(#stub.proxy_sent, 1, 'humidity change -> exactly one notify')
check_eq(stub.proxy_sent[1].command, 'HUMIDITY_CHANGED', 'and it is the humidity')

stub.clear_captures()
ha_state_for('climate.bedroom', 'cool', without(bedroom, 'current_humidity'))
check_eq(find_caps('HAS_HUMIDITY').HAS_HUMIDITY, false, 'humidity capability flips off')
check(stub.last_proxy('HUMIDITY_CHANGED', THERMO) == nil, 'no humidity value without the attr')
check_eq(count_thermo_sends(), 1, 'disappearance is a single capability flip')

---------------------------------------------------------------- presets via Extras

stub.clear_captures()
ha_state_for(
	'climate.bedroom',
	'cool',
	with(bedroom, { preset_modes = 'eco,comfort & away', preset_mode = 'eco' })
)
local setup = stub.last_proxy('EXTRAS_SETUP_CHANGED', THERMO)
check(setup ~= nil, 'extras setup sent for presets')
check(
	setup.params.XML:find('command="SELECT_HA_PRESET_MODE"', 1, true) ~= nil,
	'extras list routes to the preset command'
)
check(
	setup.params.XML:find('<item text="comfort &amp; away" value="comfort &amp; away"/>', 1, true)
		~= nil,
	'preset names XML-escaped'
)
local extras_state = stub.last_proxy('EXTRAS_STATE_CHANGED', THERMO)
check(
	extras_state ~= nil and extras_state.params.XML:find('value="eco"', 1, true) ~= nil,
	'current preset in extras state'
)

stub.clear_captures()
ha_state_for(
	'climate.bedroom',
	'cool',
	with(bedroom, { preset_modes = 'eco,comfort & away', preset_mode = 'comfort & away' })
)
extras_state = stub.last_proxy('EXTRAS_STATE_CHANGED', THERMO)
check(
	extras_state ~= nil
		and extras_state.params.XML:find('value="comfort &amp; away"', 1, true) ~= nil,
	'preset change updates extras state, escaped'
)
check(stub.last_proxy('EXTRAS_SETUP_CHANGED', THERMO) == nil, 'unchanged setup not re-sent')

stub.clear_captures()
ReceivedFromProxy(THERMO, 'SELECT_HA_PRESET_MODE', { value = 'eco' })
call = last_service()
check_eq(call.service, 'set_preset_mode', 'extras selection -> set_preset_mode')
check_eq(call.preset_mode, 'eco', 'preset string passed flat')

stub.finish('test_climate')
